# HDMI setup

The picture's mode and shape are chosen in the core's OSD (the MiSTer menu
button while the app runs); the app's Options have no video output setting.
MiSTer's HDMI scaler then turns the core's picture into the HDMI resolution set
in your MiSTer INI. The core's own manual describes every OSD option:
[core settings](../third_party/MiSTer_h264_decoder/site/content/using/settings.md).

## Recommended starting point

1. In the core OSD, set **Output Mode** to **480p60**. This fits every video and
   the menus into a 480-line picture at 59.94 Hz. Use **576p50** instead for a
   50 Hz picture, or **Native HDMI** (below) to keep the detail of 720p video.
   If an analog CRT is also connected, keep an interlaced mode it accepts.
2. Set **Display Shape** to **16:9** on a widescreen display, so the menus and
   fitted video use its full width, or **4:3** for side bars around a 4:3
   picture. Make sure the display itself preserves the incoming aspect ratio
   and does not zoom or overscan.
3. Add or update this section in the **active MiSTer INI**, preserving other
   settings. If you use an alternate configuration, edit that file rather than
   assuming `MiSTer.ini` is active. Keep the section below the `[MiSTer]`
   settings: MiSTer reads the file from top to bottom, and later values win.
   Reload the core after saving.

   ```ini
   [MisterZine Plex Core]
   video_mode=8
   vscale_mode=0
   vscale_border=0
   vrr_mode=0
   ```

   This selects 1920x1080 at 60 Hz, full-height scaling without an added border,
   and turns variable refresh rate off (see
   [below](#variable-refresh-rate-vrr-freesync)). These settings apply only to
   this core; other cores keep your global settings. MiSTer matches the section
   to the core by its name, so it must read exactly `[MisterZine Plex Core]`.
   Earlier releases used the same name, so a section written for them still
   applies: check its settings against the ones above.
4. Optionally, in the OSD's **Video Processing** settings, choose a scaler
   filter from file, such as **Interpolation (Sharp).txt** for both directions,
   to smooth uneven text strokes. No CRT simulation or scanline effect is
   needed.

If a global `vscale_mode` turns on integer scaling for every core, the picture
may not fill the screen; `vscale_mode=0` in the section above fills it.

## 50 Hz output and refresh matching

The core's refresh rate follows **Output Mode**: 59.94 Hz in the 480-line
modes, 50 Hz in the 576-line modes. With **Refresh Rate Match** at **50/60**
it switches family while a video plays, to suit the video, and returns when
playback ends. With **Native HDMI** a playing video at exactly 24, 30 or 60
frames per second runs at exactly 60 Hz; 23.976 and 29.97 stay at 59.94 Hz,
and a 25 or 50 fps video gets 50 Hz only with Refresh Rate Match on.

With `vsync_adjust=0` (MiSTer's default), HDMI keeps the rate of `video_mode`
whatever the core does. When the two differ, frames are dropped or repeated and
motion judders. For a 50 Hz picture either pick a 50 Hz HDMI mode
(`video_mode=9` is 1920x1080 at 50 Hz, `7` is 1280x720 at 50 Hz), or set
`vsync_adjust=1` so HDMI follows the core's rate, if your display accepts both
50 and 60 Hz. Refresh Rate Match on HDMI needs the second: a fixed HDMI mode
cannot follow a switch.

## Native HDMI

**Native HDMI** shows a playing video at its own picture size, up to 1280x720,
and leaves the scaling to MiSTer's HDMI scaler, so a 720p film keeps its
detail on an HD display. A playing video takes the HDMI mode's own shape;
the menus still follow Display Shape. **Video calibration** does not apply in
this mode. The analog output carries the same timing, so it is meant for HDMI
only.

## Interlaced output on HDMI

On the interlaced modes (**480i60**, **576i50**) the OSD shows **HDMI
Deinterlace**: **Weave** joins the two fields for full detail (moving edges can
comb), **Bob** shows each field on its own. The analog output is not affected.
On the progressive modes, **Deinterlace** chooses how video recorded as
interlaced fields is shown: **Weave**, **Bob** or **Blend**.

## Choosing an alternative

- **Compatible higher-resolution displays:** `video_mode=12` selects genuine
  1920x1440 at approximately 60 Hz. Other displays may reject this timing or
  stretch it; have a way to restore the INI. This is not MiSTer's
  pixel-repeated 2560x1440 mode.
- **720p or 480p displays:** use a supported output mode (`video_mode=0` for
  1280x720, `6` for 640x480, or `2` for 720x480). Check proportions and text on
  the actual display. Filtering can trade sharpness for more even strokes;
  matching 720x480 alone does not guarantee one-to-one pixels after aspect
  correction.
- **Integer scaling** (`vscale_mode=1`) can make source rows more even, but
  leaves top and bottom bars at 1080p and an especially small picture at 720p.

## Variable refresh rate (VRR, FreeSync)

VRR lets the display follow a core whose refresh rate changes. This core's
rate changes during playback when **Refresh Rate Match** switches family, and
slightly in Native HDMI and 240p playback. With VRR forced on, HDMI follows
the core's rate, as it does with `vsync_adjust`, so Options do not flag it.
MiSTer switches VRR off whenever `vsync_adjust` is 1 or 2. Forcing FreeSync
(`vrr_mode=2`) was reported to make 24 fps films stutter with this app's
earlier core, which ran at a fixed 59.94 Hz; it has not been tested with the
H.264 core. Keep `vrr_mode=0` in the section above unless you have checked
your display with it.

With VRR off, 24 fps films at 59.94 or 60 Hz can still look slightly uneven:
their frames are held for three and two refreshes in turn. Some displays smooth
it with a film-mode or motion setting, which game modes often disable. On a
50 Hz picture, **Play 24fps at 25fps** avoids the uneven pattern by speeding
films up.

## Settings Options warn about

When the app starts, its launcher reads the INI MiSTer loaded for the core,
including an alternative INI chosen in the MiSTer menu, and applies MiSTer's
own section rules. It reads the file, not live values. **Options** then shows
a row, below **Video crop**, for each setting that hurts playback, weighed
against the core's current **Output Mode** and **Refresh Rate Match**. Select
a row to see which file to change and what to add; the lines go in a
`[MisterZine Plex Core]` section at the end of that file, and take effect once
you start the app again from the MiSTer menu.

- **HDMI refresh** (with the rate, for example **60 Hz**): HDMI keeps a fixed
  rate, and either it is well away from the Output Mode's own (50 Hz for the
  576-line modes, 59.94 Hz for the others), or Refresh Rate Match is on and
  can move playback to a rate HDMI does not follow. Modes 3, 7 and 9 are
  50 Hz. With `vsync_adjust=0` the rate is `video_mode`'s. With `vsync_adjust`
  1 or 2, MiSTer follows the core instead, unless `refresh_min` or
  `refresh_max` leaves out the core's rate, or a `video_mode_pal` is set
  without a `video_mode_ntsc`, or a custom video mode needs a pixel clock
  MiSTer cannot make. For a mismatched Output Mode the note suggests a fixed
  mode at the right rate (`video_mode=8`, or `9` for the 576-line modes; `0`
  or `7` for 1280x720), with `vsync_adjust=0` when `vsync_adjust` is on. With
  Refresh Rate Match on it suggests `vsync_adjust=1` when `vsync_adjust` is 0,
  and otherwise lists what can keep MiSTer from following the core;
  either way turning matching off is offered when HDMI suits the Output Mode.
- **HDMI sound: Off (DVI mode)**: `dvi_mode=1` sends no sound over HDMI. Sound
  still plays from the analog audio output.
- **INI section: Overridden**: a `[MiSTer]` section further down the file
  changes a video setting the `[MisterZine Plex Core]` section sets to a
  different value. Move that section to the end.

Each alternative INI is checked on its own, so a section for this core kept in
only some of them, such as an HDMI INI but not a CRT one, is not flagged.
**Send a report** still notes it, in case settings seem to be ignored.

Some settings are only resolved while MiSTer runs, so rows that depend on them
stay hidden. `direct_video=1` sends the core's own timing, and with
`direct_video=2` MiSTer decides at start-up whether a VGA converter is
attached. A `[video=...]` section applies only when it names the core's
current video mode, which MiSTer measures once the core runs.

## What has been checked

These recommendations follow from how the core and MiSTer's scaler work. The
release notes list the setups each release was tested on; native 1080p and
720p panels and VRR displays have not been checked with this app yet. When
comparing captures, view them at actual size so preview resizing does not
introduce another scaling artifact.

For more detail, see MiSTer's [video scaling documentation](https://mister-devel.github.io/MkDocs_MiSTer/advanced/videoscaling/)
and [output modes](https://mister-devel.github.io/MkDocs_MiSTer/advanced/videomodes/).
