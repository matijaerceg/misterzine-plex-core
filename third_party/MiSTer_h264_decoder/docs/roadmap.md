# Implementation Roadmap: MiSTer H264 core

> Speculative "might-be-interesting" ideas that are **not** committed here live in
> [`docs/experiments.md`](experiments.md). Move an item over once it is decided.

> **How to read the checklists.** Four markers, kept honest because a stale one
> misdirects a cold session as surely as a wrong comment:
>
> - `- [x]` — done. Some carry a note where the outcome differed from the plan.
> - `- ⛔ **[superseded — why]**` — no longer wanted *as written*, because the approach
>   changed under it. Kept, not deleted: the reason is usually more useful than the item.
> - `- ⛔ **[dropped — why]**` — reviewed and decided against.
> - `- [ ]` — genuinely still open.
>
> Phase headings carry a status: `🔧 in progress`, `✅ MERGED (PR #n)`,
> `✅ HW-CONFIRMED`, `⏳ HW-confirm pending`. **Flip the marker in the same change that
> completes the work** (CLAUDE.md "Update status markers").

## What this core is

An **H.264 decode and presentation accelerator for HPS-side programs** on the MiSTer
(DE10-Nano, Cyclone V). A Linux program on the ARM -- a Moonlight game-streaming client,
a Plex / Jellyfin client, a file player -- does the networking, demux, decryption and
error correction, and hands the core compressed video (Annex-B access units), audio and
presentation times through one published interface in DDR3. The fabric decodes, keeps
audio and video in sync against one clock, and scans out on HDMI and analog. Nothing
decoded goes back to the ARM. The ARM chip cannot decode H.264 at these rates in
software; this is the offload projects on the platform do without today.

**Origin.** The decoder is **forked** from MiSTer_UMD_Video (`../MiSTer_UMD_Video`),
where it was built (P3-P5 there: the front end, the reconstruction, the display path)
for UMD Video discs: H.264 Main, Level 3.0, 720x480 at up to 30 frames/s. UMD's roadmap
("Decision: the general H.264 player core splits off after P5") planned a shared
directory; **the maintainer decided on 2026-09-27 to split instead of share**: this
repository owns its decoder outright and grows it to this core's target (below). A fix
found in either tree is ported by hand and recorded in `docs/harvest.md`.

**Analog first (the maintainer, 2026-09-28).** A large share of MiSTer users care only
about analog output, typically interlaced: composite / component on a 15 kHz CRT.
Streaming video to HDMI is trivial for modern devices; streaming it to composite /
component is the hard part, and it is what sets this project apart. So **the 480i raster
with csync is a main goal of the project**, not a late extra: a 60p stream shown as 60i
(each field the alternate lines of its own frame, full motion rate), 30p and film shown
field by field, true interlaced sources as their fields. HDMI keeps working (the raster
feeds the scaler too), but display decisions are weighed for the 15 kHz case first. The
order of that work against audio (Phase 4) is the maintainer's call; proposed: right
after P5b's throughput.

## Guiding principles

- **One published interface, versioned.** HPS programs plug into the core through the
  ring and control block of `docs/architecture.md` "The HPS interface". The core never
  depends on which program is feeding it; a program never depends on the core's
  internals. A layout change bumps the interface version and is announced in the release
  notes (the `release` skill).
- **Source-neutral input.** The decoder and the scheduler take {ES bytes, a PTS per
  access unit, discontinuity / flush / end of stream} and nothing else. Container
  formats (MPEG-TS, MP4, RTP) are the producer's business on the ARM. (Inherited from
  UMD's P5 decision, which kept PSMF / CLPI on the producer side for exactly this core.)
