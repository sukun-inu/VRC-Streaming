#!/bin/sh
# =============================================================================
#  RTMP -> HLS  変換ループ
# =============================================================================
#  publisher(OBS) が来るまで待ち、来たら変換し、切れたらまた待つ。
#  この3状態しかありません。どこで死んでも待機状態に戻ります。
#
#  外部コマンドは ffmpeg / ffprobe / find / grep / date のみ。計算はすべて
#  シェルの整数演算で済ませてあり awk にも依存しません。
#  ベースイメージを差し替えても壊れにくくするためです。
# =============================================================================
set -u

# --- 配線 (compose の environment ではなくここ。運用中に変えるものではない) ---
SRC="rtmp://127.0.0.1:1935/origin"   # mediamtx.yml の rtmpAddress と paths に対応
OUT_DIR="/hls/live"                  # nginx/hls.conf の root + /live に対応

# --- 運用ノブ (compose の environment から渡る) ------------------------------
MODE="${MODE:-copy}"
SEG="${SEG_SECONDS:-1}"
LIST="${SEG_LIST_SIZE:-8}"
KEEP="${SEG_KEEP_EXTRA:-60}"
GOP_CHECK="${GOP_CHECK_SECONDS:-4}"

PLAYLIST="${OUT_DIR}/index.m3u8"
FFPID=""

log()  { echo "[$(date -u '+%H:%M:%S')] $*"; }
warn() { echo "[$(date -u '+%H:%M:%S')] !! $*"; }

# 数値かどうか。これを通さずに $(( )) へ渡すと、想定外の入力でシェルごと落ちます。
is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

for c in ffmpeg ffprobe; do
  command -v "$c" >/dev/null || { echo "FATAL: ${c} が見つかりません"; exit 1; }
done

mkdir -p "$OUT_DIR"

# ffmpeg はバックグラウンドで動かして wait で待ちます。前面で動かすと停止シグナルを
# 受けてもこの trap が ffmpeg の終了まで走らず、停止に10秒待たされます。
trap '[ -n "$FFPID" ] && kill "$FFPID" 2>/dev/null; rm -f "$PLAYLIST"; exit 0' TERM INT

log "mode=${MODE} segment=${SEG}s window=$(( SEG * LIST ))s grace=$(( SEG * KEEP ))s latency~$(( SEG * 3 + 2 ))s"

while :; do

  # ---------------------------------------------------------------------------
  # 1) publisher を待つ
  #    MediaMTX は publisher 不在のパスへの play を即座に拒否するので、
  #    ffprobe は待たされずすぐ失敗して返ってきます。
  #
  #    ここで ffprobe を使えるのが MediaMTX を挟んでいる理由です。
  #    ffmpeg の -listen 1 で直接 RTMP を受けると接続が1本しか張れず、
  #    検査と配信を同時にできません。
  # ---------------------------------------------------------------------------
  V=$(ffprobe -v error -select_streams v:0 -analyzeduration 2000000 -probesize 2000000 \
        -show_entries stream=codec_name,profile,width,height,r_frame_rate,pix_fmt \
        -of csv=p=0 "$SRC" 2>/dev/null)
  [ -n "$V" ] || { sleep 3; continue; }

  A=$(ffprobe -v error -select_streams a:0 -analyzeduration 2000000 -probesize 2000000 \
        -show_entries stream=codec_name,sample_rate,channels \
        -of csv=p=0 "$SRC" 2>/dev/null)

  RUN="$(date -u +%Y%m%d%H%M%S)"
  log "--- publisher detected (run=${RUN}) ---"

  # ---------------------------------------------------------------------------
  # 2) 入力の検査
  #    copy は OBS の出力をそのまま流すので、ここで見ておかないと
  #    「サーバは正常なのに VRChat だけ再生できない」になります。
  # ---------------------------------------------------------------------------
  IFS=, read -r VCODEC VPROF VW VH VRATE VPIX <<EOF
$V
EOF

  # r_frame_rate は "30/1" や "30000/1001" の形。四捨五入して整数 fps にする。
  FPS=0
  RNUM="${VRATE%%/*}"; RDEN="${VRATE##*/}"
  if is_num "$RNUM" && is_num "$RDEN" && [ "$RDEN" -gt 0 ]; then
    FPS=$(( (RNUM + RDEN / 2) / RDEN ))
  fi

  if [ -n "$A" ]; then
    IFS=, read -r ACODEC ARATE ACH <<EOF
