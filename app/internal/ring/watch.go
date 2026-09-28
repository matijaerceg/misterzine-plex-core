package ring

import (
	"fmt"
	"os"
	"strings"
	"sync/atomic"
	"time"
)

// Watch reports, in the log, the things a healthy ring never shows: the
// header rewritten by someone else, the Linux framebuffer mode changed under
// the app, or the slot the app just published reading back black. It exists
// so that a flickering or black screen on a board we cannot see explains
// itself in one diagnostics report. When the header is found lost, wake is
// called so the app redraws at once: MiSTer main wipes this memory whenever
// the framebuffer mode is written, and a redraw is what brings the picture
// back. A mode that maps less than the ring is put back to 1920x1080, so the
// presenter started for each playback can still map it. Both only while the
// core runs: a short Reboot from the OSD loads the menu with this app still
// up, and main's next mode write then belongs to the menu. Rewriting it would
// clear the top of the menu's wallpaper, which begins 94 KB before the end
// of the memory each mode write clears. It stops when stop is closed.
func (r *Ring) Watch(logf func(string, ...any), wake func(), stop <-chan struct{}) {
	// A running core answers within a field; asked only after a wipe or a
	// mode change, so the wait is rare.
	gone := false
	running := func() bool {
		if r.CoreRunning(100 * time.Millisecond) {
			gone = false
			return true
		}
		if !gone {
			gone = true
			logf("watch: the core has stopped (field counter %d); leaving the framebuffer to MiSTer main", r.Field())
		}
		return false
	}
	mode := readMode()
	logf("watch: framebuffer mode %q, console %s", mode, consoleState())
	if running() {
		mode = keepRingMapped(logf, mode)
	}
	phys, fromDriver := ringPhys()
	source := "as the framebuffer driver reports it"
	if !fromDriver {
		source = "assumed; the driver did not say"
	}
	r.plantCanaries()
	logf("watch: ring at physical 0x%x (%s); memory also mapped by: %s", phys, source,
		listOrNone(mappers("/proc", phys, mapSize, os.Getpid())))
	lastConsole := consoleMode()
	logf("watch: %s", lastConsole)
	var lostHeader, foreign, black, gap, detailed int
	var scanned bool
	var lastSeq uint32
	report := time.Now()
	tick := time.NewTicker(50 * time.Millisecond)
	defer tick.Stop()
	for n := 0; ; n++ {
		select {
		case <-stop:
			return
		case <-tick.C:
		}
		lost := atomic.LoadUint32(&r.hdr[0]) != magic && atomic.LoadUint32(&r.pubSeq) != 0
		header := ""
		if lost {
			header = r.headerWords() // as found, before the redraw replaces it
			lostHeader++
			if running() {
				r.writeBrightness() // a dimmed screen stays dimmed
				if wake != nil {
					wake()
				}
			}
		}
		// Our own publish moves seq between two samples; a stranger's leaves
		// it away from ours across two consecutive samples. Nothing to judge
		// before the app's first publish. Sampled before any slow logging.
		seq := atomic.LoadUint32(&r.hdr[1])
		if ours := atomic.LoadUint32(&r.pubSeq); ours != 0 {
			if seq != ours && seq == lastSeq {
				foreign++
			}
			if r.publishedBlack() {
				black++
			}
		}
		lastSeq = seq
		hit, zeroed, first := r.canaryState()
		if hit > 0 {
			gap++
			r.plantCanaries()
		}
		if (lost || hit > 0) && detailed < 3 {
			detailed++
			what := "the gap below the first slot changed"
			if lost {
				what = "header wiped, found " + header
			}
			logf("watch: %s; canaries %s", what, describeCanaries(hit, zeroed, first))
			if !scanned {
				scanned = true
				logf("watch: at that moment the ring's memory was mapped by: %s",
					listOrNone(mappers("/proc", phys, mapSize, os.Getpid())))
			}
		}
		if n%20 == 0 {
			// The console draws its cursor over the ring's header in text
			// mode. The launcher switches it; this only reports a change.
			if c := consoleMode(); c != lastConsole {
				logf("watch: %s", c)
				lastConsole = c
			}
		}
		if n%10 == 0 {
			if m := readMode(); m != mode {
				logf("watch: framebuffer mode changed from %q to %q", mode, m)
				mode = m
				if running() {
					mode = keepRingMapped(logf, m)
				}
			}
		}
		if time.Since(report) >= 5*time.Second {
			if lostHeader+foreign+black+gap > 0 {
				logf("watch: in 5 s the header was found wiped %d times, published by another writer %d times, the published slot read black %d times, and the gap below the first slot was overwritten %d times",
					lostHeader, foreign, black, gap)
			}
			lostHeader, foreign, black, gap, detailed, scanned = 0, 0, 0, 0, 0, false
			report = time.Now()
		}
	}
}

// keepRingMapped puts back a framebuffer mode that maps less than the ring
// and returns the mode now in place.
func keepRingMapped(logf func(string, ...any), mode string) string {
	from, err := enlargeMode()
	if err != nil {
		logf("watch: framebuffer mode %q maps less than the ring and could not be changed: %v", from, err)
		return mode
	}
	if from == "" {
		return mode
	}
	now := readMode()
	logf("watch: framebuffer mode %q maps less than the ring; set it to %q", from, now)
	return now
}

// publishedBlack samples a handful of pixels of the published slot. Reading
// write-combined memory is slow, so this is a few words, not a frame.
func (r *Ring) publishedBlack() bool {
	slot := atomic.LoadUint32(&r.hdr[2]) % NSlot
	off := slot0 + int(slot)*slotSize
	for _, p := range [...]int{W*40 + 40, W*120 + 360, W*240 + 100, W*240 + 620, W*360 + 360, W*440 + 680} {
		i := off + p*4
		if r.mem[i]|r.mem[i+1]|r.mem[i+2] != 0 {
			return false
		}
	}
	return true
}

func consoleState() string {
	var parts []string
	if b, err := os.ReadFile("/sys/class/graphics/fb0/state"); err == nil {
		parts = append(parts, "fb0 state "+strings.TrimSpace(string(b)))
	}
	entries, _ := os.ReadDir("/sys/class/vtconsole")
	for _, e := range entries {
		if b, err := os.ReadFile("/sys/class/vtconsole/" + e.Name() + "/bind"); err == nil {
			parts = append(parts, fmt.Sprintf("%s bound %s", e.Name(), strings.TrimSpace(string(b))))
		}
	}
	if len(parts) == 0 {
		return "unknown"
	}
	return strings.Join(parts, ", ")
}
