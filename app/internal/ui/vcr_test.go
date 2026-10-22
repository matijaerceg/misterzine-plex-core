package ui

import (
	"slices"
	"sync"
	"testing"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/plex"
)

// The VCR panel fits the safe area on the standard and the wide canvas,
// with the sprites' places inside the controls' rows, on a flat blue band.
func TestVCRPanelFitsAndKeepsTheSpritesPlaces(t *testing.T) {
	for _, wide := range []bool{false, true} {
		a := betaTestApp(t)
		a.Out = &fakeOut{c: gfx.NewCanvas(720, 480)}
		if wide {
			a.Out = &wideFakeOut{&fakeOut{c: gfx.NewCanvas(720, 480)}}
		}
		a.osd = &painterTestOSD{}
		a.Cfg.PlaybackLook = "vcr"
		it := &plex.Item{Type: "episode", GrandTitle: "A show with a rather long name indeed", Title: "An episode", Parent: 2, Index: 7, Duration: 1460}
		p := NewPlaying(a, it, nil, 0, func(string) {})
		p.compose(false)
		left, right := p.btnX[0], p.btnX[len(p.btnX)-1]+p.btnW[len(p.btnW)-1]
		if left < p.safeX() || right > p.safeX()+p.safeW() {
			t.Fatalf("wide %v: keys %d..%d outside the safe area %d..%d", wide, left, right, p.safeX(), p.safeX()+p.safeW())
		}
		if p.pillY+PillH > p.btnY || p.btnY+BarW > OsdControlH {
			t.Fatalf("wide %v: blocks at %d, focus bar at %d, controls end at %d", wide, p.pillY, p.btnY, OsdControlH)
		}
		if p.alpha[0] != OsdAlpha {
			t.Fatalf("wide %v: the band's top edge is eased (alpha %d)", wide, p.alpha[0])
		}
		if got := gfx.Color(p.static.Pix[2])<<16 | gfx.Color(p.static.Pix[1])<<8 | gfx.Color(p.static.Pix[0]); got != vcrBlue {
			t.Fatalf("wide %v: band colour %06x, want %06x", wide, got, vcrBlue)
		}
		p.compose(true)
		if p.peekH <= 0 || p.peekH > p.btnY {
			t.Fatalf("wide %v: peek strip %d rows", wide, p.peekH)
		}
		<-p.closePainter(a.osd)
	}
}

// shakeOSD is coreOSD that can shake, recording what it was told.
type shakeOSD struct {
	coreOSD
	mu     sync.Mutex
	jitter []bool
	shakes int
}

func (s *shakeOSD) SetJitter(on bool) { s.mu.Lock(); s.jitter = append(s.jitter, on); s.mu.Unlock() }
func (s *shakeOSD) Shake()            { s.mu.Lock(); s.shakes++; s.mu.Unlock() }

func (s *shakeOSD) seen() ([]bool, int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return slices.Clone(s.jitter), s.shakes
}

// In the VCR look the controls shake while they are up, a pattern every
// ShakeFields fields, and stop when they go; the standard look never asks.
func TestVCRControlsShakeWhileUp(t *testing.T) {
	for _, look := range []string{"vcr", ""} {
		p := waitPlaying(t)
		p.app.Cfg.PlaybackLook = look
		o := &shakeOSD{}
		at := time.Now()
		fields := func(n int) {
			for range n {
				p.framed(at)
				o.vsync()
				p.Tick(at, o, true)
				p.painter.flush()
				at = at.Add(16683 * time.Microsecond)
			}
		}
		fields(1) // the first frame: the wait is over
		if p.Key(input.Event{Key: input.Enter}, at) || !p.visible {
			t.Fatal("OK did not open the controls")
		}
		fields(4 * ShakeFields)
		jitter, shakes := o.seen()
		if look == "" {
			if len(jitter) != 0 || shakes != 0 {
				t.Fatalf("standard look: jitter %v, %d shakes", jitter, shakes)
			}
			<-p.closePainter(o)
			continue
		}
		if !slices.Equal(jitter, []bool{true}) || shakes < 3 {
			t.Fatalf("controls up: jitter %v, %d shakes; want [true] and a shake every %d fields", jitter, shakes, ShakeFields)
		}
		if p.Key(input.Event{Key: input.Back}, at) || p.visible {
			t.Fatal("Back did not close the controls")
		}
		fields(1)
		jitter, shakes = o.seen()
		fields(4 * ShakeFields)
		if j, s := o.seen(); !slices.Equal(j, []bool{true, false}) || s != shakes {
			t.Fatalf("controls gone: jitter %v, shakes %d then %d", j, shakes, s)
		}
		<-p.closePainter(o)
	}
}

func TestOptionsStepThePlaybackLook(t *testing.T) {
	a := betaTestApp(t)
	o := NewOptions(a)
	a.Push(o)
	row := func() option { return o.items()[optionRow(o, "Playback controls")] }
	if optionRow(o, "Playback controls") < 0 || row().val() != "Standard" {
		t.Fatal("no Playback controls row at Standard")
	}
	pressOption(t, o, "Playback controls", input.Right)
	if a.Cfg.PlaybackLook != "vcr" || row().val() != "VCR" {
		t.Fatalf("right stepped to %q (%q)", a.Cfg.PlaybackLook, row().val())
	}
	pressOption(t, o, "Playback controls", input.Right)
	if a.Cfg.PlaybackLook != "vcr-clear" || row().val() != "VCR, no band" {
		t.Fatalf("right again stepped to %q (%q)", a.Cfg.PlaybackLook, row().val())
	}
	pressOption(t, o, "Playback controls", input.Left)
	pressOption(t, o, "Playback controls", input.Left)
	if a.Cfg.PlaybackLook != "" {
		t.Fatalf("left stepped to %q, want Standard", a.Cfg.PlaybackLook)
	}
}

