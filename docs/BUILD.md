# Build from source

MisterZine Plex Core plays video through this project's fork of the H.264 FPGA
decoder in `third_party/MiSTer_h264_decoder`. The Go app and C playback worker
build on Linux (or WSL) for MiSTer's ARMv7 processor; the core builds with
Quartus 17.0.2, most easily in its pinned Docker image.

## Dependencies and playback worker

Install the prerequisites described in [the toolchain guide](../toolchain/README.md).
From the repository root, build the HPS ring library, FFmpeg/OpenSSL libraries,
and the worker:

```sh
bash toolchain/build_hps.sh
bash toolchain/build_ffmpeg.sh
make -C arm jfplay
python3 arm/test_jfplay_contract.py
```

The outputs are `arm/jfplay`, `build/arm/ffmpeg`, and the HPS tools and libraries
under `build/arm/`. The worker is statically linked against the libraries built
by these scripts; the static `ffmpeg` plays theme music. A prefix built in
another checkout can be reused with `make -C arm jfplay PREFIX=<dir>`. Consult
the [component notices](../release/THIRD_PARTY_NOTICES.md) before distributing
binaries.

Saved video geometry is sent only to a core advertising HPS interface 1.2 or
later. The core shipped with the app (interface 1.4) applies saved geometry;
older H.264 cores keep calibration preview-only. The app's 14:9 crop uses the
same geometry interface. On older cores it falls back to Off, while the core
receives its valid Letterbox setting.

The core OSD's **Output Mode**, **Refresh Rate Match**, **Display Shape**,
**De-flicker**, **240p Playback**, and **Play 24fps at 25fps** controls use
HPS interface 1.3. Interface 1.4 exposes the selected refresh-match mode in
status word 87 bits 16–17; supported choices are Off and 50/60. Interface 1.3
uses its existing Off and 50/60 status bit. Ordinary playback remains
available with older cores.

The display options live in the core OSD, not the app. Output Mode selects
480i60, 480p60, 576i50, 576p50, or Native HDMI. Display Shape (4:3 or 16:9)
shapes every fitted raster and the aspect HDMI is told; in Native HDMI a
playing video takes the HDMI mode's own shape. Refresh Rate Match offers Off
and 50/60. Matching can switch the refresh family while a picture plays, then
restore the selected Output Mode when playback ends. Native HDMI and the
progressive Output Mode choices remain selectable. 240p Playback otherwise
changes playback on the interlaced profiles to progressive 240p or 288p; menus
and idle screens keep their normal mode.

Film Speed can speed eligible 23.976/24 fps video to 25 fps only on fixed-50-Hz
576i/576p profiles when refresh matching is Off. It shortens runtime and raises
audio pitch because pitch preservation is not implemented; a 25 fps source is
never sped up again. Exact 24/30/60 fps sources are slowed by 1000/1001 when
the output uses the NTSC family: on fitted 480-line profiles, or when refresh
matching selects NTSC rates. Audio is resampled with the same clock conversion.
Fractional NTSC sources are unchanged, and Native HDMI does not receive the
fitted 480-line slowdown. The worker selects its clock when it opens a stream,
based on the core setting, refresh mode, output family, and source frame rate.
Stop and restart playback after changing a setting that changes the playback
clock. Progress and seek targets remain in source seconds.

240p and 288p use constant line lengths, at approximately 59.914 and 49.993 Hz.
Their scheduling grid follows those actual frame periods. The small difference
from nominal cadence can still require occasional frame corrections; these
modes do not use a variable-line-length approximation of exact refresh.

## Application

With Go 1.27, from the repository root:

```sh
cd app
GOOS=linux GOARCH=arm GOARM=7 CGO_ENABLED=0 go build -trimpath -o dist/plexcrt ./cmd/plexcrt
cd ..
```

The executable retains its historical `plexcrt` name. It runs on MiSTer Linux;
it is not a desktop media player. Unit tests can run on a Linux desktop.
Normal source builds are unlocked. The app's version is shown with `-version`.

The font atlases in `app/internal/gfx/fonts` are committed and embedded in the
build. `app/tools/genatlas.ps1` generates them on Windows from the installed
Roboto, Roboto Medium, Roboto Black and Roboto Condensed fonts
(`powershell -File app\tools\genatlas.ps1`); run it only to change a face or
size, and keep every atlas the app loads by name.

For a build with an explicit release channel, version and ID, as a package
needs, use `release/beta_release.py`. It writes `app/dist/plexcrt` and the
build stamp `app/dist/plexcrt.build.json` that the packager checks:

```sh
python3 release/beta_release.py build --channel public --version 0.1.0 --id local-public
```

Beta builds and their access batches are described in
[beta releases](BETA_RELEASES.md).

### Supporter extras

