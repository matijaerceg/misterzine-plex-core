# References

## The formats

- **ITU-T H.264 / ISO/IEC 14496-10** — the spec. Main (§A.2.2) and High (§A.2.4)
  profiles, Table A-1 (levels), CABAC (§9.3 incl. the context init tables and
  `rangeTabLPS` Table 9-44), the display process and `pic_struct` (§D.2.3), Annex B byte
  streams. Free from ITU-T.
- **ITU-T H.264.1** — the conformance specification: which streams a decoder of a given
  profile must decode.
- **AAC** (ISO/IEC 14496-3) and **Opus** (RFC 6716, with its test vectors in RFC 8251) —
  only if decision D2 puts an audio decoder in fabric (`roadmap.md`).
- **MPEG systems** (ISO/IEC 13818-1) — for the 33-bit, 90 kHz PTS convention the HPS
  interface keeps. Container parsing (TS, MP4, RTP) is the ARM program's job, not this
  core's.

## Papers the decoder was sized against (UMD's; they apply unchanged)

- L. V. Agostini et al., *Design and FPGA Prototyping of a H.264/AVC Main Profile Decoder
  for HDTV*, 2007. Module architectures and per-module resource figures on a Virtex-II
  Pro.
- A. Petrovsky, A. Stankevich, A. Petrovsky, *Pipeline processing in real-time of CABAC
  decoder based on FPGA*, ICSES 2012. A complete CABAC decoder at 1 bin/cycle, 96 MHz,
  12.6K LUTs on a Virtex-6 — relevant again at game-stream bin rates.
- K. Xu, *nova: a H.264/AVC Baseline Decoder*, 2008 (opencores). 204 cycles / MB with
  4-pixel column parallelism and a 4x16 "hybrid pipeline" — the reference point for
  Phase 5's throughput work. **No licence in its repository: ideas only, no code.**
- D. Marpe, H. Schwarz, T. Wiegand, *Context-Based Adaptive Binary Arithmetic Coding in
  the H.264/AVC Video Compression Standard*, IEEE TCSVT 13(7), 2003.

## The local reference set: `$H264_REFS_DIR` (default `~/h264-refs`)

Third-party material is never committed; benches and tools find it through
`${H264_REFS_DIR:-~/h264-refs}` and SKIP loudly without it. It is the same set UMD uses
(`$UMD_REFS_DIR` there): point both variables at one directory.

| path | what |
|---|---|
| `T-REC-H.264-202606.pdf` | the spec; CABAC tables are transcribed from here, never from memory |
| `T-REC-H.264.1-201602.pdf` | the conformance spec |
| the two FPGA papers above, `nova/` | |
| `JM/` | JM 18.4 (FRExt); UMD's `tools/jm_build.sh` builds the `TRACE 1` decoder and `lencod` (Phase 2 brings the script) |
| `ffmpeg/libavcodec/h264_cabac.c` | the cross-check for the CABAC table transcription (LGPL, never copied) |
| `H.264.1_bitstreams/AVCv1/` | the Main-profile conformance package UMD graded against |
| `H.264.1_bitstreams/FRExt/` | the High (FRExt) conformance package, added for Phase 5 (D1): the CABAC 4:2:0 8-bit streams are the High oracle (`h264_conformance.py --pkg FRExt`); the MBAFF, CAVLC, 4:2:2, 10-bit and monochrome ones are refused by name |

## Oracles and tools

- **ffmpeg / ffprobe** — H.264 decode (the bit-exact reference for reconstruction), header
  traces (`-bsf:v trace_headers`), x264 (`libx264`) to make fixtures at run time.
- **JM reference software** (`ldecod`) — syntax-element traces, the only decoder that has
  them.
- **Moonlight / Sunshine**, **Plex / Jellyfin** — the hosts whose streams Phase 1 captures.

## MiSTer

- **MiSTer_UMD_Video** — the project this core was forked from: the decoder, the display
  path, the framework edits, the gates, the process (`harvest.md`).
- **MiSTer_DVD** — UMD's own source for its plumbing and process.
- Template_MiSTer and Main_MiSTer (`hps_io`, `user_io.cpp`, `menu.cpp`, `mra_loader.cpp`
  for the MGL rules, `fpga_io.cpp` for the core load sequence), mister-devel's MkDocs
  documentation.
- Quartus 17.0.2 via `raetro/quartus:mister`.
