# CAVLC through the HPS: a lossless CAVLC -> CABAC rewrite (fj#20)

Engineering note. Status: **✅ MERGED (PR fj#25, 2026-10-02; interface 0.10, rebased after
`feature/hdmi-raster`'s PR fj#26).** On the rig: rewritten streams decoded, errors 0 (`history.md`
§25); ⏳ the Moonlight client against a host forced to CAVLC not yet run. The rewriter is
in the client library (`hps/include/h264ring_cavlc.h`, `hps/lib/h264ring_cavlc.c`), `h264play`
uses it on every access unit, `bench/h264/run_cavlc.sh` is GREEN and `--red` (30 mutations), and
the core has decoded rewritten CAVLC streams on the rig (§6). **Step 1's gate (issue fj#20) is
measured and does NOT pass at 8 Mbit/s** (§5): the rewrite costs ~11-12 % of one A9 core per
Mbit/s at 480p60 (~12-13 % before the hot-loop rework, §8a), so CAVLC is playable up to ~4-5
Mbit/s beside Main and a client, not at a Moonlight session's 10. **Decided 2026-10-01 (§8): CAVLC supported through the rewrite, on by
default in `h264play` and the Moonlight client; the Jellyfin client left as it is.**

The core decodes Main and High profile streams coded with CABAC. CAVLC
(`entropy_coding_mode_flag` 0) was refused by a scoping decision (`spec_hardening.md`,
`conformance.md`: no Phase 1 capture used it; `REF_CAVLC` in `h264_pkg.sv`). It arrives anyway:
x264's `ultrafast` preset writes **High-profile CAVLC**, so a CPU-limited Jellyfin / Plex server
set to it transcodes into something the core refuses (and a device profile cannot ask for "CABAC
only"); phone and web video is Constrained Baseline; a Moonlight host can be forced to it
(`amd_coder=cavlc`, `nvenc_h264_cavlc`, `qsv_coder`: `p1_measurements.md` S4). Instead of a
CAVLC parser in the fabric (2,000-4,000 ALM; main is at 84 % ALM since the macroblock pipeline),
the ARM rewrites each CAVLC slice into a CABAC slice before it is queued: **the same syntax
elements, re-entropy-coded -- the pictures are bit-exact**, and the ring, the records and the
RTL do not change.

## 1. What is rewritten (H.264 7.3, 9.2, 9.3)

Per access unit, each NAL unit is copied byte for byte (nothing is copied at all when the unit
needs no change: `H264RING_CAVLC_PASS`, the input is returned) or rewritten:

- **SPS**: `profile_idc` 66 (Baseline) / 88 (Extended) -> 77 (Main) with `constraint_set1` set;
  `constraint_set0` and `constraint_set2` cleared on every SPS (CABAC is neither Baseline nor
  Extended). Constrained Baseline is a subset of Main; an Extended stream without data
  partitioning or SP/SI is Main-expressible. Level and `constraint_set3` (level 1b) keep their
  meaning between 66, 77 and 88. Two bytes change; the SPS is re-escaped.
- **PPS**: `entropy_coding_mode_flag` 0 -> 1, one bit flipped in place (the PPS is never
  re-serialised), re-escaped.
- **Slice header**: copied bit for bit, `cabac_init_idc` (ue(v) 0) inserted before
  `slice_qp_delta` in P / B slices, `cabac_alignment_one_bit`s after it. `cabac_init_idc` 0
  always: choosing per slice would cost a trial encode.
- **Slice data**: parsed macroblock by macroblock (7.3.4 / 7.3.5, 9.2) and coded with CABAC in
  the same pass (9.3): `mb_skip_run` -> one `mb_skip_flag` per macroblock and every
  `end_of_slice_flag`; `mb_type`, `sub_mb_type`, `ref_idx` (te(v)), `mvd`, `coded_block_pattern`
  (me(v), Table 9-4), `mb_qp_delta`, the intra modes, `transform_size_8x8_flag` re-binarised
  (9.3.2) with the ctxIdxInc neighbour derivations of 9.3.3.1.1 -- the mirror of
  `tools/h264_fe_ref.py`'s decode-side functions, named beside each one in the C; the residual's
  `coeff_token` / levels / `total_zeros` / `run_before` -> coefficients -> `coded_block_flag`, the
  significance map, the levels (9.3.2.7, 9.3.3.1.3); a High CAVLC 8x8 block (four interleaved
  4x4s, `level8x8[4 * i + i4x4]`) -> one 64-coefficient block. Two CAVLC-only forms: **P_8x8ref0**
  becomes P_8x8 with each `ref_idx_l0` coded as 0; **I_PCM** gets CABAC's flush before the
  samples and the engine's restart after them (9.3.1.2).
- **`cabac_zero_words`** (9.3.4.6, 7.4.2.10): after each rewritten slice, the words the picture
  so far needs for `BinCountsInNALunits <= 32/3 * NumBytesInVclNALunits + RawMbBits *
  PicSizeInMbs / 32` (counted across calls; a picture's slices may arrive in several). Only an
  extreme picture needs them (the synthetic `zw`: levels of 15 everywhere, ~4,600 bins a
  macroblock); `run_cavlc.sh`'s model arm checks the limit on every rewritten picture.

**Neighbour state** lives in a ring of PicWidthInMbs + 1 macroblocks (A is the previous slot, B
the next), tagged with the macroblock address and a slice number: availability (the same slice,
6.4.x) is a tag compare, the memory a row. Two trackers per macroblock: the CAVLC side's
`TotalCoeff` per 4x4 (nC, 9.2.1: 16 for I_PCM, 0 for skipped or not coded) and the CABAC side's
flags (`coded_block_flag`s, |mvd| saturated at 127 -- the derivations compare sums with 2 and
32 --, `ref_idx > 0`, predFlags, cbp, the previous macroblock's `mb_qp_delta`).

## 2. Refused, by name (`H264RING_CAVLC_REFUSED`, `h264ring_cavlc_why()`)

What Main and High cannot express, and what the core does not decode either:

| Feature | Where it is caught |
|---|---|
| slice groups (FMO, `num_slice_groups_minus1 > 0`) | its PPS (refused when a slice uses it) |
| redundant pictures (`redundant_pic_cnt_present_flag`) | its PPS |
| arbitrary slice order (ASO) | a slice whose `first_mb_in_slice` is below the end of the previous slice of the same picture (7.4.1.2.4's first-slice detection) |
| data partitioning (`nal_unit_type` 2-4) | the NAL unit |
| SP / SI slices | the slice header |
| MBAFF (`mb_adaptive_frame_field_flag` with a frame picture) | the slice header (PAFF field pictures are rewritten) |
| chroma other than 4:2:0, more than 8 bits, the transform bypass | its SPS |
| an Intra_8x8 macroblock whose only coded 8x8 blocks are all zero, with `mb_qp_delta` not 0 | the macroblock (§3) |

A malformed CAVLC slice (a code no table has, a value out of range, a slice cut short) is an
error (`H264RING_CAVLC_ERROR`): the access unit is never passed through half-rewritten. Every
value read is range-checked as the core's own parsers do (`spec_hardening.md`).

## 3. The 8x8 rule: an all-zero coded 8x8 block

CAVLC can code an 8x8 block with its `coded_block_pattern` bit set and all four interleaved
4x4s at `TotalCoeff` 0. CABAC cannot: in 4:2:0 an 8x8 block (ctxBlockCat 5) has no
`coded_block_flag` (7.3.5.3.3; inferred 1), so its significance map always ends on a coefficient.
No encoder tried emits it (x264, JM 18.4 with six settings), but it is legal, so:

- **Inter macroblock, every coded 8x8 block all zero**: coded with `transform_size_8x8_flag` 0,
  the cbp kept, every 4x4 block's `coded_block_flag` 0. The cbp keeps `mb_qp_delta` (the QP is
  unchanged); with no coefficient anywhere the transform size changes nothing in the
  reconstruction, and in deblocking only the internal 4x4 edges differ, whose bS is 0 either way
  (no coefficients; the motion is uniform inside each 8x8 partition, which the 8x8 transform
  required: `noSubMbPartSizeLessThan8x8Flag`, `direct_8x8_inference_flag`).
- **Otherwise** (some coded 8x8 block has levels, or the macroblock is Intra_8x8): the all-zero
  blocks' cbp bits are cleared. Same levels, same transform; the QP is unchanged while the cbp
  stays non-zero.
- **Intra_8x8 with every coded 8x8 block zero and `mb_qp_delta` not 0**: clearing the bits drops
  `mb_qp_delta` and changes the QP (and deblocking, and the next macroblock's QP prediction);
  Intra_8x8 cannot switch transform. **Refused** (the one legal stream the rewriter refuses for
  its own reason; `spec_hardening.md` "Known deviations").

Each case has a synthetic fixture (`tools/cavlc_synth.py` `z8_*`) and decodes bit-exact (ffmpeg
and the fabric cosim); the statistics count them (`t8_zero_blocks`). The deblocking argument is
tested where it is not trivially true by `z8_p8x8`: a P_8x8 with four different motion vectors over
a textured reference (I_PCM), cbp 15 all zero, `mb_qp_delta` +2 -- the rewrite makes its internal
4x4 edges deblockable, and the pictures still match.

## 4. The engine

Two CABAC encoding engines write the same bytes. The default holds `codILow` with the output
bits not yet written above its 10-bit window and writes whole bytes: renormalisation is one
count of leading zeros, and a carry is resolved a byte at a time (a 0xFF byte is held back until
the next byte shows whether a carry turns it over). `-DCV_SPEC_ENGINE` builds the spec's own
procedure (9.3.4.2-9.3.4.5: PutBit with `bitsOutstanding`, bit by bit), the reference the
`[engines]` arm compares on every fixture. The first bit the spec's PutBit drops
(`firstBitFlag`) is the byte engine's carry position above the first byte: always 0, as the
coded interval stays inside [0, 510). The byte engine took the host from 14 to 8.4 ns a bin. The
hot paths (the block coders, the levels, the mvd and intra-mode bins) run the same engine as
macros on local variables (`E_DECL` / `E_BIN` / `E_BYPASS` / `E_SAVE`, written back once a block;
§8a); `-DCV_SPEC_ENGINE` maps those macros to the spec's procedure too.

## 5. Step 1: the A9's cost (measured 2026-10-01, the SuperStation rig)

Inputs: 10 s of a synthetic 720x480p59.94 source (a Mandelbrot zoom with temporal grain: busy
enough that x264 spends the bits -- the Sunshine captures are a near-static desktop), x264
`ultrafast` High CAVLC with a VBV at each requested rate (the actual rates are lower), and a
Constrained Baseline `medium` clip. `cavlc2cabac --bench` (the rewrite alone, from memory;
`-O2`, Cortex-A9 at ~800 MHz, measured by a calibration loop):

| Stream | Actual Mbit/s | Bins | CPU for 10 s of video | Share of one core |
|---|---|---|---|---|
| ultrafast, 4 M requested | 3.16 | 36.2 M | 4.86 s | **49 %** |
| ultrafast, 8 M | 6.33 | 69.3 M | 8.71 s | **87 %** |
| ultrafast, 10 M | 7.92 | 86.2 M | 10.63 s | **106 %** |
| ultrafast, 16 M | 12.87 | 144.8 M | 16.65 s | **166 %** |
| Constrained Baseline, 2 M | 2.12 | 25.8 M | 3.90 s | **39 %** |

A fit: **~109 ns a bin plus ~1.1 us a macroblock** (~11 % of a core at 97,200 macroblocks/s);
~1.1 bins a CAVLC bit, so **~12-13 % of one core per Mbit/s at 480p60** plus the fixed part. A
30 frames/s stream at the same bitrate costs the same per bit and half the fixed part.

**Through the core** (`h264play --realtime`, main's fabric `H264_mbpipe_20261001_1223.rbf`, the
rewrite on every access unit): 3.16 Mbit/s -- 600 / 600 pictures, errors 0, late 0, 48.6 % of one
core, the longest single access unit 21.5 ms (an IDR); Constrained Baseline 2.12 Mbit/s -- 38.9 %,
late 0; 6.33 Mbit/s -- 86.8 %, **517 late** (the rewrite cannot keep up). A control (the same
stream rewritten beforehand on the host, no rewrite on the ARM) has 0 late. `h264play` rewrites a
unit *before* its due time: after it, every picture reached the core late by its own rewrite
time (421 late at 3.16 Mbit/s).

**Main holds one core** (it polls: ~50 % of the dual-core total at the menu and with the core
loaded), so the rewrite and the client share the other: at 3.16 Mbit/s `top` showed Main ~50 %,
`h264play` 21-28 % (of the two cores), 20-25 % idle.

**The gate** (issue fj#20: "if 8 Mbit/s fits comfortably beside a client, proceed"): **it does
not.** The ceiling is ~4-5 Mbit/s at 480p60 beside a light client. The fabric fallback is
closed (84 % ALM after the macroblock pipeline), so the result is a ceiling to record, and the
choices of §8.

**Where the time goes on the A9** (a PC-sampling profile, `-O2`, inlined): the arithmetic coder
~31 %, the CAVLC block parse ~24 %, the significance maps ~25 %, the levels ~18 % (outermost
functions), spread across both sides. Tried without gain on the A9: a branchless bin update, a
single unaligned load for the bit reader, local copies of the engine / reader state (slower),
`-O3` / `-marm` (<= 5 %). The structural rework was then tried (§8a, option A): -8 %, not 2x.

## 6. Verification

`bench/h264/run_cavlc.sh [--red] [--quick]` (bench/h264/README.md), host only:

- **[pixels]** ffmpeg's frame MD5s of the original == of the rewrite decoded with
  `-err_detect explode -xerror`: **every** rewritable stream -- x264 (ultrafast, Constrained
  Baseline, High 8x8, B with temporal direct + weighted P + 4 references, 4 slices, QP 4), JM
  (field pictures + P_8x8ref0, Intra_8x8, B), the synthetic paths, and all **70 rewritable CAVLC
  streams of the H.264.1 AVCv1 package** (Baseline, Extended-free Main, PAFF / field, PCM,
  weighted prediction, multi-slice, multiple references, cropping).
- **[refyuv]** the rewrite decoded == the conformance package's reference YUV (every stream
  that ships one, 61 arms).
- **[model]** `tools/cavlc_check.py`: the project's own CABAC model decodes the rewrite (every
  syntax element where the spec puts it), its bin count equals the rewriter's, the 7.4.2.10 limit
  holds per picture, the SPS / PPS rules hold.
- **[engines]** the byte engine and the spec's write identical bytes.
- **[verdict]** FMO, SP/SI, MBAFF (conformance + x264), 4:2:2, redundant pictures, data
  partitioning, ASO (an x264 clip's slices swapped), the Intra_8x8 all-zero case refused by name;
  an invalid code and a truncated slice errors.
- **[pass]** CABAC streams (51 conformance + x264) out byte for byte as they went in.
- **[cover]** the synthetic streams reach their paths (the rewriter's counters).
- **--red**: 30 mutations of a copy of the library (the CABAC derivations, the binarisations,
  the engine's carry and flush, the CAVLC parse, nC, the 8x8 interleave, neighbour availability
  across slices, P_8x8ref0, I_PCM, the 8x8 rule, `cabac_zero_words`, the bin count, the profile
  rewrite, each refusal, the pass-through), each caught by its own arm.

Last full run (2026-10-01): **ALL GREEN, 339 verdicts** (87 pixel-exact, 61 reference YUVs, 52
passed, 22 verdicts); `--quick --red` ALL GREEN, 30 / 30.

**The fabric's verdict** (2026-10-01): `run_cosim.sh --sweep --dir DIR --match 'cv_*'` on 26
rewritten streams -- the x264 and JM fixtures, every synthetic one, eight conformance streams
(fields, PAFF, I_PCM, weighted prediction, multi-slice) and the 720x480 6.3 Mbit/s bench stream --
**26 PASS** (and `z8_p8x8`, added after: PASS): the decoder's RTL reconstructs each pixel-exact against the model, with no error or
refusal. (A first run flagged the synthetic `zw` as ORACLE: at QP 26 its levels overflowed the
inverse transform's 16-bit intermediate range, 8.5.12.1 -- a non-conforming stream, model and
ffmpeg legitimately differing; it is now coded at QP 0, same bins.)

**On the rig**: rewritten streams decoded by the core, errors 0 (§5). **A lesson the rig taught
(fixed):** `bw_put(w, br_u(r, n), to - r->pos)` -- C leaves argument evaluation order
unspecified, and ARM's gcc read `r->pos` after `br_u()` had advanced it, so the ARM binary
dropped each slice header's tail; x86's gcc evaluated it first, and sanitisers cannot see it.
Found because the rig's output differed from the host's (`CLAUDE.md` "Lessons").

## 7. Tables

`tools/gen_cavlc_tables.py` transcribes Tables 9-4, 9-5, 9-7 to 9-10 from the spec PDF into
`tools/cavlc_tables.py` and cross-checks every code against ffmpeg's `h264_cavlc.c` /
`h264data.c`; `tools/gen_hps_tables.py` writes `hps/lib/h264ring_cavlc_tab.h` from it and from
`cabac_tables.py` / `high_tables.py` (never edited by hand; `--check` in the runner's [tables]
arm). The library is MIT (`hps/LICENSE`): the rewriter is written from the spec, no x264 / JM /
ffmpeg code.

## 8. Decisions (the maintainer, 2026-10-01)

1. **The CAVLC scoping decision is reversed: CAVLC is supported through the client library's
   rewrite, up to the A9's ceiling (~4-5 Mbit/s at 480p60).** The fabric still refuses CAVLC
   (`REF_CAVLC`) -- a program that does not rewrite sees the refusal as before.
2. **In the library, on by default in each client**: `h264play` (`--no-cavlc` to turn it off)
   and the Moonlight client (every decode unit; a refusal by the rewrite ends the stream like
   a core refusal; `moonlight.md`).
3. **The Jellyfin client: left as it is** (a CAVLC file still makes it ask the server for a
   transcode: its own check of the first access unit, so it never writes CAVLC). The options, if it is revisited:
   rewrite a CAVLC direct-play file / an ultrafast server's CAVLC transcode instead of retrying,
   and ask for a lower `MaxStreamingBitrate` (~4 Mbit/s) when the transcode is CAVLC; its host
   test's check (j) and mutation M2 change with it.
4. The ceiling is documented for integrators (`integrating/library.md`: ~11-12 % of one A9 core
   per Mbit/s at 480p60).
5. **Optimisation: asked what is possible** (2026-10-01; the answer, §8a), then **"rework the hot
   loops to see if we can boost the performance"**: option A done, measured -8 % (§8a); the
   ceiling stays ~4-5 Mbit/s. **Then decided (2026-10-01, the maintainer): the limit is accepted**
   -- "let's just accept the limited baseline bitrate". No further optimisation (not B, not the
   raw-bin input, §8a); CAVLC above ~4-5 Mbit/s at 480p60 plays late, counted, never wrong.
6. **The library's version: the maintainer had no preference; the default is kept** -- one
   number, `H264RING_LIB_VERSION` = the interface's. The rewrite adds library calls and changes
   no interface word, so it is backwards compatible and needs no bump of its own: it ships under
   the interface version current when it merges: **0.10** (`feature/hdmi-raster` merged first;
   the manual and the headers mark the write call's rewrite "(0.10)" since the rebase). A separate library version
   is worth having only once the interface is frozen (1.0) and the two can move independently.

### 8a. What a faster rewrite could be (the answer to decision 5)

Before option A: ~100 A9 cycles a bin all in (§5): the coder ~31 %, the CAVLC parse ~24 %, the
significance maps ~25 %, the levels ~18 %, spread over many small functions.

| Option | Expected | Cost, risk |
|---|---|---|
| **A. Restructure the hot paths, same algorithm**: one block coder per residual block holding the engine's state in local variables (written back once) and its output in a pointer reserved ahead (no per-byte growth check); the significance map from a bit mask (count of leading zeros) instead of a compare per position; the levels' unary prefix coded in a tight loop on one context; a cached bit reader in registers for each CAVLC block. The `cab_bin` that gcc leaves out of line costs ~45 cycles with its 8-register save; the first try (copying the state struct) did not reach registers -- it needs explicit locals | ~1.5-1.8x: ~55-65 cycles a bin, a ceiling of ~6-7 Mbit/s at 480p60 | 1-2 days; low risk: `run_cavlc.sh --red`'s 30 mutations and the `[engines]` arm (the spec's engine as the reference) catch a wrong byte |
| **B. The engine in ARM assembly** (as x264 has), on top of A | +10-15 % | days, and a second engine to keep identical (the `[engines]` arm would compare it) |
| **C. The other core** | none: Main busy-polls it (measured ~100 % of one core, at the menu and with the core loaded) | -- (Main is MiSTer's, not this project's) |
| **D. NEON** | little: entropy coding is serial; only the coefficient scans vectorise | -- |
| **E. The fabric** | a CAVLC parser in the front end: real time at any bitrate | 2,000-4,000 ALM at 84 % used: not without taking something out; an arithmetic encoder alone in the fabric would not help (the ARM would still have to write the bins somewhere the fabric reads) |
| **E'. Raw bins (not taken, the limit accepted)**: the ARM writes each bin as one bit and the front end reads it in place of its arithmetic decoder (context selection unchanged) | the coding side is ~63 % of the time after option A, most of it the arithmetic coder: maybe ~2x, unmeasured | an interface change (a stream-format flag), a bit reader and a mux at the decoder's output (unsized), the terminate bins and I_PCM alignment; a non-standard stream into the core |
| **F. Not paying it: ask the source** | the whole cost, where a source can be asked | a Jellyfin client can ask a CAVLC transcode for <= ~4 Mbit/s (§8.3); a Moonlight host can be set back to CABAC; phone video is usually 1-3 Mbit/s already |

Recommended: **F** where a client controls its source (cheapest, no risk), **A** only if a real
source needs 5-7 Mbit/s of CAVLC; not B-E.

**Option A, done (2026-10-01, the maintainer: "rework the hot loops")**, measured on the original
DE10-Nano rig (Cortex-A9 ~800 MHz, the rewrite alone, `cavlc2cabac --bench 2`, best of two, the
§5 inputs: ultrafast 6.33 Mbit/s and Constrained Baseline 2.12 Mbit/s), one change at a time:

| Variant | ultrafast 6.33 M: ns a bin | Baseline 2.12 M |
|---|---|---|
| before (the merged-for-review rewrite, `-O2`, Thumb-2) | 127.4 (8.83 s for 10 s of video) | 151.5 |
| + the levels' engine in locals | 124.9 | |
| + the 4x4 / 8x8 block coders | 125.7 | |
| + a CAVLC block reader in locals (`peek_at` / `vlc_at`, the trailing ones' signs at once) | 123.2 | |
| + the mvd and intra-mode bins | 120.9 (-5 %) | |
| + `-O3 -marm` on that one object (`hps/Makefile` `CAVLC_OPT`) -- **as built** | **116.4-117.2 (8.06 s, -8 %)** | **146.7 (-3 %)** |

Every ARM output byte-identical to the host's on both clips (the shipped `make arm` binary,
not a test build). So ~11-12 % of one core per Mbit/s at 480p60, the ceiling still ~4-5 Mbit/s:
the estimate of 1.5-1.8x was wrong. **Why** (a PC-sampling profile of the shipped flags): the
coding side is ~63 % of the time (the significance maps ~30 %, the levels ~18 %), the CAVLC parse
~26 %, the rest ~11 %; gcc already predicates the MPS / LPS choice in ARM code (no branch) and a bin
is ~20 instructions, with spills around them. What is left is the serial chain a bin cannot
escape -- the context's state, the LPS range table, the transition table, a count of leading
zeros and two shifts, each waiting on the last -- on a core that cannot overlap them. Option B
(assembly) would trim the spills, ~10-15 % at most; nothing in software reaches 8 Mbit/s on one
A9 core. The remaining ways stay F (ask the source) and E (the fabric).

## 9. In the write call (asked 2026-10-01, the maintainer: "move it to the library")

Programs no longer adopt the rewrite: `h264ring_write_au()` / `h264ring_try_write_au()` do it
(`hps/lib/h264ring.c` `rewrite_au()`; the handle owns a context, created on the first video
unit). The design points, each with an arm in `hps/tests/test_ring.c` ("rewrite:", 15 checks)
and a mutation in `tools/tests/red_h264.py`:

- **CABAC passes untouched**, and so does anything the rewrite does not need to touch: a slice
  whose PPS it never received (a stream joined mid-way), an SPS / PPS its parser cannot read
  (forgotten, not an error), a NAL unit with the forbidden bit. Only a CAVLC slice it must
  rewrite can fail. (Before the move, a missing PPS was an error: harmless when only programs
  that knew they had CAVLC called it, a regression once every stream goes through it.)
- **A retry is not rewritten twice**: the last rewritten unit is cached with a COPY of its input
  and compared byte for byte -- programs reuse one buffer for every unit (Moonlight's `au_buf`,
  Jellyfin's packets), so the pointer proves nothing. The cache is dropped once the unit is
  written, at every session start and flush, and by `h264ring_set_rewrite()`.
- **The stream resets with the interface's**: a session start, `h264ring_flush()`, and a
  DISCONTINUITY (explicit or the one owed after END_OF_STREAM) reset the context, inside the
  VIDEO_AU branch only (an AUDIO record between two units resets nothing).
- **Two new results**: `-EOPNOTSUPP` (refused), `-EBADMSG` (does not parse), the reason from
  `h264ring_rewrite_why(r)`. Neither reaches the status block -- the core never saw the stream --,
  which the manual says.
- **`h264ring_prepare_au(r, au, len, flags)`**: the rewrite before a paced unit's due time
  (`h264play --realtime`); the write of the same bytes then hits the cache.
- **`h264ring_set_rewrite(r, 0)`**: units written as given (`h264play --no-cavlc`).
- **The same picture written twice** (same frame_num / POC, first_mb 0) is refused as arbitrary
  slice order: the rewrite cannot tell a resend from ASO. A retry never gets there (the cache);
  a program resending a picture it already wrote would.
- **The library's version is unchanged** (decision 6): no interface word moved; the core checks
  the interface version exactly, so a library-only bump here would stop it attaching.
- `h264play` prepares each unit (its CPU report is the prepares'); the Moonlight backend is a
  plain writer again (it maps the two results); the cosim (`run_cosim.sh`, which builds the
  library as C++ -- the rewriter compiles as C++ since) gains `x264_uf_ring`: x264 ultrafast's
  CAVLC written through the library, the decoder RTL scored against the golden of
  `cavlc2cabac`'s rewrite.

## 10. Known limitations

- The ceiling (§5): above ~4-5 Mbit/s at 480p60 the rewrite falls behind; pictures are then
  late (counted), never wrong.
- One access unit of added latency at most (the rewrite runs before the write; an IDR took up to
  ~25 ms on the A9).
- `cabac_init_idc` is always 0 (a trial of all three would triple the cost).
- The Intra_8x8 all-zero case with `mb_qp_delta` is refused (§3); no known encoder emits it.
- Bounds above the spec maximum where the spec has none: `level_prefix` <= 28 (the spec reports
  <= 11 + bitDepth), |mvd| <= 32,767, 100 `memory_management_control_operation`s a slice (ffmpeg
  stops at 66), 64 MB a rewritten access unit (the ring's records carry at most 4 MB). Each is an
  error when exceeded, never a truncation.
- Not thread-safe per context (one context per stream).

## 11. Next concrete step

Merged (PR fj#25). A rig check
of the Moonlight client against a host forced to CAVLC (`nvenc_h264_cavlc`) at <= 4 Mbit/s.
Optimisation is closed (§8a: option A done, -8 %; the limit accepted, decision 5). The file
player (`docs/player.md` on its branch) gets the rewrite through the write call.
