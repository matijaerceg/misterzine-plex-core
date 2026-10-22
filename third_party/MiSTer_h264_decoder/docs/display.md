# Display (roadmap Phase 5)

> **Harvested from MiSTer_UMD_Video at `cc595c6` (2026-09-27, this core's Phase 2).**
> This is UMD's design note for the display path (output order, scheduler, reader), kept for its rationale: the module
> paths are rewritten to this tree (`umd/h264/` → `h264/dec/`, `umd/` → `h264/`,
> `bench/umd/` → `bench/h264/`), the rest is UMD's text. "Phase 5" and "roadmap" below
> mean **UMD's** phases and roadmap. UMD-only material is history here, not this core's
> design: the disc images (Akira, Family Guy, the library sweeps and their numbers), the
> program-stream demux and the ISO reader, the on-screen HUD, the vbuf and UMD's rig
> measurements. This core's differences: the fixtures (x264 and H.264.1 instead of discs,
> `docs/harvest.md`), the input (the ioctl stand-in, then Phase 3's ring:
> `docs/architecture.md`), the deviations (`docs/spec_hardening.md`, re-decided
> 2026-09-27). Changes made here after the harvest are marked **H264:** in place.


The display path from a decoded picture in the DPB to the raster: which picture, when,
through which port, and how a field pair is shown. `docs/roadmap.md` Phase 5 is the plan;
this note is the design as built, stage by stage. Status per stage at the end.

## 1. Scope and the decisions behind it

**Phase 5's scope (decided with the maintainer 2026-09-25): the core
display path on the 480p raster.** The 480i raster + csync, the analog vertical scaler
(Letterbox / Crop), a Film 24p raster and `av_sync` are later work (roadmap).

**ascal cannot blend.** Fed a 480i raster (`VGA_F1` toggling), ascal detects interlace
from the flag and **weaves** (default) or **bobs** (`HDMI_BOB_DEINT = 1`: the newest field
read twice with a half-line offset, no interpolation; `sys/ascal.vhd` 1217-1258,
2150-2168). There is no blend. MiSTer_DVD built its Blend in the core
(`dvd/field_blend.sv`, progressive raster only) and used ascal for Bob / Weave on its 480i
raster.

**The in-core deinterlacer here is cadence-exact for free.** H.264 says bitstream-exactly
which pictures were coded as field pairs (`field_pic_flag`). The census
(`umd_video_format.md`): film 3:2 and progressive titles are frame-coded, interlaced video
is field-coded. So the deinterlacer filters only stores decoded as fields; film and
progressive pictures pass untouched in every mode -- which ascal, blind to the content,
cannot do. Limitation: frame-coded interlaced pictures (legal, `pic_struct` 3/4 on a
frame; none in the census) are shown woven in every mode.