The official app is this source plus the supporter extras, which live in a
private repository as an overlay of extra files at the same paths. The overlay
only adds files; every Go file in it is limited to the `premium` build tag, so
this repository builds the complete public app on its own and a public change is
never shadowed by a private copy. Each extra is a `Feature` in
`app/internal/access`: its Options row shows to everyone and is greyed with
"Unlock forever" until a MisterZine code covering it has been entered (saved for
good under `unlocks/` beside the settings; the beta's own receipt counts).
Beta features show only with Options > Show beta features on, their rows
marked BETA after the star. The public build has no code registry, so no code
unlocks anything in it.

The hooks the extras plug into are in `app/internal/ui/premium.go`; the public
build's stubs, behind `//go:build !premium`, are in `premium_free.go`. To add
an extra, land the smallest hook it needs here first, then the extra in the
private repository. `release/beta_release.py build --tags premium` builds with
the overlay in place. See [public source and supporter builds](SUPPORTER_BUILDS.md).

## FPGA core

The app's core is `PlexH264.rbf`, built from `third_party/MiSTer_h264_decoder`.
Its label, `CORE_VERSION` in `h264/emu.sv`, is `plex-` plus the app version it
first ships in (for example `plex-0.1.0-beta.28`; at most 18 characters,
which `build_release.sh` checks). A later app-only release keeps the core and
its label. Commit the label, copy the core directory to a local
disk outside any synced folder, and build from that clean commit:

```sh
cd third_party/MiSTer_h264_decoder
USE_DOCKER=1 ./build_release.sh --compile --release
```

A build takes about half an hour. It writes
`releases/PlexH264_plex-<version>_<date>_<time>.rbf` and its `.rbf.json`
provenance manifest. `--release` refuses a marginal or failed fit. Keep the
file and its manifest together and unchanged: the packager checks that the
manifest names that file, records a timing pass and a clean tree, and carries a
`plex-` label. The core's own build notes are in
`site/content/about/building.md`. The same source also builds the Jellyfin
app's core under another name and label; the two are separate files.

Checks that need no Quartus:

```sh
python3 third_party/MiSTer_h264_decoder/tools/check_emu_wiring.py
bash third_party/MiSTer_h264_decoder/tools/tests/run_tests.sh
```

## Package

A release package holds `plexcrt`, `jfplay`, `ffmpeg` and `PlexH264.rbf`,
with the corresponding source published beside it:

```sh
python3 release/build_source.py --out "$SOURCE" --core-tree "$CORE_SNAPSHOT" \
    --dependencies "$DEPENDENCY_SOURCES" --rbf-manifest "$RBF.json"
python3 release/build_package.py --id local-public --version 0.1.0 \
    --worker arm/jfplay --ffmpeg build/arm/ffmpeg --rbf "$RBF" --source-archive "$SOURCE"
```

`$RBF` is the qualified core and `$CORE_SNAPSHOT` the core directory it was
built in; `$DEPENDENCY_SOURCES` is the `dependency-sources.zip` of FFmpeg,
OpenSSL and toolchain sources. `build_package.py` writes
`MisterZine-Plex-Core-<id>.zip`, its `.sha256` and the source archive as
`MisterZine-Plex-Core-Source-<id>.zip` under `release/dist` (or `--out`).
Publishing is described in [distribution](../release/DISTRIBUTION.md).

## Development install

Use a separate directory on the MiSTer's SD card. Copy `plexcrt`, `jfplay`, and
`ffmpeg` into it and make them executable. `ffmpeg` decodes show theme music, so
the preflight requires it alongside the app.

Copy a core built as above to the SD card's `_Other` folder as
`PlexH264.rbf`. See its [launch instructions](../third_party/MiSTer_h264_decoder/site/content/integrating/launch.md).
By default the app loads the `_Other/PlexH264` core through an MGL. An optional
`MISTERZINE_H264_RBF` override is an MGL core name such as `_Other/PlexH264`,
relative to the SD root and without the `.rbf` extension.

Run `./plexcrt -check` on the device to check the application files, then
`./plexcrt` to load the core and link the device with plex.tv on screen.
Configuration and cached artwork are stored alongside the executable. Keep
account files private.

Switching to another core stops the app and playback worker. Their shared-memory
mappings outlive FPGA reconfiguration, so they check MiSTer's core name and the
raster heartbeat before writing. After ownership is lost, shutdown releases
process resources without resetting the decoder or repainting the framebuffer.
These checks reduce the changeover window; they are not an atomic handoff with
MiSTer Main. Test switches from both browsing and active or paused playback,
and verify that neither process remains in the next core.

## Validation

See [Contributing](../CONTRIBUTING.md) for the Linux unit tests, ARM build checks,
and public-content scan. Playback changes also need real hardware tests covering
both direct streams and transcodes, pause/resume, repeated seeks, stop, saved
resume position, and the absence of leftover player processes.

The worker's C helpers, the pure-C video geometry helper among them, are
tested on a native Linux or WSL host without the ARM toolchain or device:

```sh
make -C arm test
```

The geometry test reads the shared expected rectangles in
`tools/testdata/fit_cases.txt` and checks NTSC/PAL alignment, crop and fit
behavior, and invalid inputs.
