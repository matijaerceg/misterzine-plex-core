# Phase 5a — High profile ✅ MERGED (PR fj#5) · ✅ HW-CONFIRMED (2026-09-28)

Engineering note for `roadmap.md` Phase 5, first half (D1: a stock Sunshine host always
sends High with the 8x8 transform in use, `p1_measurements.md` §2b). What High 4:2:0 8-bit
adds to the decoder forked from UMD, where each piece lives, and why. Status and gates at
the end (§8).

## 1. What High adds (4:2:0, 8-bit, CABAC)

| tool | clause | where |
|---|---|---|
| scaling matrices: `seq_` / `pic_scaling_matrix_present_flag`, eight `scaling_list()`s, fall-back rules A / B | 7.3.2.1.1.1, 7.4.2.1.1 Table 7-2, 7.4.2.2 | `sps_pps` (store + resolve), `recon_hdr` (the active matrix), the dequant units |
| `transform_8x8_mode_flag` (PPS) | 7.3.2.2 | `sps_pps`, `mb_syntax` |
| `transform_size_8x8_flag`, in two places | 7.3.5 | `mb_syntax` (ctxIdx 399..401, 9.3.3.1.1.10) |
| Intra_8x8: 4 modes per macroblock, prediction with a reference filter | 7.3.5.1, 8.3.2 | `mb_syntax`, `recon_mb`, `intra_pred` |
| the 8x8 residual: ctxBlockCat 5, no `coded_block_flag` in 4:2:0, Table 9-43 maps | 7.3.5.3.3, 9.3.3.1.3 | `mb_syntax` (ctxIdx 402..459) |
| LevelScale with weights, the 8x8 scaling and transform | 8.5.9, 8.5.13 | `dequant_itrans`, `dequant_itrans8` |
| deblocking: luma edges 4 / 12 skipped inside an 8x8-transform macroblock, bS 2 per 8x8 block | 8.7, 8.7.2.1 | `recon_deblock` / `mb_intake` |
| `second_chroma_qp_index_offset` | 7.4.2.2, 8.5.8 | already in the fork (the model and `recon_mb`'s `cr_qp_off`) |

**The CABAC contexts: 460, not 1,024.** High 4:2:0 uses ctxIdx 0..459: 399..401
`transform_size_8x8_flag`, 402..459 the cat-5 significance / last / level contexts. ctxIdx
460..1023 are the Cb / Cr copies of the luma contexts that only `ChromaArrayType` 3 (4:4:4)
codes (Table 9-34: ctxBlockCat 6..13). The fork's context RAM and init ROM already hold
0..459 (UMD transcribed Tables 9-12..9-24 whole), so the engine needs nothing. The earlier
"1,024 contexts" in `roadmap.md` D1 and `spec_hardening.md` is corrected with this note.

**Not in High, refused as before:** 4:2:2 / 4:4:4 (High 4:2:2 / 4:4:4 profiles),
bit depth above 8 (High 10), `qpprime_y_zero_transform_bypass_flag` (High 4:4:4
Predictive), CAVLC, MBAFF. **Monochrome (`chroma_format_idc` 0) IS legal in High** and
stays refused by name (`REF_CHROMA`): **decided 2026-09-28 with the maintainer**, a scoping
refusal like CAVLC and MBAFF (`spec_hardening.md`). No source this core targets sends it
(hardware encoders emit 4:2:0 / 4:4:4; services re-encode to 4:2:0); it comes from
grayscale imaging, some NVRs and hand-made x264 `--output-csp i400` encodes. The refusal is
at the SPS, before any macroblock, so there is no half-supported path; a client program
that direct-plays can read `chroma_format_idc` itself and ask its server to transcode
(the manual's integrator overview says so). Building it later is ~a day and touches no
interface: no chroma syntax (`intra_chroma_pred_mode`, the cbp's chroma half, the chroma
residual), chroma written as 128, no chroma deblocking; `HPCAMOLQ_BRCM_B` and x264 i400
clips as the gate (the model already skips the chroma syntax).

## 2. The oracles (done first)

- `tools/gen_high_tables.py` → `tools/high_tables.py`: the default lists (Tables 7-3 / 7-4),
  the 8x8 scans (Table 8-14; Table 8-13 re-derived as a check against the proven 4x4
  scans), normAdjust8x8's v (8-318) and Table 9-43, from `pdftotext` of the spec,
  cross-checked value by value against ffmpeg's libavcodec. Convention: `c_ij` is row i,
  column j (8.5.14: `u_ij = pred[xO + j, yO + i] + r_ij`), raster `8 i + j`.
- `tools/h264_fe_ref.py`: the syntax above; `resolve_scaling()` is the Table 7-2 walk,
  shared by the reconstruction model and the goldens.
- `tools/h264_trace_ref.py`: JM traces an 8x8 block as `Luma8x8 DC sng` (the first
  (level, run) pair) then `Luma8x8 sng`, and both intra mode kinds as
  `intra4x4_pred_mode` -- named by the macroblock's `transform_size_8x8_flag` here. New
  canonical records: `E transform_size_8x8_flag`, `E prev_intra8x8_pred_mode_flag`,
  `E rem_intra8x8_pred_mode`, `B L8 <b8> 64 ...`, `S seq_ / pic_scaling_list_present_flag[i]`,
  `S delta_scale`. The canonical stream keeps JM's 2003 name `lossless_qpprime_y_zero_flag`
  for the spec's `qpprime_y_zero_transform_bypass_flag` (the RTL's field id has that name).
- `tools/h264_recon_ref.py`: 8.5.9 / 8.5.13 / 8.3.2 / 8.7 as in the table.

**Measured (2026-09-27):** 13 x264 High clips (Intra_8x8 only, P / B / temporal direct /
weighted, 4 slices, constrained intra, the JVT default matrices, custom lists, extreme QPs,
no deblocking, a chroma QP offset): the model's records identical to JM's trace and its
pixels identical to ffmpeg's on every one. The H.264.1 FRExt package (downloaded into the
reference set, `references.md`): the CABAC 4:2:0 8-bit frame and field streams identical to
JM's trace, JM's pixels identical to the package YUV, the model's pixels identical to the
package YUV (`h264_conformance.py --pkg FRExt --recon`; the refused ones are MBAFF,
CAVLC, 4:2:2 and 10-bit, by name). `tools/tests/test_h264_recon_high.py` gates five
clips with fixture-range checks; `red_h264.py` carries 13 High mutations.

