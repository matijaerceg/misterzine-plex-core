# jfplay

`jfplay` is the small, non-interactive playback worker between the app and the
MiSTer H.264 core. It knows no media server: it is given a URL and the request
headers to send with it. The Go application chooses the media; this process opens the
supplied stream, feeds H.264 and decoded PCM to the core, accepts live controls,
and reports progress. Seeks pause the demux reader, reset the core and decoder
queues, then seek the existing media context in place. This avoids process
startup and stream probing on each seek. For a short forward skip, the worker
can reuse compressed audio/video packets it already retained; otherwise the
demuxer may still need to read from the network before it can provide the next
keyframe.

The demux reader runs separately from the core writer.  It puts compressed
video and audio packets into bounded queues, while the main thread converts and
tries to write records without ever blocking inside the ring library.  Decoded
audio is also bounded to 96,000 stereo frames (about two seconds).  When either
the local audio queue or the ring is full, jfplay leaves compressed audio in
the reader queue, services controls, and sleeps briefly as needed. Video
records stay within 100 ms of submitted audio, including while the demuxer
is fetching the next audio packet. This keeps a burst of video from placing
its matching audio too far back in the shared ring. Known audio timestamp
gaps, the end of the stream, and a blocked reader can release this gate when
less than one complete PCM record remains, so sparse audio cannot deadlock
the bounded queues. Streams without audio do not use this gate.
Compressed queues are capped at 64 MiB, 8192 packets, and 45 seconds ahead of
the current playback point (whichever bound is reached first).

## Menu navigation audio

`jfplay --menu-audio` runs the menu click worker without opening media or loading
an FPGA core. The Plex app also passes `--core-name` with its own core name. The process takes the normal exclusive ring lock, opens an audio-only session,
and sends one silent 28 ms PCM record to start the presentation clock. It writes
`ready` followed by a newline to stdout once that record has played (about one
second). After readiness, each command is a newline-terminated stdin line:

- `tap` plays a synthesized click at the Loud level with one of five nearby
  pitches, never repeating the previous random pitch.
- `tap LEVEL MIDI` selects level `1` (Quiet, half the Loud sample amplitude) or
  `2` (Loud). MIDI `0` selects the same five random variants; a MIDI note from
  `48` through `96` selects a fixed pitch, with note `69` at 440 Hz.
- `ton LEVEL MIDI` sustains a fixed pitch. Repeat it while navigating to keep
  the tone alive, or change its pitch without a silent gap. `end` releases it
  with a short fade. A missing keepalive stops the tone after 650 ms.

Other values and malformed lines are discarded. All clicks use the same 28 ms
envelope; their sample buffers are prepared once at startup. The app implements
Off by stopping the worker. The protocol carries individual notes, with no
built-in note sequences.

Sustained tones use a phase-continuous sine with a 5 ms attack/release and a
bounded PCM queue of at most 112 ms. Quiet has half the Loud amplitude. Sustained
output uses a lower peak than short clicks to keep continuous sound comfortable.

Taps received during preparation or while a click is outstanding are discarded;
bursts coalesce instead of building a backlog. Closing stdin or sending SIGTERM
ends the worker. The app waits for it to exit before starting media playback.
Core replacement, a stale raster heartbeat, or a lost session also ends it.
This mode does not read or write the media worker's control FIFO or status file.

## Invocation

```
jfplay [--rbf path] [--core-name NAME] [--base SECONDS] [--start-in-file SECONDS] [--audio INDEX] [--headers "K: v\r\n..."] [--cafile path] [--fifo /tmp/jfplay.ctl] [--status /tmp/jfplay.status] [--hold] [--direct] [--volume 0-100] [--audio-boost 100-300] [--surround-source] [--analog-aspect 0-4] [--anti-twitter 0-2] [--geometry LEFT,TOP,RIGHT,BOTTOM,WIDTH] URL
```

`URL` is a direct-play file or an HLS master/media playlist.  `--headers` is
passed to every FFmpeg HTTP open, including HLS children.  Without
`--headers`, the environment variable `JFPLAY_HEADERS` supplies them; the app
uses it, since the headers carry the token and a process's command line is
readable by every other process.  `--cafile` enables
TLS peer verification using that CA bundle.  The URL is never logged unless
`JFPLAY_LOG_URLS=1` is in the environment.

