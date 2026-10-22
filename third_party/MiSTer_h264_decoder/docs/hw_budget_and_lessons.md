# Fabric budget, memory ports, and the verification rules a failed feature earned

**Inherited from MiSTer_DVD by way of MiSTer_UMD_Video** (MiSTer_DVD's
`docs/hw_budget_and_lessons.md`, written 2026-09-21 after an abandoned deinterlacer; UMD
carried it with path edits). §1 is this core's own budget plan. §2, §4, §5, §6 and §7 are
that note's generic sections, reproduced with only path edits: every measurement in them
is about MiSTer_DVD's netlist on the same device, and every rule in them is general.
Read §2 before designing anything that touches DDR3, and §4 before trusting any gate that
says a feature works.

---

## 1. This core's budget plan

Device: Cyclone V 5CSEBA6U23I7 — **41,910 ALM, 553 M10K, 112 DSP**. MiSTer_DVD ships at
~88-93 % ALM, and UMD's P4 placed at 91 % before its area work; that is the regime where
every feature becomes a fit-rescue and clk_dec loses its margin (at 91 % UMD's front end
fell from 92 to 84 MHz).

| block | ALM | source |
|---|---|---|
| framework (`sys/`) + raster + idle screen | **6,779 measured** (P0 fit, `H264.qsf`) | this core |
| the decoder as forked (front end ~3.6K + reconstruction ~11.5K) | ~15K | UMD's fits, P3-P5 |
| the display path (output order, scheduler, reader, deinterlacer) | ~3K | UMD's P5 |
| the ring reader, the status block, `ddr_probe` | **1,385 measured** (P3i fit: `ring_rd` 764, `ring_stat` 296, the status muxes 217, `ddr_probe` 108) -- plus ~1,200 of the decoder's counters, pruned while unconnected, live since | Phase 3 (`H264.qsf` ledger) |
| audio presentation (ring, drain, A/V gate, NCO) | ~1K | MiSTer_DVD / UMD |
| in-fabric audio codecs, if D2 says so | ~3-4K | the UMD session's estimate from its ATRAC3plus DSP |
| **left for throughput and High profile** | **~12-16K** | to ~90 % |

Estimates; `roadmap.md` "Resource checkpoints" is updated with the measured fit after
each phase.

Why the forked decoder is small: UMD's throughput doctrine (one sample, one tap or one
coefficient per cycle, a shared datapath) for 12.4 Msamples/s. This core's target is
~2.5x that in samples and more in bins (480p60 at game bitrates), which is why Phase 1
measures before Phase 5 spends the remaining area.

Memory: the DPB for 720x480 at Level 3.1 is the same order as UMD's (UMD sized to 20
stores, the spec maximum at its level); the binding resource is **port occupancy** (§2),
so the display keeps `ram2` to itself and the ring's reads share `ram1` with the DPB.

Timing: `clk_dec` = 81 MHz is the domain the gate watches (`tools/fmax_check.sh`, 86.0 MHz
at both slow corners). Every block designed for clk_dec should be written registered-out
with the suppression terms at the capture register (§5), and the cold corner checked
(`TIMING_TEMP=-40`).

---

## 2. ★★ THE SCARCE RESOURCE IS ARBITRATION OCCUPANCY, NOT BANDWIDTH

Three independent measurements say the same thing, and it is the single most reusable
design rule here.

**(a) Direction matters far more than volume.** A write pump moving ~10 MB/s through
`ddr_arb` cost **nothing detectable** (lates/drops/vbuf unmoved over 10 alternating
windows). A *read* path of the **same byte rate** cost **+65 % lates**. Bandwidth
saturation cannot tell a read from a write; grant occupancy can.

**(b) Halving the traffic cut the cost 8.7×, not 2×.**

| | lates/s | drops/s | content fps |
|---|---|---|---|
| every line, on `ram1` | 5.375 | 2.683 | 22.33 |
| half the lines, on `ram1` | 0.620 | 0.312 | 24.70 |

