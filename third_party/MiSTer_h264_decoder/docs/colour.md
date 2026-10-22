# F2 — The colour matrix and range (interface 0.16)

Engineering note. Status: **built, fitted (SEED 13 PASS), pixel-exact on the rig and ✅ HW-CONFIRMED 2026-10-07**
(the maintainer's round on .201 with the 0.16 set: good); ✅ MERGED (PR fj#41). The interface: `architecture.md` "The colour (interface 0.16)". Origin: the
Jellyfin client's finding F2 (`jellyfin.md` §7); a 1.0 blocker (roadmap Phase 7: the first
release is 1.0 and freezes the interface).

## 1. The problem

The display converts every picture with **BT.601, limited range**, hard-wired:
`h264/disp_reader.sv` stages 6-8 on clk_vid (`R = (298 C + 409 E + 128) >> 8`, ...; `C = Y - 16`,
`D = Cb - 128`, `E = Cr - 128`; Q8, one rounding, a clamp). The decoder parses the SPS's VUI
colour fields (`sps_pps.sv`, field ids 106-112) and drops them in `recon_hdr.sv`'s `default` arm.
What the sources send (measured 2026-10-06 with ffprobe on the captures in `.sim/`):

| source | tags | today |
|---|---|---|
| Sunshine (Moonlight), 480p | BT.601 (`smpte170m`), limited | right |
| the Jellyfin server's QSV transcodes (852x480, 640x480 from 1080p sources) | BT.709, limited | **reds and greens shifted** |
| 720p files and streams (x264, NVENC) | usually untagged; meant as BT.709 by every player's convention | **shifted** |
| x264 / JM fixtures | untagged | right (SD) |
| full-range H.264 (`video_full_range_flag` 1; the conformance-style `h264top_vmax` fixtures) | full | **crushed / clipped** |
| the ARM's pictures (0.15 PICTURE: MJPEG / webcams full range) | the library converts full -> limited on the ARM (~8 ms at 640x480) | right, at a CPU cost |

Moonlight's client never sets `colorSpace` / `colorRange` (zero: moonlight-common-c's
`COLORSPACE_REC_601`, `COLOR_RANGE_LIMITED`), so Sunshine sends 601 at every size, 720p included.

The analog outputs need nothing: `sys/vga_out.sv` (YPbPr) and `sys/yc_out.sv` (S-Video /
composite) re-encode the core's RGB with BT.601, which is the SD analog standard; RGB is the
shared intermediate, so a 709 source decoded to RGB with 709 and re-encoded with 601 is the
correct round trip. ascal and HDMI are RGB.

## 2. Decisions (the maintainer, 2026-10-06)

- **D-C1 -- untagged by size.** A stream with no colour description (or `matrix_coefficients` 2,
  "unspecified") is BT.709 when its shown picture is **at least 1,280 wide or more than 576
  high** (mpv / libplacebo's rule), else BT.601. The cropped size (what is shown), not the coded
  one. Every SD picture keeps today's colours; a 720p file shows what its author saw. (A
  2048x448 picture is "HD" by width: the rule is a convention, and the tag or the program
  overrides it.)
- **D-C2 -- the range too.** `video_full_range_flag` is honoured (absent: limited, H.264 E.2.1's
  default). One mechanism for both.
- **D-C3 -- the program's override is a record field**, not a CONTROL record: a 3-bit `colour`
  code in the record header's word 1 [35:33] (zero until 0.16, checked), on VIDEO_AU and PICTURE
  alike (`architecture.md` "The colour"). Header word 1 rather than flag bits 5-7: the flags stay
  free for later minors after 1.0. A combined code rather than two fields: a program that knows
  one knows both (ffmpeg reports both).
