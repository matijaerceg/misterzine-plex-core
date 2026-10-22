# The client library

The repository's `hps/` directory holds a small C library (C99, libc only) that implements
[the interface](interface.md), a reference file player built on it, and a status tool.
Build against the library rather than writing the words yourself: it carries the layout,
and it checks the core's version when it attaches -- a core of the same major and a minor
at least the library's ([Versions](interface.md#versions)).

## Building

```bash
cd hps
make                          # a host build (the unit tests; your PC has no core to talk to)
make test
USE_DOCKER=1 ./build_arm.sh   # the MiSTer build: build/arm/{h264play,h264stat,cavlc2cabac,libh264ring.a}
```

The ARM build uses a pinned GCC 10.2 cross compiler (in Docker with `USE_DOCKER=1`, or
`arm-none-linux-gnueabihf-gcc` on your `PATH`), targets the Cortex-A9 with NEON and links
statically: copy the binaries to the MiSTer and run them, nothing to install.

To use the library in your program, link `libh264ring.a` and include `h264ring.h`.

## Playing a stream

```c
#include "h264ring.h"

h264ring *r;
if (h264ring_launch_core(NULL, 10000)      /* load the core unless it is running */
    || h264ring_open_devmem(&r, 0)         /* map the memory, take the lock */
    || h264ring_start_session(r, 3000))    /* a new session, acknowledged */
    return 1;

for (each access unit) {
    unsigned flags = last ? H264RING_F_END_OF_STREAM : 0;
    int rc = h264ring_write_au(r, au, au_len, pts_or_minus_1, flags, 1000);
    if (rc == -ENOTCONN) { /* the menu's Reset ended the session: start a new one */ }
    if (rc) break;          /* -EPROTO: the core refused a record -- read the status */
}
h264ring_close(r);
```

- `h264ring_open_devmem` returns `-EPROTONOSUPPORT` when the core's interface is another major
  version, or an older minor than the library's ([Versions](interface.md#versions)); a program
  that reads word 1 itself applies the same rule with `h264ring_version_ok(core,
  H264RING_VERSION)`.
- `h264ring_write_au` waits (up to its timeout) while the ring is full; `h264ring_try_write_au`
  returns `-EAGAIN` instead, for a program with its own event loop.
- Pass a PTS (90 kHz) when you have a presentation time, or `-1` to let the core pace the
  pictures by the stream's timing. A PTS is a *presentation* time: for a stream with B
  frames, give each access unit its own, not a counter in decoding order.
- After `END_OF_STREAM`, the next access unit automatically carries `DISCONTINUITY`.
- **To seek** (or switch streams at once), call `h264ring_flush(r, timeout_ms)`: it drops
  everything the core has not read yet and resets the stream (a new session; ~15-40 ms),
  then write from an IDR picture. A `DISCONTINUITY` flag alone waits for the queue to
  play out -- seconds with a full ring. See [Seeking](interface.md#seeking).
- `h264ring_split_annexb` splits an Annex-B buffer into access units, as the core needs them.
- `h264ring_write_audio(r, pcm, len, pts, timeout_ms)` writes one AUDIO record: 48 kHz
  16-bit stereo PCM, `len` a multiple of 4 (`-EINVAL` otherwise), `pts` its first frame's
  presentation time or `-1` to continue from the record before; `h264ring_try_write_audio`
  returns `-EAGAIN` instead of waiting. See [Audio](audio.md).
- `h264ring_set_pause(r, on)` and `h264ring_set_atten(r, half_db)` pause / resume and
  set the audio's attenuation (0.5 dB steps, 0 full volume, 255 mute) -- out of band, within a
  few milliseconds. See [Pausing](interface.md#pausing).
- `h264ring_request_settings(r, mask, values)` changes the core's menu settings from your
  program: `mask` of `1u << H264RING_OPT_*`, `values[H264RING_OPT_*]` their menu positions;
  returns the request's sequence number (compare it with the status block's `set_seq`).
  `h264ring_clear_settings(r)` withdraws it (the core re-applies a request left in place at
  every new session's start).
- `h264ring_status` returns a consistent copy of the status block; `H264RING_ST(&st, FIELD)`
  reads a field (the names are in `h264ring_layout.h`); `h264ring_dump` prints them all.
- `h264ring_raster(&st, &rs)` decodes the raster your overlay is drawn for: its size
  (`rs.w` x `rs.h`), the shape it is shown at (`rs.aspect`: word 47 on HDMI, 4:3 on the
  interlaced output), whether the picture is letterboxed inside it (`rs.lb`) and the picture's
  rectangle (`rs.pic_x0`, `rs.pic_y0`, `rs.pic_w`, `rs.pic_h`).
  `h264ring_state_name`, `h264ring_error_name` and `h264ring_refusal_name` turn the state, a
  record error and the decoder's refusal (`FE_REFUSED_CODE`: why it will not decode a stream --
  CAVLC, MBAFF, a picture over 128 macroblocks a side...) into words for your log or your screen.
- `h264ring_caps(&st, &caps)` decodes what the core can play (word 81): `caps.max_mbs`,
  the largest picture in macroblocks (3,600: 1280x720), `caps.mb_rate`, the macroblocks a second
  it is designed for (108,000), and `caps.native_h`, the tallest 16:9 picture Native (HDMI) shows
  at its own size (720: choose a transcode no taller). A picture past `max_mbs` is not refused
  at its SPS: its slices are dropped and counted (`RC_REF_SIZE`), so check before you send.
- `h264ring_video_out(&st)` is Video Output as the core resolved it:
  `H264RING_VOUT_INTERLACED`, `_PROGRESSIVE` or `_NATIVE`. The menu's Auto is one of them (Native
  on an HDMI-only MiSTer), so ask this -- not the menu's value -- whether pictures are shown at
  their own pixels (a client choosing a 1280x720 transcode does).
