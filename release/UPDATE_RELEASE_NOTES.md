# MisterZine Plex Core 0.1.0-beta.33

- Server connection checks no longer send your Plex token to every advertised
  address. Direct HTTPS connections are tried first, and replies must identify
  the expected server. Plain HTTP fallback is limited to connections advertised
  as local. The new Plain HTTP connections setting can disable this fallback;
  it is on by default, and sessions using it remain unencrypted on the local network.
- A new Direct play setting lets you have the server transcode every file,
  including files that could otherwise play directly. It is on by default.
- Hold L or R for two seconds during playback to go to the previous or next
  episode. The on-screen indicator shows the hold progress.
- Playback Info fetches the item's track details before its first display,
  so original video and audio information is available sooner.

Uses the same qualified FPGA core and playback worker as beta.32. Existing
settings, calibration and saved access are preserved. Rollback restores the
previous release.
