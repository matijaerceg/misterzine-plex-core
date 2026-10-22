# The Jellyfin client's host test

The branch's gate (`docs/jellyfin.md` §6): the client's own code (`../src`, built with
`-DCLIENT_TEST`) against a **fake core** and a **fake Jellyfin server**, both scripted, scored by an
oracle that shares nothing with the client or the library.

```bash
clients/jellyfin/tests/run_test.sh          # one run, ~60 s: GREEN or the failing checks
clients/jellyfin/tests/run_test.sh --red    # ...then each mutation, which its own check must catch (~16 min)
make -C clients/jellyfin test               # the same as the first
```

Needs host gcc, pkg-config with FFmpeg (libavformat, libavcodec, libswresample, libavutil) and
libcurl with WebSockets, `ffmpeg` / `ffprobe` with libx264, python3, and the DejaVu typefaces
(`JF_FONT_DIR`, default `/usr/share/fonts/TTF`). Fixtures, references and every run's files are
in `.sim/jellyfin_test/` (gitignored): `green/log` is the whole story of the last GREEN run,
`red_<mutation>/run/log` each mutant's.

## The pieces

| File | What it is |
|---|---|
| `test_client.c` | The fake core on a thread (Moonlight's, `clients/moonlight/tests/test_mister.c`: the nonce, the read index, the seqlocked status block), and the client as `jf_main("--dir", TESTDIR)` on another. Presses pad 0 through the input region on the scenario's cues. Writes what each session consumed and the clock, word 34, overlay and pad histories for the scorer; judges T1-T8 itself. |
| `fake_server.py` | A Jellyfin 10.11 (stdlib only): Quick Connect, the MediaBrowser header, the capabilities, a hand-written WebSocket on `/socket`, `PlaybackInfo`, the media with HTTP ranges, the HLS transcode (master, media playlist, segments, every URI with `ApiKey`), the reports. Plays the scenario below and logs every request and message. |
| `check_client.py` | The scorer: `tools/ring_model.py`'s consumer (written from `docs/architecture.md`) walks every session; the references come from the fixtures through the ffmpeg CLI. |
| `mutations.py` | `--red`'s table: each mutation, applied to a COPY of `src/` (compiled from the copy), and the check that must go RED. |
| `run_test.sh` | Makes the fixtures (when their recipe changed), builds (the old binary deleted first), runs, scores; requires the positive `ALL GREEN` markers of BOTH `test_client` and `check_client`. |

## The fake core's half-speed clock

The fake core runs **its STC at half real speed** (45,000 ticks a real second) from a session's
first VIDEO_AU with a PTS, frozen while word 34's PAUSE is set, and sets LIVE ENDED once the
END_OF_STREAM access unit is consumed and the clock has passed the session's latest PTS. It
consumes the ring at once (except while paused), so the client writes a whole 12 s file in about
a second: a position derived from what the client WROTE (the demuxer) runs seconds ahead of one
derived from the STC, and the half speed widens the gap. That is what makes check (h) able to
tell the two apart.

## The scenario

Sign-in by Quick Connect (Initiate by POST; two unapproved polls, then approved: ~15 s at the
client's 5 s poll) -> the capabilities -> the socket. `ForceKeepAlive`. `Play` item A (direct
play, MKV, High CABAC 640x360 25 frames/s, 12 s, an IDR a second, AAC; with its SRT as subtitle
stream 2) -> its Playing report -> 3 s -> `Pause` -> 1.5 s -> `Unpause` -> `Seek` to 6 s (the open that follows answered 1.2 s late, as a transcode's restart is) -> the
seek's Progress -> 1 s -> `SetSubtitleStreamIndex` -1 -> 1 s -> `SetSubtitleStreamIndex` 2 -> 1.5 s -> `SetVolume` 50 -> `Stop`. `Play` item C (300 s of one colour, no audio: room for the pad's seeks, a few hundred KB) -> 1 s -> the cue `pad_taps`: the fake core taps pad 0's RIGHT three times (pressed 60 ms, every 120 ms) through the input region (words 48-71, written as the core writes them: in_head first, in_tail last; the pads are a snapshot, so each press and release also lasts until the client's loop has gone round twice since the edge -- counted by `test_client.c`'s own `usleep`, which the loop calls once an iteration -- and a busy host stretches it rather than losing a tap; `test_client` prints the longest) -> (the seek's open slow too) -> the seek's Progress -> 1.5 s -> the cue `pad_hold`: RIGHT held 1.2 s (the open slow again) -> the seek's Progress -> 1 s -> `Stop`. `Play` item B: offered for direct play, but it is CAVLC (the server
cannot see that) -> the client must ask again with direct play and stream copy off -> the HLS
transcode (8 s, TS; each segment URL carries `runtimeTicks` / `actualSegmentLengthTicks` as Jellyfin's do)
-> 2 s -> `Seek` to 4 s (the client trims the playlist to the segment holding 4 s) -> 2 s -> `SetVolume` 100
(a report while the trimmed stream plays) -> played to its end (the Stopped report). `Play` item D
(`docs/jellyfin.md` §12: a 1080p HEVC source, offered only as a transcode): one 10 s TS segment whose audio
comes first after 3 s of video -- past the probe, so FFmpeg knows no sample rate -- and then 6.4 s AHEAD of
its video in the stream, more than the core's 256 records (`tools/ts_skew.py` moves the audio's PES units,
every timestamp as encoded) -> played to its end (the Stopped report). Every wait has a
timeout that ends the run (the pad's and the seeks' waits only record theirs, so (o), (p), (q) score what
happened), so a mutant that never signs in or never ends still finishes.