## 3. Scaling matrices: stored and resolved in the front end, one active matrix in the reconstruction

**The store is the spec maximum.** A scaling matrix can arrive in any of 32 SPSs and 256
PPSs, and a slice's lists depend on both (fall-back rule B points a PPS list at the SPS
one; "fall back to the previous list" chains inside a set). The lists are resolved at
**activation** (the slice), never when a PPS is parsed: the SPS a PPS names may be re-sent
between the two. So `sps_pps` keeps every set's eight lists as coded (zig-zag order, 6 x 16
+ 2 x 64 = 224 bytes = 56 words of four) beside the per-list flags {present,
useDefaultScalingMatrixFlag}: 32 x 56 + 256 x 56 words = **63 M10K** at 32 bits a word
(256 words a block). Not a hard limit (230 of 553 M10K were used at P3); flagged here so the
cost is visible if M10K runs short later -- the alternative would be a cache of the most
recent matrix-carrying PPSs refused loudly on eviction (the POC type 1 precedent), a
deviation to decide with the maintainer, not taken.

**The transport.** At every slice, after its header, the front end emits the resolved
matrix on the SE stream as header words: `F_scaling_matrix_flag` (0: every list Flat_16,
nothing follows) or 1 followed by 56 `F_scaling_list_word`s -- lists 0..5 (4x4: Intra Y,
Cb, Cr, Inter Y, Cb, Cr, four words each) then 6, 7 (8x8 Intra Y, Inter Y, sixteen words
each), four weights a word, coded (zig-zag) order, the first weight in bits 7..0. A
Sunshine stream (no matrices) costs one word a slice. The reconstruction holds only the
active matrix: two small RAMs in `recon_hdr` (4x4 lists 24 x 32, 8x8 lists 32 x 32) read
by the dequant units through a raster -> zig-zag index ROM (the inverse scan of a scaling
list is always the zig-zag, 8.5.6, even in a field picture). The one extra copy lives in
the reconstruction; the full store once, in the front end.

