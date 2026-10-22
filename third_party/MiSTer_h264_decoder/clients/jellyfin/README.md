# clients/jellyfin/ -- a Jellyfin client for the MiSTer H264 core

This project's own C (GPL-3.0-or-later, like the repository outside `hps/`): a Jellyfin server's
items, direct-played when a file fits the core or transcoded by the server when it does not, go
to the core through `hps/` (libh264ring) -- the video as H.264 access units, the audio decoded on
the ARM (FFmpeg) to 48 kHz PCM, both with their timestamps. v1 is a cast target: pick an item in
any Jellyfin app and play it on the MiSTer. Design, decisions and measurements:
`docs/jellyfin.md`.

| | |
|---|---|
| `build.sh` | the ARM build in the pinned image (`USE_DOCKER=1`): `build/arm/jellyfin`, and `build/dist/` as the SD card |
| `Makefile` | `make arm` (inside the image), `make host` (system FFmpeg / curl), `make test` (the host test) |
| `tests/` | the host test, the branch's gate: the client against a fake core and a scripted fake server, `run_test.sh [--red]` (`tests/README.md`) |
| `src/` | `jf` (the server's API, the socket), `profile` (the device profile), `main` |
| `../common/` | shared with the file player (`docs/player.md` P1): `player` (a URL into the ring), `h264check` (what the server cannot see: CAVLC, MBAFF, the size), `core` (the core held: session, heartbeat), `input`, `ui`, `subs`, stb_truetype, and `docker/` -- the build image: Moonlight's (OpenSSL 3, curl) + FFmpeg 8.0.3, the CA bundle, the DejaVu typeface |
| `third_party/` | cJSON (vendored, `third_party/README.md`) |

```bash
USE_DOCKER=1 clients/jellyfin/build.sh
# on the MiSTer, bring-up: one URL straight into the core
/media/fat/jellyfin/jellyfin play 'https://<server>/Videos/<id>/stream?static=true&ApiKey=<token>' --start 300
```

`JELLYFIN_AVLOG=info|debug` turns FFmpeg's log up for diagnostics; it prints URLs, and a
transcode's URLs carry the access token -- never leave it on in a log you share.
