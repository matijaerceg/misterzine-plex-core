# Help

[Downloads](https://github.com/matijaerceg/misterzine-plex-core/releases) ·
[Installation](https://github.com/matijaerceg/misterzine-plex-core#install) ·
[Full reference](https://github.com/matijaerceg/misterzine-plex-core/blob/main/docs/REFERENCE.md)

### Before you start

This is unstable beta software. It talks to your real Plex account: playback,
watched marks and resume points change your library, and a bug could change
them wrongly. Use it at your own risk; no responsibility is taken for what it
does to your library or your MiSTer.

### How do I use it?

D-pad moves, OK selects, and Back returns or opens the menu. During playback,
OK opens the controls. The first Back closes whatever is on screen; Back with
nothing on screen stops playback. A second Back within half a second of the
first is ignored, so a double press does not stop the video by surprise. To
leave the app, choose Exit to MiSTer menu near the bottom of the menu.

Video is decoded by the MisterZine Plex H.264 core, which the app loads when it
starts. The screen stays black until the app draws its first menu.

### Why is it asking for another code?

The Plex sign-in code links your account. Early-access releases also need a
six-digit code from that version's Patreon post to play videos. Enter it when
you press Play, or under **Patreon > Beta access** in the menu. It's saved for next time.
Public releases are free and need no playback code.

### Installation or sign-in isn't working

Check the network connection, SD card space and that MiSTer Linux is current
(Python 3.9 or newer). Rerun the installer to repair files; settings are kept.
For an expired Plex sign-in code, request a new one on the sign-in screen.
For a missing server, try **Options > Choose server again**.
If the server cannot be reached but other Plex apps on your network work, set
the server's **Settings > Network > Secure connections** to **Preferred**.
Older builds may have different script names; follow their included instructions.

### The picture looks wrong

The output is chosen in the core's on-screen menu (the MiSTer menu button while
the app runs), not in the app's Options. Start with **Output Mode: 480i60**,
**Refresh Rate Match: Off** and **240p Playback: Off**. **576i50** and
**576p50** are for PAL displays. Progressive 480p and 576p need a display that
accepts them; a normal 15 kHz CRT does not. Refresh Rate Match can switch
between the 50 and 60 Hz families during playback, so turn it on only if your
display accepts both. **Native HDMI** plays video at its own size and leaves
scaling to MiSTer's HDMI scaler.

**Display Shape** in the core's menu selects a 4:3 or 16:9 screen; the app's
screens widen for 16:9. **De-flicker** softens thin horizontal lines on
interlaced output. **Options > Video calibration** lines the picture up with
your screen's edges, and **Options > Video crop** chooses how much of a wide
film's sides to cut.

HDMI scaling follows your MiSTer INI. If it turns on integer scaling
(`vscale_mode`) for every core, the picture may not fill the screen; add a
section for this core to fill it:

```ini
[MisterZine Plex Core]
vscale_mode=0
```

See [HDMI setup](https://github.com/matijaerceg/misterzine-plex-core/blob/main/docs/HDMI.md).

### Playback stutters

Files the core can decode are streamed as stored; everything else is converted
(transcoded) by your Plex server. Try a lower **Video bitrate** in Options, and
check that your Plex server can transcode the video in real time. The steps
below 3 Mbps (2, 1 and 0.4 Mbps) are for weak Wi-Fi; they also make the
transcoded picture smaller, which costs little on a CRT. A file whose video is
above the chosen bitrate is transcoded rather than streamed as stored. If a
stream played as stored falls behind, playback switches once to a transcode at
the same position.

On HDMI, if films stutter or motion judders, look in **Options** below
**Video crop**: the app adds rows for MiSTer INI settings that hurt playback.
**HDMI refresh** means HDMI is held at a fixed rate that the core's Output Mode
or Refresh Rate Match does not keep to, **HDMI sound** means DVI mode (no sound
over HDMI), and **INI section** means a later `[MiSTer]` section overrides the
app's `[MisterZine Plex Core]` section. Select a row for the lines to add. If
24 fps films stutter with variable refresh rate forced on, see
[HDMI setup](https://github.com/matijaerceg/misterzine-plex-core/blob/main/docs/HDMI.md#variable-refresh-rate-vrr-freesync).

### Subtitles are too small or missing

Choose **Options > Subtitle size**, or **More > Subtitle size** in the playback
controls: Normal, Large (150%) or Extra large (200%). Your choice is saved for
future videos.

Text subtitles (SRT, ASS/SSA, WebVTT) are drawn by the app, so the video needs
no transcode for them, and turning them on or off or changing their size does
not restart it. Only the words are shown, without the styling of ASS/SSA
tracks. The first time a track embedded in a large file is asked for, the
server extracts it, which can take a while; the video plays without subtitles
meanwhile.

Picture subtitles (PGS, VobSub) are burned into the video by your Plex server
at the chosen size, so they need a transcode. Turning them on restarts the
stream at the same position, and the server can take a while to start it.
Lettering already embedded in the original video cannot be resized.

### Some videos show blocks or patches of other frames

Videos the core cannot play as stored are converted by your Plex server before
they reach the MiSTer. If rectangular patches of earlier frames linger on
screen, most often with older XviD or DivX `.avi` files, the server's
conversion is damaging the picture. Other Plex apps can look fine because they
often play such files without converting them.

To check, play the same video in Plex Web at a lower quality, such as 2 Mbps,
so the server has to convert it. If the same patches appear, turn off
**Use hardware acceleration when available** under **Settings > Transcoder** on
the Plex server and play it again. Re-encoding the file to H.264 also avoids it.

### How do I update or remove it?

Use **Options > Updates** to install a release, then choose **Restart now** when
ready. Sign-in and settings are kept. If the new version does not start, the
previous one is put back. If you need to go back yourself, return to MiSTer
Menu and run **MisterZine-Plex-Rollback**.

The updater installed with 0.1.0-beta.27 and earlier cannot install the H.264
releases directly. A card on 0.1.0-beta.27 or earlier is therefore always
offered **0.1.0-beta.27.1** first, whenever it updates: the current app and
core packaged so that updater can install them. From there it goes on to the
newest release.

From 0.1.0-beta.28 on, a release installs itself: the updater on the card
fetches and verifies the download, the release's own installer puts it in
place and starts it, and the card's updater only steps in to put the previous
release back if it does not start. Later releases can change what the package
contains without another bridge.

Downloads go through MiSTer Downloader, and fall back to a direct fetch of the
release file when that fails. If both fail, the message under **Options > Updates**
says whether your MiSTer's connection, its clock, its SD card or the release is
the problem. A board whose clock is far off cannot verify any secure site, so
set the time in MiSTer Menu or let it sync over the network. Wait for any
running Downloader or Update All to finish before trying again. The full
reasons are kept in `/media/fat/misterzine-plex/updates/last-error.log` and in
the diagnostics file.

To remove it, return to MiSTer Menu and run **MisterZine-Plex-Uninstall**.
It keeps your settings by default; removing all Plex data requires typing REMOVE.

### Still stuck?

**Options > Send a report** in the app describes your MiSTer to the developer and
shows a short code, such as `K7M4`, to post wherever you asked for help. The
report holds the app and launcher logs, the reasons for connection and update
failures, the video settings read from the MiSTer INI, which MiSTer main is
running and the framebuffer state. It can name media titles and playback
details; sign-in tokens, the server address and account files are never
included, and beta access codes are redacted. Reports go to
`api.misterzine.fyi`, which keeps nothing about who sent them, and are deleted
after 30 days. A copy is always saved as `/media/fat/misterzine-plex/report.txt`.

If the app does not start, **MisterZine-Plex-Diagnostics** in MiSTer Menu writes
and sends the same report and prints the code. If the MiSTer is offline, attach the
saved file to a [problem report](https://github.com/matijaerceg/misterzine-plex-core/issues/new?template=bug_report.yml)
with the version from Options, your MiSTer model, the core's Output Mode and
display connection, the bitrate, whether Plex was transcoding, and what
happened. Don't share account files, tokens or member codes.