Where the model sees it: the canonical records carry the raw syntax (they must equal JM's
trace); the resolved words are what `h264_top`'s bench golden and `recon_top`'s golden add
after each slice header, computed by `h264_fe_ref.resolve_scaling()` (the reconstruction
model resolves from the raw records itself and the two are compared).

## 4. The front end (`sps_pps`, `h264_top`, `mb_syntax`)

- `sps_pps`: the eight `scaling_list()` loops with the delta range check (-128..127, else
  `ERR_RANGE`), the store written a word at a time as four entries accumulate; the
  resolver (a per-list source pointer {FLAT, DEFAULT, SPS, PPS} x list, walked from the
  Table 7-2 rules, then 56 reads) runs when `h264_top` asks at a slice.
- `mb_syntax`: `transform_size_8x8_flag` for I_NxN (after mb_type) and for inter
  macroblocks (after the cbp, with `noSubMbPartSizeLessThan8x8Flag` kept as the sub types
  arrive and `direct_8x8_inference_flag` from the SPS); the neighbours' flags in the left
  record and the row-above memory. The 8x8 residual: the 64 coefficients live in a 64 x 16
  RAM (the Main block's 16 were registers; 64 registers and a 64:1 read would cost ~600
  LUTs), read out in order with the significance map deciding zero / stored. The
  level-decode search is "the highest remaining significant position" over a mask that
  loses each position as it is decoded (no `<= rb_i` compare). Table 9-43 as `case` ROMs,
  the next position's context looked up beside the current one (the pre-issue of the Main
  hot loop kept). A cat-5 block sets `coded_block_flag` 1 in its four 4x4 slots of the
  left record and the row-above memory (write-time substitution: 9.3.3.1.1.9 then needs no
  read-side change).
- New SE words: kind 20 `T8` (`transform_size_8x8_flag`); block kind 5 `L8` (64
  coefficients); the Intra_8x8 modes reuse kinds 5 / 6 (the reconstruction knows the size
  from the T8 word before them).

## 5. The reconstruction

- `mb_intake`: an L8 block's 64 coefficients go to the four luma 4x4 slots of its 8x8
  (`slot 1 + 4 b8 + pos / 16`), each marked coded; `nz` is the OR over the 8x8 when the
  descriptor moves out (8.7.2.1 judges bS 2 per 8x8 block for such a macroblock).
- `dequant_itrans` (4x4): LevelScale4x4 = weight x normAdjust4x4. The rounding term of
  8-337 is now BUILT: the fork omitted it because LevelScale was a multiple of 16, which a
  weight other than 16 breaks. The DC paths take `weightScale(0, 0)` of the block's list.
- `dequant_itrans8` (new): the 8x8 scaling and transform, serial and RAM-backed (a 64 x 20
  work RAM and a 64 x 20 output RAM; one 8-point butterfly, 8.5.13.2's e / f / g, used for
  rows then columns): ~290 cycles a block (measured). 8x8 blocks are ~3-4 % of coded macroblocks in the
  Sunshine captures, so a register-array design at ~2,500 ALM was not worth its area.
  (2026-10-03, Phase 5c part 2: x264 transcodes code most luma residual with the 8x8
  transform, so the unit is now a pipeline over blocks -- intake | rows | columns | output,
  ~80 cycles a block in a stream: `mb_pipeline.md` §4j.)
- `intra_pred`: kind 3, Intra_8x8. The reference filter (8.3.2.2.1) runs as a prep pass
  over the neighbour store, in place (each run keeps the unfiltered previous sample in a
  register; the corner is computed first and written last); the nine modes are the 4x4
  tap patterns with 8x8 offsets. New input `avail_corner` (8-79 / 8-82..84 depend on it).
