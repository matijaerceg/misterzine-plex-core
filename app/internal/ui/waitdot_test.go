package ui

import (
	"math"
	"testing"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/plex"
)

// coreOSD plays the core's part for the dot sprite (rtl/ddr_scanout.v):
// at each vsync it takes the asked x when the load bit has toggled, else
// adds the run's vx, clamped to the run's limits. Dot toggles the load
// bit only for a new x, as ring.Overlay does. It also keeps the overlay
// rectangle last shown (one at a time, as the core has it).
type coreOSD struct {
	nopOSD
	x, y           int
	rgb            uint32
	on             bool
	vx, xmin, xmax int
	load, loadQ    bool
	asked          int
	askedSet       bool
	dx             int // where the core has the dot
	barOn          bool
	// the overlay rectangle: shown, where, and a copy of its alpha
	shown        bool
	showX, showY int
	showW, showH int
	showAlpha    []byte
	showPix      []byte
	shows        int // Show calls so far
}

func (c *coreOSD) Show(x, y int, cv *gfx.Canvas, alpha []byte) {
	c.shown, c.showX, c.showY, c.showW, c.showH = true, x, y, cv.W, cv.H
	c.showAlpha = append(c.showAlpha[:0], alpha[:cv.W*cv.H]...)
	c.showPix = append(c.showPix[:0], cv.Pix[:cv.W*cv.H*4]...)
	c.shows++
}
func (c *coreOSD) Hide() { c.shown = false }
func (c *coreOSD) Dot(x, y int, rgb uint32, on bool) {
	c.x, c.y, c.rgb, c.on = x, y, rgb, on
	if x != c.asked || !c.askedSet {
		c.asked, c.askedSet = x, true
		c.load = !c.load
	}
}
func (c *coreOSD) DotRun(vx, xmin, xmax int)             { c.vx, c.xmin, c.xmax = vx, xmin, xmax }
func (c *coreOSD) DotX() int                             { return c.dx }
func (c *coreOSD) Bar(_, _, _, _ int, _ uint32, on bool) { c.barOn = on }
func (c *coreOSD) vsync() {
	if c.load != c.loadQ {
		c.loadQ = c.load
		c.dx = c.x
	} else if c.vx != 0 {
		c.dx = max(c.xmin, min(c.dx+c.vx, c.xmax))
	}
}

// waitDotAt reports whether the wait dots are what the core shows: a
// panel from the dots' top line (alone, or with the strip under them).
func (c *coreOSD) waitDotAt() bool {
	return c.shown && c.showY == waitTop
}

// swellOrder is which dot is largest at a moment.
func largest(n [3]int) int {
	best := 0
	for i := range n {
		if n[i] > n[best] {
			best = i
		}
	}
	return best
}

func TestWaitDotsBreatheToAndFroAtAnEvenPace(t *testing.T) {
	t0 := time.Now()
	d := newWaitDot("", t0)
	if d.step != WaitDotStep || d.gap != WaitDotGap {
		t.Fatalf("defaults: step %v, gap %d", d.step, d.gap)
	}
	// the swell runs left, middle, right, middle, left ... one hop a step
	want := []int{0, 1, 2, 1, 0, 1, 2, 1}
	for i, w := range want {
		at := t0.Add(time.Duration(i) * WaitDotStep)
		r := d.radii(d.frameAt(at))
		if got := largest([3]int{int(r[0] * 100), int(r[1] * 100), int(r[2] * 100)}); got != w {
			t.Fatalf("hop %d: the swell is on dot %d, want %d (%v)", i, got, w, r)
		}
		if r[w] != WaitDotRMax {
			t.Fatalf("hop %d: dot %d at %.1f, not full size", i, w, r[w])
		}
	}
	// between hops the sizes change a little at a time, never a jump
	prev := d.radii(d.frameAt(t0))
	for ms := 10; ms < 2500; ms += 10 {
		r := d.radii(d.frameAt(t0.Add(time.Duration(ms) * time.Millisecond)))
		for i := range r {
			if math.Abs(r[i]-prev[i]) > float64(WaitDotRMax-WaitDotRMin)/waitSlots+1e-9 {
				t.Fatalf("%d ms: dot %d jumped from %.2f to %.2f", ms, i, prev[i], r[i])
			}
			if r[i] < WaitDotRMin || r[i] > WaitDotRMax {
				t.Fatalf("%d ms: dot %d at %.2f, outside %d..%d", ms, i, r[i], WaitDotRMin, WaitDotRMax)
			}
		}
		prev = r
	}
	// the pace is the clock's: the same moment is the same frame however
	// many wakes were missed on the way to it
	if d.frameAt(t0.Add(3*WaitDotStep+WaitDotStep/2)) != d.frameAt(t0.Add(3*WaitDotStep+WaitDotStep/2)) ||
		d.frameAt(t0.Add(7*WaitDotStep)) != d.frameAt(t0.Add(3*WaitDotStep)) {
		t.Fatal("the frame is not a function of the time alone")
	}
}

