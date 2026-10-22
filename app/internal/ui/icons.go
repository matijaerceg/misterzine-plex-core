package ui

import "plexcrt/internal/gfx"

// The Icons look of the playback controls (Options > Playback UI theme) is
// the standard look with the bar's buttons drawn as small monochrome
// glyphs instead of words. Each glyph sits centred in the cell the word
// would take, so the cells, the focus bar and the colours are the
// standard look's own; only the drawing inside a cell differs.

// iconTiny is the block font for the "10" beside the skip arrows: one
// pixel wide, two tall, so it reads at the glyphs' height.
var iconTiny = gfx.PixelFont{SX: 1, SY: 2}

// iconStroke is the glyphs' line thickness, one for the whole set.
const iconStroke = 2

// osdIcon draws the glyph for button label b (osdButtons' words, with
// "Play" for "Pause" while paused) inside the cell x, y, w, h. Every glyph
// takes the same height, the cell's (the Body font's) less a margin, so
// the set reads as one whatever the word's width; the wide ones use the
// cell's width, centred in it.
func osdIcon(c *gfx.Canvas, b string, x, y, w, h int, col gfx.Color) {
	gh := h - 4 // the glyphs' height
	half := gh / 2
	cy := y + h/2
	cx := x + w/2
	st := iconStroke
	switch b {
	case "-10", "+10":
		// two arrows and the 10 beside them, the arrows on the side they point
		tw := min(half, (w-iconTiny.Width("10")-st)/2)
		ah := min(half, tw)
		gw := 2*tw + st + iconTiny.Width("10")
		lx := x + (w-gw)/2
		ty := cy - iconTiny.Height()/2
		if b == "-10" {
			triangle(c, lx, cy, tw, ah, false, col)
			triangle(c, lx+tw, cy, tw, ah, false, col)
			c.PixelText(lx+2*tw+st, ty, iconTiny, col, col, "10")
		} else {
			c.PixelText(lx, ty, iconTiny, col, col, "10")
			ax := lx + iconTiny.Width("10") + st
			triangle(c, ax, cy, tw, ah, true, col)
			triangle(c, ax+tw, cy, tw, ah, true, col)
		}
	case "Pause":
		bw := 2 * st
		c.Fill(cx-st-bw, cy-half, bw, 2*half+1, col)
		c.Fill(cx+st, cy-half, bw, 2*half+1, col)
	case "Play":
		tw := half + half/2
		triangle(c, cx-tw/2, cy, tw, half, true, col)
	case "Prev", "Next":
		tw := half + half/2
		lx := cx - (tw+st)/2
		if b == "Prev" {
			c.Fill(lx, cy-half, st, 2*half+1, col)
			triangle(c, lx+st, cy, tw, half, false, col)
		} else {
			triangle(c, lx, cy, tw, half, true, col)
			c.Fill(lx+tw, cy-half, st, 2*half+1, col)
		}
	case "Audio":
		// a speaker: its box in outline, the cone flaring right, two waves
		bw, bh := 7, half
		cw := half - 2
		r1, r2 := half/2, half
		gw := bw + cw + 3 + st + 3 + st
		lx := cx - gw/2
		c.Frame(lx, cy-bh/2, bw, bh, st, col)
		triangle(c, lx+bw-1, cy, cw, half, false, col)
		ax := lx + bw + cw + 3
		wave(c, ax, cy, r1, col)
		wave(c, ax+st+3, cy, r2, col)
	case "Subs":
		// a caption box with two lines of text in it
		bw := min(w, 2*gh)
		bx, by := cx-bw/2, cy-half
		c.Frame(bx, by, bw, 2*half+1, st, col)
		c.Fill(bx+2*st+1, cy, bw-4*st-2, st, col)
		c.Fill(bx+2*st+1, cy+half-2*st-1, (bw-4*st-2)*3/5, st, col)
	case "More":
		d := 2 * st
		gap := d
		lx := cx - (3*d+2*gap)/2
		for i := range 3 {
			c.Fill(lx+i*(d+gap), cy-d/2, d, d, col)
		}
	}
}

// wave is a sound wave of radius r right of x: an upright stroke with its
// ends turned back, the way a bracket is drawn.
func wave(c *gfx.Canvas, x, cy, r int, col gfx.Color) {
	st := iconStroke
	c.Fill(x+st, cy-r+st, st, 2*(r-st)+1, col)
	c.Fill(x, cy-r, st, st, col)
	c.Fill(x, cy+r-st+1, st, st, col)
}

// triangle fills a triangle with its point at x (right) or x+w-1 (left)
// along row cy, its base half (2*half+1 rows) at the other end, column
// by column.
func triangle(c *gfx.Canvas, x, cy, w, half int, right bool, col gfx.Color) {
	if w <= 0 {
		return
	}
	for i := range w {
		// the column's distance from the base, base first
		d := i
		if !right {
			d = w - 1 - i
		}
		hh := half * (w - d) / w
		c.Fill(x+i, cy-hh, 1, 2*hh+1, col)
	}
}