- `h264ring_set_colour(r, code)` sets the colour code every later access unit carries
  (`H264RING_COLOUR_*`; 0, auto, by default: the stream's own tags, else BT.601 for standard
  definition and BT.709 from 1,280 wide or 577 high). The core takes it from a stream's first access
  unit, so set it before the stream starts. Leave it at 0 unless you know the stream's tags are wrong
  ([The colour](interface.md#records)).

Every call returns 0 or a negative `errno` value.

## CAVLC streams

The core decodes CABAC streams only. A stream coded with **CAVLC** -- phone and web video
(Constrained Baseline), a server transcoding with x264's `ultrafast` preset (High profile,
CAVLC), a game-streaming host forced to it -- would be refused by the core. **The
library's write calls rewrite it into CABAC by themselves**: write CAVLC or CABAC as you have it, and the
core receives the same pictures, bit for bit. A CABAC access unit passes untouched (a few header
bytes are read; nothing is copied).

Two more results from `h264ring_write_au` / `h264ring_try_write_au` (include
`h264ring_cavlc.h` for the calls below):

| Result | Meaning |
|---|---|
| `-EOPNOTSUPP` | the stream uses something the core cannot be given -- slice groups (FMO), arbitrary slice order, redundant pictures, data partitioning, SP / SI slices, or what it does not decode anyway (MBAFF, 4:2:2 / 4:4:4, 10-bit). `h264ring_rewrite_why(r)` names it. Nothing is written. **The status block does not show it** (the core never saw the stream): log the reason yourself |
| `-EBADMSG` | a CAVLC access unit that does not parse (damaged): `h264ring_rewrite_why(r)`. Nothing is written; skip to the next IDR picture |

- The rewrite starts afresh with each stream: a new session, `h264ring_flush()`, an access unit
  with `DISCONTINUITY` (also the one the library adds after `END_OF_STREAM`).
- A retry of the same access unit after `-EAGAIN` is not rewritten twice (the library keeps the
  last rewrite and compares the bytes, so reusing one buffer for every unit is safe).
- **It costs ARM time, inside the write call: about 11-12 % of one core per Mbit/s at 480p,
  60 frames/s** (a 3.2 Mbit/s stream ~45 %, a 2 Mbit/s Constrained Baseline one ~38 %), most of
  it in proportion to the bitrate. Main keeps one of the two cores busy, so your program and the
  rewrite share the other: **CAVLC plays in real time up to about 4-5 Mbit/s** at 480p60 (more
  at 30 frames/s); above that the pictures are late (counted in the status block), never wrong.
- **If you pace your writes** (a live source, `--realtime` in `h264play`), rewrite each access
  unit before its due time with `h264ring_prepare_au(r, au, len, flags)` -- the same bytes and
  flags you will write; the write is then free. Rewritten inside a write made at its due time,
  an IDR picture (~25 ms on the A9) would reach the core late.
- `h264ring_set_rewrite(r, 0)` writes every access unit as given (the core then refuses CAVLC
  itself); `h264ring_rewrite_stats(r, &st)` counts what was rewritten.

The rewrite is also available on its own, for any buffer: `h264ring_cavlc_new()`,
`h264ring_cavlc_au(cv, in, len, &out, &out_len)` (`H264RING_CAVLC_PASS`, `_REWRITTEN`,
`_REFUSED`, `_ERROR`), `h264ring_cavlc_reset`, `h264ring_cavlc_why`, `h264ring_cavlc_free`.
`hps/cavlc2cabac` uses it to rewrite a file (`cavlc2cabac IN.264 OUT.264`) and to measure the
cost on your MiSTer (`cavlc2cabac --bench 2 --fps 59.94 IN.264`).

## Reading the input

`h264ring_input(r, &in)` copies the [input region](interface.md#the-input-region)
consistently (0, or `-EAGAIN` if every try met a write). `h264ring_input_events(&in, &count,
ev, cap, &lost)` hands you the events after your count, oldest first, and advances it; it adds
to `lost` the events the queue no longer held. `H264RING_IN(&in, FIELD)` reads a field
(`PAD0_JOY`, `DX_SUM`, `OSD_OPEN`, ...); `H264RING_EV_TYPE`, `_CODE`, `_EXT`, `_PRESSED` and
`_OPEN` take an event apart, and `H264RING_PAD_*` name a pad's buttons. Both calls only read,
so an input thread may call them while another thread writes the ring. An example:
[Input](launch.md#input).

## Rumble

`h264ring_rumble(r, pad, large, small)` sets a gamepad's two motors (0 off .. 255 full;
`large` the low-frequency one -- a game-streaming host's low-frequency motor divided by 256 --
`small` the high-frequency one): [Rumble](interface.md#rumble). Call
`h264ring_rumble_keepalive(r)` at least once a second while anything rumbles: MiSTer plays a
value for at most 32.767 s, and the call keeps a held one going by changing it one imperceptible
step every 10 s. Both only write the rumble's own words, so an input thread may call them (from
one thread) while another writes the ring, once your first session has started. The library
writes your values at your first session and zeroes them at `h264ring_close()`.

## Showing your own screens

`h264ring_fb_map` maps the Linux framebuffer; draw a page into it, then
`h264ring_overlay_show` describes it to the core (checked first: what the core would refuse
returns `-EINVAL`) and `h264ring_overlay_wait` waits until the core has read it -- after which
the previous page is free to draw into. A session start (`h264ring_start_session`,
`h264ring_flush`) writes your descriptor again with a newer generation, so the wait also returns
once the core has read any later one: a flip just before a seek does not wait out its timeout. `h264ring_overlay_hide` takes it down. Every session
start writes your overlay again (or none), so another program's never shows under yours. See
[Your own screens](overlay.md).

## Pictures you decode yourself

Open with `H264RING_OPEN_PICTURES`, then per picture `h264ring_picture_acquire()`,
`h264ring_picture_copy()` and `h264ring_write_picture()`: the core shows the picture as one it
decoded. See [Pictures you decode](pictures.md).

## One program at a time

`h264ring_open_devmem` takes a lock (`/tmp/h264ring.lock`); a second program gets `-EBUSY`.
A reader that only watches the status (`h264stat`) opens with `H264RING_OPEN_NOLOCK`.

**One thread at a time, too.** The ring has one writer: a session's write position and record
numbering are the handle's state, and the library takes no lock of its own. A program that
writes video and audio from different threads (a streaming client's receive threads, for
example) must serialize every call on the same handle with its own mutex. Wait out a full ring
with the `h264ring_try_*` calls and a short sleep outside that mutex, so one stream's wait
does not hold the other off.

## h264play

The reference feeder: it plays an Annex-B `.264` / `.h264` file and prints the final status
as JSON.

```text
h264play [--fps N] [--pts] [--realtime] [--ll] [--graphics] [--colour N] [--loop N] [--switch FILE [--at N] [--flush]]
         [--osd name=v,...] [--overlay [1555|4444|8888] [--overlay-band A,B] [--overlay-size W,H]]
         [--pcm FILE [--pcm-offset MS] [--pcm-chunk MS] [--pcm-lead MS] [--audio-only]] [--atten N] [--pause A,B]
         [--rumble P,L,S] [--no-cavlc] [--no-launch] [--rbf PATH] [--quiet] [--list] FILE.264
```

| option | |
|---|---|
| `--pts` | stamp access unit *i* with *i* x 90000 / fps (only for streams without B frames) |
| `--fps N` | the rate for `--pts` and `--realtime` (default 59.94) |
| `--realtime` | write access units at that rate, like a live source |
| `--ll` | low latency: show each picture as soon as it is decoded |
| `--graphics` | declare the stream rendered graphics: Anti-Twitter on Auto filters it on an interlaced output |
| `--colour N` | the stream's colour code (`h264ring_set_colour()`): 0 auto (the stream's tags, else by size), 1-6 the matrix and range ([The colour](interface.md#records)) |
| `--osd LIST` | change the core's menu settings when the session starts: `name=value,...` with the names `aspect`, `deinterlace`, `video_output`, `hdmi_deinterlace`, `analog_aspect`, `refresh_rate`, `anti_twitter` and each option's menu position (0 = the first) |
| `--loop N` | play the file N times (a new stream each time) |
| `--switch FILE --at N` | after N access units, switch to another file (a DISCONTINUITY, in order) |
| `--flush` | with `--switch`: switch at once with `h264ring_flush()`; either way `h264play` prints how long the core took to start the new stream |
| `--pcm FILE` | play raw PCM with the video: 48 kHz 16-bit signed little-endian stereo (`ffmpeg -i IN -f s16le -ar 48000 -ac 2 OUT.pcm`), stamped on the video's timeline -- the first access unit is time 0 (its `--pts` time) |
| `--pcm-offset MS` | the audio's first frame relative to the first access unit (default 0) |
| `--pcm-chunk MS` | the audio records' length (default 20) |
| `--pcm-lead MS` | how far ahead of the video the audio is written (default 300), as a demuxer interleaves them |
| `--audio-only` | the PCM alone, no video file: the core starts its clock from the audio |
| `--atten N` | the audio's attenuation, 0.5 dB steps (0 full volume, 255 mute) |
| `--pause A,B` | pause the core A seconds after the start, for B milliseconds |
| `--rumble P,L,S` | rumble gamepad P (0-5) for the whole playback, the large motor at L and the small at S (0-255), kept going past MiSTer's 32.767 s; repeatable; stopped at exit ([Rumble](interface.md#rumble)) |
| `--overlay [FMT]` | a progress bar over the video, drawn into the Linux framebuffer and composited by the core ([Your own screens](overlay.md)): `1555` (default), `4444` or `8888`; two pages, a 24-line band; hidden at exit |
| `--overlay-size W,H` | a W x H canvas instead of 720 x 480 (centred by the core), the whole canvas the band, its first line an opaque white rule |
| `--overlay-band A,B` | declare lines A..B as the overlay's band (it must contain the bar's, 420-443): the core reads them all -- `0,479` puts a full canvas's load on the decoder |
| `--no-cavlc` | write a CAVLC stream as it is (`h264ring_set_rewrite(r, 0)`: the core refuses it). By default the library's write call does the [CAVLC rewrite](#cavlc-streams) -- a CABAC stream is untouched --; `h264play` prepares each unit before its `--realtime` due time and prints the share of one core the rewrite took |
| `--no-launch` | do not load the core (it must already run) |
| `--rbf PATH` | the core to load, as the MGL's `<rbf>` (default `_Other/H264`) |
| `--quiet` | print only the final status |
| `--list` | print each access unit's offset and length, and exit (no core needed: a check of the library's splitter) |

## h264stat

```text
h264stat [--json] [--watch SECONDS] [--wait-live SECONDS] [--input]
```

Prints every status field (as JSON with `--json`), once or every few seconds;
`--wait-live` exits 0 as soon as the core's heartbeat is seen moving. `--input` prints
the [input region](interface.md#the-input-region) instead -- the gamepads, the mouse's sums and
buttons, whether the menu is open -- and with `--watch` every event on a line as it arrives
(`key E0 75 down`, `mouse buttons 0x01`, `OSD opened`): a quick way to see what the core
receives from MiSTer's program.

## License

The `hps/` directory -- the library, `h264play`, `h264stat` and `cavlc2cabac` -- is under the
**MIT license** (`hps/LICENSE`), so a program of any license can link the library. The rest of
the core is GPL-3.0-or-later.
