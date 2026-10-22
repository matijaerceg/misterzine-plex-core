# The raster on HDMI: A' and the native raster (roadmap Phase 6c)

Status: **designed, 2026-10-01; §9's choices decided by the maintainer the same day (each as recommended).
Stage 1 (A', word 80, the Jellyfin client, F8) and stage 2 (the native raster, Video Output Native
(HDMI)) built, GREEN and `--red`, fit (SEED 6 106.0 / 104.73), on the rig and ✅ HW-CONFIRMED with
the maintainer 2026-10-02 (§12, §13, `history.md` §22-§24). ✅ MERGED (PR fj#26).** Branch
`feature/hdmi-raster` (`dev-hdmi-raster`). One branch, two stages (§8): A' first (fitted to the
720 raster, letterboxed inside it when the picture is wider than the display), then the native
raster. Designed together because both decide what the raster is on HDMI and what a program's
overlay covers, and the interface should change once before 1.0, not twice.

Read with: `analog.md` §5 (the fit, today), `architecture.md` "The overlay plane" (the identity
mapping, word 47), `jellyfin.md` F8 / F9 (what asked for it), `display.md` §7 (the refresh grid).

## 1. The problem

Three things show on HDMI, two of them today:

- **Two resamples.** A 16:9 transcode (852x480) is fitted to the 720-wide raster by the core,
  then scaled 720 -> 1920 by ascal. An anamorphic 720x480 picture is fitted, then scaled again.
  One scale, by ascal, from the decoded pixels, is the sharper HDMI picture.
- **The overlay on a scope film (F9).** In Progressive with Aspect Auto the raster is filled with
  the picture and ascal is given the picture's exact aspect, so a 2.39:1 film's raster -- overlay
  included -- is shown as a 2.39:1 strip; the bars are ascal's, outside the raster, and the
  program cannot draw in them (subtitles, a progress panel).
