# VRChat HLS 配信スタック

自宅から VRChat に映像を流すための配信サーバ。PC と Quest の同時視聴前提。
Portainer の Git スタックとしてそのままデプロイできます。

```
OBS ─RTMP:1935→ mediamtx ─RTMP─→ transcoder ─HLS→ tmpfs ←─ nginx:80
                                                               ↑
                                           既存の cloudflared ─┘
```

cloudflared はこのスタックに含みません。既存のものをそのまま使います。

---

## 1. 動かす

**先に旧スタックを落としてください。** `network_mode: host` なので、
旧構成の MediaMTX が `:80` と `:1935` を掴んだままだと起動に失敗します。

Portainer → Stacks → Add stack → **Repository**

| | |
|---|---|
| Repository URL | このリポジトリ |
| Compose path | `docker-compose.yml` |
| Environment variables | 不要（全て既定値あり） |

ビルドは発生しません。公開イメージを pull して `transcoder/run.sh` を
マウントするだけです。GitOps updates を有効にすれば push で再デプロイされます。

> **なぜビルドしないのか**
> Portainer が Docker socket proxy 越しに Docker へ繋いでいる構成だと、
> BuildKit の gRPC セッション (`/session`) がプロキシを通れず、
> `failed to list workers ... frame too large, note that the frame header
> looked like an HTTP/1.1 header` でスタックのデプロイごと失敗します。
> ビルドを無くせばこの経路を一切使いません。

既存トンネルの Service が `http://localhost:80` を向いている想定です。
違うポートなら `nginx/hls.conf` の `listen` を合わせてください。
**cloudflared 側の設定変更は不要です。**

## 2. OBS を設定する

`MODE=copy`（既定）は OBS の出力を再エンコードせずそのまま流します。
CPU をまったく使わず遅延も最小ですが、そのぶん**OBS の設定がそのまま結果になります**。

| 項目 | 値 |
|---|---|
| サーバー | `rtmp://<ホストIP>:1935/` |
| ストリームキー | `origin` |
| 出力解像度 | 1280x720（1920x1080 まで可） |
| FPS | 30（Quest 同時視聴なら 60 は避ける） |
| レート制御 | CBR / 3500〜6000 kbps |
| **キーフレーム間隔** | **1 秒** |
| プロファイル | main または high |
| **B フレーム** | **0** |
| カラーフォーマット | NV12（10bit 不可） |
| 音声 | AAC 128kbps / 48kHz / ステレオ |

**キーフレーム間隔だけは厳密に。** ここが `SEG_SECONDS` とずれると、
ffmpeg は指定どおりに切れず OBS 側の間隔で切ります。2 秒なら遅延が倍になります。
間違えていればログが教えてくれるので、暗記する必要はありません。

## 3. VRChat の URL

```
https://<トンネルのホスト名>/live/index.m3u8
```

master playlist は作っていません。単一レンディションなので不要ですし、
バリアント選択まわりのトラブルを丸ごと排除できます。

---

## なぜこの構成なのか

### 遅延と安定性は別の軸で、旧構成はそれを分離できなかった

HLS プレイヤーの挙動を決めるのは、実は2つの別々のものです。

- **プレイリストに何本載っているか** → プレイヤーがどこから再生を始めるか → **遅延**
- **ディスクに何本残っているか** → 出遅れたクライアントがまだ取得できるか → **安定性**

MediaMTX の HLS マキサーは、この2つを `hlsSegmentCount` という**1つの数**で
まとめて扱います。RAM のリングバッファなので、プレイリストから溢れた瞬間に
実体も消えます。旧構成は `1秒 × 7本` だったので、

> プレイリストに 7 秒ぶん載っていて、**7 秒より古いものは存在しない**

という状態でした。猶予がゼロです。Quest の起動時バッファリング（PC より
1〜3 秒遅い）、Cloudflare エッジの往復、OBS の GOP のわずかな揺れ。
このどれかが重なって 7 秒の窓を踏み外した瞬間に 404 で死にます。
同じ URL・同じ設定なのに 18 秒差で成否が割れたのはこれが理由です。

ffmpeg の HLS マキサーはこの2つを別の設定として持っています。

