# Architecture

Engineering note. What the core is for and the phase plan: `roadmap.md`.

## Target data flow (what the roadmap builds toward)

```
 ARM (Linux)                                  FPGA fabric
 ─────────────                                ─────────────────────────────────────────────
 HPS program                                  ring reader (ram1)
  networking, demux,     DDR3 ring   ───────▶  ├─ video records ─▶ H.264 decoder (clk_dec) ─▶ DPB (ram1)
  decryption, FEC  ───▶  + control   ◀───────  │                      front end + reconstruction   │
  (hps/ client lib)       block                │                                                   ▼
                          (status)             ├─ audio records ─▶ audio ring ─▶ A/V gate ─▶ AUDIO_L/R
                                               │                     (PCM, decoded     48 kHz NCO
                                               │                      on the ARM: D2)
                                               └─ flags (DISCONTINUITY, LOW_LATENCY, EOS)
                                                                                          STC (90 kHz)
                                               display: output order ─▶ scheduler ─▶ reader (ram2)
                                                                                      ─▶ deinterlacer
                                                                                      ─▶ HDMI / analog
```

Nothing decoded returns to the ARM. The only traffic back is the status block (the
core's state, the STC, counters, errors).

**Since Phase 3** a program on the ARM feeds the decoder through the HPS interface (below);
audio does not exist yet. What `h264/emu.sv` builds now:

```
 DDR3 (ram1, ddr_mux2 B)                                              ram1 (ddr_mux2 A)
 control block + ring ─▶ ring_rd engine (clk_mem) ─▶ ring_rd parser (clk_sys) ─▶ vidfeed_cdc ─▶ h264_top ─▶ recon_top ─▶ DPB
   ▲   status words ◀── ring_rd engine ◀── ring_stat (clk_sys; cdc_snap_ix ◀ clk_mem / clk_dec)    clk_dec     clk_dec │
   │                       stream_clr ─▶ fe_rst_n (the per-stream reset: decoder, DPB abort, display)                  ▼
 the program            idle_bars ◀─ stream_live / played ─ disp_ctl + disp_sched ◀─ recon_out ◀─ output process
 (hps/lib)                 │                (clk_sys, 90 kHz STC, LOW_LATENCY)   (clk_dec→sys; rec_more)
                           ▼                               │
                      output stage ◀── disp_reader (ram2) ◀┘  ─▶ HDMI / analog; audio silent
```

**The ioctl stand-in is gone** (Phase 2's input, retired by D3 in Phase 3): `hps_io`'s
download outputs are unconnected and its `ioctl_wait` input tied low. Its history is in
`roadmap.md` Phase 2.

## Clock domains (inherited from UMD, unchanged)

| clock | MHz | from | what runs on it |
|---|---|---|---|
| `clk_sys` | 27 | `h264/sys_pll.sv` outclk_0 | everything at pixel rate; `CLK_VIDEO`; hps_io; the display scheduler |
| `clk_mem` | 90 | outclk_1 | both DDR3 masters (`DDRAM_CLK`, `DDRAM2_CLK`). 90 is the proven ceiling of the f2sdram bridge on this board |
| (spare) | 25.116 | outclk_2 | unused; kept so clk_dec stays `general[3]` |
| `clk_dec` | 81 | outclk_3 | the decoder (front end and reconstruction). `tools/fmax_check.sh` gates it at 86 MHz at both slow corners; `h264/dec_stub.sv`'s heartbeat stays beside it (LED_USER) |

Phase 1 settled that D1's throughput comes from parallelism, not the clock (clk_dec closed
at ~89 MHz in UMD against the 86 MHz gate; `p1_measurements.md`).

## Memory ports

| port | master | carries |
|---|---|---|
| `ram1` (`DDRAM_*`) | the core | the DPB (`ddr_mux2` master A) and the HPS interface (master B: `ring_rd`'s polls, ring reads and status writes), as UMD's vbuf shared it; `ddr_probe` watches the port |
| `ram2` (`DDRAM2_*`, a UMD-FORK) | the core | the display reader: `docs/hw_budget_and_lessons.md` §2, occupancy not bandwidth; (0.9) and the overlay plane, behind a second `ddr_mux2` (the reader master A) -- its page, one line a raster line, and its descriptor once a refresh |

**The DDR3 map** (the f2sdram masters address 64-bit words; byte = word × 8):

| what | word | byte | size | notes |
|---|---|---|---|---|
| the Linux framebuffer (`/dev/fb0`) | `0x0440_0000` | `0x2200_0000` | 8 MB | not the core's: the kernel's `MiSTer_fb` region. (0.9) The overlay reads the program's page from it on `ram2` ("The overlay plane") |
| (unused since 0.11) | `0x0600_0000` | `0x3000_0000` | 20 MB | the DPB's place until interface 0.11 (1 MB stores) |
| the control block | `0x0628_0000` | `0x3140_0000` | 4 KB | the HPS interface (below); words 0-31, 40-47, 48-71 and 80-87 the core's (status, input), 32-39 and 72-79 the program's (0.9: the overlay's descriptor) |
| (reserved) | `0x0628_0200` | `0x3140_1000` | to the ring | |
| the ring | `0x0630_0000` | `0x3180_0000` | 8 MB | the HPS interface's records |
| DPB: 20 stores | `0x0640_0000` + store << 18 | `0x3200_0000` | 40 MB (2 MiB a store) | (0.11, 720p) `h264_pkg` `NSTORE`; the decoder writes (ram1), the display reads (ram2); `recon_top` and `disp_reader` take the same `DPB_BASE`, the layout's `DPB_BYTE` (pinned by `check_emu_wiring.py`; `ring_layout.py` asserts it above the ring and below `0x4000_0000`). A store holds a picture up to 3,600 macroblocks (Level 3.1's MaxFS: 1.84 MB with its side words; `h264_recon.md` §2.2). Above the ring so the control block and the ring kept their addresses: no program changes for it. Ends at `0x3480_0000`. (0.15) **In a picture stream the program writes them** (the decoder is idle): "Pictures from the program" |

The framework's ALSA reader (`ddr_svc`) is detached from ram2 and compiled out
(`MISTER_DISABLE_ALSA`): audio arrives through the ring instead (`roadmap.md` "Guiding
principles"). The ring's reads are small next to the DPB's (a 17 Mbit/s stream is ~2 MB/s)
but they share ram1's occupancy. Measured in the cosim (P3h): x264_sun through the ring,
polls on, runs 1,243 clk_dec cycles a macroblock -- the same as fed directly: no measurable
cost under the DDR model. On the rig `ddr_probe`'s busy_max stays ~47 cycles.

## The HPS interface, v0.1 (decision D4, 2026-09-27)

**Status: version 1.0, FROZEN (2026-10-07, roadmap Phase 7; "Version 1.0" below).** Version
0.1 was designed at Phase 3; the paragraphs below are its history. **Version 0.2 (2026-09-29, P6 step 3):** word 30 carries the fit of the shown picture
(its rectangle, snap / crop-invalid / clamp, `disp_fetch_late`) -- added, no word moved; the
library still checks the version exactly below 1.0 (a program rebuilds against the new
header). **Version 0.3 (2026-09-29, P6 part 2, decided with the maintainer):** word 30's free
bits 19-23 report the raster -- `raster_std` (0 59.94 Hz, 1 60.00 Hz, 2 50 Hz / 576 lines;
reserved value 3 is not emitted),
`raster_il`, `raster_auto` (Refresh Rate on Auto: the rate follows the stream's VUI rate,
latched at its first picture), `anti_twitter` (applied to the shown picture) -- so a
program (a Moonlight client) can see the rate the display runs at (`analog.md` §8 / §10).
**Version 0.4 (2026-09-29, decided with the maintainer after the CRT round):** the program
declares rendered content, and sees every OSD setting -- additive, no word or field moved:
- **`GRAPHICS` (flag bit 4, VIDEO_AU only):** "this stream is rendered graphics" (a game
  stream, a desktop, a UI) -- the content, not a request. Taken from each stream's first
  VIDEO_AU like LOW_LATENCY; a later VIDEO_AU that disagrees is counted (`gfx_mismatch`,
  word 27), never obeyed; the live flag `GRAPHICS` (word 4 bit 23) shows the stream's value.
- **`Anti-Twitter: Auto, Off, On`** (the OSD; Auto the default): Auto filters iff the
  stream says `GRAPHICS` -- an unflagged stream (a file, a transcode) stays unfiltered, so
  the default behaviour is unchanged; Off / On override the program. Still only at 480i /
  576i, on frame stores (`analog.md` §9); word 30's `anti_twitter` reports it applied.
- **The OSD mirror (word 27 [44:32]):** every option's value as the menu holds it --
  Aspect Ratio, Deinterlace, Video Output, HDMI Deinterlace, Analog Aspect, Refresh Rate,
  Anti-Twitter (word 4's `osd`, Aspect and Deinterlace only, stays for 0.1-0.3 programs).
  Read by the program; it CHANGES them through the settings request (below).
- **The settings request (program word 35, a u32; decided with the maintainer 2026-09-29: a
  program can offer the core's settings in its own menus, without the user opening the OSD).**
  One atomic store: `[12:0]` the values in word 27's mirror order (Aspect `[1:0]`, Deinterlace
  `[3:2]`, Video Output `[5:4]`, HDMI Deinterlace `[6]`, Analog Aspect `[8:7]`, Refresh Rate
  `[10:9]`, Anti-Twitter `[12:11]`), `[19:13]` the mask (which options to change, one bit each
  in that order), `[23:20]` zero, `[31:24]` a sequence number (0: no request). The engine reads
  it with the doorbell (the poll reads words 32-35; 34 stays reserved for the pause); during a
  session a new sequence number is one request: range-checked (a masked value past its
  option's last, a reserved bit, an empty mask -- refused, `set_err`, word 27), else merged
  into the current settings and handed to Main through `hps_io`'s `status_in` / `status_set`
  -- the framework's own path for a core changing its options. **Main adopts it as if the
  user had chosen it**: the OSD shows it, the mirror reports it, and the user can change it
  again (the last change wins; there is one copy of the settings, Main's). `set_seq` (word 30
  [31:24]) is the last sequence number consumed. A change of Video Output or Refresh Rate
  switches the raster as the menu does. At a new session the core applies the word's current
  request once (a program re-asserting its settings). **On the rig (2026-09-29, the
  SuperStation, stock Main, `H264_graphics_20260929_1849.rbf`):** `h264play --osd
  refresh_rate=3,aspect=2` from Progressive / Auto -- Main adopted it within the poll (the
  mirror read Aspect 16:9, Refresh 50 Hz; the raster switched to 50 Hz; `set_seq` 1, `set_err`
  0), and it held through the OSD opened and closed. **Fixed 2026-10-02 (`history.md` §24):** the
  library numbered each program's requests from 1 and left word 35 as the previous program wrote it,
  so a new program's first request was a repeat (ignored) and its session re-applied the previous
  program's -- `h264ring_start_session` now writes this program's own request (or 0) and numbers on
  from word 30's `set_seq`. **Main does not save it** to the core's
  settings file (`H264_v1.CFG` unchanged): a program's settings last until the core reloads,
  when the user's saved ones return -- the program re-asserts them at its next session (the
  core applies the word's request at a session's start).
**Version 0.5 (2026-09-29, Phase 4 -- audio; designed in "Audio (Phase 4)" below):** AUDIO
records are PLAYED (PCM, 48 kHz s16 stereo, a length a multiple of 4, else `HDR_LENGTH`); **the
ring is the audio's buffer**, so **word 5's `read_index` is the released index** -- held at the
oldest AUDIO record not yet fetched to play, else the parser's record (the program's rule is
unchanged; the engine checks WIDX_RANGE against it); **word 34, the pause and attenuation**
(range-checked, refused whole with `ctl_err`); **words 40-47**, the audio's status, written as a
fifth burst before seq_tail (word 1 [63:48] `core2_word` names where they start); word 39
was reserved until interface 1.2. Additive but for word 5's meaning; the poll reads 32-39 on 1.2.
**Version 0.6 (2026-09-29, the Moonlight client's input; designed in "Input (interface 0.6)"
below):** **words 48-71, the input region** -- Main's six pads, its keys and mouse buttons as an
ordered event queue with the OSD's edges, the mouse's movement as sums -- written by the core on
change (at most every 1 ms) and each frame, under a seqlock of its own (in_head 48, in_tail
71); program words 36-37 reserved for rumble. Additive: nothing below word 48 moves.
**Version 0.7 (2026-09-30, UMD's lone-PTS rules ported; `display.md` §10):** word 27 [30:27]
`disp_lone`, the lone PTS the display disbelieved (saturating 15). Additive: bits that were zero.
**Version 0.8 (2026-09-30, reaching the program from the pad; `moonlight.md` M11):** input event
type 3, **an OSD action** -- the core's two `R` entries ("Send Home to the program", "Program
menu"), each a status bit Main pulses, queued as `{3, number}` ("The OSD's actions (0.8)" below).
Additive: a type that was reserved.
**Version 0.9 (2026-09-30, Phase 6b -- the overlay plane; designed in "The overlay plane" below):**
**program words 72-79, the overlay's descriptor** -- a page of the Linux framebuffer (its base,
size, stride, format `1555` / `4444` / `8888`, the band drawn on) composited over the video on
the core's raster, read once a refresh on `ram2` under a generation pair; **core words 46-47,
its status** (`ovl_*`, and the aspect HDMI's scaler is given). Additive: words that were
reserved or unused.
**Version 0.10 (2026-10-01, `hdmi_raster.md`):** core words 80-87, the raster (word 80); word
47 relative to it ("The raster (interface 0.10)" below).
**Version 0.11 (2026-10-02, 720p; designed in "The capabilities (interface 0.11)" below):**
**core word 81, the core's capabilities** -- the largest picture (3,600 macroblocks, Level 3.1's
MaxFS: 1280x720), the macroblock rate it is designed for (108,000 a second: Level 3.1's
MaxMBPS), the tallest 16:9 picture Native (HDMI) shows at its own size (480) -- constants a
program reads instead of hard-coding them. `rc_ref_size` (word 20) now counts pictures above
3,600 macroblocks (0.10: 1,620). The DPB moved above the ring (not the program's: the control
block and the ring did not move). Additive: a word that was reserved 0.
**Version 0.12 (2026-10-04, the HD raster: `hd_raster.md` §7):** the native raster on an 81 MHz
dot (3F dots a frame), up to 2,048 x 2,048 -- every picture the core decodes is shown native
(picture-sized at worst). **Word 81's `cap_native_h` 480 -> 720** (the value; the field did not
move); **the overlay's canvas up to `OVL_MAX_W` 2,048 x `OVL_MAX_H` 2,048** (was 1,024 x 2,047);
word 80's `raster_w` / `raster_h` up to 2,048. No word moved, no field was added: a program that
read the limits from the header and word 81 follows; the library's version 0x0C.
**Version 0.13 (2026-10-04, rumble: designed in "Rumble (interface 0.13)" below):** **program words
36-38, the pads' rumble** (two pads a word, `{large, small}` as `hps_io`'s `joystick_N_rumble`), read
with every poll (one burst of seven words, was four) and passed to Main during a session; **core
words 82-83, the rumble applied** and how often it changed. Additive: words that were reserved (36-37
for rumble since 0.6, 38 the program's, 82-83 the core's); the library's version 0x0D.

**Version 0.14 (2026-10-04, Video Output's Auto can be Native: `analog.md` §11):** **word 80 [28:27]
`video_out`, Video Output as resolved** -- 1 Interlaced, 2 Progressive, 3 Native (HDMI), never 0 on
a 0.14 core. Decided with the maintainer: Auto is Native (HDMI) unless `MiSTer.ini` sets up an
analog TV (Interlaced, as before) or a 31 kHz VGA monitor on the core's own raster
(`forced_scandoubler` with `vga_scaler=0`: Progressive). The OSD mirror (word 27) keeps reporting
the MENU's value (Auto = 0), so a program that asked "Native?" of the mirror (the Jellyfin client's
720p transcode box) would miss Auto's Native: it asks `video_out` instead, through
`h264ring_video_out()`, which falls back to the mirror (and word 30's `raster_il` for its Auto) on a
0.13 core, whose Auto never chose Native. Word 80's raster report cannot answer it: it reads
"fitted" until a session's first picture. Additive (bits that read 0); the library's version 0x0E. (The Downscale Filter, built beside it as an
evaluation option, became the Area pre-filter always on -- `analog.md` §11b: no option, nothing to
mirror.)
**Version 0.15 (2026-10-05, pictures from the program: designed in "Pictures from the program
(interface 0.15)" below):** **record type 5, PICTURE** -- a 32-byte descriptor of a picture the
program wrote into one of the DPB's stores itself (decoded on the ARM from another codec), shown as
a decoded picture is (fitted, deinterlaced, anti-twittered, paced against the STC); **core word 84,
the stores' state** (`pic_held`, `pic_mode`, `cap_pic_stores`, `pic_emitted`); **core word 85,
`disp_fhold`** (the display's field holds at 480i / 576i: a field pair starts on its first field's
raster field -- for every field-coded source, H.264's too); **error codes 11-16**;
the DPB's address and layout published (`H264RING_DPB_*`). Additive: a type, a word and codes that
were unused; the library's version 0x0F.
**Version 0.16 (2026-10-07): the colour** -- "The colour (interface 0.16)" below.
**Version 0.17 (2026-10-07, the Jellyfin client's F5):** **word 30 [45] `fit_valid`** -- 1 while a picture is
shown (`disp_ctl`'s `sh_valid`). With none shown -- a session's ready screen, after a flush -- `disp_fit`
works on a 0 x 0 picture and word 30's fit read as faults (`fit_crop_bad` 1, `fit_clamp` 1, `fit_oh` 8,191):
now `fit_crop_bad`, `fit_clamp`, `fit_snap`, `fit_ow`, `fit_oh` and word 80's `pic_x0` / `pic_y0` read 0
until a picture is up, and `fit_valid` says which. Decided 2026-10-07 (the alternative, the manual saying
"meaningful once `n_au` moves", leaves every program a rule to know; a bit is the 1.0 contract). Additive
but for the gated fields' values with no picture; the library's version 0x11.
**Version 1.0 (2026-10-07, the maintainer: "freeze the interface for 1.0"; roadmap Phase 7):** the 0.17
layout, unchanged, FROZEN; word 1 reads `0x0100`, the library's version 0x0100. Every open question was
settled first (F2 at 0.16, F5 at 0.17; F1 the overlay only during a session and F4 the STC as the
program's clock left to later additive minors -- no client needs them). **The rules for 1.x** (the
manual's `integrating/interface.md` "Versions" is their user-facing form, normative):
- *A minor only adds.* No word or field moves or changes its meaning; a field the program writes keeps
  0 = 1.0's behaviour. A minor may add a field in bits that read 0, a status word that read 0, a field in
  a program word or bits that had to be 0, a record type / flag / input event type / error code / OSD
  setting that 1.0 refused or lacked. Anything else is 2.0.
- *The version check* (`h264ring_attach`, `h264ring_version_ok()` in `h264ring.h`, a static inline so a
  program reading the words itself applies the same rule): **the same major, the core's minor >= the
  library's**. Below 1.0 the check was exact (a program rebuilt with every version); a frozen interface
  must let a 1.0 program run on a 1.3 core, and the additive rule makes that safe. The reverse (a 1.3
  program, a 1.0 core) is refused: the program might write a field the older core range-checks as
  reserved (a refusal) or read one it never sets. The minor's arm cannot be exercised through attach while
  the library is x.0, hence the helper: `test_ring` checks it directly with a 1.3 library (a 1.2 core
  refused, 1.3 / 1.4 accepted), and attach with 0.17 / 2.0 refused, 1.0 / 1.1 / 1.255 accepted;
  `red_h264.py` has a mutation per arm.
- *The program's duties*: zeros in every reserved bit and word (the core refuses a header with one set:
  error 3), unknown status bits and error codes ignored / shown by number.
- *Consequence for older text*: the 0.14 fallback "on an older core" in `h264ring_video_out()` and 0.11's
  word 81 fallback were unreachable under the exact check and stay so (a 1.x library never attaches below
  1.0); they guard only a status read before the core's first frame, or a 0 no 1.x core writes.
**Version 1.1 (2026-10-10, the maintainer: "let's do part b now"; roadmap "A transcode with no audio, and
a freeze"):** the 1.0 layout, unchanged; a behaviour. While a paced stream's queued audio leads (it waited
for the clock or started it, and has neither run dry nor come late since), a late picture no longer
anchors the clock back over it ("Queued audio: a late picture never runs the clock back over it", below).
Word 1 `0x0101`, the library's version 0x0101: a 1.1 program refuses a 1.0 core, a 1.0 program runs on a
1.1 core. `hps/tests/test_ring.c`'s matrix: 1.0 refused, 1.1 / 1.2 / 1.255 accepted.
The heading keeps "v0.1": other documents cite it by name. The layout lives in ONE table, `tools/ring_layout.py`, which generates the RTL's
constants and status muxes (`h264/ring_iface.svh`, `h264/ring_words_{sys,mem,dec}.sv`) and
the client library's header (`hps/include/h264ring_layout.h`); `--check` fails on drift
(`tools/tests/test_ring_model.py` runs it and pins the published offsets). The model the
benches score against, `tools/ring_model.py`, is written from THIS section, not from the
RTL. The manual's `integrating/` pages are the user-facing form of it.

**Version 1.2 (2026-10-16, calibrated playback geometry):** word 39 carries a sequence-tagged
picture rectangle; word 88 carries its clip viewport. The program writes word 88 first, then
commits word 39 by writing its sequence in the high 32-bit half last. The engine reads word 39
with the normal poll, fetches word 88 on a new sequence, range-checks both, and acknowledges
the sequence and result in word 31's high half. The display applies the picture rectangle in
`disp_fit` (so source steps are recomputed) and clips output to the viewport in `disp_reader`.
An all-zero rectangle and viewport clears calibration. Native output bypasses this override.
A program built against this library can still attach to 1.1 for ordinary playback;
`h264ring_set_geometry()` returns `-ENOTSUP` on that core. Additive: program word 39 was
reserved, word 88 was unused, and word 31's high half was reserved.

**Version 1.3 (display policy):** core word 87 reports the Output Mode, Match Video Refresh,
240p Playback, Play 24fps at 25fps, Display Shape, and resolved raster policy. The HPS API
`h264ring_request_display()` uses the existing word-35 settings path; its display format keeps
bit 23 as the selector, uses bits 2:0 for the profile, bit 3 for Off versus 50/60 matching,
and bits 4/5 for 240p and film speed. Masks 0:3 select these values. Interface 1.3 requests
leave bits 22:20 and 12:6 reserved, preserving the legacy bit-3 encoding.

**Version 1.4 compatibility:** word 87 bits 17:16 retain the additive field introduced in 1.4.
This core reports 0 for Off and 1 for 50/60 matching; the upper encodings remain reserved.
The former exact-48 option has been retired, while its field positions remain stable so existing
1.4 clients can keep using the published layout. The raster standard uses values 0 (59.94),
1 (60.00), and 2 (50 Hz); value 3 is reserved and is not emitted. New clients leave word-35 value bit 6 clear; the core still accepts the old bit-6 marker when
match is selected and enabled, normalizing it to 50/60 (bit 6 alone is rejected). Saved OSD value 2
resolves to Off because the selector now has only two choices. Interface version remains 1.4.

### Decided with the maintainer (2026-09-27)

- **D3: no OSD file slot.** The ioctl stand-in goes; the reference feeder (`hps/`) is the
  developer input path.
- **The ring is 8 MB.** It is the decoder's CPB: Level 3.1 High's NAL MaxCPB is 14,000 x
  cpbBrNalFactor 1,500 = 21 Mbit, ~2.6 MB (H.264 Tables A-1, A-2). 8 MB holds ~3 s at that
  rate, ~6 s at 10 Mbit/s: room for a file player's jitter.
- **DISCONTINUITY is the full per-stream reset** (decoder, DPB abort, display), not UMD's
  soft quiesce (its P6b1; a later port). Parameter sets are forgotten: a seek or a switch
  lands on an IDR that resends them.
- **Telemetry is the status block.** The core writes it every raster frame; any program
  reads it (`hps/h264stat` for the harness). No EXT_BUS telemetry, no HIL Main (UMD's
  `umd_telem` route is not carried).

### Where

| what | byte | word | size |
|---|---|---|---|
| the control block | `0x3140_0000` | `0x0628_0000` | 4 KB (words 0-31, 40-71 the core's; 32-39 and 72-79 the program's) |
| reserved | `0x3140_1000` | | to the ring |
| the ring | `0x3180_0000` | `0x0630_0000` | 8 MB (2^20 words) |

Inside the FPGA's half of DDR3 (`0x2000_0000`-`0x3FFF_FFFF`: ascal at `0x2000_0000`, Main's
framebuffer at `0x2200_0000`; cores use `0x3000_0000` up), where the DPB's 20 stores of 1 MB
ended until interface 0.11; since 0.11 the DPB (2 MiB stores, 720p) lies above the ring, at
`0x3200_0000`, so neither the control block nor the ring moved. The cosim's DDR model window
is 128 MB from `0x3000_0000` (the control block, the ring and the DPB).

### The control block

The core writes words 0-31, (0.5) 40-47 and (0.10) 80-87 every raster frame, as six write
bursts of eight -- 0-7, 8-15, 16-23, 40-47, 80-87, 24-31, so seq_tail (word 31) is the last
written; the program writes
words 32-39 and (1.2) word 88, plus 72-79 for the overlay. **No word has two writers** (the core's DDR3
master has no byte enables). Each u32 sits in its own half of a 64-bit word, so neither
side ever reads one torn.

| word | writer | contents |
|---|---|---|
| 0 | core | magic `"MiSTH264"` |
| 1 | core | version (major << 8 \| minor, 0x0100 since 1.0), core words (32), first program word (32) |
| 2 | core | ring base (byte address), ring size |
| 3 | core | **seq_head**: +1 each frame (the heartbeat); max payload |
| 4 | core | state, error, live flags, the OSD settings; err_pos |
| 5 | core | **read_index**, **ack_nonce** (one word: always coherent). (0.5) `read_index` is the RELEASED index: the core needs nothing below it -- the start of the oldest AUDIO record not yet fetched to play, else of the record the parser is at |
| 6 | core | the offending header word, verbatim |
| 7 | core | STC (33 bits, 90 kHz), the last pickup's lag (ms) |
| 8-29 | core | counters: the reader's, the front end's, the reconstruction's, the output queue's, the display's, ram1's (`ddr_probe`) -- `ring_layout.py` `WORDS` is the list |
| 27 | core | ... (0.4) the OSD mirror (`osd_*`: every option's value) and `gfx_mismatch`; (0.7) `disp_lone` |
| 30 | core | (0.2, P6 step 3) the fit: `disp_fetch_late`, `fit_crop_bad` / `fit_clamp` / `fit_snap`, the rectangle `fit_ow` x `fit_oh`; (0.3) the raster: `raster_std`, `raster_il`, `raster_auto`, `anti_twitter` |
| 31 | core | **seq_tail**; (1.2) geometry ACK sequence `[39:32]` and result `[41:40]` |
| 32 | program | **write_index** (u32; the high half is ignored) |
| 33 | program | **nonce** (u32) |
| 34 | program | (0.5) the **pause and attenuation** (u32: [0] PAUSE, [15:8] ATTEN in 0.5 dB steps, the rest 0 -- "Audio (Phase 4)") |
| 35 | program | (0.4) the **settings request** (u32; above) |
| 36-38 | program | (0.13) **the pads' rumble**: two pads a word, u32 low half -- `[15:0]` pad 2k, `[31:16]` pad 2k + 1, each `{large [15:8], small [7:0]}` ("Rumble (interface 0.13)") |
| 39 | program | (1.2) calibrated picture rectangle request: sequence `[63:56]`, signed x/y and width/height; written after word 88 |
| 88 | program | (1.2) calibrated clip viewport `{height,y,width,x}` in 12-bit fields; written before word 39 |
| 40-45 | core | (0.5) the audio: `aud_*` (state, mode, the queue, played, gaps, late drops, underruns, slips, anchors, the A/V offset, the ring bytes held) and word 34 as applied (`paused`, `atten`, `ctl_err`) |
| 46-47 | core | (0.9) the overlay's status: `ovl_*` and the aspect HDMI's scaler is given ("The overlay plane") |
| 48-71 | core | (0.6) **the input region**: Main's pads, keys and mouse, written on change (at most every 1 ms) and each frame under a seqlock of its own ("Input (interface 0.6)") |
| 84 | core | (0.15) the stores' state: `pic_held`, `pic_mode`, `cap_pic_stores`, `pic_emitted` ("Pictures from the program") |
| 85 | core | (0.15) `disp_fhold`: field pairs held a refresh at 480i / 576i for the raster's field (`analog.md` §5; UMD's V6), reset per stream |
| 82-83 | core | (0.13) the rumble applied (`rum_p0`-`rum_p5`, 0 outside a session) and `rum_changes` ("Rumble (interface 0.13)") |
| 72-79 | program | (0.9) **the overlay's descriptor**, read by the core once a refresh on `ram2` under a generation pair of its own ("The overlay plane (Phase 6b, interface 0.9)") |

**A consistent copy** (a seqlock): read seq_tail (word 31), then the words wanted, then
seq_head (word 3); equal means no frame's write overlapped the read, else retry.

**States:** 0 unwritten, 1 NO_SESSION, 2 READY (a session, no access unit since the stream
began), 3 PLAYING, 4 ENDED (END_OF_STREAM consumed and the display took the stream's END),
5 ERROR (sticky until the next session). **Live flags** (word 4 [23:16]): LOW_LATENCY, EOS,
ENDED, STC_RUN, PLAYED, OSD_OPEN, SESSION, GRAPHICS (0.4).

### The session (who starts reading where)

Indices are **free-running u32 byte counts, never zeroed**; a byte lives at
`index % RING_SIZE`. Zeroing either would race: the ARM writes the two words as two
stores and a poll (one read burst of words 32-33) can land between them.

1. The program checks the magic and the version, and that seq_head ADVANCES (a core left
   loaded by an earlier program, or the contents a previous load left in DDR3, look
   valid but do not move).
2. It stops writing records; **if the write index is not a multiple of 16 it rounds it down** (2026-10-06,
   found on the rig: after a COLD power-up DDR3 is random, the core's poll checks the write index's
   alignment throughout a session, and a program that stores its own only with its first record had
   every session in WIDX_ALIGN at once -- the library does it, `new_session`; an aligned index is never
   touched, so no race with a core still reading behind it); then it writes a new **nonce** (different
   from ack_nonce).
3. The core reads the write index and the nonce in the same poll. On a nonce change it
   starts the session **at that write index** (rounded down to 16), clears its FIFO,
   resets the stream, and publishes `ack_nonce` beside `read_index` (= the start).
4. The program waits for `ack_nonce == nonce` and continues writing at `read_index`.

**At boot** the core records the first nonce it reads and does NOT act on it: DDR3
survives a core load, and the previous program's nonce, write index and records would
otherwise replay (`mgl_launch.md` rule 5). **An OSD Reset** drops the session
(NO_SESSION, ack_nonce 0); the library notices and starts a new one.

### Polling (the doorbell)

No HPS-to-FPGA register reaches `emu` without a `sys/` fork (`EXT_BUS` is Main's), so the
core polls. A poll is a read, and a read holds ram1's grant through its latency
(`hw_budget_and_lessons.md` §2): the core polls **fast (~32 us) only when it has caught up**
with the last write index it saw, and **slow (~1 ms) always** (a nonce change is seen
mid-stream). Measured cost: `n_polls`, and the cosim's cycles a macroblock with polling
on (Phase 3 gates).

### Records

Every record starts 16-byte aligned: a 16-byte header, then the payload padded to a
multiple of 16. A record never crosses the ring's end: a **PAD** fills the tail instead
(alignment guarantees one fits).

| | bits | field |
|---|---|---|
| word 0 | [7:0] | type: 1 PAD, 2 VIDEO_AU, 3 AUDIO (0.1-0.4: skipped, counted; 0.5: played -- "Audio (Phase 4)"), 4 CONTROL (reserved: refused in 0.1), 5 PICTURE (0.15: "Pictures from the program"); **0 is never valid** (an unwritten or torn header is zeros) |
| | [15:8] | flags: PTS_VALID (b0), DISCONTINUITY (b1), END_OF_STREAM (b2), LOW_LATENCY (b3), GRAPHICS (b4, 0.4); the rest 0. (0.15) A PICTURE takes the same five as a VIDEO_AU, with the same meanings ("Pictures from the program") |
| | [31:16] | seq: records since the session began, mod 2^16, PADs included (a previous lap's record is refused) |
| | [63:32] | payload length in bytes |
| word 1 | [32:0] | PTS (90 kHz) |
| | [35:33] | (0.16) `colour`: 0 auto, 1-6 the matrix and range ("The colour (interface 0.16)"); VIDEO_AU and PICTURE only, 0 on the others |
| | [47:36] | zero (0.1-0.15: [47:33]) |
| | [63:48] | sync `0x5248` |

**Normative:**

- **One VIDEO_AU record carries exactly one complete access unit** (Annex-B, start codes
  included). The core relies on it: a record's end is an access unit's end.
- A VIDEO_AU is 1 byte to 4 MiB; any record's payload is at most 4 MiB.
- PTS_VALID marks the payload's FIRST byte with the PTS (`au_pts`: the tag belongs to the
  first access unit starting at or after the marked byte). Allowed on VIDEO_AU and AUDIO.
- DISCONTINUITY (VIDEO_AU): before the payload, the stream is reset. If END_OF_STREAM was
  consumed, the reset first waits for the display to take the stream's END (the last
  picture is shown), with a timeout. **It takes effect IN ORDER**: everything queued ahead
  of it is decoded and shown first (a playlist's next item, gapless). A seek must not
  wait for the queue: see "Seeking" below.
- END_OF_STREAM (VIDEO_AU): after the payload, the decoder is flushed; the last picture
  stays on screen. The next VIDEO_AU MUST carry DISCONTINUITY.
- GRAPHICS (VIDEO_AU, 0.4): the stream is rendered graphics; taken from each stream's first
  VIDEO_AU, later disagreements counted (`gfx_mismatch`); the OSD's Anti-Twitter Auto
  follows it.
- LOW_LATENCY (VIDEO_AU): taken from each stream's first VIDEO_AU (present as soon as
  decoded, no PTS pacing); a later record that disagrees is counted, not obeyed.
- The program writes a record, then (after a memory barrier) advances write_index past
  it. It never lets `write_index - read_index` exceed the ring size.

**Checks on arrival** (every field the program writes is range-checked; the core never
trusts the ARM side, `spec_hardening.md`). Each failure stops the session in ERROR with
the FIRST code, its position (`err_pos`) and the offending header word (`err_word`). The
record checks are made in this order: type, CONTROL, flags, length, the ring's end, seq,
then word 1's sync / zero bits, then the stream's state:

| code | name | |
|---|---|---|
| 1 | WIDX_ALIGN | write_index not a multiple of 16 |
| 2 | WIDX_RANGE | write_index more than a ring ahead of the read index, or moved backwards |
| 3 | HDR_SYNC | word 1's sync or zero bits |
| 4 | HDR_TYPE | type 0 or unknown |
| 5 | HDR_FLAGS | an undefined flag, or a flag not allowed on the type |
| 6 | HDR_LENGTH | a VIDEO_AU of 0 bytes, (0.5) an AUDIO of 0 bytes or not a multiple of 4, (0.15) a PICTURE not of exactly 32 bytes, or any payload over 4 MiB |
| 7 | HDR_WRAP | a record crossing the ring's end, or a PAD not ending exactly there |
| 8 | HDR_SEQ | seq not the next record's |
| 9 | NEED_DISCONT | a VIDEO_AU (0.15: or a PICTURE) after END_OF_STREAM without DISCONTINUITY |
| 10 | CONTROL_UNSUPPORTED | a CONTROL record (reserved) |
| 11 | STREAM_KIND | (0.15) a PICTURE in a stream whose first video record was a VIDEO_AU, or a VIDEO_AU in one whose first was a PICTURE (a stream is one or the other: DISCONTINUITY, or a new session, starts a stream of either kind) |
| 12 | PIC_FIELD | (0.15) a PICTURE's descriptor: a reserved bit set, structure 3, a `pic_struct` not allowed (below), an `aspect_ratio_idc` of 17-254 or 255 with a zero SAR, or `timing_valid` with a zero `num_units_in_tick` / `time_scale` |
| 13 | PIC_STORE | (0.15) a store at or above `cap_pic_stores` (20) |
| 14 | PIC_SIZE | (0.15) a side of 0 or above 128 macroblocks, an odd `hf_mbs` on a field pair, or `w_mbs x hf_mbs` above `cap_max_mbs` (3,600) |
| 15 | PIC_CROP | (0.15) a crop leaving nothing (`left + right >= 8 w_mbs` or `top + bottom >= 8 hf_mbs`) |
| 16 | PIC_BUSY | (0.15) the store is still held by the display when the PICTURE reaches it (the program broke the store rule) |
| 17 | HDR_COLOUR | (0.16) header word 1's `colour` is 7, or non-zero on a PAD or an AUDIO record |

Not checked: a write index that stops inside a record (harmless: the core reads only
below it, and waits for the rest). The ARM-side ordering risk (a payload seen before it
landed) is detected for headers (type 0, seq, sync) but not for payload bytes: the rig's
errors-0 runs are that evidence.

### What the program controls, and what stays Main's

Main keeps running beside the program: it owns the OSD, the input devices and the core's
settings (Aspect, Deinterlace; mirrored in word 4). The program owns only the ring.
**Input is not shared at the evdev level** (corrected 2026-09-29, `moonlight.md` M5): Main
holds an exclusive `EVIOCGRAB` on every input device while a core runs, so a program reading
`/dev/input` receives nothing. Since 0.6 the core mirrors what Main sends it (pads, keys,
mouse) into the control block ("Input (interface 0.6)" below), with the OSD's opening and
closing in the same event queue.

### Seeking, and why pause is not a record (decided 2026-09-27, after the P3 HW round)

Records are consumed in order, and the ring holds seconds of video: anything carried IN
the stream acts only once the queue ahead of it has played. Measured on the rig (P3 build,
`p60.264` switching after 500 access units, ~11 s queued): the DISCONTINUITY record reset
the stream **11,211 ms** after the program wrote it.

- **Seek / switch now = a new session.** `h264ring_flush()` writes a new nonce; the core
  starts the session at the write index it reads with it (the interface's own rule), so
  every record not yet read is dropped, and resets the stream. Then the program writes
  from an IDR with its parameter sets (no DISCONTINUITY needed: the session start is a
  stream reset). On the rig: **14 ms**. No interface change: a session start always did
  this; the library names it and the manual documents it as the way to seek.
- **Pause must be out of band** (the plan had PAUSE / RESUME as CONTROL records: wrong,
  for the same reason -- a queued pause would land seconds late). **Built in 0.5 (Phase 4):**
  program word 34, a level the engine reads in its poll, freezes the STC, holds the shown
  picture, silences the audio at its frame and stops the reader consuming the ring; resume
  continues with the timeline intact ("Audio (Phase 4)", "The pause and volume word"; on the
  rig `history.md` §11). Before 0.5 a pause was "stop feeding": the queued seconds played out
  first, the last picture then held.
- **The CONTROL record stays reserved** (refused in 0.1) for changes that belong in STREAM
  order: container overrides that start at a given picture (the display aspect). The colour
  matrix and range, once listed here, are a header field since 0.16 ("The colour (interface
  0.16)"). Volume goes with pause, out of band (Phase 4).

The program's own UI (a media browser) is decision **D6** (`roadmap.md`). **The Jellyfin client's
findings about the interface** (2026-10-01: the overlay only during a session, the colour matrix,
the refusal's name, the STC as a program's clock) are listed in `jellyfin.md` §7, each designed
here before it is built.

### Launch, and two programs

A program loads the core as MiSTer's tools do -- an MGL (`<rbf>_Other/H264</rbf>`) and
`load_core` into `/dev/MiSTer_cmd` -- only when `/tmp/CORENAME` is not already `H264`,
then runs the session handshake with a timeout (`mgl_launch.md`). Two programs: an
advisory `flock` in the library; the core does not arbitrate.

### The ARM side (the client library, `hps/`)

`/dev/mem` opened `O_RDWR | O_SYNC` (uncached, as Main's `shmem_map`), after checking
`/proc/iomem` that the range is not System RAM. **Never `memcpy` into the mapping**: an
unaligned store to strongly-ordered memory faults on ARMv7; the library copies aligned
words. Payload, `__sync_synchronize()`, then write_index. Every index store is a single
aligned 32-bit store.

### The fabric side

| module | clock (reset) | role |
|---|---|---|
| `h264/ring_rd.sv` engine | clk_mem (`mem_lock_n` only: `ddr_mux2`'s master B has no abort) | the two poll timers; read bursts of <= 8 words, never past the observed write index, into a `fifo_dc`; the write-index checks; the status write bursts; the session clear. Never withdraws a command |
| `h264/ring_rd.sv` parser | clk_sys (`reset_n`, NOT the per-stream reset: the words behind a DISCONTINUITY are the next stream) | the record checks; `{PTS, mark, au_end, byte}` into `vidfeed_cdc`; the stream reset (`fe_rst_n = reset_n & ~stream_clr`); END_OF_STREAM as `vidfeed_cdc`'s flush; the LOW_LATENCY level |
| `h264/ring_stat.sv` | clk_sys | builds the 32 (0.5: 40) status words each frame: its own domain's through `ring_words_sys`, clk_mem's and clk_dec's through `cdc_snap_ix` (an indexed request / acknowledge snapshot) |
| `h264/aud_play.sv` (0.5) | clk_sys (`fe_rst_n`; the counters `reset_n`; the owed words the lock) | the audio path: AUDIO descriptors from the parser, the fetch through the engine, the gate, the 48 kHz tick, the attenuation, the audio anchor -- "Audio (Phase 4)" |
| `h264/ddr_probe.sv` | clk_mem | UMD's passive ram1 watcher: beats, beats owed, the busy runs |

The session clear is a four-phase handshake started by the engine (vbuf's shape, UMD
`umd/vbuf.sv`): it finishes the command it presents, holds its FIFO side in reset and
raises the request; the parser resets its record state (and the stream) and acknowledges;
the engine sets its indices to the start, releases, drops the request; the parser
releases.

## Audio (Phase 4): PCM from the ARM, presented against the STC

**Status: ✅ MERGED (PR fj#12), ✅ HW-CONFIRMED 2026-09-29 (`history.md` §11; the capture chain's
absolute A/V calibration deferred). Interface 0.5** (an interface change: versioned, the manual's
`integrating/` pages in the same change).

**D2, decided (the maintainer, 2026-09-29): audio is decoded on the ARM.** The program already
does everything but video decode (networking, demux, decryption, FEC); the ARM decodes AAC /
Opus / anything its libraries support in a few percent of one A9 core, and an in-fabric codec
set would limit what a program can play. The fabric presents PCM only: no audio DSP.

**The choices (confirmed by the maintainer 2026-09-29):**

1. **One PCM format on the ring: 48 kHz, 16-bit signed little-endian, stereo, interleaved.**
   The program resamples (one library call: libswresample / speexdsp) and downmixes
   multichannel sources to stereo; the core stays at MiSTer's own 48 kHz audio path.
   Rejected: accepting 44.1 / 48 kHz and resampling in the fabric -- logic for no gain.
2. **Sync: AUDIO records carry a PTS (their first sample's, 90 kHz) and the core plays them
   against the same STC that paces the pictures.** **Low latency** (a game stream): audio
   plays as it arrives against a small target buffer; the host's clock drifting from ours is
   absorbed by dropping or repeating single samples -- **counted in the status block, never
   silent**.
3. **The pause word lands in this phase:** program word 34 (reserved since 0.1), a level the
   engine reads in its poll. **Volume** beside it (an attenuation field in the same word).
4. **The audio buffer is in DDR3**, not M10K (PCM is 192 KB a second; M10K stays the
   decoder's) -- and **it is the ring itself** (decided by the maintainer 2026-09-29, after
   the harvest below): the samples are already in DDR3 when the program writes them, so the
   core does not copy them anywhere. It remembers where each AUDIO record is, fetches its
   samples when they are about to play, and holds the published read index behind the oldest
   record it has not yet fetched, so the program cannot overwrite them. Rejected: copying the
   payloads to a buffer in the reserved region (`0x3140_1000` ...), the draft's plan -- a
   DDR3 writer with its own pointers and backpressure, a second region, and a write plus a
   read of every sample on ram1, for nothing the ring does not already hold.

### What the harvest found (read 2026-09-29)

The draft named MiSTer_DVD's `audio_ring.sv`, `aud_drain.sv`, `av_sync.sv` and `lin_rate.sv`
as the audio path. Read end to end, they are not what the draft assumed:

| DVD module | what it is | here |
|---|---|---|
| `audio_ring.sv` | a clk_sys byte ring of COMPRESSED frames (AC-3 / DTS / LPCM) in M10K, with a descriptor FIFO `{len, type, PTS}` | the descriptor idea only: here the bytes stay in the ring |
| `aud_drain.sv` | "the audio a cell delivered has played" for the disc navigation's natural transitions | not carried (no navigation) |
| `av_sync.sv` | the clk_sys mirror of the clk_dec STC | not needed: this core's STC is already on clk_sys (`disp_sched`) |
| `lin_rate.sv` | a linear file's blocks-per-second estimate, for seeking and the HUD clock | not carried |
| `dvd_audio_decode.sv` | the codecs AND the two pieces this phase wants (below) | the pieces, rewritten for PCM |

**DVD's audio buffer is not in DDR3**: its DDR3 audio path (`docs/audio_ddr_path.md` there)
was retired on 2026-06-27 when audio moved into the fabric; the ring is 32 KB of M10K and the
codecs' PCM FIFOs 43-85 ms. What carries over, from `dvd_audio_decode.sv`:
- **the 48 kHz tick from clk_sys**, the same crystal as the raster and the STC, so audio and
  video cannot drift apart (DVD: an NCO, `(48000 << 32) / 27e6`, 0.06 ppm off). Here exactly:
  27 MHz / 48 kHz = 562.5 cycles, so the tick alternates 562 and 563 cycles; the STC is
  clk_sys / 300 (`disp_ctl`), and neither changes with the raster (60.00 / 50 Hz change the
  line length, not clk_sys).
- **the gate at the PCM FIFO's EXIT**, armed from the stream's start so the FIFO is empty when
  the phase reference latches; released when the STC reaches the head sample's PTS; an
  underrun re-arms it. DVD learned the exit is the only place the phase can be set: gating the
  entry of an elastic buffer does not control when its samples leave (its v2, HW-inert).
- **the pause reuses the gate** (the tick withheld; nothing consumed; resume continues the
  same sample).
- a fallback that never lets audio wait forever for a clock that does not start (DVD's 2.5 s
  `arm_timer`); here it is the audio anchor (below), which also makes an audio-only stream
  work.

Not carried: the codec dispatch, the stale-skip and catch-up (DVD's delivery ran behind real
time under its governor; here a late record is simply cut to its due sample, below), the
in-band re-time (disc cell joins), the A/V Offset knob (the program owns its offsets).

### The record

`AUDIO` (type 3; 0.1-0.4 skipped and counted it): the payload is whole frames of the format
above -- **length a multiple of 4 and not 0, else `HDR_LENGTH`**; at most `MAX_PAYLOAD` like
any record. `PTS_VALID` gives its first sample's time; without it, its samples follow the
previous record's (a record with no PTS at the stream's start plays when the clock starts).
The program writes audio and video records into the one ring, in any interleave: the reader
routes each AUDIO record's position to the audio path and skips its payload; video goes to
the decoder as before.

### The ring is the buffer

- **The parser** (`ring_rd`, clk_sys) checks an AUDIO header like any other and pushes a
  descriptor -- the record's index, its payload length, its PTS -- into the audio path's
  descriptor FIFO (256 records), then skips the payload. When the FIFO is full the parser
  waits at that header (and video waits behind it): the core holds at most **256 unplayed
  AUDIO records**. A program should send records of 5 ms or more (Opus and AAC frames are
  10-21 ms); 256 of them are over a second of lead.
- **The published read index** (word 5) is now the index below which the core needs nothing:
  the start of the oldest AUDIO record whose samples are not yet all in the fabric's sample
  FIFO (fetched at most ~10 ms before they play), or, with none, the start of the record the
  parser is at. It trails the fetch index (which the program never saw) by the
  audio queued and the reader's FIFO. The program's rule does not change: never write more
  than a ring ahead of it. The engine checks the write index against the published index (a
  ring ahead of it is `WIDX_RANGE`). With no audio in a stream the index behaves as in 0.4,
  lagging it by at most the reader's FIFO (64 words).
- **The fetch.** The audio path (`h264/aud_play.sv`, clk_sys) asks the engine for up to eight
  words at a time from the record it is fetching; the engine (clk_mem, `ddr_mux2` master B:
  no third master on ram1) serves the request between its other commands -- after the status
  writes and the polls, before the ring reads -- and pushes the words into the audio sample
  FIFO (a `fifo_dc`, 256 words = 512 stereo samples = 10.7 ms). A request is made only when the
  FIFO has room for it, counted on the clk_sys side (words asked for minus words taken), so the
  engine never waits on it. A record never crosses the ring's end, so a fetch never wraps.
  Cost: 192 KB a second of reads, 3,000 eight-word bursts, next to the ring's own fetch of the
  same bytes (the parser skips them) -- ~0.2 % of ram1's cycles.
- **A stream or session reset** drops the queued audio with the video's queue. The sample FIFO
  and the words-asked / words-taken counters reset only with the PLL lock; after any reset the
  audio path first takes and drops every word still owed to it, so a fetch in flight across
  the reset never plays in the next stream.
- **After END_OF_STREAM**, a DISCONTINUITY's reset waits for the display to take the stream's
  END (0.1) **and for the audio queued ahead of it to play out** (the same `END_WAIT` bound):
  a playlist's next item does not cut the last item's tail.

### Playing it: two rules, chosen by the stream's LOW_LATENCY

The sample tick is 48 kHz from clk_sys (above). The gate sits at the sample FIFO's exit: while
it is closed, nothing is consumed and `AUDIO_L/R` are 0.

**Paced (a stream without LOW_LATENCY; also a stream with no VIDEO_AU yet).**
- **Start:** the gate opens when the STC runs and reaches the head sample's PTS (a head with
  no PTS: when the STC runs). Exact to one sample (21 us) against the tick.
- **Every PTS-tagged record is checked at its first sample** against the STC: early by more
  than `SLIP` (10 ms: a gap in the audio, or a record written ahead of time), the gate closes
  and silence plays until the STC reaches it; late by more than `SLIP` (an overlap, or audio
  that arrived after its time), its first samples are dropped until it is on time -- a whole
  record late is dropped whole. Within `SLIP` it plays on, sample-continuous: a program's
  rounded timestamps (1 ms in Matroska) never trigger it. Both counted (`aud_gap`,
  `aud_late`, in samples).
- **Underrun** (the FIFO empty at a tick, the queue empty): silence, the gate re-arms, counted
  (`aud_underruns`); the next record's PTS sets the phase again.
- **The audio anchor.** The STC is started by the first picture shown (0.1). When the stream
  has audio and the clock does not run -- an audio-only stream, audio written far ahead of its
  video, a video the decoder refuses -- waiting would wedge the ring: queued audio holds the
  read index, the program cannot write the video, the clock never starts. So **audio starts
  the clock**: at once when the descriptor FIFO is full (the parser is waiting on audio), else
  after `AUD_WAIT` (1 s) with audio queued and the clock stopped; the STC is set to the head's
  PTS (0 if it has none) and counts. `disp_sched` then schedules the first picture against the
  running clock instead of re-anchoring on it -- unless the picture is more than `FWD_MAX`
  (0.5 s) ahead of it or `LATE_MAX` (2.7 s) behind it, the same bounds a later picture has.
  Counted (`aud_anchor`).

**Low latency (the stream's first VIDEO_AU carried LOW_LATENCY).** The pictures are shown as
soon as decoded; the host's clock is not ours, so the STC is not the reference. Audio plays as
it arrives against a queue target:
- **Start:** when the queue (the samples of every record pushed, not yet played) reaches
  `LL_START` (20 ms). **Underrun:** silence, re-arm, counted.
- **Drift:** the queue's minimum over every 1,024 samples played (21 ms) -- the margin left
  before an underrun -- is kept between `LL_MIN_LO` (2.5 ms: below it, one sample is repeated)
  and `LL_MIN_HI` (20 ms: above it, one is dropped). At most one sample in 1,024 (~1,000 ppm,
  ten times any crystal's error; inaudible). Counted (`aud_slip_drop`, `aud_slip_rep`). A
  fixed target for the minimum would not do: records arrive in steps (5-20 ms each), so the
  queue's minimum sits a record below its level at the start.
- **A burst** (the queue past `LL_MAX`, 250 ms: a stalled network delivering its backlog):
  samples are dropped at once down to `LL_START`, counted (`aud_late`).
- Audio then lags the picture by the margin plus a record: ~10-40 ms, inside lip-sync
  tolerance.
Parameters in the RTL, recorded here; a program cannot set them in 0.5.

### Queued audio: a late picture never runs the clock back over it (interface 1.1, 2026-10-10)

**The defect** (`jellyfin.md` §12; .201, 2026-10-09, reproduced 2026-10-10 with 1.0.0's client: `history.md`
§45). A transcode's TS put the audio more than 5 s ahead of the video, and the client wrote it in that
order.
- The audio waited, early, for its time (correct), and the descriptor FIFO filled (256 records, 5.12 s of
  20 ms ones). The parser then waits at the next AUDIO header and the video behind it starves (above: by
  design). That alone would only delay the video.
- The livelock is the display's clock. The starved pictures reach `disp_sched` late by more than
  `LATE_MAX` (2.7 s), and its `disc` term (the `d_stc_pic > LATE_MAX_TICKS` leg) anchors the STC back to
  them. The queued audio is then early again, `aud_play`'s gate stays closed playing silence, and it
  never drains.
- It has two phases, both in the 1 s logs:
  1. **The FIFO gate:** `aud_q_rec` 255-256, the parser waiting on it.
  2. **The ring gate:** the audio that does play frees FIFO slots (`aud_q_rec` 45 down to 3), but the
     oldest unplayed record -- early, waiting -- holds the published read index. The ring is full
     (8.0 MB between the read and write indexes), so the program cannot write. Each picture that still
     trickles in is late and re-anchors again.
- `disp_reanchor` reached 16 in 100 s on 2026-10-09, and 7 in 60 s in the control arm. **At every one of
  them the audio was armed and waiting early** (`aud_state` 1, `aud_gap` growing) and the ring was full.
- The `far` term after an audio anchor (the clock started by a full FIFO, the first picture `LATE_MAX`
  behind it) is the same leg at a stream's start.

**No interleave a program writes may stick the core.** The client now holds its audio to ~1 s ahead, but
another program, or a source whose audio leads by more than the ring holds, can still get there.

**The invariant.** When the queued audio is on time -- playing, or waiting for the clock to reach it --
the STC is right and the pictures are what is late. Moving the clock back to a late picture then only
makes that audio early, and early queued audio holds the parser (the FIFO) or the program (the read
index): no picture behind it can arrive on time again.

**The rule (interface 1.1; the go given 2026-10-10, the maintainer: "let's do part b now").** On a
paced stream (not LOW_LATENCY), **while the queued audio LEADS -- it waited for the clock or started
it, and has neither run dry nor arrived late since -- a picture's lateness does not anchor the
clock**:
- `disp_sched` drops the `LATE_MAX` leg from `disc` and from `far`;
- the picture is shown at once, as any late picture (lateness is not a discontinuity), and counted in
  `disp_late`;
- the other anchors keep their legs: a picture behind the timeline by more than a frame, a jump forward
  past `FWD_MAX`, a picture `FWD_MAX` ahead of an audio-started clock. They follow the stream's own
  timestamps, not its starvation.

Put the other way round: **a late picture moves the clock back only if the audio has run dry or come late
since it last waited ahead.** At a healthy stream's start the first record waits for the first picture's
time, so the flag is set for the whole film; a stall clears it.

**The flag** (`aud_lead`, `h264/aud_play.sv`, registered, clk_sys):
- *set* when the gate is armed with a timed head not yet due and the clock running (the audio waits for
  the STC), and when the audio anchor starts the clock (`aanc`: audio waiting with no picture is the
  "written ahead" case too; without it the start-of-stream `far` case would take one back-step first);
- *cleared* when the queue is empty (the audio ran dry: a stall drains the ring; an underrun with records
  still queued is only a fetch behind, and keeps it), by a late drop (the gate to `G_DROP`: a record past
  `SLIP` late), and by the stream's reset;
- *gated* to 0 on a LOW_LATENCY stream (its clock is not the audio's reference).

A single misstamped record more than 10 ms late clears it, and buys one back-step at most before the next
early wait sets it again: tolerable, and never a livelock.

**Why not "the audio on time"** (the merged first draft: the gate playing, or armed with an early head).
A stall's resumed audio is late, but its late frames are dropped one a cycle. The gate is back in
`G_PLAY`, on time against the STC, before the late picture behind it is even decoded. "On time" would then
have suppressed the stall's re-anchor as well, leaving the stall's lag as lip-sync error. What tells the two
apart is the audio's history: in the freeze it had waited ahead and never ran dry. **Both traces show it:**
from the audio's first early wait through all 15 re-anchors (control arm 6, 2026-10-09 15), `aud_underruns`
and `aud_late` did not move.

With the rule, in the freeze, the STC runs forward only and reaches the waiting audio, which plays.
That frees the FIFO, then the read index, and the parser and the program go on. The video behind the
audio arrives (lead - 5.12 s) late and is shown late. The film plays with its picture that far behind its
sound, `disp_late` counting every picture: wrong and visible, but not stuck. A program that keeps its
audio within a second never gets there.
- *Why it ends:* while the audio leads, only the pictures already downstream (the DPB, the display queue)
  can reach `disp_sched`. None of them anchors for lateness, and a timeline anchor (a timestamp jump)
  fires at most once each. After them the STC only counts up and reaches the head, and the queue plays out
  at 48 kHz.
- *Why not a fill level* (an earlier draft: "within 8 records of full"): the ring gate's re-anchors came
  with `aud_q_rec` 45 down to 3 (phase 2). A fill-level rule would have let more than half of them through.
- *A slow decoder* (a stream past the decoder's rate): the parser reads the ring only as fast as the
  decoder takes video, so the audio behind it in the ring arrives slower than it plays and runs dry. The
  flag clears, and the late pictures re-anchor as in 1.0 (the stream falls behind visibly, as before).
- *The wiring:* `aud_play.aud_lead` -> `disp_ctl.aud_lead` -> `disp_sched.aud_lead`, all clk_sys (no
  crossing), sampled at the eval (`lead_q`) and used in the decide stage (ev[3]): `lat = (d_stc_pic >
  LATE_MAX) && !lead_q`, `disc = ... || lat`, `far = lat || (d_stc_pic < -FWD_MAX)`. Cost: a flop, a few
  terms; no M10K, no DSP. `tools/disp_sched_ref.py` models it (a scenario's records carry `lead`).
- *The interface:* no word or field moves or changes meaning: **1.1** (word 1 `0x0101`, the library's
  version too, `tools/ring_layout.py`). A program built for 1.1 may rely on the rule, so it refuses a 1.0
  core (the documented rule: the core's minor >= the library's); a 1.0 program runs on a 1.1 core.
  `integrating/audio.md` says it in "How the core plays it".

**Alternatives, for the maintainer.**
- **B2, the parser skips audio at the FIFO gate while the display starves** (the AUDIO record dropped,
  counted): removes B1's lag, but drops sound (gaps in a film), and the parser (clk_sys) must learn the
  display's starve state. It does nothing for the ring gate (phase 2). Not recommended.
- **B3, a deeper descriptor FIFO** (1,024 records, ~20 s; FFmpeg's muxer interleaves at most 10 s by
  default): no lag for any lead under 20 s.
  - Cost: a descriptor is 89 bits ({index, length, PTS, valid}), so 3 M10K become ~9 (1K x 10 each); the
    last fit used 421 of 553.
  - The ring then holds up to ~3.8 MB of unplayed PCM (of 8 MB), and the manual's 256 becomes 1,024 (more
    room only: additive).
  - It complements B1 and does not replace it: a lead past the FIFO, or past the ring, must still not
    stick.

**Gates.**
- `run_disp_anc.sh` (`disp_sched` directly, the audio anchor's bench): X7 the audio-started clock, a picture
  3 s behind with the lead -- taken, not anchored; X8 a late picture contiguous on the timeline (disc's
  lateness leg) with it -- not anchored; X9 the same without it (a stall) -- re-anchors; X10 with it, a jump
  past `FWD_MAX` -- re-anchors. `--red` N6 / N6b (the lead ignored) -> X7 / X8, N7 (the lateness leg gone
  whatever the audio) -> X9, N8 (the lead suppressing the timeline's legs) -> X10.
- `run_aud_play.sh` (`aud_play_tb`'s `[lead]`, scored on every frame played from what the bench saw happen):
  A1 high (the audio waited), A5Q high (the anchor), A11 / A6 / A7 never (no wait; low latency, with a
  running clock and records ahead of it), A12 cleared by a late drop, A13 by an underrun (and untimed
  audio after it does not re-set it). `--red` L1-L5, one per term (an underrun's own clear was dropped as redundant with the queue empty: no
  bench could tell them apart).
- `run_disp_sched.sh` `heldlead` (the `held` scenario with the lead: no re-anchor, its 40 delayed pictures
  shown late), against the model; `--red` D27 (the lead ignored) -> heldlead. `held` and the other
  scenarios unchanged (the lead 0).
- No bench runs `aud_play` and the display together (the cosim's ring mode ties the audio off): the
  end-to-end proof is the rig.
- The fit: SEED 4 103.8 / 102.73 PASS (`history.md` §46).
- **The rig** (`history.md` §46), control arm first. `h264play --pcm-lead 6000` does NOT stick a 1.0 core:
  its pictures are only ~0.9 s late (6 - 5.12 s), under `LATE_MAX`. A lead past ~8 s does: **`--pcm-lead
  10000` stuck the 1.0 core** (3 access units, 2 re-anchors, the program's write timed out) **and plays to
  its end on 1.1** (0 re-anchors, every picture ~4.9 s late, no silence). 1.0.0's Jellyfin client with the
  film's freezing open plays on 1.1 (73 s of clock in 76 s, against 21 s in 60 s on 1.0); its one later
  re-anchor followed the audio running dry, the stall rule.

### The pause and volume word (program word 34, a u32)

| bits | field |
|---|---|
| [0] | PAUSE: a level. Set: the STC frozen, the shown picture held (no pickup), the ring not consumed (the engine stops fetching; polls and the status block go on), audio silent with its position held. Clear: everything continues from where it stopped, the timeline intact |
| [7:1] | zero |
| [15:8] | ATTEN: attenuation in 0.5 dB steps -- 0 full volume, n = -0.5 n dB, 255 mute. Applied to the samples as they leave the gate (a 256-entry gain table, one multiply a channel) |
| [31:16] | zero |

Read with every poll (~32 us when caught up, ~1 ms always). **Range-checked:** a word with a
reserved bit set is refused whole -- the pause and attenuation keep their last values and
`ctl_err` (word 45) is set until a valid word is read. The word is the program's to own: a new
session does not clear it. Why out of band: a pause or a volume change carried in the ring
would wait behind seconds of queued video (`Seeking, and why pause is not a record` above).
Main's own volume (its OSD, `vol_att` into `audio_out`) stays on top of it.

### The status: a second core region (words 40-47)

The core's words 0-31 are full; words 32-39 are the program's (32-35 used, 36-39 reserved for
it). **The core writes words 40-47 as a fifth burst** after the four, every raster frame, under
the same seqlock (seq_tail read first, seq_head last, both unchanged in place). Additive:
nothing below word 40 moves. Fields (`ring_layout.py` `WORDS` is the list): the audio state
(off / armed / playing) and its mode (paced / low latency), the queue in samples and in
records, samples played, the counted slips (`aud_gap`, `aud_late`, `aud_underruns`,
`aud_slip_drop`, `aud_slip_rep`, `aud_anchor`), the A/V offset (the STC minus the PTS at the
last tagged record's first sample, signed ticks), the ring bytes audio holds (the fetch index
minus the published index), and the pause word as applied (`paused`, `atten`, `ctl_err`).

### The fabric side (0.5)

| module | clock | role |
|---|---|---|
| `h264/ring_rd.sv` | clk_sys / clk_mem | the parser pushes audio descriptors and waits when the FIFO is full; the engine serves the audio fetch (a request toggle with stable fields, answered after its words are pushed), reads word 34 in its poll, stops the ring fetch while paused, and publishes the released index (`cdc_snap` from clk_sys, accepted only inside the session's `[start, fetched]` so a snapshot from before a clear can never move it backwards) |
| `h264/aud_play.sv` (new) | clk_sys | the descriptor FIFO, the fetch, the sample FIFO's read side, the gate (paced / low latency), the 48 kHz tick, the attenuation, the audio anchor request, the held index, the counters |
| `h264/disp_sched.sv` | clk_sys | an external anchor (the audio's); the first picture after one is scheduled, not anchored, inside the bounds; the tick gated by the pause |
| `h264/disp_ctl.sv` | clk_sys | the pause: no evaluation or pickup while paused (the shown picture held; nothing counted as starved or late) |
| `h264/ring_stat.sv` | clk_sys | 40 words a frame, five bursts (the status FIFO's room check follows; 0.10: 48, six) |

### Known limitations (0.5)

- One format: 48 kHz s16 stereo. The program resamples and downmixes.
- At a DISCONTINUITY without END_OF_STREAM, the audio queued ahead of it is dropped with the
  video's queue at the moment the reader reaches it (the video's rule since 0.1). With
  END_OF_STREAM first it plays out (above).
- The low-latency target and slip rule are fixed parameters.
- `sys/audio_out.sv` samples `AUDIO_L/R` through two flops at its own 48 kHz (`clk_audio`, a
  separate PLL off the same crystal): the framework's convention for every core. The two
  48 kHz grids differ by the PLLs' fractions (ppm), so the framework's zero-order hold repeats
  or skips a sample at that rate -- inaudible, and not ours to fix.
- Main's audio filter (the OSD's system menu) applies to this core's output like any core's.

**Gates:** the audio path against a model (bench, `--red`: each arm catches its own mutation
-- the gate opening early, the tick's rate, a slip or a drop uncounted, the pause not
freezing the STC, a descriptor lost, the held index released early); on the rig, A/V sync
measured with a generated clip (a flash and a beep on the same frame) through the HDMI capture
card, which records the audio too; the proving ground a moonlight-embedded port (its Opus
decode on the ARM already exists).

## Input (interface 0.6): Main's input, mirrored for the program

Designed 2026-09-29 with the maintainer (`moonlight.md` M5, §7). **Why through the core:**
while a core runs, Main holds an exclusive `EVIOCGRAB` on every input device, so a program on
the ARM that opens `/dev/input` never receives an event (measured, `history.md` §12). Main
already hands the core everything a game-stream client forwards through `hps_io` -- six pads,
every key as a PS/2 set-2 scancode, the mouse -- so the core mirrors that into the control
block and the program forwards it. Stock Main, the user's own pad mapping, Bluetooth, and
Main's own OSD gating come with it.

### What Main sends (read from its source, 2026-09-29; `moonlight.md` §7 has the citations)

- **Keys:** one `ps2_key` event per key change (`[7:0]` the set-2 code, `[8]` E0-extended,
  `[9]` pressed, `[10]` toggles per event), sent the moment Main reads it: the events of one
  USB report (a modifier and a key) arrive **microseconds apart**, so the core must watch the
  toggle every clk_sys cycle and queue. No key repeat (`PS2WE=0`: Main drops evdev's value 2).
  Never sent: F12 (Main's menu, `F12KEYMOD=0`), the Menu / Homepage keys, Win+PrtSc,
  Alt/Win+ScrollLock, Mute / Volume, F17-F20; NumLock and ScrollLock presses switch Main's
  keyboard-emulation mode and are not sent, **their releases are** (a break with no make).
  Pause arrives as one pressed event (`E1` sequence -> extended `0x77`) on the key's release;
  PrintScreen as extended `0x7C`.
- **Mouse:** one `ps2_mouse` packet (`[24]` toggles) about every 15 ms while it moves, at once
  on a button change: `[2:0]` L R M, 9-bit dx / dy (sign in `[4]` / `[5]`, Y up-positive),
  each clamped to +-255 by Main (the excess is lost there); `ps2_mouse_ext [7:0]` the wheel
  (+-63), `[12:8]` buttons 4-8. Relative only: Main has no absolute pointer for a core.
- **Pads:** `joystick_N [31:0]` -- `[3:0]` right, left, down, up, then one bit per name of
  `CONF_STR`'s `J` line, in the user's MiSTer mapping; sent on change as 16-bit halves, the
  upper half only once a bit >= 16 was ever set (which is why this core's pad stays at 16 bits:
  no torn words). `joystick_l_analog_N` / `_r_analog_N [15:0]`: Y `[15:8]`, X `[7:0]`, signed
  -127..127 after Main's deadzone. **No analog triggers reach a core** (Main turns trigger axes
  into buttons). A player number is given on a pad's first press (up to six).
- **The OSD:** while it is open Main sends keys, buttons and the mouse to the menu, not the
  core. When it opens Main **zeroes the pads** but **releases no key** and leaves the sticks at
  their last value; a key held across it reaches the core as a break with no make.
  `OSD_STATUS` (into `emu`) is high while the full OSD is shown (not for an info message).

### The region: words 48-71, written by the core

| word | contents |
|---|---|
| 48 | **in_head** `[31:0]`: +1 each write of the region; **ev_count** `[63:32]`: events queued since the core's PLL lock (free-running) |
| 49-54 | pad 0-5: `joystick_N [31:0]`, left stick `[47:32]`, right stick `[63:48]` (hps_io's values verbatim) |
| 55 | mouse: **dx_sum** `[31:0]`, **dy_sum** `[63:32]` -- signed sums of every packet's dx / dy (Y up-positive), wrapping |
| 56-63 | **the event queue**: 32 entries of 16 bits, event n at entry `n % 32` = word `56 + (n % 32) / 4`, bits `16 * (n % 4)` |
| 64 | **wheel_sum** `[31:0]` (signed, wrapping); **mouse_btn** `[39:32]` (the buttons now: `[0]` L `[1]` R `[2]` M `[7:3]` buttons 4-8); **osd_open** `[40]`; **ev_lost** `[63:48]` (events the core itself could not queue: saturating, 0 in any real use) |
| 65-70 | reserved (0) |
| 71 | **in_tail** `[31:0]` (the same count as in_head) |

**An event** (16 bits): `[15:14]` the type -- **0 a key**: `[9]` pressed, `[8]` extended, `[7:0]`
the set-2 code (hps_io's `ps2_key [9:0]`); **1 the mouse buttons changed**: `[7:0]` the buttons
now (word 64's bit order); **2 the OSD**: `[0]` open (1) or closed (0); **3 (0.8) an OSD action**:
`[7:0]` its number (below). Keys, button changes, the OSD's edges and its actions share one queue so the program sees them **in the order they
happened**: a Shift-click stays one, and a key released after the OSD closed is not mistaken
for one pressed before it opened.

**Reading it:** a seqlock of its own -- read in_tail (71) first, then the words, then in_head
(48) last; equal means no write overlapped the copy, else retry. The program keeps its own
event count `c`; the new events are `c .. ev_count - 1`. If `ev_count - c > 32` the oldest were
overwritten before it read them: it counts them lost and treats its idea of what is held as
unknown (the Moonlight client releases everything). Movement: the difference of two sums (mod
2^32); a sum never loses anything between reads. The pads are a snapshot (their state is what
matters; a tap shorter than the write spacing below, ~1 ms, can be missed -- Main itself merges
changes within one of its polls).

**When it is written:** whenever something changed (an event queued, a sum moved, a pad or
stick differs), **at most once a millisecond** (27,000 clk_sys cycles from the last write's
start), and once each raster frame regardless (so `in_head` is also a heartbeat). Three
8-word bursts in order, 48-55, 56-63, 64-71, through the status block's path (below). Writes
are cheap on ram1 (they do not hold the grant through a read latency,
`hw_budget_and_lessons.md` §2): at most 3,000 bursts a second while input moves, none extra
while it is idle beyond the frame's. The latency this adds: up to 1 ms, plus the program's
own polling period (the Moonlight client polls every 1 ms: ~2 ms at most, against 16.7 ms had it
ridden the frame's write).

**Consistency inside a write:** while the region's 24 words are being pushed (a few dozen
clk_sys cycles) the queue, the sums and the button state are frozen; an event arriving then
waits in a one-deep pending register per source (key, mouse, OSD) and is applied after. A
second event from the same source before that -- impossible at Main's pace (each event is its
own multi-word bus transaction) -- is counted in `ev_lost`, never dropped silently. The pad
words are read live (each is its own word; hps_io changes one at a time).

**Resets:** the region's counters and sums reset with the PLL lock only, like the heartbeat:
an OSD Reset (which drops the ring's session) does not move them, so a program forwarding input
keeps its count across it.

**Discovery:** the interface version (0.6 or later): word 1 has no free field to name the
region, and the library then required the exact version (since 1.0: the same major, a minor at least its own).

### The OSD's actions (0.8)

Decided 2026-09-30 with the maintainer (`moonlight.md` M11). Every pad button is the game's or
Main's (the pad's Guide / Home opens the OSD), so a player could not reach the program itself:
a game-stream client could not send the host's Guide (Steam's overlay, the Xbox Game Bar), and a
program with its own menu (Phase 6b) could not be asked to open it. The core's OSD gains two
entries with generic names -- the core serves any program:

| `CONF_STR` | status bit | action | the Moonlight client |
|---|---|---|---|
| `R[17],Send Home to the program` | 17 | 0 | the host's Guide, a 100 ms tap on the first announced pad |
| `R[18],Program menu` | 18 | 1 | reserved for its menu (Phase 6b): ignored, logged |

Both exist now so the OSD's layout never changes when a program starts using the second.

- **What Main does** (`menu.cpp` ~2580, the `R` line's branch): `user_io_status_set(opt, 1)`
  then `user_io_status_set(opt, 0)` -- two SPI transactions, microseconds apart, each writing
  the whole 16-bit slice (`hps_io`'s `status[31:16]`: both bits in one slice) -- then
  `menustate = MENU_NONE1`: the OSD closes on a later pass of Main's loop. So the action's
  event is queued **before** the OSD-closed event, always. A program must take action events
  while it ignores input for the open OSD, and act on them after the close (the Moonlight
  client then sends the Guide on a pad the OSD's opening released).
- **The core** (`h264/ring_in.sv`): the rising edge of `status[17 + n]`, watched every clk_sys
  cycle (the pulse is microseconds: a level sampled at the region's write could miss it; the
  Reset line is latched the same way). The pending register is a mask, one bit an action,
  applied lowest first, after a key and a mouse event and **before an OSD edge** (the order it
  happened in). An edge of an action already pending is counted in `ev_lost` -- impossible at
  Main's pace. `IN_ACTIONS` (2) in the layout names the count.
- **Never saved set, never set by a program:** Main clears the bit itself; `h264/osd_req.sv`
  (the program's settings request, 0.4) forces `status_in[18:17]` to 0 like the Reset bit, so
  a request landing inside Main's pulse cannot leave an action set in Main's copy (and a
  program cannot trigger an action through Main).
- **Bits 17 and 18** were free (allocated once: `CONF_STR`'s comment lists them).

Rejected: the Guide back on the pad as bit 16 (M8's reasons stand: Main would send the word in
two halves, and Main's own menu button defaults to the pad's Guide / Home).

### The pad (the `J` line)

`CONF_STR` declares `JN,OK,Back,Page Back,Page Forward,Pause/Play` (bits 4-8; `[3:0]` remain the d-pad).
Only the five controls used by the programs are offered in MiSTer's button mapping: OK and Back
for navigation, with the shoulders available as optional Page Back / Page Forward shortcuts and Start toggling pause/play.
`JN`: Main does not turn the left stick into d-pad bits (`JD`, its default) -- the stick and the
d-pad reach the program separately. Never `J1` (it turns the keyboard into player 1's pad) or
`X` (it disables the OSD). `jn,A,B,L,R,Start` gives Main its normal automatic mapping by **name**.
The compact button slots are translated at the `ring_in` boundary to the established input-region
layout (d-pad `[3:0]`, B `[5]`, A `[4]`, LB `[8]`, RB `[9]`, Start `[11]`), keeping the application interface's
button meanings. **No Guide button** (decided 2026-09-29): it would be bit 16 -- Main then sends
the word as two halves (a torn read) -- and Main's own menu button defaults to the pad's Guide /
Home button anyway.

### Rumble: not in 0.6 (since 0.13)

Not in 0.6 (decided 2026-09-29: program words 36-37 reserved for it); built in 0.13, "Rumble
(interface 0.13)" below.

### The fabric side (0.6)

| module | clock | role |
|---|---|---|
| `h264/ring_in.sv` (new) | clk_sys | the toggles watched every cycle; the queue (32 x 16 registers), the sums, the button state, the pending registers and the freeze; `in_req` (changed and 1 ms since the last write, or a frame); the region's words through `ring_words_in` (generated) |
| `h264/ring_stat.sv` | clk_sys | two jobs through one status FIFO: the frame's 40 words (as before; 48 since 0.10) and the region's 24; a job runs whole, groups of eight never interleave; a frame that arrives during an input job is kept pending (not skipped); room is checked per job (48 or 24 free) -- and (2026-10-05) a frame that finds too little room, the input job's words still in the FIFO, waits for it (the engine drains it in microseconds) instead of being skipped: since 0.10's 48 words that collision skipped frames (`run_ring_in.sh` I1 / I2). Only a frame pulse that lands on one still waiting is lost and counted |
| `h264/ring_rd.sv` | clk_mem | the status FIFO's word index is 7 bits (word 71); nothing else changes: a group's address is its first word's |
| `h264/emu.sv` | -- | hps_io's pad, analog, `ps2_key`, `ps2_mouse`, `ps2_mouse_ext` ports wired; `OSD_STATUS` (already synchronised for word 4) into `ring_in`; (0.8) `status[18:17]`, the OSD's actions, into `ring_in` |

### Known limitations (0.6)

- No analog triggers, no absolute pointer, no Guide button, no rumble (above: Main's limits, or
  decided; 0.13: rumble, "Rumble (interface 0.13)"). (0.8: a program reaches the host's Guide through the OSD's action 0, or its own
  chord -- the Moonlight client's Back + Start.)
- Main's clamp: a mouse moving more than 255 counts in one ~15 ms packet loses the excess
  (in Main, before the core).
- Keys Main keeps (F12, Menu, the media keys, NumLock / ScrollLock presses) never reach a
  program; a program should ignore a release of a key it does not hold.
- Pads are a snapshot at <= 1 kHz.

## Rumble (interface 0.13): the program's words 36-38, played by Main

Designed 2026-10-04 (`moonlight.md` M9, now built). A game-stream host sends rumble for each of
its virtual pads (Moonlight's `rumble` callback); the pads are Main's (it holds every input
device while a core runs), and Main already plays a core's rumble: `hps_io`'s
`joystick_0..5_rumble [15:0]` inputs, `{large [15:8], small [7:0]}`. The core passes the
program's values to them.

### What Main does (read from its source, 2026-10-04: `input.cpp` `set_rumble`, `rumble_input_device`)

- In its input loop, while a core other than the menu runs and `RUMBLE=1` (`MiSTer.ini`, the
  default), Main reads each player's value (`UIO_GET_RUMBLE`, by the player number it gave the pad:
  pad n of the input region is player n + 1, `joystick_n`) and, **when it differs from the last one
  read**, uploads an `FF_RUMBLE` effect to that pad (strong = large x 257, weak = small x 257) with a
  length of **0x7FFF ms = 32.767 s** and plays it; a value of 0 removes the effect.
- Only a pad whose Linux driver declares `FF_RUMBLE` rumbles (most USB and Bluetooth pads: Xbox,
  DualShock / DualSense, 8BitDo in X-input mode); Main's OSD does not stop it (as on every core).

### The words (program, u32 each, the low half; the high half is ignored, as word 32's)

| word | `[15:0]` | `[31:16]` |
|---|---|---|
| 36 | pad 0 | pad 1 |
| 37 | pad 2 | pad 3 |
| 38 | pad 4 | pad 5 |

Each value is `{large [15:8], small [7:0]}` -- the low-frequency (strong) motor and the
high-frequency (weak) one, 0 off, 255 full -- `hps_io`'s format verbatim. Two pads a u32, so an
aligned 32-bit store changes both at once and the core never reads half a value. **Every value is
valid** (16 bits, no reserved bits): there is nothing to refuse, so no error field.

**Read with every poll:** the poll's burst grows from four words (32-35) to seven (32-38): ~32 us
when the core has caught up with the ring, at most 1 ms always. Three more beats a poll, and no
second read (a read holds ram1's grant through its latency: `hw_budget_and_lessons.md` §2).
**Measured** (2026-10-04, `run_cosim.sh` GREEN, main -> 0.13, clk_dec cycles a macroblock): x264_sun_ring
697 -> 699, x264_sun 695 -> 698, x264_sunh 726 -> 728, x264_uf_ring 497 -> 502 -- +0.3-1 %, the same
on the windows that do not use the ring (the idle fast poll beside the DPB on ram1); 1.71x real time
unchanged, every window bit-exact. **Applied only
during a session**: before the first, after an OSD Reset, between two, the core gives Main 0 for
every pad -- a program that never wrote the words, or the DDR3 an earlier core left there, cannot
rumble a pad.

### The 32.767 s length: the program keeps a long rumble going (decided 2026-10-04, the maintainer)

A value held unchanged plays for 32.767 s and then stops: Main re-uploads only on a change. A
program that wants a constant rumble longer than that changes the value by one step before then.
**The library does it**: `h264ring_rumble_keepalive()`, called at least once a second, flips the
lowest bit of the large motor's value (the small's when the large is 0) of each pad whose value is
nonzero and has not changed for `RUMBLE_KEEPALIVE_MS` (10 s) -- 1/255 of the motor, imperceptible,
and never to 0 (a value of 1 alternates with 2). **Why the program and not the core:** a program
that dies with a session open (a crash, a `kill -9`) leaves its words as they were; were the core
refreshing the effect, the pad would buzz until the next session or an OSD Reset. With the refresh
in the program, Main's 32.767 s is the dead program's stop. Rejected: the core refreshing (above);
nobody refreshing (a racing game's idling engine, a held rumble, stops after 33 s).

### The status (core words 82-83, the third region, every raster frame)

`rum_p0`-`rum_p5`: the values passed to Main now (0 outside a session); `rum_changes`: how many
times the applied values changed (any pad; wrapping, since the PLL lock), counted on clk_sys where
they reach `hps_io` -- it counts what reached Main, not that a poll ran.

### The library (`hps/`)

`h264ring_rumble(r, pad, large, small)` stores the pair's u32 (a shadow of words 36-38 in the
handle: the program is their only writer). The library writes zeros to the three words at the
first session a handle starts (an earlier program's values never carry over) and at
`h264ring_close` (when it ran a session; `h264stat`, which attaches without the lock, never writes
them), and never at a flush (a program's rumble survives its own session restarts). Call the two
rumble functions from one thread.

### The fabric side (0.13)

| module | clock | role |
|---|---|---|
| `h264/ring_rd.sv` | clk_mem -> clk_sys | the poll's burst of seven; words 36-38's low halves taken whole at the poll's end; 0 unless a session is open; a `cdc_snap` (96 bits) to clk_sys: `rumble`; `rum_changes` counted there |
| `h264/emu.sv` | -- | `rumble` into `hps_io`'s `joystick_0..5_rumble` (were tied to 0); words 82-83 into `ring_words_sys` |

### Known limitations (0.13)

- No trigger rumble (an Xbox One pad's impulse triggers: Moonlight's `rumbleTriggers`): Main has
  no trigger motors for a core.
- Main's scaling is its own: an 8-bit value per motor, x 257.
- A pad Main has not given a player number to (no button pressed since it was connected) does not
  rumble: Main reads by player.

## The overlay plane (Phase 6b, interface 0.9): the Linux framebuffer as the overlay

**Status: decided with the maintainer (the framebuffer as the overlay 2026-09-29; the mapping
and the formats 2026-09-30); ✅ MERGED (PR fj#21), ✅ HW-CONFIRMED 2026-10-01 (the RetroTINK, a CRT, an
HDMI capture: `history.md` §20).** An interface change (0.9,
additive): the manual's `integrating/` pages in the same change.

**Why.** A program on the ARM needs its own screens -- a media browser, a Moonlight host list,
a pause menu, subtitles, "connecting..." -- over the decoded video, on HDMI AND on a CRT. The
first plan (a palette canvas in DDR3 beside the ring, drawn through `hps/` helpers) works, but
every existing Linux client would rewrite its UI for it. Two MiSTer projects were read for how
they mix an ARM-side UI with video (2026-09-29):

- **MiSTerFin** (a Jellyfin client): no core; MPlayer decodes on the ARM into `/dev/fb0`, the
  Linux framebuffer the scaler (ascal) shows; the UI is its own software renderer into the
  SAME surface. UI and video take turns; over playing video only MPlayer can draw (its OSD,
  subtitles) -- drawing into the shared buffer flickered. It works only because the server
  transcodes to MPEG-2 at <= 720x576 / 30 fps (H.264 was too heavy for the Cortex-A9). CRTs
  get the scaler's output (`vga_scaler=1` with a 15 kHz `video_mode`; true 480i / 576i needs a
  third-party Menu core and pausing Main).
- **Groovy_MiSTer**: a patched Main and its own core; a PC renders everything, menus included,
  and streams raw / LZ4 frames into DDR3; the ARM draws nothing but a screensaver logo.

Neither composites an ARM-side UI over hardware-decoded video. This core can: the overlay's
source is the Linux framebuffer itself.

**The model.** The program draws its UI into `/dev/fb0` with ordinary fbdev code (its own
renderer into the mapped page), as it would on any Linux box; the core reads that memory on
`ram2` and composites it over the decoded picture -- or the idle screen, or black -- on ITS OWN
raster, so it reaches HDMI and the analog pins alike, at 480i / 576i / 60.00 Hz, anti-twittered
at 480i. A ported client keeps its UI and swaps its player for the ring. Main's OSD (the `osd`
module in `sys_top`) stays on top of both.

**The framebuffer's geometry comes from the program, not from Main.** `sys_top` already
receives it from Main (command `0x2F`: `LFB_EN`, base, width, height, format, stride), but
`LFB_EN` also switches ascal to show the framebuffer INSTEAD of the core (HDMI only, the
analog pins untouched): the switch this design must avoid. **Also for the input (0.6):** Main
showing fb 0 un-grabs the devices and stops sending the core any input (`video_fb_enable` ->
`input_switch(0)`), so the input region would go dark while the overlay is up
(`moonlight.md` §7, "The framebuffer as the way to the devices"). So the program leaves Main's
framebuffer switch off and describes its page in its own control-block words (the descriptor,
below).

### Decided (the maintainer, 2026-09-30)

- **The mapping is the identity, centred.** One canvas pixel is one raster pixel. The raster is
  720 pixels by 480 frame lines (576 at 50 Hz); the canvas, at most 720 x 576, is centred on
  it: canvas pixel (x, y) is raster pixel (x + ox, y + oy), ox = (720 - width) >> 1, oy =
  (lines - height) >> 1 (arithmetic: a 576-line canvas on the 480-line raster loses 48 lines
  top and bottom, flagged `ovl_clip`). No scaling: the sharpest text, no resampler in the
  fabric. The program draws for the raster's pixel aspect, which the status reports (word 47:
  the aspect HDMI's scaler is given; the analog raster is 4:3). **The cost, accepted:** on HDMI
  in Progressive with Aspect Auto the raster carries the stream's exact aspect, so a UI drawn
  for 4:3 stretches with a 16:9 stream unless the program redraws for word 47. A scaled canvas
  can come later, additively: the descriptor carries the canvas size and word 78 is reserved
  (0) for it.
- **The formats are `1555`, `4444` and `8888`, straight (not premultiplied) alpha.** The (1, 2,
  1) at 480i turns a 1-bit edge into 1/4, 1/2, 3/4 coverage, so the composite multiplies
  whatever the format; per-pixel alpha then costs only the unpack. `1555` stays the default
  (measurement 2); `4444` gives antialiased text and translucent panels at the same 16 bpp cost;
  `8888` costs twice the traffic -- measured again on the built plane at the headroom clock
  (measurement 3 below): a full-height 8888 canvas costs D1's densest stream ~1 % of the
  decoder's time and leaves ~4.5-5 % to spare, so it fits; the band still saves what a program
  does not draw. An 8888 program must write the alpha byte:
  fbdev code that leaves the X byte 0 draws an invisible overlay.

### The descriptor (program words 72-79)

One u32 in the low half of each 64-bit word (the high half is ignored), like every program word:

| word | field |
|---|---|
| 72 | `gen_lo`: the generation, written LAST |
| 73 | `ctl`: [0] ENABLE; [2:1] FORMAT -- 0 `1555`, 1 `4444`, 2 `8888` (3 refused); the rest 0 |
| 74 | `base`: the physical byte address of the page shown (a multiple of 8) |
| 75 | `size`: [15:0] width, 1..720 pixels; [31:16] height, 1..576 lines |
| 76 | `stride`: [15:0] bytes from one line to the next (a multiple of 8, at least width x bytes a pixel); [31:16] 0 |
| 77 | `band`: [15:0] the first line drawn on, [31:16] the last (first <= last < height): only these are fetched |
| 78 | reserved, 0 (a scaled canvas, later) |
| 79 | `gen_hi`: the generation, written FIRST |

**Read once a refresh** (a field at 480i / 576i) by the overlay's own engine, on `ram2`, as one
ascending 8-word burst at the vertical blank's first line; what it reads applies from the next
refresh's first line, never mid-picture. **A page flip is a new `base`**: a double-buffered
program never shows a half-drawn page; a single-buffered one may tear (its choice). `ovl_gen`
(word 46) tells the program which descriptor the core read last: the read happens in a vertical
blank, after the refresh that used the old page, so once `ovl_gen` shows the new generation the
core never reads the old page again and the program may draw into it.

**A consistent copy, the program writing:** it writes `gen_hi` = g, then the fields, then
`gen_lo` = g (g new each time; a barrier between the stores); the core's burst reads word 72
first and 79 last and takes the descriptor only when `gen_lo == gen_hi`. A read that overlaps a
write sees them differ -- counted (`ovl_torn`) and ignored, the descriptor in use kept; the next
refresh reads again. A change of `base` alone (a page flip) is one aligned store and may be
written alone.

**Range-checked on arrival** (`spec_hardening.md`: the core never trusts the ARM). A consistent
descriptor with ENABLE set is REFUSED -- the overlay off, `ovl_state` 2, `ovl_err` the first
check failed -- unless all pass:

| `ovl_err` | name | the check |
|---|---|---|
| 1 | CTL | `ctl`'s reserved bits and word 78 zero; FORMAT not 3 |
| 2 | SIZE | width 1..720, height 1..576 |
| 3 | STRIDE | a multiple of 8, at least width x bytes a pixel, the high half 0 |
| 4 | ALIGN | `base` a multiple of 8 |
| 5 | BAND | first <= last < height |
| 6 | RANGE | the whole canvas inside the Linux framebuffer's region, `0x2200_0000` + 8 MB: base >= `0x2200_0000` and base + (height - 1) x stride + width x bytes a pixel <= `0x2280_0000` |

A consistent descriptor with ENABLE clear turns the overlay off (`ovl_state` 0, `ovl_err` 0).
**Shown only during a session** (word 4's LIVE SESSION): DDR3 survives a core load, so a
previous program's descriptor must never put its page on screen after a reload (`mgl_launch.md`
rule 5); an OSD Reset hides the overlay until a new session. (`ovl_state` 1 means accepted; the
overlay is on screen when SESSION is also set.) **The library writes the program's descriptor --
or one with ENABLE clear -- before every session's nonce** (as it writes word 34), so a program
that starts a session never shows another program's page, and a program that re-starts its own
(after an OSD Reset) keeps its overlay.

**`smem_len` follows Main's HDMI mode** (measured on .201 2026-10-04, stock Main, the H264 core
loaded, `docs/hd_raster.md` §13): `video_mode=2` (720x480) 1,382,400 bytes (stride 2,880),
`video_mode=0` (1280x720) 3,686,400, `video_mode=8` (1920x1080) 8,294,400 -- width x height x 4
(`fb_size` 2 / 4 halve / quarter it). A program lays its pages out inside `smem_len`, never inside
the 8 MB region: hd_raster stage B's UI rows at a fixed 2,048 pixels left a 1280x720 mode 450 lines
a page and no UI (fixed: rows the raster's width, `clients/common/ui.c`). The manual says so
(`integrating/overlay.md` "How much framebuffer there is").

**Where Main puts things in the region** (read in Main_MiSTer's `video.cpp`, 2026-09-30): its
`FB_ADDR` is `0x2200_0000` and its page n is at `FB_ADDR + n x 1920 x 1080 x 4` (8,294,400 bytes),
page 0 shown from +4,096 (`video_fb_enable`); Main draws into pages 1 and 2 -- the Menu core's
backgrounds, from `0x227E_9000`, past the region's end -- only while the Menu core runs. While
this core runs, nothing of Main's writes the region except the Linux console on F9.

**Measured on the rig (2026-09-30, the SuperStation, stock Main, the H264 core loaded):**
`/dev/fb0`'s `smem_start` is **`0x2200_1000`** (Main's +4 KB), `smem_len` 8,294,400 (1920 x
1080 x 4: **Main's HDMI mode**, 1920x1080 on that day -- NOT a fixed size; corrected 2026-10-04,
below); its 8888 layout is red 16 / green 8 / blue 0 /
transp length 0 -- bytes B, G, R, X, this interface's `8888` with the alpha in the byte the
driver leaves unused. **The kernel's console writes the region on its own:** fbcon is bound to
fb0 (`vtcon1`), an `agetty` holds tty1, and its blinking cursor changed 16 lines of one text cell
(the lines 32-47 of the 1920-wide mode: byte +0x3C0C0 .. +0x582C0 from `smem_start`) within 2 s
of a pattern written over the whole region; with `cursor_blink` 0 and the cursor hidden on tty1
(`ESC [?25l`), nothing changed in 30 s. So **`h264ring_fb_map` quiets the cursor** (and
`h264ring_fb_unmap` restores it); the console stays bound for Main's F9. A program that maps the
framebuffer itself must do the same.

### The pixels and the composite (normative: the bench's model is written from this)

In memory, little-endian:

| format | bytes | layout, MSB first | alpha a (0..255) |
|---|---|---|---|
| `1555` | 2 | A [15], R [14:10], G [9:5], B [4:0] | A ? 255 : 0 |
| `4444` | 2 | A [15:12], R [11:8], G [7:4], B [3:0] | 17 A |
| `8888` | 4 | A [31:24], R [23:16], G [15:8], B [7:0] (bytes B, G, R, A) | A |

A zeroed page is transparent in every format. Colours widen to 8 bits by replication: 5 bits c
-> (c << 3) \| (c >> 2); 4 bits c -> 17 c.

1. **Premultiply:** P = div255(C a) for R, G and B; P_a = a. div255(x) = (x + 128 + ((x + 128)
   >> 8)) >> 8, exactly x / 255 rounded for 0 <= x <= 65,535.
2. **Outside:** a canvas line outside [0, height) or outside the band, and a pixel outside [0,
   width), is P = 0 (transparent).
3. **Anti-twitter** (480i / 576i, when the user's Anti-Twitter is Auto or On -- the overlay is
   graphics by nature; Off leaves it unfiltered): the field line on frame line L shows canvas
   line c = L - oy as (P[c - 1] + 2 P[c] + P[c + 1] + 2) >> 2 per component, alpha included.
   Otherwise, and on the progressive rasters, frame line L shows P[c].
4. **The composite:** out = P + div255(V (255 - P_a)) per colour, V the video (the picture, the
   idle screen or black), clamped at 255 (not reachable: P <= P_a).

### The status (core words 46-47, the fifth burst)

| word | field |
|---|---|
| 46 | [31:0] `ovl_gen`: the generation of the last consistent descriptor read; [33:32] `ovl_state`: 0 off, 1 accepted (shown while a session is open), 2 refused; [34] `ovl_at`: the overlay is anti-twittered; [35] `ovl_clip`: the canvas is taller than the raster; [39:36] `ovl_err` (above; 0 unless refused); [47:40] `ovl_torn` (saturating); [63:48] `ovl_late`: raster lines whose overlay line was not fetched in time -- shown transparent (saturating) |
| 47 | [11:0] `ar_x`, [23:12] `ar_y`: the aspect HDMI's scaler is given (VIDEO_ARX / ARY, a ratio: the whole raster, 720 pixels by its lines, is shown ar_x : ar_y wide); [63:32] `ovl_lines`: canvas lines fetched (free-running: liveness) |

### The fabric side (0.9)

| module | clock | role |
|---|---|---|
| `h264/ovl_plane.sv` (new) | clk_sys / clk_mem | clk_sys: the descriptor request at the vertical blank's first line, its checks when it answers (sequential: one multiply), the line control -- at every line's first dot the NEXT raster line's canvas lines worked out and commanded (a toggle, the fields stable until done): their addresses base + c x stride, each valid inside the canvas and the band -- and the read-out, LAT 5 like the picture's. clk_mem: the descriptor burst; the fetch -- bursts of up to 8 words into a beat FIFO, issued only with room -- the unpack and the premultiply at a pixel a clock, and the (1, 2, 1) as an accumulator line, into one of two line slots of premultiplied RGBA 8888. **Each canvas line is fetched once a field:** a filtered field line's command fetches c and c + 1 and carries P[c + 1] in the accumulator as the next field line's P[c - 1]; the refresh's first line, or one after a line not commanded, fetches c - 1 too |
| `h264/ovl_blend.sv` (new) | clk_sys | the composite, one register after emu's picture / idle selection: the output stage is LAT 6 (sync, DE, CE_PIXEL and VGA_F1 delayed one more; `check_emu_wiring`) |
| `h264/ddr_mux2.sv` | clk_mem | a second instance, on `ram2`: A the display reader, B the overlay (read-only) -- B takes the channel after each A command (measurement 2's shape) |
| `h264/emu.sv` | -- | the instances; the session (`rr_sess`), the Anti-Twitter option and the raster into the plane; VIDEO_ARX / ARY into word 47 |
| `hps/` | -- | `h264ring_overlay_show` / `_hide` / `_wait` / `_check` (the descriptor under a new generation each time: gen_hi, the fields, gen_lo, barriers between), `h264ring_fb_map` (`/dev/fb0` mapped whole, its physical address from `FBIOGET_FSCREENINFO`, refused unless inside the region); `h264play --overlay` (a progress bar, two pages, a 24-line band) |

**A late line** (its command not done when it begins) shows transparent and is counted
(`ovl_late`); the engine is then still busy, so the line after is not commanded either (also
transparent, also counted) and the one after that starts a new chain (fetches its c - 1).

### Known limitations (0.9)

- The identity only: no scaling. The program draws for the raster (720 x 480, or 576 at 50 Hz)
  and its aspect (word 47); on HDMI Progressive with Aspect Auto that aspect follows the stream.
- The descriptor, not the `MiSTer_fb` driver's mode, says what the core reads: fbdev code that
  asks the driver for its format sees the driver's (`/sys/module/MiSTer_fb/parameters/mode`), so
  a program sets the two consistently.
- The overlay's reads cost the decoder time: a full-height 8888 canvas ~1 % at 854x480p60
  (measurement 3), leaving ~4.5 % -- a future stream past D1, or a slower clock, would feel it
  first. The band is the program's lever.
- The framebuffer's region is fixed at `0x2200_0000` + 8 MB (the MiSTer Linux image's device
  tree): a page anywhere else is refused (RANGE), never read.
- The overlay's anti-twitter follows the user's option (Auto and On filter), not the program.
- Main's F9 (the Linux console) switches ascal to the framebuffer on HDMI: a user action.
- The kernel's console draws its cursor into the framebuffer unless it is quieted (the library
  does); anything that writes to tty1 (a login at the prompt, a message to the console) draws
  text into it.
- The cursor's quieting is saved and restored per mapping: two programs mapping the framebuffer
  at once can leave the blink off (seen on the rig when two `h264play` runs overlapped: the second
  saved the first's 0). One program at a time is the interface's model (the lock); a program that
  crashes also leaves it off until the next login or reboot.

### The measurements (on the rig, before the interface was fixed)

1. ✅ **`/dev/fb0` under THIS core** (measured 2026-09-29 on the SuperStation rig, stock
   Main, `H264_p6part2_20260929_1501.rbf`):
   - it exists and is live: `MiSTer_fb` at physical **`0x2200_0000`, an 8 MB region** (the
     device tree's `reg`: `0x22000000 0x00800000`), at the HDMI mode's size when the core
     loads (1920x1080, 32 bpp, stride 7,680: one 8.3 MB page -- too big to fetch);
   - **the program sets its own size and format** through
     `/sys/module/MiSTer_fb/parameters/mode` (`"<fmt> 1 <w> <h> <stride>"`), and it sticks
     (unchanged 10 s later): **720x480 in `8888` (32 bpp), `565` and `1555` (16 bpp -- 1555
     carries a 1-bit transparency per pixel) and `8` (8 bpp paletted)** all accepted. Main
     sets the mode again when a core loads, so a program sets it after launching the core.
     At 720x480x4 the region holds five pages;
   - **drawing into it does not disturb the core's picture**: a full 720x480 frame of noise
     written to `/dev/fb0` left the scaler's output and the core's raster identical --
     Main does not switch ascal to the framebuffer on its own. What still would: the
     user's F9 (Main's Linux console, `fb_terminal=1`), which switches ascal to the
     framebuffer on HDMI -- a user action, documented, not prevented.
2. ✅ **`ram2`'s overlay load against the decoder** (measured 2026-09-29, the SuperStation rig,
   the measurement build `H264_ovlload_20260929_1748.rbf` on the throwaway branch
   `test/p6b-ram2-load`: `h264/ovl_loadgen.sv` reads one 720-pixel overlay line a raster line
   from the framebuffer's region in 8-beat bursts, sharing `ram2` with the reader through
   `ddr_mux2`). The dense 854x480p60 proxy (`sun854_high_8M`, 8 Mbit/s), the decoder's spare
   time (its stall cycles waiting on the display) per arm, the load off first:

   | overlay load | 300-picture stream | 30 s stream (1,800) | ram1's longest wait |
   |---|---|---|---|
   | off (the control; 0.9 % on the old rig too) | 0.9 % | 5.67 % | 45 |
   | 16 bpp (1,440 bytes a line) | 0.4 % | 5.13 % (-0.5) | 44 |
   | 32 bpp (2,880) | 0.0 % | 4.31 % (-1.4) | 49 |
   | 2 x 32 bpp (5,760) | 0.0 % | 2.74 % (-2.9) | 74 |

   Every arm showed all its pictures, errors / fetch-late / the overlay's own late lines 0.
   (The 30 s stream is the clip six times over: all four arms, the control included, count
   292 late pickups -- the concatenation's, not the load's; its spare time is the higher
   figure for the same reason. The deltas are what compare.)
   **The overlay's traffic is NOT free for the decoder**, unlike the display's in MiSTer_DVD:
   `ram2`'s reads slow `ram1`'s (the one SDRAM controller behind both ports), about 0.5 % of
   the decoder's time per 1,440 bytes a line. At D1's densest case (854x480p60, ~0.9 % to
   spare) **a 32 bpp overlay would put the decoder behind real time; 16 bpp fits (~0.4 %
   left)**. Consequences for the design: **16 bpp -- `1555`, whose top bit is the per-pixel
   transparency -- is the overlay's format** (`565` with a key colour the alternative; 32 bpp
   only for pictures below the D1 edge); the program **declares the overlay's visible band**
   (the lines it drew on), and the core fetches only those -- a HUD or a progress bar costs a
   fraction of a full canvas, and a full-screen menu shows over paused or no video; longer
   bursts (16-32 beats) to measure when the overlay is built (occupancy, not bandwidth); the
   last throughput levers (`roadmap.md` P5b) would buy the margin back.
   (Measured at 96.43 MHz, ~0.9 % to spare; superseded by measurement 3 at the headroom clock.)
3. ✅ **The built plane's cost, at 103.85 MHz** (2026-09-30, the SuperStation, stock Main,
   `H264_p6bovl_MARGINAL_20261001_0002.rbf` -- the overlay's own clocks clean, clk_dec 0.15 ns
   short at -40 C before the seed sweep; `h264play --overlay F --overlay-band 0,479`: the bar
   drawn, all 480 lines declared, so every line is fetched). `sun854_high_8M`, one pass each, the
   decoder's spare time (`rc_stall` over the stream's clk_dec cycles, `history.md` §16's rule):

   | raster | off | full 1555 | full 8888 | off again |
   |---|---|---|---|---|
   | 480i (59.94, anti-twitter: each line once a field) | 5.89 % | 5.63 % (-0.26) | 4.96 % (-0.93) | 5.88 % |
   | 480p (Video Output forced Progressive) | 5.73 % | -- | 4.52 % (-1.21) | 5.71 % |

   Every run 300 / 300 pictures, errors / late / skipped / starved 0, `ovl_late` 0. **A full
   8888 canvas fits D1's densest case** at the headroom clock; 16 bpp costs a quarter of a
   point. (The 24-line band of `h264play --overlay` costs nothing measurable: 5.9 %.)

**Superseded, kept as the fallback:** the palette canvas in DDR3 beside the ring (720x480 at
8 bpp, `hps/` drawing helpers) -- had the measurements ruled the framebuffer out.

## The raster (interface 0.10): word 80, and A'

Designed in `docs/hdmi_raster.md` (with Phase 6c's native raster, its stage 2); decided with the
maintainer 2026-10-01 (§9 there). **Additive:** nothing moved; words 47 and 30 keep their places.

**A' (the core's behaviour, no field of its own):** in Progressive with Analog Aspect on Auto a
picture WIDER than the HDMI display (`sar_w Wc HDMI_HEIGHT > sar_h Hc HDMI_WIDTH`) is letterboxed
inside the 720 raster (`disp_fit`'s Fill mode, `oh = round(rh B HW / (A HH))`, the vertical alone
snapping to 1:1 within 3.5 %) and `VIDEO_ARX / ARY` -- so word 47 -- carry the display's shape
`HDMI_WIDTH : HDMI_HEIGHT` (latched at the pickup with the mode). Not wider, or no scaler
(`HDMI_WIDTH` 0): unchanged (fill + the picture's exact aspect). The point: the whole raster, a
program's overlay included, covers the screen, and a scope film's bars are the raster's.

**Word 80 (core, the sixth burst, words 81-87 reserved 0):**

| bits | field |
|---|---|
| [11:0] | `raster_w`: the raster's active width (720 fitted; native: up to 2,048 -- 0.10-0.11: 1,024) |
| [23:12] | `raster_h`: its active frame lines (480 / 576; native up to 2,048 -- 0.10-0.11: 2,047) |
| [25:24] | `raster_mode`: 0 fitted, 1 native, 2 native asked but this picture fell back |
| [26] | `raster_lb`: the raster is shown at the HDMI display's shape with the picture inside it (A', or a display-shaped native raster) |
| [44:32] | `pic_x0`: the shown picture's rectangle (word 30's `fit_ow` x `fit_oh`) on the raster, left, 13-bit two's complement (negative under Crop) |
| [60:48] | `pic_y0`: ... top, frame lines |

**Word 47** now reads "the whole raster (word 80's size) is shown `ar_x : ar_y` wide".
**The library:** `h264ring_raster()` decodes words 80, 47 and 30 (`H264RING_STATUS_WORDS` 88:
words 0-47 and 80-87 copied, 48-79 read 0). `ring_stat`'s word index is 7 bits; the frame is 48
words (the status FIFO holds 64).

**Fabric:** `disp_fit` (`disp_w` / `disp_h`, `lb`; two 12-step shift-add products and a shift,
no DSP), `emu` (`fit_dw_l` / `fit_dh_l`, `ar_x` under `fit_lb`, word 80's sources -- `raster_w`
and `raster_mode` live since stage 2: `raster_geom`'s). **Stage 2 (2026-10-02, `hdmi_raster.md` §13)**:
Video Output's Native (HDMI) (status value 3, accepted by `osd_req` and the library); the overlay's
canvas up to `OVL_MAX_W` 1,024 x `OVL_MAX_H` 2,047 (0.12: 2,048 x 2,048), centred with a signed offset
on the raster's own size and clipped both ways (`ovl_clip`); word 80 describes the native raster.

## The capabilities (interface 0.11): word 81

Designed 2026-10-02 with the maintainer (the 720p branch: `roadmap.md` D1, `spec_hardening.md`).
**Why a word:** every program hard-coded the core's 1,620-macroblock bound (`h264check`, the
Moonlight backend, the Jellyfin profile, the file player); a bound in the core's own words lets a
program follow the core it runs on instead of the core it was built for. **Additive:** word 81 was
reserved 0 in the sixth burst; `H264RING_STATUS_WORDS` (88) already copied it.

**Word 81 (core, constants built into `ring_words_sys` by `tools/ring_layout.py`):**

| bits | field |
|---|---|
| [15:0] | `cap_max_mbs`: the largest picture the core decodes, macroblocks -- 3,600 (Level 3.1's MaxFS: 1280x720, or any shape inside it up to 128 macroblocks a side). A larger picture's slices are discarded and counted in `rc_ref_size` (word 20) |
| [27:16] | `cap_native_h`: Video Output's Native (HDMI) -- the tallest 16:9 picture shown at its own size at 60 Hz, frame lines: **720 since 0.12** (`raster_geom`: an 81 MHz raster of 1,351,350 dots a frame -- every picture the core decodes is native; 0.11: 480, a 27 MHz raster). A taller one would be fitted to the 720-wide raster. A program choosing a transcode's size gains nothing above it (the Jellyfin client asks for 720p only when Native is chosen and this is at least 720) |
| [63:32] | `cap_mb_rate`: the macroblock rate the core is designed for, macroblocks a second -- 108,000 (Level 3.1's MaxMBPS: 1280x720 at 30, 854x480 at 60). Real time below it also depends on the bitrate (`roadmap.md` D1: game streams to 10 Mbit/s and 720p24 films at typical bitrates promised; x264 720p30 above ~4 Mbit/s is visibly behind until the throughput branch); above it the decoding falls behind by design, so a program refuses such a stream (the file player names it "too fast") |

**The library:** `h264ring_caps()` decodes it into `struct h264ring_caps`; a word 81 of 0 (no
status frame yet) reads as 0.10's limits (1,620 / 97,200 / 480). The library refuses any core of
another interface version (`h264ring_open`), so a 0.11 program never meets a 0.10 core (since 1.0: an
older minor or another major); the fallback guards only a read before the core's first status frame.

**The DPB moved** (not part of the interface, recorded here because it shares the region): 20
stores of 2 MiB at `0x3200_0000` (above the ring) instead of 20 of 1 MB at `0x3000_0000` -- a
3,600-macroblock picture is 1.84 MB with its side words (`h264_recon.md` §2.2). Twenty 2 MiB
stores from `0x3000_0000` would have run over the control block (store 10) and the ring.

## Pictures from the program (interface 0.15)

Designed 2026-10-05 with the maintainer (`docs/player.md` "Other codecs", `docs/experiments.md`
"Other codecs decoded on the ARM" and "Writing a picture into the stores"). **Why:** the file
player can decode MPEG-1/2, MPEG-4 Part 2, DivX 3, WMV7/8, Theora, MJPEG and H.263 on the ARM at
SD; their pictures should be shown as the core's own are -- fitted to the raster, deinterlaced,
anti-twittered, paced against the STC with the audio -- not drawn on the overlay (RGB, unfitted,
paced by the program). **How:** the DPB's stores already hold plain planar 4:2:0 (below), so the
program writes the decoded picture into a store itself and sends a small PICTURE record; the core
emits the store to the display exactly as the decoder's output process does (`recon_out`). The
pixels never cross the ring: its parser moves a byte a clk_sys cycle (27 MB/s at most).
**Additive:** record type 5, word 84 and error codes 11-16 were unused.

### A stream is coded or pictures

A stream (from a session's start or a DISCONTINUITY) whose first video record is a PICTURE is a
**picture stream**: the decoder receives nothing and stays idle, and **the 20 stores are the
program's**. A VIDEO_AU in it -- or a PICTURE in a coded stream -- is refused (`STREAM_KIND`); a
DISCONTINUITY or a new session starts a stream of either kind. LOW_LATENCY and GRAPHICS are taken
from the stream's first video record, of either type (later disagreements counted as for a
VIDEO_AU). END_OF_STREAM on a PICTURE: it is the stream's last; the display keeps it up, the state
becomes ENDED once shown; the next video record needs DISCONTINUITY (`NEED_DISCONT`).

### The store (normative: the layout the decoder writes and the display reads)

Store `k` (0 .. `cap_pic_stores` - 1) is `H264RING_DPB_STORE` (2 MiB) bytes at
`H264RING_DPB_BYTE + k x H264RING_DPB_STORE` (`0x3200_0000` +). A picture of `W` x `HF`
macroblocks (`HF` the FRAME height, 16-line units) is planar 8-bit 4:2:0, little-endian (the
leftmost sample in a 64-bit word's low byte), rows packed with no padding:

| plane | byte offset | bytes a row | rows |
|---|---|---|---|
| Y | 0 | 16 W | 16 HF |
| Cb | 256 W HF | 8 W | 8 HF |
| Cr | 320 W HF | 8 W | 8 HF |

A **field pair** is stored woven, in every plane: frame row `2r + p` (luma or chroma) is field
`p`'s row `r` (`p` = 0 top). The coded size is the picture rounded up to whole macroblocks; the
crop (below) says what is shown. The samples outside the crop may be read by the display's
filters at the picture's edges: fill them (the library replicates the edge rows and columns). The
colour is the record's `colour` (0.16: "The colour (interface 0.16)"; 0, auto, is BT.601 limited
for an SD picture); before 0.16 BT.601 limited range always, a full-range source converted by the
program.

### The record (type 5, PICTURE)

Header as every record (PTS_VALID: the picture's PTS, 90 kHz). **Payload: exactly 32 bytes**
(`HDR_LENGTH` otherwise), four little-endian u64:

| word | bits | field |
|---|---|---|
| P0 | [4:0] | `store` (0 .. 19) |
| | [15:8] | `w_mbs` (1 .. 128) |
| | [23:16] | `hf_mbs` (1 .. 128; even for a pair) |
| | [25:24] | `structure`: 0 a frame, 1 a field pair, top field first, 2 a field pair, bottom field first (3 refused) |
| | [35:32] | `pic_struct` (H.264 Table D-1), with [36] `ps_valid` |
| | [47:40] | `aspect_ratio_idc` (H.264 Table E-1: 0 unspecified -- shown as square pixels -- 1 .. 16, or 255 with the SAR below) |
| P1 | [15:0] | `sar_w` (with idc 255; else 0) |
| | [31:16] | `sar_h` |
| | [32] | `timing_valid` |
| P2 | [31:0] | `num_units_in_tick` |
| | [63:32] | `time_scale` (H.264's convention: frames a second = `time_scale / (2 num_units_in_tick)`; 29.97: 1,001 / 60,000; 25: 1 / 50) |
| P3 | [9:0] | crop left, in pairs of columns |
| | [19:10] | crop right |
| | [29:20] | crop top, in pairs of frame lines (a pair's fields lose one line each) |
| | [39:30] | crop bottom |
| every word | the rest | reserved, 0 |

- **A frame** is shown progressive (anti-twittered at 480i under Auto with GRAPHICS / On); its
  duration is two field periods, or by `pic_struct` when `ps_valid`: 0 (two), 3 / 4 (two), 5 / 6
  (three: MPEG-2's repeat_first_field), 7 (four: frame doubling), 8 (six: tripling) -- 1 and 2
  are refused (a lone field is not a picture here).
- **A field pair** is shown as the decoder's field pairs are: each field its own refresh at 480i /
  576i, deinterlaced (Bob / Weave / Blend) on progressive rasters; two field periods; `ps_valid`
  must be 0.
- The field period comes from the timing (`timing_valid`), else 59.94 Hz's (flagged, as an H.264
  stream without VUI timing). Refresh Rate Auto follows it at the stream's first picture.
- Pictures are shown in record order (the program sends them in presentation order).

**Checks on arrival** (in this order, after the header's): the stream's kind (`STREAM_KIND`), the
descriptor's fields (`PIC_FIELD`), the store (`PIC_STORE`), the size (`PIC_SIZE`), the crop
(`PIC_CROP`), and -- at the hand-over on clk_dec -- the store not held by the display
(`PIC_BUSY`). Each stops the session in ERROR, as every record error does.

### The store rule (the program's side, normative)

The program may write a store's pixels only while the display does not need it. Word 84 says:

| bits | field |
|---|---|
| [19:0] | `pic_held`: the stores the display holds (queued or shown) -- set when a store is emitted, cleared when the display releases it |
| [20] | `pic_mode`: the current stream is a picture stream |
| [31:24] | `cap_pic_stores`: the stores a picture stream may use (20; a 0.14 core reads 0) |
| [63:32] | `pic_emitted`: PICTURE records emitted to the display since the PLL lock (wrapping) |

The rule: number each PICTURE written `n = base + 1, base + 2, ...`, where `base` is
`pic_emitted` in the first status copy taken after the session's acknowledgement (a flush or
`h264ring_start_session`) **that shows state READY** -- the stream reset done: the acknowledgement
is published a few microseconds before the reset, and until it the previous stream's decoder may
still write a store and its display hold one. Every store is free then (the reset released them). A store
used by picture `n` is free again when one consistent copy of the status block shows
`pic_emitted - n >= 0` (as a signed 32-bit difference) **and** its `pic_held` bit clear. Sound
because the count and the hold rise on the same clk_dec edge and cross to the status block as one
snapshot; a store emitted and then released is no longer read. The status block is written once a
raster frame, so a program cycling 4-8 stores at 30 frames a second never waits for one.
`h264ring_picture_acquire()` implements it. A store the program has not used since the reset is
free; a coded stream's stores are the decoder's (the library refuses picture calls until a flush
or a session start follows the last VIDEO_AU).

### The library (`hps/`)

- `h264ring_open_devmem(&r, H264RING_OPEN_PICTURES)` also maps the stores (40 MiB at
  `H264RING_DPB_BYTE`; strongly ordered like the ring: ~97 MB/s of aligned stores, a 720x480
  picture ~5.3 ms of CPU -- `experiments.md`).
- `struct h264ring_picture` (the picture in pixels: width, height, structure, `pic_struct` or -1,
  SAR or 0:0, the frame rate num / den or 0) -> `h264ring_picture_layout()` (W, HF, the planes'
  offsets and strides, the crop; -EINVAL for anything the core would refuse).
- `h264ring_picture_acquire(r, &k)` (a free store by the rule, from a fresh status copy; -EAGAIN
  none yet, -EBUSY a coded stream since the last flush).
- `h264ring_picture_copy(r, k, &pic, planes, strides, fmt)`: yuv420p, yuvj420p (full range ->
  limited: Y' = 16 + (219 Y + 127) / 255, C' = 16 + (224 C + 127) / 255), yuv422p / yuvj422p
  (chroma rows averaged in pairs, rounding up -- within each field for a pair -- then converted);
  the edges replicated to the coded size (a pair's padding rows from the last row of their own
  field); aligned 64-bit stores only. Touches only the store: callable from any thread.
- `h264ring_try_write_picture(r, k, &pic, pts, flags)` (`h264ring_write_picture` with a timeout).
- `h264stat` prints word 84.

### The fabric side (0.15)

`ring_rd`'s parser (clk_sys) takes the 32 bytes through its word register into a descriptor,
checks it (`w x hf` by an 8-step shift-add: no DSP), and hands it to **`h264/pic_in.sv`** (clk_dec)
by a four-phase level handshake (`pd_req` / `pd_ack`, the descriptor quasi-static behind it,
`h264.sdc`); a session clear waits for a hand-over in flight (a flush never loses a picture taken).
`pic_in` refuses a held store (busy, answered with the acknowledgement), else drives
`recon_out`'s write side as the decoder's output process does -- the "a" half, a pair's "b" half
(no PTS, so a store's earlier use cannot leak one), the emission (with `pic_emitted`), and, after
END_OF_STREAM, `eos_done` -- through a mux in front of `recon_out` that selects it for a picture
stream (combinational: `recon_dpb`'s view of the holds is not delayed). `{oq_hold, pic_emitted}`
cross to clk_sys as one `cdc_snap` for word 84. A PICTURE's END_OF_STREAM does not raise
`vidfeed_cdc`'s flush (the decoder has nothing to flush, and its own `eos_done` would race
`pic_in`'s).

### Known limitations (0.15)

- The core cannot check the pixels: a program that breaks the store rule shows a torn picture
  (`PIC_BUSY` catches only a store still held when its PICTURE arrives).
- The copy is the ARM's: through `/dev/mem` the region is strongly ordered (~97 MB/s), which is
  why the file player decodes on the ARM only up to SD (`player.md`).
- 8-bit 4:2:0 / 4:2:2 sources. (0.15: BT.601 limited range shown always; 0.16 adds the matrix
  and range, "The colour (interface 0.16)".)

## The colour (interface 0.16): the matrix and range

**Designed 2026-10-06** (`colour.md`; the Jellyfin client's F2). Until 0.16 the display converted
every picture as **BT.601, limited range**. From 0.16 each picture carries a **colour code**,
resolved before it reaches the display, and `disp_reader` converts it with that code's
coefficients (`colour.md` §3):

| code | matrix | range |
|---|---|---|
| 0 | auto (in a record only: resolved as below) | |
| 1 | BT.601 | limited (16-235 / 16-240) |
| 2 | BT.601 | full (0-255) |
| 3 | BT.709 | limited |
| 4 | BT.709 | full |
| 5 | BT.2020, non-constant luminance | limited |
| 6 | BT.2020, non-constant luminance | full |
| 7 | reserved (`HDR_COLOUR`) | |

### The record's field (header word 1 [35:33])

- **VIDEO_AU:** taken from each stream's **first** VIDEO_AU (after a session's start or a
  DISCONTINUITY), as LOW_LATENCY and GRAPHICS are; send the same value on every VIDEO_AU of a
  stream. A later one that differs is counted (`colour_mismatch`, word 86), never obeyed. Non-zero
  overrides the stream's own tags for every picture of the stream.
- **PICTURE:** that picture's code. 0 is resolved by the size rule (a program's picture has no
  tags).
- **PAD, AUDIO:** 0 (`HDR_COLOUR` otherwise). Bits [47:36] stay zero (`HDR_SYNC`).
- A 0.15 program writes 0: auto. For every SD picture auto resolves as 0.15 showed it -- unless
  the stream's own tags say otherwise, which 0.15 ignored.

### Auto (code 0), for a coded stream

From the active SPS's VUI (H.264 E.2.1; absent fields take E.2.1's defaults):

- **The range:** `video_full_range_flag` (absent: limited).
- **The matrix:** `matrix_coefficients` 1 -> BT.709; 5, 6 -> BT.601; 9 -> BT.2020; 4 (FCC) -> BT.601
  and 7 (SMPTE 240M) -> BT.709, approximations (`spec_hardening.md`); **2 (unspecified, also when
  `colour_description_present_flag` is 0) and 3 (reserved) -> the size rule.** **0 (GBR), 8
  (YCgCo), 10 (BT.2020 constant luminance) and 11 and above are not supported**: the size rule,
  and the picture is counted (`colour_unsup`, word 86).
- **The size rule:** BT.709 when the picture as shown (after the crop) is **at least 1,280 wide
  or more than 576 high**, else BT.601 (mpv / libplacebo's convention: every SD picture 601, every
  720p 709).

The matrix only: `colour_primaries` and `transfer_characteristics` are reported (word 86), not
applied -- no gamut or transfer conversion (`spec_hardening.md`). The code applies from the
picture's first line; the analog outputs re-encode the core's RGB as BT.601 (`sys/vga_out.sv`,
`sys/yc_out.sv`), which is right for SD analog at any code.

### The status

| word | bits | field |
|---|---|---|
| 80 | [31:29] | (0.16) `colour`: the shown picture's code (1-6; 1 before any picture; a 0.15 core reads 0) |
| 86 | [7:0] | (0.16) `vui_matrix`: the SHOWN picture's `matrix_coefficients` as its SPS coded it (2 when absent; a program's picture 2) |
| | [15:8] | `vui_primaries`: `colour_primaries` (2 when absent) |
| | [23:16] | `vui_transfer`: `transfer_characteristics` (2 when absent) |
| | [24] | `vui_full_range`: `video_full_range_flag` (0 when absent) |
| | [25] | `vui_colour_present`: `colour_description_present_flag` |
| | [26] | `colour_override`: the stream's first VIDEO_AU set a non-zero `colour` |
| | [31:27] | reserved, 0 |
| | [47:32] | `colour_unsup`: pictures the display took that were shown by the size rule because their matrix is not supported, since the stream began (saturating) |
| | [63:48] | `colour_mismatch`: VIDEO_AUs whose `colour` differed from the stream's first, since the stream began (saturating) |

Word 86 describes the shown picture, as word 80's `colour` does: the decoder's colour description
rides with each picture through `recon_out`'s store table to `disp_ctl`, so both change together at
the picture the display takes (no clk_dec -> clk_sys crossing of its own: status words 80-87 are
clk_sys's).

### The library

`h264ring_set_colour(r, code)` sets the code every later VIDEO_AU carries (0 by default; set it
before the stream's first access unit; -EINVAL past 6). `struct h264ring_picture` gains `colour`
(0 auto; a positional initializer needs one more value). `h264ring_picture_copy()` keeps a
full-range source's samples when the picture's `colour` is a full-range code (2 / 4 / 6) -- the
core converts them, no conversion on the ARM (D-C8) -- and converts them to limited as before
otherwise; a limited-range source with a full-range code is -EINVAL. The error names gained 11-17
(`h264ring_error_name()` stopped at 10 in 0.15).

## Inherited `sys/` edits (all marked `UMD-FORK`, copied byte-for-byte from UMD `main`)

`sys/` is identical to MiSTer_UMD_Video's at 2026-09-27 (`75e3f37` there), so a diff
against that tree shows only changes made here. Comments inside those blocks name UMD
paths (`umd/sys_pll.sv`, `umd/csync_smpte.sv`, `bench/umd/f2sdram_term_tb.sv`); read
`umd/` as `h264/`. This core's own `sys/` edits, when there are any, are marked
`H264-FORK` and listed here.

- SDRAM add-on board ports removed (`sys_top.v`, `sys.tcl`).
- `vol_boost` support and the `audio_out.sv` overflow / saturation fixes.
- `VGA_CS` / `VGA_CS_EN` emu ports + `CS_PIPE` delay + `vga_cs_osd` mux: composite sync
  from the core's own raster, for CRT work (tied off here until the 480i raster).
- `hps_io.sv`: `ini_vga_scaler/ini_csync/ini_ypbpr/ini_sog`, `cfg_seen/cfg_wr`,
  `TIMESTAMP[32:0]`.
- Scanlines DE gate removed.
- `sys/pll_q17.qip`: the Template's `rtl/pll.qip` line removed — every clock comes from
  `h264/sys_pll.sv`.
- **`ram2` to the core** (UMD P5a): emu has a second master `DDRAM2_*`;
  `sysmem_lite.ram2_clk` takes it; `ddr_svc`'s memory side detached. Pinned by
  `tools/check_emu_wiring.py` (the port set equals sys_top's instance, `ram2_address`
  declared above `sysmem_lite`, `ram2_clk` from emu, `ddr_svc` off ram2).
- **`f2sdram_safe_terminator.sv`: the write burst tracked at the port** (UMD, 2026-09-26).
  The stock terminator desynced on a master that drops `write` between beats (legal
  Avalon; UMD's `dpb_mem` does it on every burst) and a core reset inside a write burst
  left the HPS port hung until a reboot -- the "reload hang". The fork counts the beats
  the port accepts. Its bench (`run_f2sdram_term.sh`, K0 = stock) comes over in Phase 2.
- Dropped by UMD from MiSTer_DVD: the S/PDIF and HDMI IEC 61937 passthrough muxes.

This core's own (`H264-FORK`):

- **`sys_top.sdc`: `emu|vid_pll` in the core PLL's clock group** (hd_raster, 2026-10-03,
  `hd_raster.md` §2). The raster's 81 MHz `clk_vid` comes from a second PLL; the stock group
  pattern names only `sys_pll`, and a clock in no group is timed against every framework clock.
  In the group, its crossings are timed and bounded by name in `h264/h264.sdc`.
- **`sys_top.v`: the analog DAC's dither** (added 2026-10-06, `analog.md` §12; **removed 2026-10-19**:
  it worsened macroblocking and tinted component video on a high-bit-depth analog board; never judged on a 6-bit board). It was
  `h264/dac_dither.sv` between the core-raster VGA path's last word (`vga_o`) and the pins, enabled by
  `emu`'s `VGA_DITHER` (OSD Analog Dither, `status[19]`). What remains from 2026-10-19 is the analog
  output register: `vga_od` registers `vga_o` (and the syncs / DE with it), so every analog pin and
  SOG leaves a flip-flop. HDMI and the scaler-to-VGA path (`vgas_o`) are untouched.
- **`sys_top.v`: `emu`'s `HDMI_WIDTH` / `HDMI_HEIGHT` are the HDMI mode's own size** (2026-10-19).
  Stock passes `hdmi_width` / `hdmi_height`, clipped to Main's `HSET` / `VSET`, which under integer
  scaling (`vscale_mode` 1-3) Main derives from the core's raster. The core reads the pair as the
  display's shape (A', `raster_geom`), so in Native (HDMI) the clipped height fed back into the raster:
  on the DE10 with `vscale_mode=1` a 2.39:1 film flipped between 1280x715 (shown x1) and 1439x536
  (shown x2) about twice a second. `hdmi_mode_w` / `hdmi_mode_h` register the unclipped mode in the
  same `clk_vid` block, so the crossing into `emu` is the one it was.
- **`sys.tcl`: `pll_hdmi` pinned to `FRACTIONALPLL_X0_Y1_N0`, its output to
  `PLLOUTPUTCOUNTER_X0_Y5_N1`** (2026-10-11, `history.md` §47). Main sets each HDMI mode's pixel clock
  by rewriting the PLL's physical C counter 0 (and its VCO). A fit that put the output on another
  counter kept the compiled ÷3, so every mode but 1080p ran at the wrong clock (720x480 at 135 MHz:
  black). `tools/hdmi_pll_check.sh` reads the fit report (`build_release.sh`: advisory on a dev build,
  fatal on `--release`). The stock framework has the same exposure: MiSTer_DVD's and UMD's current fits
  happen to sit on X0_Y5 (`harvest.md` "Fixes exchanged").

## Clock-domain crossings

Every crossing is a harvested primitive with its bound in `h264/h264.sdc` (UMD's `umd.sdc`
less its vbuf lines); a new crossing needs its bound in the same change, and
`tools/check_emu_wiring.py` checks that every module an SDC exception names exists.

| crossing | from → to | primitive | bound |
|---|---|---|---|
| the ring's words | clk_mem → clk_sys | `ring_rd`'s data `fifo_dc` | 8 ns |
| the status block's words | clk_sys → clk_mem | `ring_rd`'s status `fifo_dc` + the group toggle (`grp_tog`) | 8 ns |
| the session clear, the engine's error | clk_mem ↔ clk_sys | `ring_rd`'s four-phase `clr_req` / `clr_ack`, `eng_err`'s flag; `start`, `new_sess`, `eng_bad_wi` captured behind them | 8 ns |
| the OSD reset into the engine | clk_sys → clk_mem | `ring_rd`'s `rst_m1` / `rst_m2` (asynchronous assert) | false path on their clear pins |
| the ES bytes, the end of stream | clk_sys → clk_dec | `vidfeed_cdc` (a `fifo_dc` + the flush handshake) | `fifo_dc` gray pointers, 8 ns |
| the resets (per stream, the PLL lock) | → clk_dec, → clk_mem, → clk_vid (hd_raster: the locks, RESET, the per-stream reset) | `cdc_reset` (asynchronous assert, two-flop release) | false path on the flops' clear pins |
| the DPB client's commands and data | clk_dec ↔ clk_mem | `dpb_mem`'s three `fifo_dc` | 8 ns |
| the output queue, the display's releases | clk_dec ↔ clk_sys | `recon_out` (`fifo_dc` both ways) | 8 ns |
| the display's line requests, the shown picture | clk_vid ↔ clk_mem (clk_sys until hd_raster) | `disp_reader`'s request toggle + captured fields | 8 ns |
| (hd_raster) everything the raster side reads: the mode, `raster_geom`'s geometry, the shown picture, the fit, the deinterlace and overlay settings, the idle screen's flag | clk_sys → clk_vid | `emu`'s `raster_dn_xing` (one continuous `cdc_snap`, the `v_*` bundle; its packing pinned by `check_emu_wiring`) | `cdc_snap`'s, 8 ns |
| (hd_raster) the raster side's counters and the overlay's state (words 30, 46, 47) | clk_vid → clk_sys | `emu`'s `raster_up_xing` (`cdc_snap`) | `cdc_snap`'s, 8 ns |
| (hd_raster) the raster's frame events: every refresh (`ring_stat`, `ring_in`), and the frame start `disp_ctl` aligns its grid on, with the mode it was scanned in | clk_vid → clk_sys | two `cdc_pulse`; the mode through `f0_tag_s1` / `_s2` (quasi-static) | `cdc_pulse`'s toggle, the tag: 8 ns |
| (hd_raster) the overlay's line commands and descriptor | clk_vid ↔ clk_mem (clk_sys until hd_raster) | `ovl_plane`'s toggles + captured fields | 8 ns |
| `dec_stub`'s heartbeat | clk_dec → clk_sys | two flops (one slow bit) | none needed |
| the status block's clk_dec / clk_mem words | → clk_sys | `cdc_snap_ix` (`ring_stat`: an indexed request / acknowledge) | 8 ns, the index path included |
| "the END is queued" (P3f) | clk_dec → clk_sys | `recon_out`'s `end_q` (set 8 cycles before the END's FIFO word) | 8 ns |
| (0.5) the audio's fetch request, its answer | clk_sys ↔ clk_mem | `ring_rd`'s `af_req` / `af_ack` toggles, `af_addr_q` / `af_n_q` held while outstanding | 8 ns |
| (0.5) the audio's words | clk_mem → clk_sys | `ring_rd`'s `u_af` (`fifo_dc`, reset by the lock only; `aud_play` counts what it is owed) | `fifo_dc` gray pointers, 8 ns |
| (0.15) a PICTURE's descriptor, its answer | clk_sys ↔ clk_dec | `ring_rd`'s `pd_req` / `pic_in`'s `pd_ack` (four-phase levels), the descriptor and `pd_busy` held behind them | 8 ns |
| (0.15) the stores' holds and `pic_emitted` (word 84) | clk_dec → clk_sys | `emu`'s `pic_xing` (`cdc_snap`) | `cdc_snap`'s |
| (0.5) the released index; word 34 as applied | clk_sys → clk_mem; clk_mem → clk_sys | `ring_rd`'s `u_rel` / `u_ctl` (`cdc_snap`); the engine takes a released index only inside `[start, fetched]`, never backwards | 8 ns |
