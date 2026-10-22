# Chroma reconstruction: siting-aware bilinear on every output (roadmap Phase 6e)

Status: **✅ MERGED (PR #8), ✅ HW-CONFIRMED 2026-10-10** (`feature/chroma-interp`) -- decided with the maintainer ("let's do the full
version"). It REPLACES the identity-only step (`display.md` §3 "Chroma at the identity"): that step's
results are this design's special case, and the identity frame came out the same 345,600 dots. Stage 1
(the siting plumbing) `7cbaa9e`, stage 2 (the reader) `d9220af`; the benches and the fit: §6.

## 1. Why

`disp_reader` showed 4:2:0 chroma NEAREST: each decimated chroma sample repeated over the output
pixels nearest it. Beside saturated detail (red above all) the colour error lands in hard stripes one
or two pixels wide; on scaled outputs whole chroma rows are picked irregularly (720p on 480 lines,
576 on 480), so colour edges advance in uneven jumps. Luma has had a 2-tap blend both ways since P6.
The maintainer, 2026-10-09/10: the bands in Native (HDMI); then "let's do the full version" --
interpolation on every output, the remaining fabric available ("I'm trying to finalize the design").

## 2. What the result is

Every output pixel's Cb / Cr is the **bilinear** blend of the four decimated chroma samples around its
chroma position, the position taken at the picture's **chroma siting**:

- **The siting** is the SPS's VUI `chroma_sample_loc_type_top_field` / `_bottom_field` (0..5; absent:
  0, E.2.1). Horizontally types 0, 2, 4 are co-sited with even luma columns (a chroma sample at luma
  x = 2n), 1, 3, 5 centred (x = 2n + 1/2); vertically 0, 1 centred between luma rows (y = 2m + 1/2),
  2, 3 co-sited with the top row (y = 2m), 4, 5 with the bottom (y = 2m + 1). A frame uses the top
  field's type; a field its own. A value past 5 (a malformed VUI) is taken as 0 (§6).
  A PICTURE record (a program's picture) carries no siting in interface 1.0: type 0, until a 1.x
  minor adds the field (roadmap: the PICTURE record's siting, "B").
- **The position.** For an output pixel whose luma source position is X (continuous, luma sample
  centres at integers; the UNSHIFTED position -- the Area pre-filter and anti-twitter shift luma only),
  the chroma position in decimated chroma samples is `(X - hoff - (dh - 1)) / (2 dh)` with `hoff` 0
  or 1/2 by the siting: decimated chroma sample m is the box of chroma samples [m dh, (m + 1) dh),
  centred at luma x = 2 (m dh + (dh - 1) / 2) + hoff. Vertically the same with `voff` (1/2, 0, 1) and
  dv. Taps floor / floor + 1, the weight the fraction's top 8 bits; clamped to the crop's chroma
  samples as luma's taps are (below the first: both taps the first, weight 0).
- **Worked positions** (the golden asserts these first; an off-by-half hides here):

  | case | luma X or Y | chroma position | taps, weight (of 256) on the second |
  |---|---|---|---|
  | dh 1, type 0 (hoff 0), X = 2n | 2n | n | n, n + 1, w 0 |
  | dh 1, type 0, X = 2n + 1 | 2n + 1 | n + 1/2 | n, n + 1, w 128 |
  | dh 1, type 1 (hoff 1/2), X = 2n | 2n | n - 1/4 | n - 1, n, w 192 |
  | dh 1, type 1, X = 2n + 1 | 2n + 1 | n + 1/4 | n, n + 1, w 64 |
  | dv 1, voff 1/2 (types 0, 1), Y = 2m | 2m | m - 1/4 | m - 1, m, w 192 |
  | dv 1, voff 1/2, Y = 2m + 1 | 2m + 1 | m + 1/4 | m, m + 1, w 64 |
  | dv 1, voff 0 (types 2, 3), Y = 2m / 2m + 1 | | m / m + 1/2 | m, m + 1, w 0 / 128 |
  | dv 1, voff 1 (types 4, 5), Y = 2m / 2m + 1 | | m - 1/2 / m | m - 1, m, w 128 / m, m + 1, w 0 |
  | dh 2, type 0, X at decimated luma k's centre (2k + 1/2) | 2k + 1/2 | (2k + 1/2 - 1) / 4 = k/2 - 1/8 | |

  (dh 2: decimated chroma sample m covers chroma samples 2m, 2m + 1, centred at luma x = 4m + 1;
  `(X - 0 - 1) / 4` at X = 4m + 1 is m: consistent.)
- **The arithmetic** is luma's: horizontally `(a (256 - w) + b w + 128) >> 8` on the two chroma rows,
  then vertically the same with the row weight -- two roundings. At the identity (type 0) the weights
  are 0 / 128 horizontally and 64 / 192 vertically: exactly the identity step's
  `(c[n] + c[n + 1] + 1) >> 1` and `(3 b + a + 2) >> 2`.
- **A store of fields** (`pic_field`) at dv = 1: chroma is interpolated WITHIN ONE FIELD -- the field of
  the luma tap k0, i.e. the PARITY OF THE STORE ROW SHOWN (or for Bob's rebuilt line the KEPT field) --
  at the position of the line in that field's own coordinates (field line `(y - p) / 2`, then the
  field's siting); the store's chroma row of field row j is `2 j + p` (line-interleaved). **The field's
  siting is Figure E-1's** (corrected 2026-10-12, found by MiSTer_UMD_Video): field p's chroma row m sits
  at frame line `4m + 2p + voff` -- the progressive positions, MPEG-2's interlaced 4:2:0 -- so in the
  field's own lines its offset is `(voff + p) / 2`, not `voff`: type 0 a quarter down the top field's
  line pair and three quarters down the bottom's (until then both a half, field-centred: an eighth of the
  chroma step off on every field line). Types 2 / 3: 0 and 1/2; 4 / 5: 1/2 and 1. At type 0 the line
  nearer its row takes `(7 c[m] + c[n] + 4) >> 3`, the other `(5 c[m] + 3 c[n] + 4) >> 3`. Checked against
  ffmpeg's interlaced upsampling (`scale=interl=1`, libswscale 9.0.1+) within a code at all six sitings,
  the old rule more than a code off (the golden's `check_field_oracle`); `disp_reader`'s `c_vf`, N12-N14. This is
  today's rule (`c_row = 2 (k >> 2) + (k & 1)`: the row's own field) made continuous, and it does not
  depend on WHEN the row is shown: at 480i, whether the store's field p lands on raster field p is
  `disp_fhold`'s business (word 85, PR fj#35's field order); whichever raster field shows store row k,
  its chroma is field (k & 1)'s. The golden's `[il]` field arm states it. At dv > 1 a field store is
  shown woven (the known limit) and its chroma frame-wise.
- **Blend** (the kernel `(a + 2 b + d) >> 2` at the identity on a field store) keeps that kernel for
  LUMA; chroma is the line's own field's interpolation (decided: blending the two fields' chroma needs
  four chroma rows and a second interpolation per plane; chroma's vertical resolution is half luma's,
  and Blend exists for luma's combing). The golden states it; ffmpeg's `interlace` lowpass is no longer
  its chroma oracle (luma's still).
- **Not done (decided):** the Area pre-filter on chroma (chroma stays box-decimated, then blended);
  the PICTURE record's siting (an interface minor, separately).

## 3. The structure

**Chroma rows get their own slots.** Today a luma row's fetch also fetches its chroma row into the
same slot, so chroma row j is fetched twice (with luma rows 2j and 2j + 1) and the second row a
vertical blend needs is usually not held. New:

- **Luma slots** (4, as now) fetch Y only.
- **Chroma slots** (8): each holds one decimated chroma row of Cb and Cr, tagged by its STORE chroma
  row (the decimated row, or at dv = 1 on a field store the line-interleaved row `2 j + p`). The line
  control asks for two (j0, j1, weight) a line; missing rows go into the line's command beside the luma
  rows. Protected: the current line's two and the next line's two; allocation as luma's (invalid first,
  else the lowest row). The fetch per chroma row: Cb then Cr, dv source rows boxed (as today's chroma).
- **Traffic falls** about a quarter on average: per output line today `4 W` words per new luma row
  (Y 2W + Cb W + Cr W); now `2 W` per new luma row and `2 W` per new chroma row, half as many.
- **The worst line is no worse than today's.** A command carries at most two luma rows and two chroma
  rows: `2 x 2W + 2 x 2W = 8 W` words, today's worst exactly (two luma rows with their chroma, `2 x 4W`).
  It happens at a refresh's first line (every slot invalid) and after a jump. A field store at the
  identity under Weave alternates fields line by line, but each field's chroma position advances half a
  field chroma row per field line, so steady state is one new chroma row per field every four frame
  lines; the 8 chroma slots hold both fields' current pairs (four rows) plus the next line's. disp_fit's
  caps (set for 8W) therefore hold; `[late]` on the widest cases (`wide_sm`, `wide_area`) checks it.

**The read-out** gains a chroma column accumulator beside luma's (`pos0c`, + sx / 2 a dot: no
subtract in front of the RAM address), the two chroma taps clamped and their words (each chroma
copy split by word parity, as luma's b / d: a sample and its right neighbour in one cycle), and per
plane four bytes (two taps x two rows). Stage 4 blends horizontally (2 rows x 2 planes = 4 products),
stage 5 vertically (2 per plane, luma's two-product form = 4). **LAT stays 9** (the stages exist;
the products sit beside luma's). Eight 8 x 9 products: about three DSP blocks (9 left), else ALMs.

**RAM:** chroma copies row0-even, row0-odd, row1-even, row1-odd per plane, each 8 slots x 64 words
(512 x 64: 4 M10K): 8 copies, 32 M10K, replacing today's six chroma RAMs (24): +8 M10K (140 free).

## 4. The plumbing (the siting)

(Check first: `recon_out`'s per-store table is already wide (F2: "232 bits"); its packing in M10K must
survive 6 more bits -- grep the map report's "Inferred altsyncram" for it, the non-power-of-two lesson.)

`recon_hdr` captures `chroma_sample_loc_type_top_field` / `_bottom_field` beside the colour
description (`c_stage`, per SPS id in `col_ram`: 26 -> 32 bits); `recon_top` carries them as the
picture's `pinfo_siting` [5:0]; `pic_in`'s mux gives a PICTURE 0; `recon_out`'s per-store table and
`disp_ctl`'s shown-picture latch carry them like the colour code; `emu` crosses them in the raster
bundle; `disp_reader` latches them with the colour code at a refresh's first request (a picture's
siting never changes inside a refresh). No interface change (status word: §6).

## 5. Verification

- `tools/disp_golden.py`: the bilinear chroma at every fit, siting and store kind, from the design's
  formulas (not the RTL); the identity step's `up_ident` must be its special case (asserted); the
  independent check ffmpeg's own upsampling at each siting (`scale=in_chroma_loc=<loc>`, validated on
  an impulse per siting first) at the identity, and a ramp check at scaled fits (a linear chroma ramp
  must come out linear at the pixel's own chroma position: a siting or offset error shows).
- `run_disp_reader.sh`: every arm regenerated; new arms per siting (0-5) at the identity and on a
  scaled fit, a field store at 480i, Bob / Blend on a field pair; `--red` per new behaviour (the siting
  offsets, the field-row map, the weight rounding, the clamp, the chroma tags' protection, the
  traffic rule). `run_vid_equiv.sh` (the SD equivalence gate, its purpose the clock-domain move): its fixtures get
  NEUTRAL chroma (Cb = Cr = 128), which nearest and bilinear reconstruct identically, so the gate stays
  bit-exact against main at the pins -- RGB, sync, DE, CE, CS -- while chroma's correctness is
  `run_disp_reader.sh`'s.
- The siting plumbing: `run_recon_top.sh` (a stream with each `chroma_sample_loc_type`), the cosim.
- On .201: the red pattern (and a ramp) at Native, at Progressive scaled, and at 480i against the golden.

## 6. As built

- **Stage 1** (`7cbaa9e`): `recon_hdr`'s `col_ram` 26 -> 32 bits; `pinfo_siting` through `pic_in` (a
  PICTURE: 0), `recon_out` (238 bits), `disp_ctl`, emu's bundle (+6), `disp_reader.pic_siting`. Benches:
  `run_scaffold`, `run_recon_out`, `run_ring_rd`, `run_recon_top` ALL GREEN (three siting clips scored
  against ffprobe's `chroma_location`: 09, 12, 2d; every colour clip's 00); CL13-CL15.
- **Stage 2** (`d9220af`): as §3. `run_disp_reader.sh` GREEN 70 arms (the identity at every siting, a
  field pair with differing sitings, Bob / Blend, 480i, every fitted, Area and native case, `[late]`);
  `--red` N1-N11 each caught by its own arm. The fixture picture's ramp band now differs row to row:
  with identical rows the Blend kernel's first-row mirror (K5) had been visible only through the
  retired chroma kernel. `run_vid_equiv.sh` ALL GREEN with neutral chroma (bit-exact against main).
- **The fit** (SEED 2, `H264_chromafull_20261010_1752.rbf`) and **.201** at Native, Progressive and 480i: the
  core's raster matches the golden's bilinear render at 99.99-100 % (max 2), the old nearest rule at 66-76 %
  (`history.md` §44).
- **The golden's independent checks** (`tools/disp_golden.py`): the worked positions (§2's table), ffmpeg
  at all six sitings after an impulse per siting, the field split against ffmpeg's, a triangle ramp at
  three sitings on every fitted case (222 checks, worst bias 0.07 codes; a quarter-sample error is 2.0);
  each proven able to fail by a planted wrong offset.

## 7. Open points

- **Telemetry:** a malformed `chroma_sample_loc_type` (past 5) is taken as 0; it and the shown
  picture's siting become visible in the 1.x minor that adds the PICTURE record's siting (B) -- a count
  nothing publishes is not visibility, so none is added before then.
- **Timing:** clk_vid closed 96.3 MHz (gate 86) with the identity step; the chroma line-control work
  runs in more sequencer steps (a line has >= 858 dots at 27 MHz-equivalent).
