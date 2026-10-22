# MiSTer H264

**Video and sound from a program on the MiSTer, shown on a CRT or an HDMI display, in sync.**

> [!IMPORTANT]
> **This is a proof of concept, and it is not supported.** It works -- everything described below
> runs on real hardware -- but it is offered as it is: no help with setups, no fixes on request,
> no promised features. **You are encouraged to fork it** and do whatever you want with it: take
> the decoder, the interface or the programs in any direction and publish your own builds. The
> licences (GPL-3.0-or-later for the core, MIT for the client library) allow exactly that.

The MiSTer's ARM processor runs Linux and can do everything a media player does -- networking,
streaming protocols, containers, subtitles -- except decode modern video fast enough. This core
gives it an FPGA that can. A program on the ARM hands the core **H.264 video** (or pictures it
decoded itself) and **PCM audio**, each with a presentation time; the core decodes the video,
presents picture and sound against one clock, and drives:

- **a CRT** -- 480i / 576i at 15 kHz with proper composite sync, or 480p / 576p, every picture
  fitted to the screen at its true shape, with an anti-twitter filter for interlaced displays;
- **HDMI** -- the same, or the picture at its own pixels, up to **1280x720**.

It is not tied to one service. Game streaming, a media server, local files and a USB camera all
come in through the same interface.

