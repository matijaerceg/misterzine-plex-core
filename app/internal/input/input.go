// Package input turns what the core passes on from MiSTer main -- the
// gamepads and the keyboard -- into key events with auto-repeat. MiSTer
// main holds every evdev node exclusively while a core runs, so this is
// the only route to the pad. The H.264 core's input region (region.go) is
// read whole when the source offers it; the two-word Joy/Key source of the
// PlexCRT core is still accepted (the tests and older tools use it).
package input

import (
	"runtime"
	"syscall"
	"time"
)

// Key is a logical control, one bit each in the legacy joystick word
// (LegacyJoy): the d-pad, OK, Back, L, R. L/R jump sections.
type Key int

const (
	Right Key = iota
	Left
	Down
	Up
	Enter // OK
	Back
	JumpBack // L
	JumpFwd  // R
	None
)

var names = [...]string{"right", "left", "down", "up", "enter", "back", "l", "r", "none"}

func (k Key) String() string { return names[k] }

// Special is an event that is not a key: MiSTer's menu and its actions.
// Only PollAll delivers them (Key None); Poll keeps them to itself.
type Special int

const (
	NoSpecial  Special = iota
	MenuOpened         // MiSTer's menu opened: everything held was released
	MenuClosed
	ActionHome  // the menu's "Send Home to the program" (it closes the menu next)
	ActionMenu  // the menu's "Program menu"
	InputLost   // events were lost (more than 32 between two reads): everything released
	MouseButton // the mouse buttons changed: Code is the buttons now
)

// Event is one press (or auto-repeat) of a key, or the release that ends a
// held run (Release set, Count repeats delivered); or a Special.
type Event struct {
	Key      Key
	Keyboard bool // distinguish typing from controller navigation
	ScanCode int  // PS/2 set 2, extended codes have bit 8 set
	Text     rune // printable US-layout character, when present
	Repeat   bool
	Release  bool
	Count    int
	Special  Special
	Code     int // MouseButton: the buttons ([0] L [1] R [2] M); Action*: the action's number
}

// Source is anything exposing the two PlexCRT status words: joystick_1<<16
// | joystick_0 in the legacy layout, and key_cnt<<11 | ps2_key[10:0].
type Source interface {
	Joy() uint32
	Key() uint32
}

const (
	repeatDelay    = 400 * time.Millisecond
	repeatRate     = 140 * time.Millisecond // keep equal to ui.RepeatDur
	pollPeriod     = 16 * time.Millisecond  // the core posts the pad once a field: read it that often
	heldPollPeriod = 4 * time.Millisecond   // while a button is down: the release must land the ms it happens
	backspaceDelay = 250 * time.Millisecond
	backspaceRate  = 45 * time.Millisecond
)

// ps2 set-2 scan codes -> key; extended codes are 0x100|code.
var ps2map = map[int]Key{
	0x175: Up, 0x172: Down, 0x16B: Left, 0x174: Right,
	0x5A: Enter, 0x29: Enter, 0x76: Back, 0x66: Back,
	0x17D: JumpBack, 0x17A: JumpFwd, // PgUp / PgDn
	0x1D: Up, 0x1B: Down, 0x1C: Left, 0x23: Right, // WASD
}

// noTypematic are the keys the region path never repeats itself:
// modifiers, Caps Lock, and Backspace (which has its own cadence).
var noTypematic = map[int]bool{0x12: true, 0x59: true, 0x14: true, 0x114: true, 0x11: true, 0x111: true, 0x58: true, 0x66: true}

// Poll reads the source every few ms and sends key events on the returned
// channel.
func Poll(src Source, stop <-chan struct{}) <-chan Event { return poll(src, stop, false) }

// PollAll is Poll that also delivers the Special events.
func PollAll(src Source, stop <-chan struct{}) <-chan Event { return poll(src, stop, true) }

func poll(src Source, stop <-chan struct{}, specials bool) <-chan Event {
	out := make(chan Event, 64)
	go func() {
		// its own thread, a little above the decoder: a release must not
		// wait for a timeslice while video plays
		runtime.LockOSThread()
		syscall.Setpriority(syscall.PRIO_PROCESS, 0, -5)
		p := newPoller(src, out, specials)
		t := time.NewTicker(pollPeriod)
		defer t.Stop()
		period := pollPeriod
		for {
			var now time.Time
			select {
			case <-stop:
				close(out)
				return
			case now = <-t.C:
			}
			if want := p.step(now); want != period {
				t.Reset(want)
				period = want
			}
		}
	}()
	return out
}

