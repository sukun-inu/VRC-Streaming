# 設定リファレンス

[← README.ja.md に戻る](../README.ja.md)

---

## 触れる設定

Portainer の Environment variables に入れてください。全て既定値があるので、
変えたいものだけで構いません。

| 変数 | 既定 | 意味 |
|---|---|---|
| `MODE` | `copy` | `copy` / `transcode`。上の切り分け用 |
| `SEG_SECONDS` | `1` | セグメント長。**OBS のキーフレーム間隔と一致必須**。遅延を決める |
| `SEG_LIST_SIZE` | `8` | プレイリストに載せる本数（＝窓の大きさ）。プレイヤーが仕様どおりならレイテンシに影響しないはずだが、実測でズレが出た場合はここを疑う（下記変更履歴の実測結果を参照） |
| `SEG_KEEP_EXTRA` | `60` | 外した後も残す本数。**増やしても遅延は増えない** |
| `GOP_CHECK_SECONDS` | `4` | キーフレーム間隔の測定時間。`0` で無効化して配信開始が 4 秒早くなる |

ポートや配信キーの形式のような**配線は環境変数にしていません**。`configs` の中にあります。

| 何を | どこに |
|---|---|
| RTMP ポート | `configs.mediamtx_yml` の `rtmpAddress` |
| HTTP ポート | `configs.nginx_conf` の `listen` |
| 配信キーの文字種・長さ | `configs.mediamtx_yml` の `paths` 直下の正規表現（既定 `~^[A-Za-z0-9_-]{6,32}$`） |
| RTMP / 出力先パスの組み立て方 | `configs.on_available_sh` 冒頭の `SRC` / `OUT_DIR`（`$MTX_PATH` = 配信キーから自動生成） |

一度決めたら動かさないものと、運用中に触るものを混ぜないための切り分けです。

---

## 設定を変更するときの注意

このスタックは `docker-compose.yml` 1枚に全設定を埋め込む方式です。編集するときに
踏みやすい罠が3つあります。実際にこのプロジェクトで一度ずつ事故を起こしたものです。

### 1. シェルの `$` は必ず `$$` と2個重ねる

`content:` の中身は Compose の変数展開を通ります。1個だけだと空文字に置換されて
壊れます。

```sh
FPS=$$(( (RNUM + RDEN / 2) / RDEN ))    # 正しい
FPS=$(( (RNUM + RDEN / 2) / RDEN ))     # 壊れる（空文字に置換される）
```

`configs.nginx_conf` の正規表現アンカー（`\.m3u8$$` など）も同じです。
埋め込み時に機械的に変換してあるので、既存の記述はすべて `$$` になっています。

### 2. `content` を変更したら config の名前を今日の日付に変える

**編集したのに動作が変わらない場合、まずこれを疑ってください。**
Docker Compose には既知の制限があり（[docker/compose#13045](https://github.com/docker/compose/issues/13045)）、
config の**名前**を変えずに `content` だけ変更して `docker compose up -d`
（Portainer の「Update the stack」も内部的には同じ）を実行しても、
コンテナが再作成されず**古い内容のまま動き続ける**ことがあります。
nginx や mediamtx のログは正常に見えるのに、直したはずの症状が
再現し続ける場合はほぼこれです。

このリポジトリでは各 config の名前の末尾に `_20260814` のような
更新日を付けています。**`content` を変更したら、この日付を今日の日付に
書き換えて（`nginx_conf_20260814` → `nginx_conf_20260901` など）、
`services.*.configs` 側の `source:` も同じ名前に揃えてください。**
名前ごと変われば Compose は確実に「別の config」と認識するので、
確実にコンテナが作り直されます。番号を数える方式と違って「今何番か」を
確認する必要がなく、名前を見るだけでいつ触ったかも分かります。
同じ日に2回編集した場合は `nginx_conf_20260814b` のように英字を
足して区別してください。

日付を更新し忘れた/どうしても名前を変えたくない場合は、代わりに
`docker compose up -d --force-recreate` で強制的に全コンテナを
作り直してください。

### 3. nginx の正規表現で `{n,m}` を使うときは必ずクォートする

`location ~ ^/xxx{6,32}$ { ... }` のようにクォートせず書くと、nginx の設定
パーサーが `{` を（量指定子ではなく）ブロック開始として誤解釈し、
`pcre2_compile() failed: missing closing parenthesis` で**設定ファイル
全体が読み込めずコンテナが起動しなくなります。**

```nginx
location ~ "^/([A-Za-z0-9_-]{6,32})$" { ... }   # 正しい（クォートする）
location ~ ^/([A-Za-z0-9_-]{6,32})$ { ... }     # 壊れる（起動しない）
```

正規表現に `}` や `;` を含む場合は、ダブルクォートかシングルクォートで
式全体を必ず囲んでください。

---

---

## 構成ファイル

```
docker-compose.yml   これ1枚で完結
README.md            この文書
.gitattributes       LF 強制
```

`docker-compose.yml` の中身は 2 段になっています。

```
configs:
  mediamtx_yml     RTMP 受け口 + 配信キーごとの runOnAvailable フック
  nginx_conf       配信 + キャッシュ制御 + デバッグ用の口
  landing_html     配信キーから再生URLを組み立てる案内ページ (/)
  clock_html       遅延測定用のミリ秒時計 (/clock)。OBSのブラウザソース用
  on_available_sh  1配信キー分の 検査 → 変換 (runOnAvailable から起動)
services:
  mediamtx / nginx   全て network_mode: host。ビルドなし
```

イメージは 2 つとも公開イメージで、バージョンを固定しています。

| | |
|---|---|
| `bluenviron/mediamtx:1.20.0-ffmpeg` | RTMP 受け口 + `on_available.sh` の実行環境（Alpine + ffmpeg 同梱） |
| `nginx:1.27-alpine` | HLS 配信 |

`on_available.sh` が使う外部コマンドは `ffmpeg` / `ffprobe` / `find` /
`grep` / `date` だけです。計算はすべてシェルの整数演算で `awk` にも
依存しません。ベースイメージが Alpine の busybox シェルでも POSIX の
範囲だけで動くよう、この制約はそのまま引き継いでいます。

`depends_on` は意図的に付けていません。mediamtx は配信キーが来るまで
待ち続け（正確には MediaMTX 自身が publisher を待つので、こちらから
待つ処理すらありません）、nginx はファイルが無ければ 404 を返すだけなので、
どの順で起動しても、どれが単独で再起動しても正しい状態に収束します。

`docker-compose.yml` は **LF 改行必須**です（`.gitattributes` で強制）。
ブロックスカラーの改行は YAML パーサが正規化するので CRLF でチェックアウト
されても実害は出ませんが、揃えておくに越したことはありません。

`mediamtx.yml` の `runOnAvailable: /bin/sh /opt/on_available.sh` は
argv 直渡し相当の2トークンです。`sh -c "..."` のような文字列を渡す形は
使いません。以前の構成でこの形をとったとき、YAML の引用符・シェルの
引用符・Compose の変数展開が三重にかかって事故を起こしたことがあります
（`tr -d "\r"` の `\r` が実 CR 化 → YAML が改行をスペースに畳む →
`tr -d " "` になってスクリプトから全スペースが消える）。
渡すものが増えるほど壊れるので、単純な形のまま渡すのが確実です。
