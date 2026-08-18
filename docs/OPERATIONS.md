# 運用とトラブルシュート

[← README に戻る](../README.md)

---

## 動いているか見る

```bash
docker logs -f vrc-mediamtx
```

MediaMTX 自身の接続ログと、キーごとの検査ログが混ざって出ます。
各行の2番目の `[ ]` がどのキーのログかを示します。正常時はこう出ます。

```
[04:31:40] [my-room-key] publisher available mode=copy segment=1s window=8s grace=60s latency~5s
[04:31:40] [my-room-key] input: h264 Main 1280x720 30fps yuv420p / aac 48000Hz 2ch
[04:31:44] [my-room-key] keyframe interval: 約 1.0s
[04:31:44] [my-room-key] starting ffmpeg (run=20260814043144)
```

配信開始のたびにコーデック・プロファイル・pix_fmt・解像度・音声・
キーフレーム間隔を自動検査します。問題があれば `!!` の行で出ます。

```
[04:31:44] [my-room-key] !! キーフレーム間隔 2.0s が SEG_SECONDS=1s と一致していません
[04:31:44] [my-room-key] !!   OBS の「キーフレーム間隔」を 1 秒にしてください
[04:31:44] [my-room-key] !!   このままだと遅延が約 8s になります
```

「サーバは正常に見えるのに VRChat だけ再生できない」という状態には
ならないようにしてあります。

そのほかの確認:

```bash
curl -s http://127.0.0.1/<キー>/index.m3u8
```

```bash
curl -s http://127.0.0.1:8081/<キー>/ | grep -c '\.ts'
```

2つ目は猶予セグメントの本数です。プレイリストには載らないので `m3u8` を
見ても分かりません。既定値なら 60 本前後まで増えます。

```bash
curl -s http://127.0.0.1:8081/
```

これは今アクティブなキーの一覧です（autoindex）。ホスト内からのみ
到達可能で、トンネルには載っていません。

---

## 直らないときの順番

**1. LAN 直で見る。** VRChat の URL をこれに変える（Quest も同じ LAN なら可）。

```
http://<ホストIP>/<配信キー>/index.m3u8
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

### 手順1で「Cloudflare 経路の問題」と分かった場合

**症状が「視聴開始直後だけ取得エラー、LAN直結では出ない」なら、
このスタックではなく Cloudflare 側の設定が原因である可能性が高いです。**
このリポジトリのファイルからは cloudflared/Cloudflare の設定を直接
変更できないので（既存のトンネルをそのまま使う設計のため）、
Cloudflare ダッシュボードで以下を確認してください。

1. **Caching → Cache Rules / Page Rules。** このホスト名・パスに対して
   オリジンのキャッシュヘッダを上書きするルールが無いか確認してください。
   `*.m3u8` は明示的に **Bypass cache** にするのが確実です。
   nginx 側は `Cache-Control: no-store, s-maxage=0, stale-if-error=0` を
   既に付けていますが（このリポジトリで対応済み）、固定 TTL の
   Cache Rule があるとオリジンのヘッダより優先されることがあります。
2. **Caching → Configuration → Always Online。** 有効だと、オリジンに
   一瞬でも到達できなかった時にキャッシュ済みの古い応答を返すことが
   あります。古いプレイリストを掴むと中のセグメントが全部消えている
   ため、視聴開始直後に即エラーになる症状と一致します。
3. **Security → Bot Fight Mode / WAF。** VRChat の動画プレイヤーは
   ブラウザではないので、Bot 判定に引っかかると素の動画の代わりに
   チャレンジページ（HTML）が返り、プレイヤー側は再生できず
   エラーになります。このホスト名だけ Bot Fight Mode を切るか、
   `/*.m3u8` `/*.ts` を対象に WAF の Skip ルールを追加してください。
4. **Tunnel の種類。** `cloudflared tunnel --url ...` のような
   使い捨ての Quick Tunnel だと、接続が不安定になりやすいです。
   ゾーンに紐付いた名前付き Tunnel を使っているか確認してください。
5. 上記で直らない/切り分けたいときは、`cloudflared` 側のログ
   （コネクタの再接続・タイムアウトが無いか）と、一時的に nginx の
   `access_log` を有効にして（`configs.nginx_conf` の `access_log off;`
   を `access_log /dev/stdout;` に変更）失敗した瞬間に該当リクエストが
   origin まで届いていたかを突き合わせてください。届いていなければ
   Cloudflare より手前で止まっている証拠です。

---
