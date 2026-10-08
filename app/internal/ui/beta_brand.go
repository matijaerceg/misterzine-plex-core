package ui

import (
	"plexcrt/internal/beta"
	"plexcrt/internal/gfx"
)

// drawBrand is applied to browsing frames only, never player overlays: the
// BETA mark on a beta build, and on Home an UPDATE mark beside it while an
// update waits under Options.
func (a *App) drawBrand(c *gfx.Canvas) {
	x, y := SafeX+SafeW-2-betaBadgeW, SafeY
	switch a.top().(type) {
	case *Home:
		x = SafeX + 16 // where the wordmark starts, when Home has none
		if a.premiumHomeLogo() {
			x += a.Mark.W + 12
		}
	case *Login:
		x = SafeX + 16 + a.Mark.W + 12
	case *Drawer:
		return // drawn on the moving drawer panel
	}
	for _, m := range a.brandMarks() {
		im := a.mark(m.text, m.fill)
		c.Blit(x, y, im)
		x += im.W + 6
	}
}

type brandMark struct {
	text string
	fill gfx.Color
}

// brandMarks is what drawBrand shows over the top screen, left to right.
func (a *App) brandMarks() []brandMark {
	var marks []brandMark
	if beta.IsBeta() {
		marks = append(marks, brandMark{"BETA", gfx.Amber})
	}
	if _, home := a.top().(*Home); home && a.updateAvailable() {
		marks = append(marks, brandMark{"UPDATE", gfx.Purple})
	}
	return marks
}

// A mark is drawn 28 px high with the 18 px bold face, then shrunk to 16 so
// it reads as a mark rather than a label: BETA goes from 72 x 28 to 41 x 16.
const betaBadgeW, betaBadgeH = 41, 16

func (a *App) betaBadge(c *gfx.Canvas, x, y int) {
	c.Blit(x, y, a.mark("BETA", gfx.Amber))
}

// mark renders a text mark once. The text is centred on its ink, not its
// font cell: capitals have no descenders, and the cell's room for them
// would leave the word sitting high.
func (a *App) mark(text string, fill gfx.Color) *gfx.Image {
	if im := a.marks[text]; im != nil {
		return im
	}
	f := gfx.Load("bold18")
	left, top, iw, ih := f.InkBounds(text)
	w, h := iw+22, 28
	c := gfx.NewCanvas(w, h)
	c.Fill(0, 0, w, h, fill)
	c.Text((w-iw)/2-left, (h-ih)/2-top, f, gfx.Bg, text)
	full := &gfx.Image{W: w, H: h, Pix: c.Pix}
	im := full.Shrink((w*betaBadgeW+36)/72, betaBadgeH)
	if a.marks == nil {
		a.marks = map[string]*gfx.Image{}
	}
	a.marks[text] = im
	return im
}
