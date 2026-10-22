package ui

import (
	"sync"
	"sync/atomic"
	"time"

	"plexcrt/internal/gfx"
)

// Fade cross-fades between two composed pages. A full-frame blend costs
// too much of a field on the render thread, so the in-between steps are
// blended by a worker (on the other core) into private canvases and the
// render thread only copies whichever step is due: a few frames of the
// old page if the worker is behind, never a missed field.
type Fade struct {
	from, to   *gfx.Canvas
	steps      []*gfx.Canvas
	n          int           // steps in use for this fade
	ready      atomic.Int32  // steps completed so far
	stop       chan struct{} // interrupts the worker's pacing wait
	wg         sync.WaitGroup
	start      time.Time
	dur        time.Duration
	layout     bool // a show-state transition; late artwork waits for it
	backdrop   *gfx.Image
	fromY, toY int
	trace      *transitionTrace
	readyWake  chan struct{}
	shown      atomic.Int32  // the step Frame last handed out, 0 for the old page
	shownWake  chan struct{} // Frame moved on to another step
}

// One set of step canvases serves every fade: only one runs at a time.
var (
	fadePoolMu sync.Mutex
	fadePool   []*gfx.Canvas
	fadeOwner  *Fade
	fadePoolW  int
	fadePoolH  int
)

const (
	fadeStepEvery = 32 * time.Millisecond // a new step every two fields
	fadeMinSteps  = 4
	// fadeSlots is how many step canvases the pool holds: enough for a
	// layout transition's steps. A longer fade has more steps than that
	// and takes the canvases in turn, a ring: the worker is paced to the
	// steps' times, and before it blends into a canvas again it waits
	// until Frame has moved past the step the canvas held (see startFade).
	fadeSlots = transitionSteps - 1
)

var (
	fadeWarmMu sync.Mutex    // one warming at a time: each is fadeSlots canvases
	fadeWant   atomic.Uint64 // the canvas size last warmed for, w<<32 | h
)

// warmFades allocates the step buffers for w x h canvases up front, so the
// first fade does not pay for them mid-frame. Safe off the render thread:
// the new set replaces the pool under its lock, and a fade still running
// keeps the canvases it took.
func warmFades(w, h int) {
	fadeWant.Store(uint64(w)<<32 | uint64(uint32(h)))
	fillFadePool(w, h)
}

func fillFadePool(w, h int) {
	fadePoolMu.Lock()
	ready := fadePoolW == w && fadePoolH == h && len(fadePool) >= fadeSlots
	fadePoolMu.Unlock()
	if ready {
		return
	}
	fresh := make([]*gfx.Canvas, fadeSlots)
	for i := range fresh {
		fresh[i] = gfx.NewCanvas(w, h)
		fresh[i].Fill(0, 0, w, h, gfx.Bg) // touch the pages
	}
	fadePoolMu.Lock()
	if fadePoolW != w || fadePoolH != h || len(fadePool) < fadeSlots {
		fadePool, fadePoolW, fadePoolH = fresh, w, h
	}
	fadePoolMu.Unlock()
}

// warmFadesFor warms the pool again, off the render thread, when the
// layout canvas changes size (a raster or display shape changed): a 16:9
// canvas's first fade would otherwise allocate them on it. The render
// loop calls it every frame; an unchanged size costs one atomic swap.
func warmFadesFor(w, h int) {
	key := uint64(w)<<32 | uint64(uint32(h))
	if fadeWant.Swap(key) == key {
		return
	}
	go func() {
		fadeWarmMu.Lock()
		defer fadeWarmMu.Unlock()
		if fadeWant.Load() == key { // not changed again since
			fillFadePool(w, h)
		}
	}()
}

// Start begins a fade from one page to another over the standard duration.
func (f *Fade) Start(from, to *gfx.Canvas, now time.Time) { f.StartFor(from, to, now, animDur) }

// Layout moves one shared backdrop between the two layouts' vertical
// alignments. Text/shading fade with their layouts; the image never exposes
// an empty canvas edge.
func (f *Fade) Layout(from, to *gfx.Canvas, backdrop *gfx.Image, fromY, toY int, now time.Time) {
	f.startFade(from, to, now, transDur, true, backdrop, fromY, toY)
}

// StartFor begins a fade over dur. Both pages must stay unchanged until
// Done returns. The worker paces memory traffic across the fade.
func (f *Fade) StartFor(from, to *gfx.Canvas, now time.Time, dur time.Duration) {
	f.startFade(from, to, now, dur, false, nil, 0, 0)
}

