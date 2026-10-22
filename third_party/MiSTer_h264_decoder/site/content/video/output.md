# Video output

The core generates one signal for HDMI and the analog outputs alike, chosen by two
settings ([Settings](../using/settings.md)):

| Refresh Rate | Video Output: Interlaced | Video Output: Progressive | Video Output: Native (HDMI) |
|---|---|---|---|
| 59.94 Hz | 720x480i (15 kHz) | 720x480p (31 kHz) | the video's own size, at 59.94 Hz |
| 60 Hz | 720x480i at exactly 60.000 Hz | 720x480p at exactly 60.000 Hz | the video's own size, at exactly 60.000 Hz |
| 50 Hz | 720x576i (PAL, 15 kHz) | 720x576p (PAL, 31 kHz) | the video's own size, at 50 Hz |

**Video Output** on Auto follows `MiSTer.ini`: Interlaced when it sets up an analog TV
(`composite_sync`, `ypbpr` or `vga_sog` with `vga_scaler=0`, or `direct_video`), Progressive
when it sets up a 31 kHz VGA monitor on the core's own signal (`forced_scandoubler` with
`vga_scaler=0`), and otherwise **Native (HDMI)** -- on a MiSTer used with HDMI only, that is
what you get. Auto decides while no video plays, so the signal never switches under a stream.

**Refresh Rate** on Auto follows the video: a stream at exactly 60, 30, 24 or 120 frames a
second gets 60 Hz (a Moonlight game stream is exactly 60), one at 50, 25 or 100 gets 50 Hz,
anything else 59.94 Hz. The choice is made when a stream starts and kept until the next
one, so a display may resync once at the start of a stream, never during it.

**On Interlaced and Progressive, every picture is fitted to the screen** at its true shape --
its cropping and its pixel shape as the stream declares them -- centred, with black bars where
the shapes differ: 640x480, 854x480, a transcode's 720x404, a phone's portrait 480x854 alike,
on 480 or 576 lines. On HDMI with the Progressive output and Analog Aspect on Auto, the picture instead
fills the core's screen and the HDMI scaler is told its exact shape; a picture wider than your
HDMI display (a 2.39:1 film on a 16:9 TV) is letterboxed inside the core's screen, so the bars
are part of it and a player can show subtitles there.

**Video Output: Native (HDMI)** goes further for HDMI: the core's signal is the video's own size
-- 852x480, 640x480 (shown 853x480 with its side bars), 720x576, **1280x720** ... -- at the same
refresh rate, and the HDMI scaler makes the only resize to your display, the sharpest HDMI
picture. Every picture the core plays is shown this way, 720p included (any size up to 2,048
pixels on a side). Video stores its colour at half the resolution of its brightness; on every output -- Native, Progressive
and Interlaced, scaled or not -- the core rebuilds it by blending smoothly between the colour samples, at
the position the video says they sit (its chroma siting), so fine detail in strong colours (red text, a
logo's edge, a coloured subtitle outline) stays clean instead of turning into blocky steps. Each new picture size is a brief blip on HDMI (and MiSTer's resolution box, if
`video_info` is set). Native is for HDMI only: the analog output carries the same unusual timing
unless `vga_scaler=1`.

On HDMI the MiSTer's scaler converts the core's signal to your HDMI mode. A 50 Hz signal on
a 60 Hz HDMI mode shows a small judder; to avoid it, let the HDMI output follow the core
(`vsync_adjust=1` or `2` in `MiSTer.ini`). With Interlaced output the HDMI scaler
deinterlaces (**HDMI Deinterlace**).

Between two streams the screen is black and keeps the last stream's shape.
