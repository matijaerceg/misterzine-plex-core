package ui

import (
	"math"
	"strconv"
	"strings"
	"time"

	"plexcrt/internal/gfx"
)

// The wait dots: while the picture is held up (a playback coming up, or a
// stream that has stopped delivering frames after a track change or a
// restart), three dots breathe in the middle of the screen, swelling one
// after another left to right and back again, until the next frame is on
// screen. A seek's wait has none: the strip already says where it goes.
// Nothing moves: a dot swells in place, so the tube shows no judder. The
// swell is timed from the clock, not counted in wakes, so a late wake
// (the decoder has the machine) skips ahead and the pace never slackens.
const (
	WaitDotStep = 280 * time.Millisecond // the swell's hop from one dot to the next
	WaitDotGap  = 28                     // centre to centre, canvas pixels
	WaitDotRMin = 3                      // a dot at rest, radius in lines
	WaitDotRMax = 7                      // a dot at full swell
	WaitDotY    = 240                    // the middle of the frame
	// waitSlots is how many drawn frames a hop takes: enough that the
	// swell reads as a breath, not as steps, on a 60 Hz field rate
	waitSlots = 8
	// waitTop is the top line of the dots' box; even, for the 480i grid
	waitTop = WaitDotY - WaitDotRMax - 1
	// StallDelay is how long a playing picture may stand still before the
	// dots come up, so a quick seek never flashes them.
	StallDelay = 500 * time.Millisecond
	// EndSlack is how near the end, in seconds, a stall is taken for the
	// stream finishing.
	EndSlack = 5
	// RestartGap is a gap between frames that only a new stream makes: the
	// frame after it ends a seek's hush. SeekHush ends one that never
	// restarted, so a later stall is not taken for the seek's.
	RestartGap = 250 * time.Millisecond
	SeekHush   = 20 * time.Second
)

type waitDot struct {
	start time.Time
	step  time.Duration
	gap   int
	frame int  // the frame last drawn; -1 before the first
	tape  bool // the VCR looks' tape (vcr.go): two frames, turned at VCRTapeStep
}

// newWaitDot lays the dots out from a "step_ms,gap" spec (PLEXCRT_WAIT_DOT,
// for tuning on a set); an empty or unreadable part keeps its default.
func newWaitDot(spec string, now time.Time) *waitDot {
	step, gap := WaitDotStep, WaitDotGap
	parts := strings.Split(spec, ",")
	if n, err := strconv.Atoi(strings.TrimSpace(parts[0])); err == nil {
		step = time.Duration(max(100, min(n, 1000))) * time.Millisecond
	}
	if len(parts) > 1 {
		if n, err := strconv.Atoi(strings.TrimSpace(parts[1])); err == nil {
			gap = max(2*WaitDotRMax+2, min(n, SafeW/3))
		}
	}
	return &waitDot{start: now, step: step, gap: gap, frame: -1}
}

// phase is where the swell is at now: 0 at the left dot, 1 the middle, 2
// the right, running to and fro at an even pace.
func (d *waitDot) phase(now time.Time) float64 {
	hops := float64(now.Sub(d.start)) / float64(d.step)
	u := math.Mod(hops, 4)
	if u > 2 {
		u = 4 - u
	}
	return u
}

// frameAt is the drawn frame for now: the phase in whole slots.
func (d *waitDot) frameAt(now time.Time) int {
	if d.tape {
		return int(now.Sub(d.start)/VCRTapeStep) % 2
	}
	return int(d.phase(now)*waitSlots + 0.5)
}

// radii are the three dots' radii at a frame: the one the swell is on
// at full size, its neighbours between, the rest at rest.
func (d *waitDot) radii(frame int) [3]float64 {
	var r [3]float64
	pos := float64(frame) / waitSlots
	for i := range r {
		swell := max(0, 1-math.Abs(pos-float64(i)))
		r[i] = WaitDotRMin + (WaitDotRMax-WaitDotRMin)*swell
	}
	return r
}

// width is the dots' box, side to side.
func (d *waitDot) width() int { return 2*d.gap + 2*WaitDotRMax + 2 }

