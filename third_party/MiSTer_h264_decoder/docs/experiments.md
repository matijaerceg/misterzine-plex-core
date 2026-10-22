# Experiments / speculative ideas

A parking lot for ideas that are **not** committed roadmap items. Committed work lives in
`roadmap.md`; this file is for the maybes. Move an item over once it is decided, or delete
it if ruled out. Keep the technical reasoning so a later session does not re-derive it.

---

## A branded idle screen

The scaffold's idle screen is colour bars with a moving marker (`h264/idle_bars.sv`):
honest, cheap (32 ALM), and a liveness instrument. A logo or an animated screen is
cosmetic; if one comes, keep a moving element so a screenshot pair still answers "is
the machine frozen?".

## 720p and 1080p from a media server (Jellyfin / Plex)

Asked 2026-09-27: would a 720p or 1080p stream from Jellyfin play? Not measured -- an
estimate from Phase 1's numbers and UMD's code. Decided at the time: **not a target**; the
practical path is transcoding (below).

**Throughput** (macroblocks a second, the decoder's load; cycles a macroblock allowed at
81 MHz, against the D1 target of ~1,001 at 480p60 and 1,186 measured on Main today):

| stream | MB/s | vs the 480p60 target | cycles / MB allowed |
|---|---|---|---|
| 480p60 (D1) | 81,000 | 1.0x | ~1,001 |
| 720p24 | 86,400 | 1.07x | ~937 |
| 720p30 | 108,000 | 1.33x | ~750 |
| 1080p24 | 195,840 | 2.4x | ~413 |
| 1080p30 | 244,800 | 3.0x | ~330 |

- **720p24 is in the same range as D1's target**, and a 720p24 file at 4-8 Mbit/s carries
  fewer bits a macroblock (~50-90) than the 10 Mbit/s 480p60 case (~95), which moves it
  toward the cheaper end of `p1_measurements.md` §3. Plausible once Phase 5 meets its
  target; 720p30 needs a third more again.
- **1080p24 needs 2.4x the target's macroblock rate** (~3x today's decoder): far beyond
  Phase 5's ~1.27x, a much wider pipeline than the area budget allows for.

**What blocks it regardless of throughput** (read in UMD at the fork, `75e3f37`):

- **DPB store size:** a store is `base + store << 17` 64-bit words = **1 MiB**
  (`recon_inter.sv`, `disp_reader.sv`). 720x576 fits (0.6 MB); 720p (1.4 MB) and 1080p
  (3.1 MB) do not. An address-layout change (DDR3 has room: 20 stores of 4 MiB is 80 MB),
  but every client of the layout changes with it.