func TestWaitDotsDrawThreeDiscsInPlace(t *testing.T) {
	d := newWaitDot("", time.Now())
	w := 720
	c := gfx.NewCanvas(w, 2*(WaitDotRMax+1))
	alpha := make([]byte, w*c.H)
	cx, cy := w/2, WaitDotRMax+1
	var centres [3]struct{ x, y, n int }
	for frame := 0; frame <= 2*waitSlots; frame++ {
		clear(alpha)
		d.draw(c, alpha, cx, cy, frame)
		for i := range centres {
			x0 := cx + (i-1)*d.gap
			sx, sy, n := 0, 0, 0
			for y := 0; y < c.H; y++ {
				for x := x0 - d.gap/2; x < x0+d.gap/2; x++ {
					a := int(alpha[y*w+x])
					sx, sy, n = sx+a*x, sy+a*y, n+a
				}
			}
			if n == 0 {
				t.Fatalf("frame %d: dot %d is not drawn", frame, i)
			}
			mx, my := (sx+n/2)/n, (sy+n/2)/n
			if frame == 0 {
				centres[i].x, centres[i].y = mx, my
			} else if mx != centres[i].x || my != centres[i].y {
				t.Fatalf("frame %d: dot %d moved to %d,%d from %d,%d", frame, i, mx, my, centres[i].x, centres[i].y)
			}
			// its size follows its radius
			r := d.radii(frame)[i]
			area := math.Pi * r * r * 255
			if float64(n) < area*0.85 || float64(n) > area*1.15 {
				t.Fatalf("frame %d: dot %d covers %d, want about %.0f for radius %.1f", frame, i, n, area, r)
			}
		}
	}
}

func TestWaitDotSpec(t *testing.T) {
	for _, tc := range []struct {
		spec string
		step time.Duration
		gap  int
	}{
		{"", WaitDotStep, WaitDotGap},
		{"junk", WaitDotStep, WaitDotGap},
		{"400", 400 * time.Millisecond, WaitDotGap},
		{"200,40", 200 * time.Millisecond, 40},
		{" 150 , 36 ", 150 * time.Millisecond, 36},
		{"5,5000", 100 * time.Millisecond, SafeW / 3}, // clamped
		{"0,0", 100 * time.Millisecond, 2*WaitDotRMax + 2},
	} {
		d := newWaitDot(tc.spec, time.Now())
		if d.step != tc.step || d.gap != tc.gap {
			t.Errorf("%q: step %v gap %d, want %v and %d", tc.spec, d.step, d.gap, tc.step, tc.gap)
		}
	}
}

// waitPlaying is a playback controller as PlayQueue makes one, drawing
// into a fake core.
func waitPlaying(t *testing.T) *Playing {
	p := playingCrop(cropApp(t), 1.78)
	p.visible = false
	p.dur, p.pos = 1800, 600
	p.canvas, p.alpha, p.painter = gfx.NewCanvas(720, 480), make([]byte, 720*480), newPainter()
	p.starting = true
	return p
}

// tickFields runs Tick for n fields from t0, a field apart, and returns the
// time after them.
func tickFields(p *Playing, c *coreOSD, t0 time.Time, n int, each func(f int)) time.Time {
	for f := 0; f < n; f++ {
		c.vsync()
		p.Tick(t0, c, true)
		p.painter.flush()
		if each != nil {
			each(f)
		}
		t0 = t0.Add(16683 * time.Microsecond)
	}
	return t0
}

