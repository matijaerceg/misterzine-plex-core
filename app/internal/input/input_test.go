package input

import (
	"sync/atomic"
	"testing"
	"time"
)

type testSource struct{ joy, key atomic.Uint32 }

func (s *testSource) Joy() uint32 { return s.joy.Load() }
func (s *testSource) Key() uint32 { return s.key.Load() }
func TestOKReleasesAndKeyboardRepeat(t *testing.T) {
	s := &testSource{}
	stop := make(chan struct{})
	defer close(stop)
	events := Poll(s, stop)
	time.Sleep(10 * time.Millisecond)
	next := func() Event {
		select {
		case e := <-events:
			return e
		case <-time.After(time.Second):
			t.Fatal("missing event")
			return Event{}
		}
	}
	s.joy.Store(1 << Enter)
	if e := next(); e.Key != Enter || e.Release {
		t.Fatal(e)
	}
	s.joy.Store(0)
	if e := next(); e.Key != Enter || !e.Release {
		t.Fatal("missing gamepad OK release", e)
	}
	s.key.Store(1<<11 | 0x200 | 0x5a)
	if e := next(); e.Key != Enter || e.Repeat || e.Release {
		t.Fatal(e)
	}
	s.key.Store(2<<11 | 0x200 | 0x5a)
	if e := next(); !e.Repeat {
		t.Fatal("keyboard repeat was a fresh press", e)
	}
	s.key.Store(3<<11 | 0x5a)
	if e := next(); !e.Release {
		t.Fatal("missing keyboard release", e)
	}
	// Match the RTL packing: {13'd0, key_cnt[7:0], ps2_key[10:0]}.
	// Consecutive events within the same upper 16 bits must all arrive.
	for count := uint32(4); count < 44; count++ {
		pressed := count%2 == 0
		word := (count << 11) | 0x1c
		if pressed {
			word |= 0x200
		}
		s.key.Store(word)
		if e := next(); e.Text != 'a' || e.Release == pressed {
			t.Fatalf("counter %d: %+v", count, e)
		}
	}
	s.key.Store(255<<11 | 0x200 | 0x1c)
	next()
	s.key.Store(0x1c) // event counter wraps at 256
	if e := next(); !e.Release {
		t.Fatal("lost counter wrap", e)
	}
}

// A reader that stalls while a key is held gets at most the one repeat
// waiting for it, then the release: the repeats due meanwhile are dropped
// rather than played out after the key is let go.
func TestStalledReaderGetsNoBackedUpRepeats(t *testing.T) {
	s := &testSource{}
	stop := make(chan struct{})
	defer close(stop)
	events := Poll(s, stop)
	time.Sleep(10 * time.Millisecond)
	s.joy.Store(1 << Down)
	select {
	case e := <-events:
		if e.Key != Down || e.Repeat || e.Release {
			t.Fatal(e)
		}
	case <-time.After(time.Second):
		t.Fatal("missing press")
	}
	// held through about six repeats, nothing read
	time.Sleep(repeatDelay + 6*repeatRate)
	s.joy.Store(0)
	time.Sleep(50 * time.Millisecond)
	var got []Event
	for len(events) > 0 {
		got = append(got, <-events)
	}
	if len(got) != 2 || !got[0].Repeat || got[0].Key != Down || !got[1].Release || got[1].Key != Down {
		t.Fatalf("after the stall: %+v, want one repeat then the release", got)
	}
	if got[1].Count != 1 {
		t.Fatalf("the release counts %d repeats, 1 was delivered", got[1].Count)
	}
}

func TestSendDropsOnlyRepeatsBehindAnEvent(t *testing.T) {
	out := make(chan Event, 4)
	if !Send(out, Event{Key: Up, Repeat: true}) {
		t.Fatal("a repeat into an empty channel was dropped")
	}
	if Send(out, Event{Key: Up, Repeat: true}) {
		t.Fatal("a repeat behind an unread one was sent")
	}
	if !Send(out, Event{Key: Up, Release: true}) || !Send(out, Event{Key: Down}) {
		t.Fatal("a release or a press was dropped")
	}
	if len(out) != 3 {
		t.Fatalf("%d events queued, want 3", len(out))
	}
}

func TestHeldBackspaceCadenceAndRelease(t *testing.T) {
	s := &testSource{}
	stop := make(chan struct{})
	defer close(stop)
	events := Poll(s, stop)
	time.Sleep(10 * time.Millisecond)
	next := func() Event {
		t.Helper()
		select {
		case e := <-events:
			return e
		case <-time.After(time.Second):
			t.Fatal("missing backspace event")
			return Event{}
		}
	}
	s.key.Store(1<<11 | 0x266)
	if e := next(); e.Repeat || e.Release || e.ScanCode != 0x66 {
		t.Fatal(e)
	}
	start := time.Now()
	s.key.Store(2<<11 | 0x266) // duplicate hardware make must not add a deletion
	select {
	case e := <-events:
		t.Fatal("early/doubled repeat", e)
	case <-time.After(180 * time.Millisecond):
	}
	if e := next(); !e.Repeat || e.Release {
		t.Fatal(e)
	}
	if elapsed := time.Since(start); elapsed < 220*time.Millisecond || elapsed > 500*time.Millisecond {
		t.Fatal("initial delay", elapsed)
	}
	start = time.Now()
	for i := 0; i < 3; i++ {
		if e := next(); !e.Repeat {
			t.Fatal(e)
		}
	}
	if elapsed := time.Since(start); elapsed < 100*time.Millisecond || elapsed > 300*time.Millisecond {
		t.Fatal("repeat cadence", elapsed)
	}
	s.key.Store(3<<11 | 0x66)
	if e := next(); !e.Release {
		t.Fatal("missing release", e)
	}
	select {
	case e := <-events:
		t.Fatal("deletion after release", e)
	case <-time.After(100 * time.Millisecond):
	}
}
