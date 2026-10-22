# Settings

The core's OSD options. Every option the core defines is listed here; the list is checked
against the core's own definition on every build.

| Option | Values | Default | What it does |
|---|---|---|---|
| Output Mode | 480i60, 480p60, 576i50, 576p50, Native HDMI | 480i60 | Sets the display signal. **480i60** and **576i50** are interlaced, 15 kHz signals for standard-definition CRTs; **480p60** and **576p50** are progressive signals for 31 kHz displays and external scalers. 480-line fitted modes use steady-line 59.94 Hz; 576-line modes use 50 Hz. Exact-60 cadence is available only during Native HDMI playback. **Native HDMI** uses the video's own picture size while a picture plays. The core uses a 480-line picture for menus and idle screens. Native HDMI is intended for HDMI; analog output carries the same timing.
| Display Shape | 4:3, 16:9 | 4:3 | Sets one shared display shape for the HDMI output, fitted video, and overlays. The video keeps its encoded shape and is fitted or cropped inside the selected display shape. In Native (HDMI), a playing video is shown at the HDMI mode's own shape instead; the menus still follow this setting. |
| Deinterlace | Weave, Bob, Blend | Weave | How a picture that was recorded as two interlaced fields is shown on the progressive output. **Weave** shows both fields together at full resolution; moving edges can comb. **Bob** shows each field on its own, filling the missing lines from the ones above and below: smooth motion, half the vertical detail. **Blend** mixes the two fields: no combing and no flicker, with a soft ghost on fast motion. Progressive video (a game stream, film) is never altered, whatever the setting. A change takes effect immediately. |
| HDMI Deinterlace | Weave, Bob | Weave | Shown instead of Deinterlace while the output is Interlaced: how the HDMI scaler turns the 480i fields back into full frames. **Weave** joins the two fields (full detail; moving edges can comb); **Bob** shows each field on its own, line-doubled. The analog output is not affected: a CRT shows the fields as they are. |
| De-flicker | On, Off | On | On interlaced output, softens thin horizontal detail in progressive-frame video and program-drawn overlays so it flickers less. Field-coded interlaced sources bypass the filter. Progressive output is unaffected. **Off** keeps the original sharpness; **On** applies the filter at the next refresh. |
| Refresh Rate Match | Off, 50/60 | Off | **Off** keeps playback in the selected output family. **50/60** lets the picture switch between the 50 Hz and 60 Hz families while it plays. When playback ends, the selected Output Mode returns. The core reads the video rate before its first picture so the display can switch at the start. Changes to the playback clock take effect after restarting playback. |
| 240p Playback | Off, On | Off | Available on interlaced Output Modes. On those modes, shows playback as a progressive 240p or 288p signal instead of 480i or 576i. The full picture is scaled to half-height. Steady scanlines give approximately 59.914 Hz for 240p and 49.993 Hz for 288p; the scheduler follows these actual periods. It only takes effect while a video is playing; menus and idle screens keep their normal mode. Progressive and Native HDMI output modes are unchanged. |
| Play 24fps at 25fps | Off, On | Off | At playback startup, speeds eligible 23.976/24 fps film to 25 fps only on fixed-50-Hz 576i/576p Output Modes when Refresh Rate Match is Off. This traditional PAL speed-up shortens runtime and raises audio pitch; pitch is not preserved. It never speeds up 25 fps video again. Exact 30/60 fps can use the worker's 0.1% fitted-clock slowdown. The worker chooses its clock when playback starts, so restart playback after changing a setting that affects it. |
| Reset | | | Resets the core. |

Every picture size the core decodes is fitted to the screen on the Interlaced and Progressive
outputs: scaled by its true shape (the stream's pixel shape and cropping), centred, with black
bars where the shapes differ -- 640x480, 854x480, a phone's 480x854 or a transcode's 720x404
alike. On **Native (HDMI)** the core's picture is the video's own size instead, and MiSTer's
HDMI scaler fits it to your display ([Video output](../video/output.md)).

## HDMI scaling

HDMI scaling is not a core option: it follows your `MiSTer.ini`, as for every core. If
integer scaling (`vscale_mode`) is turned on for all cores, the picture may not fill the
screen. Add a section for this core to `MiSTer.ini` to fill it:

```ini
[MisterZine Jellyfin]
vscale_mode=0
```

## Saved settings

Settings are saved in the MiSTer configuration directory on the SD card using the
core's v1 settings schema. If a future version changes the option layout, the schema
version is bumped and settings return to their defaults once.

De-flicker now uses a new OSD setting bit so it can default to **On** without changing
the meaning of the existing bit used by the player settings request. On the first launch
after this update, a previously saved De-flicker choice resets to **On**. Other saved
options are preserved.