// The peek (a left or right press) and the start strip under the dots end
// at the raster edge as the full panel does, not at its safe-zone baseline.
func TestPeekPanelReachesTheBottom(t *testing.T) {
	p := waitPlaying(t)
	c := &coreOSD{}
	tickFields(p, c, time.Now(), 4, func(int) {
		p.peekAt, p.peekFor = time.Now(), OsdLinger
	})
	if !c.waitDotAt() || c.showY+c.showH != 480 {
		t.Fatalf("start strip at %d, %d high", c.showY, c.showH)
	}
	now := time.Now()
	p.framed(now)
	p.peekAt, p.peekFor = now, OsdLinger
	tickFields(p, c, now, 2, nil)
	if !c.shown || c.waitDotAt() || c.showY+c.showH != 480 {
		t.Fatalf("peek at %d, %d high (shown %v)", c.showY, c.showH, c.shown)
	}
	if a := c.showAlpha[(c.showH-1)*c.showW]; int(a) != OsdAlpha {
		t.Fatalf("peek's bottom row alpha %d, want the panel's %d", a, OsdAlpha)
	}
}

func TestStartStripKeepsTheDotUntilThePicture(t *testing.T) {
	p := waitPlaying(t)
	c := &coreOSD{}
	now := tickFields(p, c, time.Now(), 90, func(f int) {
		p.peekAt, p.peekFor = time.Now(), OsdLinger // as playLoop does before the picture
		if f > 0 && !c.waitDotAt() {
			t.Fatalf("field %d: the start strip took the dot down (on %v, y %d)", f, c.on, c.y)
		}
		if c.barOn {
			t.Fatalf("field %d: the bar sprite showed over the start", f)
		}
	})
	p.framed(now)
	if p.wait != nil || p.starting {
		t.Fatal("the dots outlived the picture")
	}
	// the strip lingers over the picture with no dots, and the run stays stopped
	c.vsync()
	p.Tick(now, c, true)
	p.painter.flush()
	if c.waitDotAt() || c.vx != 0 || !c.shown || c.showY <= waitTop {
		t.Fatalf("the strip did not come back alone: shown %v at %d, run %d", c.shown, c.showY, c.vx)
	}
	if c.on || c.vx != 0 {
		t.Fatalf("the strip brought the dot back: on %v, run %d", c.on, c.vx)
	}
}

func TestWaitDotComesUpWhenThePictureStalls(t *testing.T) {
	p := waitPlaying(t)
	c := &coreOSD{}
	t0 := time.Now()
	p.framed(t0) // the picture is up
	// frames keep coming: no dot
	now := tickFields(p, c, t0, 60, func(f int) {
		if f%2 == 0 {
			p.framed(t0.Add(time.Duration(f) * 16683 * time.Microsecond))
		}
		if c.waitDotAt() {
			t.Fatalf("field %d: a dot over a moving picture", f)
		}
	})
	// the frames stop (the launcher restarting after a network hiccup):
	// nothing for StallDelay, then the dot
	stall := now
	now = tickFields(p, c, now, 60, nil)
	if !c.waitDotAt() {
		t.Fatal("no dot a second into a stall")
	}
	if p.wait == nil || stall.Add(StallDelay).After(now) {
		t.Fatal("the stall was not timed from the last frame")
	}
	// the new stream's first frame takes it down with the next tick
	p.framed(now)
	c.vsync()
	p.Tick(now, c, true)
	p.painter.flush()
	if c.waitDotAt() || c.shown || c.vx != 0 {
		t.Fatalf("the dots outlived the stall: shown %v, run %d", c.shown, c.vx)
	}
}

// playOn publishes a frame every other field for n fields and returns
// the time after them.
func playOn(p *Playing, c *coreOSD, now time.Time, n int) time.Time {
	return tickFields(p, c, now, n, func(f int) {
		if f%2 == 0 {
			p.framed(now.Add(time.Duration(f) * 16683 * time.Microsecond))
		}
	})
}

