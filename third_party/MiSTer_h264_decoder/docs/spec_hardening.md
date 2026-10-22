# Spec hardening: design to the format's maximum, not the test shelf

**Status: Phase 2.** The decoder arrived from UMD (cc595c6) with UMD's four deviations;
each was re-decided with the maintainer on 2026-09-27 for this core's target (D1: High,
Level 3.1, a game stream is not a disc) and one was added (the picture size). The table
below is this core's, not UMD's. High profile's maxima arrived with Phase 5
(`high_profile.md`): the scaling matrices of every SPS and PPS stored as coded, the 8x8
CABAC contexts (460 in all for 4:2:0 -- the "1,024" once written here counted 4:4:4's).

MiSTer_DVD shipped the same bug twice with different clothes: a table sized to the
largest disc on the shelf (64 VOBs; 128 cells) that a real disc then exceeded, silently.
The rule it earned is in `CLAUDE.md` "Design to the spec maximum": size every table,
counter and loop bound to what the FORMAT allows; where a hard limit forces a smaller
bound, discuss it, record it beside the code, and never truncate silently.

For this core the "format" is H.264 at the level and profile Phase 1 settles, **and the
HPS interface**: a record length, a PTS, a ring index are fields a program on the ARM
writes, so they are sized to what the interface allows and range-checked on arrival,
never trusted.

## Working rules

- A bound comes with a citation (the spec table, or the interface field width) written
  beside the code.
- A bound that is ever hit is VISIBLE: a counter or flag a bench, the status block or
  telemetry can see.
- A captured stream says what is common, not what is possible. Scoping decisions (no
  CAVLC, no MBAFF) are acceptable only because the unsupported cases are refused loudly.
  (fj#20, `feature/cavlc`, **decided 2026-10-01: CAVLC is supported through the client library's
  rewrite into CABAC on the ARM**, bit-exact, up to a CPU ceiling of ~4-5 Mbit/s at 480p60; the
  fabric still refuses it -- `cavlc.md`.)
- Update `conformance.md` in the same change that closes a gap.

## 🚩 Known deviations from the spec maximum (every one a decision taken with the user)

If a stream ever fails on one of these, this is the table to read first. Each row names
the bound, what it refuses, how the refusal is made visible, and what to do about it.
**Visibility:** since Phase 3 every refusal and error below is in the HPS interface's status
block (`fe_refused` / `fe_refused_code`, `rc_ref_size`, `rc_out_dropped`, ...; `h264stat`
prints them), read by any program -- UMD showed them on a HUD this core does not carry.

| structure | spec maximum | what is built | refuses (loudly) | decided | if it bites |
|---|---|---|---|---|---|
| picture side (A.3.1: PicWidthInMbs, FrameHeightInMbs <= Sqrt(8 MaxFS)) | Level 3.1: 169 macroblocks a side (2,704 pixels: a 2704x336 picture is 3,549 macroblocks) | **128 macroblocks a side** (2,048 pixels): the front end's 7-bit size fields, every column-indexed row buffer 128 deep (`mb_syntax` `above_mem`, `recon_mb` `lm_*`) | a wider or taller picture at the SPS: `REF_SIZE` (12) in `fe_refused_code`, nothing decoded | carried from the picture-size row (2026-09-27; that row closed 2026-10-02, below) -- **accepted by the maintainer 2026-10-05** (fix/cleanup): no encoder or service sends a 1280x720-class picture wider than 2,048, and a wider one is refused loudly | widen the size fields to 8 bits and the row buffers to 170 (~+33 % of their 40 M10K) || POC type 1 `offset_for_ref_frame` tables (§7.4.2.1.1, §8.2.1.2) | 32 SPS × 255 entries × 32 bits = 27 M10K | **the full-length tables of the TWO most recently received type-1 SPSs, keyed by id** (1-2 M10K; UMD P4) | a slice activating a type-1 SPS whose table was evicted (three or more type-1 SPSs sent before the oldest is activated): a `REF` code and count, never a wrong POC | UMD 2026-09-23; **re-decided 2026-09-27** with the maintainer: the stock Sunshine captures use POC type 2 (`p1_measurements.md` §2b), x264 and NVENC never emit type 1 | grow the cache: only the NUMBER of live type-1 SPSs is capped; 32 is the 27 M10K spec store |
| `no_output_of_prior_pics_flag` (C.4.4) | inferred 1 when an IDR changes the picture size or the DPB size | **used as coded, never inferred** (as JM does) -- `recon_dpb` `D_OUT_C44`, `h264_recon_ref.output_step` | nothing is refused: on a size change with the flag 0 the old pictures still waiting are OUTPUT rather than dropped; the stores a coded 1 drops are counted (`out_dropped`) | UMD 2026-09-25; **re-decided 2026-09-27**: a stream switch here arrives as Phase 3's DISCONTINUITY, which flushes and resets the decoder, so the inference has nothing left to decide | infer it: compare the new SPS's size / DPB size with the stored one at the IDR's `D_OPEN` |
| Level 1b's MaxDpbMbs (Table A-1: 396) | level 1b = `level_idc` 11 + `constraint_set3_flag` | **read as level 1.1 (900)**: the front end does not keep `constraint_set3_flag` | nothing: a larger DPB than the spec's only delays output; the order is the same | UMD 2026-09-26; **re-decided 2026-09-27**: harmless, and no source this core targets is below Level 3 | keep the flag in `sps_t` (1 bit) and give 11 + flag 396 in `recon_dpb`'s `max_dpb_mbs` and `h264_recon_ref.MAX_DPB_MBS` |
| monochrome (`chroma_format_idc` 0), legal in High (A.2.4) | a High stream may be 4:0:0 | **refused by name** (`REF_CHROMA`, 1), as 4:2:2 / 4:4:4 are -- a scoping refusal like CAVLC and MBAFF | the whole stream: `fe_refused` / `fe_refused_code` 1 in the status block, nothing decoded (the refusal is at the SPS: no half-supported path) | **2026-09-28, with the maintainer: keep refused.** No source this core targets sends it (hardware encoders emit 4:2:0 / 4:4:4, services re-encode to 4:2:0); grayscale imaging, some NVRs and hand-made x264 i400 encodes do. The H.264.1 FRExt package has two (`HPCAMOLQ_BRCM_B`; `HPCVMOLQ_BRCM_B` is CAVLC anyway). Revisit only if a real source sends it | decode it (~a day, no interface change): no chroma syntax (the model already skips it), chroma written as 128, no chroma deblocking (`high_profile.md` §1) |
| the VUI clock tick (E.2.1, C-1) | `num_units_in_tick / time_scale`: any u32 over any non-zero u32 | **720000 x nuit / ts in 24 bits** (eighth-ticks of 90 kHz: a tick up to 23.3 s; `h264/disp_ctl.sv`, `tools/disp_sched_ref.py`) | a longer tick clamped to 23.3 s; a `time_scale` of 0 (illegal) defaulted to 59.94 -- a flag in `disp_ctl`'s `flags` | UMD 2026-09-26; **re-decided 2026-09-27**: the Sunshine captures carry VUI timing with `pic_struct` (1/59.94 s); a duration only paces the untagged pictures between two time stamps | widen `fq` / `dur_q3` / the timeline's Q3 adds (the division is already 52 bits wide on the numerator) |
| a PTS (H.264 has none of its own: the container's, a program's record PTS) | every PTS believed | **a lone PTS more than half a refresh and at most 0.5 s AHEAD of or BEHIND the timeline is disbelieved** (shown on the timeline) unless the previous tag was disbelieved too: the next tag is always believed (`h264/disp_sched.sv`, `tools/disp_sched_ref.py`; UMD's rules A and B, PR fj#25 + fj#26) | nothing is refused: counted, the status block's `disp_lone` (word 27, saturating 15) | 2026-09-29 in UMD with the maintainer (208 lone PES PTS on 73 of 88 disc images, -3 to +8 ticks); ported 2026-09-30 (`display.md` §10). No stream this core has met carries one; Moonlight sends no PTS | a real jump under 0.5 s either way is followed one tag (~0.5 s) late; two lone PTS within one tag of each other would defeat it |
| (0.6) the input region's event queue (`architecture.md` "Input (interface 0.6)") | Main's events have no bound: one per bus transaction, microseconds apart | **32 entries** (words 56-63) between two reads by the program; a one-deep pending register per source in the core while a write of the region is pushed | nothing is refused. A program more than 32 events behind loses the oldest: it sees exactly how many (`ev_count` minus its own count; `h264ring_input_events`' `lost`) and releases everything held; a second event from one source during a push is counted in `ev_lost` (never in use: I3's flood only) | 2026-09-29, the design pass with the maintainer (the proposed layout). A program polling every 1 ms needs 32 events in a millisecond to lose one | a larger queue: more words in the region (65-70 are free: 24 more entries) |
| (fj#20, the client library's CAVLC rewriter, `hps/lib/h264ring_cavlc.c`) an Intra_8x8 macroblock coded in CAVLC whose only coded 8x8 blocks are all zero, with `mb_qp_delta` not 0 | legal CAVLC (7.3.5.3.2: a cbp bit set, four `TotalCoeff` 0) | **refused by name** (`H264RING_CAVLC_REFUSED`, "not expressible in CABAC"): CABAC has no `coded_block_flag` for an 8x8 block in 4:2:0, clearing the cbp drops the `mb_qp_delta`, and Intra_8x8 cannot change transform (`cavlc.md` §3; the inter and mixed cases are re-expressed exactly) | the stream, at that access unit: the program gets the reason | **proposed 2026-10-01, pending the maintainer** (no encoder tried emits it: x264, JM with six settings; a synthetic fixture does) | none exact: the QP of that macroblock differs; a program could fall back to a transcode |
| (0.6) the pads (`padN_joy`, the sticks) | every change Main sends | **a snapshot written at most every 1 ms** (the region's minimum gap, M7) | nothing is refused. A press and release both inside one write period (< 1 ms) is not seen; Main itself merges the changes within one of its polls | 2026-09-29, M7 with the maintainer (on change, at most every 1 ms) | queue the pads' changes as events too (a type 3) |
| (0.16, `colour.md`) `matrix_coefficients` (Table E-5: 0-10, 11+ in later editions) | every matrix converted as coded | **BT.601, BT.709, BT.2020 non-constant luminance**; FCC (4) shown as 601 and SMPTE 240M (7) as 709 (Kr / Kb within 0.01) | nothing refused: GBR (0), YCgCo (8), BT.2020 constant luminance (10) and 11+ shown by the size rule and **counted** (`colour_unsup`, word 86); the stream's tags in word 86 | 2026-10-06 (design; F2) | a fourth coefficient set (GBR is the identity: a bypass), or the program decodes on the ARM |
| (0.16) `colour_primaries`, `transfer_characteristics` (E.2.1) | a display honouring the source's primaries and transfer | **reported (word 86), not applied**: the matrix only, no gamut or transfer conversion -- a BT.2020 picture shows undersaturated on a 709 display | nothing refused; visible in word 86 | 2026-10-06 (design; F2) | a 3x3 gamut matrix after the conversion (more DSP than the 10 left) |

**Closed (2026-10-02, interface 0.11, the 720p branch): the picture size.** Built since
2026-09-27 as 1 MB stores holding pictures up to 1,620 macroblocks (Level 3.0's MaxFS) against
Level 3.1's 3,600; now 2 MiB stores (`h264_recon.md` §2.2) at `0x3200_0000`, and `recon_top`
refuses above 3,600 exactly (Level 3.1's MaxFS), counted in `rc_ref_size` and told to programs in
word 81 (`architecture.md` "The capabilities (interface 0.11)"). The refusal's own defect,
found by the new refusal arm and fixed with it: a refused picture was opened in a store and
that unwritten store emitted to the display (now `recon_dpb` never sees the slice:
`h264_recon.md` §2.2). The display reader already
decimated any width to its 1,024-sample line (a 1280-wide picture stores 640); the throughput is
D1's (`roadmap.md`).

## Maxima to design to (fill at Phase 1)

| structure | format maximum | notes |
|---|---|---|
| H.264 Level 3.1: MaxMBPS / MaxFS / MaxDpbMbs / MaxBR | 108000 / 3600 / 18000 / 14000 kbit/s (Main; High's MaxBR is 1.25x: 17500) | Table A-1; confirm each from the spec PDF before sizing. 720x480 = 1350 MBs; MaxFS 3600 admits 1280x720, decoded since interface 0.11 (2 MiB stores). D1: every Level 3.1 High stream decodes CORRECTLY; real time is promised for game streams to a 10 Mbit/s request and 720p24 films to ~8 Mbit/s -- above it, falling behind is counted and shown, never silent |
| SPS / PPS ids | 32 / 256 | §7.4.2.1 / §7.4.2.2 (UMD stores all) |
| `num_ref_idx_active` | 32 | §7.4.3 |
| DPB frame stores | MaxDpbFrames `Min(MaxDpbMbs / PicSizeInMbs, 16)`: Level 3.1's 18000 gives 13 at 720x480 and 16 at 1,125 MBs or fewer -- the same 16 as Level 3.0's cap | **20** (`h264_pkg` `NSTORE`): 16 + the current picture + the display's 2 held; 40 MB at word `0x0640_0000` (2 MiB stores since 0.11; MaxDpbFrames is 5 at 1280x720); gated by `run_recon_top.sh`'s r16 clip and R9 |
| CABAC contexts | **460** for Main and High 4:2:0 (ctxIdx 399..459 are the 8x8 transform's); 1,024 only with `ChromaArrayType` 3 (4:4:4, not decoded) | §9.3.1.1, Table 9-34; D1. A stock Sunshine stream is High with the 8x8 transform used (`p1_measurements.md` §2b). The fork's context RAM already held 0..459 |
| scaling matrices | 8 lists (6 of 16, 2 of 64) in each of 32 SPSs and 256 PPSs, resolved per slice (Table 7-2) | **every set's lists stored as coded** in `sps_pps` (32 x 56 + 256 x 56 words, 63 M10K), resolved at each slice and sent to the reconstruction as 56 words (`high_profile.md` §3). At spec maximum; the M10K cost is recorded there with the rejected cache alternative |
| filler data NAL units (type 12) | any number, any size | one after every picture from Sunshine's NVENC (CBR padding): skipped, never an error |
| slices per picture | unbounded | NVENC and x264 `--slices` both emit several |
| ring record length / PTS / indices | the interface's field widths | **Phase 3** (`architecture.md` "The HPS interface, v0.1"): every field the program writes is checked on arrival and a violation stops the session with a code (the status block's `err`, `err_pos`, `err_word`): the write index (16-aligned; never more than the ring ahead of the read index, never backwards), the header (type, flags per type, reserved bits, sync, seq), the length (a VIDEO_AU 1 byte to 4 MiB -- above Level 3.1 High's 2.6 MB CPB -- any payload <= 4 MiB), the ring's end. PTS 33 bits, indices free-running u32. The ring (8 MB) holds the whole CPB with room; a program that stops reading its flow control is refused, not overrun |
| (0.15) a PICTURE's descriptor (`architecture.md` "Pictures from the program") | the interface's field widths: a 5-bit store, 8-bit sizes, 10-bit crops, 32-bit timing | **at the decoder's own maxima, no deviation:** the store 0-19 (`NSTORE`), each side 1-128 macroblocks (the 128-a-side row above: the reader's 2,048-sample line slots), `w x hf` up to 3,600 (word 81's `cap_max_mbs`), a pair's height even, the crop leaving a picture, `pic_struct` / SAR / timing as H.264's VUI admits them, every reserved bit 0 -- checked in the parser in that order (errors 12-15), the store's hold at the hand-over (16), the stream's kind (11). The pixels themselves cannot be checked (the store rule is the program's: a breach tears a picture, never the core). The file player's SD-only budget is a scoping decision of the client, refused by name (`player.md` P7), not a limit of the interface |
| (0.9) the overlay's descriptor (program words 72-79) | the interface's field widths: 16-bit width / height / stride / band, a 32-bit base | **at the raster's maximum, no deviation:** width 1..720 and height 1..576 (the widest and tallest raster; a 576-line canvas on the 480-line raster is clipped and flagged, `ovl_clip`), the stride a multiple of 8 up to the field's 65,528, the band inside the canvas, the format one of three, the reserved bits and word 78 zero, the whole canvas inside the framebuffer's 8 MB region -- checked in that order at each read, a violation refusing the overlay with its code (`ovl_err`, word 46), a torn read counted (`ovl_torn`) and ignored (`architecture.md` "The overlay plane"). The line addresses use the canvas line SIGNED (the line above a centred canvas is -1: an unsigned 10-bit line once addressed line 1024 there, found by `run_ovl_plane.sh`'s inarrow arm before any merge) |