- **D-C4 -- no OSD option.** Auto is right when the tags are; the program covers a mis-tag. (The
  OSD's mirror and request words have no spare room either.)

Decided in this design (recorded for review at the merge):

- **D-C5 -- three matrices: BT.601, BT.709, BT.2020 (non-constant luminance).** Table E-5's
  `matrix_coefficients`: 1 -> 709; 5, 6 -> 601; 9 -> 2020; 4 (FCC) -> 601 and 7 (SMPTE 240M) ->
  709 as approximations (their Kr / Kb within 0.01 of those); 2 and 3 (reserved) -> the size rule.
  **0 (GBR), 8 (YCgCo), 10 (BT.2020 constant luminance) and 11 and above are not supported**: the
  size rule, and counted (`colour_unsup`, word 86) -- never silent. A third constant set costs
  only mux inputs; 8-bit 2020 SDR is legal High profile.
- **D-C6 -- the matrix only, no primaries or transfer conversion.** `colour_primaries` and
  `transfer_characteristics` are reported (word 86), not applied: 601 and 709 primaries differ
  slightly and every SD display shows them alike; a BT.2020 picture shows with the right matrix but
  undersaturated on a 709 display (no gamut mapping). Listed in `spec_hardening.md` "Known
  deviations".
- **D-C7 -- per stream for VIDEO_AU, per picture for PICTURE.** A VIDEO_AU's `colour` is taken
  from each stream's first VIDEO_AU, as LOW_LATENCY and GRAPHICS are; a later VIDEO_AU that
  disagrees is counted (`colour_mismatch`, word 86), never obeyed. (Per access unit would need the
  code to ride through the decoder to its picture, as the PTS does: no client needs it.) A
  PICTURE's applies to that picture.
- **D-C8 -- the library passes full range through.** `h264ring_picture_copy()` stops converting
  full range to limited (YUVJ420P / YUVJ422P) and sets the record's `colour` instead -- the
  camera viewer's copy loses the conversion's ~8 ms (CPU0 at 0.724 today, `uvc.md`). Last step;
  measured on the rig.

## 3. The coefficients

Derived from Kr / Kb by E.2.1's equations, `tools/colour_ref.py` (step 2): `C = Y - Yoff`;
`R = (Kc C + Krv E + 128) >> 8`, `G = (Kc C - Kbg D - Krg E + 128) >> 8`, `B = (Kc C + Kbb D + 128)
>> 8`; Q8, rounded to nearest.

| code | set | Yoff | Kc | Krv (Cr->R) | Kbg (Cb->G) | Krg (Cr->G) | Kbb (Cb->B) |
|---|---|---|---|---|---|---|---|
| 1 | BT.601 limited | 16 | 298 | 409 | 100 | 208 | 516 |
| 2 | BT.601 full | 0 | 256 | 359 | 88 | 183 | 454 |
| 3 | BT.709 limited | 16 | 298 | 459 | 55 | 136 | 541 |
| 4 | BT.709 full | 0 | 256 | 403 | 48 | 120 | 475 |
| 5 | BT.2020 limited | 16 | 298 | 430 | 48 | 167 | 548 |
| 6 | BT.2020 full | 0 | 256 | 377 | 42 | 146 | 482 |

Code 1 is today's integers: **every picture that resolves to 601 limited is bit-identical to
main** (the regression gate, §5). The same codes are the record's `colour` (0 = auto, 7
reserved) and word 80's `colour` (the shown picture's).

## 4. The path

1. **The decoder:** `recon_hdr` keeps the SPS's `video_full_range_flag`, `colour_description
   _present_flag`, `colour_primaries`, `transfer_characteristics`, `matrix_coefficients` -- **in a
   table of its own** (32 SPS ids x 26 bits, beside `sps_ram`), not in `sps_t`: `sps_t` is also the
   front end's `sps_mem`, which never reads them. Reset to E.2.1's defaults (2, 2, 2, limited, not
   present) at each SPS's start, written with it, read with the active SPS. `recon_top` resolves
   the picture's code at `pinfo_aspect`'s point (the stream's `colour` when non-zero, else the VUI,
   else the size rule on the cropped size) into `pinfo_colour` [2:0] and an unsupported bit.
   **The stream's `colour` binds exactly:** `ring_rd` (clk_sys) latches it at the stream's first
   VIDEO_AU, which it parses only after the per-stream reset (`stream_clr`, then the settle) has
   emptied the decoder -- so every picture `recon_top` opens afterwards is that stream's, even
   across a gapless DISCONTINUITY. It crosses to clk_dec as a quasi-static value (stable from
   long before the stream's first picture opens), bounded in `h264.sdc`.
2. **The record:** `ring_rd` takes the header's `colour` (7, or non-zero on a PAD / AUDIO:
   error 17 `HDR_COLOUR`); a VIDEO_AU's is latched per stream, a PICTURE's goes with its
   descriptor and `pic_in` resolves 0 by the size rule.
3. **To the display:** beside the aspect -- `pic_in`'s mux, `recon_out`'s per-store `tab_a` (202 ->
   232 bits: the code, the unsupported flag and the 26-bit description; still six M10K), `disp_ctl`
   (`sh_colour`, `sh_col_tags`, `n_col_unsup` counted at the pickup) -- then the code across to
   clk_vid in the raster bundle `xdn_src` (`cdc_snap`, bounded by its module). The description travels
   with the picture rather than crossing clk_dec -> clk_sys on its own: status words 80-87 are clk_sys's,
   and word 86 then describes the picture word 80's code belongs to.
4. **`disp_reader`:** a coefficient set chosen by the code, registered **at the picture's first
   line** (never mid-picture), feeding the existing stage-6 products. The constants become a
   6-way mux (a case, not a multiply by a selected constant inside the product's cone); `p_c`
   and `p_dcb` (shift-adds today) become multiplies: +1-2 DSP of 10 left. `tools/synth_unit.sh`
   on `disp_reader` before a fit.
5. **Status:** word 80 [31:29] `colour` (the shown picture's code; 1 before any picture); word 86
   the shown picture's tags as coded and the two counters (`architecture.md`).

## 5. Verification

- **The SD equivalence gate:** `run_vid_equiv.sh` against main -- untagged SD and the Sunshine
  601 captures bit-identical at the pins.
- **`run_disp_reader.sh`:** arms per code (each set's pixels against `tools/colour_ref.py`, which
  derives the integers from Kr / Kb independently of the RTL, and within 1 of a float model);
  the latch (a code change lands at a picture's first line); mutations per coefficient and per
  code. **D1 today greps the literal `p_ecr <= 20'sd409 * e2;`** -- retargeted in the same
  commit, or it silently stops mutating.