func TestNoWaitDotForASeek(t *testing.T) {
	p := waitPlaying(t)
	c := &coreOSD{}
	now := time.Now()
	p.framed(now)
	now = playOn(p, c, now, 30)
	p.seekBy(10) // the old stream runs on for a frame or two, then stops
	now = playOn(p, c, now, 4)
	now = tickFields(p, c, now, 120, func(f int) {
		if c.waitDotAt() {
			t.Fatalf("a dot %d fields into a seek's wait", f)
		}
	})
	// the new stream: its first frame ends the seek's hush, so a stall
	// later on (a network hiccup) shows the dot again
	now = playOn(p, c, now, 30)
	tickFields(p, c, now, 60, nil)
	if !c.waitDotAt() {
		t.Fatal("no dot for a stall after the seek was over")
	}
}

func TestWaitDotForATrackChange(t *testing.T) {
	p := waitPlaying(t)
	p.item.Audio = []plex.Stream{{ID: "1", Title: "English", Selected: true}, {ID: "2", Title: "Commentary"}}
	c := &coreOSD{}
	now := time.Now()
	p.framed(now)
	now = playOn(p, c, now, 30)
	p.openList("Audio")
	p.list.cur = 1
	p.choose(p.list) // the stream starts over with the new track
	if p.list != nil {
		t.Fatal("the list stayed open")
	}
	tickFields(p, c, now, 60, nil)
	if !c.waitDotAt() {
		t.Fatal("no dot while the new track comes up")
	}
}

func TestWaitDotStaysDownForAQuickSeek(t *testing.T) {
	p := waitPlaying(t)
	c := &coreOSD{}
	now := time.Now()
	p.framed(now)
	// a 400 ms gap: under StallDelay
	now = tickFields(p, c, now, 24, func(int) {
		if c.waitDotAt() {
			t.Fatal("a dot in a gap shorter than StallDelay")
		}
	})
	p.framed(now)
	tickFields(p, c, now, 10, func(int) {
		if c.waitDotAt() {
			t.Fatal("a dot after the frames came back")
		}
	})
}

func TestWaitDotNotWhenPausedEndingOrStopping(t *testing.T) {
	for _, tc := range []struct {
		name string
		set  func(p *Playing)
	}{
		{"paused", func(p *Playing) { p.paused = true; p.pausedAt = time.Now() }},
		{"at the end", func(p *Playing) { p.pos = p.dur - 2 }},
		{"stopping", func(p *Playing) { p.ending = true }},
	} {
		p := waitPlaying(t)
		c := &coreOSD{}
		now := time.Now()
		p.framed(now)
		tc.set(p)
		tickFields(p, c, now, 90, func(f int) {
			if c.waitDotAt() {
				t.Fatalf("%s: a dot at field %d", tc.name, f)
			}
		})
	}
}

func TestResumeAfterPauseGetsTheFullDelay(t *testing.T) {
	p := waitPlaying(t)
	c := &coreOSD{}
	now := time.Now()
	p.framed(now)
	p.paused, p.pausedAt = true, now
	now = tickFields(p, c, now, 120, nil) // two seconds paused: no frames, no dot
	p.paused = false                      // resumed; the first frame is a moment away
	tickFields(p, c, now, 20, func(f int) {
		if c.waitDotAt() {
			t.Fatalf("a dot %d fields after resuming", f)
		}
	})
}

func TestScrubTakesTheDotFromAStall(t *testing.T) {
	p := waitPlaying(t)
	c := &coreOSD{}
	now := time.Now()
	p.framed(now)
	now = tickFields(p, c, now, 60, nil)
	if !c.waitDotAt() {
		t.Fatal("no dot in the stall")
	}
	// a press of right starts a scrub on the strip: the dot becomes its cursor
	p.Key(input.Event{Key: input.Right}, now)
	p.Tick(now, c, false)
	p.painter.flush()
	if p.wait != nil || c.waitDotAt() {
		t.Fatal("the wait dot stayed over a scrub")
	}
	c.vsync()
	want := SafeX + int(float64(SafeW)*p.scrubTo/p.dur+0.5)
	if c.dx != want {
		t.Fatalf("the scrub cursor starts at %d, not at %d: the core never took its place", c.dx, want)
	}
}
