# MisterZine Plex Core 0.1.0-beta.28

Updating from 0.1.0-beta.27 or earlier: the old updater cannot install this
release (it stops with "Unexpected package payload"). Run the beta installer
script again, or install 0.1.0-beta.27.1 first while Updates offers it.

A new playback path: video is now decoded by an H.264 decoder core on the
MiSTer's FPGA, which replaces the previous core. Scrubbing shows frames of the
film, the playback controls come in four looks, and supporters get a choice of
Home logo and a Random tab.

- From this release on, a release installs itself: the updater on the card
  fetches and verifies the download, and the release's own installer puts it
  in place and starts it. Later releases can change what the package contains
  without a stepping stone like 0.1.0-beta.27.1.
- Files the core can decode (H.264 High or Main, 8-bit, up to 1280x720) are
  streamed as stored, without a transcode on the server. Everything else is
  transcoded by your Plex server to H.264, up to 720p. If a stream played as
  stored falls behind, playback switches once to a transcode at the same
  position.
- The output is now chosen in the core's on-screen menu: 480i60 (the default),
  480p60, 576i50, 576p50 and Native HDMI, with a 4:3 or 16:9 Display Shape,
  Refresh Rate Match, 240p Playback, Play 24fps at 25fps and De-flicker. PAL
  displays are supported through the 576-line modes. **Video geometry** in
  Options is now **Video calibration**.
- Holding Left or Right on the scrubber shows a frame of the film at the dot,
  when your Plex server has made video preview thumbnails for it. Playback
  pauses while the hold runs and resumes at the seek. A dark box with the
  wait dots stands in for a frame that is still loading.
- Text subtitles (SRT, ASS/SSA, WebVTT) are drawn by the app, as white type
  with a thin dark outline. **Subtitle background** in Options puts them on a
  translucent box instead. Choosing, hiding or resizing them never restarts
  the video, and a file with text subtitles can still play as stored. Picture
  subtitles are still burned in by the server.
- **Playback UI theme** chooses the look of the playback controls: Standard,
  Icons, VCR or VCR without its band. The looks other than Standard are a
  supporter extra.
- **More** in the playback controls is one list: Crop, Downmix boost,
  Subtitle size, Autoplay next and Video bitrate change in place with Left and
  Right, and Playback info shows direct play or transcode, the picture, the
  sound and the decoder's late frames.
- **Video bitrate** offers 0.4, 1, 2, 3, 4, 6 and 8 Mbps (the default). The
  steps below 3 Mbps are for weak Wi-Fi and also make the transcoded picture
  smaller.
- Supporter extras: **Home logo** draws the wordmark, MisterKun or no logo on
  Home; the **Random** tab in libraries is out of beta and no longer needs
  Show beta features. Each row carries the purple star; OK on a locked row
  opens the code entry.
- A library wall rounds from its last row to its first, a held direction
  keeps up with the pictures, and letter jumps fetch nothing until they stop.
  Continue Watching comes from the server's own list, and **Forget my
  progress** clears an item's resume point.
- Space or P on a USB keyboard pauses and resumes in one press. During
  playback the first Back clears what is on screen, and a second Back within
  half a second is ignored, so a double press no longer stops the video.
- The progress bar shows how much is downloaded; a seek inside that range
  reuses it. Surround sound is folded to stereo on the MiSTer when a file
  plays as stored, with the same Surround downmix boost.
- FFmpeg now comes inside the release; the installer no longer downloads it.
  Each release's source is published beside it on GitHub.

Rollback to the previous release still works and brings back its core.
Network seeking, server compatibility and different hardware setups remain
beta test areas.

Installers and update notices become available when this release and its
catalogue are published. See README.md for setup and feedback instructions.
