# Watching from a Jellyfin server

This build of the core is the one **MisterZine Jellyfin** ships with: an app that
browses and plays the films and shows on your [Jellyfin](https://jellyfin.org)
server, on a CRT or over HDMI, driven with the gamepad. The app's own manual
covers installing, signing in and every screen:

- [Installation and help](https://github.com/matijaerceg/misterzine-jellyfin/blob/main/release/README.md)
- [Full reference](https://github.com/matijaerceg/misterzine-jellyfin/blob/main/docs/REFERENCE.md)
- [HDMI setup](https://github.com/matijaerceg/misterzine-jellyfin/blob/main/docs/HDMI.md)

!!! note "Not the upstream cast client"
    The upstream core comes with a cast-only Jellyfin client, started from
    **Scripts** → **jellyfin** and set up in `jellyfin.ini`. Its source is still in
    `clients/jellyfin`, but MisterZine Jellyfin releases do not include it. The app
    has its own menus: you browse and choose on the MiSTer, not from a phone.

## Installing and starting

Run the MisterZine Jellyfin installer from **Scripts**. It installs the app and
this core together and adds **MisterZine Jellyfin** to the MiSTer main menu. Open
that entry: it loads the core and starts the app. Sign in with the server's
address, then Jellyfin **Quick Connect** or a user name and password.

## What plays

Files the core can certainly play are streamed as they are stored: H.264 High or
Main, 8-bit, up to 1280x720 at 30 frames per second or up to 854 pixels wide at
60, within a bitrate the core keeps up with. Anything else is converted by your
server as it sends it (a **transcode**) to H.264 within the same limits. Text
subtitles are drawn by the app over the video; picture subtitles (PGS, VobSub),
and text in a script the app's fonts lack, are burned in by the server.

The output follows the core's [Settings](settings.md): **Output Mode**, **Display
Shape**, **Refresh Rate Match**, **240p Playback** and **Play 24fps at 25fps**.
The app's menus are drawn over the video, as [your own screens](../integrating/overlay.md)
are for any program.

## Controls

The app reads the gamepad and keyboard through the core ([Controls](controls.md)).
The D-pad moves, OK selects and Back goes back. During playback OK opens the
controls; the first Back closes what is on screen and the next one stops. The
app's reference lists every control.

## The screensaver

After three minutes without a press in the menus, or on a paused video, the app
dims the screen to a quarter of its brightness. The next press only brings it
back. The sign-in screens never dim.

## If it does not work

In the app, **Options** → **Send a report** saves a report with the app's and
the player's logs to `/media/fat/misterzine-jellyfin/report.txt`;
**Scripts** → **MisterZine-Jellyfin-Diagnostics** writes the same file when the
app does not start. See the app's
[help page](https://github.com/matijaerceg/misterzine-jellyfin/blob/main/release/README.md)
for what to check.
