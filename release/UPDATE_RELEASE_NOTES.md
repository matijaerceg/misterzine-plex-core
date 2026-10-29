# MisterZine Plex Core 0.1.0-beta.35

- A resume, a seek or Skip intro that the server never answers is retried
  instead of failing after a minute: a converted stream started part-way
  through is given 20 seconds to arrive, then asked for again with a slow
  seek (the server decodes from the file's start rather than jumping by its
  index), then from the beginning, with a line on the playback panel. The
  playback log names each attempt for Send a report. This targets servers
  whose hardware-accelerated conversion stalls on a seek; playing from the
  start was unaffected.
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
