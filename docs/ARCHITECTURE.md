# Architecture

MisterZine Plex Core is a Plex client for the MiSTer FPGA. Video decoding and
output come from this project's own fork of owenb321's H.264 decoder core, kept
at [`third_party/MiSTer_h264_decoder`](../third_party/MiSTer_h264_decoder)
(GPL-3.0-or-later core, MIT client library) and shipped with each release as
`PlexH264.rbf`. Its integration manual is under
`third_party/MiSTer_h264_decoder/site/content/integrating/` (overview, overlay,
launch) and the C interface is `hps/include/h264ring.h`. This core replaces the
PlexCRT scan-out core of earlier releases.

## Layout

```
 Plex server ──HTTP──► Go app (plexcrt) ─draws 480-line frames──► /dev/fb0 overlay page ─┐
                          ▲                                                               │
                          │ input region (pads, keys, OSD open)                           ▼
                          └──────────────────────────── H.264 core (FPGA) ◄── ring ── C player
                                                         composites overlay        (jfplay,
                                                         over decoded video         libh264ring)
```

- **The core** (`PlexH264.rbf`, label `plex-<app version>`) decodes H.264
  access units and plays 48 kHz PCM against one clock, outputs
  480i/576i/480p/576p or native HDMI, and composites a page of the Linux
  framebuffer (`/dev/fb0`) over the video. With nothing playing it shows that
  overlay over black, so the browse UI needs no video. It is loaded through an
  MGL and `/dev/MiSTer_cmd`. It is built from the same vendored source as the
  MisterZine Jellyfin app's core, but as a separate file with its own label,
  so either app can change its core without the other.
- **The Go app** (`app/`, executable `plexcrt`) signs in through plex.tv,
  selects the Plex Home user, browses the server's libraries and runs the UI,
  rendering, input handling, art cache, theme music and updater. Its frames
  go into an overlay page in `/dev/fb0` described to the core
  (`h264ring_overlay_show`), sized to the core's raster (word 80), and its
  input comes from the core's input region (MiSTer main holds the real input
  devices while a core runs). It talks to the server through `app/internal/plex`.
- **The C player** (`arm/jfplay.c`, a name kept from the code it shares with
  the Jellyfin app) reads the direct stream or transcode URL supplied by the Go
  app, passes the H.264 video to the core untouched, decodes audio to stereo
  PCM, and writes both through `libh264ring`. The Go app asks the server for
  the stream and reports progress to it. See [playback](PLAYBACK.md).
- **The static `ffmpeg`**, built with the player's libraries, plays theme
  music in the menus.
- **Installer and updater** (`release/manager.py`, `update_service.py`,
  `catalogue.py`, `build_package.py`) keep the versioned-release, hash-checked,
  rollback-capable layout. The payload is `plexcrt`, `jfplay`, `ffmpeg` and
  `PlexH264.rbf`.

Release channels (`public`, `beta`) are set at link time by
`release/beta_release.py` (`-X plexcrt/internal/beta.Channel=...`). Builds
from this repository have no access gating; official beta builds add the
supporter code from a private repository ([supporter builds](SUPPORTER_BUILDS.md),
[beta builds](BETA_RELEASES.md)).

Internal names (the `plexcrt` executable and module, `jfplay`, the
`MISTERZINE_PLEX_*`, `MISTERZINE_H264_RBF` and `PLEXCRT_*` environment
variables) keep their historical spelling. `MISTERZINE_PLEX_READY_FILE` and
`MISTERZINE_PLEX_DISPLAY` are kept on purpose: they are a compatibility
contract between the app and `release/manager.py` and `update_service.py`,
including managers already installed. Renaming one means changing the Go and
Python sides together and accepting both names for at least one release.

## The ring and input packages on the H.264 core

`app/internal/ring` and `app/internal/input` speak the H.264 core's
interface 1.x (`third_party/MiSTer_h264_decoder/hps/include/h264ring_layout.h`),
reimplemented in Go without cgo. The UI-facing API keeps the old names where
the meaning carried over (`compat.go`).

- **Memory.** The control block (`0x3140_0000`, 4 KB of 64-bit words) is mapped
  through `/dev/mem` `O_RDWR|O_SYNC` after checking `/proc/iomem` (the library's
  rule); every access is one aligned 32-bit atomic load or store (on ARMv7 Go's
  `atomic.Store` is `DMB; STR; DMB`, `atomic.Load` is `LDR; DMB`, never
  LDREX/STREX). The 8 MB ring is not mapped: only the player writes it.
  `/dev/fb0` is mapped whole (its `smem_start` from `FBIOGET_FSCREENINFO` must lie
  in `0x2200_0000`+8 MB); two overlay pages sit at its start, sized to the
  core's raster (word 80), at most 1280x720 ARGB8888 each. The app draws a
  480-line canvas, 720 wide (960 for a 16:9 Display Shape), which is scaled
  onto the page, centred on the raster. A framebuffer mode that maps less than
  two pages (a 480p HDMI mode) is set to 1920x1080 after the core is up, and
  Watch puts it back when MiSTer main shrinks it.
