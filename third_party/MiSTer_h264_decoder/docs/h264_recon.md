# Phase 4 — the H.264 reconstruction and the DPB

> **Harvested from MiSTer_UMD_Video at `cc595c6` (2026-09-27, this core's Phase 2).**
> This is UMD's design note for the reconstruction and the DPB, kept for its rationale: the module
> paths are rewritten to this tree (`umd/h264/` → `h264/dec/`, `umd/` → `h264/`,
> `bench/umd/` → `bench/h264/`), the rest is UMD's text. "Phase 4" and "roadmap" below
> mean **UMD's** phases and roadmap. UMD-only material is history here, not this core's
> design: the disc images (Akira, Family Guy, the library sweeps and their numbers), the
> program-stream demux and the ISO reader, the on-screen HUD, the vbuf and UMD's rig
> measurements. This core's differences: the fixtures (x264 and H.264.1 instead of discs,
> `docs/harvest.md`), the input (the ioctl stand-in, then Phase 3's ring:
> `docs/architecture.md`), the deviations (`docs/spec_hardening.md`, re-decided
> 2026-09-27). Changes made here after the harvest are marked **H264:** in place.


Design notes for `h264/dec/recon_*.sv` and the units under it: the syntax-element
stream of the Phase 3 front end (`h264_frontend.md`) in, decoded pictures in DDR3 out.
Status and checklist: `roadmap.md` Phase 4. This note records the *why*, the interfaces
the units compose through, what was measured, and what is deliberately not built.

