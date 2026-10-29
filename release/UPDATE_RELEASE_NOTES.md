# MisterZine Plex Core 0.1.0-beta.35

- A resume, a seek or Skip intro that the server never answers now fails
  after 20 seconds instead of a minute, and says what happened: the server
  accepted the request but sent no video. The playback log carries the same
  line for Send a report. Playing from the start is unaffected. (Seen with a
  server whose hardware-accelerated conversion stalls on a seek into 10-bit
  HEVC; turning off the server's hardware acceleration avoids it.)
- Failure reports now show which playback startup stage stalled and how long
  it took. The most recent failed playback log survives playing another video
  before sending a report.

- Movies and episodes stored as several files now ask which version to play
  when you start from the beginning. The version best suited to the MiSTer is
  selected: the largest that plays directly, otherwise the smallest of at
  least 720p. Resuming plays the version last played on this MiSTer without
  asking; a resume point set on another device asks.
- The next episode, the L/R episode hold and Shuffle never ask: they play the
  version the show last played, or the one best suited to the MiSTer.
- A Version row beside Audio and Subtitles changes the version for the next
  play, and Playback Info names the version playing.

Uses the same qualified FPGA core as beta.33, with an updated playback worker. Existing
settings, calibration and saved access are preserved. Rollback restores the
previous release.
