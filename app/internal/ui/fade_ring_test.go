package ui

import (
	"io"
	"log"
	"testing"
	"time"

	"plexcrt/internal/gfx"
)

// A fade gets a step every two fields however long it runs; the steps of
// a long one take the pool's canvases in turn.
func TestFadeStepsFollowTheDuration(t *testing.T) {
	from, to := gfx.NewCanvas(8, 4), gfx.NewCanvas(8, 4)
	for _, c := range []struct {
		dur          time.Duration
		steps, slots int
	}{
		{animDur, 5, 4},
		{600 * time.Millisecond, 18, fadeSlots},
		{time.Second, 31, fadeSlots},
	} {
		var f Fade
		f.StartFor(from, to, time.Now().Add(time.Hour), c.dur) // the worker waits: nothing is blended
		if f.n != c.steps || len(f.steps) != c.slots {
			t.Errorf("a %v fade: %d steps in %d canvases, want %d in %d", c.dur, f.n, len(f.steps), c.steps, c.slots)
		}
		f.Done()
	}
}

// A fade longer than the pool shows every step in order, from the old page
// to the new, with more steps than the ten a fade used to be held to.
func TestLongFadeShowsEveryStepInOrder(t *testing.T) {
	from, to := gfx.NewCanvas(8, 4), gfx.NewCanvas(8, 4)
	from.Fill(0, 0, 8, 4, gfx.Black)
	to.Fill(0, 0, 8, 4, gfx.White)
	var f Fade
	defer f.Done()
	start := time.Now()
	f.StartFor(from, to, start, 600*time.Millisecond)
	seen := map[byte]bool{}
	last := byte(0)
	for {
		page, running := f.Frame(time.Now())
		v := page.Pix[0]
		if v < last {
			t.Fatalf("the fade went back: %d after %d", v, last)
		}
		last = v
		seen[v] = true
		if !running {
			break
		}
		if time.Since(start) > 5*time.Second {
			t.Fatal("the fade never ended")
		}
		time.Sleep(4 * time.Millisecond)
	}
	if last != to.Pix[0] {
		t.Fatalf("the fade ended on %d, not the new page's %d", last, to.Pix[0])
	}
	if len(seen) <= 12 {
		t.Fatalf("only %d distinct frames over 600 ms; a step every two fields gives 18", len(seen))
	}
}

// A presenter that stops calling Frame mid-fade leaves the worker parked
// before a ring canvas the screen may still hold; Done still ends it at
// once rather than waiting for a Frame that never comes.
func TestFadeDoneReturnsWithTheWorkerParked(t *testing.T) {
	from, to := gfx.NewCanvas(8, 4), gfx.NewCanvas(8, 4)
	var f Fade
	dur := 600 * time.Millisecond
	f.StartFor(from, to, time.Now().Add(-dur), dur) // every step is due at once
	if f.n <= len(f.steps) {
		t.Fatalf("%d steps fit %d canvases: no ring to park on", f.n, len(f.steps))
	}
	deadline := time.Now().Add(2 * time.Second)
	for int(f.ready.Load()) < len(f.steps) {
		if time.Now().After(deadline) {
			t.Fatalf("the worker blended %d of the %d free canvases", f.ready.Load(), len(f.steps))
		}
		time.Sleep(time.Millisecond)
	}
	time.Sleep(20 * time.Millisecond)
	if got := int(f.ready.Load()); got != len(f.steps) {
		t.Fatalf("the worker reused a canvas Frame never moved past: %d steps ready, %d canvases", got, len(f.steps))
	}
	done := make(chan struct{})
	go func() { f.Done(); close(done) }()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("Done waited on a parked worker")
	}
}

// The transition trace waits for the fade's worker before reading its
// timestamps; a worker parked on the ring must not hold that up.
func TestTracePublishedStopsAParkedFade(t *testing.T) {
	from, to := gfx.NewCanvas(8, 4), gfx.NewCanvas(8, 4)
	v := &Show{app: &App{Log: log.New(io.Discard, "", 0)}}
	v.trace = &transitionTrace{start: time.Now(), status: func() (uint32, uint32, uint32) { return 0, 0, 0 }}
	v.fade.trace = v.trace
	dur := 600 * time.Millisecond
	v.fade.StartFor(from, to, time.Now().Add(-dur), dur)
	deadline := time.Now().Add(2 * time.Second)
	for int(v.fade.ready.Load()) < len(v.fade.steps) && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	done := make(chan struct{})
	go func() { v.tracePublished(); close(done) }()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("the trace waited on a parked fade worker")
	}
	if v.trace != nil {
		t.Fatal("the trace was not written out")
	}
}