- **`tools/disp_golden.py`** takes the code (default 1: unchanged goldens).
- **The decoder:** `run_recon_top.sh` / `run_h264_top.sh` arms on x264 fixtures tagged with
  `--colormatrix` / `--range` (601, 709, 2020, fcc, 240m, GBR, YCgCo, full), the code and the
  counters scored; `h264top_vmax.264` (range pc) now resolves full -- its display arms re-checked.
- **The interface:** `run_ring_rd.sh` (the field's checks, PICTURE's code), `run_scaffold.sh`
  (word 80 / 86), the library tests, `red_h264.py` mutations.
- **The rig:** the Jellyfin transcode and a 720p file against ffmpeg's RGB (a capture through the
  HDMI card, the colour bars of a tagged synthetic stream: one per code).

## 6. R4: what the server's transcodes really are (measured 2026-10-06)

`hdmi_raster.md` §9 expected "an SD source transcoded is probably tagged 709 over 601 pixels".
**Measured on the maintainer's server** (QSV, Jellyfin 10.11; the rig client's sign-in and its
own device profile, PlaybackInfo with direct play and direct stream off, the first two HLS
segments ffprobed): of the library's 522 SD items (H.264 untagged 189, tagged BT.709 105, tagged
BT.601 60; HEVC, MPEG-4 ASP and DivX 3 mostly untagged), **one transcode of each kind -- every one
tagged BT.709** (primaries, transfer and matrix), limited range, whatever the source said.

**The pixels are not converted.** A BT.601-tagged 720x480 H.264 source against its transcode
(same size and rate, frames aligned by index, 100 frames): on the source's saturated chroma
(241,756 samples) the transcode's Cr differs from the source's **as it is by 0.27** on average,
and from the source **converted 601 -> 709 by 1.86**; chroma PSNR 72.4 dB as-is vs 68.1 converted.
The server relabels: an SD source's transcode is **BT.601 pixels tagged BT.709**; an HD source's
(709 pixels, downscaled) is tagged right.

**So the Jellyfin client overrides on a transcode** (step 6): `colour` from the SOURCE's
`MediaStreams` entry -- `ColorSpace` bt709 -> 3; smpte170m / bt470bg -> 1; absent -> the size
rule on the source's size (an untagged 1080p film 3, an untagged DVD rip 1); `VideoRange` /
full range as the source says. Direct play: 0 (auto: the file's own tags).
The probe was a scratch script; the sign-in it used never left the workstation and was deleted after.

## 7. Steps

1. ✅ The design (this note, `architecture.md`), with the maintainer's choices D-C1-D-C4 (and D-C5-D-C8,
   accepted 2026-10-06).
2. ✅ `tools/colour_ref.py` + `disp_golden.py`'s code; `disp_reader` the six sets, the latch;
   `run_disp_reader.sh` arms + mutations (C1-C8, D1 retargeted).
3. ✅ The decoder's VUI fields (`recon_hdr`'s side table), `recon_top`'s resolution, the path to the display,
   the CDC (two flops + `h264.sdc`).
4. ✅ The interface: `ring_rd` (word 1 [35:33], error 17), `pic_in`, words 80 / 86, `ring_layout.py`, the
   library (`h264ring_set_colour()`, `struct h264ring_picture.colour`, D-C8), 0.16 in the manual.
5. ✅ The gates, 2026-10-07: GREEN and `--red` -- `run_disp_reader.sh` (55 arms; K10 / R3 / T5's anchors
   repaired, R3 / T5 stale on main since the Area retime), `run_ring_rd.sh` (35 scenarios, C1-C10),
   `run_recon_top.sh` with the conformance and JM sets (20 colour clips, CL1-CL12), `run_scaffold.sh`,
   `tools/tests` (red_h264: three library mutants), the clients' host tests, `run_disp_sched.sh` (78 runs)
   and `run_cosim.sh` with the reference set; **the SD equivalence gate**
   (`run_vid_equiv.sh`): every 27 MHz raster's pins identical to main's at code 1. **The fit**: SEED 13
   103.52 / 101.71 PASS after `recon_hdr`'s retime (26 seeds before it short of the gate:
   `history.md` §39), `H264_colour_20261007_1245.rbf`.
6. ✅ The clients: the player (`vdec_colour()`: ffmpeg's colorspace / range for the ARM codecs; H.264 auto),
   Jellyfin's override from R4 (`jf_source_colour()`), the camera's MJPEG tagged full (D-C8); Moonlight auto;
   `h264play --colour N`.
7. ✅ The rig (.201, 2026-10-07, `history.md` §39): every code pixel-exact against `colour_ref.py` on
   ffmpeg's decode (SD unspecified / 709 / 601 full / 709 full / 2020, 720p unspecified by size), the
   override exact. ✅ The maintainer's round on .201 (2026-10-07, the 0.16 core and clients installed, the
   0.15 set kept as `*.iface0_15`): good -- and the Jellyfin ready card's clipped "MiSTer" found and fixed
   (the card's line wraps: `player.md`).
