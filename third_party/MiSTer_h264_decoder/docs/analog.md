# Phase 6 — Analog first: 480i, picture fitting, PAL

Engineering note for `roadmap.md`'s "Analog first" goal and Phase 6. Many MiSTer users want
only analog output, typically interlaced (composite / component on a 15 kHz CRT); that is
what sets this core apart (the maintainer, 2026-09-28). Status at the end (§7).

## 1. Decisions (with the maintainer, 2026-09-28)

- **Output mode: MiSTer_DVD's design.** One OSD option, **Video Output = Auto /
  Interlaced / Progressive**, and ONE raster shared by HDMI and the analog pins. Auto
  resolves from MiSTer.ini at boot like every other core: an analog TV configured
  (`vga_scaler=0` with `composite_sync` / `ypbpr` / `vga_sog`, or `direct_video`;
  `forced_scandoubler` vetoes: a 31 kHz VGA rig) → Interlaced, else Progressive. In
  Interlaced, HDMI sees the 480i raster through ascal (Bob / Weave). MiSTer_DVD tried a
  second, simultaneous raster (480i analog + 480p HDMI) and deleted it: field-reported
  "extremely wobbly" (`../MiSTer_DVD/docs/single_raster_analog.md`).
- **16:9 on a 4:3 CRT: MiSTer_DVD's "Analog Aspect" option** (Auto / Fit / Letterbox /
  Crop). HDMI keeps the scaler's aspect (`VIDEO_ARX/ARY`, `display.md` §4).
- **In scope:** an anti-twitter option (the (1, 2, 1) vertical filter on 480i / 576i fields,
  Blend's rounding, `display.md` §8); a **60.00 Hz raster variant** (game streams arrive
  at exactly 60.000 frames/s: on the 59.94 raster one picture drops or repeats every
  ~17 s, `history.md` §5); **PAL 576i / 576p at 50 Hz** -- asked "if we can decode that
  resolution at 50 Hz": 720x576 at 50 frames/s is 1,620 x 50 = **81,000 macroblocks a
  second, the same load as 720x480p60**, which is real time on the rig with ~13 % to
  spare (`history.md` §6). Yes.
- **Any aspect, portrait included** (asked 2026-09-28: casting from a phone / tablet;
  agreed): the fitter is ONE rule for every shape, not a casting feature. The decoder
  already takes a portrait picture (the bound is 1,620 macroblocks in area and 128 a side,
  `spec_hardening.md`: 480x854 is 30 x 54 = 1,620, the load of 854x480); only the display
  lacks it (it shows the top 480 lines, left-aligned). The scalers' ranges are sized to
  that bound, not to the common shapes. A Miracast sink advertises landscape modes only
  (the phone pillarboxes itself); AirPlay- and scrcpy-style mirroring send the device's
  orientation, and a rotation mid-session is a resolution change (a new SPS) that must
  reset cleanly. The HPS program asks the sender for a size inside the bound. **Not in
  scope:** rotating a portrait picture onto a sideways (tate) CRT -- a transpose, column
  reads of the DPB -- recorded as an idea only.

## 2. What MiSTer_DVD proved and this phase harvests

| DVD source | what it gives |
|---|---|
| `syncgen`'s interlaced branch (the N64-model half-line raster: 262 / 263 lines alternating, vsync mid-line on one field) | a standard 15 kHz interlaced signal; `h264/sync_gen.sv` already accepts `interlaced` and keeps the coordinate convention (`v_pos = {line, ~odd_field}`) |
| `csync_smpte.sv`, `field_polarity.vh` | composite sync with the SMPTE serrations; the field flag's polarity |
| the `VGA_F1` convention (DVD issue #41, found on HW) | F1 = 0 on the TOP field -- what ascal's Weave needs; the inverse combs a still on HDMI while the CRT looks right |
| `disp_vscale.sv`, `disp_hstretch.sv`, `aspect_ctl.sv` | Analog Aspect: Letterbox (vertical scaling) / Crop (horizontal window), made on the raster itself |
| the Video Output option's Auto rule (hps_io's `ini_*` bits, already in `sys/`) | the boot-static resolution |
| the PAL raster (576 lines, 50 Hz) | PAL output |
| `docs/field_parity.md` | keeping the content field aligned with the raster field through seeks / restarts |

## 3. What is new for H.264 (none of it in DVD)

- **Which lines a field shows.** DVD's content was interlaced video or film; here most
  content is progressive at the raster's rate. Frame stores: **field k shows the parity-k
  lines of the picture current at that field** -- 60p becomes 60i with every field from
  its own frame (the broadcast conversion); 30p / 24p frames span two or more fields and
  are woven on the CRT (full vertical detail). Field stores (a field-coded source): their
  native fields, aligned by parity (`field_parity`). The scheduler already picks a store
  per 59.94 Hz refresh; at 480i a refresh is a field.
