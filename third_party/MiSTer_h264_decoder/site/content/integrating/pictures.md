# Pictures you decode yourself

!!! info "Version 1.0 -- frozen"
    Part of the interface's definition, fixed for every 1.x core
    ([Versions](interface.md#versions)). Build against the client library: it carries the
    layout and the rules below.

The core decodes H.264. If your program meets video in another format -- MPEG-2, MPEG-4 Part 2,
Motion JPEG, anything libavcodec decodes -- it can decode the pictures itself on the ARM and hand
them to the core **as pictures**. The core then shows them exactly as it shows its own decoded
pictures: fitted to the output, deinterlaced, anti-twittered on a CRT, in time with your audio,
on HDMI and analog alike. Nothing is converted to RGB, and you do not pace the frames yourself.

How it works: you write each picture into one of the core's **picture stores** in shared memory,
then send a small **PICTURE** record naming the store. The core's display takes it from there.

The bundled file player does this for MPEG-1/2, DivX / Xvid, WMV 7/8, Theora, Motion JPEG and
H.263 (`clients/player`, `clients/common/vdec.c` in the repository).

## Limits

- **In practice: standard definition, up to 30 frames per second.** The limit is the ARM, not the
  core. Your program has one A9 core (MiSTer's own program holds the other), and that core both
  decodes and copies: the copy into the stores alone takes about 5.3 ms for a 720x480 picture and
  14 ms for a 1280x720 one ([What it costs](#what-it-costs)). The bundled player measured nine codecs
  playing standard-definition files in real time at 13-75 % of the core. At 1280x720 the copy alone
  takes about 42 % of the core at 30 frames per second, before any decoding: the interface accepts
  720p pictures, but a software decoder on the ARM does not keep up. A stream the ARM cannot keep
  up with plays behind, as any decoder that falls behind does.
- **The format: planar 8-bit 4:2:0** in the store. The library's copy also takes 8-bit 4:2:2 and
  full-range (`yuvj`) pictures and converts them as it copies, at a cost. Anything else -- 10-bit,
  4:4:4, RGB, packed formats -- your program converts first, on the same core.
- **The size: up to 3,600 macroblocks** (1280x720, 720x576 and smaller, any shape) **and 2,048
  pixels a side** -- the same bound as the core's own decoding.
- **One kind per stream:** a stream is your pictures or H.264 access units, never both
  ([below](#a-stream-is-pictures-or-access-units)).
- **20 stores:** a store stays the core's while its picture is queued or on screen; when every one
  is, `h264ring_picture_acquire` returns `-EAGAIN` and you wait.

## What it costs

The stores are outside Linux's memory, mapped uncached: copying into them runs at about 97 MB/s
and keeps the CPU busy while it does. A 720x480 picture takes about 5.3 ms, a 1280x720 one about
14 ms. A full-range or 4:2:2 picture (MJPEG, most webcams) costs more for its conversion: about
8 ms at 640x480 full-range 4:2:2 -- less with a full-range colour code, which keeps the samples
as they are (below). With one ARM core free (MiSTer's own program holds the other), that leaves room for
software decoding up to DVD size at 30 frames per second; the file player stops there.

## A stream is pictures or access units

A stream -- from a session's start, a flush, or a DISCONTINUITY -- is either H.264 access units
for the core to decode, or pictures of yours: its first video record decides. Mixing them is
refused (error 11). While your stream is pictures, the decoder is idle and all 20 stores are
yours. The library refuses picture calls until a flush or a session start has followed your last
access unit.

## The store

Store `k` (0 to 19) is 2 MiB at `H264RING_DPB_BYTE + k x H264RING_DPB_STORE`. A picture is planar
8-bit 4:2:0, in the matrix and range its record's colour code says (0, auto: BT.601 limited for a
standard-definition picture, BT.709 limited from 1,280 wide or 577 high -- [The colour](interface.md#records)),
in whole macroblocks: `W` macroblocks wide, `HF` tall (16
lines each):

| plane | starts at byte | bytes a row | rows |
|---|---|---|---|
| Y | 0 | 16 W | 16 HF |
| Cb | 256 W HF | 8 W | 8 HF |
| Cr | 320 W HF | 8 W | 8 HF |

An interlaced picture is a **field pair, woven**: row 0 of the top field, row 0 of the bottom
field, row 1 of the top field, and so on, in every plane -- the way most decoders hand out an
interlaced frame. Fill the rows and columns past your picture's own size (the library copies the
edge out), since the display's filters read a little past the edge.

Say which field comes first (the structure: top first or bottom first) and the core keeps the order
on an interlaced output: at 480i / 576i a pair starts on a field of its first field's parity, waiting
one field when it would land on the other (word 85 counts those waits).

## The library

```c
h264ring *r;
h264ring_open_devmem(&r, H264RING_OPEN_PICTURES);       /* also maps the stores */
h264ring_start_session(r, 2000);

struct h264ring_picture pic = {
    .width = 720, .height = 480,
    .structure = H264RING_PIC_STRUCT_PAIR_TOP,   /* or _FRAME, _PAIR_BOT */
    .pic_struct = -1,                            /* frames: 5 / 6 for MPEG-2's repeat_first_field */
    .sar_w = 8, .sar_h = 9,                      /* 0:0 if unknown */
    .rate_num = 30000, .rate_den = 1001,         /* 0 / 0 if unknown */
};
for each decoded picture:
    unsigned k;
    if (h264ring_picture_acquire(r, &k) == -EAGAIN) { /* every store still on screen: later */ }
    h264ring_picture_copy(h264ring_picture_store(r, k), &pic, planes, strides, H264RING_PIX_YUV420P);
    h264ring_write_picture(r, k, &pic, pts_90khz, 0, 1000);   /* the last: H264RING_F_END_OF_STREAM */
```

- `h264ring_picture_acquire()` returns a store the display no longer needs (the store rule,
  below). Call it on the thread that writes the ring.
- `h264ring_picture_copy()` takes 8-bit 4:2:0 or 4:2:2, limited or full range
  (`H264RING_PIX_YUV420P`, `_YUVJ420P`, `_YUV422P`, `_YUVJ422P`): full range is converted to
  limited -- unless the picture's `colour` is a full-range code (`H264RING_COLOUR_601_FULL`,
  `_709_FULL`, `_2020_FULL`): then the samples are kept as they are and the core converts them,
  cheaper on the ARM (a limited source with a full-range code is refused) --, 4:2:2 averaged to
  4:2:0 (within each field for a pair). It touches only the store, so any thread may call it.
- `struct h264ring_picture`'s `colour`: the picture's matrix and range (`H264RING_COLOUR_*`;
  0 auto). Set it from what your decoder reports (ffmpeg's `colorspace` and `color_range`) when it
  knows; leave 0 when it does not.
- `h264ring_write_picture()` (and `h264ring_try_write_picture()`) sends the record, with your
  presentation time and the same flags an access unit takes (DISCONTINUITY, END_OF_STREAM,
  LOW_LATENCY, GRAPHICS). Send pictures in presentation order.
- `h264ring_picture_layout()` gives the coded size, the planes' offsets and the crop, if you copy
  yourself.

## The PICTURE record

Type 5, a 32-byte payload of four little-endian 64-bit words. The library builds it; the layout is
in `h264ring_layout.h` (`H264RING_PIC_*`) and in the design notes.

| word | bits | field |
|---|---|---|
| 0 | 4-0 | the store |
| | 15-8, 23-16 | the size in macroblocks: width, frame height (even for a pair) |
| | 25-24 | 0 a frame, 1 a field pair (top first), 2 a field pair (bottom first) |
| | 35-32, 36 | `pic_struct` (frames: 0, 3-8) and whether it is given |
| | 47-40 | `aspect_ratio_idc` (0 unknown, 1-16, or 255 with the SAR in word 1) |
| 1 | 15-0, 31-16, 32 | the SAR's width and height; the timing given |
| 2 | 31-0, 63-32 | `num_units_in_tick`, `time_scale` (frames a second = `time_scale / (2 num_units_in_tick)`) |
| 3 | 9-0 ... 39-30 | the crop: left, right, top, bottom, in pairs of columns / lines |

Every field is checked; a bad one stops the session with errors 11-16 ([The interface](interface.md#errors)).

## The store rule

You may write a store only while the display does not need it. Status word 84 tells you:
`pic_held`, the stores the display holds (queued or on screen), and `pic_emitted`, how many
PICTURE records it has taken since the core started. Number your pictures from `pic_emitted` as
it reads after your session starts (in a status copy showing the state READY); a store is free
again once a status copy shows `pic_emitted` at or past its picture's number **and** its
`pic_held` bit clear. `h264ring_picture_acquire()` does exactly this. Break the rule and the
picture on screen tears; a PICTURE naming a store still held stops the session (error 16).
