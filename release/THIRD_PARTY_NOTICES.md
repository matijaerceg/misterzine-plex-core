# Third-party components and licenses

This notice describes the components used by the source tree and binary release
packages. Source checkouts omit generated ARM executables and libraries. Binary
packages include the application, `jfplay`, FFmpeg and the qualified H.264 FPGA
image (`PlexH264.rbf`), with the corresponding source and build materials
published beside each package as `MisterZine-Plex-Core-Source-<id>.zip`.
Component licenses and upstream notices are retained with their source; license
texts referenced below are in `licenses/` in a package or `release/licenses/`
in a source checkout.

This notice does not grant a license to other project code. The repository has
no root `LICENSE` file.

## MiSTer H.264 core and HPS library

The FPGA core is built from `third_party/MiSTer_h264_decoder/`, a fork of
owenb321's MiSTer_h264_decoder (https://github.com/owenb321/MiSTer_h264_decoder),
and is GPL-3.0-or-later. Its upstream `LICENSE` and detailed per-file `NOTICE`
remain in that directory. The notice identifies MiSTer framework files with
GPL-2.0-or-later or GPL-3.0-or-later terms, with contributions by MiSTer-devel
and the other authors identified in the source; the combined core is
GPL-3.0-or-later. The associated HPS client library under `hps/` is separately
MIT-licensed; see `hps/LICENSE`. The GPL texts are in
`release/licenses/GPL-2.0.txt` and `GPL-3.0.txt`.

## ARM playback worker

`arm/jfplay.c` is GPL-3.0-or-later and links the MIT-licensed HPS library.
The retained upstream cast client source under
`third_party/MiSTer_h264_decoder/clients/jellyfin/` vendors cJSON 1.7.19 under
MIT; it is not used by the Go application or the `jfplay` build. Its license
is included beside the source.

The ARM build scripts fetch FFmpeg 7.1.1 and OpenSSL 3.0.15 from their upstream
source releases. FFmpeg is configured without `--enable-gpl` or
`--enable-nonfree`; the playback worker statically links its libavformat,
libavcodec, libswresample and libavutil libraries, and the packaged `ffmpeg`
program is built from the same configuration (with libavfilter). FFmpeg's applicable license is
LGPL-2.1-or-later; the source tree and exact configuration are documented in
`toolchain/build_ffmpeg.sh`. OpenSSL is configured static-only and is licensed
under Apache-2.0. The ARM executables are linked statically, including the GNU
C Library supplied by the ARM cross toolchain, which retains its
LGPL-2.1-or-later notices. The LGPL text is included in
`release/licenses/LGPL-2.1.txt`; OpenSSL's Apache-2.0 text is in
`release/licenses/Apache-2.0.txt`.

The source and build scripts are provided here, but this source publication
does not include those generated libraries or binaries. Each binary package is
published with its corresponding source archive, which holds the tracked
source, the qualified core snapshot and `dependency-sources.zip` (the FFmpeg,
OpenSSL and toolchain sources with relink notes). Any other binary distribution
must include the exact applicable notices and source materials, including those
for the toolchain's GNU C Library, and meet the terms that apply to its static
LGPL and OpenSSL links.

## Application assets and Go runtime

The application includes the Go runtime and standard library, copyright The Go
Authors, under the BSD-style license reproduced in `release/licenses/Go.txt`.
There are no external Go modules in this build.

The bitmap font atlases are generated from Roboto and Roboto Condensed fonts,
version 2.137 (2017), copyright 2011 Google Inc. Those fonts are licensed under
Apache-2.0; see `release/licenses/Apache-2.0.txt`. The generated atlases are
rasterized and resized for the display.

The playback bar's Icons theme uses icons from Lucide 1.61.0
(https://github.com/lucide-icons/lucide), licensed under the ISC License, with
portions from Feather under MIT. The SVG sources sit beside the rasterized masks
in `app/internal/ui/icons/` with their `LICENSE`; the ISC text is reproduced in
`release/licenses/Lucide-ISC.txt`.

## Installer and MiSTer Downloader

The independent installer can download the official GPL-3.0 MiSTer Downloader
from https://github.com/MiSTer-devel/Downloader_MiSTer at a pinned upstream
revision. It is not embedded in the Plex package and is not part of the
playback worker. Its source revision and hashes are pinned in
`update_service.py`. Direct package download is also supported; release package
hashes are verified before install. Discovery and isolated invocation were
informed by the MIT-licensed MisterZine on-device project (Copyright 2026
Matija Erceg): https://github.com/matijaerceg/misterzine-on-device.

Plex and MiSTer names belong to their respective owners. This project is
independent and is not endorsed by Plex.
