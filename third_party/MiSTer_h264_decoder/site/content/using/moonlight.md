# Streaming from a PC (Moonlight)

The core comes with a Moonlight client: your PC's desktop or its games, streamed to the MiSTer
and shown by the core on HDMI and the analog output, a CRT included, with the PC's sound. The PC
runs [Sunshine](https://github.com/LizardByte/Sunshine), the open-source game-stream host.

Your keyboard, mouse and gamepads on the MiSTer control the PC ([Controls](controls.md)).

!!! warning "Early"
    The client is new. It has no on-screen interface of its own: you set it up in a settings
    file and start it from MiSTer's **Scripts** menu, and its messages go to a log file. H.264
    streams only, stereo sound.

## Installing

MisterZine Jellyfin releases do not include the client: build it and copy its
`Scripts/moonlight.sh` and `moonlight/` folder to the root of the SD card (`/media/fat/`), with
the core in `_Other/` ([The other programs](../getting-started/install.md#the-other-programs)).

On the PC, install Sunshine and open its web page (`https://localhost:47990` on the PC).

## First run: the settings

Run **Scripts** → **moonlight** from the MiSTer menu. The first time, it creates
`/media/fat/moonlight/moonlight.ini` and stops. Edit that file (from the PC over the network, or
on the SD card) and set `host=` to the PC's IP address:

```ini
host=sunshine-host.local
app=Desktop
width=
height=
fps=60
bitrate=10000
quitappafter=0
```

| Setting | Meaning |
|---|---|
| `host` | the PC running Sunshine: its IP address, or a name your network resolves |
| `app` | the app to stream, as Sunshine lists it: `Desktop`, `Steam Big Picture`, ... |
| `width`, `height` | the picture the PC sends. **Empty (the default): the shape of your screen** -- 640x480 on a 4:3 screen (an analog TV, or Aspect Ratio 4:3), 848x480 otherwise (16:9). Set both to choose (640x480, 848x480, 1280x720, ...); the core decodes up to 854x480 at 60 or 1280x720 at 30 frames per second (set `fps` to 30 for 1280x720: the client refuses 1280x720 at 60). 1280x720 adds detail mainly with Video Output **Native (HDMI)** -- what Auto picks when MiSTer has no analog display set up -- and MiSTer's HDMI mode at 720p or above (the picture shown at its own 1280x720); on the core's 480-line screens it adds a little (the core averages it down) at half the frame rate |
| `fps` | frames per second (60) |
| `bitrate` | the bitrate to ask for, in kbit/s (10000) |
| `quitappafter` | `1`: quit the app on the PC when the stream ends |

The PC fits its desktop into the picture it is asked for. When your PC's desktop and your
screen have different shapes (a 16:9 desktop on a 4:3 TV), the picture has black bars; when
they match, it fills the screen.

## Picture quality

Three things decide how sharp the stream looks; the first is on the PC.

- **The size the PC sends, against its desktop.** The PC shrinks its whole desktop to the size you
  ask for, and Sunshine's scaler is simple: it does not average every pixel it leaves out, so a
  desktop much larger than the stream -- 2560x1440 sent as 848x480 is 3:1 -- shows jagged text and
  broken thin lines. Ask for a size the desktop divides evenly (1280x720 from a 2560x1440 desktop:
  exactly 2:1), or lower the PC's desktop resolution while it streams (Sunshine can run a command
  before and after a stream to change it).
- **MiSTer's HDMI scaler.** On HDMI the picture is enlarged to your display's mode, and without a
  scale filter that enlargement repeats pixels unevenly (2.25x for 480 lines on a 1080p display).
  Choose a filter (bicubic, Lanczos, or one of the Upscaling sets) in MiSTer's video processing
  menu.
- **The core's own resize**, needed only when the picture does not fit the output (on the
  Interlaced and Progressive outputs, or a 1280x720 stream on them): it averages the pixels each
  output pixel covers, so lines and text stay even. There is no setting.

On a CRT, ask for 640x480 or 848x480 at 60 frames per second: the screen cannot show more lines,
and 60 keeps motion smooth at 480i.

## Pairing

Run **moonlight** again. The MiSTer and the PC are not paired yet, so the script shows a
four-digit PIN. On the PC, open Sunshine's web page, go to **PIN**, and type it in. This is
needed once.

## Streaming

Run **moonlight** again: the core loads and the stream starts. Everything the PC sends is
fitted to the output like any other video ([Video output](../video/output.md)); the stream
declares itself as rendered graphics, so **Anti-Twitter: Auto** filters it at 480i
([Settings](settings.md)).

## Controlling the PC

The keyboard, the mouse and up to six gamepads reach the PC as they would a PC's own: the
gamepads appear there as Xbox controllers. If a gamepad's **LS, RS, LT or RT** does nothing, map
them once in MiSTer's menu ([Controls](controls.md#gamepads)); the triggers are on or off, never
halfway.

**Rumble:** when a game rumbles its controller, your gamepad rumbles too -- if it has motors and
MiSTer can drive them (most USB and Bluetooth gamepads), and `RUMBLE=1` in `MiSTer.ini` (the
default). A gamepad rumbles once you have pressed one of its buttons since connecting it (that is
when MiSTer gives it a player number). Rumble in the triggers (some Xbox controllers) is not
passed on.

Opening the MiSTer menu (F12, or your pad's menu button) pauses the controls: everything held
down on the PC is released, and nothing reaches it until the menu closes. F12 itself never
reaches the PC.

**The Guide button** (the Xbox button: Steam's overlay, the Xbox Game Bar): your pad's own
Home / Guide button opens the MiSTer menu instead, so there are two other ways to press it on the
PC:

- **Hold Back + Start for a second.** The game sees Back and Start pressed during that second;
  then they are released, the Guide button is pressed on that gamepad for a moment, and Back and
  Start stay released until you let go of them. (Adding LB and RB is the quit combination
  below, which never sends the Guide.)
- **Choose Send Home to the program** in the MiSTer menu ([Settings](settings.md)). The menu
  closes and the Guide button is pressed on the first gamepad.

**To stop:** press **Ctrl+Alt+Shift+Q** on the keyboard (the stream ends once you let go of
the keys), or **Start+Back+LB+RB** together on a gamepad. The MiSTer returns to its menu.
Loading another core, or the menu, from the MiSTer menu also ends the stream: the client
notices within a couple of seconds.

## If it does not work

The client writes what it did to `/media/fat/moonlight/moonlight.log`. See
[Troubleshooting](../reference/troubleshooting.md#moonlight).
