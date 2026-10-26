# MisterZine Plex Core 0.1.0-beta.31

- **Stronger de-flicker for downscaled video.** The OSD De-flicker setting now
  suppresses more of the fine horizontal detail that flickers when higher-resolution
  video is reduced to interlaced output, including 720-line video on a 480-line display.
- De-flicker Off and native-size filtering are unchanged.
- Pressing OK on the playhead after scrubbing while paused now resumes playback
  from the selected position. Releasing the scrub alone keeps playback paused.

Verified with actual DE10 output captures and visible playback checks in both apps.
Existing settings, calibration and saved access are preserved. Rollback restores
the previous application and core.
