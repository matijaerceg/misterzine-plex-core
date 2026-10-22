package input

import (
	"sync"
	"testing"
	"time"
)

// regionSource is a canned input region, as the core would write it.
type regionSource struct {
	mu sync.Mutex
	in [RegionWords]uint64
}

func (s *regionSource) InputRegion(dst *[RegionWords]uint64) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	*dst = s.in
	return true
}
func (s *regionSource) Joy() uint32 { return 0 }
func (s *regionSource) Key() uint32 { return 0 }

// push queues events as the core does: entry n%32, ev_count n+1.
func (s *regionSource) push(evs ...uint16) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, e := range evs {
		n := uint32(s.in[0] >> 32)
		slot := n % qLen
		w := &s.in[qWord+slot/4]
		*w = *w&^(0xFFFF<<(16*(slot%4))) | uint64(e)<<(16*(slot%4))
		s.in[0] = uint64(n+1)<<32 | uint64(uint32(s.in[0])+1)
	}
}

func (s *regionSource) pad(n int, buttons uint32) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.in[1+n] = s.in[1+n]&^0xFFFFFFFF | uint64(buttons)
}

func (s *regionSource) osdBit(open bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.in[wMisc] &^= 1 << 40
	if open {
		s.in[wMisc] |= 1 << 40
	}
}

func keyEv(code int, down bool) uint16 {
	e := uint16(code & 0x1FF)
	if down {
		e |= 0x200
	}
	return e
}

func osdEv(open bool) uint16 {
	if open {
		return EvOSD<<14 | 1
	}
	return EvOSD << 14
}

func TestLegacyJoyMapping(t *testing.T) {
	for pad, want := range map[uint32]uint32{
		PadRight: 1 << Right, PadLeft: 1 << Left, PadDown: 1 << Down, PadUp: 1 << Up,
		PadB: 1 << Enter, PadA: 1 << Back, PadLB: 1 << JumpBack, PadRB: 1 << JumpFwd,
		PadX | PadY | PadStart | PadBack | PadLT | PadRT | PadLS | PadRS: 0,
		PadB | PadUp: 1<<Enter | 1<<Up,
	} {
		if got := LegacyJoy(pad); got != want {
			t.Errorf("LegacyJoy(%04x) = %02x, want %02x", pad, got, want)
		}
	}
	var in [RegionWords]uint64
	up, right := int8(-120), int8(5)
	in[3] = uint64(uint16(uint8(up))<<8|uint16(uint8(right)))<<32 | PadA // pad 2: A (Back), stick up
	if got := padsLegacy(&in); got != 1<<Back|1<<Up {
		t.Fatalf("pads %02x", got)
	}
	in[3] = uint64(uint16(uint8(int8(60)))) << 32 // a stick resting off-centre is no press
	if got := padsLegacy(&in); got != 0 {
		t.Fatalf("drift %02x", got)
	}
}

func TestQueueDecodingAndLostEvents(t *testing.T) {
	s := &regionSource{}
	s.push(keyEv(0x1c, true)) // before the reader started: not its
	var q queue
	var in [RegionWords]uint64
	buf := make([]uint16, 0, qLen)
	s.InputRegion(&in)
	if evs, lost := q.next(&in, buf); len(evs) != 0 || lost != 0 {
		t.Fatal("events from before the first read", evs)
	}
	s.push(keyEv(0x1c, false), osdEv(true), EvAction<<14|1, osdEv(false), EvMouseBtn<<14|5)
	s.InputRegion(&in)
	evs, lost := q.next(&in, buf)
	want := []uint16{keyEv(0x1c, false), osdEv(true), EvAction<<14 | 1, osdEv(false), EvMouseBtn<<14 | 5}
	if lost != 0 || len(evs) != len(want) {
		t.Fatalf("got %x lost %d", evs, lost)
	}
	for i := range want {
		if evs[i] != want[i] {
			t.Fatalf("event %d = %x, want %x", i, evs[i], want[i])
		}
	}
	// 40 events between two reads: the oldest 8 were overwritten
	for i := 0; i < 40; i++ {
		s.push(keyEv(i, true))
	}
	s.InputRegion(&in)
	evs, lost = q.next(&in, buf)
	if lost != 8 || len(evs) != 32 || evs[0] != keyEv(8, true) || evs[31] != keyEv(39, true) {
		t.Fatalf("lost %d, %d events, first %x last %x", lost, len(evs), evs[0], evs[len(evs)-1])
	}
	// the count wraps at 2^32
	s.mu.Lock()
	s.in[0] = uint64(0xFFFFFFFF) << 32
	s.mu.Unlock()
	q.count = 0xFFFFFFFF
	s.push(keyEv(0x5a, true), keyEv(0x5a, false))
	s.InputRegion(&in)
	if evs, lost = q.next(&in, buf); lost != 0 || len(evs) != 2 || evs[0] != keyEv(0x5a, true) {
		t.Fatalf("across the wrap: %x lost %d", evs, lost)
	}
	// a reloaded core counts from 0 again: start over, nothing replayed
	s.mu.Lock()
	s.in[0] = 3 << 32
	q.count = 1000
	s.mu.Unlock()
	s.InputRegion(&in)
	if evs, lost = q.next(&in, buf); len(evs) != 0 || lost != 0 || q.count != 3 {
		t.Fatalf("after a reload: %x lost %d count %d", evs, lost, q.count)
	}
	if k := LastKey(&in); k>>11 != 3 {
		t.Fatalf("LastKey %x", k)
	}
}

