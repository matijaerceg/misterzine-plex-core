package ui

import (
	"testing"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/ring"
)

type dimPresenter struct {
	Presenter
	level, sets int
	old         bool // a dimmer without brightness support (the ring never is one)
}

func (p *dimPresenter) SetBrightness(level int) { p.level = level; p.sets++ }
func (p *dimPresenter) Brightness() (int, bool) { return p.level, !p.old }

type keyScreen struct{ keys []input.Event }

func (s *keyScreen) Key(ev input.Event, _ time.Time) { s.keys = append(s.keys, ev) }
func (*keyScreen) Draw(*gfx.Canvas, time.Time) bool  { return false }

func dimApp() (*App, *dimPresenter, *keyScreen) {
	out := &dimPresenter{level: ring.Full}
	s := &keyScreen{}
	return &App{Out: out, stack: []Screen{s}}, out, s
}

func TestMenuDimsAfterThreeMinutes(t *testing.T) {
	a, out, s := dimApp()
	t0 := time.Now()
	a.idle(t0, a.menuWaiting())
	a.idle(t0.Add(DimAfter-time.Second), a.menuWaiting())
	if out.level != ring.Full {
		t.Fatal("dimmed early")
	}
	a.idle(t0.Add(DimAfter), a.menuWaiting())
	if out.level != DimLevel || DimLevel != 64 {
		t.Fatalf("not dimmed to a quarter: %d", out.level)
	}
	// OK wakes the screen and does nothing else, release included
	at := t0.Add(DimAfter + time.Second)
	a.key(input.Event{Key: input.Enter}, at)
	a.key(input.Event{Key: input.Enter, Release: true}, at)
	if out.level != ring.Full || len(s.keys) != 0 {
		t.Fatalf("wake: level %d, keys %v", out.level, s.keys)
	}
	a.key(input.Event{Key: input.Enter}, at)
	if len(s.keys) != 1 {
		t.Fatal("the press after the wake was lost")
	}
	// the clock restarted at the press
	a.idle(at.Add(DimAfter-time.Second), a.menuWaiting())
	if out.level != ring.Full {
		t.Fatal("the press did not restart the clock")
	}
}

func TestHeldWakeKeyIsSwallowedUntilReleased(t *testing.T) {
	a, _, s := dimApp()
	t0 := time.Now()
	a.idle(t0, true)
	a.idle(t0.Add(DimAfter), true)
	at := t0.Add(DimAfter)
	for _, ev := range []input.Event{
		{Key: input.Down},
		{Key: input.Down, Repeat: true, Count: 1},
		{Key: input.Down, Repeat: true, Count: 2},
		{Key: input.Down, Release: true, Count: 2},
		{Key: input.Down},
	} {
		a.key(ev, at)
	}
	if len(s.keys) != 1 || s.keys[0].Repeat || s.keys[0].Release {
		t.Fatalf("screen saw %v, want only the second press", s.keys)
	}
	// a keyboard key is matched by its scan code
	a.idle(at.Add(DimAfter), true)
	s.keys = nil
	a.key(input.Event{Keyboard: true, ScanCode: 0x1c, Text: 'a', Key: input.Left}, at)
	a.key(input.Event{Keyboard: true, ScanCode: 0x1c, Key: input.Left, Release: true}, at)
	a.key(input.Event{Keyboard: true, ScanCode: 0x1b, Text: 's', Key: input.Down}, at)
	if len(s.keys) != 1 || s.keys[0].ScanCode != 0x1b {
		t.Fatalf("keyboard wake: screen saw %v", s.keys)
	}
}

func TestBusyHoldsTheClock(t *testing.T) {
	a, out, _ := dimApp()
	t0 := time.Now()
	a.idle(t0, false)
	a.idle(t0.Add(2*time.Hour), false) // a film playing
	a.idle(t0.Add(2*time.Hour+time.Second), true)
	if out.level != ring.Full {
		t.Fatal("dimmed right after playback ended")
	}
	a.idle(t0.Add(2*time.Hour+DimAfter), true) // paused, or back in a menu
	if out.level != DimLevel {
		t.Fatal("not dimmed")
	}
	a.idle(t0.Add(3*time.Hour), false) // playing again
	if out.level != ring.Full {
		t.Fatal("playing while dimmed")
	}
}

func TestNoDimOnOlderCoreOrSignIn(t *testing.T) {
	a, out, s := dimApp()
	out.old = true
	t0 := time.Now()
	a.idle(t0, true)
	a.idle(t0.Add(time.Hour), true)
	a.key(input.Event{Key: input.Enter}, t0.Add(time.Hour))
	if out.sets != 0 || len(s.keys) != 1 {
		t.Fatalf("older core: %d brightness writes, keys %v", out.sets, s.keys)
	}
	a, _, _ = dimApp()
	a.stack = append(a.stack, &Login{})
	if a.menuWaiting() {
		t.Fatal("the sign-in code dims")
	}
	a.stack = a.stack[:1]
	a.Starting = time.Now()
	if a.menuWaiting() {
		t.Fatal("a starting stream dims")
	}
}
