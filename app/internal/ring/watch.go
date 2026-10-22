package ring

import (
	"time"
)

// Watch keeps the overlay on screen and reports in the log what a healthy
// setup never shows, until stop is closed:
//   - the heartbeat still for a second: the user loaded another core or the
//     menu (the words stay in memory, so only the heartbeat tells); and its
//     return, after which a session is opened again and wake is called;
//   - no session open (a fresh core, the menu's Reset): an idle one is
//     opened when the lock is free (see session.go), and wake is called;
//   - words 72-79 written by someone else (the player's session start
//     writes its own descriptor or none): ours is written again;
//   - the raster's size changing (the canvas is centred on it): wake;
//   - MiSTer main shrinking the framebuffer's mode below two pages (it
//     sets its own at every core load): put back, and wake to redraw;
//   - a descriptor the core refused, and MiSTer's menu opening and closing.
func (r *Ring) Watch(logf func(string, ...any), wake func(), stop <-chan struct{}) {
	if wake == nil {
		wake = func() {}
	}
	mode := readMode()
	logf("watch: control block at 0x%x, overlay pages at 0x%x (%d of them), framebuffer mode %q",
		ctrlByte, r.fbPhys, r.npage, mode)
	beat, beatAt := r.Heartbeat(), time.Now()
	gone := false
	st0, _ := r.Status()
	var stolen, lastLate int
	report := time.Now()
	tick := time.NewTicker(50 * time.Millisecond)
	defer tick.Stop()
	for n := 0; ; n++ {
		select {
		case <-stop:
			return
		case <-tick.C:
		}
		// The old control block survives a core change. Stop using it once
		// Main names another core; heartbeat checks also inhibit writes during
		// reconfiguration before Main updates the name. Reading the name here
		// keeps the writers' copy of it fresh.
		if !r.CoreAvailable() {
			name, _ := CoreName()
			logf("watch: core changed to %q; stopping overlay writes", name)
			return
		}
		now := time.Now()
		if b := r.Heartbeat(); b != beat {
			beat, beatAt = b, now
			if gone {
				gone = false
				logf("watch: the core is running again (heartbeat %d)", b)
				r.sessionAt = time.Time{}
			}
		} else if !gone && now.Sub(beatAt) > time.Second {
			gone = true
			logf("watch: the core's heartbeat stopped at %d: another core or the menu is loaded", b)
		}
		if gone {
			continue
		}
		if !r.writesAllowed() {
			continue
		}
		st, ok := r.Status()
		if !ok {
			continue
		}
		if r.syncOutput(st) {
			logf("watch: overlay pages now match the %dx%d output raster", r.ow, r.oh)
			wake()
		}
		if !st.Session() && now.Sub(r.sessionAt) > 2*time.Second {
			err := r.ensureSession()
			switch {
			case err == nil:
				logf("watch: no session was open; opened an idle one so the overlay shows")
				wake()
			case err != errLocked:
				logf("watch: opening an idle session: %v", err)
			}
		}
		if r.reassert() {
			stolen++
		}
		if st.RasterW != st0.RasterW || st.RasterH != st0.RasterH || st.RasterMode != st0.RasterMode {
			logf("watch: the raster is now %dx%d (was %dx%d)", st.RasterW, st.RasterH, st0.RasterW, st0.RasterH)
			wake()
		}
		if st.DisplayWide != st0.DisplayWide {
			logf("watch: display shape is now %s", map[bool]string{true: "16:9", false: "4:3"}[st.DisplayWide])
			wake()
		}
		if st.ARX != st0.ARX || st.ARY != st0.ARY {
			logf("watch: output aspect is now %d:%d", st.ARX, st.ARY)
			wake()
		}
		if st.OvlState == OvlRefused && st0.OvlState != OvlRefused {
			logf("watch: the core refused the overlay descriptor (ovl_err %d)", st.OvlErr)
		}
		if st.OSDOpen() != st0.OSDOpen() {
			logf("watch: MiSTer's menu %s", map[bool]string{true: "opened", false: "closed"}[st.OSDOpen()])
		}
		st0 = st
		if n%10 == 0 {
			if m := readMode(); m != mode {
				if !r.writesAllowed() {
					return
				}
				logf("watch: framebuffer mode changed from %q to %q", mode, m)
				mode = keepMapped(logf, m)
				r.mu.Lock()
				r.bars = [NPage]barFrame{} // a mode write clears the framebuffer
				r.mu.Unlock()
				wake() // and the page is drawn again
			}
		}
		if now.Sub(report) >= 5*time.Second {
			if stolen > 0 {
				logf("watch: in 5 s another program wrote the overlay descriptor %d times; ours was written again", stolen)
			}
			if late := r.AckLate(); late > lastLate {
				logf("watch: in 5 s %d page flips went ahead without the core having read the descriptor", late-lastLate)
				lastLate = late
			}
			stolen, report = 0, now
		}
	}
}
