# MiSTer ARM cross-build toolchain

These scripts build 32-bit, hard-float ARMv7 binaries for the DE10-Nano's
Cortex-A9. All compilation runs inside WSL Ubuntu; no Docker is used and no
vendored source is modified.

## Prerequisites

From Windows PowerShell, install the WSL packages once:

```powershell
wsl.exe -e bash -lc 'sudo apt-get update && sudo apt-get install -y build-essential gcc-arm-linux-gnueabihf binutils-arm-linux-gnueabihf libc6-dev-armhf-cross make perl pkg-config wget xz-utils file ca-certificates qemu-user-static'
```

Ubuntu 24.04's `/usr/bin/arm-linux-gnueabihf-gcc` 13.3 is the expected cross
compiler. The HPS host test also needs native `gcc` from `build-essential`.

## Build

Open a WSL shell at the repository root, then run:

```sh
bash toolchain/build_hps.sh
bash toolchain/build_ffmpeg.sh
```

`build_hps.sh` first copies the read-only vendored HPS tree to `build/hps-src`,
runs its native x86 unit test (log: `build/hps-host-test.log`), and produces:

- `build/arm/libh264ring.a`
- `build/arm/h264play`
- `build/arm/h264stat`
- `build/arm/cavlc2cabac`

`build_ffmpeg.sh` downloads and caches OpenSSL 3.0.15 and FFmpeg 7.1.1 beneath
`build/sources`, cross-builds static OpenSSL, and installs headers and static
libraries under `build/arm/ffmpeg-prefix`. It also copies the static `ffmpeg`
and `ffprobe` executables to `build/arm/`. Both archives must match the SHA-256
pinned in the script, whether downloaded or already cached. If a download site
is down, place the archives from a release's `dependency-sources.zip`
(`vendor-sources/`) in `build/sources` first.

On a typical multi-core PC, HPS takes under a minute. The first FFmpeg/OpenSSL
build usually takes 5–20 minutes; later runs reuse downloaded archives and the
installed OpenSSL libraries. A prefix built by this script in another checkout
can be reused without rebuilding: `make -C arm jfplay PREFIX=<that checkout>/build/arm/ffmpeg-prefix`.

## Exact FFmpeg configuration

FFmpeg version: **7.1.1**. TLS library: **OpenSSL 3.0.15**, configured with
`linux-armv4 --cross-compile-prefix=arm-linux-gnueabihf-`, static-only, with
ARMv7-A/Cortex-A9/NEON/hard-float compiler flags.

The FFmpeg configure invocation is the multiline `./configure` command in
`toolchain/build_ffmpeg.sh`. It disables autodetection and everything by
default, then explicitly enables only the requested libraries, programs,
protocols, demuxers, decoders, parsers, bitstream filters, encoders, muxers,
and filters. The app's theme player invokes FFmpeg as
`-f s16le -ac 2 -ar 48000 pipe:1`; the configure components are named
`pcm_s16le` (the muxer) and `pipe` (the protocol), not `s16le`. The audio
output graph also needs `aresample`, `aformat`, `anull`, and `atrim` enabled.
The `ffmpeg` command-line program depends on libavfilter, which is therefore
included in the playback runtime. Devices remain disabled.
The target flags are:

```text
OpenSSL:                 -static -march=armv7-a -mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard
FFmpeg, HPS and jfplay:  -march=armv7-a -mfpu=neon -mfloat-abi=hard
```

Every binary is linked statically.

## Verification

```sh
file build/arm/h264play build/arm/ffmpeg
qemu-arm-static build/arm/h264play --help
qemu-arm-static build/arm/ffmpeg -version
```

Both executables should report `ELF 32-bit LSB executable, ARM, EABI5` and
`statically linked`.

## Why the scripts do this

- `build_hps.sh`: the vendored host test reads `../h264/dec/h264_pkg.sv` for the refusal
  names, so the copy under `build/hps-src/` keeps `hps/` and `h264/dec/` as siblings. The
  `-mcpu=cortex-a9` flag conflicts with `-march=armv7-a+simd` under gcc 13 and the Makefile
  builds with `-Werror`; `-march=armv7-a -mfpu=neon -mfloat-abi=hard` alone is used.
- `build_ffmpeg.sh`: FFmpeg's configure defaults to `arm-linux-gnueabihf-pkg-config` when
  cross compiling, which does not exist, so OpenSSL would not be found;
  `--pkg-config=pkg-config` fixes it. With `--disable-everything` the h264 decoder's
  `h2645_sei.o` needs `aom_film_grain.o`, which only the HEVC SEI config pulls in;
  `--enable-parser=hevc` resolves the link. `--extra-libs='-ldl -lpthread -latomic'` is
  for static OpenSSL.
- The static link warns that `getaddrinfo` needs the runtime glibc's NSS libraries; the
  MiSTer's Linux has them, and `ffprobe` resolving an HTTPS URL on the MiSTer is the check.
- If `rm: cannot remove 'ffmpeg-7.1.1': Permission denied` appears, a Windows shell has
  that directory as its working directory; leave it and rerun.
