package ui

import (
	"strings"
	"time"

	"plexcrt/internal/gfx"
)

// The VCR look of the playback controls (Options > Playback UI theme): an
// old deck's on-screen display, bright green and white block capitals with
// a hard shadow on a flat blue band (or none), the progress as a row of
// blocks, the wait dots as a turning tape, and its lines wavering sideways by a
// pixel as a tape's picture did (ring.Overlay.SetJitter). The controls
// work as in the standard look; only the drawing differs. The subtitles
// keep their own look and stay still.
var (
	vcrBig   = gfx.PixelFont{SX: 3, SY: 4} // 15x28: titles, the counter, the keys
	vcrSmall = gfx.PixelFont{SX: 2, SY: 3} // 10x21: the episode line, the lists
)

// The VCR look's colours are an old on-screen display chip's: each of red,
// green and blue fully on or off, eight colours and no greys, bright green
// the highlight and white the rest. The band is a deck's blue back, a
// darker blue of its own, so that the full blue of the idle keys still
// shows on it.
const (
	vcrBlue      gfx.Color = 0x0000AA // the band behind the controls
	vcrText      gfx.Color = 0x00FF00 // the title, the counter, the key under the cursor, the played blocks, the tape
	vcrShadow    gfx.Color = 0x000000
	vcrLo        gfx.Color = 0xFFFFFF // keys and values not under the cursor, the episode line
	vcrOff       gfx.Color = 0x0000FF // keys with nothing to do
	vcrBlockOff  gfx.Color = 0xFFFFFF // progress still to come
	vcrBuffered  gfx.Color = 0x00FFFF // downloaded ahead of the playhead
	vcrMarkerCol gfx.Color = 0xFF00FF // an intro or credits marker
	vcrBarH                = 10       // the progress blocks' height
	vcrBlock               = 6        // a block's width
	vcrBlockGap            = 2
	vcrKeyGap              = 22 // between the keys
	// ShakeFields is how many fields each step of the waver holds.
	ShakeFields = 3
)

// vcrKeys are the keys' labels in osdButtons' order: the deck's symbols
// for the ten-second steps and Pause, words for the rest.
var vcrKeys = map[string]string{
	"-10": string([]rune{gfx.PixelRewind, gfx.PixelRewind}), "Pause": string(gfx.PixelPause),
	"Play": string(gfx.PixelPlay), "+10": string([]rune{gfx.PixelPlay, gfx.PixelPlay}),
}

func vcrKey(b string) string {
	if k, ok := vcrKeys[b]; ok {
		return k
	}
	return strings.ToUpper(b)
}

// dotLiner is an OSD whose dot can be drawn as a line (ring.Overlay): the
// VCR playhead, in the highlight green.
type dotLiner interface{ SetDotLine(on bool) }

// dotColour is the playhead's colour in the look in force.
func (p *Playing) dotColour() uint32 {
	if p.app.Cfg.vcr() {
		return uint32(vcrText)
	}
	return uint32(gfx.White)
}

// barColour is the focus bar's, beside a list row or under a key: the
// highlight green in the VCR look, which has no greys.
func (p *Playing) barColour() uint32 {
	if p.app.Cfg.vcr() {
		return uint32(vcrText)
	}
	return uint32(gfx.GreyHi)
}

// jitterer is an OSD whose rectangle can shake (ring.Overlay).
type jitterer interface {
	SetJitter(on bool)
	Shake()
}

// setJitter says whether what goes up next shakes: the controls in the
// VCR look do, the subtitles and the wait dots do not. It goes through the
// painter, so it lands in order with the panels.
func (p *Playing) setJitter(osd OSD, on bool) {
	on = on && p.app.Cfg.vcr()
	j, ok := osd.(jitterer)
	if !ok || on == p.jittering {
		return
	}
	p.jittering = on
	p.painter.do(func() { j.SetJitter(on) })
}

// shake moves the shake on every ShakeFields fields while shaking
// controls are up, one shake waiting at most: a painter behind on its
// writes skips patterns rather than queueing them.
func (p *Playing) shake(osd OSD, field bool) {
	if !field || !p.jittering || p.last == "" {
		return
	}
	if p.shakeTick++; p.shakeTick%ShakeFields != 0 {
		return
	}
	j, ok := osd.(jitterer)
	if !ok || !p.shaking.CompareAndSwap(false, true) {
		return
	}
	p.painter.do(func() {
		j.Shake()
		p.shaking.Store(false)
	})
}

