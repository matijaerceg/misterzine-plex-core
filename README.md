# MisterZine Plex Core

Watch your Plex library on MiSTer. Built for CRTs, with controller navigation
and HDMI support. The Go application handles browsing and playback controls;
`jfplay` sends compressed H.264 video and decoded stereo audio to this
project's fork of owenb321's
[MiSTer H.264 decoder](third_party/MiSTer_h264_decoder/README.md) core, which
ships with the app. The app's source is available in this repository.

Clips, features and what early access includes: [misterzine.fyi/plex](https://misterzine.fyi/plex/)

<img width="1920" height="1080" alt="gosling1" src="https://github.com/user-attachments/assets/7ca87cd5-154b-42fc-9b86-88b34d657ad9" />

## Install

Public releases are free. Pre-release versions are paid early access through [Patreon](https://www.patreon.com/MisterZine): install/browsing works, but playback requires the code from that version's Patreon post. See [beta access](release/BETA_ACCESS.md).

You'll need a networked MiSTer running current MiSTer Linux with Python 3.9
or newer, at least 250 MB free on the SD card, and a Plex account with access
to a server that can transcode: anything the decoder cannot play as stored, and
every video with subtitles the server burns in (picture subtitles such as
PGS), is converted by the server. Run **Update All** or **Downloader** first so
MiSTer Linux is current: the installer fails on older system images.

The server must be reachable over IPv4. MiSTer Linux is built without IPv6, so
no MiSTer app can reach a server that is only on IPv6: use the local network, an
IPv4 route to the server, or Plex Relay, which the app tries on its own.

1. Download the Public or Beta installer from
   [Releases](https://github.com/matijaerceg/misterzine-plex-core/releases)
   and put it in the SD card's `Scripts` folder. Choose Public for free releases or Beta for paid early access, when available
2. Run the downloaded script from **Scripts**
3. Follow the sign-in screen at [plex.tv/link](https://plex.tv/link)

For an early-access build, enter the Patreon code when you first press Play.
Next time, open **MisterZine Plex** from the main menu.

If the installer or an update reports a download failure, check whether
**Update All** or **Downloader** works on the same MiSTer. If they fail too, the
problem is the board's connection or clock, not this app: run Downloader once so
the board syncs its time, or set the clock in MiSTer Menu, then try again. If
Downloader works and this app still cannot download, the on-screen message
says why; [report it](https://github.com/matijaerceg/misterzine-plex-core/issues/new?template=bug_report.yml)
with that message.

CRT output is 480i or PAL 576i, with optional 240p/288p playback. HDMI supports
480p, 576p and native output. Choose them in the core's OSD.

This is unstable beta software. It talks to your real Plex account: playback,
watched marks and resume points change your library, and a bug could change
them wrongly. Use it at your own risk; no responsibility is taken for what it
does to your library or your MiSTer.

[Need help?](release/README.md) · [Full reference](docs/REFERENCE.md) ·
[HDMI setup](docs/HDMI.md)

## What it does

- Plex sign-in through [plex.tv/link](https://plex.tv/link), Plex Home
  profiles with their PINs, and a choice of server.
- Home rows, library browsing by name, date added, release date, folders and
  collections, search with an on-screen keyboard, and resume positions and
  watched marks kept in step with Plex.
- Direct streaming of files the decoder supports; the server transcodes the
  rest. H.264 High/Main video up to 1280x720, with a video bitrate cap from
  0.4 to 8 Mbit/s; the low steps are for weak Wi-Fi. Higher frame rates are
  limited to lower widths; see [playback details](docs/PLAYBACK.md).
- Pause, seeking, audio and subtitle track choice, skip intro and credits,
  autoplay and shuffle, with Standard, Icons or VCR-style playback controls.
- Text subtitles drawn by the app in three sizes, without a transcode;
  picture subtitles burned into the picture by the server. A surround downmix
  boost with peak limiting.
- Display modes and refresh matching are selected in the core's OSD, including
  240p/288p playback and 23.976/24-to-25 film speed-up on PAL output. Film
  speed-up raises the audio pitch; it does not preserve pitch.
- Letterbox, 14:9 and Fill crop, and on-screen calibration of the picture area.
- In-app updates with rollback to the previous release.

Seek interruptions, network buffering, and hardware-specific behavior remain
under active testing.

## Build and contribute

You need MiSTer hardware, a Plex server, Go 1.27, and an ARM Linux cross
compiler. Follow [Build from source](docs/BUILD.md) for the application, the
worker and the core, and [the toolchain guide](toolchain/README.md) for the
native dependencies.

[Contributing](CONTRIBUTING.md) · [Architecture](docs/ARCHITECTURE.md) ·
[Player contract](arm/jfplay.md) · [Supporter builds](docs/SUPPORTER_BUILDS.md) ·
[Terms](release/TERMS.md) · [Component licenses](release/THIRD_PARTY_NOTICES.md)

Component licenses apply separately; source availability does not grant additional
rights. Retained license texts and upstream notices remain with their components.
Movie artwork belongs to its owners. Not affiliated with Plex or the MiSTer project.