- `recon_hdr`: the active matrix. `F_scaling_matrix_flag` sets `h_sflat` (0 = weights
  follow) and rewinds the word index; each `F_scaling_list_word` is written straight into
  `sl4_ram` (words 0..23) or `sl8_ram` (24..55), read by the two dequant units through
  `sl4_ra` / `sl8_ra` (registered, the data the cycle after); `sh_sflat` is presented with
  the rest of the slice at activation. Writing the RAMs the running slice reads is safe
  because `recon_top` holds every NAL word until the macroblock pipeline and the back
  engine are idle (`R_NAL_WAIT`), and the words arrive before the slice's first
  macroblock word (`hdr_end`). **Do not "optimise" that hold away** without
  double-buffering these RAMs.
- `recon_mb`, the residual engine: a luma block of a `transform_size_8x8_flag` macroblock
  is kind 5 (`r_blk` 1, 5, 9, 13 -- `b = 4 luma8x8BlkIdx`): 64 levels read from slots
  `b + 1 + k / 16`, sent to `dequant_itrans8` (`r_l8` routes the start, the coefficient
  queue and the result stream; the 4x4 unit never sees kind 5), the 64 samples written
  into the four 4x4 residual ids `b + {y / 4, x / 4}`, row `y % 4`, all four marked ready
  (or ready + zero when uncoded) at once. So the inter add walk over the 16 ids is
  unchanged. The 4x4 list is `(intra ? 0 : 3) + plane` (Table 7-2's order), the DC kinds
  included; the 8x8 list is `!intra` (6 Intra Y, 7 Inter Y).
- `recon_mb`, Intra_8x8: the Intra_4x4 states run with `i4 = 4 b8` and `cur_t8`. The mode
  derivation is the 4x4 one unchanged (with `i4 = 4 b8` it reads 8-72's slots 4 b8A + 1 /
  4 b8B + 2, in this macroblock or the neighbours' records) except that prev / rem come
  from index b8 (mb_intake stores the four 8x8 modes' syntax sequentially); the mode is
  written into all four slots. The gather is 25 samples (step 0..15 the row above, 16..23
  the left column, 24 the corner) through the same pipeline; the top-right half comes from
  the above macroblock (b8 0), the above-right one (b8 1: `upr_samp` now keeps its 8 bytes),
  block 1's bottom row in the bank (b8 2: reconstructed before block 2's gather) or nowhere
  (b8 3), then `p[7,-1]` is substituted into 8..15 (`top7`) when the top is available and
  the top-right is not. `avail_corner` follows the corner's source (1 inside, `ia_left` /
  `ia_above` on an edge, `ia_aleft` at the macroblock's corner). The 64 samples are written
  at `(bx + cnt % 8, by + cnt / 8)`; the residual is added as its four 4x4 quarters
  (`r_ret` 2), then the next block, chroma after block 3.
- `recon_deblock`: `q_t8_in`, latched with the headers at start (the front has moved on to
  the next macroblock by the time the edges run), turns off luma edges 1 and 3; the chroma
  internal edge stays (it lies on luma edge 2).

**Verified (2026-09-27), `run_recon_top.sh`** (pre-deblock macroblocks and final pictures
identical to the model, the model pixel-exact vs ffmpeg and the package YUVs):
x264 `hi` (Intra_8x8 in all nine modes, slices of 9 macroblocks: an unavailable
`p[-1,-1]` beside an available top and left, the filter's 8-80 / 8-84 case, reached 4
times), `hpb` (P / B with the 8x8 transform), `hci` (constrained intra, 3 slices), `hcq`
(custom lists), `hjvt` (JVT defaults); FRExt `FRExt3_Panasonic_E`, `HPCALQ_BRCM_B`,
`HPCAQ2LQ_BRCM_B` (Cb and Cr lists differ, `second_chroma_qp_index_offset`),
`HCAFF1_HHI_B` / `HPCAFL_BRCM_C` (field pictures), `HCAFR1_HHI_C` -- 2 to 4 CIF pictures
each. A fixture must REACH what it is for: the model counts `i8_block`, `i8_modeN`,
`i8_subst`, `i8_no_corner`, `i8_mode_from_nb`, `i8_coded`, `t8_inter_coded`,
`t8_edge_skipped` (an edge the 4x4 transform would have filtered) and the runner requires
the ones each clip names non-zero (`tools/recon_top_golden.py` prints them). An x264
stream cannot give Cb and Cr different lists (one chroma list per kind), so the Cb / Cr
list choice is RED-tested on `HPCAQ2LQ_BRCM_B` only (H10; SKIP without the reference set).

## 6. Throughput

Not a goal of this half. The 8x8 path is slower per block than four 4x4 blocks (~290 vs
~108 cycles), on a few percent of macroblocks, and runs ahead of the front like the rest of
the residual engine.

**Measured (2026-09-28), the real Sunshine captures** (`p1_measurements.md` §2b: stock
Sunshine, NVENC, High, 720x480p59.94; 120 pictures from the first IDR, `run_cosim.sh
--sweep --dir <captures>`; the captures are not in the repository): every macroblock and
picture of all three bit-exact in the Verilator cosim, the model bit-exact vs ffmpeg --

| session request | clk_dec cycles a macroblock | frames/s at 81 MHz | x real time (cosim DDR model) |
|---|---|---|---|
| 3,000 kbit/s | 950 | 63.1 | 1.05 |
| 10,000 (D1's target) | 986 | 60.9 | 1.02 |
| 16,000 | 996 (995 before the retime) | 60.3 | 1.01 |

These are Phase 5b's starting numbers (re-measured on the retimed netlist, `890c13f`: unchanged but for one cycle at 16 Mbit/s). They are lower than Phase 1's 1,186 on the Main
NVENC proxies because the captures are ~52 % skipped macroblocks (`p1_measurements.md`
§2b's caveat: the portal capture may have duplicated frames), so they flatter a game
stream; and the rig ran 4-7 % slower than the DDR model in UMD, so 1.02x is "at risk" there
(the runner flags anything under 1.07x). D1's gate stays ≤ ~935 cycles a macroblock on the
Sunshine-shaped proxies AND real time on the rig from a live session.

## 7. Decisions

- Monochrome (§1): refused by name, decided with the maintainer 2026-09-28; revisit only
  if a real source sends it.

## 8. Status and gates

- [x] The models, the tables, the tests (§2).
- [x] RTL: the front end (`run_h264_top.sh` 41 mutations, `run_mb_syntax.sh` 17 on High
      fixtures), GREEN and RED.
- [x] RTL: the units (`run_dequant_itrans.sh` 21, `run_intra_pred.sh` 18), GREEN and RED.
      (`run_deblock.sh` unchanged: the t8 edge skip lives in `recon_deblock`, gated by
      `run_recon_top.sh` H1 / H2.)
- [x] RTL: the reconstruction (`run_mb_intake.sh` 13, `run_recon_top.sh` H1-H17 on 5 x264
      High clips and 6 FRExt CIF streams) GREEN and RED; `run_cosim.sh --sweep` on the three
      Sunshine captures bit-exact (§6).
- [x] Fit: `H264_p5high_20260928_0459.rbf`, SEED 1, clk_dec 87.60 / 87.37 MHz, 27,318 ALM,
      315 M10K, 75 DSP, every gate PASS (after one retime: `history.md` §4).
- [x] ✅ HW: the 10 and 3 Mbit/s Sunshine captures through `h264play` on the rig, every
      picture decoded, errors 0, the picture clean; 60.8 pictures/s mid-stream at 10 Mbit/s
      (`history.md` §4).
- [x] Monochrome: refused, decided 2026-09-28 (§7).

**Next:** merge (on the maintainer's request), then Phase 5b -- throughput, its own
branch: ≤ ~935 cycles a macroblock on the Sunshine-shaped proxies, real time from a live
session.