// VCR, no band: the panel is clear where the band would be and opaque
// where something is drawn, the running time of a scrub included.
func TestVCRWithoutTheBandIsClearBetweenItsText(t *testing.T) {
	a := betaTestApp(t)
	a.Out = &fakeOut{c: gfx.NewCanvas(720, 480)}
	a.osd = &painterTestOSD{}
	a.Cfg.PlaybackLook = "vcr-clear"
	p := NewPlaying(a, &plex.Item{Title: "A film", Duration: 1460}, nil, 0, func(string) {})
	defer func() { <-p.closePainter(a.osd) }()
	p.pos, p.scrub, p.scrubTo = 300, true, 900
	p.compose(false)
	if p.alpha[0] != 0 || p.alpha[(p.osdHeight()-1)*p.canvas.W] != 0 {
		t.Fatal("the band's corners are not clear")
	}
	opaque := func(x0, y0, w, h int) bool {
		for y := y0; y < y0+h; y++ {
			for x := x0; x < x0+w; x++ {
				if p.alpha[y*p.canvas.W+x] == 255 {
					return true
				}
			}
		}
		return false
	}
	if !opaque(p.safeX(), 12, 200, vcrBig.Height()) || !opaque(p.safeX(), p.pillY, 40, PillH) ||
		!opaque(p.safeX()+p.safeW()/2-60, p.timeY, 120, vcrBig.Height()) {
		t.Fatal("the title, the blocks or the running time is not opaque")
	}
	if !a.Cfg.vcr() {
		t.Fatal("VCR, no band is not a VCR look")
	}
}

// In the VCR look the wait dots are a tape: two reels with the tape across
// their tops, drawn only where its cells are, the two frames turning the
// spokes; it wavers with the controls.
func TestVCRWaitTapeTurns(t *testing.T) {
	p := waitPlaying(t)
	p.app.Cfg.PlaybackLook = "vcr"
	o := &shakeOSD{}
	now := time.Now()
	p.Tick(now, o, true)
	p.painter.flush()
	if p.wait == nil || !p.wait.tape || p.last != "wait" || o.showY != vcrTapeTop {
		t.Fatalf("no tape shown: %q at line %d", p.last, o.showY)
	}
	if j, _ := o.seen(); !slices.Equal(j, []bool{true}) {
		t.Fatalf("the tape's jitter %v, want [true]", j)
	}
	if p.wait.frameAt(now) != 0 || p.wait.frameAt(now.Add(VCRTapeStep)) != 1 || p.wait.frameAt(now.Add(2*VCRTapeStep)) != 0 {
		t.Fatal("the tape does not turn between its two frames")
	}
	at := func(frame, cx, cy int) bool {
		c, alpha, _ := p.waitPanel(frame, nil, nil)
		x := c.W/2 - vcrTapeW*vcrTapeCell/2 + cx*vcrTapeCell + 1
		y := cy*vcrTapeCell + 1
		o := (y*c.W + x) * 4
		return alpha[y*c.W+x] == 255 && gfx.Color(c.Pix[o+2])<<16|gfx.Color(c.Pix[o+1])<<8|gfx.Color(c.Pix[o]) == vcrText
	}
	mid, hub := vcrTapeR+vcrTapeGap/2, vcrTapeR
	for f := range 2 {
		if !at(f, mid, 0) || !at(f, hub, hub) || at(f, mid, hub) {
			t.Fatalf("frame %d: the tape's top, a hub or the gap between the reels is wrong", f)
		}
	}
	if !at(0, hub, hub-2) || at(1, hub, hub-2) || at(0, hub+1, hub-1) || !at(1, hub+1, hub-1) {
		t.Fatal("the spokes do not turn from a cross to a saltire")
	}
	<-p.closePainter(o)
}

// lineOSD is a painterTestOSD that can draw its dot as a line.
type lineOSD struct {
	painterTestOSD
	line bool
}

func (l *lineOSD) SetDotLine(on bool) { l.line = on }

// The VCR playhead is a green line; the focus bar is green, never grey;
// the standard look keeps the white disc and its grey bar.
func TestVCRPlayheadIsAGreenLine(t *testing.T) {
	for _, look := range []string{"vcr-clear", ""} {
		a := betaTestApp(t)
		a.Out = &fakeOut{c: gfx.NewCanvas(720, 480)}
		o := &lineOSD{}
		a.osd = o
		a.Cfg.PlaybackLook = look
		p := NewPlaying(a, &plex.Item{Title: "A film", Duration: 1460}, nil, 0, func(string) {})
		vcr := look != ""
		if o.line != vcr || (p.dotColour() == uint32(vcrText)) != vcr || (p.barColour() == uint32(vcrText)) != vcr {
			t.Fatalf("look %q: line %v, dot %06x, bar %06x", look, o.line, p.dotColour(), p.barColour())
		}
		<-p.closePainter(a.osd)
		if o.line {
			t.Fatalf("look %q: the overlay keeps the line after the playback", look)
		}
	}
}
