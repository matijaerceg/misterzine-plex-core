# Components and retained licenses

This is a component-specific notice, not a replacement for upstream licenses.

## FPGA core and MiSTer framework

The original PlexCRT hardware sources are provided under GPL-3.0-or-later.
Bundled MiSTer framework files retain their original notices and per-file terms,
including GPL-2.0-or-later and GPL-3.0-or-later. The framework has contributions
by Till Harbaum, Alexey Melnikov and other authors identified in the source.
Both GPL version texts are included. Corresponding source and Quartus project
files for the packaged core are included in `corresponding-source.zip`.

## ARM presenter

The original `plexfb.c` presenter is provided under GPL-3.0-or-later. Its source
and build instructions are in the corresponding-source archive. The static
build uses the GNU C library from Ubuntu's ARM hard-float cross toolchain;
glibc retains its LGPL-2.1-or-later notices. The LGPL text is included too.

## Go runtime

The application includes the Go runtime and standard library, copyright The Go
Authors, under the BSD-style license in `licenses/Go.txt`. There are no external
Go modules in this build.

## Fonts

Roboto and Roboto Condensed, version 2.137 (2017), copyright 2011 Google Inc.,
are used to produce the application's bitmap font atlases. Those source fonts
identify Apache License 2.0. The license is included in `licenses/Apache-2.0.txt`.
The generated atlases are rasterized, resized and horizontally adjusted for
the display's pixel aspect ratio.

## FFmpeg

The installer downloads John Van Sickle's FFmpeg 7.0.2 ARM hard-float static
build separately from:
https://johnvansickle.com/ffmpeg/releases/ffmpeg-7.0.2-armhf-static.tar.xz

When that site cannot be reached, it downloads the identical archive from a
third-party copy at https://github.com/MotionquestAI/ffmpeg-static-build
(`ffmpeg-release-armhf-static.tar.xz`). Either file is used only if it matches
the hash below.

Archive SHA-256:
`7d41f558cb1f3395b313f8ceabed78b3731c79a0962abf405ebb5cd393e93991`

That upstream build enables GPL version 3 components. Its `GPLv3.txt` and
`readme.txt` are retained in the installed `decoder-notices` folder. Upstream
build information and source links: https://johnvansickle.com/ffmpeg/
The release ZIP does not bundle or relicense that decoder archive.

Plex and MiSTer names belong to their respective owners. This project is
independent and is not endorsed by Plex.

## MiSTer Downloader

The independent installer can download the official GPL-3.0 MiSTer Downloader
from https://github.com/MiSTer-devel/Downloader_MiSTer. It is not embedded in the
Plex package. Its source revision and hashes are pinned in `update_service.py`.
Discovery and isolated invocation were informed by the MIT-licensed MisterZine
on-device project (Copyright 2026 Matija Erceg):
https://github.com/matijaerceg/misterzine-on-device.