## The checks

| | What it proves |
|---|---|
| T1-T8 | (`test_client`) the library attaches; a session; the scenario, not the timeout, ended the run; the client returns 0 within 10 s of being stopped; every record header well formed; every overlay descriptor valid; the pad pressed on both cues; (T8, interface 0.10) the overlay drawn for the raster the fake core reports -- word 80's 576 lines (against raster_std's 480) at word 47's 16:9, as A' leaves it. |
| (0) | The scenario ran to its end; the consumer finds no protocol error in any session. |
| (a) | Quick Connect: Initiate by POST (no GET), polled until approved; then the token in the MediaBrowser header of every API request (Client, Device, DeviceId, Version always present, one DeviceId), and `ApiKey` on every media / playlist / segment URL and the socket's. |
| (b) | The capabilities: PlayableMediaTypes Video, SupportsMediaControl, and every band (the CodecProfiles after the first) keyed on **Width**, none on Height (R1). |
| (b') | (0.11) The profile: direct play up to 1280x720 (the base conditions), exactly one band keyed on the frame rate, capping a fast source inside 864x480, and the transcode's box 854x480 (the fake core's `cap_native_h` 480, Video Output not Native). |
| (c) | `ForceKeepAlive` answered by a `KeepAlive` within 2 s; the client's frames masked. |
| (d) | Item A's first session: every access unit byte-identical to `ffmpeg -c copy -bsf:v h264_mp4toannexb` of the file (the raw dump split by `framemd5`'s sizes, its MD5s verified), each with PTS_VALID and the packet's PTS at 90 kHz; the first record an IDR with SPS and PPS. |
| (e) | Item A's audio: every AUDIO record with a PTS; the PCM byte-equal to `ffmpeg -f s16le -ac 2 -ar 48000` of the file, at the offset the first PTS gives (within 1 ms: MKV's timestamps are milliseconds), every frame when the client started at the reference's first (it does here); every record's PTS at its own place within 1 ms. |
| (f) | Word 34's PAUSE: clear before `Pause`, set between `Pause` and `Unpause`, cleared after. |
| (g) | The seek is a flush: a new session starts between `Seek` and `Stop`, its first record an IDR with SPS / PPS at or before 6 s and within a GOP (1 s) of it, and its access units the file's from there. |
| (h) | Every Playing / Progress / Stopped `PositionTicks` within 0.6 s of the fake core's STC at the time (the stream's origin subtracted: the file's `start_time`); a report made while the clock is not running yet (a seek's) against the position the next session anchors at; at least 4 scored while it ran. |
| (i) | `SetVolume` 50 -> ATTEN 12 (0.5 dB steps), 0 before. |
| (j) | Item B's second `PlaybackInfo` has EnableDirectPlay and AllowVideoStreamCopy false (the first had direct play on), and no access unit of the CAVLC file was ever consumed (by MD5). |
| (k) | The transcode: every access unit as the playlist's (`ffmpeg -copyts -c copy`), PTS equal, the last (only the last) with END_OF_STREAM; the Stopped report (Transcode) within 1 s of the runtime. |
| (l) | The overlay flips pages (a taken descriptor, enabled, with another base) after the seek's session started: a session start re-writes the descriptor under a newer generation, so a client waiting for an EQUAL generation stops flipping (the signed "at least" rule in `ui.c`). |
| (m) | The subtitles: `PlaybackInfo` asked for stream 2, and its `.srt` fetched. |
| (n) | A text subtitle track switched off (-1) and on (2) during item A leaves the stream alone: no session starts between the first switch and the phase's end (no flush), the `.srt` is fetched again after the second, and no Stopped report for A in that window. |
| (p) | The held seek, for each of the three slow opens (A's `Seek`, the taps', the hold's): word 34's PAUSE set within 200 ms of the seek (the command; the pad's 600 ms after its last step), the slow request made while it was set, PAUSE never cleared before the new session starts (the flush), and the flush after the slow answer; the new session's first record a VIDEO_AU consumed within 300 ms of its start (the black is only the IDR); the old session consumed nothing after the PAUSE and had nothing written to it that it never consumed. |
| (q) | The transcode's seek opens the playlist trimmed to the target: the first segment asked for after B's `Seek` is the one holding 4 s (the last whose start, from the EXTINF durations, is at or before it) and no earlier one is asked for (an untrimmed open probes segment 0 first); the new session starts with that segment's first access unit, an IDR with SPS / PPS, byte-identical with its PTS, and continues as the playlist's. (h) scores a report made while the trimmed stream plays. |
| (r) | A slow subtitle answer (the switch's `.srt` answered 2.5 s late, as Jellyfin's first extraction of a file's embedded tracks is): the client's loop never stalls over 0.25 s while it waits. `test_client.c` records every stall between two of the loop's `usleep`s. |
| (u) | Every `.srt` is asked for from 0, the whole track with its own times. The fake server puts the PlaybackInfo's `StartTimeTicks` in the DeliveryUrl, and rebases the cues by it, as Jellyfin does. The switch after the seek asks PlaybackInfo with a start of 6 s or more. |
| (v) | Item D, the interleave: the fixture still holds its skew (from ffprobe's packets in file order: audio >= 5 s ahead, the first audio after >= 2.5 s of video); in the session, every AUDIO record within 1.3 s of the newest video PTS before it in the ring (the client's 1 s, the two access units it holds, a record's gathering: 1.16 s measured; 6.4 s in demux order); every access unit the playlist's, the last with END_OF_STREAM, the Stopped report within 1 s of the runtime. The fake core has no 256-record gate: the rule is scored directly, the core's freeze is the rig's to show. |
| (w) | Item D, the audio the probe missed: every AUDIO record with a PTS, the PCM equal to `ffmpeg -f s16le` of the source at its PTS's place (the first 2,048 frames excused when the client started past the reference's first). |
| (o) | The pad's seeks add up: the three RIGHT taps start exactly ONE session, its first record an IDR at the position at the cue + 90 s (3 steps of 30 s; at or before it, within a GOP); RIGHT held 1.2 s starts exactly ONE session, at least 3 steps on (1 + the repeats at 450 ms and then every 180 ms: up to 6). The position at the cue is the fake core's STC, which must be running. |

## `--red`

| Mutation | Must be caught by |
|---|---|
| M1 the position from the demuxer (the last access unit written) | (h) |
| M2 `h264check` never says CAVLC | (j) |
| M3 the seek without `core_new_stream` (the flush at the held stream's release) | (g) |
| M4 the pause never written to word 34 | (f) |
| M5 no `KeepAlive` on `ForceKeepAlive` | (c) |
| M6 the direct-play band keyed on Height again | (b) |
| M6b (0.11) the 720p transcode box asked for on every output | (b') |
| M6c (0.11) the fast band keyed on the width alone (a 720p60 source would direct-play) | (b') |
| M7 audio records without PTS | (e) |
| M8 the overlay's flip waiting for an EQUAL generation | (l) |
| M9 Quick Connect's Initiate by GET | (a) |
| M10 the last access unit without END_OF_STREAM | (k) |
| M11 every subtitle switch restarts the stream (`start_item`) | (n) |
| M12 a pad seek step seeks at once (no adding up) | (o) |
| M13 a held seek button never repeats | (o) |
| M14 `open_stream`'s keep forced to 0: the flush at once, nothing held | (p) |
| M15 the transcode's playlist never trimmed (`hls_trim` 0) | (q) |
| M16 the canvas's lines from raster_std, not word 80 (0.10) | T8 |
| M17 the raster's shape guessed 4:3, not word 47's (F9's squish under A') | T8 |
| M18 the subtitle URL's start kept (no `whole_track`) | (u) |
| M19 the subtitles fetched on the loop's thread (the fetcher never started) | (r) |
| M20 (0.16) a transcode trusted to its BT.709 label (the source's ColorSpace ignored) | (k2) |
| M21 (0.16) the source's tag ignored, the size rule alone | (k2) |
| M22 (§12) the audio written in the demuxer's order again (never held for the video) | (v) |
| M23 (§12) an audio stream the probe missed passed over (`av_find_best_stream` alone) | (w) |
| M24 (§12) swr built at the open from the probe's parameters (none: the audio refused) | (w) |
| M25 (§12) a frame without a time sent untimed (no carry from the frame before) | (w) |

A mutation caught only by another check is a failure of the runner. Other checks may also go
RED on a mutant (M2 lets the CAVLC file play, so (k) fails too); only the named one is required.
