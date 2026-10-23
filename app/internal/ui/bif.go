package ui

import (
	"encoding/binary"
	"errors"
	"log"
	"runtime"
	"sort"
	"sync"
	"syscall"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/plex"
)

// The Plex server's previews are a Roku BIF file per part: a frame every
// ten seconds, each a small JPEG. The whole file is fetched once in the
// background and kept; the frames under the dot are decoded on demand
// into a few display-size ones.

// bifCache is how many display-size frames are kept (about 65 KB each).
const bifCache = 24

// bifNear is how far (in frames) Frame looks for a ready one while the
// one under the dot is still decoding, so the preview does not blink.
const bifNear = 6

// bifAhead and bifBehind are how many frames are decoded either side of
// the one under the dot: more the way the scrub moves, as a run at full
// speed passes two frames a field and a decode takes one or two.
const (
	bifAhead  = 8
	bifBehind = 3
)

// bifRunNice is the decoding thread's priority while a run waits on it.
const bifRunNice = 0

// bifLeadMax caps how far ahead of the dot (in frames) a fast run's
// decodes aim.
const bifLeadMax = 60

var bifMagic = []byte{0x89, 'B', 'I', 'F', 0x0D, 0x0A, 0x1A, 0x0A}

// bifIndex is a parsed BIF: frame i is data[off[i]:off[i+1]], shown from
// at[i] milliseconds.
type bifIndex struct {
	data []byte
	at   []int64
	off  []int
}

// parseBIF reads a BIF's header and index, checking every offset: a file
// that does not hold together has no previews.
func parseBIF(data []byte) (*bifIndex, error) {
	if len(data) < 64 || string(data[:8]) != string(bifMagic) {
		return nil, errors.New("not a BIF")
	}
	le := binary.LittleEndian
	n := int(le.Uint32(data[12:]))
	unit := int64(le.Uint32(data[16:]))
	if unit == 0 {
		unit = 1000
	}
	if n <= 0 || n > (len(data)-64)/8-1 {
		return nil, errors.New("BIF index out of range")
	}
	b := &bifIndex{data: data, at: make([]int64, n), off: make([]int, n+1)}
	for i := 0; i <= n; i++ {
		e := data[64+8*i:]
		ts, off := le.Uint32(e), int(le.Uint32(e[4:]))
		if off < 64+8*(n+1) || off > len(data) || i > 0 && off < b.off[i-1] {
			return nil, errors.New("BIF offset out of range")
		}
		b.off[i] = off
		if i < n {
			if ts == 0xFFFFFFFF {
				return nil, errors.New("BIF index ends early")
			}
			b.at[i] = int64(ts) * unit
		}
	}
	return b, nil
}

// frame is the index of the frame shown at film time t (seconds).
func (b *bifIndex) frame(t float64) int {
	ms := int64(t * 1000)
	i := sort.Search(len(b.at), func(i int) bool { return b.at[i] > ms }) - 1
	return max(0, i)
}

// jpeg is frame i's bytes.
func (b *bifIndex) jpeg(i int) []byte { return b.data[b.off[i]:b.off[i+1]] }

// bifPreview is the previewer over a part's BIF.
type bifPreview struct {
	mu    sync.Mutex
	cond  *sync.Cond
	w, h  int
	index *bifIndex
	want  int // the frame the scrub is at, -1 before any
	dir   int // the way it moves: +1 or -1
	// how fast it moves (frames a second), when want last changed, and
	// how long a decode takes (seconds, averaged): a run's decodes aim
	// where the dot will be when they are done, not where it was
	speed   float64
	movedAt time.Time
	dec     float64
	frames  map[int]*bifFrame
	used    int
	closed  bool
}

type bifFrame struct {
	img  *gfx.Image
	used int
}

// newPreviewer starts the item's previews: nil when its part has none.
func newPreviewer(app *App, it *plex.Item, w, h int, start float64) previewer {
	if app == nil || app.Plex == nil || it == nil || it.PartID == "" || it.Indexes != "sd" {
		return nil
	}
	client, part := app.Plex, it.PartID
	return newBIFPreview(func() ([]byte, error) { return client.PartIndex(part) }, w, h, start)
}

// newBIFPreview starts a previewer over the file fetch returns, preparing
// round start.
func newBIFPreview(fetch func() ([]byte, error), w, h int, start float64) *bifPreview {
	b := &bifPreview{w: w, h: h, want: -1, dir: 1, dec: 0.03, frames: map[int]*bifFrame{}}
	b.cond = sync.NewCond(&b.mu)
	b.Near(start)
	go b.run(fetch)
	return b
}

// run fetches the file, then decodes what Near asks for, a frame at a
// time, on its own thread at a low priority as the art workers do.
func (b *bifPreview) run(fetch func() ([]byte, error)) {
	runtime.LockOSThread()
	syscall.Setpriority(syscall.PRIO_PROCESS, 0, 10)
	data, err := fetch()
	var index *bifIndex
	if err == nil {
		index, err = parseBIF(data)
	}
	if err != nil {
		log.Printf("preview: none for this item")
		return
	}
	log.Printf("preview: %d frames, %d bytes", len(index.at), len(data))
	b.mu.Lock()
	if b.closed {
		b.mu.Unlock()
		return
	}
	b.index = index
	b.mu.Unlock()
	b.decodeLoop()
}