`--audio INDEX` selects an absolute libavformat stream index.  Without it,
FFmpeg's best audio stream is used, falling back to the first audio stream with
an available decoder when probe metadata is incomplete.  `--base` is the item
time corresponding to the beginning of this stream.  The PTS of the first
accepted IDR access unit establishes the timestamp origin with a one-second
preroll margin.  Reported position is `base + (core STC - one second)`, clamped
at `base`; a known duration is `base + remaining container duration`.

`--start-in-file SECONDS` seeks the opened container to the nearest earlier
keyframe before reading. The first accepted access unit is still the next IDR.
Live `seek ID SECONDS` uses an increasing request ID and an absolute item
position, on the same timeline as the `position` status value. The worker reports
the matching ID and requested position while seeking, then reports `ready` when
it submits the demuxer's selected IDR to the core. A normal demux seek can land
on the keyframe immediately before the target; a retained-buffer hit selects a
confirmed keyframe no more than one second after it. `seek_actual_position`
reports the submitted keyframe's actual item time. This confirms worker
submission, not that the core has displayed the new picture yet. A failed seek
reports `seek_state=error` and a reason so the controller can replace the
stream. `seek_cache_hit=1` means the worker reused retained compressed packets;
0 means it performed a regular demux seek.

The default RBF is `_Other/H264`.  The core is loaded only if necessary, then a
new session is started.  Whether it is loaded is read from `/tmp/CORENAME`,
where MiSTer writes the loaded core's own name (the first entry of its
CONF_STR, not the rbf file name): `H264` for an upstream build of the core, or
the name an app's build gives itself.  With `--core-name NAME` only that name
counts as the core being loaded and owned (MisterZine Plex passes
`MisterZine Plex Core`), so an upstream `H264` core, which may be another
app's, is loaded over rather than written to; without `--core-name`, only
`H264` does.
Volume is a user-facing linear amplitude percentage;
100 maps to zero attenuation, 0 to mute, and intermediate values to the core's
nearest 0.5 dB attenuation step. `--audio-boost` sets the surround downmix gain,
100 to 300 percent (the app's presets are 100, 175 and 300). The gain applies
only when the decoded source has more than two channels, or when
`--surround-source` identifies a multichannel source already downmixed by the
server. A soft limiter keeps boosted PCM within
the signed 16-bit output range. Live `boost N` changes the gain for audio decoded
after the command; audio already queued for playback keeps its previous gain.

`--analog-aspect N` requests the analog picture treatment for this
playback: 0 Auto, 1 Fit, 2 Letterbox, 3 Crop, or 4 (jfplay-only) 14:9 crop.
Mode 4 uses interface 1.2 custom geometry and falls back to Letterbox on older
cores. The request is made after the
core session starts, can be replaced live with `aspect N`, and is cleared when
jfplay exits so it does not override the user's OSD choice in a later session.

`--anti-twitter N` requests the core's Anti-Twitter setting: 0 Auto, 1 Off, or
2 On. The app does not pass it: De-flicker is set in the core's OSD.
This affects frame-based video on an interlaced CRT; field-coded
interlaced video is left alone. The setting is applied with the analog aspect
request in one masked update, so the core's other menu choices are preserved.
Like the aspect request, it is cleared when jfplay exits.

`--geometry` requests saved CRT edge and width calibration. The request is
supported by H.264 core interface 1.2 or later and applies only to fitted
720x480 or 720x576 output; Native HDMI output is not supported. The app
sends this option only when the running core advertises interface 1.2 or
later, so older cores retain preview-only calibration. The core shipped with
the app (interface 1.4) applies saved geometry. Visual confirmation on a CRT
remains pending.

`--direct` marks an untranscoded stream. Before anything of the stream reaches
the core, the worker checks its SPS and PPS (from the container's extradata,
or else the first IDR access unit) with the decoder project's
`clients/common/h264check.c` plus `direct_check.h`: Main or High profile,
4:2:0, 8-bit, CABAC, no MBAFF (field-coded PAFF is accepted), at most 1280
pixels wide and 3,600 macroblocks, within the core's macroblock rate when the
container reports a frame rate, and no slice groups or redundant pictures. A failure,
or no parameter sets before the first IDR, exits with code 7 and an `error`
naming the reason. While a `--direct` stream plays, `lag_watch.h` samples
`DISP_LATE` and `LAG_MS` once a second (outside pause, seeks and a 3 s grace
after each); four consecutive seconds with new late pickups and a picture that
is behind and falling further behind (or more than 2 s behind) also exit with
code 7. The `position` written at exit is where to resume a transcode.

Whatever the source, the SPS that travels with a key frame is checked against
the container's frame rate before it reaches the core (`vui_timing.h`). The
core schedules pictures by the SPS VUI timing (`num_units_in_tick` /
`time_scale`) and, with Refresh Rate on Auto, picks the raster's rate from it;
an encoder that leaves the fields absent or wrong (a 23.976 frames/s file was
found tagged 1 / 180000) made the core pick up every other picture late for
the whole title. When the VUI rate differs from the container's by more than
half a percent, has no timing or no VUI at all, the worker rewrites the timing
to the output clock's rate (the container's, after any film-speed change) and
logs the first few rewrites.

