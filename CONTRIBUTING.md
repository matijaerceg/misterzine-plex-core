# Contributing

Start with [help and bug reports](release/README.md). See
[Build from source](docs/BUILD.md) for the application, worker and core.
Maintainers can follow [beta release preparation](docs/BETA_RELEASES.md),
[distribution](release/DISTRIBUTION.md) and the
[release hardware check](docs/HARDWARE_CHECK.md). Development builds remain
ungated; release builds select their channel explicitly.

Report bugs with the app version, MiSTer hardware, output cable and Output
Mode, local or remote server, direct-stream or transcode mode, and
reproduction steps. Review diagnostics before sharing them; never attach
account files, patron keys or unreviewed card images.

Keep changes focused and explain the resulting behavior. Retain the applicable
[component licenses](release/THIRD_PARTY_NOTICES.md) and check the
[application terms](release/TERMS.md). No additional license grant is implied
by source availability.

On Linux (on Windows, inside WSL) with Go 1.27, Python 3 and a host C
compiler (the race detector needs cgo):

```sh
cd app
go test -race ./...
GOOS=linux GOARCH=arm GOARM=7 CGO_ENABLED=0 go vet ./...
GOOS=linux GOARCH=arm GOARM=7 CGO_ENABLED=0 go build -o dist/plexcrt ./cmd/plexcrt
cd ..
make -C arm test
python3 -m unittest discover -s release -p 'test*.py'
python3 -m unittest discover -s tools -p 'test*.py'
python3 tools/check_public_content.py
```

`make -C arm test` runs the worker's contract check and every C host test,
including the geometry test, which compares the C helper with the shared fit
fixtures in `tools/testdata/fit_cases.txt`. The tests build with the host
compiler alone; only the worker itself (`make -C arm jfplay`) needs the ARM
toolchain and the HPS library and FFmpeg prefix from `toolchain/build_hps.sh`
and `toolchain/build_ffmpeg.sh` ([build](docs/BUILD.md)).

Core changes are checked without Quartus by the wiring check and the core's
test suite:

```sh
python3 third_party/MiSTer_h264_decoder/tools/check_emu_wiring.py
bash third_party/MiSTer_h264_decoder/tools/tests/run_tests.sh
```

Playback calibration is capability-gated on HPS interface 1.2; see
[Build from source](docs/BUILD.md#dependencies-and-playback-worker) for which
cores apply saved geometry.

The core's display controls and `jfplay` film-speed selection use HPS interface
1.3; interface 1.4 exposes the selected Off/50-60 refresh-match mode in status
word 87. The application accepts later 1.x interfaces, and the HPS library
checks the required version separately for each newer API call. Validate
source/output clock conversion with `make -C arm film-speed-test`. RTL timing
and mode-transition benches provide software coverage for 240p and PAL
switching; these checks do not replace hardware testing. On the target, verify
the selected mode, refresh switching, pause/resume, A/V sync, and the analog
picture. Film Speed intentionally raises pitch; do not describe it as
pitch-preserving.

Run the standalone raster bench from the vendored core directory:

```sh
cd third_party/MiSTer_h264_decoder
iverilog -g2012 -I. -Ih264 -o /tmp/sync_gen_240_tb h264/sync_gen.sv bench/h264/sync_gen_240_tb.sv
vvp /tmp/sync_gen_240_tb
```

Independent installer and publishing checks are described in
[distribution](release/DISTRIBUTION.md). The real Downloader integration test
uses a disposable `/media` card tree and a supplied official Downloader archive.

Hardware-dependent changes also need a MiSTer test. Verify direct streaming and
transcoding, continuous audio/video, pause/resume, repeated seeking, stop/restart,
and the server's saved position. Confirm that only one `jfplay` runs during
playback and none remain after stop. Test crop on an analog display when
changing it. Test credentials and media must belong to the tester; playback can
update watched state. Keep raw test journals, credentials, deployment logs and
session notes in a private directory outside Git. Public docs should describe
reproducible behavior using parameters and synthetic examples.

[Build from source](docs/BUILD.md) · [Architecture](docs/ARCHITECTURE.md) · [Playback](docs/PLAYBACK.md) · [Detailed reference](docs/REFERENCE.md)
