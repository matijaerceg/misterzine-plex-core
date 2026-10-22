# Launch and input

## Loading the core

Your program loads the core the way MiSTer's own tools do: it writes a small MGL file and
sends `load_core` for it through MiSTer's command interface. `h264ring_launch_core` does
exactly this, and only when `/tmp/CORENAME` does not already say `H264` (MiSTer writes the
core's own name there, the first entry of its CONF_STR, whatever the rbf file is called; an
app's build of the core with its own name passes that name to `h264ring_launch_core_as`):

```xml
<mistergamedescription>
  <rbf>_Other/H264</rbf>
</mistergamedescription>
```

```bash
echo "load_core /tmp/h264ring.mgl" > /dev/MiSTer_cmd    # one command per write
```

Then wait for the core's status block to be alive (the heartbeat moving) before starting a
session: `h264ring_start_session` checks it.

**Stop writing before you load another core.** Loading a core resets the old one; the
memory's contents are left as they were, but mean nothing to the next core. After any
core load, start a new session.

## The controls belong to MiSTer's menu

MiSTer's own program keeps running beside yours. It owns the on-screen menu, the core's
settings (Aspect Ratio, Deinterlace, ...) and **the input devices**: while a core runs, it
holds every keyboard, mouse and gamepad exclusively, so your program can open
`/dev/input/event*` but receives no events from them.

So **the core passes on what MiSTer's program sends it**: see [Input](#input) below.

- The menu's current settings are in the status block (every option, word 27's `osd_*`), and
  so is whether the menu is open (`OSD_OPEN` in the live flags).
- Your program can **change** the settings from its own interface
  (`h264ring_request_settings`: [Changing the settings](interface.md#changing-the-settings));
  MiSTer's menu shows the change and the user can still change it back. For content-dependent
  behaviour you can instead declare what your stream is -- the GRAPHICS flag -- and the
  settings' **Auto** values follow it.
- The menu's **Reset** restarts the core's decoding and ends your session:
  `h264ring_write_au` returns `-ENOTCONN`; start a new session and resend from an IDR
  picture.
- When the user **loads another core** (or the menu), your core is gone but its memory keeps
  the last words it wrote: the session still looks open and the ring simply stops draining.
  Watch the heartbeat (`h264ring_alive`, or `seq_head` in the status): still for more than a
  second means the core is no longer running.

## Input

The core copies what MiSTer's program sends it into control words 48 to 71, the **input
region** ([The interface](interface.md#the-input-region)): six gamepads in the user's own
MiSTer button mapping, every key, the mouse. Your program reads it; it needs no session.

```c
struct h264ring_input in;
uint16_t ev[H264RING_IN_Q_LEN];
uint32_t count, lost = 0;
unsigned n;

h264ring_input(r, &in);                              /* a consistent copy */
count = (uint32_t)H264RING_IN(&in, EV_COUNT);        /* start from now: earlier events are not yours */
for (;;) {                                           /* every millisecond or so */
    usleep(1000);
    if (h264ring_input(r, &in))
        continue;
    while ((n = h264ring_input_events(&in, &count, ev, H264RING_IN_Q_LEN, &lost)) != 0)
        for (unsigned i = 0; i < n; i++)
            handle(ev[i]);          /* a key, a mouse-button change, the menu opening or closing, a menu action */
    /* the pads: H264RING_IN(&in, PAD0_JOY) ... PAD5_JOY, _LSTICK, _RSTICK -- their state now */
    /* the mouse: H264RING_IN(&in, DX_SUM), DY_SUM, WHEEL_SUM -- movement since the last read
     * is the difference (as uint32_t, then signed) */
}
```

- **Events come in the order they happened:** keys (PS/2 scan code set 2, with the E0 prefix as
  a flag), mouse-button changes, and MiSTer's menu opening and closing, in one queue of 32.
  Read at least every few milliseconds: if more than 32 arrive between two reads the oldest are
  lost, and `h264ring_input_events` adds how many to `lost`. Treat every key and button as
  released then.
- **The menu:** MiSTer's program sends the core nothing while its menu is open, and it does not
  release what was held when the menu opened. When your program reads the "menu opened" event
  it should release everything it forwarded (a game-streaming client releases every key on the
  PC), and ignore key releases for keys it does not think are held (a key held across the menu
  arrives as a release with no press; so do NumLock and ScrollLock, whose presses MiSTer keeps).
- **The menu's actions**: the core's menu has two entries for your program --
  **Send Home to the program** (action 0: a game-streaming client presses the host's Guide /
  Home button; your pad's own Home button opens MiSTer's menu, so nothing else can) and
  **Program menu** (action 1: show your program's own menu, if it has one). Choosing one queues
  an action event (`H264RING_EV_ACTION`, its number in `H264RING_EV_CODE`) and MiSTer then
  closes its menu: the action arrives **before** the "menu closed" event. Take it even while
  you are ignoring input for the open menu, and act on it after the close. Ignore an action
  you have no use for. The programs in `clients/`: while something plays, the video player and the Jellyfin
  cast client stop it on Send Home and show their title-and-progress panel on Program menu; the camera viewer quits
  and opens its list of modes; the Moonlight client presses the PC's Guide button and ignores
  Program menu.
- **What MiSTer keeps:** F12 (its menu), the Menu key, its screenshot, volume and
  keyboard-mode keys never reach the core. There is no key repeat: the receiving side repeats.
- **The gamepads** are the core's Xbox-style pad ([Controls](../using/controls.md#gamepads)):
  bits 0-3 the d-pad (right, left, down, up), then A, B, X, Y, LB, RB, Back, Start, LS, RS, LT,
  RT (`H264RING_PAD_*`); the sticks signed -127..127, X right-positive, Y down-positive (as Linux
  reports it). A snapshot, rewritten at most every
  millisecond: a tap shorter than that can be missed.
- **The mouse** is relative only, in PS/2's counts (Y up-positive); MiSTer limits a movement to
  255 counts per ~15 ms packet.
- **Rumble** goes the other way: your program writes each gamepad's motors and MiSTer
  plays them on the user's pad ([Rumble](interface.md#rumble), `h264ring_rumble()`).
- `h264stat --input --watch 0.05` prints the region and every event as it arrives.

## Your own interface

A program that needs its own screens (a media browser, a settings page, subtitles) draws them
into the Linux framebuffer (`/dev/fb0`) with ordinary fbdev or SDL code, and the core
composites them over the video on its own output -- HDMI and the analog outputs alike, CRTs
included. The canvas, the pixel formats, transparency and page flipping:
[Your own screens: the overlay](overlay.md).
