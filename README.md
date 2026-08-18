# VRC-Streaming

A server that lets you play your own video inside VRChat, with people on PC and on Quest
seeing the same thing at the same time.

Video players in VRChat worlds will play from a URL, but only in one particular format —
and OBS, the tool most people stream with, produces a different one. **This server sits
between the two and translates.**

You pick a name for each stream, and that name is the room. Use different names and any
number of streams run side by side; while you are live, nobody else can take your name.

日本語版: [README.ja.md](README.ja.md)

## What it does

- Streams video from home into VRChat, watchable on PC and Quest at once
- Runs multiple named "rooms" in parallel
- Rejects a second publisher on a name already in use
- End-to-end latency of roughly 4-5 seconds

## How it works

```
OBS ─RTMP:1935→ mediamtx(+ffmpeg) ─HLS→ tmpfs ←─ nginx:80
                                                     ↑
                                 既存の cloudflared ─┘
```

There are only two containers. `mediamtx` takes the video OBS sends and converts it;
`nginx` serves the result. `cloudflared`, which makes it reachable from outside your
network, is assumed to already exist and is not part of this repository.

A fuller explanation is in [docs/DESIGN.ja.md](docs/DESIGN.ja.md) (Japanese).

## Getting it running

1. **Stop the old stack.** Ports `:80` and `:1935` have to be free.
2. **Portainer → Stacks → Add stack**, pointing at this repository's
   `docker-compose.yml`. No environment variables needed.
   (Docker Compose `v2.23.1` or newer is required.)
3. **Configure OBS**: CBR, 3500-6000 kbps, 1-second keyframe interval. The stream key is
   any string you like — 6-32 characters, alphanumerics plus hyphen and underscore.
4. **Paste `https://<host>/<stream-key>/index.m3u8`** into the video URL field of the
   VRChat world.

If something does not work, or you want to know what the values mean, see
[docs/SETUP.ja.md](docs/SETUP.ja.md).

## Documentation

| | |
|---|---|
| [docs/SETUP.ja.md](docs/SETUP.ja.md) | Full setup walkthrough: OBS values, stream-key rules, common snags |
| [docs/DESIGN.ja.md](docs/DESIGN.ja.md) | Why it is built this way, what each part does, glossary |
| [docs/OPERATIONS.ja.md](docs/OPERATIONS.ja.md) | Health checks, and what to look at first when it breaks |
| [docs/CONFIGURATION.ja.md](docs/CONFIGURATION.ja.md) | Tunables and their pitfalls |
| [docs/DEAD-ENDS.ja.md](docs/DEAD-ENDS.ja.md) | Options investigated and rejected, with reasons |
| [CHANGELOG.md](CHANGELOG.md) | Change history |

Detailed documentation is Japanese-only for now.