type poller struct {
	src      Source
	region   RegionSource // nil: the legacy two words
	out      chan<- Event
	specials bool
	keyboard *keyboard

	prevJoy   uint32 // the legacy-layout bits last seen (both pads OR'd)
	prevKey   uint32
	held      Key
	heldSince time.Time
	lastRep   time.Time
	reps      int

	backspaceNext time.Time

	// the region path
	in       [RegionWords]uint64
	q        queue
	buf      []uint16
	osd      bool   // MiSTer's menu is open: the pads read as released
	mask     uint32 // pad bits held across the menu, ignored until released
	coreLost uint16
	kbHeld   int // the key the region path repeats (0: none)
	kbNext   time.Time
}

func newPoller(src Source, out chan<- Event, specials bool) *poller {
	p := &poller{src: src, out: out, specials: specials, keyboard: newKeyboard(), held: None, buf: make([]uint16, 0, qLen)}
	if rs, ok := src.(RegionSource); ok {
		p.region = rs
		if rs.InputRegion(&p.in) {
			p.q.next(&p.in, p.buf) // start from now
			p.osd = OSDOpen(&p.in)
			p.coreLost = uint16(p.in[wMisc] >> 48)
			if p.osd {
				p.mask = 0xFF
			}
		}
	} else {
		p.prevKey = src.Key()
	}
	return p
}

func (p *poller) send(ev Event) { Send(p.out, ev) }

// Send puts ev on out, the only sender's, except an auto-repeat while out
// still holds an event: repeats come on the clock, and a stalled reader
// would otherwise get them all after the key is let go. Presses and
// releases always go, in order. False when ev was dropped.
func Send(out chan<- Event, ev Event) bool {
	if ev.Repeat && len(out) > 0 {
		return false
	}
	out <- ev
	return true
}

func (p *poller) special(s Special, code int) {
	if p.specials {
		p.send(Event{Key: None, Special: s, Code: code})
	}
}

// step reads the source once and returns the period to read it at next.
func (p *poller) step(now time.Time) time.Duration {
	var cur uint32
	if p.region != nil {
		cur = p.stepRegion(now)
	} else {
		j := p.src.Joy()
		cur = (j | j>>16) & 0xFF // either pad; d-pad, OK, Back, L, R
	}
	p.pads(cur, now)
	if p.region == nil {
		p.legacyKeys(now)
	}
	if !p.backspaceNext.IsZero() && !now.Before(p.backspaceNext) {
		p.send(Event{Key: Back, Keyboard: true, ScanCode: 0x66, Repeat: true})
		p.backspaceNext = now.Add(backspaceRate)
	}
	if cur != 0 || p.kbHeld != 0 {
		return heldPollPeriod
	}
	return pollPeriod
}

// pads turns the legacy-layout bits into presses, repeats and releases.
func (p *poller) pads(cur uint32, now time.Time) {
	pressed := cur &^ p.prevJoy
	released := p.prevJoy &^ cur
	p.prevJoy = cur
	// OK and Back do not auto-repeat, but holds still need releases.
	for _, k := range []Key{Enter, Back} {
		if released&(1<<k) != 0 {
			p.send(Event{Key: k, Release: true})
		}
	}
	for b := 0; b < 8; b++ {
		if pressed&(1<<b) != 0 {
			k := Key(b)
			p.send(Event{Key: k})
			if k <= Up || k == JumpBack || k == JumpFwd {
				p.held, p.heldSince, p.lastRep, p.reps = k, now, now, 0
			}
		}
	}
	if p.held != None {
		if cur&(1<<p.held) == 0 {
			p.send(Event{Key: p.held, Release: true, Count: p.reps}) // Count 0 for a tap
			p.held = None
		} else if now.Sub(p.heldSince) > repeatDelay && now.Sub(p.lastRep) > repeatRate {
			p.lastRep = now
			if Send(p.out, Event{Key: p.held, Repeat: true, Count: p.reps + 1}) {
				p.reps++
			}
		}
	}
}

