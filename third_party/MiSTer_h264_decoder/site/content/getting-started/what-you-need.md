# What you need

- A MiSTer (DE10-Nano) with an up-to-date MiSTer menu.
- An HDMI display, or an analog display through a MiSTer I/O board: a CRT TV at 15 kHz, a
  VGA monitor, or an external scaler ([Video output](../video/output.md)).
- **A program that feeds the core.** The core decodes; it does not fetch anything from
  the network or read files by itself. Programs that use it run on the MiSTer's ARM side.

This build of the core ships with **MisterZine Plex**, which installs the core with it,
starts from its own entry in the MiSTer main menu and is driven with a gamepad or a keyboard.
The repository also holds the source of three more programs; each is started from MiSTer's
**Scripts** menu and loads the core by itself, but you build it yourself
([Install the core](install.md#the-other-programs)):

| Program | What it plays | You also need |
|---|---|---|
| **MisterZine Plex** ([Watching from a Plex server](../using/plex.md)) | The films and shows on your Plex Media Server, with their sound and subtitles, browsed and chosen on the MiSTer. | A Plex account with access to a Plex Media Server that can transcode |
| **Moonlight** ([Streaming from a PC](../using/moonlight.md)) | A PC's desktop or its games, with their sound. The MiSTer's keyboard, mouse and gamepads control the PC, and rumble comes back. | A PC running [Sunshine](https://github.com/LizardByte/Sunshine), on the same network |
| **Video player** ([Playing video files](../using/player.md)) | Video files from the SD card, a USB drive or a network share, picked from a list on screen. | -- |
| **Camera viewer** ([Showing a USB camera](../using/camera.md)) | A USB webcam or capture device: the MiSTer as a screen for another source. | A USB camera that sends Motion JPEG |

A MiSTer with a network connection (wired or Wi-Fi) is needed for MisterZine Plex and
Moonlight. MisterZine Plex also needs current MiSTer Linux (Python 3.9 or newer) and at least
250 MB free on the SD card. [Install the core](install.md) says how to get each one.

Other programs can use the core too: it takes video from any program written for its
interface. If you want to write one, see [Integrating a program](../integrating/overview.md).