**✅ MERGED (PR fj#6, 2026-09-25); ✅ HW-CONFIRMED.**

**HW (2026-09-24):** the smoke build (`UMD_p4recon_20260924_1056.rbf`, a1a788c, the
reconstruction on clk_sys) decoded Akira's opening and Family Guy's field-coded title
cleanly on the rig: the P4 row's ERR 0, ~5 frames a second at 27 MHz.

**Status (2026-09-24):** the whole reconstruction (`recon_top.sv`) is bit-exact against
the model, per macroblock before deblocking and per picture in DDR3 after it, on x264
clips of every prediction mode, H.264.1 conformance field / PAFF / weighted / long-term
streams and two disc windows (Akira frames, Family Guy fields) — §5. It is wired into
`emu` behind the front end with the decode-order smoke display (§4).
**Every P4 exit criterion met on one build (2026-09-25, `UMD_p4recon_20260925_0016.rbf`):**
the reconstruction 11,470 ALM, the core 25,054; clk_dec 93.67 / 92.18 MHz; 1,843 /
1,639 cycles a macroblock on the disc windows (from 4,000-7,700 at first light), real
time on the rig: Akira 29.1 frames/s (1.21x), Family Guy 62.0 fields/s (1.03x), ERR 0
(§6).

## 1. The oracle: `tools/h264_recon_ref.py` (landed 2026-09-23)

The reconstruction's golden is **pixels**: H.264 reconstruction is exact by
specification, so every macroblock the RTL lands is compared bit-exactly. Two oracles,
one chain:

```
Annex-B stream ─► h264_fe_ref.py ─► canonical SE records (N/S/M/E/B) ─► h264_recon_ref.py ─► pictures
                                                                            │
                          ffmpeg -fps_mode passthrough (discs, x264 clips)  ═══ bit-exact
                          the H.264.1 package's reference .yuv (conformance) ═══ bit-exact
```

`h264_recon_ref.py` is the **executable specification of `recon_top`**: it never sees
the bitstream, only the SE stream the RTL consumes, and does in the spec's own terms
everything the fabric will do — POC (8.2.1, types 0/1/2), reference marking (8.2.5:
sliding window, every MMCO), frame and field reference lists with modification
(8.2.4), intra prediction (8.3), MV prediction, P_Skip, spatial and temporal direct with
the co-located derivation of Tables 8-6/8-8 (8.4.1), quarter/eighth-sample
interpolation and explicit/implicit weighted prediction (8.4.2, 8.4.3), scaling and
transforms with the zig-zag and field scans (8.5), I_PCM, deblocking (8.7). Clause
numbers sit beside the code. Its independence from the RTL is what the ffmpeg / YUV
match buys: a model written from the RTL would share its bugs.

**Proven (2026-09-23)** bit-exact against ffmpeg on x264 clips made at run time (intra
only; multi-reference P; spatial-direct and temporal-direct B; explicit weighted P and
bi-predicted B; with and without the deblocking filter), on 68 Akira frames (frame
pictures, weighted P, 3:2) and 86 Family Guy field pairs (I fields; the inter-field
window is checked below), and against the reference YUVs of the H.264.1 CABAC
streams (`tools/h264_conformance.py --recon`; the sweep's result table is in §1.1).
The two bugs it had on first contact were both found by the pixel diff: a corner
sample indexed as `top[-1]` (Python wraps it to the last element; the spec's
p[−1,−1]) in Diagonal_Down_Right, and a tC0 row transcribed one entry short.

Display order in the model is per coded video sequence by PicOrderCnt (an IDR or an
MMCO 5 starts a sequence), cropped, a field pair as one frame — what ffmpeg outputs.
That is enough to *compare*; the bumping process of C.4.5.3 is P5's concern, where
the display reads from the DPB. A clip cut after a first field ends on an unpaired
field the model outputs and ffmpeg does not; the checker says so explicitly rather
than failing.

Speed: ~0.7 s per 720x480 frame (numpy for the interpolation and the transforms,
plain Python for the per-4x4 decisions and the deblocking lines). Enough for the
unit vectors and for picture goldens of a few hundred frames per disc.

Known gaps of the model (loud, never silent): `gaps_in_frame_num` (8.2.5.2, the
"non-existing" frames) raises; a non-paired field's colocated use in the other
parity raises. Neither occurs on the 33 discs (the census: no gaps allowed, every field
paired) nor in the CABAC conformance set.

### 1.1 Conformance and discs (the pixel arm)

Filled by `tools/h264_conformance.py --recon` (`docs/conformance.md` carries the table
once the sweep finishes) and by the disc windows below.

## 2. The architecture

The doctrine (`roadmap.md`): 12.4 Msamples/s of 4:2:0 against 81 MHz means **serial**
units — one sample, one tap, one coefficient per cycle — sharing one datapath across
states. The budget per macroblock at 720x480 is 2,500 clk_dec cycles at 23.976 fps
(2,000 at the Level 3.0 ceiling of 30 fps).

```
h264_top ─SE─► se_fifo ─► recon_top ──────────────────────────────────────────────┐
                            │  parameter store (SPS/PPS fields P4 needs, by id)    │
                            │  slice header capture → POC → marking → lists →     │
                            │  weights; the MB sequencer                          │
                            ├─► mv_pred      (8.4.1: neighbours, direct, skip)    │
                            ├─► inter_pred   (partitions → windows → mc_interp → wpred)
                            ├─► intra_pred   (8.3, from the neighbour lines)      │
                            ├─► dequant_itrans (8.5) ─► + ─► cur_mb (pre-deblock) │
                            ├─► deblock      (8.7: bS, edge filter, line buffers) │
                            └─► dpb_mem ◄──── windows / writeback / side info ◄───┘
                                  │ clk_dec ↔ clk_mem FIFOs
                                  ▼
                              ddr_mux2 ─► DDRAM (ram1): 16 frame stores
                                 ▲ read-only master B: disp_smoke (P4 smoke display, §4)
```

### 2.1 Why the reconstruction reads the headers from the SE stream

`h264_top` holds the last slice's parameters on `sp_*`, but a FIFO sits between the
front end and the reconstruction, so those registers may already describe the *next*
slice when the reconstruction reaches this one's macroblocks. Every header field is on
the SE stream as a `K_HDR` word (P3 emitted them for exactly this), so `recon_top`
captures what it needs from the stream, in order, and keeps its **own** store of the
parameter-set fields it uses (SPS: 32 entries, PPS: 256 entries, in M10K — spec
maxima), keyed by id from the slice header's `pic_parameter_set_id` word. The model
does the same (`parse_*_records`): the stream is the whole contract.

### 2.2 Memory: 20 frame stores in DDR3, side info beside the samples

- **Stores.** A store holds one frame: the luma plane (stride = `2 * PicWidthInMbs`
  64-bit words, `16 * PicHeightInMbs` rows of the FRAME), then Cb, then Cr (stride
  `PicWidthInMbs` words, half the rows), then the **side info** the co-located
  derivation reads: one 64-bit word per 4x4 block, 16 per macroblock, indexed by the
  macroblock address in the picture *as it was coded* — a frame's addresses, or the
  top field's then the bottom field's (a frame coded as two fields keeps both,
  because Table 8-6/8-8 addresses the colPic as it was coded). A word is
  `{intra, pred_used, refIdxCol[4:0], ref_code[7:0], mv_x[15:0], mv_y[15:0]}` — the
  list-0 vector if predFlagL0 else the list-1 one (8.4.1.2.1). Sixteen entries per
  macroblock is the spec maximum (`direct_8x8_inference_flag` 0 is legal below Level
  3.0 — the Level 2.1 orphan in the census); a Level 3.0 stream reads the corners.
- **Sized to Level 3.1** (interface 0.11, 2026-10-02: 720p; Level 3.0 until then). Per
  macroblock a store needs 256 B luma + 128 B chroma + 128 B side info = 512 B; Level 3.1's
  MaxFS of 3,600 macroblocks (1280x720) gives 1,843,200 B, so a store is a fixed **2 MiB
  (2^18 words)** and the store index is the address's top bits (`store << 18` in
  `recon_mb`, `recon_inter`, `recon_mb_fsm.svh`'s co-located read and `disp_reader`: four
  sites, each pinned by a `--red` arm -- `run_recon_top.sh` S1-S3, `run_disp_reader.sh` H1).
  A picture above 3,600 macroblocks is a stream above Level 3.1 and is refused loudly
  (`recon_top`'s `ref_size`, word 20's `rc_ref_size`; word 81's `cap_max_mbs` tells programs
  the bound) before a sample is written. **The refusal is decided before `recon_dpb` sees the
  slice** (2026-10-02: `recon_top` delays `recon_dpb`'s `slice_ready` one cycle and gates it
  with the size, registered from the SPS `recon_hdr` activates on that pulse): until then the
  picture was opened in a store before `R_SIZE` refused its slices, and at the end of stream
  the never-written store was emitted -- the display showed whatever that store held last.
  Found by `run_recon_top.sh`'s refusal arm (`big`, +expect_refused), pinned by S6. A 2 MiB
  store would hold 4,096 macroblocks; the bound is the level's, not the store's. (1 MB stores and Level 3.0's 1,620 until 0.11.)
- **Twenty stores = 40 MB** at word `0x0640_0000` (byte `0x3200_0000`), `h264_pkg`
  `NSTORE`: above the HPS interface's ring (`0x3180_0000`, 8 MB), so the control block
  (`0x3140_0000`, where the 1 MB stores used to end) and the ring kept their addresses
  (`architecture.md` "The DDR3 map"). MaxDpbFrames is
  `Min(MaxDpbMbs / (PicWidthInMbs * FrameHeightInMbs), 16)`: 6 at 720x480, but 16 for
  a picture of 506 MBs or fewer (480x272 is 510: 15; CIF 396: 16) -- 16 references + the
  current picture + the display's two held stores = 20. A store is free when neither
  field is marked "used for reference", it is not the current picture and the display
  does not hold it (`disp_hold`). A store index is 5 bits; a reference's identity code
  `{valid, store[4:0], parity[1:0]}` 8 bits. (16 stores until 2026-09-24: short of
  the spec for small pictures; the r16 chain clip -- 16 references at 64x48 -- breaks
  at picture 17 with 16 stores, R9.) From P5 the pictures waiting for output in
  B-frame reordering also hold stores; they count inside MaxDpbFrames.
- **Field pictures** write and read a store line-interleaved: a field's line y is the
  frame's line `2y + parity`. Reference fetches for a field picture double the stride
  and add the parity; the chroma vector gets the Table 8-10 parity offset.
- **`ram1` through `ddr_arb`**, the DPB client as the priority master. The display
  reader (P4 smoke, then P5) is a *read* master, and `hw_budget_and_lessons.md` §2 says
  a second read master on the same port is exactly what costs the decoder: it goes to
  `ram2` (`architecture.md` has the recipe) when it is more than a smoke test.

### 2.3 The per-macroblock sequence and the writeback rule

1. **Intake.** The SE words of one macroblock go into a descriptor (registers: type,
   sub-types, modes, refs, mvds, cbp, qp delta) and a coefficient RAM (27 blocks x 16,
   16-bit, in M10K). Double-buffered: MB n+1 is parsed while MB n reconstructs.
2. **Motion / modes.** `mv_pred` derives the 4x4-block motion (8.4.1) from the left
   macroblock (registers) and the row above (a line memory of the bottom 4x4 row of
   every macroblock in the row: mv, ref index, ref identity, pred flags per list, plus
   the intra flag and the Intra4x4 modes — 128 entries, spec width). Direct modes read
   the co-located macroblock's 16 side-info entries from DDR3 (16 beats).
3. **Prediction.** Inter: per partition, the reference window (`(w+5) x (h+5)` luma,
   `(w/2+1) x (h/2+1)` chroma) is fetched into a window RAM (two, ping-pong, so the next
   partition's fetch overlaps this one's filtering), `mc_interp` produces one sample per
   cycle, `wpred` weights (default / explicit / implicit) into the prediction buffer.
   Intra: per 4x4 block (Intra_4x4 interleaves with the residual), per macroblock
   (16x16, chroma) from the unfiltered neighbour lines (a pixel line memory of the
   bottom row of each macroblock: 16 luma + 8 + 8 chroma bytes per macroblock; the left
   column from the current-macroblock buffer; the corner saved before it is overwritten).
4. **Residual.** `dequant_itrans` streams each coded block's 16 coefficients in scan
   order and 16 residual samples out; the adder clips into `cur_mb` (384 bytes, the
   picture-construction-prior-to-deblocking of 8.5.14).
5. **Deblock.** In-order, one macroblock at a time, exactly as 8.7 is written: the
   left edge modifies the left macroblock's right three columns (kept post-filter in
   `prev_mb`), the top edge modifies the macroblock above's bottom three rows (kept in
   the deblock line memory: 4 luma rows + 2 rows per chroma plane per macroblock
   column, 96 bytes x 128 = 12 KB).
6. **Writeback.** A macroblock's samples are final only after its right and lower
   neighbours filtered their shared edges, so the write to DDR3 lags: after
   deblocking MB (x, y) the client writes **MB (x−1, y) luma rows 0–11 and chroma rows
   0–6** (all columns final now) and **MB (x, y−1) luma rows 12–15 and chroma row 7**
   (final now). The end of a row and the end of the picture flush what is left. 48
   beats per macroblock, no partial rewrites, no full-row picture buffer.

Per macroblock the DDR3 traffic is ~48 write beats + ~50-250 read beats (windows) +
16 side-info writes (+16 co-located reads in B pictures): the budget is occupancy,
not bandwidth, and it is all on one master.

### 2.4 The unit interfaces (what the leaf units are built to)

