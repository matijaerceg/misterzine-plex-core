# The file player's host test

The branch's gate (`docs/player.md` §6): the player's own code (`../src` and `../../common`,
built with `-DCLIENT_TEST`) against a **fake core** driven by a **scripted pad**. It is scored by
an oracle that shares nothing with the player or the library.

```bash
clients/player/tests/run_test.sh          # one run, ~45 s: GREEN or the failing checks
clients/player/tests/run_test.sh --red    # ...then each mutation, which its own check must catch (~8 min)
make -C clients/player test               # the same as the first
```

Needs:
- host gcc, and pkg-config with FFmpeg (libavformat, libavcodec, libswresample, libavutil);
- `ffmpeg` / `ffprobe` with libx264 and the `mpeg4` encoder;
- python3;
- the DejaVu typefaces (`JF_FONT_DIR`, default `/usr/share/fonts/TTF`).

Fixtures, references and every run's files are in `.sim/player_test/` (gitignored):
`green/log` is the whole story of the last GREEN run, `red_<mutation>/run/log` each mutant's.

## The pieces

| File | What it is |
|---|---|
| `test_player.c` | The fake core on a thread: the Jellyfin test's, plus the settings request (word 35 consumed into word 27's mirror, SET_SEQ, 50 Hz -> RASTER_STD 576). The player runs as `player_main("--dir", TESTDIR, "--root", ROOT)` on another thread. It runs the pad's script (below) and writes, for the scorer, what each session consumed, the clock, the settings requests, the script's times and the final Refresh Rate. It judges T1-T6 itself. |
| `check_player.py` | The scorer. `tools/ring_model.py`'s consumer (written from `docs/architecture.md`) walks every session; the references come from the fixtures through the ffmpeg CLI. Refusals and subtitle cues come from the player's log (the test build logs each cue shown). |
| `mutations.py` | `--red`'s table: each mutation, applied to a COPY of `src/` and `common/` (compiled from the copy), and the check that must go RED. |
| `run_test.sh` | Makes the fixtures (when their recipe changed) and the script, builds (the old binary deleted first), runs and scores. It requires the positive `ALL GREEN` markers of BOTH `test_player` and `check_player`. |

## The fixtures

The folder the player browses, in the order it lists them (folders first):

