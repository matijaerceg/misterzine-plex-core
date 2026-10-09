package ui

import (
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