- **Width:** the front end takes up to 128 macroblocks a side (2,048 px; `h264_pkg.sv`,
  `mb_syntax`'s line memory), so 1080p's 120 fits there; the reconstruction's row buffers
  are not checked.
- **Display:** the raster is 720x480. 720p would need a downscaler in the display path
  (or an HD raster: a new pixel clock, display-reader bandwidth on ram2); a CRT needs the
  downscale either way.
- **Level:** 1080p is Level 4.0 / 4.1 (larger MaxFS / MaxDpbMbs; direct-play files at
  10-40 Mbit/s, often with B-frames and more references) -- refusals past the fabric's
  limits must stay loud (`spec_hardening.md`).

**The practical path: transcoding, not direct play.** A Jellyfin / Plex client declares
what it can play (a device profile: codec, profile, level, resolution, bitrate) and the
server transcodes whatever exceeds it -- most clients rely on this. A MiSTer client
declares "H.264 High, up to 720x480 / 576, ~10 Mbit/s" and receives a stream inside D1's
envelope; a 1080p source is downscaled on the server, which for a 480-line output loses
nothing. 720p24 direct play is the one stretch worth revisiting after Phase 5 shows where
throughput lands (with the store-size and display items above as its cost).

## HEVC / AV1

Many hosts can send them, and they save bandwidth. Out of scope: a different decoder of
several times the area. Recorded so the question is not re-asked. In software on the A9 they
are out of reach too (measured 2026-10-03, below: HEVC 1.4 cores at 480p30, AV1 / VP9 ~0.8-0.9).

## Other codecs decoded on the ARM (measured 2026-10-03)

**Taken up 2026-10-05** (`docs/player.md` P7, interface 0.15's PICTURE record: the decoded picture written into a DPB
store and shown by the core): the file player decodes the comfortable set below at SD. The rest of this section is the
measurement it was decided on.

Asked 2026-10-03: which codecs besides H.264 could a player support by decoding on the ARM?
**Measured on the rig (.201)**, FFmpeg 8.0.3 built static for the A9 with NEON (the clients'
image `mister-h264-clients:deps2`, ad hoc; dav1d 1.5.1 for AV1), `-threads 1`, one 10 s clip per
row cut from the Phase 1 source (`.sim/p5b/src60_10s.mkv`, real content), encoded on the host.
Metric: **CPU seconds a second of video** (utime + stime / duration) = the share of ONE A9 core
it needs -- FFmpeg 8 runs demux, decode and filter in separate threads, so wall time hides cost.
Main holds the other core: `-threads 2` gave H.264 720p 16.5 -> 15.0 s, HEVC 34.7 -> 30.0 s.
"+ BGRA" adds swscale's conversion to the overlay's `8888` (written to null, not to `/dev/fb0`).

| clip | Mbit/s | decode | + BGRA |
|---|---|---|---|
| MPEG-2 480p30 (two rates) | 2.5 / 3.3 | 0.22 / 0.27 | 0.34 / 0.38 |
| MPEG-2 480i (field-coded DCT / ME, two rates) | 3.2 / 4.4 | 0.24 / 0.28 | 0.36 / 0.40 |
| MPEG-2 854x480p60 | 3.8 | 0.46 | 0.98 |
| MPEG-2 720p30 (two rates) | 3.8 / 4.4 | 0.51 / 0.52 | 0.79 / 0.81 |
| MPEG-4 Part 2 (Xvid, B-frames) 480p30 | 1.5 | 0.28 | 0.40 |
| MPEG-4 Part 2 (Xvid) 720p30 | 3.6 | 0.71 | 0.99 |
| MS-MPEG4 v3 (DivX 3) 480p30 | 1.6 | 0.22 | 0.33 |
| WMV8 (`wmv2`) 480p30 | 1.6 | 0.34 | 0.45 |
| Theora 480p30 | 2.0 | 0.27 | 0.39 |
| MJPEG 480p30 (q 5) | 4.9 | 0.29 | 0.40 |
| VP8 480p30 / 720p30 | 2.1 / 4.2 | 0.47 / 1.14 | 0.59 / 1.42 |
| VP9 480p30 / 720p30 (libvpx `-cpu-used 4`) | 1.6 / 3.0 | 0.78 / 1.79 | 0.90 / 2.07 |
| AV1 480p30 / 720p30 (SVT-AV1 preset 8; dav1d) | 0.9 / 1.7 | 0.83 / 1.79 | 0.94 / 2.09 |
| HEVC 8-bit 480p30 / 720p30 (x265 medium) | 1.6 / 3.1 | 1.40 / 3.46 | 1.50 / 3.73 |
| *H.264 High 480p30 / 720p30 (x264 medium), for scale* | 2.0 / 3.9 | 0.66 / 1.64 | 0.78 / 1.94 |

The budget: one core, less the rest of a player (5.1 audio ~0.07, `jellyfin.md` R2; demux, UI),
so **decode plus delivery under ~0.7**. Reading:
- **Comfortable at SD (<= 720x576, <= 30 frames/s, interlaced included), either path below:**
  MPEG-1 / MPEG-2, MPEG-4 Part 2 (Xvid / DivX 4-6), DivX 3, WMV7 / 8, Theora, MJPEG (and
  H.263, the same decoder family as MPEG-4 Part 2; not measured on its own).
- **Marginal at SD:** VP8 (0.47 decode, 0.59 converted).
- **720p30 and 480p60: MPEG-2 and MPEG-4 Part 2 only, and only without the RGB conversion**
  (0.5 / 0.7 decode alone). The 854-wide conversion cost twice what 720p's did per pixel --
  swscale's NEON path probably not taken at that width (not investigated).
- **Not realistic:** VP9, AV1, HEVC at these sizes (0.8-1.4 of a core at 480p30 before
  anything else; 1.8-3.5 at 720p30).
- **Not measured:** VC-1 / WMV9 (no encoder on the host; FFmpeg's `vc1` / `wmv3` decoders are in
  the binary if a sample turns up), 10-bit anything.

Caveats: one source, which compresses easily (MPEG-2 undershot its 6 Mbit/s target even at q 2;
a real DVD at 5-9 Mbit/s costs a few hundredths more, extrapolating 2.5 -> 3.3 Mbit/s: +0.05);
the A9's clock assumed 800 MHz (not readable from sysfs on MiSTer Linux); the write into
`/dev/fb0`, which may be uncached, not included.

**The delivery path is the real decision.** Audio needs nothing new (the ARM already decodes
it and the core presents PCM, D2). The picture has two routes:
1. **The overlay plane** (`/dev/fb0`, interface 0.9): no RTL. But it is RGB (the conversion
   above, ~0.11 of a core at SD, ~0.3 at 720p), identity-mapped and centred on the raster (the
   ARM must scale anything not raster-sized: 720p on a 480-line raster is out), and it gets
   none of the core's fitting, deinterlacing or STC-paced presentation (the program times its
   own page flips against the status block). It IS anti-twittered at 480i under Auto / On --
   which would soften video (`player.md` §5 said it bypassed anti-twitter; corrected 2026-10-03).