- **Frames.** `Begin` hands out an ordinary-memory canvas; `End`/`Present` wait
  until the core's `ovl_gen` (word 46) has reached the last generation written
  (at most 60 ms), copy the frame into the page not on screen with alpha forced
  to 0xFF (the app draws xRGB with 0 in the top byte, which the core shows
  transparent) and the software brightness applied, then write words 79, 73-78,
  72 under a new generation. `EndBand`/`PresentBand` declare a band; `Hide`
  clears the show bit. The generation is kept ahead of word 72 and `ovl_gen`,
  because the player's library numbers its own descriptors from 1.
- **Pacing log.** Every 600 drawn frames (or at least 60 drawn over more than
  5 s) the app logs `frames N: avg A ms, worst W ms, missed fields M;
  fps=F draw=a/w wait=a/w ack=a/w copy=a/w gc=G gcpause=P`. `fps` is frames drawn
  per second over that window (about 1 when idle: the idle tick). Each `a/w` is
  the average and worst in ms (`-`: none counted): `draw` from the start of the
  frame to calling `End`, `wait` the `WaitField` before an animated frame (or
  `EndEvery`'s wait for its field), `ack` `End`'s wait for the core to take the
  previous descriptor, `copy` its copy into the page. `gc` is the GC cycles
  completed in the window and `gcpause` their total stop-the-world pause in ms.
  `missed field: drew D ms starting S ms into the field` follows a frame that
  landed a field late.
- **The overlay only during a session** (rule F1 in the vendored core's
  media-client notes, `docs/jellyfin.md`). The
  library's lock is an advisory exclusive `flock(LOCK_EX|LOCK_NB)` on
  `/tmp/h264ring.lock`, held by the player from `h264ring_open_devmem` to
  `h264ring_close`. The Go app never holds it while the player may run: when no
  session is open (a fresh core, the menu's Reset) and the lock is free, it takes
  the lock for the handshake only (pause, settings and rumble words zeroed, the
  write index rounded to 16, its descriptor, then the nonce alone, the ack),
  and releases it at once. Closing a library handle does not end a session, so
  the overlay stays up after the player exits. The player's session start writes
  its own descriptor (none) over ours; Watch notices (words 72-79 differ from what
  we wrote) and writes ours again. If the player ever draws its own overlay the
  two would fight: a contract between them is needed then.
- **The playback overlay** (`ring.Overlay`: a rectangle with alpha, the dot, the
  bar) is composed in software into the
  same pages, transparent outside its lines, band = the lines it covers. The
  core-driven dot run is emulated by a goroutine redrawing each heartbeat.
  Unchanged overlay calls skip redraws only while the published descriptor still
  matches. A replaced descriptor or framebuffer presentation forces restoration;
  changed pixels retain the normal acknowledged page-flip path.
- **Playback controls.** Startup and commands run on session workers so network
  requests and player restarts do not block input and drawing. Pending seeks
  coalesce, stop cancels startup, and child replacement remains serialized.
  Reports to the server use a separate ordered worker; metadata refreshes wait for
  the stopped report without holding up the UI.
- **Status.** `Status()` reads the status block's seqlock (word 31, the words,
  word 3): heartbeat, state, live flags (OSD open, session), shown-picture count,
  overlay generation/state/error, raster (word 80), aspect (word 47).
  `Field()` is the heartbeat; `Foreign`/`Published` follow the display's
  `fetch_changes` (word 13) while a picture is shown. Idle dimming is the
  software brightness applied as frames are copied into a page; `Tap`, the
  PlexCRT core's click, is a no-op (`compat.go`).
- **Launch.** `ring.Open` calls `LaunchCore` (MGL in `/tmp/h264ring.mgl`,
  `load_core` written once to `/dev/MiSTer_cmd`, only when `/tmp/CORENAME`
  does not already name the app's core, `MisterZine Plex Core`, the only name
  it accepts (`H264` is another app's core); rbf `_Other/PlexH264`, or
  `$MISTERZINE_H264_RBF`) and waits for the heartbeat. An installed release
  is started by its menu entry, which loads the release's own `PlexH264.rbf`
  first.
- **Input.** `input.Poll` reads the whole input region (words 48-71) as a seqlock
  (in_tail first, in_head last) when the source offers `InputRegion`, keeps its
  own event count against `ev_count` (more than 32 between reads: the oldest are
  lost, everything is released), and maps the pads (all six OR'd, the left stick
  past 96/127 as the d-pad) to the legacy layout the UI uses: bits 0-3 d-pad
  (same bits), 4 OK <- B, 5 Back <- A, 6 L <- LB, 7 R <- RB. Key events feed
  the existing PS/2 set-2 decoder (the event's [9:0] is in the key word layout
  that decoder reads); since MiSTer sends no typematic, the last key held repeats in software.
  MiSTer's menu opening releases everything held and the pads read released
  until it closes (buttons held across it are ignored until let go); a release
  with no press is dropped. `PollAll` also delivers `Special` events (Key None):
  `MenuOpened`, `MenuClosed`, `ActionHome` ("Send Home to the program"),
  `ActionMenu` ("Program menu"), `InputLost`, `MouseButton`; `Poll` keeps them
  to itself so the current UI sees only keys.
