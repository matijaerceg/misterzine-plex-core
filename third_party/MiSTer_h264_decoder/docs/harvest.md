# Harvest table: what transfers from MiSTer_UMD_Video (and MiSTer_DVD), and when

MiSTer_UMD_Video (`../MiSTer_UMD_Video`) is the source of this core's decoder, display
path, framework edits, gates and process; it in turn harvested its plumbing from
MiSTer_DVD (`../MiSTer_DVD`), whose `docs/harvest.md` there says what came from where.

**This is a fork, not a share** (the maintainer, 2026-09-27; `roadmap.md` "Origin"). The
decoder is copied once, at a recorded UMD commit, and owned here from then on. The two
trees will drift -- this core grows toward 480p60 and possibly High profile -- so a fix
found in either is ported by hand and recorded in the "Fixes exchanged" table below,
both ways. Before porting, check whether the other tree's code has changed under the fix.

Modules are NOT copied speculatively: each comes over in the roadmap phase that wires
it, with its bench, runner, golden and `--red` arms in the same change (a bench copied
without its module is dead weight; a module without its bench is a MiSTer_DVD lesson).

Classification: **V** verbatim (path/header edits only) · **S** surgery (named) ·
**T** template (write a new module in its shape) · **X** do not copy.

## Done at Phase 0 (UMD `main` = `75e3f37`, 2026-09-27)

| UMD source | class | became |
|---|---|---|
| `sys/` (whole, every `UMD-FORK` edit) | V (byte-for-byte) | `sys/` |
| `umd/sys_pll.sv`, `umd/sync_gen.sv` | V (header) | `h264/` |
| `umd/dec_stub.sv` | V (header) | `h264/dec_stub.sv` |
| `umd/emu.sv` (UMD's P0 shape, today's port list) | S | `h264/emu.sv`: no file slot, no OSD pop, no mount handling, the idle screen swapped |
| `umd/xmb_wave.sv` (the PSP wave) | X | replaced by `h264/idle_bars.sv` (new) |
| `umd/block_streamer.sv`, `umd/ddr_arb.sv` | X | no sd path; `ddr_mux2` comes in Phase 2 instead |
| `build_release.sh`, `tools/{fmax_check,lint_undriven,netlist_canary,seed_sweep,timing_paths,synth_unit,package_release,publish_draft,docker_reexec,notify}.*` | V (names) | same paths |
| `tools/docs_check.py` | S | no buttons / extensions allowed |
| `tools/check_emu_wiring.py` | S | helpers + sys_top / ram2 checks verbatim; the seam checks rewritten |
| `tools/mister.py`, `tools/mister_keyd.py` | S | the stock-Main subset: no HIL Main, `launch` without an image |
| `bench/umd/sync_gen_tb.sv`, `run_scaffold.sh` (shape) | V / S | `bench/h264/` |
| `.claude/` skills and `/merge`, `.github/`, `mkdocs.yml`, `site/` shell, `.gitignore`, `.vscode/` | S (names, audience) | same paths |

## Phase 2: the decoder and the display path

**Record the UMD commit harvested from** in the Phase 2 commit message and here: it
is the boundary for "Fixes exchanged" below. A UMD fix made before that commit arrives
with the copy and needs no port; one made after it does. UMD keeps the mirror table
("Fixes exchanged with MiSTer_h264_decoder" in its `docs/harvest.md`) and tells its
agents to check this tree before fixing `umd/h264/` or the display path.

