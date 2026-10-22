package ui

import (
	"slices"
	"strings"
	"testing"

	"plexcrt/internal/gfx"
)

// Each Icons-look button paints inside its cell (the word's width, or the
// glyph's where wider) and nowhere else, and the paused bar shows a
// different glyph from the playing one.
func TestIconButtonsStayInTheirCells(t *testing.T) {
	a := betaTestApp(t)
	f := a.F.Body
	paint := func(b string) (*gfx.Canvas, int, int, int, int) {
		c := gfx.NewCanvas(200, 80)
		c.Fill(0, 0, c.W, c.H, gfx.Bg)
		x, y, w, h := 60, 25, iconCellW(a.F, b), f.Height()
		osdIcon(c, a.F, b, x, y, w, h, gfx.White)
		return c, x, y, w, h
	}
	lit := func(c *gfx.Canvas, x, y int) bool {
		i := (y*c.W + x) * 4
		return gfx.Color(c.Pix[i+2])<<16|gfx.Color(c.Pix[i+1])<<8|gfx.Color(c.Pix[i]) != gfx.Bg
	}
	for _, b := range append(slices.Clone(osdButtons), "Play") {
		c, x0, y0, w, h := paint(b)
		in := 0
		for y := range c.H {
			for x := range c.W {
				if !lit(c, x, y) {
					continue
				}
				if x < x0 || x >= x0+w || y < y0 || y >= y0+h {
					t.Fatalf("%s: painted at %d,%d outside its cell %d,%d %dx%d", b, x, y, x0, y0, w, h)
				}
				in++
			}
		}
		if in == 0 {
			t.Fatalf("%s: painted nothing in its cell", b)
		}
	}
	play, _, _, _, _ := paint("Play")
	pause, _, _, _, _ := paint("Pause")
	if slices.Equal(play.Pix, pause.Pix) {
		t.Fatal("the paused glyph is the playing one")
	}
}

// The Icons look keeps the standard look's row and gap: a cell is the
// word's width or, where the glyph is wider, the glyph's (never narrower
// than the word), the row stays centred, and the focus bar follows the
// cell. The paused bar draws differently.
func TestIconsLookCellsHoldTheirGlyphs(t *testing.T) {
	a := betaTestApp(t)
	cells := func(look string, paused bool) ([]int, []int, int, []byte) {
		a.Cfg.PlaybackLook = look
		p := playingCrop(a, 1.78)
		p.paused = paused
		p.dur, p.pos = 1800, 600
		p.canvas, p.alpha = gfx.NewCanvas(720, 480), make([]byte, 720*480)
		p.compose(false)
		p.sprites()
		if p.barX != p.btnX[p.focus] || p.barW != p.btnW[p.focus] {
			t.Fatalf("%s: the focus bar %d+%d is not its cell %d+%d", look, p.barX, p.barW, p.btnX[p.focus], p.btnW[p.focus])
		}
		return slices.Clone(p.btnX[:]), slices.Clone(p.btnW[:]), p.btnY, slices.Clone(p.static.Pix)
	}
	for _, paused := range []bool{false, true} {
		_, sw, sy, _ := cells("", paused)
		ix, iw, iy, _ := cells("icons", paused)
		if sy != iy {
			t.Fatalf("paused %v: icon row at %d, standard at %d", paused, iy, sy)
		}
		for i, b := range osdButtons {
			if b == "Pause" && paused {
				b = "Play"
			}
			if iw[i] < sw[i] || iw[i] != iconCellW(a.F, b) {
				t.Errorf("paused %v: %s cell %d wide, word %d, want %d", paused, b, iw[i], sw[i], iconCellW(a.F, b))
			}
			if i > 0 && ix[i] != ix[i-1]+iw[i-1]+OsdBtnGap {
				t.Errorf("paused %v: %s at %d, not a gap after the cell before", paused, b, ix[i])
			}
		}
		n := len(osdButtons) - 1
		if left, right := ix[0], 720-(ix[n]+iw[n]); abs(left-right) > 1 {
			t.Errorf("paused %v: the row is off centre, %d left and %d right", paused, left, right)
		}
	}
	_, _, _, playing := cells("icons", false)
	_, _, _, paused := cells("icons", true)
	if slices.Equal(playing, paused) {
		t.Fatal("pausing did not change the icon bar")
	}
	a.Cfg.PlaybackLook = "icons"
	if a.Cfg.vcr() || !a.Cfg.icons() {
		t.Fatal("the Icons look is not the standard path with icons")
	}
}

