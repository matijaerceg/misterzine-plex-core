package gfx

import (
	"sync"
	"time"
)

// TextCache renders text lines off the render thread. A line is an opaque
// strip (text over a known background) so drawing it is one memmove per
// row and never reads the destination, which matters when the destination
// is the write-combined frame ring. A long line not yet rendered is queued
// and simply absent for a frame; a short one is rendered on the spot.
//
// Lines live in two generations: new lines go into cur, and when cur is
// full it becomes old and the previous old is dropped. A line found in old
// moves back to cur, so whatever is drawn every frame survives the turn
// and only lines not drawn for a whole generation are lost.
type TextCache struct {
	mu       sync.Mutex
	cur, old map[textKey]*Image
	busy     map[textKey]bool
	work     chan textKey
	wake     chan struct{}
	gen      int // lines per generation
	syncAt   time.Time
	syncLeft int // characters still to render on the caller this field
}

type textKey struct {
	f       *Font
	s       string
	col, bg Color
}

// NewTextCache starts n render workers; wake is signalled as lines land.
func NewTextCache(n int, wake chan struct{}) *TextCache {
	const gen = 300 // two generations hold at most 600 lines
	tc := &TextCache{cur: make(map[textKey]*Image, gen), old: make(map[textKey]*Image, gen),
		busy: map[textKey]bool{}, work: make(chan textKey, 512), wake: wake, gen: gen}
	for i := 0; i < n; i++ {
		go tc.worker()
	}
	return tc
}

func renderLine(k textKey) *Image {
	w := k.f.Width(k.s) + 2
	if w < 2 {
		w = 2
	}
	c := NewCanvas(w, k.f.Height())
	c.Fill(0, 0, c.W, c.H, k.bg)
	c.Text(1, 0, k.f, k.col, k.s)
	return &Image{W: c.W, H: c.H, Pix: c.Pix}
}

// put stores a line; tc.mu is held.
func (tc *TextCache) put(k textKey, img *Image) {
	if len(tc.cur) >= tc.gen {
		clear(tc.old) // keeps its buckets, so turning over allocates nothing
		tc.cur, tc.old = tc.old, tc.cur
	}
	tc.cur[k] = img
}

// lookup finds a line in either generation; tc.mu is held.
func (tc *TextCache) lookup(k textKey) *Image {
	if img, ok := tc.cur[k]; ok {
		return img
	}
	if img, ok := tc.old[k]; ok {
		delete(tc.old, k)
		tc.put(k, img)
		return img
	}
	return nil
}

func (tc *TextCache) worker() {
	for k := range tc.work {
		img := renderLine(k)
		tc.mu.Lock()
		tc.put(k, img)
		delete(tc.busy, k)
		tc.mu.Unlock()
		select {
		case tc.wake <- struct{}{}:
		default:
		}
	}
}

// A line of up to syncLen characters is rendered by the caller when it is
// first asked for, so text that changes under the user (a typed address,
// a counter) never blanks for a frame. A 30-character line takes about
// 30 us on a desktop core and several times that on the DE10, so only
// syncBudget characters a field are rendered this way, keeping a screenful
// of new lines off one frame: the rest go to the workers.
const (
	syncLen    = 40
	syncBudget = 240
	syncField  = 16700 * time.Microsecond
)

// spend reports whether n more characters may be rendered on the caller
// this field; tc.mu is held.
func (tc *TextCache) spend(n int) bool {
	if now := time.Now(); now.Sub(tc.syncAt) >= syncField {
		tc.syncAt, tc.syncLeft = now, syncBudget
	}
	if n > tc.syncLeft {
		return false
	}
	tc.syncLeft -= n
	return true
}

// Get returns the rendered line, or nil after queueing it. Short lines
// are rendered at once (see syncLen).
func (tc *TextCache) Get(f *Font, s string, col, bg Color) *Image {
	if s == "" {
		return nil
	}
	k := textKey{f, s, col, bg}
	tc.mu.Lock()
	if img := tc.lookup(k); img != nil {
		tc.mu.Unlock()
		return img
	}
	if len(s) <= syncLen && tc.spend(len(s)) {
		// render without the lock, so the workers and other callers go on;
		// if one of them stores the same line meanwhile, it is identical
		tc.mu.Unlock()
		img := renderLine(k)
		tc.mu.Lock()
		tc.put(k, img)
		tc.mu.Unlock()
		return img
	}
	if !tc.busy[k] {
		select {
		case tc.work <- k:
			tc.busy[k] = true
		default:
		}
	}
	tc.mu.Unlock()
	return nil
}

// Warm queues a line for the workers when it is neither cached nor on its
// way, so it is there when first drawn. Nothing is rendered on the caller.
func (tc *TextCache) Warm(f *Font, s string, col, bg Color) {
	if s == "" {
		return
	}
	k := textKey{f, s, col, bg}
	tc.mu.Lock()
	defer tc.mu.Unlock()
	if tc.busy[k] || tc.lookup(k) != nil {
		return
	}
	select {
	case tc.work <- k:
		tc.busy[k] = true
	default:
	}
}

// Line draws a cached line with its cell top at y (x is the glyph origin).
func (c *Canvas) Line(tc *TextCache, x, y int, f *Font, col, bg Color, s string) {
	if img := tc.Get(f, s, col, bg); img != nil {
		c.Blit(x-1, y, img)
	}
}

// LineClip draws a cached line clipped to rows cy0..cy1.
func (c *Canvas) LineClip(tc *TextCache, x, y int, f *Font, col, bg Color, s string, cy0, cy1 int) {
	if img := tc.Get(f, s, col, bg); img != nil {
		c.BlitClip(x-1, y, img, 0, cy0, c.W, cy1-cy0)
	}
}

// LineClipX draws a cached line clipped to columns cx0..cx1.
func (c *Canvas) LineClipX(tc *TextCache, x, y int, f *Font, col, bg Color, s string, cx0, cx1 int) {
	if img := tc.Get(f, s, col, bg); img != nil {
		c.BlitClip(x-1, y, img, cx0, 0, cx1-cx0, c.H)
	}
}

// LineRight draws a cached line ending at x.
func (c *Canvas) LineRight(tc *TextCache, x, y int, f *Font, col, bg Color, s string) {
	c.Line(tc, x-f.Width(s), y, f, col, bg, s)
}

// LineCenter draws a cached line centred on x.
func (c *Canvas) LineCenter(tc *TextCache, x, y int, f *Font, col, bg Color, s string) {
	c.Line(tc, x-f.Width(s)/2, y, f, col, bg, s)
}

// Over wraps existing pixels as a canvas (a frame-ring slot).
func Over(pix []byte, w, h int) *Canvas { return &Canvas{W: w, H: h, Pix: pix[:w*h*4]} }
