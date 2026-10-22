# clients/moonlight/ -- a Moonlight client for the MiSTer H264 core

[moonlight-embedded](https://github.com/moonlight-stream/moonlight-embedded) (GPL-3.0) with a
`mister` platform: the host's H.264 stream and its audio (Opus, decoded on the ARM) go to the
core through `hps/` (libh264ring), and the controls go back to the host. GPL-3.0-or-later,
like the rest of the repository outside `hps/` (`NOTICE`).

| | |
|---|---|
| `build.sh` | fetches upstream at the pinned commit, applies `patches/`, adds `src/mister/`, cross-builds a static binary into `build/` |
| `patches/` | the changes to upstream (`git format-patch` from the pin): a static build without avahi / libuuid / libudev; the `mister` platform; `-platform fake` writing the video to `$MOONLIGHT_DUMP`; the automatic size (the MiSTer screen's shape). `0004` input through the core (Main holds the input devices: `src/mister/mister_input.c` reads the core's input region, interface 0.6; `docs/moonlight.md` M5, §7) |
| `src/mister/` | the platform: video, audio, the session, the core's error counters |
| `mister/moonlight.sh` | the launcher, installed as `Scripts/moonlight.sh` (`build/dist/` is the SD card's layout) |
| `tests/` | the backend against a fake core on the host: `tests/run_test.sh [--red]` (after one `build.sh`, for the upstream headers) |
| `docker/` | the build image: `hps/docker`'s toolchain + the dependencies cross-built static (OpenSSL 3, curl, expat, opus, libevdev; pinned by sha256) |

```bash
USE_DOCKER=1 clients/moonlight/build.sh     # -> build/moonlight (static ARM), build/gamecontrollerdb.txt
```

Run by hand (not through the launcher), pass `-bitrate`: with `-width 0 -height 0` (the
automatic size) upstream derives its default bitrate from the 0x0 it was given (2,000 kbit/s).

The design, its decisions and its gates: `docs/moonlight.md`. Editing a patch: apply the
series to a checkout of the pin, commit on top, and re-export with
`git format-patch --no-signature --zero-commit -o patches <pin>` under a generic author
(the patches are published).
