# MisterZine Plex Core 0.1.0-beta.36

- Video crop set to Fill applies when playback starts again. Since the
  decoder-core release it only took effect after changing Crop under More
  during playback; a saved Video geometry calibration hid the fault.
- Theme music fades out over its last seconds instead of stopping dead.
  The clips servers hold are mostly 30 s long and cut hard at the end,
  which sounded like the app cutting the music off.

Uses the same qualified FPGA core as beta.33, with an updated playback worker. Existing
settings, calibration and saved access are preserved. Rollback restores the
previous release.