// decodeLoop decodes the frame the scrub is at, then the ones either side
// of it (next), until it is closed.
func (b *bifPreview) decodeLoop() {
	prio := 10 // this thread's nice, as run set it
	for {
		b.mu.Lock()
		i := -1
		for !b.closed {
			if i = b.next(); i >= 0 {
				break
			}
			b.cond.Wait()
		}
		if b.closed {
			b.mu.Unlock()
			return
		}
		index, w, h := b.index, b.w, b.h
		nice := 10
		if b.lead() != 0 {
			// a run waits on these: the paused picture leaves the time,
			// and at nice 10 a decode took ten times as long
			nice = bifRunNice
		}
		b.mu.Unlock()
		if nice != prio {
			prio = nice
			syscall.Setpriority(syscall.PRIO_PROCESS, 0, prio)
		}
		var img *gfx.Image
		at := time.Now()
		decoding(func() {
			if src, err := gfx.Decode(index.jpeg(i)); err == nil {
				img = previewImage(src, w, h)
			}
		})
		took := time.Since(at).Seconds()
		b.mu.Lock()
		if b.closed {
			b.mu.Unlock()
			return
		}
		b.dec = (3*b.dec + took) / 4
		if img == nil {
			img = &gfx.Image{} // a bad frame: not tried again
		}
		b.add(i, img)
		b.mu.Unlock()
	}
}

// next is the frame to decode, -1 for none: the one the dot will be at
// when it is decoded (lead), then outward from it, bifAhead the way the
// scrub moves and bifBehind the other, a few ahead for each one behind.
// Called under mu.
func (b *bifPreview) next() int {
	if b.index == nil || b.want < 0 {
		return -1
	}
	n := len(b.index.at)
	at := max(0, min(b.want+b.lead(), n-1))
	for _, d := range bifOrder {
		i := at + d*b.dir
		if i >= 0 && i < n && b.frames[i] == nil {
			return i
		}
	}
	return -1
}

// lead is how many frames the dot moves in a decode and a half, signed:
// 0 when it stands. Called under mu.
func (b *bifPreview) lead() int {
	if b.speed == 0 || time.Since(b.movedAt) > 250*time.Millisecond {
		return 0
	}
	l := int(b.speed * b.dec * 1.5)
	return max(-bifLeadMax, min(l, bifLeadMax))
}

// bifOrder is next's order, forward being the way the scrub moves.
var bifOrder = func() []int {
	o := []int{0}
	for a, d := 1, 1; a <= bifAhead || d <= bifBehind; {
		for k := 0; k < 3 && a <= bifAhead; k++ {
			o = append(o, a)
			a++
		}
		if d <= bifBehind {
			o = append(o, -d)
			d++
		}
	}
	return o
}()

// add keeps a decoded frame, dropping the least recently used past
// bifCache. Called under mu.
func (b *bifPreview) add(i int, img *gfx.Image) {
	b.used++
	b.frames[i] = &bifFrame{img: img, used: b.used}
	for len(b.frames) > bifCache {
		old, oldest := -1, 0
		for k, f := range b.frames {
			if old < 0 || f.used < oldest {
				old, oldest = k, f.used
			}
		}
		delete(b.frames, old)
	}
}

func (b *bifPreview) Near(t float64) {
	b.mu.Lock()
	defer b.mu.Unlock()
	i := 0
	if b.index != nil {
		i = b.index.frame(t)
	} else {
		i = max(0, int(t/10)) // before the file is in: its ten seconds a frame
	}
	if i != b.want {
		now := time.Now()
		if b.want >= 0 {
			b.dir = 1
			if i < b.want {
				b.dir = -1
			}
			// a run's speed, from successive moves; a jump (a seek, a
			// first move after a rest) is no speed
			if dt := now.Sub(b.movedAt).Seconds(); dt > 0 && dt < 0.25 && abs(i-b.want) <= bifLeadMax/4 {
				b.speed = (b.speed + float64(i-b.want)/dt) / 2
			} else {
				b.speed = 0
			}
		}
		b.want, b.movedAt = i, now
		b.cond.Broadcast()
	}
}

func (b *bifPreview) Frame(t float64) *gfx.Image {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.index == nil {
		return nil
	}
	i := b.index.frame(t)
	// the nearest ready one: a run's decodes are spread along its lead
	for d := 0; d <= bifNear+abs(b.lead()); d++ {
		for _, k := range []int{i - d, i + d} {
			if f := b.frames[k]; f != nil && f.img.W > 0 {
				b.used++
				f.used = b.used
				return f.img
			}
		}
	}
	return nil
}

func (b *bifPreview) Close() {
	b.mu.Lock()
	b.closed = true
	b.index, b.frames = nil, nil
	b.mu.Unlock()
	b.cond.Broadcast()
}