Every unit is `clk`/`rst_n`, registered outputs, valid/ready streams; sizes are the
spec's. Vectors for every one come from `h264_recon_ref.py`'s functions of the same
name (the bench's golden is the model, and the model is proven against ffmpeg).

| unit | in | out | golden |
|---|---|---|---|
| `dequant_itrans` | `kind` (L4 16 / L-AC 15 / C-AC 15 / L-DC 16 / C-DC 4), `qp`, `field_scan`, `dc_in`; coefficients in scan order, one per cycle | residual samples in raster order, one per cycle (DC kinds: the 16 / 4 scaled DC values) | `dequant4x4` + `itrans4x4`, `luma_dc`, `chroma_dc` |
| `intra_pred` | `kind` (4x4 / 16x16 / chroma), `mode`, the neighbour samples (top 0..15, left 0..15, corner) and their availability | prediction samples in raster order, one per cycle | `intra4x4_pred`, `intra16x16_pred`, `intra_chroma_pred` |
| `mc_interp` | `is_chroma`, `frac_x/y`, `w`, `h`; a window RAM read port | prediction samples, one per cycle | `mc_luma`, `mc_chroma` |
| `wpred` | mode (default / explicit / implicit), `logWD`, `w0/w1/o0/o1`; the two list predictions as streams | the weighted sample stream | `SliceDecoder.weighted` |
| `deblock_bs` | the p and q blocks' info (intra, nz, refs, mvs, pred flags), `mb_edge`, `vertical`, `field` | `bS` | `boundary_strength` |
| `deblock_filter` | p3..q3, `bS`, `qp_p`, `qp_q`, `alpha_off`, `beta_off`, `chroma` | p'2..q'2 | `filter_line` |

### 2.5 Refused, counted, visible

The reconstruction refuses nothing new (the front end already fenced the profile); it
**counts** what it cannot serve and shows the last code on the HUD: a reference index
naming an empty list slot, a frame_num gap, a temporal-direct reference not in list 0,
a missing co-located field, a store exhausted (never on a conforming stream: §2.2). Never garbage decoded as pixels: the
macroblock is left as its prediction and the count moves.

The HUD's `P4` row (`tools/diag_layout.py`): `PIC` pictures opened, `MB` macroblocks
reconstructed, `ERR count/code`, `SZ` pictures refused above MaxFS (§2.2). The code is
the last error's:

| code | meaning | from |
|---|---|---|
| 1 | a slice names a PPS never received | `recon_hdr` |
| 2 | a PPS names an SPS never received | `recon_hdr` |
| 3 | POC type 1 with an SPS outside the two-slot offset cache (`spec_hardening.md`) | `recon_hdr` |
| 4 | more MMCOs in a slice than the table holds | `recon_hdr` |
| 5 | a frame_num gap | `recon_dpb` |
| 6 | no free store | `recon_dpb` |
| 7 | the sliding window must remove a picture and none is short-term | `recon_dpb` |
| 8 | an MMCO naming no picture | `recon_dpb` |
| 9 | a list modification naming no picture | `recon_lists` |
| 10 | a macroblock's words in an order its syntax does not allow (more references than partitions) | `mb_intake` |
| 11 | a reference index naming no list entry, or a temporal-direct co-located reference outside list 0 | `recon_mb` / `mv_pred` |
| 12 | a list entry with no picture behind it | `recon_mb` / `recon_inter` |

Codes 11 and 12 are counted by `recon_mb` and folded into `recon_top`'s count by the
change of that counter (one per offending partition).

## 3. What is deliberately not built

- MBAFF, 8x8 transform, scaling matrices, 4:2:2/4:4:4, >8-bit: refused upstream.
- `gaps_in_frame_num_value_allowed_flag` 1 with actual gaps: counted as an error, the
  picture decoded against whatever is in the lists (the census: never allowed on a disc).
- The bumping / output process (C.4.5.3): P5, with the display reader.

## 4. The P4 smoke display (`emu.sv`, `ddr_mux2.sv`, `disp_smoke.sv`)

> **P5a (2026-09-25):** `disp_smoke.sv` is now `disp_reader.sv` on its own port (`ram2`),
> with field-aware chroma rows, and `run_disp_smoke.sh` is `run_disp_reader.sh`. The display
> from P5 on is `docs/display.md`; this section records the P4 smoke design as it was.

The HW gate is "first pictures on HDMI in decode order": no timing, no reordering, no
3:2 (P5). What `emu` composes:

- **`recon_top` on clk_dec** with the front end (since 2026-09-24, after the area work
  of §6.1): the syntax elements go straight across, `h264_top.se_ready` is the
  reconstruction's (pinned by `tools/check_emu_wiring.py`). Reset per mount with
  `fe_rst_dec_n`; its DPB client on clk_mem with the same mount reset released into
  clk_mem. **Before: the smoke clocking** -- `recon_top` on clk_sys (27 MHz) through
  `h264/se_cdc.sv` (a 32-word `fifo_dc` and an output register, kept with its bench as
  the fallback), because the first fit that placed (37,785 ALM, 90 %) closed clk_dec at
  40.9 MHz with the reconstruction on it (§6.2); the rig's first pictures (HW smoke)
  ran that way at ~5 frames/s.
- **`ddr_mux2` on ram1**: A = the DPB client (reads and writes), B = the display (reads
  only). One command channel; no write while any read beat is outstanding (the port's
  rule, for both masters); responses routed by a 16-entry owner FIFO (full-guarded);
  B cuts in after every accepted A command and once per A write that waits for reads to
  drain (without the once, B's reads kept re-blocking A's write for ever — the bench
  found it). ⚠ Sharing ram1 costs the decoder arbitration occupancy
  (`hw_budget_and_lessons.md` §2): acceptable for a smoke picture; P5's display moves
  to ram2.
- **Mount reset vs the DDR3 port.** A mount can land inside a write burst; a master
  reset there leaves the controller waiting for beats that never come (a hung port,
  every later read with it). So the mux is reset only with the core and the mount
  ABORTS master A instead (`a_abort`, the mount reset synchronised into clk_mem): an
  open burst is completed with masked beats (`byteenable` 0), A's outstanding read
  beats are swallowed, and A sees waitrequest until the port is clean.
- **Which picture.** `recon_top.pic_done` fires when the next picture opens; the display
  takes the finished store only when the next picture opened in ANOTHER store — a frame,
  or the second field of a pair (a first field's successor is its own second field).
  The newest such store and the store the display latched (at line 500 of the raster,
  before line 0's fetch) are held out of the decoder's allocation (`disp_hold`). The
  newest is decided on clk_dec (held from the cycle the picture completes) and crosses
  to clk_sys in a `cdc_snap`; the latched store crosses back in another. ⚠ A picture
  completing within the ~20 cycles between a latch and its hold arriving could free the
  latched store: a torn smoke frame, ~6e-6 per displayed frame. P5's display scheduler
  replaces this. The HUD's counters cross in a third snapshot.
- **Crossings at 27 / 90 and 81 / 90 MHz.** clk_sys (27) against clk_mem (90): the
  display's line requests (and, in the smoke clocking, the DPB client's FIFOs); clk_dec
  (81) against clk_mem: the DPB client's FIFOs, nearest edges 1.23 ns apart. The core PLL's clocks
  are one group in `sys_top.sdc` (timed), and these two clocks' nearest edges are
  3.7 ns apart, so the first fit failed them. `h264/h264.sdc` bounds the synchroniser
  stages to 8 ns and cuts `cdc_reset`'s clear pins; `disp_smoke` captures the line and
  picture fields only when a request has crossed, and computes its row addresses in
  two setup cycles (the multiply in the burst loop missed 90 MHz).
- **`disp_smoke`**: at each raster line it requests the next one; clk_mem fetches the
  luma row (2W words) and the chroma rows (W words each) as ≤8-beat bursts into
  dual-clock line buffers; the raster side converts BT.601 limited-range YCbCr to RGB
  (the integer 298/409/100/208/516 form) at LAT 4, the latency of `xmb_wave` and
  `diag_hud`, so one delayed sync serves all three. Field pairs show woven (a frame
  store holds them line-interleaved). Outside the picture: black. The HUD composes over
  the picture.

## 5. Verification

| runner | what | status |
|---|---|---|
| `run_dpb_mem.sh --red` | `sfifo`, `dpb_mem` on two clocks vs the policing DDR model | 7 mutations |
| `run_recon_ctl.sh --red` | the control path (params, POC, marking, lists, tables) per slice vs the model | 7 mutations |
| `run_mb_intake.sh --red` | the macroblock intake | mutation-gated |
| `run_dequant_itrans.sh`, `run_intra_pred.sh`, `run_mc.sh`, `run_deblock.sh`, `run_mv_pred.sh`, `run_dsf_calc.sh` (all `--red`) | the leaf units vs the model's functions | mutation-gated each |
| `run_recon_top.sh [--red] [--discs]` | **the whole reconstruction**: [pre] per macroblock, [post] per picture in DDR3 | 15 mutations (R1-R15) |
| `run_cosim.sh [--red] [--sweep]` | **the disc cosim** (Verilator): the front end and the reconstruction as `emu` composes them, 300 frames of every disc's main title, per macroblock and per picture (§5.1) | 6 mutations (C1-C6) |
| `run_disp_smoke.sh --red` | `ddr_mux2` (abort, fairness, owner FIFO) and `disp_smoke` (every dot of a frame vs BT.601) | 9 mutations |
| `run_scaffold.sh --red` | the emu seams (`check_emu_wiring.py`), W6-W8 for P4 | mutation-gated |
| `run_diag_hud.sh --red` | the HUD with the P4 row, pixel-exact | 7 mutations |

`run_recon_top.sh`'s mutations are the roadmap's named RED arms: the 6-tap's
coefficient (R1), the bS rule (R2), weighted prediction skipped (R3, and implicit
weights R6), the opposite-parity chroma offset (R4) and the frame scan in a field
picture (R5) — each caught by its own arm on its own clip.

Measured (Icarus, the chain bench; clk_dec cycles per macroblock, DDR model latency
4-20 mclk, 30 % random waitrequest):

| clip | cycles / MB |
|---|---|
| x264 intra (i2) | 7,660 |
| x264 P, 2 refs (p4) | 4,168 |
| x264 B spatial / temporal (bsp / btm) | 4,057 / 4,521 |
| x264 weighted P / implicit B (wp / wb) | 3,785 / 4,547 |
| x264 3 slices (sl) | 5,699 |
| Family Guy fields, 6 pictures | 4,775 |

**The JM `lencod` streams (2026-09-25)** cover what no x264 setting and no disc produces:
field MMCOs, long-term references used in frame streams, the B-list swap of 8.2.4.2.3/4
and the modification's duplicate removal. `tools/jm_fixtures.py` encodes a 96x64 source
per case with JM 18.4's `lencod` (`tools/jm_build.sh --lencod`; Main, CABAC, no 8x8
transform) and writes the fixture only when (1) the model is bit-exact vs ffmpeg on the
stream and (2) **the model's coverage counters** (`Decoder.cov`) show the stream reaches
the case's own path -- a fixture that never swaps a list cannot vouch for the swap (the
first `PReplaceBSlice` attempt produced no B slice at all and was refused by this check):

