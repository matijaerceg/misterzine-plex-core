# Playback

The Go app handles the Plex session and the on-screen controls. It starts
`jfplay`, a small playback worker that sends video and audio to the MiSTer
H.264 core. The file is streamed as stored when the core can certainly play
it, and the Plex server transcodes it otherwise.

## Starting playback

When playback starts, the app reads the item's first media version and file
(its part) from `/library/metadata`, with the streams the server probed. When
the chosen audio track is not the part's selected one, the app selects it on
the server first, because a transcode follows the part's selected streams.

Unless a subtitle must be burned in, the app then checks the file's video
against the core's own limits: H.264 High or Main, level 4.1 or lower, 8-bit,
CABAC entropy coding, at most 1280x720, at most 30 frames per second above
854 pixels wide (60 at or below), and an average bitrate of at most 6 Mbit/s
above 854 pixels wide (8 Mbit/s at or below). It also checks the video bitrate
against the **Video bitrate** setting: the setting is there for a link that
cannot carry more, so a file whose video is above it is never streamed as
stored. A value the server does not report is not held against the file. A
file that fits is streamed directly: `jfplay` opens the file on the server
(`/library/parts/...`) as stored.

Otherwise the app asks the server's universal transcoder for a decision
(`/video/:/transcode/universal/decision`) and plays its progressive Matroska
stream (`start.mkv`) over HTTP. The request asks as the Plex Web client, with
extra profile lines that hold the transcode to the core's limits: H.264 High
or Main, level 4.1, 8-bit, at the **Video bitrate** setting (8 Mbit/s at
most), and stereo AAC audio, so the server downmixes surround sound. The
bitrate steps below 3 Mbit/s also make the transcode smaller, so a low bitrate
is spent on fewer pixels: at most 854x480 below 3 Mbit/s and 640x360 below
1 Mbit/s; 1280x720 otherwise. Above 854 pixels wide, a 50 or 60 frames per
second source is asked for at half its rate (25 or 29.97). When the server
refuses to transcode, playback fails with the server's reason.

One transcode session ID serves a whole playback. A seek, a track change or a
restart asks for a new decision on the same session, and the server replaces
its transcoder. Leaving playback ends the session on the server
(`/video/:/transcode/universal/stop`).

Plex's metadata cannot report every property the core depends on (CAVLC
versus CABAC when the server does not know, MBAFF versus field-coded
interlace). MBAFF is refused and field-coded interlace is accepted; the app
logs an interlaced direct stream and lets `jfplay` decide. `jfplay` checks a
direct stream's parameter sets before the first picture is shown. If the check
fails, the core refuses the stream, or the core keeps falling behind for
several seconds, the app restarts the item once as a transcode at the current
position. The switch is recorded in the playback log and is not shown as an
error.

The app passes the token and its client identifier to `jfplay` as request
headers; stream URLs never carry the token, and the playback log redacts it.
The app hides its overlay while the video is playing. The worker status file
supplies playback position and state; the app reports start, progress every
ten seconds (playing or paused), and stop to the server through
`/:/timeline`. A playback stopped at 90% or more marks the item watched.

## Controls and seek

Pause and resume are sent to `jfplay` through its control FIFO. For a direct
stream, a capable worker can seek without reopening the file. The app waits
for a matching seek acknowledgement while input and rendering continue. A
transcode, an older worker, and a failed or timed-out seek use the
process-restart fallback: stop and reap the worker, then start at the target.
A direct restart reuses its URL; a transcode restart asks the server for the
stream at the new offset. Container start timestamps are included when
seeking. Seeks can still interrupt the picture while the decoder starts from
a keyframe.

The compressed forward queue is bounded by 64 MiB, 8,192 packets, and a
45-second read-ahead horizon when timestamps are known. A nearby forward seek
can reuse queued packets when both streams cover a confirmed H.264 IDR within
one second of the target, before or after it. The closest eligible IDR is used,
and must advance beyond the current position. Other seeks use the demuxer;
backward history is not retained. Network speed, server transcoding speed, and
keyframe spacing determine whether a fast-path hit is possible. Neither path
promises frame-exact seeking or instant startup.

The playback progress bar shows verified buffered audio/video coverage in pale
purple, with played video in the normal purple. It does not infer a video range
from the audio-only queue, and clears unavailable coverage during seeking.
Buffered coverage indicates downloaded media, not a guarantee that every point
within it has a suitable keyframe for a fast seek.
Seeking or changing audio while paused keeps the replacement paused. Resume
continues playback; it does not automatically start because a stream restarted.

On initial playback and Resume, the loading UI covers the retained previous
picture with opaque black until a new picture is shown. The session handshake
keeps that cover in place until the core acknowledges its display reset.

