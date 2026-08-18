# VRC-Streaming

自分の映像を VRChat の中で流すためのサーバです。PC の人も Quest の人も、同じものを
同時に見られます。

VRChat のワールドにある動画プレイヤーは、URL を渡せば映像を再生してくれます。ただし
受け付ける形式が決まっていて、配信によく使われる OBS が出す形式とは別物です。
**この2つの間に立って形式を変換するのが、このサーバの役目**です。

配信には自分で決めた名前を付けます。その名前がそのまま「部屋」になります。別々の名前を
使えば何人でも同時に配信でき、あなたが配信している間は同じ名前を横取りされません。

English: [README.md](README.md)

## できること

- 自宅から VRChat へ映像を配信する（PC / Quest 同時視聴）
- 好きな名前を付けた「部屋」を複数、並行して配信する
- 同じ名前への二重配信を自動で拒否する
- 遅延はおおよそ 4〜5 秒

## 仕組み

```
OBS ─RTMP:1935→ mediamtx(+ffmpeg) ─HLS→ tmpfs ←─ nginx:80
                                                     ↑
                                 既存の cloudflared ─┘
```

登場するのは2つのコンテナだけです。`mediamtx` が OBS からの映像を受け取って変換し、
`nginx` がそれを配ります。外部からアクセスするための `cloudflared` は、既にあるものを
そのまま使う前提で、このリポジトリには含みません。

もう少し詳しい説明は [docs/DESIGN.ja.md](docs/DESIGN.ja.md) にあります。

## 動かす

1. **旧スタックを止める。** `:80` と `:1935` が空いている必要があります。
2. **Portainer → Stacks → Add stack** で、このリポジトリの `docker-compose.yml` を
   指定する。環境変数の設定は不要です。
   （Docker Compose `v2.23.1` 以上が必要）
3. **OBS を設定する。** CBR・3500〜6000 kbps・キーフレーム間隔 1 秒。配信キーは
   好きな文字列（半角英数字・ハイフン・アンダースコア、6〜32文字）。
4. **VRChat のワールドの動画URL欄**に `https://<ホスト>/<配信キー>/index.m3u8`
   を貼る。

つまずいたとき、設定値の意味を知りたいときは
[docs/SETUP.ja.md](docs/SETUP.ja.md) を見てください。

## ドキュメント

| | |
|---|---|
| [docs/SETUP.ja.md](docs/SETUP.ja.md) | 導入手順の詳細。OBSの設定値、配信キーの規則、つまずきやすい点 |
| [docs/DESIGN.ja.md](docs/DESIGN.ja.md) | なぜこの構成なのか。各部品の役割、遅延と安定性の関係、用語集 |
| [docs/OPERATIONS.ja.md](docs/OPERATIONS.ja.md) | 動作確認、直らないときに何から見るか |
| [docs/CONFIGURATION.ja.md](docs/CONFIGURATION.ja.md) | 変更できる設定の一覧と注意点 |
| [docs/DEAD-ENDS.ja.md](docs/DEAD-ENDS.ja.md) | 検討して採用しなかった案とその理由 |
| [CHANGELOG.md](CHANGELOG.md) | 変更履歴 |