// composeStaticVCR is composeStatic in the VCR look, with the same places
// for the sprites: the title, the episode line, the blocks, PLAY or PAUSE
// beside the counter (or, with timed, room for the running time at timeY),
// and the keys.
func (p *Playing) composeStaticVCR(c *gfx.Canvas, peek, timed bool) {
	c.Fill(0, 0, c.W, c.H, vcrBlue)
	x0, w := p.safeX(), p.safeW()
	title, sub := heading(p.item)
	y := 12
	c.PixelText(x0, y, vcrBig, vcrText, vcrShadow, vcrBig.Fit(title, w))
	y += vcrBig.Height() + 4
	if sub != "" {
		c.PixelText(x0, y, vcrSmall, vcrLo, vcrShadow, vcrSmall.Fit(sub, w))
	}
	y += vcrSmall.Height() + 10
	p.pillY = y + (vcrBarH-PillH)/2 // the dot rides the blocks' middle
	p.vcrBlocks(c, y)
	y += vcrBarH + 10
	status := string(gfx.PixelPlay) + " PLAY"
	if p.paused {
		status = string(gfx.PixelPause) + " PAUSE"
	}
	c.PixelText(x0, y, vcrBig, vcrText, vcrShadow, status)
	if timed {
		p.timeY = y
	} else {
		t := clock(int(p.pos))
		if p.dur > 0 {
			t += " / " + clock(int(p.dur))
		}
		c.PixelText(x0+w-vcrBig.Width(t), y, vcrBig, vcrText, vcrShadow, t)
	}
	y += vcrBig.Height() + 14
	if peek {
		p.peekH = y
		return
	}
	labels := make([]string, len(osdButtons))
	total := vcrKeyGap * (len(labels) - 1)
	for i, b := range osdButtons {
		if b == "Pause" && p.paused {
			b = "Play"
		}
		labels[i] = vcrKey(b)
		total += vcrBig.Width(labels[i])
	}
	x := (c.W - total) / 2
	for i, b := range labels {
		col := vcrLo
		if i == p.focus && !p.scrub {
			col = vcrText
		}
		if p.dimmed(i) {
			col = vcrOff
		}
		p.btnX[i], p.btnW[i], p.btnY = x, vcrBig.Width(b), y+vcrBig.Height()+3
		c.PixelText(x, y, vcrBig, col, vcrShadow, b)
		x += vcrBig.Width(b) + vcrKeyGap
	}
}

// vcrClearBand takes the band away for VCR, no band: the panel's alpha
// is opaque where something is drawn and clear where the band shows, as
// a deck put its text straight over the picture.
func (p *Playing) vcrClearBand(c *gfx.Canvas, alpha []byte) {
	b, g, r := byte(vcrBlue&0xFF), byte(vcrBlue>>8&0xFF), byte(vcrBlue>>16)
	for i := range alpha[:c.W*c.H] {
		o := i * 4
		if c.Pix[o] == b && c.Pix[o+1] == g && c.Pix[o+2] == r {
			alpha[i] = 0
		} else {
			alpha[i] = 255
		}
	}
}

// vcrBlocks draws the progress as blocks across the safe width, each
// coloured by the film time at its middle: played, in a marker, buffered,
// or still to come.
func (p *Playing) vcrBlocks(c *gfx.Canvas, y int) {
	x0, w := p.safeX(), p.safeW()
	for x := 0; x+vcrBlock <= w; x += vcrBlock + vcrBlockGap {
		col := vcrBlockOff
		if p.dur > 0 {
			t := float64(x+vcrBlock/2) * p.dur / float64(w)
			switch {
			case t <= p.pos:
				col = vcrText
			case p.inMarker(t):
				col = vcrMarkerCol
			case t >= p.bufferStart && t < p.bufferEnd:
				col = vcrBuffered
			}
		}
		c.Fill(x0+x, y, vcrBlock, vcrBarH, col)
	}
}

func (p *Playing) inMarker(t float64) bool {
	for _, m := range p.item.Markers {
		if t >= m.Start && t < m.End {
			return true
		}
	}
	return false
}

// The tape the VCR looks show while the picture is held up: two reels, the
// tape drawn tight across their tops, in chunky cells. Two frames turn the
// reels' spokes from a cross to a saltire and back, a spinning a deck's
// display could draw.
const (
	vcrTapeCell = 4                              // a cell's side, pixels and lines
	vcrTapeR    = 4                              // a reel's radius, cells
	vcrTapeGap  = 12                             // reel centre to reel centre, cells
	vcrTapeW    = vcrTapeGap + 2*vcrTapeR + 1    // cells across
	vcrTapeH    = (2*vcrTapeR + 1) * vcrTapeCell // lines down
	vcrTapeTop  = (WaitDotY - vcrTapeH/2) &^ 1   // the tape's top line, even for the 480i grid
	// VCRTapeStep is how long each frame of the turn holds.
	VCRTapeStep = 220 * time.Millisecond
)

// tapeCell reports whether cell x, y of the tape is drawn in frame f.
func tapeCell(x, y, f int) bool {
	if y == 0 && x >= vcrTapeR && x <= vcrTapeR+vcrTapeGap {
		return true // the tape across the reels' tops
	}
	for _, cx := range []int{vcrTapeR, vcrTapeR + vcrTapeGap} {
		dx, dy := x-cx, y-vcrTapeR
		d2 := dx*dx + dy*dy
		switch {
		case d2 >= 13 && d2 <= 20: // the rim
			return true
		case d2 == 0: // the hub
			return true
		case f == 0 && (dx == 0 || dy == 0) && d2 <= 4: // the spokes as a cross
			return true
		case f == 1 && (dx == dy || dx == -dy) && d2 <= 2: // turned an eighth, short of the rim
			return true
		}
	}
	return false
}

