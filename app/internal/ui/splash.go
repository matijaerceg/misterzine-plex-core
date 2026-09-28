package ui

import (
	"time"

	"plexcrt/internal/gfx"
)

// drawScreen paints the top screen and the brand marks over it.
func (a *App) drawScreen(c *gfx.Canvas, now time.Time) bool {
	defer a.drawBrand(c)
	return a.top().Draw(c, now)
}
