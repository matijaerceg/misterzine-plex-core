# clients/player/ -- a video file player for the MiSTer H264 core

This project's own C (GPL-3.0-or-later, like the repository outside `hps/`).
- It plays video files from the MiSTer's SD card, USB drives and mounted network shares through
  `hps/` (libh264ring).
- The video goes to the core as H.264 access units -- or (0.15) decoded on the ARM and sent as
  pictures, for the older formats; the audio is decoded on the ARM (FFmpeg) to 48 kHz PCM. All
  carry their timestamps.
- Text subtitles are drawn on the overlay.
- A folder browser on the overlay is driven by the pad.

What plays: H.264 up to 720p (the core's decoder; CAVLC rewritten by the library), and MPEG-1/2,
MPEG-4 Part 2, DivX 3, WMV7/8, Theora, MJPEG and H.263 up to 720x576 at 30 frames/s (decoded on the
ARM: `../common/vdec.c`, interface 0.15's PICTURE records). Everything else is refused by name
before it reaches the core. Design and decisions: `docs/player.md`; for
users: `site/content/using/player.md`.

| | |
|---|---|
| `build.sh` | the ARM build in the pinned image (`USE_DOCKER=1`): `build/arm/h264player`, and `build/dist/` as the SD card |
| `Makefile` | `make arm` (inside the image), `make host` (system FFmpeg), `make test` (the host test) |
| `tests/` | the host test, the branch's gate: the player against a fake core and a scripted pad, `run_test.sh [--red]` (`tests/README.md`) |
| `src/` | `browse` (folders, the roots, the order), `main` (the browser, playback, refusals, the refresh rate, subtitles) |
| `mister/h264player.sh` | the Scripts-menu launcher |
| `../common/` | shared with the Jellyfin client: `player` (a file or URL into the ring), `h264check` (what the core would refuse, and the picture bound it does not report), `vdec` (0.15: the other codecs, decoded on the ARM), `core`, `input`, `ui`, `subs`, the build image (`deps3`) |

```bash
USE_DOCKER=1 clients/player/build.sh
# on the MiSTer, bring-up: one file through the same code, no browser
/media/fat/h264player/h264player play /media/fat/video/film.mkv
```

`H264PLAYER_AVLOG=1` turns FFmpeg's log up to info, for diagnostics.