// key sends a decoded keyboard word ([9] pressed, [8] E0, [7:0] code),
// with Backspace's own cadence.
func (p *poller) key(word uint32, now time.Time) {
	ev, ok := p.keyboard.decode(word)
	if !ok {
		return
	}
	if ev.ScanCode == 0x66 {
		if ev.Release {
			p.backspaceNext = time.Time{}
		} else if !ev.Repeat {
			p.backspaceNext = now.Add(backspaceDelay)
		}
		// Own the cadence; hardware typematic must not double it.
		if !ev.Repeat {
			p.send(ev)
		}
		return
	}
	p.send(ev)
}

func (p *poller) legacyKeys(now time.Time) {
	kw := p.src.Key()
	if (kw>>11)&0xff != (p.prevKey>>11)&0xff {
		p.prevKey = kw
		p.key(kw, now)
	}
}

// stepRegion reads the region: its events in order, then the pads. It
// returns the pads' legacy-layout bits.
func (p *poller) stepRegion(now time.Time) uint32 {
	if !p.region.InputRegion(&p.in) {
		return p.prevJoy // the core kept writing: this read is skipped
	}
	evs, lost := p.q.next(&p.in, p.buf)
	if cl := uint16(p.in[wMisc] >> 48); cl != p.coreLost {
		lost += uint32(cl - p.coreLost)
		p.coreLost = cl
	}
	if lost > 0 {
		// launch.md: treat every key and button as released then
		p.releaseKeys(now)
		p.special(InputLost, int(lost))
	}
	for _, e := range evs {
		switch e >> 14 {
		case EvKey:
			p.regionKey(uint32(e)&0x3FF, now)
		case EvMouseBtn:
			p.special(MouseButton, int(e&0xFF))
		case EvOSD:
			if e&1 != 0 {
				// MiSTer sends nothing while its menu is open and does not
				// release what was held: release it all here
				p.osd = true
				p.releaseKeys(now)
				p.special(MenuOpened, 0)
			} else {
				p.osd = false
				p.mask = padsLegacy(&p.in) // still held from before: ignored until let go
				p.special(MenuClosed, 0)
			}
		case EvAction:
			// it arrives before the menu's close; taken even while open
			switch int(e & 0xFF) {
			case ActNumHome:
				p.special(ActionHome, ActNumHome)
			case ActNumMenu:
				p.special(ActionMenu, ActNumMenu)
			}
		}
	}
	if open := OSDOpen(&p.in); open != p.osd && len(evs) == 0 {
		// the event was missed (lost, or before the first read): the bit says
		p.osd = open
		if open {
			p.releaseKeys(now)
		} else {
			p.mask = padsLegacy(&p.in)
		}
	}
	if p.kbHeld != 0 && !now.Before(p.kbNext) {
		p.key(0x200|uint32(p.kbHeld), now) // a repeat: the key is down
		p.kbNext = now.Add(repeatRate)
	}
	if p.osd {
		return 0
	}
	j := padsLegacy(&p.in)
	p.mask &= j
	return j &^ p.mask
}

// regionKey is one key event from the queue.
func (p *poller) regionKey(word uint32, now time.Time) {
	code := int(word & 0x1FF)
	down := word&0x200 != 0
	if !down {
		if !p.keyboard.down[code] {
			return // a release with no press: held across the menu, or NumLock / ScrollLock
		}
		if code == p.kbHeld {
			p.kbHeld = 0
		}
		p.key(word, now)
		return
	}
	if p.keyboard.down[code] {
		return // MiSTer does not repeat: a second make is not a new press
	}
	p.key(word, now)
	if !noTypematic[code] {
		p.kbHeld, p.kbNext = code, now.Add(repeatDelay)
	}
}

// releaseKeys sends a release for every key the keyboard holds and makes
// the pads read released until each button is let go and pressed again.
func (p *poller) releaseKeys(now time.Time) {
	for code, down := range p.keyboard.down {
		if down {
			p.key(uint32(code), now)
		}
	}
	p.kbHeld = 0
	p.backspaceNext = time.Time{}
	p.mask = 0xFF
	p.pads(0, now)
}