A linear response would mean a bandwidth budget being consumed. A strongly super-linear
one means a **contention threshold** being crossed.

**(c) The controlled version: same traffic, different port, zero cost.**

| | lates/s | drops/s | content fps |
|---|---|---|---|
| half the lines, on `ram1` | 0.620 | 0.312 | 24.70 |
| **half the lines, on `ram2`** | **0.000** | **0.000** | **25.03** |
| control arm (pump off) | 0.000 | 0.000 | 25.01 |

Nothing about the DDR3 device or the number of bytes changed — only which master had to
wait for a grant. **0 of 6 windows positive.**

### Why a read is so much more expensive than a write

A write is fire-and-forget into the bridge's buffer: the master hands over beats and is
done. A read holds the grant through **command + memory latency + every return beat**,
with the other master held off by `waitrequest` for the whole slot, because responses are
routed by grant and the grant cannot move while beats are outstanding.

### The rule for future features

> **If a new DDR3 master measurably hurts the decoder, do not reach for smaller data
> first. Ask whether it can have its own port.** Subsampling, lower precision and shorter
> bursts all trade a feature's quality against the wrong variable. `ram2` is free and
> costs no quality at all.

⚠ All three ports reach the **same DDR3 device**, so a port move buys **no bandwidth**.
It removes arbitration occupancy. That is a different (and, here, the binding) resource.

---

## 4. ★★★ HOW A FEATURE WITH A FULLY GREEN GATE SHIPPED AS A VISIBLE REGRESSION

Stage B had 42 green arms in `run_deint.sh --red`, 12 mutations each caught by exactly its
own arm in `run_hist_wr.sh --red`, a memory-path A/B, a wiring checker, and an offline
model predicting it would help. It was still a regression on a screen. Every reason below
is general.

### 4.1 The bit-exact model cosim never exercised the feature

`bench/dvd/ (MiSTer_DVD) deint_comb_tb.sv` is the **only** bench that compares the RTL bit-exactly
against `tools/deint_model.py` — the model whose numbers justified building Stage B at
all — over real disc frames. When Stage B's ports were added, that bench tied
`.hist_ok(1'b0)`, the no-history case.

So the feature was validated by: a directed arm (the veto zeroes a weight), a differential
chain arm on synthetic data, and a memory-path bench. **Not once was its output compared
against the model that predicted the benefit.**

> **RULE. When a feature is justified by an offline model, the bit-exact cosim against
> that model MUST exercise the feature. Otherwise the justification is untested, and a
> model/RTL divergence and a wrong model are indistinguishable.**

⚠ This is also why the abandonment is clean rather than frustrating: nobody can currently
say whether Stage B failed because the RTL diverged from the model, or because the model
measured the wrong thing. Closing that gap is the first step for anyone who revisits it.

### 4.2 A bench can PASS vacuously on X — and `!=` is how

`deint_chain_tb` was given four new ports and they were left unconnected. Icarus floats
those Z; `hist_ok` Z made a predicate X, which made the dilated weight X, and because
`mix8`'s multiply propagates X through a *zero* weight, the pass-through anchor lines went
X too — **~1552 of every scan's 4096 pixels, 37 % of everything the bench emitted**.

Every one of those pixels **passed every arm**, because scoring used `!=` and
`x != 169` evaluates to `x`, which `if` treats as false. The bench printed
`RESULT: PASS` with 12,028 X pixels in it, for several commits.

> **RULE. Score benches with `!==`, never `!=`.** It is the only thing that makes this
> class self-reporting rather than silent. Reach for it immediately when a bench reports a
> count of 0 for something that cannot be 0, or is green on RTL you know is incomplete.

⚠ And the general form of the trap: **adding a port to a shared module silently poisons
every bench that instantiates it without the port.** After adding one, grep the benches
and tie it off in the same commit. This happened *twice* in one week here, the second time
in the very bench written to gate the new port.

### 4.3 A fixture chosen to make an arm decisive can make it unrepresentative

