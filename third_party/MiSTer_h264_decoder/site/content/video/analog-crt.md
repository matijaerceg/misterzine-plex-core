# Analog and CRT output

The analog outputs carry the core's own signal (see [Video output](output.md)), with the
framework's usual `MiSTer.ini` video options (`vga_scaler`, `composite_sync`, `ypbpr`,
`vga_sog`, `direct_video`).

**Set up `MiSTer.ini` for your analog display first.** Video Output's **Auto** reads it: with
an analog TV set up it picks Interlaced, with a 31 kHz VGA monitor on the core's own signal
Progressive, and with neither it picks **Native (HDMI)**, whose unusual timing an analog display
cannot show. Or choose Interlaced or Progressive yourself ([Settings](../using/settings.md)).

## A standard-definition CRT (15 kHz)

Set **Video Output** to Interlaced -- or leave it on Auto with `MiSTer.ini` set up for an
analog TV (`composite_sync`, `ypbpr` or `vga_sog` with `vga_scaler=0`, or `direct_video`). The
core then generates 480i (576i at 50 Hz) with standard composite sync: equalizing and
serration pulses, so a TV interlaces the two fields correctly.

- **Analog Aspect** fits pictures that are not 4:3 inside the 4:3 screen: Letterbox (black
  bars, the whole picture; what Auto does here), Crop (fills the screen, cuts the sides) or
  Fit (for a TV in its 16:9 wide mode: every picture at its true shape once the TV stretches it).
- **Anti-Twitter**: a detail one line tall -- small text, a game's HUD, a thin horizontal
  edge -- flickers on an interlaced screen. Anti-Twitter softens the picture vertically just
  enough that it stops. On **Auto** (the default) it filters game streams, desktops and the
  programs' own screens (menus, subtitles) and leaves films unfiltered; **On** filters
  everything, **Off** nothing.
- **Refresh Rate**: 59.94 Hz and 60 Hz are NTSC-rate signals (480 lines); 50 Hz is the PAL
  rate with 576 lines -- your TV must accept 50 Hz. On Auto the rate follows the video.
- A 60p stream at 480i shows each field from its own picture (the broadcast conversion:
  full motion); 24p and 30p pictures span two or more fields and keep their full
  vertical detail.

## A 31 kHz display

For a VGA monitor or an external scaler, use Video Output **Progressive** (480p, or 576p at
50 Hz), and set Analog Aspect to Letterbox or Crop: on Auto the Progressive output fills the
screen for HDMI's benefit and the analog picture would be stretched.

## Banding on an 18-bit I/O board

The classic DE10-Nano analog I/O board has a 6-bit-a-colour video DAC: smooth gradients -- a
sky, a fade, a dark scene -- show some banding, and there is no option for it. (An analog
dither was tried and removed: on component video it made the picture worse.) A board with a
full 8-bit DAC (a SuperStation, a 24-bit analog board) does not band. HDMI is never affected.
