# MisterZine Plex Core 0.1.0-beta.38 (unreleased)

- Send a report now includes the board’s network setup and private IPv4 addresses,
  plus subnet and ARP-cache clues from failed connection attempts. Server addresses,
  hostnames, MAC addresses and public addresses are omitted from these new diagnostics.
- A completed Plex link-code sign-in is saved even when no server answers.
  Retrying or restarting keeps the sign-in; a rejected account token asks for a new code.
- Send a report now includes the composite and S-Video setup: `vga_mode`, `ntsc_mode` and the picture controls from the MiSTer INI, and whether MiSTer main will use the app's colour subcarrier lines in `yc.txt`.

# MisterZine Plex Core 0.1.0-beta.37

- A movie's edition (Director's Cut, Extended, Remastered) now shows after
  the runtime on the movie page, the Home hero and the library band, on the
  right of the playback controls, and in search results, so two editions of
  one film can be told apart.
- Composite and S-Video colour: the core now reports its video clock count
  over a whole frame to MiSTer main (words 19/20 of the current framework),
  so main computes the subcarrier exactly on every start instead of from a
  one-line measurement that landed on 80.99 or 81.01 MHz. The yc.txt lines
  added in beta.36 stay as a fallback for MiSTer releases before August 2026.
  The core also picks up the framework's Y/C chroma and NTSC timing fixes,
  registered analog audio pins and a scaler state reset at VSync.
- 720p transcodes from Plex servers that use Intel Quick Sync hardware encoding now show a picture; before, the screen stayed black while the sound played. Intel's encoder codes 720p as 1280x736 with a note to show only 720 lines, and the core silently refused anything larger than 1280x720. It now accepts pictures up to 4,096 blocks of 16x16 pixels, which its frame memory always had room for, so hardware encoding can stay on.
- If the core still decodes a stream but shows none of it, or drops its pictures as too large, the app now notices (within a second for pictures that are too large, a few seconds otherwise) and restarts the item once at the same point as a transcode of at most 854x480, instead of leaving the spinner up over the sound. A file played as stored falls back to an ordinary transcode first.
- Files coded at 1280x736 and similar sizes just over 720 lines can now play as stored, at up to 29.6 frames per second.

Ships a new qualified FPGA core. Existing settings, calibration and saved
access are preserved. Rollback restores the previous release.

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