$A
EOF
    log "input: ${VCODEC} ${VPROF} ${VW}x${VH} ${FPS}fps ${VPIX} / ${ACODEC} ${ARATE}Hz ${ACH}ch"
  else
    ACODEC=""
    log "input: ${VCODEC} ${VPROF} ${VW}x${VH} ${FPS}fps ${VPIX} / 音声なし"
  fi

  if [ "$MODE" = "copy" ]; then
    if [ "$VCODEC" = "h264" ]; then
      case "$VPROF" in
        Baseline|"Constrained Baseline"|Main|High) ;;
        *) warn "H.264 プロファイル ${VPROF} は Quest で再生できない可能性が高い" ;;
      esac
    else
      warn "映像が ${VCODEC}。VRChat は H.264 のみ。OBS を直すか MODE=transcode に"
    fi
    [ "$VPIX" = "yuv420p" ] || warn "pix_fmt が ${VPIX}。Quest は yuv420p しか再生できません"
    [ -n "$ACODEC" ] && [ "$ACODEC" != "aac" ] && warn "音声が ${ACODEC}。VRChat は AAC のみ"
    is_num "$VW" && [ "$VW" -gt 1920 ] && warn "横 ${VW}px。Quest 向けには 1920 以下を推奨"
    is_num "$VH" && [ "$VH" -gt 1080 ] && warn "縦 ${VH}px。Quest 向けには 1080 以下を推奨"
    is_num "$VH" && [ "$FPS" -gt 30 ] && [ "$VH" -gt 720 ] &&
      warn "${VW}x${VH}@${FPS} は Quest だと描画とデコーダが競合しやすい"
  fi

  # ---------------------------------------------------------------------------
  # 3) キーフレーム間隔の実測 (copy 運用での最重要項目)
  #    OBS のキーフレーム間隔が SEG_SECONDS と違うと、ffmpeg は指定どおりに
  #    切れず OBS 側の間隔で切ります。遅延がそのぶん伸びます。
  #    「なぜか遅延が想定の倍」はほぼこれです。
  #
  #    小数を扱わずに済むよう、すべて 1/10 秒単位の整数で計算しています。
  # ---------------------------------------------------------------------------
  if is_num "$GOP_CHECK" && [ "$GOP_CHECK" -gt 0 ]; then
    KF=$(ffprobe -v error -select_streams v:0 -read_intervals "%+${GOP_CHECK}" \
           -show_entries frame=key_frame -of csv=p=0 "$SRC" 2>/dev/null | grep -c '^1')
    if is_num "$KF" && [ "$KF" -gt 0 ]; then
      EST10=$(( GOP_CHECK * 10 / KF ))          # 例: 4秒に2枚 -> 20 (=2.0秒)
      log "keyframe interval: 約 $(( EST10 / 10 )).$(( EST10 % 10 ))s"
      # 許容 ±30%。EST10 は10倍値なので閾値も10倍で比較する。
      if [ "$EST10" -gt $(( SEG * 13 )) ] || [ "$EST10" -lt $(( SEG * 7 )) ]; then
        warn "キーフレーム間隔が SEG_SECONDS=${SEG}s と一致していません"
        warn "  OBS の「キーフレーム間隔」を ${SEG} 秒にしてください"
        warn "  このままだと遅延が約 $(( EST10 * 3 / 10 + 2 ))s になります"
      fi
    fi
  fi

  # ---------------------------------------------------------------------------
  # 4) 前回の残骸を掃除
  #    セグメント名に RUN が入るので、消しても CDN 上のキャッシュ済み URL と
  #    名前が衝突しません。固定名を使い回すと Cloudflare が前回配信の中身を
  #    返してしまいます。
  # ---------------------------------------------------------------------------
  rm -f "$PLAYLIST"
  find "$OUT_DIR" -maxdepth 1 -type f -name '*.ts' -delete 2>/dev/null

  # ---------------------------------------------------------------------------
  # 5) コーデック指定
  # ---------------------------------------------------------------------------
  if [ "$MODE" = "copy" ]; then
    VOPT="-c:v copy"
    AENC="-c:a copy"
  else
    # 切り分け用の固定プロファイル。ここは環境変数で変えられません。
    # 「既知の正常値」であることが唯一の存在価値なので、可変にすると
    # 切り分けの道具として機能しなくなります。
    VOPT="-vf scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2
          -c:v libx264 -preset veryfast -profile:v main -level:v 4.0 -pix_fmt yuv420p
          -b:v 3500k -maxrate 3500k -bufsize 7000k
          -r 30 -g $(( 30 * SEG )) -keyint_min $(( 30 * SEG )) -sc_threshold 0 -bf 0"
    AENC="-c:a aac -b:a 128k -ar 48000 -ac 2"
  fi

  # 音声トラックが無い入力にも無音 AAC を必ず載せます。
  # 音声なしの HLS は AVPro が読み込みに失敗することがあります。
  if [ -n "$ACODEC" ]; then
    SILENCE=""
    MAPS="-map 0:v:0 -map 0:a:0"
    AOPT="$AENC"
  else
    SILENCE="-f lavfi -i anullsrc=channel_layout=stereo:sample_rate=48000"
    MAPS="-map 0:v:0 -map 1:a:0"
    AOPT="-c:a aac -b:a 128k -ar 48000 -ac 2 -shortest"
  fi

  # ---------------------------------------------------------------------------
  # 6) HLS 出力
  #
  #   hls_delete_threshold がこのスタックの要です。
  #   プレイリストから外した後もディスクに残す本数で、既定は 1。
  #   ここに残ったセグメントはプレイリストに現れないので遅延に影響せず、
  #   取得が遅れたクライアントが 404 を踏まなくなるだけです。
  #   MediaMTX の HLS マキサーにはこの概念がありません。
  #
  #   temp_file : .tmp に書いてから rename。書きかけを nginx が配る事故を防ぐ。
  #   master playlist は作りません (単一レンディションなので不要)。
  # ---------------------------------------------------------------------------
  log "starting ffmpeg"

  # shellcheck disable=SC2086
  ffmpeg -hide_banner -loglevel warning -nostdin \
    -fflags nobuffer -analyzeduration 2000000 -probesize 2000000 \
    -i "$SRC" $SILENCE \
    $MAPS $VOPT $AOPT \
    -f hls \
    -hls_time "$SEG" \
    -hls_list_size "$LIST" \
    -hls_delete_threshold "$KEEP" \
    -hls_flags delete_segments+omit_endlist+temp_file \
    -hls_segment_type mpegts \
    -hls_segment_filename "${OUT_DIR}/${RUN}_%06d.ts" \
    "$PLAYLIST" &

  FFPID=$!
  wait "$FFPID"
  FFPID=""

  # プレイリストを消します。残すと「配信中に見えるのに全セグメント404」という
  # 一番わかりにくい状態になります。
  rm -f "$PLAYLIST"
  log "ffmpeg exited — 待機に戻ります"
  sleep 2
done
