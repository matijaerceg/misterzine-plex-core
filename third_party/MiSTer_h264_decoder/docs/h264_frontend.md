# Phase 3 — the H.264 bitstream front end

> **Harvested from MiSTer_UMD_Video at `cc595c6` (2026-09-27, this core's Phase 2).**
> This is UMD's design note for the front end (`h264/dec/` NAL → syntax elements), kept for its rationale: the module
> paths are rewritten to this tree (`umd/h264/` → `h264/dec/`, `umd/` → `h264/`,
> `bench/umd/` → `bench/h264/`), the rest is UMD's text. "Phase 3" and "roadmap" below
> mean **UMD's** phases and roadmap. UMD-only material is history here, not this core's
> design: the disc images (Akira, Family Guy, the library sweeps and their numbers), the
> program-stream demux and the ISO reader, the on-screen HUD, the vbuf and UMD's rig
> measurements. This core's differences: the fixtures (x264 and H.264.1 instead of discs,
> `docs/harvest.md`), the input (the ioctl stand-in, then Phase 3's ring:
> `docs/architecture.md`), the deviations (`docs/spec_hardening.md`, re-decided
> 2026-09-27). Changes made here after the harvest are marked **H264:** in place.


Design notes for `h264/dec/` (NAL → SPS/PPS/slice header → CABAC → syntax elements).
Status and checklist: `roadmap.md` Phase 3. This note records the *why* and what was
measured, starting with the oracle the RTL will be scored against.

## 1. The SE golden (landed 2026-09-23)

The front end's gate is a **bit-exact syntax-element stream**: every `mb_type`, `mvd`,
`coded_block_pattern`, every residual coefficient, in syntax order, compared against a
reference decoder. Pixels come later (P4, ffmpeg). The oracle chain:

```
H.264.1 package: stream + reference .yuv + Sony's 2004 -trace.txt
        │                                        │
        ▼                                        ▼
JM 18.4 ldecod (TRACE 1) ── pixels == .yuv     h264_trace_ref.py --jvt
        │ trace_dec.txt                          │
        ▼                                        ▼
h264_trace_ref.py --jm  ──── canonical == ──── canonical      (534,852 records, CABACI3_Sony_B)
        │
        ▼  on a disc slice: pixels == ffmpeg -fps_mode passthrough
   the RTL bench's golden (mb_syntax_tb, later)
```

Two independent tracers agreeing on every record over 300 I/P/B frames, four slices per
picture, all three `cabac_init_idc` values, proves the **normaliser**; JM's pixels being
bit-exact against the package's YUV and against ffmpeg on discs proves **JM parsed what
it traced**. Neither alone would do: a normaliser written from JM's code would share JM's
reading of the format, and a pixel match says nothing about which SE JM mislabelled.

### Files

| file | job |
|---|---|
| `tools/jm_build.sh` | builds `$H264_REFS_DIR/JM/build_trace/bin/ldecod.exe` with `TRACE 1` from a copy of the tree (`--clean` to redo) |
| `tools/jm_posix_compat.h` | the MSVC calls the tree uses unguarded (`_aligned_malloc`, `_fseeki64`, `__int64`), injected with `-include`; `-fcommon` for gcc ≥ 10 |
| `tools/h264_trace_ref.py` | JM trace / donated trace → canonical stream; `--jm` runs ldecod; `--disc x.iso --clip N --packs M` cuts a clip's video ES to whole access units and runs it; `--diff` |
| `tools/tests/test_h264_trace_ref.py` | synthetic traces in both formats from one description; with `$H264_REFS_DIR`, the CABACI3_Sony_B proof (SKIP without) |
| `tools/tests/red_umd.py` | three mutations of the normaliser, each caught by the test |

```bash
H264_REFS_DIR=... tools/jm_build.sh
H264_REFS_DIR=... tools/h264_trace_ref.py --disc disc.iso --clip 1 --packs 1500 --es x.264 --yuv x.yuv -o golden.txt
ffmpeg -i x.264 -fps_mode passthrough -f rawvideo -pix_fmt yuv420p x_ff.yuv && cmp x.yuv x_ff.yuv
```

### The JM tree, as found

`$H264_REFS_DIR/JM` is JM 18.4 with someone's research additions (VQ codebooks in
`bin/codebooks`, a residual-dump mode, `fastnn.c`). Both are off with
`-p VQdim=0 -p ResidualsOutput=0`, which `run_jm()` always passes; with them off the
decode path is stock, and the pixel checks above are the evidence. `TRACE` is a
compile-time constant that `#undef`s any `-D`, hence the patched copy. A pristine JM
19.0 would drop in unchanged: Main-profile decoding has not changed since 2003 and the
trace hooks are the same; there is no correctness reason to swap (a question raised
2026-09-23 and answered by measurement, not by version number).

### What the two trace formats actually say (all measured, none from documentation)

JM `trace_dec.txt`:
- Header fields as `@<bitpos> SPS:|PPS:|SH:|SEI:|VUI: name bits (value)`. `SH:` names
  are JM's (`num_ref_idx_override_flag`, `adaptive_ref_pic_buffering_flag`,
  `ref_pic_list_reordering_flag_l0`); the PPS default counts are traced under the SH
  name. `ALIAS`/`PPS_ALIAS` map them to the spec's.
