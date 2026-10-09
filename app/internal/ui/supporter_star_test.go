package ui

import (
	"slices"
	"testing"
	"time"

	"plexcrt/internal/access"
	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
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

// A starred value has the purple star after it, the selected row's arrows
// staying where they are and the value moving over; dim greys the value
// and leaves the row live. The label keeps the star's room either way.
func TestOptionsStarredValue(t *testing.T) {
	a := betaTestApp(t)
	const label = "Starred: a setting whose label runs on well past its value"
	starOn, dim, steps, opened := true, false, 0, 0
	withExtraOptions(t, func(a *App) []option {
		at := func() (int, int) { return 1, 3 }
		return []option{
			{label: label, val: func() string { return "Choice" }, step: func(d int) { steps += d }, at: at,
				starred: func() (bool, bool) { return starOn, dim }, do: func() { opened++ }},
			{label: "Plain", val: func() string { return "Choice" }, step: func(int) {}, at: at},
		}
	})
	o := NewOptions(a)
	a.Push(o)
	c := gfx.NewCanvas(720, 480)
	body, star := a.F.Body, supporterStar()
	_, capTop, _, capH := body.InkBounds("H")
	// valueRight is the rightmost column in col of the row whose text
	// starts at y, right of the label's half and left of the right arrow;
	// -1 for none
	valueRight := func(y int, col gfx.Color) int {
		for x := MenuRight - stepArrowW - 1; x >= MenuX+MenuWidth/2; x-- {
			for yy := y; yy < y+body.Height(); yy++ {
				if optionPixel(c, x, yy) == col {
					return x
				}
			}
		}
		return -1
	}
	// labelled reports whether the row whose text starts at y shows its
	// label's first letters in col
	labelled := func(y int, col gfx.Color) bool {
		for yy := y; yy < y+body.Height(); yy++ {
			for x := MenuX; x < MenuX+40; x++ {
				if optionPixel(c, x, yy) == col {
					return true
				}
			}
		}
		return false
	}
	// rowAt draws Options, the row labelled l selected or the one below
	// it, until the row's label and its value in col are drawn (text is
	// cached off-thread), and returns where the row's text starts
	rowAt := func(l string, selected bool, col gfx.Color) int {
		row := optionRow(o, l)
		o.cur = row
		labelCol := gfx.White
		if !selected {
			o.cur++
			labelCol = gfx.GreyHi
		}
		for range 400 {
			o.Draw(c, time.Now())
			y := ListY0 + focusY(c) + 9
			if !selected {
				y -= MenuRowH
			}
			if labelled(y, labelCol) && valueRight(y, col) >= 0 {
				return y
			}
			time.Sleep(5 * time.Millisecond)
		}
		t.Fatalf("%q: no value drawn", l)
		return 0
	}
	// purple counts the star's pixels with its right edge at right
	purple := func(right, y int) int {
		n := 0
		y0 := y + capTop + capH/2 - star.H/2
		for yy := y0; yy < y0+star.H; yy++ {
			for x := right - star.W; x < right; x++ {
				if optionPixel(c, x, yy) == gfx.Purple {
					n++
				}
			}
		}
		return n
	}
	moved := star.W + supporterStarGap // how far a star moves the value
	plain := valueRight(rowAt("Plain", true, gfx.Amber), gfx.Amber)
	arrows := func(y, valueEnd int) (left, right gfx.Color) {
		mid := y + body.Height()/2
		return optionPixel(c, valueEnd-body.Width("Choice")-stepArrowW+5, mid), optionPixel(c, MenuRight-6, mid)
	}

	// the star, selected: after the value, inside the arrows
	y := rowAt(label, true, gfx.Amber)
	if n := purple(MenuRight-stepArrowW, y); n < star.W*star.H/5 {
		t.Fatalf("the selected starred value's star has %d purple pixels", n)
	}
	if got := valueRight(y, gfx.Amber); got != plain-moved {
		t.Fatalf("the starred value ends at %d, want %d (the plain one's %d less the star and its gap)", got, plain-moved, plain)
	}
	if l, r := arrows(y, MenuRight-stepArrowW-moved); l != gfx.Amber || r != gfx.Amber {
		t.Fatalf("the starred value's arrows: %06x and %06x", l, r)
	}
	labelBand := func(y int) []gfx.Color {
		// the label's room, the narrowest it is: the value and its star
		// with the arrows either side, and the space before them
		var px []gfx.Color
		for yy := y; yy < y+body.Height(); yy++ {
			for x := MenuX; x < MenuRight-body.Width("Choice")-24-2*stepArrowW-moved; x++ {
				px = append(px, optionPixel(c, x, yy))
			}
		}
		return px
	}
	withStar := labelBand(y)
	if !slices.Contains(withStar, gfx.White) {
		t.Fatal("the selected starred row's label is not drawn")
	}

	// not selected: the star at the right edge, the value before it
	y = rowAt(label, false, gfx.Amber)
	if n := purple(MenuRight, y); n < star.W*star.H/5 {
		t.Fatalf("the starred value's star, not selected, has %d purple pixels", n)
	}
	if got, want := valueRight(y, gfx.Amber), plain+stepArrowW-moved; got != want {
		t.Fatalf("the starred value, not selected, ends at %d, want %d", got, want)
	}

	// dim: the value greyed in the same place, the row still live
	dim = true
	y = rowAt(label, true, gfx.GreyLo)
	if got := valueRight(y, gfx.GreyLo); got != plain-moved {
		t.Fatalf("the dimmed value ends at %d, want %d", got, plain-moved)
	}
	if got, valueStart := valueRight(y, gfx.Amber), plain-moved-body.Width("Choice"); got >= valueStart {
		t.Fatalf("the dimmed value has amber at %d, right of where it starts (%d)", got, valueStart)
	}
	if n := purple(MenuRight-stepArrowW, y); n < star.W*star.H/5 {
		t.Fatalf("the dimmed value's star has %d purple pixels", n)
	}
	if l, r := arrows(y, MenuRight-stepArrowW-moved); l != gfx.Amber || r != gfx.Amber {
		t.Fatalf("the dimmed value's arrows: %06x and %06x", l, r)
	}
	pressOption(t, o, label, input.Right)
	pressOption(t, o, label, input.Enter)
	if steps != 1 || opened != 1 {
		t.Fatalf("a dimmed value's row: Right stepped %d, OK ran its action %d times", steps, opened)
	}

	// no star: none drawn, the value where the plain one is, the label the same
	starOn, dim = false, false
	y = rowAt(label, true, gfx.Amber)
	if n := purple(MenuRight-stepArrowW, y); n != 0 {
		t.Fatalf("an unstarred value has %d purple pixels in the star's place", n)
	}
	if got := valueRight(y, gfx.Amber); got != plain {
		t.Fatalf("the unstarred value ends at %d, want the plain one's %d", got, plain)
	}
	if !slices.Equal(labelBand(y), withStar) {
		t.Fatal("the label changed as the value's star went")
	}
}