| | ffmpeg | MediaMTX |
|---|---|---|
| プレイリストに載せる本数 | `hls_list_size` | `hlsSegmentCount` |
| 外した後も残す本数 | `hls_delete_threshold` | **無い** |

`hls_delete_threshold` に残ったセグメントは**プレイリストに現れません**。
だから遅延には 1ms も影響せず、出遅れたクライアントを救うためだけに存在します。
これが MediaMTX から ffmpeg に載せ替えた唯一にして最大の理由です。

現在の既定値は `窓 8 秒 / 猶予 60 秒`。遅延は旧構成と同じまま、
安全余裕だけが約 10 倍になっています。

### 遅延は既に下限

```
OBS のエンコードと送出           0.3〜0.8s
セグメント1本の完成待ち          最大 1.0s
nginx + Cloudflare Tunnel        0.05〜0.2s
プレイヤーのライブエッジ戻し     3.0s   ← 3 × EXT-X-TARGETDURATION
                                ─────────
                                 約 4〜5s
```

`EXT-X-TARGETDURATION` は仕様上**整数秒**なので、1 秒セグメントで
ライブエッジ戻しは 3 秒。これ以上は縮みません。
残る削りどころは OBS 側だけです（`tune=zerolatency`、NVENC なら P1〜P3 と
Look-ahead オフ、あと「配信の遅延」が有効になっていないか）。

ただし**削る前に測ることを勧めます。** 上の数字はプレイヤーが RFC どおりに
振る舞う前提の計算値で、AVPro が実際にどれだけ積むかは測らないと分かりません。
OBS のシーンにミリ秒表示の時計を出し、PC と Quest で同時再生して、
両方の画面を1枚の写真に収める。これで**両者のズレ**も同時に取れます。
同時視聴が目的である以上、絶対遅延よりそちらのほうが重要です。

### なぜ MediaMTX を残しているのか

ffmpeg 単体でも `-listen 1` で RTMP を直接受けられますが、接続を 1 本しか
張れません。このスタックは**配信開始前に ffprobe で入力を検査**しており、
それには接続が 2 本必要です。OBS の再接続処理が堅いのも MediaMTX の利点です。

---

## 動いているか見る

```bash
docker logs -f vrc-transcoder
```

正常時はこう出ます。

```
mode=copy segment=1s window=8s grace=60s latency~5s
--- publisher detected (run=20260814034640) ---
input: h264 Main 1280x720 30fps yuv420p / aac 48000Hz 2ch
keyframe interval: 約 1.0s
starting ffmpeg
```

配信開始のたびにコーデック・プロファイル・pix_fmt・解像度・音声・
キーフレーム間隔を自動検査します。問題があれば `!!` の行で出ます。

```
!! キーフレーム間隔 2.0s が SEG_SECONDS=1s と一致していません
!!   OBS の「キーフレーム間隔」を 1 秒にしてください
!!   このままだと遅延が約 8s になります
```

「サーバは正常に見えるのに VRChat だけ再生できない」という状態には
ならないようにしてあります。

そのほかの確認:

```bash
curl -s http://127.0.0.1/live/index.m3u8
```

```bash
curl -s http://127.0.0.1:8081/live/ | grep -c '\.ts'
```

2つ目は猶予セグメントの本数です。プレイリストには載らないので `m3u8` を
見ても分かりません。既定値なら 60 本前後まで増えます。

---

## 直らないときの順番

**1. LAN 直で見る。** VRChat の URL をこれに変える（Quest も同じ LAN なら可）。

```
http://<ホストIP>/live/index.m3u8
```

ポートもパスも本番と同じなので、変わるのは経路だけです。
安定するなら Cloudflare 経路の問題。失敗するならサーバか OBS 側。

**2. PC だけ / Quest だけで試す。** 片方だけ落ちるならデコーダ側です。
上の `input:` ログの解像度と fps を疑ってください。

**3. `MODE=transcode` にする。** OBS の出力を無視して 720p30 / 3.5Mbps /
main / B フレーム無し に強制変換します。**これで直れば原因は OBS 側**、
直らなければサーバか経路側。一発で割れます。

このモードに設定項目は**わざと持たせていません**。既知の正常値であることが
唯一の存在価値なので、可変にすると切り分けの道具として機能しなくなります。
CPU を 1〜2 コア使うので、判定が済んだら `copy` に戻してください。

