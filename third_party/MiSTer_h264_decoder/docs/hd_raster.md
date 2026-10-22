# The HD raster: Native (HDMI) up to 1280x720 and past it (roadmap Phase 5c part 3)

Status: **✅ MERGED (PR fj#30), ✅ HW-CONFIRMED 2026-10-04 (the overlay over 720p30, Moonlight and Jellyfin
in Native with the maintainer: §13).** **Designed 2026-10-03; §10's choices decided by the maintainer the same day (each as
recommended).** Built on `dev-hd-raster` (the branch merged and deleted). **Stage A built, fitted and on the rig
over HDMI and the analog chain (§12, `history.md` §29). Stage B built, fitted (both gates PASS) and on
the rig: 1280x720 native, x264 720p30 8 Mbit/s 1.13x (§13, §30).** The plan: two stages on one branch, each fitted and run on
the rig (§9).

Read with: `hdmi_raster.md` (the native raster as it is: §3b's rule, §4's timing, §13 as built),
`display.md` §7 (the refresh grid), `analog.md` §10 (the events' phases), `architecture.md` "The
overlay plane", "The capabilities (interface 0.11)", `hw_budget_and_lessons.md` §4 / §5.

## 1. The problem

Since Phase 5c part 1 the core decodes any picture up to 3,600 macroblocks (1280x720). On HDMI,
Video Output **Native (HDMI)** shows a picture at its own pixels only up to 480 lines at 60 Hz.
Word 81's `cap_native_h` is 480, and a 1280x720 picture falls back to the fitted 720x480 raster
(`raster_mode` 2, `history.md` §27). There it is resampled twice (1280 -> 720 by the core, then up
by ascal) and loses most of its horizontal detail. The Jellyfin client asks for a 720p transcode
only when `cap_native_h` >= 720, so today it never does.

The limit is the dot clock, not the decoder. Everything that draws the raster runs on `clk_sys`,
27 MHz, so a 59.94 Hz frame has 450,450 dots. A 1280x720 picture has 921,600 active pixels.

## 2. The clock

**What it must be.** Two constraints set it:

- **Analog first: the SD rasters must not change.** 480i / 576i / 480p / 576p reach the analog
  pins at a 27 MHz dot. On a faster clock, each dot must still be a whole number of clocks: a
  2-3-2-3 pattern (67.5 MHz) alternates pixel widths of 29.6 and 44.4 ns on the VGA pins. So the
  video clock is **k x 27 MHz**.
- **1280x720 inside today's refresh grid.** The grid stays (§4). The active lines end by the skip
  event, 93.3 % into the frame (`hdmi_raster.md` §4), and each line needs 1,280 + 20 dots (ascal's
  blank). So 720 x 1,300 / 0.933 x 59.94 >= **~61 MHz**. k = 2 (54 MHz) gives 900,900 dots a
  frame against the 936,000 needed. **k = 3: 81 MHz.**

**Where it comes from.** `sys_pll`'s VCO is 1,350 MHz (27 = / 50, 90 = / 15, clk_dec 96.43 = / 14).
81 is not a divisor of it (/ 16.67). The VCOs that make 27 x 3, 90 and ~96 together:

- 1,620 MHz is above Cyclone V's VCO range (1,600).
- 1,215 MHz drops clk_mem to 86.8 MHz and clk_dec to 93.5 MHz: -3 % on both.

**So: a second PLL** (the device has 6; 3 are used: the framework's `pll_hdmi` and `pll_audio`,
and `sys_pll`). It runs from the same 50 MHz pin as `sys_pll`: VCO 810 = 50 x 81 / 5, `clk_vid` =
/ 10.

- **Same rate, no drift.** It is locked in frequency to `clk_sys` (both are integer-N from one
  crystal): exactly 3 `clk_vid` cycles per 27 MHz dot. The raster therefore never drifts against
  the refresh grid on `clk_sys`.
- **Unrelated phase.** Every transfer between `clk_sys` and `clk_vid` goes through a crossing
  primitive.
- **Timing groups.** `sys/sys_top.sdc` keeps the core's PLL clocks in one timed group by a
  hierarchy pattern (`*|sys_pll|altera_pll_i|*`). A new PLL that matches no group is timed
  against every framework clock: the UMD-FORK comment there records -68k ns of TNS from exactly
  that. So the edit is an `H264-FORK` addition of the new PLL to the same group. Its crossings
  are then timed on the tightest edge pair and bounded by name in `h264/h264.sdc`
  (`set_max_delay 8`, as every crossing is today). An unbounded crossing shows up as a failing
  path; it is never silently cut.
- **Reset and gates.** Its `locked` enters the reset chain. The `ram` masters' clk_mem sides stay
  on `sys_pll`'s lock; the raster sides take both locks. `tools/fmax_check.sh` gains a second
  gated clock: **clk_vid at 86 MHz, both corners** (the 5 MHz rule). `tools/timing_paths.sh`'s
  `TIMING_CLK` learns to name it.

**Rejected:**

| Option | Why not |
|---|---|
| `outclk_2` (spare, same VCO) at 67.5 or 75 MHz | The SD dot is not a whole number of clocks. |
| 74.25 MHz (CEA 720p) | Same problem. |
| 54 MHz | Too few dots for 720 lines at 59.94. |
| Changing the VCO | Costs clk_mem and clk_dec. |
| Moving `clk_sys` itself to 81 MHz | `clk_sys` closes at **44 MHz** today (the fit's Fmax summary). `raster_geom`, `disp_ctl` and `disp_fit` are 15-17 ns paths, so the whole domain would need retiming. |
| A raster at the stream's rate (30 Hz) | Rejected in `hdmi_raster.md` §11. 900,900 dots at 27 MHz is still under 921,600. |

**The framework on CLK_VIDEO.** `CLK_VIDEO` becomes `clk_vid` (81 MHz), with `CE_PIXEL` every third
clock on the SD rasters and every clock on the native raster:

- **ascal** samples on CE_PIXEL. Only DE matters to it (`hdmi_raster.md` §2).
- **`yc_out`** (composite / S-Video) adds a phase increment each `clk_vid` cycle. Main computes
  that increment from the clock it measures (`video.cpp` `set_yc_mode`: `CLK_VIDEO = ctime x 100 /
  ptime`), so the subcarrier follows any clock. **To confirm on S-Video with the maintainer**:
  analog first.
- **Timing.** ascal's input side (12.2 ns paths today, constrained at 27 MHz) and `yc_out` (13.4 ns)
  must close at 86 MHz. They are framework code: if they do not close, that is a finding to bring
  back, not something to retime here.

## 3. The domain split

**Moves to `clk_vid`:**

- `sync_gen`
- the raster sides of `disp_reader` and `ovl_plane` (the line control and the read-out)
- `idle_bars`, `csync_smpte`, `ovl_blend`
- `emu`'s output stage (the `*_dly` lines, the selection registers, the VGA registers)

**Stays on `clk_sys`:**

- `disp_ctl` and `disp_sched`: the grid, the 90 kHz tick, the STC, and the audio's pacing through
  them
- `disp_fit`, `raster_geom`
- `emu`'s latches at the pickup
- `ring_stat`, `osd_req`, everything else

The `clk_mem` sides of the reader and the overlay do not move.

**The rule: every raster-side register advances on the dot enable `ce`.** `ce` is one clock in
three on a fitted raster and every clock on the native one. This covers the reader's and the
overlay's LAT-5 read-outs, the output stage's LAT 6, and the 480i pixel repetition (a sub-enable,
one dot in two). LAT is counted in dots: `check_emu_wiring` reads it so. A stage that advanced on
clocks instead would be correct on the native raster and **wrong on every SD raster**, the analog
one included. §8's equivalence gate exists for this.

**The crossings:**

| Direction | What | How |
|---|---|---|
| `clk_sys` -> `clk_vid` | the picture (`sh_*`), the fit (`fit_*`), the raster geometry (`geom_*`), the settings the raster reads (`il`, `pal`, `std`, `deint_mode`, `at_en`, `sess`) | Quasi-static bundles: set at the pickup, 21,450 dots before the frame that uses them. One toggle per bundle, captured once it has crossed two flops, as `disp_reader`'s commands are today. |
| `clk_vid` -> `clk_sys` | the frame alignment | `disp_ctl` starts its tick and refresh counter at the raster's first (0, 0) after the mount reset (it reads `h_pos` / `v_pos` today). It gets a frame-start pulse instead, crossed in two flops: a constant offset of 2-3 `clk_sys` cycles against a 300-cycle tick. `disp_sched`'s model and its 37 scenarios do not change; their GREEN is the proof. |
| `clk_vid` -> `clk_sys` | `fetch_late`, the `ovl_*` counters and `ovl_gen` / `ovl_state`, `lines` / `last_line`, `frame_tick` | `cdc_snap` for the words; a toggle for the pulses. |
| `clk_vid` <-> `clk_mem` | the reader's and the overlay's command / done toggles and descriptor request | Today's primitives with a new clock on one side. `h264.sdc`'s patterns match them by name; a census after the first fit confirms nothing is left unbounded. |

**What has to be retimed** (the census, from the last fit's database, `H264_resovlp_20261003_2016`,
cold corner). These are `clk_sys`-launched endpoints of the moving modules whose data delay is
over 11 ns; 81 MHz with the gate's margin leaves ~11.6:

| Module | Endpoints over 11 ns | Worst (ns) |
|---|---|---|
| `disp_reader` (the raster side, its slot RAMs' address registers) | ~240 | 22.7 (`prot` -> `al_skip`) |
| `ovl_plane` (raster side) | 94 | 14.5 |
| `sync_gen` | 105 | 14.3 |
| the output stage (`ovl_blend` -> the VGA registers' shift taps) | 24 | 22.0 |
| `csync_smpte` | 1 | 13.4 |

Paths constrained at 37 ns were never pushed by the fitter, so this is an upper bound. Even so, it
is a retime round of `hw_budget_and_lessons.md` §5's kind, at 88 % ALM. Part of the reader's
22.7 ns is in the line control, which runs once a line (1,750 clocks at 720p). It can take more
cycles rather than more logic.

## 4. The native raster on the 81 MHz dot

**The grid does not move.** The refresh stays F 27 MHz dots (450,450 / 450,000 / 540,000). The skip,
eval and pickup stay at their phases on `clk_sys` (`analog.md` §10). In `clk_vid` cycles a frame is
exactly **3F** (1,351,350 / 1,350,000 / 1,620,000) and the active lines end by **Ae' = 3 Ae**
(1,261,260 / 1,529,280). `hdmi_raster.md` §4's geometry applies unchanged in these units:
`L = min(floor(Ae' / Rh), 4,000)`, the odd line first in the blank, fits iff `L - Rw >= 20`.

| Picture | 59.94 / 60.00 | 50 Hz |
|---|---|---|
| 1280x720 | L 1,751, blank 471 | L 2,124 |
| 854x480 / 852x480 | L 2,627 | fits |
| 864x480 uncropped (fell back at 27 MHz) | L 2,627: **fits** | fits |
| 720x480 SAR 8:9, display-shaped 960x480 (picture-sized at 27 MHz) | **fits** | fits |
| 480x854 portrait (fell back) | L 1,476: **fits** | fits |
| 2048x448 (128 x 28 MB, the widest legal shape) | L 2,815 | fits |
| 448x2048 (the tallest) | L 615, blank 167 | fits |

**Every picture the decoder accepts fits picture-sized.** Rw x Rh <= 921,600 and Rh <= 2,048
give Rh (Rw + 20) <= 962,560 <= Ae'. The display-shaped raster (`hdmi_raster.md` §9 (a)) is used
whenever it fits, picture-sized otherwise (flagged, as today). §4's fallbacks at 59.94 disappear
along with the "skip one line later" follow-up noted there.

**The fitted rasters** (480i / 576i, 480p / 576p, the idle screen) keep the 27 MHz dot: `ce` one
clock in three, sync_gen's counters advance on it. Same timing, same pins (§8's gate).

## 5. The width: 2,048

- **The reader.** Its line slots hold 1,024 samples (`h_pos[9:0]`); a native picture is limited to
  `16 W <= 1,024`. They become **2,048 samples**: the next power of two above 1,280 (the lesson
  file's rule: a non-power-of-two depth falls out of M10K). That is also the decoder's side bound,
  128 macroblocks. Level 3.1 allows 169 macroblocks, and that is an open `spec_hardening.md` row
  for the maintainer. If the decoder's bound is ever widened, a picture over 2,048 wide falls back
  to the fitted raster, flagged (`raster_mode` 2). It is never truncated.
- **`raster_geom`.** Rw <= 2,048. Rh <= 2,047 becomes **2,048**: a 128-macroblock-tall picture has
  2,048 lines, and today's bound misses it by one.
- **The overlay.** The canvas goes up to 2,048 x 2,048 (`OVL_MAX_W` / `_H`): slot 2 x 2,048 x 32,
  accumulator 2,048 x 40. The RANGE check still keeps a canvas inside the framebuffer's region, so
  a 2,048 x 2,048 8888 canvas (16 MB) is refused by it. `clients/common/ui.c` sizes its pages from
  the raster rather than the maximum.
- **Memory.** The reader's slot RAMs double (~192 Kbit), and the overlay's slot and accumulator
  double (~100 Kbit): **~+30-40 M10K** of the 176 free. No DSP: 9 are left.

## 6. Bandwidth and DDR3: the risk

A 1280x720 raster at 60 Hz moves about three times what today's raster does:

| Load | Today (480-line raster) | 1280x720p60 |
|---|---|---|
| The reader on `ram2` (4:2:0) | ~37 MB/s | ~83 MB/s |
| A full 8888 overlay canvas on `ram2` | ~83 MB/s | ~221 MB/s |
| ascal's input written to DDR3 (24 bpp) | ~74 MB/s | ~166 MB/s |

The display has its own port (`ram2`), but the DDR3 controller is shared with `ram1` (the DPB), so
the cost is arbitration occupancy (`hw_budget_and_lessons.md` §1).

**Measured on the rig 2026-10-03** (main's build `H264_resovlp_20261003_2016`, x264 720p30
8 Mbit/s, `h264play`, 480i):

| Run | Decoder idle | Real time |
|---|---|---|
| no overlay | 11.3 %, 11.3 % | 1.13x |
| a full 8888 canvas (`--overlay 8888 --overlay-band 0,479`, ~83 MB/s) | 9.5 %, 9.6 % | 1.11x |

So ~83 MB/s of display traffic costs this stream ~1.75 points of idle. Extrapolated linearly, the
HD raster's extra ~150 MB/s (reader and ascal) and ~140 MB/s (a full 1280x720 8888 canvas) cost
**~3-4 points** without an overlay and **~7** with a full one. That puts x264 720p30 8 Mbit/s at
**~1.08x** and **~1.03x**. It stays real time, but thinly; contention is not linear, so the stage B
gate measures it. Ordinary overlays declare a band (a progress bar, subtitles) and cost little. A
full-screen canvas is the browse UI's case, and it does not play video beneath it.

**Not designed around:** a cap on the overlay's canvas in HD, or 4444 forced. If stage B's
measurement shows 720p30 falling under real time with a full canvas, that is the maintainer's
call then, with the number.

## 7. The interface: 0.12

- **Word 81's `cap_native_h`: 480 -> 720.** Its text becomes "the tallest 16:9 picture shown at its
  own size: 720, every picture the core decodes, on a raster of 3F 81 MHz dots". The Jellyfin
  client's 720p transcode in Native (HDMI) turns on from this value with no client change; its host
  test gains the arm.
- **`OVL_MAX_W` / `_H`: 1,024 x 2,047 -> 2,048 x 2,048.** The table in `tools/ring_layout.py`, the
  library's range check and its red arm in `tools/tests`.
- **The rest.** Word 80's fields are 12 bits (up to 4,095): unchanged. `H264RING_VERSION` 0x0C.
  The manual: `integrating/status.md` and `overlay.md`, `using/settings.md` (Native (HDMI): HD
  pictures at their own pixels), `reference/compatibility.md`, the README's headline if it
  names 480.
- **Clients.** `clients/common/ui.c` (the page layout, §5). The Moonlight client at 1280x720p30 is
  then shown native: nothing to change. The file player: nothing.

## 8. The gates

1. **The SD equivalence gate (new, the analog-first proof).** A bench runs `emu`'s raster path at
   the branch's two clocks. Each `ce` dot's VGA R/G/B/HS/VS/DE/F1/CE_PIXEL is compared bit for bit
   with main's per-`clk_sys` trace of the same raster, picture and overlay. It covers 480i, 576i,
   480p and 576p at the three standards, anti-twitter On, and the overlay in each format. Main's
   trace is captured once from main's RTL as the golden. Mutations: a reader stage on the clock
   instead of `ce`, a `*_dly` stage on the clock, the 480i sub-enable dropped. Each is caught by
   its own arm.
2. **Every bench that instantiates a moved module** gains the second clock and `ce` in the same
   commit (a new port floats Z otherwise): `run_scaffold.sh`, `run_disp_reader.sh`,
   `run_ovl_plane.sh`, `check_emu_wiring` (its LAT pins).
3. **`run_disp_sched.sh`** unchanged and GREEN: the events did not move, and the frame-start
   pulse's offset is invisible to it.
4. **The native raster.** `run_scaffold.sh` (`sync_gen_nat_tb`: frames of exactly 3F clocks,
   1280x720, 2048x448, 448x2048, the switch at a frame boundary). `run_disp_reader.sh` (a 1280x720
   identity, a 2,048-wide case). `run_ovl_plane.sh` (a 1,280- and a 2,048-wide canvas).
   `run_raster_geom.sh` (Rh 2,048, the 81 MHz units; `tools/raster_geom_ref.py` the same).
5. **Fit.** clk_dec 101.4 and **clk_vid 86** at both corners. The census (§3) after the first roll.
   The `M10K` and `altsyncram` lines for the doubled slots.
6. **On the rig.** Stage A: HDMI and the RetroTINK at 480i / 576i unchanged, S-Video on a CRT with
   the maintainer (`yc_out` at 81 MHz). Stage B: 1280x720 native (`raster_mode` 1, ascal at its
   exact aspect), §6's measurement with and without a full canvas, the Jellyfin client's 720p
   transcode in Native with the maintainer.

## 9. Stages

- **Stage A: the domain move, no new capability.** The second PLL, `clk_vid`, the split and the
  crossings (§3), `ce` everywhere on the raster side, the retime round, gate 1. The native raster
  stays on the 27 MHz dot (`ce` 1 in 3), so **every output is as on main**. It is fitted and run
  on the rig. If the retime does not close at 88 % ALM, that is learned before the wider line adds
  area.
- **Stage B: HD.** The native raster on the 81 MHz dot (§4), the 2,048 line (§5), interface 0.12,
  the clients, the measurement (§6). Fitted, run on the rig, with the maintainer's rounds.

## 10. Choices for the maintainer -- decided 2026-10-03

**Decided (the maintainer, 2026-10-03): (a) a second PLL at 81 MHz; (b) every native raster on the
81 MHz dot; (c) native up to 2,048 wide; (d) two stages, each fitted and on the rig.** The options
as they were put:


- **(a) The clock: a second PLL at 81 MHz = 3 x 27** (recommended: the only clock that keeps every
  SD raster bit-identical and costs neither clk_mem nor clk_dec). The alternatives are in §2.
- **(b) Which native rasters use the 81 MHz dot.** Every native raster (recommended): one geometry,
  every legal picture native, the 59.94 fallbacks gone. Or SD native stays on the 27 MHz dot as
  confirmed, and only a raster that does not fit there moves up: two cases where one suffices,
  and the 864x480 / 480x854 / anamorphic-4:3 fallbacks stay.
- **(c) The native width: 2,048** (the decoder's side bound; recommended, and 1,280 costs the same
  memory, §5). Wider falls back, flagged.
- **(d) Two stages, each fitted and on the rig** (recommended), or one fit at the end.

## 11. Known limits (as designed)

- A full-canvas 8888 overlay over 720p30 at 8 Mbit/s is expected near real time, not comfortably
  inside it (§6). It is measured in stage B.
- Native is HDMI-only, as before. With `vga_scaler` = 0 the VGA pins carry an 81 MHz-dot raster of
  odd timing (as they carry the 27 MHz native raster today); the manual says so.
- A Level 3.1 picture wider than 128 macroblocks is refused by the decoder (`spec_hardening.md`).
  If that bound is lifted, the native raster falls back past 2,048.
- **`direct_video`** (an HDMI-to-VGA DAC to a CRT: an analog user's setup) clocks the HDMI
  transmitter with `CLK_VIDEO` itself (`sys_top.v`'s `hdmi_clk_sw`). On 81 MHz the transmitter
  sends each 27 MHz dot three times (480p: 2,574 x 525 at 81 MHz; 480i: 5,148 x 525i). The
  timing in microseconds is the same and the DAC's analog output identical in principle, but the
  pixel clock it is handed is not CEA's. **To confirm on the rig with a DAC** (stage A): if a DAC
  refuses it, the fallback is a `direct_video`-only 27 MHz `CLK_VIDEO` (a clock mux), designed
  then.

## 12. Stage A, as built (2026-10-03, in progress)

- **The clock:** `h264/vid_pll.sv` (81 MHz from the pin `sys_pll` runs from; `emu|vid_pll`), its
  `locked` in `LOCKED` and in the raster side's resets (`vid_lock_n`, `vid_rst_n`, `vid_fe_rst_n`:
  `cdc_reset`s into clk_vid of the locks, RESET, the per-stream reset). `sys/sys_top.sdc` keeps it in
  the core group (`H264-FORK`). `CLK_VIDEO = clk_vid`; sys_pll's `outclk_2` is spare again.
- **The dot:** `ce_dot`, one clk_vid cycle in three. `sync_gen` (clk_en), `disp_reader`'s and
  `ovl_plane`'s raster sides, `idle_bars`, `csync_smpte` and the output stage advance on it. The
  output stage is `h264/vid_out.sv` now (emu's inline code, unchanged but for the gating) so the
  equivalence bench runs the same code as emu. `CE_PIXEL` is high one clock a dot (`ce & ce_dly[5]`).
  `sync_gen`'s `frame_tick` is a level for its dot (consumers on the dot see it once) and it reports
  the mode it scans (`mode_il` / `mode_std`).
- **The crossings** (§3): `raster_dn_xing` (one continuous `cdc_snap`, 258 bits: mode, geometry,
  picture, fit, deinterlace, the overlay's session and anti-twitter, the idle flag) into clk_vid;
  `raster_up_xing` (112 bits: `fetch_late`, the overlay's words 46-47) back; `frame_sys` (every
  refresh: `ring_stat`, `ring_in`) and `frame0_sys` (the frame start, taken only when the mode it
  was scanned in -- `f0_tag` -- is `disp_ctl`'s) as `cdc_pulse`s. `disp_ctl`'s `h_pos` / `v_pos`
  became `frame0`: the grid is now 2-3 clk_sys cycles later against the raster (its events are in
  the vertical blank). `h264.sdc` bounds the pulses, the tag and the reader's captures from the
  bundle; the overlay's and the reader's other bounds match by name.
- **Found on the way:** the reader's slot RAMs must be read on the dot too. Read every clock, the
  stage-1 register held the NEXT dot's word when stage 2 took it beside this dot's byte selects
  (`run_disp_reader.sh` red from dot 7; now Q7 of the equivalence gate).
- **Gates:** `run_vid_equiv.sh` (new, §8 gate 1) GREEN: seven scenarios identical dot for dot at
  the pins against main's fork point (480p / 480i / 576i / 576p, 59.94 / 60.00 / 50 Hz, anti-twitter,
  1555 / 4444 / 8888, the idle bars in the margins); Q1-Q7 each caught in its own class (Q2's
  anchor fixed after the first run). `run_scaffold.sh --red` (W80-W90 new: the dot, the bundle's
  packing, the frame tag, CE_PIXEL, the gating; the output-stage arms read `vid_out.sv`;
  `check_emu_wiring` resolves the bundle so the old arms keep their meaning). `run_disp_reader.sh`
  and `run_ovl_plane.sh` GREEN at 81 MHz with the dot one clock in three (`+ce1`: every clock, for
  stage B). `run_csync_field.sh` GREEN (ce tied 1: a unit bench; the gate covers the dot).
- **The retime** (`H264.qsf`'s ledger, three fits so far):

  | fit | clk_vid (100 / -40 C) | clk_dec | what was left |
  |---|---|---|---|
  | 1 (`e145a75`) | 60.46 / 59.92 | 94.68 / 96.49 | 596 endpoints: the reader's read-out (stage 2: the byte select and the horizontal blend, 16.3 ns; stage 0: the position into the RAM address, 15.6) and line control (the slot allocation's tag compares, 16.1; the row position's 44-bit product), the overlay's descriptor checks (15.1) and read-out, the composite (14.9), ascal / `pll_hdmi_adj`'s input side (24, framework); the crossings with clk_vid -1 to -4 ns on 8 ns bounds |
  | 2 (`20f47ff`) | 85.26 / 81.86 | 101.86 / 100.54 | 14 endpoints, one cluster: the reader's stage 5 (the vertical blend, 11.8 ns); every other domain clean; ascal / `pll_hdmi_adj` closed by themselves (placement) |
  | 3 (`d09514e`) | 92.76 / 93.63 PASS | 100.64 / 102.55 | clk_dec only (the seed sweep: 7 seeds, best 101.24 / 102.56) -- one cluster, `mc_interp`'s S7 (t7_s -> fmem, 10.0 ns): S7's parameters registered from t6's set, bit-exact (`run_mc.sh --red`; its +ovl bench now two window banks, M15 caught again) |
  | 4 (`35e72b7`) | **92.16 / 92.05 PASS** | **104.30 / 103.71 PASS** | SEED 6 first roll, 36,639 ALM (87 %), RAM 375, DSP 102, `H264_hd-raster_20261004_0243.rbf` |

  Round 1: the read-outs from LAT 5 to **LAT 9** (the reader: position / taps + RAM / the M10K's
  output register / bytes / horizontal blend / vertical blend / products / sums / clip; the
  overlay: column / RAM / output register / delays); **the composite registered** (`ovl_blend`'s
  `PIPE`, vid_out's `LAT_BLEND` 1: the pins 12 dots after sync_gen); the reader's line control on
  local copies of the fit, its row product in two halves and its sums one a step (15 steps), the
  slot allocation ordering the tags from a registered matrix; the overlay's checks a step more;
  idle_bars' marker edge a register; no M10K shift registers in the raster modules (fit 1 had put
  delay chains in `altshift_taps`). **The crossings with clk_vid bounded at 12 ns, not 8**:
  `set_max_delay` counts the skew between the two PLLs (~3 ns: 5 ns of data failed 8); every
  capture they protect is >= 2 destination cycles after its qualifier. Round 2: the vertical blend
  as `(256 - w) b + w d + 128` (the same integer, no subtract before the multiply) and luma's
  kernel chosen in stage 6. LAT stays 9.
  **The latency is uniform** -- every signal at the pins moves together -- so nothing downstream
  sees it but a 12-dot shift of the whole raster (ascal and a CRT do not); the equivalence gate
  starts its trace at a VS rise at the pins, so it compares the raster, not its delay.
- **`run_disp_sched.sh`** GREEN (all 37 scenarios, progressive and interlaced: the grid's frame
  start, crossed, moved nothing the scheduler scores).
- **On the rig** (`history.md` §29): HDMI unchanged (480i / 480p / 576i / 576p / Native, every
  picture, errors 0), x264 720p30 8 Mbit/s 1.13x as on main. Not measured: the overlay (the rig's
  Main had been switched to `MiSTer_DVDcss`, under which `h264play` cannot map `/dev/fb0`) and the
  analog chain.
- **`--red` after the retime** (2026-10-04): `run_scaffold`, `run_vid_equiv` (Q1-Q7; Q2 -- the sync
  delays on the clock -- now shows as [rgb]: the trace starts at a VS rise at the pins),
  `run_disp_reader`, `run_ovl_plane` (O15's anchor follows the registered checks), `run_mc` (M15
  caught again by the two-bank bench) ALL GREEN. `run_disp_sched.sh --red` (~1.5 h) not re-run.
- **The analog chain** (2026-10-04, `history.md` §29, on .236 where the RetroTINK is): 480i 59.94 /
  60.00 and 576i measured by the RetroTINK exactly as main's (1716x525i / 1728x625i, 26.9996 MHz,
  59.94 / 60.00 / 50.00 Hz), field order correct at both (101 / 99 lines), anti-twitter's (1, 2, 1)
  through the pins (45 / 94 / 45).
- **Next:** S-Video on a CRT (`yc_out` at 81 MHz) and a DAC on `direct_video` if one is at hand, the
  overlay under the stock Main (.201 runs `MiSTer_DVDcss`) -- then stage B (§9).

## 13. Stage B, as built (2026-10-04)

- **The native raster on the 81 MHz dot** (§4): `raster_geom` (and `tools/raster_geom_ref.py`, from
  this text) in 81 MHz dots -- a frame 3F, the active lines by 3 Ae, Rw / Rh <= 2,048, coded <= 128
  macroblocks. Every picture the decoder accepts is native (the model asserts it on 6,000 random
  shapes); 864x480 (864x486 display-shaped), portraits and anamorphic 4:3 SD (960x480) no longer
  fall back. `run_raster_geom.sh --red` (G1-G10).
- **The dot** (`sync_gen`'s `dot`, emu's `ce_dot`): the 27 MHz tick on the fitted rasters, every clock
  on the native one **once its frame has begun on a tick** (`nat_go`), so a native frame starts on a
  tick and, 3F clocks long, ends the clock before one -- the frames keep their time against the
  grid across a switch either way. The outputs are registered a dot behind the counters and a dot is
  3 clocks fitted, 1 native: at a switch the visible frame start moves 2 clocks (25 ns, in the
  vertical blank; `sync_gen_nat_tb` scores exactly that, and 3F everywhere else).
- **The line, 2,048 samples:** `disp_reader`'s slots (4 x 2,048 luma, chroma 1,024), the column 11
  bits, the word index and the decimation accumulator 256 words; `disp_fit` no longer forces dh >= 2
  past 1,024 on the native raster (F23). `ovl_plane`'s slots 2 x 2,048 and accumulator 2,048, the
  canvas widths 12 bits.
- **Interface 0.12** (§7, `architecture.md`): `CAP_NATIVE_H` 720, `OVL_MAX_W` / `_H` 2,048, version
  0x0C; the library, `clients/common/ui.c` (rows the raster's width since 2026-10-04 -- below), the
  Jellyfin host test ((b'') the HD profile; M6d / M6e), the manual's pages.
- **Found:** `ovl_plane` centred the canvas on `sync_gen`'s CURRENT frame's lines when it took the
  descriptor on the old frame's last line -- the first frame after a native size change showed the
  canvas off by half the change (since hdmi_raster stage 2; the 480 -> 720 arm found it). It now
  centres on raster_geom's height (`rast_h`), as it did the width.
- **Known limit (found by the first n8888hd fixture):** the overlay engine composes every canvas
  column, the clipped ones too, at one pixel a clk_mem cycle. A canvas no wider than the raster always
  keeps up (a native line is at least Rw + 20 dots at 81 MHz, the engine runs at 90), but a much wider
  one does not: a 2,048-wide canvas on 1280x720 loses lines (shown transparent, counted in `ovl_late`
  -- visible, never silent). The manual tells programs to size the canvas to word 80's raster. A
  fetch that skips the clipped columns is the fix if a program ever needs it.
- **Gates so far:** `run_disp_reader.sh` (nat_hd 1280x720, nat_w2k 2048x448: pixel-exact on the 81
  MHz dot, no line late), `run_ovl_plane.sh` (n8888hd, n4444w2k, n8888w2k: a 2,048-wide 8888 canvas, the
  only one that sets the line word count's top bit -- O38's arm), `run_raster_geom.sh --red`,
  `run_disp_fit.sh --red`, `sync_gen_nat_tb` at all three standards, `check_emu_wiring` (W91, W92),
  `make -C hps test`, `tools/tests`, the manual's checks; `run_scaffold.sh` and **`run_vid_equiv.sh`
  GREEN again after stage B** (the SD rasters still identical to main's at the pins); the Jellyfin
  (`--red`), player and Moonlight host tests.
- **Fit:** SEED 6 closed clk_vid (95.33 / 91.57) but not clk_dec (96.60 / 98.63, placement); the sweep's
  **SEED 3: clk_dec 105.21 / 103.79, clk_vid 98.86 / 96.39, both PASS**, 36,736 ALM (88 %), RAM 411
  (+36), `H264_hd-raster_20261004_1539.rbf`.
- **On the rig** (`history.md` §30): 1280x720 shown natively, every picture, errors 0; **x264 720p30
  8 Mbit/s 1.13x natively, the same as on the fitted raster** -- §6's risk did not materialise at
  720p (the display's reads and ascal's input cost nothing measurable).
- **Found on the rig (2026-10-04): `/dev/fb0` is Main's HDMI mode's size**, not the 8 MB region:
  `smem_len` 1,382,400 at `video_mode=2` (720x480), 3,686,400 at 0 (1280x720), 8,294,400 at 8
  (1920x1080) -- measured with a probe of `FBIOGET_FSCREENINFO` (`architecture.md` corrects its
  2026-09-30 note, which took one 1080p measurement for a constant). Stage B's `ui.c` laid two pages
  of 2,048-pixel rows: 450 lines on a 1280x720 mode, under its 576-line floor -- **the Jellyfin client
  and the player had no UI on a 720p HDMI mode** (main's 1,024-pixel rows gave 900; on a 720x480 mode
  main's UI was refused too: 337 lines). On the rig the player exited "ui: the framebuffer: too
  small". **Fixed in `ui.c`:** rows the raster's own width (a multiple of 8 bytes), the two pages laid
  out again at every raster change (the overlay hidden first and neither page drawn until the core
  has taken the hide: the shown page may overlap either new one), a raster taller than two pages fit
  drawn shorter (logged; the core centres it), and the only open-time floor two 720x480 pages (a
  720x480 mode's whole framebuffer). On the rig the player's UI opens at 720x480 and 1280x720 modes.
  The player's host test now runs on a 1280x720 mode's framebuffer (`CLIENT_TEST_FB_LEN`) and a second
  arm on a 720x480 mode's: T8 (every canvas the raster's lines, or all two pages fit) and T9 (every
  canvas inside `smem_len`), M13 (the fixed 2,048 row) and M14 (pages spaced for the tallest canvas).
  `h264play --overlay-size` takes up to OVL_MAX (it stopped at 720 x 576) and names the bytes it
  needs when `/dev/fb0` is too small.
- **The overlay over 720p30 (§6's measurement, 2026-10-04, `history.md` §30)**, x264 720p30 8 Mbit/s
  in Native on a 16:9 mode (raster 1281x720: the clip's SAR 1215:1216), a full 1280 x 720 canvas
  (`--overlay-size 1280,720`, live: `ovl_state` 1, `ovl_lines` 720 a refresh, `ovl_late` 0): no
  overlay 10.7-10.8 % idle (1.12x); **`4444` 9.7 % (1.11x); `8888` 7.4 %, 7.4 % (1.08x)** -- every
  picture, late / skip / fetch-late 0. §6 had predicted ~7 points with a full 8888 canvas: it costs
  ~3.3, and 720p30 at 8 Mbit/s stays real time under it. Nothing to decide (§6's "not designed
  around" holds).
- **The Moonlight client at 1280x720p30 in Native, with the maintainer (2026-10-04, `history.md`
  §30):** clean picture, controls responsive; 11,961 access units, 0 decoder errors, 0 IDRs asked.
- **The Jellyfin client in Native, with the maintainer (2026-10-04, `history.md` §30):** a 720p file
  direct played, a 1080p film transcoded to the HD profile's box -- both good on HDMI.
- **Every runner's `--red` after stage B (2026-10-04):** `run_scaffold`, `run_disp_reader`, `run_ovl_plane`,
  `run_vid_equiv` ALL GREEN (and RED); `run_disp_sched` all 37 scenarios on both rasters (8 re-run with
  `DSCHED_ONLY` after another session's `kill` by process name took them); the player (`--red`, T8 / T9)
  and Jellyfin (`--red`) host tests, `make -C hps test`. Three mutation anchors had kept pre-widening
  text (R6 `c_n`, O9 / O28 / O38) -- found as harness failures, fixed.
- **✅ MERGED (PR fj#30).** Not testable here: the direct-video DAC (§11's fallback
  stays recorded). Recorded for later: the Moonlight client's automatic size on Native + a 720p-capable
  mode (`moonlight.md` §5's note: still 848x480 at 60). Not testable here: the direct-video DAC (the maintainer has none; §11's fallback
  stays recorded).
