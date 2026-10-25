# MisterZine Plex Core 0.1.0-beta.30

This update improves gradients, controller playback controls, server-outage
handling, menu audio, and the choice between original video and server conversion.

- **Gradient Dither** is on by default. It smooths colour gradients in the
  final picture and can be switched off in the core OSD.
- The controller **Start** button pauses and resumes playback.
- Menus stay responsive while the server is unavailable. Requests can be
  cancelled, and a connection error offers a retry instead of leaving the
  screen apparently frozen.
- Original H.264 video can play at unusual dimensions when it fits the
  decoder's picture and frame-rate limits. This permits some pictures slightly
  taller than 720 pixels; it does not add 1080p decoding.
- Surround audio is converted to stereo by the server. Eligible video stays
  unchanged during audio conversion; supported mono/stereo audio can still
  play directly. The selected video bitrate remains a limit on original video.
- Audio/video feeding is paced more carefully to avoid starving audio when
  video packets arrive in bursts.

- Navigation clicks play promptly while browsing. Navigation sounds retain
  their Off, Quiet and Loud settings.
- The navigation melody chooser includes Trolo, Sahur, Astro, Tetro and Cat.
- Show theme music is available again when supplied by the server, with an
  independent Theme music toggle. Themes mix with navigation clicks and stop
  before video playback.

Existing settings, calibration and saved access are preserved by updates.
Rollback restores the previous application and core. This remains a beta;
please include the title, playback position and symptoms when reporting an issue.

Cards on 0.1.0-beta.27 or earlier first update through 0.1.0-beta.27.1.
