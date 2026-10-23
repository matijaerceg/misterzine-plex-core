package ui

import (
	"encoding/binary"
	"errors"
	"log"
	"runtime"
	"sort"
	"sync"
	"syscall"

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
	mu     sync.Mutex
	cond   *sync.Cond
	w, h   int
	index  *bifIndex
	want   int // the frame the scrub is at, -1 before any
	frames map[int]*bifFrame
	used   int
	closed bool
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
	b := &bifPreview{w: w, h: h, want: -1, frames: map[int]*bifFrame{}}
	b.cond = sync.NewCond(&b.mu)
	b.Near(start)
	client, part := app.Plex, it.PartID
	go b.run(func() ([]byte, error) { return client.PartIndex(part) })
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

// decodeLoop decodes the frame the scrub is at, then the next ones either
// side of it, until it is closed.
func (b *bifPreview) decodeLoop() {
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
		b.mu.Unlock()
		var img *gfx.Image
		decoding(func() {
			if src, err := gfx.Decode(index.jpeg(i)); err == nil {
				img = previewImage(src, w, h)
			}
		})
		b.mu.Lock()
		if b.closed {
			b.mu.Unlock()
			return
		}
		if img == nil {
			img = &gfx.Image{} // a bad frame: not tried again
		}
		b.add(i, img)
		b.mu.Unlock()
	}
}

// next is the frame to decode, -1 for none: the one wanted, then the two
// either side. Called under mu.
func (b *bifPreview) next() int {
	if b.index == nil || b.want < 0 {
		return -1
	}
	for _, d := range []int{0, 1, -1, 2, -2} {
		i := b.want + d
		if i >= 0 && i < len(b.index.at) && b.frames[i] == nil {
			return i
		}
	}
	return -1
}

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
		b.want = i
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
	for d := 0; d <= bifNear; d++ {
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
