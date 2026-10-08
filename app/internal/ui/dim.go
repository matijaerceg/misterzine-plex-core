package ui

import (
	"time"

	"plexcrt/internal/input"
	"plexcrt/internal/ring"
)

// The screen goes down to a quarter once nothing has been pressed for
// DimAfter while it only waits (a menu, or a paused playback), so a still
// picture does not wear a CRT or an OLED. The core does the dimming, so
// the picture, the overlay and the sprites all go down together, and it
// cuts back at the first press.
const (
	DimAfter = 3 * time.Minute
	DimLevel = ring.Full / 4
)

// dimmer is a presenter whose output can be dimmed: the ring, on a core
// that reports the brightness it uses.
type dimmer interface {
	SetBrightness(level int)
	Brightness() (level int, supported bool)
}

// idleDim is the app's dimming state; the render thread owns it.
type idleDim struct {
	last   time.Time   // the last button event, or when waiting began
	on     bool        // the screen is dimmed
	wokeBy input.Event // the press that woke it, while its repeats and release are due
	woken  bool
}

// wake notes a button event. While the screen is dimmed an event only
// brings it back: the press that did, its repeats and its release do
// nothing else, so OK on a poster cannot start a film. True when the event
// was used up.
func (a *App) wake(ev input.Event, now time.Time) bool {
	d := &a.dim
	d.last = now
	if d.woken {
		if sameButton(ev, d.wokeBy) && (ev.Repeat || ev.Release) {
			d.woken = !ev.Release
			return true
		}
		d.woken = false
	}
	if !d.on {
		return false
	}
	a.setDimmed(false)
	if !ev.Repeat && !ev.Release {
		d.wokeBy, d.woken = ev, true
	}
	return true
}

func sameButton(a, b input.Event) bool {
	if a.Keyboard || b.Keyboard {
		return a.Keyboard && b.Keyboard && a.ScanCode == b.ScanCode
	}
	return a.Key == b.Key
}

// idle dims the screen once it has been waiting DimAfter since the last
// press. Anything that is not waiting (playing, a stream starting, the
// sign-in code) holds the clock at now and brings the screen back.
func (a *App) idle(now time.Time, waiting bool) {
	d := &a.dim
	if !waiting || d.last.IsZero() {
		d.last = now
		a.setDimmed(false)
		return
	}
	if a.premiumIdle(now, waiting, now.Sub(d.last)) {
		return // an extra has the screen (a screensaver): no dimming over it
	}
	if !d.on && now.Sub(d.last) >= DimAfter {
		a.setDimmed(true)
	}
}

// menuWaiting reports whether the menus are only waiting for a press.
func (a *App) menuWaiting() bool {
	if !a.Starting.IsZero() || len(a.stack) == 0 {
		return false
	}
	_, signIn := a.top().(*Login) // the code is read from across the room
	return !signIn
}

func (a *App) setDimmed(on bool) {
	if a.dim.on == on {
		return
	}
	out, ok := a.Out.(dimmer)
	if !ok {
		return
	}
	if _, supported := out.Brightness(); on && !supported {
		return // an older core would eat the waking press for nothing
	}
	a.dim.on = on
	level := ring.Full
	if on {
		level = DimLevel
	}
	out.SetBrightness(level)
	if a.Log != nil {
		if on {
			a.Log.Printf("screen dimmed after %s without a press", DimAfter)
		} else {
			a.Log.Printf("screen back to full brightness")
		}
	}
}
