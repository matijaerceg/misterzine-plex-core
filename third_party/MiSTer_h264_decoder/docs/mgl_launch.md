# MGL launch

Engineering note. The user-facing page is `site/content/getting-started/loading.md`.

An MGL is MiSTer's shortcut: a small XML file that loads a core (and, for a core with a
file slot, mounts a file into it). This core has no file slot, so its MGL is just:

```xml
<mistergamedescription>
  <rbf>_Other/H264</rbf>
</mistergamedescription>
```

`<rbf>` resolves to the lexicographically greatest `H264*.rbf` in `_Other/` (not the
newest). **An HPS program loads the core this way** -- write the MGL, then
`load_core <path>.mgl` into `/dev/MiSTer_cmd`, one command per write -- and then waits for
the control block's magic before feeding it (`architecture.md` "The HPS interface",
decision D4).

## What MiSTer_DVD and UMD learned, and this core inherits

1. **A running MGL owns the whole UI.** While `mgl->done == 0`, Main never calls
   `menu_key_get()`, and the MGL's only forward edge requires `menustate == MENU_NONE2`.
   Anything that raises `Info`/`InfoMessage` from a poll tick during that window freezes
   the launch with no timeout. This core has no Main-side code, so it cannot trip this —
   the rule matters the day it grows one.
2. **A mount with no media is not a mount** (for the day a file slot exists, decision
   D3). Main sends `UIO_SET_SDSTAT` even when the open failed, with size 0, and `hps_io`
   raises `img_mounted` for it — which is also how an EJECT arrives. Gate on
   `img_size != 0`; UMD's `emu.sv` shows the pattern.
3. **The virtual OSD button is a pulse, gated on `~status[0]`.** A held button of ≥ 3 s
   means "enter Bluetooth pairing". This core does not pop the OSD (nothing to pick);
   UMD's `emu.sv` has the 0.9 s wait-then-100 ms-pulse if it ever should.
4. **The `boot.rom` trap.** A `boot.rom` transfer re-enters `HandleUI()` before the MGL
   timer is armed, and `CheckTimer(0)` reads as expired, consuming the `delay`. This core
   ships no `boot.rom`.
5. **A core load resets the old core, then drops the HPS bridges** (`fpga_io.cpp
   fpga_load_rbf`). An HPS program must stop writing the ring before it loads another
   core, and must re-check the magic after any load: the region's contents are not
   defined across a load.
