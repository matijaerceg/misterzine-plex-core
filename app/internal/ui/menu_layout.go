package ui

import "plexcrt/internal/gfx"

// Menu content sits farther inside the raster for CRT overscan.
const (
	MenuX      = SafeX + 24
	MenuRight  = SafeX + SafeW - 24
	MenuWidth  = MenuRight - MenuX
	MenuRowH   = 32
	MenuBarGap = 8
)

func menuFocusBar(c *gfx.Canvas, x, y, h int) {
	c.Fill(x-MenuBarGap-BarW, y+2, BarW, h-4, gfx.GreyHi)
}

// menuScrollbar is the library wall's scrollbar, in the same place, for a
// list shown a window at a time: the track spans the window and the handle
// covers the rows in view. A list that fits gets none.
func menuScrollbar(c *gfx.Canvas, y, h, first, visible, total int) {
	if total <= visible {
		return
	}
	thumbH := max(20, h*visible/total)
	thumbY := y + (h-thumbH)*first/(total-visible)
	c.Fill(WallBarX, y, WallBarW, h, gfx.Bar)
	c.Fill(WallBarX, thumbY, WallBarW, thumbH, gfx.GreyLo)
}
