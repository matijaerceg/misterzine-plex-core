# MisterZine Plex Core 0.1.0-beta.34

- Movies and episodes stored as several files now ask which version to play
  when you start from the beginning. The version best suited to the MiSTer is
  selected: the largest that plays directly, otherwise the smallest of at
  least 720p. Resuming plays the version last played on this MiSTer without
  asking; a resume point set on another device asks.
- The next episode, the L/R episode hold and Shuffle never ask: they play the
  version the show last played, or the one best suited to the MiSTer.
- A Version row beside Audio and Subtitles changes the version for the next
  play, and Playback Info names the version playing.

Uses the same qualified FPGA core and playback worker as beta.33. Existing
settings, calibration and saved access are preserved. Rollback restores the
previous release.
