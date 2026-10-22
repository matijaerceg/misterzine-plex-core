package ui

import (
	"time"

	"plexcrt/internal/gfx"
)

// Wrappers only the tests call: the app uses the pieces they join.

// nextWant takes the next artwork request with background work allowed.
// Called under mu.
func (a *Art) nextWant() (artReq, bool) { return a.nextRequest(true) }

// compose draws the whole page into c: the still layer, then the column.
func (p *Preplay) compose(c *gfx.Canvas, now time.Time) bool {
	st := p.still(c.W, c.H)
	y := p.drawStill(c, &st)
	return p.drawColumn(c, y, now) || st.fading()
}

// drawPage composes the header (backdrop strip, logo, facts) once per
// season and picture state, cross-fading between states.
func (s *Season) drawPage(c *gfx.Canvas, now time.Time) bool {
	show, fading := s.preparePage(c, now)
	return s.paintPage(c, show, fading, now)
}

// drawSubtitle paints lines on fresh storage (subtitlePaint.draw).
func drawSubtitle(lines []string, size, w int) (*gfx.Canvas, []byte) {
	return new(subtitlePaint).draw(lines, size, w)
}