| case | lencod settings | coverage | RTL |
|---|---|---|---|
| `jfmmco` field MMCOs | `PicInterlace 1`, `PocMemoryManagement 1`, 3 refs | 18 field MMCOs | bit-exact, 1,657 / MB |
| `jlt` long-term in frames | `SetFirstAsLongTerm 1`, 2 refs, frame 0 revisited | 197 partitions from the long-term | bit-exact, 1,452 / MB |
| `jswap` the list-1 swap | `BReferencePictures 2`, no B frames: low-delay B | 8 swaps | bit-exact, 1,534 / MB |
| `jmod` duplicate removal | 3 refs; each P slice header rewritten to ONE operation (see below) | 286 partitions from an index the removal changed | bit-exact, 1,549 / MB -- **after the fix below** |

Their RED arms (`run_recon_top.sh` R17-R20): the swap never taken, the later duplicate
kept, a field MMCO 1 leaving the bottom field marked, `long_term_reference_flag`
ignored -- each caught on its own stream.

**`jmod` and the bug it found.** The first `jmod` (`ReferenceReorder 1` over reference B
pictures) passed its coverage check -- 15 duplicates removed -- and R18 (the later
duplicate KEPT) survived it: lencod's method 1 names every list entry explicitly, so the
removal never changes an index in use (CAWP5, the conformance modification stream, is
the same: 129 removals, none observable; method 2 crashes this JM tree). The counter
counted that the path RAN, not that it MATTERED. It now counts `mod_dup_used` -- a
partition predicted from a list index where the lists with and without the removal
differ (the model builds both). `jmod` is a plain 3-reference lencod stream whose P slice
headers get ONE operation spliced in (`rewrite_modification`: the default list's second
entry to the front, [B, A, B, C] -> [B, A, C]; the CABAC slice data is byte-aligned
after the header, so the header is re-emitted around the splice and the data follows
unchanged). On it the RTL FAILED unmutated, identically to R18: **`recon_lists`
compared each entry against the PREVIOUS entry's FrameNumWrap** in `L_MOD_COMPACT` (the
table was addressed from `cent`, registered only at the end of the phase that should
address it), so a later duplicate was dropped only when the entry before it shared its
store. Fixed (`tab_ra` from `lq_cur` in phase 1); every disc window, conformance
stream and clip stayed bit-exact, because none of them made the removal observable. (The JM tree in `$H264_REFS_DIR` is a research
fork whose encoder loads VQ codebooks unless `VQdim` / `VQcblen` are 0; the tool sets
them only when that extension is present, and gives the leaky-bucket files a path.)

### 5.1 The disc cosim (`run_cosim.sh`, Verilator, 2026-09-25)

Icarus runs the chain at ~5 pictures in 20-40 minutes, so a whole-library check needs a
faster simulator. `bench/h264/run_cosim.sh` Verilates **the decoder as `emu` composes
it**: `h264_top` straight into `recon_top` on clk_dec, the DPB client on the 90 MHz
memory clock (`bench/h264/cosim_top.sv`). The C++ harness (`bench/h264/cosim_main.cpp`)
drives both clocks, feeds the elementary stream as bytes (one flush pulse after the
last), and carries the DDR model with `ddr_model.sv`'s rules and randomness (30 %
waitrequest, 4-20 mclk read latency, the ordering / burst / credit policing as the
`[ddr]` arm). Its arms are `recon_top_tb.sv`'s: [pre] every macroblock, [post] every
picture once its writes land, [count] (pictures, macroblocks, and no error or refusal on
either half), [hang]. ~650K clk_dec cycles a second, single-threaded (`--threads 4` was
3x slower: the design is too small to split); a 300-frame window takes ~18 minutes.

**The golden** (`tools/cosim_golden.py`): the main title (the longest playlist), from
the first IDR after the video EP entry at 40 % of the title, cut after 300 frames (a
field pair is one frame; the header parsers count them), and the model's decode-order
pictures before and after deblocking as raw planes. **The model is checked against
ffmpeg on the same window first**: a window where they disagree is an ORACLE verdict
and is not scored. So every PASS says RTL == model == ffmpeg on that window.