- **Fitting any picture to the raster** (D1's "every picture fitted", `roadmap.md`): any
  picture the decoder takes (1,620 macroblocks, 128 a side, any aspect -- landscape or
  portrait, §1) scaled by ONE factor, the smaller of the width and height ratios once the
  sample aspect ratio is applied, and centred: pillarbox or letterbox borders as the
  shape needs. Both axes scale DOWN as well as up: a 9:16 picture on a 4:3 raster is 480
  lines tall and ~42 % of the width (~300 of 720 dots from 480 columns); vertically
  854 -> 480 lines is 0.56, and at 480i a field is 240 lines (3.6 : 1), which needs a
  multi-line filter or it aliases and twitters on a CRT. The scaler's worst case reads
  every source line each field: ~2.4x the display's reads today, on `ram2` --
  **measured against the display's port before the design is committed**
  (`hw_budget_and_lessons.md`: occupancy, not bandwidth). Today a picture wider than 720
  shows its left 720 columns, a taller one its top 480 lines (`history.md` §6).
- **Anti-twitter** as an option on the field lines.

## 4. The order of work (each step gated before the next)

1. **The 480i raster** (`sync_gen`'s interlaced branch + csync + F1) and the **Video Output**
   option (CONF_STR, the manual's settings page -- `docs_check.py` enforces it). Gate: the
   raster bench (`run_scaffold.sh`) extended to the interlaced timings (line counts, the
   half-line, vsync placement, F1), `--red`.
2. **Field selection** in the display path (frame stores by the raster's field; field
   stores by parity). Gate: the display benches (`run_disp_reader.sh`, the scheduler's
   Verilator bench) with interlaced cases.
3. **Picture fitting**: one fit rule for any shape (§3), the horizontal and vertical
   scalers (down and up, ranges to the 128-macroblock side), centring; **Analog Aspect**
   (Letterbox / Crop). First the `ram2` read measurement for the worst vertical case.
   Gate: benches against a model (ffmpeg's `scale` / `pad` as the oracle) spanning
   landscape, 4:3, portrait (480x854) and the extreme sides the bound allows, and a
   resolution change mid-stream (a phone rotating) resetting cleanly.
4. **Anti-twitter** option.
5. **60.00 Hz raster variant** (to measure: the PLL cannot move 27 MHz alone -- it shares
   the VCO with 90 and 96.43 MHz; a line of 857 dots gives 60.009 Hz at 27 MHz, inside a
   CRT's tolerance -- decided with a measurement, not assumed).
6. **PAL 576i / 576p** at 50 Hz (the raster; Auto from the stream's rate).

**Testing on hardware:** the rig's screenshots are the core's raster (they show an
interlaced raster's fields), not the analog pins. For the pins the maintainer routes the
MiSTer's analog output through a RetroTINK into a capture card on the workstation (offered
2026-09-28): frames of the analog signal as a real scaler reads it. The RetroTINK is itself
an instrument between the pins and the capture (it deinterlaces and scales), so field order
and twitter are judged with that in mind; a CRT stays the final reference for sync.

## 5. Step 3, the fitting design (2026-09-29; reviewed: HDMI and timing decided)

**The display size is the cropped one.** An 854x480 stream is coded 864x480 with
`frame_cropping` (10 columns off the right). Today the crop reaches `recon_out`'s
`rec_crop` and stops (`emu` leaves it open), and the HDMI aspect is computed from coded
macroblocks (`display.md` §4). Step 3 carries the crop rectangle to `disp_ctl` /
`disp_reader` with the store, and every size below is the cropped `Wc x Hc`; the exact
display aspect `sar_w Wc : sar_h Hc` (the roadmap item) is the same number.

**The raster's pixel aspect: 720 dots = 4:3** (a pixel 8:9 at 480 lines), MiSTer_DVD's
convention and what ascal does with `VIDEO_ARX/ARY` = 4:3 -- not BT.601's 704 = 4:3
(10:11). One convention for HDMI and analog; the 2 % differs from a broadcast CRT's
nominal geometry, well inside any CRT's overscan.

**One fit rule.** In raster pixels, the picture is `Ww = Wc * (sar_w / sar_h) * (9 / 8)`
wide and `Hc` tall (the 9/8 undoes the raster's 8:9 pixel); the raster is 720 x 480 (a
field 240 of those lines). Per Analog Aspect:
- **Letterbox** (and Auto): `s = min(720 / Ww, 480 / Hc)` -- the whole picture, bars on the
  short axis (pillarbox for 4:3-and-narrower, portrait; letterbox for wider);
- **Crop**: `s = max(720 / Ww, 480 / Hc)` -- the raster filled, the long axis cut;
- **Fit**: the anamorphic 16:9 fit (§5a, issue #11; until 2026-10-11 `720 / Ww` and `480 / Hc`
  separately -- the raster filled, the geometry stretched: MiSTer_DVD's Fit) -- Letterbox's
  rule for the 16:9 a TV in its wide mode shows the raster at.
The output rectangle `(s Ww) x (s Hc)` is centred, odd remainders to the right / bottom.
The step for each axis, source pixels per output pixel in fixed point, and the first
output's phase are computed ONCE per shown store by a restoring divider (MiSTer_DVD's
`disp_hstretch` pattern: no per-pixel divide; no `function automatic` or `N'()` casts --
Quartus 17). The pickup (line 500) leaves ~20,000 cycles before the next field: ample. A
store of a new size (a rotating phone's new SPS) gets its own numbers at its pickup: no
mode, no restart.

**At 480i, field line `i` of parity `p` samples source row `(2i + p + 1/2) * Hc / Ho - 1/2`**
(`Ho` the output height the fit gives, in frame lines; centre-aligned like ffmpeg's
`scale`): the frame's formula at frame line `2i + p`, so each field takes alternate rows of
the one resample, 60p becomes 60i with every field from its own frame, as today, and step
4's anti-twitter filter shares this one definition. The decimation is the Progressive one
(`sy`, not the field's `2 sy`): the raster is 480 lines over its two fields, and deciding it
per field would average every line pair of a native 480-line picture -- half its vertical
detail gone, an anti-twitter filter nobody chose (found on the first fixtures, 2026-09-29).
The fetch takes the two rows the next line needs, so at 480i the other field's rows are
not fetched.

**The filter: integer box pre-decimation at fetch, then a 2-tap blend.** A 2-tap blend
alone aliases past 2 : 1, and the range here is far past it: portrait at 480i is 3.6 : 1
vertically, the spec's extreme side (12 x 128 macroblocks, 192 x 2,048: 1,536 <= 1,620) 4.3 :
1. So:
- vertically, the fetch engine sums `d = floor(step)` consecutive source rows into one
  line-buffer row (a read-modify-write per word; the box's weights exact: `d` a power of
  two where the step allows, else a reciprocal multiply once per word), and the read-out
  blends the two stored rows that straddle the exact position;
- horizontally, the same at the line-buffer write: `d_h` source samples summed into one,
  so a stored line is at most 1,024 samples -- **today's line buffers (4 lines x 1,024
  luma) hold every legal width** (2,048 = 128 macroblocks at `d_h` = 2) with no M10K added.
  Today a picture wider than 1,024 would be cut at the buffer: the spec's maximum side is
  now reached by decimation, not truncated.
- up-scaling (a 640x480 or 352x240 picture) is the 2-tap blend alone.
The constraint that shaped this is not bandwidth: it is **source rows per raster line**
against a fetch engine that requested ONE line two ahead (up to ~8.5 rows a line at 480i;
the P6 reader commands decimated rows into tagged slots instead, `display.md` §3).
The numbers: the worst legal case reads ~640 KB a field; a portrait 480x854 ~2.4x today's
reads -- on `ram2`, the display's own port, where MiSTer_DVD measured the display's traffic
costing the decoder nothing (`hw_budget_and_lessons.md` §2). The fetch engine's per-line
time budget: a 480i line is 63.5 us = 5,720 `clk_mem` cycles; the engine issues a plane
row's bursts back to back (up to 256 beats in flight) and waits once per plane row, so a
row costs ~(latency ~40 + its words) per plane -- the worst case (8.5 rows of 192 samples,
three planes) ~1,500 cycles (26 %), portrait (3.6 rows of 480) ~900. The bench's memory
model has random latency (it polices the protocol, it does not model the rig), so the
figure is arithmetic, confirmed on the rig with the feature.

**The arithmetic, exactly** (the RTL, `tools/disp_fit_ref.py` and the bench share it):
- `Wc = 16 W - 2 (left + right)`, `Hc = 16 HF - (cuy4 ? 4 : 2)(top + bottom)`. A crop that
  leaves nothing (either size <= 0; the parser checks each offset only against 1,023) is
  **ignored and flagged** (`disp_flags` bit, the status block): the coded picture is shown
  whole, never a garbage rectangle.
- SAR: `aspect_vui`'s resolved `sar_w : sar_h`; unspecified or reserved -> 1 : 1.
- Letterbox's test `3 Wc sar_w >= 4 Hc sar_h` (the picture at least as wide as 4:3):
  `ow = 720, oh = round(640 Hc sar_h / (Wc sar_w))`; else `oh = 480, ow = round(540 Wc
  sar_w / (Hc sar_h))`. Crop the other branch; Fit §5a's. Each of `ow, oh` at least
  2. **The native snap:** under Letterbox / Crop / Fit, a fit within 3.5 % of the picture's own
  size on both axes (`1000 |ow - Wc| <= 35 Wc`, alike for `oh`) is shown 1:1 -- BT.601's
  720x480 at 10:11 against the raster's 8:9 is 2 %: a 480 -> 469 rescale would soften
  every line on a CRT to correct what overscan hides. `ox0 = (720 - ow) >> 1`
  (arithmetic: negative under Crop), `oy0` alike.
- Steps in Q.16: `sx = Wc / ow`, `sy = Hc / oh`; at 480i the field's row step is `2 sy`.
- Decimation, powers of two: `dh = pow2floor(sx)` capped at 8, and at least 2 when
  `16 W > 1,024` (the stored line <= 1,024 samples); `dv = pow2floor(sy)` capped at 8, and at 4 when `W > 80` (the fetch budget: `2 dv` rows of `3 W`
  words a line <= ~4,000 cycles). The whole CODED width is fetched and decimated from
  column 0 (words stay aligned); the crop's `left` / `top` are phase offsets.
- The residual steps `sx / dh`, `sy / dv` are < 2 below the caps -- the 2-tap blend is
  sound there; past the caps (an absurd SAR, e.g. 255 : 1) the residual exceeds 2 and the
  blend aliases -- a quality limit, never a truncation (every row the fit needs is
  fetched).
- Positions: output pixel `j` of the rectangle samples source `x = left_px + (j + 1/2)
  sx - 1/2`, in decimated units `(x - (dh - 1) / 2) / dh`; rows alike (480i: frame line
  `2i + p`). Edges clamp (replicate), as the mirror does today.
- Chroma: box-decimated by the SAME `dh` / `dv` in chroma samples, so the 4:2:0 ratio holds
  after decimation (a stored chroma row is half the stored luma row: the 512-sample chroma
  slots hold every legal width -- `dh / 2` would overflow them at 2,048); read NEAREST: the
  luma tap `k + (w >= 128)`, `>> 1` (today's `x >> 1` siting generalised), rows alike.
- The samples: a box is `(sum + 2^(s-1)) >> s` over its `dh x dv` samples, `s = dh_l2 +
  dv_l2` (`s = 0`: the sample itself); the blend `(a (256 - w) + b w + 128) >> 8`,
  horizontally on rows `k` and `k + 1`, then vertically. The coded size is a multiple of
  16 and the factors at most 8, so no box straddles a picture edge. Identity (`w = 0`,
  `s = 0`) is today's sample exactly.
- The deinterlacer's kernels (Bob / Blend on a field store, `display.md` §8) apply iff
  Progressive and the fit is the identity on both axes (steps 1.0, no decimation: 720x480,
  and the snapped 704x480 at an offset); otherwise the rows are resampled woven. Known
  limit: a field-coded picture that is scaled shows woven (combing on motion) -- streaming
  sources are progressive.
- Fetch-late is counted (a row the read-out needs not held when its line begins: past the
  caps a line's rows can exceed the fetch budget), reported with `crop_bad` / `clamp` in
  step 3e's status word -- visible, never silent.
- Letterbox / pillarbox bars are black (Y 16, C 128 -> RGB 0).

**Today's reader, what changes:** the line index is 9 bits (pictures up to 512 lines
addressable -- portrait's 854 need 11, the spec's 2,048 too), a line slot 128 words (1,024
samples), one source row fetched per display line.

**HDMI (Progressive): fill + the exact aspect** (decided 2026-09-29, the maintainer).
The raster is filled (Fit's mapping then; since issue #11 `disp_fit`'s mode 3, Fill) and `VIDEO_ARX/ARY` carry the picture's exact
display aspect `sar_w Wc : sar_h Hc`, reduced to fit 13 bits (sar 16:11 x 720 exceeds
8,191), so ascal restores the geometry at the raster's full resolution -- portrait as
9 : 16. ARX < ARY is ordinary for Main (vertical arcade cores report 3 : 4); confirmed on
the rig with the feature regardless. The rejected option: the analog fit on HDMI too (one
path, but a portrait picture would use ~40 % of the raster's width). In Interlaced both
outputs see the analog fit (one raster), `VIDEO_ARX/ARY` the raster's 4:3.

**Analog Aspect in Progressive too** (decided 2026-09-29, the maintainer; found on the
RetroTINK: in Progressive the analog pins carry the FILLED raster, so a 31 kHz analog display
-- a VGA CRT, an external scaler -- showed a portrait picture stretched to 4:3, the exact
aspect reaching HDMI only). The option is shown in both modes; set explicitly (Letterbox /
Crop / Fit) it fits the picture inside the 4:3 raster in Progressive as well and HDMI is
told 4:3 (`raster_fitted`; 16:9 under Fit since §5a); its Auto keeps Letterbox at 480i and fill + the exact aspect in
Progressive. check_emu_wiring pins `ar_exact` to `raster_fitted` (W48).

**Timing:** closed once for the whole phase (decided 2026-09-29): step 3 changes CONF_STR,
which re-rolls the seed anyway; step 2's MARGINAL build (clk_dec 100.22 / 98.85, above the
96.43 it runs at) serves the rig meanwhile.

**The gate.** Geometry against ffmpeg `scale` / `pad` (edge positions, bar widths, centring
within a pixel); sample values against a model written from the formulas above (2-tap +
box will not bit-match ffmpeg's bicubic). Cases: 640x480, 854x480 (cropped), 720x404, a
352x240 up-scale, 480x854, a 192x2048-class extreme, a mid-stream size change. Each
Analog Aspect mode. `--red` as always.

**Lands with it:** Analog Aspect in CONF_STR (once; `settings.md`, `docs_check`), the
manual's compatibility row, the roadmap's exact-aspect item.

### 5a. Fit, the anamorphic 16:9 fit (issue #11, decided 2026-10-11 with the maintainer; ✅ MERGED (PR #14), ✅ HW-CONFIRMED on HDMI 2026-10-12)

**Found** (issue #11, on the rig with a 720x304 2.37:1 clip): Fit stretched every picture to the
whole 720 x 480 raster, and a TV in its 16:9 (wide) mode stretches that to 16:9 -- so every
picture came out at 1.78:1: a scope film 25 % too tall, a 4:3 picture stretched wide. On a DVD
(MiSTer_DVD's Fit) the anamorphic frame IS 16:9 and a scope film is letterboxed inside it, so
filling the raster was right there; streams and files carry a scope film at its own shape.

**The rule:** Letterbox, computed for a 16:9 display, then stretched to the raster (the raster's
720 dots span the screen's width whatever its lines, so one rule serves 480 and 576):
- wider than 16:9 (`9 A > 16 B`, `A = Wc sar_w`, `B = Hc sar_h`): `ow = 720`, `oh = round(rh x
  16 B / 9 A)` -- §3a of `hdmi_raster.md`'s quotient with a 16 x 9 "display": `P = 16 B`, `Q = 9 A`
  shifted down together until `Q` fits 28 bits, `oh = round(rh P / Q)`. The 720x304 clip -> 720 x
  360 (576 lines: 432). `lb` stays 0: the raster is the analog one, not shown at a display's shape.
- 16:9 or narrower: `oh = rh`, `ow = round(405 A / B)` (`720 x 9/16`, Letterbox's 540 being
  `720 x 3/4`): 4:3 -> 540, portrait 480x854 -> 228; exactly 16:9 -> 720 (filled, as before).
- **4:3 pillarboxed** (the maintainer's choice: the alternative was keeping the stretch for
  narrower pictures; pillarboxing is what a wide-mode TV needs to show it undistorted).
- The native snap applies as under Letterbox (both axes within 3.5 %): an anamorphic 704x480 at
  40:33 (exactly 16:9) is shown 1:1, 8 columns in.
- **HDMI's Auto aspect is 16:9 under Fit** (the maintainer's choice; `emu`'s `fit_169`,
  `check_emu_wiring` pins it, `run_scaffold.sh` W111): HDMI shows the raster as the wide-mode TV
  does, so a Fit picture is undistorted on HDMI too (before: 4:3, which suited only the old stretch).
  **Except on Main's SD HDMI modes**, 720x480 and 720x576: Main sends them as CEA's 16:9 VIC 3 / 18
  (the AVI frame's 16:9 bit set; Main's `vmodes` table), so the TV stretches the frame to 16:9 itself,
  while ascal treats it as square pixels -- 16:9 there gave a 720x405 window, letterboxed and too wide
  on the TV (found on .201 with the maintainer, `history.md` §48). There Auto gives the scaler the
  mode's own shape (`fit_fill`: `HDMI_WIDTH : HDMI_HEIGHT`, the frame filled), and the TV's stretch does
  what a wide-mode analog TV does (`check_emu_wiring` `fit_fill`, W112 / W113). Forced 4:3 / 16:9 are
  left as they are.

**What did not change:** Fill (mode 3: HDMI in Progressive with Analog Aspect Auto) keeps the
raster filled when the picture is not wider than the display, and A' when it is; with no display
(`disp_w` 0) it is the old Fit exactly. The benches that meant "the raster filled" (the reader's
identity arms, `run_vid_equiv.sh`'s cases, `disp_golden.py`'s fitted cases) now drive mode 3 with no
display -- their goldens are byte-identical to main's. No interface change: word 30 already
reports the fit's rectangle.

**Gates:** `run_disp_fit.sh --red` (the model vs ffmpeg on an 854x480 / 1024x576 square canvas for
Fit; the RTL vs the model on 16,399 vectors -- Fit letterboxed 2,180, pillarboxed 1,770, filled 44,
snapped 6; F33-F38 Fit's mutations, each by its own arm; the bench checks `lb` before the flags now,
since an `lb` defect moves the snap rule); `run_disp_reader.sh` (`fit_scope` 720x304 at 480i, `fit_43`
640x480 pillarboxed); `run_vid_equiv.sh`; `run_scaffold.sh --red` (W111).

## 6. Known limits carried in

- ascal cannot blend (`display.md` §1): in Interlaced, HDMI is Bob or Weave.
- The in-core deinterlacer (Weave / Bob / Blend) applies to the progressive raster; in
  Interlaced the analog pins get the fields themselves.

## 7. Status

- [x] 1. The 480i raster + Video Output (2026-09-28): `sync_gen`'s interlaced branch
      (DVD's N64 model; `sync_gen_il_tb` measures it, S3..S9), `csync_smpte.sv` + its gate
      (`run_csync_field.sh`: DVD's hardware-proven numbers reproduced on our raster, 5 RED
      arms), emu (Video Output with the latched Auto, CE_PIXEL / VGA_F1 / VGA_CS, the H0 /
      h0 menu swap to HDMI Bob / Weave; check_emu_wiring W38..W43; numbered W30..W35 at
      first, clashing with the ring's arms, whose verdicts the runner then overwrote --
      renumbered in step 2). A restart ticking twice (a spurious refresh at a mode switch)
      found by the display bench and fixed (S9).
- [x] 2. Field selection (✅ MERGED PR fj#8, ✅ HW-CONFIRMED) -- `disp_reader` (the pixel column, the kernel off
      at 480i, the fetch count at each field's first line; [il] arms, I1 / I2), `disp_ctl`
      (a refresh is a field; its events placed on the model's 450,450-cycle grid: the long
      field's at their progressive offsets, the short field's 858 cycles earlier in the
      field -- `tools/disp_sched_ref.py` holds unchanged), `run_disp_sched.sh` every
      scenario again at 480i; emu wires both `.il` to `interlaced_eff` (W44 / W45). The
      bench counts refreshes from where `disp_ctl` aligns (a TOP field's first dot;
      counting from a bottom field put it one field ahead: all 20 scenarios RED on the
      first run, a bench bug). I2 (a top-field-only fetch count) is scored on `tff`: a
      field pair changes parity every field; on film32 the changes land 2-3 fields apart
      and a top-only count still sees each (equivalent there). Known limit (until
      2026-10-05): a FIELD-coded source's field order against the raster's was not corrected
      (DVD's field-parity corrector; streams were progressive). **Measured 2026-10-05 (`history.md` §35): at 576i an
      interlaced MPEG-2's woven pairs (interface 0.15, from the ARM) played each pair's later field first through a whole
      clip (the RetroTINK on Bob: +3 / -1 fields); the parity of the lines was right. Fixed the same day
      (`feature/arm-codecs`): UMD's V6 ported (its PR fj#37, HW-confirmed on a CRT there; `harvest.md`) -- `disp_ctl`
      holds a due field PAIR one refresh when the refresh it would be picked up for is not its first field's (refresh 0
      the top field, the pickup in refresh k deciding refresh k + 1), unless it is late (a backlog catches up, a head
      waits once at most); frames and single fields never; nothing on a progressive raster. This tree adds: the hold's
      next pickup not counted late nor its store's cadence judged, and word 85's `disp_fhold`. Not ported: UMD's pause
      sampled at top fields (this pause gates the STC cycle by cycle and also feeds `aud_play`) -- after a pause of an
      odd field count, as after a 3-field frame or a single field, the timeline sits a field off the raster and EVERY
      pair is held: still in order, one field behind the audio (16.7 / 20 ms), `disp_fhold` climbing by one a pair; a
      frame or single field after such a pair cuts its second field (the cut keeps the lag bounded: a two-field minimum
      was modelled and ratchets -- pairs never catch up, and two refreshes behind, every pair was taken late, off its
      field: `unpaired` at 480i). Nor UMD's (2): a single field (and a paused pair) at 480i shows the other raster
      field's lines stale, not rebuilt. Gates: `tools/disp_sched_ref.py --il` (the rule, from the raster's convention),
      `run_disp_sched.sh` every scenario at 480i against it (NAME.il), the bench's `[field]` arm against `sync_gen`'s
      v_pos (not the model), F1-F9.**
      On the rig 2026-09-29 (`history.md` §7): 60p and 24p at 480i through the ring, every
      picture, errors / late / cadence 0. **The analog pins (RGBS -> RetroTINK -> capture):
      480i measured by the RetroTINK (1716x525i, 15.73 kHz / 59.94 Hz), Auto -> Interlaced
      from the ini, the field order measured correct (one-line markers 101 / 99 lines
      apart). HDMI Bob confirmed on a capture of the MiSTer's HDMI (comb energy halved
      against Weave, the control arm).** Open: composite / S-Video, a CRT.
- [x] 3. Picture fitting (any aspect, portrait included; decided 2026-09-28) + Analog Aspect --
      ✅ MERGED (PR fj#8), ✅ HW-CONFIRMED (2026-09-29): (a) the crop carried to the display (`recon_top` + the
      vertical unit bit); (b) `disp_fit` + `tools/disp_fit_ref.py` (its rectangle = ffmpeg's
      `scale` within a pixel; `run_disp_fit.sh`, 2,400 vectors, F1-F10); `aspect_vui`'s
      resolved SAR ([sar], A6); (c) / (d) `disp_reader` rewritten: decimated rows into four
      tagged slots, a command of at most two rows a line, the box sum in an accumulator line,
      the 2-tap blends, chroma nearest, LAT 5 (emu's delays, check_emu_wiring, the scaffold's
      anchors follow); `run_disp_reader.sh`: every old case bit-exact at the identity, nine
      fitted pictures pixel-exact against the render golden, R1-R10 (R8 equivalent); the
      scheduler's bench ties the identity; the first-refresh fetch change counted only with a
      picture shown (a `bff` over-count found). (e) Analog Aspect (Auto / Fit / Letterbox /
      Crop, 480i only, latched once a refresh; W46), HDMI's exact aspect in Progressive,
      the interface 0.2 (word 30: the fit's rectangle, snap / crop-invalid / clamp,
      `disp_fetch_late`). Found on the way: deciding dv per FIELD at 480i would have halved
      a native picture's vertical detail (dv follows sy). **On the rig 2026-09-29
      (`history.md` §8): every shape in Progressive (portrait as 9:16 on HDMI) and at 480i
      (Letterbox, Crop, Fit, the snap), errors / late / fetch-late 0.** Open: the analog pins
      with fitted pictures on the RetroTINK / a CRT (the 480i signal itself is proven, §7 of
      history), the 12-bit aspect fix's own fit and a 10:11 clip in Progressive.
- [x] 4. Anti-twitter (§9) -- ✅ MERGED (PR fj#9), ✅ HW-CONFIRMED 2026-09-29 (the (1, 2, 1)
      through the analog pins; ON A CRT (S-Video, 480i): "very clearly an improvement in all
      the test cases, controls unaffected" -- `history.md` §9): the sliding luma
      boxes (`disp_fit` publishes `slide`, capped dv; `disp_reader` fetches 2 dv luma rows,
      the position half a row up, chroma at the second tap), `h0O[10],Anti-Twitter,Off,On`
      latched with Analog Aspect, frame stores at 480i / 576i (`fit_at`; W49 / W50).
      `tools/disp_golden.py` renders it from §9 and checks the identity case against
      ffmpeg's `interlace` lowpass (within one code: the design rounds twice);
      `run_disp_reader.sh`: six 480i anti-twitter pictures pixel-exact (720x480 the (1, 2, 1),
      854x480, 480x854, 192x2048 at dv 4, 2048x192 at the W > 40 cap, 352x240 up), T1-T6
      each caught by its own arm (T3, chroma's tap, only on 480x854: on 854x480 the step
      4/3 puts every line weighted below a half on an even row, where both taps share a
      chroma row); PAL coverage includes 576i anti-twitter and the paired 1280x534 Area-only
      control / Anti-Twitter case; `run_disp_fit.sh`: 3,600 vectors (480i with and without), F11-F13.
      On the rig (`history.md` §9): applied (status `anti_twitter` 1), one-line vertical
      detail in the woven screenshot down ~40 %; the look on a 15 kHz display is open.
- [x] 5. 60.00 Hz variant (§10) -- ✅ MERGED (PR fj#9), ✅ HW-CONFIRMED 2026-09-29 (the RetroTINK:
      1716x525i, V 60.00 Hz, stable; `history.md` §9): `sync_gen`'s `std` (1 =
      60.00: 450,000 dots, 75 long lines, every hsync edge within a dot of the uniform grid;
      interlaced fields 450,858 / 449,142, vsync edges 450,000 +- 2 apart; S10 / S11);
      `disp_ctl`'s refresh grid from a counter (RF per standard, the old (line, dot) events'
      cycles at 59.94), R_Q3 / half per standard; Refresh Rate (`O[12:11]`, Auto from the
      VUI rate, `std_auto_l`; W51-W53); the model per standard (NAME@STD: p60, p60ll, p24,
      film32@1, llburst@1), the rate class scored. On the rig (`history.md` §9, at 480i):
      Auto -> 60.00 Hz on a 60.000 stream, 59.992 Hz measured against 59.948 forced (the
      heartbeat over 60 s on the ARM's clock); low latency: 0 steady skips at 60.00 against
      1-2+ at 59.94. Progressive 60.00 on the refit: 60.003 Hz (59.946 forced 59.94). Open: the
      RetroTINK's lock: done (V 60.00 Hz); Main's reported rate not read (the heartbeat and the
      RetroTINK stand in).
- [x] 6. PAL (§10) -- ✅ MERGED (PR fj#9), ✅ HW-CONFIRMED 2026-09-29 (the RetroTINK: 1728x625i,
      V 50.00 Hz, detected 576i; field order correct; `history.md` §9): `sync_gen` std 2 (CEA-861 576p / 576i,
      S12-S14); `csync_smpte`'s PAL block passes every `run_csync_field.sh` gate on the 576i
      raster (both fields the same waveform, both separator models 312.5 lines apart every
      field); `disp_fit` / `disp_reader` on 576 lines (the fit vs ffmpeg on a 768x576
      square raster; F14 / F15; three pictures pixel-exact, P1 / P2); the scheduler on 50
      Hz (p25, p50, i25, film32@2, llsteady@2; G1-G5). `run_disp_sched.sh --red`: 60 runs
      (30 scenarios x progressive / interlaced) identical to the model, D1-D17, I2, G1-G5
      each caught by its own arm; `run_disp_reader.sh --red` ALL GREEN (31 arms, 45 mutations). Interface 0.3 (word 30's raster
      report). Hardware clips: `tools/p6/make_clips.sh` (p60x, pal50, pal25, twitter).
      On the rig (`history.md` §9): 576i and 576p, 50.02 Hz, 50p / 25p paced exactly (late /
      starve / cadence 0), the 720x576 12:11 picture snapped, HDMI told 12:11 in Progressive.
      576i's field order measured correct on the RetroTINK (a PAL CRT stays open).
      Known: `field_polarity.vh` is NTSC-measured -- 576i's field order is confirmed on the
      RetroTINK or it is the open risk that file records; csync's half-line stays 858 on the
      60.00 Hz raster's 1,714-dot lines (a 37 ns asymmetry of the equalizing pulses).
- [ ] The CRT round (the maintainer's CRT).

## 8. Part 2: decisions (with the maintainer, 2026-09-29)

- **Anti-twitter: Off by default** (`h0`, beside HDMI Deinterlace:
  the menu never offers what the raster cannot do). Frame-coded pictures only: a
  480i / 576i field-coded source's fields are interlaced content already, and filtering across them
  would be Blend deinterlacing, not anti-twitter.
- **One option, `Refresh Rate: Auto / 59.94 Hz / 60 Hz / 50 Hz`.** 50 Hz is the 625-line
  (576 active) PAL raster, 576i or 576p by Video Output. **Auto follows the stream's VUI
  rate**, latched at each stream's first picture (while no picture of it is shown) and
  held while it plays: a tick of exactly 60, 30, 24 or 120 frames/s -> 60.00 Hz; 50, 25 or
  100 -> 50 Hz; anything else, or no VUI timing -> 59.94 Hz. Between streams the last
  choice holds (no resync to 59.94 in a gap). A stock Sunshine stream carries
  `num_units_in_tick` 1,000 / `time_scale` 120,000 (60.000 frames/s, traced on the
  captures), so a Moonlight session lands on 60.00 Hz.
- **60.00 Hz exactly, by line length**: one line in seven is one dot longer (857 / 858
  dots; 1,714 / 1,716 at 480i), 450,000 dots a frame = 60.000 Hz on the 27 MHz clock
  (fixed: it shares the PLL's VCO with clk_mem and clk_dec). Rejected: every line 857
  dots, 60.0100 Hz -- no jitter, but a picture repeated every ~100 s on a 60.000 stream.
  The hsync edges sit within one dot (37 ns) of a uniform grid; confirmed on the RetroTINK
  and with Main's reported rate before merge.
- **The status block reports the raster** (interface 0.3): word 30's free bits -- the
  rate, interlaced, whether Auto chose it, anti-twitter applied. Additive, no word moved.

## 9. Step 4, anti-twitter (the design)

**Why a sliding box.** A (1, 2, 1) on the OUTPUT frame lines needs the resample at three
lines per field line (the frame lines above and below), up to five source rows a line on a
scaled picture, and more line slots than the four the reader has: the current line holds
three, the next line's two new rows need two more. Instead the filter moves INTO the fetch
and the vertical position, where the reader already has the machinery:

- **The rows fetched are sliding boxes.** Under anti-twitter a decimated luma row k is the
  box of `2 dv` source rows `[k dv, k dv + 2 dv)` (not `dv`): each row overlaps the next by
  half. The fetch engine sums `2 dv` rows instead of `dv` (the same accumulator: `dh x 2 dv
  <= 64` samples under the cap below, 14 bits), rounded `>> (dh_l2 + dv_l2 + 1)`.
- **The position moves half a decimated row up.** Row k's box is centred at decimated
  position `k + 1/2`, so the vertical position is `u' = u - 1/2`: in the reader's formula
  the offset `(dv - 1) / 2` becomes `(2 dv - 1) / 2` (`(pos - (2 dv - 1) << 15) >> dv_l2`).
  The 2-tap blend between rows k and k + 1 of `u'` is then a box of 2 dv rows convolved
  with the triangle: symmetric, shift-invariant, the SAME kernel in both fields.
- **At the identity it is the (1, 2, 1).** A native 480-line picture (Fit, 720x480):
  field line L has `u' = L - 1/2`: sliding rows L - 1 and L, weight 1/2 --
  `((r[L-1] + r[L]) / 2 + (r[L] + r[L+1]) / 2) / 2 = (r[L-1] + 2 r[L] + r[L+1]) / 4`.
  The rounding is two steps,
  `((a + b + 1) >> 1 + (b + d + 1) >> 1 + 1) >> 1`, within one code of Blend's `(a + 2b + d
  + 1) >> 2` (checked against ffmpeg's `interlace` lowpass in `tools/disp_golden.py`).
- **Rows per line are unchanged**: a field line reads two decimated rows (k, k + 1) and
  the next field line two more -- four slots hold them, one command of at most two rows a
  line, as without the filter. The traffic doubles per row (2 dv source rows).
- **Chroma is not filtered and keeps its siting.** Chroma rows are fetched as before (the
  box of `dv` rows): the nearest decimated row to the UNSHIFTED position u is `round(k' +
  w + 1/2) = k' + 1`, the second tap of `u'`, so chroma is read from the second tap's slot.
  4:2:0 chroma already spans two frame lines (a chroma row is shared by both fields'
  lines at the identity), so it does not twitter.
- **Edges clamp.** The last sliding box that stays inside the picture is `kmax - 1` (`kmax`
  = the crop's last decimated row): the taps clamp to `[kmin, kmax - 1]` (the box at
  `kmax - 1` ends at `(kmax + 1) dv <= 16 HF`: never past the plane). The top line becomes
  `(r0 + r1) / 2` rather than a mirror's `(3 r0 + r1) / 4`: a quarter of a line at the
  picture's edge.
- **The fetch budget's cap (disp_fit).** A 480i line is 5,720 clk_mem cycles; a line's
  fetch is two decimated rows, now `2 dv` luma rows (`2W` words) + `dv` rows of each chroma
  plane (`W` words), with a wait of ~40 cycles a plane row: about `dv (12 W + 320)` cycles.
  Under anti-twitter `dv <= 4`, and `dv <= 2` when `W > 40` (W 128 at dv 2: ~3,700; W 40 at
  dv 4: ~3,200). The cap binds only on absurd SARs (sy >= 4 with W > 40); past it the
  residual step exceeds 2 and the blend aliases -- a quality limit, never a truncation.
- **Where it applies:** 480i (576i), a frame store, the option on. Published with the
  fit's set by `disp_fit` (`slide`, latched with the rest: a reader never sees half a set);
  the option is latched once a refresh with Analog Aspect, so a menu change never splits a
  picture. An up-scaled picture (sy < 1) is filtered too: its rows are already spread over
  more than a line, so the filter only softens it slightly (no predicate added for it).

## 10. Steps 5 and 6, the raster standards (the design)

**Three standards, one enum** `std`: 0 = 59.94 Hz (525 lines), 1 = 60.00 Hz (525 lines),
2 = 50 Hz (625 lines). With Video Output, six rasters, all on the 27 MHz clock:

| std | progressive | interlaced (pixel repetition, a field is a refresh) |
|---|---|---|
| 59.94 | 858 x 525 (720 + 16 / 62 / 60; 480 + 9 / 6 / 30) = 450,450 | 1,716 x 262 / 263, 240 active a field, vsync [244, 247), half-line 858 = 900,900 a frame |
| 60.00 | lines of 857, one in seven (frame line `% 7 == 0`: 75) of 858 = 450,000 | lines of 1,714, the same one in seven 1,716 (the frame line count runs over both fields) = 900,000 |
| 50 | 864 x 625 (720 + 12 / 64 / 68; 576 + 5 / 5 / 39) = 540,000 | 1,728 x 312 / 313, 288 active, vsync [292, 295), half-line 864 = 1,080,000 |

The 50 Hz values are MiSTer_DVD's (CEA-861 576p / 576i; hsync 732..795, vsync 581..586
progressive), its csync_smpte PAL arm (`VSS_P` 292 = the per-field vsync) already carried.
The 60.00 Hz short line ends one dot earlier (the back porch's last dot): hsync -> active
stays fixed within a line; the long lines are spread by the frame line count so no hsync
edge is more than a dot from a uniform grid, and the fields are 450,858 / 449,142 dots (the
ideal 450,000 +- 857.14: vsync 262.5 lines apart within a dot). The vsync sample dot and
csync's half-line stay 858 (a dot off the 1,714-dot line's half: 37 ns).

**Which field is SMPTE field 1** stays `FIELD1_VPOS` for 625 lines too -- the open risk
`field_polarity.vh` records (NTSC-measured, PAL never confirmed on HW). If the RetroTINK
reports the fields swapped at 576i, the constant becomes per-standard in all its
consumers; it is never flipped globally.

**disp_ctl: the refresh grid from a counter, not raster positions.** The model
(`tools/disp_sched_ref.py`) already states each event as an absolute time, `P = RF k +
offset` from the first top-field / frame start after alignment. The events now come from a
refresh-phase counter (0 .. RF - 1, restarted at alignment) instead of (line, dot) pairs --
at 59.94 the same cycles exactly (the 480i placement of §7 step 2 was chosen to land on the
grid), and for any raster whose frame is a whole number of refreshes:

| std | RF (a refresh) | R_Q3 (eighth-ticks) | HALF (ticks) | skip / eval / pickup offsets |
|---|---|---|---|---|
| 59.94 | 450,450 (1,501.5 ticks) | 12,012 | 750 | 490 x 858, 499 x 858, 500 x 858 |
| 60.00 | 450,000 (1,500) | 12,000 | 750 | the same cycles (line ~500 of 857.14 dots) |
| 50 | 540,000 (1,800) | 14,400 | 900 | 590 x 864, 599 x 864, 600 x 864 |

Each pickup is in vertical blanking and before the next refresh's first line is commanded
(progressive line 524 / 624; a field's last line). A change of `std` restarts the raster
and realigns disp_ctl, as a change of `il` does.

**The reader and the fit.** `disp_reader`: the frame wrap (524 / 624), a field's last line
(261 / 262; 311 / 312) and the active lines (480 / 576). `disp_fit` on 576 lines: the
raster is 720 x 576 at 4:3 (a pixel 16:15), so the picture is `Wc sar (15/16)` raster
pixels wide: wide -> `oh = round(768 B / A)`; narrow -> `oh = 576, ow = round(540 A / B)`
(540 = 720 x 3/4 on either raster); Fit 720 x 576; `oy0 = (576 - oh) >> 1`. emu latches
Analog Aspect and anti-twitter at the pickup's line (500 / 600; a field's 250 / 300).

**Auto (emu).** `disp_ctl` classifies each prepared head's VUI tick (`field_q3`): 3,000,
6,000, 12,000 or 15,000 eighth-ticks (120, 60, 30, 24 frames/s) -> 60.00; 3,600, 7,200 or
14,400 (100, 50, 25) -> 50; else, or no VUI timing (flag 1/2) -> 59.94. emu latches the
class while no picture of the stream is shown (`sh_valid` 0); the raster switches before
the first pickup (disp_ctl realigns; the prepared head waits one refresh).

**HDMI.** The raster reaches HDMI through ascal: 50 Hz content at a 60 Hz HDMI mode
judders 5:6 unless MiSTer.ini's `vsync_adjust` locks the output to the core (the manual's
settings and compatibility pages say so).

## 11. Auto -> Native (HDMI), and the Downscale Filter (2026-10-04, with the maintainer)

**The report.** A Moonlight stream at 854x480 looked pixelated on HDMI, better in Native (HDMI)
than in Progressive; 1280x720p30 looked great in Native and much worse in Progressive (Bicubic on in
Main's scaler both times). Measured by simulation (the chain modelled stage by stage, a synthetic
desktop of text and thin lines; the scripts stayed in the session's scratchpad):
- **The host (not this core):** Sunshine's CUDA path (`src/platform/linux/cuda.cu`, RGBA_to_NV12)
  scales with ONE bilinear tap per output pixel at `idX * scale`: at 2560x1440 -> 854x480 (3:1) four
  of every nine source pixels are read. Thin lines break up, text stairs. An exact 2:1 (1280x720 from
  1440p) makes that tap a true 2x2 box. Advice only: the core cannot repair it.
- **Progressive's fit (this core):** at a step between 1 and 2 the fit is the plain 2-tap blend
  (`dh = pow2floor(s)` is 1, no box), which weights the source unevenly -- thin lines BEAD (their
  brightness pulses along them) and strokes vary in weight. And a picture wider than 1,024 had `dh`
  forced to 2 (the line slots' old 1,024 samples, §5; the slots hold 2,048 since `hd_raster.md`
  stage B, which lifted the floor for the native raster only): 1280x720 was boxed to 640 columns and
  blended UP to 720. On top, 720x480 holds 37 % of a 720p picture's pixels: no filter makes
  Progressive equal Native on HDMI.

### 11a. Video Output's Auto is Native (HDMI) unless the ini says analog

Auto: an analog TV in `MiSTer.ini` (the rule of §1: `composite_sync` / `ypbpr` / `vga_sog` with
`vga_scaler=0`, or `direct_video`) -> Interlaced; else a 31 kHz VGA monitor on the core's own raster
(`forced_scandoubler` with `vga_scaler=0`) -> Progressive; else Native (HDMI). A plain VGA monitor
on a stock ini (no `forced_scandoubler`) now gets Native's unusual timing: accepted by the
maintainer (the manual says to set `forced_scandoubler` or choose Progressive). Both verdicts are
latched as `analog_want_l` always was (cfg seen, no stream live): Native makes Main report a new
resolution at every picture size, and Main re-sends cfg with each. `emu`'s `video_out_eff` is the
one resolved value; `interlaced_eff` and the Native request (`nat_req_l`) derive from it, and word
80 reports it (interface 0.14, `architecture.md`). Gates: `check_emu_wiring` (the latches, the
derivations, the report), `run_scaffold.sh` W39 / W96-W98.

### 11b. The Area pre-filter (always on: decided with the maintainer 2026-10-05)

**The decision (2026-10-05).** First built as an evaluation option, the "Downscale Filter" (OSD
`O[14:13]`: Sharp, Area, Smooth). The maintainer's comparison on .201: Sharp and Area close at
854x480 (Area's weights there are 7/8, 1/8), Area clearly better on a 1280x720 stream (all 1,280
columns kept, A = 3), Smooth too soft. Asked whether 720p30 on a CRT matters when a game stream
could ask for 480p60: not for games, but 720p films reach the analog outputs anyway (Jellyfin's
direct play, the file player). So: **Area always, no option** -- Smooth and the menu line removed
(status bits 14:13 freed), `disp_fit`'s `area` tied high in `emu`; low is the **Sharp control**
the benches keep (the fit before this, bit-identical to main's: the existing fixtures and the SD
equivalence gate still compare against it). Not in the interface (no option to mirror). The text
below is the design as first built; Smooth's `(2, 4, 2)` and the third box are gone from the RTL.

#### As first built: the Downscale Filter (OSD `O[14:13]`: Sharp, Area, Smooth; Sharp the default)

An evaluation option the maintainer asked for, to compare two anti-aliasing filters on the rig
(the analog outputs and Progressive; Native and every upscale are untouched). **Sharp** is the
fit exactly as before -- bit-identical, the `dh >= 2` floor kept -- so it is the control arm and the
default until the verdict.

**The filter, per axis, on the decimated grid.** After the box decimation by `d` (`dh` / `dv`, §5)
the residual step is `r = s / d` (Q.16: `s >> d_l2`). A pre-filter of three weights in eighths,
`(w0, w1, w2)`, `w0 + w1 + w2 = 8`, forms each stored sample from three consecutive decimated
samples: `p_k = (w0 b_k + w1 b_k+1 + w2 b_k+2) / 8`, centred at `k + S / 8`, `S = w1 + 2 w2`; the
read-out's 2-tap blend is unchanged and samples `p` at the decimated position less `S / 8`. The
weights:
- **Sharp:** `(8, 0, 0)` -- the stored samples are the boxes, as before.
- **Area:** `A = clamp(floor(4 r - 4 + 1/2), 0, 4)` (`r = 1.5`: `A = 2`), `(8 - A, A, 0)`. With the
  2-tap this is the area (pixel-mixing) average exactly at `r = 1` (the identity) and `r = 2` (the
  two-box), and close between (simulated against the exact area filter: visually the same, PSNR
  within 0.5 dB, the beading gone).
- **Smooth:** `(2, 4, 2)` -- the (1, 2, 1) -- whenever `r > 1`; softer than Area, no beading at all.
- At `r <= 1` (an upscale, the identity) every mode is `(8, 0, 0)`: Native and upscales unchanged.
- **Anti-twitter** (vertical, 480i, a frame store, §9) is `(4, 4, 0)` -- its sliding box IS this
  pre-filter with `A = 4`. With it on, the vertical weights are the stronger: Sharp and Area give
  `(4, 4, 0)` (Area's `A` is at most 4), Smooth `(2, 4, 2)` where `r > 1`. Anti-twitter's integers
  are unchanged (below).
- **The floor:** under Area and Smooth the fitted raster no longer forces `dh >= 2` past 1,024
  columns (the 2,048-sample slots hold every legal width): 1280x720 keeps its 1,280 columns. The
  fetch reads the whole coded width whatever `dh` is (§5), so this costs no fetch time. Under Sharp
  the floor stays (bit-identical).

**Where: both axes in the fetch (`clk_mem`), none in the read-out.** Vertically the box rows of
luma decimated row `k` become `[k dv, (k + nb) dv)`, `nb = 1 + (w1 > 0) + (w2 > 0)` boxes, source row
`i` weighted `w_(i >> dv_l2)` into the accumulator (anti-twitter's `2 dv` rows, generalised).
Horizontally at the slot write: stored sample `m` is `w0 V_m + w1 V_m+1 + w2 V_m+2` over the
vertically weighted sums `V`; a word is written once the next word's first two lanes are known (one
word late), and the row's last word is flushed after it (its missing neighbours replicated: never
read -- the taps are clamped below). Chroma is unfiltered both ways, as anti-twitter's is. One
rounding at the end: `stored = (sum_h sum_v w_h w_v SIGMA + 2^(s+5)) >> (s + 6)`, `s = dh_l2 +
dv_l2`, `SIGMA` a box's sample sum -- `(8, 0, 0)` both ways is `(SIGMA + 2^(s-1)) >> s`, the old box
exactly; anti-twitter's `(4, 4, 0)` is `(SIGMA_0 + SIGMA_1 + 2^s) >> (s + 1)`, its old integer exactly.
The accumulator's lanes grow 14 -> 17 bits (`8 x 64 x 255`).
**Retimed 2026-10-06:** the horizontal stage's weighted sums are registered (`hq`) and rounded into
the slot a clock later -- `hp -> lb_wdata` in one `clk_mem` cycle had closed at -1.08 ns at -40 C (SEED
3; `clk_mem` is not gated by `fmax_check.sh`, and earlier fits' worst `clk_mem` path was the framework's
bridge, so it went unseen). The slot write lands one clock later; the command's done still follows it.

**Why the fetch and not the read-out (rejected):** a pre-filter in the read-out needs a stage (LAT 9
-> 10: `ovl_plane`, `vid_out` and the SD equivalence gate against main all move) or a deeper
81 MHz stage; a third ROW at the read-out (the exact area filter vertically) needs five line slots
when `r > 1.5` (the current line's three and the next line's two new), not four; the exact area
weights need a per-pixel reciprocal. The pre-filter on the decimated grid needs none of these and
reuses anti-twitter's sliding rows.

**The read-out:** the column position less `dh S_h / 8` (folded into `pos0`), the row position less
`dv S_v / 8` (with the `(dv - 1) / 2` of §5: anti-twitter's `(2 dv - 1) / 2` is `S_v = 4`); the taps
clamped to `[kmin, kmax - (nb - 1)]` (anti-twitter's `kmax - 1`: the last pre-filtered sample inside
the crop). **Chroma follows the UNSHIFTED position**, so colour stays registered with luma:
horizontally the tap `(w + 32 (S_h mod 8) >= 128 ? k1 : k0) + S_h / 8`, `>> 1`; vertically the slot
`d` iff `w + 32 (S_v mod 8) >= 128` (anti-twitter: always `d`, as before), and Smooth's whole row by
fetching each slot's chroma for row `k + S_v / 8`.

**The fetch budget.** Smooth's three boxes triple a stored row's luma rows. A stored row of `nb`
boxes costs about `dv (W (2 nb + 2) + 45 (nb + 2))` `clk_mem` cycles (luma `nb dv` rows of `2W` words,
chroma `2 dv` rows of `W`, ~45 cycles of latency a row), and a 480p line (2,860 cycles) may need two:
`nb dv <= 8` and that cost `<= 1,300`. Past it Smooth falls back to two boxes `(4, 4, 0)`, and two
boxes to one (`A = 0` / `(8, 0, 0)`); anti-twitter keeps its two (its own `dv` caps, on the 480i
field line's double time). **Found by the bench (2026-10-04):** the first rule (`nb dv <= 8`, `nb dv
W <= 640`: luma alone, "today's caps") let 2048x448 take two boxes at `dv` 2 -- ~3,800 cycles a line --
and `run_disp_reader.sh`'s `wide_sm` showed the rows late (a wrong first pixel). Sharp's own
worst legal case, the same picture at one box, is ~2,590 cycles a line: inside, but with little to
spare -- the rig's `fetch_late` measures the real latency. A late row
is counted (`fetch_late`, word 30) -- measured on the rig on 1280x720, a 720x1280 portrait and
2048x448 in each mode before a verdict.

**Gates:** `tools/disp_fit_ref.py` (the weights, the budget, the floor) and `tools/disp_golden.py`
(the render: written from this text) against `disp_fit_tb` / `disp_reader_tb`; every existing golden
unchanged under Sharp (run first, before the modes: the plumbing transparent); invariants independent
of the formula: chroma's tap the same in all three modes, every `r <= 1` case and every native case
identical to Sharp; the odd-width flush (a 720x1280 portrait at `dh` 2). `--red`: the position
offset dropped, the flush skipped, a box weight wrong, chroma not following the offset.

## 12. The analog DAC's dither (2026-10-06, with the maintainer)

**Removed 2026-10-19.** On a high-bit-depth analog board over component the dither made macroblocking
look worse and tinted the picture. It was never judged on a 6-bit board, where it could still help. So `dac_dither`, the Analog Dither option (`status[19]`),
`VGA_DITHER` and the bench are gone. Only the analog output register (`vga_od`) stays. The rest of
this section is history.

**Found:** on a CRT over S-Video (.236, `vga_mode=svideo`) films showed banding. Test patterns
(`ramp_dark`: Y 16 -> 64 across the screen, x264 at qp 2, verified smooth: 49 levels, monotonic) showed
**14 bands**: the ramp is RGB 0 -> 56, and the I/O board's VGA DAC takes the top **6 bits** of each
channel (`sys_top`: `VGA_R = vga_o[23:18]`; S-Video's luma from `yc_out` likewise) -- 56 / 4 = 14. A
colour ramp banded too. The black level was right (`black_level`: bars at Y 8 and 16 vanish, 20 shows),
so nothing crushes in the core; the core's YUV -> RGB (BT.601 limited, 8-bit, one rounding) is exact.

**Decided with the maintainer:** dither on the **analog output only** (HDMI bit-exact), an **ordered
pattern inverted every field**. `h264/dac_dither.sv` (an `H264-FORK` edit in `sys/sys_top.v`): a 4 x 4
threshold of 0..3 LSB (a Latin square since 2026-10-06: "The matrix" below) added to each channel of the core-raster VGA path's last word (RGB, YPbPr or
S-Video's Y / C alike) before the DAC drops the low two bits, so `floor((v + t) / 4)` averages to `v / 4`
exactly (`v <= 252`; saturating above). The pattern is keyed on `clk_vid` CLOCKS (81 MHz, a pixel held 3
or 6), not pixels: horizontally ~20 MHz, above the video bandwidth -- the DAC and the TV low-pass it into
the two bits. Active video only (blanking, sync levels and the burst untouched; a multiple of 4 is
unchanged at 6 bits). Boards taking the low bits on SDIO (an 8-bit DAC) see `v + 0..3`: invisible.

**Rejected:** dithering in `emu` (HDMI would carry it); a static pattern (a fixed crosshatch on flat
areas). **An OSD option, Off by default** (the maintainer, 2026-10-06, after the same patterns on .201, a
SuperStation over composite: no banding -- its analog DAC is 24-bit; the 18-bit board is the DE10-Nano's
classic analog I/O board): `O[19],Analog Dither,Off,On` (bit 19: never used, so every saved config reads
Off; bits 13-14, the retired Downscale Filter's, could hold an evaluation build's value), `emu`'s new
output `VGA_DITHER` into sys_top (an H264-FORK port, inside `ifndef MISTER_DUAL_SDRAM` as `VGA_DISABLE`),
synchronised into clk_vid in `dac_dither` (`en_s1` / `en_s2`; `h264.sdc` false-paths `en_s1`). A MiSTer.ini
key was the maintainer's first thought; a core cannot read MiSTer.ini (stock Main parses it and passes
only its fixed framework settings), and this project does not modify Main. Not in word 27's OSD mirror
nor the settings request (a property of the board, not of a stream: nothing a program needs). **Not covered:** the scaler-to-VGA path
(`vga_scaler=1`, `vgas_o`), which this core's users have no reason to use. **No NTSC setup** (7.5 IRE) is
added: the patterns showed black right on the maintainer's set.

**The matrix (revised 2026-10-06, ✅ MERGED PR fj#38, ✅ HW-CONFIRMED; found in MiSTer_DVD's copy, its PR #164).** The first
build took the top two bits of a 4 x 4 Bayer matrix. Those reduce to the 2 x 2 Bayer `{0 2; 3 1}` tiled, so
the "4 x 4" was a 2 x 2: exact over a 4 x 4 cell, but **not per line** -- at `v % 4 = 1` alternate lines
average 0 and 1/2 DAC step (ideal 1/4), at `v % 4 = 3` 1/2 and 1 (ideal 3/4). Along the line the pattern is
~20 MHz, far above the video bandwidth, so a line is seen as its mean: alternate lines half a step apart are a
line texture (on DVD's capture rig the 480i line texture fell 0.26 -> 0.055 with the fix, and its maintainer
judged less crosshatching on the CRT). The replacement, rows the lines and columns the clocks:

```
3 0 2 1
2 1 3 0
0 3 1 2
1 2 0 3
```

- **Every line and every column holds 0..3 once**, so any 4 consecutive clocks of a line, and any 4
  consecutive lines of a column, average to `v / 4` exactly, whatever the alignment against DE and vs.
- `3 - t` of a Latin square is a Latin square, so the field's inversion keeps it.
- **DVD's matrix, taken as it is**, for parity between the forks. Its choice among the Latin squares (high
  and low thresholds alternating clock by clock, the 3s stepping between pixel halves line to line) is DVD's
  27 MHz case, a 480i pixel two clocks; here a pixel is 3 (480p) or 6 (480i) clocks of the 81 MHz `clk_vid`
  and any Latin square would do -- so the bench scores lines and columns, not DVD's pixel-pair arm.
- **✅ HW-confirmed 2026-10-06 on .236's CRT** (480i, S-Video, A/B'd against main's build, `history.md` §38):
  the crosshatching main's build shows on `ramp_dark` is gone, gradients look better, a blue ramp no worse (the
  maintainer).
- DVD's PWM-cores evaluation (`Jokippo/MiSTer_PWM_Cores`: the same ramp on every line, clocked far above the
  dot) does not apply either way: its line-identical ramp is vertical stripes, the `[cols]` arm's T9.

Gates: `bench/h264/run_dac_dither.sh --red` (every level's 6-bit average exact over the field, every line
and every column, multiples of 4, the saturation, blanking and the bypass bit-exact, the fields
complementary; T1-T9: T8 the first Bayer-top-bits matrix -> `[lines]`, T9 the same ramp on every line ->
`[cols]`, T2 the row never stepping -> `[cols]`), `check_emu_wiring`
(`VGA_DITHER`) + `run_scaffold.sh` W108. **✅ HW-confirmed 2026-10-06 (`history.md` §36):** on .236's CRT
(the 18-bit board, S-Video) Analog Dither On smooths the ramps' banding (the maintainer).

**Which rig for analog checks (2026-10-06):** .201 (a SuperStation, a 24-bit DAC, this project's own rig)
measures levels exactly -- recommended for the analog capture chain; .236's 18-bit board is the commonest
user setup, so **a change to the analog output's bit depth (this dither, YC / composite levels) is checked
on both before a merge**.

