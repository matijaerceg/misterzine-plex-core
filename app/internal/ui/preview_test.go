package ui

import (
	"strings"
	"testing"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
)

// fakePreview has a frame for every time, once ready.
type fakePreview struct {
	ready  bool
	img    *gfx.Image
	near   float64
	closed bool
}

func (f *fakePreview) Frame(float64) *gfx.Image {
	if !f.ready {
		return nil
	}
	return f.img
}
func (f *fakePreview) Near(t float64) { f.near = t }
func (f *fakePreview) Close()         { f.closed = true }

func previewPlaying(t *testing.T) (*Playing, *fakePreview, *[]string) {
	p := waitPlaying(t)
	w, h := previewSize(720, 480)
	fp := &fakePreview{ready: true, img: &gfx.Image{W: w, H: h, Pix: make([]byte, w*h*4)}}
	p.preview, p.pvTried = fp, true
	sent := &[]string{}
	p.send = func(cmd string) { *sent = append(*sent, strings.Fields(cmd)[0]) }
	return p, fp, sent
}

func TestPreviewSizeShowsSixteenByNine(t *testing.T) {
	if w, h := previewSize(720, 480); w != 180 || h != PreviewH {
		t.Fatalf("720x480: %dx%d", w, h)
	}
	if w, _ := previewSize(640, 480); w != 160 {
		t.Fatalf("640x480: %d", w)
	}
}

func TestPreviewStaysInTheSafeArea(t *testing.T) {
	const sx, sw, ow = 36, 648, 184
	for _, c := range []struct{ dot, want int }{
		{sx, sx},                     // the start of the bar
		{sx + 50, sx},                // still too near it
		{360, 360 - ow/2},            // the middle: centred
		{sx + sw, sx + sw - ow},      // the end
		{sx + sw - 30, sx + sw - ow}, // near it
		{sx + sw + 40, sx + sw - ow}, // past it
		{sx - 40, sx},                // before it
		{sx + ow/2 + 1, sx + 1},      // just free of the start
		{sx + sw - ow/2 - 1, sx + sw - ow - 1},
	} {
		if got := previewX(c.dot, ow, sx, sw); got != c.want {
			t.Errorf("dot at %d: frame at %d, want %d", c.dot, got, c.want)
		}
	}
}

// hold presses Right with the controls hidden, holds it for d, lets go
// and runs the fields through the seek's grace.
func hold(p *Playing, c *coreOSD, now time.Time, d time.Duration, during func()) time.Time {
	keyAt(p, c, input.Right, now)
	end := now.Add(d)
	for now.Before(end) {
		now = tickFields(p, c, now, 1, nil)
		if during != nil {
			during()
		}
	}
	p.Key(input.Event{Key: input.Right, Release: true}, now)
	return tickFields(p, c, now, 40, nil)
}

func TestAHoldPausesShowsTheFrameAndResumesAfterItsSeek(t *testing.T) {
	p, fp, sent := previewPlaying(t)
	c := &coreOSD{}
	now := time.Now()
	p.framed(now)
	now = tickFields(p, c, now, 1, nil)
	lifted := false
	hold(p, c, now, time.Second, func() {
		if p.pvImg != nil && c.showH == p.peekStripH()+previewLift {
			lifted = true
			// the rows above the strip are clear but for the frame
			row := c.showAlpha[(previewLift-PreviewGap-2)*c.showW : (previewLift-PreviewGap-1)*c.showW]
			if row[0] != 0 || row[c.showW-1] != 0 || !strings.Contains(string(row), "\xff") {
				t.Fatal("the frame's rows are not clear around it")
			}
		}
	})
	if !lifted {
		t.Fatal("the hold never showed its frame above the strip")
	}
	if got := strings.Join(*sent, ","); got != "pause,resume,seek" {
		t.Fatalf("sent %s, want pause,resume,seek", got)
	}
	if p.paused || p.pvImg != nil || p.pvOn {
		t.Fatal("the preview or the pause outlived the seek")
	}
	if fp.near == 0 {
		t.Fatal("the backend was never told where the scrub is")
	}
	p.closePainter(c)
	if !fp.closed {
		t.Fatal("the end of the playback did not close the previews")
	}
}