- **JM traces the slice headers of a whole picture, and the next picture's first, before
  that picture's macroblocks** (it reads ahead to detect the picture boundary). Headers
  and MB groups are paired by order; `first_mb_in_slice` is checked against the group.
- CABAC SEs as `@<symbol#> name (value)` with JM's own values: **`mb_skip_flag` is
  inverted** (1 = not skipped); **P-slice `mb_type` is spec + 1** (I and B are the spec
  value); `intra4x4_pred_mode` is `-1` for "use predicted" else the rem mode; `mvd0_lX`/
  `mvd1_lX` for 16x16/16x8/8x16 partitions and `mvd_lX` for sub-partitions.
- **JM never decodes the `end_of_slice_flag` of a picture's last macroblock** (it stops
  on the MB count). The bitstream holds a `1` there, the donated trace prints it, and the
  RTL will decode it: the normaliser synthesises it when a group ends without one.
- Residual as `(level, run)` pairs, one `0 0` line per block end (also for a
  `coded_block_flag 0` block); block identity is NOT printed — the normaliser derives the
  expected block sequence from `mb_type`/`coded_block_pattern` (7.3.5.3) and checks the
  names against it. Chroma DC Cb then Cr; AC Cb×4 then Cr×4.

Sony's 2004 tracer (`-trace.txt` in the H.264.1 zips):
- `@<hex> : name : value : (bits) : [bitstring]`, spec values, spec-2003 names
  (`pic_order_present_flag`, `reserved_zero_5bits`).
- Every residual block is labelled with its **spec block index** (`luma.dc_ac : BK 9`),
  which cross-checks the normaliser's cbp→block derivation on every macroblock.
- The residual is the CABAC bin view (`significant_coeff_flag`, `last_...`,
  `coeff_abs_level_minus1`, `coeff_sign_flag` in reverse scan order; the last scan
  position inferred significant when the map runs out) — reconstructed independently
  of JM's run/level.
- `mb_skip_flag` is printed before the `+++ MB n` line it belongs to.
- **It prints no `mb_type` for an intra macroblock in a P or B slice.** I_NxN is
  recoverable (its first SE is `prev_intra4x4_pred_mode_flag`); Intra_16x16 carries its
  prediction mode inside `mb_type`, which is lost. Such a record is `E mb_type *`, the
  diff counts it (296 on CABACI3_Sony_B, all Intra_16x16 in P/B) and takes the block
  structure from the labels. Those 296 values are covered only by JM's pixel match.

### The canonical stream

