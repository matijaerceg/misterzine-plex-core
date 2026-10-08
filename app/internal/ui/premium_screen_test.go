package ui

import (
	"testing"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/ring"
)

// paintedScreen paints the whole frame one colour.
type paintedScreen struct{ col gfx.Color }

func (s *paintedScreen) Key(input.Event, time.Time) {}
func (s *paintedScreen) Draw(c *gfx.Canvas, _ time.Time) bool {
	c.Fill(0, 0, c.W, c.H, s.col)
	return true
}

// fullPaintedScreen is one that takes the whole picture, as a screensaver does.
type fullPaintedScreen struct{ paintedScreen }

func (*fullPaintedScreen) fullScreen() {}

func TestFullScreenHasNoMarks(t *testing.T) {
	a := betaTestApp(t) // a beta build: the BETA mark goes over every page
	marked := func(s Screen) bool {
		a.stack = []Screen{s}
		c := gfx.NewCanvas(720, 480)
		a.drawScreen(c, time.Now())
		for i := 0; i < len(c.Pix); i += 4 {
			if c.Pix[i] != 0 || c.Pix[i+1] != 0 || c.Pix[i+2] != 0 {
				return true
			}
		}
		return false
	}
	if !marked(&paintedScreen{gfx.Black}) {
		t.Fatal("no BETA mark over an ordinary page: the test cannot tell")
	}
	if marked(&fullPaintedScreen{paintedScreen{gfx.Black}}) {
		t.Fatal("a mark drawn over a full screen")
	}
}

func TestPausedPlaybackStillDims(t *testing.T) {
	a, out, _ := dimApp()
	a.playing = true // paused: for the extras this is not the menus waiting
	t0 := time.Now()
	a.idle(t0, true)
	a.idle(t0.Add(DimAfter-time.Second), true)
	if out.level != ring.Full {
		t.Fatal("dimmed early")
	}
	a.idle(t0.Add(DimAfter), true)
	if out.level != DimLevel {
		t.Fatal("a paused playback did not dim")
	}
}