func collect(t *testing.T, ch <-chan Event, n int) []Event {
	t.Helper()
	var got []Event
	for len(got) < n {
		select {
		case e := <-ch:
			got = append(got, e)
		case <-time.After(time.Second):
			t.Fatalf("got %d events of %d: %+v", len(got), n, got)
		}
	}
	return got
}

func quiet(t *testing.T, ch <-chan Event, d time.Duration) {
	t.Helper()
	select {
	case e := <-ch:
		t.Fatalf("unexpected %+v", e)
	case <-time.After(d):
	}
}

func TestRegionPadsKeysAndTheMenu(t *testing.T) {
	s := &regionSource{}
	stop := make(chan struct{})
	defer close(stop)
	events := PollAll(s, stop)
	time.Sleep(20 * time.Millisecond)

	s.pad(1, PadB) // pad 1 navigates too
	if e := collect(t, events, 1)[0]; e.Key != Enter || e.Release {
		t.Fatal(e)
	}
	s.pad(1, 0)
	if e := collect(t, events, 1)[0]; e.Key != Enter || !e.Release {
		t.Fatal(e)
	}

	// a key held as MiSTer's menu opens is released here; the pads read
	// released while it is open; the menu's actions come through
	s.push(keyEv(0x175, true)) // up arrow
	if e := collect(t, events, 1)[0]; e.Key != Up || !e.Keyboard || e.Release {
		t.Fatal(e)
	}
	s.pad(0, PadDown)
	if e := collect(t, events, 1)[0]; e.Key != Down || e.Release {
		t.Fatal(e)
	}
	s.push(osdEv(true))
	s.osdBit(true)
	got := collect(t, events, 3)
	var upRel, downRel, opened bool
	for _, e := range got {
		upRel = upRel || e.Key == Up && e.Keyboard && e.Release
		downRel = downRel || e.Key == Down && !e.Keyboard && e.Release
		opened = opened || e.Special == MenuOpened
	}
	if !upRel || !downRel || !opened {
		t.Fatalf("menu open: %+v", got)
	}
	s.push(EvAction<<14 | ActNumHome)
	if e := collect(t, events, 1)[0]; e.Special != ActionHome || e.Key != None {
		t.Fatal(e)
	}
	s.push(osdEv(false))
	s.osdBit(false)
	if e := collect(t, events, 1)[0]; e.Special != MenuClosed {
		t.Fatal(e)
	}
	// down is still held from before the menu: ignored until let go; the
	// arrow's release arrives with no press and is ignored too
	s.push(keyEv(0x175, false))
	quiet(t, events, 60*time.Millisecond)
	s.pad(0, 0)
	quiet(t, events, 40*time.Millisecond)
	s.pad(0, PadDown)
	if e := collect(t, events, 1)[0]; e.Key != Down || e.Release {
		t.Fatal(e)
	}
	s.pad(0, 0)
	if e := collect(t, events, 1)[0]; e.Key != Down || !e.Release {
		t.Fatal(e)
	}
}

func TestPollKeepsSpecialsToItself(t *testing.T) {
	s := &regionSource{}
	stop := make(chan struct{})
	defer close(stop)
	events := Poll(s, stop)
	time.Sleep(20 * time.Millisecond)
	s.push(osdEv(true), EvAction<<14|ActNumMenu, osdEv(false), EvMouseBtn<<14|1)
	quiet(t, events, 60*time.Millisecond)
	s.push(keyEv(0x5a, true))
	if e := collect(t, events, 1)[0]; e.Key != Enter || !e.Keyboard {
		t.Fatal(e)
	}
}

func TestLostEventsReleaseEverything(t *testing.T) {
	s := &regionSource{}
	stop := make(chan struct{})
	defer close(stop)
	events := PollAll(s, stop)
	time.Sleep(20 * time.Millisecond)
	s.push(keyEv(0x1c, true)) // 'a' held
	if e := collect(t, events, 1)[0]; e.Text != 'a' || e.Release {
		t.Fatal(e)
	}
	// 33 events in one go (shift taps: no events of their own)
	evs := make([]uint16, 0, 34)
	for i := 0; i < 17; i++ {
		evs = append(evs, keyEv(0x12, true), keyEv(0x12, false))
	}
	s.push(evs...)
	got := collect(t, events, 2)
	var rel, lost bool
	for _, e := range got {
		rel = rel || e.Text == 'a' && e.Release
		lost = lost || e.Special == InputLost && e.Code == 2
	}
	if !rel || !lost {
		t.Fatalf("%+v", got)
	}
}

func TestRegionKeyboardRepeatsItself(t *testing.T) {
	s := &regionSource{}
	stop := make(chan struct{})
	defer close(stop)
	events := Poll(s, stop)
	time.Sleep(20 * time.Millisecond)
	s.push(keyEv(0x172, true)) // down arrow: MiSTer sends no typematic
	start := time.Now()
	if e := collect(t, events, 1)[0]; e.Key != Down || e.Repeat {
		t.Fatal(e)
	}
	if e := collect(t, events, 1)[0]; e.Key != Down || !e.Repeat {
		t.Fatal(e)
	}
	if el := time.Since(start); el < repeatDelay-20*time.Millisecond || el > repeatDelay+100*time.Millisecond {
		t.Fatal("first repeat after", el)
	}
	s.push(keyEv(0x172, false))
	for {
		e := collect(t, events, 1)[0]
		if e.Release {
			break
		}
		if !e.Repeat {
			t.Fatal(e)
		}
	}
	quiet(t, events, 200*time.Millisecond)
}