| File | What it is |
|---|---|
| `a_dir/inner.mkv` | 120 s of one colour, 25 frames/s, an IDR a second, no audio: the folder, the seek, 50 Hz |
| `b_pal.mp4` | 3 s, 352x288, 25 frames/s, MP4 (avcC), AAC: 50 Hz |
| `c_ok.mkv` | 8 s, 640x360, 30 frames/s, AAC, an SRT track (default) and an ASS track: a dialogue line with `{\i1}` tags and a `\N` break, overlapped by a vector drawing (`{\p1}`) that must not show |
| `d_big.mkv` | 1344x720 (3,780 macroblocks, over interface 0.11's 3,600) at 24 frames/s (90,720 a second: only the size refuses it), CAVLC: refused for its size (the core would not refuse it at the SPS: §2). CAVLC alone would now play, so the size must be found first (`h264check` names CAVLC last) |
| `e_cavlc.mkv` | 1 s of Baseline (CAVLC) 320x240: plays, rewritten into CABAC by the library's write call (`docs/player.md` P6) |
| `f_mpeg4.mkv` | (0.15) 1 s of MPEG-4 Part 2 320x240 at 30: decoded on the ARM, sent as pictures (frames) |
| `g_fast.mkv` | (0.11) 1 s of 1280x720 at 60 frames/s: inside the picture bound but 216,000 macroblocks a second -- refused as too fast (the core's 108,000) |
| `h_mpeg2i.mpg` | (0.15) 1 s of MPEG-2 352x240 interlaced (top first, B-pictures) at 29.97, a program stream: decoded on the ARM, sent as woven field pairs |
| `i_mjpeg.avi` | (0.15) 1 s of MJPEG 320x240 yuvj422p at 30: 4:2:2 full range, converted to 4:2:0 limited by the library's copy |
| `j_ffv1.mkv` | (0.15) FFV1: refused (not a codec the MiSTer decodes) |
| `k_hd.mkv` | (0.15) MPEG-4 Part 2 1280x720: refused (larger than SD, the ARM's budget) |
| `l_ahead.ts` | (`docs/jellyfin.md` §12) 8 s, 320x240 at 25, AAC, MPEG-TS, its audio up to 6.4 s AHEAD of its video in the file (`tools/ts_skew.py --lead 6.5`): held to ~1 s ahead |
| `m_late.ts` | (§12) 6 s, the same (another test pattern: the scorer tells the sessions apart by their first access unit), no audio in the file's first 3 s of video (`--audio-from 3`): past the probe (no sample rate), played all the same |
| `.hidden.mkv`, `aa_notes.txt` | Never listed. Either would sort before `b_pal`, so every press after it would land elsewhere. |

## The scenario

The script `run_test.sh` writes. Each command is run when the previous one is done, and every
wait times out after 20 s, so a mutant still finishes:
1. DOWN, A: b_pal plays. It asks for 50 Hz first.
2. Its end plays c_ok by itself. Auto is given back first. c_ok's SRT track is on.
3. At 2.75 s of c_ok's clock, X switches to the ASS track.
4. c_ok's end tries d_big, which is refused: back to the list.
5. DOWN, A: e_cavlc plays (rewritten); its end plays f_mpeg4 (decoded on the ARM); its end tries
   g_fast, refused (too fast): back to the list.
6. DOWN, A: h_mpeg2i plays (pairs); its end plays i_mjpeg; its end tries j_ffv1, refused: the list.
   DOWN, A: k_hd is refused (over SD): back to the list.
   DOWN, A: l_ahead plays; its end plays m_late; the folder's end: the list.
7. LB, LB (the top: the folder), A, A: inner plays. It asks for 50 Hz.
8. At 1 s, RIGHT: the seek.
9. Back + Start: the list. B: up to the root.
10. Left alone 9 s: the screensaver dims at 3.6 s and goes black at 7.2 s (`h264player.ini` in the
   run's directory sets them in minutes: 0.06 and 0.12).
11. DOWN wakes it and must do nothing else, so the A after it opens a_dir; a DOWN that moved the
    selection would make it play b_pal. Back + Start: quit. The player gives Auto back and ends
    by itself.

The fake core's clock runs at half speed, as the Jellyfin test's does. Its raster (word 80 / 47,
interface 0.10) is a 16:9 film's Video Output "Native (HDMI)" at 59.94 / 60 Hz -- 852 x 480 -- and
the fitted 720 x 576 at 50 Hz, so the canvas is drawn for two widths.

## The checks

| | What it proves |
|---|---|
| T1-T7 | (`test_player`) the library attaches; a session; the script ran to its end with no wait timed out; the player ended by itself (the quit press) and returned 0; every record header well formed; every overlay descriptor accepted; (T7) the canvas as wide as the raster the fake core reports: 852 on the native raster, 720 on the fitted one, no other width. |
| T8, T9 | (0.12) `/dev/fb0` is the size of Main's HDMI mode, not the 8 MB region: the run is on a 1280x720 mode's 3,686,400 bytes (`CLIENT_TEST_FB_LEN`; every mutant too), a second GREEN arm on a 720x480 mode's 1,382,400. (T8) every canvas has its raster's lines (852 wide: 480, 720 wide: 576), or as many as two pages of its width fit, never fewer -- a fixed 2,048-pixel row leaves 450. (T9) every canvas lies inside that framebuffer. |
| (0) | The references split exactly; the consumer finds no protocol error in any session. |
| (b) | The first file the player opened (its log) is b_pal, and the first session's AUs are b_pal's: the list's order (folders first; hidden files and non-videos left out -- a hidden file opened first is refused before the ring, so the sessions alone cannot tell). |
| (d) | b_pal (MP4: avcC to Annex B) and c_ok: every access unit byte-identical with `ffmpeg -c copy -bsf:v h264_mp4toannexb`, each with its PTS. c_ok's last AU has END_OF_STREAM; its audio records carry PTS. |
| (c) | The folder plays on: c_ok's session follows b_pal's and starts before any press made after b_pal's started (a later press would also play it). |
| (e) | No access unit of d_big, g_fast, j_ffv1 or k_hd ever reached the core (by MD5), and exactly three sessions of pictures exist (f, h, i: no refused file decoded on the ARM). The log's "cannot play" names "1344x720 is larger", "too fast", "cannot decode" (FFV1) and "larger than SD" (k_hd). |
| (v) | The CAVLC file plays: the third session's every PPS has entropy_coding_mode_flag 1 (the scorer's own parse), and ffmpeg decodes the AUs the core read to exactly the pictures (frame MD5s) it decodes `e_cavlc.mkv` to: the rewrite lossless, judged by a decoder that shares nothing with it. |
| (p1) | (0.15) f_mpeg4 (MPEG-4 Part 2 320x240) decoded on the ARM: every picture's visible planes, read from the fake core's snapshot of its store by `docs/architecture.md`'s layout, MD5-equal to ffmpeg's decode (yuv420p), in order and all of them; its PTS the decoder's `best_effort_timestamp` (ffprobe); a frame; the rate 30; END_OF_STREAM on the last only. |
| (p2) | (0.15) h_mpeg2i (MPEG-2 352x240 interlaced, top first, B-pictures, a program stream): every picture a woven field pair, top first (structure 1), MD5-equal to ffmpeg's decode, with its PTS; the rate 29.97. |
| (p3) | (0.15) i_mjpeg (MJPEG 320x240 yuvj422p): every picture equal to ffmpeg's yuvj422p decode converted by the interface's formula (chroma rows averaged, rounding up; Y' = 16 + (219 Y + 127) / 255, C' = 16 + (224 C + 127) / 255), computed in Python. |
| T10 | (0.15, test_player.c) More than 20 pictures consumed (the stores reused), and none named a store the stand-in display held (queued or shown). |
| (f) | The ninth file played is a_dir/inner.mkv: a folder entered. |
| (g) | RIGHT once makes exactly one new session. Its first AU is an IDR (SPS / PPS) at the clock's position + 30 s (at or before, within a GOP), and its AUs are the file's from there (matched by MD5 and PTS: one colour's IDRs are identical). |
| (r1) | A settings request for 50 Hz consumed before each 25 frames/s file's first session (b_pal, inner). |
| (r2) | A request for Auto consumed between b_pal's start and c_ok's, and after the quit press; the mirror's Refresh Rate is Auto at the end. |
| (s1) | c_ok's default SRT track: "The first cue" shown between 0.5 and 2.5 s of its clock. |
| (z1) | The screensaver: the overlay's corner pixels (2, 2) and (w - 3, 2) are outside every list, card and panel, so their alpha is the veil's. The fake core reads them from the page each descriptor names (`client_test_fb`). Before the idle phase they are never lit; in it, both alpha 11 (dimmed) from 3.4 s and 15 (black) from 7.0 s -- the right one on the 852-wide native raster. |
| (z2) | The wake: within 1.5 s of the DOWN the veil is gone; no file plays after it (the A opened a_dir); the log says the press woke the screensaver. |
| (w) | In this build every video write takes 15 ms, as the A9's CAVLC rewrite of a dense stream does. From the first press to the quit, the player's loop never stalls over 0.25 s between two of its `usleep`s (`test_player.c` records the stalls): the pad is read while writes are slow. |
| (x) | (§12) l_ahead, the seventh session: the fixture holds its skew (>= 5 s, from ffprobe's packets); every AUDIO record within 1.3 s of the newest video PTS before it in the ring; every access unit the file's, the last with END_OF_STREAM; the PCM equal to ffmpeg's decode. |
| (y) | (§12) m_late, the eighth: the fixture's first audio after >= 2.5 s of video; every AUDIO record with a PTS, the PCM equal to ffmpeg's decode at its PTS's place. |
| (s2) | After X, the ASS track's dialogue as plain text ("An ASS line", a line break, "on two") between 3.0 and 5.5 s; no cue shows event fields, a tag, a literal `\N` or the drawing. |

## `--red`

| Mutation | Must be caught by |
|---|---|
| M1 a 25 frames/s file never asks for 50 Hz | (r1) |
| M2 Auto never given back for a file of another rate | (r2) |
| M3 Auto not given back when the player ends | (r2) |
| M4 a file's end goes back to the list | (c) |
| M5 `h264check` never says SIZE | (e) |
| M6 the file's text tracks discarded (`text_subs` 0) | (s1) |
| M7 an ASS event taken as plain text | (s2) |
| M8 hidden files listed | (b) |
| M9 the forward seek step 10 s, not 30 | (g) |
| M10 OK on a folder opens nothing | (f) |
| M11 the screensaver's dim stage never comes | (z1) |
| M12 the press that wakes the screensaver also acts | (z2) |
| M13 playing never counts as busy (the saver dims a playing film) | (z1) |
| M14 CAVLC refused again (`cavlc_ok` 0) | (v) |
| M15 `h264check` names CAVLC before the size (the CAVLC 1344x720 let through) | (e) |
| M16 the canvas 720 wide whatever the raster | T7 |
| M20 the canvas's rows a fixed 2,048 pixels apart (450 lines on a 1280x720 mode) | T8 |
| M21 the pages spaced for the tallest canvas (2,048 lines): page 1 past the framebuffer | T9 |
| M17 a step writes its 64 packets whatever the time (no budget) | (w) |
| M18 (0.11) no rate check: the 720p60 file reaches the core | (e) |
| M19 (0.11) the check's bound fixed at 0.10's 1,620, not the core's word 81 (g_fast refused by size, not named too fast) | (e) |
| M22 (0.15) `arm_video` off: f_mpeg4 refused again | (p1) |
| M23 an interlaced picture sent as a frame | (p2) |
| M24 MJPEG's full range taken as limited | (p3) |
| M25 the SD budget gone: k_hd decoded on the ARM | (e) |
| M26 the last picture without END_OF_STREAM | (p1) |
| M27 stores taken in turn without the store rule | T10 |
| M28 every picture's PTS dropped | (p1) |
| M29 swr built once at the open, from the decoder's layout then (dca: stereo under `downmix`, its frames 5.1) | (p4) |
| M30 (§12) the audio written in the demuxer's order again | (x) |
| M31 (§12) an audio stream the probe missed passed over | (y) |
| M32 (§12) swr built at the open from the probe's parameters | (y) |
| M33 (§12) a frame without a time sent untimed | (y) |

A mutation caught only by another check is a failure of the runner. Other checks may also go RED
on a mutant (M5 lets the 1344x720 file play, so the sessions after it shift); only the named one is
required.
