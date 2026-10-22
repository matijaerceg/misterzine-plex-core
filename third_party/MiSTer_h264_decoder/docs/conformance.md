# Conformance matrix

The durable "what is correct / what is missing" map. Each row marks a feature
*implemented / partial / missing* with the reference oracle for it. Keep it current in
the same change that closes a gap (the stale-marker rule).

Legend: ✅ implemented and gated · 🔧 partial · ❌ missing · ⛔ deliberately out of scope ·
📐 golden only (the offline oracle exists and is gated; the fabric does not yet) ·
🔀 exists in UMD, arrives with the fork (Phase 2) -- none left since the Phase 2 harvest

## How to use the oracles

Verify in increasing order of authority and cost. "ffmpeg does X" is a hypothesis to
check against the spec, not a conclusion; but for reconstruction ffmpeg is bit-exact by
the standard's own definition and is the gate.

1. **ffmpeg / JM** — executable baselines: pixels (bit-exact), syntax-element traces.
2. **The spec** (H.264) — for anything the oracle and the RTL disagree on.
3. **Captured host streams** (Phase 1) — what Sunshine / NVENC / Plex actually send.

## Rows

| area | feature | status | oracle |
|---|---|---|---|
| output | 720x480p raster, HDMI | ✅ (P0: `sync_gen_tb`) | CEA-861 timing, measured |
| output | idle screen | ✅ (P0: `idle_bars_tb`) | EIA-189-A bar order |
| input | the HPS ring, records, flags | ❌ Phase 3 | a Python model of the producer |
| video | NAL / SPS / PPS / slice header / SEI / VUI, Main | ✅ (P2: `run_h264_top.sh`, x264 + CABACI3, CAWP5, Sharp_MP_PAFF_2r, CAPM3, CAFI1, camp_mot_fld0_full) | JM trace; ffmpeg `trace_headers`; H.264.1 Table 1 |
| video | CABAC, every Main SE | ✅ (P2: `run_h264_cabac.sh`, `run_mb_syntax.sh` incl. field slices) | JM trace; the conformance traces |
| video | intra, inter, weights, deblocking, DPB, output order, PAFF | ✅ (P2: `run_recon_top.sh` -- x264, CAFI1, camp_mot_fld0_full, CAPA1, CAWP5, CABREF3, JM control-path streams; `run_cosim.sh` -- two x264 480p60 windows, camp_mot_fld0_full, CAPA1 whole, `--sweep`: all 32 AVCv1 CABAC packages in scope bit-exact, the 25 MBAFF / CAVLC ones refused; UMD had 88 of 89 disc images bit-exact) | ffmpeg pixels; H.264.1 YUVs |
| video | High profile: 8x8 transform, intra 8x8, scaling matrices | ✅ (P5a, PR fj#5, `high_profile.md`): `run_h264_top.sh` / `run_mb_syntax.sh` (x264 High, FRExt3, HPCALQ, HCAFF1 fields), `run_dequant_itrans.sh`, `run_intra_pred.sh`, `run_mb_intake.sh`, `run_recon_top.sh` (5 x264 High clips; FRExt3_Panasonic_E, HPCALQ, HPCAQ2LQ, HCAFF1, HPCAFL, HCAFR1 pixel-exact); monochrome refused (`REF_CHROMA`, to decide) | ffmpeg; JM; the H.264.1 FRExt package (in the reference set since Phase 5) |
| video | 480p60 in real time | ❌ Phase 5 (P2 cosim: 1,237 cycles / MB on a Sunshine-shaped 8 Mbit/s window; ≤ ~935 needed) | the cosim's cycles / MB; the rig |
| video | CAVLC / MBAFF / FMO | ⛔ refused loudly by the fabric (as UMD; `run_h264_top.sh`'s refusal arms) -- no Phase 1 capture uses them | ffmpeg `trace_headers` |
| video | CAVLC through the client library's rewrite (fj#20, `cavlc.md`) | 🔧 `feature/cavlc`: `run_cavlc.sh` -- every rewritable CAVLC stream of AVCv1 (70) bit-exact against ffmpeg and the reference YUVs, x264 / JM / synthetic High CAVLC; FMO / ASO / redundant / DP / SP-SI / MBAFF refused by name; up to ~4-5 Mbit/s at 480p60 on the A9 | ffmpeg pixels; H.264.1 YUVs; the project's CABAC model |
| display | output order, `pic_struct` pacing, Weave / Bob / Blend | ✅ (P2: `run_recon_out.sh`, `run_disp_sched.sh`, `run_disp_reader.sh`) | UMD's scheduler model; ffmpeg `interlace` / `separatefields` |
| display | LOW_LATENCY presentation | ❌ Phase 3 | — |
| display | PAL raster; exact aspect; 480i | ❌ Phase 6 | — |
| audio | PCM records against the STC | ❌ Phase 4 | a phone video, then an instrument |
| audio | AAC-LC / Opus in fabric | ❌ D2 undecided | ffmpeg, libopus, ISO / RFC vectors (bounded error) |
