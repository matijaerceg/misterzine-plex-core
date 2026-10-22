package ui

import (
	"slices"
	"strings"
	"testing"

	"plexcrt/internal/gfx"
)

// Each Icons-look button paints inside the cell its word would take and
// nowhere else, and the paused bar shows a different glyph from the
// playing one.
func TestIconButtonsStayInTheirCells(t *testing.T) {
	a := betaTestApp(t)
	f := a.F.Body
	paint := func(b string) (*gfx.Canvas, int, int, int, int) {
		c := gfx.NewCanvas(200, 80)
		c.Fill(0, 0, c.W, c.H, gfx.Bg)
		x, y, w, h := 60, 25, f.Width(b), f.Height()
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

// The Icons look keeps the standard look's cells: only the drawing in
// them differs, and the paused bar draws differently.
func TestIconsLookKeepsTheStandardCells(t *testing.T) {
	a := betaTestApp(t)
	cells := func(look string, paused bool) ([]int, []int, int, []byte) {
		a.Cfg.PlaybackLook = look
		p := playingCrop(a, 1.78)
		p.paused = paused
		p.dur, p.pos = 1800, 600
		p.canvas, p.alpha = gfx.NewCanvas(720, 480), make([]byte, 720*480)
		p.compose(false)
		return slices.Clone(p.btnX[:]), slices.Clone(p.btnW[:]), p.btnY, slices.Clone(p.static.Pix)
	}
	for _, paused := range []bool{false, true} {
		sx, sw, sy, _ := cells("", paused)
		ix, iw, iy, _ := cells("icons", paused)
		if !slices.Equal(sx, ix) || !slices.Equal(sw, iw) || sy != iy {
			t.Fatalf("paused %v: icon cells %v %v %d, standard %v %v %d", paused, ix, iw, iy, sx, sw, sy)
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

// Every bar label has a Lucide mask no taller than the glyph height (the
// Body font's less 4), and the jump buttons' "10" fits beside its arrow in
// the Body font, as the rest of the bar's words are set.
func TestIconMasksFitTheBar(t *testing.T) {
	a := betaTestApp(t)
	f := a.F.Body
	for _, b := range append(slices.Clone(osdButtons), "Play") {
		m := iconMask(b)
		if m == nil {
			t.Fatalf("%s: no mask", b)
		}
		if m.Rect.Dy() > f.Height()-4 || m.Rect.Dx() > f.Width(b) {
			t.Errorf("%s: mask %v too big for its %dx%d cell", b, m.Rect.Size(), f.Width(b), f.Height())
		}
	}
	for _, b := range []string{"-10", "+10"} {
		if w := iconMask(b).Rect.Dx() + iconJumpGap + tenWidth(f); w > f.Width(b) {
			t.Errorf("%s: arrow and Body 10 take %d of a %d cell", b, w, f.Width(b))
		}
	}
}