// drawTape paints the tape's frame f centred on cx, with its top at the
// canvas's line 0, each cell with the hard shadow of the VCR text.
func drawTape(c *gfx.Canvas, alpha []byte, cx, f int) {
	x0 := cx - vcrTapeW*vcrTapeCell/2
	for pass, col := range []gfx.Color{vcrShadow, vcrText} {
		off := 2 * (1 - pass) // the shadow first, two pixels right and down
		for y := range 2*vcrTapeR + 1 {
			for x := range vcrTapeW {
				if tapeCell(x, y, f) {
					px, py := x0+x*vcrTapeCell+off, y*vcrTapeCell+off
					c.Fill(px, py, vcrTapeCell, vcrTapeCell, col)
					opaque(alpha, c.W, c.H, px, py, vcrTapeCell)
				}
			}
		}
	}
}

// opaque marks an n x n square at x0, y0 of a w x h alpha plane drawn.
func opaque(alpha []byte, w, h, x0, y0, n int) {
	for y := max(0, y0); y < min(h, y0+n); y++ {
		for x := max(0, x0); x < min(w, x0+n); x++ {
			alpha[y*w+x] = 255
		}
	}
}

// vcrRunningTime draws the time the scrub dot stands for, centred in the
// room composeStaticVCR left for it.
func (p *Playing) vcrRunningTime(c *gfx.Canvas) {
	t := clock(int(p.scrubTo))
	c.PixelText(p.safeX()+(p.safeW()-vcrBig.Width(t))/2, p.timeY, vcrBig, vcrText, vcrShadow, t)
}

// composeSkipVCR is composeSkip's button in the VCR look.
func (p *Playing) composeSkipVCR(c *gfx.Canvas, label string) {
	c.Fill(0, 0, c.W, c.H, vcrBlue)
	label = strings.ToUpper(label)
	c.PixelText((c.W-vcrBig.Width(label))/2, (c.H-vcrBig.Height())/2, vcrBig, vcrText, vcrShadow, label)
}

// drawListVCR is uploadList's column in the VCR look, from column row base.
func (p *Playing) drawListVCR(c *gfx.Canvas, base int) {
	l := p.list
	c.Fill(0, 0, c.W, c.H, vcrBlue)
	x := p.menuX()
	if base == 0 {
		title := l.kind
		if l.hint != "" {
			title += " (" + l.hint + ")"
		}
		f := vcrBig
		if f.Width(title) > OsdListW-x-OsdListPad {
			f = vcrSmall
		}
		c.PixelText(x, 18, f, vcrText, vcrShadow, f.Fit(title, OsdListW-x-OsdListPad))
	}
	for i, item := range l.items {
		y := OsdListTop + i*OsdListRowH - base
		if y+OsdListRowH <= 0 || y >= c.H {
			continue
		}
		left, right := p.listArrows(l, i)
		arrowsW := 0
		if left != arrowNone || right != arrowNone {
			arrowsW = vcrArrowsW
		}
		v := ""
		if i < len(l.vals) {
			v = strings.ToUpper(l.vals[i])
		}
		item, v = listRowText(vcrSmall, x, item, v, arrowsW)
		c.PixelText(x, y+2, vcrSmall, vcrText, vcrShadow, item)
		if i == l.set {
			c.PixelText(OsdListW-34, y+2, vcrSmall, vcrText, vcrShadow, string(gfx.PixelTick))
		}
		vr := OsdListW - OsdListPad // the value's right edge
		if arrowsW > 0 {
			aw := vcrSmall.Width("<")
			vr -= aw + listArrowGap
			if col, ok := vcrArrowColour(left, i == l.cur); ok {
				c.PixelText(vr-vcrSmall.Width(v)-listArrowGap-aw, y+2, vcrSmall, col, vcrShadow, "<")
			}
			if col, ok := vcrArrowColour(right, i == l.cur); ok {
				c.PixelText(OsdListW-OsdListPad-aw, y+2, vcrSmall, col, vcrShadow, ">")
			}
		}
		if v != "" {
			c.PixelText(vr-vcrSmall.Width(v), y+2, vcrSmall, vcrLo, vcrShadow, v)
		}
	}
}

// vcrArrowsW is the room the VCR look's < and > take beside a value.
var vcrArrowsW = 2 * (vcrSmall.Width("<") + listArrowGap)

// vcrArrowColour is arrowColour in the VCR look, which has no greys: the
// highlight green on the cursor row, white as the value on the others,
// and at an end the blue of a key with nothing to do.
func vcrArrowColour(s arrowState, cursor bool) (gfx.Color, bool) {
	switch {
	case s == arrowNone:
		return 0, false
	case s == arrowEnd:
		return vcrOff, true
	case cursor:
		return vcrText, true
	}
	return vcrLo, true
}