The chain arm scored a *static* region against a *moving* region within one scan — a
differential design, deliberately immune to a detector that simply stopped firing. Good
design. But the "moving" region moved by a fixed **24 code values** per picture, well
above the threshold of 8, because that is what made the arm unambiguous.

Real content moving slowly changes by **less** than the threshold while still combing.
The arm could not have failed for the reason the feature actually failed.

> **RULE. Ask what range of the input space a synthetic fixture spans, and whether the
> failure you fear lives inside it.** A fixture tuned for a clean pass/fail boundary tends
> to sit far from that boundary.

### 4.4 The metric decides the verdict, so ask what it cannot see

The offline study scored *visible shimmer on static pixels* and a *global comb ratio*. It
never scored "comb left on slowly-moving edges", nor "the veto mask's edges are visible as
a one-frame trail" — the two things the maintainer reported. Both are invisible to both
metrics, so a favourable verdict was guaranteed regardless of those artifacts.

> **RULE. Before trusting a model's verdict, enumerate the artifact classes its metric is
> structurally blind to.** A number that cannot go bad for a given defect is not evidence
> about that defect.

### 4.5 When you reduce work, score the SET, not the COUNT

Halving the pump's reads (skipping lines whose history can never be consulted) was
implemented with the parity **inverted** — right algebra applied to the wrong line. It
fetched exactly the half that is never used.

The count was identical either way. The arm caught it in one run *only because* it scored
**which** lines were fetched. A count-based arm would have passed.

> **RULE. An optimisation that does half as much work must be gated on doing the RIGHT
> half. The wrong half has the same count.**

### 4.6 A measurement that can no longer detect its own subject

Once the pump moved to `ram2` its cost hit exactly zero, so the probe's two arms became
indistinguishable — **which is also precisely what a dead pump reads.** "No measurable
cost" and "not running" produce identical telemetry.

