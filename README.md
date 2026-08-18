# VRChat HLS streaming stack

A self-hosted streaming server that gets video from your home into VRChat, with PC and
Quest watching at the same time. Deployable as-is as a Portainer Git stack.

Stream keys are not fixed — they are *rooms*. Any key you invent in OBS runs as its own
independent stream, several can run in parallel, and a second publisher on the same key
is rejected.

日本語版: [README.ja.md](README.ja.md)

## How it fits together

VRChat's video player takes exactly one URL, and it has to be **HLS**. OBS speaks RTMP.
This server is the translator between the two.

```
OBS ─RTMP:1935→ mediamtx(+ffmpeg) ─HLS→ tmpfs ←─ nginx:80
                                                     ↑
                                 existing cloudflared ┘
```

`cloudflared` is assumed to already exist and is **not** part of this repository. What
this repo manages is the two containers, `mediamtx` and `nginx`, and nothing else.

`mediamtx` receives RTMP and tracks which keys are currently publishing. The moment a
key goes live it starts one `ffmpeg` dedicated to that key, which slices the stream into
HLS segments on a shared tmpfs; `nginx` serves that directory over HTTP. Segments are
cached hard, playlists are never cached.

A full walkthrough, and the reasoning behind each choice, is in
[docs/DESIGN.ja.md](docs/DESIGN.ja.md).

## Running it

**Stop the old stack first.** `network_mode: host` means startup fails if anything else
is holding `:80` or `:1935`.

Deploy `docker-compose.yml` as a Portainer Git stack. Configuration is by environment
variable (`MODE`, `SEG_SECONDS`, `SEG_KEEP_EXTRA` and friends).

In OBS, use CBR at 3500-6000 kbps with a 1-second keyframe interval, and pick any stream
key you like (6-32 characters, alphanumeric plus hyphen and underscore). Codec settings
are validated automatically.

In VRChat, paste `https://<your-host>/<stream-key>/index.m3u8` into the world's video
URL field. The same URL works on PC and on Quest.

Step-by-step instructions are in [README.ja.md](README.ja.md) (Japanese).

## Latency

Roughly 4-5 seconds end to end. That is inherent to HLS, which works by writing whole
segment files and advertising them in a playlist — the reasoning, and why WebRTC is not
an option here, is in [docs/DESIGN.ja.md](docs/DESIGN.ja.md) and
[docs/DEAD-ENDS.ja.md](docs/DEAD-ENDS.ja.md).

## Documentation

| | |
|---|---|
| [docs/DESIGN.ja.md](docs/DESIGN.ja.md) | How each component works, why mediamtx and nginx are the only two containers, why latency and stability are separate axes, glossary |
| [docs/OPERATIONS.ja.md](docs/OPERATIONS.ja.md) | Health checks, and what to look at first when it breaks |
| [docs/CONFIGURATION.ja.md](docs/CONFIGURATION.ja.md) | Tunables, editing pitfalls, file layout |
| [docs/DEAD-ENDS.ja.md](docs/DEAD-ENDS.ja.md) | Options that were investigated and rejected, with reasons |
| [CHANGELOG.md](CHANGELOG.md) | Changes to `docker-compose.yml`, with the "why" |

Detailed documentation is Japanese-only for now.
