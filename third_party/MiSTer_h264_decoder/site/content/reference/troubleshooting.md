# Troubleshooting

| Symptom | What to check |
|---|---|
| Nothing on screen after loading the core | Try another HDMI mode or display; check that the rest of the MiSTer's video works. If the analog output also shows nothing, [report it](reporting-a-bug.md) with the core version. |
| The screen stays black before the app menu appears | The core has no startup image. If the menu does not appear, check the app launcher log and launch the installed MisterZine Jellyfin menu entry again. |
| A program cannot reach the core (its log says "Protocol not supported") | The program was built for a newer core than the one on the SD card: a program accepts a core of its own interface version or later. Build the core and the programs from the same source ([Install the core](../getting-started/install.md#the-other-programs)). "Device or resource busy" means another program is using the core: quit it first. |
| The screen stays black after a video played | The program stopped sending video after a stream switch or a seek. Restart the program; its log says what happened. |
| A stream does not play and the status block shows a refusal | The stream uses something the core does not decode: CAVLC, MBAFF interlacing, monochrome, 4:2:2 / 4:4:4, 10-bit or lossless coding ([Compatibility](compatibility.md)). The program's log names it. A program can rewrite CAVLC into CABAC with the client library ([CAVLC streams](../integrating/library.md#cavlc-streams)); the Moonlight client and the video player do; MisterZine Jellyfin does not (it checks the stream first and asks the server for a transcode instead). |
| A CAVLC stream plays with late or dropped pictures | The program rewrites it into CABAC on the ARM, which keeps up to about 4-5 Mbit/s at 480p60; ask the source for a lower bitrate, or for CABAC ([CAVLC streams](../integrating/library.md#cavlc-streams)). |
| A 60 frames/s stream plays with dropped frames | The core decodes up to 854x480 at 60 (or 1280x720 at 30) frames/s in real time; a larger picture or a higher rate falls behind, and the late pictures are counted in the status block ([Compatibility](compatibility.md)). |
| A 720p film or transcode at 30 frames/s plays a little jerky | A very dense 720p30 encode (well above 8 Mbit/s: a high-bitrate file or transcode) can be more than the decoder keeps up with; up to about 8 Mbit/s, 24 and 30 frames/s films, transcodes and game streams play in real time. Choose a lower bitrate or 854x480 for the transcode, or convert the file ([Compatibility](compatibility.md)). |

## Moonlight

The client's log is `/media/fat/moonlight/moonlight.log`
([Streaming from a PC](../using/moonlight.md)).

| Symptom | What to check |
|---|---|
| **Scripts → moonlight** says "Could not reach" the PC | `host=` in `moonlight.ini` is the PC's address, Sunshine is running on it, and the PC's firewall lets Sunshine's ports through. |
| The pairing PIN is not accepted | Type it into Sunshine's web page (**PIN**) within a minute of running the script, then run the script again. |
| It says the PC has no such app | Set `app=` to one of the names the script lists (as written, spaces included). |
| The stream starts, then the MiSTer returns to its menu | The log's last lines say why. "the core refused the stream" names what the core does not decode; a host that refused the app says so too; "Couldn't find monitor" in Sunshine's own log means the PC could not capture its display that moment -- try again. |
| The log says "the stream cannot be given to the core", or the picture is late and jerky with "rewritten from CAVLC" in the log | The PC's encoder is set to CAVLC (Sunshine's `nvenc_h264_cavlc`, `amd_coder` or `qsv_coder`). The client rewrites CAVLC for the core, but only up to about 4-5 Mbit/s: set the encoder back to its default (CABAC), or lower the bitrate. |
| The picture has black bars on every side | `width`/`height` are set to a shape that is neither your screen's nor the PC desktop's: leave both empty (the screen's shape). |
| The PC shows the wrong screen | Sunshine streams one of the PC's displays: choose it in Sunshine's settings (**Audio/Video** → the display). |
| Keys or buttons do nothing on the PC | Close the MiSTer menu: nothing is sent while it is open. The log says "input paused" / "input resumed" as it opens and closes. |
| LS, RS, LT or RT does nothing on the PC | Some controllers need them mapped: assign them with **Define H264 buttons** in the OSD's system settings ([Controls](../using/controls.md#gamepads)). |
| A gamepad's buttons are mixed up on the PC (A and B swapped, X and Y swapped) | Remap them with **Define H264 buttons**: A is the bottom face button, B the right, X the left, Y the top. |
| A gamepad does not rumble | Press one of its buttons once after connecting it (MiSTer drives the motors of a pad it has given a player number). Check `RUMBLE=1` in `MiSTer.ini` (the default) and that the game rumbles on the PC. Some gamepads have no motors, or none MiSTer can drive. The log's last line counts the rumble changes the client passed on. |

## Jellyfin

MisterZine Jellyfin has its own help
([Watching from a Jellyfin server](../using/jellyfin.md)). Its
[troubleshooting](https://github.com/matijaerceg/misterzine-jellyfin/blob/main/release/README.md#troubleshooting)
covers installing, signing in, stutter, updates and reports. In the app, **Options** →
**Send a report** saves the app's and the player's logs to
`/media/fat/misterzine-jellyfin/report.txt`; **Scripts** →
**MisterZine-Jellyfin-Diagnostics** writes the same file when the app does not start.
These rows are about the picture the core receives:

| Symptom | What to check |
|---|---|
| A film stutters or falls behind | The server's conversion is not keeping up: its dashboard shows the transcode's speed. A lower **Video bitrate** in the app's Options also helps. |
| Faint blocky lines across the picture during fades and dark scenes, on a film the server converts | Artifacts of the server's conversion (common with HEVC or HDR films): dark fades are hard to encode, and the MiSTer shows what it receives. In the server's dashboard (**Playback** → **Transcoding**), choose a slower encoder preset or a higher quality for hardware encoding, and turn on tone mapping for HDR films. A film already in H.264 at 1280x720 or less is played as it is, with no conversion ([What plays](../using/jellyfin.md#what-plays)). |

## Video files

The player's log is `/media/fat/h264player/h264player.log`
([Playing video files](../using/player.md)).

| What you see | What to do |
|---|---|
| **Scripts → h264player** says the player is not installed | Copy `h264player/` from the player's build to `/media/fat/` ([Install the core](../getting-started/install.md#the-other-programs)). |
| "No video folders" | Put videos in `/media/fat/video` (the player makes it), plug in a USB drive, or list your folders in `h264player.ini` with `root=` lines. |
| A file is missing from the list | The list shows only the file types the player opens -- `.mkv`, `.mp4`, `.m4v`, `.mov`, `.ts`, `.m2ts`, `.mts`, `.264`, `.h264`, `.avi`, `.divx`, `.mpg`, `.mpeg`, `.vob`, `.m1v`, `.m2v`, `.wmv`, `.asf`, `.ogv` and `.3gp` -- and no hidden ones (names starting with a dot). |
| "Cannot play: 1920x1080 is larger than 720p" (or another size) | The core decodes pictures up to 1280x720 (3,600 macroblocks). Convert the file ([Compatibility](compatibility.md#converting-a-file)). |
| "Cannot play: 1280x720 at 60 frames/s is too fast" | The core decodes up to 1280x720 at 30 or 854x480 at 60 frames per second; a 720p file at 50 or 60 would play at half speed. Convert it to 854x480, keeping its frame rate ([Compatibility](compatibility.md#converting-a-file)). |
| "Cannot play: 10-bit H.264", "MBAFF interlaced H.264", "4:2:2, 4:4:4 or monochrome H.264", "CAVLC H.264 the rewrite cannot carry: ..." | H.264 the core does not decode. Convert the file ([Compatibility](compatibility.md#converting-a-file)). |
| A phone or webcam video plays late or jerky | It is Baseline (CAVLC) H.264, which the player converts as it plays; that keeps up to about 4-5 Mbit/s at 480p60. Convert the file ([Compatibility](compatibility.md#converting-a-file)). |
| "Cannot play: the video is HEVC (H.265): the MiSTer cannot decode it" (or another format) | The core decodes H.264, and the ARM the older formats (MPEG-2, DivX / Xvid, WMV 7 / 8, Theora, Motion JPEG, H.263); not this one. Convert the file ([Compatibility](compatibility.md#converting-a-file)). |
| "Cannot play: MPEG-2 1280x720 is larger than SD (720x576): too much for the ARM" | The older formats are decoded by the MiSTer's ARM processor, which keeps up only to DVD size. Convert the file to H.264 ([Compatibility](compatibility.md#converting-a-file)). |
| "Cannot play: MPEG-4 Part 2 (DivX / Xvid) at 59.94 frames/s is too fast for the ARM (30 at most)" | Likewise: at most 30 frames per second. Convert it to H.264. |
| "Cannot play: MPEG-2 in yuv444p: only 8-bit 4:2:0 and 4:2:2 are shown" | A picture format the core does not show. Convert the file. |
| A file plays with no sound | Its track is one the player cannot decode (Dolby TrueHD): press Y for another track, or convert the sound with `-c:a aac`. |
| A PAL (25 frames/s) file judders | Set **Refresh Rate** to **Auto** ([Settings](../using/settings.md)): the player then switches to 50 Hz for it. On HDMI, 50 Hz needs `vsync_adjust` in `MiSTer.ini` to be smooth. |
| Subtitles do not show | Press X: the file may have them off by default. Picture subtitles (DVD / Blu-ray) are not shown. An `.srt` must have the video's name: `Film.srt` or `Film.en.srt` beside `Film.mkv`. |

## USB cameras

The viewer's log is `/media/fat/h264cam/h264cam.log` ([Showing a USB camera](../using/camera.md)).

| What you see | What to do |
|---|---|
| **Scripts → h264cam** says the viewer is not installed | Copy `h264cam/` from the viewer's build to `/media/fat/` ([Install the core](../getting-started/install.md#the-other-programs)). |
| **Scripts → h264cam** says "Another H264 program (h264player) is running: quit it first." (or moonlight, jellyfin) | That program is using the core: quit it (Back + Start), then run h264cam again. |
| "Plug in a USB camera or video capture device" stays on the screen with a camera plugged in | The camera is not a USB Video Class (UVC) device, or it needs more power than the port gives: try a powered USB hub. The log says when a device is found. |
| "... cannot be shown: it sends only uncompressed video ..." | A capture device or camera without Motion JPEG. The MiSTer's USB port carries about 6 MB/s of live video: only its smallest modes would fit, and it has none. Use a camera or capture device that sends MJPEG. |
| "... cannot be shown: its video is H.264 only ..." | A camera that sends only H.264: not supported. |
| "Camera unplugged" | The camera stopped sending (unplugged, or it lost power). Plug it back in: the picture comes back by itself. |
| The picture is dark | The viewer keeps the camera at its full frame rate, so it cannot lengthen its exposure in a dark room. Add light. |
| The picture is soft | The camera's mode is small (the viewer shows 720x576 at most), or you chose a smaller one: press B for the list of modes. |

## The screen dims or goes black

The [video player](../using/player.md#the-screensaver) and the
[camera viewer](../using/camera.md#the-screensaver) dim the screen after 5 minutes while
nothing plays, and turn it black after 30, against burn-in. Press any button to bring it back.
The player's times are in its `.ini` (`screensaver_dim=`, `screensaver_black=`).

[MisterZine Jellyfin](../using/jellyfin.md#the-screensaver) dims the screen to a quarter of
its brightness after 3 minutes without a press in the menus or on a paused video, and does
not turn it black. The next press only brings it back.
