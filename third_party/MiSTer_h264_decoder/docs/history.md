# Solved-problem history (condensed)

Each entry: *what was wrong*, *how it was fixed*, one paragraph each. The full
investigation lives in the docs note or PR it names; this file is the index a cold
session reads first.

---

## 1. The scaffold (P0)

**First fit (2026-09-27, `H264_scaffold_20260927_1219.rbf`, SEED 1, first roll, commit
`021682d`):** 6,779 ALMs of 41,910 (16 %), 10,032 registers, 60 M10K, 33 DSP (all
ascal's); clk_dec 297.62 MHz @100 °C / 291.89 @−40 °C against the 86.0 gate (the domain
holds one 24-bit counter, so this says nothing about the decoder to come); 2.4 MB
compressed. No implicit nets; `lint_undriven` and `netlist_canary` PASS. In `emu`:
`hps_io` 287 ALM (its `video_calc` 236), `idle_bars` 32, `sync_gen` 27, `dec_stub` 12.
411 ALM under UMD's P0 (7,190), which carried the PSP wave (232 ALM, 3 DSP) and the
block streamer (101).

*What the scaffold taught:* `tools/lint_undriven.sh` greps Verilator's output for
"Signal is not driven", and Verilator exits 1 on this tree (eleven `PROCASSWIRE` errors
in stock `hps_io`, the same in UMD). A grep that finds nothing on a failed parse would
read as PASS, so the gate was checked for that: an undriven `stream_live` is reported by
name despite the errors, and `run_scaffold.sh --red` keeps it as mutation L1.

*Hardware (same day):* loaded on the rig from the menu core with `tools/mister.py`
(`CORENAME` H264). Two raw screenshots ~1.7 s apart matched the layout pixel for pixel
(bars on every 7th line, the band black but for the 32x32 marker) with the marker at x 4
and x 400 -- 99 frames at 4 dots each, so the core runs. `shot --scaled`: 1920x1080 at
Auto (the rig's 1080p mode is widescreen) and 1440x1080 with `Aspect Ratio=4:3`. Not
exercised: the analog output.

*What the hardware round taught (the harness, not the core):* `launch` backed up the
settings file once, and when none existed the SECOND launch backed up the FIRST launch's
own all-zero file as "the user's", which `restore` then put back -- leaving a file the
maintainer never had. Fixed in `tools/mister.py`: a `.hilnew` marker records that the
harness created the file, and `restore` deletes it (proved on the rig: two launches,
restore, nothing left). `restore` also waits 4 s for the menu load, so a `state` right
after reads MENU rather than the unloading core. UMD's copy has the same backup logic.

## 2. The fork (P2): UMD's decoder and display path, fed by the ioctl stand-in

*2026-09-27, `feature/p2-harvest`, UMD `cc595c6`.* The first fit with the decoder:
SEED 1 first roll, **23,331 ALM (56 %), 230 M10K, 69 DSP, clk_dec 91.43 / 88.67 MHz**
at the two slow corners (the gate is 86), every gate PASS,
`H264_p2harvest_20260927_1801.rbf` (`cf2851a`). The Phase 2 estimate was ~24-25K ALM and
~250 M10K; UMD's P5 fit with its reader, demux, HUD and vbuf was 31,400 / 401 (with
ATRAC3plus). The reconstruction alone is 11,453 ALM against UMD P4's 11,524: the same
netlist, as a verbatim copy should be. `netlist_canary` confirms the ES crossing carries
live bytes: the stand-in did its job, the decoder was not folded.

