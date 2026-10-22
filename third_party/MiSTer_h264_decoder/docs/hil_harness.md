# Hardware-in-the-loop harness

**Status: UMD's stock-Main subset, renamed; untested on this core until Phase 0's
hardware gate.** `tools/mister.py` deploys a build, loads the core, presses keys and pulls
back a screenshot over ssh, so a session can SEE the core instead of asking someone to
test and report. The operating manual is the `hil-testing` skill; this note records what
it relies on.

> Engineering note, not user documentation. The harness needs a repo checkout and ssh to
> your own MiSTer; it is not shipped and has no page in `site/`.

```bash
echo root@<mister-ip> > tools/.mister_host      # gitignored; or $MISTER_HOST
tools/mister.py state
tools/mister.py deploy --rbf releases/H264_scaffold_<date>.rbf
tools/mister.py launch --opt "Aspect Ratio=16:9"     # no image: this core has no file slot
tools/mister.py shot -o <scratch>/bars1.png; sleep 1; tools/mister.py shot -o <scratch>/bars2.png
tools/mister.py restore
```

The Phase 0 gate is that pair of shots: the bars, and the marker in a different place in
the second (`h264/idle_bars.sv` moves it 4 dots a frame).

## Why this needs no change to the core or to Main

Four stock mechanisms, verified on hardware by MiSTer_DVD before any code was written:

| | |
|---|---|
| **`load_core` an `.mgl`** | `/dev/MiSTer_cmd` is a FIFO Main polls; `load_core` accepts a `.mgl`, which loads a core (and can mount media in the same command). |
| **`screenshot`** | The same FIFO writes a PNG of the **core's raw raster**, read from ascal's *input* buffer, so it carries no OSD, no popups, no scaling. A name ending in `.png` is used verbatim under `screenshots/`. |
| **`config/H264_v1.CFG`** | The core's saved settings are a raw 16-byte dump of Main's 128-bit `cur_status`, read at core init before reset is released. Writing it sets any OSD option for the next launch. `mister.py` derives the file name from the `"v,N"` line in `h264/emu.sv`, never a constant. |
| **uinput** | Main enumerates new `/dev/input` devices; a virtual keyboard (`tools/mister_keyd.py`, fed from a FIFO on the target) reaches the core's PS/2 path. Nothing consumes it unless an `h264/kbd_map.sv` exists; `key osd` works from day one. |

## Feeding a stream, reading the status (Phase 3)

The reference feeder and the status tool (`hps/`, `docs/architecture.md` "The HPS
interface, v0.1") run ON the rig; the harness copies them and drives them over ssh:

```bash
USE_DOCKER=1 hps/build_arm.sh                                  # static ARM binaries
tools/p3/make_clips.sh <scratch>/clips                         # synthetic x264 Main clips
tools/mister.py deploy --rbf releases/H264_x.rbf
tools/mister.py deploy --bin --clip <scratch>/clips/film.264   # -> /media/fat/h264hil/
tools/mister.py feed /media/fat/h264hil/film.264               # h264play: loads the core, plays, prints the status
tools/mister.py feed --bg /media/fat/h264hil/p60.264 -- --switch /media/fat/h264hil/switch.264 --at 300
tools/mister.py stat [--count N --watch S]                     # h264stat --json
tools/mister.py restore                                        # also kills a feeder, removes /media/fat/h264hil
```

`feed` passes everything after `--` to `h264play` (harness options go before it: argparse's
REMAINDER once handed `--bg` to `h264play`, which printed its usage -- and the "test"
measured nothing). Clips live on the rig's own storage (local media:
`hw_budget_and_lessons.md` §6).

**The telemetry is the status block** (decided 2026-09-27: D4). `h264stat --json` prints
every field of `tools/ring_layout.py`'s table: the reader's state and error, the front end's
and the reconstruction's counters, the display's pickups / late / starved / skipped and
the judder pair (`disp_dc` vs `fetch_changes`: compare DELTAS, `fetch_changes` is never
reset per stream), ram1's `ddr_probe`. It is readable by any program, needs no Main fork,
and reports a stale core by its heartbeat (`seq_head` standing still).

## Facts that bite (inherited from UMD and MiSTer_DVD, all measured on the same platform)

Kept as UMD wrote them, UMD's names included: they are measurements of the platform,
and several (the DDR3 port hang) explain `sys/` edits this core carries.


- **The OSD is not in a screenshot, and keys do not reach the core while it is open.**
  Options are set by writing the settings file, not by navigating menus.
