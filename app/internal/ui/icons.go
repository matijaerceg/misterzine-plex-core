package ui

import (
	"bytes"
	"embed"
	"image"
	"image/draw"
	"image/png"
	"sync"

	"plexcrt/internal/gfx"
)

// The Icons look of the playback controls (Options > Playback UI theme) is
// the standard look with the bar's buttons drawn as small monochrome
// glyphs instead of words. Each glyph sits centred in the cell the word
// would take, so the cells, the focus bar and the colours are the
// standard look's own; only the drawing inside a cell differs.
//
// The glyphs are Lucide icons (ISC licence, icons/LICENSE), rasterised
// ahead of time to anti-aliased coverage masks by tools/icons and tinted
// here with the button's colour. The bar glyphs are 21 pixels to Lucide's
// 24-unit grid, the Body font's height less 4; the jump arrows are
// smaller, to leave room for the "10" in the -10 and +10 cells.

//go:embed icons/*.png
var iconFS embed.FS

// iconFiles maps a button label to its mask.
var iconFiles = map[string]string{
	"-10":   "rotate-ccw",
	"+10":   "rotate-cw",
	"Pause": "pause",
	"Play":  "play",
	"Prev":  "skip-back",
	"Next":  "skip-forward",
	"Audio": "volume-2",
	"Subs":  "captions",
	"More":  "ellipsis",
}

var (
	iconOnce  sync.Once
	iconMasks map[string]*image.Gray
)

// iconMask is the decoded mask for button label b, decoded once for all.
func iconMask(b string) *image.Gray {
	iconOnce.Do(func() {
		iconMasks = map[string]*image.Gray{}
		for label, name := range iconFiles {
			data, err := iconFS.ReadFile("icons/" + name + ".png")
			if err != nil {
				panic(err)
			}
			img, err := png.Decode(bytes.NewReader(data))
			if err != nil {
				panic(name + ": " + err.Error())
			}
			g, ok := img.(*image.Gray)
			if !ok || g.Rect.Min != (image.Point{}) {
				g = image.NewGray(image.Rect(0, 0, img.Bounds().Dx(), img.Bounds().Dy()))
				draw.Draw(g, g.Rect, img, img.Bounds().Min, draw.Src)
			}
			iconMasks[label] = g
		}
	})
	return iconMasks[b]
}

// iconJumpGap is the space between a jump arrow and its "10", and
// between the 1 and the 0, set closer than the font's own spacing so the
// pair fits the narrow -10 cell beside the arrow.
const iconJumpGap = 1

// osdIcon draws the glyph for button label b (osdButtons' words, with
// "Play" for "Pause" while paused) centred in the cell x, y, w, h. The
// jump buttons put "10" beside the arrow, on the side away from where it
// points, in the Body font, or SmallBold (Medium: Regular flickers on
// 480i) should Body not fit the cell.
func osdIcon(c *gfx.Canvas, f Fonts, b string, x, y, w, h int, col gfx.Color) {
	m := iconMask(b)
	if m == nil {
		return
	}
	mw, mh := m.Rect.Dx(), m.Rect.Dy()
	cy := y + h/2
	if b != "-10" && b != "+10" {
		c.Mask(x+(w-mw)/2, cy-mh/2, m, col)
		return
	}
	font := f.Body
	if mw+iconJumpGap+tenWidth(font) > w {
		font = f.SmallBold
	}
	tw := tenWidth(font)
	gx := x + (w-(mw+iconJumpGap+tw))/2
	if b == "-10" {
		c.Mask(gx, cy-mh/2, m, col)
		ten(c, font, gx+mw+iconJumpGap, cy, col)
	} else {
		ten(c, font, gx, cy, col)
		c.Mask(gx+tw+iconJumpGap, cy-mh/2, m, col)
	}
}

// tenWidth is the ink width of ten's "10".
func tenWidth(f *gfx.Font) int {
	_, _, w1, _ := f.InkBounds("1")
	_, _, w0, _ := f.InkBounds("0")
	return w1 + iconJumpGap + w0
}

// ten draws "10" with its ink starting at x, centred on row cy, its digits
// iconJumpGap apart.
func ten(c *gfx.Canvas, f *gfx.Font, x, cy int, col gfx.Color) {
	l1, t1, w1, h1 := f.InkBounds("1")
	l0, t0, _, h0 := f.InkBounds("0")
	c.Text(x-l1, cy-h1/2-t1, f, col, "1")
	c.Text(x+w1+iconJumpGap-l0, cy-h0/2-t0, f, col, "0")
}
