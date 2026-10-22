# Playing video files

The core comes with a video player for files on the MiSTer itself: the SD card, a USB drive,
or a network share. It plays them on HDMI and on the analog output, a CRT included, with their
sound and subtitles. You pick the file with a gamepad.

!!! warning "Up to 720p, and older formats at DVD size"
    The core decodes H.264 up to 1280x720 (720p) at up to 30 frames per second, and DVD-sized
    video at up to 60. Older formats -- MPEG-2 (DVD rips, TV recordings), DivX / Xvid, WMV,
    Theora, Motion JPEG -- play up to DVD size (720x576) at up to 30 frames per second: the
    MiSTer's ARM processor decodes them. Many files from the internet are 1080p or HEVC; the
    player names what it cannot play, and [Compatibility](../reference/compatibility.md#video-files)
    shows how to convert a file on a computer. For your Jellyfin library, use
    [MisterZine Jellyfin](jellyfin.md) instead: your server converts what the core cannot play.

## What plays

| | |
|---|---|
| **Video** | H.264 (High or Main profile, 8-bit) up to 1280x720, any shape: a 720p film or episode, DVD-sized video, a PAL or NTSC recording, a 480p encode. Progressive, or interlaced coded as fields. Every picture is fitted to your screen: on the Interlaced and Progressive outputs to their 480 or 576 lines, on Native (HDMI) shown at its own size |
| **Older video** | Up to 720x576 at up to 30 frames per second: MPEG-1 and MPEG-2 (DVD rips and TV recordings, interlaced ones included), MPEG-4 Part 2 (DivX, Xvid), DivX 3, WMV 7 and 8, Theora, Motion JPEG (cameras), H.263. The MiSTer's ARM processor decodes these; the core shows them as it shows H.264 -- fitted, deinterlaced, in time with the sound |
| **Frame rates** | 23.976 to 60 frames per second (720p: up to 30, in real time up to about 8 Mbit/s; a denser 720p30 encode may play a little behind). A 25 or 50 frames/s file switches the output to 50 Hz when **Refresh Rate** is **Auto** (below) |
| **Files** | `.mkv`, `.mp4`, `.m4v`, `.mov`, `.ts`, `.m2ts`, `.mts`, raw `.264` / `.h264` streams, and for the older video `.avi`, `.divx`, `.mpg`, `.mpeg`, `.vob`, `.m1v`, `.m2v`, `.wmv`, `.asf`, `.ogv`, `.3gp` |
| **Sound** | AAC, AC-3 (Dolby Digital), E-AC-3, DTS, MP3, MP2, Opus, Vorbis, FLAC, LPCM, WMA, ADPCM -- surround mixed down to stereo |
| **Subtitles** | Text subtitles inside the file (SRT, ASS, MP4 text, WebVTT), or an `.srt` file beside it with the same name (`Film.srt` or `Film.en.srt` for `Film.mkv`) |

H.264 from phones and webcams (Baseline profile) plays too: the player converts it for the core
as it plays, which keeps up to about 4-5 Mbit/s at 480p, 60 frames/s.

What does **not** play: 1080p and 4K video, 720p at 50 or 60 frames per second, HEVC (H.265), AV1, VP8 / VP9, VC-1 / WMV9,
the older formats above DVD size or above 30 frames per second, 10-bit H.264 (common for anime), and interlaced H.264 coded as
MBAFF (most TV recordings). The player shows **Cannot play** and the reason; see
[Compatibility](../reference/compatibility.md#video-files).

Picture subtitles (DVD and Blu-ray subtitles) are not shown. A Dolby TrueHD track is silent:
press Y for another audio track.

## Installing

MisterZine Jellyfin releases do not include the player: build it and copy its
`Scripts/h264player.sh` and `h264player/` folder to the root of the SD card (`/media/fat/`), with
the core in `_Other/` ([The other programs](../getting-started/install.md#the-other-programs)).

## Where the videos go

The player shows these folders:

| Folder | |
|---|---|
| `/media/fat/video` | on the SD card (made the first time the player runs) |
| `/media/usb0` ... `/media/usb7` | a USB drive, while one is plugged in |
| `/media/fat/cifs` | a network share mounted by MiSTer's `cifs_mount` script |

To show other folders instead, create `/media/fat/h264player/h264player.ini` with a `root=` line
for each:

```ini
root=/media/fat/video
root=/media/usb0/Films
```

## Playing something

Run **Scripts** → **h264player** from the MiSTer menu. The core loads and shows the folders.
Choose a folder, then a file:

| Gamepad | Keyboard | In the list |
|---|---|---|
| Up / Down (hold to scroll) | Up / Down | move |
| LB / RB | Page Up / Page Down | a page up / down |
| A, Start, Right | Enter, Space, Right | open the folder, or play the file |
| B, Left | Esc, Backspace, Left | back to the folder above |
| Back + Start | Q | quit to the MiSTer menu |

When a file ends, the next one in the folder plays. After the last one, or if a file cannot play,
the list comes back. The next time you run the player, it starts in the folder you were in.

While a file plays:

| Gamepad | Keyboard | |
|---|---|---|
| A, Start | Space, Enter, K | pause / play |
| Left / Right | Left / Right | back 10 seconds / forward 30 seconds |
| LB, Down / RB, Up | Page Down / Page Up | back / forward 5 minutes |
| X | S | the next subtitle track (or off) |
| Y | A | the next audio track |
| B | I | show the title and progress |
|  | N / P | the next / previous file in the folder |
| Back + Start | Esc, Q | stop, back to the list |

**Seeking** adds up: tap Right three times, or hold it, and the panel shows where you are going;
the file jumps there once you stop pressing. The picture stays on screen, frozen, until it starts
again (the panel says **Loading**). A raw `.264` stream cannot seek.

**Subtitles** start on when the file has an `.srt` beside it, or marks a subtitle track as its
default. X steps through the file's text tracks, then the `.srt`, then off.

**Send Home to the program** in the MiSTer menu stops the file; **Program menu** shows the title
and progress ([Settings](settings.md)).

## The screensaver

After 5 minutes without a button press while nothing plays (in the list, or with a file
paused), the screen dims. A line of text fades in and out at different places, saying what is
up: the folder, or the paused file and where it stopped. After 30 minutes the screen goes
black, with the same line. This protects OLED, plasma and CRT screens from burn-in.

Any button brings the screen back; that press does nothing else. To change the times, put
these lines in `/media/fat/h264player/h264player.ini` (minutes; 0 turns a step off):

```ini
screensaver_dim=5
screensaver_black=30
```

## 50 Hz video

With **Refresh Rate** on **Auto** (the default, [Settings](settings.md)), the player switches the
output to 50 Hz for a 25 or 50 frames/s file, PAL or 576i on a CRT. It switches back to Auto for
a file at another rate and when you quit. While such a file plays, the menu shows **50 Hz**.
A Refresh Rate you choose yourself is left alone.

## If it does not work

The player writes what it did to `/media/fat/h264player/h264player.log`. See
[Troubleshooting](../reference/troubleshooting.md#video-files).