// The skip button shares the alpha plane's first rows with the panel: the
// panel that follows it still has its top edge eased in.
func TestPanelAfterSkipButtonKeepsItsEasedEdge(t *testing.T) {
	a := betaTestApp(t)
	p := playingCrop(a, 1.78)
	p.dur, p.pos = 1800, 600
	p.canvas, p.alpha = gfx.NewCanvas(720, 480), make([]byte, 720*480)
	p.compose(false) // the panel once, so its alpha is drawn
	p.composeSkip()
	p.compose(false)
	w := p.canvas.W
	for x := range w {
		if p.alpha[x] >= OsdAlpha {
			t.Fatalf("panel row 0 at %d has alpha %d, want the eased edge under %d", x, p.alpha[x], OsdAlpha)
		}
		if a := p.alpha[20*w+x]; a != OsdAlpha {
			t.Fatalf("panel row 20 at %d has alpha %d, want %d", x, a, OsdAlpha)
		}
	}
}

// A long list item never runs into its right-aligned value, in either
// painter's font.
func TestListItemClearsItsValue(t *testing.T) {
	a := betaTestApp(t)
	x := playingCrop(a, 1.78).menuX()
	right := OsdListW - OsdListPad
	items := []string{"Surround downmix boost", "Skip intro and credits buttons", strings.Repeat("W", 60)}
	vals := []string{"300%", "Default", "Fill", "Some much longer value"}
	for _, item := range items {
		for _, v := range vals {
			f := a.F.Body
			if end, start := x+f.Width(f.Fit(item, listItemW(x, f.Width(v)))), right-f.Width(v); end >= start {
				t.Errorf("%q with %q: item ends at %d, value starts at %d", item, v, end, start)
			}
			u := strings.ToUpper(v)
			if end, start := x+vcrSmall.Width(vcrSmall.Fit(item, listItemW(x, vcrSmall.Width(u)))), right-vcrSmall.Width(u); end >= start {
				t.Errorf("VCR %q with %q: item ends at %d, value starts at %d", item, u, end, start)
			}
		}
	}
}

// Every bar label has a Lucide mask no taller than the Body font, inside
// its cell, and the jump buttons' arrow with its Body-font "10" fits too.
func TestIconMasksFitTheBar(t *testing.T) {
	a := betaTestApp(t)
	f := a.F.Body
	for _, b := range append(slices.Clone(osdButtons), "Play") {
		m := iconMask(b)
		if m == nil {
			t.Fatalf("%s: no mask", b)
		}
		if m.Rect.Dy() > f.Height() || m.Rect.Dx() > iconCellW(a.F, b) {
			t.Errorf("%s: mask %v too big for its %dx%d cell", b, m.Rect.Size(), iconCellW(a.F, b), f.Height())
		}
	}
	for _, b := range []string{"-10", "+10"} {
		if w := iconMask(b).Rect.Dx() + iconJumpGap + tenWidth(f); w > iconCellW(a.F, b) {
			t.Errorf("%s: arrow and Body 10 take %d of a %d cell", b, w, iconCellW(a.F, b))
		}
	}
}

// The transport glyphs are solid: the middle of play's triangle, of each
// pause bar and of the skip triangles is lit, where an outline would
// leave a hole.
func TestTransportIconsAreFilled(t *testing.T) {
	for b, xs := range map[string][]float64{"Play": {0.4}, "Pause": {0.2, 0.8}, "Prev": {0.65}, "Next": {0.35}} {
		m := iconMask(b)
		w, h := m.Rect.Dx(), m.Rect.Dy()
		for _, fx := range xs {
			x := int(fx * float64(w))
			if v := m.GrayAt(x, h/2).Y; v < 200 {
				t.Errorf("%s: %d,%d of %dx%d is %d, not filled", b, x, h/2, w, h, v)
			}
		}
	}
}
