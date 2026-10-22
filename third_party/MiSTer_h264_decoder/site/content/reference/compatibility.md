# Compatibility

Current as of: release 1.1.0.

| | Status |
|---|---|
| Test pattern on HDMI and analog | Works |
| Output signals: 480p, 480i (15 kHz, composite sync with equalizing pulses), at 59.94 or exactly 60 Hz; 576p / 576i (PAL) at 50 Hz | Work; the rate follows the stream on Auto. Checked on NTSC CRTs and through a RetroTINK; 576i has not been checked on a PAL CRT |
| Native (HDMI): the core's signal at the video's own size, up to 2,048 pixels a side | Works on HDMI; Video Output's Auto picks it unless `MiSTer.ini` sets up an analog display ([Video output](../video/output.md)) |
| The interface for programs (version 1.4) | Works: a program on the MiSTer plays H.264 through it ([Integrating a program](../integrating/overview.md)); frozen at 1.0: a program built for 1.0 runs on every later 1.x core, one built for a later version needs a core of that version or later |
| H.264 decoding, Main profile | Works, pictures up to 3,600 macroblocks (for example 1280x720, 720x576, 720x480, 854x480, 640x480), any aspect ratio |
| H.264 decoding, High profile (what a stock Moonlight / Sunshine host sends): the 8x8 transform, 8x8 intra prediction, scaling matrices | Works, pictures up to 3,600 macroblocks (1280x720), 8-bit 4:2:0 |
| High profile variants: monochrome (4:0:0), 4:2:2, 4:4:4, 10-bit, lossless | Refused (the refusal is shown in the status block) |
| CAVLC streams (Constrained Baseline phone video, x264's `ultrafast` preset) | Refused by the core, but the client library's write calls [rewrite them into CABAC](../integrating/library.md#cavlc-streams) and they play bit for bit, in real time up to about 4-5 Mbit/s at 480p, 60 frames/s (the ARM's CPU is the limit): `h264play`, the Moonlight client and the [video player](../using/player.md) play them so; **MisterZine Jellyfin does not send them** (it checks the stream first and asks the server for a transcode instead). Slice groups, arbitrary slice order, redundant pictures and data partitioning (Baseline / Extended features) are refused |
| Video the program decodes itself, handed over as pictures (MPEG-2, MPEG-4 Part 2, Motion JPEG, ...; [Pictures you decode](../integrating/pictures.md)) | Standard definition (up to 720x576) at up to 30 frames/s in practice: the ARM's one free core decodes and copies each picture (the copy alone about 5 ms at 720x480). The interface takes pictures up to 1280x720, but a software decoder on the ARM does not keep up at that size. 8-bit 4:2:0 or 4:2:2, limited or full range; other formats converted by the program first. A stream is pictures or H.264, not both |
| H.264 at 480p, 23.976-29.97 frames/s | Real time |
| H.264 at 480p, 59.94-60 frames/s, 720x480 or smaller | Real time (measured on Sunshine-shaped High profile streams at up to 10 Mbit/s) |
| H.264 at 854x480, 60 frames/s | Real time at 8 Mbit/s at the encoder (a 10 Mbit/s game-stream request) with about 55 % to spare (the decoder idle 36 % of the time); a much denser stream may fall behind (late pictures are counted in the status block) |
| Pictures other than 720x480 (for example 640x480, 854x480, a transcode such as 720x404, or a portrait picture such as 480x854 from a phone) | Decoded and fitted to the screen at their true shape (the stream's cropping and pixel shape), with black bars; on a CRT the Analog Aspect setting chooses Letterbox, Crop or Fit. Any size up to 3,600 macroblocks (1280x720), up to 2,048 pixels on a side. On HDMI, Video Output **Native (HDMI)** shows them at their own pixel size instead -- 1280x720 included -- scaled once by HDMI's scaler |
| A picture coded as separate fields (interlaced video) at a size that needs scaling | Shown with its two fields woven (moving edges can comb); at 720x480 on the Progressive output the Deinterlace setting applies as usual |
| Interlaced video (field pictures) | Decoded; shown per the [Deinterlace](../using/settings.md) setting |
| Low latency (game streaming: each picture shown as soon as it is decoded) | Works (a source faster than the display drops the older pictures, counted) |
| Audio | 48 kHz 16-bit stereo PCM from the program (it decodes any codec its libraries support), played in sync with the pictures, or as it arrives for a game stream; pause and volume from the program ([Audio](../integrating/audio.md)) |
| A stream with an occasional wrong time stamp (a lone one, up to 0.5 s off) | Shown smoothly on its normal timing; the next time stamp is always believed ([Time stamps](../integrating/interface.md#time-stamps)) |
| The MiSTer's keyboard, mouse and gamepads (for a program such as the Moonlight client) | Passed on through the core ([Controls](../using/controls.md)) |
| Gamepad rumble from a program (a game's rumble through the Moonlight client) | Played on the user's pad by MiSTer: two motors per pad, six pads; no trigger rumble ([Rumble](../integrating/interface.md#rumble)) |
| Anti-twitter for interlaced CRTs | Works: on Auto (the default) for game streams and the programs' own screens, or On / Off for everything |
| Colour: the stream's own matrix and range | BT.601, BT.709 and BT.2020 (non-constant luminance), limited or full range, from the stream's tags; a stream without tags is BT.601 at standard definition and BT.709 from 1280 wide or 577 high. Not converted: the colour primaries and transfer (a BT.2020 or HDR picture shows undersaturated), and the rare GBR / YCgCo matrices (shown as untagged; counted in the status block). Colour detail (stored at half resolution) is rebuilt smoothly on every output at the stream's own chroma siting (`chroma_sample_loc_type`, all six types); pictures a program decodes itself are taken as the default siting |
| H.264 at 720x576, 25 / 50 frames/s | Real time (50 frames/s at 720x576 is the same load as 720x480 at 60) |
| H.264 at 1280x720 (720p), 23.976-30 frames/s | Decoded and fitted to the screen on 480i, 480p and 576 (a 720p picture adds no detail on these 720-wide pictures, but plays without converting); on HDMI with Video Output **Native (HDMI)** shown at its own 1280x720, sharp on a 720p or 1080p HDMI mode. Real time for game streams (about 1.3x at a 10 Mbit/s request), and for films and transcodes with B-frames up to about 8 Mbit/s (measured: 30 frames/s at 8 Mbit/s about 1.13x, 24 frames/s at 8 Mbit/s about 1.27x); a denser encode may fall behind, its late pictures counted in the status block |
| H.264 at 1280x720, 50 / 60 frames/s | Not real time (twice the decoder's rate): refused by the video player and the Moonlight client; decoded slowly if a program sends it anyway |

The target is H.264 **High profile** streams (what a stock Sunshine host sends; Main
profile too) of any size up to 3,600 macroblocks per picture (1280x720), in real time up to
854x480 at 60 or 1280x720 at 30 frames per second (met at 854x480 with about 55 % to spare; at
1280x720 for game streams, films and transcodes up to about 8 Mbit/s) at the bitrate of a Moonlight
session at 10 Mbit/s, whatever service sends them (a game-streaming host, a Jellyfin / Plex transcode,
a remote-play console at 640x360); higher rates will still play correctly, but may drop
frames when the decoder falls behind. Streams the decoder does not support are
refused, never shown as garbage.

## Video files

What the [video player](../using/player.md) plays from the SD card, a USB drive or a network
share. The core decodes the video, so the limits above apply to every file:

| | Plays | Does not play |
|---|---|---|
| Video | H.264 High or Main profile, 8-bit 4:2:0; up to 3,600 macroblocks a picture (1280x720, 854x480, 720x576, 720x480 and smaller, any shape) at up to 30 frames/s for 720p, 60 for 480p; progressive or field-coded interlaced. Baseline / CAVLC H.264 (phones, webcams, old iPod files) too, converted as it plays: in real time up to about 4-5 Mbit/s at 480p60 | 1080p and up; 720p at 50 / 60 frames/s; HEVC / H.265, AV1, VP8 / VP9, VC-1 / WMV9; 10-bit H.264; 4:2:2 / 4:4:4; MBAFF interlaced H.264 (most interlaced recordings); Baseline features no other profile has (slice groups, arbitrary slice order, redundant pictures) |
| Older video (decoded by the ARM) | MPEG-1, MPEG-2 (interlaced included), MPEG-4 Part 2 (DivX, Xvid), DivX 3, WMV 7 / 8, Theora, Motion JPEG, H.263 -- up to 720x576 at up to 30 frames/s, 8-bit 4:2:0 or 4:2:2 | the same formats above 720x576 or 30 frames/s (the ARM's budget: one core, with the picture's copy into the core); 4:4:4 or 10-bit pictures |
| Sound | AAC, AC-3, E-AC-3, DTS (core), MP3, MP2, Opus, Vorbis, FLAC, LPCM, WMA, ADPCM; mixed down to stereo | Dolby TrueHD (silent: pick another track), ALAC |
| Files | `.mkv`, `.mp4`, `.m4v`, `.mov`, `.ts`, `.m2ts`, `.mts`, `.264`, `.h264`; for the older video also `.avi`, `.divx`, `.mpg`, `.mpeg`, `.vob`, `.m1v`, `.m2v`, `.wmv`, `.asf`, `.ogv`, `.3gp` | `.flv`, `.webm`, `.rmvb` |
| Subtitles | Text: SRT, ASS / SSA (plain text, without styling), MP4 text, WebVTT, inside the file or an `.srt` beside it | Picture subtitles (DVD VobSub, Blu-ray PGS, DVB) |

A raw `.264` / `.h264` stream plays without seeking, position or sound.

### Converting a file

Any file the player refuses can be converted on a computer with [ffmpeg](https://ffmpeg.org) to
one it plays, keeping its shape inside 854x480 (the lightest for the core, and all a 480-line
screen shows):

```sh
ffmpeg -i input.mkv -map 0:v:0 -map 0:a -map 0:s? \
  -c:v libx264 -profile:v high -pix_fmt yuv420p -crf 20 -preset slow \
  -vf "scale=w=854:h=480:force_original_aspect_ratio=decrease:force_divisible_by=2" \
  -c:a copy -c:s copy output.mkv
```

`-c:a copy` keeps the sound as it is; use `-c:a aac -b:a 192k` for a TrueHD or other track the
player cannot decode. A 720x576 PAL source can keep its size: replace the `scale` filter's box
with `w=720:h=576`. A 1080p film at 24-30 frames/s may become 720p instead (`w=1280:h=720`); a
50 / 60 frames/s source must stay inside 854x480.

## USB cameras

What the [camera viewer](../using/camera.md) shows: USB Video Class (UVC) cameras and capture
devices, decoded by the MiSTer's ARM processor.

| | Works | Does not work |
|---|---|---|
| Video | Motion JPEG (most webcams) up to 720x576 at up to 30 frames per second; uncompressed (YUY2) up to about 6 MB/s (320x240 or 352x288 at 30 frames per second) | larger or faster modes (not offered); uncompressed video above 6 MB/s (the MiSTer's USB port loses most of its frames); H.264-only cameras |
| Tested | Logitech C270 (640x480 MJPEG at 30 frames per second), on a MiSTer whose ports sit behind two USB 2.0 hubs; the 6 MB/s was measured there, a port without hubs was not tried | |
| Sound | -- | a camera's or capture device's microphone or audio input |
