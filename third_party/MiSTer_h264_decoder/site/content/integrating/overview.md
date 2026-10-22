# Integrating a program

This part of the manual is for developers of programs that run on the MiSTer's ARM side
and want the FPGA to decode and show their video.

**How it works.** Your program does everything a player does except decode: it connects
to the network, reads files, demultiplexes the container (MPEG-TS, MP4, RTP), and
decrypts if it must. It then hands the core **H.264 access units** (Annex-B byte stream,
one access unit per record), each optionally with a presentation time, by writing them
into a ring in shared memory. The core decodes the video, paces it against its own clock
(or shows each picture as soon as it is decoded, for game streaming), and shows the
result on HDMI and analog. Nothing decoded comes back to your program; it reads the core's
status block instead: its state, errors, its presentation clock and counters.

**What you get:** H.264 decoding the ARM chip could not do in software, on every output the
MiSTer has. Video in other formats your program can decode itself and hand over as
pictures: the core presents them as its own ([Pictures you decode](pictures.md)).

**What your program still does:** networking, container parsing, decryption, error
correction, and anything else that is not decoding and presentation. Its user interface it
draws itself, into the Linux framebuffer; the core shows it over the video on every output
([Your own screens](overlay.md)).

!!! info "Interface version 1.1 -- the layout frozen at 1.0"
    The layout and the meaning of every word are fixed for every 1.x core: a later version
    only adds, so a program built for 1.0 keeps working on newer cores
    ([Versions](interface.md#versions)). 1.1 changes no word: audio written ahead of its
    video can no longer stop the picture. Build against the client library: it carries the
    layout and checks the version.

## The pieces

- **The interface** -- a control block and a ring of records in the MiSTer's DDR3:
  [The interface](interface.md).
- **The client library** (`hps/` in the repository: `libh264ring.a` and its headers) -- maps
  the memory, starts a session, writes records, reads the status: [The client
  library](library.md).
- **The reference feeder, `h264play`** -- plays an H.264 file through the library; the
  example to start from.
- **`h264stat`** -- prints the status block, alone or beside a running feeder.
- **The four programs in `clients/`** (Moonlight, the upstream core's cast-only Jellyfin client,
  the video player, the camera viewer) -- complete programs on the same library,
  GPL-3.0-or-later. MisterZine Jellyfin releases include none of them; MisterZine Jellyfin
  feeds the core with its own player.
  `clients/common/` holds what three of them share: the session, the on-screen interface drawn
  into the overlay, input, subtitles, and decoding other formats on the ARM.
- **Launching the core, and input** (MiSTer's menu keeps the devices; the core passes on its
  keyboard, mouse and gamepads): [Launch and input](launch.md).
- **Your own screens** -- draw into the Linux framebuffer; the core composites it over
  the video on HDMI and analog: [Your own screens](overlay.md).

## What the core decodes today

H.264 **Main** and **High** profile (High is what a stock Moonlight / Sunshine host always
sends), 8-bit 4:2:0, CABAC, frame and field pictures, up to 3,600 macroblocks a picture
(1280x720; word 81 tells your program, [the interface](interface.md)). A stream the core does
not decode (CAVLC, MBAFF, monochrome, 4:2:2 / 4:4:4, 10-bit) is refused, and the refusal
is visible in the status block; a CAVLC stream is rewritten into CABAC by the library's
write calls before it is queued, up to a few Mbit/s ([CAVLC streams](library.md#cavlc-streams)). A program that plays files directly (rather than asking a
server to transcode them) can check the stream's SPS before sending it -- `profile_idc`,
`chroma_format_idc`, the bit depths, `entropy_coding_mode_flag` in the PPS,
`frame_mbs_only_flag` / `mb_adaptive_frame_field_flag`, the picture size and the frame rate
against `h264ring_caps()` -- and ask for a transcode instead. In real time up to 854x480 at 60
or 1280x720 at 30 frames/s (measured to 8 Mbit/s at 720p30 with B-frames, about 13 % to spare); a
denser stream plays correctly but late, and the lateness is counted. See [Compatibility](../reference/compatibility.md).

**Audio:** your program decodes it (any codec its libraries support) and sends **PCM, 48 kHz
16-bit stereo**, through the same ring with presentation times; the core plays it in sync
with the pictures, or as it arrives for a low-latency game stream, and takes a pause and a
volume from your program out of band. See [Audio](audio.md).

**Input:** while a core runs, MiSTer's own program holds every keyboard, mouse and gamepad, so
your program cannot read them itself. The core passes on what MiSTer sends it -- six gamepads
in the user's own button mapping, every key, the mouse, and MiSTer's menu opening and closing
-- for your program to read. See [Launch and input](launch.md#input).