With `--hold`, the session starts paused before any records are submitted.  The
reader finds the first IDR (discarding earlier video), then the process fills as
much of the ring as it can while the old display can remain visible outside
this process.  `resume` releases the new session.  Without `--hold`, playback
starts normally.  A `pause` freezes the core clock, picture and audio together.

## Media path

Probe size and analysis time are deliberately generous enough for high-bitrate
transport streams, but audio does not depend on probe-populated rate/channel
metadata: the decoder opens first and the resampler is created lazily from the
first decoded frame.  H.264 streams with AVCC extradata pass through FFmpeg's
`h264_mp4toannexb` bitstream filter; Annex-B transport streams pass unchanged.
Corrupt packets and all video before the first IDR are dropped.  Each output
packet is treated as one access unit and stamped in 90 kHz units.  A timestamp
that would normalize below zero is submitted as missing rather than as a
negative PTS.  The first accepted access unit's NAL types, size, timestamps and
flags are logged once for startup diagnosis.

Audio is decoded, downmixed/resampled to 48 kHz signed 16-bit stereo, and held
as a bounded queue of per-decoded-frame chunks with their PTS.  It is sent in
960-frame (20 ms) records.  Chunks whose timestamps are contiguous within about
one millisecond are combined; a gap or discontinuity begins a fresh record at
its own PTS (the preceding short record is silence-padded).  Missing frame PTS
continues from preceding decoded audio when possible.  Audio decoding requires
local queue room, and its queued tail may normally be no more than 90,000 ticks
ahead of the newest submitted video.  At natural EOF that lead gate is released
so the decoder and resampler can be fully drained.

Ring order matters as much as timestamps.  The core parses the ring in write
order and runs only as far ahead of the picture as the decoder's frame stores
allow (about a second, less in scenes that keep many reference frames); an
audio record is queued to play only when the parser reaches it.  Audio that
trails its video in the ring therefore arrives at the gate just late, is counted
late and dropped, and the sample FIFO underruns while the picture stays on time.
So the writer keeps audio level with or slightly ahead of video in ring order,
like a well-muxed stream: every audio record that is ready is written before
the next video access unit, audio may run up to one second past the newest
video written, and a video access unit may run only 0.1 s past the newest audio
written while audio is still pending (it waits, and audio that is blocked only
by a full ring keeps its turn).  Two earlier versions failed on the DE10: one
record per access unit left audio seconds behind during the ring fill (sound
stopped after 11 s on a local file), and letting video run a second ahead
left audio 0.7 s behind in the ring, which held for 50 s of an HLS transcode
until the decoder's run-ahead shrank and the audio queue drained.

`JFPLAY_DEBUG=1` logs a line every two seconds: the core's STC, the newest
video and audio PTS written (`nv`, `na`), the local PCM queue depth, records
written, the core's audio counters (`played`, `late`, `under`, `gap`, `qrec`
queued records, `astate`), display re-anchors, free ring bytes, and the
writer's record splits, padding and untimed records.  The core's counters are
cumulative across sessions, so compare deltas.

## FIFO commands

The FIFO is created if absent and opened non-blocking.  Commands are ASCII, one
per line.  Unknown or malformed commands are logged and ignored.

