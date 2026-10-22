# The Jellyfin client (Phase 7's second example integration)

Engineering note. Status: **v1 (the cast target) ✅ MERGED (PR fj#24), ✅ HW-CONFIRMED 2026-10-01 with
the maintainer (casting from a phone, the pad, seeks, subtitles; a CRT at 480i not yet: §10,
`history.md` §21); J1-J6 decided 2026-10-01 (the
maintainer accepted the proposals); R1-R3 done (§5); the host test (§6) GREEN and `--red`.** Asked 2026-10-01 (the maintainer): a
Jellyfin client next. **The interface is not frozen by this work** (the maintainer, 2026-10-01:
1.0 waits for a public release, not planned soon): what the client finds goes into §7 as
findings, designed in `architecture.md` and versioned (0.10 onward) like any interface change,
and nothing here assumes the current layout is final.

**Since 2026-10-09 (§12):** a 9.6 Mbit/s transcode played without audio after some opens, and froze when the
server put its audio seconds ahead of its video. Client fixes on `fix/jellyfin-transcode`, host-tested and
verified on .201 (control arm first). The core's livelock is designed only.

A Jellyfin server (10.10 onward) holds the user's library. The client on the MiSTer's ARM asks it
for a stream the core can decode -- the file itself when it fits D1's budget, a transcode when it
does not -- demuxes it, decodes the audio to PCM, and hands the core H.264 access units and PCM
with their timestamps through `hps/lib` (libh264ring). Its screens are drawn into `/dev/fb0` and
composited by the core (the overlay plane, interface 0.9); its controls arrive through the core
(the input region, 0.6).

**What it exercises that Moonlight did not** (why it is the interface's next customer):
PTS-paced playback (B-frames, reordering, audio against the STC -- Moonlight runs LOW_LATENCY
with no PTS), the seek (`h264ring_flush`) and the pause (word 34), sessions of hours, the overlay
used continuously (a player's controls, subtitles), and the STC read back (word 7) as the
program's clock. The research behind this note (2026-10-01: the server's source at v10.10.7,
v10.11.11 and v12.1; jellyfin-web, jellyfin-mpv-shim; FFmpeg's configure; MiSTerFin) is cited
where it is used; **every Jellyfin fact below is from source, not yet run against a server**
(R1 runs them).

**Since the file player (`docs/player.md` P1, 2026-10-01):** `player`, `h264check`, `core`,
`input`, `ui`, `subs`, stb_truetype and the build image live in `clients/common/`, shared by the
two clients. The ready screen is `ui_card`; the image is tagged `mister-h264-clients:deps2` (the
text subtitle decoders and the raw H.264 demuxer added); the host test compiles `src/` +
`common/` and its mutations name their tree. Paths to `src/player.c` etc. below read
`clients/common/`.

## 1. Decisions (decided 2026-10-01, the maintainer: the proposals accepted as written)

| # | Decision | Alternatives, and why not (yet) |
|---|---|---|
| J1 | **v1 is a cast target**: the client registers with the server as a remote-controllable player; the user picks something in a Jellyfin app (phone, web) and chooses "Play on" the MiSTer; the MiSTer plays it with a now-playing overlay (title, a progress bar, pause / seek feedback) and pad transport (pause, seek, stop, audio / subtitle track). The browse UI (an LVGL 10-foot UI over the overlay) is v2, on the same code. Moonlight's precedent (M6: view-only first). | **A browse UI from the start**: the product most users picture, but most of its work (a focus-driven poster UI, text entry, image caching) exercises the overlay and input the interface already has; the cast target exercises the whole playback interface in a fraction of the time, and v2 adds the UI to a player already proven. |
| J2 | **`clients/jellyfin/`, this project's own C code, GPL-3.0-or-later** (M1's reasoning: the interface still moves, one repository). **An ARM binary static except glibc** (amended 2026-10-01, §10: a static glibc's host-name lookups crashed on the rig) from a Docker image extending Moonlight's (`clients/moonlight/docker/`): **libavformat + libavcodec (audio) + libswresample** (FFmpeg, LGPL-2.1+, no `--enable-gpl`), **OpenSSL 3 shared with Moonlight's image**, libcurl (HTTP and its WebSocket API), a small JSON parser (cJSON, MIT). | **MiSTerFin's code** (the one Jellyfin client for MiSTer; C): **CC BY-NC 4.0, incompatible with GPL-3.0** -- ideas only (its Quick Connect flow, its transcode request, its pixel-aspect handling), credited as reading, never copied. **mbedTLS** (the FFmpeg build ~2.3 MB smaller): a second TLS stack beside Moonlight's for one binary's size. **A Python client** (jellyfin-mpv-shim's model): MiSTer Linux's Python lacks the libraries; a static binary is immune to its changes (M4). |
| J3 | **What the server is asked for** (§2): direct play when the file fits (H.264 High / Main, 8-bit SDR, progressive, inside the picture bound below, <= 10 Mbit/s, an audio codec the ARM decodes); otherwise an **HLS transcode in MPEG-TS** to H.264, its size **capped by one box: 854x480** (every aspect fits 1,620 macroblocks: 16:9 -> 854x480, coded 864x480 = 1,620; 4:3 -> 640x480). **Never the union of two boxes** (854 wide AND 576 high lets a 4:3 PAL source become 768x576 = 1,728 macroblocks: refused). A 720x576 box for 25 / 50 frames/s sources is a refinement after R1 (§2). | **Progressive transcode** (`stream.ts`): seeking is a new request either way, and the server forces progressive remuxing off ("currently broken", `MediaInfoHelper.cs`); HLS also restarts its transcode at a seek by itself. **Always transcode**: wastes the server and the picture when the file already fits. |
| J4 | **Sign-in by Quick Connect**: the client shows a six-digit code on the overlay; the user approves it in any signed-in Jellyfin app; the token and a stable DeviceId are kept on the SD card (`/media/fat/jellyfin/`). The server's address in an ini; an API key in the ini as the fallback for a server with Quick Connect off. | **Username and password** (typed with a pad, or kept in the ini in clear): Quick Connect exists for exactly this. |
| J5 | **A Scripts-menu launcher, Moonlight's pattern (M2)**: `Scripts/jellyfin.sh` reads `jellyfin.ini` (server URL), runs the client detached; the client loads the core, opens a session and shows "Ready to play -- cast from Jellyfin" on the overlay **over the idle screen** (the overlay is shown only during a session: §7 F1), and stays a cast target until the user loads another core from Main's OSD (the heartbeat rule, `moonlight.md` §2) or presses the quit combo. The library's lock keeps a second program out. | **Exit after each item**: back to the menu after every film, the cast target gone between them. |
| J6 | **Subtitles: text on the overlay, bitmaps burned in.** Text subtitles (SRT / ASS / VTT, embedded or external) fetched from the server as SRT (it converts) and drawn on the overlay against the STC; bitmap subtitles (PGS, VobSub, DVB) delivered `Encode` (burned in by the server: forces a video transcode). | **All burned in** (v1's simplest: no renderer): every subtitled film becomes a transcode, and the overlay -- built for exactly this -- goes unused. **Bitmaps on the overlay** (PGS fetched raw on 10.10+): a decoder and a scaler on the ARM; later, if burn-in's transcode hurts. |

## 2. The stream

### The device profile (sent with every `PlaybackInfo`)

From the server's `StreamBuilder.cs` / `ProfileConditionValue.cs` (v12.1): a profile's video
conditions decide direct play AND become the transcode's limits (`MaxWidth`, `MaxHeight`,
`VideoBitrate`, the level), and a transcoding profile's own conditions are applied after them
(`Math.Min`). **The server cannot express the macroblock bound** (no pixel-count condition) **and
never reads a PPS** (CABAC is invisible to it), so:

- **Direct play's picture bound as two bands** (`ApplyConditions`): width <= 720 allows height
  <= 576 (45 x 36 = 1,620); width 721-864 allows height <= 480 (54 x 30 = 1,620); wider or taller
  is transcoded. Conservative: a 960x400 file (1,500 macroblocks) is transcoded although it fits.
  At <= 60 frames/s both bands are inside 97,200 macroblocks a second. **The band is keyed on the
  WIDTH, not the height** (R1, 2026-10-01): a band's conditions also become the transcode's
  limits whenever the SOURCE matches it, so "height >= 481 -> width <= 720" capped every 1080p
  source's transcode at `MaxWidth=720` (a 16:9 film at 720x404); "width >= 721 -> height <= 480"
  admits the same files and gives a 1920-wide source `MaxWidth 854 / MaxHeight 480`, measured.
- **(Interface 0.11, 2026-10-02: 720p; roadmap Phase 5c.)** The core decodes up to 3,600
  macroblocks (1280x720) and is designed for 108,000 a second (word 81, `h264ring_caps()`), so
  direct play grows to **1280x720 at <= 30 frames/s** -- 720p24 / 720p30 files play without a
  transcode -- by the base conditions (`Width` <= 1280, `Height` <= 720, both required) and THREE
  bands, every one keyed on the width: width <= 720 -> height <= 576; width 721-864 -> height <=
  480; **width >= 865 and `VideoFramerate` >= 30.5 -> width <= 864 and height <= 480**. The last
  is keyed on the rate as well because a band's conditions become the transcode's limits: a
  frame-rate CONDITION (720p only at <= 30) would cap every 60 frames/s source's transcode at 30
  frames/s, while the rate in the band's `ApplyConditions` leaves a 720p60 / 1080p60 source's
  transcode at 854x480 and its own 60 frames/s (as before 0.11). A source whose rate is unknown
  matches both sides of a rate condition (the server treats a missing value as satisfied unless
  required), so it gets the stricter 864x480. Not measured against the server yet (⏳ on the rig:
  a 720p24 file offered direct play, a 720p60 file transcoded at 60).
- **The transcode's box follows the output** (decided 2026-10-02 with the maintainer): 1280x720
  only when Video Output is Native (HDMI) on a core whose native raster shows a 720-line picture
  (`cap_native_h` >= 720; `hd_box()` in `main.c`, `jf_profile_json(1)`), else 854x480 -- on the
  fitted 720-wide rasters (480i / 480p / 576, HDMI's fitted) a 720p transcode adds only work. Since
  interface 0.12 (the HD raster, Phase 5c part 3: `cap_native_h` 720) the rule is on: on the rig
  2026-10-04 with the maintainer a 1080p film transcoded to the 1280x720 box and a 720p file direct
  played in Native, both good on HDMI (`history.md` §30). The item's choice is kept for its
  subtitle switches (the fetcher's PlaybackInfo).
- **The rest of direct play:** `VideoProfile` high | main (never "constrained baseline":
  CAVLC), `VideoBitDepth` <= 8, `VideoRangeType` SDR, `IsInterlaced` false (the server cannot
  tell PAFF, which the core decodes, from MBAFF, which it refuses: every interlaced file is
  transcoded -- and every transcode is deinterlaced, yadif, `EncodingHelper.cs`),
  `VideoBitrate` <= 10 Mbit/s, `VideoFramerate` <= 60. Audio: AAC, AC-3, E-AC-3, MP3, Opus,
  FLAC (decoded on the ARM, §3); TrueHD and DTS-HD are left out, so the server transcodes them.
- **The transcode:** `Protocol` hls, `Container` ts, H.264, audio AAC or AC-3 stereo, the box
  854x480 (J3). `MaxStreamingBitrate` and `MaxStaticBitrate` 10,000,000 (both default to 8 M).

The profile's JSON lives in the client's source (`profile.c`), with this section as its
rationale; R1 checks the server answers it as read. **The transcode's level** comes back as
`h264-level=41` (the server's own choice): harmless -- the core neither refuses on `level_idc`
nor sizes its DPB from it beyond the 16-frame cap (`spec_hardening.md`), and the bitrate stays
the profile's (9.6 Mbit/s of video).

### The client's check (what the server cannot see)

Before the first access unit reaches the ring the client parses the SPS / PPS itself:
`entropy_coding_mode_flag` 0 (CAVLC), `frame_mbs_only_flag` 0 with
`mb_adaptive_frame_field_flag` 1 (MBAFF), `profile_idc` 66, a picture over the core's bound (0.11:
3,600 macroblocks, word 81; 1,620 before), or (0.11) a stream above its macroblock rate (108,000 a
second, from the container's frame rate: a 720p60 file).
On any of them it asks `PlaybackInfo` again with direct play, direct stream and stream copy all
off -- a transcode the server's own encoder makes, which is CABAC unless the admin chose x264's
`ultrafast` preset. Three ways such a stream would otherwise arrive: a Baseline source remuxed
(the server copies a profile *lower* than the one asked for), CAVLC Main / High or MBAFF files
(invisible to the server), and `ultrafast`. **If the transcode still fails the check, the
client stops and says why on the overlay** (and the core's refusal, should one get through, is
named the same way: §7 F3) -- never garbage.

### Delivery

Both are a URL handed to `avformat_open_input`:
- **Direct play:** `/Videos/{id}/stream?static=true&mediaSourceId=..&ApiKey=..` (the file, with
  HTTP ranges: libavformat seeks in it). MKV / MP4 packets are one access unit each;
  `h264_mp4toannexb` turns `avcC` into Annex B with the parameter sets before each IDR.
- **Transcode:** the `TranscodingUrl` from `PlaybackInfo` (`master.m3u8`; 3 s TS segments when
  encoding). The mpegts demuxer runs the H.264 parser, so packets are whole access units.

**Seeking:** `h264ring_flush` (the session restarts in ~14 ms, the queue dropped:
`architecture.md` "Seeking"), then `av_seek_frame` to the IDR at or before the target (HLS:
the server restarts its transcoder at the segment asked for). The first access unit written is
the IDR with its parameter sets.

**Timestamps:** MPEG-TS / MKV / MP4 timestamps rescaled to 90 kHz (the ring's unit), the
stream's start subtracted so the first picture is near 0 (the 33-bit field's wrap kept out of
the core's way); video PTS on every access unit, audio PTS on every record. Paced, never
LOW_LATENCY. GRAPHICS never set (film, not graphics: Anti-Twitter Auto leaves it alone).

### Position, resume and reports

**The position is the STC (word 7), never the demuxer's.** The ring holds seconds; a position
read from what was written would report the film further on than the screen, mark it watched
early and resume past where the user stopped. The client converts the STC back to the item's
time (its start offset, the seek target) and reports `Playing` / `Progress` (every 10 s and on
each event) / `Stopped` with `PositionTicks` (100 ns), `PlayMethod`, `PlaySessionId`, so the
server keeps its resume point and its watched flag (it sets both itself: resume cleared under
5 %, watched over 90 %). `Stopped` also ends the transcode (the server kills an un-pinged HLS
transcode after 60 s otherwise). **The same STC times the subtitles.**

## 3. Audio

FFmpeg's decoders on the ARM (D2: the core presents PCM): AAC, AC-3 / E-AC-3 (the decoder's own
`downmix=stereo`), MP3, Opus, FLAC; libswresample to 48 kHz s16 stereo; 5 ms-or-longer records
with their PTS through `h264ring_write_audio`. Estimated 4-8 % of one Cortex-A9 core for a 5.1
AC-3 / E-AC-3 / AAC downmix (the MDCT has no 32-bit NEON path: plain C) -- an estimate scaled
from the workstation, **measured by R2** before it is relied on. The pause and the volume are
word 34 (`h264ring_set_pause`, `h264ring_set_atten`).

## 4. Sign-in and the cast target

**The header:** `Authorization: MediaBrowser Client="MiSTer H264", Device="MiSTer",
DeviceId="..", Version="..", Token=".."` (values URL-encoded; all four of Client / Device /
DeviceId / Version required). **Legacy authentication is off by default from 12.0** (the
`X-Emby-*` headers, `?api_key=`): only the `MediaBrowser` header and `?ApiKey=` on URLs. A new
sign-in with the same DeviceId revokes that device's older tokens, so the DeviceId is generated
once (a UUID) and kept.

**Quick Connect:** `GET /QuickConnect/Enabled`; `POST /QuickConnect/Initiate` (the GET form is
gone in 12.0) -> `{Secret, Code}`, the Code on the overlay; `GET /QuickConnect/Connect?secret=`
every 5 s until `Authenticated` (an unapproved request expires after 10 minutes); `POST
/Users/AuthenticateWithQuickConnect {Secret}` -> the token.

**Being a cast target:** `POST /Sessions/Capabilities/Full` (`PlayableMediaTypes` Video,
`SupportsMediaControl`, the commands below, the device profile), then the WebSocket
`/socket?ApiKey=..`: a `KeepAlive` every 30 s (the server sends `ForceKeepAlive` after 45 s of
silence and drops the socket at 60). Handled: `Play` (PlayNow; the queue's PlayNext / PlayLast
later), `Playstate` (Stop, Pause, Unpause, PlayPause, Seek, NextTrack, PreviousTrack),
`GeneralCommand` SetVolume, SetAudioStreamIndex, SetSubtitleStreamIndex, DisplayMessage. On
Play: the items, `PlaybackInfo` with the profile, the URL (static when allowed, else the
transcode) -- jellyfin-mpv-shim's flow (`event_handler.py`, `media.py`), the one cast-only
client to read.

## 5. Measurements before the code depends on them

- **R1 -- what the maintainer's server sends** (QSV; Jellyfin 10.11.11; a non-admin test
  account; the library mostly 1080p H.264 High, some HEVC / MPEG-4 ASP / VC-1, SD DVD rips).
  **So far (2026-10-01):** SD H.264 rips inside the bands (720x480 23.976, 710x572 25, 640x480)
  are offered direct play; a 1080p25 film (DTS 5.1) is transcoded to an 854x480 box. **The QSV
  transcode** (60 s captured from 10 minutes in): High, CABAC, `frame_mbs_only`, **852x480**
  (54 x 30 = 1,620 macroblocks, 6 columns cropped; SAR 640:639), **I and P only, one
  reference, no reordering** (Sunshine's shape: the decoder's easy case), the 8x8 transform,
  **VUI timing present (25 frames/s, fixed)**, **colour tagged BT.709** (F2), AAC-LC stereo 48
  kHz; ~9 Mbit/s. **Then** a 23.976 film (852x480, the same shape) and a 4:3 1440x1080 source
  (**640x480**, square pixels): the one box gives each aspect its size. No interlaced item in the
  test library (that case stays unmeasured). **The cosim** (`run_cosim.sh --sweep`, 120 frames,
  96.43 MHz, bit-exact against ffmpeg): Brick 1,454 cycles a macroblock, **1.64x** real time at 25
  frames/s; 3 Men and a Baby 1,431, **1.73x** at 23.976; Frosty 1,918 (640x480), **1.75x** -- the
  transcodes spend ~2.5x Sunshine's bits a macroblock (9.6 Mbit/s at 24-25 frames/s), which the
  CABAC front end pays for, and still decode with ~65 % to spare at film rates. **The rig:** the
  QSV transcode through the client (§10), errors / late / skipped 0, the raster at 576i from its
  VUI. **The transcode's timestamps** are the item's time plus a constant offset (~10 s on this
  server, the demuxer's `start_time`): a seek inside the HLS playlist lands where asked (the
  server restarts its transcoder at that segment), and the position is PTS minus `start_time`, as
  for a file -- one rule for both (`player_position`). `StartTimeTicks` in PlaybackInfo does not
  reach the transcode's URL: a start is a seek. The method: Through the profile of §2, by hand
  (curl, then ffmpeg pulling the HLS): a 16:9 film, a 4:3 item, a 25 frames/s (PAL) item, an
  interlaced item. Per stream: what the server chose (direct play or transcode, the size),
  then ffprobe and a header trace -- profile, level, **CABAC**, references, B-frames and
  pyramid, **the VUI's timing** (Refresh Rate Auto reads it: without `timing_info_present_flag`
  a 25 frames/s transcode does not switch the raster to 50 Hz -- the fallback is the program's
  settings request, word 35), **the colour tags** (§7 F2), the cropped size. Then the cosim
  (cycles a macroblock, bit-exact against ffmpeg) and the rig (`h264play --pts`: late /
  skipped / errors). Captures stay in `.sim/jellyfin/` (gitignored), never committed.
- **R2 -- the ARM's audio cost:** a static ARM `ffmpeg` (`-benchmark -threads 1`) decoding and
  downmixing 5.1 AC-3, E-AC-3 and AAC to 48 kHz s16 on the rig, beside Main. **Done 2026-10-01**
  (.201, stock Main on the menu core; FFmpeg n8.0 static, `-benchmark -threads 1`, 60 s of 5.1
  each, user + system time over the clip's length, the demux included): **AAC 7.0 %, AC-3 7.1 %,
  E-AC-3 7.1 %, Opus 11.7 %, DTS 12.8 %, TrueHD 36.9 % of one Cortex-A9 core.** Main keeps about
  one core busy; the other has room for any of them. So DTS can join direct play's audio list
  (saving the server an audio transcode of every DTS film); TrueHD stays off it (a third of a
  core, beside the demux and the network).
- **R3 -- a session with no video:** the core loaded, a session open for minutes with no
  access unit, the overlay shown over the idle screen: no starvation counter, no audio anchor,
  nothing in the status block that a later stream inherits (J5's ready screen depends on it).
  **Done 2026-10-01** (.201, main's SEED 6 build; a scratch program on libh264ring: a 400x120
  4444 panel shown, a session started, 120 s with no record, the status every 10 s, then 10 s of
  the QSV transcode (R1) in the SAME session with PTS; a control run with no idle): **the idle
  session raised nothing** -- READY throughout, the STC 0, errors / late / skipped / starved 0,
  `ovl_late` 0, the session kept -- and the clip after it played as in the control: 250 / 250
  pictures, errors / late / skipped 0, ENDED, `disp_reanchor` 1 in both (the stream's own first
  anchor). **Refresh Rate Auto switched the raster to 576i at 50 Hz from the transcode's VUI**
  (`raster_std` 2; 852x480 fitted to `fit_oh` 432 on the 4:3 raster). Two readings to know:
  `ovl_late` 2 came with that raster switch (480i -> 576i mid-session), not the idle (the
  control, already at 576i, added none; the counters are cumulative since the core's load);
  and a session with no picture yet reports the fit as `fit_crop_bad` 1 / `fit_clamp` 1 /
  `fit_oh` 8191 (F5).

## 6. Gates

- **A host test against a fake core AND a fake server** (Moonlight's `tests/run_test.sh
  --red` pattern; a capture cannot stand in for a server that answers): a stub HTTP server
  serving `PlaybackInfo` JSON, an HLS playlist and TS segments cut from fixtures (generated by
  x264 / ffmpeg, never others' media), Quick Connect's three calls and the WebSocket's Play /
  Playstate. Scored: every access unit byte-identical with its PTS, the audio equal to a
  reference decode, a seek = a flush and an IDR first, the pause on word 34, the reports'
  positions from the fake core's STC (not the demuxer's), the CAVLC / MBAFF check asking for a
  transcode, the keep-alive. **`--red`: each mutation caught by its own check.**
  **Built 2026-10-01** (`clients/jellyfin/tests/`, its `README.md`): `run_test.sh` (~45 s) --
  `test_client.c` runs the client (`-DCLIENT_TEST`) beside a fake core whose **STC runs at half real
  speed** (frozen under PAUSE), so a position taken from what was written runs seconds ahead of
  one taken from the STC; `fake_server.py`, a fake Jellyfin 10.11 (Quick Connect by POST only, the
  token enforced, a hand-written WebSocket, ranged media, the HLS chain) driving a scripted
  scenario (sign-in, a keep-alive, play A with its SRT, pause, unpause, seek, volume, stop; play B --
  a CAVLC file the client must refuse -- to its transcode's end); `check_client.py` scoring with
  `tools/ring_model.py`'s consumer against ffmpeg's references: (a) Quick Connect, (b) the profile's
  width-keyed band, (c) the keep-alive, (d) A's access units byte-identical with their PTS, (e) the
  PCM bit-identical to a reference decode, (f) the pause word, (g) the seek a new session from an
  IDR, (h) **every report within 0.6 s of the STC**, (i) the volume, (j) the CAVLC retry with direct
  play and stream copy off and none of its access units consumed, (k) the transcode to its END,
  (l) overlay flips after a session start (F6), (m) the subtitles fetched. **`--red`: 10 mutations,
  each caught by its own check** (the position from the demuxer, no CAVLC check, a seek without a
  flush, no pause word, no keep-alive, the height-keyed band, audio without PTS, the overlay's
  equal-generation wait, Quick Connect by GET, no END_OF_STREAM). It found one client bug: a
  Stopped report for a play the server never saw start (the CAVLC retry) -- fixed: Stopped only
  after a Start.
- **On the rig:** a film from the maintainer's server cast from a phone, start to end; pause,
  seek both ways, stop, resume from where it stopped; a PAL item (50 Hz raster); a subtitled
  item; 480i on a CRT / the RetroTINK; the status block clean.

## 7. Interface findings (not locked: each designed in `architecture.md` before it is built)

- **F1 -- the overlay is shown only during a session.** The ready screen and v2's browse screens
  need a session with no video open for as long as the client runs (R3). If that has side
  effects, the rule is revisited ("a program's overlay while the program holds the lock", say)
  before 1.0.
- **F2 -- the colour matrix.** The display converts BT.601 limited range always; a transcode
  of an HD source is BT.709 (the server's filter chain starts with `setparams=..bt709`
  unconditionally, 10.10 to 12.1), so reds and greens shift slightly. And an SD source
  transcoded is probably tagged 709 over 601 pixels (inferred from the same filter: R1 checks),
  so honouring the VUI blindly is wrong too. An RTL change (the reserved CONTROL record, or the
  VUI's matrix with an override): **its own branch**, after R1 says what servers really send;
  **designed 2026-10-06: `colour.md` (interface 0.16: the VUI's matrix and range, a record field
  to override). R4 measured 2026-10-06 (`colour.md` §6): the server tags EVERY transcode 709 and
  converts nothing -- an SD source's transcode is 601 pixels tagged 709, so the client overrides
  from the source's own `ColorSpace` on a transcode**;
  this branch stays ARM-only (no fit).
- **F3 -- `h264ring_refusal_name()`.** Moonlight's `mister.c` carries the `REF_*` names "until a
  second program needs it" (`moonlight.md` §2): this one does. **Done 2026-10-01:** an additive
  library call (no layout change, so the interface version stays 0.9), `integrating/library.md`;
  `hps/tests/test_ring.c` checks every `REF_*` code read from `h264_pkg.sv` against its name (a
  swapped pair goes RED). Moonlight's own table moves to it the next time its client is touched.
- **F4 -- the STC as the program's clock.** Word 7 (33 bits, 90 kHz) is enough for reports and
  subtitles if it is read often (a seqlock copy); whether a program also needs "the PTS of the
  picture on screen" (exact under pause and at a seek) is what this client will show.

- **F5 -- the fit's flags before any picture.** A session with no picture yet (the ready screen)
  reports `fit_crop_bad` 1, `fit_clamp` 1 and `fit_oh` 8191 (R3): nothing is shown, so nothing is
  wrong, but a program that reads the word reads a fault. Either the core reports "no picture" in
  the word, or the manual says the fit is meaningful only once `n_au` moves. Small; decided with
  the other findings. **Closed 2026-10-07, interface 0.17** (`architecture.md` "Version 0.17"): word 30's
  `fit_valid`, the fit's fields and word 80's place reading 0 while no picture is shown. On .201 the
  ready screen reads `fit_valid` 0 and every field 0 (`history.md` §40). ✅ MERGED (PR fj#42).

- **F6 -- `h264ring_overlay_wait` waited for an EQUAL generation** (found on the rig 2026-10-01:
  the ready screen stayed up over a playing film). Every session start re-writes the program's
  descriptor with a newer generation (`h264ring_start_session`, `h264ring_flush`), so a flip
  followed by a seek never saw its own generation reported: the client's double buffer stalled.
  **Fixed in the library** (no layout change: "at or past `gen`", a signed difference),
  `test_ring.c`'s new arm (GREEN with the fix, RED with `==`), the manual's library page; the
  client's own flip check uses the same rule.
- **F7 -- a fully static ARM binary's host-name lookups.** A static glibc loads the system's NSS
  modules (`libnss_files`, `libnss_dns`) for `getaddrinfo`, and that second libc is not set up for
  threads the static one created: curl's resolver thread crashed in `libnss_files` on the rig (the
  WebSocket's handle: a fresh lookup on a new thread). The client links glibc dynamically (2.31,
  MiSTer Linux's; a binary linked against it runs on any later glibc) and everything else
  statically -- still one file to copy. The Moonlight client (M4, fully static) did NOT reproduce
  it (`list` by DNS name, `localhost` and an IP: no crash, 2026-10-01); it makes one lookup per
  run. Recorded for the next static program, and for Moonlight if a crash on a named host is ever
  reported.

- **F8 -- word 47's `ar_x` / `ar_y` read 0 on the hardware** -- **FOUND 2026-10-01: 0 : 0 between streams** (after a stop, during a seek's restart: the fit of the reset 0x0 picture; `hdmi_raster.md` §7, fixed on `feature/hdmi-raster`); first **not reproduced** during playback on the same build
  (raw word and `h264stat`, 480i 4:3, Progressive 854x480 and 852x356 exact; the likeliest cause the instrument:
  `hdmi_raster.md` §7, which adds a wiring arm and a rig check). As first reported (2026-10-01, .201, main's SEED 6 build;
  `h264stat` while a 2.39:1 film played -- HDMI itself got the right aspect, and the same word's
  `ovl_lines` climbs). The packing is benched (`ring_rd_tb` drives 0x123 / 0x456) but `emu`'s
  `f_ar_x(VIDEO_ARX[11:0])` connection is not checked with real values anywhere. A program cannot
  learn the shape HDMI shows its overlay at. To find and fix on the A' branch (it needs the word);
  meanwhile the client follows the core's rule itself (`raster_aspect`: the OSD mirror's Aspect
  Ratio and Analog Aspect, the picture's display aspect from the server).
- **F9 -- the overlay on a picture wider than the display** (the maintainer, 2026-10-01: "squished
  vertically on scope movies in Progressive"). In Progressive with Aspect Auto the core fills its
  raster with the picture and gives ascal the picture's exact aspect, so a 2.39:1 film's raster --
  overlay included -- is shown as a 2.39:1 strip and the bars are ascal's, outside the raster.
  **Client side, done:** the overlay is drawn for the raster's displayed aspect (the glyphs'
  pixel aspect follows it), so its text keeps its shape. **Core side, decided 2026-10-01 (the
  maintainer): A'** -- roadmap Phase 6c's companion: letterbox INSIDE the raster only when the
  picture is wider than the HDMI display (the core knows HDMI_WIDTH / HEIGHT) and give ascal the
  display's shape; keep fill + exact aspect otherwise (pillarboxing a narrower picture inside a
  720-wide raster would cost horizontal pixels: a 640-wide 4:3 picture would get 540 columns).
  Letterboxing loses nothing (the core's vertical scale becomes ~1:1, ascal makes the one scale).
  Its own RTL branch after this one.
- **The overlay's text was ~21 % too narrow everywhere** (found with F9): the glyph scale multiplied
  by the pixel aspect instead of dividing (a 4:3 raster's pixels are narrow, so a glyph needs MORE
  of them across). Fixed.

## 8. Known limitations (v1, as proposed)

- No browse UI (J1): items are chosen in another Jellyfin app.
- Stereo only (D2); TrueHD / DTS-HD transcoded by the server.
- Bitmap subtitles burned in (a video transcode).
- 480-line transcodes for every frame rate (J3) until a 576 box per source is measured.
- Every interlaced file is transcoded (the server cannot tell PAFF from MBAFF).
- No HDR (tone-mapped by the server), no 10-bit, no HEVC / AV1 (the core decodes 8-bit H.264).

- The pad controls are built (§10) but not yet pressed by a person on the rig (the harness cannot
  press a pad).
- One stream at a time; a queue's next item starts when one ends (no gapless).
- An HTTPS server needs a certificate the bundled CA list trusts (a public one); a server with a
  self-signed certificate is reached over its plain `http://` address.

## 9. Next concrete step

The maintainer's turn on the rig: cast from a phone, the pad controls, a
CRT at 480i. Then merge. v2 (the browse UI, LVGL) was dropped (the maintainer, 2026-10-12): the client
stays a cast target.

## 10. As built (v1, 2026-10-01)

`clients/jellyfin/` (`README.md`): `src/player` (libavformat on a reader thread into a bounded
packet queue; the loop moves packets into the ring without blocking; avcC filtered to Annex B; the
last access unit carries END_OF_STREAM; audio decoded, AC-3 / E-AC-3 downmixed in the decoder,
resampled to 48 kHz s16, 20 ms records with their PTS; every request FFmpeg opens -- the HLS
segments' included, which inherit no TLS option -- verified against the bundled CA list through an
`io_open` hook), `src/h264check` (the SPS / PPS check), `src/core` (one session for the client's
life, the heartbeat, an OSD Reset's session re-opened), `src/jf` (REST and the WebSocket on
libcurl, cJSON), `src/ui` (the overlay in 4444 with DejaVu through stb_truetype, drawn for the
raster's pixel aspect inside a CRT's safe area, two pages, the band only the drawn lines),
`src/subs` (SRT), `src/input` (any pad, the keyboard, the OSD's two actions), `src/main` (the cast
loop; `play URL` for bring-up), `mister/jellyfin.sh` (the launcher). The build image adds FFmpeg
8.0.3 (LGPL), the CA bundle and the typeface to Moonlight's; cJSON and stb_truetype are vendored.
**FFmpeg's log stays at warning level:** its info level prints every URL, and a transcode's carry
the access token (`JELLYFIN_AVLOG` raises it for diagnostics only).

**On .201 against the maintainer's server (2026-10-01):** signed in by Quick Connect (the code
approved through the API as the test user; `state.json` kept, mode 600); the session
remote-controllable; *Brick* cast from 10:00 as a QSV transcode (576i from its 25 frames/s), paused,
unpaused, sought to 50:00 and stopped from the server; the reported position from the STC (21.1 s
over 21 s); *Meet Killface* direct-played (MKV, AC-3) with its SRT drawn on the overlay; the core's
errors / late / skipped / starved 0 throughout (4 audio underruns, all at stream transitions). The
first picture comes ~3 s after a start or a seek (direct play: the Cues read, then the jump; a
first read of a file once took 12 s -- the server's disk). Exit on SIGTERM ~0.2 s.

**The maintainer's round (2026-10-01, .201, a phone's Jellyfin app):** casting worked; pause and
stop worked; **the pad was hit and miss** -- a d-pad tap seeked, holding did nothing, and taps were
lost -- and **the subtitle button cut the picture to black** for a while. Causes and fixes:
- *Holding did nothing:* input acted on a button's press only. **A held d-pad direction / LB / RB now
  repeats** (`input.c`: first after 450 ms, then every 180 ms; the keyboard repeats by itself).
- *Taps lost, each tap slow:* every tap was its own seek, and a seek restarts the stream (a
  transcode: seconds); and the loop that reads the pad also made the 10 s Progress report over TLS
  (a few hundred ms), so a tap pressed and released inside either was never seen. **Seek steps now
  add up** (`seek_step`: the panel shows the target and "Seek"; the stream restarts once, 600 ms after
  the last step; the server's own Seek stays immediate) and **the reports go out on their own thread**
  with their own connection (`struct reporter`, drained at exit so the last Stopped still goes).
- *Black at the subtitle button:* every track change asked the server for a new stream -- a
  transcode restarted from scratch (~7 s of black, reproduced). **A text track is now the overlay's
  alone** (`set_subs`: a PlaybackInfo probe for the new index -- it does not disturb the running
  transcode, measured -- then only the SRT is fetched or dropped); only a track the server must burn
  in restarts the stream, and says so. Verified on the rig: *Jurassic Park*'s SRT switched on with the
  picture playing throughout.
- *No sign of a restart:* the panel now says **Loading** from a start or a seek until the first
  picture.
(One rig lesson: copying a new client over a running one fails with "Text file busy"; a deploy
that hid the error left the rig on the old build for a round. The checksum is compared now.)

**Seeking without the black, and faster (asked by the maintainer, 2026-10-01: "it cuts to black
for a second or two").** The black was the whole open: `h264ring_flush` first (the display black
until a new picture), then the new stream's connect, probe and first IDR. Two changes:
- **The old picture holds.** A seek or a track change while a stream is on screen PAUSES the core
  (the picture holds, the sound stops) and opens the new stream HELD (`player_cfg.hold`): the
  player demuxes up to the first IDR, checks it, and stops at `PL_READY` writing nothing; only
  then does the client flush, restore the pause state and release it. The black is the IDR's
  decode; the panel shows the target and **Loading** over the frozen picture meanwhile. A seek's
  Progress report goes out at the release (the position is the new stream's then). On the rig,
  0.7 s into a seek: the old frame up, "Loading", the target time.
- **The open is shorter.** Measured per stage (`CLIENT_TIMING`): a transcode's open fetched the
  server's whole playlist, so FFmpeg probed segment 0 -- the server started transcoding the
  film's beginning -- and the seek then killed that and started again at the target: two encoder
  starts. **The client now trims the playlist** (`trim_hls`: each segment URL carries its start as
  `runtimeTicks`; a playlist from the target's segment, written to /tmp, opened as HLS): one
  encoder start, at the target. (`StartTimeTicks` on the playlist URL is no help: the server sent
  nothing in 174 s.) The probe reads at most 1 MB / 0.5 s (it read up to 5 MB / 5 s: ~1 s of a
  transcode's start), and a file's range requests share one connection (`multiple_requests`).
  First IDR after the open, on the rig with the maintainer's server:

  | | before | after |
  |---|---|---|
  | transcode, cast at 17:44 | 5.49 s | **3.05 s** |
  | transcode, seek to 33:20 | 5.79 s | **3.72 s** |
  | direct play (MKV), cast at 5:00 | 2.61 s | **2.16-2.21 s** |
  | direct play, seek | ~2.9 s | 2.80-2.88 s (the Cues read and the jump: ~1.1-1.5 s) |

  What is left of a transcode's is the server starting its encoder at the target (~3 s on QSV);
  a direct play's seek is the Matroska index read over HTTPS.

## 11. The maintainer's hands-on round (2026-10-01, reported by the hdmi-raster session)

Status: **✅ MERGED (PR fj#27)**, with the file player. ⏳ HW-confirm pending: the fixes below, and the
screensaver on this client, are host-tested; not yet run against the maintainer's server.

Two defects, fixed on `feature/file-player` (where the client's code now lives with the file
player's: `docs/player.md` P1):
- **A subtitle (or audio) switch froze the picture and the overlay for seconds.**
  - The cause: `set_subs()` asked PlaybackInfo and fetched the `.srt` on the loop's thread, and
    `start_item()` fetched it through `load_subs()`. The film was an MKV with 27 embedded text
    tracks, which Jellyfin extracts on the first request (later answers took 0.2 s).
  - The fix: both requests run on a **subtitle fetcher thread** with its own connection
    (`jf_clone`, as the report thread does). One job at a time: a newer one replaces a waiting
    one, and a result is applied only if its generation is still current. "Subtitles:
    Loading..." shows meanwhile. A burned-in track's restart and the cues are applied on the
    loop's thread when the answer arrives.
  - Host test: (r) checks no loop stall over 0.25 s during a 2.5 s `.srt`; M19.
- **English on, no subtitles shown.**
  - The cause: an External subtitle's DeliveryUrl, `.../Subtitles/{index}/{startTicks}/Stream.srt`,
    carries the PlaybackInfo's `StartTimeTicks`. The server drops the cues before that time and
    shifts the rest by it (`SubtitleController` -> `SubtitleEncoder.FilterEvents`, `copyTimestamps`
    false). The switch came at 297.9 s, after a transcode seek, so the cues came back rebased to 0,
    while the client looks cues up at the item's time.
  - A cast resumed mid-film had the same defect.
  - The fix: `whole_track()` in `jf.c` sets the start to 0: the whole track, its own times.
  - Host test: (u); the fake server now builds the URL and rebases as Jellyfin does; M18.

**Since (2026-10-01): the screensaver, `player.md` P5** (asked by the maintainer for this client's
Ready to play screen too).
- `ui.c` dims the screen after 5 minutes while nothing plays: the ready card, the sign-in code,
  a paused film. It goes black at 30.
- Activity is a button, or a Play / Playstate / GeneralCommand from the server. The server's
  other broadcasts are not activity.
- The press that wakes it is dropped. The sign-in wait also reads the pad for that.
- `jellyfin.ini`: `screensaver_dim=` / `screensaver_black=` (minutes, 0 off).
- **Gate:** the file player's host test ((z1) / (z2), M11-M13) proves `ui.c`'s stages, the veil's
  pixels and the dropped press. This client's own integration (the server-command filter, the
  busy state while a film plays, the sign-in wake) is NOT covered by its host test yet; it is
  checked on the rig.

**Known since §11:** the subtitle fetcher's thread is joined at quit. A fetch still running (a
first extraction of many tracks) delays the exit until curl's timeout (20-30 s) at worst.

**Since the rebase onto 0.10 (2026-10-02, `player.md` §3):** `ui.c` draws for the raster's own
width as well as its lines (`raster_width()` beside main's `raster_lines()` / `raster_aspect()`),
so the overlay and the screensaver's veil span a Native (HDMI) raster up to 1,024 wide. The
host test's T8 hooks are `client_test_par` / `client_test_lines` (in `clients/common/ui.c`).

## 12. A transcode with no audio, and a freeze (found 2026-10-09; client fixes `fix/jellyfin-transcode`)

Status: **the client's fixes ✅ MERGED (PR #9), ✅ HW-CONFIRMED 2026-10-11** (the maintainer's round; host tests GREEN and `--red`; verified on .201 with the maintainer's film,
control arm first (`history.md` §45: 1.0.0's client froze and played two opens silent; this branch clean on
every open). **The core's livelock: interface 1.1, ✅ MERGED (PR #10), ✅ HW-CONFIRMED 2026-10-11**
(`history.md` §46: 1.0.0's client plays the freezing open on it) (Part B,
`architecture.md` "Queued audio: a late picture never runs the clock back over it").

**What the maintainer found (2026-10-09, testing 1.0.0 on .201).** A 1080p HEVC 10-bit film with surround
sound, transcoded by the server to H.264 1280x720 at 9.6 Mbit/s with stereo AAC 384k (the HD box,
Native (HDMI)). A 1 s logger of the status block ran beside the client's log.
1. **After some opens (a start, a seek), no audio for the whole stretch.** The core's `n_audio` stayed 0.
2. **A freeze that only a seek ended:** about 1 s of progress every ~20 s.

**Causes.**
- *No audio (the client).* At 9.6 Mbit/s the probe (1 MB / 0.5 s, sized in §10 for the 854x480
  transcodes) can end before the TS's first audio packet. FFmpeg then knows the AAC stream only from the
  PMT: no sample rate, no channels ("unspecified sample rate"). Two things then dropped it, measured on a
  fixture (`tools/ts_skew.py --audio-from 3`):
  - `av_find_best_stream` passes over an audio stream with no channels or rate: a transcode
    (`audio_stream` -1) got none at all;
  - `open_audio` built swr from those parameters and failed (EINVAL) when the track had been named
    (direct play's `audio_index`).
  The decoder itself opens with rate 0 and decodes 48 kHz stereo from the ADTS headers. And a probe
  of 4 MB / 2 s misses the same fixture, so a larger probe alone is no fix.
- *The freeze (triggered by the stream, held by the core).*
  - After a seek the server's TS put the audio more than 5 s ahead of the video: its video encoder lags,
    and FFmpeg's muxer interleaves up to 10 s. The logger saw 266 audio records in one second.
  - The client wrote records in demux order. The core's 256-record audio queue (5.12 s) filled, so it
    stopped reading the ring (by design, `integrating/audio.md`), and the video behind that audio starved.
  - Late pictures then re-anchored the clock back (`disp_reanchor` 1 -> 16 in 100 s). The queued audio was
    early again and waited, playing silence (`aud_state` 1, `aud_gap` growing), and the FIFO never
    drained. Then, with the FIFO no longer full, unplayed early audio held the read index of a full 8 MB
    ring, so the program could not write. That is the core's part (below).

**The client's fixes** (`clients/common/player.c`, so the file player has them too):
- **The audio is held to ~1 s ahead of the video.**
  - The reader's one queue is now two: video and subtitles (512 packets / 6 MB, as before), and audio
    (1,024 / 2 MB: ~20 s of AAC). Each packet keeps the demuxer's order.
  - `take()` pops in that order, except that an audio packet more than `AUD_LEAD` (1 s) past the newest
    video PTS handed on waits. So does audio before the first picture: it is no longer dropped when it
    came first, only by its frames' times. The video goes on meanwhile.
  - Audio goes anyway when nothing else can come: the reader done, or the audio queue full with no video
    queued (an audio-only stretch). Otherwise the reader, blocked on the full audio queue, would never
    bring the video the loop waits for. These packets are counted (`audio_forced`).
  - At close the log says how far ahead the stream's audio ran, if more than 1 s.
  - An untimed packet (a PES's later frames) is placed at the time the decoded audio has reached.
- **An audio stream the probe missed is played.** If `av_find_best_stream` finds none, the first audio
  stream a decoder exists for is taken. `open_audio` no longer builds swr: `audio()` builds it per frame
  from the frame's own layout and rate (the DTS fix of 2026-10-06 already did).
- **Every record keeps a PTS.** With the rate unknown, the TS demuxer times only each PES's first AAC
  frame (410 of 469 records went out untimed on the fixture). The interface allows an untimed record (it
  follows the one before), but a frame without a time now takes the time where the previous frame ended
  (`apts_next`). The frames before the first picture are dropped by that time.
- **The probe stays 1 MB / 0.5 s** (decided by the rig's measurement, below). A 4 MB / 2 s probe for
  network inputs was built and measured. On the same opens it missed the same audio ("unspecified sample
  rate" on both), and its stream-info stage took ~0.15-0.2 s longer an open (250-290 ms against 55-130).
  The fallback above is the fix, and the larger probe was reverted.

**Gates.**
- The Jellyfin host test (`clients/jellyfin/tests/`) has **item D**: a source only a transcode can carry,
  whose one 10 s TS segment has no audio in its first 3 s of video and then the audio 6.4 s ahead
  (`tools/ts_skew.py` moves the audio's PES units; every timestamp as encoded).
  - (v): every AUDIO record within 1.3 s of the newest video before it in the ring (1.16 s measured;
    6.4 s without the fix), every access unit the playlist's, and the item played to its end.
  - (w): the PCM equal to a reference decode, every record timed.
  - Both first check, from ffprobe's packets, that the fixture still holds its skew.
  - Mutations M22 (demux order) -> (v); M23 (no fallback stream), M24 (swr at open), M25 (no PTS carry)
    -> (w).
- The file player's test has `l_ahead.ts` (audio 6.4 s ahead) and `m_late.ts` (no audio in the first 3 s):
  (x) and (y), M30-M33. Its `wait_ended` now latches an end: a folder's last file opens the list's session
  the moment its ENDED is read, faster than the script's 2 ms poll. M29 (swr built once at open) is now
  written for the per-frame swr alone.
- The fake cores still consume at once, with no 256-record gate. The checks score the client's rule
  directly in what it wrote; that the core then does not freeze is the rig's to show.

**On the rig (2026-10-10, `history.md` §45).** The same film, cast through the server's API, with 2026-10-09's
four opens:
- 1.0.0's client froze on the first (the clock 21 s in 60 s, 6 re-anchors, `aud_q_rec` 256) and played the
  next two without audio;
- this branch played all four with audio, no re-anchor, `aud_q_rec` <= 86. The probe still missed the
  audio on two opens, and the fallback decoded it;
- the client held back audio running up to 2.5 s ahead on ordinary opens.

**Not fixed by the client:** audio BEHIND the video in the stream (the mirror case). The core reads video
only as fast as it decodes (~0.5 s ahead of the clock), so audio that arrives seconds after its video is
played late or dropped. Not seen from a server; holding video back for it would stall the picture
whenever the audio is sparse. Left until a source shows it.

**The core's part (Part B, designed in `architecture.md`, not built):** whatever a program writes, the
core must not livelock. A program's interleave can still fill the queue: a program without this
client's rule, or a source whose audio leads by more than the ring holds.
