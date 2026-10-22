# Application

The Go browser and playback interface for MisterZine Plex Core.
See [build instructions](../docs/BUILD.md), [architecture](../docs/ARCHITECTURE.md)
and [user guide](../release/README.md).

Runtime flags include -config, -cache, -player and -ffmpeg for installation
paths; -version identifies the build and -check validates the installation.
With no sign-in on record, -host with -token connects to that server with the
Plex token read from a file (a legacy setup). Developer flags include -dump
(with -wait, how long it waits for artwork) and -cpuprofile. PLEXCRT_NOPLAY
permits UI walks without launching media. PLEXCRT_CATALOGUE_FILE reads the
update catalogue from a local file instead of the published one.
PLEXCRT_TRANSITION_TRACE=1 logs screen transition timings for
tools/transition_trace.py, and PLEXCRT_BENCH_RING=1 lets the transition
benchmarks write to the overlay pages of an idle device.
PLEXCRT_WAIT_DOT="step,gap" tunes the three dots that
breathe while a playback starts or stalls (milliseconds from one dot's swell
to the next, centre-to-centre gap in pixels; default "280,28").
Synthetic controller input uses /tmp/plexcrt.ctl.