One record per line, spec names, spec values (the tool's docstring is normative):

```
N <nal_unit_type> <nal_ref_idc>
S <field> <value>                  SPS / PPS / slice header, syntax order
M <mb_addr>
E <se> <value>                     prev_intra4x4_pred_mode_flag / rem_intra4x4_pred_mode, mb_skip_flag,
                                   mb_type, sub_mb_type, ref_idx_lX, mvd_lX, intra_chroma_pred_mode,
                                   coded_block_pattern, mb_qp_delta, end_of_slice_flag
B <kind> <idx> <n> c0 .. c(n-1)    LDC 16 | L4 <spec 4x4 idx> 16 (15 for Intra16x16 AC) | CDC 0/1 4 | CAC 0-7 15
```

Coefficients are stored as full arrays in scan order rather than JM's `(level, run)` or
the bin view, so the RTL's residual output can be scored whichever form `mb_syntax`
emits (that choice is made with the RTL, `roadmap.md` P3). Dropped from both sources:
`rbsp_*`, alignment and reserved bits, SEI/VUI payloads (P5 reads `pic_struct` itself),
JM's bit positions.

### Measured on discs (2026-09-23)

| slice | pictures | records | exercises |
|---|---|---|---|
| CABACI3_Sony_B (H.264.1) | 300 frames, 4 slices each | 534,852 | I/P/B, `cabac_init_idc` 0/1/2, temporal direct, B sub-partitions |
| Akira clip 1, 1500 packs | 243 frame pictures (3:2 `pic_struct`) | 4,082,899 | explicit weighted P (`luma_weight_l0`), one slice per picture, `num_ref_idx_l0_active_minus1 0` (no `ref_idx` coded) |
| Family Guy clip 1, 1500 packs | 748 **field** pictures | 3,575,149 | `field_pic_flag`/`bottom_field_flag`, `modification_of_pic_nums_idc_l0`, `ref_idx_l0`, field MB addressing |

Both disc slices: JM pixels == ffmpeg 9.0 pixels, byte-exact. **`-fps_mode passthrough`
is mandatory** on a 3:2 disc: ffmpeg's rawvideo output otherwise repeats frames to
29.97 (304 frames for Akira's 243) and the compare fails at frame 11 for no decoder
reason.

### Known gaps (open, tracked in `roadmap.md` P3)

- **I_PCM** has not been through the normaliser (no disc has it; `CAPM3_Sony_D` will).
  JM's `readIPCM_CABAC` tracing is unread; expect a new record kind.
- The `pred_weight_table`, `dec_ref_pic_marking` and list-modification field names are
  JM's, seen only on discs so far; the donated names are unverified until the
  conformance sweep (`CAWP*`, `MR9_BT_B`, `HCMP1_HHI_A`) runs both tracers.
- MBAFF (`mb_field_decoding_flag`), the 8x8 transform, SP/SI slices are refused loudly,
  never normalised — the same policy the RTL will have.
- `--disc` cuts at the last access-unit delimiter; a clip whose ES does not start on an
  AUD is refused (all 33 discs start clips on one).

## 2. The Python front end (landed 2026-09-23)

`tools/cabac_ref.py` (the arithmetic decoder, context initialisation, binarisation
helpers) and `tools/h264_fe_ref.py` (NAL units, SPS/PPS/slice header, the CABAC slice
data with every ctxIdxInc derivation) decode an Annex-B stream to the canonical SE
stream of S1 — the executable specification the RTL modules will each mirror.

### The tables come from the PDF, checked twice

`tools/gen_cabac_tables.py` runs `pdftotext -layout` on `T-REC-H.264-202606.pdf` and
parses Tables 9-12..9-24 (ctxIdx 0..459, four init sets), 9-44 (rangeTabLPS) and 9-45
(state transitions) into `tools/cabac_tables.py`. Two things about the extraction are
worth knowing: a table caption can start a page (form feed before "Table"), and a
two-digit negative in a narrow column wraps onto two lines ("−4" over "6" for −46 in
Table 9-14) — the horizontal tables are read by column position and the pieces of a
cell joined top to bottom. The result agrees value for value with **ffmpeg's**
`cabac_context_init_I/PB` (1787 defined cells, indexed by ctxIdx; the source is kept at
`$H264_REFS_DIR/ffmpeg/libavcodec/h264_cabac.c`) and, for 9-44/9-45, with **JM's**
encoder tables. `gen_cabac_tables.py --check` re-derives and compares; the test runs it.

### What the model is checked against

| stream | records | result |
|---|---|---|
| CABACI3_Sony_B (300 frames, I/P/B, 4 slices/picture, `cabac_init_idc` 0/1/2) | 534,852 | identical to JM's trace, no wildcards (the model knows every mb_type) |
| Akira clip 1, 1500 packs (243 frame pictures, weighted P) | 4,082,899 | identical |
| Family Guy clip 1, 1500 packs (748 field pictures, list modification) | 3,575,149 | identical |
| x264 synthetic (12 frames, 4 slices, B, 3 refs, weighted P; test time) | — | every slice ends on the picture's last MB, SEs in range, all 52 headers == ffmpeg `trace_headers` |

Each identical on the first run, which is what a decoder written from the spec text
should do; the RED arm (five mutations: a rangeTabLPS entry, the qCodIRangeIdx bits,
the mvd threshold, a coded_block_flag condTerm, a B mb_type context) proves the arms
can fail — a wrong context desynchronises the arithmetic decoder within a macroblock,
so even the refs-free x264 arm catches them.

Throughput of the model: ~1.4 Mbins/s in CPython (27 M bins for 1500 packs of a disc
in ~20 s), fine for goldens.

### The H.264.1 sweep (`tools/h264_conformance.py`, 2026-09-23)

All 135 AVCv1 packages: 33 decode, 102 are refused by name, 0 problems. Every decoded
stream is identical to JM's trace and JM's pixels equal the package YUV; the Sony-format
donated traces (10 packages) are identical too, after two more findings about that
tracer: an I_PCM macroblock is `pcm_alignment_bits` + 384 `pcm_coding_pixel` lines, and
in a P/B slice its `mb_type` is missing like every intra one (recovered exactly — I_PCM
has no other shape). Two other donation-time formats exist and are not parsed: an old
JM's (the `*_SVA_*` packages: `Luma sng( 4) level = 0 run = 0`, `CABAC terminating bit`
lines, no NAL lines) and Toshiba's CSV; those streams are covered by JM + pixels only.
The measured feature coverage of the 33 is in `roadmap.md` P3; the notable absence is
MMCO / long-term marking, which no CABAC stream in the package (nor either disc slice)
exercises.

`MV1_BRCM_D` (720x480, 19.9 M records, 113 M bins) is the largest: ~100 s in the model.

### Decisions recorded in the code, with the clause

- Direct-predicted partitions (B_Direct_16x16, B_Skip, B_Direct_8x8) contribute 0 to
  the ref_idx and mvd context derivations because their `predModeEqualFlagN` is 0
  (9.3.3.1.1.6/7), not because "mvd is 0" — the code tests the flag.
- A P_Skip/B_Skip neighbour gives `condTermFlagN = 1` for the luma cbp bins (9.3.3.1.1.4:
  the zero-condition requires "not P_Skip/B_Skip"); JM's `(cbp & bit) == 0 ? 1 : 0` agrees
  because a skipped MB has cbp 0.
- The mvd ctxIdxInc thresholds are `sum > 32 → 2`, `sum > 2 → 1` (9.3.3.1.1.7).
- B `mb_type` bin 2 uses ctxIdxInc 5 after b1 == 0 and 4 after b1 != 0; B `sub_mb_type`
  bin 2 uses 3 / 2 (Table 9-41). The intra suffix in P uses ctxIdxOffset 17, in B 32.
- After a terminate bin of 1 the bit pointer is just past the flushed `1`; I_PCM
  byte-aligns there, reads 384 samples, re-initialises the engine (9.3.1.2, 9.3.3.2.4).
  Exercised by `CAPM3_Sony_D` (4,123 I_PCM macroblocks) and `CAPCM1/CAPCMNL1_Sand_E`,
  identical to JM and to Sony's trace; the canonical record is `B PCM 0 384 ...`.
- Field pictures: the significance/last contexts move to 277/338; MB addressing is the
  field's; nothing else in the entropy layer changes (no MBAFF here).
- Register widths: codIRange 9 bits after renormalisation, codIOffset 9 (10 during a
  bypass) — the RTL holds exactly these.

### Refused, by name

`entropy_coding_mode_flag 0`, `mb_adaptive_frame_field_flag`, `num_slice_groups_minus1 > 0`,
`transform_8x8_mode_flag`, scaling matrices, `chroma_format_idc != 1`, bit depth > 8,
`redundant_pic_cnt > 0`, SP/SI slices, NAL types 2-4 (partitioning), 14/20 (SVC/MVC).
A `Refused` error names the field; the RTL will raise the same flags.

## 3. The engine in fabric (landed 2026-09-23)

`h264/dec/cabac_engine.sv` + `cabac_ctx.sv`, gated by `bench/h264/run_h264_cabac.sh`
against `cabac_ref.Cabac` (the module headers are the interface reference; this is the
why).

**Interface.** A held byte handshake in (`in_byte/in_valid/in_ready`, `in_last` on the
NAL unit's last byte) and a request/response port: kinds DECISION(ctxIdx), BYPASS,
TERMINATE, INIT(set, QP), ALIGN, RAWBYTE, REINIT, FLUSH — one registered response pulse
per request, in order. ALIGN/RAWBYTE/REINIT are the I_PCM path (9.3.1.2) at the engine
level, so `mb_syntax` never touches the bit buffer; FLUSH is what the parent issues
between NAL units (the buffer keeps up to 4 bytes of read-ahead that must not leak
into the next slice — the bench's flush pair proves it).

**Cadence.** A decision is accepted in an idle cycle (the context read is issued then)
and computed the next — context state, rangeTabLPS, subtract, compare, the bin, the
context write-back — ending at registers that hold the range and offset *before*
renormalisation; the renormalisation shift and the bit-buffer update happen in the
following idle cycle, which is also the cycle the next dependent decision is accepted
in. So: **two cycles per dependent bin, one per bypass/terminate (one more when it
follows a decision), every output registered.** Measured 0.52 bins/cycle on the random
mix (70 % decisions) — 42 Mbins/s at 81 MHz against the 2 Mbins/s average / 13 Mbins/s
Level-3 ceiling of `roadmap.md`: the engine is not the front end's bottleneck and no
speculation is needed. The caller's ctxIdxInc logic sees `rsp_bin` combinationally in
the response cycle; that path (bin → next ctxIdx → RAM address) lives in the caller.

**Renormalisation** is one barrel shift by the leading-zero count of the new range
(at most 1 on the MPS path, at most 6 on the LPS path since rangeTabLPS ≥ 6), not a
serial loop. The bit buffer is 32 bits, refilled a byte per cycle while ≤ 24 bits are
held (the byte lands at a position known from the count alone, then one shift by the
bits consumed), consumed 0..9 bits per cycle (9 at an engine init).

## 4. The macroblock layer in fabric (landed 2026-09-23)

`h264/dec/mb_syntax.sv`, gated by `bench/h264/run_mb_syntax.sh` (fixtures from
`tools/mb_syntax_golden.py`: real slices decoded by the model, the byte stream in and
the exact SE stream out). The executable specification is `h264_fe_ref.py`'s
`SliceDecoder`: every state is one of its decision points, in its order, with the same
ctxIdxInc derivations; the module header names the clauses.

**Scope.** Every Main SE with its ctxIdxInc derivation, the residual with significance /
last maps and level prefix / suffix, I_PCM (through the engine's ALIGN / RAWBYTE /
REINIT path), frame AND field pictures (the field's own macroblock grid and the
field-coded significance context ranges), `num_ref_idx` up to 32, PicWidthInMbs up to
128 (Level 3.0's MaxFS bounds it at 113). No MBAFF, no 8x8 transform, 4:2:0 only —
refused upstream, never reached here.

**Neighbour state (6.4.11).** The previous macroblock in decoding order lives in
registers (it is the left neighbour A whenever `mb_x != 0`, and prevMbAddr for
`mb_qp_delta`); the row above is a 128-entry line memory — one synchronous read at each
macroblock's start, one write at its end (the LUT-RAM lesson) — holding only what the B
derivations ask: the bottom row of 4x4 blocks, chroma blocks 2 and 3 of each plane, the
macroblock flags and the slice id (an entry is available iff its slice id is the
current slice's, which is how slice boundaries are honoured without a map). Per 4x4
block, per list: predFlag, `ref_idx > 0`, and |mvd| clipped to 33 per component — all
the ctxIdxInc rules ever compare against (9.3.3.1.1.6/7: sums against 2 and 32) — 6
bits each instead of a 16-bit motion vector difference.

**Structure.** Emission is generic (`S_EMIT` with a return state), as are the unary /
TU prefix, the Exp-Golomb suffix and the sign of the binarisations: an SE's states set
the parameters and the return state. The SE output is a held valid/ready stream, one
word per cycle at most: MB_START, the macroblock's SEs in syntax order, each residual
block as BLK_START then its coefficients in scan order (zeros included), END_OF_SLICE;
kinds are `tools/mb_syntax_golden.py`'s table.

**Throughput.** One engine request outstanding; the next is issued the cycle after the
response is consumed. Measured **0.16–0.26 bins/cycle** on the fixtures (13–21 Mbins/s
at 81 MHz; the Level-3 ceiling is 13 Mbins/s, UMD content ~2). The cycle accounting: a
dependent bin costs the engine's two cycles plus the issue and consume cycles around
it (about four), and a non-coefficient SE costs a two-cycle `S_EMIT` round trip. The
follow-up (`roadmap.md` P3: Mealy issue in every state, emission merged into the
issuing states) is taken only if the P3 HW gate shows the front end starving P4;
`run_mb_syntax.sh` prints bins/cycle per fixture, so the gain is measured, not
estimated.

**Gate.** Word-exact SE stream against the model on CABACI3 I/P/B, CAPM3 (I_PCM), an
Akira P slice, Family Guy I/P field slices and x264 I/P/B (refs-free); 12 RED
mutations, each caught by its own arm, including a frame/field context-range swap.

**H264:** the disc slices are replaced by H.264.1's `camp_mot_fld0_full` (an I field of
251k bins, a P and a B field: the field-picture context ranges), and M12 is caught on its
P field. Its **B field slice runs at 0.148 bins/cycle** (word-exact): under UMD's 0.16
Level-3.0 floor, on a dense field slice. `mb_syntax_tb` takes `+rate_min` per fixture and
the runner gates that slice at its own measured 0.14, so a regression still fails. The
front end's rate against this core's target is Phase 5's (`roadmap.md` D1: the CABAC front
end starves the reconstruction above ~8 Mbit/s, `p1_measurements.md` §3).
Standalone: 2,731 ALMs.

## 5. The chain in fabric (landed 2026-09-23)

`h264/dec/nal_parser.sv` → `rbsp_reader.sv` → `sps_pps.sv` / `slice_hdr.sv` →
`cabac_engine` + `mb_syntax`, composed by `h264/dec/h264_top.sv`; gated by
`bench/h264/run_h264_top.sh` (`tools/h264_top_golden.py`: an Annex-B stream in, the
model's whole record list — NAL words, every header field, every macroblock SE — out).
The module headers are the interface reference; the decisions:

- **`nal_parser`** holds a NAL unit's last byte back until the next start code says it
  was the last (at most one undecided byte plus a saturating count of zeros after it:
  two can precede an EPB or a start code, three or more only a start code). `in_flush`
  closes the stream by releasing the held byte as last — which is what `emu` needs at
  the end of a title (§6). 38 ALMs.
- **`rbsp_reader`** is bit-serial on purpose (a slice header is a few hundred bits; the
  longest legal one, a 32-reference `pred_weight_table`, ~4 kbit) and fetches only on
  demand, so after `cabac_alignment_one_bit` nothing of the slice data is buffered and
  the engine takes the bytes from the parser's output register. `more_rbsp_data()` from
  the last-byte flag and the stop-bit rule. 230 ALMs.
- **`sps_pps`** stores 32 SPS × 166 bits and 256 PPS × 44 bits in RAM (`h264_pkg.sv`),
  refuses by the model's names plus the fabric's own (a side > 128 macroblocks,
  `REF_SIZE`), and reports a value outside its 7.4.2 range as `ERR_RANGE` rather than
  aliasing it (the stores are spec-sized, so an out-of-range id would otherwise land on
  a legal one silently). The POC type 1 `offset_for_ref_frame` table is emitted, not
  stored: 255 × 32 bits × 32 SPS would be 27 M10Ks for a table no disc uses (the P4
  decision in `roadmap.md`). 1,156 ALMs.
- **`slice_hdr`** parses the whole 7.3.3 header including `ref_pic_list_modification`,
  `pred_weight_table` (both lists) and `dec_ref_pic_marking` (every MMCO), for frame
  and field pictures and POC types 0/1/2, and puts every field on the SE stream
  (`tools/h264_fields.py` ids) so P4 needs no second store. Loops a truncated stream
  could run forever end on the reader's `err_eos`. 608 ALMs.
- **`h264_top`**: the NAL machine (header byte read here, payload routed by type), the
  engine FLUSHed between slices (its 4-byte read-ahead must not leak), INIT per slice,
  the drain of whatever a consumer did not take, refusals and errors counted separately
  with their last code (`h264_pkg.sv`), and `nal_ended` remembering that a unit's last
  byte went to *some* consumer so a drain after a partial parse cannot wait for a byte
  already taken. SE kinds 17 (NAL word) and 18 (header field) beside `mb_syntax`'s 1..16,
  values 32-bit.

**Fit, standalone** (`.sim/synth_h264top`: the nine `h264/dec/*.sv`, `VIRTUAL_PIN`
on everything but `clk`, 81 MHz): **3,919 ALMs, 3,951 registers, 16 M10K (68 kbit:
the context RAM and init ROM, the row-above memory, the SPS and PPS stores), 3 DSPs**;
Fmax 87.77 MHz at 100 °C and 87.43 MHz at −40 °C against 12.345 ns, worst slack
+0.95 / +0.91 ns. The binding path is `mb_syntax`'s, not the new modules': `width_mbs`
→ the `S_MB_BEGIN` multiply-compare that derives the first macroblock's (x, y) → `state`
— the one DSP-fed path in the front end, and the first thing to retime (an incremental
row counter instead of `mb_y * width_mbs == mb_addr`) if `emu`'s fit needs margin. By
entity: mb_syntax 2,731, sps_pps 1,157, slice_hdr 608, cabac_engine 559 (contexts 86),
rbsp_reader 228, nal_parser 38, the top's own muxes ~400. The P3 checkpoint was ≤ 5K
ALMs for the front end.

**RED (`--red`, 18 mutations, each caught by its own arm):** EPBs kept (on the I_PCM
fixture: a normal x264 clip's EPBs all sit in its VUI and SEI, which are not decoded —
the first mutation to *survive* on the Main clip, for exactly that reason), the last
byte never flagged (caught by `[hang]`: the drain waits for an end that never comes),
the ue(v) suffix off by one, se(v) sign inverted, `more_rbsp_data` without the stop-bit
rule, the alignment run fetching a byte it will not consume (the engine then loses the
slice's first byte), `weighted_pred_flag` stored inverted, the High-profile SPS branch
skipped, `idr_pic_id` read for non-IDR slices, `slice_qp_delta` ignored, I slices on
init set 0, the chroma weight pair read once, the marking syntax skipped,
`field_pic_flag` never read (the field fixture), the engine not flushed between
slices, refusals counted as errors (`[refuse]`), the unary cap removed (`[hang]` on the
truncated fixture). A "skip the alignment run" mutation turned out to be an
*equivalent mutant* — the bits it consumes are the held byte's alignment ones, which no
consumer needs — and was dropped rather than kept as a false arm. Fixture ranges are
asserted by the runner, not assumed: the fade carries luma and chroma weights, a list
modification and an MMCO; the noise clip carries I_PCM macroblocks and EPBs; each
truncation lands where it claims.

**What the bench found.** On conformant streams, nothing in the RTL: the chain was
identical to the model on the x264 clip at the first run, then on every other fixture.
The **no-hang arm** (the Main clip cut inside a slice header, and inside slice data)
found two real ones: (1) `mb_qp_delta`'s and `ref_idx`'s unary binarisations were
unbounded, and a stream that runs out (the engine reads zeros past `in_last`) decodes
MPS = 1 for ever — the slice never ended. The spec bounds them (53 and 32 bins) and the
UEGk prefixes (k < 15 for any legal `mvd` or level), so `mb_syntax` now abandons the
slice with `err_bins` at 63 unary bins or a 16th prefix bin, which the top counts as
`ERR_RANGE`; (2) a slice whose header consumes the unit's last byte left INIT waiting
for nine bits the engine could never get (it never sees `in_last`): `ERR_EMPTY_NAL`
before the INIT. Neither is visible on any conformant fixture; the P3 HW gate's "no
hang on a full film" rests on this arm. In the harness: `mb_syntax`'s `done` being a
level (the wait state above), a `grep -q` closing the model's pipe, the standalone
fit's 570 output pins (virtual pins), and a runner edited while its background run was
still reading it (never again: the run dies mid-way and looks like a partial log).

## 6. In `emu`: the clock crossing, the flush and the readout (2026-09-23)

`h264/emu.sv` composes: `ps_demux` (clk_sys) → `h264/vidfeed_cdc.sv` + `h264/fifo_dc.sv`
→ `h264_top` (clk_dec) → an always-ready sink that counts SE words (P4 replaces it with
its FIFO); `es_probe` beside the demux; the front end's counters back to the HUD
through `h264/cdc.sv`'s `cdc_snap`. Gated by `bench/h264/run_p3_chain.sh`
(`bench/h264/p3_chain_tb.sv`, `tools/p3_chain_golden.py`) and, in `emu` itself, by
`tools/check_emu_wiring.py`. Decisions:

- **The CDC is the harvested `vidfeed_cdc`** (`harvest.md`, class S), with an own
  `fifo_dc` (gray-code pointers, Cummings; the DVD's wrapped the MPEG-2 tree's Xilinx
  FIFO), one reset per clock domain instead of one shared, and the read side presenting
  a *held* valid to `h264_top` (the DVD decoder consumed on a pulse). The DVD's 3-state
  pull adapter is kept verbatim for the reason its header gives: at most one pop in
  flight, never an unconsumed head overwritten — the "pop whenever the head looks
  free" shape dropped a byte and garbled every clip there. 32 deep: `ps_stream_fifo`
  and the reader's 16 KB cache are the real buffering; the CDC's job is the crossing.
  Backpressure is real end to end: FIFO full → `vid_ready` low → the demux stalls →
  `ps_stream_fifo` fills → `umd_reader`'s `busy`. `es_probe` therefore counts a video
  byte on valid AND ready now (the checker pins it: a count on valid alone counts
  every stalled cycle as a byte, and the P2 CRC would have "matched" nothing).
- **The end-of-title flush.** `nal_parser` releases a NAL unit's last byte only when
  the next start code arrives; the title's final unit has none, so `vidfeed_cdc` turns
  `umd_reader`'s `title_done` (a clk_sys level: every item streamed, the cache drained)
  into one `es_flush` pulse — after the level has crossed AND the FIFO and the head have
  *then* been quiet for 4096 clk_dec cycles (~50 µs). The window exists because
  `title_done` says nothing about the bytes still inside `ps_stream_fifo` and the demux
  (a few dozen, moving at a byte per clk_sys cycle: an order of magnitude inside the
  window). Counted from the level's arrival, never before it: the chain bench's first
  run caught a flush 4 cycles after the level, because the FIFO had been quiet for ages
  while the last pack was still upstream — a title whose last bytes arrive in the same
  breath as `title_done` (the reader waiting on the card, then draining) would have
  lost them. One pulse per title; `rd_flushed` shows on the HUD (`FLUSH 1`).
- **Reset.** A mount or an eject resets the whole front end (`fe_rst_n`: 16 clk_sys
  cycles, so the 3x faster clk_dec side sees it), released into clk_dec through
  `cdc_reset` (asynchronous assert, two-flop release). Both FIFO sides, the parser
  chain and its parameter-set store start clean per title; `h264_top`'s `clear` is
  therefore tied off. Nothing arrives in the window: the reader has a whole image walk
  to do before the first pack.
- **The readout crosses through one `cdc_snap`** (a four-phase toggle handshake: the
  destination asks, the source latches all 329 bits in one of its cycles, the
  destination copies), so every number on screen is a value the counters held in the
  same clk_dec cycle — never a tear between bits that per-bit synchronisers make of a
  counter mid-carry. `sys_top.sdc` keeps clk_sys and clk_dec in one exclusive group, so
  the crossings are timed transfers; the handshakes are about one launch edge per
  captured value, not about false paths. A third helper, `cdc_pulse`, exists for later
  event crossings (a toggle + two flops + an edge). The HUD grew from 8 to 16 plane
  rows (14 fit on the 480-line raster) for three more lines: `H264 NAL / SLICE / PIC`,
  `SPS / PPS / REF n/code / ERR n/code`, `SE / BINS / FLUSH`; and `STALL` on the packs
  row — clk_sys cycles the demux spent waiting on the front end, which is the one
  number that says whether the front end or the SD path is the slower stage.

**The chain bench** (`p3_chain_tb`) is `emu`'s composition with two real clocks: a
reader-shaped pusher (a byte per two clocks, `busy` read combinationally) →
`ps_stream_fifo` → `ps_demux` → `vidfeed_cdc` → `h264_top`, `es_probe`, `cdc_reset`,
`cdc_snap`, `title_done` raised after the last byte. Scored: the SE stream word-exact
against the model through the demux and the crossing, the counters, the probe's byte
counts and CRC (every byte reached its sink exactly once), the flush ≥ 4096 cycles after
the level, the snapshot copies monotonic and ≤ the live counter with the final copies
equal, no hang, idle at the end; `+stall` (a random-ready SE sink) drives the whole
backpressure path and the runner requires it to have actually stalled both the demux
and the pusher (a fixture-range check, not a hope); a 73 MHz clk_dec run shakes the
CDC phases with a non-integer ratio. Fixtures: the x264 Main clip packed into synthetic
packs with audio interleaved (`p3_chain_golden.py --x264`, refs-free) and, with
`$UMD_ISO_DIR`, 120 verbatim packs of Akira (frames) and Family Guy (fields) — cut
mid-NAL, so the flush turns the cut unit into exactly one expected error (the golden is
built as a truncated stream). RED: 6 mutations, each caught by its own arm — the FIFO
never full, its gray conversion dropped, the adapter popping from every state (the
DVD's original defect), the flush never issued, the flush without its window, the
snapshot never answered. Two equivalent mutants were dropped rather than kept as false
arms: `rd_valid` as the DVD's consume pulse survived (a valid that follows ready breaks
the protocol but loses nothing — the head still waits for ready), and a reset released
asynchronously has no metastability to show in RTL simulation (covered by
construction). The first RED run also had the missing-flush mutant land in `[hang]`
rather than `[flush]` — the flush wait was longer than the hang budget — a harness
defect worth writing down: an arm's timeout must be shorter than every arm that could
fire first.

**Measured on the synthetic clip:** 0.16 bins/cycle end to end, and the demux waiting
on the front end 88 % of the time — on a 720x480 CRF-28 x264 stream that is far denser
than any disc (13 Mbins/s, the Level-3 ceiling, against ~2 on UMD content). The HW
gate's `STALL` and `PACKS/S` readouts decide whether the throughput follow-up (§4) is
needed.

**The HW gate (2026-09-23, `UMD_p3h264_20260923_2237.rbf`, SEED 1 first roll, clk_dec
94.72/92.29 MHz, 12,959 ALM) — passed.** Akira, frame-coded, the whole film from the
rig's NAS share: 180,198 pictures (its full 125 minutes), `ERR 0`, `REF 0`, `FLUSH 1`,
the reader done, CRC equal to the P1 tool; 188 slices/s ≈ 8x real time, ~14 Mbins/s =
0.18 bins/cycle — the bench's figure on silicon. Family Guy, field-coded, the whole
22.6-minute title: 81,304 field pictures, `ERR 0`, `REF 0`, `FLUSH 1`; 570 fields/s ≈
9.5x real time. `STALL` saturated within minutes on both: the demux waited on the front
end ~95 % of the time, so the front end sets the pace at 8-9x real time and the SD path
(~800 packs/s) is not the limit. That settles the throughput question the §4 follow-up
was waiting on: not needed for P4. Zero errors on ~15 GB of stream across the two
coding styles; nothing in the HUD moved that should not have, and `SPS`/`PPS` climbing
(one per GOP) is the discs, not the parser.

## 6b. The compressed-video buffer (P6a, 2026-09-27)

`h264/vbuf.sv` sits between `ps_demux` and `vidfeed_cdc`: the demux's `{pts, mark, byte}`
go into a **2 MB ring in DDR3** (ram1, word `0x0628_0000`, right after the DPB's 20
stores; `ddr_mux2`'s master B) and come out, in order and unchanged, to the CDC.

**Why.** It is the decoder's CPB, which a multiplex assumes (H.264 Annex C; Level 3's
MaxCPB = 10,000 kbit = 1.25 MB). Without it the video path held 32 bytes, so the demux ran
ahead of the display only as far as free picture stores reach (~16 pictures), and audio
the multiplex carries up to 0.55 s behind the video reached its decoder late: Family Guy
on the rig (`at3p_decoder.md` S7.8). The maintainer chose the DDR3 ring over ~100 KB of
M10K (not the spec maximum, and the M10K P7 wants), 2026-09-27.

**Shape.** Everything that counts is on clk_sys: the byte position (`wpos` / `rpos`), a
queue of `{position, PTS}` stamps for the marked bytes (a mark is the first payload byte
of a PES with a PTS: `h264_top`'s `au_pts` associates by position, so the stamp must come
out on the same byte), the flow control (bytes held under the ring less 2 KB; the stamp
queue not full), and the burst descriptors (8 words, the ring's end, or 256 idle
cycles). The clk_mem engine only moves words: a described write burst, else a read burst
of up to 8 into the read FIFO when it has room. Bursts of <= 8, the envelope every client
of this port is built to. The title's end: once `title_done` has been quiet 4096 cycles
the partial word goes out padded (the padding never leaves) and `flush_out` rises when
every byte is out -- that is now `vidfeed_cdc`'s `wr_flush`.

**The DDR3 rules kept.** The engine never withdraws a command (the reload hang,
`hil_harness.md`): a mount's clear is a req / ack handshake -- the engine finishes the
command it presents (an open write burst completed, with zeros if its words are gone;
read beats owed swallowed), resets its side, acks; both sides of every dual-clock FIFO
are in reset together while nothing moves. The engine resets with the PLL lock alone.
`ddr_mux2`'s master B gained write bursts (they pin the grant; no write while any read
is outstanding; a blocked B write holds the grant). Building its bench found a latent
mux bug: the grant could go to B in the cycle an orphan write opened A's burst
(`run_disp_reader.sh` X12).

**Sizing with the audio ring.** Whichever buffer fills first paces the demux: at disc
bitrates (1-2 Mbit/s) 2 MB is 8-16 s of video, so the 32 KB audio ring (1.4-2 s) paces
it, and the run-ahead is the audio ring's. Only at the spec's 10 Mbit/s would the vbuf
(1.6 s) pace. Before the first picture the audio ring is what fills; the gate's
pre-anchor drops fire only if the first picture takes longer than that ring's seconds.

**Gates.** `bench/h264/run_vbuf.sh --red` (the vbuf through the real mux and `ddr_model`
beside a live master A: every byte, mark and PTS against the stimulus list; a mid-stream
clear, one timed onto a held read; ring wrap; the title's end; flow control; 8
mutations), `run_disp_reader.sh --red` (the mux, X8-X12), `run_scaffold.sh` (W15,
W42-W44). **HUD:** none (the 64 field ids are spent); telemetry `vbuf_fill`,
`vbuf_max`, `vbuf_bp`, `vbuf_late`.

## 7. Next

- Merged (PR fj#4, 2026-09-23). Phase 4, the reconstruction: the typed SE FIFO
  with backpressure from P4 replaces the counting sink (the front end has ~8x headroom,
  so the FIFO's depth is about smoothing, not rate). The POC type 1 offset-table
  decision is taken (2026-09-23, with the user): 🚩 a recorded deviation from the spec
  maximum — P4 caches the full-length tables of the two most recently received type-1
  SPSs and refuses loudly on eviction; `spec_hardening.md` "Known deviations" is the red
  flag to read if a type-1 stream ever fails.
- The `mb_syntax` throughput follow-up (§4) stays an optimisation, not a prerequisite.
