package ui

import (
	"testing"
	"time"

	"plexcrt/internal/access"
	"plexcrt/internal/gfx"
)

// A supporter extra's row, locked or not, has the purple star after its
// label, at the middle of the capitals; other rows have none.
func TestOptionsSupporterStar(t *testing.T) {
	registerTestGrant(t, 999903, "135791", "")
	a := betaTestApp(t)
	f := access.Feature{Premium: true, Since: 999903}
	withExtraOptions(t, func(a *App) []option {
		on := func() bool { return true }
		extra, _ := a.gated(option{label: "Extra", get: on, set: func(bool) {}}, f)
		return []option{extra, {label: "Plain", get: on, set: func(bool) {}}}
	})
	o := NewOptions(a)
	c := gfx.NewCanvas(720, 480)
	star := supporterStar()
	// purple pixels in the star's place after the label
	starred := func(label string) int {
		o.cur = optionRow(o, label)
		o.Draw(c, time.Now())
		_, top, _, h := a.F.Body.InkBounds("H")
		x0 := MenuX + a.F.Body.Width(label) + supporterStarGap
		y0 := ListY0 + focusY(c) + 9 + top + h/2 - star.H/2
		n := 0
		for y := y0; y < y0+star.H; y++ {
			for x := x0; x < x0+star.W; x++ {
				if optionPixel(c, x, y) == gfx.Purple {
					n++
				}
			}
		}
		return n
	}
	if row := o.items()[optionRow(o, "Extra")]; !row.locked || !row.supporter {
		t.Fatalf("the extra without a code: locked %v, supporter %v", row.locked, row.supporter)
	}
	if n := starred("Extra"); n < star.W*star.H/5 {
		t.Fatalf("a locked extra's star has %d purple pixels", n)
	}
	if n := starred("Plain"); n != 0 {
		t.Fatalf("a plain row has %d purple pixels after its label", n)
	}
	a.access = 999903
	if row := o.items()[optionRow(o, "Extra")]; row.locked || !row.supporter {
		t.Fatalf("the covered extra: locked %v, supporter %v", row.locked, row.supporter)
	}
	if n := starred("Extra"); n < star.W*star.H/5 {
		t.Fatalf("a covered extra's star has %d purple pixels", n)
	}
	// the star itself: a point at the top middle, none in the top corners,
	// as wide as 9/8 of its height allows
	at := func(x, y int) gfx.Color {
		p := (y*star.W + x) * 4
		return gfx.Color(star.Pix[p]) | gfx.Color(star.Pix[p+1])<<8 | gfx.Color(star.Pix[p+2])<<16
	}
	if at(star.W/2, 1) == gfx.Bg || at(0, 0) != gfx.Bg || at(star.W-1, 0) != gfx.Bg || star.W < star.H {
		t.Fatalf("the star is %dx%d, top middle %06x, corners %06x %06x", star.W, star.H, at(star.W/2, 1), at(0, 0), at(star.W-1, 0))
	}
}