**This is the MisterZine fork of the core, as kept in MisterZine Plex.** Here it is built as
`PlexH264.rbf` and released only inside
[MisterZine Plex](https://github.com/matijaerceg/misterzine-plex-core), whose installer puts
the app and this core on the SD card together ([user guide](https://github.com/matijaerceg/misterzine-plex-core/blob/main/release/README.md)).

## Programs in this repository

The source of four programs that feed the core is in `clients/`. MisterZine Plex releases
include none of them: build one yourself to use it
([Install the core](site/content/getting-started/install.md#the-other-programs)). Each starts
from MiSTer's **Scripts** menu and is driven with the gamepad.

| Program | What it does |
|---|---|
| **Moonlight** ([manual](site/content/using/moonlight.md)) | Streams games from a PC running Sunshine. The MiSTer's keyboard, mouse and gamepads reach the PC; rumble comes back. |
| **Video player** ([manual](site/content/using/player.md)) | Plays files from the SD card, a USB drive or a network share. H.264 goes to the core; MPEG-2, DivX / Xvid, WMV, Theora and Motion JPEG are decoded on the ARM and shown the same way. |
| **Camera viewer** ([manual](site/content/using/camera.md)) | Shows a USB webcam or capture device -- the MiSTer as a 15 kHz monitor for another source. |
| **Jellyfin cast client** ([`clients/jellyfin`](clients/jellyfin/README.md)) | The upstream core's cast target for a Jellyfin server, kept as source. It is not part of MisterZine Plex releases. |

## What the core handles

| | |
|---|---|
| **Video** | H.264 High or Main profile, 8-bit 4:2:0, any size up to 1280x720. Real time at **854x480 / 720x480, 60 frames/s** (a 10 Mbit/s game stream) and **1280x720, 30 frames/s** (game streams, films and transcodes up to about 8 Mbit/s). CAVLC streams are rewritten on the ARM, up to about 4-5 Mbit/s. |
| **Pictures you decode** | Any format the program decodes on the ARM itself, handed over as raw 8-bit 4:2:0 (or 4:2:2) pictures and presented exactly like decoded H.264. **In practice standard definition (up to 720x576) at up to 30 frames/s**: the ARM has one free core, and copying a picture into the core's memory alone takes about 5 ms at 720x480 (14 ms at 1280x720), so software decoding does not keep up at 720p. See [the limits](site/content/integrating/pictures.md#limits). |
| **Audio** | 48 kHz 16-bit stereo PCM, played against the same clock as the pictures; pause and volume. |
| **Output** | 480i, 576i, 480p, 576p and HDMI at the picture's own size. 59.94, exactly 60.00, or 50 Hz, chosen from the stream. The picture's colour (BT.601 / 709 / 2020) honoured. |
| **Your own screens** | A program draws menus, subtitles or a progress bar into the Linux framebuffer; the core composites them over the video on HDMI and analog alike. |
| **Input** | The keyboard, mouse and gamepads plugged into the MiSTer reach the program; the program can drive the gamepads' rumble. |

Higher rates (720p at 60 frames/s, 1080p) decode correctly but fall behind, visibly, so the
programs avoid them: the player and Moonlight refuse them by name, MisterZine Plex asks the
server for a transcode. The full list: [compatibility](site/content/reference/compatibility.md).

## Write your own program

The interface is a ring of records and a control block in shared DDR3 memory -- **version 1.4,
the layout frozen at 1.0**: a program built for 1.0 keeps working on every later 1.x core. The C client library in
[`hps/`](hps/) (MIT-licensed, libc only) does the work:

```c
#include "h264ring.h"

h264ring *r;
if (h264ring_launch_core(NULL, 10000) || h264ring_open_devmem(&r, 0) ||
    h264ring_start_session(r, 3000))
    return 1;
for (each access unit)
    h264ring_write_au(r, au, len, pts_90khz, flags, 1000);   /* audio: h264ring_write_audio() */
h264ring_close(r);
```

Start with [Integrating a program](site/content/integrating/overview.md); `hps/feeder/h264play.c`
is a complete reference player.

## Status

**A proof of concept, offered as is.** Everything above runs on the hardware (a DE10-Nano,
tested over HDMI, on CRTs and through a RetroTINK); the video player and the camera viewer are
early. **No support is provided**: issues and pull requests may go unanswered, and nothing here
is a promise of future work. MisterZine Plex releases carry the core built from this
source.

**If you fork it**, these are the places to start:

- [`docs/roadmap.md`](docs/roadmap.md) -- what was decided, built and measured, and the ideas
  left unbuilt;
- [`docs/`](docs/) -- why each part is designed the way it is, with the measurements behind it;
- [`bench/h264/`](bench/h264/) -- the simulation benches (`run_*.sh`; `--red` proves each one can
  fail), and [`tools/mister.py`](tools/mister.py), which drives a real MiSTer over ssh for
  hardware tests.

## Building

Quartus 17.0.2, natively or in the pinned Docker image; the ARM programs build in Docker images
defined in this repository.

```bash
USE_DOCKER=1 ./build_release.sh --compile      # the core -> releases/PlexH264_*.rbf
USE_DOCKER=1 hps/build_arm.sh                  # the library, h264play, h264stat
USE_DOCKER=1 clients/moonlight/build.sh        # likewise clients/player, clients/uvc (and clients/jellyfin)
```

Copy each client's `build/dist/*` to the card's root. The clients load an `H264` core from
`_Other/` and accept only a core that names itself `H264`, as owenb321's upstream core does;
the core built here names itself MisterZine Plex Core. MisterZine Plex packages its own copy
of the core as `PlexH264.rbf` (the app's `release/build_package.py`) and installs it in each
release's folder, `misterzine-plex/releases/<id>/`.
[Building from source](site/content/about/building.md) has the details.

## Documentation

- **[The manual](site/content/index.md)** -- for users, and for developers of
  programs that feed the core (`site/content/`, built with MkDocs).
- **Engineering notes** -- `docs/`: why the design is the way it is. Not user documentation.
  References written `fj#NN`, and commit SHAs quoted there, come from the private repository the
  core was brought up in and do not resolve here.

## Credits and licence

The decoder and display path are forked from **MiSTer_UMD_Video** (a PSP UMD Video player core) and
through it from **[MiSTer_DVD](https://github.com/owenb321/MiSTer_DVD)**, by the same author; the
framework is MiSTer's. See [acknowledgements](site/content/about/acknowledgements.md).

GPL-3.0-or-later, except `hps/` (the client library, `h264play`, `h264stat`), which is MIT. See
[LICENSE](LICENSE), [hps/LICENSE](hps/LICENSE) and [NOTICE](NOTICE) (framework licences,
verification oracles, patents).