// draw paints the frame's three dots centred on cx, cy into c, with their
// coverage in alpha (a byte a pixel, c.W a row): a disc's edge is sampled
// 4 x 4 a pixel, so the swell grows smoothly rather than a line at a time.
func (d *waitDot) draw(c *gfx.Canvas, alpha []byte, cx, cy, frame int) {
	r := d.radii(frame)
	for i, ri := range r {
		x0 := cx + (i-1)*d.gap
		box := int(math.Ceil(ri)) + 1
		c.Fill(x0-box, cy-box, 2*box, 2*box, gfx.Amber)
		for y := cy - box; y < cy+box; y++ {
			if y < 0 || y >= c.H {
				continue
			}
			for x := x0 - box; x < x0+box; x++ {
				if x < 0 || x >= c.W {
					continue
				}
				in := 0
				for sy := 0; sy < 4; sy++ {
					dy := float64(y-cy) + (float64(sy)+0.5)/4
					for sx := 0; sx < 4; sx++ {
						dx := float64(x-x0) + (float64(sx)+0.5)/4
						if dx*dx+dy*dy <= ri*ri {
							in++
						}
					}
				}
				alpha[y*c.W+x] = byte(in * 255 / 16)
			}
		}
	}
}

// heldUp reports whether the picture is held up: the start, or no frame
// for StallDelay while playing. Not once the playback is ending, not for
// a seek, not over a scrub (the dot is its cursor) or a list, and not in
// the last seconds, where a stall is the stream finishing.
func (p *Playing) heldUp(now time.Time) bool {
	switch {
	case p.ending:
		return false
	case p.starting:
		return true
	case p.paused || p.frameAt.IsZero() || p.scrub || p.list != nil:
		return false
	case !p.hushAt.IsZero() && now.Sub(p.hushAt) < SeekHush:
		return false
	case p.dur > 0 && p.pos >= p.dur-EndSlack:
		return false
	}
	return now.Sub(p.frameAt) >= StallDelay
}

// waiting starts and stops the wait dots; it runs at the top of every
// Tick. Tick draws them, alone or over the start strip.
func (p *Playing) waiting(now time.Time) {
	if p.paused {
		p.frameAt = now // a paused picture is not a stall, nor the moment after
	}
	if held := p.heldUp(now); held && p.wait == nil {
		p.wait = newWaitDot(p.waitSpec, now)
		p.wait.tape = p.app.Cfg.vcr()
	} else if !held {
		p.stopWait()
	}
}

// waitPanel is the overlay panel with the dots at a frame: alone, a short
// box in the middle; with a strip, one panel from the dots down to the
// strip's bottom edge, the strip in its place at the bottom and the rest
// clear, so the two show together (the overlay is one rectangle).
func (p *Playing) waitPanel(frame int, strip *gfx.Canvas, stripAlpha []byte) (c *gfx.Canvas, alpha []byte, y int) {
	w := p.canvas.W
	top, h := waitTop, 2*(WaitDotRMax+1)
	if p.wait.tape {
		top, h = vcrTapeTop, vcrTapeH+2 // and its shadow
	}
	if strip != nil {
		h = p.canvasHeight() - top // the strip's panel reaches the raster edge
	}
	if p.waitCanvas == nil || p.waitCanvas.W != w || p.waitCanvas.H != h {
		p.waitCanvas = gfx.NewCanvas(w, h)
		p.waitAlpha = make([]byte, w*h)
	}
	c, alpha = p.waitCanvas, p.waitAlpha
	clear(alpha)
	if p.wait.tape {
		drawTape(c, alpha, w/2, frame)
	} else {
		p.wait.draw(c, alpha, w/2, WaitDotY-waitTop, frame)
	}
	if strip != nil {
		top := h - strip.H
		copy(c.Pix[top*w*4:], strip.Pix[:strip.W*strip.H*4])
		copy(alpha[top*w:], stripAlpha[:strip.W*strip.H])
	}
	return c, alpha, top
}

// framed notes a frame published by the presenter: a held picture moves
// on, the first one ends the start, and the first of a new stream ends a
// seek's hush.
func (p *Playing) framed(now time.Time) {
	if !p.lastFrame.IsZero() && now.Sub(p.lastFrame) >= RestartGap {
		p.hushAt = time.Time{}
	}
	p.frameAt, p.lastFrame = now, now
	p.starting = false
	p.stopWait()
}

// end is the playback stopping: the dots go at once and stay gone.
func (p *Playing) end() {
	p.ending = true
	p.stopWait()
}

// stopWait takes the dots down: whatever shows next is repainted without
// them, or the overlay hidden if nothing does.
func (p *Playing) stopWait() {
	if p.wait != nil {
		p.wait = nil
		p.last = ""
		p.dirty = true
	}
}