- **Audio is presented by the core, against the core's clock.** Audio records carry a PTS
  and arrive through the same ring as video; the fabric plays them against the one STC
  the display runs on. The framework's ALSA path stays compiled out
  (`MISTER_DISABLE_ALSA`), so `ram2` stays the display's. Why: `sys/alsa.sv` already
  drains at an FPGA-clocked 48 kHz, so the two would not drift, but the OFFSET through
  Linux's ALSA buffering is unknowable from the fabric; presenting in fabric removes it
  (the UMD session's analysis, 2026-09-27). Where audio is DECODED is a separate, open
  decision (D2 below).
- **Never modify `sys/` except as marked forks**, additive where possible. Inherited
  edits keep their `UMD-FORK` markers; this core's own are `H264-FORK`
  (`docs/architecture.md`).
- **Bench before hardware.** Every module ships with a bench that `$fatal`s, a runner that
  requires the PASS marker positively, and `--red` mutations caught by their own arms.
- **Each phase ends on hardware**, with a stated HW gate and a control arm where the
  defect is intermittent.
- **Design to the spec maximum** (CLAUDE.md). Where a bound must be smaller, the reason
  and the failure mode are written beside the code and in `docs/spec_hardening.md`.
- **Measure, don't extrapolate.** Every scope decision below waits on a measurement.

## Target envelope

| | this core's target | the decoder as forked from UMD |
|---|---|---|
| picture | 720x480 progressive at 60 frames/s (Moonlight); up to 720x576; film and TV rates. (2026-10-02, Phase 5c: any picture to 3,600 macroblocks -- 1280x720 at 30, 720p24 films) | 720x480, up to 30 frames/s (Level 3.0) |
| level | 3.1 (81,000 MB/s is exactly 2x Level 3.0's 40,500) | 3.0; the fabric's limit is MaxFS / DPB, not `level_idc` |
| profile | **High (D1, decided)** -- a stock Sunshine host always sends it, with the 8x8 tools on ~3-4 % of coded macroblocks; decoded since Phase 5 (`high_profile.md`) | Main; High refused (`REF_T8X8`), CAVLC and MBAFF refused |
| bitrate | **real time at 10 Mbit/s requested** (~7.7 at the encoder; D1, decided); up to Level 3.1's maximum decoded correctly | tuned on ~2 Mbit/s film |
| macroblocks / s | 81,000 | ~57-66k measured on the UMD rig, disc content |
| CABAC bins / s | ~15-25 M at 10-17 Mbit/s | ~15-20 M (0.17-0.23 bins / cycle at ~89 MHz) |
| audio | PCM from the ARM (D2, decided 2026-09-29: the program decodes any codec), presented in fabric against the STC | none (UMD decodes ATRAC3plus separately) |

The gap, measured in Phase 1 (`p1_measurements.md`): **High profile** (required) and
**~1.27x throughput** at the 10 Mbit/s target (1,186 → ≤ ~935 cycles a macroblock in the
cosim). Not from the clock -- clk_dec closes at ~89 MHz against its 86 MHz gate -- but from
parallelism, so area.

## Resource checkpoints

| after phase | ALM budget (cumulative) | M10K | notes |
|---|---|---|---|
| P0 | **6,779 measured** (framework ~6.4K + emu 0.4K) | **60** | first fit, SEED 1; `H264.qsf` ledger. UMD's P0 was 7,190 ALM / 62 M10K |
| P2 | **23,331 measured** (56 %; estimate ~24-25K) | **230** | first fit with the decoder, SEED 1, clk_dec 91.43 / 88.67 MHz, 69 DSP; emu 16,937 (recon_top 11,453, h264_top 3,798, display ~1,250); `docs/history.md` §2 |
| P3 | P2 + the ring reader (~1.4-1.8K estimated) | | the reader, the status block (~30 words across three domains), `ddr_probe`; the budget note's "< 1K" was low |
| P4 | + audio presentation (~1K; no in-fabric codecs: D2) | | |
| P5 | ≤ ~38K (~90 %) | | what is left (~15-17K on paper) buys throughput and High profile |

Device: 41,910 ALM, 553 M10K, 112 DSP. Gate on the measured fit numbers after each
phase (`H264.qsf` SEED LEDGER), not on these estimates.

## Open decisions (each taken with the maintainer, then moved into its phase)

- **D1 — profile and throughput scope.**
  - ✅ **Profile: High, decided 2026-09-27 (the maintainer): "this should work with a
    stock server", so no patched Sunshine.** A stock host always sends High with the 8x8
    tools in use (`p1_measurements.md` §2b), so the fabric decodes High profile: the 8x8
    transform and its dequantisation, intra 8x8 prediction with its reference filtering,
    the 8x8 CABAC contexts (ctxIdx 399..459: 460 in all for 4:2:0 -- "1,024" counted
    4:4:4's copies, corrected in Phase 5, `high_profile.md` §1), the High SPS / PPS syntax
    (scaling matrices included, to the spec maximum even though no host measured sends
    them). Phase 5 builds it.
  - ✅ **Re-expressed 2026-09-28 (the maintainer): a budget, not a resolution.** The
    720x480 target came from DVD / UMD, whose formats are stored at that size; streaming
    servers are not. A Moonlight host encodes exactly the size the client requests (and
    fits its desktop into it with bars: P1's 720x480 capture carries a 640x480 picture
    between 40-pixel bars); Jellyfin / Plex transcode to fit the client's declared maximum
    width / height, aspect kept, so any size arrives (a 16:9 film capped at 720 wide ~720x404,
    2.39:1 ~720x302, 4:3 ~640x480, typically 24-30p); Chiaki sends fixed presets (640x360
    fits, 960x540 does not); YouTube's 480p is 854x480. (Survey from knowledge, not
    measured; GeForce NOW has no open client and is not assessed.) So the core must not
    be built around one service's shape -- **the target, service-neutral like H.264's
    levels:**
    - **frame size: any width x height up to 1,620 macroblocks** (Level 3.0's MaxFS, the
      bound `spec_hardening.md` already enforces; cropped sizes that are not multiples of
      16, any sample aspect ratio);
    - **decode rate: real time up to 97,200 macroblocks a second** = 854x480 (coded 864x480,
      1,620 macroblocks) at 60 frames/s -- which covers 640x480p60 (72,000), 720x480p60
      (81,000), 854x480p30, 640x360p60 and every 24-30p transcode. Measured in the cosim
      on the Sunshine-shaped proxies, less the rig's 4-7 %; the bitrate stays D1's (a
      session requesting 10 Mbit/s). **Decided 2026-09-28 (the maintainer): the gate is
      81,000 (720x480p60) now; 97,200 is the target of lever 4b (two samples a cycle out
      of `mc_interp`, `throughput.md`) and becomes the gate once 4b is measured;**
    - **display: every decoded picture fitted to the fixed output raster** (480i analog
      first, 480p / HDMI): aspect-corrected scaling in both axes and letterbox / pillarbox
      borders, for ANY aspect the bound admits -- portrait included (a phone / tablet cast;
      decided 2026-09-28, `analog.md` §1) -- display work that joins the analog raster
      ("Analog first" above);
    - a client describes the core to any server in these terms (Jellyfin / Plex device
      profiles, the size a Moonlight client requests, Chiaki's 360p), so nothing in the
      core is specific to one service.
  - ✅ **Widened 2026-10-02 (the maintainer: "let's work toward 720p30 playback"; Phase 5c
    below): Level 3.1's envelope, functional first.** The value is compatibility -- the 720p
    files people have, Jellyfin direct play without a transcode, a Moonlight session at 720p --
    not sharpness (every raster is still 720 wide):
    - **frame size: any picture up to 3,600 macroblocks** (Level 3.1's MaxFS: 1280x720, or any
      shape inside it up to 128 macroblocks a side) -- 2 MiB stores (`h264_recon.md` §2.2), the
      bound told to programs in interface 0.11's word 81;
    - **decode rate: designed for 108,000 macroblocks a second** (Level 3.1's MaxMBPS: 720p30,
      854x480p60); **real time promised** for game streams (854x480p60, 720p30 at a 10 Mbit/s
      request: ~1.2x estimated at 720p30, `mb_pipeline.md` §4g) and **720p24 films** at typical
      bitrates (x264 B-frames 4 Mbit/s: ~1.2x estimated; 8 Mbit/s of dense content ~1.03x --
      marginal); **x264 720p30 above ~4 Mbit/s decodes correctly
      and visibly behind** (late pictures counted) until the throughput branch (Phase 5c part 2);
      programs refuse a stream above 108,000 (720p60) by name;
    - **display: unchanged** -- every picture fitted to the 720-wide raster (a 1280-wide picture
      is decimated to a 640-sample line, then blended); a 1280x720 Native (HDMI) raster is
      Phase 5c part 3. The Jellyfin client asks for a 720p transcode only when the output shows
      it (Native (HDMI) on a core whose `cap_native_h` reaches 720: none yet).
    The 1,620 / 97,200 budget above is superseded by this (its text kept for the numbers).
    The original decision, kept for its numbers (superseded as the gate by the above):
  - **Throughput (2026-09-27): real time at 720x480p59.94, High profile, for a Moonlight session
    requesting 10 Mbit/s** (~7.3-7.7 Mbit/s at a stock Sunshine encoder) -- decided
    2026-09-27 by the maintainer from the quality comparison (`p1_measurements.md` §7: 3 →
    10 Mbit/s requested removes nearly all visible break-up on cuts and motion bursts; 10
    → 16 buys much less for 1.38x instead of ~1.18x decoder speed). **In numbers: ≤ ~935
    clk_dec cycles a macroblock in the cosim at 81 MHz** on the 8 Mbit/s windows (1,001
    real time, less the 4-7 % the rig ran slower than the DDR model in UMD), against 1,186
    measured on Main today: ~1.27x, before High profile's own cost. Found where Phase 1
    points: the inter-prediction floor first, then the CABAC front end (starving from ~8
    Mbit/s). **Above the target** (up to Level 3.1's 14 Mbit/s): every stream still decodes
    correctly; when the decoder falls behind real time it is VISIBLE -- a counter in the
    status block, and `frame_drop_ctl` (Phase 6) drops non-reference pictures rather than
    drifting -- never silent (CLAUDE.md "Design to the spec maximum").
- ✅ **D2 — where audio is decoded: DECIDED 2026-09-29 (the maintainer): on the ARM.** The
  program decodes audio (any codec its libraries support) and hands the core PCM through the
  ring; the fabric presents it against the STC. The reasoning: the program already does
  everything but video decode (networking, demux, decryption, FEC), the ARM decodes AAC /
  Opus in a few percent of one A9 core, and an in-fabric codec set would limit which codecs
  a program can play. No audio DSP; the fabric's audio is presentation only (P4). The
  alternative below is kept as history. -- PCM from the ARM is the floor (any codec, the ARM
  decodes AAC / Opus in a few percent of one A9 core). The UMD session proposed
  (2026-09-27, *nothing decided*): AAC-LC stereo and Opus CELT-only in fabric on a
  microcoded audio DSP derived from UMD's ATRAC3plus decoder (2,229 ALM standalone),
  with per-stream microcode and tables loaded from the ARM so M10K is the largest codec,
  not the sum; HE-AAC (SBR / PS) and SILK / hybrid Opus refused loudly; the transform
  size is the catch (AAC-LC's 1,024-point IMDCT is ~98 M MAC/s direct form: needs ~4
  multiplier lanes or an FFT IMDCT). Cycle counts from the microcode emulator come
  before any RTL. Video throughput stays the priority.
- ✅ **D3 — a developer input path: decided 2026-09-27 (the maintainer): no OSD file
  slot.** The ioctl stand-in is removed in Phase 3; the reference feeder (`hps/h264play`,
  run over ssh) is the developer input path.
- ✅ **D4 — interface transport details: decided 2026-09-27** (the maintainer on the ring
  size, DISCONTINUITY and telemetry; the rest as proposed): the control block at byte
  `0x3140_0000`, an **8 MB** ring at `0x3180_0000` (Level 3.1 High's 2.6 MB CPB and
  room), free-running indices, a session nonce the core acknowledges (and ignores at
  boot), polling (fast when caught up, slow always), **the status block as the
  telemetry** (every frame; no EXT_BUS, no HIL Main), **DISCONTINUITY = the full stream
  reset**, launch by MGL, an advisory lock for two programs. `docs/architecture.md` "The
  HPS interface, v0.1".
- **D6 — the program's own UI** (asked 2026-09-27, while planning Phase 3). A media-server
  client needs a browse screen; the core shows only decoded video. Candidates: MiSTer's
  HPS framebuffer overlay (`MISTER_FB` in `sys/`, the Linux framebuffer the menu core
  uses) or something drawn by the core. Not sized; not needed by a Moonlight client.
  **Direction taken 2026-09-29 (the maintainer): drawn by the core -- the overlay plane,
  Phase 6b.** `MISTER_FB` goes through ascal, so it reaches HDMI only and replaces the
  core's picture; the overlay is composited on the raster (HDMI and analog alike), over
  the video or over black -- a browse screen is the overlay with no stream playing.
- **D5 — the name.** "H264" chosen 2026-09-27; the UMD design chat had floated names for
  an "accelerator for HPS streaming apps" (Downlink, SetTop, Kinescope). **Decided 2026-10-06
  (the maintainer): "H264" is kept** -- a generic name for a generic accelerator, not tied to one
  service or program; the GitHub repository stays `MiSTer_h264_decoder`.

---

## Phase 0 — Scaffold ✅ MERGED (PR fj#1) · ✅ HW-CONFIRMED on HDMI (2026-09-27) · ⏳ analog

**Goal:** the core compiles, loads, shows its idle screen on HDMI and analog, and carries
every process and gate of UMD's. Nothing decodes; nothing is fed.

- [x] Framework (`sys/`) byte-for-byte from UMD `main` (2026-09-27), its forks kept:
      SDRAM removal, composite-sync ports, `hps_io` ini exports, audio fixes, `ram2` to the
      core, the `f2sdram_safe_terminator` burst fix.
- [x] `h264/emu.sv`: clocks (`sys_pll` 27/90/25/81), reset, CONF_STR v1 (`Aspect Ratio`,
      `Reset`), `hps_io` with no file slot, no startup OSD pop, the idle aspect, the
      registered output stage, both DDR3 ports idle, audio silent.
- [x] `h264/idle_bars.sv`: 75 % colour bars with a marker that moves every frame (a
      screenshot pair proves the core is running). UMD's PSP wave is not carried.
- [x] `h264/sync_gen.sv`, `h264/sys_pll.sv` verbatim; `h264/dec_stub.sv` keeps a register
      in clk_dec so the Fmax gate has a row.
- [x] Build gates from UMD `main`, renamed: `build_release.sh`, `fmax_check`,
      `lint_undriven`, `netlist_canary`, `seed_sweep`, `timing_paths`, `synth_unit`,
      `package_release`, `publish_draft`; `docs_check` (no buttons / extensions allowed);
      `check_emu_wiring` (UMD's sys_top / ram2 checks + this core's seams); the HIL harness
      cut to its stock-Main subset.
- [x] `bench/h264/run_scaffold.sh --red`: the raster measured, the bars scored on pixels
      (two configurations so a wrap is seen), the emu seams, the lint; 14 mutations each
      caught by its own arm.
- [x] Process: CLAUDE.md, README, NOTICE, the manual (MkDocs, stub pages), the skills
      (`release`, `hil-testing`, `docs-sweep`, `field-report`), `/merge`, CI templates.
- [x] First Quartus fit (2026-09-27): SEED 1 first roll, 6,779 ALM (16 %), 60 M10K, 33 DSP,
      clk_dec 297.62 / 291.89 MHz, every gate PASS, `H264_scaffold_20260927_1219.rbf`
      (`021682d`); ledgered in `H264.qsf` and `docs/history.md` §1.
- [x] HW gate, HDMI (2026-09-27, `H264_scaffold_20260927_1219.rbf`, rig idle on the menu
      core beforehand): deployed with `tools/mister.py`, `/tmp/CORENAME` read `H264`; two
      raw shots ~1.7 s apart both pixel-exact to the layout (bars sampled every 7th line,
      the band black but for one 32x32 white marker), the marker at x 4 then 400 (the
      core runs); `shot --scaled` 1920x1080 at Auto on the rig's 1080p mode (idle follows
      a widescreen display) and 1440x1080 with `Aspect Ratio=4:3`. `docs/history.md` §1.
- [ ] HW gate, analog: not exercised (a screenshot is the core's raster, upstream of
      both outputs; it needs a person at a CRT or a capture).
- [x] Merged (PR fj#1, 2026-09-27). **Next:** Phase 1, measure the gap.

## Phase 1 — Measure the gap (no RTL) ✅ MERGED (PR fj#2) · D1 decided (High; 10 Mbit/s requested)

**Goal:** the numbers D1 needs, measured, not extrapolated. Results and method:
`docs/p1_measurements.md`.

- [x] **What a stock Sunshine host sends** (2026-09-27, from the sources: Sunshine
      `66abe63`, moonlight-common-c `f900dd4`): **always High profile, the 8x8 transform on,
      no knob on either side turns it off**; CABAC; P only, refs 1 and no long-term refs
      unless the client declares RFI; slices as the client asks; CBR with a one-frame VBV;
      frame pictures, 8-bit 4:2:0. Measured on NVENC (RTX 4070): High sets
      `transform_8x8_mode_flag` 1.
- [x] **The forked decoder's cycles per macroblock at 480p60** (2026-09-27, UMD `75e3f37`'s
      cosim on local NVENC / x264 Main proxies, every window bit-exact): **1,033 cycles a
      macroblock at Moonlight's default** (3,000 kbit/s requested, ~2 Mbit/s at the
      encoder: 3 % short), 1,069 / 1,186 / 1,382 at 4 / 8 / 12 Mbit/s encoder targets
      (Sunshine-shaped NVENC), 1,298 (x264, 7 slices, 300 frames); real time needs 1,001 at
      81 MHz, and the rig ran 4-7 % slower than the DDR model in UMD.
      Inter prediction is a fixed ~560-650-cycle floor; the CABAC front end starts to
      starve the reconstruction above ~6-8 Mbit/s (`M_IDLE` 0 → 246).
- [x] **A capture from a real Sunshine host** (2026-09-27, stock Sunshine on the
      workstation, NVENC, a real Moonlight client with a dump sink:
      `tools/p1/capture_sunshine.sh`): **High, 8x8 transform on, used by ~3-4 % of coded
      macroblocks at every bitrate** (inter 8x8 transform 0.9-2.3 %, intra 8x8 1.6-2.4 %;
      no intra 4x4 at all), one IDR then P only, 1 slice, refs 2 / 1 active, a filler NAL
      after every picture. So stock hosts REQUIRE High profile in the fabric.
      `docs/p1_measurements.md` §2b.
- [x] **D1, profile: High in fabric** (2026-09-27, the maintainer: a stock server, no
      patched Sunshine).
- [x] **D1, throughput: real time at 10 Mbit/s requested** (2026-09-27, the maintainer;
      ≤ ~935 cycles a macroblock in the cosim, see D1 above). The throughput plan itself is
      Phase 5's first step, from a read of `recon_inter.sv` and `mb_syntax.sv` (the inter path first, then the front end, then
      clk_dec); the bitrate the client will request. Record it here and the maxima in
      `docs/spec_hardening.md` (Level 3.1; High's contexts: 460 for 4:2:0, Phase 5).
- [x] ~~If D2 is taken up: the audio DSP's cycle counts~~ -- D2 decided: audio decoded on the
      ARM (no audio DSP).

No hardware gate: Phase 1 changes no RTL.

- [x] Merged (PR fj#2, 2026-09-27). **Next:** Phase 2, harvest the decoder and the display
      path from UMD at or after its PR fj#17 (the ddr_mux2 orphan-grant fix), the commit
      recorded in `docs/harvest.md`.

## Phase 2 — Harvest the decoder and the display path (the fork) ✅ MERGED (PR fj#3)

**Goal:** UMD's decoder and display running in this core, bit-exact in simulation, with
no input yet (the ring is Phase 3). `docs/harvest.md` is the list. ✅ MERGED (PR fj#3,
2026-09-27), harvested from UMD `cc595c6` (its PR fj#17 merge: the ddr_mux2
orphan-grant fix is in the copy).

Decided with the maintainer at the start (2026-09-27):

- **The ES stand-in is `hps_io`'s ioctl download path, with no OSD slot.** With the
  decoder's input tied off, Quartus folds the whole decoder and the P2 fit would measure
  the scaffold again; ioctl bytes come from `HPS_BUS`, which it cannot fold, and nothing
  user-visible is added. D3 stays open (an `F0` slot in CONF_STR would make it a
  developer input path); Phase 3's ring reader replaces the stand-in.
- **The Deinterlace option (Weave / Bob / Blend) comes over now** with the display reader
  and its manual row: the decoder decodes field pictures, and a TV stream from a media
  server can carry them.
- **Telemetry only, at Phase 3; UMD's on-screen development HUD (`diag_hud`, `p2_diag`)
  is not carried.** There are no counters worth reading until the ring feeds the
  decoder.

- [x] `umd/h264/*` → `h264/dec/`; the display modules (`recon_out`, `ddr_mux2`,
      `disp_reader`, `disp_sched`, `disp_ctl`, `aspect_vui`, `cdc`, `sfifo`, `fifo_dc`,
      `vidfeed_cdc`) → `h264/`; `umd.sdc`'s decoder and display bounds → `h264/h264.sdc`
      (2026-09-27, UMD `cc595c6`; `se_cdc` not carried: nothing wires it).
- [x] Their benches, runners, goldens and the field table → `bench/h264/`, `tools/`,
      `tools/tests/`; the disc arms replaced by H.264.1 streams or dropped, never left to
      SKIP (three recon_ctl RED arms would have); `run_cosim.sh` on x264 720x480p59.94
      windows and two field streams (`docs/harvest.md` Phase 2). GREEN and `--red` ALL
      GREEN on every runner: see "Phase 2 gates" below.
- [x] `run_f2sdram_term.sh` for the inherited `sys/` fork: GREEN, 5 RED arms (K0 the
      stock terminator, kept as `bench/h264/f2sdram_term_stock.sv`).
- [x] UMD-specific inputs cut at the seam: the demux, the ISO reader, the vbuf, the HUD,
      the audio path are not carried. `au_pts` came over verbatim: its position rule is
      source-neutral (a PTS on an access unit's first byte is exactly what it expects);
      Phase 3 confirms it when D4 fixes the record.
- [x] `emu` wiring: the ioctl stand-in → `vidfeed_cdc` → `h264_top` → `recon_top` (DPB on
      ram1, `ddr_mux2` master A) → `recon_out` → `disp_ctl` → `disp_reader` (ram2); the
      output stage at the reader's LAT 4, the idle bars behind the picture; Auto aspect from
      the VUI, square pixels when unspecified; CONF_STR `O[4:3] Deinterlace`
      (`using/settings.md`). `check_emu_wiring.py` pins the seams; `run_scaffold.sh --red`
      38 mutations, W1-W28 each caught by its own named check.
- [x] UMD's four spec deviations re-decided with the maintainer (2026-09-27, all kept) and
      one added: pictures above 1,620 macroblocks refused (the 1 MB stores; Level 3.1's
      MaxFS is 3,600). `docs/spec_hardening.md`.
- [x] Fit (2026-09-27): SEED 1 first roll, 23,331 ALM (56 %), 230 M10K, 69 DSP, clk_dec
      91.43 / 88.67 MHz (gate 86), every gate PASS incl. the new canary on the ES crossing;
      `H264_p2harvest_20260927_1801.rbf`; ledgered in `H264.qsf`, `docs/history.md` §2.
- [x] No HW gate of its own: nothing feeds the decoder until Phase 3. Its gate is Phase 3's.
- [x] Merged (PR fj#3, 2026-09-27). **Next:** Phase 3, the HPS interface -- D4 (the ring's
      transport details) with the maintainer first.

**Known limitations (Phase 2):**

- The ioctl stand-in's skid lives in `emu.sv` with no emu-level bench: only
  `check_emu_wiring.py` pins it. Stock Main never downloads to this core, so it is never
  exercised; its job is to keep the decoder in the netlist. If D3 adopts the path, factor
  it into a module with a bench (UMD's `p3_chain_tb` is the shape) before it is relied on.
  Also: a download's start holds the stream in reset for 16 clk_sys cycles with
  `ioctl_wait` low, so a byte arriving in that window would be lost (UMD's mount had a whole
  image walk before its first byte; Main's file read may not) -- hold `ioctl_wait` through
  the clear if D3 adopts the path.
- The SDC's `cdc_snap` bounds and `disp_reader`'s `fetch_changes` / `fc_*` targets match
  nothing in this build (TimeQuest warns: no `cdc_snap` until Phase 3's telemetry;
  `fetch_changes` unconnected and pruned). Every other bound matched.
- The decoder's refusal and error counters (`REF_SIZE`, the POC type 1 cache, `ref_size`,
  ...) are counted in the RTL but left unconnected in `emu`: nothing reads them until
  Phase 3's telemetry (`spec_hardening.md`'s visibility caveat).
- The front end runs 0.148 bins/cycle on `camp_mot_fld0_full`'s B field slice (gated at
  0.14 there): Phase 5's throughput work owns it.
- `run_cosim.sh`'s "x real time" is meaningful only for streams with timing or at 59.94
  (the x264 windows); for the conformance packages it is a number, not a verdict.

**Phase 2 gates** (2026-09-27, `$H264_REFS_DIR` set; mutations caught / total):
h264_cabac 11/11, mb_syntax 12/12, h264_top 34/34, recon_ctl 7/7, mb_intake 10/10,
dequant_itrans 11/11, intra_pred 13/13, mc 15/15, deblock 19/19, mv_pred 21/21, dsf_calc
5/5, dpb_mem 7/7, recon_out 7/7, disp_reader 27/27, aspect_vui 5/5, f2sdram_term 5/5,
scaffold 38/38, tools/tests 15/15, recon_top 32/32, disp_sched 14/14, cosim 8/8 (C4 on
an I_PCM window -- the x264 one carries no EPB in slice data -- caught by its zero-output
signature, `[out] 0 stores emitted`). Cosim GREEN, bit-exact:
x264_sun (Sunshine-shaped, 8 Mbit/s) **1,237 clk_dec cycles a macroblock**, x264_film
1,173, `cabac_mot_fld0_full` 1,519, `CAPA1_TOSHIBA_B` 2,236 -- the Sunshine number in line
with Phase 1's 1,186 on NVENC at 8 Mbit/s: the Phase 5 gap is unchanged. `run_cosim.sh --sweep` over
every H.264.1 AVCv1 CABAC package (120 frames each): **32 PASS bit-exact, 0 FAIL, 0
ORACLE, 25 REFUSED by scope** (MBAFF, CAVLC) -- UMD's P5 closeout sweep's counterpart.

## Phase 3 — The HPS interface and the reference feeder ✅ MERGED (PR fj#4) · ✅ HW-CONFIRMED on HDMI (2026-09-27)

**Goal:** a program on the ARM plays an H.264 stream on HDMI through the published
interface. First pictures on the rig. The decoder is still Main profile (Phase 5 brings
High), so the gates use x264 Main clips; a live Sunshine stream is refused loudly
(`REF_T8X8`, visible in the status block from this phase).

Decided with the maintainer at the start (2026-09-27): D3 and D4 above; DISCONTINUITY is
the full per-stream reset, and after the first stream the screen shows black, not the
bars, between streams; the status block is the telemetry.

- [x] **P3a** the interface written down first: `docs/architecture.md` "The HPS
      interface, v0.1"; `tools/ring_layout.py` (one table -> the RTL's constants and
      status muxes, the C header; `--check`); `tools/ring_model.py` (the producer and the
      reference consumer, from the architecture text; the bench scenarios R1-R19);
      `tools/tests/test_ring_model.py` + 5 RED arms.
- [x] **P3b** the ring reader (`h264/ring_rd.sv`: the clk_mem engine and the clk_sys
      parser, UMD's `vbuf.sv` shape) -- `run_ring_rd.sh --red`: 20 scenarios GREEN
      against `tools/ring_model.py`, 29 mutations each caught by its own arm (the RED run
      found four blind spots in the first bench: the slow poll's promptness, burst-aligned
      wraps, a withdrawal at master B the port model cannot see, parse errors masked by a
      flow-control hang -- each closed by a check of its own).
- [x] **P3c** the status block (`h264/ring_stat.sv`, `cdc_snap_ix`, `ddr_probe`): R18 and the
      status arms of `run_ring_rd.sh`.
- [x] **P3d** `recon_dpb` honours `max_num_reorder_frames` (E.2.1; 0 inferred for POC
      type 2): a stock Sunshine SPS says 0 reorder, 2 buffers, and the decoder holds each
      picture ~2 frames before. Model and RTL (`nrf_late` counts a stream past its own
      limit); `run_recon_top.sh` ALL GREEN (the [out] arm scores WHEN each store leaves), the
      ring cosim on x264_sun (POC type 2), C11 RED. **The RED run found the cost:** the
      early output made the spec's bumping path DORMANT on the x264 fixtures (x264 always
      writes `bitstream_restriction`; P-only x264 is POC type 2), so four output-process arms
      (O2 the VUI's DPB size, O3 MaxDpbFrames, O5 MMCO 5's flush, O10 a waiting store kept
      busy) survived. Two fixtures keep the path alive: `c44mb` (B frames, POC type 0, no
      VUI, MMCO 5) and `c44d` (`h264_synth.py dpb3`: max_num_reorder_frames =
      max_dec_frame_buffering = 3, so the DPB size alone decides; at 4 the limit fires
      exactly when the bump would -- an equivalent mutant, found on the model). The cosim's
      C8 (the same mutation) and C6 (a DPB write with reads outstanding, now held by
      `ddr_mux2` in front of the DPB) are retired, each covered by its unit bench. The same run showed
      `run_disp_sched.sh`'s D17 vacuous on llsteady (on-time pictures are due by their PTS
      anyway): `llearly` (3 refreshes ahead) is its arm now.
- ⛔ **[deferred to Phase 5 -- decided 2026-09-27 while building P3]** **P3e** `au_end`: a
      record's end would close the picture at once, not when the next access unit's start
      code arrives (one frame of latency). It touches `nal_parser`, `h264_top`,
      `vidfeed_cdc`'s width, `recon_dpb` and two models, and its benefit cannot be measured
      on the rig until Phase 5 makes 480p60 real time (the latency case is Moonlight,
      which needs Phase 5's High profile anyway). The reader already carries `es_au_end`
      (unconnected in `emu`), and the interface's one-access-unit-per-record rule is
      normative, so it needs no interface change.
- [x] **P3f** LOW_LATENCY in the display: due at every pickup, the newest picture shown,
      skips counted; the STC still anchors (Phase 4's audio clock). `recon_out`'s
      `rec_more` never counts the END (the END is pushed 8 cycles behind a flag that
      crosses first), so a stream's last picture is always shown. `run_disp_sched.sh`
      llsteady / llburst / llend, D15-D17; on the rig: 290 skipped of 600 when the decoder
      outruns the raster, 1 in 600 at 60.00 frames/s (`history.md` §3).
- [x] **P3g** `hps/`: the client library (a backend: /dev/mem, a buffer, the cosim),
      `h264play`, `h264stat`, `h264ring_split_annexb` (== ffprobe's split), the host tests
      (`test_ring` against a fake core; the bytes through `ring_model`'s consumer) with 8
      RED arms, the ARM build in Docker (gcc-arm 10.2, static, no VFPv4).
- [x] **P3h** the cosim in ring mode (`run_cosim.sh`: `x264_sun_ring`, `+ring`): the library
      as the producer, `ring_rd` beside the DPB on `ddr_mux2`, every picture PTS-tagged,
      bit-exact; **1,243 clk_dec cycles a macroblock through the ring, the same as fed
      directly** (the ring's reads and polls cost nothing measurable under the DDR model);
      C9-C11 RED on it. (Descoped: the splice and EOS-then-DISCONTINUITY windows -- the
      reader's bench covers them byte-exact and the rig ran both.)
- [x] **P3i** emu: the stand-in removed, the ring reader on `ddr_mux2` B, every counter
      connected, black between streams; `check_emu_wiring.py` and `run_scaffold.sh --red`
      (47 arms, W29-W37 new).
- [x] **P3j** the fit, the ledger, the docs and the manual. Final fit: SEED 1, clk_dec 88.21 /
      88.24 MHz, ALM 26,112 (62 %), M10K 235, DSP 71, `H264_p3ring_20260927_2129.rbf`
      (P3i's: 87.94 / 87.19, 25,965). The manual's integrating pages (the interface v0.1,
      the library, launch and input); `hps/` under MIT (decided 2026-09-27, the maintainer).
- [x] **P3k** HW gate: `h264play` plays an x264 Main 480p60 clip and a 480p30 film clip on
      the rig; errors 0; the judder pair equal; a switch mid-play and EOS-then-a-new-stream
      recover; low latency plays with skips counted; a restarted feeder recovers; ten core
      reloads while playing leave no port hang. **First round done on the P3i build
      (2026-09-27, `history.md` §3):** first pictures; the film clip ENDED 240 / 240, judder
      equal, errors 0; the switch; the lock; a restarted feeder; ten reloads mid-stream;
      the PTS path (600 / 600 tagged); EOS then a new stream (`--loop 2`); 480p60 measured
      at ~59.6k MB/s = 44 frames/s (Phase 5's gap, counted as late / starved). **Low
      latency on the final build** (the same day): 290 of 600 skipped when the decoder
      outruns the raster, 1 of 600 at 60.00 frames/s, errors 0; the film regression clean.
**Phase 3 gates** (2026-09-27, the final RTL, `$H264_REFS_DIR` set): every runner GREEN
and `--red` ALL GREEN -- ring_rd 20 scenarios / 29 mutations, scaffold 47, recon_top (with
c44mb / c44d) all O / R arms, disp_sched 19 scenarios / 17, cosim C1-C5 C7 C9-C11 (C6 / C8
retired, reasons in the runner), tools/tests 29 (the layout, the model, `hps/` incl. the
flush), recon_ctl / recon_out / h264_top GREEN. Cosim: x264_sun 1,237 cycles a macroblock,
**x264_sun_ring 1,238** (the ring's reads and polls: < 0.1 %); `--sweep` over every H.264.1
CABAC package: **32 PASS bit-exact, 0 FAIL, 0 ORACLE, 25 REFUSED** -- Phase 2's result, with
the early output in.

- [x] Merged (PR fj#4, 2026-09-27). **Next:** Phase 4 (audio, and the out-of-band pause)
      or Phase 5 (High profile and throughput -- what a stock Moonlight session needs):
      the maintainer's call.
- ⛔ **[superseded — D4: the status block is the telemetry]** HIL: bring back UMD's
      telemetry and HIL Main (`docs/hil_harness.md`) once there are counters to read.

## Phase 4 — Audio ✅ MERGED (PR fj#12) · ✅ HW-CONFIRMED (2026-09-29; the capture chain's absolute A/V calibration deferred)

**Designed 2026-09-29, settled 2026-09-29** (D2 and the choices confirmed by the maintainer:
PCM 48 kHz s16 stereo from the ARM; presented against the STC -- DVD's clk_sys tick and gate
at the FIFO's exit -- with low latency's drift absorbed by counted single-sample slips; the
pause and volume word in this phase; **the audio buffer is the ring itself**, the published
read index held behind the oldest unplayed record -- the maintainer's decision after the
harvest showed DVD's DDR3 audio path had been retired): `architecture.md` "Audio (Phase 4)".
Interface 0.5. Merged as PR fj#12 (`feature/p4-audio`). The proving ground: a moonlight-embedded port.

- [x] **Interface 0.5**: AUDIO accepted (`HDR_LENGTH` for 0 or not a multiple of 4), word 34
      (pause, attenuation; range-checked), word 5 the released index, words 40-47 (the
      audio's status, a fifth burst); `ring_layout.py`, `ring_model.py`, the manual's
      `integrating/` pages, the library.
- [x] The reader: audio descriptors from the parser, the audio fetch and the released index in
      the engine, the ring not fetched while paused.
- [x] `aud_play.sv`: the descriptor FIFO, the fetch, the gate (paced / low latency), the
      48 kHz tick, the attenuation, the audio anchor, the counters; `AUDIO_L/R` in `emu`.
- [x] `disp_sched` / `disp_ctl`: the audio anchor, the pause (STC frozen, the picture held);
      with it UMD P6b3i's `disp_frz` (a paused display's holds are no decode error).
- [x] Benches GREEN and `--red` (`run_aud_play.sh`, `run_ring_rd.sh`, `run_disp_anc.sh`,
      `run_recon_top.sh` r16f, `run_scaffold.sh` W56); fit SEED 7, clk_dec 102.80 / 102.07.
- [x] `hps/`: writing AUDIO records, the pause / volume word, `h264play` with a PCM file,
      `h264stat`'s audio fields.
- [x] On the rig (`history.md` §11): every record at its PTS by the core's counters; the
      capture moves with the timestamps (+50 ms -> +41, inside the card's wander); pause (3 s
      exact, no decode error), volume (-6.00 dB), audio only (the audio anchor), low latency.
- [x] **The A/V evidence for Phase 4 (decided with the maintainer 2026-09-29):** the relative
      result -- the core's counters put every record at its PTS, and the capture moves with the
      timestamps. The absolute calibration of the capture chain (~-100 ms, audio first) is
      DEFERRED: a PC cannot calibrate the Hagibis (it declares no audio in its EDID, so a
      GPU sends none; `history.md` §11). Later: a source that sends HDMI audio regardless of
      EDID (a console, a streaming stick, another MiSTer) into the card, and a judgement by eye
      and ear on a TV. If the ~-100 ms is the MiSTer's scaler, the remedy is a program's
      timestamps, not the core.
- [x] Before merge: `run_cosim.sh` ALL GREEN (six windows bit-exact; through the ring 970
      cycles a macroblock vs 968 fed directly: the audio costs the decoder nothing measurable),
      `run_disp_sched.sh` ALL GREEN (30 scenarios, progressive and 480i), `run_recon_top.sh
      --red` with the conformance set, `docs-sweep` (the integrators' overview, the landing page).
- [x] ✅ **MERGED (PR fj#13), ✅ HW-CONFIRMED (2026-09-30), watch only.** The proving ground: a moonlight-embedded port (Opus on the ARM, LOW_LATENCY) --
      **designed 2026-09-29** with the maintainer (`moonlight.md`: in-repo `clients/moonlight/`,
      a Scripts-menu launcher + ini, 720x480p60 at 10 Mbit/s requested, a fully static binary);
      branch `feature/moonlight`. The static client builds; **first live sessions on the rig
      2026-09-29** (view-only: 3 min of 720x480p60, 0 errors, 0 skips, audio 2 underruns / 4
      slips, the client ~10 % of one ARM core; `history.md` §12); the launcher, the host test
      (13 of 13 `--red`), the automatic size, the way out. **Main grabs every input device**:
      this branch merges **view-only** (M6); input goes through the core on its own branch
      (M5, below). ✅ HW-CONFIRMED 2026-09-30 on the shipped fit (SEED 7, clk_dec 108.12 /
      104.32): the maintainer ran it from the Scripts menu (`history.md` §12).
- [x] ✅ **MERGED (PR fj#14), ✅ HW-CONFIRMED (2026-09-30). Moonlight input through the core** (decided 2026-09-29, `moonlight.md` M5): hps_io's
      pads, keyboard and mouse mirrored into the control block (interface 0.6, `CONF_STR`'s `J`
      line), the client forwarding them, the release on the OSD's opening. Branch
      `feature/moonlight-input`. **Designed with the maintainer 2026-09-29** (`moonlight.md` §7
      M7-M10: written on change at most every 1 ms; a 16-bit pad, no Guide; rumble later; F12
      Main's; `architecture.md` "Input (interface 0.6)": words 48-71, one ordered event queue,
      the mouse as sums). **Built**: `h264/ring_in.sv`, `ring_stat`'s second job, the library's
      `h264ring_input`, `h264stat --input`, the client's `mister_input.c` + patch 0004;
      `run_ring_in.sh --red` 14/14, `run_ring_rd.sh` GREEN, `run_scaffold.sh --red` GREEN, the
      client's host test `--red` (13 input mutations). Fit SEED 7 first roll, clk_dec 104.07 /
      104.08, ALM 32,528 (`H264_mlinput_20260930_0429.rbf`); **on the rig, scripted through
      Main: keys, the OSD's edges and the mouse exactly as designed** (`history.md` §13).
      **✅ HW-CONFIRMED 2026-09-30 with the maintainer**: keys typed into
      the PC, the mouse, an Xbox pad (every button, the sticks' directions) seen as an Xbox pad
      on the PC, the release on the OSD's opening, both quit combos (`history.md` §13).
- [x] ✅ **MERGED (PR fj#16). Reaching the program from the pad** (decided 2026-09-30, `moonlight.md` M11 / M12): two OSD
      actions mirrored as input events (interface 0.8: "Send Home to the program" -> the host's
      Guide, "Program menu" reserved for the client's menu) and a client chord (Back + Start held
      1 s -> Guide). Branch `feature/pad-home` (`dev-padhome`): built; `run_ring_in.sh --red`,
      `run_osd_req.sh --red`, the client's host test `--red` (T10 / T11); fit SEED 7 first roll,
      clk_dec 109.59 / 108.46, ALM 32,527 (`H264_padhome_20260930_1641.rbf`); on the rig, scripted through Main: both actions queued before
      the OSD's closing; **✅ HW-CONFIRMED 2026-09-30 with the maintainer**: Send Home and the
      chord opened the host's Guide, Program menu did nothing, the quit combo held (`history.md`
      §15).
- [x] ✅ **MERGED (PR fj#31), HW-CONFIRMED 2026-10-04 with the maintainer (a game through the Moonlight client: "rumble works and feels good"; the keepalive's 10 s step not yet exercised by a sustained rumble). Rumble through the core** (asked 2026-10-04, the maintainer: "Add rumble support for
      moonlight"; `moonlight.md` M9, `architecture.md` "Rumble (interface 0.13)"): program words
      36-38 -> `hps_io`'s `joystick_N_rumble` during a session (Main plays it on the user's pad),
      core words 82-83 the rumble applied; **the keepalive in the program** (decided 2026-10-04:
      Main's 32.767 s length is a dead program's stop); the library's `h264ring_rumble` /
      `_keepalive`; the client's callback (patch 0005) and its 1 ms timer. Branch
      `feature/rumble` (`dev-rumble`). Built: `run_ring_rd.sh` R27 + U1-U6, `run_scaffold.sh`
      W93-W95, the library's checks + six `red_h264.py` arms, the client's T12 + seven arms;
      `h264play --rumble`. Fit SEED 3 first roll, clk_dec 104.11 / 104.8, ALM 36,988 (88 %),
      `H264_rumble_20261004_2256.rbf`; on the rig the core's side as designed (`history.md` §32).
      On .201 with the 0.13 clients: ✅ HW-CONFIRMED 2026-10-04 with the maintainer (a game through the Moonlight client: "rumble works and feels good"; the keepalive's 10 s step not yet exercised by a sustained rumble) (`history.md` §32).
- [x] ✅ **MERGED (PR fj#15). UMD's lone-PTS rules A and B ported** (UMD PR fj#25 + fj#26; `display.md` §10): a lone PTS
      off the timeline by more than half a refresh and at most 0.5 s is disbelieved, the next tag
      always believed; `disp_lone` in the status block (interface 0.7). Branch `fix/lone-pts`.
      `run_disp_sched.sh --red` ALL GREEN (37 scenarios x 2 rasters; 32 mutations each caught by
      its own arm, D18-D26 the rule's); fit SEED 7 105.49 / 106.0
      (`H264_lonepts_20260930_1453.rbf`); on the rig a playback smoke test: version 7, clean
      streams untouched (`disp_lone` 0, errors 0; `history.md` §14).
- [x] D2 decided 2026-09-29: **audio is decoded on the ARM**; the core presents PCM (no audio
      DSP, no in-fabric codecs).
- [x] **Pause, out of band** designed (decided 2026-09-27 after the P3 HW round: a pause
      record would queue behind seconds of video): word 34, in this phase (above).

## Phase 5 — Throughput and profile (D1's answer)

- [x] ✅ **High profile (D1, required) -- MERGED (PR fj#5), ✅ HW-CONFIRMED (2026-09-28)**
      (`high_profile.md`): the 8x8
      transform and its dequantisation, intra 8x8 prediction with its reference sample
      filtering, the 8x8 CABAC contexts (399..459; the "1,024" was 4:4:4's count), the High
      SPS / PPS syntax and scaling matrices (every set stored as coded: the spec maximum);
      conformance from the H.264.1 FRExt (High) package, and the real Sunshine captures
      (`tools/p1/`) bit-exact.
  - [x] The models (`h264_fe_ref`, `h264_recon_ref`, `h264_trace_ref`): identical to JM's
        trace and to ffmpeg / the package YUVs on 13 x264 High clips and every CABAC 4:2:0
        8-bit FRExt stream.
  - [x] The front end (`sps_pps` store + resolver, `mb_syntax` 8x8 syntax):
        `run_h264_top.sh` / `run_mb_syntax.sh` word-exact on x264 High and FRExt, RED.
  - [x] The units: `dequant_itrans` (weights), `dequant_itrans8` (new), `intra_pred`
        (Intra_8x8): `run_dequant_itrans.sh`, `run_intra_pred.sh`, RED.
  - [x] The reconstruction (`mb_intake`, `recon_hdr`, `recon_mb`, `recon_deblock`):
        `run_mb_intake.sh`, `run_recon_top.sh` (five x264 High clips, six FRExt CIF
        streams, H1-H17), RED.
  - [x] The Sunshine captures in the cosim (bit-exact, 986 cycles a macroblock at 10
        Mbit/s); the fit (SEED 1, clk_dec 87.60 / 87.37, 27,318 ALM, 315 M10K,
        `H264_p5high_20260928_0459.rbf`); ✅ HW-CONFIRMED: the 10 and 3 Mbit/s captures
        through `h264play` on the rig, every picture, errors 0 (`history.md` §4).
  - [x] Monochrome (`chroma_format_idc` 0, legal in High): refused by name -- decided
        2026-09-28 with the maintainer (`spec_hardening.md`, `high_profile.md` §7).
- [x] ✅ **Throughput (D1) -- met with ~40 % to spare (part 3, PR fj#22).** **Part 1 ✅ MERGED (PR fj#6), ✅ HW-CONFIRMED 2026-09-28** -- the
      81,000 macroblocks/s gate (720x480p60) met (`throughput.md`): clk_dec 96.43
      MHz (fit 104.69 / 101.46), the deblock pre-pass, the residual overlap, the streaming
      start -- `sun_high_8M` 1,084 cycles a macroblock in the cosim (1.09x), on the rig 300
      / 300 per loop, late 0, starved 0, errors 0, ~1.04x (`history.md` §5). A live
      session waits for a Moonlight client on the ARM (none exists yet: the captures stand
      in). **Part 2 ✅ MERGED (PR fj#7), ✅ HW-CONFIRMED 2026-09-28:** two interpolation
      lanes, the fetch run-ahead, the writeback's row setup overlapped -- 968 cycles a
      macroblock in the cosim; on the rig 854x480p60 at 8 Mbit/s real time (97,200
      macroblocks/s, ~1 % to spare; `history.md` §6). The last levers (four lanes, the
      residual engine, the CABAC front end) wait behind the display work (the maintainer).
      **The headroom clock ✅ MERGED (PR fj#17), ✅ HW-CONFIRMED** (`throughput.md` §7): clk_dec 96.43 ->
      **103.85 MHz** (VCO 1,350 / 13), four retime rounds and a seed sweep (SEED 9: 111.77 /
      110.41 at the 108.8 gate); on the rig 854x480p60 at 8 Mbit/s **~6 % to spare** (was ~1 %;
      `history.md` §16) -- **superseded by part 3**, which returns clk_dec to 96.43 (below). Next by the maintainer's order (2026-09-30): Phase 6b's overlay (the
      last large logic addition), then read the area left before the four lanes. **The area left
      after the overlay** (PR fj#21, SEED 7): ALM 33,501 / 41,910 (80 %: 8,409 left),
      RAM blocks 355 / 553, **DSP 103 / 112 (9 left)** -- the DSPs bind first for more lanes.
- [ ] `dec_stub`'s reset released through a `cdc_reset` into clk_dec, and a recovery check beside
      `fmax_check.sh`'s setup gate (negative recovery into clk_dec on every build since at least
      pad-home, cosmetic: the LED heartbeat; `throughput.md` §7). With the next branch that fits.
- [x] ✅ **Throughput part 3: the macroblock pipeline -- MERGED (PR fj#22), ✅ HW-CONFIRMED (2026-10-01)** (`dev-mbpipe`;
      `docs/mb_pipeline.md`). Started 2026-09-30 as an experiment, made a branch by the maintainer the
      same day: the writeback streamed (+ `dpb_mem`'s write skid), two front stages (A predicts
      macroblock k + 1 while B reconstructs k), `mb_syntax`'s emission queue, the back engine split
      (deblock + writeback, five sample banks), `dequant_itrans`'s two work buffers. Cosim, bit-exact:
      `sun_high_8M` 985 -> 711 cycles a macroblock at 103.85 MHz (1.29x -> 1.79x), 687 at 96.43
      (1.72x); x264 medium 480p 4 Mbit/s (B-frames) 1,101 -> 803; 720p30 1.10-1.30x with the
      simulation-only `H264_BIG_STORES` (720p itself is a separate decision: the store layout, the
      1,620-macroblock bound -- taken 2026-10-02, Phase 5c; the define retired there). Cost +1,400 ALM, +23 M10K, 0 DSP. **It carries the fixes for fj#18** (the
      explicit-weight default overflowing at denom 7: x264 medium decodes wrong chroma) **and fj#19**
      (below) -- the maintainer, 2026-09-30: main need not be stable before release, no separate fix
      branches. Rebased on main + the overlay; the suites and a code review done (`mb_pipeline.md`
      §5b); fit SEED 5 from a sweep, 109.06 / 108.18 (MARGINAL by 0.6 MHz cold), 34,943 ALM (83 %).
      **On the rig 2026-10-01** (`history.md` §18): 854x480p60 8 Mbit/s **1.06x -> 1.51x** real time,
      720x480p60 1.22x -> 1.68x, x264 medium B-frames 1.03x -> 1.34x; every picture, errors 0.
      A retime round (`top7`) and an 11-seed sweep: best SEED 10 106.97 / 107.56, none closes
      108.8 (what recurs is `deblock_filter`, untouched: placement at 83 % ALM;
      `mb_pipeline.md` §6). **The maintainer's call: clk_dec back to 96.43 MHz** (gate 101.4;
      `mb_pipeline.md` §4f): SEED 6 105.71 / 103.22, PASS, 35,112 ALM (84 %); on the rig
      854x480p60 8 Mbit/s **1.43x**, 720x480p60 1.60x, x264 B-frames 1.29x, errors 0
      (`history.md` §19). Merged 2026-10-01 at the maintainer's word. Next (`mb_pipeline.md` §6): what
      binds after it (the residual engine's 8x8 unit, the B-frame fetch's DDR3 latency); 720p24 is
      a separate D1-scope decision (the stores, the 1,620-macroblock bound, the display) -- taken
      2026-10-02: Phase 5c.
- [x] ✅ **Fixed by PR fj#22 (`wr_drained`), fj#19 closed.** **A picture is "done" when its writes are issued, not landed** (fj#19; found 2026-09-30 by the
      maintainer's `exp/mb-pipeline` experiment; carried by `feature/mb-pipeline`): `recon_top`'s
      `pipe_idle` releases a picture to the display once every write command is issued, while
      writes can still sit in `dpb_mem`'s clock-crossing FIFOs; the display reads it through
      ram2, with no ordering against ram1. Unreachable today (the writeback is slow and the display
      picks up at a refresh boundary); a faster writeback exposes it (`recon_top_tb` [hold] did on
      the experiment). The fix there: `dpb_mem.wr_drained` (write bursts taken vs completed, the
      count crossing back as gray), `pipe_idle` waiting on it -- `c6996c5` on `exp/mb-pipeline`.
      **Take it before any throughput work that speeds up the writeback** (the four lanes
      included). Its companion, `dpb_mem`'s write-beat skid (`c40522c`, ~3.5 mclk a beat
      today), is a throughput lever for the same time.

## Phase 5c — 720p (asked 2026-10-02, the maintainer: "let's work toward 720p30 playback")

D1 widened to Level 3.1's MaxFS (above, D1 "Widened 2026-10-02"). Planned as three branches,
each its own plan; decided with the maintainer the same day: functional first; a capability word
(interface 0.11) so programs stop hard-coding the bound; the Jellyfin client asks for a 720p
transcode only where the output shows it; the HD raster after the throughput.

- [x] ✅ **MERGED (PR fj#28), ✅ HW-CONFIRMED (2026-10-04: `history.md` §30 / §31). Part 1 -- functional 720p (`dev-720p`).** 2 MiB stores at `0x3200_0000`
      (above the ring: the control block and the ring unmoved), `recon_top`'s bound 3,600 (Level
      3.1's MaxFS: `spec_hardening.md`'s picture-size row closed), the simulation-only
      `H264_BIG_STORES` retired; **interface 0.11**: word 81, `cap_max_mbs` 3,600 /
      `cap_mb_rate` 108,000 / `cap_native_h` 480, `h264ring_caps()` (`architecture.md` "The
      capabilities (interface 0.11)"); the clients read it -- `h264check` (the shared check) also
      refuses a stream above the rate (a 720p60 file: "too fast"), the Moonlight backend refuses
      above it (was a warning), the Jellyfin profile direct-plays 720p at <= 30 frames/s (bands
      keyed on the width, the rate keying the band above 30 frames/s so a 60 frames/s source's
      transcode keeps its rate) and switches its transcode box to 1280x720 only on Native (HDMI)
      with `cap_native_h` >= 720. Benches: `run_disp_reader.sh` four 1280x720 fit arms from a
      3,600-macroblock store (H1 / H2), `run_recon_top.sh` a 720p I / P / B clip and a refused
      1344x720 one (S1-S5), the cosim's DDR window 128 MB with the DPB above the ring; the library,
      Moonlight, player and Jellyfin host tests with 0.11 arms; the cosim on the 720p proxies, every
      picture bit-exact (`mb_pipeline.md` §4g: NVENC 720p30 1.25x, x264 720p24 4M 1.42x / 8M 1.21x,
      x264 720p30 4M 1.20x / 8M 1.04x -- the rig ~0.85x of that on B-frames). **A defect found and fixed** (older
      than the branch): a picture over the bound was opened in a store before its slices were
      refused, and the unwritten store was emitted to the display -- now refused before
      `recon_dpb` sees it (`h264_recon.md` §2.2, S6). Fit SEED 6 105.62 / 101.4 PASS, 36,109 ALM
      (`H264_720p_20261002_2329.rbf`). **On the rig** (`history.md` §27): NVENC 720p30 10 Mbit/s
      1.16x, x264 720p24 4M 1.29x / 8M 1.12x, x264 720p30 4M 1.12x / 8M ~1.00x (at the limit), every
      picture, errors / late 0; word 81 read; Native falls back for 1280 wide; the file player plays
      720p24 / 30 files and refuses 720p60 ("too fast") and 1080p by name. Moonlight at 1280x720p30 and
      Jellyfin direct play of a 720p file with the maintainer (§30); the RetroTINK at 480i: 720p letterboxed,
      sync locked, 1.13x (§31). A CRT at 480i not separately (the RetroTINK's chain is the same signal).
- [x] ✅ **MERGED (PR fj#29), ✅ HW-CONFIRMED (the rig's throughput, `history.md` §28). Part 2 -- throughput for x264 720p30 at 8 Mbit/s** (`mb_pipeline.md` §6's levers: the
      residual engine's 8x8 unit overlapped, a deeper A/B hand-off on B-frame content, the B-frame
      reference fetch's DDR3 latency -- the rig ~16 % under the cosim on x264 -- and 103.85 MHz
      again if area is recovered). 86 % ALM, 92 % DSP.
      **Profiled 2026-10-02** (`mb_pipeline.md` §4h): on x264 720p30 8 Mbit/s the two front stages
      each wait ~276 cycles a macroblock on the other -- a two-entry A -> B queue first (up to
      ~1.47x decoupled), then the 8x8 residual overlap; at 12 Mbit/s 480p60 the CABAC front end
      begins to bind (a deeper front-end queue, then the bin rate) -- the higher-bitrate path.
      **The order, decided 2026-10-02 (the maintainer):** (1) a two-entry A -> B hand-off queue,
      (2) the 8x8 residual overlap, (3) a deeper front-end -> A queue then a faster bin decode
      (the higher-bitrate path: the 480p ceiling past ~12 Mbit/s, toward Level 3.1's 17.5), (4) the
      clock (103.85) last. Each measured in the cosim before a fit.
      **Step 1 measured 2026-10-03 (`feature/ab-queue`, `mb_pipeline.md` §4i): the two-entry
      queue buys 2.6 % (856 -> 834 on x264 720p30 8 Mbit/s; 687 -> 673 on `sun_high_8M`) for
      +622 ALM** -- the stages' imbalance is per picture type, not per macroblock (B pictures
      bound by the interpolation, P by the residual engine, I by the bins). **Parked (the
      maintainer, 2026-10-03)**: the residual overlap next (step 2, `feature/res-overlap`),
      then the interpolation's throughput as a new lever (B pictures), then the bins.
      **Step 2 built 2026-10-03 (`feature/res-overlap`, `mb_pipeline.md` §4j, not fitted):**
      `dequant_itrans8` a four-stage pipeline over blocks (~285 -> 80 cycles a block); x264
      720p30 8 Mbit/s 856 -> 817 (1.09x cosim), 720p24 8 Mbit/s 925 -> 875 (~1.09x on the rig,
      est.), every picture bit-exact, +331 ALM; every runner GREEN and `--red`. Stage B (intra
      prediction ~360, the residual adds ~130 a macroblock) now binds P pictures -- a lever not
      in the order. **Then the interpolation (2026-10-03, §4k):** the window rectangle narrowed
      to what each position class reads, the items overlapped (two parameter sets in
      `mc_interp`, per-lane writers), the next item's weights read ahead: cosim 817 -> 755, +200
      ALM. **Fit** SEED 6 104.32 / 102.05 PASS, 36,709 ALM (88 %); **on the rig (`history.md`
      §28): x264 720p30 8 Mbit/s ~1.00x -> 1.13x**, 720p24 8 Mbit/s 1.27x, NVENC 720p30 1.29x,
      854x480p60 1.57x, every picture, errors 0 -- part 2's goal met. Next (the maintainer's
      call): merge; the intra rewrite (P pictures, ~+300-500 ALM) or a cross-macroblock fetch
      (B pictures) only if more is wanted.
- [x] ✅ **Part 3 -- the HD raster -- MERGED (PR fj#30), ✅ HW-CONFIRMED (2026-10-04)**: a 1280x720 Native (HDMI) raster -- a video clock and CE
      scheme (27 MHz holds 450,450 dots a frame, under 921,600 active pixels), a luma slot and
      column index 1,280 wide (`disp_reader`'s 1,024-sample line), ~3x the reads on `ram2`, the
      overlay's mapping. It raises `cap_native_h` to 720, which turns the Jellyfin client's 720p
      transcode on. **Designed 2026-10-03 (`hd_raster.md`, `feature/hd-raster`, `dev-hd-raster`), §10's
      choices decided by the maintainer 2026-10-03 (each as recommended):** a second PLL at 81 MHz = 3 x 27 (the SD rasters unchanged at
      one dot in three; `clk_sys` closes at only 44 MHz, so the raster side moves to its own clock),
      every native raster on the 81 MHz dot (every legal picture fits, picture-sized at worst),
      2,048-sample lines, interface 0.12; stage A the domain move alone, stage B HD.
      **Stage A built, fitted (SEED 6: clk_dec 104.30 / 103.71, clk_vid 92.16 / 92.05) and on the rig
      2026-10-04: HDMI and the analog chain (RetroTINK 480i / 576i, field order, anti-twitter) exactly as
      main's (`history.md` §29). Stage B built, fitted (SEED 3: 105.21 / 103.79, clk_vid 98.86 / 96.39) and
      on the rig: 1280x720 at its own pixels, x264 720p30 8 Mbit/s 1.13x as on the fitted raster (§30).**
      DDR3 measured first: a full 8888 canvas (~83 MB/s) costs x264 720p30 8M ~1.75 points (1.13x -> 1.11x),
      so the HD raster's ~300 MB/s was expected to leave ~1.03-1.08x; measured, the raster costs nothing and a
      full 1280x720 canvas over it `4444` 1.11x, `8888` 1.08x (§30). Found: `/dev/fb0` is Main's HDMI mode's
      size -- `ui.c` fixed (`hd_raster.md` §13). Moonlight at 1280x720p30 in Native ✅ with the maintainer
      (clean, responsive, errors 0); Jellyfin in Native ✅ (720p direct play, a 1080p film transcoded to
      1280x720: both good on HDMI). Not tested: a direct-video DAC, S-Video on a CRT.

## Phase 6 — Display completeness (UMD's "Moved out of P5", plus the general core's list)

✅ **P6 part 1 -- MERGED (PR fj#8), ✅ HW-CONFIRMED (2026-09-29): the 480i raster + csync and every
picture fitted to the raster** (`analog.md` §7, `history.md` §7 / §8): 480i measured on a
RetroTINK (1716x525i, 15.73 kHz / 59.94 Hz, field order correct), HDMI Bob, every shape in
Progressive (portrait 9:16 on HDMI) and at 480i (Letterbox / Crop / Fit / the snap).
✅ **P6 part 2 -- MERGED (PR fj#9), ✅ HW-CONFIRMED (2026-09-29): anti-twitter, the 60.00 Hz
raster, PAL 576i / 576p** -- on HDMI, the RetroTINK and a CRT (`analog.md` §8-§10, §7 steps
4-6; `history.md` §9). Decided with the maintainer
2026-09-29: Anti-Twitter Off by default, a 480i-only line; `Refresh Rate: Auto / 59.94 / 60 /
50 Hz`, Auto from the stream's VUI rate (a Sunshine stream is exactly 60.000 -> 60.00 Hz);
60.00 Hz exact by line length (one line in seven a dot longer); interface 0.3 (word 30
reports the raster). Remaining after it: a CRT round.

**Analog first (`analog.md`).** Decided with the maintainer
2026-09-28: MiSTer_DVD's Video Output (Auto / Interlaced / Progressive, one raster) and
Analog Aspect (Auto / Fit / Letterbox / Crop); an anti-twitter option; a 60.00 Hz raster
variant; PAL 576i / 576p (720x576 at 50 is 81,000 macroblocks a second: the same load as
720x480p60, already real time). Every picture fitted to the raster (D1). The items below
that these cover are tracked in `analog.md` §7.

- [x] Anti-twitter (480i, an option, Off by default) -- ✅ MERGED (PR fj#9), ✅
      HW-CONFIRMED (the (1, 2, 1) through the analog pins; on a CRT, S-Video 480i: a clear
      improvement on every test clip, the controls unaffected; `analog.md` §9).
- [x] The 60.00 Hz raster (Refresh Rate; Auto from the VUI rate) -- ✅ MERGED (PR fj#9), ✅ HW-CONFIRMED: 60.003 Hz
      measured, the RetroTINK reads V 60.00 Hz, no steady low-latency skips (`analog.md` §10).
- [x] PAL: a 50 Hz / 576-line raster (MiSTer_DVD's is the harvest); 25 / 50 frames/s
      content without 59.94 judder. ✅ MERGED (PR fj#9) (576p / 576i,
      the fit and the reader on 576 lines, csync's PAL block, Auto from the VUI rate), ✅ HW-CONFIRMED (576i field order
      correct on the RetroTINK).
- [x] The exact display aspect: `sar_w * W : sar_h * H` to the scaler (UMD rounds to 4:3 /
      16:9). ✅ MERGED (PR fj#8): the cropped size, 12 bits (sys_top's bit 12 is a pixel size).
- [x] The 480i raster + csync for CRTs; an analog vertical scaler (✅ MERGED (PR fj#8), ✅
      HW-CONFIRMED on a RetroTINK); a Film 24p raster (not built).
      **60p on a 15 kHz CRT** (asked 2026-09-28): the 480i raster shows each field from
      its own frame -- field n the even lines of the newest frame, field n + 1 the odd
      lines of the next -- the broadcast 60p -> 60i conversion, full motion rate, half the
      vertical detail per field. The pieces exist: the display scheduler already picks a
      store per 59.94 Hz refresh (a field is a refresh), `disp_reader` fetches one line per
      raster line (every other line of a frame store: half today's ram2 traffic), and
      the parity logic a field store uses would come from the raster's field for a frame
      store. New: sync_gen's 858 x 525 interlaced timing at 13.5 MHz (a clock enable on
      clk_sys), csync, and a Video Output option (the raster feeds HDMI's scaler too:
      480i there means ascal's weave / bob of a progressive source, so 480i is chosen for
      analog, not forced). Worth offering: P5f's (1, 2, 1) vertical lowpass on the field
      lines against interlace twitter on fine horizontal detail (the Blend's rounding,
      already built). The decoder is untouched (the raster is decoupled from decode).
- [x] **Analog Aspect** ✅ MERGED (PR fj#8), both output modes (asked 2026-09-27): MiSTer_DVD's `O Analog Aspect: Auto / Fit /
      Letterbox / Crop` (`dvd/emu.sv` there): on a CRT the raster goes out unscaled, so a
      16:9 stream on a 4:3 tube needs Letterbox (the vertical scaler above) or Crop (a
      horizontal window). HDMI is already handled by the scaler's `VIDEO_ARX`.
- [x] ✅ MERGED (PR fj#11), ✅ HW-CONFIRMED (`history.md` §10; with the OSD mirror and the
      settings request -- a program changes the core's settings, Main adopts them, not saved:
      `architecture.md` 0.4). **The program declares rendered content** (asked 2026-09-29 after the CRT round: the
      maintainer keeps Anti-Twitter Off by default, but a game-stream client should be able
      to turn it on): a `GRAPHICS` flag on VIDEO_AU (bit 4), taken from each stream's first
      like LOW_LATENCY (mismatches counted, a live flag); `Anti-Twitter: Auto, Off, On`, Auto
      = filter when the stream says GRAPHICS (unflagged streams stay unfiltered), Off / On
      override. Interface 0.4 (additive), `h264play --graphics`, the integrator pages. A
      follow-up branch (the maintainer, 2026-09-29).
- [ ] `frame_drop_ctl` (skip `nal_ref_idc == 0` when behind) if Phase 5 leaves any
      stream under real time.

## Phase 6b — The overlay plane (asked 2026-09-29, the maintainer) -- ✅ MERGED (PR fj#21), ✅ HW-CONFIRMED (2026-10-01)

The HPS program draws its own graphics -- a menu, a host list, a progress bar, subtitles, a
connection message -- over the decoded video, on HDMI AND analog. The MiSTer OSD is Main's
(a third-party program cannot drive it) and Linux's framebuffer path through ascal replaces
the core's picture on HDMI only; neither reaches a CRT. So the core composites it on the
raster itself. Before Phase 7: the control block's fields should exist when the interface
freezes at 1.0.

**Decided in principle 2026-09-29 (the maintainer): the overlay IS the Linux framebuffer.**
The program draws into `/dev/fb0` with ordinary fbdev / SDL code, so a ported client
(MiSTerFin-style Jellyfin, a Moonlight UI) keeps its UI; the core reads that memory and
composites it over the video on its own raster. Research behind it (MiSTerFin, Groovy_MiSTer:
neither composites an ARM UI over hardware-decoded video) and the design:
`architecture.md` "The overlay plane (Phase 6b)".

- [x] **Measure first** (the rig): ✅ `/dev/fb0` under this core (2026-09-29: `0x2200_0000`,
      8 MB; the program sets 720x480 in 8888 / 565 / 1555 / 8 and it sticks; drawing into it
      leaves the core's picture alone -- `architecture.md`); ✅ `ram2`'s load (2026-09-29: NOT free
      -- ~0.5 % of the decoder's time per 16 bpp line; at 854x480p60's ~0.9 % margin 32 bpp would
      fall behind, 16 bpp fits: the format is `1555`, and the program declares the band it drew
      on).
- [x] **Decided 2026-09-30 (the maintainer): the identity mapping, centred** (one canvas pixel one
      raster pixel; the status reports HDMI's aspect for the program; a scaled canvas later,
      additively) **and the formats `1555` / `4444` / `8888`, straight alpha** (the 480i filter needs
      a real blend whatever the format, so per-pixel alpha costs only the unpack).
- [x] **The interface, 0.9** (`architecture.md` "The overlay plane"): program words 72-79 (enable,
      format, base, size, stride, band, a generation pair -- gen_hi first, gen_lo last), read once a
      refresh on `ram2`, range-checked in order (CTL / SIZE / STRIDE / ALIGN / BAND / RANGE: refused,
      visible), shown only during a session; core words 46-47 (`ovl_*`, HDMI's `ar_x : ar_y`). Main's
      `LFB_EN` stays off. `hps/`: `h264ring_overlay_*`, `h264ring_fb_map`; the manual's
      `integrating/overlay.md`.
- [x] **The display side:** `h264/ovl_plane.sv` (the descriptor, the line control, the clk_mem engine:
      bursts into a beat FIFO, unpack, exact premultiply, the (1, 2, 1) as an accumulator line --
      each canvas line fetched once a field -- two slots of premultiplied RGBA; read-out LAT 5),
      `h264/ovl_blend.sv` (the composite; the output stage LAT 6), a second `ddr_mux2` on `ram2`.
- [x] **Gates in simulation:** `bench/h264/run_ovl_plane.sh` (8 arms against `tools/ovl_ref.py`,
      written from the architecture; O1-O32), `run_scaffold.sh` W60-W68, `run_ring_rd.sh` (words
      46-47), the library's host test + 4 red arms; `h264play --overlay` draws a progress bar.
- [x] **The fit:** SEED 7 (a sweep: the inherited SEED 9 missed by 0.15 ns), clk_dec 110.74 / 110.25,
      ALM 33,501 (80 %, +1,032), RAM 355 (+14), DSP 103 (+8), `H264_p6bovl_20261001_0013.rbf`.
- [x] **On the rig (2026-09-30, `history.md` §17):** every format composited over the densest
      stream (screenshots of the raster), flips clean, hide clean; fbcon's cursor found writing the
      region (the library now quiets it); `smem_start` `0x2200_1000`, 8888 = B, G, R, X;
      **measurement 3: a full 8888 canvas costs ~1 % and fits** (4.5-5 % left).
- [x] **With the maintainer (2026-10-01, `history.md` §20):** the RetroTINK at 480i / 576i (sync
      unchanged; the (1, 2, 1) through the pins: Off one line, Auto three), a CRT over S-Video (On /
      Auto steady, Off flickers), HDMI through a capture (each Bob field equally bright; 480p
      unfiltered; the stretch with a 16:9 stream as decided) -- ✅ HW-CONFIRMED.
- Fallback if the measurements rule the framebuffer out: the first plan -- a palette canvas
  (720x480 at 8 bpp) in DDR3 beside the ring, drawn through `hps/` helpers.

## Phase 6c — HDMI at the picture's own size (proposed 2026-10-01, the maintainer) -- designed with A' (`docs/hdmi_raster.md`, 2026-10-01; choices decided the same day) -- stage 1 (A', interface 0.10) and stage 2 (the native raster, Video Output Native (HDMI)) built, fit (SEED 6 106.0 / 104.73, 86 % ALM) and on the rig (`history.md` §22-§24), ✅ MERGED (PR fj#26), ✅ HW-CONFIRMED with the maintainer 2026-10-02

**Designed 2026-10-01 together with A' (`docs/hdmi_raster.md`), branch `feature/hdmi-raster`, two stages: A' on the
fitted raster first, then the native raster.** What the design found changes the questions below: ascal measures only
the DE area (>= 18 dots of horizontal blank), so **27 MHz is enough** -- the refresh stays 59.94 / 60.00 / 50 Hz at
exactly today's dots a frame, `disp_ctl`'s events do not move, and a native raster spends its spare dots on horizontal
blanking (854x480, 852x480, 640x480 and 720x576 fit; an uncropped 864x480 and full-size portraits at 59.94 fall back to
the fitted raster, flagged). `ini_vga_scaler` already reaches `emu` (a UMD-FORK in hps_io). The risk left is Main's
reaction to a size change (a mode re-programmed under `vsync_adjust`): measured first in stage 2. The text below is the
proposal as written before the design.

**The idea:** a mode where the core's raster is the decoded picture's own size (852x480, 640x480,
720x576, ...) instead of every picture fitted into the 720x480 / 576 raster, and ascal (the
framework's scaler) does the one scale to the display. Today a 16:9 transcode is resampled twice on
HDMI -- 852 wide down to 720 by the core's fit, then 720 up to 1920 by ascal -- and an anamorphic
720x480 picture is fitted by the core and scaled again. One scale, by ascal, from the decoded pixels
is the sharper HDMI picture; VIDEO_ARX / ARY already carry the exact display aspect (SAR included).
It is also the display half of any larger-than-480-line path later (`experiments.md`: 720p was
blocked as much by the 720x480 raster as by throughput).

**The constraint:** the core has ONE video output. It reaches HDMI through ascal and the analog
pins directly -- unless MiSTer.ini's `vga_scaler=1` sends ascal's output to the analog pins too. A
picture-sized raster on the analog pins is no TV's timing, so the mode is **HDMI (or `vga_scaler=1`)
only**, a user's choice; the analog-first default (the fitted 480i / 576i raster) stays. `emu`
already has `vga_scaler` (`ini_vga_scaler`, a UMD-FORK in hps_io -- corrected 2026-10-01), so the core can
refuse the mode, or choose it, knowing where its output goes.

**Questions for the design (none decided):**
- *The dot clock.* CLK_VIDEO is clk_sys, 27 MHz (480p's dot clock exactly). 864 active pixels at
  59.94 Hz and 525 lines need ~31-32 MHz with a short blanking; the widest picture inside the
  1,620-macroblock bound at 60 Hz needs more. A faster video clock (a sys_pll output) with
  CE_PIXEL, or a raster at the STREAM's rate (24 / 25 / 30 Hz: 864x480 at 24 Hz fits 27 MHz
  easily) and ascal's frame-rate conversion to the display -- which moves the cadence work from
  `disp_ctl` to ascal (its judder, its triple buffering; `vsync_adjust`).
- *Size changes.* The raster changes when the stream's size does (a new item, Moonlight's size, a
  resolution change mid-stream): ascal re-locks (a blank moment on HDMI); acceptable between items,
  to be measured mid-stream.
- *The overlay plane (interface 0.9).* Its canvas is identity-mapped onto a 720-wide raster; on a
  raster of the picture's size the mapping must be redefined (centred at its size, or scaled) --
  **an interface change to settle before 1.0** (`architecture.md` "The overlay plane").
- *Field pictures* (PAFF, 576i / 480i sources): the display's Weave / Bob still apply; native means
  the field pair's frame size.
- *The fit's other jobs* (crop, the VUI's display window, letterboxing a 2.39:1 picture) move to
  ascal's aspect handling; the status block's fit words report the native mode.
- *Display-reader bandwidth on ram2:* at most 1,620 macroblocks a picture, the same order as the
  fitted raster's reads -- to be measured, with the overlay's.

**A' (decided 2026-10-01, the maintainer; `jellyfin.md` F9): Progressive, Aspect Auto, a picture
WIDER than the HDMI display** -- letterbox it inside the raster and give ascal the display's shape
(the core knows HDMI_WIDTH / HEIGHT), so a program's overlay covers the screen and a scope film's
subtitles can sit in the bars; keep fill + the exact aspect for every other shape (pillarboxing a
narrower picture inside the 720-wide raster would cost horizontal pixels). Letterboxing costs nothing:
the core's vertical scale becomes ~1:1 and ascal makes the one scale. With it: **F8**, word 47's
`ar_x` / `ar_y` reading 0 on the hardware (`jellyfin.md`). Its own RTL branch, after the Jellyfin
client's; designed together with Phase 6c (both decide what the raster is on HDMI).

## Phase 6d — The picture's quality: Auto -> Native, the Area pre-filter (asked 2026-10-04, the maintainer) -- ✅ MERGED (PR fj#32), ✅ HW-CONFIRMED 2026-10-05 (the maintainer's comparison on .201)

The report: Moonlight at 854x480 "very pixelated", better in Native than Progressive; 1280x720p30
great in Native, much worse in Progressive (`analog.md` §11). Found: the host's 3:1 downscale
(Sunshine's one-tap CUDA sampler -- advice, not RTL), and the fit's 2-tap blend between 1:1 and 2:1
(beading) plus the 1,024-column floor (1280 boxed to 640). Decided with the maintainer:
- [x] **Video Output's Auto is Native (HDMI)** unless the ini sets up an analog TV (Interlaced) or a
      31 kHz VGA monitor (Progressive); interface 0.14 (word 80's `video_out`,
      `h264ring_video_out()`), the Jellyfin client's 720p box asks it (`analog.md` §11a). GREEN and
      `--red`: run_scaffold W39 / W96-W98, run_ring_rd, the library, the Jellyfin host test.
- [x] **The Area pre-filter, always on** (decided 2026-10-05 after the maintainer's comparison of the
      evaluation option Sharp / Area / Smooth: Area better on 720p, close at 854x480, Smooth too soft;
      `analog.md` §11b): no menu option, Smooth removed; Sharp kept only as the benches' control.
- [x] Fit SEED 6 103.62 / 102.8 PASS (90 % ALM, DSP 103); on the rig every mode bit-exact against the golden,
      `fetch_late` 0 on 1280x720, 720x1280, 2048x448 (`history.md` §33).
- [x] The maintainer's comparison on .201 (2026-10-05) -> Area always.
- [x] Refit (SEED 6 103.49 / 102.79 PASS, 90 % ALM, DSP 102) and the rig with Area always: bit-exact, no late rows (`history.md` §33).
- [x] ✅ MERGED (PR fj#32, 2026-10-05).
- Not changed (the maintainer, 2026-10-04): ascal's own filter when Main loads none (nearest).

## Phase 6e — Chroma reconstruction: siting-aware bilinear on every output (asked 2026-10-09, the maintainer) -- ✅ MERGED (PR #8), ✅ HW-CONFIRMED 2026-10-10 (the maintainer on .201)

The report, testing 1.0.0 in Native (HDMI): vertical bands beside red detail (the Netflix logo, a red
suit's webbing). Measured on .201: the reader showed chroma NEAREST (99.99 % of a test pattern), each
4:2:0 sample's error in one hard one-pixel stripe, widened by HDMI's scaler (`display.md` §3 "Chroma at
the identity").
- [x] At the identity fit (Native, a 1:1 Progressive picture) chroma interpolated at H.264's default
      siting: horizontally (the sample read one ahead = the second tap; the left neighbour the previous
      dot's), vertically on a frame store (the kernel's rows a / d). Shifts and adds: no DSP, no RAM,
      LAT 9. Stores of fields horizontal only; the scaled outputs and 480i nearest; siting type 0 fixed.
- [x] `run_disp_reader.sh` GREEN (57 arms) and `--red` (72 mutations, Z1-Z7 new); the golden checked
      against ffmpeg's in_chroma_loc=left upsampling within a code; `run_vid_equiv.sh` ALL GREEN.
- [x] Fit: SEED 12 MARGINAL (clk_vid 81.6: the first ahead index before the RAM address -- replaced by
      the second tap), then SEED 5 103.33 / 104.01, clk_vid 96.31 / 95.39 PASS
      (`H264_chromasweep_20261010_0632.rbf`); on .201 the pattern at Native matches the RTL's integers
      on 99.99 % of pixels, ffmpeg's upsampling within 3 codes (was 76 % / 107: `history.md` §43).
- [x] **The full version** (2026-10-10, "let's do the full version"; `docs/chroma.md`): the stream's
      `chroma_sample_loc_type` (all six types) carried from the SPS to the display; chroma rows in their own
      8 slots (each fetched once); bilinear chroma at the siting on EVERY output -- Interlaced, Progressive,
      Native, scaled or not; a field store within its own field. The identity step is its special case.
      Benches GREEN / `--red` (`chroma.md` §6).
- [x] Fit SEED 2 102.15 / 102.45, clk_vid 96.94 / 91.46 PASS; on .201 at Native, Progressive (scaled, Area) and
      480i the raster matches the golden 99.99-100 % (`history.md` §44).
- [x] The maintainer's look on real content (.201, 2026-10-10): "this looks better".
- [x] Merged (PR #8).
- Later: the PICTURE record's siting (an interface 1.x minor, with the siting / malformed-VUI telemetry);
  chroma under the Area pre-filter.

## A transcode with no audio, and a freeze (found 2026-10-09, the maintainer testing 1.0.0) -- the client ✅ MERGED (PR #9); the core (1.1) ✅ MERGED (PR #10); both ✅ HW-CONFIRMED 2026-10-11

`docs/jellyfin.md` §12, `history.md` §45.
- [x] The client (`clients/common/player.c`, both FFmpeg clients): the audio held to ~1 s ahead of the
      video (two reader queues), an audio stream the probe missed played, every record timed. A larger
      probe was measured on the rig and not kept.
- [x] Host tests GREEN and `--red`: Jellyfin (v) / (w), M22-M25; the player (x) / (y), M30-M33. The
      fixtures come from `tools/ts_skew.py`.
- [x] On .201, control arm first: 1.0.0's client froze and played two opens silent; this branch played
      all four opens with audio and no re-anchor.
- [x] Merged (PR #9). ✅ HW-CONFIRMED 2026-10-11 (the maintainer's round on .201, with the 1.1 core: `history.md` §46).
- [x] **The core's livelock (Part B), interface 1.1** -- ✅ MERGED (PR #10), ✅ HW-CONFIRMED 2026-10-11 (`architecture.md` "Queued
      audio: a late picture never runs the clock back over it"). Go given 2026-10-10 (the maintainer: "let's
      do part b now"). The rule, refined while building (the audio's history, not its state, tells the
      freeze from a stall): no lateness anchor while the queued audio LEADS (waited for the clock or started
      it, neither ran dry nor came late since). Built: `aud_play`'s `aud_lead`, `disp_sched`'s `lat`, the
      layout's version 1.1; benches `run_disp_anc.sh` X7-X10, `run_aud_play.sh` `[lead]` A12 / A13,
      `run_disp_sched.sh` heldlead, all GREEN and `--red`; fit SEED 4 103.8 / 102.73 PASS; **on .201** (control
      arm first, `history.md` §46): an audio lead of 10 s stuck the 1.0 core and plays to its end on 1.1, and
      1.0.0's Jellyfin client plays the film's freezing open, with one re-anchor after its queue ran dry (6 on
      1.0, frozen). The full `run_disp_sched.sh --red` ALL GREEN (43 mutations). The maintainer's round on .201
      (2026-10-11): "all tests look good". Merged (PR #10).

## Analog Aspect Fit, the anamorphic 16:9 fit (issue #11, found 2026-10-11 on the rig) -- ✅ MERGED (PR #14) · ✅ HW-CONFIRMED on HDMI (2026-10-12)

`docs/analog.md` §5a. Fit filled the 720x480 raster, so a TV in its 16:9 wide mode showed every picture at
1.78:1. Decided 2026-10-11 with the maintainer: Fit = Letterbox for a 16:9 display (a wider picture
letterboxed, a narrower one -- 4:3 included -- pillarboxed, 16:9 filled), HDMI's Auto 16:9 under Fit.
- [x] `disp_fit` (mode 2; Fill unchanged), `disp_fit_ref.py` (the rule, Fit in the ffmpeg oracle), `emu`
      `fit_169`; the manual's Fit and Aspect Ratio entries.
- [x] Benches: `run_disp_fit.sh --red` ALL GREEN (F33-F38); the "raster filled" fixtures moved to mode 3 with
      no display, byte-identical to main's; `run_disp_reader.sh` `fit_scope` / `fit_43`; `run_vid_equiv.sh`;
      `run_scaffold.sh` W111.
- [x] On .201 (`history.md` §48): under Fit at 480i, 720x304 -> 720 x 360, 640x480 -> 540 x 480, 848x480 -> 716 x 480,
      HDMI 16 : 9, errors 0; Fill unchanged (the control). First fit SEED 5 MARGINAL (100.45 / 98.98); a sweep follows.
- [x] A passing seed: SEED 1 101.91 / 102.68, HDMI gate PASS, smoke on .201 (720 x 360, HDMI 27.000 MHz).
- [x] The maintainer's look on HDMI (an LG B7 in 16:9, 2026-10-12): the SD HDMI modes now filled under Fit (`fit_fill`,
      `history.md` §48); the 4:3 / scope / 16:9 clips correct, the remaining crop the TV's overscan. Fit SEED 1 PASS
      102.99 / 101.87 (`H264_fit169_20261012_0103.rbf`).
- [x] Merged (PR #14, 2026-10-12).
- [x] On a CRT at 480i (.236, the maintainer, 2026-10-12): looks good, with the 0.15-era set replaced by main's core
      and clients (`history.md` §48).

## A field store's chroma at Figure E-1's field siting (2026-10-12, found by MiSTer_UMD_Video) -- ✅ MERGED (PR #17) · ✅ HW-CONFIRMED on .201 (2026-10-13)

`docs/chroma.md` §2, `history.md` §49. A field's chroma offset was the frame's in the field's own lines (field-centred);
Figure E-1 puts it at `(voff + p) / 2`. Field-coded content only (interlaced H.264, the player's interlaced MPEG-2).
- [x] `disp_reader` `c_vf`, the golden's rule and `check_field_oracle` (ffmpeg `interl=1`, six sitings); `run_disp_reader.sh
      --red` ALL GREEN (N12-N14).
- [x] On .201 against the golden, main's build as the control arm: 98.61 % exact / 99.99 % within 2 (main: 1.25 %).
- [x] A passing seed: SEED 5 105.24 / 102.18 (SEEDs 1-4 missed), HDMI gate PASS; the same result on .201.

## The 93 % ALM retime and the fitter's target (2026-10-13, `perf/retime`) -- ✅ MERGED (PR #18) · ✅ HW-CONFIRMED on .201 (2026-10-13)

`docs/throughput.md` §8, `history.md` §50. Every branch since 93 % ALM needed a seed sweep; agreed with the maintainer
to retime.
- [x] Three rounds from the census (seven modules), bit-exact: `run_recon_top.sh`, `run_mc.sh`, `run_mb_intake.sh`,
      `run_mv_pred.sh` `--red`; the cosim.
- [x] `h264/h264_fit.sdc`: the fitter aims clk_dec at ~104.5 MHz (+2-3 MHz on average across seeds).
- [x] Result: the seed spread is placement's (~93-104 MHz either way); SEED 1 102.28 / 102.79 PASS pinned; on .201 no
      throughput change against main, errors 0. Decided: merge as is; sweeps stay; clk_dec not lowered.

## Saved playback calibration (interface 1.2) -- implemented, strict fit passed; telemetry verified on Mister Pi, physical display check pending

The player can save measured picture placement and a visible viewport, then reapply them when a playback session
starts or resumes after a seek. The HPS computes the rectangle; the core publishes it together with the matching
clip, preserving the selected Auto / Fit / Letterbox / Crop mode and keeping native HDMI output outside this
override. Older cores report calibration as unsupported. The implementation is unmerged. The strict Quartus fit,
HDMI canary and calibration telemetry have passed; a physical CRT calibration check remains pending, and no DE10
hardware test has been run.
- [x] Ring Interface 1.2 request / ACK, validation and session replay; additive HPS API with explicit unsupported
      result on older cores. All 35 ring Icarus scenarios passed, including geometry request validation and
      nonce transitions.
- [x] Fit and reader regressions: `disp_fit_tb` checks calibrated sizing and atomic publication of rectangle
      plus viewport while a later request arrives; `disp_reader_tb +arm=geometry` checks inside/outside pixels
      and the large right-edge bound. Targeted mutations: `bash bench/h264/run_geometry_mutations.sh` must report
      all three caught (ignored geometry, ignored clip, malformed rectangle accepted).
- [x] Strict Quartus 17.0.2 fit passed: clk_dec 102.65 / 102.17 MHz, clk_vid 91.53 / 88.15 MHz; 41,180 / 41,910
      ALMs, 56,960 registers, 110 DSPs. HDMI canary passed. Qualified image: `H264_calibration_20261016_2357.rbf`,
      4,421,120 bytes, SHA-256 `09d868ebfc75412a18c1bad2527d5787a89372c94c4c5f034b777e95111ae968`.
- [x] On Mister Pi, with DeFlicker off and on, telemetry returned exact expected fit/crop/fit geometry for
      request sequences 1, 2 and 3; a fresh nonce started a clean session. Playback stopped cleanly in both tests.
- [ ] Physical CRT calibration visual check remains pending. No DE10 test has been performed; the telemetry result
      confirms reported geometry values, not how the calibrated picture looks on a display.

## Phase 7 — For integrators

- [x] ✅ **The interface frozen at 1.0 -- MERGED (PR fj#43)** (2026-10-07; `architecture.md` "Version 1.0",
      the manual's `integrating/interface.md` "Versions"): word 1 `0x0100`, the 0.17 layout unchanged; the
      library accepts the same major and a minor >= its own (`h264ring_version_ok()`), was exact; the
      integrator pages normative, their "not frozen" banners gone. Fit SEED 2 104.68 / 104.28 PASS
      (`H264_iface1_20261008_0042.rbf`); on .201 word 1 `0x0100`, a capture plays as on main's build, 0.17 <-> 1.0
      refused both ways; the 1.0 set installed on .201 (`history.md` §41). **The first release is
      1.0** (decided 2026-10-06, the maintainer): it freezes the interface (the control block's
      version, the library's, the integrator pages' "not frozen" banners) and goes out with the
      move to GitHub. Before it, every open interface question is settled or explicitly left to a
      later minor (additive) version: the Jellyfin findings still open (`jellyfin.md` §7: F1 the
      overlay only during a session, **F2 the colour matrix -- 720p sources are BT.709 and shown
      through BT.601** (built, fitted, pixel-exact on the rig, ✅ HW-CONFIRMED 2026-10-07: `colour.md`,
      interface 0.16; ✅ MERGED (PR fj#41)), F4 the STC as the program's clock, F5 the fit's flags before any picture -- interface 0.17, word
      30's `fit_valid`, on .201 2026-10-07: `history.md` §40; ✅ MERGED (PR fj#42)). F1 / F4 left to later additive minors
      (no client needs them).
- [x] ✅ **The move to GitHub -- made 2026-10-08** (decided 2026-10-06, the maintainer: a fresh history, as
      MiSTer_DVD's; CLAUDE.md "Source control"). Before it: Forgejo-era references written `fj#NN` (CLAUDE.md
      "Historical `fj#NN` references"), `NOTICE` for `clients/common`, `player`, `uvc`, the manual's stale overlay
      section, the README, the camera viewer in `tools/package_release.sh` (PR fj#40); D5 decided (the name stays
      "H264"); `tea` -> `gh` and the workflows active (PR fj#45); the tree swept for personal data (no personal
      e-mail address, host or path in any tracked file). **The import commit `9aacaac`** ("MiSTer H264 core", no
      parent, the tree of Forgejo's last `main`), authored and committed with the GitHub noreply address (this
      repository's `user.email` since), pushed alone as `main` to `github.com/owenb321/MiSTer_h264_decoder`
      (private while staged); `origin` is GitHub, the Forgejo repository the remote `forgejo` (never pushed to
      GitHub). **The release's clients built in CI** (PR #1): `clients.yml` builds the four HPS clients in images
      made from the repository -- a check on every PR touching `hps/` or `clients/`, and called by `package.yml`
      with the manifest's commit, so the zip's clients are the release commit's. Left for going public, with the
      first release (1.0, above): the repository's visibility, Settings -> Pages -> Source "GitHub Actions".
      MiSTer_UMD_Video is private, so nothing public links it.
- [x] Example integrations: a Moonlight client fork (PR fj#13), the Jellyfin client (PR fj#24) and the file player
      (PR fj#27), below. **A Plex client is dropped** (the maintainer, 2026-10-04: "I'm content with Jellyfin");
      the core stays service-neutral, and a Plex client remains something an integrator could write against the
      interface.
- [x] ✅ **MERGED (PR fj#24), ✅ HW-CONFIRMED (2026-10-01, with the maintainer; a CRT not yet). The
      Jellyfin client** (asked 2026-10-01, the maintainer; `docs/jellyfin.md`, `history.md` §21):
      **v1, the cast target, on the rig** against the maintainer's server
      (§10: Quick Connect, cast, pause / seek / stop, the overlay's panel and subtitles); the host
      test GREEN and `--red` (`clients/jellyfin/tests/`); the maintainer's rig round left. Decisions J1-J6 (accepted 2026-10-01) (v1 a cast target, an LVGL
      browse UI in v2; `clients/jellyfin/`, own C code + FFmpeg's LGPL libraries; direct play
      when a file fits D1, else an HLS transcode capped by one 854x480 box; Quick Connect; text
      subtitles on the overlay). Measurements R1-R3 first (what a QSV server sends, the ARM's
      audio cost, a session with no video). **The interface is not frozen by it** (the
      maintainer: 1.0 waits for a public release): its findings (`jellyfin.md` §7 -- the overlay
      only during a session, the colour matrix, the refusal's name, the STC as the clock) are
      designed and versioned as usual. The UI of D6 was to be its v2 -- **dropped (the maintainer, 2026-10-12)**: the
      client stays a cast target.
- [x] ✅ **CAVLC through the HPS (fj#20) -- MERGED (PR fj#25, 2026-10-02, interface 0.10; `docs/cavlc.md`)**: a lossless CAVLC ->
      CABAC rewrite in the client library (`hps/include/h264ring_cavlc.h`), no RTL change;
      `h264play` uses it on every access unit. `run_cavlc.sh` GREEN and `--red` (30 mutations):
      70 AVCv1 CAVLC streams + x264 / JM / synthetic High CAVLC bit-exact, the refusals by name.
      **Step 1 measured on the rig: ~12-13 % of one A9 core per Mbit/s at 480p60** (3.2 Mbit/s
      49 %, 6.3 Mbit/s 87 %); the issue's gate (8 Mbit/s beside a client) does NOT pass -- the
      ceiling is ~4-5 Mbit/s (the hot-loop rework, `cavlc.md` §8a: -8 %, ~11-12 % per Mbit/s;
      no software path to 8 Mbit/s). Rewritten streams decoded by the core on the rig, errors 0.
      **Decided 2026-10-01 (`cavlc.md` §8)**: CAVLC supported through the rewrite (the scoping
      decision reversed, the ceiling stated); on by default in `h264play` and the Moonlight client
      (its host test S7 / S8); the Jellyfin client left as it is; one version number kept;
      optimisation: the hot loops reworked, -8 % (§8a), the limit then accepted. The rewrite runs
      inside `h264ring_write_au()` (§9). ⏳ The Moonlight client against a host forced to CAVLC.
- [x] ✅ **MERGED (PR fj#27), ✅ HW-CONFIRMED (2026-10-02, the maintainer on .236). The file player** (asked 2026-10-01, the maintainer: "a video
      player HPS app -- what formats can we support?"; `docs/player.md`). `h264player`: files
      from the SD card, USB drives and mounted shares, a folder browser on the overlay driven
      by the pad, a Scripts-menu launcher. **What plays is the core's envelope** (no transcode
      on the ARM): SD H.264 Main / High CABAC 8-bit 4:2:0 up to 1,620 macroblocks; MKV / MP4 /
      TS / raw .264; AAC / AC-3 / E-AC-3 / DTS / MP3 / Opus / Vorbis / FLAC; text subtitles from
      the file or an .srt beside it. Everything else refused by name before the ring (the
      1,620 bound raises no refusal in the core: the player checks the SPS). Decisions P1-P3
      (2026-10-01: `clients/common/` shared with the Jellyfin client; the overlay browser; v1
      = the envelope + embedded text subtitles), P4 accepted 2026-10-02 (50 Hz for 25 / 50 frames/s files
      while Refresh Rate is Auto). Host test GREEN and `--red` (`clients/player/tests/`, 17
      mutations); the Jellyfin test GREEN and `--red` (19). The ARM build in
      `mister-h264-clients:deps2`; **on the rig** (`history.md` §26). Also on the branch: the
      Jellyfin client's two defects from the maintainer's round (`jellyfin.md` §11: a subtitle
      switch froze the picture; subtitles switched on mid-film never showed) and **P5, a
      screensaver** in `clients/common/ui.c` for both clients (dim at 5 min, black at 30, a
      status line fading at random places; decided with the maintainer). **Rebased onto
      interface 0.10 (2026-10-02):** the overlay canvas the raster's own width (Native (HDMI)),
      and CAVLC files play through fj#20's rewrite (P6: up to ~4-5 Mbit/s at 480p60). **The
      maintainer's round on .236 with a 0.10 core: every test successful**, the screensaver
      included; the dense CAVLC clip's sluggish controls fixed (`history.md` §26). ⏳ The Jellyfin
      fixes and screensaver on the maintainer's server; a CRT at 576i. What would widen it: the
      720p24 D1 decision (taken 2026-10-02: Phase 5c -- 720p files play, a 720p60 file is refused
      "too fast").
- [x] **Other codecs decoded on the ARM (P7, interface 0.15) -- ✅ MERGED (PR fj#35), ✅ HW-CONFIRMED 2026-10-06 (the maintainer: .236's CRT and .201)** (asked 2026-10-03 / 2026-10-05, the maintainer: "let's work on implementing the
      wider codec support on ARM for the video player"; `docs/player.md` P7, `docs/architecture.md`
      "Pictures from the program"). Decided 2026-10-05: a raw-picture record (the ARM writes the decoded
      picture into a DPB store, the core presents it as its own), the measured-comfortable codecs
      (MPEG-1/2, MPEG-4 Part 2, DivX 3, WMV7/8, Theora, MJPEG, H.263), Jellyfin unchanged; **SD only**
      after step 0 (the store copy is CPU-bound at ~97 MB/s, `experiments.md`). Built: `h264/pic_in.sv`,
      `ring_rd`'s PICTURE path (errors 11-16), word 84; the library's store rule and copy; `vdec.c` and the
      player's picture path. GREEN and `--red`: `run_ring_rd.sh` (R28-R33, 83 mutations), `test_ring` /
      `test_hps_lib` (12 library mutations), the player's host test (p1-p3, T10, M22-M28). Fit SEED 6
      PASS (102.95 / 102.9, 90 % ALM); on .201 every store byte-exact against the ARM's own decode, nine
      codecs in real time (`history.md` §35). The analog chain (§35): timing and line parity right, the pairs'
      temporal order wrong at 576i -- fixed on the branch (UMD's V6 ported, word 85; `analog.md` §5). The
      maintainer's round on .236 / .201 (2026-10-05 / 06): the player's UI kept inside title-safe on SD rasters,
      DTS 5.1 downmixed with its centre, the library's cold-boot write index fixed; the analog DAC's banding
      on an 18-bit I/O board found and an OSD option added (Analog Dither, Off; `analog.md` §12); the fetch
      retimed on clk_mem. Fit SEED 5 PASS (103.11 / 103.46, every clock positive); on .236's CRT the dither smooths
      the banding and the 576i field-order clip plays with no back-steps (`history.md` §36). Merged (PR fj#35). ⏳ Moonlight / Jellyfin 0.15 builds through a whole session; interlaced
      MPEG-2 at 480i by eye.
- [x] **The dither's matrix: a Latin square -- ✅ MERGED (PR fj#38), ✅ HW-CONFIRMED 2026-10-06 (.236's CRT)** (2026-10-06; found in MiSTer_DVD's copy, its
      PR fj#164; `analog.md` §12 "The matrix"). Analog Dither's Bayer-top-bits matrix (a 2 x 2 in effect) was exact
      over 4 x 4 but not per line: a line texture at `v % 4 = 1` / `3`. Now every line and column exact (DVD's
      matrix); `run_dac_dither.sh --red` GREEN (`[lines]` / `[cols]`, T1-T9). Fit SEED 5 103.61 / 102.79 PASS, 37,938 ALM. On .236's CRT at 480i against main's
      build: main's crosshatching gone, gradients better, blue no worse (the maintainer; `history.md` §38).
- **Dropped (the maintainer, 2026-10-12): a CRT test-pattern / calibration app** (proposed 2026-10-06 with the
      USB viewer below; never started).
- [x] **A USB capture / webcam viewer -- ✅ MERGED (PR fj#37), ✅ HW-CONFIRMED 2026-10-06 (.201, and .236's CRT)** (proposed 2026-10-06 with the app above;
      `docs/uvc.md`: step 1's tool `h264cam` built -- libusb + our own UVC layer, the stage-by-stage
      measurement --; **measured on .201 with a C270 (2026-10-06): MJPEG 640x480 at 30 fits, CPU0 taken
      0.724** after the library's full-range / 4:2:2 copy was sped up 14.3 -> 8.15 ms (NEON, same bytes,
      `hps/tests/run_copy_arm.sh`); USB ~0.2 of CPU0; the USB host carries ~6 MB/s of isochronous
      video (uncompressed 640x480 loses every frame; light MJPEG streams on every setting). **The viewer
      built** (`Scripts/h264cam.sh`, `clients/uvc/src/cam.c`, `docs/uvc.md` U6): the best mode, a mode
      list, pause, unplug / replug, refusals by name; its host test GREEN and `--red` (15 checks, 21
      mutations); the manual's "Showing a USB camera"; on .201 with the C270 (`history.md` §37); ✅ HW-CONFIRMED with the
      maintainer on .236 2026-10-06 (unplug / replug twice, good on a CRT at 480i)). A UVC camera or an HDMI
      capture dongle shown through the core -- the MiSTer as a 15 kHz output for another source. **The
      catch, measured on .201:** the MiSTer kernel (6.18.38-MiSTer) has no UVC / V4L2 (neither built in
      nor a module), so it needs userspace USB (`libuvc` over `libusb`, usbfs) and MJPEG (or YUYV) decoded on
      the A9 into the stores at SD (the ARM path's budget: `player.md` P7, `experiments.md`); latency a
      few frames (a camera, not a game). Step 1 (usbfs and MJPEG 640x480 at 30 on one A9 core with the copy) passed:
      above.
