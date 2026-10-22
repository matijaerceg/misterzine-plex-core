# Phase 1 — measuring the gap

Engineering note (`roadmap.md` Phase 1). What the hosts send, and what the decoder forked
from UMD costs on it, measured before any design choice for Phase 5. Inputs to decision
D1 (profile and throughput scope). All numbers 2026-09-27.

## 1. Method

- **The decoder:** MiSTer_UMD_Video at `75e3f37` (the fork point; UMD main moved to
  `6d312a6` since, a docs-only PR), snapshotted with `git archive` into scratch so nothing
  was written into UMD's tree, run through UMD's own Verilator cosim (`h264_top` →
  `recon_top` as `emu` composes them, the C++ DDR model with `ddr_model.sv`'s rules),
  built with `bench/umd/run_cosim.sh`'s exact flags. Coordinated with both UMD sessions
  first (one cosim at a time while their fit ran).
- **The golden:** UMD's Python model (`h264_recon_ref.py`) through `tools/p1/es_golden.py`
  — UMD's `cosim_golden.py` with an Annex-B file in place of a disc window. **Every window
  below: the model bit-exact vs ffmpeg, then the RTL identical to the model on every
  macroblock before deblocking and every picture after it**, output order scored.
- **The metric:** clk_dec cycles per macroblock over the window, at 81 MHz. Real time at
  720x480p59.94 is **81 M / (1,350 × 59.94) = 1,001 cycles a macroblock**. The DDR model
  is not the rig's DDR3: UMD measured the rig 4-7 % slower than the model on its discs.
  Where the cycles go: the cosim's `+prof` histograms per state (`tools/cosim_prof.py`,
  UMD's), cycles per macroblock.
- **Reproduce:** `tools/p1/make_clips.sh SOURCE START OUT` then
  `tools/p1/run_p1_cosim.sh [--frames N] OUT/*.264` (tell the UMD sessions first).

## 2. The streams: proxies (§2a) and a capture from a real host (§2b)

### 2a. Proxies

Local encodes shaped like what a host sends (§4 says how Sunshine configures its encoders).
Source: 5 s of an action sequence from an animated film (sharp edges and flat areas, like
game content), cropped to 3:2, 720x480, motion-interpolated from 23.976 to 59.94 distinct
frames/s (duplicated frames would encode as skips and understate the load). The encoder
is an RTX 4070's NVENC (the Sunshine default on NVIDIA) and libx264.

| stream | encoder, shape | profile | refs | slices / picture | notable |
|---|---|---|---|---|---|
| `x264_main_12M` | libx264 veryfast zerolatency, 11.0 Mbit/s | Main | 1 | **7** | weighted P on, deblocking off across slice edges (`disable_deblocking_filter_idc` 2), POC type 2 |
| `nvenc_main_12M` | NVENC p1 ull CBR, 12 Mbit/s | Main | 3 | 1 | filler data NAL units (type 12) |
| `sun_main_{4,8,12}M` | NVENC p1 ull CBR, VBV one frame, refs 1 requested, 1 slice, infinite GOP — the stock Sunshine shape but Main | Main | 2 (NVENC's DPB for refs 1) | 1 | — |
| `nvenc_high_12M`, `sun_high_8M` | the same at High | **High** | 3 / 2 | 1 | **`transform_8x8_mode_flag` 1**: the driver enables the 8x8 transform by itself |

Every stream: CABAC, frame pictures only, P slices only after the IDR, level_idc 31,
8-bit 4:2:0. `tools/p1/hdr_summary.py` gives the full field census.

### 2b. A capture from a real Sunshine host (2026-09-27)

**Stock Sunshine on this workstation** (the maintainer installed it; default settings;
Linux, KDE Wayland portal capture, FFmpeg `h264_nvenc` on the RTX 4070 -- Sunshine's log:
"Found H.264 encoder: h264_nvenc [nvenc]"), streamed to **a real Moonlight client**:
moonlight-embedded `f32e415` with one addition, a video sink that writes every decode
unit to a file (`tools/p1/moonlight_dump.patch`), paired by PIN like any client. The
session: the host's Desktop app at 720x480@60, H.264 only, 1 slice requested, no reference
frame invalidation declared (the simplest shape a client can ask for), view-only. On the
host's screen: the same action segment as the proxies, 10 s at 59.94 distinct frames/s,
looped fullscreen in mpv (known, moving content; nothing personal). Three 22 s sessions:
`tools/p1/capture_sunshine.sh`.

| session request | frames | at the encoder (measured) | Sunshine's formula |
|---|---|---|---|
| 3,000 kbit/s (moonlight-qt's default) | 1,293 | 2.41 Mbit/s | 1.99 (the gap not explained yet: the IDR and the CBR fill of a short window are candidates) |
| 10,000 | 1,315 | 7.74 | 7.30 |
| 16,000 | 1,314 | 12.07 | 12.03 |

**Headers** (`tools/p1/hdr_summary.py`, every capture identical): **High profile
(`profile_idc` 100), `transform_8x8_mode_flag` 1**, CABAC, `level_idc` 31, no scaling
matrices, `max_num_ref_frames` 2 with one reference active, one IDR at the start then P
pictures only (no B), 1 slice per picture, POC type 2, no weighted prediction, deblocking
on, frame pictures, 8-bit 4:2:0, VUI timing with `pic_struct_present_flag` 1 -- and **a
filler-data NAL unit (type 12) after every picture** (CBR padding). (Found at P5a, 2026-09-28: the
stream carries **no SEI at all** -- NAL types 7, 8, 5, 1 and 12 only -- although
`pic_struct_present_flag` 1 requires a pic_timing SEI in every access unit (Annex D), so every
picture counts `pt_missing` in the status block and the display paces by the VUI tick
(`display.md`); harmless, but a Moonlight client cannot take picture structure from it.) Exactly the source
study's prediction (§4) and the NVENC proxies' shape.

**Macroblocks** (`tools/p1/mb_census.sh`: JM's trace of the first 120 pictures, the IDR
included, classified by `tools/p1/jm_mbcensus.awk`; validated on a 10-picture window
against the trace's own totals -- 13,500 macroblocks, 4,313 skipped):

| session request | skipped | inter | intra 4x4 | intra 8x8 | intra 16x16 | PCM | coded MBs using an 8x8 tool (inter 8x8 transform + I8x8) |
|---|---|---|---|---|---|---|---|
| 3,000 | 58.2 % | 40.1 % | 0 | 0.68 % | 1.03 % | 0 | **3.9 %** (2.3 + 1.6) |
| 10,000 | 52.3 % | 45.1 % | 0 | 1.13 % | 1.52 % | 0 | **3.8 %** (1.4 + 2.4) |
| 16,000 | 52.7 % | 44.8 % | 0 | 1.10 % | 1.39 % | 0 | **3.3 %** (0.9 + 2.3) |

- **Every stream uses the 8x8 tools, on ~3-4 % of coded macroblocks.** One such
  macroblock is enough for a Main-only decoder to refuse the stream (as this one does,
  `REF_T8X8`) or, worse, show garbage. With a stock host **High-profile decoding is a
  requirement**, not an option; its throughput weight is small (a few percent of
  macroblocks), its cost is area and correctness work.
- **NVENC never uses intra 4x4 here**: every `I_NxN` macroblock is intra 8x8. (Intra 4x4
  stays required -- legal, and x264 uses it -- but the 8x8 path is the one this host
  exercises.)
- **Half the macroblocks are skipped** although the content moves in every source frame.
  Not verified: whether the portal capture delivered every distinct frame of the 59.94
  frames/s playback on the 60 Hz desktop (a duplicated capture encodes almost entirely as
  skips). The 8x8 shares above are per CODED macroblock, which that does not bias; the
  skip share should not be read as typical of games.
- JM trace quirks the census handles (both checked in JM's source): the next slice's
  header is printed before the current picture's macroblocks; CABAC `mb_skip_flag` is
  traced inverted; P-slice `mb_type` is traced in JM's own code (1-5 inter, 6 `I_NxN`,
  7-30 `I_16x16`, 31 PCM; `readMB_typeInfo_CABAC_p_slice`).

The captures are High, so the cosim cannot run them (the decoder refuses the 8x8
transform); §3's cycles come from the Main proxies, which have the same encoder, shape
and rates.

## 3. Results

Bitrates are the **encoder's target**. A Moonlight client's request reaches a Sunshine
encoder reduced by the FEC share (20 % by default), stereo audio (192 kbit/s) and a
10 % / 500 kbit/s overhead margin (`src/rtsp.cpp:1262-1276`, read): **the client-side
equivalent is given beside each row. moonlight-qt's default request for 720x480 at 60
frames/s is 3,000 kbit/s** (`app/settings/streamingpreferences.cpp:367`, moonlight-qt
`c0f62ad`: 1.64 by interpolation between its 360p and 480p rows, x 2 for 60 frames/s,
rounded to 3), which is **~1,990 kbit/s at the encoder** -- the `sun_main_2M` row.

"Real time" is 1,001 / cycles a macroblock (the cosim's own figure uses the window's
pic_timing duration, which counts one frame short: 0.984 s for 60 frames).

| window | encoder target | client request | frames | cycles / MB | frames/s at 81 MHz | real time | speed-up needed |
|---|---|---|---|---|---|---|---|
| `sun_main_2M` | 1.99 Mbit/s | **3.0 (the default)** | 60 | **1,033** | 58.1 | **0.97x** | **1.03x** |
| `sun_main_4M` | 4.0 | 5.8 | 60 | 1,069 | 56.1 | 0.94x | 1.07x |
| `sun_main_8M` | 8.0 | 10.9 | 60 | 1,186 | 50.6 | 0.84x | 1.18x |
| `x264_main_12M` | 11.0 (x264) | — | 60 | 1,296 | 46.3 | 0.77x | 1.29x |
| `sun_main_12M` | 12.0 | 15.9 | 60 | 1,382 | 43.4 | 0.72x | 1.38x |
| `nvenc_main_12M` | 12.0 | 15.9 | 60 | 1,383 | 43.4 | 0.72x | 1.38x |
| `x264_main_12M` | 11.0 (x264) | — | 300 | 1,298 | 46.2 | 0.77x | 1.30x |
| `nvenc_main_12M` | 12.0 | 15.9 | 300 | 1,356 | 44.2 | 0.74x | 1.35x |

The 300-frame windows (5 s, 405,000 macroblocks each) agree with their 60-frame ones
within 2 %: inter wait 616 / 619, input wait 122 / 180 cycles a macroblock.

(UMD's disc titles, for scale: 1,639-1,843 cycles a macroblock at ~2 Mbit/s film content,
where real time at 23.976 frames/s allows ~2,500.)

**Correctness: no functional gap for Main.** UMD's decoder plays every Main stream here
bit-exact -- 7 slices per picture with deblocking off across their edges, explicit
weighted P, 1-3 references, filler NAL units, POC type 2 -- none of which its disc library
exercised this way.

**Throughput: at Moonlight's default bitrate the Main decoder is 3 % short at 81 MHz;
at game-streaming bitrates chosen by the user (11-16 Mbit/s requested) 1.2-1.4x short.**

### Where the cycles go (cycles a macroblock, `recon_mb`'s front, 60-frame windows)

| window | total | waiting on inter prediction (`M_INTER_WAIT`) | waiting for input (`M_IDLE`) | residual (`M_RES_*`) | deblock hand-off (`M_DB_WAIT`) |
|---|---|---|---|---|---|
| `sun_main_2M` | 1,033 | 625 | ~0 | ~60 | 100 |
| `sun_main_4M` | 1,069 | 652 | ~0 | ~60 | 100 |
| `sun_main_8M` | 1,186 | 626 | 90 | ~140 | 100 |
| `x264_main_12M` | 1,296 | 587 | 153 | ~250 | 100 |
| `sun_main_12M` | 1,382 | 558 | 246 | ~230 | 100 |

Inside the inter path (`x264_main_12M`): the reference fetch from DDR (`I_FETCH`) 297,
list / setup (`I_LIST`) 183, drain 86; the interpolator's `K_WEIGHT_WAIT` 405. ⚠ This
breakdown is **attributed from state names, not yet from a read of `recon_inter.sv`**:
`K_WEIGHT_WAIT` is as large (383) on the NVENC streams, whose `weighted_pred_flag` is 0,
so it is not the explicit weighting itself -- probably the interpolator waiting on the
weighting / write-back stage's hand-off. What is measured is the total: the ~600-cycle
floor. The back engine's deblock (`E_DB`, 370-490) and the residual feed
(`R_FEED`, 530-610) overlap the front and are not on the critical path at these rates.

Two findings:

1. **Inter prediction is a fixed ~560-650-cycle floor per macroblock**, nearly independent
   of bitrate. On its own it is over half the 1,001-cycle budget; at 4 Mbit/s it is the
   whole shortfall. It is the first thing to widen; which part of it (the fetch, the
   interpolator, the hand-off after it) needs a read of `recon_inter.sv` and a profile
   per sub-state before a design -- the cost is DDR occupancy and area, not a new
   algorithm.
2. **The front end (CABAC, `mb_syntax`) starts to starve the reconstruction above ~6-8
   Mbit/s** at the encoder: `M_IDLE` 0 → 0 → 90 → 246 cycles a macroblock at 2 / 4 / 8 /
   12 Mbit/s. UMD's
   deferred `mb_syntax` throughput follow-up (issue the next request in the cycle a bin is
   consumed; SE emission merged into the issuing states: roadmap P3 there, measured
   0.16-0.26 bins/cycle) becomes needed at game bitrates.

A faster clk_dec buys the rest linearly: UMD closes ~89-93 MHz at its best seeds against
the 86 MHz gate; at 90 MHz the default bitrate (1,033 cycles: 1.08x) and 4 Mbit/s (1.05x)
would be real time on the DDR model -- **but UMD measured the rig 4-7 % slower than this
model**, which eats that margin; 8 and 12 Mbit/s would not be real time at any clock
UMD has closed.

## 4. What a stock Sunshine host sends to a Moonlight client

From the sources (Sunshine `66abe63`, 2026-09-27; moonlight-common-c `f900dd4`,
2026-09-26; read by a research agent, citations as `file:line`):

- **Profile: always High**, on every H.264 path (read), and **no knob turns the 8x8
  transform off** (read: no config key or client flag exists). Whether each encoder
  actually USES 8x8 at High: **measured** for NVENC (below), **read in FFmpeg's code**
  for VAAPI and libx264's default preset, **inferred, not measured** for QSV, AMF and
  MediaFoundation. NVENC native (Windows) uses the High GUID (`src/nvenc/nvenc_base.cpp:361`) and
  never sets `adaptiveTransformMode`; the FFmpeg paths ask for High
  (`src/video.cpp:846, 2032`; QSV `:956`; VAAPI `VAProfileH264High`,
  `src/platform/linux/vaapi.cpp:252-254`, where FFmpeg sets `transform_8x8_mode_flag` for
  every non-Main profile); libx264's default `superfast` preset has 8x8dct on. The client
  cannot ask for Main: `VIDEO_FORMAT_H264` means High profile
  (moonlight-common-c `src/Limelight.h:225`). The only non-High route is AMD AMF with
  `amd_coder=cavlc` (Constrained Baseline, `src/video.cpp:151-161`) -- CAVLC, which this
  decoder refuses too. **Measured here:** NVENC at High sets `transform_8x8_mode_flag` 1.
- **Entropy: CABAC by default** everywhere (host knobs `nvenc_h264_cavlc`, `qsv_coder`,
  `amd_coder` exist to force CAVLC).
- **Slices:** the client's `videoEncoderSlicesPerFrame` (1-255; 1 when unset,
  `src/SdpGenerator.c:423-432`); libx264 hosts force at least `min_threads` = 2.
- **References / GOP:** no B-frames anywhere; infinite GOP, an IDR only when the client
  asks (MediaFoundation: every 120 frames); **refs 1 unless the client declares reference
  frame invalidation** (then "encoder default": NVENC DPB 5). No long-term references
  anywhere in Sunshine; without RFI the client waits for an IDR after a loss, so no
  frame_num gaps. Intra refresh is never requested by moonlight-common-c.
- **Rate control:** CBR (NVENC) with a VBV of ONE frame; the client's bitrate reaches the
  encoder at ~0.73x after FEC, audio and a 500 kbit/s margin (`src/rtsp.cpp:1262-1276`).
  moonlight-qt's default request for 720x480 at 60 frames/s is 3,000 kbit/s (read, §3):
  ~2 Mbit/s at the encoder. The user can raise it; the client chooses.
- **Always frame pictures, always 8-bit**; 4:4:4 only if the client sets
  `VIDEO_FORMAT_H264_HIGH8_444`. No level_idc is forced (the encoder picks it).
- **What a decoder must tolerate:** trailing zero padding from FEC, filler NAL units
  (likely only on VAAPI CBR), an SPS / PPS repeated at every IDR, I and P slices only.

**So a stream from a stock host is High profile with the 8x8 transform on.** The
simplest shape the FPGA client can ask for: 1 slice, RFI not declared (refs 1, P only,
IDR on loss), 4:2:0, the bitrate it can decode.

## 5. What this means for D1 (to decide with the maintainer)

Two separable questions:

1. **High profile, or a patched host.** Measured on a real session (§2b): every stream
   uses the 8x8 tools, on ~3-4 % of coded macroblocks. With stock Sunshine the core must
   decode High:
   the 8x8 transform and its dequantisation, intra 8x8 prediction (with the reference
   sample filtering), the 8x8 CABAC contexts (1,024 in all), and the High-profile SPS / PPS
   syntax (scaling matrices: none of the hosts above sends any, but they are legal).
   The alternative is a one-line Sunshine patch per encoder (Main GUID / profile), which
   every user of the core would need on their host. The UMD session estimated High at a
   modest area cost next to the throughput work; not measured.
2. **Throughput.** Main at 480p60 is **3 % short at Moonlight's default bitrate** (~2
   Mbit/s at the encoder) and 1.2-1.4x short at 11-16 Mbit/s requested; the DDR model
   flatters the rig by 4-7 %. The inter path is the fixed floor (~600 cycles, first);
   the front end matters above ~8 Mbit/s. The bitrate the FPGA client requests (it is
   Moonlight's own setting) bounds the second. High profile's 8x8 transform is, if
   anything, cheaper per coefficient; intra 8x8 adds a prediction mode.

## 6. Not measured yet

- **High-profile cycles:** the decoder refuses the 8x8 transform, so there is no number
  (the captures, §2b, cannot run in the cosim).
- **A game** as the captured content (§2b used a looped film segment), and whether the
  capture delivered every distinct frame (the 52-58 % skip share).
- **Another host encoder** (AMD AMF, Intel QSV / VAAPI, libx264 software): the source
  study covers them (§4); only NVENC was captured.
- **The rig vs the DDR model** at these rates (UMD's 4-7 % held for disc content).
- **Bins per cycle directly** (the cosim does not print it); `M_IDLE` stands in for it.
- **Audio** (D2): no measurement taken; Moonlight sends Opus.

## 7. Picture quality at 3, 10 and 16 Mbit/s requested (2026-09-27, for D1's bitrate)

To choose the bitrate the core promises, the maintainer asked what the difference looks
like. Method: two 10 s clips at 720x480, 59.94 distinct frames/s (motion-interpolated film:
the animated action scene of §2, and a grainy live-action fight), encoded by NVENC exactly
as stock Sunshine does (High, 8x8 on, 1 slice, refs 1, no B, CBR with a ONE-frame VBV) at
the encoder rates the three real sessions measured (§2b: 2.41 / 7.74 / 12.07 Mbit/s for
3,000 / 10,000 / 16,000 kbit/s requested), scored per frame against the source with VMAF
(libvmaf 3.2.0, default model), PSNR and SSIM. 600 frames per clip.

| clip | request | VMAF mean | worst 1 % | worst frame | frames < 80 | longest soft stretch (< 85 until > 90) |
|---|---|---|---|---|---|---|
| live action | 3,000 (default) | 89.1 | 46.6 | 19.9 | 8.5 % | 34 frames (567 ms) |
| live action | 10,000 | 97.3 | 78.2 | 50.8 | 1.2 % | 5 frames (83 ms) |
| live action | 16,000 | 98.4 | 85.2 | 67.9 | 0.7 % | 3 frames (50 ms) |
| animated | 3,000 (default) | 93.6 | 72.0 | 41.2 | 2.7 % | 9 frames (150 ms) |
| animated | 10,000 | 96.3 | 89.1 | 53.3 | 0.5 % | 2 frames (33 ms) |
| animated | 16,000 | 96.8 | 92.8 | 74.6 | 0.3 % | 1 frame (17 ms) |

**Steady scenes look the same at every rate** (a typical frame scores 91-97 at all three);
**the rate decides how badly a scene cut or a burst of motion breaks up and how long the
picture stays soft** -- with a one-frame VBV there is nowhere to borrow bits from. The big
step is 3 → 10 Mbit/s requested; 10 → 16 is a smaller one. Film is not a game (games have
sharper edges, HUD text and more constant motion: the low rate looks worse there, not
better). The side-by-side crops, the per-frame curves and a 2x2 comparison video were
shown to the maintainer (an artifact page; the video is local, not committed).
