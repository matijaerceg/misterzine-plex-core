# Install the core

This build of the core has no download of its own: it ships inside **MisterZine Plex**
releases ([Watching from a Plex server](../using/plex.md)).

1. Download the MisterZine Plex installer, put it in the SD card's `Scripts` folder and run
   it from **Scripts** in the MiSTer menu, as its
   [installation guide](https://github.com/matijaerceg/misterzine-plex-core#install)
   describes. It installs the app and this core together, in `misterzine-plex/` on the
   SD card (each release in its own folder, with its own copy of the core), and adds
   **MisterZine Plex** to the main menu.
2. Open that entry. It loads the core and starts the app; an update from the app's
   **Options** → **Updates** brings a new copy of the core with the new release.

## The other programs

The Moonlight client, the video player and the camera viewer are in this repository's
source, but MisterZine Plex releases do not include them. To use one, build it
([Building from source](../about/building.md)) and copy its `build/dist/` contents to the
root of the SD card, which places its script in `Scripts/` and its folder beside it:

- the Moonlight client: `Scripts/moonlight.sh` and `moonlight/`
  ([Streaming from a PC](../using/moonlight.md));
- the video player: `Scripts/h264player.sh` and `h264player/`
  ([Playing video files](../using/player.md));
- the camera viewer: `Scripts/h264cam.sh` and `h264cam/`
  ([Showing a USB camera](../using/camera.md)).

These programs load the core from `_Other/` (the `H264*.rbf` there that sorts last by
name) and accept only a core that names itself `H264`, as owenb321's upstream core does.
The core built from this source names itself **MisterZine Plex Core**, so they use neither
it nor the copy in MisterZine Plex's folder: put an `H264` core in `_Other/` for them.
Run a program from **Scripts**; it loads the core itself when it starts playing.

## Version check

The OSD's About line shows the running build as `<core name> <version> <yymmdd>`. A core
from a MisterZine Plex release has a version of the form `plex-<app version>`. Quote that
line when reporting a problem.