**The menu never offers what the raster cannot do** (the maintainer: "it's confusing to a
user to select blend but actually see bob"). This branch: `O[4:3] Deinterlace: Weave /
Bob / Blend`, in the core, 480p. When the 480i raster lands, that line is swapped for an
ascal `Bob / Weave` line (bit `[5]`, `HDMI_BOB_DEINT`) with CONF_STR hide prefixes (`H`/`h`
+ a `status_menumask` bit the core drives from the effective raster), and `[7:6]` becomes
Video Output. `tools/docs_check.py` accepts the prefixes (it silently skipped them before
P5). ⚠ Verify stock Main's lowercase `h` (hide when the bit is clear) in `menu.cpp` before
relying on it.

## 2. The port: `ram2` (P5a)

The display reader is a read-only master on its own f2sdram port, `ram2` (`DDRAM2_*`, a
`UMD-FORK` in `sys/sys_top.v`: `architecture.md`). Why: MiSTer_DVD measured that a
second read master on the decoder's port costs the decoder by **occupancy**, not
bandwidth (`hw_budget_and_lessons.md` §2) -- the P4 smoke display shared `ram1` through
`ddr_mux2`. `ddr_mux2` stays in front of `ram1` for its mount abort, master B tied off.
The three ports share one DDR3 device and one address map: the display reads the DPB
stores at word `0x0640_0000 + store << 18` exactly as the decoder writes them (2 MiB
stores since interface 0.11; `0x0600_0000 + store << 17` before: `h264_recon.md` §2.2).

## 3. The reader (`h264/disp_reader.sv`)

Born as the P4 smoke display (`h264_recon.md` §4): at the first dot of each raster line
it requests the next line (a toggle + line number to clk_mem), clk_mem fetches the luma
row (2W words) and the two chroma rows (W words each) in bursts of <= 8 into dual-clock
line buffers, and the clk_sys side converts BT.601 limited range to RGB, LAT 4.

**Since P6 step 3 the reader FITS the picture to the raster** (`analog.md` §5, the
design; `h264/disp_fit.sv` the per-picture parameters): it reads DECIMATED rows (boxes of
`dh x dv` samples) into four TAGGED line slots, commands the rows the next raster line
needs (at most two) at each line's start, and resamples with the 2-tap blend both ways
(chroma nearest -- interpolated at the identity since 2026-10-09, "Chroma at the identity" below),
black outside the picture's rectangle -- LAT 5 (the horizontal blend's
stage). At the identity fit (720x480 in Progressive) the rows fetched are exactly the old
rule's (row v + 2 during line v, the window v - 1 .. v + 1 held) and the output is the old
golden bit for bit; the kernels below apply there only. `fetch_late` counts a line whose
rows were not in when it began. The paragraphs below describe the P5 reader; the fetch
rule and LAT are superseded as stated here.

**Chroma at the identity (feature/chroma-interp, 2026-10-09) -- SUPERSEDED the next day by `docs/chroma.md`**
(siting-aware bilinear on every output; this step's integers are its special case, kept below as the
record of the measurement and the first decisions). The maintainer, testing 1.0.0 in
Native (HDMI): "details around red colors show noticeable vertical bands around them" (the Netflix
logo, a red suit's webbing). Measured on .201 with a synthetic 1280x720 pattern (red, blue and green
details, 1- and 2-pixel lines, edges at every column offset) at Native: the core's raster matched a
**nearest-chroma** model of ffmpeg's decode on 99.99 % of pixels (max 2 codes), an interpolating
player's on 77 % (up to 108 codes apart). Nearest repeats each 4:2:0 chroma sample over its 2 x 2
luma block, so a colour edge or a thin line inside saturated colour lands its whole chroma error in
one hard one-pixel stripe on one side; MiSTer's HDMI scaler (1.5x to 1080p, a sharp filter's
ringing) widens it into the bands. Red shows it most (the largest chroma excursion at a low luma, so
luma cannot mask it). Nearest came with the display from UMD / DVD; no note weighed it as a quality
choice.

- **What changed: at the identity fit chroma is interpolated** at H.264's default siting
  (`chroma_sample_loc_type` 0): horizontally co-sited with even luma columns -- an odd column x is
  `(c[x >> 1] + c[(x + 1) >> 1] + 1) >> 1` -- then, on a frame store, vertically between luma rows
  2m and 2m + 1: row 2m `(3 h[m] + h[m - 1] + 2) >> 2`, row 2m + 1 `(3 h[m] + h[m + 1] + 2) >> 2`
  (two roundings; ffmpeg's single-rounding upsample within one code). The identity is `ident` (the
  progressive raster, steps 1.0, no decimation): **Native (HDMI)** -- every picture -- and a 1:1
  picture on Progressive (720x480, the 704x480 snap).
- **The cost: shifts and adds, no DSP, no latency, no RAM.** At 1:1 the column steps by one a dot,
  so stage 1 reads the sample AHEAD (`(x + 1) >> 1`, clamped to the crop's last) and the previous
  dot's read is the left neighbour, still in stage 4's register (`r4_*`). That index is the second
  tap's own, `x_k1 >> 1` (`x_k1 = min(x + 1, kmax)`, the crop's first column even), so the identity
  only adds a term to the chroma tap's choice. (The first form computed `(x_k0 + 1) >> 1` against
  `kmax >> 1` in front of the RAM's address: clk_vid's worst path, 81.6 MHz against its 86 gate.) The rows above and below
  are already held at the identity (the kernel's `a` / `d`: k - 1 / k + 1, the window v - 1 .. v + 1),
  their chroma rows (k +- 1) >> 1. Stage 4 blends horizontally (all three rows), stage 5 vertically.
  LAT stays 9.
- **Invariant relied on:** a line's first shown column at the identity is even (the crop's `lx` is
  even: H.264's CropUnitX = 2 at 4:2:0, the PICTURE record's crop in pairs), so the first shown dot
  never needs a left neighbour from before the line. The picture's edges replicate (the right edge by
  the clamp; the first / last row by the reader's mirror, a = k + 1 / d = k - 1 -- chroma row m itself).
- **Decided: the siting is type 0, fixed.** The VUI's `chroma_sample_loc_type` is not read. Type 0
  is H.264's default and what encoders write (x264, NVENC, the servers' transcodes); a type-1 or
  type-2 stream keeps a half-sample colour offset -- as every stream had under nearest. Reading it is
  a later refinement (the SPS parser would carry two more fields to the display).
- **Decided: the identity only.** The scaled outputs (Interlaced, Progressive at another size) keep
  chroma nearest at the tap: their positions are fractional per dot, so interpolation there needs
  variable weights -- multipliers (9 DSP blocks left) or a second chroma read per tap -- and the
  analog screens they mostly feed soften the 2-pixel step themselves (a CRT's chroma bandwidth). 480i
  is never the identity (`ident` requires the progressive raster).
- **Decided: a store of fields interpolates horizontally only.** Its rows `a` / `d` are the OTHER
  field's lines (the Weave / Bob / Blend kernel consumes them); weighting them as progressive chroma
  would mix the fields. Vertically each field's chroma stays nearest, as before.
- **Verified:** `tools/disp_golden.py` (`hup`, `vrow`, `up_ident`, `up_field`; `render` at the
  identity) is the bit-exact golden; its independent check is ffmpeg's own upsampling
  (`scale=in_chroma_loc=left:flags=bilinear+full_chroma_int+accurate_rnd`, validated first on an
  impulse: the even column full, odd neighbours one half; rows 2m / 2m + 1 three quarters, the rows
  beyond one quarter -- without `in_chroma_loc` ffmpeg assumes centre siting). The 480i arms keep
  nearest (`disp_want_frame_il` / `field_il`); every fitted case is unchanged. `--red`: Z1-Z7
  (`bench/h264/run_disp_reader.sh`).

**Field-aware chroma (P5a).** A store of fields holds them line-interleaved in every
plane (`h264_recon.md` §2.2): luma line y is field (y & 1)'s line y >> 1, chroma row c
is field (c & 1)'s row c >> 1. A field's own 4:2:0 siting puts its line k on its chroma
row k >> 1, so luma line y of a field store takes chroma row `2 (y >> 2) + (y & 1)`; a
frame store takes `y >> 1`. The smoke display took `y >> 1` for both: on field content,
lines 4k+1 and 4k+2 took the other field's colour (chroma bleed on motion). The flag
(`pic_field`) is the completed picture's `done_struct != frame`, carried with the store
through emu's snapshot to the display's per-frame latch.

The golden for that siting is not the formula: `tools/disp_golden.py` has ffmpeg
`separatefields` split the woven store into its two fields (every plane), converts each
field with the plain 4:2:0 rule, and weaves the RGB back (`run_disp_reader.sh`,
`disp_field` arm; mutations D4 frame siting on a field store, D5 the other field's
chroma).

## 4. The VUI and the aspect (P5b)

**The front end parses the whole VUI** (E.1.1) and its `hrd_parameters()` (E.1.2) in
`sps_pps.sv` and emits every field as a header word, like every other SPS field (41 new
ids in `tools/h264_fields.py`, appended so the earlier ids stay). The model
(`h264_fe_ref.parse_vui`) records the same fields in the same order; the JM trace
normaliser keeps its `VUI:` fields now (aliases for JM's three non-spec names and the HRD
loop's `[i]`); `test_h264_fe_ref.py` compares the model's headers with ffmpeg's
`trace_headers`, VUI included. What is stored (`h264_pkg` `sps_t`): the picture-timing
SEI's delay lengths, `CpbDpbDelaysPresentFlag` and `pic_struct_present_flag` (the front
end's, P5c), the aspect, the timing and `max_dec_frame_buffering` (the reconstruction's
copy in `recon_hdr`, P5d). u(32) fields are read as two u(16) (`rbsp_reader` serves 31
bits) and emitted as one word.

Range errors (`ERR_RANGE`, the SPS not stored) only on what is stored or looped over:
`cpb_cnt_minus1` > 31, `num_units_in_tick` or `time_scale` 0, the two structures'
lengths differing, `max_dec_frame_buffering` > 16, `max_num_reorder_frames` above it.
The model raises at the same field. `chroma_loc` > 5 and the other unstored fields are
not checked (nothing aliases).

The fixtures no encoder makes come from `tools/h264_synth.py`, which rewrites an x264
stream's SPS with a VUI built bit by bit from the syntax table: `max` (every part present
at its maximum: two HRD structures of 32 CPBs, u(32) values of 2^32 - 1, ue(v) values of
2^32 - 2, 255s -- and EPBs inside the VUI), and one stream per range error. The maximal
SPS parses to the same 254 fields in the model and in ffmpeg's `trace_headers`.

**Aspect (`h264/aspect_vui.sv`).** The shown picture's `aspect_ratio_idc` (and its
Extended_SAR) travels with the store to the display latch; Table E-1 gives the SAR; the
display aspect sar_w W : sar_h H is rounded to the nearer of 4:3 and 16:9 (16:9 iff
9 sar_w W > 14 sar_h H; W, H in macroblocks). Unspecified (no VUI, idc 0 or reserved, a
0 in Extended_SAR) keeps the P4 rule, 16:9. `run_aspect_vui.sh`: Table E-1 read from the
spec PDF, the rounding checked against the table's own 25 labelled examples, every idc,
both sides of each entry's decision boundary, Extended_SAR edges. Cropping is not
applied to the aspect (no disc crops). ⚠ A HUD flag for "aspect unspecified, fallback" is
not built: it goes on the P5 HUD row (P5e).

**The aspect's hardware gate moves to P5e.** The harness screenshot is the core's raw
raster, upstream of ascal: `VIDEO_ARX/ARY` cannot be seen in it, so "Akira shows 16:9" is
not measurable in P5b (a round that never reached the state is not a measurement). The
P5e HUD row shows the aspect Auto chose (and the unspecified fallback); the gate reads it
on Akira (`aspect_ratio_idc` 5 -> 16:9) and on Family Guy or Short Circuit (idc 3 ->
4:3: their main titles' SPS, read 2026-09-26 -- every rig disc's SPS also says
`max_dec_frame_buffering` 3, timing 4004 / 240000, `pic_struct_present_flag` 1).

**The VUI oracles.** ffmpeg `trace_headers` (the x264 clip and the maximal VUI, 254 SPS
fields) and JM `ldecod`'s trace (`test_h264_trace_ref.py`: the maximal VUI, 1,614 records
identical to the model). JM holds the u(32) fields in an int and prints 2^32 - 1 as -1:
the normaliser reads `num_units_in_tick`, `time_scale` and the HRD values unsigned.

## 5. The picture timing SEI, the PTS, end of stream (P5c)

Every per-picture display fact reaches the reconstruction IN BAND, as header words after
the picture's first slice header (`first_mb_in_slice` 0), in this order: the picture
timing SEI's `cpb_removal_delay`, `dpb_output_delay` (when `CpbDpbDelaysPresentFlag`),
`pic_struct` (when `pic_struct_present_flag`), then the access unit's PTS as
`au_pts_lo` (bits 31..0) and `au_pts_hi` (bit 32). A picture without them simply has no
such words; the display infers (P5d). After the stream's last NAL unit: one
`K_EOS_WORD` (kind 19) -- in band, so it can never overtake the words before it. The
reconstruction's router consumes it (P5d gives it its meaning).

**The SEI (`h264/dec/sei_pt.sv`).** A byte-level walker over the SEI RBSP (0xFF runs for
payloadType / payloadSize; `nal_parser` has already removed the EPBs, so payloadSize
counts right). It keeps the first **9 bytes** of the last complete `pic_timing` payload:
the fields up to `pic_struct` are at most 32 + 32 + 4 = 68 bits. The clock timestamps
after `pic_struct` are NOT parsed -- nothing downstream uses them, and the walker skips
them by payloadSize (the rest of a known payload, not a bound). The payload waits because
its syntax depends on the SPS its access unit's first slice activates, which follows the
SEI (D.2.3 NOTE 1); `h264_top` interprets it after that slice's header, with that SPS.
The needed length is checked up front: too short emits nothing (`pt_short`). `pic_struct`
is emitted, then checked against Table D-1 (reserved values, `field_pic_flag` /
`bottom_field_flag`): a mismatch counts `pt_struct`, the display decides. A malformed
unit (a type or size cut by the unit's end, a payload running into its last byte, a
non-0x80 last byte at a message boundary) counts `sei_malformed`; a pic_timing it cut
leaves nothing pending. A picture that should have one (either flag set) and has none
counts `pt_missing`. None of these is a decode error: they never damage a picture. A
first draft (the session stopped mid-P5c) kept 64 bytes and parsed every clock timestamp
field; it had a width bug (a 64-byte payload's bit count, 512, wrapped to 0 in 9 bits)
and more area for no function.

**The PTS (`h264/dec/au_pts.sv`, positions from `nal_parser`).** The source-neutral input
is {byte, mark, PTS}: `ps_demux` marks the first payload byte of every video PES that
carried a PTS, and `vid_pts` (held from that header) rides with the byte through
`vidfeed_cdc`, now 42 bits wide -- the PTS cannot be sent separately, because PTS pulses
and marks are not 1:1 (`ps_demux.sv`: a PES of length 1 sets the PTS but marks nothing).
`nal_parser` counts its input bytes (24 bits, modulo) and reports each NAL unit's 3-byte
start code position. The rule (ISO/IEC 13818-1 2.4.3.7): a PES's PTS belongs to the first
access unit that COMMENCES at or after its first payload byte; an access unit commences
at its first NAL's start code (7.4.1.2.3: an AUD / SEI / SPS / PPS / 14..18 NAL after a
VCL NAL, else the picture's first slice). At each access unit start, `au_pts` pops every
stamp at or before it; the latest is the tag, earlier ones are counted (`pts_drops`: a PES
with no access unit of its own). The queue holds 4 stamps; a fifth evicts the OLDEST,
counted -- by then it can only be superseded, the newest can still be a tag (a draft
dropped the newest and lost the right tag on `--synth-marks`). UMD streams carry a PTS only on the PES that opens a GOP
(about every half second); the rest are untagged and the display extrapolates (P5e).

**Verification.** The model (`h264_fe_ref.decode_stream(..., marks=)`) against
independent oracles: its per-picture PTS equals ffprobe's per-packet PTS at the same
decode index on every tagged picture of the Akira and Family Guy windows; its SEI fields
equal ffmpeg `trace_headers` on the rewritten x264 streams. `tools/h264_synth.py`
rewrites an x264 stream's picture timing SEIs: every `pic_struct` value on frames
(`ps_all`), a 300-byte message full of EPBs + a payloadType >= 255 + an over-long
`pic_timing` (`sei_edge`), short / malformed / missing, and an SPS with other delay
lengths between an SEI and its slice (`sps_after_sei` -- where ffmpeg itself parses the
first such SEI with the old SPS, reading `cpb_removal_delay` 0 for 12: the fixture tells
the two strategies apart). `--synth-marks` puts PES marks at -1 / 0 / +1 / +2 around every
start code (a mark inside a start code belongs to the NEXT access unit). The RTL is scored
word-exact on all of them plus the disc windows (`run_h264_top.sh` E1-E5, A1-A4, Z1) and
through the whole chain with the demux's real marks (`run_p3_chain.sh`).

## 6. The output order, the holds, end of stream (P5d)

**What is output, and when (Annex C.4).** After each picture's marking the DPB runs the
output process: C.4.4 first (an IDR empties the DPB -- without output when
`no_output_of_prior_pics_flag` is set, else by bumping everything; an MMCO 5 bumps
everything), then C.4.5 (a reference picture: bump while the DPB is full, then store; a
non-reference picture: bump while full and something waiting has a POC at or below its
own, else output it directly without storing). A bump (C.4.5.3) outputs the waiting
picture with the smallest POC. The DPB size is `max_dec_frame_buffering` when the VUI
has it (Max(1, it)), else MaxDpbFrames from Table A-1 by `level_idc`, capped at 16. Every
readable disc's main title (49 of 49, `umd_video_format.md`) codes
`max_dec_frame_buffering` 3: three pictures of output latency. Without it a 720x480 Level 3.0 stream gets 6 and a 480x272
one 15 -- more latency, the same order.

**The STORE is the output unit.** The spec outputs PICTURES: a field pair's two fields
may leave apart when another picture's POC falls between theirs, and a non-reference
first field output directly (C.4.5.2) is gone before its partner is decoded -- the
partner, not "still in the DPB", is then stored and output later on its own. The display
shows stores (a pair is one frame buffer, woven). So a store is emitted when the
bumping FIRST selects it, whole, once per allocation, and never before it is complete: a
first field output directly waits (`pend_emit`) and goes out with its second field, or
unpaired when the next picture does not pair with it. This changes WHEN a pair's second
field is shown, never the order of stores: `tools/dpb_output_ref.py` runs the spec's
per-picture process literally over the model's events and checks that each store's
first appearance there is the model's emitted order, counting the "splits". JM does
the same (its output writes a pair's frame when the pair completes).

**Choices, recorded as deviations** (`spec_hardening.md`): `no_output_of_prior_pics_flag`
is used AS CODED -- C.4.4's inference of 1 on a picture size change is not made (JM does
not either; the display never shows a picture of the old size into a new CVS's first
frame, it shows the old pictures, which is the more useful failure). Level 1b (coded as
`level_idc` 11 + `constraint_set3_flag` in the Baseline / Main / Extended profiles) is
read as 1.1: the front end does not keep `constraint_set3_flag`; 1.1's larger DPB only
adds latency.

**The RTL (`h264/dec/recon_dpb.sv`).** Per store three bits beside the marking:
`waiting` ("needed for output"), `emitted` (once per allocation) and `pend_emit`; all
three keep a store busy. The process runs in new states between the marking and
`D_POST_MARK`, i.e. BEFORE an MMCO 5's POC rewrite (the spec bumps with the old POCs):
`D_OUT_C44`, `D_OUT_FILL` (a registered fullness, a cycle after any change), `D_OUT_C45`,
`D_OUT_SCAN` (the minimum-POC scan, one store a cycle through the existing table port),
`D_OUT_ACT` (bump / direct output), `D_OUT_END` (a pending pair completed), and `D_EOS`.
The DPB size is computed serially when a picture opens (repeated subtraction of
PicSizeInMbs from MaxDpbMbs, at most 16 steps; decoding takes far longer). End of stream
(the front end's `K_EOS_WORD`, P5c): the router pulses `eos`, the DPB closes the last
picture like a new one would, emits a pending first field unpaired, then everything
waiting in POC order, and pulses `eos_done` -- the last picture's `pic_done` comes with
it (P4 never completed the last picture of a title).

**Deadlock and release safety.** A picture's output step runs before the NEXT picture
opens a store, so references + waiting <= the DPB size <= 16 when a store is chosen;
with 20 stores (`h264_pkg` NSTORE) at least four are free unless the DISPLAY holds some.
Then `D_OPEN` waits for a release (`stall_cycles` counts every cycle); a wait longer
than `STALL_LIMIT` (13 M cycles at 96.43 MHz, ~135 ms, ~4 frame periods) counts `err_no_store` (code 6) and
waits on -- a display that never releases is visible, never a silent hang, and never a
store overwritten on screen. The display always releases (it holds one store on screen
plus the queue, and pops one per refresh), so the wait ends.

**The queue (`h264/recon_out.sv`).** Per store a table of the picture's display facts,
written when it opens (the "a" half: size, cropping, aspect, `pic_struct`, PTS, IDR;
the "b" half: a pair's second field's `pic_struct` and PTS) on clk_dec and read by
clk_sys; a record FIFO (clk_dec -> clk_sys: store, frame / unpaired / first-bottom /
fields decoded; one END record after `eos_done`); a release FIFO back; and the holds,
`oq_hold` = recon_dpb's `disp_hold`: set when a store is emitted, cleared when its
release arrives. A queued store cannot be written (held), so its table row is stable
until it is released; at most 20 records are ever queued, the FIFOs are 32 deep (a
push into a full one sets `rec_ovf`, a release of a store not held `rel_bad`: both on
the HUD, both design errors). The timing SEI's `num_units_in_tick` / `time_scale` are not
in the table yet (P5e adds the field period there).

**The interim consumer (emu, until P5e).** At line 500 of every other refresh (~29.97
stores a second) it takes the next record and releases the store shown until then:
line 500 is after the last line's fetch and before line 0's, so no read of the
released store is still to come. 29.97 field-pair titles play at their rate; 24p film
plays 1.25x fast, and the decoder, faster than that, waits on the display's holds --
the path this stage exists to prove on the rig. The END record is taken and the last
picture stays up, held. An unpaired field is shown woven with whatever the store's
other field lines hold (P5f bobs it: §8).

**Not yet benched (P5e's verification):** the display's side of the hold contract -- a
read by `disp_reader` of a store it does not hold (the plan's `ddr_model.sv` / cosim
`$fatal`) -- and the seam recon_dpb -> recon_out -> the consumer in one simulation (each
half is benched alone; `recon_top_tb` and the cosim play the display themselves). P5e's
scheduler replaces the interim consumer and gets both. Until then the rig's HUD is the
instrument: `X` 0 (`rel_bad`), `OUT` trailing `P4 PIC` by the DPB size, `ERR` 0.

**The HUD** gains a row: `OUT` stores emitted, `DIR` non-reference pictures output
directly, `DRP` stores dropped by `no_output_of_prior_pics_flag`, `DPB` the fullness
(references + waiting), `WT` the cycles the decoder waited on the display (/4096), `X`
faults {DPB full of references alone (a non-conforming stream), queue overflow, bad
release}.

**Verification.** The model (`h264_recon_ref.output_step`) three ways: the spec's
per-picture process (`dpb_output_ref.py`: the store order equal, splits counted),
ffmpeg's display order (`framemd5`), and JM `ldecod`'s output (JM honours
`no_output_of_prior_pics_flag`, ffmpeg does not -- on `c44n` JM and the model output 7
stores, ffmpeg 14; ffmpeg also drops a cut window's trailing unpaired field, set aside
and counted). Fixtures (`run_recon_top.sh`): x264 B pictures with a VUI DPB of 2 (six
direct outputs), that stream's second IDR with `no_output_of_prior_pics_flag` set, a P
stream with an MMCO 5 spliced in (both through `tools/h264_synth.py`, the VUI dropped so
the size comes from Table A-1), a JM field stream whose B pairs are output directly
(`jdefer`, `jm_fixtures.py`: coverage-checked, order checked against the spec process
and JM), a conformance field stream cut after a first field (`fodd`: unpaired at the
end), and `r16s` -- 16 reference frames with display holds of up to 600,000 cycles, so
the decoder must wait (916,499 cycles of it) and still decode every picture exactly with
no error. `recon_top_tb [out]` scores every emission's store, shape and WHEN (the
pictures opened before it: a DPB-size error moves the timing, not the order); `[hold]`
fails any DDR3 write burst into a store the display holds. Mutations O1-O12 (order, the
two size sources, `no_output`, MMCO 5, direct output, the pending pair, the EOS scan, the
stall, the busy term, the unpaired flag, the wiring), each caught by its own arm.

**Found on the way.** The bench scored each completed picture by a counter read inside
a `fork ... join_none` after the parent had moved it (and in static variables shared by
overlapping scorers): harmless while pictures completed far apart, wrong on the first
field pair whose first field completed in the cycle its second field opened. The
scoring is now an in-order queue. And the bump path first emitted every store as paired:
a lone field bumped later (the stream's end, or a partner that never came) must go out
unpaired -- the `fodd` fixture and O11 pin it. The first mutation round found two
more: the scan's "at the end of stream, the current store too" term was dead code
(`D_POST_MARK` has already closed the last picture, so it is a candidate anyway: an
equivalent mutant, the term removed, O8 now skips the end-of-stream flush); and the
bench's `[hang]` arm excused EVERY cycle the DPB waited on a hold, so a DPB waiting on the
bench's own scoring hold (R9, NSTORE 16: no store ever free) ran to the 2-hour timeout --
a wait is now excused only while the bench-display holds a store it will release.

## 7. The scheduler: STC pacing and field cadence (P5e)

**The model.** A set-top box's: one 90 kHz clock (the STC) that just runs, from the same
27 MHz crystal as the raster (`clk_sys / 300`), so the RATE of display and content is
locked by construction and the scheduler owns only PHASE. It anchors the STC to a
picture's PTS and, at every refresh, decides whether the store at the head of the
output queue is due. `h264/disp_sched.sv` is MiSTer_DVD's scheduler with surgery (its
header lists what was kept and what was dropped, and why -- `harvest.md`);
`h264/disp_ctl.sv` is the control around it; both on clk_sys, so none of it costs the
decoder's timing. `tools/disp_sched_ref.py` is the reference, written from the rules
below.

**Duration** (Table E-6, DeltaTfiDivisor, checked against the spec text): a frame lasts 2
clock ticks, or by its `pic_struct` 0/3/4 -> 2, 5/6 -> 3, 7 -> 4, 8 -> 6; a field 1 (a
pair 1 + 1). A tick is `num_units_in_tick / time_scale` (C-1): `field_q3 = 720000 x nuit
/ ts` eighth-ticks of 90 kHz (UMD: 4004 / 240000 = 12012, 1/59.94 s; the 23.976
progressive discs 5005 = 15015). The division is serial (24 steps) on clk_sys when a
record reaches the head -- recon_out's table carries `timing_v`, `nuit` and `ts`, so
there is no write-after-emit window (a record's row is written when its picture opens).
No VUI timing: 12012 and flag 1. A quotient >= 2^24 eighth-ticks (a tick over 23 s) is
clamped, or `time_scale` 0 defaulted, flag 2 (`spec_hardening.md`). A `pic_struct` that
does not fit the store (1/2 on a frame, 0/3-8 on a field, 9-15) takes the default, flag 4.
A pair tagged only on its second field: that PTS minus one tick.

**The refresh contract** (exact to the tick, which is what lets the model score the RTL
refresh by refresh): the tick is phased to the raster -- P = 0 at the first (h 0, v 0)
after the mount reset, a tick at every P = 300 m -- so a 450,450-cycle refresh is 1501.5
ticks. At line 499 the head is EVALUATED with that cycle's STC; at line 500 a due head is
TAKEN: the store shown until then is released (its last line was fetched at line 478,
line 0's comes at 523 -- P5f's fetch two ahead, §8), the new one latched for the reader.
(Since P6 part 2 the events come from a refresh-phase counter at `RF k + 499 x 858` / `+ 500 x
858` -- the same cycles at 59.94 -- with RF, the offsets, the half refresh and R_Q3 per raster
standard: 60.00 Hz RF 450,000; 50 Hz RF 540,000 at 599 / 600 x 864, half 900; `analog.md` §10.)
**Due**: STC >= want - 750
(half a refresh), want = the head's PTS when tagged, else the timeline's next PTS (the
last one's plus its duration). **Anchor**: the first head, or a TAGGED head more than a
frame behind the timeline, more than 0.5 s ahead of it, or more than 2.7 s late.
**Lateness is not a discontinuity** (MiSTer_DVD's HW round B): a late head is shown at
once and the timeline continues from it; an overdue queue drains at one store a refresh,
and on this 59.94 raster every census content class has at least two refreshes a store,
so the display catches up without dropping. Not so for a stream of single 59.94 fields
(one tick each: the display's maximum rate) -- none in the census; a starve there would
recover only at LATE_MAX (`reference/compatibility.md`). DVD's catch-up drop is not
ported for that reason. **END**: the record is taken at a pickup; the last store stays
up, held.

**Parity**: a field store (a pair) shows `first_bot ^ (refreshes since its pickup) & 1`
-- first the field decoded first, then the other, alternating while it is held; a
single field its own; a frame 0. P5e carries it to `disp_reader` (`pic_parity`); P5f's
Bob and the future 480i raster use it.

**The field at 480i / 576i** (P7, 2026-10-05; UMD's V6 ported -- `analog.md` §5): the raster's
field shows its own lines of a field store, so a pair is picked up only for a refresh of its first
field's parity (refresh 0 the top field; the pickup in refresh k decides refresh k + 1). A due pair
on the other field waits one refresh (`disp_fhold`, word 85) unless it is late; the hold's next
pickup is not counted late, nor the held store's cadence judged. Measured before it on the
RetroTINK: every pair of an interlaced MPEG-2 later-field-first at 576i (`history.md` §35).

**Instruments** (the HUD's last row, `DC FT LG RA LT CE F`): `DC` the (store, parity)
changes the control DECIDED; `FT` the ones `disp_reader` FETCHED, counted on clk_mem
from what it captured with each frame's line-0 request -- the independent half of the
judder gate: over any span of settled playback their deltas are equal (the reader resets
with the core, not per mount -- a DDR3 read master cannot be reset mid-burst -- so the
raw values differ after a remount; the gate compares deltas); `LG` the last pickup's
lag (want - STC) in ms; `RA` STC anchors (1 on a continuous title); `LT` late pickups: the
picture was ALREADY due at the previous refresh (a missed opportunity -- starved or
backlogged; judged with the previous eval's STC on the same timeline). The first
definition, STC - want > half a refresh at the pickup, counted the 2.5-refresh rhythm
of 23.976 film -- every other frame is taken ~750 ticks after its PTS, the best a 59.94
raster can do, and the phase noise of the disc's time stamps pushed some over: X-Men 2
read `LT` 21 a minute on the rig with the decoder ahead of the display (`WT` climbing),
while 3:2 film and field pairs, whole-refresh cadences, read 0; `CE` cadence errors: a store held a refresh count outside
{floor, ceil} of its duration / one refresh, judged at the next contiguous pickup -- a
self-consistency check (it shares the scheduler's `field_q3`; `FT` is the independent
one); `F` the flags above.

**Verification** (`run_disp_sched.sh`, Verilator `--timing`: a 300-refresh scenario is
~135 M clk_sys cycles on three clocks): `recon_out` -> `disp_ctl` + `disp_sched` ->
`disp_reader` over `ddr_model`, with the real raster (`sync_gen`), fed the model's
scenarios and scored at line 510 of EVERY refresh ({shown, store, parity, field}), then
the counters, `FT == DC`, and every reader burst from a store the display holds -- which
closes P5d's two open seams (the display-side hold contract, and the queue -> control ->
reader chain in one simulation). Scenarios: 3:2 film, 23.976 progressive (2.5 refreshes
a frame), TFF / BFF pairs, `pic_struct` 7 / 8, single fields, sizes + no VUI timing, a
late decoder, a backward PTS jump, a 0.3 s gap waited out, a 2 s gap re-anchored,
LATE_MAX after a 4 s still, and a 400 ms starvation that must NOT re-anchor (the DVD
regression [8b]).

## 8. The deinterlacer: Weave / Bob / Blend (P5f)

**One window, three kernels, in the reader.** Bob and Blend both need the lines above
(a) and below (d) the display line (b). `disp_reader` now fetches the line TWO ahead of
the raster (the blank lines 523 and 524 fetch lines 0 and 1; line v fetches v + 2) into a
ring of four line buffers, so a, b and d are all present while the next line lands. Each
plane has three copies written alike, one read port per window line: nine simple
dual-clock RAMs (196,608 bits; `synth_unit.sh`: all nine inferred, the reader 499 ALMs)
-- never one array read three ways, which Quartus leaves in registers. The kernel runs in
readout stage 2 on each channel's own samples (after the field-aware chroma siting: each
fetched line carries its own field's chroma row), so LAT stays 4 and emu's composition is
untouched. No bandwidth is added: still one line fetched per raster line.

| store | Weave (0, and the unused 3) | Bob (1) | Blend (2) |
|---|---|---|---|
| frame | b | b | b |
| field pair | b | keep `pic_parity`: its lines b, the other field's `(a + d + 1) >> 1` | `(a + 2b + d + 1) >> 2` |
| single field | bob, its own field | bob, its own field | bob, its own field |

- **Only stores of fields are filtered.** H.264 says which pictures are fields
  (`field_pic_flag`), so film and progressive pass untouched in every mode (§1); a
  frame-coded interlaced picture (`pic_struct` 3/4 on a frame, none in the census) is
  shown woven in every mode.
- **Bob is temporal for free.** `disp_ctl` already alternates `sh_parity` every refresh on
  a pair (the field decoded first, then the other): Bob keeps that field and rebuilds the
  other field's lines from the kept lines above and below, so a pair becomes two
  pictures 1/59.94 s apart. Not line doubling: a doubled field bounces half a field line
  between refreshes; the interpolated one keeps each field's lines where they are.
- **Blend is static**: the (1, 2, 1) mix is the same on every refresh a store is held
  (MiSTer_DVD's lesson, `dvd/field_blend.sv`: no per-refresh state, no shimmer).
- **A single field** (unpaired; the store's other lines hold nothing of it) is bobbed on
  its own field whatever the menu says -- the interim display showed it woven with stale
  lines (§6). `disp_ctl` exports it as `sh_single`.
- **Edges mirror** (a := d on line 0, d := a on the picture's last line), by the ring
  slot the copy reads -- an edge line keeps an interior line's balance of the two fields,
  and no line outside the picture is ever read. A picture taller than the raster
  (720x576, legal at Level 3.0: 1,620 macroblocks) is clipped at line 479, whose d is the
  picture's real line 480: the reader fetches it at raster line 478 when the picture has
  it (a mirror there would be wrong; a first draft mirrored at 479 and needed a special
  term an H <= 480 fixture could not see).
- **The mode** is `status[4:3]`, latched once a frame at line 524, so a menu change never
  splits a picture. **Fetch timing moved:** line 0 at raster 523 (was 524), line 479 at
  477, a taller picture's line 480 at 478: the last fetch is still before the line-500
  release and the next frame's first after it, so disp_ctl's hold contract is unchanged
  (`run_disp_sched.sh [hold]`).

**Blend's rounding is ffmpeg's**, `(1 + a + 2b + d) >> 2` (vf_tinterlace's
`lowpass_line_c`, measured: the `interlace=lowpass=linear` filter on a duplicated frame
matches it on every interior line), chosen so Blend has an independent oracle. DVD used
`+ 2`; the difference is invisible. ffmpeg clamps each FIELD's first and last lines to
themselves, which is not the reader's rule: `tools/disp_golden.py` feeds it the 4:4:4
planes padded with two mirrored lines each side and crops, so the filter's edge rule never
touches a scored line and the golden checks the reader's mirror too. Bob has no exact
ffmpeg equivalent (its bobs are temporal or edge-directed): its golden is the formula,
and its kept lines are the ffmpeg-split weave's.

**Verification** (`run_disp_reader.sh`): every dot `{de, R, G, B}` of a whole raster
against the golden, 13 arms -- `[rgb]` / `[field]` Weave (unchanged fixtures, byte for
byte); `[pass]` a frame in Bob and in Blend; `[blend]` at 720x480, 480x272 (the bottom
mirror inside the raster, black beyond) and 720x576 (the clip); `[bob]` both parities at
720x480 and 480x272 (the top mirror when the bottom field is kept, the bottom mirror when
the top is); `[single]` one field in Weave and in Blend. Mutations K1-K10 (rounding, Cb
left out, the kept field inverted, the rebuilt line's rounding, each mirror, line 480
unfetched, frames filtered, a single field following the menu, the mode never latched),
each caught by its own arm, with D1-D5 re-run (D3 re-anchored on the ring slot).
`run_disp_sched.sh` scores `sh_single` at every refresh against `disp_sched_ref.py`
(D14); `run_scaffold.sh` W33 / W34 pin the menu bits (`check_emu_wiring.py` reads them
from the CONF_STR line) and the single flag.

**Not built:** a HUD / telemetry readout of the kernel in use (the rig gate is the
screenshot itself, below); the 480i raster's Bob / Weave through ascal (§1, later).

**The rig gate** (`tools/comb_metric.py`): the mean absolute second difference down the
columns, `|2 b - a - d|`, over the picture in a raw screenshot, divided by the same over
two lines (within a field) -- the comb of a woven field pair. Its self-test proves it
separates a woven pan from a progressive, blended and bobbed one before it is trusted.

**✅ HW 2026-09-27** (`UMD_p5f-deint_20260927_0206.rbf`, Diagnostics Off, the mode
switched live with `mister.py osd`): **Family Guy** (field pairs), three rounds of
Weave / Bob / Blend with three shots each: Weave 0.41-0.50, Bob 0.33-0.35, Blend
0.33-0.36 -- every Weave shot above every Bob and Blend shot; then four triples with the
mode switched between consecutive shots of one scene: Weave highest in all four
(+0.07-0.13). Zoomed, static thin diagonals are sharp in Weave, stair-stepped in Bob (one
field: half the vertical detail) and soft in Blend -- each kernel as designed, no stray
lines or colour errors. **Akira** (3:2 film, frame-coded), the control: four triples with
no mode ordering (Weave lowest in one) -- film untouched. `telem --watch 30` in Bob:
Family Guy decided +1,918 = fetched +1,918 (59.94 changes a second: one field per
refresh), 29.97 pairs a second, 2.00 refreshes a pair; Akira +761 = +761, 2.50 refreshes
a picture; `late` / `starve` / `cadence` 0, one anchor, decode errors 0 on both.
Not exercised on the rig: a single field (none in the census; benched), a 720x576
picture (none in the library; benched), a menu change mid-title beyond the live switches
above.

## 9. Status

| stage | what | status |
|---|---|---|
| P5a | `ram2` fork, `disp_reader` on it, field-aware chroma, `VGA_DE` from the raster | ✅ MERGED (PR fj#8). ✅ benched (`run_disp_reader.sh --red`, `run_scaffold.sh --red` W12-W16, T1-T4); fit `UMD_p5display_20260926_0007.rbf` (SEED 1, clk_dec 91.09 / 89.65, 25,084 ALM, no 10236); ✅ HW 2026-09-26: Family Guy 98.1 fields/s (1.64x; 95.9 on ram1), The Office Disc 01 84.3 (1.41x; 83.1), ERR 0, pictures clean -- the port move cost the decoder nothing |
| P5b | VUI parsing, aspect from the VUI | ✅ MERGED (PR fj#8). ✅ HW 2026-09-26 (`UMD_p5display_20260926_0145.rbf`, `mister.py shot --scaled`): Family Guy (VUI idc 3) on Auto 1440x1080 = 4:3, identical to the forced 4:3 shot, forced 16:9 1920x1080; Akira (idc 5) on Auto 16:9; ERR 0, pictures clean. ✅ benched (+ `test_h264_trace_ref.py`: JM `ldecod` == the model on every field of the spec-maximum VUI): `run_h264_top.sh --red` (24 fixtures incl. the x264 VUI clip, the maximal synthetic VUI and five range errors; 23 mutations, V1-V6 new), `run_aspect_vui.sh --red` (5), `run_scaffold.sh --red` (W17 / W18), the model vs ffmpeg `trace_headers` VUI included; fit + HW pending |
| P5c | SEI `pic_timing`, PTS to the decoder, end-of-stream word | ✅ MERGED (PR fj#8). ✅ benched (§5; `run_h264_top.sh --red` 32 runs / 35 mutations, `run_p3_chain.sh --red`, `run_recon_top.sh`, `run_cosim.sh`, `run_diag_hud.sh --red`, the model vs ffmpeg / ffprobe in `test_h264_fe_ref.py`); fit `UMD_p5display_20260926_0501.rbf` (25,991 ALM, clk_dec 87.83 / 86.93 -- 0.93 MHz of margin; the 40 worst paths at -40C are all P4's `mv_pred` `sp_mode` / `b8` -> `mvp_q`, none of P5c's logic: placement at 62 %; the path to pipeline if P5d's fit misses); ✅ HW 2026-09-26: Akira `PT` = `P4 PIC` (every picture timed), `NO` / `BAD` / `SX` 0, one PTS per ~12 pictures (~0.5 s), 0 dropped, `PS` 5 / 6 (film); Family Guy the same with one PTS per ~28 fields, ERR 0 |
| P5d | output order (C.4.5.3), hold / release, EOS flush | ✅ MERGED (PR fj#8). ✅ benched (§6): `run_recon_top.sh --red --discs` (26 runs incl. `c44b/n/m`, `jdefer`, `fodd`, `r16s`; 32 mutations, O1-O12 new), `run_recon_out.sh --red` (3 seeds, 7), `run_cosim.sh` (Family Guy 1.65x, Akira 1.91x, order + holds scored) + `--red` (C7 / C8 new), `run_scaffold.sh --red` (W10, W21-W23), `run_diag_hud.sh --red`, `test_dpb_output_ref.py` (+4 RED; the model == the spec process == ffmpeg == JM); fit `UMD_p5display_20260926_1507.rbf` (SEED 1, clk_dec 87.25 / 87.31, 26,627 ALM, M10K 233); ✅ HW 2026-09-26: Akira `OUT` 3 behind `P4 PIC` (`DPB 03`), 29.5 stores/s (the interim consumer's rate), `WT` climbing (the decoder waits on the display: 24p decodes at 1.8x), the reader paced down with it; Family Guy 28.7 pairs/s, 3 pairs behind; `X` 0, `ERR` 0, pictures clean on both. The rig shows the process running and nothing written under the display; ORDER as seen is the cosim's (1 fps screenshots cannot see reordering). ✅ A title's end exercised on the rig at P5g (the P5g row). ✅ The whole-library `run_cosim.sh --sweep` since P5d (P5g: 88 of 89 bit-exact, order + holds scored); a subset of 8 (2026-09-26: The Office Disc 01, Ghost in the Shell 2.0, South Park, Tom & Jerry, The Dark Knight, Interstella 5555, Austin Powers, Goo Goo Dolls -- the slowest windows of the P4 sweep and five field-coded titles) all PASS, order and holds scored, 1.35-1.77x real time |
| P5e | the scheduler (STC, field cadence) | ✅ MERGED (PR fj#9) (§7): ✅ benched -- `run_disp_sched.sh --red` (16 scenarios refresh-exact vs the model; 13 mutations: D3 on the 200 ms backward jump -- on a 5 s one the LATE_MAX leg re-anchors too; D13 on single fields -- only they take a picture at the refresh right after an anchor), `run_recon_out.sh`, `run_disp_reader.sh`, `run_diag_hud.sh`, `run_scaffold.sh --red` (W24-W26); `disp_ctl` + `disp_sched` alone 1,132 LUTs / 862 registers / 5 DSP; fit `UMD_p5sched_20260926_1851.rbf` (SEED 1, clk_dec 90.99 / 89.44, 27,332 ALM, M10K 238, DSP 74 -- the first fit missed at 84.48 on P5d's output scan, now two stages); ✅ HW 2026-09-26, 60 s each on settled playback: Akira (3:2) +1,472 DC = +1,472 FT (24.1/s), X-Men 2 (23.976 progressive) +1,470 = +1,470, Family Guy (pairs) +3,678 = +3,678 (30.1 pairs/s); `LT` 0, `CE` 0, `RA` 1, `F` 0 on all three. (The first round's X-Men 2 read `LT` 21 a minute: the late definition, fixed -- §7.) |
| P5f | Weave / Bob / Blend | ✅ MERGED (PR fj#12) (§8): ✅ benched -- `run_disp_reader.sh --red` (13 arms, K1-K10 + D1-D5), `run_disp_sched.sh --red` (D14), `run_scaffold.sh --red` (W33 / W34); fit `UMD_p5f-deint_20260927_0206.rbf` (SEED 9, clk_dec 91.68 / 90.28, 28,062 ALM, M10K 256 (+18), DSP 74; SEED 1 missed at 85.95 on P4's `mv_pred`, none of P5f's paths); ✅ HW 2026-09-27: Family Guy Weave combs above Bob / Blend in every shot, Akira (film) the same in every mode, `DC` = `FT` in Bob on both, errors 0 (§8) |
| P5g | closeout | ✅ MERGED (PR fj#13), HW-CONFIRMED. **Timing:** `umd.sdc` bounds every `cdc_snap` at 8 ns (`hold -> dst_data`, the two synchroniser first stages): the three clk_mem -> clk_sys snapshots had sat at -0.28 / -0.09 ns since P5e, timed on the 3.7 ns 90 / 27 MHz edge window the handshake never uses; `fmax_check.sh` now warns on negative setup slack on any core-PLL clock; `disp_reader`'s dead `m_parity` gone. Fit `UMD_p5g_20260927_0308.rbf` (SEED 9, clk_dec 92.91 / 90.46, 28,073 ALM, M10K 256, DSP 74; every core clock positive, clk_sys +2.32 / +2.52 ns); ✅ HW 2026-09-27, 60 s of settled playback each (`telem --watch 60`, Bob): Family Guy 29.970 pairs/s, 2.000 refreshes a pair, decided +3,851 = fetched +3,851; Akira loaded over it, 23.976 pictures/s, 2.500 refreshes a picture, +1,541 = +1,541; `late` / `starve` / `cadence` 0, one anchor, decode errors 0 on both, Akira's picture clean (a first Akira window that began inside the launch transient read -1,541 ppm and a re-anchor: discarded, re-measured settled). ✅ `run_disp_reader.sh`, `run_scaffold.sh`. **✅ A title's end on the rig** (2026-09-27, the P5f build, Family Guy's whole 22.6 min main title in Bob): the END record taken (`sched` ended), every emitted store picked up (40,652 = 40,652), `late` / `starve` / `cadence` 0, decode errors 0, the judder gate equal throughout and after the end (a held pair still alternates its fields: `DC` = `FT` climbing ~60 / s); the last picture held -- two shots 12 s apart identical, black, and the stream's own last ~85 pictures are video black (ffmpeg: peak luma 16-18). Two re-anchors mid-title, at 521 s and 747 s of the title: the stream's timestamps skip a field and repeat one at seven edit points (351, 521, 747, 778, 1,010, 1,120, 1,349 s); the scheduler re-anchored at two of them (why only those two: inferred -- a PTS-tagged picture at the break -- not proven), with nothing late or dropped. **✅ The whole-library `run_cosim.sh --sweep`** (2026-09-27): 88 of 89 disc images bit-exact over 300 frames of the main title with the output order and holds scored (Desperado SKIP: a zero-filled rip), 0 FAIL / REFUSED / ORACLE; every PASS >= 1.35x real time (the slowest The Office Disc 01 1.35x, as at P4; Red Hot Chili Peppers 1.40x next). Per disc against the P4 sweep (2026-09-25): no verdict changed but Astro Boy (FAIL -> PASS, P4's later fix); the library changed since (King Kong now two disc ISOs in a folder, My Chemical Romance two, Hellboy II's empty zip gone, Metallica and Now That's What I Call Music 2006 added). The runner globs only the top level: the two folders ran as their own sweeps (since fixed: `--sweep` descends one level, `fix/timing-tools`). |

## 10. A lone PTS: UMD's rules A and B (ported 2026-09-30)

**What UMD found** (its `docs/display.md` §10.6-§10.9; PR fj#25 `74aa193` rule A, PR fj#26 `7087070`
rule B): UMD's discs carry an occasional PES PTS 1-8 ticks off the timeline -- 208 of them on 73
of 88 images, 206 LATE (a GOP-opening PES stamped a few ticks late) and 2 early -- with the next
tag back on the old timeline (both the pic_struct timeline and the SEI's HRD delays disagree
with the lone one). The scheduler believed it: a late one held a picture ~3x (the scheduler
waited for it), then the next tag's return re-anchored the STC back ~80 ms and `recon_dpb`'s
store alarm tripped (UMD's whole-film gate: three points of *Akira*); an early one (behind the
timeline by more than a frame) re-anchored at once and then waited on the return.

**The rule** (`h264/disp_sched.sv` ev[1] `lone_pts`, `tools/disp_sched_ref.py` "lone PTS"): a
TAGGED head more than half a refresh (750 ticks; 900 on the 50 Hz raster) and at most FWD_MAX
(0.5 s) off the timeline, AHEAD (rule A) or BEHIND (rule B), not late past LATE_MAX, is
**disbelieved** -- taken as untagged, shown on the timeline -- unless the previous tag taken was
disbelieved too (`susp`): the next tag is always believed, so a real jump under 0.5 s is
followed one tag (~0.5 s) late, and a larger one re-anchors at once as before (`back1s`,
`gap2s`). The flag is set by the pickup of a disbelieved head, cleared by the pickup of a
believed tagged one, and by the stream's reset (this tree has no seek `clr`). The edge is half a
refresh, not a frame: +1 tick past it (UMD's *Simpsons Movie*) held a picture one refresh too
long, and +1 frame came back as a re-anchor.

**Why here:** this core's streams come from programs, not discs, but a container can carry the
same shape (a TS remux with one late PES, a player's rounding); Sunshine / Moonlight sends no PTS
(`moonlight.md`: `-1`), so a game stream never meets the rule. The port is UMD's logic with this
tree's differences: `half` from the raster (750 / 900), the audio anchor's state (anchored, no
timeline yet) never judged (`ln` needs `next_valid`), and `tag_e` (the tag after the rule) in
the audio anchor's `far` leg too, so a disbelieved tag can never anchor.

**Visible:** `disp_ctl`'s `n_lone` (4 bits, saturating) is the status block's `disp_lone`, word
27 [30:27] -- interface **0.7** (additive: bits that were zero). `spec_hardening.md` lists the
rule as a known deviation (a real sub-0.5 s jump followed one tag late).

**Also found by UMD** (§10.9 there, harmless, not changed): the timeline advances in whole ticks
for untagged pictures (Q3 accumulates, but `want` is taken from `next_q3 >> 3`), so a 23.976
picture's untagged position drifts -0.75 tick a frame against an exact timeline until the next
tag; `loneearly` models it (a frame-early tag reads -3,746, not -3,754.5).

**Benched** (`bench/h264/run_disp_sched.sh --red`): scenarios lone7, lonefld, lone2, loneearly,
loneearlyfld, back1s (UMD's) and lone7@2 (the edge at 50 Hz's 900), on the progressive and the
480i rasters; mutations D18-D26 (UMD's D30-D38); D2 / D4's anchors narrowed (the compares now
appear twice). The model's `lone` count is scored against `n_lone` ([count]). **Result
(2026-09-30): ALL GREEN** -- 74 runs refresh-exact, 32 mutations each caught by its own arm.