| Command | Meaning |
|---|---|
| `pause` | Pause presentation out of band. |
| `resume` | Resume presentation. |
| `toggle` | Toggle the current pause state. |
| `volume N` | Set volume, where N is 0 through 100. |
| `boost N` | Set surround downmix boost from 100 through 300 percent. |
| `seek ID SECONDS` | Seek to an absolute item position; ID must increase for each request. |
| `aspect N` | Set analog aspect treatment, where N is 0 through 4 (4: jfplay's 14:9 crop; see `--analog-aspect`). |
| `anti-twitter N` | Set Anti-Twitter, where N is 0 (Auto), 1 (Off), or 2 (On). |
| `stop` | Silence playback and reset the core session to discard buffered video/audio, then exit. |
| `quit` | Alias for `stop`; it is also a clean end. |

SIGINT and SIGTERM have the same meaning as `stop`. Stop snapshots the resume
position, pauses output and flushes the core session with a one-second timeout
before joining the network reader. Cleanup discards compressed packets and PCM.
A failed reset reports an error and leaves output paused. Natural input EOF is different:
it drains the bitstream filter, audio decoder, resampler, and queued PCM before
submitting END_OF_STREAM. In-place seeking requires the demuxer to support
seeking; the controller can restart the worker when it reports an error.

## Status keys

The complete file is written to a sibling temporary file and atomically renamed
over the requested status path every 250 ms and on important transitions.
Values are single-line ASCII; diagnostic text is sanitized so it cannot add
keys.  Unknown numeric values are `0`, empty text is written as an empty value,
and fractional seconds use three decimal places.

| Key | Meaning |
|---|---|
| `state` | `opening`, `playing`, `paused`, `ended`, or `error`. |
| `position` | Item position in seconds: base plus core STC less the one-second preroll, clamped at base. |
| `duration` | Item duration in seconds when known, otherwise 0. |
| `width` | Coded video width. |
| `height` | Coded video height. |
| `fps` | Nominal video frame rate as a decimal. |
| `film_speed` | `1` when PAL film speed-up (24 to 25 fps) is active, otherwise `0`. |
| `ntsc_slowdown` | `1` when the 1000/1001 NTSC slowdown is active, otherwise `0`. |
| `audio_output_rate` | PCM rate in Hz the audio is resampled to (48000 unless a film-speed clock is active). |
| `video_bitrate` | Container/stream video bitrate in bits per second. |
| `audio_codec` | Decoder codec name, or empty when there is no audio. |
| `audio_channels_in` | Channels reported by the first decoded input frame. |
| `audio_boost` | Configured surround gain percentage. |
| `seek_supported` | `1` when this worker supports in-place demux seeks. |
| `seek_id` | Most recently accepted seek request ID. |
| `seek_state` | `idle`, `seeking`, `ready`, or `error`. |
| `seek_position` | Target position for `seek_id`, in item seconds. |
| `seek_actual_position` | Actual IDR time submitted to the core when the seek is ready; otherwise 0. |
| `seek_cache_hit` | `1` when the seek reused retained compressed packets, otherwise `0`. |
| `seek_error` | Sanitized reason when the last in-place seek failed. |
| `buffered_valid` | `1` when accepted video/PCM and queued compressed packets establish a contiguous common A/V range. |
| `buffered_start` | Start of that common item-time range in seconds; otherwise `0`. |
| `buffered_end` | End of that common item-time range in seconds; otherwise `0`. |
| `late` | Core `DISP_LATE` counter. |
| `errors` | Core reconstruction error counter. |
| `refused` | `0 none`, or the numeric refusal code and its library name. |
| `buffered_ms` | Core queued PCM plus PCM waiting in this process, in milliseconds. |
| `error` | Sanitized failure text; empty unless state is `error`. |

## Exit codes and lifecycle

| Code | Meaning |
|---:|---|
| 0 | Input ended, or stop/quit/signal requested a clean end. |
| 2 | Invalid command-line arguments. |
| 3 | The H.264 core could not be launched, opened, or started. |
| 4 | The URL could not be opened or initial stream setup failed. |
| 5 | The core refused the stream (unsupported profile, size, or similar). |
| 6 | A network/demux/decode failure occurred after playback opened. A socket read that sees no data for 15 s (direct) or 60 s (transcode) fails and FFmpeg reconnects at the same offset, backing off for about two minutes; only then does the worker exit 6. |
| 7 | `--direct` only: the stream needs a server transcode (pre-check failed, or the core could not keep up). |

On natural EOF the final held video access unit carries
`H264RING_F_END_OF_STREAM` after queued audio. On stop, a session reset discards
hardware queues instead of placing an end marker behind them. Either clean
path publishes `state=ended`; if no IDR was ever
available, the process still closes the session cleanly.  Core calls are all
made on the main thread because a `h264ring` handle is not thread-safe.
