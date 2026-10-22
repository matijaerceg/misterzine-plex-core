# Video output

The core generates one signal for HDMI and the analog outputs alike, chosen by **Output
Mode** and **Refresh Rate Match** ([Settings](../using/settings.md)):

| Output Mode | Signal | With Refresh Rate Match at 50/60, while a video plays |
|---|---|---|
| 480i60 (the default) | 720x480i at 59.94 Hz (15 kHz) | 720x576i at 50 Hz for a 50 Hz-family video |
| 480p60 | 720x480p at 59.94 Hz (31 kHz) | 720x576p at 50 Hz for a 50 Hz-family video |
| 576i50 | 720x576i at 50 Hz (PAL, 15 kHz) | 720x480i at 59.94 Hz for any other video |
| 576p50 | 720x576p at 50 Hz (PAL, 31 kHz) | 720x480p at 59.94 Hz for any other video |
| Native HDMI | the video's own size, at 59.94 or exactly 60 Hz as the video runs; 59.94 Hz while no video plays | also 50 Hz for a 50 Hz-family video |

There is no Auto output: the Output Mode you pick is the signal, whatever `MiSTer.ini` sets
up. **Display Shape** (4:3 or 16:9) sets the shape the menus and fitted video are drawn for.

**Refresh Rate Match** (Off or 50/60) decides whether the rate follows the video. Off keeps
the Output Mode's rate. At 50/60 a stream at 50, 25 or 100 frames a second plays in the 50 Hz
family and any other in the 59.94 Hz family. On **Native HDMI** a stream at exactly 60, 30, 24
or 120 frames a second plays at exactly 60 Hz, with Refresh Rate Match Off or 50/60 (a
Moonlight game stream is exactly 60). The rate is read before the first picture, so a display
may resync once at the start of a stream, and the Output Mode's rate returns when playback ends.

**On the interlaced and progressive modes, every picture is fitted to the screen** at its true shape --
its cropping and its pixel shape as the stream declares them -- centred, with black bars where
the shapes differ: 640x480, 854x480, a transcode's 720x404, a phone's portrait 480x854 alike,
on 480 or 576 lines.

**Native HDMI** goes further for HDMI: the core's signal is the video's own size
-- 852x480, 640x480 (shown 853x480 with its side bars), 720x576, **1280x720** ... -- at the same
refresh rate, and the HDMI scaler makes the only resize to your display, the sharpest HDMI
picture. Every picture the core plays is shown this way, 720p included (any size up to 2,048
pixels on a side). Video stores its colour at half the resolution of its brightness; on every output -- Native HDMI, progressive
and interlaced, scaled or not -- the core rebuilds it by blending smoothly between the colour samples, at
the position the video says they sit (its chroma siting), so fine detail in strong colours (red text, a
logo's edge, a coloured subtitle outline) stays clean instead of turning into blocky steps. Each new picture size is a brief blip on HDMI (and MiSTer's resolution box, if
`video_info` is set). Native is for HDMI only: the analog output carries the same unusual timing
unless `vga_scaler=1`.

On HDMI the MiSTer's scaler converts the core's signal to your HDMI mode. A 50 Hz signal on
a 60 Hz HDMI mode shows a small judder; to avoid it, let the HDMI output follow the core
(`vsync_adjust=1` or `2` in `MiSTer.ini`). On the interlaced modes the HDMI scaler
deinterlaces (**HDMI Deinterlace**).

Between two streams the screen is black and keeps the last stream's shape.
