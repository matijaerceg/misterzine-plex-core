# MisterZine Plex Core 0.1.0-beta.32

- Playback Info fits in one wider, compact panel with no row selection.
- Video and audio separately explain whether the server converted them.
  Original and received formats are compared when the source details are known.
- Plain-language conversion reasons explain format, channel, subtitle and
  playback-limit requirements. Local stereo output is shown separately.
- Measured current and average video bitrate, the applicable bitrate limit,
  MiSTer output and effective de-flicker state are visible together.
- Recent late frames and decoder errors are separated from playback totals;
  the sound buffer is shown in seconds.
- Arrow keys leave Playback Info open. Left/Right on its More-menu row has no
  effect; OK and Back return from Info to More.
- Original video whose file carries wrong or missing frame timing in its H.264
  header no longer judders. The player corrects the timing to the file's real
  frame rate before the core schedules pictures; a steady late-frame count on
  an otherwise smooth title was this.
- Reports include the H.264 stream headers as received, the demuxer's frame
  rates and the core's output changes, for diagnosing wrong output rates.

Uses the same qualified FPGA core as the preceding release. Existing settings,
calibration and saved access are preserved. Rollback restores the previous release.
