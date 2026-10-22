# Your own screens: the overlay

!!! info "Version 1.0 -- frozen"
    This page is part of the interface's definition, fixed for every 1.x core
    ([Versions](interface.md#versions)). Use the [client library](library.md): it carries the
    layout.

Your program draws its own screens -- a browser, a host list, a pause menu, subtitles, a
"connecting..." message, a progress bar -- into a page of the **Linux framebuffer**
(`/dev/fb0`), as any Linux program would. The core reads that page and **composites it over
the video on its own output**: HDMI and the analog outputs alike, at 480i, 576i and every
rate the core generates. With no stream playing, the screen shows your overlay over black
(or over the idle pattern before anything has played), so a browse screen needs no video.
MiSTer's own menu stays on top of both.

Do not switch MiSTer's display to the framebuffer (its "Linux console" switch): that
shows the framebuffer *instead of* the core, on HDMI only, and stops MiSTer passing input to
the core. The core reads the page itself; your program only tells it where the page is.

## The canvas

**One canvas pixel is one pixel of the core's output**, and the canvas is centred on it.
The output's size is word 80's `raster_w` x `raster_h` (`h264ring_raster()`): **720 x 480**
(576 at 50 Hz) on the Interlaced and Progressive outputs, and on **Native (HDMI)** -- what Video
Output's Auto picks on a MiSTer used with HDMI only -- the size of the video being shown: 852 x
480, 853 x 480, 720 x 576, 1280 x 720 ..., up to 2,048 x 2,048. A canvas of the
output's size fills it; a smaller one is centred; a wider or taller one is centred and loses its
edge columns or lines (`ovl_clip`). Nothing is scaled, so text stays as sharp as you drew it.
**Redraw when word 80's size changes** (a new item of another size in Native), as you already do
when word 47's shape changes. A canvas may be up to 2,048 x 2,048.
**Size it to the output** on Native (HDMI): the core composes every column of a canvas line, the
clipped ones too, and a native line is short -- a canvas much wider than the output (a 2,048-wide
one on 1280 x 720) can fall behind the picture and lose lines (shown transparent, counted in
`ovl_late`).

**How much framebuffer there is.** `/dev/fb0` is not the whole 8 MB the core can read: MiSTer
sizes it to its **HDMI mode** (the `video_mode` in `MiSTer.ini`), width x height x 4 bytes --
1,382,400 at 720x480, 3,686,400 at 1280x720, 8,294,400 at 1920x1080 (`fb.len` from
`h264ring_fb_map`). Lay your pages out inside `fb.len`, not inside the region, and lay them out
again when word 80's size changes. Rows the output's width apart (a multiple of 8 bytes) keep
two pages small: two `4444` pages of a 1280 x 720 output need 3,686,400 bytes and fit a 1280x720
mode exactly, two `8888` pages need a 1920x1080 mode. A row as wide as the largest canvas
(2,048 pixels) leaves a 1280x720 mode room for only 450 lines a page. When the output is taller
than two pages fit, draw a shorter canvas: the core centres it.

**Draw for the output's shape.** On an analog display the 720 x 480 output fills a 4:3
screen, so its pixels are slightly narrow (8:9) -- except with Analog Aspect set to Fit, which is
for a TV in its 16:9 wide mode: the output is then shown at 16:9 (word 47 reads 16 : 9 on HDMI too --
on a 720x480 / 720x576 HDMI mode the mode's own size, 720 : 480 or 720 : 576, since the TV stretches
that mode to 16:9 itself), so its pixels are wide (32:27). The pixel's shape on HDMI is `ar_x / ar_y`
x `raster_h / raster_w` (the library's `rs.aspect * rs.h / rs.w`): on a native output it is
usually square. On HDMI the shape is what the core tells
the scaler: word 47's `ar_x : ar_y` is the width to height of the whole output (word
80's `raster_w` x `raster_h`). With the Progressive output and Aspect Ratio and Analog Aspect
on Auto that follows the **stream** -- a 16:9 stream makes the output 16:9 -- so a screen drawn
for 4:3 looks stretched over it unless you redraw for `ar_x : ar_y`.

**A picture wider than the HDMI display**: in that same mode, a 2.39:1 film on a
16:9 display is **letterboxed inside the output** -- black bars above and below it, part of
the output -- and HDMI is given the display's own shape, so your overlay covers the whole
screen and the bars are yours to draw subtitles or a progress bar in (word 80's `raster_lb`
is 1; `pic_x0`, `pic_y0` with word 30's `fit_ow` x `fit_oh` say where the picture is).

`h264ring_raster()` (the [library](library.md)) decodes all of it: the output's size, the
shape it is shown at (4:3 on the interlaced output), and the picture's rectangle on it.

## The pixels

Three formats, each **straight (not premultiplied) alpha**, little-endian in memory:

| format | bytes a pixel | layout (most significant bit first) | alpha |
|---|---|---|---|
| `1555` | 2 | A (1 bit), R G B (5 bits each) | A = 1 opaque, 0 transparent |
| `4444` | 2 | A R G B (4 bits each) | 0 transparent .. 15 opaque |
| `8888` | 4 | A R G B (8 bits each): bytes B, G, R, A | 0 transparent .. 255 opaque |

**A zeroed page is transparent** in every format. `4444` and `8888` give antialiased text and
translucent panels; `1555` is opaque or transparent. `8888` must carry its alpha byte:
drawing code that leaves the fourth byte 0 draws nothing visible.

On an interlaced output (480i, 576i) the core softens the overlay vertically so that thin
lines and small text do not flicker, unless the user sets the core's **Anti-Twitter** to
Off (your screens count as graphics: Auto filters them).

**The cost.** The core reads your page while it decodes, from the same memory, and every
line read costs the decoder a little time. Declare the lines you actually drew on (the
**band**): the core reads those alone. Even a full 720 x 480 page leaves the core's densest
real-time case (854x480 at 60 frames a second) with room to spare: measured, a full `8888`
page costs it about 1 % of the decoder's time, a full `1555` or `4444` page a quarter of
that. A full 1280 x 720 page over a 720p stream at 8 Mbit/s (Native (HDMI)) costs about 1 %
in `4444` and 3 % in `8888`; that stream still plays in real time with either.

## Showing it

The overlay is described by eight words your program writes, **words 72 to 79** of the
control block (one 32-bit value in the low half of each word):

| word | contents |
|---|---|
| 72 | the generation, written **last** |
| 73 | bit 0: show; bits 2-1: the format -- 0 `1555`, 1 `4444`, 2 `8888`; the other bits 0 |
| 74 | the page's physical address (a multiple of 8) |
| 75 | bits 15-0 the width (1-2,048), bits 31-16 the height (1-2,048) |
| 76 | the stride: bytes from one line to the next (a multiple of 8, at least width x bytes a pixel) |
| 77 | the band: bits 15-0 its first line, bits 31-16 its last (first <= last < height) |
| 78 | reserved, 0 |
| 79 | the generation, written **first** |

Write word 79, then the others, then word 72, with a memory barrier between; use a new
generation each time. The core reads the eight words once a screen refresh (a field when
interlaced) and uses them from the next refresh, never in the middle of one: when words 72
and 79 differ it has caught you mid-write, ignores them (counted, `ovl_torn`) and reads them
again at the next refresh. **A page flip is a new address**: draw into a page not shown,
write its address, and wait until `ovl_gen` shows the new generation -- from then on the
core never reads the old page, and you may draw into it again.

The overlay shows **only during a session**, so a descriptor a previous program left behind
never shows after the core is reloaded; the library writes yours (or none) at every session
start.

The core checks every descriptor. One it cannot use is refused -- the overlay is hidden,
`ovl_state` is 2 and `ovl_err` says why -- until you write a good one:

| `ovl_err` | name | the problem |
|---|---|---|
| 1 | CTL | a reserved bit, word 78 not 0, or format 3 |
| 2 | SIZE | the width or height out of range |
| 3 | STRIDE | not a multiple of 8, too small for the width, or above 65,535 |
| 4 | ALIGN | the address not a multiple of 8 |
| 5 | BAND | the band's first line after its last, or its last line past the height |
| 6 | RANGE | the page not wholly inside the framebuffer: `0x2200_0000` to `0x2280_0000` |

## The status

| word | contents |
|---|---|
| 46 | `ovl_gen` (the generation of the last descriptor the core read), `ovl_state` (0 hidden, 1 shown -- during a session -- 2 refused), `ovl_at` (softened for an interlaced output), `ovl_clip`, `ovl_err`, `ovl_torn`, `ovl_late` (lines the core could not read in time: shown transparent; 0 in normal use) |
| 47 | `ar_x`, `ar_y` (the output's shape on HDMI) and `ovl_lines` (canvas lines read: a count that moves while the overlay shows) |
| 80 | `raster_w` x `raster_h` (the output your canvas is centred on), `raster_mode`, `raster_lb` (the picture letterboxed inside it on HDMI), `pic_x0`, `pic_y0` (the picture's rectangle's top-left; negative under Crop) |

## With the library

```c
struct h264ring_fb fb;
struct h264ring_overlay o = { 0 };
int gen;

h264ring_fb_map(&fb);                       /* /dev/fb0, mapped whole: fb.virt, fb.phys, fb.len */
o.base = fb.phys;                           /* page 0 at the start; page 1 at fb.phys + a page */
o.width = 720; o.height = 480;
o.stride = 720 * 2;
o.format = H264RING_OVL_FMT_4444;
o.band_first = 400; o.band_last = 459;      /* the lines drawn on */
/* draw into fb.virt ... */
gen = h264ring_overlay_show(r, &o);         /* checked here first: -EINVAL for what the core would refuse */
h264ring_overlay_wait(r, gen, 100);         /* read by the core; -EPROTO if it refused it */
...
h264ring_overlay_hide(r);
h264ring_fb_unmap(&fb);
```

`h264play --overlay [1555|4444|8888]` draws a progress bar this way (two pages, a 24-line
band): the example to start from.

**The console's cursor.** Linux's text console is drawn into the same framebuffer: its login
prompt's blinking cursor rewrites a small block of it several times a second, which would
show as a flickering speck in your page. `h264ring_fb_map` stops the blink and hides the
cursor (`echo 0 > /sys/class/graphics/fbcon/cursor_blink`, and `ESC [?25l` written to
`/dev/tty1`); `h264ring_fb_unmap` puts them back. If you map `/dev/fb0` yourself, do the same.

The framebuffer's own mode (what `/dev/fb0` reports to other drawing code) is not what the
core reads -- the descriptor is. Its `8888` mode is laid out exactly as the overlay's `8888`
(bytes B, G, R, then the byte the driver leaves unused -- your alpha). If your toolkit draws through the framebuffer device's
reported layout, set that mode to match what you describe (MiSTer sets it again whenever a
core loads, so set it after launching the core).
