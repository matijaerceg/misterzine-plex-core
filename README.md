# MisterZine Plex Core

Watch your Plex library on MiSTer. Built for CRTs, with controller navigation
and HDMI support. The app's source is available in this repository.

Clips, features and what early access includes: [misterzine.fyi/plex](https://misterzine.fyi/plex/)

<img width="1920" height="1080" alt="gosling1" src="https://github.com/user-attachments/assets/7ca87cd5-154b-42fc-9b86-88b34d657ad9" />

## Install

Public releases are free. Pre-release versions are paid early access through [Patreon](https://www.patreon.com/MisterZine): install/browsing works, but playback requires the code from that version's Patreon post.

You'll need a networked MiSTer running current MiSTer Linux, at least 250 MB free on the SD card, and a Plex account with access to a server that can transcode. Run **Update All** or **Downloader** first so MiSTer Linux is current: the installer fails on older system images.

1. Download the Public or Beta installer from
   [Releases](https://github.com/matijaerceg/misterzine-plex-core/releases)
   and put it in the SD card's `Scripts` folder. Choose Public for free releases or Beta for paid early access, when available
2. Run the downloaded script from **Scripts**
3. Follow the sign-in screen at [plex.tv/link](https://plex.tv/link)

For an early-access build, enter the Patreon code when you first press Play.
Next time, open **MisterZine Plex Core** from the main menu.

If the installer or an update reports a download failure, check whether
**Update All** or **Downloader** works on the same MiSTer. If they fail too, the
problem is the board's connection or clock, not this app: run Downloader once so
the board syncs its time, or set the clock in MiSTer Menu, then try again. If
Downloader works and this app still cannot download, the on-screen message
says why; [report it](https://github.com/matijaerceg/misterzine-plex-core/issues/new?template=bug_report.yml)
with that message.

CRT output is NTSC 480i; PAL isn't supported yet. HDMI supports 480p rendering.

This is unstable beta software. It talks to your real Plex account: playback,
watched marks and resume points change your library, and a bug could change
them wrongly. Use it at your own risk; no responsibility is taken for what it
does to your library or your MiSTer.

[Need help?](release/README.md) · [Build and contribute](CONTRIBUTING.md)

[Terms](release/TERMS.md) · [Component licenses](release/THIRD_PARTY_NOTICES.md).
Movie artwork belongs to its owners. Not affiliated with Plex or the MiSTer project.
