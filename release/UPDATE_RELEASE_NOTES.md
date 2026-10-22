# MisterZine Plex Core 0.1.0-beta.28

A new playback path: video is now decoded by an H.264 decoder core on the
MiSTer's FPGA, which replaces the previous core.

- Files the core can decode (H.264 High or Main, 8-bit, up to 1280x720) are
  streamed as stored, without a transcode on the server. Everything else is
  transcoded by your Plex server to H.264, up to 720p. If a stream played as
  stored falls behind, playback switches once to a transcode at the same
  position.
- The output is now chosen in the core's on-screen menu: 480i60 (the default),
  480p60, 576i50, 576p50 and Native HDMI, with a 4:3 or 16:9 Display Shape,
  Refresh Rate Match, 240p Playback and De-flicker. PAL displays are supported
  through the 576-line modes. **Video geometry** in Options is now **Video
  calibration**.
- Text subtitles (SRT, ASS/SSA, WebVTT) are drawn by the app. Choosing, hiding
  or resizing them never restarts the video, and a file with text subtitles
  can still play as stored. Picture subtitles are still burned in by the
  server, at the chosen Subtitle size.
- **Video bitrate** offers 0.4, 1, 2, 3, 4, 6 and 8 Mbps (the default). The
  steps below 3 Mbps are for weak Wi-Fi and also make the transcoded picture
  smaller.
- **Options > Playback controls** adds two VCR looks, an old deck's on-screen
  display, beside the standard controls.
- During playback the first Back clears what is on screen, and a second Back
  within half a second is ignored, so a double press no longer stops the video.
- The progress bar shows how much is downloaded; a seek inside that range
  reuses it.
- Surround sound is folded to stereo on the MiSTer when a file plays as
  stored, with the same Surround downmix boost.
- FFmpeg now comes inside the release; the installer no longer downloads it.
  Each release's source is published beside it on GitHub.
- Menus draw faster and drop fewer frames, and network requests give up
  instead of hanging.

Rollback to the previous release still works and brings back its core.
Network seeking, server compatibility and different hardware setups remain
beta test areas.

Installers and update notices become available when this release and its
catalogue are published. See README.md for setup and feedback instructions.