**The window starts at an IDR, not at the EP entry:** Family Guy's EP entries are
non-IDR I pictures (recovery points). A decode that starts at one has no reference
state, and the model refuses the frame_num gap. **This matters for seeking (P6,
`roadmap.md`):** a seek lands on EP entries, so the decoder must start cleanly from a
recovery point. The model refuses that start today; the RTL has not been tested on it.
Astro Boy's IDRs do not repeat the parameter sets (sent once, at the title's start):
the golden carries the title start's SPS / PPS, then any the window sent before its
IDR, right after the IDR's delimiter, as a decoder that had played up to there would
hold them.

Verdicts: PASS, FAIL [arm], SKIP (a damaged rip), REFUSED (the model refuses the stream:
a scoping decision, e.g. CAVLC or MBAFF, and the core must refuse it loudly too),
ORACLE. `--sweep` runs every image in `$UMD_ISO_DIR`, `.iso` and `.zip` (unpacked to
scratch one at a time a job), 5 at a time by default (each golden peaks at ~2 GB).
`--red`: C1-C6 on 12-frame windows of Akira and Family Guy, each caught by its own arm
(the 6-tap coefficient [pre], the bS rule [post], the opposite-parity chroma offset
[pre] on fields, emulation prevention kept in the front end [pre], the arbiter granting
inside a burst [hang], a write with reads outstanding [ddr]).

**The library sweep (2026-09-25, 85 files: 34 `.iso`, 51 `.zip`, one holding two discs --
86 disc images):** **84 PASS**, every one bit-exact per macroblock and per picture over
300 frames (RTL == model == ffmpeg); 2 SKIP (Desperado, the damaged rip; Hellboy II, a
170-byte file that is not a zip). Astro Boy passed on a rerun after the golden learned
to carry the parameter sets (its first run failed in the golden, never in the RTL);
King Kong's two discs (one zip) passed once the runner took every ISO in a zip.
No REFUSED, no ORACLE: no disc of the 85 uses CAVLC, MBAFF or anything else refused.
Per-disc results: `.sim/cosim/sweep.tsv` (not committed; rerun to reproduce).