2. **A raw-picture record** (YUV 4:2:0 from the ARM, presented by the core like a decoded
   picture, into a store the display reads): an interface change and RTL in the parser and
   display path, and the store layout the ARM must write. It skips the conversion and gets
   fitting, deinterlace, anti-twitter by the content flag and A/V sync for free; 720x480 at 30
   is ~15.5 MB/s through `ram1` (720p30 ~41 MB/s), with the decoder idle meanwhile. The right
   shape if this is ever taken up, and the only one that reaches 720p30 / 480p60 MPEG-2.

### Writing a picture into the stores (measured 2026-10-05, step 0 of `feature/arm-codecs`)

The ARM-decoded picture is copied into a DPB store through `/dev/mem`. On MiSTer Linux
(`mem=511M memmap=513M$511M`, no CMA, no uio) the FPGA region is not System RAM, so the kernel maps
it **strongly ordered** whatever the open flags: every store waits for the bus. Measured on .201
(menu core loaded, nothing else running) with a throwaway static tool, one 2 MiB store at
`0x3460_0000`, 10-30 repetitions, every copy verified:

| writer | into a store (`/dev/mem`) | into `/dev/fb0` (write-combined) |
|---|---|---|
| aligned 64-bit loop (`strd`) | 97 MB/s | 450-490 MB/s |
| `ldm`/`stm`, 32 bytes | 88 MB/s | 475-527 MB/s |
| NEON `vst1.64`, 64 bytes | 88 MB/s | 482-521 MB/s |
| glibc `memcpy` | 96-99 MB/s | 600-727 MB/s |

The store copy is CPU-bound (CPU time = wall time): **5.3 ms a 720x480 I420 picture, 14.2 ms a
1280x720** -- 0.16 of a core at 480p30 / 576i25, ~0.38 at 854x480p60, ~0.43 at 720p30. With the
decode costs above and ~0.1 for audio, demux and UI against a ~0.8 budget: every SD case fits (DVD
480i at 9.5 Mbit/s 0.68, Xvid 480p 0.54), MPEG-2 720p30 (1.05) and 480p60 (0.94) do not. **Decided
2026-10-05 (the maintainer): the ARM path is SD only in v1** (<= 720x576, <= 30 frames/s).

`/dev/fb0` is the only write-combined memory a program can map (the fb driver), ~6x faster; a
later extension could hold ARM pictures there behind a second picture base in `disp_reader`, but
its size follows Main's HDMI mode (1.4 MB at a 480p mode: one 720p picture), so it would work only
with some `MiSTer.ini` setups. (The fb0 rows' verify saw 512 bytes rewritten at one offset on
every pass: fbcon's cursor, which `h264ring_fb_map` quiets and this tool did not.)

**Revised 2026-10-06 (`docs/uvc.md` U2a):** the copy of a **full-range or 4:2:2** picture cost far more
than the limited 4:2:0 rows above -- 14.3 ms a 640x480 full-range 4:2:2 picture (a table lookup and a
clamp per sample) -- and is now 8.15 ms (a clamp-free interior, NEON on the ARM, same bytes).

### MPEG-2's ceiling and ATSC (measured 2026-10-03)

Same method, five more MPEG-2 clips with film grain added (`noise=alls=10`) so the bitrates
are reached: 480i at DVD's maximum, 720p60 at three broadcast rates, 1080i at ATSC's 19.4.
`-lowres 1` is FFmpeg's half-resolution decode (the IDCT and motion compensation at half size,
720p -> 640x360; the bitstream parsing is unchanged).

