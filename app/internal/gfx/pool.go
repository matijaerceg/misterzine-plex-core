package gfx

import "sync"

// Spare canvases for pop-overs (the menu, a chooser) that hold a snapshot
// of the screen beneath while they are open. Opening one used to allocate
// a frame (1.38 MB, zeroed and faulted in) in the key handler; taking a
// spare costs nothing, and its old pixels are about to be overwritten.
var (
	spareMu sync.Mutex
	spares  []*Canvas
)

const maxSpares = 4

// TakeCanvas returns a w x h canvas, a spare if one fits. Its pixels are
// whatever was last drawn into it.
func TakeCanvas(w, h int) *Canvas {
	spareMu.Lock()
	defer spareMu.Unlock()
	for i := len(spares) - 1; i >= 0; i-- { // the latest given: likeliest still cached
		if c := spares[i]; c.W == w && c.H == h {
			spares = append(spares[:i], spares[i+1:]...)
			return c
		}
	}
	return NewCanvas(w, h)
}

// GiveCanvas keeps a canvas for the next TakeCanvas of its size. The
// giver must not draw into it or show it afterwards.
func GiveCanvas(c *Canvas) {
	if c == nil {
		return
	}
	spareMu.Lock()
	defer spareMu.Unlock()
	for _, s := range spares {
		if s == c {
			return // given twice
		}
	}
	if len(spares) >= maxSpares {
		spares = spares[1:] // the oldest goes to the collector
	}
	spares = append(spares, c)
}

// Darken scales every byte of the canvas to bright/256 in place, with the
// vectorized blend (four pixels per step on the device).
func (c *Canvas) Darken(bright int) {
	img := &Image{W: c.W, H: c.H, Pix: c.Pix}
	c.BlendSolidClip(0, 0, img, Black, 256-bright, 0, 0, c.W, c.H)
}
