# MisterZine Plex Core 0.1.0-beta.35

- A resume, a seek or Skip intro that the server never answers now fails
  after 20 seconds instead of a minute, and says what happened: the server
  accepted the request but sent no video. The playback log carries the same
  line for Send a report. Playing from the start is unaffected. (Seen with a
  server whose hardware-accelerated conversion stalls on a seek into 10-bit
  HEVC; turning off the server's hardware acceleration avoids it.)

Uses the same qualified FPGA core as beta.33, with an updated playback worker. Existing
settings, calibration and saved access are preserved. Rollback restores the
previous release.