| clip | decode | + BGRA | lowres 1 | lowres 1 + BGRA |
|---|---|---|---|---|
| 480i, 9.5 Mbit/s | 0.42 | 0.54 | 0.31 | 0.38 |
| 720p60, 8 Mbit/s | 1.02 | 1.60 | 0.66 | 0.83 |
| 720p60, 13 Mbit/s | 1.24 | 1.81 | 0.81 | 0.99 |
| 720p60, 19 Mbit/s | 1.42 | 1.99 | 0.95 | 1.12 |
| 1080i (60 fields), 19 Mbit/s | 1.46 | 2.06 | 0.96 | 1.12 |

`-threads 2` on the 720p60 19 Mbit/s clip: 14.5 -> 14.0 s (Main's core is not available).
A fit of the rows: ~0.013 of a core per Mpixel/s plus ~0.036 per Mbit/s -- at high rates the
serial bitstream parsing dominates, which is why `lowres` saves only about a third.
- **MPEG-2's realistic ceiling (decode only, under ~0.7):** SD at any DVD or broadcast rate;
  480p60 and 720p30 up to roughly 9-10 Mbit/s. **720p60 and 1080i: no** at full size (1.0-1.5
  cores), and with `lowres` only 720p60 at about 8 Mbit/s or less, shown at 640x360.
- **ATSC 1.0** (MPEG-2 in a transport stream, AC-3 audio): the 480i subchannels decode
  comfortably; the HD main channels (720p60, 1080i) do not. **ATSC 3.0** is HEVC + AC-4 (and
  often encrypted): out.
- **Input:** an HDHomeRun is an HTTP MPEG-TS stream, which the clients' FFmpeg already demuxes
  (`http`, `mpegts`, `ac3`). A USB tuner is not an option on stock MiSTer Linux: its kernel
  (6.18.38-MiSTer) is built with `CONFIG_MEDIA_SUPPORT` unset -- no DVB core, no drivers.
- **The practical route for HD channels:** a server (Jellyfin / Plex Live TV, Channels DVR,
  Tvheadend) transcodes the tuner's MPEG-2 to H.264, which the core decodes; 480p60 keeps the
  60 Hz motion and is D1's own target. Whether the Jellyfin client's cast flow takes a Live
  TV channel is not tested.

**A fabric MPEG-2 decoder for ATSC HD** (asked 2026-10-04: MiSTer_DVD's decoder stripped to the
decoder, like this core). Read from MiSTer_DVD's docs and fit report, not measured here:
- The rates: 720p60 is 216,000 macroblocks/s, 1080i (1920x1088, 30 frames) 244,800 -- 5.3-6x DVD's
  40,500 -- at up to 19.4 Mbit/s (2x DVD).
- DVD's decoder: `clk_dec` 81 MHz (closes ~88-91), ~750-880 cycles a macroblock busy at SD with
  ~2x headroom, the worst picture ~1,300. HD at 81 MHz allows ~331 (1080i) / ~375 (720p60).
- Its structure sets a floor above that: the run-length decoder and IDCT take one coefficient a
  cycle, all 64 of every block, non-coded and skipped blocks included -- >= 384 cycles a
  macroblock. The measured bottleneck at SD is the reference fetch (VLD active 2-3 % of the time;
  the bridge "wall" ~180 MB/s through a 16 KB cache, display reads on the same port).
- Area is not the obstacle: the decode path is ~6,650 ALM / 46 M10K / 18 DSP (+ its 1,287-ALM
  memory shim). Its display side is SD-only (720 wide, 27 MHz, >480 lines taken as PAL).
- So: **not by stripping it; possibly by rebuilding its back end** (skip non-coded blocks, a wider
  IDCT, window fetches on a port of their own) -- the kind of work this core's macroblock pipeline
  took for H.264. MPEG-2's per-macroblock work is far lighter than H.264's, so ~350-400 cycles is
  plausible but unproven. The natural shape is a sibling core: this core's shell (ring, audio,
  display, overlay, HD raster) with an MPEG-2 decoder in place of the H.264 one, loaded by the
  program per stream (`mgl_launch.md`); it does not fit beside H.264 at 88 % ALM.
  1080i's 8,160-macroblock picture is also past this display path's 3,600 bound.

A fabric MPEG-2 decoder (MiSTer_DVD has one) is not worth it: MPEG-2 is the cheapest codec on
the ARM, and the fabric is at 88 % ALM.

## Returning decoded frames to the ARM

The opposite of this core's design (nothing decoded goes back). A program that wants
frames for its own compositing would need a write-back path on the HPS-side port. Not
planned; note the occupancy cost (`hw_budget_and_lessons.md` §2) if it ever is.
