# Install the core

This build of the core has no download of its own: it ships inside **MisterZine Jellyfin**
releases ([Watching from a Jellyfin server](../using/jellyfin.md)).

1. Run the MisterZine Jellyfin installer from **Scripts** in the MiSTer menu, as its
   [installation help](https://github.com/matijaerceg/misterzine-jellyfin/blob/main/release/README.md)
   describes. It installs the app and this core together, in `misterzine-jellyfin/` on the
   SD card, and adds **MisterZine Jellyfin** to the main menu.
2. Open that entry. It loads the core and starts the app; updates from the app's
   **Options** replace both together.

## The other programs

The Moonlight client, the video player and the camera viewer are in this repository's
source, but MisterZine Jellyfin releases do not include them. To use one, build it
([Building from source](../about/building.md)) and copy its `build/dist/` contents to the
root of the SD card, which places its script in `Scripts/` and its folder beside it:

- the Moonlight client: `Scripts/moonlight.sh` and `moonlight/`
  ([Streaming from a PC](../using/moonlight.md));
- the video player: `Scripts/h264player.sh` and `h264player/`
  ([Playing video files](../using/player.md));
- the camera viewer: `Scripts/h264cam.sh` and `h264cam/`
  ([Showing a USB camera](../using/camera.md)).

These programs load the core from `_Other/` (the `H264*.rbf` there that sorts last by
name), not from
MisterZine Jellyfin's folder, so put a core built from the same source in `_Other/` as well.
Run a program from **Scripts**; it loads the core itself when it starts playing.

## Version check

The OSD's About line shows the running build as `<core name> <version> <yymmdd>`. A core
from a MisterZine Plex release has a version of the form `plex-<app version>`. Quote that
line when reporting a problem.
