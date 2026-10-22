# The USB camera / capture viewer (`h264cam`)

Roadmap: "A USB capture / webcam viewer" (proposed 2026-10-06 with the CRT pattern app). A UVC camera
or an HDMI capture dongle plugged into the MiSTer, shown through the core: the MiSTer as a 15 kHz
output for another source. ARM-side only, no RTL: the pictures go through interface 0.15's PICTURE
record (`docs/architecture.md` "Pictures from the program"), as the file player's ARM-decoded codecs do.

**Status (2026-10-06): ✅ MERGED (PR fj#37), ✅ HW-CONFIRMED with the maintainer on .236 (unplug /
replug twice, the picture good on a CRT at 480i: `history.md` §37).** step 1 measured on .201 with a Logitech C270 --
**the gate passes for MJPEG 640x480 at 30 frames/s: CPU0 taken 0.724** (U2's results), after the
library's store copy was made faster for full-range 4:2:2 (U2a). The USB host carries ~6 MB/s of
isochronous video, so uncompressed 640x480 does not stream (U2b). **The viewer (U6) is built**: the
Scripts-menu launcher, the best mode automatically, a mode list, pause, unplug / replug, refusals by
name; its host test GREEN and `--red`; the manual's "Showing a USB camera"; on .201 with the C270
(`history.md` §37), then with the maintainer on .236: plugged and unplugged twice, good on a CRT at 480i.

## U1. The kernel has no V4L2: userspace USB

Measured on .201 (6.18.38-MiSTer): `CONFIG_MEDIA_SUPPORT` is not set -- no V4L2, no `uvcvideo`,
neither built in nor a module. `CONFIG_USB=y`, `CONFIG_USB_DWC2_HOST=y` (the HPS's DWC2 OTG
controller, high speed), usbfs present (`/dev/bus/usb`), `usbfs_memory_mb` 16. So the stream is read
in userspace through **libusb** (usbfs): the UVC class protocol (PROBE / COMMIT, the payload headers)
is the program's.

**Our own UVC layer, not libuvc** (`clients/uvc/src/uvc.c`, ~450 lines). libuvc would do PROBE /
COMMIT and the reassembly, but: it reports none of the ways a frame is lost (U3's counters are the
measurement's point: "frames received" cannot see a torn picture), it keeps 100 transfers in flight on
Linux (a bulk device's 100 x `dwMaxPayloadTransferSize` can pass usbfs's 16 MB), and it delivers
through a thread and a copy of its own. What we need of UVC is small: the VS descriptors (formats,
frames, intervals), PROBE / COMMIT, the alternate setting, the payload header's FID / EOF / ERR.

**libusb** 1.0.29, static, `--disable-udev` (MiSTer Linux has no libudev; libusb scans
`/dev/bus/usb`). Built as a layer on the file player's image (`clients/uvc/docker/`,
`mister-h264-uvc:deps1` FROM `mister-h264-clients:deps3`): FFmpeg is not rebuilt.

**The alternate setting: the smallest that carries the committed `dwMaxPayloadTransferSize`, never
the largest** (as `uvcvideo` does): USB reserves a setting's whole bandwidth on the bus, so a larger one
only takes room from other devices. (First written as "DWC2's weakest case is high-bandwidth
isochronous": U2b measured otherwise -- every setting streams; the limit is the data, ~6 MB/s.)

## U2. Step 1: does it fit one core? (✅ measured 2026-10-06: yes, MJPEG)

The roadmap's gate: whether usbfs and a device's MJPEG at 640x480 / 720x480, 30 frames/s, plus the
store copy, fit **CPU0**. On the MiSTer **Main is pinned to CPU1 and polls** (measured:
`Cpus_allowed_list: 1`; an idle-priority spinner on CPU1 gets ~0.3 % of what CPU0's gets), so
everything a program does shares CPU0 with the kernel's interrupt work -- **DWC2's interrupt is
routed to CPU0 only**.

Known costs (`docs/experiments.md`): MJPEG decode 0.29 of a core at 480p30 (a q 5 source: a camera's
is usually lighter), the store copy ~0.16 (5.3 ms a 720x480 picture; the full-range LUT path may cost
more). Budget ~0.7-0.8 of CPU0 -> **the USB side must cost under ~0.25**.

`h264cam --stage S` separates the costs; each stage adds one to the one before:

| stage | what runs |
|---|---|
| `idle` | nothing: the baseline (Main, the kernel, the USB host's existing interrupts) |
| `capture` | the device streams; frames assembled and discarded (usbfs, libusb, DWC2) |
| `decode` | ... and decoded (MJPEG by libavcodec, one thread; YUY2 repacked to planar 4:2:2) |
| `show` | ... and copied into a store and shown (PICTURE, LOW_LATENCY) |

**The instruments.** Per-thread CPU clocks give decode and copy per frame, and the libusb event
thread's own CPU. **But that is not the whole cost: this kernel does not account interrupt time**
(`/proc/stat`'s irq column stays 0), so the interrupt and URB-completion work done in DWC2's handler
is charged to whatever was interrupted, or nowhere. Hence `--spin`: a `SCHED_IDLE` spinner pinned to
each core counts what is left over; the run's rate against the idle stage's (`--spin-base`) is the
share of CPU0 everything else took, interrupts included. Checked on .201 (2026-10-06, the H264 core
loaded, no device): idle twice 86,536 / 86,551 iterations a second on CPU0 (`taken` 0.000); with a
5 s busy loop pinned to CPU0 inside a 10 s window, `taken` **0.500**. It can say "nothing happened"
and it measures a known load exactly. Also printed: DWC2's interrupt rate (`/proc/interrupts`) --
**~8,000 a second already at idle** (a microframe's: the hub's and keyboard's periodic endpoints keep
DWC2's start-of-frame interrupt on), so a stream's cost is the increment.

Run (on the MiSTer, root; the H264 core loaded for `show`), **pinned to CPU0** with `taskset -c 0`:
unpinned, CFS may move the decode onto CPU1 once it is heavy, sharing Main's core (Main stutters,
and CPU0's spinner under-reads the cost). The spinners pin themselves; **CPU1's is the leak
detector**: anything but its idle rate (~271 a second) means work escaped onto Main's core.

```sh
h264cam --list
taskset -c 0 h264cam --stage idle    --spin --seconds 30            # cpu0's rate: B0, cpu1's: B1
taskset -c 0 h264cam --stage capture --spin-base B0,B1 --seconds 30 --size 640x480 --fps 30
taskset -c 0 h264cam --stage decode  --spin-base B0,B1 --seconds 30 --size 640x480 --fps 30
taskset -c 0 h264cam --stage show    --spin-base B0,B1 --seconds 30 --size 640x480 --fps 30
```

Read the `capture` run's DWC2 interrupt rate first: near the idle 8,000 a second, the isochronous
completions ride the start-of-frame interrupt already on, and the USB cost is mostly URB reaping in
userspace (ours to reduce); well above it, it is per-packet handler work in the kernel, which only the
spinner sees and no userspace change removes. Check the printed `payload` against the alternate
setting chosen (a device committing 0 gets the largest, said so). `--save` writes captured frames for
inspection: **they stay local** (a camera's picture of a room is nobody's fixture; a replay test uses a
synthetic payload stream).

**The devices at hand:**
- **Logitech Brio 100** (046d:094c, on the workstation): USB 2.0, MJPEG and YUY2 up to 1920x1080,
  640x480 among them; **isochronous**, 11 alternate settings up to 3 x 1,020 bytes a microframe
  (high bandwidth). The iso case -- and the common one: most webcams and the cheap MS2109 HDMI
  dongles stream isochronous.
- **Hagibis (MacroSilicon MS2130)** (345f:2130): USB 3.2, MJPEG / YUY2 640x480 to 2560x1440,
  **bulk**. It is the workstation's capture of .236's HDMI (`history.md` §11): not to be moved.

**Gate:** `show` at 640x480 MJPEG 30 frames/s with CPU0 `taken` <= ~0.8, frames `bad` and `replaced`
~0, the device's committed alternate setting recorded. If the USB side alone (`capture`) takes more
than ~0.25 -- e.g. DWC2's iso interrupt work -- the fix is not in userspace, and the app is re-scoped
(a lower rate, bulk devices only) before it is built.

### Results (2026-10-06, .201, a Logitech C270 behind the SuperStation's hubs)

The device: **Logitech C270** (046d:0825), UVC 1.00, MJPEG and YUY2 160x120-1280x960 (no 720x480: 640x480
is its SD 4:3 mode), isochronous. MJPEG 640x480 at 30 commits a 1,280-byte payload: **alt 7, one packet
a microframe** (the smallest that carries it; never a high-bandwidth one). Its JPEGs are **4:2:2 full range**
(`yuvj422p`) and carry an APP segment FFmpeg logs an error for on every frame (harmless; the tool logs
fatal only). **In a dim room it dropped to 12.6 frames/s**: the camera terminal's auto-exposure
priority lets exposure stretch the frame interval; `uvc_fixed_rate()` switches it off (constant 30, a
darker picture), which a viewer wants anyway. Every run `taskset -c 0`, 30-40 s; the idle baseline
CPU0 86,517 a second, CPU1 265 (Main's).

| stage (MJPEG 640x480, 30) | frames/s | bad | per frame | CPU0 taken | DWC2 irq/s |
|---|---|---|---|---|---|
| idle | -- | -- | -- | 0 | 8,013 |
| capture | 30.06 | 0 | -- | **0.197** (USB thread 0.094) | 11,444 |
| decode | 30.28 | 0 | decode 11.8 ms | 0.537 | 11,246 |
| show, the copy as merged (P7) | 30.02 | 0 | copy + write 14.3 ms | **0.888** ✗ | 11,007 |
| show, U2a's scalar interior | 30.22 | 0 | 11.1 ms | 0.801 | 11,033 |
| **show, U2a's NEON interior** | **29.97** | **0** | **8.15 ms** | **0.724** ✓ | 11,120 |

Every packet arrived (packet errors 0, frames bad 0, fid_no_eof 0) in every MJPEG run; 0.6-2 % of
frames `replaced` (the consumer a little late, the newest taken). CPU1's spinner stayed at its idle rate
(no work leaked onto Main's core). **The USB side costs ~0.2 of CPU0** -- about half in the libusb
thread, half in the kernel's interrupt and URB work that only the spinner sees -- and DWC2's interrupt
rate rises ~3,000 a second over idle (what it is per is not known: ~250 transfers and 30 frames a
second complete, 8,000 packets arrive). It is the same whatever the frame rate (12.6 frames/s cost 0.188): the
microframes' packets, not the frames, are the work. The decode of a 4:2:2 camera JPEG (11.3-11.8 ms) is
heavier than `experiments.md`'s 4:2:0 file. **Left on CPU0 for the app's UI, the overlay and audio:
~0.28 of what the idle run left over** (the spinner's share, not of a whole core: the idle baseline
already carries Main's and the kernel's own work on CPU0).

### U2a. The store copy for full range and 4:2:2 (`hps/lib/h264ring.c` `put_row`)

The library's copy took **14.3 ms** a 640x480 full-range 4:2:2 picture, against the 5.3 ms of a
limited 4:2:0 720x480 (`experiments.md`): the general loop clamped every sample's index to the row and
looked each up in a table. Into cached memory on the A9 (a throwaway bench): 1.48 ms limited 4:2:0
(the `memcpy` path), 4.13 full 4:2:0, 3.40 limited 4:2:2, **6.00 full 4:2:2** -- the strongly-ordered
stores add ~4.75 ms whatever the format. Now: the words wholly inside the source row take a loop per
case with no clamp; the range table replaced by its arithmetic, `16 + x / 255` with `x = m v + 127`
and `x / 255 == (x + 1 + (x >> 8)) >> 8` -- exact for every `v` (checked), and it fits a 16-bit lane;
on the ARM the interior is NEON (`vrhadd_u8` is the average's `(a + b + 1) >> 1` exactly, `vmlal_u8`
and `vshrn` the conversion), elsewhere scalar. Into cached memory: 1.61 / 2.10 / 1.82 / **2.56 ms**;
in the camera's show stage 14.3 -> 11.1 (the scalar interior alone) -> **8.15 ms**. Same bytes on every
path:
- the host tests score the scalar path against `tools/tests/test_hps_lib.py`'s model (four formats,
  frames and pairs, odd widths); `tools/tests/red_h264.py` gained four mutations of it (one sample
  unconverted, one row not averaged, x / 256 for x / 255, the interior past the source's end), each
  caught;
- **the NEON path no host test runs**: `hps/tests/run_copy_arm.sh [--red]` builds `copy_equiv.c` against
  the ARM library twice (NEON, `-DH264RING_NO_NEON`), runs both on the rig and diffs a hash per case
  (896: four formats, frames and pairs, 14 widths, 8 heights, random bytes, unaligned rows); a control
  checks the NEON build holds a `vrhadd`. GREEN; `--red` catches three NEON mutations (a truncating
  average, the division's +1, the rounding's 127) by 226-383 cases each.

Not an interface change (the same bytes, the same calls); the file player's MJPEG and every
full-range or 4:2:2 picture gain the same.

### U2b. The USB host's limit: ~6 MB/s of isochronous video (the data, not the setting)

First seen as "uncompressed YUY2 does not work": YUY2 640x480 at 30 (18.4 MB/s) commits a 3,060-byte
payload, alt 11 -- three 1,020-byte packets a microframe -- and on .201 lost **every frame** (8,720
packet errors in 30 s; the assembler dropped them whole, nothing torn reached the screen). That was
first read as "DWC2 does not carry high-bandwidth isochronous". **Wrong, and measured so** (2026-10-06,
`h264cam --alt N` forces a setting): the MJPEG 640x480 run above was itself high-bandwidth (C270 alt 7
is **2 x 640**), and light MJPEG (0.5 MB/s) streamed with **0 errors on every setting, alt 11's 3 x
1,020 included**. The C270 commits 3,060 bytes for every YUY2 mode, so YUY2's rate is set by size and
frame rate alone -- the sweep:

| YUY2 | alt | the data | frames | packet errors (10 s) |
|---|---|---|---|---|
| 640x480 at 5 | 6 (944) | 3.1 MB/s | all | 0 |
| 320x240 at 30 | 8 (2 x 800) | 4.6 MB/s | all | 0 |
| 352x288 at 30 | 9 (2 x 992) | 6.0 MB/s | all | 0 |
| 640x480 at 10 | 9 (2 x 992) | 6.1 MB/s | 1 lost | 3 |
| 640x480 at 15 / 544x288 at 30 | 11 (3 x 1,020) | 9.2 / 9.4 MB/s | 26 / 47 % | 1,842 / 2,314 |
| 640x480 at 20-30, 640x360, 800x448, 864x480, 800x600 | 11 | 12-18 MB/s | none | 2,200-5,300 |

**DWC2 here sustains ~6 MB/s of isochronous video; past it, packets are lost and frames with them.**
Not isolated (the cause, not the limit): DWC2's per-transaction interrupt work at a full microframe,
the SuperStation's two 7-port hubs (a root port was not tried). What follows for the viewer: **MJPEG
always** (0.5-3 MB/s), **uncompressed only up to 6 MB/s** (`UVC_MAX_RAW_BPS`, by arithmetic: 320x240
at 30, 352x288 at 30, 640x480 at 5). A capture dongle that sends only YUY2 at SD will show only its
small modes; a bulk one (the MS2130 class) is a separate case, not measured.

## U3. The assembler and its host test

Payloads to frames (`uvc_asm_*` in `uvc.c`, pure, no libusb): a frame ends at EOF or at the FID
toggling (counted `fid_no_eof`: accepted if whole); dropped whole for the device's error bit, a
packet error inside it, an overflow past `dwMaxVideoFrameBufferSize`, or a wrong shape (MJPEG without
SOI ... EOI -- a stream joined mid-frame, a lost first packet --, YUY2 not width x height x 2); data
after EOF before the toggle is a stray, never the next frame's start. Three buffers: the newest
complete frame waits for the consumer, an untaken one is replaced (counted: a camera, not a file --
lowest latency wins), the one the consumer holds is never written.

`clients/uvc/tests/run_test.sh [--red]`: nine arms (A1-A9) over synthetic payload streams, GREEN; `--red`
proves eight mutations of `uvc.c` each caught by its own arm (M4, an overflow delivered truncated,
first survived because the shape check also dropped the truncated frame: A5's frame now ends in EOI
before the cut, so only the overflow check can drop it).

## U4. Decisions so far, and the open ones

Taken in the tool (the maintainer may overrule any):
- **LOW_LATENCY, no PTS**: the camera's clock is not ours; each picture is shown as it arrives
  (`architecture.md` "Low latency"). The rate given to the record is the committed interval's
  (10,000,000 / interval), so Refresh Rate Auto follows the device.
- **The newest frame wins** at every step: the assembler's three buffers, and a frame with no free
  store (`h264ring_picture_acquire` -EAGAIN) or a full ring is dropped, counted. An acquired store
  left unwritten stays the program's and is simply reused later (the library's store rule).
- **MJPEG first; YUY2 through a repack in the app** (to planar 4:2:2, then the library's copy), no new
  `H264RING_PIX_` format: no interface change.
- Square pixels (SAR 0:0) for now; a capture dongle's 720x480 from a 4:3 / 16:9 source needs an aspect
  option (open).

- **MJPEG first; uncompressed only up to 6 MB/s** (U2b): a mode past it is never offered.
- **Constant frame rate** (`uvc_fixed_rate`, the camera terminal's AE priority off) where the device
  has the control.

Open (for the app, after U2):
- **SD only**, as P7 (<= 720x576, <= 30 frames/s), unless U2 shows room.
- **Audio**: a capture dongle's UAC interface (isochronous PCM) is the natural pairing; out of v1 --
  a second isochronous stream on DWC2 is its own measurement.
- **The launcher and UI**: a Scripts-menu entry like the player's; the device and mode chosen on the
  overlay, or the best SD mode automatically.
- **U5. Frame-based H.264** (`VS_FORMAT_FRAME_BASED`, listed by `--list`): a device that sends H.264
  could feed the core's own decoder (no ARM decode at all). Few current devices do; most such streams
  are Baseline / CAVLC (the library's rewrite, ~4-5 Mbit/s). Not pursued unless a device turns up.

## U6. The viewer (`h264cam` with no measuring option; `src/cam.c`)

Built 2026-10-06 (merged as PR fj#37). Run from `Scripts/h264cam.sh` (the player's launcher's shape:
detached, its log in `/media/fat/h264cam/h264cam.log`, back to the menu when it ends; **pinned to CPU0**
with `taskset`, since Main holds CPU1 -- U2; refuses to start beside the player, Moonlight or Jellyfin).
`h264cam --list / --stage ...` is still the measuring tool (`main.c` dispatches: any option but `--dir`).

**States.** WAIT: a card ("Plug in a USB camera or video capture device"), a device looked for once a
second. LIVE: the picture; A / Start / Space pause (word 34: the core freezes and holds the shown picture,
the ring is not consumed; the viewer takes the frames and lets them go -- it never acquires a store it
will not write), B / I / the OSD's "Program menu" open MENU. MENU: the modes over the live picture
(`ui_list`, the one streaming marked `>`); a choice restarts the device in that mode **in a new stream**
(`core_new_stream`: the picture's size may change), and a mode that fails to start falls back to the one
before. REFUSED: a card naming the device and why; the device is not tried again until it has gone
(`uvc_open` fails once). Back + Start / Q / Esc quit from every state. The screensaver (P5's 5 / 30
minutes) only while no camera shows.

**The mode.** The candidates: MJPEG or YUY2, at most 720 x 576, the fastest rate the mode offers at or
under 30 frames a second (a mode only faster is left out), uncompressed only up to
`UVC_MAX_RAW_BPS` (U2b); best first -- MJPEG before YUY2, then the larger, then the faster. Auto is
the first that starts. The C270: 640x480 MJPEG at 30 (its 752x416 and larger are past 720 wide); its
YUY2 320x240 at 30 (4.6 MB/s) is in the list, 640x480 (18.4) is not.

**Unplugged.** `uvc_take` -EIO (libusb's transfers end NO_DEVICE): the device closed, a pause cleared,
**a flush** (the last picture goes, black, the card), a message; WAIT again. The flush re-arms the
library's store numbering (`h264ring_flush` is a new session: `pic_ok` 1, `pic_base_ok` 0). A frame
that will not decode for 3 s (with decode errors counted) refuses the device.

**What each picture carries.** LOW_LATENCY, no PTS (U4); the rate the device **committed** (a device may
commit another than asked: the fake camera's 320x240 does); square pixels.

**Found on the rig, fixed:** a restart (a mode change) left `uvc_dev`'s `stopping` set, so libusb's
callback resubmitted nothing and the screen stayed black -- `uvc_start` now resets the stream's state (the
measuring tool starts once, so it never met it). A device with no product string (the C270) is named
"USB camera"; the menu's title is "Product (vvvv:pppp)".

**The host test** (`clients/uvc/tests/run_test.sh [--red]`, `test_cam.c`): cam.c against a fake core cut
down from the player's -- a copy, not a shared file; a third user is the moment to move it to
`clients/common/tests/` -- and a fake camera behind `uvc.h`'s device calls: pre-encoded 4:2:2 full-range
JPEGs whose top-left block's brightness is the frame number (so each picture's store names its frame and
shows full range made limited), an uncompressed-only device, a "flaky" one whose best mode fails to start,
plug / unplug from the script. 15 checks (C1-C10, T1-T5) GREEN; `--red` 13 viewer mutations each caught by
its own check, plus the assembler's 8. (C10, the fallback to the next mode, was added after review: the
fake camera had never let a start fail, so the loop that tries the next mode had never run.)
V11 (one store for every picture) first went uncaught: **the library refuses a picture into a store
never acquired** (`-EINVAL`, every write), so the mutation could not happen -- the one that can (the
first acquired store reused: one acquire a stream is all the library checks) is caught by the fake
display's store rule. A wait the script never reached no longer aborts the test before the checks
that need no mark.

**On .201** (`history.md` §37): launched as the Scripts menu does, 640x480 live, the menu over the
picture, 320x240 chosen (after the restart fix), pause held (`paused 1` in the status block), quit back
to the menu -- 725 and 483 pictures shown, 0 waits for a store, 0 undecodable. With the maintainer on .236:
unplug and replug twice, and the picture on a CRT at 480i -- good. **Not yet:** a capture dongle.

## Next step

Merge (`/merge`). Not measured: a bulk capture dongle (MS2130 class), an MJPEG HDMI dongle (MS2109 class), a
root port without the hubs. Open (U4): audio from a capture device (UAC), an aspect option for capture
dongles' 720x480, H.264 cameras (U5).
