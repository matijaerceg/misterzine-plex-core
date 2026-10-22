# The macroblock pipeline (Phase 5, throughput part 3)

**Status: ✅ MERGED (PR fj#22), ✅ HW-CONFIRMED (2026-10-01; `history.md` §18 / §19)** (roadmap Phase 5, throughput part 3; clk_dec 96.43, §4f). Started
2026-09-30 as an experiment ("see just what's possible"), made a branch by the maintainer the
same day and rebased onto main `e1b59de` (the overlay merged). It carries the fixes for fj#18 and
#19. Originally based on `feature/clk-dec-up` (`879fc91`, clk_dec 103.85 MHz); the commit SHAs
quoted below are the pre-rebase ones. Every number below is the
Verilator cosim (`bench/h264/run_cosim.sh`'s binary, `+prof`) on `sun_high_8M` (NVENC
High, 720x480p60, 8 Mbit/s, 120 frames; `docs/throughput.md` §1), bit-exact unless
stated.

## 1. Why

The profile of the shipped tree (2026-09-30, 968 cycles a macroblock at 96.43 MHz; 985
at 103.85) showed the units idle most of the time: the interpolator 566 of 968 cycles,
the residual engine 521, the back engine 289. `recon_mb`'s one FSM ran a macroblock
through prediction -> residual -> add -> save -> deblock hand-off before the next began,
and the fetch was already hidden (`M_INTER_WAIT` 425 ~= `K_WEIGHT_WAIT` 386). The
decoupling worth doing is a pipeline over macroblocks, not a deeper prefetch.

The walls, as sums of their states (measured), and what a pipeline could reach (an
estimate, before building it):

| unit | cycles a macroblock busy |
|---|---|
| stage A: load, QP, mv_pred, the inter prediction | ~450 |
| stage B: residual adds, save, the deblock hand-off, intra | ~420 |
| the residual engine (`R_FEED` + `R_NEXT` + ...) | ~450 |
| the back engine (`E_DB` 313 + `E_DATA` 310 + ...) | ~680 |

## 2. Step 1: the writeback streams (`c6996c5`, `c40522c`)

The back engine's writeback read a bank word, waited for it, pushed it and waited for
the port: one word every ~6.5 cycles. Now (`recon_mb_fsm.svh`, E_SEG .. E_TAIL):

- a **read side** prefetches the item's words into a 4-deep FIFO, one a cycle (the words
  land two edges after the address; the source -- LM_DBK, the left bank, the current
  bank -- travels with the read);
- a **command side** issues a row's burst when the previous burst's words are all sent
  (`w_left == 0`) and this row's wait in the FIFO, so the words follow without a gap;
  the address steps by the plane's row stride (luma 2W words a frame row, chroma W; a
  field's rows twice that), the product pipeline only at a plane's first row.

That alone made things WORSE (985 -> 1,000): `dpb_mem`'s mclk master fetched each write
beat after the previous one was accepted (~3.5 mclk a beat; 64 beats a macroblock =
~260 clk_dec cycles), the bursts queued behind it, and the fetch's reads waited behind
them (`M_INTER_WAIT` 444 -> 473). **`dpb_mem`'s write beats now stream** from a two-word
skid pulled every cycle it has room: 1,000 -> **938** (`E_ROW` 190).

**A latent race, found by `recon_top_tb [hold]`:** `recon_top`'s `pipe_idle` meant
"every write command issued", not "every write landed". With the writes queued in
`dpb_mem`'s clock-crossing FIFOs, a B picture (output at once, C.4.5.2) was emitted to
the display before its last rows reached the DDR (bsp, btm, wb, sl, r16, c44b failed).
On `main` the writeback is slow enough that the queue never builds, but nothing
guarantees it. `dpb_mem` now reports **`wr_drained`** (write bursts taken, clk, against
those completed, mclk, the count crossing back as a gray code) and `pipe_idle` waits for
it. Mutation T12 (`run_recon_top.sh`) removes it; bsp's [hold] catches it. **Worth
porting to `main` regardless of this experiment.**

## 3. Step 2: two front stages (A predicts k + 1 while B reconstructs k)

`recon_mb_fsm.svh` now has two sequential blocks:

- **stage A (`as`)**: the descriptor, LM_INFO's above / above-right records, the
  availability, QP, the residual engine's request, the co-located side words, mv_pred,
  recon_inter's prediction into bank `a_fb`; then the **hand-off** (`hand`): stage B
  idle, and the engine has taken A's request.
- **stage B (`ms`)**: LM_SAMP's row-above samples (corners, above-right), intra
  prediction (Intra_4x4 / 8x8 / 16x16, chroma), I_PCM, the residual adds, SAVE, the side
  words, the deblock hand-off, the end walk.

Why it is legal: the inter prediction reads only reference pictures, complete before the
current picture starts (a second field's reference to its first too); mv_pred for k + 1
needs k's VECTORS (known at A's MV_READ), not its pixels; intra prediction needs k's
pixels, so it stays in stage B, which is serial.

What had to be split or banked (the cost is memory, not logic):

| resource | before | now | why |
|---|---|---|---|
| sample banks | 3 | **4** | A's k + 1, B's k, the engine's k - 1 and its left k - 2. A starts k only after B finished k - 2, whose DB_GO waited for the engine to finish k - 3 -- so k - 4's bank is written back |
| `mb_intake` coefficient RAM | 2 banks | **4** (`mb_cbank`, `coef_bank`) | A releases the descriptor at the hand-off; B (I_PCM) and the residual engine still read k's coefficients. At a transfer A has handed k + 1, so B has finished k: the new working bank (k + 3 = k - 1 mod 4) is free |
| motion RAM | 1 | **2 memories** | A writes / recon_inter reads k + 1's; B reads k's (side words, end walk) |
| deblocker block records | 1 | **2 banks** (`rec_wbank`, `rec_rbank` latched at start) | A's MV_READ writes k + 1's before k's pre-pass |
| residual RAM + `res_rdy`/`res_zero` | 1 | **2 banks** | the engine fills k + 1's while B adds k's |
| `nb_left` | 1 | A's (`a_nb_left`: header + right column's motion, set at the hand-off) and B's | mv_pred for k + 1 runs before B's end walk for k |
| `nb_above` | LM_INFO's output register | B's copy at the hand-off | A re-reads LM_INFO for k + 1 |
| position, QPs, flags, descriptor fields B reads | shared | B's copies (`b_*`, `mbx`, `qp`, ...) | |

Hazards and how each is closed:

