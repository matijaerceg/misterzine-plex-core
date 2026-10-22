# Building from source

Everything builds on a Linux PC. Docker is the simplest route: every toolchain below has a
pinned image in the repository, built on first use when `USE_DOCKER=1` is set.

## The core

Requires **Quartus 17.0.2 exactly**. The pinned Docker image `raetro/quartus:mister` is
that version:

```bash
USE_DOCKER=1 ./build_release.sh --compile   # -> releases/H264_<version>_<date>_<time>.rbf
```

`build_release.sh` also runs the build gates (implicit nets, undriven signals, the
decoder-clock timing gate at both corners, the netlist canary) and packs a **compressed**
`.rbf`, which MiSTer's loader requires. Copy it to `_Other/` on the SD card.

Simulation benches run under Icarus Verilog and Verilator: `bench/h264/run_*.sh` (add `--red`
to prove each bench can fail; `bench/h264/README.md` lists them).

## The programs

MisterZine Jellyfin (the app and its player) is built by the MisterZine Jellyfin repository
this fork lives in ([its build guide](https://github.com/matijaerceg/misterzine-jellyfin/blob/main/docs/BUILD.md));
nothing below is part of it. The programs in `clients/` and the client library are ARM programs,
cross-compiled in their own Docker images. Each client's build writes the SD card's layout
to its `build/dist/`: copy its contents to the card's root, and put the core you built in
`_Other/`, where these programs load it from.

```bash
USE_DOCKER=1 hps/build_arm.sh               # the library, h264play, h264stat, cavlc2cabac -> hps/build/arm/
USE_DOCKER=1 clients/moonlight/build.sh     # Scripts/moonlight.sh, moonlight/
USE_DOCKER=1 clients/player/build.sh        # Scripts/h264player.sh, h264player/
USE_DOCKER=1 clients/uvc/build.sh           # Scripts/h264cam.sh, h264cam/
USE_DOCKER=1 clients/jellyfin/build.sh      # Scripts/jellyfin.sh, jellyfin/ (see below)
```

`clients/jellyfin` is the upstream core's cast-only Jellyfin client, kept as source. It is
not part of MisterZine Jellyfin releases, and this manual does not describe it; its own
`clients/jellyfin/README.md` does.

The images build on one another (the compiler, then Moonlight's libraries, then FFmpeg for
the video player, the camera viewer and the Jellyfin cast client): the first build takes a
while.

Each one has a test that runs on the PC against a simulated core (add `--red` to prove it
can fail). They need gcc, python3, ffmpeg, and the development packages of FFmpeg, libcurl,
libopus and libusb; run Moonlight's after its build, which fetches the upstream source it
compiles against:

```bash
make -C hps test
clients/moonlight/tests/run_test.sh
clients/jellyfin/tests/run_test.sh
clients/player/tests/run_test.sh
clients/uvc/tests/run_test.sh
```

## Releases

This core is MisterZine Jellyfin's fork. It is released only inside MisterZine Jellyfin
packages, built by that project's `release/build_package.py` from a `--release` build; see its
`release/DISTRIBUTION.md`.

## The manual

The manual is built with MkDocs (`site/requirements.txt`):
`python3 tools/docs_check.py && mkdocs build --strict`.