**Real time across the library -- the finding.** Each window's display time comes from
its pic_timing SEI (Table E-6 ticks, `display_seconds()`), so the cosim reports decode
time against it. Film (23.976) windows are all 1.10x or better. **Three 29.97 windows
are below real time under the DDR model**: The Office Disc 01 (fields) 0.92x, Red Hot
Chili Peppers Live at Slane Castle (29.97 progressive) 0.94x, Tom & Jerry Vol. 1
(fields) 0.98x. Nine more are within 1.03-1.07x (all 29.97), and the rig ran 4-7 %
slower than the model on Akira and Family Guy, so those are at risk on hardware. The
exit criterion held on the two discs it was measured on and not on the library: 29.97
content needs **≤ 2,000 cycles a macroblock sustained** (Level 3.0's 40,500 MB/s), and
The Office Disc 01's window takes 2,183.

**The fix (2026-09-25): sixteen reference rows in flight.** The cosim's profile (+prof,
`tools/cosim_prof.py`) put 1,844 of The Office Disc 01's 2,237 cycles a macroblock in
inter prediction -- the reference fetch 905, the interpolation 855, one after the other
-- with the back engine idle ~1,400 and the residual engine ~1,900. The fetch was still
DDR3-latency bound at four rows in flight; the row buffers are byte-lane RAMs since the
area batch, so deeper costs +32 LUTs: four -> eight -> sixteen rows took the Office
window (100 frames) from 2,237 to 1,974 to 1,907, the fetch from 905 to 641 to 574.
Sixteen rows of <= 4 words fill `dpb_mem`'s 64-beat read buffer exactly. **The 15 windows
under 1.1x, re-swept:** every one bit-exact and at **1.08x or better** -- The Office
Disc 01 1.08x (was 0.92x, 1,854 cycles a macroblock), Red Hot Chili Peppers 1.14x (was
0.94x), Tom & Jerry 1.21x (was 0.98x), Family Guy 1.36x (1,470); the rest 1.23-1.37x.
The Office Disc 01 stays the margin case (the rig ran 4-7 % under the model).
**On the rig (2026-09-25, `UMD_p4recon_20260925_1106.rbf`, from each title's start):**
Akira 36.4 frames/s (1.52x, was 29.1), Family Guy 79.6 fields/s (1.33x, was 62.0), **The
Office Disc 01 66.1 fields/s (1.10x)**; ERR 0, pictures clean.
**The fetch / interpolation overlap (2026-09-25).** `recon_inter` is now two machines over
a double-buffered window RAM: the fetch side (`st`) walks the (group, plane, list) items
-- geometry, the reference rows, the copy into window bank `fb` -- marks the bank full
with the item's descriptor (plane, fraction, size, list, bi, position, references) and
goes on to the next item, waiting only for a full bank; the interpolation side (`k`)
takes the banks in order (list 0 of a bi-predicted group into `pbuf0`, else the weights
and the interpolation streaming through `wpred`) and frees each. The interpolation side
stays serial, so `pbuf0` has one user at a time; the POC lookups follow the item being
weighted (one register stage, read three states after its bank is taken). Area: +7 LUTs,
+64 registers (the window lanes 128 -> 256 bytes, still RAM). The Office Disc 01 window
(100 frames): 1,907 -> **1,521** cycles a macroblock (**1.32x**), Red Hot Chili Peppers
1,399 (1.43x), Family Guy 1,238 (1.62x); every one bit-exact. `run_recon_top.sh` R16:
the fetch filling a bank still being interpolated, caught by [pre].
**The library re-swept on the overlap (2026-09-25): 84 PASS, 2 SKIP, ALL GREEN** -- every
disc bit-exact over 300 frames, **every window at 1.35x real time or better** (The Office
Disc 01 1.35x at 1,481 cycles a macroblock, Red Hot Chili Peppers 1.40x, Equilibrium
1.49x; the median 1.83x; was 0.92x worst and ~1.3x median before this work).
**On the rig** (`UMD_p4recon_20260925_1845.rbf`, clk_dec 87.11 / 87.87 MHz -- tighter than
the 89.6 before, still over the 86 gate and 81 in use): **The Office Disc 01 83.1 fields/s
(1.39x), Family Guy 95.9 fields/s (1.60x), Akira 44.0 frames/s (1.83x)**, ERR 0.
The smoke display (§4) sometimes shows a field-coded frame combed: it shows a store once
ONE field of the pair is complete, the other field's lines still holding the store's
previous picture (seen on Family Guy at scene cuts; more often at this decode rate).
A display artefact of the P4 smoke path, not a decode error (the cosim proves the
pixels); P5's display weaves a pair only once both fields are in.

## 6. Open before P4 closes

1. **Throughput.** 4,000-7,700 cycles per macroblock against 2,500 (23.976 fps at
   720x480, 81 MHz); the Akira window measured 6,348. Where the cycles go (a histogram
   of `recon_mb`'s state per clk_dec cycle on the chain bench, 2026-09-24; states under
   1 % omitted):

   | clip | `DB_WAIT` (deblock) | `INTER_WAIT` (fetch + MC + weight) | `RES_FEED` (residual) | `WB_DATA` | `I4_*` |
   |---|---|---|---|---|---|
   | i2, intra | 4,075 / MB (53 %) | — | 1,726 | 240 | 539 |
   | p4, P | 1,543 (37 %) | 1,324 (31 %) | 429 | 240 | 140 |
   | bsp, B | 1,262 (31 %) | 1,705 (42 %) | 299 | 240 | 47 |

   Done the same day, each gated bit-exact by the chain bench:
   * **the deblock in segments of eight lines** (`recon_deblock`: the words of eight
     lines read into an 8 x 8 buffer, the lines through one `deblock_filter` back to
     back, whole words written back): intra `DB_WAIT` 4,075 → 946 cycles; then STREAMED
     (Nova's pipelined filter; the bank's read and write ports are separate): a vertical
     edge's lines go from the read data through the filter to the write port with no
     buffer, a horizontal edge transposes through eight row shift registers (rows in and
     out by row shifts, positions through the filter by byte shifts, the results landing
     back at their own bytes after 8 + latency shifts) -- ~200 cycles a macroblock less,
     and the 8 x 8 buffer's ~1,700 LUTs of byte selection gone;
   * **the coefficient feed pipelined** (a 4-entry queue, reads every cycle): the
     transform takes a coefficient a cycle instead of one every ~4;
   * **the reference window copied four bytes a cycle** (four byte banks):
     `FETCH` 695 → 517 on the P clip.

   | clip | this morning | now |
   |---|---|---|
   | i2, intra | 7,660 | 3,724 |
   | p4, P | 4,168 | 2,659 |
   | bsp, B | 4,057 | 2,775 |
   | Akira window (frames) | 6,348 | 3,834 |
   | Family Guy window (fields) | 4,775 | 3,094 |
   | CAPA1_TOSHIBA_B (PAFF, conformance) | 10,887 | 6,644 |

   (`run_recon_top.sh --red --discs` on 3ef988a: 15 clips bit-exact, R1-R8 each caught.)

   **Next:** `recon_inter`'s fetch is now DDR-latency bound (two rows requested ahead,
   each a full round trip: more rows in flight); its weighting pass (~300 cycles) is
   redundant for default single-list prediction (write the interpolator's output
   straight to the bank); `RES_FEED` still ~1,000 on intra (the transform's
   row/column passes between blocks); the Intra4x4 chain. Profile with the scratch
   probes (a histogram of `recon_mb.ms`, and of `recon_inter.st` inside
   `M_INTER_WAIT`).
   **On the rig (2026-09-24, the reconstruction on clk_dec, `UMD_p4recon_20260924_1934`):**
   Akira 16.0 frames/s (0.67x of 23.976; ~21,500 MBs/s = ~3,760 cycles a MB with the
   reader's stalls), Family Guy 34 fields/s (0.57x of 59.94; ~23,000 MBs/s = ~3,500), P4
   ERR 0, pictures clean. Interlaced titles set the real target: 59.94 x 675 = 40,460
   MBs/s is **~2,000 cycles a MB** at 81 MHz (film at 23.976 frames: ~2,500).

   **Profile after the area and timing work (2026-09-24, busy cycles a macroblock,
   `recon_mb.ms` histogram on the chain bench):** i2 3,087 (deblock + writeback ~1,050,
   `RES_FEED` 918), p4 2,430 (`INTER_WAIT` 1,151: fetch 518, MC 313, weighting 299;
   deblock + writeback ~670), bsp 2,591 (`INTER_WAIT` 1,475). The register stages of
   §6.2 added ~30-60. The levers, largest first:

   **Done (2026-09-24), each bit-exact on the chain bench -- chain cycles a MB:**

   | step | i2 | p4 | bsp | mvq | fld0 (conf.) |
   |---|---|---|---|---|---|
   | after the timing work | 3,450 | 2,606 | 2,760 | 3,390 | 3,954 |
   | the MB overlap (below) | 2,611 | 2,208 | 2,398 | 2,666 | 3,049 |
   | the weighting folded into the last list's interpolation | 2,611 | 1,913 | 2,078 | 2,586 | |
   | four reference rows in flight | 2,611 | 1,742 | 1,833 | 2,539 | |
   | `mb_intake` double-buffered | 2,306 | 1,665 | 1,778 | 2,257 | |
   | the residual engine | 1,492 | 1,453 | 1,638 | 1,531 | 1,598 |
   | sixteen reference rows in flight (2026-09-25, after the library sweep) | 1,504 | 1,241 | 1,388 | 1,486 | |
   | the fetch / interpolation overlap (2026-09-25) | **1,504** | **1,140** | **1,229** | **1,458** | **1,346** |

   * **The weighting folded:** the last list's interpolation streams straight into
     `wpred` (the weights are read before it); a bi-predicted group's list 0 is
     interpolated into `pbuf0` first and joins through a 4-deep prefetch FIFO (the
     interpolator is throttled when it is empty). No second pass over a buffer; `pbuf1`
     is gone.
   * **Four row buffers** in `recon_inter` (were two): four reference rows in flight
     against the DDR3 round trip.
   * **`mb_intake` double-buffered:** a working descriptor (w_*) and the output stage
     (the mb_* ports); END_OF_SLICE completes the working set, which moves out when the
     output is free while the coefficient / mvd RAMs swap banks -- the words of
     macroblock n + 1 are taken while n is reconstructed (the intake of the levels was
     serial with the reconstruction: 200-480 cycles a MB).
   * **The residual engine** (`recon_mb_fsm.svh`, R_*): started at M_QP, it walks the
     whole macroblock's residual (the luma DC for Intra_16x16, the 16 luma blocks, per
     chroma plane the DC then the AC) through `dequant_itrans` into a residual RAM
     (24 blocks x 4 rows of four 16-bit samples) with a ready / all-zero bit per block;
     the front only waits for a block and adds it (skipping all-zero ones). The
     transforms run under the inter prediction and ahead of the Intra_4x4 chain.

   **The MB overlap (done 2026-09-24):** the deblock and writeback of
   macroblock n run in their own engine while n + 1 reconstructs (-650 .. -1,050 a MB).
   * Three sample banks, macroblock k in bank k mod 3: deblock n reads banks n and n - 1
     (its left edge's p samples), writeback of n - 1 reads bank n - 1, n + 1 builds in
     bank n + 1's slot -- free once engine n - 1 is done.
   * The deblocker's bS pre-pass reads this macroblock's block records and the left /
     above records: it runs before n + 1 overwrites them (the record RAM at n + 1's
     M_MV_READ, `nb_left` at the end walk); it latches its headers (q / l / t qP, PCM,
     intra), the edge flags and the slice's filter offsets at start (n + 1 may be in a
     new slice). The end walk (LM_INFO[mbx], `nb_left`) follows the pre-pass.
   * The writeback shares the DDR3 command port with n + 1's reads (co-located side
     words, the inter fetch) and side-word writes: a write is granted as a whole (its
     command and all its data words) -- dpb_mem pairs write data with write commands in
     order, so two writers must never interleave inside a burst.
   * Ordering: engine n starts when recon n is done and engine n - 1 is idle; recon
     n + 1 starts when engine n - 1 is idle (its bank). A picture boundary waits for the
     engine to go idle (the writeback addresses are the picture's); `idle` includes it.
   Disc windows after the batch: Akira 1,843, Family Guy 1,639 cycles a MB (were 3,674 /
   3,007).
   **On the rig (2026-09-24, `UMD_p4recon_20260924_2353`, clk_dec 89.57 / 89.40 MHz):**
   Akira **29.2 frames/s (1.22x of 23.976)**, ~39,300 MBs/s = ~2,060 cycles a MB with
   the reader's stalls; Family Guy **62.0 fields/s (1.03x of 59.94)**, ~41,900 MBs/s =
   ~1,935; P4 ERR 0, pictures clean (the HUD's `P4 PIC` over 31 s of settled playback).
   **Both real time: the throughput exit criterion is met.** The decoder free-runs (no
   display pacing until P5), so these are its ceiling on each title. The area
   criterion regressed on this build (the reconstruction 12,786 ALM, the core 26,380)
   and was recovered (11,470 / 25,054, the same rates on the rig): §6.1 "Area recovery".
   **Left (not needed for the criterion):** the pre-pass split (~100), the inter fetch
   overlapping the previous group's interpolation, the Intra_4x4 chain.
2. ~~DPB stores to the spec maximum~~ — done 2026-09-24: 20 stores (§2.2).

### 6.1 Area (2026-09-24)

The first full fit of the core with the reconstruction **did not fit**: 4,807 LABs
needed of 4,191 (the reconstruction placed at 33,900 ALMs; the framework ~5,000, the
front end ~3,400, the reader ~2,000). Measured with `tools/synth_unit.sh recon_top`
(Analysis & Synthesis of the one module, minutes), LUTs / registers:

| step | recon_top | what |
|---|---|---|
| first build | 47,964 / 28,992 | |
| sample banks 48 → 64 deep | | a 48-deep byte-enabled array stayed in 6,144 registers, silently (CLAUDE.md lesson) |
| `recon_lists` scans | | the store argmax, the parity search and the modification target over 16 stores in parallel with 32-bit keys → one store per cycle: 8,397 → 3,374 |
| `recon_dpb` scans | | FrameNumWrap, the sliding window and every MMCO over the stores → one per cycle (exact: each touches a store from its own pre-operation state): 5,932 → 2,962 |
| `m_code` in `recon_mb` | 34,605 / 23,056 | `code[l][m_ref[l][b]]` looked up for 32 blocks in parallel → captured with the motion |
| one gather mux in `mv_pred` | | A, B, C-or-D in turn through one 26:1 mux: 6,265 → 4,181, +2 cycles a partition (worst case 46 → 70) |
| POC table in RAM | 31,367 / 20,758 | `recon_slice_tab`'s 2 x 32 x 32-bit table → two 32-word RAMs, one registered read port shared by the table builder and `recon_inter` |
| DPB table + co-located buffer in RAM | ~31,000 / ~18,500 | `recon_dpb`'s POCs / FrameNumWrap / frame_num per store in four RAMs behind one port (the scans read a store the cycle before processing it); `recon_mb`'s co-located buffer (32 x 64) in M10K read one block at a time by `mv_pred`; `recon_inter`'s uniformity flags computed as the blocks are read back |
| mvds in RAM; bS pre-pass (Nova) | 27,122 / ~17,500 | `mb_intake`'s per-block mvds in a 32-word RAM; `recon_deblock` decides the 32 luma edge groups' bS in a pre-pass from a 16-entry block-record RAM (4,942 → 2,598 LUTs, ~70 cycles a MB saved) |
| lists, map, DSF tables in RAM | 24,462 / 17,073 | `recon_lists`' two 32-entry lists (two 64-word RAMs; the swap, shift and compaction walk them); `recon_slice_tab`'s MapColToList0 and temporal-direct DSF tables behind read ports, `mv_pred`'s temporal path two stages deeper (worst case 72 cycles a partition, bound 80) |
| motion in RAM (`recon_mb`, `mv_pred`) | 21,397 / 14,387 | `recon_mb`'s 16-block motion (1,472 registers) in a 16 x 92 RAM written as `mv_pred` is read back, the codes looked up once there: `recon_inter` reads the group's first block through a port (its 1,216-bit bus and its own code lookup gone), the side words and the bottom row / right column are walked out of it (LM_INFO split into a header RAM and four block RAMs written one block a cycle; `nb_left`'s motion walked in during the writeback). `mv_pred`'s derived blocks: one record per partition at its first block plus a 4-bit block → entry map (1,216 → 64 registers), +1 gather cycle a partition (worst case 84, gate 90) |
| the streamed deblock | 20,342 / 14,449 | above (item 1); `recon_deblock`'s own logic 2,625 → 1,643 LUTs |
| index-times-constant selects as cases | 18,921 / 14,449 | `nb_left[49 + 97*by4[3:2] +: 4]` (the Intra_4x4 mode neighbours) and `l_blk[83*g +: 83]` synthesised as barrel shifters over the whole record: ~200 LUTs each, ~1,400 in all (CLAUDE.md lesson) |
| codes, intra neighbours in RAM | 18,396 / 13,538 | `recon_slice_tab`'s `code` table in two 32-word RAMs (the motion read-back takes them a cycle later, holding mv_pred's words; MapColToList0 walks two cycles an entry); the row above read in place from LM_SAMP and the left column in a 32-byte RAM, both through the Intra gather pipeline (+2 cycles for each Intra_16x16 / chroma neighbour load) |
| `nb_above` held by LM_INFO's port | 18,326 / 13,094 | the above macroblock's word is LM_INFO's read output itself (read last in M_LOAD, nothing else reads LM_INFO during a macroblock, the macroblock's own LM_INFO writes moved after the deblock into one end walk with `nb_left`'s); `mv_pred` selects the neighbour entry before normalising it |

The rule these share: a structure consulted once per slice or once per partition does
not need a parallel search; a scan costs cycles the slice / partition budget has; state
read one item at a time lives in a RAM behind a registered port. Remaining owners
(own LUTs, 2026-09-24, after the motion RAMs): `recon_mb` 3,655, `recon_dpb` 2,899,
`recon_deblock` 2,625, `mv_pred` 1,954, `recon_inter` 1,606, `recon_lists` 1,461,
`intra_pred` 1,083, `recon_hdr` 1,070, `dequant_itrans` 1,056. Registers by name (the
post-synthesis VQM): the slice table's codes 512, `recon_inter`'s row buffers 512,
`recon_deblock`'s line buffer `bf` 512, `nb_above` / `nb_left` 870, `dequant_itrans`'
stages 640, the intra neighbour samples / DC / residual arrays ~1,150, `pps_valid` 256.
3. ~~**JM `lencod` fixtures** for the uncovered control paths (§5).~~ Done 2026-09-25:
   `jfmmco`, `jlt`, `jswap`, `jmod`, each coverage-checked, R17-R20.
4. **The display to ram2** — P5, with presentation order and the output process.
5. **Timing closure at clk_dec** (§6.2), then the reconstruction back on clk_dec (§4).
6. **Area: the reconstruction ≤ 12K ALM** (24,639 placed at the 20-store build). The
   P4 exit criteria (`roadmap.md` Phase 4) make 1, 5 and 6 one job: the remaining
   register-held state into M10K (block RAM is 33 % used), the remaining parallel
   selections serialised (`mv_pred`'s neighbour mux, `recon_deblock`'s block
   selection, `recon_lists`), register stages placed where the scans leave them
   unnecessary. If area work cannot reach the budget, the contingency the user chose is
   the ISO handling on the HPS, never A/V decode (`roadmap.md` "Resource checkpoints").

**Area recovery (after the throughput batch, 2026-09-24).** The throughput build fit at
26,380 ALM with the reconstruction at 12,786, over the budget again (the double-buffered
intake, the residual engine's RAM plumbing, the third bank, four row buffers). Unit synthesis:
recon_top 18,735 LUTs / 15,102 registers. The largest register holders were
`recon_inter`'s row buffers (1,024), the deblocker's `hr` (512, a pure shift structure:
cheap per bit, kept), `nb_left` (433), `dequant_itrans` A / O (640), the DC arrays (384)
and `pps_valid` (256). Done:
* the row buffers as eight byte-lane RAMs (a copy step's four columns fall in four
  different lanes, or the same lane and address when clamped; stage 1 addresses the
  lanes, stage 2 takes the bytes);
* the DC arrays (`dcy` / `dcc`) in a 32-entry RAM with a nonzero flag each (an uncoded
  DC block clears the flags; a transformed block waits one cycle for the read: +12 a MB
  on i2).
Together: 17,518 LUTs / 13,732 registers (-1,217 / -1,370). **The fit (2026-09-25,
`UMD_p4recon_20260925_0016.rbf`): the reconstruction 11,470 ALM, the core 25,054
(60 %), clk_dec 93.67 / 92.18 MHz, every gate PASS; on the rig Akira 29.1 frames/s,
Family Guy 62.0 fields/s, ERR 0: every P4 exit criterion met on one build.**
Not done, and the next levers if area is needed again: `pps_valid` into RAM (an exact
clear needs a 256-cycle walk that a PPS could race, or an epoch tag that can alias),
`nb_left` (433 registers, read as parallel buses by `mv_pred` and the bS pre-pass),
`dequant_itrans`' A / O (640, row and column access).

### 6.2 Timing (2026-09-24)

The fit of commit db7ab90 (recon 34,605 LUTs in synthesis) placed at 37,785 ALM (90 %)
and closed clk_dec at 40.87 / 40.51 MHz (100 / -40 °C) against 86: **10,451 failing
endpoints** at -40 °C (one path per endpoint, `quartus_sta ... -nworst 1`). Worst per
module (slack at a 12.3 ns period):

| module | worst | endpoints | the long path |
|---|---|---|---|
| `mv_pred` | -12.3 | 1,790 | `recon_mb.mby` → Table 8-6 co-located address → `col_data` → `map_col` → `tdir_dsf` → `t1_dsf`; the APPLY chain (gather → median → + mvd → `cur`) |
| `recon_inter` | -11.3 | 170 | the window address (`cmd_addr`: products and offsets in one cycle) |
| `deblock_bs` | -10.6 | 2 | the 81-bit block selection in `recon_deblock` → the bS compare |
| `recon_mb` | -7.9 | 327 | Intra4x4 `modes` from the neighbour entries |
| `recon_slice_tab` | -7.4 | 2,551 | the table writes from the lists' entries through the store POC muxes (now partly RAM) |
| `recon_lists` | -6.8 | 786 | |
| `h264_top.mb_syntax` | -5.1 | 595 | (closed at ~92 MHz alone: the crowded chip) |
| `mb_intake`, `dequant_itrans`, `recon_dpb`, `recon_hdr` | -3.4 .. -4.8 | ~3,800 | |

The reconstruction was written for correctness first: most of these are single-cycle
chains through wide muxes that a register stage (or the scans of §6.1) removes. The
plan: register the named chains, one module at a time, each gated by its runner and
`run_recon_top.sh`, then a fit; area and timing together (a 90 %-full chip does not
close at 86 MHz: the front end alone lost 30 %).

**After the area work (2026-09-24, the reconstruction moved back to clk_dec in `emu`):**
the fit closed clk_dec at **51.0 / 48.9 MHz** (61 % of the chip), 2,627 failing
endpoints at -40 °C (`quartus_sta` one path per endpoint, scratch Tcl `report_timing
-nworst 1 -less_than_slack 0`, grouped by destination module). The clusters and what
was registered for each (every step gated by its unit runner and the chain):

| cluster (worst at 81 MHz) | the chain | the register stage |
|---|---|---|
| `recon_inter` -8.1 | the motion RAM's output -> the chroma offset -> clamp -> `srow * stride` -> the bases -> `cmd_addr` | the window geometry registered in I_LIST, the base and first row in I_LIST2 / 3; each row request steps the address by the stride while the clamped row still advances (`addr_cur`, `y_cur`) |
| `recon_inter` -3.6 | the copy's column clamp -> word -> byte select -> the window banks | two copy stages (`c1_*`: the clamped columns, then the bytes) |
| `recon_mb` -5.7 | Table 8-8's co-located address (a product) -> the command | the per-macroblock addresses registered in two stages (their inputs hold for the macroblock) |
| `recon_mb` -0.4 / -0.04 | the residual add (bank read -> add -> clip -> write) ; the Intra_4x4 mode | the add pipelined over the four rows (also ~5 cycles a block faster); the mode in two cycles |
| `recon_lists` -5.0 / -4.4 | the scan's table read -> POC min -> compare with `best`; `mod_data` -> picNum arithmetic | the scan's key registered (resolve one step later); the modification's picNum over three cycles; the field walk in two phases a step |
| `mv_pred` -5.0 | the gather -> median -> + mvd -> the derived-block RAM | the predictor registered (S_MVP_Q, +1 cycle a partition); the neighbour entry selected in the issue cycle |
| `recon_dpb` -1.1 / -0.9 | the table -> 2 FrameNumWrap + p == target ; the bottom POC -> min | the MMCO targets registered and matched on FrameNumWrap == t >>> 1 (no adder); the bottom POC in its own state |
| `recon_slice_tab` -2.6 | the list entry -> count test -> 20:1 marking select -> `lng` | the entries registered at T_CODES phase 1 |
| `recon_deblock` / `deblock_filter` -2.6 | the edge -> macroblock -> plane qP selection -> indexA | the segment's qPs registered at D_EDGE |
| `intra_pred` -1.6 | the neighbour index -> 33:1 -> the four-sample sum | the samples registered after their fetch (S_SUM one step longer, S_PLB0) |
| `dequant_itrans` -2.3 | the row / column select -> two adder levels -> the write | a two-stage butterfly, rows back to back (+2 cycles a block) |
| `mb_intake` -1.8 | the types -> the partition layout -> the mvd mask | the layout registered; a type word holds the intake one cycle |
| `recon_top` -1.1 / -1.7 | `pipe_idle` -> the header unit's enables ; the size product -> compare | three registered idle cycles gate a NAL word; the size check in its own state |
| front end `mb_syntax` -2.0 | the position test (a product) -> ~600 record enables | the test registered, S_MB_POS before every S_MB_BEGIN (the bench caught a state number the first attempt reused) |
| front end `sps_pps` / `slice_hdr` -1.5 / -1.3 | `f_val` -> the next field's id | none needed: they closed once the reconstruction's clusters were registered (placement) |

That first round gave **75.7 / 71.8 MHz** (273 endpoints under the 86 MHz margin). Three
more rounds, each measured the same way:

| round | result | registered |
|---|---|---|
| 2 | 78.1 / 74.7 | `recon_inter`'s window span from the registered position (I_LIST2, +I_LIST4); `recon_mb` takes the slice's registered picture size (recon_top, set before `mb_slice_go`) and registers the writeback address (M_WB_ADDR); `recon_dpb`'s type-0 POC over three cycles; `mv_pred`'s median from three parallel compares (a between b and c: a; else b or c by (a > b) == (b > c)) and its partition geometry registered (S_PREP, +1 cycle a partition, worst case 114, gate 120); `recon_lists`' scan a third stage (the POC minimum registered) |
| 3 | 86.3 / 81.7 | `recon_dpb`: type-1 POC over three cycles, type-2 FrameNumOffset first, the marking scan's per-store fields read a cycle ahead (store di, like the table RAM) instead of a 20:1 read of dx in front of the write decode; the writeback address in two steps (the product, then the sums); `mb_syntax`'s mvd context increment registered (S_MVD_CTX) |
| 4 | **92.5 / 89.8 PASS** | the co-located second row `col_mb1` = the registered `col_mb0` + W |

The reconstruction is on clk_dec at 61 % of the chip (`UMD_p4recon_20260924_1934.rbf`);
the cost of the register stages is ~30-60 cycles a macroblock, which the MB overlap
(§6 item 1) is to recover.

