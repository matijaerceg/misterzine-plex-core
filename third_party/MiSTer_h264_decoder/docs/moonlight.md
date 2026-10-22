# The Moonlight client (the proving ground)

Engineering note. Status: **the view-only client ✅ MERGED (PR fj#13, 2026-09-30), ✅
HW-CONFIRMED**; **input through the core (§7, branch `feature/moonlight-input`, interface 0.6):
designed with the maintainer, built, GREEN in simulation and the host tests; fitted (SEED 7,
104.07 / 104.08); ✅ HW-CONFIRMED 2026-09-30 with the maintainer: keys, mouse, an Xbox pad, the OSD
release and both quit combos, through a stream into the PC (`history.md` §13). ✅ MERGED (PR fj#14).**
**Reaching the program from the pad (§7 M11 / M12, branch `feature/pad-home`, interface 0.8):
built, GREEN in simulation and the host tests; fit SEED 7 109.59 / 108.46 (`H264_padhome_20260930_1641.rbf`); on the rig both actions arrive before the OSD's closing
and ✅ HW-CONFIRMED 2026-09-30 with the maintainer: Send Home and the chord open the host's Guide
(`history.md` §15). ✅ MERGED (PR fj#16).** History: **designed 2026-09-29** (the decisions below taken with the
maintainer); **the static ARM build works** (`clients/moonlight/build.sh`, 3.8 MB); **the first
live sessions ran on the rig 2026-09-29** (view-only, video + audio through the ring, 0 errors:
`history.md` §12); input, the launcher and the host test are next. Branch `feature/moonlight`. The roadmap's box: Phase 4's "the
proving ground" (and Phase 7's example integration).

A stock Sunshine / GeForce Experience host streams a desktop or a game to a Moonlight client
on the MiSTer's ARM; the client hands the core H.264 access units and PCM through
`hps/lib` (libh264ring) and forwards the controls to the host. It is the first program other
than `h264play` on the interface before 1.0 freezes, and it is what every open question
waits on: 854x480p60 at ~1 % margin (Phase 5's last levers), low-latency audio drift from a
real host, whether a client needs the overlay (Phase 6b).

## 1. Decisions (2026-09-29, the maintainer)

| # | Decision | Rejected, and why |
|---|---|---|
| M1 | **In this repository, a sibling directory `clients/moonlight/`**: a pinned upstream moonlight-embedded commit, a patch series, and this project's own `mister` platform backend; built by a script. It moves to a fork (or an upstream PR) at Phase 7. | A separate fork repo now: tests the library as a third party would, but every interface change before 1.0 would span two repositories. **Not under `hps/`**: moonlight-embedded is GPL-3.0 and `hps/` is MIT with the promise "link it from a program of any license"; `clients/` is GPL-3.0-or-later like the rest of the tree (a `NOTICE` entry). |
| M2 | **A Scripts-menu launcher + an ini** (v1, before the overlay): `Scripts/moonlight.sh` reads `moonlight.ini` (host, app, size, rate, bitrate); `pair` prints its PIN in the script console; `stream` runs the client detached, which loads the core; when the client exits, for any reason, the launcher loads the menu core (only from H264). | Shell-only until Phase 6b draws a host / app picker: leaves no user path at all for months. |
| M3 | **The size is automatic: the MiSTer screen's shape** (decided 2026-09-29, the maintainer, after the first rig sessions showed a 4:3 desktop boxed on all four sides). At start the client reads the status block: an interlaced raster (480i / 576i: the analog-TV case -- Video Output Auto decides it from `MiSTer.ini` before any stream) or Aspect Ratio 4:3 asks **640x480**; otherwise (HDMI, Aspect Auto / 16:9) **848x480** (53x30 macroblocks: 16:9 in whole macroblocks, inside the 1,620). 60 frames/s, 10,000 kbit/s requested (D1). Sunshine fits its desktop into the frame it is asked for, so matching the *screen* leaves at most one set of bars (Sunshine's, when the desktop's shape differs); `width` / `height` in the ini override. | **720x480** (the first default): square pixels make it a 3:2 frame -- Sunshine boxed a 4:3 desktop into it and the core boxed the 3:2 frame onto a 4:3 screen (both measured: `fit_oh` 427, bars on all sides). **Following the PC's desktop**: Sunshine reports no display modes (measured: `serverinfo` over HTTP and over HTTPS as the paired client carries no `DisplayMode`). **Fixed 848x480**: a 4:3 desktop on a 4:3 screen boxed on all sides again. |
| M4 | **A fully static ARM binary**: OpenSSL 3 (Apache-2.0, compatible with GPL-3.0; moonlight-embedded carries no OpenSSL exception), curl (HTTP/HTTPS only), expat, opus, libevdev, cross-built from pinned tarballs in a Docker image that extends `hps/docker/` (it lacks cmake and pkg-config). One file to copy, immune to MiSTer Linux changing its libraries. | Dynamic against the rig's own libraries (OpenSSL 1.1, curl, expat, evdev, udev are there; opus and avahi are not -- measured 2026-09-29): faster to stand up, but breaks when MiSTer Linux changes versions, and GPL-3.0 + OpenSSL 1.1 would lean on the system-library exception. |
| M5 | **Input comes through the core** (decided 2026-09-29, the maintainer): **Main holds an exclusive `EVIOCGRAB` on every input device while a core runs** (Main's `input.cpp`: `grabbed = 1`, released only while the Linux framebuffer console is shown; measured on the rig: the pad and the IR remote `EBUSY`), so a program on the ARM opens the devices and never receives an event. Main already hands the core everything a game-stream client forwards (hps_io: six pads -- 32 buttons in the user's MiSTer mapping, both sticks --, every keyboard event as a PS/2 scancode, the mouse); the core will mirror them into the status block (interface 0.6) and the client forward them. Stock Main, the user's own pad mapping, Bluetooth, and Main stops feeding the core while its OSD is open (the gating for free). **Its own branch** after this one merges. | **hidraw** (the grab does not reach it): a HID descriptor parser per device, and xpad-driven Xbox pads (the rig's own) have no hidraw node. **A Main fork** leaving the devices ungrabbed: the project runs on stock Main. **The framebuffer console** (Main un-grabs while it is shown): it replaces the core's picture. |
| M6 | **v1 is view-only; merged before the input** (the maintainer): `-viewonly`; the way out is loading another core (or the menu) from Main's OSD -- the client notices the core's heartbeat stop and ends the stream. | One branch until input works: holds a working streaming client back behind an interface change and RTL. |

## 2. The design

### Upstream and the patch series

moonlight-embedded `f32e415` (moonlight-common-c `b126e48`), the commit Phase 1 captured
with. `clients/moonlight/patches/`, each small and upstreamable in spirit:

1. **A static build** (`0001`): libgamestream and moonlight-common as static libraries, the
   dependencies' include paths and link order. **No avahi**: `gs_discover_server` compiled
   out; the host address is required (the ini names it). **No libuuid**: libgamestream's
   calls (a fresh token per request) replaced by a version-4 UUID from OpenSSL's
   `RAND_bytes`. **No udev**: `src/input/udev.c`'s hotplug replaced by an inotify watch on
   `/dev/input` (a static libudev means systemd's; MiSTer Linux creates the nodes itself).
2. **A `mister` platform** (`0002`: `platform.c` / `platform.h`, `main.c`, CMake's
   `ENABLE_MISTER`): `-platform mister`, and `auto` picks it when `/dev/MiSTer_cmd` is
   writable. The core loads before the host starts the app (`platform_start` moved ahead of
   `gs_start_app` for this platform); H.264 and stereo forced. The callbacks are this
   project's `src/mister/mister.c` (below), copied into the tree by `build.sh`.
3. **`-platform fake` dumps the video** (`0003`, Phase 1's `tools/p1/moonlight_dump.patch`):
   the client's cost without a decoder (R1), and captures of what a host sends.
4. ~~Input shared with Main~~ (a `0004` reading `/dev/input` with the OSD gating was written and
   dropped: Main's grab starves it -- M5, below). 0002 also carries the automatic size: with
   `-width 0 -height 0` (the launcher's default) `main.c` calls `mister_preferred_size` after
   the core is loaded, before the host starts the app.

### Video

`submitDecodeUnit` concatenates the decode unit's buffer list into one Annex-B access unit and
writes it with `h264ring_write_au(r, au, len, -1, LOW_LATENCY | GRAPHICS, timeout)`:
- **LOW_LATENCY | GRAPHICS on every access unit.** The core presents each picture as soon as
  it is decoded (the host's clock is not ours) and Anti-Twitter Auto filters a game stream at
  480i (`analog.md` §9).
- **No PTS (`-1`).** Under LOW_LATENCY neither the display nor the audio uses one
  (`architecture.md` "Low latency"); the host's `rtpTimestamp` is 32-bit at 90 kHz and would
  only add a wrap to reason about.
- **Errors ask for an IDR.** After each write the client reads the status block (a seqlock
  copy, ~48 words: cheap at 60 Hz); if `FE_ERR` or `RC_ERR` advanced, it
  calls `LiRequestIdrFrame()` (the error belongs to an access unit already written, so
  returning `DR_NEED_IDR` for this one would be late anyway). A session the core dropped
  (`-ENOTCONN`: the OSD's Reset) or stopped in ERROR is restarted, then an IDR requested.
  **The grace window** (found by the host test): the core lags a few pictures, so errors from
  pictures written *before* an IDR can reach the status block just *after* it is written; for
  `IDR_GRACE_MS` (250 ms) after an IDR an error only moves the baseline. The cost: an error
  in the IDR itself asks for nothing until the next error after the window.
  Network loss is moonlight-common-c's: without reference frame invalidation it drops
  frames until the next IDR, so no broken reference reaches the core.
- **A refusal ends the stream, by name.** `FE_REFUSED` advancing means the stream uses
  something the core does not decode (`h264_pkg.sv` `REF_*`: MBAFF, CAVLC, 4:2:2, a picture
  over 128 macroblocks a side...); no IDR cures that, so the client prints the refusal's name and
  ends the stream (SIGTERM to its own main loop). The library does not name the `REF_*` codes
  yet: `mister.c` carries the table -- a candidate for `h264ring_refusal_name()` in the library
  (an additive library change) once a second program needs it.
- **CAVLC is rewritten into CABAC** (fj#20, decided 2026-10-01: on by default in each client;
  `cavlc.md` §9): the library's write call does it -- a CABAC unit passes untouched, a host
  forced to CAVLC (`amd_coder=cavlc`, `nvenc_h264_cavlc`, `qsv_coder`) is rewritten bit-exact up
  to the A9's ceiling (~4-5 Mbit/s at 480p60; above it the pictures are late, the LOW_LATENCY
  presentation drops the older ones). The backend only maps the write's two new results: a
  refusal (`-EOPNOTSUPP`) ends the stream once like a core refusal (SIGTERM; the units after it
  dropped), a unit that does not parse (`-EBADMSG`) is dropped and an IDR awaited
  (`DR_NEED_IDR`). `cleanup` prints how many units were rewritten.
- **No reference frame invalidation in v1** (`capabilities = 0`). The decoder keeps a full
  DPB, so declaring RFI (the host then re-references an older frame instead of sending an
  IDR) is a later latency lever, measured before it is claimed.
- The stream starts at the first IDR with its SPS / PPS (the depacketizer strips a leading AUD
  / SEI); a non-IDR access unit while an IDR is awaited returns `DR_NEED_IDR` unwritten. A new
  session per stream. No END_OF_STREAM at the quit: the flag rides on an access unit and the
  last one is gone by then; the next session's start resets the stream (and v1 loads the
  menu core at the quit anyway).

### Audio

**Stereo Opus only** (`AUDIO_CONFIGURATION_STEREO`, whatever the command line says: the core
presents 48 kHz s16 stereo, D2). `decodeAndPlaySample` decodes one packet with libopus and
writes it with `h264ring_write_audio(r, pcm, len, -1, timeout)`. Sunshine sends **5 ms
packets** by default (moonlight-common-c `SdpGenerator.c`: 10 ms only for a declared slow
decoder or a low bitrate with arbitrary durations allowed), i.e. 240 frames, 960 bytes: at the
library's "5 ms or more" and 1.28 s at the core's 256 unplayed records. No audio capability
flags in v1. The core plays low-latency audio against a queue target with counted
single-sample slips (`architecture.md` "Low latency") -- the real host's drift is what this
client measures. A lost packet (`decodeAndPlaySample(NULL, 0)`) is decoded by libopus as
concealment (`opus_decode(..., NULL, ...)`), so the queue keeps its length.

### One writer

moonlight-common-c calls the video and the audio callbacks from different threads; the ring
has **one writer** (a session's write index and sequence number are the library's state).
The library is not thread-safe and never was; **the client serializes every ring call with
one mutex**. One exception to "never wait inside it": a session (re)start holds it for up to
2 s (`h264ring_start_session` waits for the core's acknowledgement); the audio, called on
moonlight-common-c's receive thread, sees a `restarting` flag and drops its packet instead of
queueing behind it (a restart is a hole in the picture and the sound either way). That is a documentation fact, not an interface change: `h264ring.h` and the
manual's `integrating/library.md` say it in the same change. A full ring is waited out with
the `try_` calls and a short sleep **outside** the mutex, so a stalled video write cannot hold
the audio off (or the reverse) for its whole timeout.

### Input -- superseded by M5 (kept for the next branch: what was tried and learned)

**Measured 2026-09-29 on the rig, with the maintainer:** a uinput keyboard on the MiSTer, the
client open on it (`/proc/<pid>/fd`), nothing reached Kate on the PC -- **Main grabs every
input device** (`EVIOCGRAB`, `input.cpp:5547`, `grabbed = 1` from boot; released only with the
Linux framebuffer console shown, `video.cpp` `input_switch(0)`). The manual's "read them, but
leave them shared" (`integrating/launch.md`) was wrong and is corrected. The design below was
built (patch 0004, the host-side test of the gating's rig half: F12 -> `OSD_OPEN` -> "input
paused") and dropped; the next branch reads the input from the status block instead, and the
release-on-OSD-open idea carries over (Main stops feeding the core while its OSD is open, but
the client must still release what the host holds).


- **No `EVIOCGRAB`**: upstream grabs keyboards, mice and touchscreens once streaming starts;
  a grabbed device never delivers the menu key to Main.
- **Nothing forwarded while `OSD_OPEN`**: a 50 ms timerfd on the main loop reads the status
  block (`mister_poll_status`) and is the only writer of `mister_blocked`. While it is set the
  handlers run as usual -- their state (modifiers, buttons, sticks, hats) stays true -- but the
  six `LiSend*` calls are macros that send nothing (`LiSendControllerArrivalEvent` stays live: a
  pad plugged in meanwhile is still announced). On the rising edge the client releases on the
  host every key libevdev reports down, the five mouse buttons and every gamepad (all zero);
  on the falling edge it sends each gamepad's current state. A key pressed during the OSD and
  released after reaches the host as a lone release: harmless. Rejected: dropping the events
  while the OSD is open -- the handlers' state would go stale (a stick left deflected, a
  modifier left set).
- **Main's keys are never forwarded**: F12 (the menu), a table in the patch. F9 (Main's
  console), F11 (Bluetooth pairing) and **a gamepad's menu button** are R3: the gamepad's press
  reaches the host before `OSD_OPEN` does (up to 50 ms plus Main's own delay), so a Guide
  button mapped to Main's menu would also open Steam's overlay -- measured before deciding.
- Gamepads through upstream's SDL-style mappings; Main reads the same devices for its menu.
- **Quit**: upstream's combos (Ctrl+Alt+Shift+Q; Start+Select+L1+R1) end the stream,
  optionally quit the host app (the ini), and load the menu core.

### The way out (M6) and the unloaded core

View-only has no quit combo. The user loads another core, or the menu, from Main's OSD. **An
unloaded core's words stay in memory as they were** (measured on the rig: the session still
looked open, the ring simply stopped draining, every write timed out) -- so the client watches
the heartbeat: `seq_head` (+1 a frame) still for `ALIVE_MS` (1.5 s) -> "the H264 core is no
longer running" -> SIGTERM, the stream ends, no restart is tried again. The status is read after
every write, after a failed one, and on the early `DR_NEED_IDR` returns, so the heartbeat is
watched even while the client waits for an IDR. On the rig: 891 access units, then
`load_core menu.rbf` -> the client's message and a clean exit within the window. (An OSD Reset
keeps the heartbeat: its dropped session is restarted, as before.)

### Launching (M2)

`clients/moonlight/mister/moonlight.sh`, installed as `Scripts/moonlight.sh`, and
`/media/fat/moonlight/`: the binary, `gamecontrollerdb.txt`, `moonlight.ini`, `keys/` (the
client's key directory), `moonlight.log`. `build.sh` lays these out in `build/dist/` as the SD
card. One script, three states, no arguments (the Scripts menu passes none):
1. no ini: write a commented template, say "set host=", stop;
2. `moonlight list` says "must pair": run `pair` (the PIN in the Scripts console; the user
   types it into Sunshine's web page), stop; a host that cannot be listed, or an `app=` it
   does not list, is said so with the apps it has;
3. otherwise stream: detached (`setsid nohup`) so the client outlives the console and the core
   load it makes (**R2 measures this**); when the client exits, for any reason, load the menu
   core -- only if `/tmp/CORENAME` is still H264, never over another core.
The ini is parsed, not sourced (keys whitelisted, spaces and CRs trimmed, numbers checked); a
second launch while a client runs is refused. Tested on the workstation against a stub client
(every branch). Messages a user needs while streaming (a lost host, a refused stream) have
nowhere to go until the overlay: v1 writes them to the log and ends the stream back to the
menu. User page: the manual's `using/moonlight.md`.

## 3. Measurements before the code depends on them

- **R1 (CPU and loss, no ring code)**: `clients/moonlight/build/moonlight` with `-platform
  fake -viewonly` and `MOONLIGHT_DUMP=/dev/null` (writing 1.25 MB/s to the SD card would load
  the measurement), a 5-minute session from the workstation's Sunshine at 720x480p60 and 10
  Mbit/s requested, mpv playing a known clip fullscreen on the host (Phase 1's protocol,
  `tools/p1/capture_sunshine.sh`): the ARM's CPU beside Main (FEC, audio decryption, the
  receive threads), moonlight-common-c's loss statistics. A second short run with a real dump
  path if the bytes are wanted. If one Cortex-A9 core cannot keep up, everything else waits.
  **Pairing may carry over**: Sunshine knows a client by its certificate, and Phase 1's dump
  client is paired -- its key directory (`client.p12`, `client.pem`, `key.pem`,
  `uniqueid.dat`; never committed) copied to the rig and named with `-keydir`; `moonlight
  list <host>` printing the apps proves it, and saves a PIN round with the maintainer.
  **Measured 2026-09-29 on the original DE10-Nano (.236, stock Main on the menu core):**
  pairing carried over (Phase 1's key directory, `moonlight list` printed the host's three
  apps; no PIN); Sunshine's Desktop at 720x480@60, 10,000 kbit/s requested, mpv looping a 60
  frames/s clip on the host, 5 minutes (busybox `top` every 10 s, 28 samples): **the client
  2.1 % of the ARM's total (max 4 %) -- ~4 % of one Cortex-A9 core**; Main 49.9 % (one core, its
  usual poll loop); softirq 1-4 %; the rest idle (~44 %). The kernel's UDP counters: 344,400
  datagrams (~1,160 a second: video with its FEC, and audio), **0 RcvbufErrors, 0 InErrors**;
  the client logged no lost frame and asked for no IDR. Not in the figure: Opus decoding (the
  fake platform leaves audio undecoded) -- a few percent of a core for stereo, measured with
  the `mister` platform. Video encryption is off (Sunshine's LAN default); audio is decrypted.
  **Verdict: the ARM has the headroom; CPU does not gate the port.**
- **R2 (the launcher)**: a process started with `setsid` from a Scripts-menu script survives
  the console closing and a `load_core`. **Done over ssh 2026-09-29** (`history.md` §12): the
  launcher returns at once, the client loads the core and streams, and its exit brings the menu
  back. From the Scripts menu itself: by Main's source (`menu.cpp` MENU_SCRIPTS_FB: the script
  under `agetty` on tty2, its children not waited for), expected the same; confirmed by hand
  when the maintainer runs it.
- **R3 (Main's keys)**: which keys Main acts on while a core without a keyboard runs (F9,
  F11, F12, the gamepad's menu button), to fill the filter table.

## 4. Gates

- **The host test** ✅ (`clients/moonlight/tests/run_test.sh [--red]`, ~3 min with `--red`):
  `mister.c` unmodified, built for the host (the seam: `mister_attach` takes a ring the test
  attached; `mister_get_counters`), against a fake core consuming on its own thread
  (`test_mister.c`, the protocol's core side as `hps/tests/test_ring.c` has it). S1: the
  Sunshine capture (`.sim/sunshine/cap_10000.h264`, else an x264 High clip made on the spot)
  as decode units split over 1-3 buffer entries, 2 ms apart, while an audio thread started
  first sends 5 ms Opus packets (every 40th lost); S2 an error counter -> one IDR request, P
  frames refused until the IDR; S3 the session dropped (the ack cleared: an OSD Reset) -> a
  new session opening with the IDR; S4 a refusal -> SIGTERM once, no IDR; S5 OSD_OPEN. The
  consumed bytes scored by `check_mister.py` through `tools/ring_model.py`'s consumer: no
  error, one VIDEO_AU per decode unit, byte-identical, LOW_LATENCY | GRAPHICS on each, no
  PTS, no audio before the session's first access unit, every AUDIO record 960 bytes and the
  audio equal to a separate reference decode of the packets written. The fake core's barrier
  yields the CPU between a record's payload and its index, so two unserialized writers
  interleave. S5 also checks the size rule; **S6 the core unloaded** (its words left as they
  were, the heartbeat still: the rig's behaviour) -> the stream ends. **GREEN; `--red` 13
  mutations, each caught by its own check** (a flag, the buffer concatenation, the mutex -- 4 of
  4 runs --, the early-audio rule, the IDR request, the grace window, the IDR wait, the restart,
  the refusal, OSD_OPEN, the concealment, the size rule, the unloaded core). It found the
  grace-window bug above, and S6 as first written (the ack cleared) passed while the rig's
  unloaded core went unnoticed -- rewritten to the rig's behaviour. **(fj#20) S7**: an x264
  ultrafast CAVLC clip in session 2 -- every unit rewritten (counted) and the consumed bytes equal
  to `hps/cavlc2cabac`'s output on the same file; **S8**: a stream the rewrite refuses (redundant
  pictures, `tools/cavlc_synth.py`) -> SIGTERM once, nothing written, no IDR asked; then a new
  stream writes again. `--red` 15 mutations (+ the rewrite off -> S7, its refusal's SIGTERM
  removed -> S8).
- **On the rig** (`history.md`): a 30-minute session at 720x480p60, errors 0, the late /
  skipped and audio slip counters recorded; the OSD opened mid-game (no input reaches the
  host, nothing stuck); the OSD's Reset (the session restarts, the picture returns within an
  IDR); the quit combo (back to the menu); 854x480 at 10 Mbit/s requested (the margin); 480i
  on the RetroTINK with Anti-Twitter Auto.

## 5. Known limitations (v1)

- The core loads before the host starts the app (`mister_start` precedes `gs_start_app`), so
  a host that refuses the app leaves the core's black screen up: the launcher loads the menu
  core on any non-zero exit.
- ~~View-only (M6)~~: the input comes through the core since interface 0.6 (§7). Its own
  limits: no analog triggers, no Guide button on the pad (the host's Guide through the OSD's
  Send Home or the Back + Start chord since 0.8: §7 M11 / M12), no rumble (since 0.13: §8), no absolute pointer
  (Main's, or decided: `architecture.md` "Input (interface 0.6)"); LS / RS / LT / RT need the
  user's "Define H264 buttons" once.
- No on-screen UI: pairing and errors go through the Scripts console and a log (Phase 6b).
- No host discovery (no avahi): the ini names the host.
- H.264 only (the core decodes nothing else); stereo only.
- No reference frame invalidation (an IDR per loss).
- The ini's resolution is checked by the client against the core's own bounds (interface 0.11,
  word 81 via `h264ring_caps()`, 2026-10-02): a picture above 3,600 macroblocks or a rate above
  108,000 macroblocks a second is **refused** at setup (it warned above 97,200 before). So
  `width=1280` / `height=720` works with `fps=30` (720p30: a light game stream decodes at ~1.2x,
  `mb_pipeline.md` §4f); 1280x720 at 60 is refused with the advice to ask for 30. The automatic
  size stays 848x480 / 640x480 (M3): on today's 720-wide rasters a 720p stream adds no detail.
  Since interface 0.12 (`hd_raster.md`) Video Output Native (HDMI) shows 1280x720 at its own pixels
  on HDMI, so there a 720p30 stream does add detail; the automatic size still asks 848x480 at 60
  (a 720p30 default would halve the frame rate, which a game stream may not want) -- `width=1280
  height=720 fps=30` asks for it. **Decided 2026-10-04 (the maintainer, after the 720p round): the
  automatic size stays 848x480 / 640x480 at 60 -- "framerate trumps resolution here"**; 720p30 stays
  an explicit choice in `moonlight.ini`.

## 6. Next concrete step

This branch (view-only, M6): the fit done (2026-09-30, SEED 7 first roll, clk_dec 108.12 /
104.32, `H264_moonlight_20260930_0247.rbf`; no RTL change), the release packaging done
(`tools/package_release.sh` carries `build/dist`), docs-sweep done, the Scripts menu run by the
maintainer on the shipped build (2026-09-30, `history.md` §12). ✅ MERGED (PR fj#13). After it, the
input branch (M5): the core mirrors hps_io's pads, keyboard and mouse into the status block
(interface 0.6: the fields, a keyboard-event queue, `CONF_STR`'s `J` line naming the pad's
buttons for Main's mapping), the client reads and forwards them (PS/2 set-2 to the host's key
codes; MiSTer's pad bits to the host's gamepad), releases on the OSD's opening; R3 (Main's own
hotkeys) then matters only for what Main forwards to the core. Rig notes: Sunshine on the
workstation captures HDMI-A-1 (a 640x480 output) -- play test content there (`mpv
--fs-screen-name=HDMI-A-1`); Sunshine once refused a session with "Couldn't find monitor [0]"
(transient: the next session streamed); the paired key directory goes to the rig for a test
and is deleted after (never committed).

## 7. The input branch (M5): the brief to start from

Written 2026-09-30 at the merge of the view-only client (PR fj#13), for a fresh session.
**Branch `feature/moonlight-input`** (`CORE_VERSION dev-mlinput`, its first commit; nothing
pushed). The project's order holds: **a design pass with the maintainer first**, recorded here
and in `architecture.md`, then code; the interface is a published contract (CLAUDE.md).

### What is known

- **Main holds every input device** while a core runs (`EVIOCGRAB`; Main's source is at
  `../MiSTer_DVD/main/.build/Main_MiSTer/`: `input.cpp:1736` `grabbed = 1`, `:5547` and `:6482`
  the grab, `video.cpp` ~3676 the only release -- the Linux framebuffer console). Measured on the
  rig (`history.md` §12): a second grab on the pad and the IR remote returns `EBUSY`; a uinput
  keyboard the client opened delivered nothing.
- **What Main already gives the core** (`sys/hps_io.sv`, none of it wired in `h264/emu.sv`
  yet): `joystick_0..5 [31:0]` (buttons in the user's MiSTer mapping, named by `CONF_STR`'s
  `J` line), `joystick_l_analog_0..5` / `joystick_r_analog_0..5 [15:0]` (signed -127..+127, Y
  [15:8], X [7:0]), `ps2_key [10:0]` (PS/2 set-2 scancode [7:0], [8] extended, [9] pressed,
  [10] toggles each event -- one event at a time: the core must queue them), `ps2_mouse [24:0]`
  ([24] toggles each event; buttons and 9-bit signed dx / dy as PS/2 packs them),
  `ps2_mouse_ext [15:0]` ([7:0] wheel), paddles, spinners; and **`joystick_0..5_rumble [15:0]`
  inputs** (large [15:8], small [7:0]): the PC's rumble could flow back to the pads.
- **Main and its OSD** (to confirm in the design pass, pointers only): analog axes are not sent
  while the OSD is visible (`input.cpp:3920`); keys and buttons go to the menu instead
  (`:3636`); `user_io_kbd` / `joy_digital` route. Whatever the core last saw stays latched while
  the OSD is open -- **the client must still release everything on `OSD_OPEN`'s rising edge**
  (the view-only branch's `mister_poll_status` / `mister_osd_open` already read it).
- **The status block today:** words 0-31 and 40-47 (the audio) written by the core **once a
  raster frame** (`h264/ring_stat.sv`, five 8-word bursts under the seqlock; `ring_rd.sv`'s
  engine issues them on ram1's master B); 32-39 are the program's. Layout tables:
  `tools/ring_layout.py` (generates `hps/include/h264ring_layout.h`; never edit the header).
  Once a frame means up to 16.7 ms of added latency, and keyboard or mouse events between two
  writes are lost unless queued.
- **The send side already exists** in the dropped patch 0004 (the `LiSend*` calls, releasing
  keys / mouse buttons / pads, restoring pads, the upstream evdev state model):
  `git show a93114d:clients/moonlight/patches/0004-MiSTer-input-shared-with-Main-no-grab-F12-kept-nothi.patch`.
  Moonlight's API: `LiSendKeyboardEvent` (Windows VK codes, 0x80xx), `LiSendMouseMoveEvent`,
  `LiSendMouseButtonEvent`, `LiSendScrollEvent`, `LiSendMultiControllerEvent` (buttons, two
  8-bit triggers, four 16-bit axes), `LiSendControllerArrivalEvent`; rumble comes back through
  the connection callbacks.

### Questions for the design pass (the maintainer decides)

1. **Where the input goes in the control block**: a new core region (like 0.5's 40-47), how
   many words, one more burst. Pads as a snapshot (six pads x buttons + two sticks); the
   keyboard and the mouse as **event queues** (a ring of N entries with a write counter, the
   client reading from its last count: no event lost between frames, overflow counted).
2. **Latency**: once a frame (the existing cadence) or a faster input burst (every ~1-2 ms: a
   few more ram1 bursts; occupancy, not bandwidth, is the scarce resource --
   `hw_budget_and_lessons.md`). Measure the added latency either way.
3. **The pad model**: MiSTer's bits -> Moonlight's buttons (A B X Y, LB RB, Back Start Guide,
   LS RS, the d-pad); triggers digital (0 / 255) unless mapped otherwise; the `J` line's names
   (what Main's "define joystick buttons" asks the user); how many pads to forward.
4. **The keyboard**: PS/2 set-2 (+E0) -> the host's VK codes -- a table in the client (the
   inverse of Main's Linux-keycode -> PS/2 map, then upstream's `keyCodes`); Main's own keys
   (F12, and R3's others) are presumably never passed to the core -- confirm.
5. **The mouse**: relative, PS/2 packing, the wheel; absolute is not available.
6. **Rumble back to the pads**: in scope or later (a program word -> `joystick_N_rumble`).
7. **Interface 0.6**: additive (a new region, older programs unaffected); the integrator
   pages, `h264stat`, `ring_model.py`, and the benches that write / check the status block
   (`run_ring_rd.sh`, `run_scaffold.sh`'s `check_emu_wiring`).

### Decided in the design pass (2026-09-29, the maintainer)

The core's side is `architecture.md` "Input (interface 0.6)" (words 48-71). The four choices
the maintainer made, each the recommended one:

| # | Decision | Rejected, and why |
|---|---|---|
| M7 | **Written on change, at most every 1 ms**, and once a frame (the heartbeat); the client polls every 1 ms: ~2 ms added at most. | Once a raster frame with the status block: up to 16.7 ms more, felt in a fast game. |
| M8 | **No Guide button: the pad is 16 bits** (d-pad, A B X Y, LB RB, Back Start, LS RS, LT RT). | Guide as bit 16: Main then sends the word in two halves (a torn read to design around), and Main's own menu button defaults to the pad's Guide / Home. Steam's overlay stays on the keyboard (Shift+Tab). |
| M9 | **Rumble later**; program words 36-37 reserved for it. (Built 2026-10-04 in interface 0.13: §8.) | In this branch: a read the engine would add to its poll (reads hold ram1's grant), measured on its own; and Main's ~32.8 s effect length to design around. |
| M10 | **F12 stays Main's** (`F12KEYMOD=0`): plain F12 opens the menu and never reaches the PC, as on every core. | Win+F12 for the menu: F12 reaches the PC, but the Win press leaks to it first. |

Defaults taken with them (stated in the pass, not objected to): no key repeat from Main (the
host repeats; the PC's repeat is the rig test's control arm); the mouse relative; the PS/2 ->
host key table in the client; all six pads mirrored, each announced to the host on its first
input; the `J` line `JN` (sticks never become d-pad bits), the default mapping by position
(`jn`), checked on the rig with a real pad.

### Reaching the program: OSD actions and a chord (decided 2026-09-30, the maintainer; ✅ MERGED, PR fj#16)

Every pad button is the game's or Main's (the pad's Guide / Home opens Main's OSD), so a player
has no way to send the host's Guide (Steam's / Xbox's overlay) or, later, to open the client's
own menu (Phase 6b). Two ways, both chosen (rejected: Guide back on the pad as bit 16 -- M8's
reasons stand):

| # | Decision | Notes |
|---|---|---|
| M11 | **OSD actions, two entries now**: `R` lines in the core's `CONF_STR` (generic names, the core serves any program: e.g. "Send Home to the program", "Program menu"), each a status bit Main pulses, mirrored into the input region as a new event type (**3: an action, [7:0] its number**) -- interface 0.8, additive. The Moonlight client maps action 0 to the host's Guide (press + release) and ignores action 1 (reserved for its menu once the overlay exists), so the OSD's layout never changes later. | Main pulses a trigger's bit (set, cleared: `menu.cpp` ~2580) and an `R` line then closes the OSD, so the action event lands BEFORE the OSD-closed event: the client must take action events while it drops input for the open OSD, and act on them after the close (the host then sees the Guide on a clean, released state). Status bits: [17], [18] (free; bits are allocated once). A pulse is microseconds: the core latches the edge on clk_sys (as the Reset line's). |
| M12 | **A client chord**: holding **Back + Start** for about a second sends the host's Guide (the client's quit combo stays Start + Back + LB + RB). No core or interface change. | The game sees Back and Start pressed before the hold completes (the price of a chord); moonlight-embedded's own "hold Start" (mouse emulation) is the precedent. The hold length is a client constant. |

**As built** (branch `feature/pad-home`, `CORE_VERSION dev-padhome`; the core's side is
`architecture.md` "The OSD's actions (0.8)"):

- The OSD: `R[17],Send Home to the program` and `R[18],Program menu`, above Reset in their own
  group; `ring_in.sv` queues each rising edge as event `{3, n}`, before a pending OSD edge;
  `osd_req.sv` never passes the two bits through a program's settings request.
- The client (`src/mister/mister_input.c`): an ACTION event is taken whatever the OSD's state
  and acted on at the first read where the OSD is closed. Action 0 -> a Guide tap on the first
  announced pad (pad 0, announced as it is sent, when none is: a keyboard-only user still gets
  one); action 1 -> logged ("this client has no menu yet"). The chord: Back + Start held, LB
  and RB not held (else it is the quit combo under way, which must never also send a Guide),
  for `GUIDE_CHORD_MS`; the Guide on THAT pad; Back and Start then masked from what is
  forwarded until each is released (else the game would see them pressed again when the Guide
  tap ends). The quit combo reads the pad's raw word, so the mask never hides it.
- **The two lengths** (client constants, counted in 1 ms timer ticks; a late timerfd wakeup
  counts its expirations): `GUIDE_CHORD_MS = 1000` -- a deliberate hold, long enough that no
  game's Back + Start press sends a Guide by accident, short enough to feel like a button
  (upstream's "hold Start" for mouse emulation is the same order); `GUIDE_TAP_MS = 100` -- the
  Guide is held that long, not pressed and released in one read: a host that polls its virtual
  pad (XInput behind ViGEm on a Windows host) could miss a sub-millisecond tap, and 100 ms is
  under any "long press" a host UI might give another meaning.
- The Guide goes as Moonlight's `SPECIAL_FLAG`; a pad's arrival now declares it among its
  buttons (Sunshine then gives the virtual pad a Guide button).
- Instruments: `bench/h264/run_ring_in.sh --red` (arms A1-A6: the number, the edge, the order
  beside an OSD edge, the losses, both actions at once, the write), `run_osd_req.sh --red` (O8:
  the action bits never pass), the client's `tests/run_test.sh --red` (T10 the OSD's action,
  T11 the chord, nine mutations), `h264stat --input` prints `OSD action n`.

### The client's side (patch 0004, `src/mister/mister_input.c`)

- **A 1 ms timerfd on the input loop** (upstream's `loop_add_fd`, the evdev input module not
  started at all: every device is Main's): `h264ring_input()` (a consistent copy of words
  48-71), then `h264ring_input_events()` hands the events since the client's count, in order,
  and says how many were lost.
- **Keys:** PS/2 set-2 (+ extended) -> Linux key code (the inverse of Main's `ev2ps2`, a table
  in `mister_input.c`) -> upstream's `keyCodes` (Linux -> Windows VK) -> `LiSendKeyboardEvent`
  with the modifiers the client tracks. A held-key set: a release of a key not held is dropped
  (NumLock / ScrollLock's breaks; a key held across the OSD); Pause (Main sends it once, on the
  key's release) goes down and up at once.
- **Mouse:** the sums' differences -> `LiSendMouseMoveEvent` (Y negated: PS/2 is up-positive,
  the host down-positive), split into `short`s; the wheel's -> `LiSendScrollEvent`; a buttons
  event -> `LiSendMouseButtonEvent` for each bit that changed (L, M, R, X1, X2; buttons 6-8 have
  no host button).
- **Pads:** MiSTer bits -> Moonlight's flags (`[3:0]` RIGHT LEFT DOWN UP, then A B X Y LB RB
  BACK PLAY LS_CLK RS_CLK; LT / RT -> 0 or 255), the sticks' -127..127 scaled to +-32767 (Y
  negated to Xbox's up-positive... after checking Main's sign on the rig);
  `LiSendControllerArrivalEvent` (Xbox type, no capabilities) on a pad's first non-zero word,
  then `LiSendMultiControllerEvent` whenever its word changes, with the active-pad mask.
- **The OSD:** an OSD-open event releases everything the host holds (keys, mouse buttons,
  every announced pad zeroed) and drops key / button events until the OSD-close event; pads
  resume with their next change (Main zeroed them). **Lost events** (the count ran more than 32
  ahead): the same release, counted, logged.
- **Quit:** upstream's combos (Ctrl+Alt+Shift+Q; Start+Select+LB+RB) end the stream; the
  launcher then loads the menu core. `-viewonly` goes from the launcher.

### How other hybrid MiSTer projects get input (read 2026-09-30, at the maintainer's request)

An agent read the source of every MiSTer project found that pairs an FPGA core with a program
on the ARM (clones under the session's scratch space; commits cited there):

| Project | Input tactic |
|---|---|
| DreamSTer (skmp) | **Kills Main** (SIGTERM, then SIGKILL), loads its own bitstream -- polly2 has no hps_io, it is not a MiSTer core -- and its emulator (minicast) reads `/dev/input/event*`; reloads the menu and restarts Main after |
| Groovy_MiSTer | **A Main fork** (`MiSTer_groovy`) chosen per core with `MiSTer.ini`'s `main=` (a stock feature: `cfg.cpp`, `app_restart`); hooks Main's joystick / keyboard / mouse sends beside the SPI writes and sends UDP to the PC. The input never touches the FPGA |
| 3S-ARM, AM2R_MiSTer | **A Main fork** via `main=` that publishes Main's mapped pad state to `/dev/shm`; pads only |
| MiSTer-VCMI | Runs **with the Linux framebuffer shown** (Main un-grabs then) and SDL reads the devices |
| MiSTer_SAM | Keyboard through **hidraw**; mouse through `/dev/input/mice` -- by the source read, a MiSTer **kernel patch** keeps `mouse*` handles fed under Main's grab; **measured on .201 (2026-09-30): `mouse1` / `mouse2` delivered nothing under the grab** (`history.md` §13) |
| mrext, Zaparoo | Inject input into Main (uinput, `/dev/MiSTer_cmd`); never read the user's devices |

No stock Main feature exports input to a program (no socket, no shm; `/dev/MiSTer_cmd` has no
input command). The established tactic is the **per-core Main fork through `main=`**: no added
latency, the OSD gating free, but it replaces Main for that core, needs a hand-edited ini and a
rebase per Main release -- M5's "the project runs on stock Main" rejects it. The core mirror is
the only stock-Main, no-ini path that carries everything hps_io does. (The kernel's `/dev/input/mice` path as a mouse complement: not needed -- the core carries the
mouse -- and on the rig `mouseN` delivered nothing under the grab.)

**The framebuffer as the way to the devices (asked by the maintainer 2026-09-30, rejected).**
Main un-grabs only in `video_fb_enable(1, 0)` -- the Linux console framebuffer (fb 0; fb > 0
keeps the grab) -- which also switches the scaler to show the framebuffer INSTEAD of the core
(HDMI; the analog pins keep the core's picture): "the framebuffer on, nothing drawn" is a blank
console on HDMI, not the stream. While it is shown Main still reads every device and turns pad
presses into uinput keys for the console (`input.cpp` ~2531: d-pad -> arrows, button 1 ->
Enter, button 2 -> Esc): a program would see phantom keys beside the pad, and F12 too. And
there is no stock trigger: this core has no `MISTER_FB` (Main keeps the grab: "Core doesn't
support HPS frame buffer"), and `/dev/MiSTer_cmd` has no command that shows fb 0 for a core.
**Phase 6b's overlay is unaffected:** its draft already leaves Main's framebuffer switch off
(the core composites `/dev/fb0`'s memory itself) -- and must keep doing so, or the input
through the core goes dark while the overlay is shown (`architecture.md` Phase 6b).

### Instruments and rig notes (§7)

- The host test (`clients/moonlight/tests/run_test.sh --red`) extends with the fake core
  writing input words: events in, the right `LiSend*` calls out (stub them in `test_mister.c`),
  nothing lost across frames, the release on `OSD_OPEN`.
- On the rig: `tools/mister_uinput_keys.py` (overlapping and held keys; its keys now reach
  Main and, through hps_io, the core) and `tools/mister.py key` (single keys, the OSD toggle);
  on the PC a text editor on the captured display (Sunshine captures HDMI-A-1, 640x480) with
  **the maintainer present** (the keys land in their desktop) -- the PC's key repeat is the
  control arm. Sunshine injects through its "libvirtualhid" devices (present on the PC).
- Streaming for a test: the paired key directory (`~/.cache/moonlight`: `client.p12`,
  `client.pem`, `key.pem`, `uniqueid.dat`) copied to `/media/fat/moonlight/keys` beside
  `build/dist`; remove it all afterwards (`mister.py restore` does not know those files).
- Rigs: .201 (the SuperStation) is H264's; .236 belongs to the DVD / UMD sessions -- ask them
  (their session names change; `ListAgents`) before using it.

## 8. Rumble (interface 0.13; branch `feature/rumble`, `dev-rumble`)

Asked 2026-10-04 by the maintainer ("Add rumble support for moonlight"); M9's deferral ends. The
core's side is `architecture.md` "Rumble (interface 0.13)" (program words 36-38 -> `hps_io`'s
`joystick_N_rumble` during a session, status words 82-83).

**Decided 2026-10-04 (the maintainer): the keepalive is the program's.** Main plays a value for
32.767 s and re-uploads only on a change, so a constant rumble needs a nudge; the library's
`h264ring_rumble_keepalive()` steps a held value by one (1/255 of a motor) every 10 s and back.
Rejected: the core refreshing (a client that crashes with a session open would leave the pad
buzzing until the next session or an OSD Reset; with the refresh in the program, Main's 32.767 s
is the dead program's stop); nobody refreshing (a held rumble, an idling engine, stops after 33 s).
Defaults taken with it: the words read with every poll (one burst of seven, not a second read);
rumble passed on while Main's OSD is open (Main's behaviour on every core); every 16-bit value
valid (no reserved bits, nothing to refuse -- the three u32s' high halves ignored, like word 32's).

**As built** (`src/mister/mister_input.c`, patch 0005):

- **The callback** (`mister_rumble`, moonlight-common-c's callback thread) stores pad n's
  `{lowFreqMotor >> 8, highFreqMotor >> 8}` (an `__atomic` u16 each); the host's controller n is
  the pad the client announced as n, which is Main's pad n (player n + 1). A controller past the
  six is counted (`rumble_dropped`) and dropped. The 1 ms input timer writes a changed value
  (`h264ring_rumble`: one thread writes the words) and runs the keepalive every `RUMBLE_TICK_MS`
  (100 ms). It writes whatever the OSD's state. `mister_input_stop` stops every pad (the host's
  last word may not be 0); the library zeroes the words at close.
- **Patch 0005** sets `rumble_handler` **and** `rumble_triggers_handler` on the mister platform:
  upstream's `connection.c` `rumble_triggers()` tests `rumble_handler` before calling
  `rumble_triggers_handler`, so setting only the first would call a NULL pointer on a host's
  trigger rumble (an Xbox One controller's impulse triggers). The trigger handler drops it (Main
  has no trigger motors).
- **Pads are announced with `LI_CCAP_RUMBLE`** (was 0), so a host that reads the capability
  gives the virtual pad its motors.
- **The counters** (printed at the end): rumble changes written, pads the keepalive stepped,
  rumble for a controller past six.

**Instruments:** `run_ring_rd.sh` R27 (U1-U6), `run_scaffold.sh` W93-W95, the library's
`test_ring.c` "rumble" checks (`red_h264.py`, six arms), the client's `test_input.c` T12 (seven
arms). On the rig: `h264stat` shows `rum_p0`-`rum_p5` and `rum_changes` (what reached Main); the
motor itself needs a hand on the pad (the maintainer's round).

**Fit and rig (2026-10-04, `history.md` §32):** SEED 3 first roll, clk_dec 104.11 / 104.8, 88 % ALM
(`H264_rumble_20261004_2256.rbf`); on .201 `h264play --rumble` put each value in its pad's half of
words 82-83 during the session and 0 after the exit. ✅ HW-CONFIRMED 2026-10-04 with the maintainer (a game through the Moonlight client: "rumble works and feels good"; the keepalive's 10 s step not yet exercised by a sustained rumble) -- .201 running the 0.13 core
with Moonlight, Jellyfin and the player rebuilt (the 0.12 set backed up on the card). The poll's burst of seven costs +0.3-1 % cycles a
macroblock in the cosim (`architecture.md` "Rumble (interface 0.13)").

**The maintainer's round (HW-confirm):** the core with the three ARM clients rebuilt against 0.13
(Moonlight, Jellyfin, the player: the library accepts only its own interface version). A pad with
force feedback, one of its buttons pressed first (Main gives it a player number then), then a game
that rumbles through this client, or `h264play --rumble 0,200,0 FILE` with `h264stat` showing
`rum_p0`. **Feel for the keepalive's step:** every 10 s a held rumble is re-uploaded to the pad
(Main's `EVIOCSFF` on the playing effect, then a replay); some drivers may restart the effect with a
brief dip. If it is felt, lengthen `H264RING_RUMBLE_KEEPALIVE_MS` (any value under ~30 s keeps the
dead-program stop) -- a constant, not a design change.