- **MGL `<rbf>` resolution takes the lexicographically GREATEST match**, not the newest
  file, so the harness deploys under the fixed name `H264_hil.rbf` (UMD's: `UMD_hil.rbf`) and names it exactly.
- **One command per FIFO write.** A second command in the same write is discarded.
- **`screenshots/` is not created on the verbatim path** — `deploy` does the `mkdir -p`.
- **The PNG is written asynchronously** with no temp-and-rename: poll for existence AND a
  stable size (`shot` does).
- **The MiSTer has no `pkill` and no `killall`.** `kill_exact()` walks `/proc`.
- **Main is started from `/etc/inittab` with `&`; nothing respawns it.** Killing it needs a
  reboot.
- **`launch` overwrites the user's saved settings.** It backs them up once; `restore` puts
  them back. Never leave a session without `restore`. When there was no file, a
  `.hilnew` marker says the harness created it and `restore` deletes it (before this
  fix, found at the H264 P0 gate, a second launch backed up the first launch's file as
  the user's and `restore` left it behind; UMD's harness still has that gap).
- **Deleting the harness `.rbf` does not unload it.** `restore` now returns to the menu
  core when (and only when) `/tmp/CORENAME` is `UMD` -- found at the P2 gate, where the
  rig stayed on the UMD core after a restore.
- **Images can live on the rig's network share** (a CIFS mount under `/media/fat/cifs/`,
  read-write), which avoids the nearly full card entirely; `launch` takes that path.
- **The rig is the maintainer's.** Check `state` first; a disturbed run of theirs is void,
  not salvageable. **It is also shared with the sibling project's sessions** (2026-09-27,
  P5g): another core loaded at `state` may be a test in progress on the same
  workstation. A UMD load voided a DVD step and was itself overwritten a minute later.
  Find who drives it and agree an order before loading.
- **`/tmp/umd_telem.json` goes stale when another core loads**: the HIL Main that writes
  it is no longer running, so the last values stay on disk. A waiter that reads frozen
  counters as a stalled decode is wrong about which machine it is measuring. Check that
  `t` advances (and `/tmp/CORENAME`) before believing any count.
- **A target-side screenshot burst resolves ~1 s per frame.** For a defect that is a FLASH
  the instrument is a burst sequenced on the target; for one that HOLDS a settled shot is
  enough.
- **HIL latency is part of the instrument.** ssh-paced key presses cannot test a timing
  window under ~3 s; sequence them on the target.
- **Run the OLD build through the same script as the control arm** when a defect is
  intermittent, and change ONE thing per hardware round.
- **Ask "is the PICTURE frozen or is the MACHINE frozen?"** — it separates an HPS-side
  stall from a core-side one before any code is read.
