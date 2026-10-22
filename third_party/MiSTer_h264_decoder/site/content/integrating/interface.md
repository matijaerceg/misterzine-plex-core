# The interface

!!! info "Version 1.0 -- frozen"
    This page defines the interface every 1.x core implements. Nothing on it moves or
    changes its meaning in a later 1.x version; a later version only adds
    ([Versions](#versions)). The [client library](library.md) carries the layout and checks
    the version for you.

The core and your program share two areas of the MiSTer's DDR3 memory, in the half
reserved for the FPGA:

| area | physical address | size |
|---|---|---|
| the control block | `0x3140_0000` | 4 KB |
| the ring | `0x3180_0000` | 8 MB |

8 MB holds about three seconds of the highest bit rate the core accepts (H.264 Level 3.1
High), and more at ordinary rates.

## The control block

It holds 64-bit words. The core writes words 0 to 31, 40 to 47 and 80 to 87
(its **status block**) once a video frame, and 48 to 71 (the input region); your program writes words
32 to 39, 72 to 79 (the overlay), and 88 (the calibrated clip viewport). Neither side ever
writes the other's words.

| word | contents |
|---|---|
| 0 | the magic `"MiSTH264"` |
| 1 | the interface version (major x 256 + minor); where the second status region starts (40) |
| 2 | the ring's address and size |
| 3 | a sequence number that advances every frame (the **heartbeat**) |
| 4 | the state, the error code, live flags, the menu's settings, the error's position |
| 5 | the **read index** (held behind audio not yet played -- see [Indices](#indices)) and the **acknowledged nonce** |
| 6 | the header of the record that caused an error |
| 7 | the presentation clock (90 kHz) |
| 8-29 | counters: records, pictures decoded and shown, errors, refusals, skips, lateness; and (word 27) **every menu setting's value** (`osd_*` in `h264ring_layout.h`: Aspect Ratio, Deinterlace, Video Output, HDMI Deinterlace, Analog Aspect, Refresh Rate, Anti-Twitter) and `gfx_mismatch`; (word 27) `disp_lone` -- see [Time stamps](#time-stamps) |
| 30 | how the shown picture is fitted to the screen: its rectangle's width and height on the raster (720x480, or 720x576 at 50 Hz), whether it is shown 1:1 (snapped), whether its crop was invalid (ignored) or its rectangle clamped, and the lines the display could not fetch in time (0 in normal use); and the signal the core is generating: its rate (`raster_std`: 59.94 Hz, 60.00 Hz, 50 Hz with 576 lines, with value 3 reserved), whether it is interlaced, whether the legacy Refresh Rate field reads Auto (the rate itself now comes from Output Mode and Refresh Rate Match; with matching at 50/60 it follows your stream's rate while it plays), and whether anti-twitter filters the shown picture. `fit_valid` (bit 45): a picture is shown; while it is 0 (no picture yet, or after a flush) the fit's fields here and word 80's `pic_x0` / `pic_y0` read 0 |
| 31 | the sequence number again; 1.2 geometry acknowledgement sequence and result in bits 32-41 |
| 32 | **your write index** |
| 33 | **your session nonce** |
| 34 | **your pause and volume** -- see [Pausing](#pausing) |
| 35 | **your settings request** -- see [Changing the settings](#changing-the-settings) |
| 36-38 | **your rumble for the gamepads** -- see [Rumble](#rumble) |
| 39 | 1.2 calibrated picture rectangle request; write its clip viewport in word 88 first |
| 40-45 | **the audio**: its state (idle, waiting to start, playing) and mode (paced or low latency), the queue (records and frames), frames played, silence played for gaps, frames dropped late, underruns, low-latency drops and repeats, how often the audio started the clock, the A/V offset (the clock minus the last timed record's time, 90 kHz), the ring bytes the audio holds; and the pause word as applied (`paused`, `atten`, `ctl_err`). The fields are `aud_*`, `paused`, `ctl_err`, `atten` in `h264ring_layout.h` |
| 46-47 | **the overlay's status**: the descriptor read last, shown / hidden / refused and why, and the output's shape on HDMI -- see [Your own screens](overlay.md#the-status) |
| 48-71 | **the input region**: MiSTer's gamepads, keys and mouse -- see [The input region](#the-input-region) |
| 72-79 | **your overlay's descriptor**: a page of the Linux framebuffer composited over the video -- see [Your own screens](overlay.md) |
| 80 | **the raster**: the size of the core's output picture area (720 x 480, or 720 x 576 at 50 Hz; with Video Output on Native (HDMI) the video's own size, up to 2,048 x 2,048), its mode (fitted, native, or native but this picture shown fitted), whether it is shown at the HDMI display's shape with the picture letterboxed or pillarboxed inside, and where the picture's rectangle sits on it -- see [Your own screens](overlay.md#the-canvas). `video_out`: Video Output as the core resolved it -- 1 Interlaced, 2 Progressive, 3 Native (HDMI); the menu's Auto is one of them (Native on an HDMI-only MiSTer), so read this, not the menu's value in word 27, to know whether the picture is shown at its own pixels (`h264ring_video_out()`). `colour` (bits 29-31): the shown picture's colour code, 1-6 ([The colour](#records)) |
| 81 | **what the core can play** (constants): `cap_max_mbs`, the largest picture in macroblocks (3,600: 1280x720 -- a larger one's slices are dropped and counted in word 20's `rc_ref_size`); `cap_mb_rate`, the macroblocks a second the core is designed for (108,000: 1280x720 at 30, 854x480 at 60 -- real time below it also depends on the bitrate, see [Compatibility](../reference/compatibility.md)); `cap_native_h`, the tallest 16:9 picture Video Output's Native (HDMI) shows at its own size (720). Read them with `h264ring_caps()` instead of hard-coding them |
| 82-83 | **the rumble passed to MiSTer**: each gamepad's value now (`rum_p0` to `rum_p5`; 0 when no session is open) and `rum_changes`, how many times it changed -- see [Rumble](#rumble) |
| 84 | **the picture stores**: `pic_held` (bits 0-19: the stores the display holds), `pic_mode` (20: the stream is pictures of yours), `cap_pic_stores` (24-31: 20), `pic_emitted` (32-63: PICTURE records taken since the core started) -- see [Pictures you decode](pictures.md#the-store-rule) |
| 85 | `disp_fhold`: at 480i / 576i, field pairs held one field so that each starts on its first field's raster field -- one a stream start or a field-order change is normal; one every pair means the stream's timing sits a field off the raster (after a pause, or a 3-field frame): the fields still play in order, one field behind the sound |
| 86 | **the colour**: the shown picture's colour description as its stream coded it -- `vui_matrix` (bits 0-7), `vui_primaries` (8-15), `vui_transfer` (16-23), `vui_full_range` (24), `vui_colour_present` (25; 2 / 2 / 2 / 0 / 0 when the stream has none, and for your own pictures) --, `colour_override` (26: your stream's first access unit set a non-zero code), `colour_unsup` (32-47: pictures shown by the size rule because their matrix is one the core does not convert -- GBR, YCgCo, BT.2020 constant luminance, or a newer one) and `colour_mismatch` (48-63: access units whose code differed from the stream's first), both since the stream began. The code in use is word 80's `colour` |
| 87 | **display policy** (1.3): profile `[2:0]`, refresh matching enabled `[3]`, 240p request `[4]`, 25 fps film speed-up request `[5]`, 16:9 shape `[6]`, effective output profile `[10:7]`, raster rate `[12:11]`, interlaced `[13]`, de-flicker active `[14]`, 240p active `[15]`; interface 1.4 retains `[17:16]` as an additive field; this core reports 0 Off or 1 for 50/60, with upper encodings reserved. Bit 3 remains the compatible enabled flag. |
| 88 | 1.2 calibrated clip viewport (x, y, width, height, each 12 bits); write before word 39 |

A consistent copy of the status block: read word 31, then the words you need, then word
3; if the two sequence numbers differ, the core was writing -- read again. (The core writes
words 40-47 before word 31, so the rule covers them too.) The library does this for you.

**States:** NO_SESSION (no program), READY (a session, nothing decoded yet), PLAYING,
ENDED (the stream's end was shown; the last picture stays on screen), ERROR (the core
refused something you wrote: the error code says what).

## The input region

Words 48 to 71 carry what MiSTer's program sends the core: while a core runs MiSTer
holds every input device, so this is how your program sees them ([Input](launch.md#input)).
The core rewrites the region when something changes -- at most once a millisecond -- and once
a video frame regardless.

| word | contents |
|---|---|
| 48 | `in_head`: +1 each time the region is written; `ev_count`: the number of events queued since the core started (the next event's number) |
| 49-54 | gamepad 0-5: the buttons (`padN_joy`, bits 0-15 -- [the pad](launch.md#input)), the left stick (`padN_lstick`: Y in the high byte, X in the low byte, each signed -127..127), the right stick (`padN_rstick`) |
| 55 | the mouse: `dx_sum`, `dy_sum` -- the sums of every movement since the core started (signed 32-bit, wrapping; Y up-positive) |
| 56-63 | **the event queue**: 32 entries of 16 bits, four to a word; event number *n* is entry *n* mod 32 |
| 64 | `wheel_sum` (like `dx_sum`); `mouse_btn`, the mouse buttons now (bit 0 left, 1 right, 2 middle, 3-7 buttons 4-8); `osd_open`, the menu is open; `ev_lost`, events the core itself could not queue (0 in use) |
| 65-70 | reserved (0) |
| 71 | `in_tail`: `in_head` again |

**An event** is 16 bits. Bits 15-14 are its type:

| type | meaning | bits |
|---|---|---|
| 0 | a key | 9: pressed (1) or released (0); 8: the E0 prefix; 7-0: the PS/2 scan code, set 2 |
| 1 | the mouse buttons changed | 7-0: the buttons now (as `mouse_btn`) |
| 2 | MiSTer's menu | 0: opened (1) or closed (0) |
| 3 | a menu action chosen | 7-0: its number -- 0 "Send Home to the program", 1 "Program menu" ([Input](launch.md#input)) |

A consistent copy of the region: read word 71, then the words you need, then word 48; if the
two differ the core was writing -- read again (`h264ring_input` does this). Keep your own
event count: the new events are the ones from it up to `ev_count`. The region keeps its counts
across the menu's Reset; they restart only when the core is loaded.

## Rumble

Words 36 to 38 are your program's rumble for the six gamepads; MiSTer's program plays it
on the user's own pad (gamepad *n* of [the input region](#the-input-region) is MiSTer's player
*n* + 1). Two gamepads to a word, in the low 32 bits (the high 32 are ignored):

| word | bits 15-0 | bits 31-16 |
|---|---|---|
| 36 | gamepad 0 | gamepad 1 |
| 37 | gamepad 2 | gamepad 3 |
| 38 | gamepad 4 | gamepad 5 |

A gamepad's value is the large (low-frequency, strong) motor in bits 15-8 and the small
(high-frequency, weak) one in bits 7-0, each 0 (off) to 255 (full). Write a word with one 32-bit
store, so both of its gamepads change together. Every value is valid.

- **Only during a session.** The core reads the words with every poll (within a few
  milliseconds) and passes them on only while your session is open; with none, every gamepad's
  value is 0. Words 82-83 show what is passed on now.
- **32.767 seconds.** MiSTer plays a value for at most 32.767 s and starts it again only when the
  value changes. To hold one rumble longer, change the value by one step before then and back
  (the library's `h264ring_rumble_keepalive()` does it). If your program dies, the pad stops
  within that time.
- **Stop it yourself.** Write 0 when you are done: the core keeps passing the words on while
  your session is open. The library writes your values (0 unless you set some) at your first
  session and zeroes them when you close.
- **What the user needs:** a pad with force feedback that MiSTer recognises, and MiSTer's
  `RUMBLE=1` (its default, in `MiSTer.ini`). There are no trigger motors.

## Indices

The write index and the read index count bytes written into / read from the ring since
forever: they are never reset, and they wrap at 2^32. A byte at index `i` lives at ring
offset `i % 8 MB`. You may write while `write_index - read_index` stays within the ring's
size; the read index advances as the core is done with records.

The ring is also the **audio's buffer**: an AUDIO record stays in the ring until the
core fetches it to play, a few milliseconds before its time, and the read index stays at
the start of the oldest such record. While audio waits to play, the read index can
therefore lag the video you wrote; the rule above does not change.

## Records

Every record starts on a 16-byte boundary: a 16-byte header, then the payload, padded to a
multiple of 16. A record never crosses the ring's end -- write a **PAD** record to fill the
tail and continue at the start.

| type | payload |
|---|---|
| PAD | ignored: fills the ring's tail |
| VIDEO_AU | exactly **one complete H.264 access unit**, Annex-B (start codes included), 1 byte to 4 MB |
| AUDIO | PCM, 48 kHz 16-bit signed little-endian stereo, whole frames: a multiple of 4 bytes, not 0 -- see [Audio](audio.md) |
| CONTROL | reserved: refused in this version |
| PICTURE | 32 bytes: a picture you wrote into one of the core's stores -- see [Pictures you decode](pictures.md). Takes the same flags as VIDEO_AU |

**Flags** (on VIDEO_AU; AUDIO takes only PTS_VALID):

- **PTS_VALID** -- the header carries a 90 kHz presentation time for this access unit (on
  AUDIO: for its first frame). Without one, the core paces pictures by the stream's own
  timing (its VUI); audio continues from the record before.
- **DISCONTINUITY** -- a new stream that follows the current one in order (the next item
  of a playlist): the decoder and the display restart before this access unit, after
  everything queued ahead of it has played. Send it with an IDR picture and its parameter
  sets. **To seek, do not use it**: see [Seeking](#seeking).
- **END_OF_STREAM** -- the last access unit: the decoder drains, the last picture stays on
  screen. The next access unit must carry DISCONTINUITY.
- **LOW_LATENCY** -- show each picture as soon as it is decoded (game streaming). Taken from
  each stream's first access unit.
- **GRAPHICS** -- this stream is rendered graphics: a game stream, a desktop, an
  interface -- not camera or film video. It tells the core what the content IS; the user's
  settings decide what to do with it: with **Anti-Twitter** on Auto (the default) the core
  filters a GRAPHICS stream on an interlaced (15 kHz) output, where one-line detail such as
  small text and HUDs would otherwise flicker; a stream without it is left unfiltered, and the
  user's Off / On override either way. Taken from each stream's first access unit (set it on
  every one); an access unit that disagrees is counted (`gfx_mismatch`) and changes nothing.
  The live flags show the stream's value.

**The colour** -- a 3-bit code in the header (word 1, bits 33-35), on VIDEO_AU and PICTURE
only: which matrix and range the core converts the pictures with. **0, auto, is right for almost
every program**: the core reads the stream's own colour tags (the SPS's VUI), and a stream without
them is BT.601 when it is standard definition and BT.709 when it is at least 1,280 wide or more
than 576 high. Set a code (`h264ring_set_colour()`) only when you know the tags are wrong -- a media
server that labels every transcode BT.709, say, even one made from a DVD's BT.601 pixels:

| code | matrix | range |
|---|---|---|
| 0 | auto: the stream's tags, else by size | |
| 1 / 2 | BT.601 | limited / full |
| 3 / 4 | BT.709 | limited / full |
| 5 / 6 | BT.2020 (non-constant luminance) | limited / full |
| 7 | reserved: refused (error 17) | |

Like LOW_LATENCY it is taken from each stream's first access unit (send the same value on every
one); one that disagrees is counted (`colour_mismatch`, word 86) and changes nothing. A PICTURE's
code applies to that picture. The matrix only: the core does not convert primaries or transfer
(a BT.2020 picture shows undersaturated on an ordinary display). An HDR or wide-gamut stream is not
converted at all.

Each header also carries a sequence number (records since your session began, PADs
included) and a fixed sync pattern, so a record from a previous lap of the ring, or one
not yet fully written, is refused rather than decoded.

## The session

1. Check the magic and the version (the same major as yours, a minor at least yours:
   [Versions](#versions)), and that the heartbeat advances (a core loaded a moment ago, or
   left over from an earlier run, can hold valid-looking words that do not move).
2. If the write index (word 32) is not a multiple of 16, round it down to one. After a cold
   power-up DDR3 holds random bits, and the core checks the write index's alignment at every
   poll of a session (`WIDX_ALIGN`): left as it is, your session fails before your first
   record. An aligned index (an earlier program's) needs nothing.
3. Write a new **nonce** to word 33 -- and nothing else.
4. The core starts your session at the write index it read at that moment, and
   acknowledges: word 5's upper half becomes your nonce, its lower half your starting read
   index. Continue writing from there.

Writing a new nonce replaces any session the core was running. MiSTer's menu **Reset**
ends the session; the library notices and you start a new one. A core that has just
been loaded ignores whatever nonce it finds in memory.

## Seeking

The core reads records in order, and the ring can hold several seconds of video, so
anything you send *in* the stream -- including DISCONTINUITY -- takes effect only after
what is queued ahead of it has played. To seek, or to switch streams at once, **start a
new session** (the library's `h264ring_flush()`): the core drops every record it has not
read yet and resets the decoder and the display (black until the next picture), within a
few tens of milliseconds. Then write from an IDR picture with its SPS / PPS; no
DISCONTINUITY flag is needed.

## Changing the settings

Your program can change the core's menu settings from its own interface -- an aspect or
refresh-rate choice in your menus, without the user opening MiSTer's OSD. The client
library's `h264ring_request_settings(r, mask, values)` does it (`h264play --osd
aspect=2,refresh_rate=2` from the command line).

- **One request is one 32-bit store into word 35:** bits 12..0 the values, in the order and
  layout of the status block's mirror (word 27's `osd_*` fields, shifted down by 32); bits
  19..13 which options to change, one bit each in that order; bits 23..20 zero; bits 31..24
  a sequence number, 1 to 255 (0 means no request). A request with a new sequence number is
  applied once, during your session.
- **MiSTer's own menu adopts it as if the user had chosen it:** the OSD shows the new value,
  the status block's mirror reports it, and the user can change it again -- the last change
  wins. There is one copy of the settings, MiSTer's; your program never fights the menu.
- **The result:** `set_seq` (word 30) is the last request the core read, `set_err` (word 27)
  its result -- 0 applied, 1 a value past its option's last, 2 a reserved bit set, 3 no
  option selected. A refused request changes nothing.
- The signal the core generates is chosen by **Output Mode** and **Refresh Rate Match** in
  the menu; the legacy Video Output and Refresh Rate fields no longer choose it. Changing
  Output Mode in the menu switches the signal: the display resyncs.
- At the start of a new session the core applies the word's current request once, so a
  program re-asserts its settings simply by leaving its last request in place. **The other
  side of that:** a request left in word 35 is applied again at every later session start --
  over whatever the user chose in the menu meanwhile, and even for another program that does
  not use the settings. When you stop wanting your settings asserted (the user took over, you
  exit), clear the word: `h264ring_clear_settings(r)` (writes 0, "no request").
- **Your changes are not saved** with the user's settings: when the core is loaded again,
  the user's saved settings return. (If the user then changes a setting in the menu, MiSTer
  saves the menu as it stands.)

### Display requests (interface 1.3)

`h264ring_request_display(r, mask, profile, match_refresh, playback_240p,
film_speed)` uses an extended word-35 request. Bit 23 selects this format;
bits 2..0 hold the output profile (0: 480i60, 1: 480p60, 2: 576i50,
3: 576p50, 4: Native HDMI); bit 3 is the refresh-match enabled value
(0 Off, 1 50/60); bits 4 and 5 hold the 240p and film-speed settings. Mask bits
0..3 select profile, refresh matching, 240p, and film speed. Bits 22..20, 12..7, and mask bits 6..4 remain reserved. New clients leave value
bit 6 clear; legacy bit 6 is accepted only with matching enabled and selected, then maps
to 50/60. The library accepts legacy mode value 2 and emits the interface 1.3 encoding.
Sequence numbers, acknowledgement, session behavior, and clearing the request
work as above.

Word 87 reports the requested and effective display policy. The mode field at
bits 17:16, added in interface 1.4, reports 0 Off or 1 50/60; upper values
are reserved. Bit 3 remains the backward-compatible enabled flag. Raster
standard values are 0 for 59.94 Hz, 1 for 60.00 Hz, and 2 for 50 Hz; value 3
is reserved. On interface 1.3, the full mode field is absent and reads 0, while
bit 3 still reports whether 50/60 matching is enabled. `display_240p` is the
saved request, while `display_240p_active` reports the effective playback
policy gate for the reduced-line raster. This status follows the mode-transition
control and is not a measurement of the instantaneous output signal during a
transition. The raster height in word 80 remains the logical 480/576-line
coordinate space. Applications should normally leave display policy to the
core OSD and clear temporary settings requests after they have been acknowledged.

## Time stamps

A VIDEO_AU's presentation time is believed, with one exception: a **lone** time stamp --
more than half a refresh (about 8 ms) and at most 0.5 s away from where the pictures before it
say it should be, ahead or behind, when the one before it was believed -- is taken as a mistake
and the picture is shown on the running timeline. The next time stamp is always believed, so a
real jump under 0.5 s is followed one time stamp late, and a larger one at once. `disp_lone`
(word 27) counts the time stamps disbelieved. Containers occasionally carry such a stamp (a
remuxed transport stream, a rounding in a player); a program that sends none (a game stream)
never meets the rule.

## Pausing

**Word 34** is your pause and volume, one 32-bit store (the library's
`h264ring_set_pause()` and `h264ring_set_atten()`):

| bits | field |
|---|---|
| 0 | **PAUSE**: 1 pauses, 0 plays |
| 7..1 | zero |
| 15..8 | **ATTEN**: the audio's attenuation in 0.5 dB steps -- 0 full volume, 255 mute |
| 31..16 | zero |

The core reads it with every poll, so it acts within a few milliseconds: it is deliberately
**not** a record, which would wait behind the seconds of video queued in the ring. While
paused, the presentation clock stands still, the picture holds, the audio is silent and the
core stops reading the ring; resuming continues the same timeline, nothing lost. A word
with a reserved bit set is refused whole -- the previous pause and volume stay -- and
`ctl_err` (word 45) says so until a valid word is read. The word applies during a session;
the library writes it again at each session start, so a program that stopped while paused
does not leave the next one paused.

## Errors

Every field you write is checked. The first failure stops the session in ERROR with its
code, its position and the offending header; a new session clears it.

| code | meaning |
|---|---|
| 1 | the write index is not a multiple of 16 |
| 2 | the write index moved backwards, or more than a ring ahead of the read index |
| 3 | a header's sync pattern or reserved bits are wrong (bits 36-47 of word 1; 33-35 are the colour) |
| 4 | an unknown record type (or an unwritten header) |
| 5 | a flag that is not defined, or not allowed on that type |
| 6 | a payload length out of range (an empty access unit; an AUDIO record of 0 bytes or not a multiple of 4; a PICTURE not of 32 bytes; anything over 4 MB) |
| 7 | a record crossing the ring's end, or a PAD that does not end there |
| 8 | a record out of sequence |
| 9 | an access unit (or a PICTURE) after END_OF_STREAM without DISCONTINUITY |
| 10 | a CONTROL record (reserved) |
| 11 | a PICTURE in a stream of access units, or an access unit in a stream of pictures |
| 12 | a PICTURE's field out of range: a reserved bit, structure 3, a `pic_struct` not allowed, an `aspect_ratio_idc` of 17-254 (or 255 with a zero SAR), timing with a zero field |
| 13 | a PICTURE's store past 19 |
| 14 | a PICTURE's size: a side of 0 or past 128 macroblocks, an odd height for a field pair, or more than 3,600 macroblocks |
| 15 | a PICTURE's crop that leaves nothing |
| 16 | a PICTURE naming a store the display still holds (the store rule broken) |
| 17 | a record's colour code is 7, or not 0 on a PAD or an AUDIO record |

## Writing safely from Linux

Map `/dev/mem` with `O_SYNC` (uncached). Store the record's words, issue a memory barrier,
then store the write index as one aligned 32-bit store. **Do not `memcpy` into the
mapping**: an unaligned store to uncached memory faults on the MiSTer's ARM. The library
does all of this.

## Versions

Word 1's low 16 bits hold the interface version, major x 256 + minor: `0x0100` is 1.0. This
manual describes 1.4 (`0x0104`).

**Within 1.x the interface only grows.** A later minor version (1.1 through 1.4, and later
additive versions) never moves a
word or a field, never changes what a value means, and never makes a field your program writes
mean something new when it is 0. It may add:

- a field in bits that read 0, or a status word that read 0 (1.4 adds word 87 bits 17:16);
- a program word or a field in one that had to be written 0 (0 keeps asking for what 1.0
  does);
- a record type, a flag, an input event type, an error code or a menu setting that 1.0 refused
  or did not have;
- a guarantee about what the core does in a case 1.0 left unsafe, such as 1.1's (below).

A change that cannot be made that way is a new major version (2.0), never a silent one.

**What your program does:**

- **Accept a core of the same major whose minor is at least the one you built against**, and
  refuse any other. The client library does this when it attaches (`-EPROTONOSUPPORT`
  otherwise); a program that reads the words itself can call `h264ring_version_ok(core,
  H264RING_VERSION)` from `h264ring.h`. A program built for 1.0 runs on a 1.3 core; a program
  built for 1.3 refuses a 1.0 core, which lacks what 1.3 added.
- **Write 0 to every reserved bit and word**, and to every field you do not use. The core
  refuses a record with a reserved bit set, and a later version may give the bit a meaning.
- **Ignore what you do not know** in the status block: a bit or a word reserved in your version
  may be set by a newer core. Show an error code you do not know by its number.

## Version history

- **1.0** -- the first published version, frozen under the rules above.
- **1.1** -- the layout unchanged. Audio your program wrote ahead of its video can no longer stop
  the picture: a late picture is shown late instead of moving the clock back, unless the audio
  has run dry or come late since it last waited ahead ([Audio](audio.md#how-the-core-plays-it)).
  A program built for 1.1 refuses a 1.0 core.
- **1.2** -- words 39 and 88 add calibrated playback geometry. Word 39 contains the signed
  picture position, its width and height, and a nonzero sequence number. Word 88 contains the
  visible clip viewport. The core acknowledges the sequence in word 31 only after it has read
  and validated both words. `h264ring_set_geometry()` waits for this acknowledgement; it returns
  `-ENOTSUP` on a 1.1 core. Native video output ignores calibration. A zero rectangle clears it.
- **1.3** -- word 87 adds the display policy status, and word 35 gains the display request
  format used by `h264ring_request_display()`. Match mode 0/1 is Off/50-60; its request value
  uses the legacy bit 3. Programs built for 1.3 continue to run on 1.4 cores.
- **1.4** -- word 87 bits 17:16 add the refresh-match mode field. This core reports 0 Off or
  1 for 50/60; upper values remain reserved. Raster standard 3 remains reserved. New clients
  leave word-35 value bit 6 clear; the core accepts the old bit-6 marker only with the selected
  and enabled match field and normalizes it to 50/60 (bit 6 alone is rejected). Saved OSD value 2 becomes Off.