Liveness was proven separately: the DDR3 region *changes* with the pump on and *freezes*
with it off (with the decoder's own framestore as the control, to show playback was live),
and the pump's FSM is serial, so writes continuing proves its reads complete.

> **RULE. When an effect reaches zero, the instrument that measured it can no longer tell
> you the mechanism is present. Prove liveness by a different route before reporting
> "free".**

### 4.7 A PASS fit that sends the wrong HDMI clock (H264, 2026-10-11)

Three fits of three different branches closed timing, passed every gate and showed 1080p perfectly. At
720x480 the TV was black. `pll_hdmi`'s output had been placed on a physical counter that Main never
reprograms, so only the VCO followed the mode. 720x480 left at 135 MHz, and 720p at 148.5 MHz: a 120 Hz
signal that a 4K TV happily showed (`history.md` §47). Nothing in the build could see it, since the timing
analysis knows only the compiled 148.5 MHz. The transmitter's own detected VIC read "480p60" for the
300 Hz signal, because it counts lines and pixels and not time.

> **RULE. Logic that is reconfigured at run time is outside the fitter's view: pin what the run-time
> writer addresses (here the PLL's site and output counter, `sys/sys.tcl`) and gate the fit report for it
> (`tools/hdmi_pll_check.sh`). On the rig, measure the quantity itself (the ADV7513's CTS: `mister.py
> hdmi`), not a classifier derived from it.**

---

## 5. Timing technique that worked

### ★ Gate at the register, not inside the producing cone

A one-bit term was ANDed into a combinational result inside `deint_detect`. That put it in
the module's critical cone, which was already the binding path. Two consecutive builds
missed the gate (**91.42/85.08**, then **82.52/84.73** against 86.0) and each needed a
fitter seed sweep.

The term reached the output through exactly one gate, and the output was already zero
whenever that gate was false — so tying the input to `1'b1` and applying the term at the
**register** instead (`q <= term ? result : 0`) is algebraically identical, and lifts it
out of the cone entirely.

Result: **89.81 @100 °C / 88.36 @−40 °C, passing on the FIRST fit**, ~2.4 MHz of margin,
no sweep.

> **RULE. When a new term only ever *suppresses* an existing result, apply it at the
> register that captures the result, not inside the logic that produces it.**

### The cold corner usually binds, and the tool defaults to the hot one

`fmax_check` gates **both** slow corners and −40 °C is frequently the worse one, while
`tools/timing_paths.tcl` defaults to 100 °C. Pass `TIMING_TEMP=-40` or you will retime a
path that is not the one failing — which has cost this project two wasted retimes.

### A netlist change invalidates the pinned seed

`H264.qsf`'s pinned `SEED` is tied to the exact synthesis netlist. A seed that closes one
build can be far below the gate on the next: **SEED 5 passed at 88.61/87.63 and then
returned 74.76/79.39** after the RTL changed. Expect to re-sweep after any real change,
and treat a first-fit pass as luck rather than entitlement.

### ★ Retiming for a faster clock: the P5b playbook (81 → 96.43 MHz, 2026-09-28)

Fourteen fits took clk_dec's -40 °C fit from 87.4 to 101.4 MHz. What made the rounds
converge, in the order a round runs:

**1. Measure the census, not the top N.** A plain report's top 100 paths are one or two
clusters; fixing them reveals the next and each fit tells you one module. Instead count
every failing ENDPOINT once:

```bash
TIMING_TEMP=-40 TIMING_BELOW=<slack> USE_DOCKER=1 tools/timing_paths.sh 100000
python3 tools/timing_census.py        # per module: endpoints failing, worst slack, worst path
```

`<slack>` = constraint period − 1000 / gate (at 103.85 MHz and the 108.8 gate, since 2026-09-30:
9.630 − 9.191 = 0.439; at 96.43 MHz and the 101.4 gate: 10.370 −
9.862 = 0.508). **Run it at both corners** (`TIMING_TEMP=100` too): the cold corner bound
for the whole campaign, then the first fit at the new clock missed only at 100 °C. The
census went ~630 → 73 → 31 endpoints; a whole batch of modules fixed per fit.

**2. Read the cells before designing the fix.** The census names endpoints; the fix lives
in what sits between:

```bash
TIMING_TEMP=100 TIMING_PAIRS='*u_dpb|cur_store[0] *u_dpb|win_best[20]' \
  USE_DOCKER=1 tools/timing_paths.sh 5 && python3 tools/timing_chain.py
```

Look at the cell names (`LessThan`, `Add`, `Mux`, `Selector`, a RAM's `PORT_B`, a DSP's
`resulta`) and where the fanout column jumps. Guessing from the endpoint alone retimed the
wrong thing once in this campaign: `win_best`'s failing path was not the scan compare it
looked like but a 20:1 `ref_t[cur_store]` read gating its reset in the state before.

**3. The fixes that worked, by shape** (nearly every failing path was one of these):

| shape of the path | fix | examples (P5b) |
|---|---|---|
| a wide compare / predicate whose result fans out to many enables in the same cycle | register the predicate a cycle early (a new state, or a stage before the consumer) | recon_dpb `bump_it` → `D_OUT_PRE`; the parsers' range checks as `p_u5`/`p_u8`/... registered from `f_val` every cycle |
| a value used a cycle after it could have been computed | compute it where its inputs settle and register it | mb_intake's mvd mask on the x word for the y word; intra_pred's x / y / z one position ahead |
| a RAM output → lookup → arithmetic → compare | store the lookup beside the RAM word, or register the RAM output first | CABAC's rLPS row stored in the context RAM; residual add's RAM outputs delayed a cycle |
| `a - b >= c` behind a late operand | rearrange so the register-only part is precomputed in parallel | CABAC `off >= rng - rLPS` → `rLPS >= rng - off` (one compare behind the RAM) |
| a product in front of a compare | keep a running sum beside the counter | mb_syntax's `row_base` for `mb_y * PicWidthInMbs` |
| an N:1 select by an index that is itself late | select a cycle earlier (read at the address being issued) | recon_lists' marking read at `si`, used at `sx = si - 1` |
| a state-selected index feeding a big mux | separate muxes per state class, each with its own (registered) index | intra_pred's stream / prep tap muxes (`80.22` MHz until split) |
| an enable gated by a test that does not need to gate it | make the harmless assignments unconditional | recon_dpb `D_MARK_WIN`'s scan resets |

**4. Judge a batch by the census, not by one fmax.** Placement at 65 % ALM moves a fit
±3 MHz: `cd5b485` fitted 3.5 MHz below `9d3fc16` with no longer path. Two fits of the same
netlist can disagree; two censuses of it do not.

**5. Budget the cycles each retime adds, and prefer free ones.** Most cost nothing (a
predicate registered in a state that already waits). Where a stage adds cycles, count
where: per picture or per slice (recon_dpb, the parsers, cabac_ctx's init) is free; per
macroblock is worth checking; per bin or per sample is not free. `mv_pred`'s cap moved
(120 → 152 cycles); `intra_pred`'s cycle counts stayed identical (its `run_intra_pred.sh`
per-block table is the check).

**6. Keep the gates honest while retiming.** A retime moves code, so mutation anchors
break (re-anchor, never delete: 12 re-anchored here), some mutants become equivalent
(retire them with the reason in the runner, e.g. `run_intra_pred.sh` M20), and some become
unreachable by any fixture (probe every fixture before saying so, then document it, e.g.
`run_recon_ctl.sh`'s store-19 note). Every new register stage gets an arm that breaks it
(`run_h264_cabac.sh` E9 / E10 / C4, `run_intra_pred.sh` M21, `run_mb_syntax.sh` M18 / M19).

### ★ MV predictor availability retime (2026-10-16; qualified seed-1 fit)

The calibration branch's seed-2 cold `clk_dec` census had nine endpoints under the 0.508 ns
gate. The worst path was `recon_mb.a_av_aright` through `mv_pred`'s external-neighbour
availability, C/D choice, and 10:1 neighbour-entry mux to `nb_sel_q` (0.037 ns slack).
Capture the resolved external-or-internal availability in one register per neighbor in the
already-existing `S_PREP2` selector-prep stage, alongside each selector. External availability
is held for the macroblock. Internal `dec_done` is stable from `S_PREP2` through a normal
gather: the prior `S_APPLY` update happens before it, while the only `S_GATHER` update is a
direct-submacroblock fast path that skips these neighbor reads. This adds no state or cycle.
`run_mv_pred.sh --red` checks P/B reference streams, stall behavior, and mutation sensitivity,
including M24/M25 which remove either source. The first fitter after this change moved the
decoder limiter off `mv_pred` but still missed the 101.4 MHz gate at 100.82 MHz hot / 99.47 MHz
cold; video passed. Subsequent CABAC and DPB timing work is recorded below; the combined
seed-1 build now passes the strict clock gates.

### ★ CABAC initialization control cone (2026-10-16; qualified seed-1 fit)

The combined-availability fit's remaining decoder limiter is `h264_top.mbs_owns` through the
CABAC request-kind mux, `req_ready`/`take`, the variable `taken` shifter, and into
`cabac_engine.err_init` (8 logic levels; 0.317 ns cold, 0.451 ns hot slack). The initialization
branches consume exactly nine bits: K_REINIT is accepted only with no pending renormalisation
and enough input; S_INIT_CTX is non-idle and its consume is guarded by enough input. Therefore
`taken` equals `top9` in both branches. Use `top9` directly for their initialized offset and
510/511 error test, leaving the variable shifter for other request kinds. This adds no register
or cycle and removes the shift-select logic from that error path. `run_h264_cabac.sh --red`
exercises top9=510 and 511 on both K_REINIT and S_INIT_CTX and mutates each branch's threshold
independently. The initial candidate fit missed; after the DPB count was balanced, the combined
seed-1 build passed both decoder corners. See §9 for the measured resource and clock results.
**7. The clock itself.** outclk_3 shares the VCO with 27 and 90 MHz: list the reachable
frequencies before choosing (docs/throughput.md §4, and §7 for the 103.85 step), request the unused spare output as a
divisor of the new VCO, and read the fit report's PLL Usage Summary (VCO, M, N, C) to
confirm the frequency landed exactly. Anything that counts clk_dec cycles as time
(`recon_dpb`'s STALL_LIMIT, the cosim's clock) moves with it.

**8. The headroom round (96.43 → 103.85 MHz, 2026-09-30, `throughput.md` §7).** Four fits and a
sweep: a census of 12-13 endpoints in four clusters, fixed; the next fit's census moved to a
cluster no earlier fit had shown (recon_lists' L_FIELD), then one fix's placement pushed a path
that had always met timing (recon_dpb's D_POC1_RD2) BELOW the constraint itself, then a census
spread thin over three modules -- placement, where a seed sweep (SEED 9, first try) beat another
RTL round. Near 78 % ALM, stop retiming when the census stops being one cluster.

**8b. The 93 % ALM retime (2026-10-13, `throughput.md` §8): the seed spread is placement's.** Three rounds each removed
their census clusters, and each netlist still fitted ~93-104 MHz across four seeds -- the clusters move with the seed.
Two lessons: **measure a round on several seeds**, never one (round 2 passed SEED 5 at 104 and failed three others);
and **the fitter aims at the SDC, not at the gate** -- Auto Fit eases off at the real clock, so `h264/h264_fit.sdc`
over-constrains clk_dec for `quartus_fit` only (+2-3 MHz on average; it must follow `sys.qip`, after the PLL clocks
exist, or it is silently ignored -- check the fit report for "Ignored set_clock_uncertainty").

**9. The build gate watches setup only.** `fmax_check.sh` reads clk_dec's setup Fmax; the timing
report's *recovery* analysis had been negative into clk_dec on every build since at least
pad-home (`dec_stub`'s heartbeat counter released from clk_sys with no synchroniser: cosmetic
there, `throughput.md` §7) and nothing said so. After a clock change read the Setup / Hold /
Recovery / Removal summaries for every core clock -- a tighter edge pair (clk_dec / clk_sys 0.74
ns apart at / 13) moves exactly those.

---

## 6. Hardware-in-the-loop measurement discipline

- **An EMPTY `vbuf` is upstream starvation, not memory contention.** A decoder held off by
  the bus stops *consuming* and its buffer fills; a buffer that drains to zero means bytes
  are not arriving. Reading this correctly stopped a wrong diagnosis ("the pump is
  starving the arbiter") that was already half-written.
- **Test on LOCAL media.** The first probe attempt ran from a CIFS share and produced
  playback stalls that looked exactly like a core defect. A network hiccup and an arbiter
  bug present identically in telemetry. The stalls were never attributed and should not be
  cited in either direction.
- **A paired, alternating, within-build comparison cancels netlist quality.** That is what
  made it defensible to measure on a `_MARGINAL_` build: both arms run inside one netlist,
  so any weakness applies to both. ⚠ It licenses *relative* claims only — never picture
  quality, never anything cross-build.
- **Content drift is the same order as the effect.** Two consecutive same-arm windows on
  different scenes differed as much as the effect under test, which is why the arms must
  interleave rather than run as one Off block and one On block.
- **Check the feature is even engaged before measuring it.** Much of this work was
  measured on content where the deinterlacer never blended a pixel (`comb_density = 0`).
  That is fine for a *traffic* question and worthless for a *quality* one — and confusing
  the two is how a feature gets declared "free" the day before it is rejected.

---

## 7. Recurring papercuts, none of them interesting, all of them expensive

- **Verilog declaration-after-use** cost ~5 build/elaboration failures across this work,
  in both benches and `sys_top.v`. Icarus and Quartus both reject it; neither says
  "move the declaration up".
- **A port left as `input` while the module drives it internally** is a *multiple-driver*
  error that **neither the linter nor any bench can see** — `lint_undriven.sh` asks about
  nets with *no* driver, and every bench instantiates the leaf modules directly rather
  than the wrapper. Only the fitter catches it, as `Error (12014)`, ~30 seconds into a
  40-minute compile. When a signal stops leaving a module, delete it from the port list in
  the same edit.
- **`pgrep -f <pattern>`** matches the shell running the command that contains the
  pattern. An `until ! pgrep -f build.sh` loop waits forever on itself. Match on a
  container name or a PID.
- **A renamed OSD option must move with its manual row** (`tools/docs_check.py` enforces
  parity) — and, less mechanically, **a row whose description stops being true is a
  documentation bug**: this feature's row said it "changes only memory traffic, never the
  picture", which silently became false the moment the term consumed it.

---


---

## 8. What was left behind on purpose

The source note's §0, §1, §3 and §8 describe MiSTer_DVD's abandoned deinterlacer, its
measured per-module ALM table and its `ram2` wiring recipe. The recipe is reproduced in
`architecture.md` in outline; the rest is that core's history and is not carried here.

## 9. C.4.4 dropped-store count (2026-10-16; qualified seed-1 fit)

The IDR `no_output_of_prior_pics_flag` path counts waiting DPB stores other than the
current store. The old loop conditionally incremented a six-bit count once per store,
creating a serial arithmetic chain on the `clk_dec` path. The replacement forms one-bit
leaves with the same predicate and reduces them through a padded binary tree. With the
current `NSTORE=20`, this changes the logical adder depth from a store-by-store chain to
five levels. `drop_n` is still captured in `D_OUT_C44`; `out_dropped` is still updated on
the following cycle. No state, protocol, or picture-output timing changes.

The focused gate is `bench/h264/run_recon_dpb_drop.sh --red`: it exhausts all 1,048,576
waiting masks against all 20 current-store positions in a separate truth-table checker,
then drives the actual RTL tree and `D_OUT_C44` for empty/full masks, singleton masks,
and 4,096 deterministic pseudo-random masks. O14 deliberately removes the current-store
exclusion and must fail. `recon_top_tb.sv`'s byte-difference loops use bounded `while`
loops so Icarus 12 can compile the existing DPB regression. The full `run_recon_top.sh`
GREEN/RED regression remains the integration gate; the focused bench is not a substitute.

The qualified seed-1 build passes the strict clock gates: `clk_dec` is 102.65 / 102.17 MHz
against the 101.4 MHz gate, and `clk_vid` is 91.53 / 88.15 MHz against 86 MHz. It uses
41,180 / 41,910 ALMs, 56,960 registers, 421 M10Ks, and 110 DSPs. The RBF is
`H264_calibration_20261016_2357.rbf` (4,421,120 bytes; SHA-256
`09d868ebfc75412a18c1bad2527d5787a89372c94c4c5f034b777e95111ae968`). The full
HD720p recon_top regression timed out and remains inconclusive. Optional external reference
packs were skipped separately because they were unavailable; their absence did not cause the
HD720p timeout. The focused RTL counter bench and its current-store-exclusion mutation passed,
but do not replace the full regression. On Mister Pi, fit/crop/fit telemetry matched
the expected geometry with DeFlicker off and on, with fresh session nonces and
request acknowledgments. Both tests stopped cleanly. Physical CRT picture
validation remains pending.

Passing the clock gates does not mean every timing advisory is clear. In the cold
corner, all 49 new raster clipping fields have positive setup and hold margins
(at least 1.534 ns and 0.648 ns respectively). Four existing `ar_y` to `arx`
metadata paths have negative hold slack, worst -0.069 ns. A separate held-bus
`fit_sy[2]` transfer has -0.600 ns setup slack against its 12 ns max-delay
constraint; `cdc_snap` holds the bundle while the acknowledgment crosses two
destination-clock stages before capture. These advisories are separate from the
new clipping fields; no broad timing exceptions were added to hide them.
