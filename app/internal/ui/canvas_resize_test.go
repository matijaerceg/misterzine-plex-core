package ui

import (
	"io"
	"log"
	"testing"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/plex"
)

type resizeOut struct{ *fakeOut }

func (*resizeOut) LayoutCanvasSize() (int, int) { return 960, 480 }

func TestHomeRebuildsPageAfterCanvasResize(t *testing.T) {
	a := &App{
		Cfg: &Config{NoTheme: true},
		F:   appFonts(),
		Art: NewArt(nil, 0, nil),
		Log: log.New(io.Discard, "", 0),
	}
	a.T = gfx.NewTextCache(1, nil)
	a.Mark = NewWordmark()
	a.Out = &resizeOut{fakeOut: &fakeOut{c: gfx.NewCanvas(720, 480)}}
	h := &Home{app: a, home: true, preloadAfter: time.Now().Add(time.Hour)}
	h.setHubs([]*plex.Hub{{Title: "Recently Added", Items: []*plex.Item{{RatingKey: "one", Type: "movie", Title: "A title"}}}})
	now := time.Now()
	h.Draw(gfx.NewCanvas(720, 480), now)
	if h.page == nil || h.page.W != 720 {
		t.Fatalf("initial page size = %v, want 720 wide", h.page)
	}
	h.Draw(gfx.NewCanvas(960, 480), now.Add(time.Second))
	if h.page == nil || h.page.W != 960 || h.page.H != 480 {
		t.Fatalf("resized page is %v, want 960x480", h.page)
	}
}

func TestFadePoolResizesWithCanvas(t *testing.T) {
	warmFades(720, 480)
	f := &Fade{}
	f.Start(gfx.NewCanvas(960, 480), gfx.NewCanvas(960, 480), time.Now())
	t.Cleanup(f.Done)
	if len(f.steps) == 0 || f.steps[0].W != 960 || f.steps[0].H != 480 {
		t.Fatalf("fade step canvas = %v, want 960x480", f.steps[0])
	}
}

// The step canvases are made for the canvas the display asks for at the
// start, and again, off the render thread, when it changes: a fade then
// finds them ready instead of making them mid-frame. A fade still running
// at the old size keeps its own.
func TestFadePoolIsWarmedForTheLayoutCanvas(t *testing.T) {
	pooled := func(w, h int) func() bool {
		return func() bool {
			fadePoolMu.Lock()
			defer fadePoolMu.Unlock()
			return fadePoolW == w && fadePoolH == h && len(fadePool) >= fadeSlots
		}
	}
	New(nil, &resizeOut{fakeOut: &fakeOut{c: gfx.NewCanvas(960, 480)}}, nil, log.New(io.Discard, "", 0))
	if !pooled(960, 480)() {
		t.Fatalf("the pool was warmed for %dx%d, not the 960x480 layout", fadePoolW, fadePoolH)
	}
	warmFadesFor(720, 480) // the display went 4:3
	waitUntil(t, "the pool for 720x480", pooled(720, 480))
	fadePoolMu.Lock()
	first := fadePool[0]
	fadePoolMu.Unlock()
	f := &Fade{}
	f.Start(gfx.NewCanvas(720, 480), gfx.NewCanvas(720, 480), time.Now().Add(time.Hour)) // the worker waits
	t.Cleanup(f.Done)
	if f.steps[0] != first {
		t.Fatal("the fade made its own canvases")
	}
	warmFadesFor(960, 480)
	waitUntil(t, "the pool for 960x480", pooled(960, 480))
	if f.steps[0] != first || f.steps[0].W != 720 {
		t.Fatal("warming took the canvases of a fade still running")
	}
}
