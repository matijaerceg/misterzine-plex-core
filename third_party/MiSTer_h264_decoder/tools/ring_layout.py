#!/usr/bin/env python3
"""ring_layout.py -- the HPS interface's layout, written down once (docs/architecture.md
"The HPS interface"). Interface version 1.4 (1.0 FROZEN, roadmap Phase 7; 1.2 adds playback geometry, 1.3 adds display policy status, 1.4 reserves display policy extension bits after restoring 50/60 refresh matching). Nothing published
here moves or changes its meaning within 1.x; a minor version only adds (a field in bits
that read 0, a word that read 0, a record type that was refused), and 0 must keep meaning
what it meant. Any change here is an interface change -- bump VERSION, update the
manual's integrating/ pages and announce it in the release notes (CLAUDE.md "The HPS
interface is a published contract", docs/architecture.md "Version 1.0").

Generated from these tables (committed; `--check` fails if any differs):
  h264/ring_iface.svh               the constants and codes, the status fields' positions
  h264/ring_words_sys.sv            the status words built on clk_sys (a mux on the word index)
  h264/ring_words_mem.sv            ... whose sources are on clk_mem (read through cdc_snap_ix)
  h264/ring_words_dec.sv            ... whose sources are on clk_dec (read through cdc_snap_ix)
  h264/ring_words_in.sv             (0.6) the input region's words (h264/ring_in.sv's state)
  hps/include/h264ring_layout.h     the same for the client library and h264stat

    ring_layout.py            write them
    ring_layout.py --check    exit 1 if a generated file differs from the tables

THE REGION (DDR3, the FPGA's half: 0x2000_0000-0x3FFF_FFFF; the core's DPB is 0x3200_0000 +40 MB,
above the ring, since 0.11 -- not the program's, never written by it):
  the control block  CTRL_BYTE, 4 KB. Words 0-31, 40-47 and (0.10) 80-87 are written by the
                     core (every raster frame, as six bursts of eight: 0-7, 8-15, 16-23, 40-47,
                     80-87, 24-31, so seq_tail in word 31 is last); words 32-39 by the program
                     (0.13: 36-38 the pads' rumble; 1.2: 39 geometry request). Word 31's high
                     half carries the geometry acknowledgement. Word 88 holds the clip viewport.
                     (0.6) Words 48-71, the input
                     region: written by the core on change (at most every 1 ms) and each
                     frame, three bursts in order under a seqlock of its own (in_head 48
                     first, in_tail 71 last). No word has two writers (the core's master has
                     no byte enables). (0.9) Words 72-79, the overlay's descriptor: written
                     by the program (gen_hi 79 first, gen_lo 72 last), read by the core once a
                     refresh on ram2 (docs/architecture.md "The overlay plane").
  the framebuffer    (0.9) FB_BYTE, FB_SIZE: the kernel's MiSTer_fb region, not the core's; the
                     overlay's page must lie inside it.
  the ring           RING_BYTE, RING_SIZE (a power of two). Indices are free-running u32
                     byte counts, never zeroed; a byte's place is index % RING_SIZE.

THE RECORD: a 16-byte header, then the payload padded to a multiple of 16 (so every
record starts 16-aligned and a PAD always fits before the ring's end).
  word 0  [7:0] type  [15:8] flags  [31:16] seq (records since the session began, mod
          2^16, PADs included)  [63:32] payload length in bytes
  word 1  [32:0] PTS (90 kHz)  [35:33] colour (0.16: VIDEO_AU and PICTURE; 0 auto)  [47:36] zero
          [63:48] SYNC
Type 0 is never valid: an unwritten or torn header (zeros) is refused, never parsed.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

VERSION_MAJOR, VERSION_MINOR = 1, 4    # preserve the published 1.4 interface; retired extension bits remain reserved
                                       # 1.2 (2026-10-16, calibrated playback geometry: program word 39 + clip word 88)
                                       # 1.1 (2026-10-10, behaviour only, the layout unchanged): a late
                                       # picture never runs the clock back over queued audio that leads it
                                       # (docs/architecture.md "Queued audio: ..."; a 1.1 program may rely on it);
                                       # 1.0: the 0.17 layout, frozen (the library accepts a core of
                                       # the same major and a minor >= its own);
                                       # 0.2 (P6 step 3): word 30, the fit's telemetry (additive);
                                       # 0.3 (P6 part 2): word 30's raster report (additive);
                                       # 0.4: the GRAPHICS flag, word 27's OSD mirror (additive);
                                       # 0.5 (Phase 4): AUDIO played (the ring is its buffer:
                                       # read_index is the released index), word 34 the pause
                                       # and attenuation, words 40-47 the audio's status;
                                       # 0.6 (the Moonlight input): words 48-71, Main's input;
                                       # 0.7 (UMD's lone-PTS rules): word 27's disp_lone;
                                       # 0.8 (reaching the program from the pad): event type 3,
                                       # the OSD's actions;
                                       # 0.9 (Phase 6b): the overlay plane -- program words 72-79
                                       # the descriptor, core words 46-47 its status;
                                       # 0.10 (docs/hdmi_raster.md): core words 80-87, the
                                       # raster (word 80); word 47 relative to it
                                       # 0.11 (720p): word 81, the core's capabilities (the
                                       # largest picture: 3,600 macroblocks; additive)
                                       # 0.12 (docs/hd_raster.md): the native raster on 81 MHz --
                                       # cap_native_h 720, the overlay's canvas to 2,048 x 2,048
                                       # 0.13: program words 36-38 the pads' rumble, core words
                                       # 82-83 the rumble applied (docs/architecture.md "Rumble")
                                       # 0.14: word 80's video_out, Video Output as resolved (Auto
                                       # can be Native: docs/analog.md §11; additive)
                                       # 0.15: record type 5 PICTURE (a picture the program wrote
                                       # into a DPB store), word 84 the stores' state, errors 11-16,
                                       # the DPB published (docs/architecture.md "Pictures from the program")
                                       # 0.16: header word 1 [35:33] the colour code (the matrix and range;
                                       # 0 auto: the VUI, else the size rule), error 17, word 80's colour, word 86
                                       # the shown picture's colour description (docs/architecture.md "The colour")
                                       # 0.17: word 30's fit_valid -- the fit's fields (word 30) and the picture's
                                       # place (word 80) read 0 while no picture is shown (the Jellyfin client's F5)
MAGIC = int.from_bytes(b"MiSTH264", "little")
CTRL_BYTE = 0x3140_0000          # word 0x0628_0000: where 0.1-0.10's 1 MB stores ended (unmoved since)
RING_BYTE = 0x3180_0000          # word 0x0630_0000
RING_SIZE = 0x0080_0000          # 8 MiB: Level 3.1 High's NAL MaxCPB is 21 Mbit (Tables A-1, A-2)
MAX_PAYLOAD = 0x0040_0000        # 4 MiB: above the 2.6 MB CPB; a larger record is refused
CORE_WORDS = 32                  # words 0-31: the core's
PROG_WORD = 32                   # words 32-39: the program's (34 the pause / attenuation: 0.5; 35 the settings
                                 # request: 0.4; 36-38 rumble: 0.13; 39 geometry request: 1.2)
RUMBLE_WORD = PROG_WORD + 4      # 0.13: words 36-38, the pads' rumble (two pads a u32)
RUMBLE_PADS = 6                  # 0.13: hps_io's joystick_0..5_rumble
CORE2_WORD = 40                  # 0.5: words 40-47, the core's second region (the audio's status)
CORE2_WORDS = 8
CORE3_WORD = 80                  # 0.10: words 80-87, the core's third region (the raster: docs/hdmi_raster.md)
CORE3_WORDS = 8
IN_WORD = 48                     # 0.6: words 48-71, the input region (docs/architecture.md "Input (interface 0.6)")
IN_WORDS = 24
IN_Q_WORD = 56                   # 0.6: the event queue, words 56-63: IN_Q_LEN entries of 16 bits
IN_Q_LEN = 32
IN_ACTIONS = 2                   # 0.8: the OSD's action entries (CONF_STR's R[17], R[18]): action n is status[17 + n]
OVL_WORD = 72                    # 0.9: words 72-79, the overlay's descriptor (the program's)
OVL_WORDS = 8
FB_BYTE = 0x2200_0000            # 0.9: the Linux framebuffer's region (MiSTer_fb, the device tree's reg)
FB_SIZE = 0x0080_0000            # 8 MiB
DPB_BYTE = 0x3200_0000           # 0.11: the core's DPB (h264/emu.sv DPB_BASE, word 0x0640_0000); 0.15: published --
DPB_STORES = 20                  # 20 stores (h264_pkg NSTORE) of 2 MiB (a 3,600-macroblock picture is 1.84 MB
DPB_STORE = 0x0020_0000          # with its side words; docs/h264_recon.md S2.2), above the ring. A picture stream's
                                 # program writes them (docs/architecture.md "Pictures from the program")
PIC_PAYLOAD = 32                 # 0.15: a PICTURE's descriptor, bytes (exactly)
PIC_MAX_SIDE = 128               # 0.15: a PICTURE's widest / tallest, macroblocks (disp_reader's 2,048-sample slots)
CAP_MAX_MBS = 3600               # 0.11: Level 3.1's MaxFS (Table A-1): the largest picture the core decodes
CAP_MB_RATE = 108000             # 0.11: Level 3.1's MaxMBPS: the macroblock rate the core is designed for
CAP_NATIVE_H = 720               # 0.12: Native (HDMI)'s tallest 16:9 picture at its own size at 60 Hz (raster_geom; 0.11: 480)
OVL_MAX_W = 2048                 # 0.12: the widest raster (the native raster's; 0.10: 1,024; 0.9: 720)
OVL_MAX_H = 2048                 # 0.12: the tallest raster (the native raster's; 0.10: 2,047; 0.9: 576). A canvas
                                 # wider or taller than the raster shown is centred and clipped (ovl_clip)
AUD_MAX_RECORDS = 256            # 0.5: unplayed AUDIO records the core holds; past it the reader waits
SYNC = 0x5248                    # "HR", header word 1 [63:48]
REC_ALIGN = 16

CONSTS = [
    ("VERSION", (VERSION_MAJOR << 8) | VERSION_MINOR, 16, "interface version, major << 8 | minor"),
    ("CTRL_BYTE", CTRL_BYTE, 32, "the control block's byte address"),
    ("RING_BYTE", RING_BYTE, 32, "the ring's byte address"),
    ("RING_SIZE", RING_SIZE, 32, "the ring's size in bytes (a power of two)"),
    ("MAX_PAYLOAD", MAX_PAYLOAD, 32, "the largest payload a record may carry"),
    ("CORE_WORDS", CORE_WORDS, 8, "control words written by the core (0 .. CORE_WORDS-1)"),
    ("PROG_WORD", PROG_WORD, 8, "the first control word written by the program"),
    ("W_WRITE_INDEX", PROG_WORD + 0, 8, "program: the write index (u32, low half; the high half is ignored)"),
    ("W_NONCE", PROG_WORD + 1, 8, "program: the session nonce (u32, low half)"),
    ("W_PAUSE", PROG_WORD + 2, 8, "program (0.5): the pause and attenuation (u32, low half: [0] PAUSE, [15:8] ATTEN, the rest 0)"),
    ("CTL_PAUSE_BIT", 0, 8, "pause word: the PAUSE level"),
    ("CTL_ATTEN_LSB", 8, 8, "pause word: ATTEN [15:8], 0.5 dB steps (0 full volume, 255 mute)"),
    ("CTL_RESERVED", 0xFFFF00FE, 32, "pause word: the bits that must be 0 (a word with one set is refused whole)"),
    ("W_SETTINGS", PROG_WORD + 3, 8, "program (0.4): the settings request (u32, low half: values, mask, seq)"),
    ("REQ_MASK_LSB", 13, 8, "settings request: the mask's first bit (one bit an option, in the mirror's order)"),
    ("REQ_SEQ_LSB", 24, 8, "settings request: the sequence number [31:24] (0 = no request)"),
    ("W_RUMBLE", RUMBLE_WORD, 8, "program (0.13): the pads' rumble, words W_RUMBLE .. +2 (u32, low half: [15:0] pad 2k, [31:16] pad 2k+1)"),
    ("W_GEOMETRY", PROG_WORD + 7, 8, "program (1.2): calibrated picture rectangle request; word 88 supplies the clip viewport"),
    ("W_GEOMETRY_CLIP", 88, 8, "program (1.2): calibrated clip viewport, written before W_GEOMETRY"),
    ("GEOMETRY_X_LSB", 39, 8, "geometry word 39: signed x, 13-bit two's complement (bits 51:39)"),
    ("GEOMETRY_Y_LSB", 26, 8, "geometry word 39: signed y, 13-bit two's complement (bits 38:26)"),
    ("GEOMETRY_W_LSB", 13, 8, "geometry word 39: output width (bits 25:13)"),
    ("GEOMETRY_H_LSB", 0, 8, "geometry word 39: output height (bits 12:0)"),
    ("GEOMETRY_CLIP_X_LSB", 0, 8, "geometry clip word 88: x (bits 11:0)"),
    ("GEOMETRY_CLIP_Y_LSB", 12, 8, "geometry clip word 88: y (bits 23:12)"),
    ("GEOMETRY_CLIP_W_LSB", 24, 8, "geometry clip word 88: width (bits 35:24)"),
    ("GEOMETRY_CLIP_H_LSB", 36, 8, "geometry clip word 88: height (bits 47:36)"),
    ("GEOMETRY_SEQ_LSB", 56, 8, "geometry request word 39: nonzero request sequence"),
    ("GEOMETRY_ACK_W", 31, 8, "core: geometry acknowledgement in word 31 high half"),
    ("GEOMETRY_ERR_LSB", 40, 8, "core: geometry request result (0 accepted, 1 invalid range, 2 reserved bits)"),
    ("RUMBLE_PADS", RUMBLE_PADS, 8, "(0.13) pads with a rumble value: pad n is Main's player n+1 (the input region's pad n)"),
    ("RUMBLE_LARGE_LSB", 8, 8, "(0.13) a pad's value: [15:8] the large (low-frequency, strong) motor, [7:0] the small (high-frequency, weak); 0 off"),
    ("POLL_WORDS", PROG_WORD + 8 - PROG_WORD, 8, "(1.2) the core's poll reads words PROG_WORD .. +7, including geometry word 39"),
    ("CORE2_WORD", CORE2_WORD, 8, "(0.5) the first word of the core's second region (40-47)"),
    ("CORE2_WORDS", CORE2_WORDS, 8, "(0.5) its size in words"),
    ("CORE3_WORD", CORE3_WORD, 8, "(0.10) the first word of the core's third region (80-87)"),
    ("CORE3_WORDS", CORE3_WORDS, 8, "(0.10) its size in words"),
    ("IN_WORD", IN_WORD, 8, "(0.6) the input region's first word (in_head)"),
    ("IN_WORDS", IN_WORDS, 8, "(0.6) its size in words (in_tail is the last)"),
    ("IN_Q_WORD", IN_Q_WORD, 8, "(0.6) the event queue's first word: event n is entry n % IN_Q_LEN, 16 bits, four a word"),
    ("IN_Q_LEN", IN_Q_LEN, 8, "(0.6) the event queue's entries"),
    ("EV_TYPE_LSB", 14, 8, "(0.6) an event's type [15:14]"),
    ("EV_KEY_PRESSED", 9, 8, "(0.6) a key event: [9] pressed, [8] extended (E0), [7:0] the PS/2 set-2 code"),
    ("EV_KEY_EXT", 8, 8, "(0.6) a key event: the E0 prefix"),
    ("IN_ACTIONS", IN_ACTIONS, 8, "(0.8) the OSD's action entries: an ACTION event's number is 0 .. IN_ACTIONS-1"),
    ("OVL_WORD", OVL_WORD, 8, "(0.9) the overlay's descriptor, words 72-79 (the program's; u32 each, low half)"),
    ("W_OVL_GEN_LO", OVL_WORD + 0, 8, "(0.9) program: the descriptor's generation, written LAST"),
    ("W_OVL_CTL", OVL_WORD + 1, 8, "(0.9) program: [0] ENABLE, [2:1] FORMAT (OVL_FMT_*), the rest 0"),
    ("W_OVL_BASE", OVL_WORD + 2, 8, "(0.9) program: the page's physical byte address (a multiple of 8)"),
    ("W_OVL_SIZE", OVL_WORD + 3, 8, "(0.9) program: [15:0] width 1..OVL_MAX_W, [31:16] height 1..OVL_MAX_H"),
    ("W_OVL_STRIDE", OVL_WORD + 4, 8, "(0.9) program: [15:0] bytes a line (a multiple of 8, >= width x bytes a pixel), [31:16] 0"),
    ("W_OVL_BAND", OVL_WORD + 5, 8, "(0.9) program: [15:0] the first line drawn on, [31:16] the last (only these are fetched)"),
    ("W_OVL_RSVD", OVL_WORD + 6, 8, "(0.9) program: reserved, 0"),
    ("W_OVL_GEN_HI", OVL_WORD + 7, 8, "(0.9) program: the descriptor's generation, written FIRST"),
    ("OVL_CTL_ENABLE_BIT", 0, 8, "(0.9) ctl: ENABLE"),
    ("OVL_CTL_FMT_LSB", 1, 8, "(0.9) ctl: FORMAT [2:1]"),
    ("OVL_CTL_RESERVED", 0xFFFFFFF8, 32, "(0.9) ctl: the bits that must be 0"),
    ("OVL_MAX_W", OVL_MAX_W, 16, "(0.12) the canvas's widest: the widest raster (native: 2,048; 0.10: 1,024; 0.9: 720)"),
    ("OVL_MAX_H", OVL_MAX_H, 16, "(0.12) the canvas's tallest: the tallest raster (native: 2,048; 0.10: 2,047; 0.9: 576)"),
    ("FB_BYTE", FB_BYTE, 32, "(0.9) the Linux framebuffer's region (MiSTer_fb): the overlay's page lies inside it"),
    ("FB_SIZE", FB_SIZE, 32, "(0.9) its size in bytes"),
    ("AUD_MAX_RECORDS", AUD_MAX_RECORDS, 16, "(0.5) unplayed AUDIO records the core holds before the reader waits"),
    ("AUD_RATE", 48000, 32, "(0.5) AUDIO payloads: 48 kHz, s16 little-endian, stereo interleaved (4 bytes a frame)"),
    ("DPB_BYTE", DPB_BYTE, 32, "(0.15) the DPB's stores: store k at DPB_BYTE + k x DPB_STORE (the decoder's in a coded stream, the program's in a picture stream)"),
    ("DPB_STORES", DPB_STORES, 8, "(0.15) the stores"),
    ("DPB_STORE", DPB_STORE, 32, "(0.15) a store's size in bytes"),
    ("PIC_PAYLOAD", PIC_PAYLOAD, 8, "(0.15) a PICTURE's payload: exactly this many bytes (four u64)"),
    ("PIC_MAX_SIDE", PIC_MAX_SIDE, 8, "(0.15) a PICTURE's w_mbs / hf_mbs at most"),
    ("CAP_MAX_MBS", CAP_MAX_MBS, 16, "(0.11) word 81's cap_max_mbs: (0.15) a PICTURE's w_mbs x hf_mbs at most"),
    ("PIC_RSV0", 0xFFFF00E0FC0000E0, 64, "(0.15) a PICTURE's P0: the bits that must be 0"),
    ("PIC_RSV1", 0xFFFFFFFE00000000, 64, "(0.15) ... P1's"),
    ("PIC_RSV3", 0xFFFFFF0000000000, 64, "(0.15) ... P3's (P2 has none)"),
    ("PIC_STRUCT_FRAME", 0, 8, "(0.15) P0 [25:24] structure: a frame"),
    ("PIC_STRUCT_PAIR_TOP", 1, 8, "(0.15) ... a field pair, top field first (woven)"),
    ("PIC_STRUCT_PAIR_BOT", 2, 8, "(0.15) ... a field pair, bottom field first (woven)"),
    ("SYNC", SYNC, 16, "header word 1 [63:48]"),
    ("HDR_COLOUR_LSB", 33, 8, "(0.16) header word 1 [35:33]: the colour code (docs/architecture.md 'The colour'); VIDEO_AU and PICTURE only"),
    ("COLOUR_AUTO", 0, 8, "(0.16) colour 0: auto -- the stream's VUI, else the size rule (>= 1,280 wide or > 576 high: BT.709, else BT.601)"),
    ("COLOUR_601", 1, 8, "(0.16) colour 1: BT.601, limited range"),
    ("COLOUR_601_FULL", 2, 8, "(0.16) colour 2: BT.601, full range"),
    ("COLOUR_709", 3, 8, "(0.16) colour 3: BT.709, limited range"),
    ("COLOUR_709_FULL", 4, 8, "(0.16) colour 4: BT.709, full range"),
    ("COLOUR_2020", 5, 8, "(0.16) colour 5: BT.2020 (non-constant luminance), limited range"),
    ("COLOUR_2020_FULL", 6, 8, "(0.16) colour 6: BT.2020 (non-constant luminance), full range (7: reserved, HDR_COLOUR)"),
    ("REC_ALIGN", REC_ALIGN, 8, "records start on this alignment; payloads are padded to it"),
]

TYPES = [("INVALID", 0), ("PAD", 1), ("VIDEO_AU", 2), ("AUDIO", 3), ("CONTROL", 4),
         ("PICTURE", 5)]                       # 0.15: a picture the program wrote into a store
FLAGS = [   # bit, and the record types it is allowed on
    ("PTS_VALID", 0, ("VIDEO_AU", "AUDIO", "PICTURE")),
    ("DISCONTINUITY", 1, ("VIDEO_AU", "PICTURE")),
    ("END_OF_STREAM", 2, ("VIDEO_AU", "PICTURE")),
    ("LOW_LATENCY", 3, ("VIDEO_AU", "PICTURE")),
    ("GRAPHICS", 4, ("VIDEO_AU", "PICTURE")),  # 0.4: the stream is rendered graphics (Anti-Twitter Auto)
]
EVENTS = [   # 0.6: an input event's type ([15:14])
    ("KEY", 0, "(0.6) a key: [9] pressed, [8] extended, [7:0] the PS/2 set-2 code (hps_io's ps2_key [9:0])"),
    ("MOUSE_BTN", 1, "(0.6) the mouse buttons changed: [7:0] the buttons now (word 64's mouse_btn order)"),
    ("OSD", 2, "(0.6) Main's OSD: [0] opened (1) or closed (0)"),
    ("ACTION", 3, "(0.8) an OSD action chosen: [7:0] its number (0 'Send Home to the program', 1 'Program menu')"),
]
OVL_FORMATS = [   # 0.9: the overlay's pixel formats (ctl [2:1]): name, code, bytes a pixel
    ("1555", 0, 2), ("4444", 1, 2), ("8888", 2, 4),
]
OVL_STATES = [("OFF", 0), ("ACCEPTED", 1), ("REFUSED", 2)]   # 0.9: word 46's ovl_state
OVL_ERRORS = [   # 0.9: word 46's ovl_err, the first check a descriptor with ENABLE failed
    ("NONE", 0, "accepted, or off"),
    ("CTL", 1, "a reserved bit of ctl or word 78 set, or FORMAT 3"),
    ("SIZE", 2, "width not 1..OVL_MAX_W or height not 1..OVL_MAX_H"),
    ("STRIDE", 3, "the stride not a multiple of 8, below width x bytes a pixel, or its high half set"),
    ("ALIGN", 4, "the base not a multiple of 8"),
    ("BAND", 5, "the band's first line after its last, or its last not below the height"),
    ("RANGE", 6, "the canvas not wholly inside [FB_BYTE, FB_BYTE + FB_SIZE)"),
]
STATES = [("UNWRITTEN", 0), ("NO_SESSION", 1), ("READY", 2), ("PLAYING", 3), ("ENDED", 4), ("ERROR", 5)]
ERRORS = [   # the first one of a session is kept (engine errors win: they come first causally)
    ("NONE", 0, "no error"),
    ("WIDX_ALIGN", 1, "the write index is not a multiple of 16"),
    ("WIDX_RANGE", 2, "the write index is more than a ring ahead of the read index, or moved backwards"),
    ("HDR_SYNC", 3, "header word 1's sync or zero bits ([47:36]; 0.1-0.15: [47:33]) are wrong"),
    ("HDR_TYPE", 4, "type 0 or an unknown type"),
    ("HDR_FLAGS", 5, "an undefined flag, or a flag not allowed on this type"),
    ("HDR_LENGTH", 6, "a VIDEO_AU of length 0, an AUDIO of length 0 or not a multiple of 4 (0.5), a PICTURE not of PIC_PAYLOAD bytes (0.15), or any payload above MAX_PAYLOAD"),
    ("HDR_WRAP", 7, "a record crossing the ring's end, or a PAD not ending exactly there"),
    ("HDR_SEQ", 8, "the header's seq is not the next record's"),
    ("NEED_DISCONT", 9, "a VIDEO_AU (0.15: or a PICTURE) after END_OF_STREAM without DISCONTINUITY"),
    ("CONTROL_UNSUPPORTED", 10, "a CONTROL record (reserved: refused in 0.1)"),
    ("STREAM_KIND", 11, "(0.15) a PICTURE in a coded stream, or a VIDEO_AU in a picture stream (the stream's first video record decides)"),
    ("PIC_FIELD", 12, "(0.15) a PICTURE's descriptor: a reserved bit, structure 3, a pic_struct not allowed, an aspect_ratio_idc of 17-254 or 255 with a zero SAR, or timing with a zero field"),
    ("PIC_STORE", 13, "(0.15) a PICTURE's store at or above DPB_STORES"),
    ("PIC_SIZE", 14, "(0.15) a PICTURE's side 0 or above PIC_MAX_SIDE, an odd hf_mbs on a pair, or w_mbs x hf_mbs above cap_max_mbs"),
    ("PIC_CROP", 15, "(0.15) a PICTURE's crop leaving nothing"),
    ("PIC_BUSY", 16, "(0.15) a PICTURE's store still held by the display (the store rule broken)"),
    ("HDR_COLOUR", 17, "(0.16) header word 1's colour is 7, or non-zero on a PAD or an AUDIO record"),
]
LIVE = [   # status word 4 [23:16]
    ("LOW_LATENCY", 0, "the current stream asked for low latency"),
    ("EOS", 1, "END_OF_STREAM consumed for the current stream"),
    ("ENDED", 2, "the display took the stream's END (the last picture stays up)"),
    ("STC_RUN", 3, "the presentation clock is anchored and counting"),
    ("PLAYED", 4, "a picture has been shown since the core's reset (black between streams)"),
    ("OSD_OPEN", 5, "Main's OSD is open: a program forwarding input should pause it"),
    ("SESSION", 6, "a session is open"),
    ("GRAPHICS", 7, "(0.4) the current stream declared rendered graphics (its first VIDEO_AU)"),
]

# The core's status words: (word, domain, [(field, lsb, width, doc)]).
# domain: sys (built on clk_sys; the constants too), mem (sources on clk_mem), dec (clk_dec).
# A field's source is the SV port f_<field> of ring_words_<domain>.
WORDS = [
    (0, "sys", [("magic", 0, 64, "MAGIC, \"MiSTH264\"")]),
    (1, "sys", [("version", 0, 16, "VERSION"), ("core_words", 16, 16, "CORE_WORDS"),
                ("prog_word", 32, 16, "PROG_WORD"), ("core2_word", 48, 16, "(0.5) CORE2_WORD: the core's second region")]),
    (2, "sys", [("ring_byte", 0, 32, "RING_BYTE"), ("ring_size", 32, 32, "RING_SIZE")]),
    (3, "sys", [("seq_head", 0, 32, "the status sequence: +1 a frame (the heartbeat); read LAST"),
                ("max_payload", 32, 32, "MAX_PAYLOAD")]),
    (4, "sys", [("state", 0, 8, "STATE_*"), ("err", 8, 8, "ERR_* (the session's first)"),
                ("live", 16, 8, "LIVE_* bits"), ("osd", 24, 8, "the OSD settings: status[4:1] (aspect, deinterlace)"),
                ("err_pos", 32, 32, "the offending record's index, or the offending write index")]),
    (5, "mem", [("read_index", 0, 32, "the released index: the core needs nothing below it, so the program may overwrite it (0.5: held behind the oldest AUDIO record not yet fetched to play)"),
                ("ack_nonce", 32, 32, "the nonce of the session the core runs")]),
    (6, "sys", [("err_word", 0, 64, "the offending header word 0 verbatim (0 for an index error)")]),
    (7, "sys", [("stc", 0, 33, "the presentation clock (90 kHz)"), ("lag_ms", 48, 16, "the last pickup's lag, ms (signed)")]),
    (8, "sys", [("n_au", 0, 32, "VIDEO_AU records consumed"), ("n_audio", 32, 32, "AUDIO records queued for playing (0.4: skipped)")]),
    (9, "sys", [("n_pad", 0, 32, "PAD records"), ("n_streams", 32, 32, "streams started (session starts + DISCONTINUITY)")]),
    (10, "sys", [("es_bytes", 0, 32, "payload bytes delivered to the decoder"),
                 ("ll_mismatch", 32, 32, "VIDEO_AUs whose LOW_LATENCY differs from the stream's first")]),
    (11, "mem", [("n_polls", 0, 32, "reads of the program's words"), ("n_bursts", 32, 32, "ring read bursts")]),
    (12, "mem", [("eng_err", 0, 8, "the engine's error (ERR_WIDX_*)"), ("eng_session", 8, 1, "the engine runs a session"),
                 ("eng_widx", 32, 32, "the write index the engine last read")]),
    (13, "mem", [("fetch_changes", 0, 32, "disp_reader: shown (store, parity) changes fetched (never reset per stream)"),
                 ("probe_busy", 32, 16, "ram1: the current run of a request held under waitrequest")]),
    (14, "dec", [("fe_nal", 0, 32, "front end: NAL units"), ("fe_slice", 32, 32, "slices decoded")]),
    (15, "dec", [("fe_pic", 0, 32, "pictures (first_mb_in_slice 0)"), ("fe_refused", 32, 32, "refusals (REF_*)")]),
    (16, "dec", [("fe_err", 0, 32, "front-end errors (ERR_*)"), ("fe_bins", 32, 32, "CABAC bins / 256")]),
    (17, "dec", [("fe_pts_tag", 0, 32, "pictures tagged with a PTS"), ("fe_pts_drop", 32, 32, "PTS stamps dropped")]),
    (18, "dec", [("fe_refused_code", 0, 4, "the last refusal (h264_pkg REF_*)"), ("fe_err_code", 4, 4, "the last front-end error"),
                 ("rc_err_code", 8, 4, "the last reconstruction error"), ("fe_pic_struct", 12, 4, "the last pic_struct"),
                 ("rc_dpb_fill", 16, 5, "DPB stores in use"), ("out_ovf", 24, 1, "recon_out: a record pushed into a full FIFO (sticky)"),
                 ("out_rel_bad", 25, 1, "recon_out: a release of a store not held (sticky)"),
                 ("fe_sei_err", 32, 32, "malformed SEI NAL units")]),
    (19, "dec", [("rc_pic", 0, 32, "pictures reconstructed"), ("rc_mb", 32, 32, "macroblocks reconstructed")]),
    (20, "dec", [("rc_err", 0, 32, "reconstruction errors"), ("rc_ref_size", 32, 32, "pictures refused by size (> 3,600 MBs: word 81's cap_max_mbs; 0.1-0.10: > 1,620)")]),
    (21, "dec", [("rc_out_dropped", 0, 32, "stores dropped without output (no_output_of_prior_pics)"),
                 ("rc_out_direct", 32, 32, "non-reference pictures output directly")]),
    (22, "dec", [("rc_out_over", 0, 32, "a DPB full of references (non-conforming)"), ("rc_stall", 32, 32, "reconstruction stall cycles")]),
    (23, "dec", [("rc_nrf_late", 0, 32, "an output below the last POC output (non-conforming max_num_reorder_frames)"),
                 ("out_emit", 32, 32, "stores emitted to the display")]),
    (24, "dec", [("out_rel", 0, 32, "stores released by the display"), ("fe_pt_missing", 32, 32, "pictures missing a required picture timing SEI")]),
    (25, "sys", [("disp_dc", 0, 32, "decided (store, parity) changes (the judder pair's first half)"),
                 ("disp_pick", 32, 32, "pickups")]),
    (26, "sys", [("disp_skip", 0, 32, "pictures skipped in low latency"), ("disp_late", 32, 16, "late pickups"),
                 ("disp_starve", 48, 16, "starved refreshes")]),
    (27, "sys", [("disp_cadence", 0, 16, "cadence errors"), ("disp_reanchor", 16, 8, "re-anchors"),
                 ("disp_flags", 24, 3, "disp_ctl flags (timing defaulted / clamped / pic_struct)"),
                 ("disp_lone", 27, 4, "(0.7) lone PTS disbelieved: a tag off the timeline by more than half a refresh and at most 0.5 s, the tag before it believed -- taken as untagged (saturating)"),
                 ("osd_aspect", 32, 2, "(0.4) the OSD: Aspect Ratio -- 0 Auto, 1 4:3, 2 16:9"),
                 ("osd_deint", 34, 2, "(0.4) Deinterlace -- 0 Weave, 1 Bob, 2 Blend"),
                 ("osd_video_out", 36, 2, "(0.4) Video Output -- 0 Auto, 1 Interlaced, 2 Progressive, 3 Native (HDMI) (0.10)"),
                 ("osd_hdmi_deint", 38, 1, "(0.4) HDMI Deinterlace -- 0 Weave, 1 Bob"),
                 ("osd_analog_aspect", 39, 2, "(0.4) Analog Aspect -- 0 Auto, 1 Fit, 2 Letterbox, 3 Crop"),
                 ("osd_refresh", 41, 2, "(0.4) Refresh Rate -- 0 Auto, 1 59.94 Hz, 2 60 Hz, 3 50 Hz"),
                 ("osd_anti_twitter", 43, 2, "(0.4) Anti-Twitter -- 0 Auto (the stream's GRAPHICS), 1 Off, 2 On"),
                 ("set_err", 45, 3, "(0.4) the last settings request's result: 0 applied, 1 a value out of range, 2 a reserved bit set, 3 an empty mask"),
                 ("gfx_mismatch", 48, 16, "(0.4) VIDEO_AUs whose GRAPHICS differs from the stream's first (saturating)")]),
    (28, "mem", [("probe_wr", 0, 32, "ram1 write beats"), ("probe_rd", 32, 32, "ram1 read beats")]),
    (29, "mem", [("probe_owed", 0, 16, "ram1 read beats owed"), ("probe_busy_max", 16, 16, "ram1 longest busy run")]),
    (30, "sys", [("disp_fetch_late", 0, 16, "disp_reader: lines begun before their rows were all fetched (past the fit's caps; saturating)"),
                 ("fit_crop_bad", 16, 1, "the shown picture's crop left nothing: ignored, the coded picture shown whole (0.17: 0 while fit_valid is 0)"),
                 ("fit_clamp", 17, 1, "the fitted rectangle clamped at 8,191 (an absurd SAR under Crop) (0.17: 0 while fit_valid is 0)"),
                 ("fit_snap", 18, 1, "the shown picture is within 3.5 % of the raster: shown 1:1, unscaled (0.17: 0 while fit_valid is 0)"),
                 ("raster_std", 19, 2, "(0.3) the raster's rate: 0 59.94 Hz, 1 60.00 Hz (525 lines, 480 active), 2 50 Hz (625, 576 active); 3 reserved"),
                 ("raster_il", 21, 1, "(0.3) the raster is interlaced (480i / 576i: a refresh is a field)"),
                 ("raster_auto", 22, 1, "(0.3) Refresh Rate is Auto: the rate follows the stream's VUI rate (latched at its first picture)"),
                 ("anti_twitter", 23, 1, "(0.3) anti-twitter is applied to the shown picture"),
                 ("set_seq", 24, 8, "(0.4) the sequence number of the last settings request consumed (applied or refused)"),
                 ("fit_ow", 32, 13, "the shown picture's rectangle on the raster (720 x 480 or 576): width (pixels) (0.17: 0 while fit_valid is 0)"),
                 ("fit_valid", 45, 1, "(0.17) a picture is shown: the fit's fields (here) and its place on the raster (word 80's pic_x0 / pic_y0) describe it; 0: nothing is shown and they read 0 (a 0.16 core reads 0 here, its fit fields as before)"),
                 ("fit_oh", 48, 13, "... height (frame lines)")]),
    (31, "sys", [("seq_tail", 0, 32, "the status sequence again: read FIRST (equal to seq_head = a consistent copy)"),
                 ("geometry_ack_seq", 32, 8, "(1.2) calibrated picture rectangle request sequence consumed; 0 before a request"),
                 ("geometry_error", 40, 2, "(1.2) 0 applied, 1 range error, 2 reserved bits set; 3 reserved")]),
    # 0.5: the core's second region, written between words 16-23 and 24-31 (before seq_tail)
    (40, "sys", [("aud_state", 0, 2, "(0.5) audio: 0 idle (nothing queued), 1 armed (queued, waiting to start), 2 playing"),
                 ("aud_ll", 2, 1, "(0.5) audio follows the low-latency rule (the stream's LOW_LATENCY), else paced by the STC"),
                 ("aud_q_rec", 16, 9, "(0.5) AUDIO records queued, not yet played (at most AUD_MAX_RECORDS)"),
                 ("aud_q_samples", 32, 32, "(0.5) stereo samples queued, not yet played")]),
    (41, "sys", [("aud_played", 0, 32, "(0.5) samples played (counted at the gate, silence not included)"),
                 ("aud_records", 32, 32, "(0.5) AUDIO records finished (played, dropped or cut by a reset)")]),
    (42, "sys", [("aud_gap", 0, 32, "(0.5) samples of silence played for an early record (paced: a gap in the audio)"),
                 ("aud_late", 32, 32, "(0.5) samples dropped: late (paced), or a burst past the low-latency maximum")]),
    (43, "sys", [("aud_underruns", 0, 16, "(0.5) the queue ran empty while playing (saturating)"),
                 ("aud_slip_drop", 16, 16, "(0.5) low latency: single samples dropped for drift (saturating)"),
                 ("aud_slip_rep", 32, 16, "(0.5) low latency: single samples repeated for drift (saturating)"),
                 ("aud_anchor", 48, 16, "(0.5) the audio started the STC (no picture had; saturating)")]),
    (44, "sys", [("aud_offset", 0, 32, "(0.5) STC minus PTS at the last tagged record's first sample, 90 kHz ticks (signed; paced)"),
                 ("aud_hold_bytes", 32, 32, "(0.5) ring bytes the queued audio holds behind the reader")]),
    (45, "sys", [("paused", 0, 1, "(0.5) the pause is applied (word 34's PAUSE, during a session)"),
                 ("ctl_err", 1, 1, "(0.5) the last word 34 read had a reserved bit set: refused, the previous values kept"),
                 ("atten", 8, 8, "(0.5) the attenuation applied (word 34's ATTEN)")]),
    # 0.9: the overlay plane's status (docs/architecture.md "The overlay plane")
    (46, "sys", [("ovl_gen", 0, 32, "(0.9) the overlay: the generation of the last consistent descriptor read"),
                 ("ovl_state", 32, 2, "(0.9) 0 off, 1 accepted (shown while a session is open), 2 refused"),
                 ("ovl_at", 34, 1, "(0.9) the overlay is anti-twittered (480i / 576i, Anti-Twitter Auto or On)"),
                 ("ovl_clip", 35, 1, "(0.9) the canvas is taller (0.10: or wider) than the raster: its edge lines (columns) are not shown"),
                 ("ovl_err", 36, 4, "(0.9) OVL_E_*: the first check a refused descriptor failed (0 unless refused)"),
                 ("ovl_torn", 40, 8, "(0.9) descriptors read torn (gen_lo != gen_hi): ignored (saturating)"),
                 ("ovl_late", 48, 16, "(0.9) raster lines whose overlay line was not fetched in time: shown transparent (saturating)")]),
    (47, "sys", [("ar_x", 0, 12, "(0.9) the aspect HDMI's scaler is given (VIDEO_ARX): the raster (0.10: word 80's raster_w x raster_h) is shown ar_x : ar_y wide"),
                 ("ar_y", 12, 12, "(0.9) ... VIDEO_ARY"),
                 ("ovl_lines", 32, 32, "(0.9) canvas lines the overlay fetched (free-running: liveness)")]),
    # 0.10: the core's third region, written after words 40-47 (before seq_tail): the raster
    # (docs/hdmi_raster.md, docs/architecture.md "The raster (0.10)")
    (80, "sys", [("raster_w", 0, 12, "(0.10) the raster's active width, pixels (the overlay's canvas and the picture are placed on it)"),
                 ("raster_h", 12, 12, "(0.10) ... its active height, frame lines (480 / 576; a field is half of them)"),
                 ("raster_mode", 24, 2, "(0.10) 0 fitted (720 wide), 1 native, 2 native but this picture fell back to fitted"),
                 ("raster_lb", 26, 1, "(0.10) the picture is letterboxed inside the raster so the raster is shown at the HDMI display's shape (A')"),
                 ("video_out", 27, 2, "(0.14) Video Output as the core resolved it: 1 Interlaced, 2 Progressive, 3 Native (HDMI) -- Auto is one of them (a 0.13 core reads 0)"),
                 ("colour", 29, 3, "(0.16) the shown picture's colour code (COLOUR_*: 1-6; 1 before any picture; a 0.15 core reads 0)"),
                 ("pic_x0", 32, 13, "(0.10) the shown picture's rectangle (word 30's fit_ow x fit_oh) on the raster: left, two's complement (negative under Crop); (0.17) 0 while word 30's fit_valid is 0"),
                 ("pic_y0", 48, 13, "(0.10) ... top, frame lines, two's complement")]),
    # 0.11: the core's capabilities, constants (a 0.10 core reads 0 here: 1,620 / 480 / 97,200)
    (81, "sys", [("cap_max_mbs", 0, 16, "(0.11) the largest picture the core decodes, macroblocks (3,600: Level 3.1's MaxFS); a larger one is refused (rc_ref_size)"),
                 ("cap_native_h", 16, 12, "(0.11) Native (HDMI): the tallest 16:9 picture shown at its own size at 60 Hz, frame lines (0.12: 720 -- every picture the core decodes; 0.11: 480)"),
                 ("cap_mb_rate", 32, 32, "(0.11) the macroblock rate the core is designed for, macroblocks a second (108,000: Level 3.1's MaxMBPS); real time below it depends on the bitrate")]),
    # 0.13: the rumble passed to Main (docs/architecture.md "Rumble (interface 0.13)")
    (82, "sys", [("rum_p%d" % n, 16 * n, 16, ("(0.13) pad %d's rumble passed to Main now ({large, small}; 0 outside a session)" % n) if n == 0 else "(0.13) pad %d's" % n)
                 for n in range(4)]),
    (83, "sys", [("rum_p4", 0, 16, "(0.13) pad 4's"), ("rum_p5", 16, 16, "(0.13) pad 5's"),
                 ("rum_changes", 32, 32, "(0.13) the rumble passed to Main changed (any pad), counted since the PLL lock (wrapping)")]),
    # 0.15: the stores' state (docs/architecture.md "Pictures from the program": the store rule)
    (84, "sys", [("pic_held", 0, 20, "(0.15) the stores the display holds (queued or shown): set at an emission, cleared at the release"),
                 ("pic_mode", 20, 1, "(0.15) the current stream is a picture stream (its first video record was a PICTURE)"),
                 ("cap_pic_stores", 24, 8, "(0.15) the stores a picture stream may use: DPB_STORES (a 0.14 core reads 0)"),
                 ("pic_emitted", 32, 32, "(0.15) PICTURE records emitted to the display since the PLL lock (wrapping): with pic_held, the store rule")]),
    # 0.15: the display's field alignment (docs/analog.md §5)
    (85, "sys", [("disp_fhold", 0, 32, "(0.15) 480i / 576i: field pairs held one refresh so that each starts on the raster field of its first field (reset per stream, as disp_late)")]),
    # 0.16: the colour (docs/architecture.md "The colour (interface 0.16)", docs/colour.md)
    (86, "sys", [("vui_matrix", 0, 8, "(0.16) the shown picture's SPS matrix_coefficients as coded (2 when absent; a program's picture 2)"),
                 ("vui_primaries", 8, 8, "(0.16) ... colour_primaries (2 when absent)"),
                 ("vui_transfer", 16, 8, "(0.16) ... transfer_characteristics (2 when absent)"),
                 ("vui_full_range", 24, 1, "(0.16) ... video_full_range_flag (0 when absent)"),
                 ("vui_colour_present", 25, 1, "(0.16) ... colour_description_present_flag"),
                 ("colour_override", 26, 1, "(0.16) the stream's first VIDEO_AU set a non-zero colour (it overrides the stream's tags)"),
                 ("colour_unsup", 32, 16, "(0.16) pictures shown by the size rule because their matrix is not supported (0 GBR, 8 YCgCo, 10 BT.2020 cl, 11+), since the stream began (saturating)"),
                 ("colour_mismatch", 48, 16, "(0.16) VIDEO_AUs whose colour differed from the stream's first, since the stream began (saturating)")]),
    # 1.3/1.4: display policy mirror; word 88 remains the program's clip viewport.
    (87, "sys", [("display_profile", 0, 3, "(1.3) OSD selection: 0 480i60, 1 480p60, 2 576i50, 3 576p50, 4 Native HDMI"),
                 ("display_match_refresh", 3, 1, "(1.3) Match Video Refresh is enabled; its playback-only rate override restores the OSD profile when idle"),
                 ("display_240p", 4, 1, "(1.3) 240p Playback is requested; 288p at 50 Hz"),
                 ("display_film_speed", 5, 1, "(1.3) Film Speed is enabled for the program's frame-rate choice"),
                 ("display_wide", 6, 1, "(1.3) Display Shape is set to 16:9 (0 when 4:3)"),
                 ("display_effective_profile", 7, 4, "(1.3) resolved output family: 0 480i, 1 480p, 2 576i, 3 576p, 4 Native HDMI"),
                 ("display_raster_std", 11, 2, "(1.3) resolved raster rate: 0 59.94, 1 60.00, 2 50; 3 reserved"),
                 ("display_interlaced", 13, 1, "(1.3) resolved output is interlaced"),
                 ("display_deflicker", 14, 1, "(1.3) global vertical De-flicker is active; only applies to interlaced output"),
                 ("display_240p_active", 15, 1, "(1.3) the physical raster is currently progressive 240p or 288p"),
                 ("display_refresh_match_mode", 16, 2, "(1.4) Refresh Rate Match: 0 Off, 1 50/60; upper encodings reserved")])
]
# 0.6: the input region (docs/architecture.md "Input (interface 0.6)"), built by h264/ring_in.sv and
# written by h264/ring_stat.sv as its second job: (word, [(field, lsb, width, doc)])
INPUT = [(IN_WORD, [("in_head", 0, 32, "(0.6) +1 each write of the region; read LAST"),
                    ("ev_count", 32, 32, "(0.6) events queued since the PLL lock (free-running): the next event's number")])]
INPUT += [(IN_WORD + 1 + n, [("pad%d_joy" % n, 0, 32, "(0.6) pad %d: hps_io's joystick_%d (the d-pad [3:0], the J line's buttons from [4])" % (n, n)),
                             ("pad%d_lstick" % n, 32, 16, "(0.6) ... its left stick: Y [15:8], X [7:0], signed -127..127" if n == 0 else "(0.6) ... left stick"),
                             ("pad%d_rstick" % n, 48, 16, "(0.6) ... its right stick" if n == 0 else "(0.6) ... right stick")])
          for n in range(6)]
INPUT += [(IN_WORD + 7, [("dx_sum", 0, 32, "(0.6) the mouse: the sum of every packet's dx (signed, wrapping)"),
                         ("dy_sum", 32, 32, "(0.6) ... of every packet's dy (Y up-positive, as PS/2 packs it)")])]
INPUT += [(IN_Q_WORD + w, [("ev_q%d" % (4 * w + i), 16 * i, 16, "(0.6) event queue entry %d" % (4 * w + i)) for i in range(4)])
          for w in range(IN_Q_LEN // 4)]
INPUT += [(IN_Q_WORD + IN_Q_LEN // 4, [
              ("wheel_sum", 0, 32, "(0.6) the sum of every packet's wheel (signed, wrapping)"),
              ("mouse_btn", 32, 8, "(0.6) the mouse buttons now: [0] L [1] R [2] M [7:3] buttons 4-8"),
              ("osd_open", 40, 1, "(0.6) Main's OSD is open (as last applied to the queue)"),
              ("ev_lost", 48, 16, "(0.6) events the core could not queue (a second from one source while the first waited; saturating)")])]
INPUT += [(w, []) for w in range(IN_Q_WORD + IN_Q_LEN // 4 + 1, IN_WORD + IN_WORDS - 1)]
INPUT += [(IN_WORD + IN_WORDS - 1, [("in_tail", 0, 32, "(0.6) in_head again: read FIRST (equal to in_head = a consistent copy)")])]

CORE_REGIONS = list(range(CORE_WORDS)) + list(range(CORE2_WORD, CORE2_WORD + CORE2_WORDS)) + \
    list(range(CORE3_WORD, CORE3_WORD + CORE3_WORDS))
# the order the core writes the bursts: seq_head (word 3) first, seq_tail (word 31) last
WRITE_ORDER = list(range(0, 24)) + list(range(CORE2_WORD, CORE2_WORD + CORE2_WORDS)) + \
    list(range(CORE3_WORD, CORE3_WORD + CORE3_WORDS)) + list(range(24, 32))


def _check_tables():
    seen = set()
    assert [w for w, _ in INPUT] == list(range(IN_WORD, IN_WORD + IN_WORDS)), "INPUT must list 48..71 in order"
    assert IN_Q_LEN & (IN_Q_LEN - 1) == 0 and IN_WORD >= CORE2_WORD + CORE2_WORDS
    for w, fields in INPUT:
        used = 0
        for name, lsb, width, _ in fields:
            assert name not in seen, "field %s twice" % name
            seen.add(name)
            m = ((1 << width) - 1) << lsb
            assert lsb + width <= 64 and not (used & m), "word %d: %s overlaps" % (w, name)
            used |= m
    words = [w for w, _, _ in WORDS]
    assert words == CORE_REGIONS, "WORDS must list 0..%d, %d..%d and %d..%d in order" % (
        CORE_WORDS - 1, CORE2_WORD, CORE2_WORD + CORE2_WORDS - 1, CORE3_WORD, CORE3_WORD + CORE3_WORDS - 1)
    # the clk_mem / clk_dec words are below 64 (their masks and the snapshots' 6-bit index)
    assert all(w < 64 for w, d, _ in WORDS if d != "sys")
    assert sorted(WRITE_ORDER) == CORE_REGIONS and WRITE_ORDER[-1] == 31 and WRITE_ORDER.index(3) == 3
    assert PROG_WORD + 8 <= CORE2_WORD
    assert RUMBLE_WORD + (RUMBLE_PADS + 1) // 2 <= PROG_WORD + 8 and RUMBLE_PADS == 6
    for w, dom, fields in WORDS:
        assert dom in ("sys", "mem", "dec"), dom
        used = 0
        for name, lsb, width, _ in fields:
            assert name not in seen, "field %s twice" % name
            seen.add(name)
            m = ((1 << width) - 1) << lsb
            assert lsb + width <= 64 and not (used & m), "word %d: %s overlaps" % (w, name)
            used |= m
    assert RING_SIZE & (RING_SIZE - 1) == 0 and RING_BYTE % RING_SIZE == 0
    assert OVL_WORD >= IN_WORD + IN_WORDS and OVL_WORD % 8 == 0 and OVL_WORDS == 8
    assert FB_BYTE % 8 == 0 and FB_BYTE + FB_SIZE <= 0x3000_0000
    assert CORE3_WORD >= OVL_WORD + OVL_WORDS and CORE3_WORD % 8 == 0 and CORE3_WORDS == 8
    assert CTRL_BYTE + 8 * (CORE3_WORD + CORE3_WORDS) <= RING_BYTE and CTRL_BYTE >= 0x3000_0000
    # 0.11: the DPB above the ring, inside the FPGA's half, each store holding CAP_MAX_MBS x 512 B
    assert DPB_BYTE >= RING_BYTE + RING_SIZE and DPB_BYTE + DPB_STORES * DPB_STORE <= 0x4000_0000
    assert CAP_MAX_MBS * 512 <= DPB_STORE
    # 0.15: a PICTURE's largest picture fits a store; the store index fits P0 [4:0] and pic_held
    assert CAP_MAX_MBS * 384 <= DPB_STORE and DPB_STORES <= 20 and PIC_PAYLOAD == 32


def field(name):
    for w, dom, fields in WORDS + [(w, "in", fs) for w, fs in INPUT]:
        for f, lsb, width, doc in fields:
            if f == name:
                return w, lsb, width
    raise KeyError(name)


def const(name):
    return {n: v for n, v, _, _ in CONSTS}[name]


# ------------------------------------------------------------------------ generators
HDR = "generated by tools/ring_layout.py -- edit the tables there, never this file"


def gen_svh():
    o = ["// h264/ring_iface.svh -- the HPS interface's layout v%d.%d (%s)." % (VERSION_MAJOR, VERSION_MINOR, HDR),
         "// docs/architecture.md \"The HPS interface\". Included inside a module.", ""]
    o.append("localparam logic [63:0] RI_MAGIC = 64'h%016X;" % MAGIC)
    for n, v, w, doc in CONSTS:
        o.append("localparam logic [%d:0] RI_%s = %d'h%X;   // %s" % (w - 1, n, w, v, doc))
    o.append("localparam logic [28:0] RI_CTRL_WORD = 29'h%07X;   // CTRL_BYTE / 8" % (CTRL_BYTE >> 3))
    o.append("localparam logic [28:0] RI_RING_WORD = 29'h%07X;   // RING_BYTE / 8" % (RING_BYTE >> 3))
    o.append("localparam int RI_RING_AW = %d;                   // log2(RING_SIZE / 8)" % ((RING_SIZE >> 3).bit_length() - 1))
    for n, v in TYPES:
        o.append("localparam logic [7:0] RT_%s = 8'd%d;" % (n, v))
    for n, b, types in FLAGS:
        o.append("localparam int RF_%s = %d;   // on %s" % (n, b, ", ".join(types)))
    for n, v in STATES:
        o.append("localparam logic [7:0] RS_%s = 8'd%d;" % (n, v))
    for n, v, doc in EVENTS:
        o.append("localparam logic [1:0] RV_%s = 2'd%d;   // event type: %s" % (n, v, doc))
    for n, v, doc in ERRORS:
        o.append("localparam logic [7:0] RE_%s = 8'd%d;   // %s" % (n, v, doc))
    for n, b, doc in LIVE:
        o.append("localparam int RL_%s = %d;   // %s" % (n, b, doc))
    for n, v, nb in OVL_FORMATS:
        o.append("localparam logic [1:0] RO_FMT_%s = 2'd%d;   // (0.9) %d bytes a pixel" % (n, v, nb))
    for n, v in OVL_STATES:
        o.append("localparam logic [1:0] RO_S_%s = 2'd%d;" % (n, v))
    for n, v, doc in OVL_ERRORS:
        o.append("localparam logic [3:0] RO_E_%s = 4'd%d;   // (0.9) %s" % (n, v, doc))
    o.append("localparam logic [28:0] RI_OVL_DESC_WORD = 29'h%07X;   // (0.9) (CTRL_BYTE / 8) + OVL_WORD" % ((CTRL_BYTE >> 3) + OVL_WORD))
    mem = sum(1 << w for w, d, _ in WORDS if d == "mem")
    dec = sum(1 << w for w, d, _ in WORDS if d == "dec")
    o.append("localparam logic [63:0] RI_MEM_WORDS = 64'h%016X;   // status words read through the clk_mem snapshot" % mem)
    o.append("localparam logic [63:0] RI_DEC_WORDS = 64'h%016X;   // ... through the clk_dec snapshot" % dec)
    o.append("localparam int RI_NSTAT = %d;   // (0.5) status words written a frame, in RI_STAT_IX's order" % len(WRITE_ORDER))
    o.append("// (0.5) the write order: seq_head (word 3) first, words 40-47 before 24-31, seq_tail (word 31) last")
    o.append("localparam int RI_STAT_A = 24;   // steps 0-23: words 0-23")
    o.append("localparam int RI_STAT_B = %d;   // steps 24-%d: words %d-%d" % (
        24 + CORE2_WORDS, 24 + CORE2_WORDS - 1, CORE2_WORD, CORE2_WORD + CORE2_WORDS - 1))
    o.append("localparam int RI_STAT_C = %d;   // (0.10) steps %d-%d: words %d-%d; then 24-31" % (
        24 + CORE2_WORDS + CORE3_WORDS, 24 + CORE2_WORDS, 24 + CORE2_WORDS + CORE3_WORDS - 1,
        CORE3_WORD, CORE3_WORD + CORE3_WORDS - 1))
    return "\n".join(o) + "\n"


def gen_words(domain):
    fields = [(w, f) for w, d, fs in WORDS if d == domain for f in fs]
    name = "ring_words_" + domain
    o = ["// h264/%s.sv -- the HPS interface's status words whose sources are on %s (%s)." %
         (name, {"sys": "clk_sys", "mem": "clk_mem", "dec": "clk_dec"}[domain], HDR),
         "// A mux on the word index: combinational, the index quasi-static (h264/ring_stat.sv holds",
         "// it through the snapshot). Words of other domains read 0 here.",
         "", "`default_nettype none", "", "module %s (" % name,
         "    input  wire  [%d:0]  ix," % (6 if domain == "sys" else 5)]
    for w, (f, lsb, width, doc) in fields:
        if domain == "sys" and f in CONST_FIELDS:
            continue
        o.append("    input  wire  [%d:0] f_%s,%s// w%d: %s" % (width - 1, f, " " * max(1, 18 - len(f)), w, doc))
    o.append("    output logic [63:0] w")
    o.append(");")
    o.append("    always_comb begin")
    o.append("        w = 64'd0;")
    o.append("        case (ix)")
    for w, d, fs in WORDS:
        if d != domain or not fs:
            continue
        parts = []
        for f, lsb, width, doc in fs:
            src = CONST_FIELDS.get(f) if domain == "sys" else None
            src = ("%d'h%X" % (width, src)) if src is not None else "f_" + f
            parts.append("w[%d:%d] = %s;" % (lsb + width - 1, lsb, src))
        o.append("            %d'd%d: begin %s end" % (7 if domain == "sys" else 6, w, " ".join(parts)))
    o.append("            default: ;")
    o.append("        endcase")
    o.append("    end")
    o.append("endmodule")
    o.append("")
    o.append("`default_nettype wire")
    return "\n".join(o) + "\n"


def gen_words_in():
    o = ["// h264/ring_words_in.sv -- the HPS interface's input region, words %d-%d (0.6; %s)." %
         (IN_WORD, IN_WORD + IN_WORDS - 1, HDR),
         "// A mux on the region's own word index (0 = word %d): combinational; h264/ring_in.sv holds" % IN_WORD,
         "// the state it reads still while h264/ring_stat.sv pushes the region's words.",
         "", "`default_nettype none", "", "module ring_words_in (",
         "    input  wire  [4:0]  ix,"]
    for w, fs in INPUT:
        for f, lsb, width, doc in fs:
            o.append("    input  wire  [%d:0] f_%s,%s// w%d: %s" % (width - 1, f, " " * max(1, 18 - len(f)), w, doc))
    o.append("    output logic [63:0] w")
    o.append(");")
    o.append("    always_comb begin")
    o.append("        w = 64'd0;")
    o.append("        case (ix)")
    for w, fs in INPUT:
        if not fs:
            continue
        parts = ["w[%d:%d] = f_%s;" % (lsb + width - 1, lsb, f) for f, lsb, width, doc in fs]
        o.append("            5'd%d: begin %s end" % (w - IN_WORD, " ".join(parts)))
    o.append("            default: ;")
    o.append("        endcase")
    o.append("    end")
    o.append("endmodule")
    o.append("")
    o.append("`default_nettype wire")
    return "\n".join(o) + "\n"


CONST_FIELDS = {
    "magic": MAGIC, "version": (VERSION_MAJOR << 8) | VERSION_MINOR, "core_words": CORE_WORDS,
    "prog_word": PROG_WORD, "core2_word": CORE2_WORD, "ring_byte": RING_BYTE, "ring_size": RING_SIZE, "max_payload": MAX_PAYLOAD,
    "cap_max_mbs": CAP_MAX_MBS, "cap_native_h": CAP_NATIVE_H, "cap_mb_rate": CAP_MB_RATE,
    "cap_pic_stores": DPB_STORES,
}


def gen_h():
    o = ["/* hps/include/h264ring_layout.h -- the HPS interface's layout v%d.%d (%s). */" %
         (VERSION_MAJOR, VERSION_MINOR, HDR),
         "/* SPDX-License-Identifier: MIT (hps/LICENSE) */",
         "#ifndef H264RING_LAYOUT_H", "#define H264RING_LAYOUT_H", "", "#include <stdint.h>", ""]
    o.append("#define H264RING_MAGIC 0x%016XULL /* \"MiSTH264\" */" % MAGIC)
    for n, v, w, doc in CONSTS:
        o.append("#define H264RING_%s 0x%XU /* %s */" % (n, v, doc))
    o.append("")
    for n, v in TYPES:
        o.append("#define H264RING_T_%s %d" % (n, v))
    for n, b, types in FLAGS:
        o.append("#define H264RING_F_%s (1U << %d) /* on %s */" % (n, b, ", ".join(types)))
    for n, v in STATES:
        o.append("#define H264RING_S_%s %d" % (n, v))
    for n, v, doc in ERRORS:
        o.append("#define H264RING_E_%s %d /* %s */" % (n, v, doc))
    for n, b, doc in LIVE:
        o.append("#define H264RING_L_%s (1U << %d) /* %s */" % (n, b, doc))
    for n, v, doc in EVENTS:
        o.append("#define H264RING_EV_%s %d /* an event type: %s */" % (n, v, doc))
    for n, v, nb in OVL_FORMATS:
        o.append("#define H264RING_OVL_FMT_%s %d /* (0.9) %d bytes a pixel */" % (n, v, nb))
    for n, v in OVL_STATES:
        o.append("#define H264RING_OVL_S_%s %d" % (n, v))
    for n, v, doc in OVL_ERRORS:
        o.append("#define H264RING_OVL_E_%s %d /* (0.9) %s */" % (n, v, doc))
    o.append("")
    o.append("/* status fields: word, lsb, width */")
    for w, d, fs in WORDS:
        for f, lsb, width, doc in fs:
            o.append("#define H264RING_%s_W %d" % (f.upper(), w))
            o.append("#define H264RING_%s_LSB %d" % (f.upper(), lsb))
            o.append("#define H264RING_%s_WIDTH %d /* %s */" % (f.upper(), width, doc))
    o.append("")
    o.append("struct h264ring_field { const char *name; uint8_t word, lsb, width; };")
    o.append("#define H264RING_FIELDS { \\")
    for w, d, fs in WORDS:
        for f, lsb, width, doc in fs:
            o.append("    { \"%s\", %d, %d, %d }, \\" % (f, w, lsb, width))
    o.append("}")
    o.append("#define H264RING_NFIELDS %d" % sum(len(fs) for _, _, fs in WORDS))
    o.append("")
    o.append("/* (0.6) the input region's fields: word (absolute), lsb, width */")
    for w, fs in INPUT:
        for f, lsb, width, doc in fs:
            if f.startswith("ev_q"):
                continue                  # the queue: H264RING_IN_Q_WORD / H264RING_IN_Q_LEN
            o.append("#define H264RING_%s_W %d" % (f.upper(), w))
            o.append("#define H264RING_%s_LSB %d" % (f.upper(), lsb))
            o.append("#define H264RING_%s_WIDTH %d /* %s */" % (f.upper(), width, doc))
    o.append("#define H264RING_IN_FIELDS { \\")
    for w, fs in INPUT:
        for f, lsb, width, doc in fs:
            if not f.startswith("ev_q"):
                o.append("    { \"%s\", %d, %d, %d }, \\" % (f, w, lsb, width))
    o.append("}")
    o.append("#define H264RING_IN_NFIELDS %d" % sum(1 for _, fs in INPUT for f in fs if not f[0].startswith("ev_q")))
    o.append("")
    o.append("static inline uint64_t h264ring_get(const uint64_t *w, unsigned word, unsigned lsb, unsigned width)")
    o.append("{")
    o.append("    uint64_t v = w[word] >> lsb;")
    o.append("    return width >= 64 ? v : (v & ((1ULL << width) - 1));")
    o.append("}")
    o.append("#define H264RING_GET(w, F) h264ring_get((w), H264RING_##F##_W, H264RING_##F##_LSB, H264RING_##F##_WIDTH)")
    o.append("")
    o.append("#endif")
    return "\n".join(o) + "\n"


OUTPUTS = [
    ("h264/ring_iface.svh", gen_svh),
    ("h264/ring_words_sys.sv", lambda: gen_words("sys")),
    ("h264/ring_words_mem.sv", lambda: gen_words("mem")),
    ("h264/ring_words_dec.sv", lambda: gen_words("dec")),
    ("h264/ring_words_in.sv", gen_words_in),
    ("hps/include/h264ring_layout.h", gen_h),
]


def main(argv):
    _check_tables()
    check = "--check" in argv
    bad = 0
    for rel, fn in OUTPUTS:
        path = os.path.join(ROOT, rel)
        text = fn()
        if check:
            old = open(path).read() if os.path.exists(path) else None
            if old != text:
                print("ring_layout: %s differs from the tables (run tools/ring_layout.py)" % rel)
                bad = 1
        else:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as f:
                f.write(text)
            print("wrote " + rel)
    if check and not bad:
        print("ring_layout: generated files match")
    return bad


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