*What the harvest taught.* Three RED arms of `run_recon_ctl.sh` targeted disc fixtures and
would have SKIPped -- silently, in a runner that prints ALL GREEN -- the moment the discs
went away; the cosim's EPB arm (C4) survived on the x264 window because 12 frames of x264
carry no emulation-prevention byte in slice data (Akira's did). Both were found only by
running every `--red` arm after moving the fixtures: a fixture swap is a change to the
gate, not just to its input.


## 3. The HPS interface (P3): first pictures on the rig, through the ring

*2026-09-27, `feature/p3-ring`.* The first fit with the ring reader and the status block
(P3i, before the low-latency stages): SEED 1 first roll, **25,965 ALM (62 %), 235 M10K,
71 DSP, clk_dec 87.94 / 87.19 MHz**, every gate PASS, `H264_p3ring_20260927_2029.rbf`
(`3db8aba`). The interface itself is 1,385 ALM (`ring_rd` 764, `ring_stat` 296, the status
muxes 217, `ddr_probe` 108), inside the 1.4-1.8K estimate; the other ~1,200 of the growth
are the decoder's and the display's counters, which P2 left unconnected and Quartus pruned,
now live in the status block.

*The first hardware round* (the rig idle on the menu beforehand; `tools/mister.py deploy
--bin`, the clips from `tools/p3/make_clips.sh` on the rig's own storage):

- `h264play film.264` (720x480, 23.976 frames/s coded, B frames, 240 access units) loaded
  the core through its own MGL, opened a session and played: **ENDED, 240 decoded, 240
  shown, judder pair equal (240 / 240), late / starved / cadence 0, every error and
  refusal 0**; two shots a second apart, the zoom moved.
- `p60.264 --switch switch.264 --at 300`: the switch recovered (the SMPTE bars on screen,
  3 streams counted, the last one's 300 pictures decoded and shown, errors 0, ENDED).
- **480p59.94 is not real time yet**, measured, not assumed: ~59,600 macroblocks/s
  (44 pictures/s) on the testsrc2 clip against 81,000 needed -- Phase 1's gap (57-66k
  measured on UMD's rig), Phase 5's work. It is visible, never silent: `disp_late` and
  `disp_starve` count it, every picture is still decoded and shown in order.
- A second `h264play` was refused by the lock (EBUSY); a killed feeder's successor started
  a new session and played clean.
- **Ten core reloads mid-stream** (the ring reader inside its bursts, the previous
  feeder's nonce and write index left in DDR3 each time): alive after every one, then a
  clean play -- no port hang, and the boot rule ignored the stale session each time.

- **The PTS path end to end** (`sun.264 --pts`: P only, so decode order is presentation
  order): `fe_pts_tag` 600 of 600 access units, 0 dropped, one anchor, ENDED, errors 0 --
  PTS_VALID -> the parser's mark -> `au_pts` -> the scheduler, on hardware.
- **END_OF_STREAM then a new stream in one session** (`film.264 --loop 2`): the library's
  automatic DISCONTINUITY, the parser's wait for the display's END: 240 / 240 again,
  ENDED, no NEED_DISCONT. (Across the runs the fetch side counted 1,079 changes for 1,080
  pictures: a new stream's first picture can land in the store the old stream's last
  one held, which `fetch_changes` -- counting (store, parity) changes -- cannot see.)

*What the round taught.* `tools/mister.py feed` first passed its own options (`--bg`,
`--timeout`) to `h264play` (argparse's REMAINDER takes everything after the positional):
`h264play` printed its usage and the "test" measured nothing. Now h264play's options go
after `--` only.

*The final Phase 3 build* (P3d early output, P3f low latency, P3h; SEED 1, clk_dec 88.21 /
88.24 MHz, 26,112 ALM, `H264_p3ring_20260927_2129.rbf`, `264a38d`), on the rig the same day
(the rig idle on the menu before, restored after). A 352x240 clip (600 pictures, P only,
POC type 2) -- small enough that the decoder outruns the 59.94 raster, which low latency
needs to show its skips at all:

| run | shown | skipped | late | errors |
|---|---|---|---|---|
| paced by its VUI (the control) | 600 | 0 | 0 | 0 |
| `--ll`, the ring filled at once | 310 | 290 | 0 | 0 |
| `--ll --realtime --fps 60` (60.00 into 59.94) | 599 | 1 | 0 | 0 |

One skip in ten seconds at 60.00 frames/s is the 0.1 % rate difference; every run ENDED
with the last picture on screen. The film clip again: 240 / 240, late / starve / cadence 0.

*Seeking* (the same build and day; asked by the maintainer: "how will this handle pause /
seek?"). `p60.264 --switch switch.264 --at 500` leaves ~11 s of video queued in the ring
ahead of the switch: the DISCONTINUITY record, consumed in order, reset the stream
**11,211 ms** after `h264play` wrote it; `--flush` (`h264ring_flush()`: a new session, the
unread records dropped) did it in **14 ms**. Both ENDED, errors 0. So the manual's seek is a
new session, not a flag, and the planned pause became an out-of-band control word for
interface 0.2 rather than a record (`architecture.md` "Seeking, and why pause is not a
record").

## 4. High profile (P5a): a real Sunshine capture on the rig

*The first High fit* (`feature/p5-high`, `7b433c6`, 2026-09-28) closed clk_dec at only
75.25 / 74.63 MHz (target 86): three single-cycle cones added by this phase -- intra_pred's
Intra_8x8 tap-index analysis feeding the 33:1 tap mux (-1.05 ns), dequant_itrans8's
normAdjust ROM (inferred into an M10K, its output late) into the multiply and the rounding
shift (-0.97), the weighted 4x4 normAdjust lookup in the multiply's cycle (-0.29). Each got
one register (`890c13f`); the second fit closed first roll: SEED 1, **clk_dec 87.60 /
87.37 MHz, 27,318 ALM (65 %), 315 M10K, 75 DSP**, `H264_p5high_20260928_0459.rbf`. High
costs +1,206 ALM and +80 M10K on P3 (63 of them the scaling store at the spec maximum,
`high_profile.md` §3).

*On the rig* (the same day; idle on the menu before, restored after), `h264play` fed the
real Sunshine captures of `p1_measurements.md` §2b (stock Sunshine, NVENC, High with the
8x8 tools, 720x480p59.94, a filler NAL after every picture) through the ring, paced by the
VUI:

| capture | pictures decoded | macroblocks | errors / refusals | late | starved |
|---|---|---|---|---|---|
| 10 Mbit/s requested | 1,315 / 1,315 | 1,775,250 | 0 / 0 | 1,310 | 3 |
| 3 Mbit/s requested | 1,293 / 1,293 | 1,745,550 | 0 / 0 | 790 | 0 |

The picture clean on a screenshot. The 10 Mbit/s capture decoded at **60.8 pictures/s
(82,253 macroblocks/s)** over a 5 s window mid-stream -- the cosim's 986 cycles a
macroblock predicted 1.02x -- yet `disp_late` counts almost every picture: at ~1.0x the
decoder never wins back the lag of the stream's start (the IDR). These captures are ~52 %
skipped macroblocks (a desktop more than a game), so they flatter the decoder; the D1 gate
stays ≤ ~935 cycles a macroblock and real time from a live session (Phase 5b).

## 5. Throughput (P5b): the 96.43 MHz clock and the 81,000 macroblocks/s gate on the rig

*The build* (`feature/p5-throughput`, `183c339`, 2026-09-28): clk_dec moved from 81 to
96.43 MHz (VCO 1,350) after a retime campaign of eleven fits (87.37 → 80.22 → ... →
106.02 / 103.79; the playbook in `hw_budget_and_lessons.md` §5), plus the deblock bS
pre-pass, the residual engine's overlap and the streaming start (the interpolation
follows its window's fetch). Fit: SEED 1, clk_dec 104.69 / 101.46 MHz against the 101.4
gate, 27,560 ALM, 319 M10K, 74 DSP, `H264_p5tput_20260928_1717.rbf`. Cosim, `sun_high_8M`:
1,084 cycles a macroblock = 65.9 frames/s, 1.09x real time.

*On the rig* (idle on the menu before, no other session driving it, restored after), fed
through the ring by `h264play`, paced by each stream's VUI:

| stream | pictures | errors | late | starved | the decoder waiting on the display |
|---|---|---|---|---|---|
| `sun_high_8M` (NVENC High, 8 Mbit/s, the dense proxy; 59.94 frames/s), four loops | 300 / 300 each | 0 | 0 | 0 | ~3.5 % of the cycles |
| the real 10 Mbit/s Sunshine capture (60.000 frames/s) | 1,315 / 1,315 | 0 | 812 | 0 | ~26 % |

**720x480p60 is real time on the rig** -- D1's gate (81,000 macroblocks a second, the
maintainer's decision the same day): the dense proxy never late, never starved, the
decoder idle ~3.5 % waiting for a free store (so ~1.04x on the rig against the cosim's
1.09x: the 4-7 % the DDR model flatters it by, again). In P5a the same capture counted
1,310 late and 3 starved. **The capture's 812 late pickups are the frame rate, not the
decoder**: it declares exactly 60.000 frames/s (time_scale 120,000, num_units_in_tick
1,000) and the raster runs 59.94; the 0.1 % drift reaches half a refresh after 8.3 s =
picture ~500, exactly where `disp_late` began counting (0 at picture 328, 108 at 630).
The display does not skip outside low latency, so a 60.00 stream on the 59.94 raster
lags one picture every ~17 s whatever the decoder does -- a display question (a 60.00 Hz
raster variant, or low-latency skipping), not throughput. A screenshot mid-stream: the
picture clean (the host's 640x480 picture between the 40-pixel bars of its fitting).
The 5 MHz fit rule held at this clock on this run; no artifact seen.

## 6. Throughput part 2 (P5b): 854x480p60 real time on the rig

*The build* (`feature/p5-throughput-2`, `3ec031c`, 2026-09-28): part 1 plus two
interpolation lanes, the fetch run-ahead (requests into the next item), the writeback's row
setup overlapped with its data, and two retimes (the co-located product, the MMCO scan's z
stage). Fit: SEED 1, clk_dec 102.74 / 102.90 MHz (gate 101.4), 28,118 ALM (67 %), 328
M10K, 79 DSP, `H264_p5tput2_20260928_2148.rbf`. Cosim, `sun_high_8M`: 968 cycles a
macroblock = 73.8 frames/s, 1.22x.

*On the rig* (a MiSTer_DVD session had it; asked, lent, handed back restored with its
settings file and ini checked), through the ring by `h264play`, each stream's VUI pacing:

| stream | pictures | errors | late | starved | the decoder idle on the display |
|---|---|---|---|---|---|
| `sun_high_8M` (720x480p60, NVENC 8 Mbit/s), the last of three loops | 300 / 300 | 0 | 0 | 0 | 13.0 % (part 1: 3.5 %) |
| `sun854_high_5M` (854x480p60, 5 Mbit/s) | 300 / 300 | 0 | 0 | 0 | 7.1 % |
| `sun854_high_8M` (854x480p60, 8 Mbit/s) | 300 / 300 | 0 | 0 | 0 | 0.9 % |
| the real 10 Mbit/s Sunshine capture (720x480, 60.000 frames/s) | 1,315 / 1,315 | 0 | 812 (its 60.000 on the 59.94 raster) | 0 | 33.5 % |

**854x480p60 at 8 Mbit/s at the encoder (a ~10 Mbit/s request) is real time on the rig --
97,200 macroblocks a second -- with ~1 % to spare**; 5 Mbit/s with ~7 %; 720x480p60 with
~13 %. The cosim's own criterion for 97,200 (<= ~930 cycles a macroblock on `sun_high_8M`)
is not reached (968): the rig's margin on the 854 proxy is thin, and a denser 854 stream
could fall behind (visibly: `disp_late`). A screenshot of the 854x480 stream: the picture
clean, **its left 720 columns shown** (the right 134 cut) -- the display does not fit a
picture wider than the raster yet (the analog / display phase).

## 7. Analog (P6): the first 480i pictures on the rig (2026-09-29)

`H264_p6analog_MARGINAL_20260929_0228.rbf` (`c3c364b`: the 480i raster, csync, Video
Output, field selection; clk_dec 100.22 / 98.85 against the 101.4 gate -- above the 96.43
it runs at, so loaded for a look, not for a gate). The rig lent by a MiSTer_DVD session
(restored, the menu's Main back after one reboot), Video Output = Interlaced:

| stream | pictures | errors | late / starved / cadence | the screenshot |
|---|---|---|---|---|
| idle | -- | -- | -- | 720x480, the bars full width (CE_PIXEL halves the 1440 dots), the marker combed (it moves every field) |
| `p60.264` (720x480p59.94, synthetic) | 600 / 600 | 0 | 0 / 0 / 0; 600 pickups, the reader fetched 600 | full frame; moving edges comb in the scaler's Weave: each field from its own frame (60p -> 60i) |
| `film.264` (23.976, 3:2) | 240 / 240 | 0 | 0 / 0 / 0 | woven clean: a frame's two fields from one picture, full vertical detail |

*The instrument's limit, found here:* with HDMI Deinterlace = Bob (status bit 7 set, the
settings file checked) both `shot` and `shot --scaled` still comb -- the screenshot reads
the scaler's frame buffer, where the fields are stored woven; Bob is applied only when
ascal reads it out to HDMI. Bob, the analog pins (csync, the 15 kHz timing) and field order
on a real scaler are judged on the RetroTINK capture (the maintainer's, `analog.md` §4),
not by `tools/mister.py shot`.

*The analog pins, the same day* (the maintainer routed the MiSTer's RGBS -- MiSTer.ini
`vga_mode=rgb`, `composite_sync=1`, `vga_scaler=0` -- into a RetroTINK, its HDMI into a
capture card on the workstation; `docs/analog.md` §4). Video Output left on **Auto**:
the ini's analog settings resolved it to Interlaced. The RetroTINK's own measurement of
the signal: **1716x525i (1440x480), 26.9996 MHz, H 15.73 kHz, V 59.94 Hz, detected 480i**
-- locked to `csync_smpte`'s composite sync (the menu, before it: 1716x262p, 240p). The
idle bars and `p60.264` (600 / 600, errors / late 0) clean on the capture, the last
picture held after the end. **Field order, measured:** a clip of three one-line markers
(frame lines 100, 201, 300) captured 2.25 pixels a line: spacings 227.36 and 222.79
pixels = 101.0 and 99.0 lines -- with the fields swapped they would read 99 and 101 --
identical over 60 consecutive captured frames (no bob).

*HDMI Bob, the same day* (the MiSTer's own HDMI on the capture card, 1080p out of ascal),
`p60.264` at Video Output = Interlaced, the control arm first: **Weave** -- comb energy
(the mean of |2p(y) - p(y-1) - p(y+1)| over the frame) 2.18 / 2.52 / 3.06 (min / median /
max, 60 consecutive frames), the moving band's edges serrated line by line; **Bob** --
1.19 / 1.27 / 1.34, the ranges disjoint, the band a clean staircase of doubled lines. 600 /
600, errors / late 0 in both. HDMI Deinterlace reaches ascal (`HDMI_BOB_DEINT`).


## 8. Picture fitting (P6 step 3) on the rig (2026-09-29)

`H264_p6analog_20260929_0654.rbf` (`17862b2`: the fitting reader, `disp_fit`, Analog
Aspect, interface 0.2; clk_dec 105.92 / 104.23). Synthetic x264 High clips (testsrc2, 60
frames/s, 6 Mbit/s) through the ring; the status block's word 30 read with `h264stat`:

| clip | output | fit (word 30) | the scaler's picture | errors / late / fetch-late |
|---|---|---|---|---|
| 854x480 (coded 864, cropped) | Progressive | 720 x 480 (filled) | 1920 x 1079: 16:9 | 0 / 0 / 0 |
| 480x854 portrait | Progressive | 720 x 480 (filled) | **607 x 1080: 9:16** (ascal takes ARX < ARY) | 0 / 0 / 0 |
| 640x480 | Progressive | 720 x 480 | 1440 x 1080: 4:3 | 0 / 0 / 0 |
| 720x480 square pixels | Progressive | 720 x 480 | 1620 x 1080: its exact 3:2 (4:3 before) | 0 / 0 / 0 |
| 854x480 | 480i, Letterbox | 720 x 360, bars 60 lines | 4:3 | 0 / 0 / 0 |
| 480x854 | 480i, Letterbox | 304 x 480, centred | 4:3 | 0 / 0 / 0 |
| 640x480 | 480i, Letterbox | 720 x 480 (exactly 4:3) | 4:3 | 0 / 0 / 0 |
| 704x480 at 10:11 | 480i, Letterbox | 704 x 480, **snapped** 1:1 | 4:3 | 0 / 0 / 0 |
| 854x480 | 480i, Crop | 961 x 480, the sides cut | 4:3 | 0 / 0 / 0 |
| 854x480 | 480i, Fit | 720 x 480, stretched | 4:3 | 0 / 0 / 0 |

The screenshots show the raster (ascal's buffer): the letterbox's bars, the portrait's
pillarbox, Crop's cut sides and Fit's stretch as the model draws them. Two harness errors
on the way, not the core's: the ARM binaries deployed first were 0.1's (the library checks
the version exactly: "Protocol not supported"), and a round that fed the next clip 5 s into
a 10 s one was refused by the feeder lock (the previous clip's last picture stayed up).
This build's exact aspect let bit 12 through for products of 4,096 or more (sys_top's
explicit-size flag): the 10:11 clip was not played in Progressive on it; fixed in `63081ca`.

*The pre-merge build* (`H264_p6analog_20260929_1126.rbf`, `dd92b6d`: + Analog Aspect in both
modes, the 12-bit aspect; clk_dec 108.91 / 107.14; pll_hdmi -3.0 ns reported inside ascal).
Progressive + Letterbox on the RetroTINK: the portrait clip pillarboxed (~621 x 1080 of the
RetroTINK's frame, 9:16), HDMI told 4:3; Progressive + Auto: 9:16 / 16:9 to HDMI. The 10:11
clip presents as 4:3 exactly (7040 : 5280). **The real HDMI output captured** (the MiSTer's
HDMI into the capture card, 1080p60): three clips, 13 s each -- every frame clean across the
clip (timecode advancing a second a tile, the shapes exact, no displaced line, no garbage
block, no loss of signal), 600 / 600 pictures, errors / late / fetch-late 0. ascal's
reported slack (-2.1 / -2.3 / -3.0 ns over three placements) does not show on the output.

## 9. P6 part 2 on the rig: 60.00 Hz, 50 Hz / 576 lines, anti-twitter (2026-09-29)

Build `H264_p6part2_20260929_1355.rbf` (`00f305d`, SEED 1, clk_dec 105.30 / 103.06; its one
clk_mem violation, -0.356 ns on the anti-twitter flag's quasi-static crossing, was an
unbounded capture in `h264.sdc`, fixed for the refit -- functionally sound: the flag settles
a line before it is captured). The rig's `MiSTer.ini` makes Video Output's Auto Interlaced.
Clips: `tools/p6/make_clips.sh` and the 10 Mbit/s Sunshine capture.

**The instrument for the rate:** the status block's heartbeat (`seq_head`) advances every
refresh; counted over 60 s on the ARM's own clock (one shell on the target, two
`h264stat` reads), with the forced-59.94 arm as its control:

| clip | Refresh Rate | raster_std | refreshes / s (60 s) |
|---|---|---|---|
| p60x (VUI 1 / 120: 60.000) | Auto | 1 (60.00) | 3,603 / 60.058 s = 59.992 |
| p60x | 59.94 Hz (control) | 0 | 3,600 / 60.052 s = 59.948 |
| pal50 (VUI 1 / 100) | Auto | 2 (50) | 403 / 8.056 s = 50.02 |

**The benefit, low latency** (the Sunshine capture, `--ll --realtime --fps 60`, two loops:
each loop is a new stream and the counters restart): 60.00 Hz skipped 1 picture in 2,628 --
already at the second stream's 105th, the burst after a DISCONTINUITY -- and none in steady
play; 59.94 Hz skipped 4, of which 1-2 are start bursts (stream 1's single skip came before
its 455th picture: a start burst or a steady one, the samples cannot tell) and 2-3 steady
(one every 16.7 s expected: ~2.2 in ~36 s). So 0 against 1-2 or more in steady play: the
direction and the control arm carry it, not the exact count. Errors 0, late / starve 0.

**PAL:** pal50 at 576i: 720 x 576 snapped 1:1 (SAR 12:11), 49.9 pictures / s, pal25 24.9 / s,
the STC 89.8 kHz against the ARM, late / starve / cadence 0, one anchor a stream; 576p:
the screenshot 720 x 576, every line of the picture; HDMI 1472 x 1080 = 1.363, the stream's
exact 12:11 shape (720 x 12/11 : 576 = 1.364). A first PAL round read ~30 pictures / s
with re-anchors: `h264play --pts` stamps access units in decode order at its own `--fps`
(59.94) -- documented as invalid for reordered streams, and the PAL clips have B frames.
Paced by the VUI (no `--pts`) it is exact. A harness error, not the core.

**Anti-twitter** (the one-line grid clip, 480i, Off vs On, three shots each): the status
reports it applied (`anti_twitter` 1); the screenshots' one-line vertical detail (the mean
second difference down the picture) falls from 45-50 to 28-32. The screenshot is ascal's
woven buffer: the look on a 15 kHz display is the RetroTINK round's.

A DVD session took the rig for ~5 minutes mid-round (its harness had been told the rig was
free); the runs that overlapped it were voided and repeated, the ones before it stand.

*The clean refit* (`H264_p6part2_20260929_1501.rbf`, `c2aa76f`, clk_dec 105.45 / 106.13, no
negative slack on a core clock) on the rig: Progressive + Auto + p60x -> 60.00 Hz, not
interlaced, 720 x 480; 576i + pal50; 480i + anti-twitter on the grid clip (applied) -- errors,
late, starve, cadence and fetch-late 0 in each. The rate of the idle Progressive raster over
90 s: forced 60 Hz 5,403 / 90.045 s = **60.003 Hz**, forced 59.94 Hz 5,398 / 90.048 s =
**59.946 Hz**. (A 30 s window across a looping clip read 59.964: the heartbeat misses a write
or two at a stream restart -- it undercounts, never overcounts; measure a steady raster.)

*The analog pins* (the refit; RGBS -> RetroTINK -> capture card, as in §7; OBS had to release
the card first). Video Output = Interlaced, Analog Aspect = Fit (the clips shown 1:1):

- **The RetroTINK's own measurement** (its analyzer page): 60.00 Hz -- *1716x525i, V = 60.00
  Hz, detected CP 480i, stable rate, valid sync* (part 1 read 59.94 on the same page); its
  "H-Freq 15,743.44 Hz" is the mean of the two line lengths' rates (1,714 / 1,716 dots:
  15,752.6 / 15,734.3), so it samples single lines -- the vsync-based V is the rate. 50 Hz --
  *1728x625i, 26.9996 MHz, H 15,625.00 Hz, V 50.00 Hz, detected CP 576i, active lines 20-307
  (288), stable rate, valid sync*.
- **Field order** (`tools/p6/make_clips.sh` mark480 / mark576: one-line markers at frame
  lines 100, 201, 300; their spacing on the capture, consistent in every non-black frame):
  480i at 59.94 227.04 / 222.96 px = 101 / 99 lines (the control: part 1's numbers); 480i at
  60.00 the same; **576i 189.75 / 185.25 px = 101 / 99 lines at 1.875 px a line -- correct**
  (swapped fields read 99 / 101). `FIELD1_VPOS` holds for 625 lines as the RetroTINK reads
  BT.470's block. The picture stable through each capture: black only in the card's ~1 s
  warm-up and one frame at each loop restart (the screen goes black between streams).
- **Anti-twitter** (the still grid, Off / On, two captures each): through the pins a
  one-line grid line (196-199 on black) becomes 42 / 91-94 / 39-42 on three lines -- the
  (1, 2, 1), a quarter / a half / a quarter. The twitter itself is NOT visible on this chain
  either way: the RetroTINK weaves a still picture back to progressive (frame-to-frame
  change median 0.28 Off, 0.43 On; a handful of spikes a capture, at the loop restarts) --
  the metric is blind to flicker; a CRT is the instrument for that.

*On a CRT* (the maintainer, 2026-09-29: the MiSTer's S-Video out, MiSTer.ini
`vga_mode=svideo`, `composite_sync=1`; 480i at 59.94, Analog Aspect = Fit; the twitter set
`tools/p6/make_crt_clips.py`, Anti-Twitter flipped in the OSD while each clip played):
**"anti-twitter is very clearly demonstrated as an improvement in all these test cases,
controls were unaffected"** -- the line chart (1-line lines, alternating 1-on / 1-off; the
2-line control steady either way), the zone plate, the 1-line HUD text (its 2x half the
control) and the scrolling text. The first CRT result of the phase, and the one the
RetroTINK could not give (it weaves a still picture: §9 above).

**Open:** 576i on a PAL set (the 576-line clips exist). Main's reported rate was not read:
the heartbeat (60.003 / 59.946 Hz) and the RetroTINK's vsync-based reading (60.00) stand in.

## 10. Interface 0.4 on the rig: GRAPHICS and the settings request (2026-09-29)

`H264_graphics_20260929_1849.rbf` (`4cb395b`, SEED 1, clk_dec 102.59 / 104.00, 30,843 ALM), the
SuperStation rig (stock Main), `p60x.264`:

- **GRAPHICS / Anti-Twitter Auto** (Video Output Interlaced): an unflagged stream -- live flag
  bit 7 clear, anti-twitter not applied; `h264play --graphics` -- bit 7 set, applied; Anti-Twitter
  Off with `--graphics` -- not applied (the user's override); the mirror's `osd_anti_twitter`
  0 / 0 / 1; `gfx_mismatch` 0; errors 0.
- **The settings request:** from Progressive with every option on Auto, `h264play --osd
  refresh_rate=3,aspect=2` -- "settings request 1 sent"; within the poll the mirror read
  Aspect 2 (16:9) and Refresh 3 (50 Hz), `raster_std` 2 (the output switched to 50 Hz), `set_seq`
  1, `set_err` 0. The OSD opened (the live `OSD_OPEN`) and closed: the values held. **Not saved**
  by Main: `config/H264_v1.CFG` unchanged -- a program's settings last until the core reloads.

## 11. Audio (Phase 4, interface 0.5) on the rig (2026-09-29)

The original rig (the HDMI one wired to the workstation's capture card, which records the
picture AND the sound: a Hagibis UVC card, MJPEG 1080p60 + its ALSA device), stock Main, the
seed-7 builds `H264_p4audio_20260929_2149.rbf` (whose netlist is 62c299f's: see the pause below)
for the A/V runs and `H264_p4audio_20260929_2240.rbf` (086f174, a fresh synthesis) for the
pause's re-test; the audio path is the same in both. Clips `tools/p4/make_clips.sh`: `avsync.264` / `.pcm` (a one-frame
white flash each second, a 30 ms 1 kHz beep starting at the same instant, both from time 0),
`tone.pcm`. Fed with `h264play --pts --pcm ...` through the ring. The rig's Video Output Auto
made the raster 480i (its ini), HDMI through the scaler.

**The core's own account (the status block, every run):** all 1,500 AUDIO records of the 30 s
clip played, `aud_played` 1,440,000 (exactly 30 s at 48 kHz), `aud_gap` / `aud_late` 0, one
underrun (the audio's end), `aud_offset` 0-1 tick (the STC minus the last timed record's PTS
when its first frame played), the display's `lag_ms` 0, pictures 1,799 / 1,799, late 0.

**The capture (independent; flash onsets against beep onsets, all 29 pairs a run):**

| run (one recording, so the card's own skew is common) | audio minus video, median | s.d. |
|---|---|---|
| offset 0, 480i | -105.3 ms | 5.0 |
| `--pcm-offset 50`, 480i | -64.7 ms | 4.7 |
| offset 0, 480p (`--osd video_output=2`) | -98.4 ms | 5.0 |

- The **relative** control works: +50 ms of timestamps moved the capture +41 ms -- inside this
  instrument's error: a single recording's timeline wanders 10-20 ms over half a minute (the
  card's video and ALSA clocks), and separate recordings differ by ~20 ms (the first run read
  -84 ms at offset 0).
- The **absolute** ~-100 ms (the beep BEFORE the flash) is the chain after the core, not
  separable here: the MiSTer's scaler buffers the picture (480p ~7 ms less than 480i) and the
  capture card's MJPEG picture trails its audio; the core's counters put both at their times.
  **Open: calibrate the capture chain** (a known-synced source into the same card) before
  reading the absolute number as the MiSTer's HDMI A/V offset; if the scaler's latency turns
  out to be the bulk, a program can shift its audio with its timestamps.
- **The calibration attempt (same day):** the workstation's GPU into the same card, playing
  the clip (flash and beep muxed, aligned to 0.3 ms) with mpv. The card raises hot-plug only
  while something captures from it, and **declares no audio in its EDID** (no ELD on the GPU's
  HDMI port), so the GPU sent no sound: 29 flashes, silence. The MiSTer's HDMI sends audio
  regardless, which is why the card records it. Deferred (the maintainer): the relative
  result stands as Phase 4's A/V evidence; a source that ignores EDID calibrates the card later.

**Pause, volume, audio only, low latency (one recording):**
- `--pause 12,3000`: the audio stopped for exactly the pause (the longest beep spacing 4.00 s
  = 1 s + 3 s), every pair present after the resume, the STC frozen through it (722,326 read
  twice 1.5 s apart). **But `rc_err` counted the store alarm (code 6) ~7 a second while paused**
  -- UMD P6b3i's defect, whose `disp_frz` fix was ported in 8f5ec6a: the sweep that made this
  build re-ran only the fitter on the previous synthesis, so the fix was not in it (the
  manifest named HEAD). `seed_sweep.sh` now refuses a stale netlist. **Re-tested on the fresh
  synthesis (`..._2240.rbf`): `rc_err` 0 through a 4 s pause**, the STC frozen (722,383 read
  twice), `aud_played` and `disp_pick` held, and play resumed. (A first "re-test" still
  counted: `mister.py deploy` had replaced the file but left the previous bitstream running,
  and h264play does not reload a loaded core. `deploy` now reloads a running core.)
- `--atten 12`: the beeps on the capture **-6.00 dB** (peak 8,019 vs 16,001).
- `--audio-only --pcm tone.pcm`: `aud_anchor` 1 (the audio started the clock after its 1 s
  wait), 960,000 frames played (20 s exactly), no picture.
- `--ll --realtime --pcm-lead 20 --pcm-chunk 10`: `aud_ll` 1; 172 single-frame drops and 1
  repeat in 30 s (3.6 ms in all, ~120 ppm): either the loop trimming the margin to its 20 ms
  bound or the ARM's clock (h264play's `--realtime` pacing) running ~120 ppm fast of the
  FPGA's -- both inside the design's range; when the drops fell was not recorded, which would
  tell them apart. No gaps, no underruns but the end; on the capture -112 ms, the same chain.

## 12. The Moonlight client on the rig: the first live sessions (2026-09-29)

`feature/moonlight` (`docs/moonlight.md`), on the original DE10-Nano (.236, stock Main), the
core `H264_p4audio_20260929_2240.rbf` (the branch changes no RTL), the host this workstation's
Sunshine (Desktop app, 720x480@60, 10,000 kbit/s requested), the client
`clients/moonlight/build/moonlight` (static, 3.8 MB) with Phase 1's paired key directory
(no PIN). View-only (no input yet).

- **R1, no decoder** (`-platform fake`, 5 min): the client ~4 % of one Cortex-A9 core, 0 UDP
  receive errors in 344,400 datagrams (`moonlight.md` §3).
- **Through the ring** (`-platform mister`): the client loaded the core itself (the MGL path,
  `h264ring_launch_core`) and streamed. First run: Sunshine captured the host's other output
  (a 640x480 monitor showing a wallpaper; Sunshine has no `output_name` set, mpv went to the
  main one) -- still 4,763 access units, 0 dropped, 0 decoder errors, audio 15,790 records,
  0 underruns; 207 skips / 206 starved refreshes in ~80 s: a static desktop reaches the client
  unevenly. Second run, mpv moved to the captured output (`--fs-screen-name`), 3 minutes of
  moving 60 frames/s content, the raster at 480i: **10,503 access units (60.0 a second, 7.8
  Mbit/s), 0 dropped, 0 decoder errors, 0 IDRs asked; disp_skip 0, disp_late 0, disp_starve 0
  while playing** (240 after the stop: the 4 s before the last dump); audio 34,819 records, 0
  dropped, 2 underruns (start, stop), 4 single-sample repeats (the drift rule), queue ~26 ms;
  **the client 4.9 % of the ARM with Opus decoding** (~10 % of a core). The picture on the
  core's raster: the host's frame, fitted (screenshot by `mister.py shot`).
- **The launcher (R2 over ssh, the same evening, .236):** installed as `build/dist` lays it out.
  First run wrote the ini; with a fresh key directory it detected "must pair" and printed a PIN
  (stopped before pairing); with the paired keys `bash Scripts/moonlight.sh` returned at once, the
  client ran detached in its own session, loaded the core itself (MENU -> H264) and streamed
  (1,338 access units, 0 dropped, 0 decoder errors, audio 4,339 records); SIGINT (the same loop
  exit as the quit combo) -> `moonlight exited: 0` in the log and the menu core back (H264 ->
  MENU). Not run from the Scripts menu itself (screenshots cannot show the OSD): Main's source
  (`menu.cpp` MENU_SCRIPTS_FB) runs a script under `agetty` on tty2 and does not wait for its
  children; the client's `setsid nohup` puts it outside that session.
- **The OSD gating:** with the harness's uinput keyboard as the input, F12 -> the core's live
  flags 217 -> 249 (OSD_OPEN) and the client's log "The MiSTer menu is open: input paused";
  F12 again -> 217 and "input resumed". What the host receives is not yet observed (no
  instrument on the host side without typing into the maintainer's desktop).
- **Input, with the maintainer (Kate focused on the captured display):** a uinput keyboard on
  the MiSTer, the client open on it -- nothing reached the PC, not even the control arm (a key
  held 2.2 s, which the PC's autorepeat would have shown). **Main holds an exclusive
  `EVIOCGRAB` on every input device while a core runs** (a second grab: the Xbox One pad and
  the IR remote `EBUSY`; Main's `input.cpp`, `grabbed = 1`, released only with the Linux
  framebuffer console shown). Decided with the maintainer: input through the core (hps_io's
  pads, keyboard and mouse into the status block, interface 0.6, its own branch); this branch
  becomes view-only (`moonlight.md` M5, M6); patch 0004 dropped.
- **The size:** the first default (720x480, square pixels: 3:2) boxed a 640x480 desktop on all
  four sides (`fit_oh` 427). Sunshine reports no display modes (serverinfo over HTTP and HTTPS),
  so the automatic size follows the MiSTer's screen: on the rig (interlaced raster) the client
  asked 640x480 and the desktop filled the raster (`fit_ow`/`fit_oh` 720x480, no bars).
- **The way out:** `load_core menu.rbf` under a stream -- the unloaded core's words stayed, the
  session still looked open and every write timed out (the first try: the client ran on). Now
  the client watches the heartbeat: 891 access units, then the menu, then "the H264 core is no
  longer running" and a clean exit. (One session before it was refused by Sunshine, "Couldn't
  find monitor [0]": transient, the next streamed.)
- **The shipped build, from the Scripts menu, by the maintainer (2026-09-30, .201, the
  SuperStation):** `H264_moonlight_20260930_0247.rbf` (sha `a1ca2810...`, the ledgered fit):
  Scripts -> moonlight -> the script's window, the core loaded, the PC's display shown at the
  screen's shape (640x480 asked); the About line `H264 dev-moonlight 260930`; another core loaded
  from the menu -> the stream ended. The client's log: 3,288 access units, 0 dropped, 0 decoder
  errors, audio 10,777 records (1 dropped), "the H264 core is no longer running", exit 0.
  **R2 through Main's own script runner confirmed.**
- Not yet: a long session, the RetroTINK / CRT at 480i with Anti-Twitter Auto.

## 13. Input through the core (interface 0.6) on the rig: keys and the mouse, scripted (2026-09-30)

`H264_mlinput_20260930_0429.rbf` (SEED 7 first roll, clk_dec 104.07 / 104.08, ALM 32,528 --
78 %, +792 for the input region; RTL `f328edb`) on .201 (the SuperStation), stock Main, no PC
stream: `h264stat --input --watch 0.02` on the target while a uinput device played input to
Main (so through Main's grab, hps_io and the core -- the path a user's devices take).

- **Keys** (`tools/mister_uinput_keys.py`: A; Shift+A; B held; F12; C inside the menu; F12; B
  released): the region's events, exactly as designed -- `1C down, 1C up, 12 down, 1C down,
  1C up, 12 up, 32 down, OSD opened, OSD closed, 32 up`. F12 never reached the core; C, pressed
  while the menu was open, neither; B, held across the menu, arrived as its release after the
  close (the client's held-key set handles it). `in_head` 458 about 7.6 s after the load: the
  frame heartbeat. `ev_lost` 0.
- **The mouse** (a scripted uinput mouse: ten moves of REL_X +10 / REL_Y +20, one wheel notch
  up, L, L+R, R, none): `dx_sum` 100, `dy_sum` -200, `wheel_sum` -1, the buttons as four events
  `0x01, 0x03, 0x02, 0x00`. **The sign conventions the client was written against are Main's:**
  Y up-positive (a move down is negative), the wheel counting towards the user (a notch up is
  -1); the client negates both for the host.
- **With the maintainer at the rig (2026-09-30; a keyboard, a Logitech / Nordic 2.4G mouse and an
  Xbox controller on .201), `h264stat --input --watch` on the target (it now prints pad and mouse
  changes too):** every pad button in its bit -- A 0x10, B 0x20, X 0x40, Y 0x80, LB, RB, Back,
  Start, LS, RS, LT, RT 0x1000-0x8000; the d-pad up 0x08, down 0x04, left 0x02, right 0x01. **Main
  mapped all sixteen by itself** (this Xbox pad: LS / RS / LT / RT included, no "Define H264
  buttons"), the face buttons by position (X / Y not swapped). The sticks: up -127 (Y
  down-positive, as Linux reports), right +127, both sticks. Keys: `hello` and Shift+A in order;
  F12 -> OSD opened / closed. The mouse: a wireless mouse asleep swallowed the first moves (its
  wake-up), then 20 s of movement summed dx +16,502, dy -5,028 (right, down: Y up-positive); the
  wheel one notch up = -1, down = +1. **`/dev/input/mouse1`/`mouse2` read directly beside Main
  delivered NOTHING under the grab** (0 packets while the core summed the moves): the research's
  "the kernel keeps mouse handles fed" (`moonlight.md` §7) does not hold on this rig.
- **Streaming to the PC** (the new client from `build/dist`, a key directory copied and removed
  after, Sunshine's Desktop at 640x480, Kate on the captured display, read back with `mister.py
  shot`): `Hello, MiSTer!` typed exactly (Shift, punctuation); `x` held 2 s -> a row of the PC's
  own repeats; `z` held, then F12 -> the z's stopped (the release on the OSD's opening; the log
  "input paused" / "input resumed"); a double-click selected `Hello`, a right-click opened Kate's
  context menu; a browser gamepad tester saw "045e-0b13-Sunshine" (an Xbox pad, standard
  mapping) with A, RB, LT (1.00), d-pad up and the left stick's axis 1 at -0.99997 (up) held
  together; **both quit combos** (Start+Back+LB+RB; Ctrl+Alt+Shift+Q) ended the stream back to
  the menu. The last session: 344 access units, 0 decoder errors, 0 lost events. **Input through
  the core HW-CONFIRMED** on `H264_mlinput_20260930_0429.rbf`.

## 14. UMD's lone-PTS rules on the rig: a playback smoke test (2026-09-30)

`H264_lonepts_20260930_1453.rbf` (SEED 7 first roll, clk_dec 105.49 / 106.0, ALM 32,523; RTL as
`4411e25`, the manifest's sha `1024e47`) on .201 between the DVD session's bisect arms, `h264play`
through the ring (`tools/p3/make_clips.sh`'s synthetic clips): the status block reads version 7;
**film** (3:2, 240 access units) ENDED, 240 pictures, errors 0, `disp_lone` 0, one anchor, late /
cadence / starve 0, 240 pickups; **sun** (Sunshine-shaped 60p, 600) ENDED, 600 pictures, errors 0,
`disp_lone` 0, one anchor, late 0. The rule leaves clean streams alone on the hardware; its cases
(a lone tag ahead or behind, the believed next tag, a real jump) are the bench's
(`run_disp_sched.sh`, `display.md` §10) -- no stream this core has met carries a lone PTS.
(Main at the time was the DVD session's HIL Main, left running across the core load; the
decoder's and display's counters do not depend on it.)

## 15. The OSD's actions (interface 0.8) on the rig: scripted through Main (2026-09-30)

`H264_padhome_20260930_1641.rbf` (SEED 7 first roll, clk_dec 109.59 / 108.46, ALM 32,527; sha
`9d80689`) on .201 after the DVD session released it: the status block reads version 8. A uinput
keyboard on the target (`tools/mister_uinput_keys.py`: F12, Down, Enter) drove Main's menu while
`h264stat --input --watch 0.02` read the input region:

- **Send Home to the program:** `event 1: OSD action 0`, `event 2: OSD closed`, `event 3: key 5A
  up` -- the action queued BEFORE the OSD's closing, as `architecture.md` "The OSD's actions
  (0.8)" says Main's order makes it; then Enter's release, which reaches the core with no press
  (the client drops it: a key not held).
- **Program menu:** `event 5: OSD action 1`, `event 6: OSD closed`, `event 7: key 5A up`.
- `ev_lost` 0; no event repeated (Main's pulse cleared the bit; the edge queued once); the session
  state untouched (NO_SESSION throughout: neither entry is Reset).

Learned about Main's menu, for the next scripted round: the cursor starts at the top on every
opening; the items shown follow the menumask (the rig's ini makes Video Output Auto resolve to
Interlaced, which shows HDMI Deinterlace and Anti-Twitter in place of Deinterlace), so Send Home
was 6 Downs from the top, not 5 -- two Enters on the wrong line changed Analog Aspect and Refresh
Rate, read back from word 27's mirror (the OSD itself is not in a screenshot) and put back by
`restore`. (Main at the time was again the DVD session's HIL Main left running; the input region
does not depend on it.)

**✅ HW-CONFIRMED with the maintainer (2026-09-30, on .236 at their request, stock Main):** the same
build and the rebuilt client (`clients/moonlight/build/dist` + the paired keys, removed after),
streaming this workstation's desktop through Sunshine, a real pad. The maintainer watched the PC's
primary monitor while the MiSTer streamed the captured one (Steam's Big Picture would not open on the
captured HDMI-A-1 output: Steam opens it on the primary display -- a KWin rule or `kscreen-doctor
output.HDMI-A-1.priority.1` for a later round). Every step reached the PC: the OSD's **Send Home**
opened the host's Guide (three times), **Back + Start held** did too (twice), **Program menu** did
nothing on the PC, **Start + Back + LB + RB** ended the stream. The client's log: `Guide sent to the
host (the MiSTer menu's Send Home)` x3, `(Back + Start held)` x2, `The MiSTer menu's Program menu:
this client has no menu yet`, `Quit combo: the stream ends`; 19,601 access units, 0 decoder errors,
0 IDRs asked, one session; input: 6 OSD openings, 4 OSD actions, 5 Guides, 1 pad announced, 0 lost.

## 16. clk_dec at 103.85 MHz on the rig: decoder headroom (2026-09-30)

`H264_clkup_20260930_2013.rbf` (`feature/clk-dec-up` `e125f75`, SEED 9 from a sweep, clk_dec
111.77 / 110.41 at the 108.8 gate; `throughput.md` §7) on .201 (idle on the menu before,
restored after), fed through the ring by `h264play` -- the same streams as §6, each stream's
VUI pacing, `rc_stall` (the reconstruction waiting for a free store: the display holding it)
read from the status block after each run:

| stream | pictures | errors | late | starved | the decoder idle, 96.43 MHz (§6) | at 103.85 MHz |
|---|---|---|---|---|---|---|
| `sun854_high_8M` (854x480p60, 8 Mbit/s at the encoder, a ~10 Mbit/s request), twice | 300 / 300 | 0 | 0 | 0 | 0.9 % | **5.9 %, 5.9 %** |
| `sun854_high_5M` | 300 / 300 | 0 | 0 | 0 | 7.1 % | 11.6 % |
| `sun_high_8M` (720x480p60), twice | 300 / 300 | 0 | 0 | 0 | 13.0 % | 17.7 %, 17.6 % |

**D1's hardest case goes from ~1 % to ~6 % to spare** (~1.06x real time); every stream gains
~4.6-5 points, a little under the clock's +7.7 % because the reference fetch is DDR3-latency
bound and clk_mem stays at 90 MHz (§5, "the clock, measured"). The status block read version 8
(the pad-home interface); `dev-clkup`.

## 17. The overlay plane (interface 0.9) on the rig (2026-09-30)

`feature/p6b-overlay`: `H264_p6bovl_MARGINAL_20261001_0002.rbf` (SEED 9 inherited, clk_dec 0.15 ns
short at -40 C, the overlay's own clocks clean) for the first round, then the swept
`H264_p6bovl_20261001_0013.rbf` (SEED 7, clk_dec 110.74 / 110.25, `5cecf6f`) for the confirmation;
the SuperStation (.201) with stock Main (rebooted out of a leftover DVD HIL Main, with the DVD
session's go), its output 480i (the ini's analog Auto), `h264play` + `libh264ring` 0.9 built for
the ARM.

- **The framebuffer, measured first** (`architecture.md` "The overlay plane"): `smem_start`
  `0x2200_1000`, 8,294,400 bytes, 8888 = bytes B, G, R, X. **fbcon writes it on its own**: a
  pattern over the whole region lost 16 lines of one text cell within 2 s (tty1's `agetty`, the
  blinking cursor); with the blink off and the cursor hidden, nothing in 30 s -- so
  `h264ring_fb_map` quiets the cursor and `h264ring_fb_unmap` restores it.
- **Composited, every format:** `h264play --overlay 1555 / 4444 / 8888` over `sun854_high_8M`
  (D1's densest): the bar where it was drawn (lines 420-443, x 60-659) in raster screenshots,
  4444's translucent remainder exactly the formula's (colour 17 at alpha 170 over black: 11), the
  frame's edges softened by the 480i filter; 27 flips over three loops with `ovl_torn` 0 and
  `ovl_late` 0; 21,744 canvas lines for ~906 fields of a 24-line band (each line once a field);
  the bar gone after `h264play`'s hide (0 of 14,400 band pixels). A session with no overlay
  shows the library's descriptor-off write (generation 1, state off).
- **Measurement 3, the cost at 103.85 MHz** (`architecture.md`, the decoder's spare time as §16):
  480i off 5.89 / 5.88 %, full 1555 5.63 %, full 8888 4.96 %; 480p off 5.73 / 5.71 %, full 8888
  4.52 %; the swept build: off 5.87 %, each format's band 5.87-5.89 %, full 8888 4.96 %. Every run
  300 / 300 pictures, errors / late / skipped / starved 0. **A full 8888 canvas fits D1's densest
  case.**

**Found after this round, fixed before any merge** (2026-09-30): a narrow filtered arm added to
`run_ovl_plane.sh` (inarrow) showed the line ABOVE a centred, filtered canvas fetching the wrong
memory -- its canvas line c is -1, and the address of c + 1 (line 0) was derived from c's low 10
bits (line 1024's). The round's builds carried it; the bar (a 720 x 480 canvas, oy 0) never met it.
The fix (a signed product) is in the refit that follows.

**The fix on the rig** (`H264_p6bovl_MARGINAL_20261001_0054.rbf`, `bf951cf`, SEED 7 re-rolled to
105.81 / 104.0 -- under the 108.8 gate, positive at the 103.85 MHz clock; the sweep stopped at the
maintainer's word to test it as is): `h264play --overlay 1555 --overlay-size 720,400` (a canvas
centred at oy 40, its line 0 an opaque white rule) at 480i with the filter -- raster line 39 (the
line above the canvas, the bug's path) 64 on all 720 pixels, line 40 128, line 41 64: exactly
(0 + 0 + 255 + 2) >> 2 and (2 x 255 + 2) >> 2. The format suite again: off 5.88 %, 1555 / 4444 / 8888
bands 5.87-5.89 %, full 8888 4.96 %, a centred 500x300 4444 canvas 5.69 %; every run 300 / 300
pictures, errors / late / skipped / starved 0, `ovl_late` 0, `ovl_torn` 0.

Not covered here (the maintainer's chain): the RetroTINK at 480i field by field and a CRT; HDMI
through a capture (the screenshots are the core's own raster).

## 18. The macroblock pipeline on the rig (feature/mb-pipeline, 2026-10-01)

*The build* (`feature/mb-pipeline` `16923d6`, rebased on main `e1b59de` = + the overlay;
`docs/mb_pipeline.md`): the streamed writeback, `dpb_mem`'s write skid, two front stages, the
emission queue, the back engine split, `dequant_itrans`'s two work buffers, and the fixes of fj#18
(9-bit weights) and fj#19 (`wr_drained`). SEED 5 from a sweep, clk_dec 109.06 / 108.18 (the cold
corner 0.6 MHz under the 108.8 gate, +4.3 MHz over the 103.85 clock), 34,943 ALM (83 %), 378 RAM,
103 DSP, `H264_mbpipe_MARGINAL_20261001_0620.rbf`. On .201 (idle on the menu before, restored
after), fed by `h264play`, each stream's VUI pacing, the decoder's spare time as §16
(`rc_stall` over the play time's clk_dec cycles); the control arm is main's merged build
(`H264_p6bovl_MARGINAL_20261001_0054.rbf`, `bf951cf`) loaded in the same session:

| stream | pictures | errors / late / skipped / starved | main idle | pipeline idle | real time, main -> pipeline |
|---|---|---|---|---|---|
| `sun854_high_8M` (854x480p60, D1's densest) | 300 / 300 | 0 | 5.9 % (§16), **5.88 %** re-run | **33.6 %** | 1.06x -> **1.51x** |
| `sun854_high_5M` | 300 / 300 | 0 | 11.6 % (§16) | 38.8 % | 1.13x -> 1.63x |
| `sun_high_8M` (720x480p60) | 300 / 300 | 0 | 17.7 % (§16) | 40.6 % | 1.22x -> 1.68x |
| `x264med480_4M` (x264 medium, B-frames, `weightp=2`, 720x480p60) | 120 / 120 | 0 | **3.2 %** | 25.5 % | 1.03x -> 1.34x |
| `sun854_high_8M` + a full 8888 overlay canvas (`--overlay 8888 --overlay-band 0,479`) | 300 / 300 | 0, `ovl_late` / `ovl_torn` 0 | 4.96 % (§17) | 32.4 % | |

**The decoder's busy time falls by ~1.4x on every Sunshine stream** (0.94 -> 0.66 of the
picture time at 854x480p60): the cosim's 985 -> 711 cycles a macroblock (1.39x) holds on the rig.
The rig runs ~6 % under the cosim's model on the NVENC streams (`sun_high_8M`: 1.79x predicted,
1.68x measured), ~16 % under on the x264 B-frame stream (803 cycles a macroblock predicted 1.60x;
1.34x measured; main the same way, 1.16x predicted, 1.03x measured): bi-prediction's reference
fetch is DDR3-latency bound (clk_mem 90 MHz), which the cosim's model under-counts. The overlay's
full canvas costs the pipeline 1.2 points, as on main (0.9). Main's 3.2 % on the x264 stream is
also wrong chroma (fj#18, uncounted: the stream's denom-7 slice); the pipeline carries the fix.

## 19. The macroblock pipeline at 96.43 MHz on the rig (feature/mb-pipeline, 2026-10-01)

At 103.85 MHz no seed of eleven closed the 108.8 gate on the pipeline's netlist (83 % ALM;
`docs/mb_pipeline.md` §6), so clk_dec went back to 96.43 (VCO 1,350 / 14, gate 101.4; the
maintainer's call on the recommendation): the pipeline alone gives D1 several times the
margin the faster clock did. The build: `fcbd409`, SEED 6 from a sweep (seeds 1 and 3 just
under), clk_dec **105.71 / 103.22 -- PASS**, 35,112 ALM (84 %), 378 RAM, 103 DSP,
`H264_mbpipe_20261001_1223.rbf`. On .201 (lent to the UMD session for its B4 gates first,
handed back restored and rebooted; restored after), the method of §16 at 96.43 MHz:

| stream | pictures | errors / late / skipped / starved | idle | real time | (at 103.85, §18) | main at 103.85 |
|---|---|---|---|---|---|---|
| `sun854_high_8M` (D1's densest) | 300 / 300 | 0 | 30.2 % | **1.43x** | 1.51x | 1.06x |
| `sun854_high_5M` | 300 / 300 | 0 | 35.8 % | 1.56x | 1.63x | 1.13x |
| `sun_high_8M` (720x480p60) | 300 / 300 | 0 | 37.5 % | 1.60x | 1.68x | 1.22x |
| `x264med480_4M` (x264 medium, B-frames) | 120 / 120 | 0 | 22.2 % | 1.29x | 1.34x | 1.03x |
| `sun854_high_8M` + a full 8888 overlay canvas | 300 / 300 | 0, `ovl_late` / `ovl_torn` 0 | 29.3 % | 1.41x | | |

The clock's 7 % costs ~5 % of throughput (the reference fetch is DDR3-latency bound at
clk_mem's 90 MHz, which does not move): **D1's hardest case keeps ~40 % to spare** at a
gate nearly every seed clears.

## 20. The overlay plane on the analog chain, a CRT and an HDMI capture (2026-10-01)

The checks §17 left to the maintainer's chain, which make Phase 6b ✅ HW-CONFIRMED. The original
DE10-Nano (.236, held from the DVD / UMD sessions for the round, restored and released after),
`H264_mbpipe_20261001_1223.rbf` (main's build: `fcbd409`, SEED 6, clk_dec 96.43 MHz), `h264play`
rebuilt from main `693c003`, over `sun854_high_8M` (D1's densest) looping. The fixture for the
filter: `--overlay 1555 --overlay-size 720,400`, a canvas centred at oy 40 whose line 0 is an
opaque white rule (§17's), over the letterbox's black -- a one-line feature on black, the worst
case for twitter.

**The RetroTINK** (RGBS, composite sync; its analyzer page through the Hagibis at 1920x1080;
the RetroTINK scales a 480-line raster ~2.25x and weaves the fields, so it shows the filter's
shape, not twitter):

- **Sync with the overlay up:** 1716x525i, 15.73 kHz, 59.94 Hz, stable, valid; at Refresh Rate
  50 Hz 1728x625i, 15.625 kHz, 50.000 Hz, and the 400-line canvas centred on 576i (the rule at
  line ~88 = (576 - 400) / 2).
- **The (1, 2, 1) through the pins** (the rule's capture rows, mean luma over 70 columns):
  Anti-Twitter **Off** 44 202 184 6 -- one line; **Auto** 16 38 56 86 84 43 40 -- three raster
  lines, the outer two about half the centre (64 / 128 / 64 in the raster, §17).
- **The formats over video:** 4444 and 8888 bars with clean edges, no combing, steady between
  fields; 4444's translucent remainder shows the picture through it (Analog Aspect Crop puts the
  picture behind the bar: at Auto a 16:9 stream's bar sits in the letterbox). Status: errors 0,
  `ovl_torn` 0, `ovl_late` 0, `ovl_at` 1 with `anti_twitter` 0 (the video is not graphics; the
  overlay is filtered regardless: `architecture.md`).

**A CRT over S-Video, 480i** (the maintainer's eyes; Anti-Twitter changed live in the OSD): **On
and Auto show a steady line, Off makes it flicker.**

**HDMI through the capture** (.236's HDMI straight into the Hagibis):

- **480i, HDMI Deinterlace Bob:** the rule, the picture and the bar where the RetroTINK showed
  them. Consecutive frames alternate fields: **Auto** one field shows two lines at ~63 (255 / 4),
  the next one line at ~137 (128) -- per-field sums 574 / 552, equal brightness, so Bob shows no
  30 Hz blink; **Off** one field 255, the next 0 -- the rule blinks on HDMI too.
- **480p** (Main's banner: 720x480 31.48 kHz -> 1920x1080 60 Hz): the rule one sharp line
  (`ovl_at` 0: progressive is not filtered); with Aspect Auto the 4:3-drawn canvas stretches with
  the 16:9 stream (the bar x 162-1758, against 360-1560 at 480i's 4:3) -- the cost decided with the
  mapping (`architecture.md`: the program redraws for word 47).
- A capture frame that looked wrong (all white but the bar) is the clip's own: `sun854_high_8M` has
  5 near-white pictures a loop (mean luma > 200), and the capture's white frames recur at the
  loop's period.

## 21. The Jellyfin client on the rig (feature/jellyfin, 2026-10-01)

.201 (main's SEED 6 bitstream: the branch changes no RTL), the client run from `/tmp/jf`, the
maintainer's Jellyfin 10.11.11 with QSV and a non-admin test account. Details and numbers:
`jellyfin.md` §5 (R1-R3) and §10.

- **Scripted** (the server's session API as the phone app drives it): Quick Connect (the code
  approved through the API), a remote-controllable session; a QSV transcode cast from 10:00 (576i
  from its 25 frames/s), paused, sought, stopped; an MKV direct play with its SRT on the overlay; the
  reported position from the STC (21.1 s over 21 s); errors / late / skipped / starved 0. Found and
  fixed on the way: a static glibc's lookups crashing in curl's resolver thread (F7), the overlay's
  flip stalling after a session start (F6, a library fix), FFmpeg's info log carrying the token.
- **The maintainer's first round:** casting, pause, stop fine; the pad hit and miss (holding did
  nothing; taps lost while the loop sent a report or restarted a stream) and the subtitle button
  restarting a transcode (~7 s of black). Fixed: held buttons repeat, seek steps add up into one,
  reports on their own thread, text subtitles switched without a restart.
- **Seeking** ("it cuts to black for a second or two"): the old picture now holds (the core paused)
  until the new stream's first IDR is ready, and a transcode opens a trimmed playlist (one encoder
  start): first IDR 5.8 -> 3.7 s on a transcode seek, 2.6 -> 2.2 s on a direct-play start; on the
  rig 0.7 s into a seek the old frame, "Loading" and the target.
- **The maintainer's second round:** taps add up (five Right taps one seek, 16.5 -> 164.9 s), B / Y /
  X / A / Back+Start as mapped (logged). A one-off freeze after B B Y Y X on the earlier build (three
  back-to-back seeks no logged button made) did not recur; the client now logs every action and
  server command. The overlay on a 2.39:1 film in Progressive drawn for the displayed aspect;
  word 47's aspect reads 0 on the hardware (F8, to fix with A').
- Not exercised: 480i on a CRT with this client; Quick Connect off (user= / password=); an
  interlaced source.

## 22. A' and interface 0.10 on the rig (feature/hdmi-raster stage 1, 2026-10-01)

`H264_hdmi-raster_20261001_2310.rbf` (SEED 6 first roll, clk_dec 107.83 / 106.16 at the 101.4 gate,
35,483 ALM, `3c6cfdc`), `h264play` / `h264stat` built for 0.10, on .201 (HDMI 1920x1080), Video
Output Progressive, Aspect Ratio and Analog Aspect Auto (`docs/hdmi_raster.md` §12):

| clip | word 47 | word 80 | fit | `shot --scaled` |
|---|---|---|---|---|
| 852x356 SAR 640:639 (synthetic scope, 24 frames/s: Refresh Rate Auto -> 60.00 Hz) | 1920 : 1080 | 720x480, `raster_lb` 1, (0, 62) | 720x356 | 1920x1080; the picture rows 140-940 (1920x801, 2.397 -- exact 2.397), black bars above and below |
| 854x480 SAR 8100:8113 (a hair under 16:9; Refresh Rate Auto -> 59.94 Hz) | 3377 : 1901 | `raster_lb` 0 | 720x480 | 1918x1080 (fill + the exact aspect, as before) |
| 640x480 square (30 frames/s -> 60.00 Hz) | 640 : 480 | `raster_lb` 0 | 720x480 | 1440x1080 |

With `--overlay 8888` over the scope clip the progress bar lights rows 946-999 of the HDMI picture:
inside the lower bar, which before A' was ascal's and out of a program's reach. Decode errors 0 on
every clip. F8's word 47 read raw (`devmem`) matches `h264stat`. Not yet: the Jellyfin client's
subtitles in the bars with the maintainer, a CRT round (A' does not change the 480i raster).

## 23. F8 on the rig: found with the maintainer, fixed (feature/hdmi-raster, 2026-10-02)

In the maintainer's Jellyfin round on `H264_hdmi-raster_20261001_2310.rbf`, the status block at the
client's ready screen after a stop read word 47 = `0x00000000` (state READY): the exact aspect was
computed from the per-stream reset's 0x0 picture (`hdmi_raster.md` §7). The fix (`fb27e4c`, ar_x /
ar_y held while no picture is shown) built as `H264_hdmi-raster_20261002_0004.rbf` (SEED 6, 104.67 /
105.99). Same sequence on each build -- a clip played to its end in Progressive, then the Jellyfin
client started (a new session, no picture):

| build | at the ready screen after | word 47 |
|---|---|---|
| `..._20261001_2310` (control, the maintainer's session) | a film, stopped | `0x00000000` -- 0 : 0 (HDMI's fill) |
| `..._20261002_0004` (the fix) | the 640x480 clip | `0x001E0280` -- 640 : 480 held |
| `..._20261002_0004` | the scope clip (A': 1920 : 1080 while it played) | `0x00438780` -- 1920 : 1080 held |

Word 80 at the ready screen reads the reset fit (720x480 at 0, 0, `raster_lb` 0): no picture is
shown, so no rectangle; the shape a program draws for is word 47's, which now holds. (A first
attempt read the old core's stale status words: `h264play` timed out loading the core from the
menu -- the readings are from after a confirmed load, CORENAME H264, the 4:3 clip ENDED.)
The Jellyfin client's two bugs from the same round (the freeze on a subtitle / audio switch; no
subtitles after a switch: the server rebases the cues to the URL's start time) were fixed by the
file-player session on `feature/file-player` (`15b4fab`), not here.

## 24. The native raster on the rig (feature/hdmi-raster stage 2, 2026-10-02)

`H264_hdmi-raster_20261002_0245.rbf` (SEED 6 first roll, clk_dec 106.0 / 104.73 at 101.4, 35,896 ALM,
`9c46b4d`), .201 on a 1920x1080 HDMI mode, `h264play --osd video_output=3` (Native (HDMI)):

| clip | word 80 / `shot` (the raw raster) | word 47 / `shot --scaled` |
|---|---|---|
| 852x356 SAR 640:639 (scope, 24 frames/s -> 60.00 Hz) | 852x480 native, letterboxed (`pic_y0` 62) | 1920 : 1080 -> 1920x1080 |
| 640x480 square (30 -> 60.00 Hz) | 853x480 native, pillarboxed (`pic_x0` 106) | 1920 : 1080 -> 1920x1080 |
| 854x480 SAR 8100:8113 (59.94) | 855x480 native (a hair under 16:9: pillarboxed by 1) | 1920 : 1080 -> 1920x1080 |
| 720x576 SAR 16:15 (25 -> 50 Hz) | 720x576 native, picture-sized (display-shaped would be 960) | 2,880 : 2,160 (4:3) -> 1440x1080 |

Decode errors 0, `disp_fetch_late` 0 on all. **A size change mid-session** (`--switch` with a flush,
scope -> 640x480): word 80 went 852x480 -> 853x480 directly (sampled every 0.1 s: never the 720
raster between) and **held** the native raster after the stream ended. **The overlay** (`--overlay
8888`) on the native 852x480 raster: accepted, `ovl_late` 0, the bar centred on the HDMI picture
(columns 284-1636 around 960) in the lower bar.

**Found: the settings request across programs** (an interface 0.4 bug, not stage 2's): the library
numbered every program's requests from 1, and a new session applies word 35 once -- so a program's
request repeated the previous program's sequence number (ignored) and its session re-applied the
PREVIOUS program's request: each `h264play` run showed the settings the run before had asked for.
Fixed in `hps/lib/h264ring.c` (a session writes this program's own request or 0; the numbering
continues from word 30's `set_seq`); `test_ring.c` + two red arms; on the rig alternating Progressive /
Native between programs now applies at once (set_seq 2, 3, 4). Not yet: what Main reports as the
core's resolution with the odd blank line; `video_info`'s box and whether HDMI blanks at a size change
(neither is visible in `shot`); the maintainer's round with a client in Native.

**With the maintainer (2026-10-02, .201, the Jellyfin client, Video Output Native (HDMI)):** it works;
a film "looks good in this mode"; a change of picture size between items is a small blip on HDMI and
Main's resolution box shows the new size (`video_info=2`; `vsync_adjust=0` -- no mode change) --
as §2 of `hdmi_raster.md` predicted. Stage 2 ✅ HW-CONFIRMED.

## 25. The CAVLC rewrite's cost on the A9, and rewritten streams through the core (feature/cavlc, 2026-10-01)

.201 (main's SEED 6 bitstream `H264_mbpipe_20261001_1223.rbf`: the branch changes no RTL), the
rig shared with the hdmi-raster and file-player sessions in turns. Details and the tables:
`cavlc.md` §5.

- **The rewrite alone** (`cavlc2cabac --bench`, 10 s of x264 ultrafast High CAVLC at 720x480p59.94):
  49 % of one A9 core at 3.16 Mbit/s, 87 % at 6.33, 106 % at 7.92, 166 % at 12.87; Constrained
  Baseline at 2.12 Mbit/s 39 %. ~109 ns a bin + ~1.1 us a macroblock; the A9 measured at ~800 MHz
  by a calibration loop. **Issue fj#20's gate (8 Mbit/s beside a client) does not pass.**
- **Through the core** (`h264play --realtime`, the rewrite on every access unit): 3.16 Mbit/s 600 /
  600 pictures, errors 0, late 0, the longest unit 21.5 ms; 2.12 Mbit/s late 0; 6.33 Mbit/s 517
  late (the rewrite cannot keep up). A control (rewritten beforehand on the host): late 0. Main
  holds a full core (menu or core loaded); the feeder with the rewrite 42-56 % of the other.
- **Found on the rig:** the ARM binary's output differed from the host's -- C's unspecified
  argument evaluation order (`bw_put(w, br_u(r, n), to - r->pos)`; ARM's gcc dropped each slice
  header's tail); fixed, and the two outputs then identical (`CLAUDE.md` "Lessons"). And
  `h264play` rewrote a unit after waiting for its due time (421 late at 3.16 Mbit/s); it now
  rewrites first.
- Profiled on the A9 (a SIGPROF PC sampler): the coder ~31 %, the CAVLC parse ~24 %, the
  significance maps ~25 %, the levels ~18 %; branchless / unaligned-load / local-state tries and
  `-O3` / `-marm` gave at most 5 %.
- Not exercised: the rewrite beside a running Moonlight or Jellyfin client (only beside `h264play`
  and Main); a CRT.

## 26. The file player on the rig (feature/file-player, 2026-10-01)

.201, main's SEED 6 bitstream (`H264_mbpipe_20261001_1223.rbf`, `fcbd409`: the branch changes no
RTL), the player from `Scripts/h264player.sh` as a user runs it, synthetic clips in
`/media/fat/video`. A uinput keyboard on the target (`tools/mister_uinput_keys.py`) stood in for
the pad. `docs/player.md` §8.
- **The browser:** drawn over the idle screen. The roots view (`/media/fat/video`,
  `/media/fat/cifs`: both exist on this rig), then the folder: the sub-folder first, the five
  files in order, the `.srt` not listed.
- **854x480p60 High, 8 Mbit/s, AAC, an embedded SRT (default):** letterboxed, the cue in its time
  (5-9 s, seen at 7.05 s), 18 s in: errors 0, late 0, skipped 0, starved 0.
- **The folder played on:** the 576p25 MP4 (AC-3 5.1 mixed down, its `.srt` beside it). The player
  asked for 50 Hz (`set_err` 0); `raster_std` 2, 576 lines interlaced on this rig's Video
  Output; no errors or late pictures.
- **Its end tried the 720p file:** refused, "1280x720 is larger than ...", back to the list.
  Baseline: "CAVLC H.264 ..." on screen. HEVC: "the video is HEVC (H.265), not H.264". No access
  unit of any of them reached the core (`fe_refused` 0: the core never saw them).
- **The sub-folder's 640x480 23.976 TS:** Refresh Rate back to Auto (`raster_std` 0), played,
  errors 0.
- **Quit** (Q in the list): exit 0, Main's menu loaded.
- Found and changed: the refusal's message overlapped the list's title, and its header nearly ran
  off the safe area. Over a list it is now drawn at the list's foot, with shorter reasons
  ("CAVLC H.264 (Baseline profile)", "1280x720 is larger than SD").
- Not exercised on the rig: pause, seek and the subtitle button during playback (the clips ended
  before the keys arrived; the host test's (g) / (s2) cover the code); a real pad; a USB drive; a
  CRT at 576i (the maintainer's RetroTINK / CRT round).
- **The maintainer's round on .236 (2026-10-02, after the rebase onto 0.10)**, main's 0.10 core
  (`H264_hdmi-raster_20261002_0245.rbf`, `9c46b4d`: this branch's RTL but for CORE_VERSION), a pad:
  **every test successful**. Covered: pause, seek, subtitles, the 50 Hz PAL file, the refusals, the
  CAVLC phone clip at 2 Mbit/s, Native (HDMI) with the folder's 4:3 and scope films, and the
  screensaver (P5: the dim at 5 minutes, the fading line, the wake).
  - One finding: the 8 Mbit/s Baseline 480p60 clip (past the rewrite's ~4-5 Mbit/s ceiling, as
    expected late) made the controls very sluggish; Back + Start had to be held for seconds to
    quit.
  - The cause: `player_step` wrote up to 64 access units a turn, each rewritten on the loop's
    thread (~16 ms a unit at 8 Mbit/s on the A9), so the loop read the pad about once a second.
    A press shorter than that was never seen: the pads are a snapshot.
  - Fixed: a 10 ms budget per turn (`STEP_BUDGET_MS`). The host test makes every write 15 ms and
    checks the loop never stalls over 0.25 s ((w), M17).
  - Measured on .236, the same clip: a uinput keyboard pressed Space (pause) ten times, 1.5 s
    apart, and the delay to the player's "input: pause" was timed. Keys are a queue in the
    input region, so none is lost; the delay is the loop's period, which decides whether a pad
    press (a snapshot) is seen at all.

    | Binary | Median delay | Worst delay |
    |---|---|---|
    | before | 0.48 s | 1.43 s |
    | after | 0.016 s | 0.067 s |

    Half of each run's presses land while paused, when nothing is being written. The instrument
    first missed every press: its uinput events were packed with 64-bit times, and an ARM32
    `input_event` has 32-bit ones (`<llHHi`, as `tools/mister_uinput_keys.py` packs them).

## 27. 720p on the rig (feature/720p, roadmap Phase 5c part 1, interface 0.11, 2026-10-02)

*The build* (`feature/720p` `56d247b`): 2 MiB stores above the ring, the 3,600 bound decided
before `recon_dpb` (the refusal no longer emits an unwritten store), word 81. SEED 6 first roll,
clk_dec **105.62 / 101.4 -- PASS** (the cold corner exactly at the gate), 36,109 ALM (86 %), 378
RAM, 103 DSP, `H264_720p_20261002_2329.rbf`. On .201: the maintainer's Jellyfin client (0.10) was
running and held the session -- stopped with the maintainer's go, and put back afterwards (the
installed core is still 0.10, so the 0.11 client waits beside it as `jellyfin.iface0_11`).

**Throughput** (`h264play`, each stream's VUI pacing, §16's method: `rc_stall` over the play
time's clk_dec cycles; 10 s proxies, `.sim/p720/long/`, the Phase 1 source cropped to 16:9 at
1280x720). Every picture, errors / late / skipped / starved / `disp_fetch_late` 0, `rc_ref_size` 0:

| stream | pictures | idle | real time | cosim (60 frames, `mb_pipeline.md` §4g) |
|---|---|---|---|---|
| control: `sun854_high_8M` (854x480p60) | 300 | 29.8 % | 1.42x | (§19: 1.43x) |
| NVENC ull 720p30 10 Mbit/s | 300 | 14.1 % | **1.16x** | 1.25x |
| ... + a full 8888 overlay canvas | 300 | 12.2 % | 1.14x | |
| x264 medium 720p24 4 Mbit/s | 240 | 22.3 % | **1.29x** | 1.42x |
| x264 medium 720p24 8 Mbit/s | 240 | 10.5 % | **1.12x** | 1.21x |
| x264 medium 720p30 4 Mbit/s | 300 | 11.1 % | **1.12x** | 1.20x |
| x264 medium 720p30 8 Mbit/s | 300 | 0.0 % | **~1.00x** (the play time 10.06 s for 10.01: at the limit) | 1.04x |

The rig ran ~7-8 % under the cosim on these x264 720p streams (~16 % at 480p, §18): the 720p24
promise holds to 8 Mbit/s here, and x264 720p30 at 8 Mbit/s is exactly at the limit -- Phase 5c
part 2's case. The overlay's full canvas costs 2 points, the display's 1280-wide reads nothing
visible (`disp_fetch_late` 0 throughout).

**Word 81** reads `cap_max_mbs` 3,600, `cap_native_h` 480, `cap_mb_rate` 108,000, version 11.
**Native (HDMI):** a 1280x720 picture falls back to the fitted 720x480 raster (`raster_mode` 2),
854x480 still native (855x480, mode 1). **The picture** (a screenshot of the core's raster): the
720p frame letterboxed to 720x360 on the 720x480 raster, clean.

**The file player** (the 0.11 build, run from the harness folder): `t720p24_6M.mkv` (x264 B-frames,
AAC) and `t720p30_4M` / `_8M.mkv` play to the end -- mid-play the decoder ~18 pictures ahead of the
display, late / skipped / fetch-late 0, the audio playing; `t720p60.mkv` refused "1280x720 at 60
frames/s is too fast", `t1080p24.mkv` "1920x1080 is larger than 720p", nothing written for either.
(`aud_late` grows ~1,046 samples per file at its start -- a 480p control file the same: not 720p's.)

**Not done on the rig:** the Moonlight client at 1280x720p30 against the host (the NVENC proxy
stands in for its decode; the client's limits are host-tested), Jellyfin direct play of a 720p
file (needs the 0.11 core installed and a cast), the analog chain (RetroTINK / CRT at 480i: the
maintainer plugs it in).

## 28. Phase 5c part 2 on the rig: x264 720p30 at 8 Mbit/s real time (feature/res-overlap, 2026-10-03)

*The build* (`feature/res-overlap` `9131e29`): `dequant_itrans8` a pipeline over blocks
(`mb_pipeline.md` §4j), the window rectangle narrowed to what each position class reads, the
interpolation items overlapped and their weights read ahead (§4k). SEED 6 first roll, clk_dec
**104.32 / 102.05 -- PASS** at 101.4, 36,709 ALM (88 %), 377 RAM, 103 DSP, lint / canary PASS,
`H264_resovlp_20261003_2016.rbf`. On .201: the maintainer's Jellyfin client (0.10) was running;
stopped with the maintainer's go and, at their word, not restarted (the rig left on the menu).

**Throughput**, §27's method and streams (`h264play`, VUI pacing; idle = `rc_stall` over the
pictures' play time at 96.43 MHz). Every picture, errors / late / skipped / starved /
`disp_fetch_late` / `rc_ref_size` 0 throughout:

| stream | main (§27) | this build | cosim (main -> branch) |
|---|---|---|---|
| control: `sun854_high_8M` (854x480p60), twice | 1.42x | **1.57x, 1.57x** (36.2 % idle) | 647 -> 626 |
| NVENC ull 720p30 10 Mbit/s | 1.16x | **1.29x** | 716 -> ~684 |
| x264 medium 720p24 4 Mbit/s | 1.29x | **1.49x** | 785 -> ~749 |
| x264 medium 720p24 8 Mbit/s | 1.12x | **1.27x** | 925 -> ~875 |
| x264 medium 720p30 4 Mbit/s | 1.12x | **1.32x** | 746 -> ~717 |
| x264 medium 720p30 8 Mbit/s, twice | ~1.00x | **1.13x, 1.13x** (11.3 % idle) | 856 -> 755 |

**The rig against the cosim:** on x264 720p30 8 Mbit/s the two agree (cosim 1.04x -> 1.18x, rig
1.00x -> 1.13x: the rig/cosim factor ~0.96 before and after -- the 0.85 used for the part 2
estimates was a 480p x264 stream's, §4e, too pessimistic for 720p). On the 854x480 control the
rig gained MORE (+11 % against the cosim's +3 %): the narrowed window fetch moves fewer DDR3
bursts, which the cosim's DDR model prices lower than the rig (§18's latency shortfall). The
720p24 promise now holds with ~27 % to spare at 8 Mbit/s; x264 720p30 at 8 Mbit/s -- Phase 5c
part 2's case -- runs at 1.13x. (The cosim columns marked ~ are §4j's table after step 2, before
the interpolation levers; only the 720p30 8M stream and `sun_high_8M` were re-run after them.)

## 29. Phase 5c part 3, stage A on the rig: the raster on its own clock, nothing visible (feature/hd-raster, 2026-10-04)

*The build* (`feature/hd-raster` `35e72b7`, `docs/hd_raster.md` §12): the raster side on clk_vid (81
MHz, a second PLL) on a dot enable, one clock in three -- every 27 MHz raster bit-identical at the pins
to main's (`run_vid_equiv.sh`); the read-outs LAT 9, the composite registered; `mc_interp`'s S7
retimed (clk_dec's one binding path once the second clock domain shared the die). SEED 6 first roll,
**clk_dec 104.30 / 103.71, clk_vid 92.16 / 92.05 -- both PASS** (101.4 / 86.0), 36,639 ALM (87 %), RAM
375, DSP 102, `H264_hd-raster_20261004_0243.rbf`. On the rig the Main running was `MiSTer_DVDcss` (not
the stock binary the earlier rounds ran; the harness never changes Main).

**HDMI, synthetic clips (`h264play`), every picture, errors / late / skipped / starved /
`disp_fetch_late` 0:**

| case | raster | result |
|---|---|---|
| 720x480p59.94 (600 pictures), Video Output Auto (the rig's analog ini) | 480i, fitted (720x427 letterboxed), word 47 4 : 3 | correct picture (a screenshot) |
| the same, Progressive | 480p, filled | correct |
| x264 720p30 8 Mbit/s, twice | 480p | **11.2 % idle, 11.2 %: 1.13x** -- main's 11.3 % (§28): the display's new clock costs the decoder nothing |
| 852x480 30 frames/s, Native (HDMI) | native 852x480 at 60.00 Hz (mode 1) | correct |
| 852x356 24 frames/s (scope), Native | native, picture-sized 852x356 -- **main's build the same under this Main** (A/B): what this Main reports as the HDMI display, not stage A |
| 720x576 25 frames/s, Auto / Progressive | 576i / 576p at 50 Hz | correct |

**The analog chain, the same morning (2026-10-04)** -- on .236 (the RetroTINK is wired there; stock Main,
MiSTer.ini `vga_mode=rgb`, `composite_sync=1`, `vga_scaler=0`): RGBS -> RetroTINK -> the Hagibis, the
same build. Every number equals main's rounds (§7 / §9):

| | the RetroTINK's analyzer | field order (one-line markers at 100 / 201 / 300) |
|---|---|---|
| 480i 59.94 (`mark480`, Fit) | 1716x525i, 26.9996 MHz, H 15.73 kHz, V 59.94 Hz, CP 480i, stable, valid sync | 227.04 / 222.96 px = 101 / 99 lines (242 frames) -- correct, §8's numbers |
| 480i 60.00 (`p60x`, Refresh Auto) | 1716x525i, V 60.00 Hz, H-Freq 15,743.44 Hz (the two line lengths' mean, §9) | |
| 576i 50 (`mark576`) | 1728x625i, 26.9996 MHz, H 15,625.00 Hz, V 50.00 Hz, CP 576i | 189.75 / 185.25 px = 101 / 99 lines (182 frames) -- correct |

**Anti-twitter through the pins** (`still`, Fit): Off -- a grid line one raster line (peak 199); On --
three lines 45 / 94 / 45, the (1, 2, 1) (§9: 42 / 91-94 / 39-42). The 81 MHz clock, the dot enable,
the LAT 9 read-outs and the registered composite changed nothing a 15 kHz display receives.

**Not measured:** the overlay -- `h264play --overlay` could not map `/dev/fb0` under this Main ("the
framebuffer: No space left on device"; it worked under the stock Main the same evening, §28's
methods), so the core was never handed a canvas; the raster side's overlay path is covered by
`run_ovl_plane.sh` and the equivalence gate (every format). **S-Video / composite** (`yc_out` now
runs on 81 MHz with Main's measured subcarrier increment) and **an HDMI-to-VGA DAC on
`direct_video`** (its pixel clock now 81 MHz): the maintainer's round.

## 30. Phase 5c part 3, stage B on the rig: 1280x720 at its own pixels (feature/hd-raster, 2026-10-04)

*The build* (`feature/hd-raster` `126718b`, `docs/hd_raster.md` §13): the native raster on the 81
MHz dot, 2,048-sample lines, interface 0.12. SEED 6 closed clk_vid but not clk_dec (96.60 / 98.63:
four small placement clusters); the sweep's SEED 3 **105.21 / 103.79, clk_vid 98.86 / 96.39 -- both
PASS**, 36,736 ALM (88 %), RAM 411 (+36: the slots), DSP 102, `H264_hd-raster_20261004_1539.rbf`.
On .201 (Main `MiSTer_DVDcss`, which reports a 720x480 HDMI display: the display-shaped native
rasters come out 3:2).

| stream | Video Output | raster | result |
|---|---|---|---|
| 1280x720 30 frames/s (testsrc2) | Native (HDMI) | **native 1280x853** (mode 1: the 3:2 display's shape, the picture 1280x720 inside), 60.00 Hz | every picture, errors / late / fetch-late 0; the picture clean |
| x264 720p30 8 Mbit/s, twice | Native | native 1280x853 at 59.94 | **11.3 % / 11.2 % idle: 1.13x** |
| the same | Progressive | fitted 720x480 | 11.2 % idle |

**The display path's DDR3 cost is not measurable at 720p**: the reader's 1,280-sample lines and
ascal's 1280x853 input cost x264 720p30 8 Mbit/s nothing against the fitted raster (§6 had
extrapolated 3-4 points from the overlay's measurement). The overlay run failed (`ENOSPC`), first
put down to that Main -- the cause was the HDMI mode, below.

**The framebuffer is the HDMI mode's size; the overlay over 720p30** (the same day, .201 back on the
stock Main, `MiSTer.ini`'s `video_mode` changed with the maintainer's leave and rebooted for each):
`/dev/fb0`'s `smem_len` measured 1,382,400 at `video_mode=2` (720x480, .201's setting until then),
3,686,400 at 0 (1280x720), 8,294,400 at 8 (1920x1080). On the 720x480 mode `h264player` exited "ui:
the framebuffer: too small" -- stage B's UI rows at a fixed 2,048 pixels; fixed (`hd_raster.md`
§13), the player's UI then opened at 720x480 and 1280x720 modes. On a 16:9 mode the native raster
is display-shaped 1281x720 (the clip's SAR 1215:1216). x264 720p30 8 Mbit/s, Native, a full 1280 x
720 canvas (`h264play --overlay-size 1280,720`; the canvas checked live mid-play: `ovl_state` 1,
`ovl_lines` 720 a refresh, `ovl_late` 0):

| HDMI mode | canvas | idle | real time |
|---|---|---|---|
| 1280x720 | none | 10.8 % | 1.12x |
| 1280x720 | full `4444` (two pages fill the mode's framebuffer exactly) | 9.7 % | 1.11x |
| 1920x1080 | none, twice | 10.7 %, 10.7 % | 1.12x |
| 1920x1080 | full `8888`, twice | **7.4 %, 7.4 %** | **1.08x** |

Every picture, late / skip / fetch-late / errors 0. A full 8888 canvas costs ~3.3 points (§6 had
predicted ~7). .201 left on `video_mode=8` for the maintainer's rounds (`MiSTer.ini.before_hd_raster`
holds the old file).

**The Moonlight client at 1280x720p30, with the maintainer** (the same day, `video_mode=8`, Video
Output Native (HDMI), `width=1280 height=720 fps=30`, Sunshine's "Steam Big Picture" on this
workstation, NVENC, 10 Mbit/s requested): **"picture looked clean and controls were decently
responsive"**. The client's log: 11,961 access units (~6.6 min, 378 MB: ~7.6 Mbit/s), 0 dropped, **0
decoder errors, 0 IDRs asked**; audio 81,553 records, 1 dropped; an Xbox pad (7,987 updates), 14 OSD
openings, 7 OSD actions, 6 Guides sent, 0 events lost; the stream ended by another core's load. (The
first try said it could not reach the host: Sunshine was not running.)

**The Jellyfin client in Native, with the maintainer** (the same setup, the 0.12 client against the
maintainer's server): **a 720p file direct played and a 1080p film transcoded, "both looked good over
HDMI"**, seeks included. The client's log: "direct play" for the first, "transcode" for the second (the
HD profile: the box 1280x720 since `cap_native_h` 720); at the end the raster was the display-shaped
native 1280x718 (the film's scope transcode letterboxed inside it), decoder / front-end errors 0,
late / skip / fetch-late 0. Seen in the log and harmless here: libavformat's HLS probe "could not find
codec parameters ... unspecified size" at the transcode's start and after a seek (it played), and a
TLS "unknown error" as the server closed the direct-play stream at Stop. **Not measured:** a
direct-video DAC (none at hand).

## 31. 720p fitted to 480i on the analog chain: Phase 5c part 1's last round (2026-10-04)

The merged HD raster build (`H264_hd-raster_20261004_1539.rbf`, main at `e6454ab`) on .236, stock Main, `MiSTer.ini`
`vga_mode=rgb`, `composite_sync=1`, `vga_scaler=0`: RGBS -> the RetroTINK -> the Hagibis, Video Output Interlaced,
Analog Aspect Auto (the 16:9 film letterboxed), x264 720p30 8 Mbit/s (the 1280x720 film clip of §28 / §30).

- **The RetroTINK's analyzer** (its stats page in the capture): 1716x525i, 26.9996 MHz, H 15.73 kHz (15,734.27 Hz),
  V 59.94 Hz, detected CP 480i, stable rate, valid sync, V sync 3 lines, H sync 4.41 us negative -- as §29 measured
  with SD content. **V. Active lines 48 to 227 a field: 180 lines, 360 a frame** -- the core's `fit_oh` 360 (the 16:9
  picture letterboxed in the 4:3 raster's 480 lines); H. Active 239 to 1678 (53.33 us, the 720 samples).
- **The picture** (the stats page closed): clean, at its true shape, letterboxed, the full 4:3 width; the
  1280-sample lines decimated to 720 with nothing visibly wrong.
- **Throughput at 480i:** 300 / 300 pictures, errors 0, late / skip / fetch-late 0, **11.3 % idle (1.13x)**, twice --
  the same as at 480p (§28) and natively (§30).

With §30's Moonlight (1280x720p30) and Jellyfin (720p direct play) rounds, **Phase 5c part 1 is HW-CONFIRMED.** (The
RetroTINK took ~1.5 s to lock after each core load: the first captures held only black -- read a capture's
brightness before its frames.)

## 32. Rumble through the core on the rig: the core's side (feature/rumble, interface 0.13, 2026-10-04)

**The build:** `H264_rumble_20261004_2256.rbf` (commit 5d40c2d; SEED 3 first roll, clk_dec 104.11 /
104.8 at the 101.4 gate, clk_vid 92.77 / 94.46 at 86.0; ALM 36,988, 88 %, +252 over stage B's 36,736;
RAM 411, DSP 102). On .201 (the SuperStation, stock Main), the ARM `h264play` / `h264stat` of 83f5194.

**What was measured** (`h264play --realtime --fps 30 --rumble 0,128,64 --rumble 3,255,1 --rumble 5,0,1`
on a 10 s 720p30 clip, `h264stat` read before, 6 s in, and after the exit):

| | version | state | `rum_p0` | `rum_p3` | `rum_p5` | others | `rum_changes` |
|---|---|---|---|---|---|---|---|
| before (no session) | 13 | NO_SESSION | 0 | 0 | 0 | 0 | 0 |
| playing | | PLAYING | `0x8040` | `0xFF01` | `0x0001` | 0 | 1 |
| after the exit | | ENDED | 0 | 0 | 0 | 0 | 2 |

The values reach the signal that drives `hps_io`'s `joystick_N_rumble` exactly as written, two pads
a word in the right halves (pads 0, 3 and 5: each word's both halves and all three words), the three
words' stores caught in one poll (one change), and the library's close zeroes them while the session
is still open (ENDED: the core would otherwise go on passing them).

**Not measured: a motor.** No gamepad was connected to .201 (`/proc/bus/input/devices`: the IR
receivers, the flirc, Main's virtual input -- none with `FF`), so Main had no pad to play it on; the
step from `hps_io` to the pad (Main's `UIO_GET_RUMBLE` poll and `FF_RUMBLE` upload) is Main's own and
the maintainer's round (a pad, `h264play --rumble` or a game through the Moonlight client). The rig
was restored to `H264_hd-raster_20261004_1539.rbf` afterwards: the installed Moonlight / Jellyfin /
player clients are 0.12 builds (the library accepts only its own interface version).

**The motor, with the maintainer** (the same evening): the 0.13 core installed as `_Other/H264_rumble_20261004_2256.rbf`
with the three clients rebuilt against 0.13 (the 0.12 set backed up in `/media/fat/h264_iface0_12_bak/` and
`*.iface0_12`; the player's smoke test first: attached, played, its settings requests answered). A game through the
Moonlight client on the maintainer's pad: **"rumble works and feels good"**. No dip felt at 10 s, but the
maintainer may not have held one rumble that long: the keepalive's step is still unexercised on a pad.

## 33. The Downscale Filter on the rig: bit-exact, no late rows (feature/fit-filter, interface 0.14, 2026-10-05)

`H264_fitfilter_MARGINAL_20261005_0431.rbf` (SEED 3 first roll: clk_dec 101.73 / 100.57, MARGINAL at
the 101.4 gate but above the 96.43 MHz it runs at; its picture logic is the shipped one -- the
refit only re-expressed nine multiplies as shift-adds) on .201 with `h264play` / `h264stat` at
0.14. Three synthetic stills (text, thin lines, coloured edges: a desktop drawn by PIL, x264 High
CABAC 6 Mbit/s, 30 frames/s) looped through the ring; for each Video Output and Downscale Filter,
`launch --opt`, a shot of the core's raster (ascal's input buffer), `stat`.

- **Bit-exact against the golden.** Each shot scored against `tools/disp_golden.py`'s render of
  ffmpeg's decode of the clip (the still's frames differ by the encode's drift, so the best of its
  120 frames: frame 43 every time): **0 of 345,600 pixels differ** for 1280x720 in Progressive
  (Fill, 720x480; pre-filters Sharp 0/0, Area 3/2, Smooth 5/5) and at 480i (letterboxed 720x360,
  woven fields; 3/0 and 5/0 -- the rows are exactly 2:1 there, which the box already averages).
- **No late rows.** `disp_fetch_late` 0 in every run: 1280x720, the 720x1280 portrait (Fill:
  720x480, dv 2, Smooth's three boxes) and 2048x448 (A': 720x187, dh 2 / dv 2, the vertical over
  the budget -> Sharp's rows) in each mode, Progressive; 1280x720 at 480i.
- `video_out` (word 80, 0.14) read 2 in Progressive and 1 in Interlaced, as set; the interface
  version 14.
- Found on the way (the harness, not the core): a looping `h264play` from the previous run holds
  the interface's lock, so the next `feed` fails "Device or resource busy" and its `stat` reads
  NO_SESSION -- the first Area / Smooth numbers were of nothing. The round's script stops the old
  feeder (and waits for it) first.

The shipped fit (SEED 6, `H264_fitfilter_20261005_0528.rbf`) installed on .201 as `_Other/H264_fitfilter_20261005_0528.rbf`
with the clients rebuilt for 0.14 (a 0.13 program refuses a 0.14 core at attach): `moonlight`, `jellyfin`, `h264player`
replaced, the 0.13 binaries and core kept beside them as `*.iface0_13` (sha256 checked). .201's ini sets up no analog
display, so its Auto is now Native (HDMI). Not yet: the maintainer's comparison (Moonlight at 1280x720p30 and
854x480p60 in Progressive, 480i on the CRT / RetroTINK, each filter).

**Area always (2026-10-05, `H264_fitfilter_20261005_1611.rbf`, SEED 6 103.49 / 102.79).** After the maintainer's
comparison (Area better on 720p, close at 854x480, Smooth too soft: `analog.md` §11b) the option and Smooth
were removed. On .201 again, every shot equal to the golden (0 of 345,600 pixels): 1280x720 in Progressive
(3 / 2) and at 480i (3 / 0), 2048x448 (A': 2 / 0), and the 720x1280 portrait with Analog Aspect Letterbox
(304x480 pillarboxed, 1 / 1, odd W: the flush) -- under Auto a portrait is shown 9:16 and ascal stores it
already shrunk (607 wide on a 1080p output), so its shot is not the core's raster; `fetch_late` 0 in every
run. Installed for the maintainer as `_Other/H264_fitfilter_20261005_1611.rbf` (the three-mode build kept
as `.rbf.3modes`).

**Merged** as PR fj#32 (2026-10-05) after the maintainer's comparison on .201 -- ✅ HW-CONFIRMED.

## 34. The status block every frame: ring_stat waits for room (fix/cleanup, 2026-10-05)

`H264_cleanup_20261005_1734.rbf` (SEED 6, 103.7 / 102.99 PASS). Since 0.10's 48-word frame, a frame landing while the
input region's 24 words were still in the 64-word status FIFO was skipped (`run_ring_in.sh` I1 / I2 RED on main); now
it waits for the room. On .201, 1280x720 looping in Progressive (the raster at 60.00 Hz, Refresh Rate Auto, the input
region written every frame beside it): `seq_head` 730 -> 1,337 in 10.12 s -- 607 status frames, every raster frame,
none lost. Installed for the maintainer as `_Other/H264_cleanup_20261005_1734.rbf` (the previous build kept as
`.rbf.prev`).


## 35. Pictures from the program on the rig: other codecs decoded on the ARM (feature/arm-codecs, interface 0.15, 2026-10-05)

**Step 0** (before the design was frozen, `experiments.md` "Writing a picture into the stores"): a copy into a store
through `/dev/mem` is strongly ordered and CPU-bound, ~97 MB/s whatever the writer (64-bit loop, `stm`, NEON,
`memcpy`); `/dev/fb0` (write-combined) is 450-730 MB/s. A 720x480 picture is 5.3 ms of CPU, a 1280x720 one 14.2 ms:
**SD only**, decided with the maintainer.

`H264_arm-codecs_20261005_1936.rbf` (SEED 6, 102.95 / 102.9 PASS, 90 % ALM) on .201 as the harness's `H264_hil.rbf`
(the maintainer's installed core and 0.14 clients untouched), the 0.15 player beside them as
`/media/fat/h264player/h264player.p7` (`deps3`), clips in `/media/fat/video/p7test/` (generated: testsrc2 and the
Phase 1 source).

**Exactness, store by store.** After a 2 s clip played (`h264player.p7 play`), the 8 MB ring and the 40 MB of
stores were read back through `/dev/mem` (a throwaway `mmap` dumper: `read()` on that range returns nothing); each
store's last PICTURE record (the last session's, walking the ring from the write index) names its picture by PTS:
- MPEG-4 640x480: against the HOST's decode every store differs by at most 1 in 8-19 of 460,800 samples (the
  IDCT's platform rounding, which MPEG-4 allows); against the ARM's own decode of the same file (step 0's
  benchmark `ffmpeg`, the same FFmpeg) **20 of 20 stores byte-exact**.
- MPEG-2 720x480 interlaced (top first): **20 of 20 byte-exact** against the ARM's decode, every record a woven
  pair (structure 1), 60 records for 60 frames.
- MJPEG 640x480 yuvj422p: **20 of 20 byte-exact** against the ARM's decode converted by the documented formula
  (4:2:2 -> 4:2:0 rows averaged, full -> limited range).
So the copy, the layout, the descriptor and the store rule are exact on the ARM; only a decoder's own rounding
separates the rig from a host reference -- the fj#20 lesson (compare the ARM's output with the host's) answered by
comparing with the ARM's decode as well.

**Real time** (10 s clips with their audio, `play`; the player's CPU over 3-8 s, the status near the end):

| clip | CPU (one A9 core) | late / starved refreshes | errors |
|---|---|---|---|
| MPEG-2 720x480i, 6 Mbit/s, MP2 (`.vob`) | 51 % | 0 / 0 | 0 |
| MPEG-2 720x576i, 6 Mbit/s, AC-3 (`.mpg`; 50 Hz asked for) | 47 % | 0 / 0 | 0 |
| MPEG-2 720x480p30, 5 Mbit/s (`.m2v`) | 46 % | 0 / 0 | 0 |
| Xvid 640x480, 1.5 Mbit/s, MP3 (`.avi`) | 49 % | 0 / 0 | 0 |
| DivX 3 640x480 at 25 (`.avi`) | 35 % | 0 / 0 | 0 |
| WMV8 640x480, WMA2 (`.wmv`) | 53 % | 0 / 0 | 0 |
| Theora 640x360, Vorbis (`.ogv`) | 42 % | 0 / 0 | 0 |
| MJPEG 640x480 yuvj422p q 4 (~30 Mbit/s), PCM (`.avi`) | 75 % | 0 / 0 | 0 |
| H.263 352x288 at 15, AAC (`.3gp`) | 13 % | 0 / 0 | 0 |

Refused by name before the ring: an MPEG-2 1280x720 ("larger than SD (720x576): too much for the ARM") and an
MPEG-4 at 60 frames/s ("too fast for the ARM (30 at most)"). The audio's late drops at a stream's start (`aud_late`,
samples dropped before the clock reached them) are the H.264 path's too: an H.264 / AAC control on the same player
dropped 1,045, Theora's Ogg 6,720 (140 ms at its start -- a later look). Not yet: the analog chain at 480i / 576i
(field order of the pairs on the RetroTINK, a CRT), the maintainer's round with a pad.

**The analog chain (.236, the same day: RGBS -> the RetroTINK -> the Hagibis, stock Main, Video Output Interlaced,
the 0.15 build as `H264_hil`, the player from `/media/fat/h264p7`).**
- **Timing** (the RetroTINK's analyzer, MPEG-2 480i playing): 1716x525i, 26.9996 MHz, H 15.73 kHz, V 59.94 Hz, CP 480i,
  stable, valid sync -- as §29 / §31.
- **Field parity, measured:** interlaced MPEG-2 clips (still pictures) with one-line markers on frame lines 100, 201 and
  300, sent as woven pairs: spacings **101.08 / 98.92 lines** at 480i top-first, 480i bottom-first and (101.0 / 99.1) at
  576i top-first, 30 of 30 captured frames each -- every field's lines land on the raster's field of that parity (swapped
  would read 99 / 101). The 576i clip switched the raster to 50 Hz by itself (P4).
- **Temporal field order: wrong at 576i (measured), unmeasured at 480i.** A bar moving 8 px a field (MPEG-2, woven pairs,
  top first). With the RetroTINK on Bob, at 576i each captured frame held one field, and the bar stepped **+3 fields,
  -1 field** (+45 / -15 px) through the whole clip: each pair's later field shown first. At 480i the RetroTINK kept
  blending (two edges a frame at 30 Hz despite Bob): no temporal reading. This is `analog.md`'s known limit -- "a
  FIELD-coded source's field order against the raster's is not corrected yet" -- the display shows a field store's field
  by the RASTER's parity, and a pair picked up on a bottom-field refresh plays bottom-then-top; H.264 field pairs (PAFF)
  share it. It did not matter while the core's sources were progressive; interlaced MPEG-2 (DVDs, recordings) is now the
  ARM path's main 480i / 576i case, so it judders on a CRT (each field pair played backwards in time).

## 36. The maintainer's round on the CRTs: field order, the player, the cold boot, the analog DAC (feature/arm-codecs, 2026-10-05 / 06)

- **Field order fixed (`analog.md` §5, UMD's V6 ported):** `disp_ctl` holds a due field pair a refresh when the
  refresh it decides is not its first field's. On .201 over HDMI (SEED 5 build, `H264_arm-codecs_20261006_0327.rbf`)
  the 576i interlaced MPEG-2 clip switched the raster to 50 Hz, 220 pairs shown, late / cadence 0, **`disp_fhold` 1**
  (one hold at the stream's start, every pair on its field after). **On .236's CRT (S-Video, the maintainer):
  `fo_576i_tff.vob`'s bar moves with no back-steps** (it stepped +3 / -1 fields before, §35); the fine serration on
  the moving edge is the clip's own interlaced motion (each field a different time; anti-twitter leaves field-coded
  pictures alone by design).
- **The player (the maintainer, .236):** much of the UI's text was cut off by a CRT's overscan -- every screen now keeps
  inside title-safe on SD rasters (`player.md`), confirmed; a Blu-ray rip's DTS 5.1 had no dialogue -- the downmix's
  swr was built from the decoder's layout at open (dca reports stereo under `downmix`, decodes 5.1 without embedded
  coefficients), now from each frame's (`player.md`), confirmed.
- **The cold boot (.201, after it was moved):** nothing played, "Loading" for ever -- the core in ERROR, `WIDX_ALIGN`,
  the stale write index `0xFFFFFFFF`: after a power-up DDR3 is random, the core checks the write index's alignment at
  every poll of a session, and the library stored its own only with its first record. The library now rounds a
  misaligned stale index down before the nonce (`architecture.md` "The session"); the player, Moonlight and Jellyfin
  rebuilt; plays.
- **The analog DAC's banding (`analog.md` §12):** test patterns on .236's CRT: black level right (Y 8 / 16 vanish, 20
  shows), `ramp_dark` (Y 16 -> 64) in **14 bands** -- the DE10-Nano's 18-bit analog I/O board takes the top 6 bits;
  on .201 (a SuperStation, composite) **no banding** (a 24-bit DAC). So an OSD option, **Analog Dither** (Off by
  default): an ordered 4 x 4 dither inverted every field in sys_top's VGA path. **On .236 with it On: the ramps'
  banding smoothed out** (the maintainer). HDMI untouched.
- **Timing:** `disp_reader`'s fetch retimed twice on clk_mem (the pre-filter's horizontal sums, the bridge's read data):
  clk_mem -1.08 -> positive; SEED 5 103.11 / 103.46 PASS, every clock positive (the ledger).

## 37. A USB camera through the core: step 1 and the viewer (feature/uvc-viewer, 2026-10-06)

.201 (the SuperStation, its two 7-port hubs), the menu or the H264 core loaded, main's bitstream (the
branch changes no RTL). A **Logitech C270** (046d:0825, UVC 1.00, isochronous) the maintainer plugged in.
`docs/uvc.md` has the design and every number.
- **Step 1, the measurement** (U2): `h264cam --stage`, every run `taskset -c 0`, a SCHED_IDLE spinner per
  core checked first (0.000 at idle, 0.500 with a 5 s load in 10 s). MJPEG 640x480 at 30: capture 0.197 of
  CPU0, decode 11.8 ms a frame (4:2:2 full range), show 0.888 with the store copy as merged -- past the
  gate. The copy of a full-range 4:2:2 picture was 14.3 ms; `put_row`'s clamp-free NEON interior (U2a) made
  it 8.15 ms and show **0.724**, 30 frames/s, 0 bad; NEON == scalar on the rig over 896 cases
  (`hps/tests/run_copy_arm.sh`). In a dim room the C270 fell to 12.6 frames/s (auto-exposure priority):
  switched off by the viewer.
- **The USB host's limit** (U2b): YUY2 640x480 at 30 lost every frame on alt 11 (3 x 1,020). First read
  as "no high-bandwidth isochronous" -- disproved: the working MJPEG ran on alt 7 (2 x 640), and `--alt N`
  streamed MJPEG clean on every setting, alt 11 included. YUY2 by rate: clean to 6.0 MB/s, a packet lost
  at 6.1, most frames lost from 9. The rule is the data: uncompressed only up to 6 MB/s.
- **The viewer** (U6), from `Scripts/h264cam.sh` as the menu runs it: the card, then 640x480 MJPEG at 30
  live; the mode list over the picture (I key: "Program menu"'s mapping), 320x240 chosen -- black at
  first (a restart left the stream's `stopping` flag set: fixed), then the picture and "Mode 320 x 240";
  Space: "Paused", the status block `paused 1`, the picture held; Space, Q: exit 0, back to the menu.
  Shown 725 and 483, no store waits, nothing undecodable.
- **With the maintainer on .236** (the original rig, its analog output on a CRT; the H264 core 0.15 build
  `H264_20261006.rbf`, stock Main; the C270 moved there): the viewer from the Scripts menu, the camera
  plugged and unplugged twice -- each plug streamed 640x480 MJPEG at 30 (alt 7), each unplug went to the
  card ("the device stopped", "state wait"); the status block errors 0; the raster 480i (Auto, interlaced).
  The maintainer: **the picture looked good on the CRT**. ✅ HW-confirmed.


## 38. The dither's Latin-square matrix on the rigs (fix/dither-latin, 2026-10-06)

`H264_ditherlatin_20261006_2313.rbf` (SEED 5, the ledger) against main's netlist (`H264_arm-codecs_20261006_0327.rbf`:
the same RTL but for `CORE_VERSION`). `docs/analog.md` §12 "The matrix" has the design.
- **.201** (the SuperStation, 24-bit DAC; Auto = Interlaced, 480i): `chart480.264` 600 / 600 with Analog Dither On,
  errors 0, late 0. The fit's clk_mem miss (-0.099 at -40 C) lands in `disp_reader` (`pm_r` -> `row_base`), so the
  reader's output was checked: two shots of the chart on each build, **pixel-identical** (183 colours, not a blank
  frame). HDMI never sees the dither, so this says nothing about the matrix.
- **.236 with the maintainer** (the classic 18-bit I/O board, `vga_mode=svideo`, a CRT at 480i; the harness's MGL,
  Analog Dither On, each clip looped by `h264play`): A = main's build, B = the Latin square, flipped on request.
  `ramp_dark` (Y 16 -> 64 across the screen): **"crosshatching is noticeable on A but not B. The overall ramp looks
  similar but the image quality on B is better."** A blue ramp (RGB 0 -> 112 in blue alone, left to right, x264
  qp 2, BT.601 -- made for this: the patterns folder's `ramp_color` is an orange ramp top to bottom), B then A:
  **"I don't notice the crosshatching in A in this pattern as much as the last one, but the gradient in B still
  looks better to my eye."** DVD's capture had flagged blue at 480i as worse with this matrix and its CRT cleared
  it; here too blue is no worse. ✅ HW-confirmed. Not checked: .201's analog capture (dither Off identical to main
  is by construction: the bypass is `run_dac_dither.sh`'s `[off]`).

## 39. The colour, interface 0.16 (feature/colour-matrix, 2026-10-06 / 07)

The Jellyfin client's F2 before 1.0 (`colour.md`): the display converted every picture as BT.601
limited. **R4 on the maintainer's server** (the rig client's sign-in, its own device profile, direct
play off): every transcode of the library's 522 SD items' kinds is tagged BT.709 and nothing is
converted -- a BT.601 source's transcode carries its pixels unchanged (saturated Cr 0.27 off as-is, 1.86
off converted). So auto alone would have shown SD transcodes WRONG; the Jellyfin client sends the
source's code.

Built: six coefficient sets in `disp_reader` (latched per refresh), the VUI's colour in `recon_hdr`'s
side table, the code per picture through `recon_out`'s table, header word 1 [35:33], error 17, words 80
/ 86, the library's `h264ring_set_colour()` and full-range pass-through, the clients. Every bench GREEN
and `--red` (the SD equivalence gate against main included).

**The fit**: the first roll 94.3 / 95.76 -- the PICTURE's code outside the descriptor's `h264.sdc`
bound (-2.1 ns, added) -- then 26 seeds within ~1 MHz of the 101.4 gate and none over it on both
corners. A census of the best (SEED 2, 101.33 / 102.62) named `recon_hdr`: the SE word's decode into
`is_nal` (fanout 50), which the colour description's reset and table write had loaded; moved a clock
behind, the retimed netlist's SEED 13 103.52 / 101.71 PASS (`H264_colour_20261007_1245.rbf`, ALM 37,888).

**On .201** (Video Output Native, SMPTE HD bars as all-intra x264, every frame identical; the screenshot
-- the core's raster -- against `tools/colour_ref.py` on ffmpeg's decode, chroma nearest as the display
samples it): **every pixel exact** for the unspecified SD clip (code 1), BT.709 (3), BT.601 full (2),
BT.709 full (4), BT.2020 (5) and an unspecified 1280x720 (3, by size, at its native 1280x720); each
12-42 levels from every other code's prediction (the instrument separates them). Words 80 / 86 as
designed every time. The override (`h264play --colour`): BT.709-tagged shown as 1, unspecified as 6,
exact, `colour_override` 1. Not on the rig: a Jellyfin transcode end to end (the host test's (k2) and
R4 cover the override; the maintainer's round), the analog chain (RGB is the shared intermediate:
`sys/`'s YPbPr / S-Video re-encode it as before).

**The maintainer's round** (2026-10-07, .201: `_Other/H264_20261007.rbf` and the four 0.16 clients, the 0.15
set kept as `*.iface0_15` -- the library's version check is exact): good, ✅ HW-CONFIRMED. Found on the way:
the Jellyfin ready card's "...play it on this MiSTer" cut at "MiST" by the title-safe card; the card's line
and note now wrap, balanced (`player.md`, the ui.c row).

## 40. The fit word with no picture, interface 0.17 (feature/fit-word, 2026-10-07)

The Jellyfin client's F5, the last pre-1.0 interface finding but for F1 / F4 (left to later additions): on its
ready screen (a session, no picture) word 30 read a 0 x 0 picture's fit -- `fit_crop_bad` 1, `fit_clamp` 1,
`fit_oh` 8,191 -- faults a program would believe. Word 30 [45] `fit_valid` (disp_ctl's `sh_valid`); the fit's
fields and word 80's `pic_x0` / `pic_y0` read 0 while it is 0 (emu's `st_*` wires, pinned by check_emu_wiring:
run_scaffold.sh W109 / W110, W73 retargeted). Fit SEED 2 102.18 / 102.35 PASS (`H264_fitword_20261007_2343.rbf`).

**On .201**: the core loaded, nothing played -- `fit_valid` 0, every fit field and `pic_x0` / `pic_y0` 0,
version 17; a picture playing -- `fit_valid` 1, 720 x 427 at (0, 26); **the Jellyfin ready screen (READY, no
picture) -- `fit_valid` 0, every field 0** (0.16: the faults above). Installed with the 0.17 clients:
`_Other/H264_20261008.rbf`, the 0.16 set kept as `*.iface0_16`.

## 41. The interface frozen at 1.0 (feature/iface-1.0, 2026-10-07)

The maintainer: "let's freeze the interface for 1.0". The 0.17 layout unchanged; word 1 `0x0100`; the rules for
1.x and the library's new check (the same major, a minor at least its own -- `h264ring_version_ok()`; exact below
1.0) in `architecture.md` "Version 1.0" and the manual's `integrating/interface.md` "Versions". `tools/tests --red`
ALL GREEN (88 mutations; the three new ones, one per arm of the rule, each caught by `test_hps_lib.py`);
`run_ring_rd`, `run_scaffold`, `run_ring_in` and the four clients' host tests GREEN. Fit SEED 2 first roll 104.68 /
104.28 PASS (`H264_iface1_20261008_0042.rbf`; clk_mem -0.093 at -40 C on §38's `disp_reader` path).

**On .201**: word 1 reads `0x00200100` (version 256); the 1.0 `h264play` plays `cap_3000` (Sunshine, 3 Mbit/s,
`--realtime`) 1,293 / 1,293, errors 0, ENDED; the control arm -- main's 0.17 build and main's `h264play`, the same
clip and options -- every counter equal (`disp_late` 341 and `disp_starve` 1 on both: the clip's, not the change's).
Across the boundary each way: the installed 0.17 `h264stat` on the 1.0 core and the 1.0 `h264stat` on the 0.17 core
both "Protocol not supported" (`-EPROTONOSUPPORT`), as designed -- the one break the freeze costs. The 1.0 client set
is built (`clients/*/build/dist`) and, after the merge (PR fj#43), installed on .201 at the maintainer's word: `_Other/H264_20261008.rbf`
and the moonlight / jellyfin / h264player / h264stat / h264cam binaries, checksums equal to the builds; the installed core
loaded from `_Other` reads version 256 through the installed `h264stat`. The 0.17 set kept as `*.iface0_17`.

## 42. Release 1.0.0 (2026-10-08 / 09)

The release commit `fdecab5` (the only one carrying `v1.0.0`): `CORE_VERSION`, `mkdocs.yml`'s `released_version`,
compatibility's "Current as of", the install page's "Not yet released" gone, SEED 12. The manual audited first (PR #5:
the four programs, Native as Auto's default, the ARM codecs; the pre-1.0 `(0.x)` marks and history stripped -- the
maintainer's decision). Host tests from the release commit: `make -C hps test` and the four clients'
`run_test.sh --red` ALL GREEN (and RED).

**The fit.** The version string re-rolled the netlist: SEED 2 98.73 / 98.76, refused by `--release`. A sweep of fifteen
seeds found two at the gate -- **SEED 12 103.15 / 102.38** and SEED 15 101.74 / 102.69 -- the rest 96.3-102.5 at one
corner or the other (the ledger has every one). `--release --compile` with SEED 12 pinned reproduced 103.15 / 102.38,
clk_vid 93.62 / 94.43, lint and canary PASS, 37,932 ALM (91 %), RAM 413, DSP 103: `H264_20261009.rbf` (sha256
`d07607d3...`). Ungated: two crossings into clk_vid at 100 C, `analog_want_l` -> `ary[7]` -0.206 ns and `status[6]` ->
`ary[7]` -0.086 ns (clk_sys settings flags into the aspect register, quasi-static) -- seed placement, like the clk_mem
paths of §38 / §41.

**The sweep's own defect.** The background task that ran `seed_sweep.sh` hit its time limit at seed 7; killing the
attached `docker run` signalled the sweep, whose EXIT trap ran (deleting its `H264.qsf` snapshot) and left bash
running the loop with `continue` / `break` dead: every later seed printed FAIL and then "PASS", the qsf restore
failed (Quartus' 172-line rewrite left in place: restored from git), and the closing pack failed on the dirty tree.
The measurements stand; the release was built by a fresh compile, not from the sweep's files. Fix wanted in
`tools/seed_sweep.sh` (run it detached, or make the trap not fire mid-loop); until then run a sweep with
`docker run -d` / `docker logs -f`, never under a killable foreground task.

**On .201** (rebooted first, at the maintainer's word: a leftover DVD HIL Main from an earlier DVD session): stock
Main, the release `.rbf` deployed (manifest `v1.0.0`, `fdecab5`, SEED 12), `h264play` and the clips rebuilt from the
release commit. `p60.264` (720x480p59.94) 600 / 600 and `film.264` (23.976) 240 / 240 decoded, emitted and shown, ENDED,
errors 0, `disp_skip` / `disp_late` / `disp_starve` 0, version 256; 480i (the box's analog ini), the picture letterboxed
720 x 427 at line 26, the scaled output exactly 4:3. Restored. The About line itself is not visible to the harness;
its version is the manifest's.

## 43. Chroma at the identity (feature/chroma-interp, 2026-10-09 / 10)

The maintainer, testing 1.0.0 in Native (HDMI) on .201: vertical bands beside red detail. A synthetic
1280x720 pattern (`redpat.264`: red / blue / green details on white and black, 1- and 2-pixel lines,
edges at every column offset; H.264 High QP 2, BT.709 limited) played through `h264play --osd
video_output=3`, the raw raster screenshotted, compared with models built on ffmpeg's decode:

| build | nearest model | the RTL's interpolation | ffmpeg's upsampling (in_chroma_loc=left) |
|---|---|---|---|
| 1.0.0 (`H264_20261009.rbf`) | **99.99 %** exact, max 2 | -- | 77 %, max 108 |
| `H264_chromasweep_20261010_0632.rbf` (SEED 5) | 76 %, max 107 | **99.99 %** exact, max 2 | 98.5 %, max 3 |

90 / 90 pictures, `disp_fetch_late` 0, the raster 1280x720 native, colour code 3. The design and its
decisions: `display.md` §3 "Chroma at the identity"; the fits: the SEED LEDGER (SEED 12 marginal --
clk_vid 81.6 from the first ahead index, fixed by using the second tap -- then SEED 5 PASS). The sweep
ran detached (`setsid`): §42's trap avoided.

## 44. Chroma reconstruction, the full version (feature/chroma-interp, 2026-10-10)

`docs/chroma.md`: the SPS's `chroma_sample_loc_type` to the display, chroma rows in their own slots,
siting-aware bilinear chroma on every output. Fits (the SEED LEDGER): the first missed clk_vid (62.5 MHz:
the chroma slot allocation's running minimum over eight slots -- made parallel) and clk_mem (-7.2 ns: the
chroma command's crossing unbounded in `h264.sdc` -- bounded, as m_hpf / m_vpf had been in 6d); then SEED 2
102.15 / 102.45, clk_vid 96.94 / 91.46 PASS (`H264_chromafull_20261010_1752.rbf`, 39,040 ALM 93 %, DSP 109).

**On .201** (rebooted first at the maintainer's word: a DVD harness Main left resident by a session no live
one claimed), `redpat.264` (1280x720, BT.709) at three outputs, the raw raster against
`tools/disp_golden.py`'s `render` with the core's reported fit, bilinear (the design) and the old reader's
nearest rule:

| output | the fit | bilinear | nearest |
|---|---|---|---|
| Native (HDMI) | 1280x720, 1:1 | 99.99 % exact, max 2 | 75.9 %, max 107 |
| Progressive (480p) | 720x480, Area | 99.99 % exact, max 2 | 72.2 %, max 144 |
| Interlaced (480i) | 720x360 letterboxed, Area | 100.00 % exact, max 2 | 65.9 %, max 146 |

90 / 90 pictures each, errors 0, `disp_fetch_late` 0. Restored. Then installed on .201 as
`_Other/H264_20261010.rbf` (beside 1.0.0's `H264_20261009.rbf`; the programs load the newest) for the
maintainer's own round on real content: **"this looks better"** (2026-10-10).


## 45. The Jellyfin transcode's no audio and freeze (fix/jellyfin-transcode, 2026-10-10)

`docs/jellyfin.md` §12: the client's half (audio held to ~1 s ahead of the video, an audio stream the probe
missed played, every record timed); the core's livelock designed only (`architecture.md` "Queued audio: a
late picture never runs the clock back over it"). No RTL (`dev-jftranscode` only: no fit).

**On .201**, with the maintainer's word, control arm first. The setup:
- the core is the chroma build (`_Other/H264_20261010.rbf`), Native (HDMI);
- the film is the maintainer's 1080p HEVC 10-bit one of 2026-10-09, transcoded by the server to H.264
  1280x720 at 9.6 Mbit/s with AAC stereo;
- it was cast through the server's API with the client's own token: Play at 5046.4 s, then seeks to
  5060.9, 6090.5 and 3946.6 s (2026-10-09's opens), 35-70 s each;
- the 1 s status logger (`h264stat --json`) ran beside the client's log (`CLIENT_TIMING`). Logs on the
  rig: `/media/fat/h264tel/{control,fixed,fixed2}.{stat,jf}.log`.

The clock is measured within each session; the probe is the stream-info stage, from `CLIENT_TIMING`:

| open | 1.0.0's client (control) | this branch |
|---|---|---|
| Play 5046.4 | **froze**: the clock 21.1 s in 60.5 s, 6 re-anchors, `aud_q_rec` 256, 1,075 records | clock 70.1 s in 70.1 s, no re-anchor, `aud_q_rec` <= 86, 3,368 records |
| seek 5060.9 | **no audio** (0 records; "unspecified sample rate") | 1,389 records ("decoding them from the stream") |
| seek 6090.5 | **no audio** (0 records; the same) | 820 records (the same) |
| seek 3946.6 | 1,620 records | 1,671 records |
| first IDR / probe | 13.65 (the server's first start), 2.15, 4.20, 4.02 s / 53-127 ms | 3.33, 2.47, 4.45, 3.78 s / 179-286 ms |

- *The hold:* the client logged the stream's audio up to 1.0 s, 2.4 s and 2.5 s ahead of its video on
  ordinary opens, and held it back. Nothing was let through early.
- *Every control re-anchor* came with the audio armed and waiting early (`aud_state` 1, `aud_gap` growing)
  and the ring full (8.0 MB): first with `aud_q_rec` at 255-256, then with it falling to 45 / 38. The
  2026-10-09 trace shows the same thing over 16 re-anchors, `aud_q_rec` down to 3. That data set Part B's
  rule (the audio's state, not the FIFO's fill level).
- *The probe:* that arm ran a 4 MB / 2 s probe for network inputs. It missed the same audio on both opens
  and its stage took ~0.15-0.2 s longer, so it was reverted to 1 MB / 0.5 s.
- *The rebuilt client* (`fixed2`), Play 5060.9 and seek 6090.5: 880 / 803 records, no re-anchor, probe
  100 / 120 ms, first IDR 3.55 / 4.25 s.

Restored: the menu core, 1.0.0's client back in `/media/fat/jellyfin/jellyfin`, this branch's beside it as
`jellyfin.jftranscode` (0ef771f4...). The file player's ARM build was not run on the rig (the same
`player.c`; host-tested: (x) / (y)).

## 46. Interface 1.1: a late picture never runs the clock back over leading audio (feature/aud-clock, 2026-10-11)

`docs/architecture.md` "Queued audio: a late picture never runs the clock back over it" (and "Version 1.1").
The rule changed while building: "the audio on time" (the merged draft) would also have caught a stall,
whose late audio is dropped and on time again before the late picture is decoded. The audio's history
tells the two apart (`aud_lead`: it waited for the clock or started it, and has neither run dry nor come
late since). Benches: `run_disp_anc.sh` X7-X10 and `run_aud_play.sh` `[lead]` A12 / A13, both GREEN and
`--red`; `run_disp_sched.sh` GREEN (40 scenarios, both rasters, heldlead new); D2 / D27 RED.

**Fits** (the SEED LEDGER): SEED 2 first roll MARGINAL (102.32 / 99.05). The first sweep (5, 13, 6, 3, 12, 7,
9, 1) all missed by 0.5-3 MHz. The census (SEED 1, -40 C) put the failing endpoints in the decoder's own
reconstruction (recon_inter's 5x5 product, recon_hdr, recon_mb), re-placed by the netlist change. The second
sweep's first seed passed: **SEED 4, 103.8 / 102.73 PASS**, clk_vid 92.04 / 88.43, 39,014 ALM (93 %), RAM 421,
DSP 109, `H264_audclocksweep_20261011_0503.rbf` (30a71bf).

**On .201** (with the maintainer's word; control arm first). Each arm ran as the harness core
(`_Other/H264_hil.rbf`), with the 1 s logger (`h264stat --json`) beside 1.0 programs (a 1.0 program runs on
a 1.1 core). The clip is 40 s of 720x480 at 29.97 (x264, no B-frames: `--pts`) with a chirp, played as
`h264play --pts --fps 29.97 --pcm lead.pcm --pcm-lead MS`.

| | 1.0 core (`H264_20261010.rbf`, chroma) | 1.1 core (SEED 4) |
|---|---|---|
| `--pcm-lead 6000` | plays to its end, ~0.9 s late (6 - 5.12 s: under `LATE_MAX`), no re-anchor | -- |
| `--pcm-lead 10000` | **stuck**: 3 access units consumed, the clock 2.6 s in 12 s, 2 re-anchors, the ring full: `h264play` gave up at access unit 333 ("Connection timed out") | **plays to its end**: the clock 41.6 s in 42 s, 0 re-anchors, every picture shown ~4.9 s late (`disp_late` 1,194), `aud_gap` 0 |
| 1.0.0's Jellyfin client, the film, Play 5046.4 s (Part A's freeze, `history.md` §45) | froze: the clock 21.1 s in 60.5 s, 6 re-anchors | plays, with one re-anchor after the queue ran dry: the clock 73.4 s in 76.3 s; `aud_q_rec` reached 256 without one; 316 pictures late and 647 starved refreshes before it settled |

On the 1.1 core the Jellyfin run's one later re-anchor came after the audio ran dry (`aud_q_rec` 0, an
underrun). That is the stall's case, where the 1.0 recovery is kept: the audio then waited, played, and the
stream ran on. Logs: `/media/fat/h264tel/b_{control,control10,new10,jf10}.*` on the rig. Restored: the menu
core, the harness core and binaries removed, 1.0.0's client and the installed cores untouched.

**The maintainer's round (2026-10-11, .201): "all tests look good".** The setup: the 1.1 core
(`_Other/H264_20261011.rbf`), the fixed Jellyfin client and file player (PR #9), and the checklist: the film's
four opens (1:24:06, 1:24:21, 1:41:31, 1:05:47) and the maintainer's own seeks, pause / stop / recast, a
direct-play film, the file player, Moonlight. The 1 s logger over the 24 minutes recorded:
- no re-anchor beyond each stream's first picture;
- the audio queue peaking at 95 records;
- one decoder error in one stream.
Restored afterwards:
- the 1.1 core kept as `H264_20261011.rbf.iface1_1` (inactive), the chroma build the active newest;
- 1.0.0's `jellyfin` and `h264player` back in place, the fixed ones beside them as `*.jftranscode`.

## 47. A black TV at 720x480 HDMI: the HDMI PLL's output counter (fix/hdmi480-black, 2026-10-11; ✅ MERGED (PR #12))

**How it was found.** The maintainer had reported 480p "looking jagged" and wanted to compare HDMI output
at 720x480 with the 1080p they had been using. .201's `MiSTer.ini` went from `video_mode=8` to `video_mode=2`,
and after a reboot the TV showed nothing from the core. It reported 480p, but the screen was black and the
OSD was invisible. The menu core and the DVD core were fine at the same mode.

**Whether the picture or the HDMI signal was missing.** The core's own raster was fine: `h264player`'s
browser was in the screenshot and it moved as the maintainer navigated. Every Video Output (Auto / 480i,
Progressive, Native) was black, so it was not one raster.

**Bisected by build** (the maintainer watching the TV, each build loaded by MGL with no program running):

| build | SEED | 720x480 HDMI |
|---|---|---|
| `resovlp_20261003_2016` (before hd_raster) | 6 | bars |
| `hd-raster_20261004_0243` (stage A), `_1539` (stage B) | 6, 3 | bars |
| `rumble_20261004_2256`, `fitfilter_20261005_1611`, `arm-codecs_20261006_0327` | | bars |
| `colour_20261007_1245` | 13 | bars |
| `fitword_20261007_2343` | **2** | **black** |
| `iface1_20261008_0042` | **2** | **black** (twice) |
| `20261009` (release 1.0.0) | 12 | bars (twice) |
| `chromafull_20261010_1752` (.201's installed core) | **2** | **black** (three times) |
| `audclocksweep_20261011_0503` (main, interface 1.1) | 4 | bars |

The fault was not a code change. Only the three SEED 2 fits were black.

**Bisected by HDMI mode** (the chroma build, SEED 2): 640x480@60 gave no signal (SEED 4: bars),
720x576@50 black, 1280x720 and 1920x1080 bars. Custom timings (`720,480,60`, and the 9-field CEA form at
27.0 / 27.1 MHz) were refused by the TV ("Invalid format").

**Measured, not watched.** The ADV7513 measures the TMDS clock for HDMI audio. Its read-only CTS (registers
0x04-0x06) is `f_pix x N / (128 x 48 kHz)`, so with Main's N of 6144 the CTS in kHz is the pixel clock.
`i2cget -y 1 0x39` from the rig's Linux reads it; `tools/mister.py hdmi` now does it.

| build | `video_mode` | pixel clock (CTS) | VIC detected | should be |
|---|---|---|---|---|
| SEED 4 | 2 (720x480) | 27.000 MHz | 3 | 27.000 |
| SEED 2 | 2 (720x480) | **135.000 MHz** | 3 | 27.000 |
| SEED 2 | 0 (1280x720) | **148.500 MHz** | 4 | 74.250 |
| SEED 4 | 0 (1280x720) | 74.250 MHz | 4 | 74.250 |
| SEED 2 | 8 (1920x1080) | 148.500 MHz | 16 | 148.500 |

**The detected VIC does not see the clock.** It read 480p60 for a 300 Hz signal. A first check by VIC alone
seemed to rule the cause out.

**The mechanism.** Main sets each mode's pixel clock by retuning `pll_hdmi` through `pll_cfg`
(Main_MiSTer `video.cpp` `setPLL`): it picks a VCO of at least 400 MHz (M, N, the fractional K) and
rewrites **physical C counter 0** (register 5, counter select 0). The PLL's compiled setting is 148.5 MHz:
VCO 445.5 MHz, C = 3. In the SEED 2 fits the fitter put `outclk_0` on the counter at
`PLLOUTPUTCOUNTER_X0_Y7_N1`; every working fit had it on `X0_Y5_N1`. Main's C write landed on a counter
that drives nothing, so only the VCO followed the mode:
- 720x480 came out at 405 / 3 = 135 MHz (858 x 525 at ~300 Hz: black);
- 720x576 likewise;
- 640x480 at 402.8 / 3 = 134 MHz (no signal);
- 1280x720 at 445.5 / 3 = 148.5 MHz (720p at **120 Hz**, which this 4K TV accepted, so it looked fine);
- 1080p, the compiled clock, was right.

Timing closed in every one of these fits: the timing analysis cannot see a counter that Main reprograms
at run time. **Every 720p test on a SEED 2 build (iface1, fitword, the chroma build) ran on a 120 Hz signal.**

Reproduced from source: `a83a388` refitted at SEED 2 with BUILD_DATE pinned to `261010` gave a
byte-identical `.rbf` (sha256 `e20b2ef3...`), its report on `X0_Y7_N1`.

**The fix.**
- `sys/sys.tcl` (`H264-FORK`) pins `pll_hdmi` to `FRACTIONALPLL_X0_Y1_N0` and its output counter to
  `PLLOUTPUTCOUNTER_X0_Y5_N1`.
- `tools/hdmi_pll_check.sh` reads the fit report: the PLL's site, its output counter, and any ignored pin.
  `build_release.sh` runs it after the netlist canary: advisory on a dev build, fatal on `--release`.
- The gate is FAIL on the SEED 2 report and PASS on SEED 4's, MiSTer_DVD's and UMD's current ones. The
  siblings carry the same `sys/` and the same exposure (`harvest.md` "Fixes exchanged").
- "X0_Y5 is the counter Main writes" is inferred: every working fit uses it and the one failing placement
  does not. The proof is the CTS on a fit that the pin forced back:
  - `a83a388` + the two pins, refitted at SEED 2 (BUILD_DATE `261010`): the report shows `X0_Y5_N1`
    (`hdmi_pll_check` PASS). clk_dec was MARGINAL: the pins re-place the design. The build is
    `H264_chroma_MARGINAL_20261011_1906.rbf`, a test build only.
  - On .201 the HDMI clock measured 27.000 MHz at `video_mode=2`, 74.250 at `0` and 148.500 at `8`.
    The same netlist without the pins had measured 135 / 148.5 / 148.5.
- The release skill's smoke test now reads `mister.py hdmi` at `video_mode=2`.
- **The branch's fit:** SEED 4's first roll was MARGINAL (98.12 / 98.72). In the sweep **SEED 5 passed at 101.77 / 101.58**,
  clk_vid 91.65 / 87.57, with `hdmi_pll_check` PASS (`H264_hdmi480sweep_20261011_1951.rbf`, `a02caba`; the SEED
  LEDGER has the rest).
  - On .201 HDMI measured 27.000 / 74.250 / 148.500 MHz at `video_mode` 2 / 0 / 8.
  - The test chart in Native (a 720x480 raster on that HDMI mode) is 100.00 % exact against `disp_golden`; errors,
    late and fetch-late are all 0.
  - Progressive could not be scored on that HDMI mode. ascal stores a 4:3 picture at its output width (640), and
    `shot` reads ascal's buffer: the raw shot is 640 wide, so it is a different instrument from the 720-wide raster.

**Also measured the same day** (the maintainer's "480p looks jagged", PC desktop at 640x480; .201 on the
chroma core):
- The core is exact against `disp_golden`'s render of ffmpeg's decode on all three outputs (99.66-100 %,
  max 2 codes).
- .201's ini (`composite_sync=1`, `vga_scaler=0`, no saved `H264.CFG`) makes Video Output's Auto
  Interlaced. HDMI Deinterlace defaults to Weave, so motion combs on HDMI.
- A 640-wide picture on the 720-wide SD rasters is a 9:8 upscale through the 2-tap blend: 1-px lines
  alternate 1 px (peak 242) / 2 px (peak 155). Native (HDMI) is 1:1.
- The Moonlight client's GRAPHICS flag turns Anti-Twitter Auto on at 480i.
- The PC's Sunshine (KMS grab) delivered the desktop at a linear 0.59 gain (white 255 -> 150). The
  September captures reach full white, so this is new on the PC side.
- `shot --scaled` is Main's own nearest-neighbour resize, not ascal's filtered output.
- The maintainer's Analog Aspect Fit report (a scope film too tall on a wide-mode TV) became issue #11.

.201 afterwards: `_Other/H264_20261011.rbf` is the SEED 4 interface 1.1 build (the clients load the newest).
The chroma build is kept as `H264_20261010.rbf.seed2_hdmi480_black`. `video_mode=2`, the old ini as
`MiSTer.ini.bak_videomode8`.

## 48. Analog Aspect Fit, the anamorphic 16:9 fit (fix/fit-anamorphic, 2026-10-11; issue #11; ✅ MERGED (PR #14))

`analog.md` §5a. Fit filled the 720x480 raster, so a TV in its 16:9 wide mode showed every picture at
1.78:1. Now Letterbox for a 16:9 display: wider letterboxed, narrower (4:3) pillarboxed, HDMI Auto 16:9.

**On .201** (`H264_fit169_MARGINAL_20261011_2117.rbf`, SEED 5 first roll, clk_dec 100.45 / 98.98 -- above the
96.43 it runs at; synthetic x264 High clips, `h264play`), Video Output Interlaced, Analog Aspect Fit:

| clip | word 30 / 80 | the raw raster (a field) | `ar_x : ar_y` |
|---|---|---|---|
| 720x304 (2.37:1) | 720 x 360 at (0, 60) | field lines 30-209, columns 0-719 | 16 : 9 |
| 640x480 (4:3) | 540 x 480 at (90, 0) | every line, columns 90-629 | 16 : 9 |
| 848x480 | 716 x 480 at (2, 0) | every line, columns 2-717 | 16 : 9 |

Every one `disp_fit_ref.py`'s, `raster_lb` 0, errors 0, late 0. The issue's numbers: the 720x304 clip was 720 x 480
(each circle 1.33x taller than wide in wide mode); at 360 lines it is 2.37:1 on the 16:9 screen. **Control:** Progressive
with Analog Aspect Auto (Fill) on the rig's 720x480 HDMI mode as before -- 720x304 A' (720 x 304 snapped, `raster_lb` 1,
`ar` the display's 720 : 480), 640x480 filled with the exact aspect 640 : 480. Not yet: the maintainer's eye on a TV in
its wide mode.

**The swept build** (SEED 1 PASS 101.91 / 102.68, `H264_fit169sweep_20261011_2130.rbf`) on .201: the 720x304 clip under Fit at
480i 720 x 360 at (0, 60), `ar` 16 : 9, errors 0; HDMI 27.000 MHz (VIC 3) -- the PLL pin holds on this seed.

**The maintainer's round on HDMI** (an LG B7 in 16:9, .201's `video_mode=2`, 720x480): every clip letterboxed -- the
core's 16:9 made ascal a 720x405 window inside the 720x480 frame, and Main sends that mode as CEA's 16:9 VIC 3, so the
TV stretched it again. Fixed (`fit_fill`): on Main's 720x480 / 720x576 modes Fit gives the scaler the mode's own shape,
the frame filled (`H264_fit169_20261012_0103.rbf`, SEED 1 first roll PASS 102.99 / 101.87): the scaler's output is the
full 720 x 480, `ar` 720 : 480. The maintainer: 640x480 pillarboxed with bars at the sides only, the 720x304 film
"letterboxed properly", 848x480 fills the screen; the remaining crop is the TV's overscan (the signal carries all 480
lines).

**On a CRT at 480i** (.236, 2026-10-12): main's build (`H264_fit169_20261012_0103.rbf` as `_Other/H264_20261012.rbf`) and
main's clients (the player, the camera viewer, Jellyfin, Moonlight: library 1.1; the 0.15-era set kept as
`*.iface0_15`), with the three Fit clips in `video/fit-test/`. The maintainer: "looks good".

## 49. A field store's chroma at Figure E-1's field siting (fix/chroma-field, 2026-10-12; from MiSTer_UMD_Video; ✅ MERGED (PR #17))

`docs/chroma.md` §2, `harvest.md`. MiSTer_UMD_Video, building its own field chroma step, found this tree's field rule
field-centred: field p's offset is `(voff + p) / 2` of its own line pair (type 0: a quarter / three quarters), not `voff`.
Ported: `disp_reader`'s `c_vf`, the golden's field rule, UMD's `up_fv` cross-check, `check_field_oracle` (ffmpeg
`scale=interl=1` within a code at all six sitings, the old rule > 1 off); `run_disp_reader.sh --red` ALL GREEN (72
mutations, N12-N14 new). First fit SEED 1 MARGINAL 99.58 / 97.82 (`H264_chromafield_MARGINAL_20261013_0049.rbf`; the
reported 97 % ALM is packing -- `disp_reader` alone synthesises +42 ALUTs, registers equal).

**On .201**, the marginal build (above 96.43) and main's as the control arm, the same script: an interlaced MPEG-2 still
(720x480, top field first, intra, square pixels so HDMI's scaler passes the raster 1:1; a new chroma value on every chroma
row) played by the file player (0.15's field pairs, `pic_mode` 1), 480p, Deinterlace Weave; the raw raster against
`disp_golden.py`'s field model of the host's decode under both rules:

| build | Figure E-1 (this branch's rule) | field-centred (main's) |
|---|---|---|
| this branch | **98.61 % exact, 99.99 % within 2, max 3** | 1.25 % exact, max 45 |
| main (control) | 1.26 % exact, max 45 | **98.58 % exact, 99.99 % within 2, max 3** |

The same ~1.4 % residual (at most 3 codes) on both builds: the decode / conversion, not the siting.

**The swept build** (SEED 5 PASS 105.24 / 102.18, `H264_chromafieldsweep_20261013_0155.rbf`; SEEDs 2-4 missed) on .201 through
the same script: 98.61 % exact, 99.99 % within 2, max 3 (main's rule 1.25 %); HDMI 27.000 MHz. (.201 was running a DVD
harness Main left from that session's round -- Main's binary-switch trap; the raster does not depend on it.)

## 50. The 93 % ALM retime and the fitter's target (perf/retime, 2026-10-13; ✅ MERGED (PR #18))

`docs/throughput.md` §8. Every RTL branch since 93 % ALM had needed a seed sweep. Three retime rounds from the census
(recon_top's size check, mc_interp S8, recon_inter's bank count and setup fields, the header words into recon_hdr,
recon_mb's QP and DC clears, mb_intake's slot-use table, mv_pred's entry select) removed their clusters but not the
seed spread (each netlist ~93-104 MHz across seeds 5 / 1 / 2 / 4); `h264/h264_fit.sdc` -- the fitter aiming clk_dec at
~104.5 MHz -- added ~2-3 MHz on average. Pinned SEED 1, 102.28 / 102.79 PASS (`H264_retimeoc_20261013_0846.rbf`).

**On .201**, main's build the control arm, `h264play` with VUI pacing (idle = `rc_stall` over the play time at 96.43
MHz): the 10 Mbit/s Sunshine capture idle 64.8 % on both; x264 720p30 8 Mbit/s 17.5 % on both (1.21x); every picture,
errors / late 0. (.201 had a DVD harness Main resident from that session's round; the measurement does not depend on it.)

## 51. Release 1.1.0 (2026-10-14)

The first public release (the 1.0.0 draft of 2026-10-09 was never published; it predated PRs #8-#18). Release commit
`30c5f44` (`release/1.1.0`): CORE_VERSION `v1.1.0`, the manual's released version, compatibility's current-as-of, the
README; a docs sweep over `fdecab5..main` found every feature's pages current. Interface 1.1 (the 1.0 layout, frozen).

**The fit** (`--release`): SEED 1 first roll PASS, clk_dec 102.84 / 104.12, clk_vid 91.69 / 91.99, HDMI gate / lint /
canary PASS, ALM 40,943 (98 %), RAM 421, DSP 110, `H264_20261014.rbf`.

**On .201:** HDMI 27.000 MHz at `video_mode=2` (720x480); word 1 0x0101; 480p the 10 Mbit/s Sunshine capture (1,315
pictures) and x264 720p30 8 Mbit/s (600) -- errors / late 0, idle 64.8 % / 17.5 % as main's; 480i the capture, errors /
late / `disp_fetch_late` 0. Restored.