**4. `SEG_KEEP_EXTRA` を増やす。** 120 でも 300 でも。遅延は増えません。

---

## 触れる設定

Portainer の Environment variables に入れてください。全て既定値があるので、
変えたいものだけで構いません。

| 変数 | 既定 | 意味 |
|---|---|---|
| `MODE` | `copy` | `copy` / `transcode`。3 の切り分け用 |
| `SEG_SECONDS` | `1` | セグメント長。**OBS のキーフレーム間隔と一致必須**。遅延を決める |
| `SEG_LIST_SIZE` | `8` | プレイリストに載せる本数 |
| `SEG_KEEP_EXTRA` | `60` | 外した後も残す本数。**増やしても遅延は増えない** |
| `GOP_CHECK_SECONDS` | `4` | キーフレーム間隔の測定時間。`0` で無効化して配信開始が 4 秒早くなる |

ポートやパスのような**配線は環境変数にしていません**。設定ファイル側にあります。

| 何を | どこに |
|---|---|
| RTMP ポート | `mediamtx.yml` |
| HTTP ポート | `nginx/hls.conf` |
| RTMP / 出力先パス | `transcoder/run.sh` 冒頭 |

一度決めたら動かさないものと、運用中に触るものを混ぜないための切り分けです。

---

## 調べ尽くした行き止まり

同じ検討を繰り返さないための記録です。

**LL-HLS** — AVPro 3 が非対応（2026-08-14 確認）。これで低遅延方向は閉じました。
仮に対応しても、Quest だけ速くなると PC の視聴者と別の瞬間を見ることになります。
ライブ HLS には固定のタイムライン原点がないので、VideoTXL や ProTV のような
同期プレイヤーでも**ライブ配信では視聴者間の同期機構が働きません**。
同時視聴が目的なら、片側だけの低遅延化は逆効果です。

**CMAF / fMP4** — コンテナ形式を変えるだけで遅延は下がりません。
セグメント長もライブエッジ戻しも変わらず、変わるのはオーバーヘッドが
約 2% から 1% 未満になることだけ。init セグメントのぶん起動はむしろ遅くなります。
「CMAF で低遅延」は CMAF chunked transfer + LL-HLS の話で、効いているのは後者です。

**0.5 秒セグメント** — `EXT-X-TARGETDURATION` は切り上げで 1 になるため、
ライブエッジ戻しの 3 秒は変わりません。得られるのは完成待ちの 0.5 秒だけで、
OBS のキーフレーム間隔を 0.5 秒にする必要があり（UI は整数秒のみ）画質も落ちます。

**`#EXT-X-START:TIME-OFFSET`** — ffmpeg の HLS マキサーが出力せず、
Windows 側の Media Foundation は無視します。

**WebRTC** — 1 秒を切れますが、VRChat の映像プレイヤーが再生できません。

---

## 構成ファイル

```
docker-compose.yml   3サービス。全て network_mode: host。ビルドなし
mediamtx.yml         RTMP 受け口だけ。他のサーバは全部 off
nginx/hls.conf       配信 + キャッシュ制御 + デバッグ用の口
transcoder/run.sh    待機 → 検査 → 変換 のループ。イメージにマウントされる
.gitattributes       LF 強制
```

イメージは 3 つとも公開イメージで、バージョンを固定しています。

| | |
|---|---|
| `bluenviron/mediamtx:1.20.0` | RTMP 受け口 |
| `jrottenberg/ffmpeg:8.1.2-ubuntu2404` | `run.sh` の実行環境 |
| `nginx:1.27-alpine` | HLS 配信 |

`run.sh` が使う外部コマンドは `ffmpeg` / `ffprobe` / `find` / `grep` / `date`
だけです。計算はすべてシェルの整数演算で `awk` にも依存しません。
ffmpeg イメージを差し替えたくなったときに壊れにくくするためです。

`depends_on` は意図的に付けていません。transcoder は publisher が来るまで
待ち続け、nginx はファイルが無ければ 404 を返すだけなので、どの順で起動しても、
どれが単独で再起動しても正しい状態に収束します。

`.sh` / `.yml` / `.conf` は **LF 改行必須**です。`.gitattributes` で強制しつつ、
compose の entrypoint で実行前に `tr -d "\r"` を通す保険もかけています。