- **The engine's flags.** B must not read `res_rdy` of its bank before the engine has
  taken its macroblock (the bank still holds k - 2's "all ready"): `hand` waits for
  `!rq_v`.
- **The engine's result stream.** It takes a macroblock only with its collector empty
  (`rq_take`): the next macroblock's first block may be an 8x8 one, whose start steers
  the shared result stream (`r_l8`) away from a 4x4 block still being collected.
- **I_PCM and the coefficient port.** B's I_PCM reads the port the engine uses:
  `pcm_lock` stops the engine's reads, and B waits out the one in flight
  (`M_PCM_LOCK`).
- **Narrow pictures.** At 1 or 2 macroblocks wide, k + 1's above or above-right record IS
  k's, which B's end walk has not written: A waits for B idle (`width_mbs <= 2`).
- **Slices, pictures.** Every NAL boundary already waits for `idle` (now A, B, both
  engines and `wr_drained`), so the slice parameters never change under a stage.
- **The DDR port.** A's reads first (latency), then B's side-word writes, then the
  engine's writeback; a write burst is granted whole (`w_left`).

## 4. Measurements

| step | `sun_high_8M` cycles / MB at 103.85 MHz | frames/s | notes |
|---|---|---|---|
| base (`879fc91`) | 985 | 78.1 | the clock alone |
| writeback streamed | 1,000 | 77.0 | behind `dpb_mem`'s write beats |
| + `dpb_mem` write skid | 938 | 82.0 | |
| + two front stages | **757** | **101.6** | 1.68x real time; -23 % from the base |

The two-stage profile (`+prof`, cycles a macroblock; `as` is stage A, `ms` stage B):

| stage A | | stage B | | back engine | | residual engine | |
|---|---|---|---|---|---|---|---|
| A_INTER_WAIT | 412 | M_IDLE (waiting for A) | 198 | E_DB | 313 | R_NEXT | 217 |
| A_HAND (waiting for B) | 166 | M_DB_GO (waiting for the engine) | 128 | E_ROW | 185 | R_FEED | 196 |
| **A_IDLE (waiting for the next descriptor)** | **146** | M_RES_NEXT | 94 | E_IDLE | 214 | R_IDLE | 310 |
| A_MV_* | 27 | M_RES_ADD_RD | 65 | | | | |

Reading it: the back engine is busy ~545 of 757 and stage B waits for it 128 a
macroblock (`M_DB_GO`); stage A waits for B (`A_HAND` 166) and **for the front end**
(`A_IDLE` 146: no descriptor -- the CABAC front end, `docs/throughput.md` lever 5, now
binds at 8 Mbit/s, as predicted before building). The three limits are within ~20 % of
each other: the deblocker (`E_DB` 313), the CABAC front end, the inter prediction (412).

### 720p30 (the question that started this)

`H264_BIG_STORES` (simulation only: 2 MiB stores -- 720p is 1.84 MB of samples and side
words -- and pictures to 5,461 macroblocks; twenty such stores would overlap the ring, so
never in a hardware build) lets the cosim decode 1280x720. (2026-10-02, roadmap Phase 5c: the
define is retired -- 2 MiB stores are the build's, the DPB above the ring at `0x3200_0000`, the
bound 3,600; "5,461" was samples alone: with the side words a 2 MiB store holds 4,096.) The proxy: the Phase 1 source
cropped to 16:9 and scaled to 1280x720, 30000/1001 frames/s, the same NVENC recipe as
`sun_high_8M` (High, p1 ull CBR, a one-frame VBV, refs 1, 1 slice) at **10 Mbit/s**
(`.sim/p720/`, level 3.1). 60 frames, the model bit-exact vs ffmpeg:

| tree | cycles / MB | frames/s at 103.85 MHz | real time |
|---|---|---|---|
| two front stages (`1744d06`) | **776** | **37.2** | **1.22x** |

The rig ran 4-7 % under the cosim's DDR model (`docs/throughput.md`), and a 1280-wide
source costs the display's reads more (`ram2`; unmeasured, estimated 1-3 %): **720p30 at
10 Mbit/s is real time with ~10-15 % to spare on this tree**, before the display fits it
to the raster (not built for 1280 wide sources beyond the decimation `analog.md` §8
describes, and the 2 MiB stores need a new DDR layout: `spec_hardening.md`'s bound).

At 720p the limit moves to stage B: A waits for it 272 a macroblock (`A_HAND`), B waits
for the back engine 131 (`M_DB_GO`; `E_DB` 363 -- more edges filter at 720p -- plus
`E_ROW` 169) and for the residual engine 109 (`M_RES_NEXT`; the engine busy ~510).

## 4b. The front end: the emission decoupled (`85f5a56`)

`mb_syntax` streamed a residual block's coefficients (16, or 64, zeros included) after
the block decoded and before the next began, and held the machine on every other SE until
it was taken. Now the machine pushes jobs into a four-entry ordered queue (a word, or a
block's coefficients on one of two level-RAM banks) and an output process drains it: the
next block decodes while this one streams. `run_mb_syntax.sh` ALL GREEN (word-exact).
Cycles a slice against `e125f75`: x264 I -14 %, P -12 %, B -12 %; field P -19 %, High field
P -23 %. The rest of the front end's cost is the bins themselves (~4-5 cycles a dependent
bin: issue, the engine's two, consume, and a state change before the next issue).

On `sun_high_8M` the emission queue brings the pipeline from 757 to **726 cycles a
macroblock** (106.0 frames/s, 1.75x; `A_IDLE` 146 -> 91), bit-exact.

## 4b'. Step 3: the back engine split (`b514df9`)

The deblock engine hands macroblock n to the writeback engine and filters n + 1 while
n - 1 is written (phase L first: the writeback engine's LM_DBK accesses, then the
deblocker may start; five sample banks). Stage B's wait for it, `M_DB_GO`, 131 -> 27.

| window | step 2 | + emission queue | + engine split |
|---|---|---|---|
| `sun_high_8M` (720x480p60, 8 Mbit/s) | 757 | 726 | **711** (108.3 frames/s, 1.79x) |
| 720p30 proxy (10 Mbit/s) | 776 | -- | **739** (39.1 frames/s, 1.28x) |

What binds now, at both sizes: **the residual engine** (720p: `R_NEXT` 270 + `R_FEED` 216,
~520 busy; stage B waits for it 121, stage A 268 at the hand-off -- `hand` waits for the
engine to take A's request). It feeds one 4x4 block at a time through `dequant_itrans`, 16
coefficients a block zeros included, ~27 cycles a block. The front end has slack at 720p
(`S_RB_NEXT` 285: its queue back-pressured).

## 4b''. Step 4: dequant_itrans's two work buffers (`75f1f1e`)

The 4x4 unit's intake fills one work buffer while the transform works on the other (the
transform keeps its own copy of the block's parameters): 29 -> 22 cycles a 4x4 block in
`run_dequant_itrans.sh`. On the 720p30 proxy **739 -> 727 cycles a macroblock (39.7
frames/s, 1.30x)**, bit-exact. Less than the unit's gain: NVENC's High stream codes most
residual as 8x8 blocks, and `dequant_itrans8` is serial (the engine drains its collector
around every 8x8 block: `R_NEXT` still 217). Overlapping the 8x8 unit the same way is the
next residual lever for this content.

## 4c. The first fit (`6314ba1`, the two front stages, before the emission queue)

SEED 7 first roll: **33,134 ALM (79 %)**, 356 M10K (64 %), 95 DSP; lint_undriven and
netlist_canary PASS; **clk_dec 100.97 / 101.12 MHz, MARGINAL** against the 108.8 gate --
below even the 103.85 clock, so not a runnable build. The census (-40 C, 50 endpoints
under the gate): 24 in `recon_mb` at -0.26 ns, `sh_field_pic` -> the streamed writeback's
field row select -> the DSP product into `wb_prod_q` (step 1's address pipeline: fixed by
registering the row first, state `E_SROW`, one cycle a plane segment); the other 26
(`recon_slice_tab`, `mv_pred`, `mb_syntax`, `intra_pred`, ...) pass 103.85 and miss the gate
by under 0.35 ns -- placement at 79 % ALM, the base `e125f75` closed 111.77 / 110.41.

**Fit 2** (`75f1f1e`: steps 1-4, E_SROW), SEED 7 first roll: **33,869 ALM (81 %)**, 364
M10K (66 %), 95 DSP; lint / canary PASS; **clk_dec 104.28 / 103.36 MHz, MARGINAL** (gate
108.8). The census (-40 C): 91 endpoints under the gate, ONE under the 103.85 clock
(`ef_n` -> the writeback's wd_valid -> the arbiter -> dpb_mem's write FIFO `full`, -0.05 ns:
fixed, `ef_ne` registered). The rest are `recon_lists` (42) and `recon_dpb` (33) from M10K
write-enable registers, `recon_mb`'s `top7` (6), `mb_intake` (3) ... at +0.02 .. +0.44: they
closed 110+ in `e125f75`'s smaller netlist -- placement at 81 % ALM. Closing the 5 MHz gate
would take the P5b playbook (a retime round on those clusters, then a seed sweep); the
pipeline adds ~1,300 ALM, ~23 M10K over the base.

## 4d. 720p30 from a media server's transcode (x264, B-frames) -- and a bug on main

The NVENC proxy is the easy case (P only, refs 1). A Jellyfin / Plex transcode is x264 with
B-frames: 720p30 from the same source, `-preset veryfast|medium -profile:v high -level 3.1
-bf 3`, VBV-capped (maxrate = bitrate, bufsize 2x), 60 frames, every one bit-exact after the
fix below:

| stream | cycles / MB | frames/s | real time (cosim) |
|---|---|---|---|
| NVENC ull 10 Mbit/s (P, refs 1) | 727 | 39.7 | 1.30x |
| x264 medium 4 Mbit/s | 763 | 37.8 | 1.26x |
| x264 veryfast 8 Mbit/s | 860 | 33.6 | 1.12x |
| x264 medium 8 Mbit/s | 875 | 33.0 | 1.10x |

Less the rig's 4-7 % and the display's 1280-wide reads (1-3 %): **B-frame 720p30 at 8 Mbit/s
is marginal (~1.00-1.05x); at 4 Mbit/s ~1.15x.** In the B-frame profile stage A waits for B
(`A_HAND` 243) while B idles 312: the two stages alternate on macroblocks of very different
cost (intra quick in A and long in B, bi-predicted the reverse), which a one-deep hand-off
cannot smooth; the front end starves A 147 (~104 bins a macroblock).

**A decoder bug on main (not the pipeline), found by these streams:** x264 medium's
`weightp=2` (explicit weighted prediction with duplicated references) decoded wrong chroma
(samples ~1 for ~150). `recon_hdr` stored the default weight of an entry without explicit
weights -- 2^log2_weight_denom (7.4.3.2) -- in a signed byte: at denom 7 that is 128, read
as -128. Bisected on `e125f75` itself (the base cosim, no big stores, a 480p x264 medium
stream: FAIL at picture 57; `weightp=0` and `ref=1` PASS); the stream carries one slice with
denom 7. Fixed: the weight table's weights are 9 bits (`recon_hdr` wt_ram 51 bits a
entry, `recon_inter` selects the plane with a case). No small fixture reaches denom 7 yet
(x264 chooses it): the regression evidence is the 480p stream (`.sim/p720/x264med480_4M`).

**The issued-not-landed race is real on main too:** the base cosim fails `[hold]` on the
x264 medium `weightp=1` 480p stream (a write into a store the display holds); this branch
(`wr_drained`) passes it.

## 4e. On main (+ the overlay): the fit, a sweep, the rig (2026-10-01)

Rebased on `e1b59de`. SEED 7 first roll (`91ea8fa`): 102.98 / 101.35, negative at the 103.85
clock in paths the pipeline does not touch (`mc_interp` fx -> fmem; clk_mem's `disp_reader`) --
placement at 83 % ALM. A fitter sweep: seeds 1-5 from 89.9 to **109.06 / 108.18 (SEED 5)**, a
~20 MHz spread on one netlist. SEED 5 pinned and compiled (`16923d6`): 34,943 ALM (83 %), 378
RAM, 103 DSP, the cold corner 0.6 MHz under the 108.8 gate, `H264_mbpipe_MARGINAL_20261001_0620.rbf`.

On the rig (`docs/history.md` §18), every stream every picture, errors / late 0, against main's
build in the same session:

| stream | main real time | pipeline |
|---|---|---|
| `sun854_high_8M` (D1's densest) | 1.06x | **1.51x** |
| `sun854_high_5M` | 1.13x | 1.63x |
| `sun_high_8M` | 1.22x | 1.68x |
| x264 medium 480p 4 Mbit/s (B-frames) | 1.03x | 1.34x |

The rig is ~6 % under the cosim on NVENC streams and ~16 % under on x264 B-frames (their
reference fetch is DDR3-latency bound): **the 720p30 x264 estimates of §4d should be read
~10 % lower than the "less 4-7 %" there** -- 4 Mbit/s ~1.05-1.1x, 8 Mbit/s under real time.
The NVENC 720p30 proxy (1.30x cosim) would be ~1.2x. A full 8888 overlay canvas costs 1.2
points (main 0.9).

## 4f. Back to 96.43 MHz (2026-10-01, the maintainer's call)

No seed of eleven closed 103.85's 108.8 gate (§6); ten of the same eleven clear 101.4. The
pipeline gives D1 ~1.4x at 96.43, so the faster clock (PR fj#17, bought for main's ~1 % margin)
is no longer needed for D1 and costs robust closure at 83 % ALM. `a8e7a6d`: `sys_pll` / 14,
`fmax_check` / `seed_sweep` 101.4, `STALL_LIMIT` 13 M, the cosim's default 96.43. SEED 6 from a
sweep: 105.71 / 103.22, PASS (`H264_mbpipe_20261001_1223.rbf`). On the rig (`history.md` §19):
854x480p60 8 Mbit/s **1.43x** (1.51x at 103.85), 720x480p60 1.60x, x264 B-frames 1.29x, the
overlay's full 8888 canvas 1 point. What it gives up: ~5 % of throughput, which matters only
past D1 (720p30 x264 transcodes, already marginal); if 720p is taken on, the faster clock
comes back with area recovered for it.

720p30 at 96.43 (the big-stores cosim rebuilt from `315bbf4`, every picture bit-exact; the rig
estimate scales by the measured rig / cosim ratio at 96.43: 0.96 on NVENC -- `sun_high_8M` 1.66x
cosim, 1.60x rig -- and 0.85 on x264 B-frames -- `x264med480_4M` 782 cycles, 1.53x cosim, 1.29x
rig -- before the display's 1280-wide reads, est. 1-3 %):

| 720p30 stream | cycles / MB | cosim | rig (est.) |
|---|---|---|---|
| NVENC ull 10 Mbit/s (P, refs 1) | 716 | 1.25x | ~1.2x |
| x264 medium 4 Mbit/s (B-frames) | 746 | 1.20x | ~1.0x (marginal) |
| x264 veryfast 8 Mbit/s | 844 | 1.06x | ~0.9x (behind) |
| x264 medium 8 Mbit/s | 860 | 1.04x | ~0.9x (behind) |

720p30 game streaming would hold; media-server transcodes at 720p would not, at either clock
(at 103.85 the x264 8 Mbit/s cases are ~0.95x). The levers past the clock: the B-frame
reference fetch's DDR3 latency (the rig-vs-cosim gap), the residual engine's 8x8 unit, the
A/B hand-off depth (§4d).

## 4g. 720p on the 0.11 build (2026-10-02, roadmap Phase 5c part 1)

The 2 MiB stores are the build's now (`H264_BIG_STORES` retired), the DPB above the ring at
`0x3200_0000`; the cosim's window 128 MB. The proxies regenerated (`.sim/p720/mk.sh`: the Phase 1
source cropped to 16:9, 1280x720, 60 frames, frames dropped to 29.97 or 23.976), 720p24 added for
the films the file player now takes. Every picture bit-exact at 96.43 MHz. Real time against each
stream's own rate (`cosim_golden.py` read every x264 stream as 59.94 until this change: with VUI
timing and no pic_timing SEI a frame is now two ticks); the rig estimate x0.96 (NVENC) / x0.85
(x264 B-frames), before the display's 1280-wide reads (§4e):

| stream | cycles / MB | frames/s | cosim | rig (est.) |
|---|---|---|---|---|
| NVENC ull 720p30 10 Mbit/s (P, refs 1) | 716 | 37.4 | 1.25x | ~1.20x |
| x264 medium 720p30 4 Mbit/s | 746 | 35.9 | 1.20x | ~1.02x |
| x264 medium 720p30 8 Mbit/s | 856 | 31.3 | 1.04x | ~0.89x (behind) |
| x264 veryfast 720p30 8 Mbit/s | 841 | 31.8 | 1.06x | ~0.90x (behind) |
| x264 medium 720p24 4 Mbit/s | 785 | 34.1 | 1.42x | ~1.21x |
| x264 medium 720p24 8 Mbit/s | 925 | 29.0 | 1.21x | ~1.03x (marginal) |
| x264 slow 720p24 8 Mbit/s (refs 4) | 913 | 29.3 | 1.22x | ~1.04x (marginal) |

The 720p30 rows equal §4f's (716 / 746 / 856 / 841 against 716 / 746 / 860 / 844): the stores'
move and the refusal fix cost nothing. 480p regression: `sun_high_8M` 687 cycles (1.72x),
`sun854_high_8M` 647 (1.52x), unchanged. **720p24 at 8 Mbit/s is marginal on this proxy** --
interpolated game footage, denser than most film at that rate (its bits a macroblock: ~93 vs
the 720p30 8 Mbit/s rows' ~74); D1's 720p24 promise is "typical bitrates", 8 Mbit/s of dense
content falls to part 2 with 720p30.

## 4h. What binds at 720p30 and at 12 Mbit/s (the profiles for Phase 5c part 2, 2026-10-02)

`+prof` cosims (`.sim/prof720/`, the 0.11 build, 96.43 MHz; `tools/cosim_prof.py`), cycles a
macroblock per state:

| | x264 medium 720p30 8 Mbit/s (856) | NVENC `sun_high_12M` 720x480p60 (874) |
|---|---|---|
| stage A busy (mostly `A_INTER_WAIT`: the fetch ~405, the interpolation ~400, overlapped) | ~480 (`A_INTER_WAIT` 430) | ~390 (`A_INTER_WAIT` 365) |
| A waits for B to take (`A_HAND`) | **276** | 166 |
| A starved by the front end (`A_IDLE`) | 97 | **312** |
| stage B waits for A (`M_IDLE`) | **277** | 355 |
| B waits for the residual engine (`M_RES_NEXT`) | 123 | 89 |
| the residual engine busy (`R_NEXT` + `R_FEED`) | 485 | 442 |
| the front end: bins a macroblock; back-pressured (`S_RB_NEXT`) | 98; 296 | 150; 200 |

**x264 B-frame content:** A and B each wait ~276 on the other -- the alternating costs (intra
quick in A and long in B, bi-predicted the reverse) a one-deep hand-off cannot smooth (§4d).
Decoupled, a macroblock would cost max(A ~480, B ~580) ~ 580: up to ~1.47x on this stream; a
two-entry A -> B queue is the first lever (mostly M10K: a bank more). **Wrong, measured 2026-10-03
(§4i):** the stages do not alternate macroblock by macroblock but picture type by picture type
(B pictures stage-A bound, P pictures stage-B / residual bound, I pictures front-end bound); the
averages above mix them, and max-of-averages is no bound. The queue bought 2.6 %. Then the residual engine
(busy 485; the serial `dequant_itrans8`). **12 Mbit/s at 480p60:** the front end begins to bind
(A starved 312 at ~150 bins a macroblock), bursty as well (starved on some macroblocks,
back-pressured on others): a deeper front-end -> A queue, then the bin rate (~4-5 cycles a
dependent bin; `S_TU` / `S_RB_SIG`), move the bitrate ceiling. The clock (103.85) ~5 %, last.

## 4i. Phase 5c part 2 step 1: the two-entry A -> B hand-off (`feature/ab-queue`, 2026-10-03) -- PARKED

The order decided 2026-10-02 (roadmap Phase 5c part 2) starts here. Planned with the
maintainer 2026-10-03; measured in the cosim before a fit. **Parked the same day (the
maintainer's decision): ~2-3 % for +622 ALM; the branch is kept, unmerged and unfitted (local,
`d0697b2`), to re-measure once the residual lever balances P pictures.** The design below is
the branch's; main does not have it. What came to main from it: `+prof`'s per-picture
histograms, `cosim_prof.py --by-type`, the `nar3` fixture.

**The slot (Q).** A register stage between stage A's `A_HAND` and stage B's `M_IDLE`: A pushes
its finished macroblock into Q when Q is empty (its context and the descriptor fields B reads,
~180 bits; A releases the descriptor, steps its banks and sets its left neighbour, as the old
hand-off did), B pops Q when idle. A finished macroblock waits in Q and a second in `A_HAND`:
two entries. No bypass (A -> B direct when Q is empty): it would give every B register two
sources; the cost is one cycle a macroblock.

**The residual engine's request queue, one -> two entries, in the same step.** `A_QP` waited
for the engine to TAKE the previous request (`!rq_v`), and the engine takes only when it has
fed the previous macroblock. With the slot alone, on intra, intra, bi-pred, bi-pred A would
stall at the second bi-pred's `A_QP` until the engine finished feeding the second intra --
about when B finishes it: one pair smoothed, not the run. Two entries cost ~50 bits and no
residual bank (below). **B pops Q only once the engine has taken Q's request** (`q_rqp`, set
at the push when Q's request is still queued, cleared by its take -- the oldest queued request
is always Q's: B's was taken before B popped it); I_PCM sends no request.

**The banks**, with A on m, Q holding m - 1, B on m - 2, the deblocker on m - 3 (left m - 4),
the writeback on m - 4 / m - 5 (its `e_cur` / `e_left`):

| resource | was | now | why |
|---|---|---|---|
| sample banks | 5 | **6** | A writes bank m mod 6 = m - 6's. B's `DB_GO` for m - 3 waited for the deblocker idle and the writeback's LM_DBK phase of m - 4 done: the writeback holds at most m - 4 / m - 5 |
| motion RAM | 2 | **3** | A writes m (recon_inter reads it), B reads m - 2 (side words, end walk), Q's m - 1 waits |
| deblocker block records | 2 | **3** (`recm_*` 64 entries) | A writes m in `A_MV_READ` while the pre-pass reads B's |
| residual RAM, `res_rdy` / `res_zero` | 2 | **3** (`res_m` 512 words) | the engine takes m + 1 (clearing its bank, m - 2's) only after A requested it, i.e. after A pushed m into an empty Q: B had popped m - 1, so finished m - 2 |
| `mb_intake` coefficient banks | 4 | 4 | A releases m at its push; Q was empty, so B had popped m - 1 (and the engine had taken it: done reading m - 2); the new working bank (m + 2) mod 4 = m - 2's |
| `mb_intake` mvd RAM | 2 | 2 | stage A's alone |

**The above neighbour's record: B reads its own copy of LM_INFO.** B used to copy LM_INFO's
output register at the hand-off (A's read of `mbx`, held through mv_pred). Carrying it through Q
would be 437 registers at 86 % ALM; a second read copy of the five RAMs (written by the same end
walk) is ~14 M10K and no logic, and B reads it at `M_LOAD0` into the existing `nb_above`. Valid
because between A's read and B's start the only writer of column `mbx_m` is m's own end walk:
m - 1 and m - 2 write other columns whenever the picture is >= 4 macroblocks wide -- the only
pictures that pipeline (next).

**Narrow pictures: 3 macroblocks wide or less run serially.** A on m reads the records of
m - W and m - W + 1 (above, above-right) and, from its previous read, m - W - 1. With Q full B
has finished only m - 3: the overlap needs W >= 4. Below that A waits for B idle and Q empty
(`width_mbs <= 3`, was 2; fixture `nar3`, 48 pixels wide).

**Fences.** `idle` includes `!q_v` and the request queue empty (every NAL boundary waits on it:
the slice parameters must not change under a queued macroblock); `clear` drops Q and the queue.

**Go / no-go before a fit.** `x264med720p30_8M` (856 cycles a macroblock, 1.04x): real time
needs 894 at 96.43 MHz, the rig runs ~0.85x of the cosim on x264 B-frames -- **gate <= 757**
(real time on the rig), **target <= ~700** (~1.1x), ceiling ~580 (A and B fully decoupled).
Between gate and target, the fit is the maintainer's call. Then the fit (SEED 6, 101.4; the
six-way bank select feeds `gt2_nb`, `top7`'s old worst path -- a sweep is likely) and the rig.

### Measured (2026-10-03): the queue buys ~2-3 %; the imbalance is per picture type

Built as above (`8a6c331`), every picture bit-exact. The cosim at 96.43 MHz, against main
(`7f50e03`) built the same way:

| stream | main | the queue | |
|---|---|---|---|
| x264 medium 720p30 8 Mbit/s (60 frames) | 856 | **834** | -2.6 %, 1.07x |
| `sun_high_8M` (NVENC 720x480p60, P only, 120 frames) | 687 | **673** | -2.0 % |

**Why so little (what surprised us).** `+prof` now keeps a histogram per picture (the slice
types its macroblocks were decoded in, every unit's states, its bins) and the hand-off's state
(`cosim_prof.py --by-type`). On the x264 stream:

| pictures | share of the time | cycles / MB (main) | what binds |
|---|---|---|---|
| I (4) | 14 % | 1,700 (1,710) | the CABAC front end: A starved 1,376 a macroblock at 405 bins; the residual engine busy ~1,050 |
| P (18) | 33 % | 917 (941) | stage B: A waits for it 534; the **residual engine busy 698** (`R_NEXT` 403 + `R_FEED` 295) |
| B (38) | 53 % | 704 (726) | stage A: `A_INTER_WAIT` 551 -- the **interpolation** (`K_WEIGHT_WAIT` 373 + `K_MC_WAIT` 114, idle 176), the fetch's `I_REQ` 260; B idle ~300 |

The hand-off histogram says the same: the slot sits full (A blocked, 224 a macroblock) or empty
(B starved, 245) for whole stretches; waiting for the engine's take, ~1. §4h's "A and B each
wait ~276 on the other" was the average of P pictures (A waits) and B pictures (B waits); no
small queue smooths imbalance at that scale. What each lever would give this stream (time-
weighted): P pictures at ~700 -> ~770 total; B pictures at ~600 as well -> ~700; I pictures
are bins. No single step reaches the gate (757): the residual lever (P, I) **and** the
interpolation lever (B).

**Its cost** (`tools/synth_unit.sh recon_mb`, Quartus 17 map, against main's): **+622 ALM**
(10,844 -> 11,466 estimated), +325 registers, +61,184 block memory bits; every new memory
inferred (`bank5` as eight byte-lane RAMs, the LM_INFO copy, `mot_m2`, `res_m` at 512, `recm_*`
at 64). The plan's estimate was +200-300 ALM: the six-way bank port selects and the second
request entry cost more than the slot itself. `run_recon_top.sh` ALL GREEN (46 arms, `nar3`
added); the `--red` arms for the slot are not written.

**Recommendation (taken by the maintainer, 2026-10-03):** park the branch unmerged and unfitted --
~2-3 % for +622 ALM at 86 % and a cold corner on the 101.4 gate is a bad trade -- and re-measure
it after the residual lever balances P pictures. Keep the instrument (`+prof`'s per-picture
histograms, `cosim_prof.py --by-type`) and the `nar3` fixture on the next branch. The order of
part 2 to re-decide: (2) the residual engine's 8x8 overlap (P and I pictures: the engine busy
698 / ~1,050 a macroblock), then the interpolation's throughput for bi-predicted content (B
pictures, a lever not in the 2026-10-02 order), then the bins (I pictures, higher bitrates).

## 4j. Phase 5c part 2 step 2: the 8x8 residual unit a pipeline over blocks (`feature/res-overlap`, 2026-10-03) -- ✅ MERGED (PR fj#29)

**Why.** The per-picture profile (§4i) on x264 medium 720p30 8 Mbit/s, main: in P pictures the
residual engine is busy 698 of 941 cycles a macroblock and `dequant_itrans8` ~430 of them (in
100, rows 115, columns 115, out 98: ~1.5 coded 8x8 blocks a macroblock at ~285 cycles each,
serial); in I pictures ~690 of the engine's ~1,050. x264 codes most luma residual with the 8x8
transform (the Sunshine captures did not: `high_profile.md`'s "~3-4 %").

**What.** `dequant_itrans8` became four stages, each with its own half of a ping-pong RAM:
intake (the four-stage scaling pipeline into A[ia]) | the row pass (A -> B transposed) | the
column pass (B -> O, 8-406) | the output stream (O, `res_ready`). The two passes are one
`dq8_pass` module each, so each has its own butterfly (the pass logic unchanged, moved). A stage
takes the next block when its input half is full and its output half free; `busy` is low when
the intake may take one: idle, its next half of A free, and **fewer than four blocks in
flight** (the engine's collector FIFO holds four: the unit's contract, like `dequant_itrans`'s
three). ~285 -> **79.7 cycles a block** in a stream (`run_dequant_itrans.sh`; a pass, 64 reads
and its tail, is the slowest stage). In the residual engine: the next 8x8 block starts on
`!dq8_busy` (`R_NEXT`), and a 4x4 or DC block after 8x8 ones waits in `R_SETUP` for the
collector to empty -- `r_l8` steers the shared result port and `dequant_itrans` cannot be held.

Rejected: keeping one butterfly and overlapping only intake / transform / output (~150 cycles a
block: the passes serial); a register-array transform (~2,500 ALM, `high_profile.md`); feeding
only to the last nonzero level and a wider output (the feed's 64 cycles a block is now the
floor beside the passes -- a later lever if the engine binds again).

**Measured** (the cosim, 96.43 MHz, bit-exact):

| stream | main | step 2 | |
|---|---|---|---|
| x264 medium 720p30 8 Mbit/s | 856 | **817** | -4.6 %, 1.09x |
| `sun_high_8M` (NVENC 720x480p60) | 687 | **667** | -2.9 % |

The §4g table on this branch (every picture bit-exact; the rig estimate x0.96 NVENC / x0.85
x264 B-frames, before the display's 1280-wide reads):

| stream | §4g (main) | step 2 | | cosim | rig (est.) |
|---|---|---|---|---|---|
| NVENC ull 720p30 10 Mbit/s | 716 | **684** | -4.5 % | 1.29x | ~1.24x |
| x264 medium 720p30 4 Mbit/s | 746 | **717** | -3.9 % | 1.25x | ~1.06x |
| x264 medium 720p30 8 Mbit/s | 856 | **817** | -4.6 % | 1.09x | ~0.93x (behind) |
| x264 veryfast 720p30 8 Mbit/s | 841 | **829** | -1.4 % | 1.08x | ~0.92x (behind) |
| x264 medium 720p24 4 Mbit/s | 785 | **749** | -4.6 % | 1.49x | ~1.27x |
| x264 medium 720p24 8 Mbit/s | 925 | **875** | -5.4 % | 1.28x | ~1.09x |
| x264 slow 720p24 8 Mbit/s (refs 4) | 913 | **873** | -4.4 % | 1.28x | ~1.09x |
| `sun854_high_8M` (480p regression) | 647 | **626** | -3.2 % | 1.57x | |

720p24 at 8 Mbit/s moves from marginal (~1.03-1.04x) to ~1.09x on the rig (est.); x264 720p30
at 8 Mbit/s stays behind (~0.93x).

Per picture type (x264 720p30 8M): I 1,710 -> 1,691, P 941 -> 881, B 726 -> 695. In P pictures
stage B's wait for the residual engine fell 153 -> 36; A still waits for B 459: **stage B itself
binds P pictures now** -- intra prediction ~360 a macroblock (`M_I4_PRED` 163, `M_I4_NB` 61,
`M_CI_PRED` 80, ...: one predicted sample and one gathered neighbour a cycle), the residual
adds ~130 (`M_RES_ADD_RD`: seven cycles a 4x4 block), the saves and the deblock hand-off ~110.
B pictures stay stage-A (interpolation) bound, I pictures front-end bound.

**Cost** (`tools/synth_unit.sh recon_mb` against main's): **+331 ALM** (10,844 -> 11,175
estimated), +497 registers, +3,584 block memory bits; the RAMs inferred.

**A cost it introduced (recorded, not fixed):** the engine now waits in `R_SETUP` ~118 (P) /
~151 (I) cycles a macroblock for the 8x8 samples to drain before the chroma blocks (main: ~21):
invisible while the engine does not bind, real engine time once stage B gets faster. The known
fix: steer the result port by the collector's head (`cf_l8[cf_h]`) instead of `r_l8` and hold
`dequant_itrans`'s `res_ready` while the head is an 8x8 block -- the next engine lever.

**Verification.** `run_dequant_itrans.sh --red` ALL GREEN, 23 arms: M18 re-aimed at
`dq8_pass`'s write (the row pass only); new **M22** (the four-in-flight cap dropped -> `[flight]`,
a new testbench check, under a slow consumer: `+stall` >= 100 holds `res_ready` seven cycles in
eight, the backlog that fills every stage -- the ordinary `+stall` never exceeds four) and
**M23** (a pass restarted in its `done` cycle); a GREEN arm with the slow consumer.
`run_recon_top.sh --red` ALL GREEN (77 arms): T3 re-aimed (`r_serial` is the DC kinds alone
now), new **V1** (a 4x4 / DC block started while 8x8 samples stream) and **V2** (the next 8x8
block started without the unit's `busy`), both caught on `hpb` as `[hang]`. (`hpb` itself, a
64x48 clip, went 806 -> 815 cycles a macroblock: the drain wait above costs more there than the
overlap saves.) `run_cosim.sh` GREEN (seven windows) and `--red` (nine arms) with the profile's
new outputs; `lint_undriven` PASS; `netlist_canary` PASS on `recon_mb`'s map.

## 4k. Phase 5c part 2, the B pictures' lever: the interpolation (`feature/res-overlap`, 2026-10-03) -- ✅ MERGED (PR fj#29), ✅ HW-CONFIRMED (§28)

Decided with the maintainer 2026-10-03 (after §4j): continue on the branch, the B pictures'
lever first, one fit at the end.

**What the profile says** (`+prof`'s new units: `kitem` / `kitemn`, the interpolation side's
items -- a group, a plane, a list -- by plane, size, position class and list role; `mc0`, lane
0's `mc_interp`: reading, starved of window rows, held, idle). x264 720p30 8 Mbit/s B pictures
(695 cycles a macroblock after §4j): 5.5 items a macroblock; lane 0 issues reads 318 cycles a
macroblock, is starved of rows 84, has nothing to read 293 (169 of them with no window bank
ready at all). The fetch side waits on its own copy (`I_REQ`'s sixteen-row bound, `I_LIST`'s
full queue): four bytes a cycle of a window that was always (w+5) x (h+5) for luma -- 21 x 21
bytes for a 16 x 16 item at a full-sample position, the commonest item in this stream (~150 of
the 531 cycles a macroblock items own), whose interpolation reads 16 x 16.

**Lever 1, built: fetch and copy only the rectangle the position class reads.** The window
keeps its layout (`mc_interp`'s addressing: stride w+5 / w+1, origin (xInt-2, yInt-2) / (xInt,
yInt)); the fetch requests and the copy writes luma columns 2..w+1 unless the x fraction is
nonzero (then 0..w+4) and rows 2..h+1 unless the y fraction is (then 0..h+4) -- exactly
`mc_interp`'s per-class sweep -- and chroma w (+1 for a nonzero x fraction) x h (+1). The copy
starts at the rectangle's first window address and steps by the window's stride; the bank's
row count (`rows_avail`) starts at the rectangle's first row (the rows above are never read).
No memory, a few registers in the queue. Cosim, bit-exact: **x264 720p30 8 Mbit/s 817 -> 788,
`sun_high_8M` 667 -> 643**; B pictures 695 -> 653, P 881 -> 873; `recon_top`'s clips exact and
faster (bsp 683 -> 660, wb 803 -> 769). After it the interpolation side is busy nearly all the
time `recon_inter` runs (B pictures: `A_INTER_WAIT` 505, lane 0 reading 318, starved 46).

**What is left in B pictures' interpolation** (lane 0, `+prof`'s `mc0` with the item's phase,
cycles a macroblock): reading 318; an item's setup before its first read 46 (the weights:
`K_WT_RD` .. `K_IMPL_WAIT`, the start); its first rows awaited 40 (about one DDR round trip a
macroblock: the first item's -- the fetch cannot start before the macroblock's vectors);
the drain after its last read ~94 (`mc_interp`'s nine stages and FIFO, `wpred`, the lanes'
imbalance); outside `recon_inter` ~148 (stage A's own states). Setup + drain ~25 cycles an item
x 5.5 items. Overlapping an item's setup and start with the previous item's drain would take
most of the ~140.

**Lever 3, built in two measured steps: items overlap.**

*Step A -- the reader moves on when the reads are done* (`177b090`). `mc_interp` keeps TWO
parameter sets (class, fractions, chroma weights); every read carries its set through the nine
stages and every use site selects by its stage's tag. It takes the next `start` once the item
has issued its last read (`ready`: no reads left, and the set it would overwrite carried by no
read still in the stages -- a 2x2 chroma item issues its reads in a few cycles, so a third item
could otherwise enter while the first drains); `busy` = items in flight. In `recon_inter` the K
machine frees the window bank and takes the next item two cycles after both lanes' last reads
(the last read's window RAM access); each lane's **writer** takes the items' samples out of
`mc_interp` from a two-entry descriptor queue pushed at each start -- into `pbuf` (list 0 of a
bi-predicted group) or through `wpred` (started by the writer with the descriptor's weights and
sample count) into the row segments with the descriptor's geometry. `pbuf` has two banks (a
group's list 1 reads one while the next group's list 0 writes the other). `I_DRAIN` waits for
the writers. Cosim 788 -> **766**, `sun_high_8M` 643 -> 631, bit-exact.

*Step B -- the next item's weights read ahead* (`53caeff`). A setup machine (`ks`) reads the
weights (and runs the implicit DSF) for the bank that starts next as soon as it is claimed,
while the item before it still reads; `poc_ra*` / `wt_addr` / the plane select follow its
target bank; the main machine starts the item the cycle the lanes are free. Item setup 46 -> 5
cycles a B-picture macroblock. Cosim 766 -> **755** (the gate is 757), `sun_high_8M` 631 -> 628,
bit-exact.

Unit verification: `run_mc.sh --red` ALL GREEN with `+ovl` (the testbench starts each case on
`ready` and scores the overlapped stream in order: 338,458 -> 282,719 cycles over the fixture);
new arms M14 (a use site on the issuing set, not its stage's) and M15 (a start while the set is
in flight), each caught only with `+ovl`; M6 / M7 re-aimed.

**What is left in B pictures** (607 cycles a macroblock): reads 313; waiting for windows 59 at
an item's start and 14 inside (small items are now quicker than a DDR round trip -- two window
banks keep the fetch one item ahead; four would cost no M10K: each byte-lane RAM is a quarter
of one); outside `recon_inter` ~159.

**Cost** (`tools/synth_unit.sh recon_mb`, `53caeff`'s RTL): 11,175 (§4j) -> **11,375 ALM
estimated (+200 for levers 1 and 3)**, 14,953 registers, 310,368 block memory bits; the window
lanes and the two-bank `pbuf` inferred. The branch over main: +531 ALM (~36,640 projected for the
whole design, ~87.4 %).

**The fit and the rig** (`9131e29`, `history.md` §28): SEED 6 first roll 104.32 / 102.05, PASS
at 101.4, 36,709 ALM (88 %). On .201, every picture, errors / late 0: x264 medium 720p30 8 Mbit/s
**~1.00x -> 1.13x**, 720p24 8 Mbit/s 1.12x -> 1.27x, NVENC 720p30 10 Mbit/s 1.16x -> 1.29x,
854x480p60 8 Mbit/s 1.42x -> 1.57x. On x264 720p30 8M the rig tracks the cosim (factor ~0.96
before and after: the 0.85 used in §4h-§4j's estimates came from a 480p x264 stream and was too
pessimistic for 720p); on the 854x480 control it gained more than the cosim (+11 % against +3 %:
the narrowed fetch's fewer DDR3 bursts count for more on the rig).

Tried and reverted: **four window banks** (the fetch up to three items ahead; no M10K): 755 ->
753, the start-of-item wait 59 -> 57. The wait is not bank-bound: about one DDR round trip a
macroblock -- its FIRST window, which cannot be requested before the macroblock's vectors
(`mv_pred`, stage A's own order). The lever behind it is a fetch across macroblocks (stage A
running `mv_pred` for k + 1 while `recon_inter` predicts k), not more buffering.

Rejected for now, **lever 2**: an 8-byte copy (eight window byte lanes, the copy's clamp and
lane match doubled on a path retimed before): after lever 1 the copy rarely starves the lanes.

## 5. Verification

- `run_recon_top.sh` x264 clips (i2 p4 bsp btm wp wb sl mvq r16, bspf): PASS at each step.
- `run_dpb_mem.sh`: ALL GREEN with the write skid.
- Mutations re-aimed or added: T10 (the read side's word), T11 (the stride), T12 (the
  drain). The anchors of R12, R13, H4, H8, H9 and run_cosim's C5 moved with the renames
  (updated in the same change).

## 5b. Code review (2026-09-30, after the rebase onto `e1b59de`)

No functional defect found in the pipeline paths (the five-bank rotation, the A/B hand-off, the
residual / motion / record bank flips, the four coefficient banks, PCM's port, the streamed
writeback). Acted on:
- stale `--red` anchors: `run_recon_top.sh` R14 / H3 and `run_dpb_mem.sh` M3 re-aimed at the
  rewritten code; new arms `run_dpb_mem.sh` M6 (the write skid's second entry) and
  `run_mb_syntax.sh` M20 (the level bank's interlock, under a stalling consumer: the runner's
  `mut` takes a stall argument now);
- `h264/h264.sdc`: the `wr_drained` count's crossing (`wl_g` -> `wl_s1`) bounded at 8 ns like
  the FIFOs' gray pointers;
- comments: what `wr_drained` proves (ram1's port took every beat -- not that the SDRAM
  controller committed them before a ram2 read; the display's refresh-boundary pickup is the
  margin), `pipe_idle` waiting at every NAL boundary (a few cycles a slice), `dequant_itrans`'s
  `busy` contract (three blocks in flight now).

**Known limitations** (recorded, not fixed):
- `clear` (recon_top's port, tied 0 in `emu`: the stream reset is `rst_n`): a clear in the
  middle of a residual block would leave the dequant units and the collector holding it, and
  the engine's take waits on an empty collector -- a hang. Nothing drives `clear`; a future user
  must reset those with it. (Since §4j that includes `dequant_itrans8`'s halves, `inflight`, its
  output stream and both passes: none has a clear.)
- `mb_syntax`'s output process idles a cycle between jobs (2 cycles a word job): with
  `se_ready` high it could sustain one a cycle by taking the next head as it pops. A
  throughput refinement, not a defect.
- The writeback's read and command sides repeat the item row walk (`c_next` / `r_next`), and
  `E_LK1` / `E_LK2` their exit; a change to the row ranges must touch both (arms T10 / T11).

## 6. Open

- **Timing at 103.85 (the 108.8 gate not closed; clk_dec now 96.43, §4f).** Retime round 1 (`2cc0690`): SEED 5's only cold
  paths under the gate were `top7` (6 endpoints, the five-bank read mux and a byte select into
  its own next-state select) -- top3 / top7 now load from `ip_nb_val` a cycle later (arms H18 /
  H19). The refit re-rolled (102.85 / 101.01) with the failures elsewhere (`sps_pps` 39,
  `deblock_filter` 11, ...); a sweep of 11 seeds: 95.2 .. **106.97 / 107.56 (SEED 10, pinned)**,
  108.77 / 106.56 (SEED 12: 6 endpoints, `deblock_filter` 5) -- none closes 108.8, all but one
  positive at the 103.85 clock. What recurs is `deblock_filter` (stage C's clip-add-clip into
  `p0o`, stage B's `t1p` from the high-fanout `a_q*`), untouched by the pipeline and closing on
  main at 80 % ALM: placement. Closing it would mean a deeper filter (a stage, whose latency
  the next edge's read-after-write sees) or recovering area; **left to the maintainer**, with
  the alternatives: test on a positive-but-marginal seed (main merged the overlay so, 105.81 /
  104.0), or keep sweeping. The maintainer took the recommendation: back to 96.43 (§4f).
- **What binds next** (cosim profile, `sun_high_8M`): the residual engine (`R_NEXT` + `R_FEED`
  ~520 busy at 720p; `dequant_itrans8` serial), the CABAC front end (`A_IDLE` ~90), the
  one-deep A/B hand-off on B-frame content (`A_HAND` 243 while B idles 312).
- **DDR3 latency on B-frames**: the rig runs ~16 % under the cosim on x264 B-frame streams
  (§4e); the reference fetch, not the pipeline, is the lever there (clk_mem, the fetch's
  run-ahead depth).
- 720p itself (the stores, the 1,620-macroblock bound, the display at 1280 wide) is a separate
  decision -- taken 2026-10-02 (roadmap Phase 5c: functional first, the throughput for x264
  720p30 at 8 Mbit/s its part 2).