func TestATapNeverPauses(t *testing.T) {
	p, _, sent := previewPlaying(t)
	c := &coreOSD{}
	now := time.Now()
	p.framed(now)
	now = tickFields(p, c, now, 1, nil)
	hold(p, c, now, 50*time.Millisecond, func() {
		if p.pvImg != nil {
			t.Fatal("a tap showed a frame")
		}
	})
	if got := strings.Join(*sent, ","); got != "seek" {
		t.Fatalf("a tap sent %s", got)
	}
}

func TestAPauseOfTheUsersOwnStays(t *testing.T) {
	p, _, sent := previewPlaying(t)
	c := &coreOSD{}
	now := time.Now()
	p.framed(now)
	p.paused = true
	now = tickFields(p, c, now, 1, nil)
	hold(p, c, now, time.Second, nil)
	if got := strings.Join(*sent, ","); got != "seek" || !p.paused {
		t.Fatalf("sent %s, paused %v", got, p.paused)
	}
}

func TestBackDuringAHoldResumesWithoutASeek(t *testing.T) {
	p, _, sent := previewPlaying(t)
	c := &coreOSD{}
	now := time.Now()
	p.framed(now)
	now = tickFields(p, c, now, 1, nil)
	keyAt(p, c, input.Right, now)
	now = tickFields(p, c, now, 40, nil)
	keyAt(p, c, input.Back, now)
	p.Key(input.Event{Key: input.Right, Release: true}, now)
	tickFields(p, c, now, 40, nil)
	if got := strings.Join(*sent, ","); got != "pause,resume" || p.paused || p.pvImg != nil {
		t.Fatalf("sent %s, paused %v", got, p.paused)
	}
}

// In the panel, the frame floats above it and the panel goes up by its rows.
func TestTheHoldOnThePanelLiftsIt(t *testing.T) {
	p, _, sent := previewPlaying(t)
	c := &coreOSD{}
	now := time.Now()
	p.framed(now)
	now = tickFields(p, c, now, 1, nil)
	keyAt(p, c, input.Up, now)
	now = tickFields(p, c, now, 2, nil)
	keyAt(p, c, input.Right, now)
	lifted := false
	for i := 0; i < 40; i++ {
		now = tickFields(p, c, now, 1, nil)
		if p.pvImg != nil && c.showY == p.osdY()-previewLift && c.showH == p.osdHeight()+previewLift {
			lifted = true
		}
	}
	p.Key(input.Event{Key: input.Right, Release: true}, now)
	tickFields(p, c, now, 40, nil)
	if !lifted {
		t.Fatal("the panel never rose for the frame")
	}
	if got := strings.Join(*sent, ","); got != "pause,resume,seek" {
		t.Fatalf("sent %s", got)
	}
}

// Without previews a hold is as it was: no pause.
func TestNoPreviewsNoPause(t *testing.T) {
	p, _, sent := previewPlaying(t)
	p.preview = nil
	c := &coreOSD{}
	now := time.Now()
	p.framed(now)
	now = tickFields(p, c, now, 1, nil)
	hold(p, c, now, time.Second, nil)
	if got := strings.Join(*sent, ","); got != "seek" {
		t.Fatalf("sent %s", got)
	}
}

// A hold before the backend has a frame (the file still downloading)
// pauses and resumes as any hold, with nothing drawn above the strip.
func TestAHoldBeforeTheFramesAreInDrawsNone(t *testing.T) {
	p, fp, sent := previewPlaying(t)
	fp.ready = false
	c := &coreOSD{}
	now := time.Now()
	p.framed(now)
	now = tickFields(p, c, now, 1, nil)
	hold(p, c, now, time.Second, func() {
		if p.pvImg != nil || p.lift() != 0 || c.shown && c.showH > p.peekStripH() {
			t.Fatal("a frame that was not ready was drawn")
		}
	})
	if got := strings.Join(*sent, ","); got != "pause,resume,seek" || p.paused {
		t.Fatalf("sent %s, paused %v", got, p.paused)
	}
}
