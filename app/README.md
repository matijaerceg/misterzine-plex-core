# Application

The Go browser and playback interface for MisterZine Plex Core.
See [build instructions](../docs/BUILD.md), [architecture](../docs/ARCHITECTURE.md)
and [user guide](../release/README.md).

Runtime flags include -config, -cache, -player and -ffmpeg for installation
paths; -version identifies the build and -check validates the installation.
Developer flags include -dump and -cpuprofile. PLEXCRT_NOPLAY permits UI walks
without launching media. PLEXCRT_WAIT_DOT="step,gap" tunes the three dots that
breathe while a playback starts or stalls (milliseconds from one dot's swell
to the next, centre-to-centre gap in pixels; default "280,28").
Synthetic controller input uses /tmp/plexcrt.ctl.
