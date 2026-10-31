# MisterZine Plex Core 0.1.0-beta.37

- A movie's edition (Director's Cut, Extended, Remastered) now shows after
  the runtime on the movie page, the Home hero and the library band, on the
  right of the playback controls, and in search results, so two editions of
  one film can be told apart.

# MisterZine Plex Core 0.1.0-beta.36

- Video crop set to Fill applies when playback starts again. Since the
  decoder-core release it only took effect after changing Crop under More
  during playback; a saved Video geometry calibration hid the fault.
- Theme music fades out over its last seconds instead of stopping dead.
  The clips servers hold are mostly 30 s long and cut hard at the end,
  which sounded like the app cutting the music off.
- Direct Video works again through HDMI-to-VGA adapters, such as a DAC
  feeding a 15 kHz CRT. Since the decoder-core release the core clocked the
  HDMI transmitter at 81 MHz on Direct Video and put a broadcast-style
  composite sync with equalizing pulses on the sync line; adapters dropped
  lock and the screen stayed black. The transmitter now runs at 27 MHz there
  and sends the plain composite sync the other cores use. Confirmed on the
  reporter's adapter with test build 0.1.0-beta.35.2.
- Composite and S-Video colour (MiSTer.ini vga_mode=svideo or cvbs) is now
  pinned: the installer and the app add this core's lines to the SD card's
  yc.txt, as the other cores have, so it applies from the first start. This
  fixes the occasional wrong colours after an OSD Reset or a new start, and
  the dot crawl that came with them.
- The 4:3 filter now ignores season 0 specials when judging a show, and
  re-checks the TV libraries once a day while the menus sit dimmed.

Ships a new qualified FPGA core (the Direct Video fix is in the core) with an
updated playback worker. Existing settings, calibration and saved access are
preserved. Rollback restores the previous release.