func (f *Fade) startFade(from, to *gfx.Canvas, now time.Time, dur time.Duration, layout bool, backdrop *gfx.Image, fromY, toY int) {
	f.Done()
	f.layout, f.backdrop, f.fromY, f.toY = layout, backdrop, fromY, toY
	fadePoolMu.Lock()
	if fadeOwner != nil && fadeOwner != f {
		fadeOwner.cancel() // another screen's fade is still using the pool
	}
	fadeOwner = f
	if fadePoolW != to.W || fadePoolH != to.H {
		fadePool = nil
		fadePoolW, fadePoolH = to.W, to.H
	}
	// a step every two fields however long the fade: a long one (the
	// wall's new palette, a screensaver's slideshow) used to be held to
	// ten steps and changed only every few fields
	n := max(fadeMinSteps, int(dur/fadeStepEvery))
	if layout {
		n = transitionSteps
	}
	slots := min(n-1, fadeSlots)
	for len(fadePool) < slots {
		fadePool = append(fadePool, gfx.NewCanvas(to.W, to.H))
	}
	f.steps = fadePool[:slots]
	fadePoolMu.Unlock()
	f.n = n
	f.dur = dur
	f.from, f.to = from, to
	f.ready.Store(0)
	f.start = now
	f.stop = make(chan struct{})
	stop := f.stop
	f.readyWake = make(chan struct{}, 1)
	wake := f.readyWake
	f.shown.Store(0)
	f.shownWake = make(chan struct{}, 1)
	shownWake := f.shownWake
	trace := f.trace
	a := &gfx.Image{W: from.W, H: from.H, Pix: from.Pix}
	b := &gfx.Image{W: to.W, H: to.H, Pix: to.Pix}
	first := 1
	if layout {
		// The presenter draws the second frame immediately after publishing
		// the first. Seed that frame before handing the rest to the worker.
		y := layoutY(fromY, toY, 1, n)
		if trace != nil {
			trace.BackgroundBegin[1] = trace.point()
		}
		f.steps[0].BlendBackdrop(a, fromY-y, b, toY-y, backdrop, y, 256/n)
		if trace != nil {
			trace.BackgroundReady[1] = trace.point()
		}
		f.ready.Store(1)
		first = 2
	}
	f.wg.Add(1)
	go func() {
		defer f.wg.Done()
		for i := first; i < n; i++ {
			due := now.Add(time.Duration(i) * dur / time.Duration(n))
			lead := 12 * time.Millisecond
			if layout {
				// The next complete frame is drawn immediately after publishing
				// the previous one, then waits for its assigned vsync. Prepare
				// backdrop steps ahead of that draw, not just ahead of display.
				lead = 3 * transitionFrame
			}
			if wait := time.Until(due) - lead; wait > 0 {
				timer := time.NewTimer(wait)
				select {
				case <-timer.C:
				case <-stop:
					timer.Stop()
					return
				}
			}
			select {
			case <-stop:
				return
			default:
			}
			// A long fade's step i reuses the canvas of step i-len(steps).
			// The clock alone does not keep that step off the screen (the
			// presenter may be late), so wait until Frame has handed out a
			// later one. The presenter shows one canvas at a time and is
			// done with it before its next Frame call, so a canvas whose
			// step is behind the one Frame last returned is free.
			if prev := i - len(f.steps); prev >= 1 {
				for int(f.shown.Load()) <= prev {
					select {
					case <-shownWake:
					case <-stop:
						return
					}
				}
			}
			if layout {
				if trace != nil {
					trace.BackgroundBegin[i] = trace.point()
				}
				y := layoutY(fromY, toY, i, n)
				f.steps[i-1].BlendBackdrop(a, fromY-y, b, toY-y, backdrop, y, i*256/n)
				if trace != nil {
					trace.BackgroundReady[i] = trace.point()
				}
			} else {
				f.step(i).Blend(0, 0, a, b, i*256/n)
			}
			f.ready.Store(int32(i))
			select {
			case wake <- struct{}{}:
			default:
			}
		}
	}()
}

// cancel stops the worker and ends the fade (the pool is needed elsewhere).
func (f *Fade) cancel() {
	f.Done()
}

// Done cancels the worker and waits for it, so the pages may be reused.
func (f *Fade) Done() {
	if f.stop != nil {
		close(f.stop)
		f.stop = nil
	}
	f.wg.Wait()
	f.start = time.Time{}
}

// Transitioning keeps late artwork from replacing an in-progress layout change.
func (f *Fade) Transitioning(now time.Time) bool {
	return f.layout && !f.start.IsZero() && now.Sub(f.start) < f.dur
}

func layoutY(from, to, step, steps int) int {
	p := float64(step) / float64(steps)
	e := 1 - (1-p)*(1-p)*(1-p)
	return from + round(float64(to-from)*e)
}

// ArtY matches the actual published step, including a worker running behind.
func (f *Fade) ArtY(now time.Time) int {
	if f.start.IsZero() || now.Sub(f.start) >= f.dur {
		return f.toY
	}
	k := int(now.Sub(f.start) * time.Duration(f.n) / f.dur)
	k = max(0, min(k, int(f.ready.Load())))
	return layoutY(f.fromY, f.toY, k, f.n)
}

// Running reports whether a fade is in progress.
func (f *Fade) Running() bool { return !f.start.IsZero() }

// Frame returns the page to show now and whether the fade continues.
func (f *Fade) Frame(now time.Time) (*gfx.Canvas, bool) {
	if f.start.IsZero() {
		return f.to, false
	}
	k := int(now.Sub(f.start) * time.Duration(f.n) / f.dur)
	if k >= f.n {
		f.start = time.Time{}
		return f.to, false
	}
	if r := int(f.ready.Load()); k > r {
		k = r
	}
	if f.shown.Swap(int32(k)) != int32(k) {
		select {
		case f.shownWake <- struct{}{}:
		default:
		}
	}
	if k == 0 {
		return f.from, true
	}
	return f.step(k), true
}

// step is the canvas that holds step i (1 to n-1), the steps taking the
// canvases in turn when there are more of them than canvases.
func (f *Fade) step(i int) *gfx.Canvas { return f.steps[(i-1)%len(f.steps)] }

// waitReady spends only a small part of the next field waiting for a nearly
// complete background, rather than committing immediately to a repeated frame.
func (f *Fade) waitReady(step int, budget time.Duration) int {
	if ready := int(f.ready.Load()); ready >= step {
		return ready
	}
	timer := time.NewTimer(budget)
	defer timer.Stop()
	for int(f.ready.Load()) < step {
		select {
		case <-f.readyWake:
		case <-timer.C:
			return int(f.ready.Load())
		case <-f.stop:
			return int(f.ready.Load())
		}
	}
	return int(f.ready.Load())
}