- **Phase 2 harvested from UMD commit: `cc595c6`** (UMD `main`, its PR fj#17 merge,
  2026-09-27; this tree's `a32e2c6`). UMD's `sys/` is byte-identical to the fork point's
  (`75e3f37`), so nothing under `sys/` moved; between the two commits the copied RTL
  changed only in `ddr_mux2.sv` (the orphan-grant fix) and `disp_ctl.sv`.

What came over, and how (the table below is the plan it followed):

- **RTL verbatim** but for the paths: every `umd/h264/*` → `h264/dec/` (`au_pts.sv`
  included: its rule -- a PTS belongs to the first access unit starting at or after its
  marked byte -- is source-neutral, and a ring record that marks an access unit's first
  byte satisfies it exactly, so the planned surgery is nothing; Phase 3 confirms it when
  D4 fixes the record); the display path and its crossings → `h264/`.
- **Not carried:** `se_cdc.sv` (UMD's retired P4 clocking fallback: nothing wires it) and
  its bench arms; `diag_hud` / `p2_diag` / `hud_font` (decided 2026-09-27: telemetry
  only, at Phase 3, no on-screen HUD); `umd_telem` / `ddr_probe` / `telem_layout` / `main/`
  (Phase 3, re-planned then); `vbuf.sv` (Phase 3's template); every X row.
- **Benches and runners:** 19 runners (`bench/h264/run_*.sh`) with their benches, the
  C++ cosim and `ddr_model.sv`. Every `$UMD_ISO_DIR` disc arm is gone: replaced by an
  H.264.1 stream where it carried coverage or a RED target (`camp_mot_fld0_full` for the
  field slices, `CAPA1_TOSHIBA_B` for the POC lsb wrap), dropped where another fixture
  already required its classes. Three recon_ctl arms (D1, D3, L2) would otherwise have
  SKIPped silently. `run_cosim.sh` is rebuilt around x264 720x480p59.94 windows (film-like
  and Sunshine-shaped) and two field streams, its `--sweep` over the H.264.1 CABAC set and
  `--dir`. K0 of `run_f2sdram_term.sh` reads `bench/h264/f2sdram_term_stock.sv` (MiSTer's
  stock terminator) instead of a UMD commit.
- **Tools:** the models and goldens (`tools/*_ref.py`, `*_golden.py`, the CABAC tables, JM
  build and fixtures) with their `--disc` inputs removed; `cosim_golden.py` takes an
  Annex-B `--es` (Phase 1's `tools/p1/es_golden.py` folded in); `tools/tests/` with the
  four tests that apply (`score.py` is `umd_synth.py`'s `Score` class alone).

| UMD source | class | change |
|---|---|---|
| `umd/h264/*` (`h264_pkg`, `nal_parser`, `rbsp_reader`, `sps_pps`, `slice_hdr`, `cabac_ctx`, `cabac_engine`, `mb_syntax`, `sei_pt`, `h264_top`, `dpb_mem`, `dsf_calc`, `recon_*`, `mb_intake`, `mv_pred`, `mc_interp`, `wpred`, `recon_inter`, `intra_pred`, `dequant_itrans`, `deblock_*`, `recon_mb`, `recon_top`) | V | → `h264/dec/`; `$readmemh` paths |
| `umd/h264/au_pts.sv` | ~~S~~ V | carried verbatim (above): the position rule is source-neutral; Phase 3 confirms with D4 |
| `umd/recon_out.sv`, `ddr_mux2.sv`, `disp_reader.sv`, `disp_sched.sv`, `disp_ctl.sv`, `aspect_vui.sv`, `cdc.sv`, `sfifo.sv`, `fifo_dc.sv`, `vidfeed_cdc.sv` | V | → `h264/`; `aspect_vui` later gains the exact aspect (Phase 6). `se_cdc.sv`: X (above) |
| `umd/umd.sdc` (the decoder's and the display's bounds) | S | → `h264/h264.sdc`, the reader / demux lines dropped |
| `umd/ddr_probe.sv` | S | **Phase 3**: → `h264/ddr_probe.sv`, the beat counters widened to 32 bits; watches ram1, read through the status block |
| `umd/umd_telem.sv`, `umd_telem_words.svh`, `tools/telem_layout.py`, `main/` (the HIL Main) | X | **decided 2026-09-27 (D4)**: the HPS interface's status block is the telemetry; `tools/ring_layout.py` is `telem_layout.py`'s pattern (one table -> the RTL mux and the C header, `--check`) |
| `umd/diag_hud.sv`, `p2_diag.sv`, `hud_font.mem`, `tools/diag_layout.py`, `hud_font.py` | X | decided 2026-09-27 with the maintainer: telemetry alone (Phase 3), no on-screen HUD |
| `bench/umd/*` for the above, `ddr_model.sv`, `cosim_top.sv`, `cosim_main.cpp`, `run_f2sdram_term.sh` + `f2sdram_term_tb.sv` | V / S | → `bench/h264/`; disc windows replaced by x264 / H.264.1 fixtures |
| `tools/cabac_*.py`, `gen_cabac_tables.py`, `h264_fe_ref.py`, `h264_recon_ref.py`, `h264_fields.py`, `h264_trace_ref.py`, `h264_conformance.py`, `h264_synth.py`, `jm_build.sh`, `jm_fixtures.py`, `jm_posix_compat.h`, `*_golden.py`, `dpb_output_ref.py`, `disp_sched_ref.py`, `disp_golden.py`, `comb_metric.py`, `cosim_*.py`, `tools/tests/test_h264_*.py` | V | `$UMD_REFS_DIR` → `$H264_REFS_DIR` |
| `umd/vbuf.sv` (UMD P6, 2026-09-27: a 2 MB compressed-video buffer on ram1 through `ddr_mux2`'s master B, with write bursts) | T | **Phase 3**: `h264/ring_rd.sv` -- vbuf's engine / clk_sys split, its read bursts and its clear handshake (never withdrawing a command); the ring is written by the ARM, not the fabric, so the engine polls a write index and writes the status block instead of packing bytes |
| `umd/umd_reader.sv`, `ps_demux.sv`, `ps_stream_fifo.sv`, `es_probe.sv`, `tools/umd_*.py`, `psmf_*.py`, `at3p_*`, the P1 corpus tools | X | UMD's container and disc; this core's input is the ring |

## Phase 4: audio (from MiSTer_DVD via UMD's P6 plan)

Read end to end 2026-09-29 (`architecture.md` "Audio (Phase 4)", "What the harvest found"):
the draft's list assumed DVD's audio path was a DDR3 buffer and four reusable modules. It is
not: DVD's DDR3 audio path was retired on 2026-06-27, its ring is an M10K byte ring of
compressed frames, and two of the four modules serve its disc navigation. What carries over is
two ideas inside `dvd_audio_decode.sv`, rewritten here for PCM (`h264/aud_play.sv`).

| source | class | change |
|---|---|---|
| MiSTer_DVD `dvd_audio_decode.sv`: the 48 kHz tick from clk_sys and the gate at the PCM FIFO's exit (armed from the stream's start, released at STC >= the head's PTS, re-armed by an underrun; the pause reuses it) | T | rewritten in `h264/aud_play.sv`: an exact 562 / 563-cycle tick instead of the NCO; the gate plus a per-record PTS check (silence / drop past 10 ms) and the audio anchor instead of the fallback timer; the low-latency queue rule is new |
| MiSTer_DVD `audio_ring.sv` | T | the descriptor FIFO idea only (`{position, length, PTS}` per record); the bytes stay in the HPS ring |
| MiSTer_DVD `aud_drain.sv`, `lin_rate.sv` | X | disc navigation (natural transitions, linear-file seeking) |
| MiSTer_DVD `av_sync.sv` | X | the clk_sys mirror of DVD's clk_dec STC; this core's STC is already on clk_sys (`disp_sched`) |
| UMD's ATRAC3plus decoder (`feature/p6-atrac3p` there) | X | D2 decided: no in-fabric codecs |

## Phase 6: display completeness (MiSTer_DVD modules UMD listed and did not build)

| MiSTer_DVD source | class | change |
|---|---|---|
| `csync_smpte.sv`, `field_polarity.vh`, `timescale.v` | V | the 480i raster; `sync_gen`'s interlaced branch |
| `pal_detect.sv`, the PAL raster | S | fed the SPS height |
| `frame_drop_ctl.sv` | S | skip `nal_ref_idc == 0` when behind |

## Fixes exchanged with UMD after the fork

(MiSTer_DVD's exchanges are recorded here too, its name in the row.)

| date | fix | found in | ported to | commit(s) |
|---|---|---|---|---|
| 2026-09-27 | `tools/mister.py`: a second `launch` backed up the harness's own settings file as the user's (`.hilnew` marker; `restore` waits for the menu load) | H264 (P0 HW gate) | UMD (PR fj#16, `0e335c1`, with `tools/tests/test_mister_cfg.py` + 3 RED arms) | H264 `caba00d` |
| 2026-09-27 | `umd/ddr_mux2.sv`: in the cycle an orphan write (the reload-hang fix's re-presented command) is accepted, A looks idle and the grant could pass to master B inside A's new write burst; the grant now never moves while `orphan` (and the same on `b_cut`). Latent in UMD while B was tied off. Bench: X12 in `run_disp_reader.sh` (the long-latency arm) | UMD (PR fj#17) | H264: **arrived with the Phase 2 copy** (`cc595c6` is PR fj#17's merge); X12 caught here too. It matters because Phase 3's ring reader will be ram1's master B | UMD PR fj#17; H264 `a32e2c6` |
| 2026-09-27 | `tools/tests/red_umd.py`: the RED copy of `tools/` linked only `umd/`; `test_telem` needs `main/` and `bench/` too, so its control failed and its RED arms proved nothing -- now links all three | UMD | H264: **applied at the Phase 2 harvest** -- `tools/tests/red_h264.py` links `h264/` and `bench/` (every directory a carried test reads); its control copy is green | UMD (logged in its `docs/harvest.md`); H264 Phase 2 |
| 2026-09-28 | `bench/h264/cosim_top.sv`: the ES ready is gated with the front end's synchronised reset -- `nal_parser`'s `in_ready` reads 1 in reset, so the harness's first byte after reset was taken and lost (a stream opening with a 3-byte start code lost its SPS: `ERR_NO_SPS`). emu is safe: its CDC FIFO shares `fe_rst_dec_n` | H264 (P5a, the pcm cosim window) | UMD: **checked, not applicable** -- its cosim_top resets `h264_top` with the harness's own `rst_n & seek_rst_n` (no `cdc_reset` on the clk side), so ready and the parser leave reset together; worth a look if a synchroniser is ever added there | H264 `7b433c6` |
| 2026-09-28 | `tools/h264_synth.py unlossless` (new in H264 P5a) kept neither the bytes before the first start code nor a rewritten unit's trailing zeros: the SPS lost its zero_byte (B.1.2) | H264 | UMD: not applicable (the mode is H264's; UMD's `rewrite()` already keeps both) | H264 `7b433c6` |
| 2026-09-28 | UMD took H264 P5b's `e2c8aeb` (mv_pred's registered `ref_in` / `c_dir*`) and `d6e7b69` (recon_inter's x0 stage, recon_mb's plane bases) verbatim: 5 of 5 fitter seeds pass UMD's 86 MHz (2 of 9 before), cosim bit-exact, cycles unchanged | H264 (P5b) | UMD `752e912` | H264 `e2c8aeb`, `d6e7b69` |
| 2026-09-28 | `run_mv_pred.sh` M21 (from UMD): spatial direct's `ref_in_q` must be taken as `S_SP_REF` writes it (the cycle before `S_MVP_Q0` reads it) -- the mutation replaces that branch with the plain `ref_in` copy; caught by BDIR16S (6 of 1,981 cases, as in UMD) | UMD | H264: **taken** | UMD `752e912`; H264 (P5b, with this row) |
| 2026-09-28 | Stale sim binaries: a runner that checks `[ -f sim ]` without deleting it first runs the last build when a build fails (`run_mv_pred.sh`, `run_dequant_itrans.sh`, `run_recon_ctl.sh` in UMD) | H264 (P5b: `run_intra_pred.sh` printed GREEN on an edit that did not compile) | both: H264 fixed every runner in `a364cb0`; UMD added `rm -f` in `752e912` | H264 `a364cb0` |
| 2026-09-28 | dequant_itrans: UMD registers the LevelScale lookup at the intake with the coefficient (`p1_ls <= ls_in` from `{b_m, in_cls}`; `b_m` is set a cycle before the first coefficient can arrive) -- zero cycles, where H264's P5b product register costs one a block | UMD | H264: **noted, not taken yet** -- H264's stage shape differs (the High-profile weight stage in front of the product); worth trying if dequant_itrans reappears in the census | UMD `752e912` |
| 2026-09-28 | recon_dpb's D_OPEN wait on `disp_hold` counts `err_no_store` every STALL_LIMIT while the display is FROZEN holding its stores (a pause: ~8 false errors a second in UMD). UMD's fix: a `disp_frz` level into recon_top / recon_dpb (two flops into clk_dec); the stall counter restarts while frozen and counts only unfrozen. Also found: no bench hold had ever outlasted STALL_LIMIT, so the alarm had never run in simulation (UMD's `run_recon_top.sh` now builds a second sim with `-Precon_top_tb.STALL=20000`: r16f / r16a, F1-F3) | UMD (its pause, `docs/transport.md` §9) | H264: **the freeze does not exist yet** (pause is planned out of band for interface 0.2, Phase 4: `docs/architecture.md`), so no false count today -- take `disp_frz` WITH the pause. **The alarm-coverage gap applies now** (H264's only long hold is O9's 600 k cycles against a 13 M bound): **ported** (P5b): recon_top passes STALL_LIMIT through, `run_recon_top.sh` builds `sim_alarm` with `-Precon_top_tb.STALL=20000`, arm r16a (+expect_alarm: code 6 counted, every picture exact) and mutation A1 (the alarm never counts: caught by [alarm]); the freeze half waits for the pause. **The freeze half ported with the pause (Phase 4, 2026-09-29):** `disp_frz` into recon_top / recon_dpb (the bound restarts while frozen), emu's `frz_dec_s` (interface 0.5's `ctl_pause` through two clk_dec flops, bounded in `h264.sdc`, pinned by `check_emu_wiring.py` + W56), `run_recon_top.sh` r16f (frozen, a wait past the 20,000-cycle bound, no error: [frz]) and F1-F3 | UMD `69179a5` | H264 (P5b, this row's commit); Phase 4 `feature/p4-audio` |
| 2026-09-29 | `build_release.sh` / `seed_sweep.sh`: a swept build's `.rbf.json` recorded the qsf's old SEED (the sweep restores the qsf before packing) and the last fit's area, not the winner's. The sweep now passes `BUILD_SEED=<winner>` to the pack and keeps `H264.fit.summary` with the `.sof` / `.sta.rpt` pair | UMD (P6b7, `2c1774a`) | H264: **ported** (Phase 4, before its seed sweep) | UMD `2c1774a`; H264 `feature/p4-audio` |
| 2026-09-29 | The display path (disp_ctl / disp_sched / recon_out, as copied): at three points of Akira (3:2 film) three pictures are held ~2x their duration, the scheduler re-anchors ~83 ms back and recon_dpb's store alarm (code 6) trips; reproduces exactly, the decoder bit-exact there; at an output-order spot where three pictures are decoded before the next store is emitted. UMD `docs/transport.md` §9 "P6b7, as built" | UMD (its whole-film rig gate) | H264: **open, not fixed in UMD yet** -- UMD will say when; check this tree's display against it then (the same code). UMD's diagnosis (2026-09-29, its `display.md` §10): the STREAM, not the RTL -- a GOP-opening PES PTS on many discs is 5-8 field ticks late and the next tag is back on the old timeline; disp_sched waited for the lone late tag, then re-anchored the STC back. Planned rule: a lone tag more than a frame and at most 0.5 s ahead of the timeline is disbelieved, the next tag always believed. Here it matters for a program whose container timestamps jitter the same way (a TS remux). **The fix exists (2026-09-29):** UMD `fix/film-timing` `c4422c2` (not yet merged there), its three-point rig repro clean (no STC step, no code 6, no audio re-arm) -- to port on its own branch after Phase 4 merges, with its bench. **Merged on UMD's main
2026-09-30 (PR fj#25, `74aa193`, unchanged since `c4422c2`)**: the rule in `disp_sched.sv` (ev[1]'s
`lone_pts` stage, `susp`, `tag_e`) and `n_lone` in `disp_ctl.sv`; the model
`tools/disp_sched_ref.py` ("lone PTS" in THE RULES); bench scenarios lone7 / lonefld / lone2
and RED D30-D36 in `run_disp_sched.sh` (D2 / D4's mutation anchors moved: the compares appear
twice); rationale and census UMD `display.md` §7, §10.6-§10.8; the window's upper edge FWD_MAX,
the lower HALF_SCAN (half a refresh), not a frame. **Rule B, merged on UMD's main 2026-09-30
(PR fj#26, `7087070`): the band is symmetric** -- a lone tag BEHIND the timeline is disbelieved
too: `ln = ((d_pic_next > HALF_SCAN) || (d_pic_next < -HALF_SCAN)) && !(d_pic_next >
FWD_MAX_TICKS) && !(d_pic_next < -FWD_MAX_TICKS)` in `disp_sched.sv`, `abs()` in
`disp_sched_ref.py`; new scenarios loneearly / loneearlyfld / back1s, RED D37 / D38, D33 / D34's
anchors moved. Also found there (harmless, UMD `display.md` §10.9): the timeline keeps whole ticks
for untagged pictures (-0.75 tick per 23.976 frame). H264: **ported together 2026-09-30 on
`fix/lone-pts`, ✅ MERGED (PR fj#15)** (`display.md` §10): `disp_sched.sv`'s ev[1] stage (`tag_e` also in the audio
anchor's `far` leg; `half` from the raster), `n_lone` in `disp_ctl` -> the status block's
`disp_lone` (interface 0.7), the model, scenarios lone7 / lonefld / lone2 / loneearly /
loneearlyfld / back1s + lone7@2 (the 50 Hz edge), mutations D18-D26 | UMD `74aa193`, `7087070` (main) |
| 2026-10-01 | UMD's 480i display fixes (UMD PR fj#37, merge `919b8e9`; its `docs/analog.md` V6 / V7, its harvest row of the same day), both HW-confirmed on the maintainer's CRT there: **(1) field order at 480i** -- `disp_ctl` defers a field PAIR's pickup one refresh when its first field's parity differs from the next raster field's (`pdefer`; not for late heads; the freeze sampled only at top fields so a pause keeps the phase), model `disp_sched_ref.py --il`, RED D39-D42 -- here a field-coded source shows reversed pairs half the time; **(2) a single field (and a paused pair) shown on both raster fields at 480i**, the other field's lines rebuilt half a line -- here they are left stale | UMD | H264: **(1) ported 2026-10-05** on `feature/arm-codecs`, after the RetroTINK measured it here (576i, interlaced MPEG-2 from the ARM: every pair later-field-first, `history.md` §35): the same rule (a due PAIR held one refresh when the refresh it decides is not its first field's; never a late head, a frame or a single field) on this tree's refresh grid (`fpar`, refresh 0 the top field); added here: the hold's next pickup not counted late nor its store's cadence judged, word 85's `disp_fhold`, the bench's `[field]` arm against `sync_gen`'s v_pos, scenarios `fldmix` / `fldlate`, F1-F9. **Not ported:** UMD's freeze sampled at top fields (this tree's pause gates the STC per cycle and feeds `aud_play`: after an odd-field pause every pair is held, in order, a field behind the audio -- `analog.md` §5). A two-field minimum on a shown pair was tried here and rejected (it ratchets: `analog.md` §5). **(2) not taken** (singles are H.264 PAFF only; the ARM path sends none) | UMD `919b8e9`; H264 `feature/arm-codecs` |
| 2026-10-06 | `dac_dither`'s matrix: the first one took a 4 x 4 Bayer's top two bits, which reduce to a 2 x 2 `{0 2; 3 1}` -- exact over 4 x 4 but not per line, so `v % 4 = 1` / `3` showed alternate lines half a DAC step apart (a line texture); now a Latin square, every line and column exact (`analog.md` §12 "The matrix"). The dither itself was written here first (`63ca27d`, 2026-10-05, `feature/arm-codecs`); MiSTer_DVD's own is its PR #161 | MiSTer_DVD (its PR #164, `d7f17a9`; a capture A/B and its CRT) | H264: **ported** (PR fj#38) -- DVD's matrix as it is; its pixel-pair arm (T9) and cyclic-Latin mutation not taken (a 2-clock-pixel property; a pixel here is 3 or 6 clocks of `clk_vid`); `run_dac_dither.sh` `[lines]` / `[cols]`, T8 / T9 | DVD `d7f17a9` (merge `233bca7`); H264 `a5cd75b` (merge `c327b03`) |
| 2026-10-11 | `sys/`: **`pll_hdmi`'s output counter is not pinned in the stock framework.** Main sets every HDMI mode's pixel clock by rewriting the PLL's physical C counter 0 and its VCO (Main_MiSTer `video.cpp` `setPLL`). A fit that puts `outclk_0` on another counter still closes timing and still shows 1080p (the compiled 148.5 MHz). Every other mode then keeps the compiled /3 under the new VCO: 720x480 at 135 MHz (a black TV) and 1280x720 at 148.5 MHz (720p120). Here: the SEED 2 fits of three branches, on `PLLOUTPUTCOUNTER_X0_Y7_N1` (`history.md` §47). Measured on the rig as the ADV7513's CTS (TMDS clock); its detected VIC does not see the clock. The fix pins `FRACTIONALPLL_X0_Y1_N0` + `PLLOUTPUTCOUNTER_X0_Y5_N1` in `sys/sys.tcl`, and `tools/hdmi_pll_check.sh` gates the fit report (fatal on `--release`) | H264 (the maintainer's TV at `video_mode=2`) | DVD and UMD: **the same exposure, not hit today** -- both current fit reports are on X0_Y5 (`hdmi_pll_check.sh` PASS on each, 2026-10-11). Measured the same day on .201 at 720x480: DVD `20261011`, `20260930`, `20260918` and UMD `zoom_20261009_2050`, `telecine_20261009_0424`, `resetfix_20261008_0525` all send exactly 27.000 MHz (the ADV7513's CTS). The two `sys.tcl` lines and the gate port verbatim | H264 `fix/hdmi480-black` |
| 2026-10-12 | **A field store's chroma at Figure E-1's FIELD siting.** `disp_reader` / `disp_golden.py` took a field's vertical chroma offset as the frame's `voff` in the field's own lines (field-centred: type 0's rows at a half of each field line pair); H.264 Figure E-1 sites field p's chroma row m at frame line 4m + 2p + voff (MPEG-2's interlaced 4:2:0), i.e. `(voff + p) / 2` of its own line pair -- type 0 a quarter in the top field, three quarters in the bottom. An eighth of the chroma step on every field line, visible on field-coded content only (interlaced H.264, the player's interlaced MPEG-2 pairs). Oracle: ffmpeg 9.0.1+'s interlaced upsampling (`scale=interl=1`), within a code at all six sitings, the old rule > 1 code off (`check_field_oracle`) | UMD (building its own field chroma step, branch `feature/chroma-field` `8b747e8`; its harvest row "to port back") | H264: **ported** (`fix/chroma-field`, 2026-10-12): `c_vf = (voff + p) / 2` in `disp_reader`'s field row position, the golden's field rule and worked positions (types 0 / 2 / 4), UMD's `up_fv` as the golden's independent field cross-check, `check_field_oracle`; `run_disp_reader.sh` N12-N14 (`docs/chroma.md` §2) | UMD `8b747e8`; H264 PR #17 |