- **F8** (word 47's `ar_x` / `ar_y` reading 0): **not reproduced** (§7).

## 2. What ascal and Main do (read from `sys/`, 2026-10-01)

From `sys/ascal.vhd` and `sys/sys_top.v` (and Main's `video.cpp` in a local checkout -- the rig's
Main may differ; each claim below that matters is confirmed on the rig in stage 2):

- **ascal measures only DE.** No htotal / vtotal inputs; `iauto` = 1 (`sys_top.v:753-757`). The
  width is the DE run of each line (counted in CE ticks), the height the DE lines between VS
  rises (`ascal.vhd:1228-1281`). The totals are free.
- **Its one timing need: >= 17 CE ticks of DE low between lines** (`i_de_delay` reaches 16 then
  17 before the next DE rise advances the line, `ascal.vhd:1477-1493`). So a horizontal blank of
  at least 18 dots; this design uses 20.
- **Bounds:** 12-bit counters (4,095 x 4,095); a line at most ~2,645 pixels at 24 bpp (31 bursts
  of 256 B); no multiple-of constraint on either size (`ascal.vhd:1556-1576`, 1998-2005); each of
  the three buffers 8 MB at `0x2000_0000` (an 852x480 frame is ~1.2 MB). Nothing near the
  1,620-macroblock bound binds.
- **A size change:** no lock state. The new width applies from the next line, the new height at
  the next VS; the output picks the new size up at its next frame (one transitional frame at
  most). ascal can black 3 frames itself (`HDMI_BLACKOUT`, today 0). **The output timing never
  changes** (Main's mode).
- **Main's reaction is the risk.** hps_io reports a new resolution after ~15 stable frames
  (`hps_io.sv:985-988`); Main then re-programs the HDMI mode (`video_set_mode`: the PLL and the
  HDMI transmitter over I2C -- a TV may re-sync, a blank second or two) **if** `vsync_adjust` != 0,
  `vscale_mode` >= 4, a `[video=...]` section or `vrr_mode` = 4; otherwise only the filters and
  the scaling window. Whether re-writing the same mode blanks a TV: unverified.
- **The clock:** ascal samples on CLK_VIDEO with CE_PIXEL; sys_top.sdc constrains nothing beyond
  the PLLs. **27 MHz is enough** (§4): a 59.94 Hz frame is 450,450 dots, and the largest legal
  picture (1,620 macroblocks) is 414,720 pixels. No new clock, no new crossing.
- **`vga_scaler`** already reaches `emu` (`ini_vga_scaler`, the UMD-FORK in `hps_io.sv`) -- the
  roadmap's "sys_top does not pass it" was wrong. With `vga_scaler` = 1 the VGA pins carry ascal's
  output; with 0 they carry the core's raster on clk_vid, so a native raster's odd timing would
  reach a CRT. `direct_video` = 1 bypasses ascal on HDMI: no native raster then either.

## 3. The rule: what the raster is on HDMI

Two rasters, one rule for where the picture sits in them.

**Notation.** `Wc x Hc` the cropped picture, `sar_w : sar_h` its resolved SAR (`aspect_vui`),
`A = sar_w Wc`, `B = sar_h Hc` (its display aspect A : B), `D = HW : HH` the HDMI display's shape
(`HDMI_WIDTH` / `HDMI_HEIGHT` into `emu`: the window after `VSET` / pixel repetition; 0 with
`direct_video` or no scaler). **Wider than the display:** `A HH > B HW`.

### 3a. The fitted raster (720 x 480 / 576) -- A'

Unchanged at 480i / 576i and whenever Analog Aspect is set explicitly (`raster_fitted`): the 4:3
fit, `VIDEO_ARX / ARY` 4 : 3 -- 16 : 9 under Fit since issue #11 (`analog.md` §5a: Fit is the
anamorphic 16:9 fit, and its letterbox reuses this section's quotient with a 16 x 9 "display",
`lb` left 0).

**Progressive with Analog Aspect Auto** (today: fill + the exact aspect):
- **not wider than the display** (or `HW` = 0): unchanged -- the raster filled, `VIDEO_ARX / ARY`
  = A : B reduced to 12 bits. (Pillarboxing a narrower picture INSIDE the 720 raster would cost
  horizontal pixels: decided against, `jellyfin.md` F9.)
- **wider than the display (A')**: the picture fills the raster's width and is letterboxed in it
  so the whole raster shows at the display's shape: `ow = 720`, `oh = round(rh B HW / (A HH))`
  (`rh` = 480, 576 on the 625-line raster), centred, black bars; `VIDEO_ARX / ARY = HW : HH` (12
  bits each already). A 2.39:1 852x356 transcode (SAR 640:639) on a 1920x1080 display: oh =
  round(480 x (639 x 356) x 1920 / ((640 x 852) x 1080)) = 356 -- the vertical is 1:1 and only the
  horizontal is resampled (852 -> 720, as today). **The vertical alone snaps** (the 3.5 % rule of
  `analog.md` §5, applied to the height only: the width is the raster's 720, resampled anyway, so
  the both-axes snap could never fire), so a near-miss (a 1366x768 display: 356.2 -> 356) lands on
  1:1 rows; a 5:4 1280x1024 display gives 250, no snap.

`disp_fit` gains the display's shape as an input set member and one branch (the divider is
reused: `oh = round(rh B HW / (A HH))` is one more division; `B HW` and `A HH` are up to 40 bits,
so both are **shifted down together** until `A HH` fits 28 bits -- the divisor `2 A HH` then fits
its 29 -- rather than widening the divider). `tools/disp_fit_ref.py` carries the same integers.
**As built:** the two products are serial (12 shift-add steps, no DSP: 9 are left); `ar_exact`
is unchanged (W48 stands) -- under A' the registers it selects, `ar_x / ar_y`, take the latched
display shape instead of the picture's; **the snap under A' is the vertical alone** (the width is
the raster's 720 and resampled anyway, so the both-axes snap would never fire): oh within 3.5 %
of Hc, and Hc <= rh, shows the rows 1:1.
A display-mode change (`HDMI_WIDTH / HEIGHT` move when Main changes the mode) is a new input set:
latched with Analog Aspect at the pickup, so it never splits a picture.

### 3b. The native raster (stage 2)

The raster's active area is the picture at its own pixels: `ow = Wc`, `oh = Hc`, steps 1.0, no
decimation -- the identity fit, so the deinterlacer's kernels (Bob / Blend on a field store) apply
to every native picture, not only 720x480 ones. ascal makes the one scale; `VIDEO_ARX / ARY` give
it the raster's display aspect.

**Its size** (§9 choice (a) decides between the two; the recommendation is the second):
- **picture-sized, A' carried over:** `Rw x Rh = Wc x Hc`; when wider than the display, `Rh =
  round(Wc sar_w HH / (sar_h HW))` (the raster at the display's shape, the picture centred in
  it), `VIDEO_ARX / ARY = HW : HH`; otherwise `A : B`, ascal's bars outside.
- **display-shaped whenever it fits:** the raster is the display's shape in both directions --
  letterboxed inside when wider (as above), pillarboxed inside when narrower (`Rw = round(Hc
  sar_h HW / (sar_w HH))`) -- so a program's overlay covers the whole screen for every picture.
  Pillarboxing costs nothing here (the picture keeps every pixel; only dots a line grow), unlike
  on the fitted raster. Where the display-shaped raster does not fit the line limit or the dot
  budget (§4: a portrait picture on a 16:9 display wants a 1,518-wide raster), the
  picture-sized raster is used instead, flagged.

## 4. The native raster's timing on 27 MHz

**The refresh does not change.** Every frame is still exactly F dots -- 450,450 (59.94 Hz),
450,000 (60.00), 540,000 (50) -- with the Refresh Rate's standard chosen as today. So the refresh
grid, `disp_ctl`'s events, the STC, audio, low latency and Main's view of the rate are untouched;
only the geometry inside a frame changes.

**`disp_ctl`'s events stay where they are** (absolute phases of the refresh: skip 420,420, eval
428,142, pickup 429,000 at the 525-line standards; 509,760 / 517,536 / 518,400 at 50 Hz;
`analog.md` §10). The native raster keeps the same vertical blanking: its active lines end by
the skip, `Ae` = 420,420 (509,760 at 50 Hz), so the scheduler, its model and its bench need no
change, and the time from the pickup to the next frame (21,450 dots) is today's.

**The geometry:** the active lines are `L = min(floor(Ae / Rh), 4,000)` dots each (all of the
spare goes to horizontal blanking); `N = floor(F / L)` lines, `R = F mod L`: R >= 32 adds one line
of R dots, else one line is L + R -- **that odd line is the first blank line (line Rh)**, so the
frame is exactly F dots (as built: the remainder is not spread; and not the last line, where the
reader fetches the next frame's first rows -- a 150-dot last line made a line late, §13). HS and VS sit in the
blanks as today (front porch, pulse, back porch scaled into what the line has). **It fits iff `L
- Rw >= 20`** (ascal's 18, plus 2).

| picture | 59.94 / 60.00 (`Ae` 420,420) | 50 Hz (`Ae` 509,760) |
|---|---|---|
| 854x480 (Sunshine's 854, cropped) | L 875, blank 21 -- fits | fits |
| 852x480 (Jellyfin's transcode) | L 875, blank 23 -- fits | fits |
| 852x356 (a scope transcode) | L 1,180 -- fits | fits |
| 640x480, 720x480, 720x404 | fit | fit |
| 720x576 (PAL) | (a 50 Hz source: Auto picks 50) | L 885 -- fits |
| 864x480 uncropped (1,620 macroblocks) | L 875, blank 11 -- **falls back** | fits |
| 480x854 portrait | L 492 -- **falls back** | L 596 -- fits |
| wider than 1,024 coded (the reader's line) | **falls back** | **falls back** |

**Display-shaped (§3b, §9 (a)) on a 16:9 display**, where pillarboxing inside adds width: the
line is at most `floor(Ae / Rh)` dots, so at Rh = 480 a raster can be at most 855 wide.

| picture | display-shaped raster | at 59.94 / 60.00 | at 50 Hz |
|---|---|---|---|
| 640x480 square (a 4:3 transcode) | 853x480 | fits (L 875) | fits |
| 720x480 SAR 8:9 (4:3 SD, MPEG's) | 960x480 | **picture-sized** | fits (L 1,062) |
| 720x480 SAR 10:11 (4:3 SD, BT.601's) | 939x480 | **picture-sized** | fits |
| 720x576 SAR 16:15 (4:3 PAL) | (a 50 Hz source) | -- | **picture-sized** (960 > 885 - 20) |
| 480x854 portrait | 1,518x854 | **picture-sized** (and then falls back, above) | picture-sized (over 1,024) |

So every anamorphic 4:3 SD source -- a direct-played DVD-shaped file -- takes the picture-sized
raster (ascal's pillarbox bars, outside the raster; the overlay covers only the picture) under
the display-shaped choice. Only square-pixel 4:3 transcodes get the full-screen overlay from it.

**Falling back** = the fitted 720 raster for that picture (§3a), with `raster_native_fb` set in
the status (§6): visible, never silent, and the picture is still shown correctly. Only what the
mode is a preference for is lost.

The two 59.94 misses come from the skip's lead (9 lines before the eval: no reason is recorded in
`display.md`). Moving the skip to one line before the eval (`Ae` 427,284) fits 864x480 (L 890,
blank 26) and 480x854 (L 500, blank 20); every legal shape needs the pickup later as well. **Not
in this design** -- `disp_ctl`'s model and its 32-mutation bench are the cost -- a follow-up if a
real stream ever lands there. D1's real sources (Sunshine's 854, Jellyfin's 852 / 640, PAL 720x576)
all fit.

**The line limit:** `disp_reader`'s line slots hold 1,024 samples and its column is 10 bits
(`h_pos[9:0]`); a picture coded wider than 1,024 is decimated today (`dh` >= 2). Native is
`16 W <= 1,024` (64 macroblocks); the display-shaped raster also needs `Rw <= 1,024`.
`ovl_plane`'s line slots are 1,024 wide already.

## 5. What moves with the raster

Today these assume 720 x 480 / 576 and 525 / 625 lines; each takes the raster's geometry from one
place (a `raster_geom` block in `emu`: `Rw`, `Rh`, `L`, `N`, the blank lines' lengths, latched at the
frame boundary after the pickup that shows a new size):

- `sync_gen`: the native geometry as inputs (progressive only); it switches at a frame boundary,
  without restarting the refresh (the frame is F dots either way).
- `disp_fit`: native mode (the identity and the raster's size, or §3a's rule).
- `disp_reader` / `ovl_plane`: the frame wrap (`v_pos == 524 / 624`, `disp_reader.sv:172`,
  `ovl_plane.sv:181`) and the active lines (`lines`, `ovl_plane.sv:99-100`).
- `emu`: the Analog Aspect / anti-twitter latch at line 500 / 600 (`emu.sv:916-917`) -> the
  pickup's dot (`disp_ctl`'s phase), which is raster-independent.
- `idle_bars`: native mode shows the idle screen on the fitted raster (no picture, no size).
- Word 30's `fit_ow` / `fit_oh` (13 bits: enough), the new raster word (§6).
- `csync_smpte` / the analog pins: native mode is never on them (§9 (b)).

**When the size changes** (a new item, a new Moonlight size, a phone rotating): the raster takes
the new geometry at the frame after the pickup that shows the picture; disp_fit's ~150 cycles run
inside the pickup's 21,450-dot lead as today. ascal follows within a frame; Main may re-program the
HDMI mode (§2): **measured first in stage 2** (with the rig's and the maintainer's MiSTer.ini).
A raster switch with no size change (a new item of the same size) changes nothing.

## 6. The interface: 0.10 (additive)

- **The raster word.** Words 0-31 and 40-47 are full; **a sixth status burst, words 80-87 (core)**,
  under the same seqlock (seq_tail first, seq_head last). Word 80: `raster_w` [11:0], `raster_h`
  [23:12] (the active area the overlay and the picture are placed on), `raster_mode` [25:24] (0
  fitted, 1 native, 2 native fell back), the picture's rectangle on it: `pic_x0` [43:32], `pic_y0`
  [55:44] (with word 30's `fit_ow` x `fit_oh`). 81-87 reserved (0). A program learns the size it
  draws for from word 80 and the shape it is shown at from word 47.
- **Word 47's text:** "the whole raster (word 80's size) is shown `ar_x : ar_y` wide" (was "720
  pixels by its lines").
- **The overlay (§9 (c)).** Recommended: the identity, centred, on whatever the raster is; the
  canvas up to 1,024 wide and as tall as the tallest native raster (was 720 x 576; `ovl_plane`'s
  slots are 1,024 wide already; the RANGE check keeps it inside the framebuffer's 8 MB), a canvas
  larger than the raster clipped and flagged (`ovl_clip`, as a 576-line canvas on 480 lines is
  today). A program redraws when word 80 changes -- as it already must for word 47. The
  alternative, the scaled canvas (word 78, reserved for it): a resampler in `ovl_plane` (area at
  84 % ALM) and blurrier text; kept for later.
- **The library:** `h264ring_raster()` (word 80 decoded), the integrator pages
  (`integrating/overlay.md`, `integrating/status.md`), `H264RING_VERSION` 0x0A.
- A' alone (stage 1) changes no field: word 47 already reports what ascal is given. Stage 1 can
  still carry word 80 (the fitted raster's 720 x 480, the rectangle) so programs code against it
  once.

## 7. F8 -- found (2026-10-01, the maintainer's round): 0 : 0 BETWEEN streams

**The cause:** `emu`'s exact aspect `ar_x / ar_y` followed `disp_fit` continuously, and between
streams -- after a stop, and during every seek's or track change's restart (the per-stream reset
clears `sh_w` / `sh_hf`) -- the fit is computed from a 0x0 picture: `wc = hc = 0`, so `ar_x = ar_y =
0`. `ar_exact` stays 1 there (`played`), so `VIDEO_ARX / ARY` were 0 : 0: sys_top's FREESCALE path
(the HDMI picture stretched to fill), word 47 reading 0, and an aspect change Main may answer with
an HDMI mode change. Seen in the status block at the Jellyfin client's ready screen after a stop
(word 47 `0x00000000`, state READY). The 2026-09-27 rule -- between streams the Auto aspect holds
the last picture's -- held for the 4:3 / 16:9 path (`last_wide_q`) but was lost when the exact
aspect arrived (P6). **The fix:** `ar_x / ar_y` update only while `stream_live`, holding the last
shown picture's otherwise (`check_emu_wiring` "ar_hold", W74). My first rig check (below) read
the word only DURING playback, which is why it did not reproduce; the subagent's RTL trace
assumed a nonzero coded size. **On the rig 2026-10-02** (`history.md` §23): the fix holds 640 : 480 and
1920 : 1080 at the client's ready screen where the old build read 0 : 0.

### The first look (2026-10-01): not reproduced during playback

`H264_mbpipe_20261001_1223.rbf` (main's build, sha `fcbd409`, SEED 6) through `h264play`, word 47
read raw (`devmem 0x31400178`) and through `h264stat`:

| raster | stream | raw | ar_x : ar_y |
|---|---|---|---|
| 480i (Video Output Auto, the rig's analog ini) | 854x480 | `0x00003004` | 4 : 3 (the fitted raster's) |
| Progressive (`--osd video_output=2`) | 854x480, SAR 8100:8113 | `0x0076DD31` | 3,377 : 1,901 = 1.77643 (exact 854 x 8100 : 480 x 8113 = 1.77632) |
| Progressive | 852x356 SAR 640:639 (synthetic) | `0x00378852` | 2,130 : 888 = 2.399 (exact 2.397) |

The RTL path was also traced end to end (no clock crossing, the bench's packing is what `emu`
connects; `ar_y` cannot be 0 by construction, and the maintainer's screen showed a 2.39:1 strip, so
VIDEO_ARX was not 0). **The likeliest cause is the instrument** -- an older `h264stat` (a 0.8
binary reads no `ar_*`), or a different bitstream running than the one assumed. What this branch
adds so it cannot recur unseen: a `check_emu_wiring` arm pinning `.f_ar_x / .f_ar_y` to
`VIDEO_ARX / ARY[11:0]` (red when tied to 0), and a rig check (a known-aspect clip in Progressive:
word 47 nonzero, `ar_x Hc` ~ `ar_y Wc sar`). If the maintainer sees 0 again, read the raw word in
the same moment. (Superseded: found, above.)

## 8. Stages and gates

**Stage 1 -- A' (+ riders)**, fitted raster only, no new clock, no timing change:
- `disp_fit` + `disp_fit_ref.py` (§3a), `emu` (`ar_exact`, VIDEO_ARX = the display's), the
  display shape latched at the pickup; word 80 (if taken now); `check_emu_wiring` W48 and the F8
  arm.
- Gates: `run_disp_fit.sh` (new cases: 852x356 / 864x360 / 2.0:1 on 16:9 and 4:3 displays, `HW`
  = 0, the snap at the edge, a display-mode change mid-stream) GREEN and `--red`;
  `run_scaffold.sh`; `run_ring_rd.sh` (word 80); the library's host test. Fit; the rig:
  `shot --scaled` of the scope clip in Progressive (the raster letterboxed, the HDMI picture the
  same shape as today), and the Jellyfin client's subtitles in the bars with the maintainer.
- **The Jellyfin client follows A' (not a choice: stage 1 is incorrect without it).** Its
  `raster_aspect` (`clients/jellyfin/src/main.c`) already prefers word 47 when it is nonzero, but
  its fallback is the core's pre-A' rule (fill + the picture's exact aspect), which under A' is
  wrong -- the F9 squish back for any reader that falls back; and `raster_lines` knows only 480 /
  576. Stage 1: the fallback goes (word 47 is trusted: §7), the raster's size and the picture's
  rectangle come from word 80 / word 30, and subtitles may sit in the bars A' adds; the host test gains
  an arm (a scope picture at 16:9: glyph aspect from word 47, subtitles below the picture's
  rectangle). The Moonlight client draws nothing on the overlay: untouched.
- Riders, each its own commit and each droppable: F5 (the fit word before any picture: report
  "no picture"), `dec_stub`'s reset through a `cdc_reset` (roadmap Phase 5). F2 (the colour
  matrix) is NOT a rider: it needs the VUI's `matrix_coefficients` parsed and a policy for
  untagged and mis-tagged SD (R1 measured only HD sources transcoded, tagged BT.709 correctly) --
  its own small design. **Designed 2026-10-06: `colour.md`, interface 0.16.**

**Stage 2 -- the native raster**, measure first:
0. **Answered from the rig's MiSTer.ini (2026-10-02, .201):** `vsync_adjust=0`, `vscale_mode=0`,
   `vrr_mode=0`, no `[video=...]` section for this core, `video_mode=8` (1080p60): by Main's code
   (§2) a size change at the same rate re-programs nothing -- ascal's one transitional frame at
   most. The one visible effect: **`video_info=2` shows Main's resolution box for 2 s on every new
   raster size** (each item of a new size in Native). An ini with `vsync_adjust` 1 / 2 or
   `vscale_mode` >= 4 re-programs the HDMI mode at each size change (a TV re-sync): the manual
   says so beside the option. The original plan for this step, kept:
   **No RTL, today's build:** Main's `fb_crc` includes ARX / ARY, so a change of `VIDEO_ARX`
   already makes Main run `video_mode_adjust` -- which happens today whenever one stream follows
   another of a different aspect in Progressive. Play 854x480 then 640x480 back to back with the
   maintainer's MiSTer.ini (its `vsync_adjust`) and watch HDMI on the capture: no blank there
   makes one from a DE-size change at the same rate unlikely; a blank there is pre-existing, not
   the native raster's.
1. **Main's reaction to a size change at the same rate**, before any of the design is built: a
   test bitstream (or a `sync_gen` parameter on a throwaway branch) that alternates the DE area
   between 720x480 and 852x480 every 10 s at 59.94; on the rig with `vsync_adjust` 0, 1, 2 (the
   maintainer's ini first): does HDMI blank, how long. This decides whether a size change between
   items is acceptable and whether mid-stream changes need holding back.
2. The 20-dot horizontal blank on ascal (§4: 854x480 has 21): confirmed by the same build.
3. Then `raster_geom`, `sync_gen`, the consumers (§5), the overlay's limits, word 80's native
   values; gates: `run_scaffold.sh` (the native raster's DE / HS / VS against a model, the frame
   exactly F dots, the switch at the frame boundary), `run_disp_reader.sh` (an 852-wide
   identity), `run_ovl_plane.sh` (a 1,024-wide canvas, a raster change), `run_disp_sched.sh`
   unchanged and GREEN (the proof the events did not move).

## 9. Choices for the maintainer -- decided 2026-10-01

**Decided (the maintainer, 2026-10-01): (a) display-shaped whenever it fits; (b) a fourth Video Output value,
`Native (HDMI)`, Auto unchanged; (c) the overlay's identity on any raster, up to 1,024 wide; (d) word 80 in
stage 1.** The options as they were put:

- **(a) The native raster's shape:** picture-sized with A' carried over, or **display-shaped
  whenever it fits** (recommended, narrowly: the overlay covers the screen for wider pictures and
  square-pixel 4:3 transcodes -- Jellyfin's 640x480 -- but every anamorphic 4:3 SD source falls
  back to picture-sized at 59.94, §4's second table; the cost is one more branch in the raster's
  arithmetic, no area to speak of).
- **(b) How native is chosen:** **a fourth Video Output value, `Native (HDMI)`** (recommended),
  whose Auto stays as today; or Auto also picking native when `vga_scaler` = 1 and no analog TV
  is configured (`analog_want` 0) -- the one case where every output goes through ascal. Native is
  never chosen with `direct_video` (no ascal on HDMI), and with `vga_scaler` = 0 the VGA pins get
  the native timing: the manual says so.
- **(c) The overlay in native mode:** **the identity on any raster, up to 1,024 wide**
  (recommended), or a scaled canvas (word 78), later.
- **(d) Word 80 in stage 1** (recommended: programs code against one interface) or with stage 2.

## 10. Known limits (as designed)

- Native needs a picture coded at most 1,024 wide; at 59.94 / 60.00 Hz an uncropped 864x480 and
  full-size portraits fall back to the fitted raster (§4) -- flagged in word 80.
- Native is HDMI-only (and `vga_scaler` = 1); the analog-first default is the fitted raster.
- A size change may blank HDMI for as long as Main's mode change takes (§2) -- measured in stage 2.
- A' leaves the double horizontal resample of the fitted raster; native removes it.
- **A' on a 4:3 HDMI mode** (1024x768, 640x480 output) letterboxes a 16:9 picture inside the
  raster at oh = 360: a real vertical downscale in the core, then ascal's up-scale -- a double
  vertical resample that today's fill + exact aspect does not have. The price of the overlay
  covering the screen on a rare display; native mode removes it.

## 11. Rejected

- **A faster video clock** (a new `sys_pll` output, 32-40 MHz): not needed (§4); it would have
  moved the whole output stage off clk_sys or added a crossing.
- **A raster at the stream's rate** (24 / 25 / 30 Hz, ascal converting): moves the cadence work from
  `disp_ctl` (STC-paced, audio-locked, LL skips) to ascal's triple buffer, and `vsync_adjust`
  would then pick a 24 Hz HDMI mode on some setups. The refresh stays the core's.
- **Moving `disp_ctl`'s events** to fit every legal shape at 59.94: the scheduler's model and
  bench for two shapes no source sends today (§4).

## 12. Stage 1, as built (2026-10-01)

- **Interface 0.10** (`tools/ring_layout.py`): core words 80-87, the sixth burst (written after
  40-47, before 24-31: under the seqlock); word 80 as in `architecture.md` "The raster (0.10)";
  `ring_stat` 48 words a frame with a 7-bit word index (the clk_mem / clk_dec masks stay 64 bits:
  the generator asserts those words are below 64).
- **A'** in `disp_fit` (mode 3, Fill) and `tools/disp_fit_ref.py`; `emu` latches `HDMI_WIDTH /
  HEIGHT` with the mode at the pickup, gives HDMI the display's shape under `fit_lb`.
- **The library:** `h264ring_raster()`; the status copy 0-47 and 80-87. **The Jellyfin client:**
  `raster_lines` / `raster_aspect` from it (the pre-A' fallback rule gone).
- **Gates:** `run_disp_fit.sh --red` ALL GREEN (8,000 vectors, 1,232 taking A'; F16-F20 new, each
  by its own arm -- F17, "wider" at equal, needed every case to meet a 1920x1080 display once);
  `run_ring_rd.sh` GREEN (word 80's fields where the layout puts them, 81-87 zero; S6 / S7 new
  mutations); `run_scaffold.sh --red` ALL GREEN (W69-W73: the display latched, A''s `ar_x`, F8's
  word 47 pin, word 80's sources); `make -C hps test` (the raster decode, the copy; two red arms
  in `tools/tests/red_h264.py`); the client's `run_test.sh` GREEN with **T8** (the overlay drawn
  for word 80's 576 lines at word 47's 16:9) and M16 / M17.
- Riders (F5, the `dec_stub` reset) not taken.
- **Fit:** SEED 6 first roll, 107.83 / 106.16 MHz (gate 101.4), 35,483 ALM (85 %, +371), RAM 378,
  DSP 103 (unchanged: the products are serial), `H264_hdmi-raster_20261001_2310.rbf`.
- **The rig** (`history.md` §22): the scope clip letterboxed inside the raster at 356 lines, word 47
  1920 : 1080, HDMI's picture 1920x801 inside 1920x1080 at the exact 2.397; a 16:9-and-narrower or
  4:3 picture filled with its exact aspect as before; the overlay's progress bar drawn in the lower
  bar. **Next concrete step:** the maintainer's round with the Jellyfin client (a scope film's
  subtitles in the bars, the glyphs' shape), then merge stage 1 or go on to stage 2 (step 0 first).

## 13. Stage 2, as built (2026-10-02)

- **`h264/raster_geom.sv`** + `tools/raster_geom_ref.py` (§3b / §4's rule, from the text): serial
  products and one restoring divider, no DSP; bounds Rw <= 1,024 (the reader's line), Rh <= 2,047
  (its 11-bit line index -- a display-shaped raster of a tall picture at an extreme SAR reached
  4,658 in the model's sweep), L <= 4,000 (`h_pos` 12 bits with the odd line's 31 more). Computes
  while a picture is shown or Native is off; **holds between streams** (a seek never flips the
  raster). `run_raster_geom.sh --red` (G1-G10).
- **`sync_gen`'s native raster**: geometry taken only at a frame's first dot (never a restart:
  disp_ctl's alignment holds); HS [len - 14, len - 6), VS [Rh + 2, Rh + 5); `lines` / `last_line`
  report the current frame to the reader and the overlay. `sync_gen_nat_tb` measures every frame
  (exactly F dots, the DE footprint, the blank >= 20, HS / VS, the report) with segments presented
  mid-frame, at all three standards (N1-N6 in `run_scaffold.sh`).
- **The odd line moved to the first blank line**: `run_disp_reader.sh`'s new 720x576 native case
  at 50 Hz found one line late -- the remainder (150 dots) as the frame's last line left the reader
  150 dots to fetch the next frame's first rows. The frame total is unchanged.
- **`disp_fit`'s native mode** (the picture 1:1, centred on Rw x Rh, no snap, size clamped >= 2
  like every path); F21 / F22. **`disp_reader`** wraps on sync_gen's frame; three native cases
  (852x356 letterboxed, 640x480 pillarboxed to 853, 720x576 picture-sized at 50 Hz) against the
  golden rendered on the native raster.
- **The overlay (0.10)**: canvas up to 1,024 x 2,047 (`OVL_MAX_W` / `_H`), centred with a signed
  offset on the raster's own width and lines, clipped and flagged when wider or taller;
  `run_ovl_plane.sh` n8888wide / n1555tall, O35-O38.
- **emu**: the fit's latches (mode, display shape, Native) moved from line 500 to `disp_ctl`'s
  `pick_ph` (a native raster is shorter or taller; the per-stream reset is a pulse, so the latch
  resumes within a frame); `raster_fitted` is 0 on a native raster (Analog Aspect does not apply);
  HDMI gets the display's shape for a display-shaped raster; word 80 live. `check_emu_wiring` +
  W75-W79.
- **Video Output: Native (HDMI)** (status value 3): `osd_req` and the library accept it; the
  manual's settings page.
- **Fit**: SEED 6 first roll, 106.0 / 104.73 (gate 101.4), 35,896 ALM (86 %, +421), RAM 378, DSP 103,
  `H264_hdmi-raster_20261002_0245.rbf`. Every runner GREEN and `--red` (`run_disp_sched.sh` all 37
  scenarios, progressive and interlaced: the events did not move).
- **The rig** (`history.md` §24): four shapes native as designed (852x480 letterboxed, 853x480 and
  855x480 pillarboxed, 720x576 picture-sized at 50 Hz), HDMI given the display's shape or the
  picture's; a size change mid-session goes straight from one native raster to the next and the
  raster holds after the end; the overlay centred on it. Found and fixed: the library's settings
  request across programs (an interface 0.4 bug: §24).
- **✅ HW-CONFIRMED with the maintainer (2026-10-02, `history.md` §24):** the Jellyfin client in
  Native (HDMI) -- films look good; a size change between items is a small blip, Main's
  resolution box shows the new size. Not measured: what Main reports with the odd blank line. The file-player session's `clients/common/ui.c` assumes 720
  wide (its rebase item). ✅ MERGED (PR fj#26).
