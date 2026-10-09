# Build from source

Use Go 1.27, Python 3, Quartus Prime Lite 17.0 with Cyclone V support, and an ARM
hard-float GCC toolchain. The framework and PLL inputs are included under core/;
an external working tree or floating upstream checkout is not required.

## Application

```sh
cd app
GOOS=linux GOARCH=arm GOARM=7 CGO_ENABLED=0 go build -trimpath -o dist/plexcrt ./cmd/plexcrt
cd ..
```

Normal source builds are unlocked. See [beta builds](BETA_RELEASES.md)
for explicit release-channel builds. The app's version is available via -version.

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
marked BETA after the star. The public
build has no code registry, so no code unlocks anything in it.

The hooks the extras plug into are in `app/internal/ui/premium.go`; the public
build's stubs, behind `//go:build !premium`, are in `premium_free.go`. To add
an extra, land the smallest hook it needs here first, then the extra in the
private repository. `release/beta_release.py build --tags premium` builds with
the overlay in place.

## FPGA core

```sh
cd core
quartus_sh --flow compile PlexCRT
cd ..
```

Output: core/output_files/PlexCRT.rbf. The sys/ and PLL RTL are bundled build
inputs with their original notices. Project-owned RTL is covered by
[core licensing](../core/LICENSING.md). Do not change timing for a CRT without
checking the output profile guard and verifying on appropriate hardware.

## Presenter and package

```sh
python3 release/build_presenter.py
cp core/output_files/PlexCRT.rbf core/PlexCRT.rbf
python3 release/build_package.py --core-tree core --id source-build --version 0.1.0-beta.15
```

build_presenter.py runs `arm-linux-gnueabihf-gcc -O2 -static -march=armv7-a
-mfpu=neon -mfloat-abi=hard -pthread -o arm/plexfb arm/plexfb.c -lm` from the
repository root (the source path is embedded in the binary; `--cc` selects another
compiler name) and records the SHA-256 of the source and the binary in
arm/plexfb.build.json. On Windows, run it inside WSL. build_package.py refuses a
presenter without that record, one built from a different arm/plexfb.c, or one
replaced after its build, so rebuild the presenter whenever its source changes.

The packaged presenter uses glibc; preserve its LGPL terms and relinking/source
obligations. The reference toolchain is GCC 13 with glibc 2.39. Generated release
ZIPs go under release/dist and include the matching core/presenter source and
license texts. FFmpeg is fetched separately by the installer with a pinned hash.
No patron keys or account files belong in these packages.

The runtime requires MiSTer Linux devices and cannot run as a desktop app.
Linux unit tests can run on a desktop; use GOOS=linux for target vet/builds.
