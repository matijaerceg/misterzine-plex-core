# The file player (Phase 7's third example integration)

Engineering note. Status: **✅ MERGED (PR fj#27), ✅ HW-CONFIRMED 2026-10-02** (the maintainer's
round on .236, every test successful: `history.md` §26). Rebased onto interface 0.10 before the
merge. ⏳ A CRT at 576i.
- Decided with the maintainer: P1-P5 (P4 accepted as built 2026-10-02; P5 the screensaver). P6 follows
  from fj#20's merge (CAVLC through the library's rewrite).
- Built: `clients/common/` (the Jellyfin client's modules, shared) and `clients/player/`.
- The host test (§6) GREEN and `--red`; the Jellyfin client's test GREEN and `--red` after the
  move.
- The ARM build of both clients in `mister-h264-clients:deps2`.
- **On the rig** (`history.md` §26): browse, play, the folder playing on, 50 Hz and back to Auto,
  three refusals, quit. 854x480p60 at 8 Mbit/s: errors and late pictures 0.
- The maintainer's round (2026-10-02, .236, a pad): pause, seek, subtitles, 50 Hz, the refusals,
  CAVLC, Native (HDMI), the screensaver -- all successful.

**Other codecs decoded on the ARM (P7, interface 0.15) ✅ MERGED (PR fj#35), ✅ HW-CONFIRMED 2026-10-06 (the maintainer: .236's CRT and .201):**
designed and decided with the maintainer 2026-10-05 (P7 below; the interface in `architecture.md`
"Pictures from the program"). Built: the RTL (`h264/pic_in.sv`, `ring_rd`'s PICTURE path, word 84),
the library's store rule and copy, `clients/common/vdec.c` and the player's picture path; every
runner it touches GREEN and `--red` (`run_ring_rd.sh` R28-R33, `test_ring` / `test_hps_lib`, the
player's host test p1-p3 / T10, 26 mutations; the Jellyfin test unchanged and GREEN / RED). Fit SEED 6
PASS (102.95 / 102.9, 90 % ALM); the ARM build in `deps3`; **on .201** (`history.md` §35): every store
byte-exact against the ARM's decode, nine codecs in real time (MPEG-2 480i 51 %, Xvid 49 %, MJPEG 75 %
of a core), refusals by name. ⏳ The analog chain, the maintainer's round.

Asked 2026-10-01 (the maintainer): "a video player HPS app: what formats can we support?"

`h264player` plays video files from the MiSTer's own storage through the core. Users find the
files on the SD card, a USB drive or a network share Linux has mounted. The program runs on the
ARM and does these jobs:
- shows the folders on the overlay plane (interface 0.9) and takes the pad through the core's
  input region (0.6);
- demuxes the file with libavformat and checks the stream's SPS / PPS before a byte reaches the
  ring;
- decodes the audio to PCM;
- hands the core H.264 access units and PCM with their timestamps, through `hps/lib`.

Nothing is transcoded: the A9 cannot re-encode video in real time, and the ring takes only H.264.
So **what plays is the core's envelope, not the player's** (§2). Everything outside it is refused
by name, never sent as garbage.

**What it exercises that the Jellyfin client did not:**
- the settings request (word 35) used by a program, per file (P4);
- text subtitles taken from the file itself (no server converts them);
- a refusal with no fallback;
- a browse UI on the overlay.

## 1. Decisions

| # | Decision | Alternatives, and why not |
|---|---|---|
| P1 | **One code base for the two FFmpeg clients** (decided 2026-10-01). The Jellyfin client's `player`, `h264check`, `core`, `input`, `ui` and `subs` move to `clients/common/`. Both `clients/jellyfin/` and `clients/player/` link them, as two binaries. The FFmpeg build image is shared too: `clients/common/docker/`, tagged `mister-h264-clients:deps2`. | **A file mode of the jellyfin binary**: quickest, but it ties a local player to a server client's build (curl, a CA bundle) and its launcher. **A copy in `clients/player/`**: every fix would be ported by hand, as `docs/harvest.md` does between the cores. |
| P2 | **A browser drawn on the overlay, driven by the pad** (decided 2026-10-01). A Scripts-menu launcher (`Scripts/h264player.sh`, J5's pattern) runs the player detached. It loads the core and shows the video folders over the idle screen. Pad: up / down, LB / RB a page, A open, B back, Back + Start quit. | **Main's file picker**: the core has no OSD slot that reaches the ARM program (the ioctl stand-in was removed in P3). **A fixed folder played in order**: no choice of file. |
| P3 | **v1 is the core's envelope plus embedded text subtitles** (decided 2026-10-01). Not in v1: CAVLC (fj#20, a CAVLC-to-CABAC rewrite on the ARM, its own work), extra containers (AVI / FLV / PS) and MP2 / ALAC, bitmap subtitles (PGS / VobSub on the overlay), and 720p (a D1 decision on the RTL: taken 2026-10-02, roadmap Phase 5c -- 720p plays since interface 0.11). | Each of those widens what plays; none is needed to prove the player. |
| P4 | **The refresh rate from the file when the user's choice is Auto** (proposed 2026-10-01; **accepted as built by the maintainer 2026-10-02**, over the narrower "only when the SPS has no VUI timing" and dropping it). Refresh Rate Auto picks the raster from the stream's VUI rate. A 25 / 50 frames/s file without VUI timing would play on 59.94 Hz and judder, which matters for PAL files on a 576i CRT. So, at a file's start, while the OSD's Refresh Rate is Auto (or the player's own 50 Hz), a 25 / 50 frames/s file (the container's rate) asks for 50 Hz through the settings request. A file of any other rate gives Auto back, and so does the player when it ends. **A rate the user chose in the OSD is never touched.** The request is cleared once the core consumed it (`h264ring_clear_settings`), so a new session never re-applies it over the user's later choice. | **Leave it to Auto**: VUI-less PAL files judder. **Ask for 50 Hz only when the SPS has no VUI timing**: needs a VUI parse in `h264check`; the simpler rule is right for every file Auto would have put on 50 Hz anyway. While a PAL file plays, the OSD shows "50 Hz", not "Auto". |
| P6 | **CAVLC files play, through the library's rewrite** (2026-10-02, at the rebase onto 0.10: fj#20 merged with the rewrite inside `h264ring_write_au()`, `docs/cavlc.md` §9, "on by default in `h264play` and the Moonlight client"). The player lets a CAVLC verdict through (`player_cfg.cavlc_ok`): the write call rewrites each unit into CABAC, losslessly. **The ceiling is the A9's:** ~11-12 % of one core per Mbit/s at 480p60, so up to ~4-5 Mbit/s plays in real time; past it, pictures are late (the core's counter, `cavlc.md` §8a). `h264check` now names CAVLC **last**, so a CAVLC file is still refused for its size, MBAFF, chroma or bit depth. A file the rewrite cannot carry (FMO, ASO, redundant pictures, data partitioning: `-EOPNOTSUPP`) is refused with the library's reason; a unit it cannot parse (`-EBADMSG`) is dropped and playback resumes at the next IDR, counted (`rewrite_skipped`). The Jellyfin client keeps asking its server for a transcode, as `cavlc.md` §8 decided. | **Refuse CAVLC still** (P3's v1): phone and webcam clips are the files most people have at SD. **Rewrite on the reader thread** (`h264ring_prepare_au` does not run off the ring's thread: the library is not thread-safe), so the rewrite's time is the loop's: input and the overlay are slower on a dense CAVLC file. |
| P7 | **Other codecs decoded on the ARM, shown as pictures** (decided 2026-10-05 with the maintainer, after `experiments.md`'s measurements: "the measured-comfortable set", "a raw-picture record", "Jellyfin unchanged"; SD only after step 0's copy measurement). MPEG-1 / MPEG-2, MPEG-4 Part 2 (Xvid / DivX 4-6), MS-MPEG4 v1-v3 (DivX 3), WMV7 / WMV8, Theora, MJPEG and H.263 are decoded by libavcodec on a thread of its own (`vdec.c`) **up to 720x576 at 30 frames/s**; each picture is copied into one of the core's DPB stores by the library's store rule and sent as a PICTURE record (interface 0.15), so the core shows it as its own: fitted, deinterlaced (an interlaced picture is a woven field pair), anti-twittered, paced against the STC with the audio. Anything else -- HEVC, AV1, VP8 / VP9, VC-1, FFV1, an SD codec above 720x576 or 30 frames/s, a pixel format other than 8-bit 4:2:0 / 4:2:2 -- is refused by name before the ring. **The budget:** one A9 core (Main holds the other); decode (0.22-0.42 at SD, `experiments.md`) + the copy into the strongly-ordered stores (~97 MB/s: 5.3 ms of CPU a 720x480 picture, 0.16 of a core at 30 frames/s) + ~0.1 for audio, demux and UI under ~0.8. MPEG-2 720p30 (1.05) and 480p60 (0.94) do not fit: SD only (decided 2026-10-05). | **The overlay plane, RGB** (no RTL): the conversion on top of the copy, no fitting or deinterlace, the program pacing its own frames. **A fabric MPEG-2 decoder** (MiSTer_DVD's): the fabric is at 90 % ALM, and MPEG-2 is the cheapest codec on the ARM. **720p30 / 480p60 that falls behind** (frame dropping): visibly jerky; the maintainer chose SD only. **Jellyfin direct-playing them**: its server transcodes already (kept as it is). |
| P5 | **A screensaver against burn-in, in `clients/common/ui.c`: both FFmpeg clients** (decided 2026-10-01 with the maintainer: "it needs some kind of screensaver or OLED burn-in protection"). **When it runs:** nothing has happened for 5 minutes and no video is playing (a list, the ready or sign-in card, a paused or ended picture). Activity is a button, a server command (Jellyfin), or video playing. **Stage 1, 5 min:** a 75 % black veil over the whole raster, so the picture and the core's idle bars are dimmed too; the overlay is above both. One line fades in at a random place in the safe area, holds, fades out, and comes back elsewhere. It says what is up: "Paused · title · 1:02:13", "Ready to play", the folder, or the sign-in code. **Stage 2, 30 min:** fully black, the same line. Any button wakes it, and that press does nothing else. Both times are in the program's ini (`screensaver_dim=`, `screensaver_black=`, in minutes; 0 off). | **A clock**: a stock MiSTer has no RTC, so its time may be wrong. **A moving logo / text**: the maintainer preferred fading in random places. **Pure black at 5 min**: looks like the MiSTer hung. **Pixel shift only**: not enough for hours on a list. **In the core** (an OSD option blanking the idle bars and a frozen picture in the fabric, which would also cover Moonlight): a fit at 84 % ALM and an interface note; later, if wanted. |

## 2. The envelope (what plays)

The core decides it; the sources are `docs/spec_hardening.md`, `docs/high_profile.md`,
`h264/dec/sps_pps.sv` and `h264/dec/recon_top.sv`.

| | Plays | Refused (by the player, before the ring) |
|---|---|---|
| Video (P7, decoded on the ARM) | MPEG-1, MPEG-2 (DVD rips, broadcast recordings; interlaced as field pairs, repeat_first_field as pic_struct), MPEG-4 Part 2 (Xvid, DivX 4-6), MS-MPEG4 v1-v3 (DivX 3), WMV7 / WMV8, Theora, MJPEG (4:2:2 / full range converted), H.263 -- **up to 720x576 at 30 frames/s**, 8-bit 4:2:0 or 4:2:2 | the same codecs above 720x576 ("larger than SD: too much for the ARM") or 30 frames/s ("too fast for the ARM"); HEVC, AV1, VP8 / VP9, VC-1 / WMV9, FFV1, ProRes and the rest ("the MiSTer cannot decode it"); other pixel formats (4:4:4, 10-bit) |
| Video | H.264 Main / High (CABAC), and CAVLC (Baseline / Constrained Baseline: phones, webcams, old iPod files; Main / High coded CAVLC) rewritten into CABAC by the library (P6, up to ~4-5 Mbit/s at 480p60 in real time); 8-bit, 4:2:0; progressive or field-coded (PAFF); any shape up to **3,600 macroblocks** a picture (interface 0.11: 1280x720, 854x480, 720x576 and smaller, cropped; 1,620 before); 23.976-60 frames/s, up to **108,000 macroblocks a second** (720p at 30 or less, 480p at 60) | 1080p (more than 3,600 macroblocks); 720p at 50 / 60 frames/s ("too fast": 216,000 a second); MBAFF interlaced (x264's `--interlaced`); High 10 (most fansubbed anime), 4:2:2, 4:4:4, monochrome; Baseline / Extended features the rewrite cannot carry (FMO, ASO, redundant pictures, data partitioning) |
| Rate | Real time up to 97,200 macroblocks a second (854x480p60 at about 10 Mbit/s; 1.43x on the rig, `history.md` §19); 720p24 films (x264 B-frames: ~1.2x estimated at 4 Mbit/s, marginal at 8 Mbit/s of dense content, `mb_pipeline.md` §4g); 720p30 is 108,000 -- real time for light streams, behind for x264 above ~4 Mbit/s until roadmap Phase 5c part 2 | A file above 108,000 a second is refused by name (`h264check`'s rate check, 0.11, from the container's frame rate; a rate of 0 or above 120 -- a VFR file, a remux's time base -- is taken as unknown: no rate check); a heavy one below it decodes correctly and falls behind visibly (the late counter) |
| Audio | AAC, AC-3, E-AC-3, DTS (core), MP3, Opus, Vorbis, FLAC, mixed down to 48 kHz stereo on the ARM (R2: about 7-13 % of one A9 core); (P7) MP2 (DVDs, broadcast), LPCM (DVD, WAV in AVI), WMA v1 / v2, IMA / MS ADPCM | TrueHD (not built: 37 % of a core, R2); its file plays silent unless another track is picked; ALAC (not built: P3) |
| Containers | MKV / WebM-with-H.264, MP4 / MOV / M4V, MPEG-TS / M2TS / MTS, raw `.264` / `.h264`; (P7) AVI / DivX, MPEG-PS (`.mpg`, `.mpeg`, `.vob`), MPEG elementary (`.m1v`, `.m2v`), ASF (`.wmv`, `.asf`), Ogg (`.ogv`), 3GP | FLV |
| Subtitles | A `.srt` beside the file (`name.srt` or `name.<lang>.srt`); the file's text tracks: SRT, ASS / SSA (as plain text), mov_text, WebVTT | PGS, VobSub, DVB (bitmaps: not shown, not offered) |

**Why the check is the player's:** a stream over the core's bound (3,600 macroblocks since
interface 0.11, word 81's `cap_max_mbs`; 1,620 before) is not refused by the core at the SPS.
- If both dimensions are within 128 macroblocks, the SPS passes. `recon_top` then drops every
  slice: a blank screen, with only `rc_ref_size` (status word 20) counting.
- `REF_SIZE` (12) is raised only for a dimension past 128 macroblocks (`sps_pps.sv`).
- So the player runs `h264check` on the first access unit (the Jellyfin client's check, J3)
  before anything is written. The core's own refusals (`fe_refused`) are still watched as a
  second net.

**The user's way out:** on screen, "Cannot play: <reason>", and "Convert it on a computer: the
manual's Compatibility page". The page gives one ffmpeg command:
- `-c:v libx264 -profile:v high -vf scale=w=854:h=480:force_original_aspect_ratio=decrease:force_divisible_by=2`;
- this fits any shape inside 854x480 (16:9 -> 854x480 = 1,620 macroblocks; 4:3 -> 640x480);
- PAL sources may keep 720x576; since interface 0.11 a 1080p source may become 1280x720 at its
  own rate up to 30 frames/s (a 60 frames/s one at 854x480).

## 3. The design

### Files

| File | Role |
|---|---|
| `clients/common/player.c` | The Jellyfin client's player. It adds `player_info()`: duration, frame rate, size and display aspect, the audio tracks with their names and whether each is playable, and the text subtitle tracks. With `text_subs`, it decodes every text track into cues as the demuxer passes them (`player_subs()`). A raw `.264` is written without PTS (`raw`). Video that is not H.264 fails with "the video is HEVC (H.265), not H.264". The default audio track is the best one *a decoder was built for*: a film's default TrueHD track no longer leaves it silent. |
| `clients/common/vdec.c` (P7) | `vdec_allowed()`: the codec list and the SD budget, a refusal as words. `vdec_open()`: libavcodec, one thread (`thread_count` 1: one core), `apply_cropping`; a decode thread at nice +4 between a 16-packet queue and a 4-picture queue (`vdec_put` / `vdec_get`, both bounded: the loop stops popping packets while the decoder's queue is full, which bounds how far the audio runs ahead). `vdec_skip_nonref()`: reference pictures only while behind. `vdec_pix()`: the store copy's source formats. |
| `clients/common/player.c` (P7) | Behind `player_cfg.arm_video` (the file player's alone: Jellyfin leaves it 0, its path textually unchanged): a video stream that is not H.264 goes to `vdec`, or the open fails with `vdec_allowed()`'s reason. `sw_pictures()`, at most one picture a step (its copy ~5 ms of the step's 10): the next decoded picture, written once another waits behind it or the decoder is drained (the last carries END_OF_STREAM); a store by `h264ring_picture_acquire`, the copy, `h264ring_try_write_picture` (a full ring keeps the store and retries). From the frame: `AV_FRAME_FLAG_INTERLACED` / `_TOP_FIELD_FIRST` -> a woven pair; `repeat_pict` 1 / 2 / 4 -> pic_struct 5-6 / 7 / 8; the SAR (`av_guess_sample_aspect_ratio`); the stream's rate (1-120 frames/s, else none); `best_effort_timestamp` in 90 kHz. A picture already 100 ms late is dropped before its copy (`pics_late`); five in a second switch to reference pictures only for two seconds (`pics_nonref`). Held opens work as for H.264: the first picture decoded is `PL_READY`, and nothing is copied before the release's flush. |
| `clients/common/player.c` (2026-10-10, `docs/jellyfin.md` §12) | Two reader queues (video and subtitles; audio), popped in the demuxer's order except that audio more than 1 s past the newest video waits (the core's 256 records are 5.12 s: a stream whose audio runs further ahead stopped the picture). An audio stream the probe missed (no sample rate yet) is still played, its decoder reading them from the stream; every audio record keeps a PTS. The probe stays 1 MB / 0.5 s. Host test (x) / (y). |
| `clients/common/subs.c` | `subs_add()`: one cue, kept in start order. An ASS event's Text field is taken: `\N` becomes a line break, `\h` a space, and a vector drawing (`{\p1}`) is dropped. `subs_at()` joins the cues that overlap, a line each (two speakers). |
| `clients/common/ui.c` | `ui_card` (Jellyfin's ready screen, generalised) and `ui_list`: the browser, the whole safe area, a page around the selection, a scroll bar. **Since 0.10 the canvas is the raster's own width** (`ui_draw(u, w, lines, aspect)` from `h264ring_raster()`): 720 fitted, the picture's size on Video Output "Native (HDMI)" (up to 1,024 x 2,047). Rows are `STRIDE` (1,024) pixels apart; a page holds the tallest raster two of which fit the framebuffer (MiSTer_fb's region: all 2,047 lines); a taller raster's canvas is clipped and centred by the core. The pixel aspect is `aspect * lines / w`. |
| `clients/common/ui.c` (2026-10-06) | **The safe area: title-safe on an SD raster.** The maintainer, on a CRT: much of the UI's text was cut off by the overscan. On a raster of at most 576 lines (the analog rasters, Interlaced or Progressive, and an SD picture's native one -- a TV overscans that too) every screen keeps inside 10 % of the width and the lines from each edge (SMPTE RP 27.3's title-safe: 72 px x 48 / 57 lines at 720 x 480 / 576); a larger native raster keeps the old 40 px x 28 lines. `u->mx` / `u->my`, set at each raster change; panel backgrounds may reach 10 px outside. The list's page is 9 rows at 480 (was 10). Shared with the Jellyfin client. |
| `clients/common/ui.c` (2026-10-07) | **The card's lines wrap.** The maintainer: the Jellyfin ready card's "...play it on this MiSTer" was cut at "MiST" -- the title-safe card (576 px at 720) is narrower than the line. The card's line and note now word-wrap to its width less a 16 px margin, up to three lines each, BALANCED (the narrowest width that needs no more lines: no lone last word), the card growing and staying centred. On .201 at 480i: two even lines inside the card. Shared by the three clients. |
| `clients/common/ui.c` (P5) | The screensaver: `ui_saver_times`, `ui_activity` (a server command), `ui_busy` (video playing), `ui_wake` (a button: 1 when it only woke the saver; the caller drops the press). With no activity for the dim time, every page is the veil (alpha 11 / 15, the whole raster, nothing else drawn) and one 22 px line. The line's colour alpha follows a 2 s fade in, 6 s hold, 2 s fade out and 1 s gap, and it moves to a random place in the safe area each cycle. Its text comes from the UI's own state: the paused title and position, the list's title, or the card's title and code. |
| `clients/common/input.c` | `nav`: a list's mapping (up / down / page / ok / cancel), the same edges and held-button repeats as playback's. N / P: next / previous. |
| `clients/player/src/browse.c` | A folder's sub-folders, then its video files (by extension). Case is ignored and numbers compare by value ("Episode 2" before "Episode 10"). Hidden entries are left out. The roots: those that exist; a `/media/usbN` only when something is mounted. |
| `clients/player/src/main.c` | The browser and playback (below). |

### Playback

Every open is **held**: `player_open(hold=1)`. The player stops at `PL_READY` with the first IDR
checked:
- **A refusal** (`PL_UNDECODABLE`, or the video not H.264) never reaches the ring.
- **A new file:** at its first `PL_READY`, the refresh rate (P4) and the default subtitle track
  are set. Then `core_new_stream` (the flush) and `player_release`.
- **A seek or an audio track change:** the core is paused (the picture holds), and the flush
  comes at the new stream's `PL_READY`. This is the Jellyfin client's held seek.

The controls:
- Seek steps add up and are applied 600 ms after the last.
- A file's end plays the next file in the folder. The end of the folder, or a refused file,
  returns to the list.
- Position is the core's STC (F4) minus the file's `start_time`.

### Subtitles

The track a file starts with:
- the `.srt` beside the file, if there is one (someone put it there);
- else the file's text track marked default or forced;
- else none.

X steps Off -> each text track -> the `.srt` -> Off, at once: every text track's cues are
collected as the demuxer passes them, so a switch never restarts the stream (Jellyfin's M11
lesson). Cues are drawn as plain text, at the bottom, up to four lines (`ui.c`).

### The launcher and files

| Item | |
|---|---|
| `Scripts/h264player.sh` | Makes `/media/fat/video`, runs `/media/fat/h264player/h264player` detached, and loads the menu when it exits (only from this core). |
| `/media/fat/h264player/` | The binary, the DejaVu typefaces, `h264player.log`, `state.txt` (the last folder and file: the next run starts there), and the optional `h264player.ini` (`root=` lines replace the default roots). |
| `h264player play FILE` | Plays one file through the same code and ends with it: bring-up and the rig. |

## 4. The build

| Item | |
|---|---|
| `clients/player/build.sh` | The image `mister-h264-clients:deps2`, built from `clients/common/docker/` on the Moonlight image, as the Jellyfin client is built. (P7) `deps3`: the video decoders, parsers and demuxers below, and the audio decoders MP2 / LPCM / WMA / ADPCM; the Jellyfin client stays on `deps2` (its inputs unchanged). |
| FFmpeg allowlist | Jellyfin's, plus the `h264` demuxer (raw files) and the text subtitle decoders: `subrip`, `srt`, `ass`, `ssa`, `movtext` (mov_text: configure's name has no underscore, and an unknown name is only a warning -- check the "Enabled decoders" list), `webvtt`, `text`. |
| Link | Static except glibc, as Jellyfin's (F7): the shared libavformat carries its network protocols, whose name lookups would load NSS into a static glibc. |

## 5. Rejected alternatives

| Alternative | Why not |
|---|---|
| **Software decode on the ARM into the overlay plane, as RGB** | The overlay plane is an RGB layer the size of the raster: a 720x480 16-bit page is 0.7 MB a frame, 20 MB/s at 30 frames/s, with the colour conversion on the A9; it would bypass the core's fitting, deinterlacing and STC-paced presentation (the overlay IS anti-twittered at 480i under Auto / On). Measured 2026-10-03 (`experiments.md` "Other codecs decoded on the ARM"). **The software decode itself was taken up (P7, 2026-10-05) through a PICTURE record instead**, the picture in the core's own store. |
| **Transcode on the ARM** | Two A9 cores cannot encode H.264 in real time at any useful size. |
| **Report the 1,620 bound from the core** (a refusal code) | An RTL change for what the program can see in the SPS. Recorded as a candidate: a program that does not check gets a blank screen with only a counter. **Taken in another form, 2026-10-02 (interface 0.11):** the core reports its bounds (word 81, `h264ring_caps()`), and the player's check reads them; still no refusal code (the slices are counted in `rc_ref_size`). |

## 6. Gates

`clients/player/tests/run_test.sh [--red]` (`tests/README.md`):
- The player (built with `-DCLIENT_TEST`) runs against the Jellyfin test's fake core, extended
  with the settings request and a scripted pad.
- It is scored by `check_player.py` with `tools/ring_model.py`'s consumer and ffmpeg references.
- Checks: (b) the list's order; (c) the folder plays on; (d) every AU byte-identical with its PTS;
  (e) the refusals (a CAVLC 1344x720 refused for its size -- 3,780 macroblocks, over 0.11's 3,600;
  a 720p60 file refused as too fast, `g_fast`); (v) a CAVLC file plays (every PPS the
  core read is CABAC, and ffmpeg decodes what it read to the file's own pictures); (f) a folder
  entered; (g) the seek; (r1) / (r2) the refresh rate; (s1) / (s2) subtitles; (z1) / (z2) the
  screensaver (the overlay page's pixels, both edges); T1-T7 (T7: the canvas as wide as the
  raster the fake core reports, 852 native or 720 fitted).
  (w): every video write made 15 ms slow (the A9's rewrite), the loop never stalls over 0.25 s.
- `--red`: nineteen mutations, each caught by its own check (0.11: M18 no rate check, M19 the
  limits not from the core).
- (P7, 0.15) The fake core carries the stores, reports READY until a video record and word 84 from a
  stand-in display (each picture shown when the clock reaches its PTS, the store before it released).
  `f_mpeg4` plays now; `h_mpeg2i` (MPEG-2 352x240 interlaced, top first, B-pictures) and `i_mjpeg`
  (320x240 yuvj422p) were added; `j_ffv1` and `k_hd` (MPEG-4 1280x720) are refused. (p1) / (p2):
  every picture's visible planes MD5-equal to ffmpeg's decode, its PTS the decoder's
  `best_effort_timestamp`, frames / pairs, the rate, END_OF_STREAM on the last; (p3) the MJPEG's
  pictures equal to the documented 4:2:2 -> 4:2:0 and full -> limited conversion of ffmpeg's decode,
  computed in Python; (e) the four refusals named, exactly three picture sessions; T10 the store rule
  (no PICTURE named a store the display held, over 91 pictures). Mutations M22-M28: the flag off,
  pairs sent as frames, full range as limited, no SD budget, no END_OF_STREAM, no store rule, no
  PTS.

Also:
- The Jellyfin host test is re-run after the move to `common/` (ALL GREEN).
- `make -C hps test`: the refusal names' new check.

## 7. Known limitations

**What plays:**
- **Up to 720p at 30 frames/s** (interface 0.11; SD only before). 1080p and 720p50 / 60 are
  refused (size, rate), and HEVC is out of scope. 720p30 x264 files above ~4 Mbit/s fall behind
  until roadmap Phase 5c part 2; 720p24 films play in real time at typical bitrates (estimated:
  8 Mbit/s of dense x264 is marginal).
- **Most interlaced H.264 is refused:** MBAFF, x264's interlaced mode. PAFF plays.
- **CAVLC plays up to ~4-5 Mbit/s at 480p60** (P6): past it the A9's rewrite falls behind, and
  pictures are late. The controls stay responsive: a step of `player_step` writes for at most
  `STEP_BUDGET_MS` (10 ms) before the loop reads the pad again. Before that, 64 rewrites a step
  held the loop for about a second (the maintainer's round, `history.md` §26). A file the rewrite refuses (FMO and the like) is named on screen; that path
  has no host-test fixture (x264 makes no FMO stream) -- the library's own runner covers it
  (`bench/h264/run_cavlc.sh`).
- Stereo only (the core presents 48 kHz stereo PCM). Surround is mixed down with swresample's default
  matrix (centre and surrounds at -3 dB, normalised) or, for AC-3 / E-AC-3, the decoder's own downmix
  (the stream's coefficients). **Fixed 2026-10-06 (the maintainer: a Blu-ray rip's DTS 5.1 had no
  dialogue):** `swr` was built once from the layout the decoder reported at open, and dca reports stereo
  there under the `downmix` option while it decodes a track without embedded downmix coefficients as 5.1
  -- the stereo-built `swr` took planes 0 and 1 (FL, FR) and dropped the centre and the surrounds.
  `swr_for()` now builds it from each frame's own layout, format and rate (again when they change).
  AC-3 and E-AC-3 were never affected (their decoders do downmix). Host test (p4): `f_mpeg4.mkv`'s DTS
  5.1 tone in the centre only, the session's PCM at ffmpeg's `-ac 2` level in both sides; M29 (the
  per-frame rebuild removed) caught by it. Shared with the Jellyfin client (its direct play).

**Other codecs (P7):**
- SD only (720x576, 30 frames/s): the copy into the strongly-ordered stores (~97 MB/s) leaves no room
  for 720p30 / 480p60 on one A9 core (`experiments.md`). A later extension could hold ARM pictures in
  the write-combined `/dev/fb0` region (~6x faster) behind a second picture base in `disp_reader`.
- BT.601 limited range shown (the core's display is BT.601 today); a full-range source is converted.
- A picture the decoder flags interlaced is shown as a field pair; a progressive film coded
  interlaced (hard telecine) is deinterlaced as video.
- **Interlaced pictures at 480i / 576i** played each field pair later-field-first half the time (measured at 576i on
  the RetroTINK, `history.md` §35); fixed the same day in the display (UMD's V6 ported: a pair starts on its first
  field's raster field, `analog.md` §5; word 85 counts the holds). Left: after a pause of an odd field count the
  pictures can run one field (16.7 / 20 ms) behind the sound until the next stream or seek.
- VC-1 / WMV9 not decoded (not measured; in the binary's decoder list it would be a one-line change
  after a measurement).
- A failure in the middle of a file decoded on the ARM shows "Cannot play" (`main.c`'s refusal branch for
  any `PL_FAILED` whose video is not H.264), not "Playback failed": cosmetic, not changed.
- Theora in Ogg drops ~140 ms of audio at its start as late (`aud_late`; an H.264 / AAC control ~20 ms,
  `history.md` §35): not investigated yet.

**Subtitles:**
- Plain text only: no styling, no positioning, ASS effects lost.
- Bitmap subtitles are not offered.
- Cues come only from where the demuxer has read. After a seek, a cue that started before the
  seek point is not shown until the next one.

**Other:**
- Raw `.264` / `.h264` files: no seeking, no position, no audio. They are paced by their VUI;
  without VUI timing, the core's 59.94 Hz default applies.
- No resume position across runs (`state.txt` keeps only the folder and file), no playlists, no
  gapless playback between files.
- A file over a slow network share stutters if libavformat's reads stall; the reader thread
  queues 6 MB.

## 8. Next concrete step

1. ~~The ARM build~~ (done) and ~~the first rig round~~ (done, `history.md` §26).
2. **The maintainer's round** on the rig, with a pad (**done 2026-10-02 on .236, every test
   successful; the 8 Mbit/s CAVLC clip's sluggish controls fixed**, `history.md` §26):
   - pause, seek and the subtitle button during playback;
   - the screensaver (P5): its veil and fading line on HDMI and on a CRT (the line is a grey of
     alpha 11 / 15 over the veil: legible?), and the Jellyfin Ready to play screen's;
   - a USB drive;
   - a 576p25 file at 576i on the RetroTINK or a CRT (its field order);
   - their own files, to see how many fall outside the envelope.
3. ~~P4's decision~~ (accepted as built, 2026-10-02); then the merge. The manual pages are
   written (`using/player.md`).
4. ~~The rebase onto interface 0.10~~ (done 2026-10-02: main with `feature/hdmi-raster` and fj#20).
   `ui.c` draws for the raster's width (Native (HDMI)), the screensaver's veil spans it, and CAVLC
   plays (P6). **On the rig with a 0.10 core:** the native raster's canvas (a list and the
   screensaver on an 852x480 picture), and a phone clip.

**After v1 (what widens the envelope):**
- ~~**720p24:** a D1 decision on the RTL~~ (taken 2026-10-02: roadmap Phase 5c part 1, 720p to
  30 frames/s).