Stopping also asks the worker to exit and reports the final position to the
server. If the stream ends normally, the app treats it as completed and can
continue to the next episode. Worker errors are shown as a short playback
notice.

The playback **More > Crop** setting offers **Off**, **14:9**, and **Fill** for
applicable wide-screen content. Off asks the core to letterbox; 14:9 zooms
wide pictures toward a 14:9 window, trimming less of the sides than Fill and
leaving small bars; pictures at or narrower than 14:9 stay whole. Fill crops
the picture to fill the analog display. The choice is sent when a worker starts
and can be changed live while playback continues. The app keeps the selected
value for the current playback. 14:9 uses custom geometry on cores with HPS
interface 1.2 or later; older cores safely show the full picture as Off does.

**Options > Video calibration** saves the screen edges and width correction for
the current display. Playback uses those values only when the running H.264
core advertises the additive 1.2 geometry interface, as the core shipped with
the app does. On older cores the screen is labeled **Video calibration
(preview only)** and playback remains unchanged; the saved values are
retained. Geometry is separate from the crop setting and is limited to fitted
480- or 576-line output; Native HDMI output is not supported.

De-flicker is an option of the core's OSD, not of the app: on interlaced
output it softens thin horizontal detail in frame-based video and in the app's
screens so it flickers less between fields. It is On by default. Video recorded
as interlaced fields is not filtered. The app does not pass `jfplay` an
Anti-Twitter request, so the OSD choice stays in force during playback.

## Audio and subtitles

Audio is decoded by `jfplay` and downmixed to stereo PCM for the core. Audio
changes during playback restart at the current position. A direct stream
passes the selected track's index in the file to the worker; a transcode
carries the track selected on the server.

**Surround downmix boost** is available in Options and playback More, with Off,
Small (175%), and Large (300%) settings. The worker applies it, and the server's
own downmix in a transcode is asked for at 100%, so the gain is never applied
twice. The worker boosts only a known surround source, including one the server
has already downmixed to stereo, and soft-limits peaks before output. Stereo
sources are unchanged. Changing boost during playback does not restart the
stream; audio already queued may retain its previous gain briefly. The separate
worker volume control only attenuates sound.

Text subtitle tracks (SRT, ASS/SSA, WebVTT and the other text formats the
server serves as a file of their own) are drawn by the app. It fetches the
whole track from `/library/streams/<id>`, asked for as UTF-8 SRT so the server
converts other text formats, keeps the cue text only (styling, positioning and
ASS effects are dropped) and draws the cues as white type on a translucent box,
centred along the bottom of the safe area. The stream is requested without
them, so it can still play as stored, and choosing another text track or Off
changes the overlay without restarting the stream. Cue times follow the
worker's reported position and run on from its last report while playing. The
subtitles show while nothing else is on the overlay: the controls, a list, the
seek strip, the skip button and the wait dots replace them while they are up.
They are drawn over the picture, so cropping does not cut them.

**Subtitle size** in Options and playback More offers Normal, Large (150%) and
Extra large (200%). For drawn subtitles, Normal is 22-pixel type on the
480-line overlay; long lines wrap within the safe area, and at most six lines
show at once. A change applies from the next subtitle painted, without a
restart.

Picture subtitles (PGS, VobSub, DVB), and text tracks the server does not
serve as a file, are burned into the video by the server. The app requests a
transcode with that track selected on the part and the subtitle size;
changing the size of a burned-in track starts the transcode over. The overlay
fonts cover ASCII; Latin letters with accents (Latin-1 and Latin Extended-A)
are drawn as their base letters. A text track in which more than one letter in
twenty falls outside them (Cyrillic, Greek, Arabic, CJK and other scripts) is
handed back to the server to burn in as well, with one restart, and is burned
in from the start for the rest of the app's run. Cropping can cut burned-in
subtitles. Changing to or from a burned-in track restarts the stream; track
changes preserve the position and pause state.

## Worker interface

`jfplay` accepts a direct stream or transcode URL, request headers, an optional
base time and in-file seek, volume, audio stream index, control FIFO, status
file, analog aspect, the core's file and name (`--rbf`, `--core-name`), and (on
capable core versions) saved video geometry. With `--core-name` it treats a
core reporting that name, or the upstream name `H264`, as its own. The app
passes saved geometry only when the running core reports interface 1.2 or
later. Its full command line and status/control contract are documented in
[`arm/jfplay.md`](../arm/jfplay.md). Seeks go to the running worker as `seek`
commands; when it cannot seek in place, the app restarts it with an in-file
seek for direct streams and a new offset for transcodes.
