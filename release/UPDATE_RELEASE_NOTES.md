# MisterZine Plex Core 0.1.0-beta.31

- Stronger OSD de-flicker for downscaled video, including 720-line video on
  interlaced 480-line output. Off and native-size filtering are unchanged.
- Scrubbing while paused keeps the picture and play icon steady. Press OK on
  the playhead, Start, or the play button to resume at the selected position.
- Playback Info shows separate video/audio conversion status, current and
  average video bitrate, core output, and a concise conversion reason.
  The compact layout removes duplicate position information and indicates scrolling.
- Main and playback menus wrap from the first entry to the last and back.
- Show themes use buffered audio to prevent distortion from underruns and play
  at source volume with smooth fades.

Existing settings, calibration and saved access are preserved. Rollback restores
the previous application and core.
