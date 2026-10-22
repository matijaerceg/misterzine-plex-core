# Watching from a Plex server

This build of the core is the one **MisterZine Plex Core** ships with: an app that
browses and plays the films and shows on your Plex Media Server, on a CRT or over
HDMI, driven with the gamepad. It appears in the MiSTer main menu as
**MisterZine Plex**, the name this manual uses for it. The app's own manual covers
installing, signing in and every screen:

- [Installation](https://github.com/matijaerceg/misterzine-plex-core#install)
- [Help](https://github.com/matijaerceg/misterzine-plex-core/blob/main/release/README.md)
- [Full reference](https://github.com/matijaerceg/misterzine-plex-core/blob/main/docs/REFERENCE.md)
- [HDMI setup](https://github.com/matijaerceg/misterzine-plex-core/blob/main/docs/HDMI.md)

!!! note "Not the upstream cast client"
    owenb321's upstream core comes with a cast-only Jellyfin client, started from
    **Scripts** → **jellyfin** and set up in `jellyfin.ini`. Its source is still in
    `clients/jellyfin`, but MisterZine Plex releases do not include it, and it does
    not play from Plex. The app has its own menus: you browse and choose on the
    MiSTer.

## Installing and starting

Download the installer from the app's
[releases](https://github.com/matijaerceg/misterzine-plex-core/releases), put it in
the SD card's `Scripts` folder and run it from **Scripts**. It installs the app and
this core together in `misterzine-plex/` on the SD card, each release in its own
folder with its own copy of the core, and adds **MisterZine Plex** to the MiSTer
main menu. Open that entry: it loads the core and starts the app.

To sign in, enter the code the app shows at [plex.tv/link](https://plex.tv/link).
A Plex Home with several profiles then asks who is watching, and a protected
profile asks for its Plex PIN. **Options** → **Choose server again** picks another
server.

The core calls itself **MisterZine Plex Core**: that is the name in its OSD and
the name of its section in `MiSTer.ini` ([Settings](settings.md#hdmi-scaling)).

## What plays

Files the core can certainly play are streamed as they are stored: H.264 High or
Main, 8-bit, level 4.1 or lower, up to 1280x720, at most 30 frames per second
above 854 pixels wide (60 at or below) and at most 6 Mbit/s above 854 pixels wide
(8 Mbit/s at or below), and no more than the app's **Video bitrate** setting.
Anything else is converted by your Plex server as it sends it (a **transcode**)
to H.264 within the same limits. If a file streamed as stored turns out
unplayable or falls behind, playback switches once to a transcode at the same
position.

Text subtitles (SRT, ASS/SSA, WebVTT) are drawn by the app over the video, words
only. Picture subtitles (PGS, VobSub, DVB), and text in a script the app's fonts
lack, are burned in by the server, which then transcodes the video.

The output is chosen in the core's OSD, not in the app: it follows the core's
[Settings](settings.md): **Output Mode**, **Display Shape**, **Refresh Rate
Match**, **240p Playback**, **Play 24fps at 25fps** and **De-flicker**. The app's
**Options** → **Video calibration** lines the picture up with the screen's edges,
and **Options** → **Video crop** chooses how much of a wide film's sides to cut.
The app's menus are drawn over the video, as [your own screens](../integrating/overlay.md)
are for any program.

## Controls

The app reads the gamepad and keyboard through the core ([Controls](controls.md)).
The D-pad moves, OK selects and Back goes back or opens the menu. During playback
OK opens the controls; the first Back closes what is on screen, and Back with
nothing on screen stops playback. A second Back within half a second of the first
is ignored. To leave the app, choose **Exit to MiSTer menu** in its menu. The
app's reference lists every control.

## The screensaver

After three minutes without a press in the menus, or on a paused video, the app
dims the screen to a quarter of its brightness. The next press only brings it
back; it does not also act. The sign-in code never dims.

## Updates

**Options** → **Updates** installs a newer release when you choose **Restart
now**; the new release brings its own copy of the core. If the new version does
not start, the previous one is put back. **Scripts** →
**MisterZine-Plex-Rollback** goes back to the previous release by hand.

## If it does not work

In the app, **Options** → **Send a report** sends a report with the app's,
launcher's and player's logs and shows a short code to post where you ask for
help; a copy is always saved as `/media/fat/misterzine-plex/report.txt`.
**Scripts** → **MisterZine-Plex-Diagnostics** writes the same report when the app
does not start. See the app's
[help page](https://github.com/matijaerceg/misterzine-plex-core/blob/main/release/README.md)
for what to check.