- **An HPS DDR3 port can hang, and it survives loading another bitstream** (2026-09-26,
  P5e gate). Loading Akira over a playing X-Men 2 left every later launch stuck at the
  same place: 8 packs read (`PACKS/S 0`), the decoder's first picture done (`MB 0546`),
  nothing more, `STALL` climbing, no error -- the decoder waiting on its write-back to
  ram1 -- and the PREVIOUS build, which had played Akira that morning, froze identically.
  A reboot cured it; the same launch then played clean. Signature to recognise: a
  freeze at a fixed early point that follows the rig, not the build (the control arm
  shows it). Suspected trigger: an FPGA reload while the core's f2sdram ports carry
  traffic (MiSTer_DVD's bring-up saw the same accept-a-few-then-BUSY hang). The harness
  should stop the core's DDR3 traffic before loading another image; until then, a
  reboot (the maintainer's call) clears it. The `CRC ... 0` on such a screen is a
  PARTIAL checksum (the trailing 0 = incomplete), not evidence of corrupt data.
  **Measured with the telemetry (2026-09-26):** loading a title over a playing one hung
  3 times in 24 reloads (12.5 %); every hang the same -- ram1 accepted the new core's
  writes (~43 k beats) and 24 read beats, returned NONE (`d1_rdb` 0), and held BUSY for
  good (`d1_busy` = `d1_busy_max` = 0xFFFF). With the core held in its OSD reset for 1 s
  before each load: 0 in 16 -- consistent, not yet decisive (12 % by chance). Suspect,
  unproven: a request WITHDRAWN while the port still asserted waitrequest (Avalon forbids
  it). `ddr_mux2`'s abort drops a pending A read / first write beat the cycle it engages,
  the display reader drops a pending read when it resets, and sys `f2sdram_safe_terminator`
  only protects a request still asserted on the cycle it locks -- a two-flop race with the
  core's own reset. The framework's own note: a transaction cut mid-way leaves the f2sdram
  port broken until the SDRAM controller is reset, i.e. a reboot.
  **Fix (`fix/ddr-reload-hang`, 2026-09-26):** simulation now proves the withdrawal:
  `bench/umd/ddr_model.sv` (and the cosim's C++ copy) fail `[avalon]` when a request held
  under waitrequest is withdrawn or changed, and `ddr_mux2_tb`'s aborts 3 and 4 (a read
  and a first write beat caught under waitrequest) fail it on the old mux. Two changes:
  1. `umd/ddr_mux2.sv` HOLDS a request the port has not accepted: if master A withdraws
     it (its reset, the abort) the mux keeps presenting the held command, unchanged,
     until the port takes it; a held read's beats are then swallowed, a held write
     beat's burst completed masked (`run_disp_reader.sh` X7 removes the hold -> `[avalon]`).
  2. In `emu`, every master that drives a port directly -- the mux, its abort register,
     the display reader's fetch side -- resets with the PLL lock ALONE (`mem_lock_n`),
     never with RESET or the mount (`check_emu_wiring.py`, scaffold W7, W30-W32). On
     RESET the decoder's master is aborted and drained, the reader finishes its line
     and idles; neither withdraws anything.
  **Rig round (`UMD_reloadfix_20260926_2309.rbf`): NOT FIXED -- 2 hangs in 40 reloads**
  (the old build 5 in 40; Fisher p ~ 0.4, no evidence of a change). Both hangs carry the
  old signature exactly: Akira stopped at `packs=8 pics=2 mbs=5 d1_wr=337` -- the new
  core's writes accepted, its FIRST ram1 read never returned. So the port's read side is
  broken before the new core's first read; the withdrawal was real (the bench proves it)
  but is not what breaks the port. Main's load (`fpga_io.cpp fpga_load_rbf`): core reset
  (the terminators lock), read the rbf, `do_bridge(0)` (`fpgaportrst` 0, bridges reset),
  program, `do_bridge(1)` (`fpgaportrst` 0x3FFF): the old core has ~100 ms under the
  terminator before the fabric goes.
  **The cause, reproduced in simulation (2026-09-26):** `bench/umd/f2sdram_term_tb.sv` puts
  sys's `f2sdram_safe_terminator` (every core's last stage before the port) between a
  dpb_mem-shaped master and `ddr_model` and locks it mid-traffic. The STOCK terminator
  leaves the port beats short of a write burst ([owed], at the first aimed lock). Its
  write tracker counts a beat on every cycle a burst is open and waitrequest is low --
  no `write` term -- and ends a burst on the count alone. `dpb_mem` drops `write`
  between the beats of EVERY burst while it fetches the next one (legal Avalon), so the
  tracker is out of step on most bursts; when Main's core-load reset locks it inside a
  burst it completes the wrong number of beats and the port waits for the rest forever:
  the next core's writes are swallowed into the old burst and its first read never
  returns -- the rig's signature exactly. A quiesced load has no burst open at the lock,
  hence 0 in 16. (Even contiguous bursts desync it when the last beat meets waitrequest;
  rarer.) Fix: `sys/f2sdram_safe_terminator.sv` as a `UMD-FORK` that counts the beats
  the port ACCEPTS; `run_f2sdram_term.sh --red` (K0 = the stock module, caught).
  **Rig (`UMD_reloadfix_20260926_2349.rbf`): 0 hangs in 60 reloads** (Akira and Family
  Guy alternating, each loaded over the other playing), against 7 in 80 on every build
  without the fork (P(0 in 60) at 7/80 = 0.4 %). ✅ Fixed. The harness no longer needs
  to quiesce the core before a load.

## Not carried (decided 2026-09-27)

- **UMD's EXT_BUS telemetry and HIL Main** (`umd_telem.sv`, the `main/` Main fork,
  `mister.py telem / osd / deploy --main`): replaced by the HPS interface's status block
  (above), which any program reads without a Main fork. UMD's `ddr_probe.sv` came over
  (ram1's words in the status block). What the status block does not give: a rate fit at
  4 Hz (`mister.py stat --count N --watch S` samples; fit offline if a rate is needed), and
  a live OSD channel (settings go through `launch --opt`, as before).
- The HUD decoder, the capture card and the navigation oracle diff (UMD's "not here yet"
  list). The capture-card lesson worth keeping: **a sampled capture measures OFFSETS, not
  RATES** -- relevant the day A/V sync is measured (Phase 4).

## Seeing the aspect: `shot --scaled` (2026-09-26)

A plain `shot` is the core's raw 720x480 raster (ascal's input), where the aspect the
core reports (`VIDEO_ARX/ARY`) is invisible. `shot --scaled` sends Main's `screenshot
scaled`: the scaler's output, cropped to the active picture, so the image's WIDTH is the
measurement -- on a 1080p output 1440x1080 for 4:3 and 1920x1080 for 16:9. Validated
in UMD (P5b) on Family Guy (VUI `aspect_ratio_idc` 3): Auto 1440x1080 = the forced 4:3 shot,
forced 16:9 1920x1080. ⚠ A 16:9 result alone proves nothing about the VUI path: the
fallback for an unspecified SAR is also 16:9 -- test on a 4:3-declaring disc.

