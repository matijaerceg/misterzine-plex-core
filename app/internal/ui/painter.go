package ui

import (
	"log"
	"sync"

	"plexcrt/internal/gfx"
)

// painter writes the overlay's pixels from its own goroutine, so the
// play loop never waits on the write into the frame memory (which can
// stall behind the decoder) and the sprites keep moving every field.
// The loop fills a free staging buffer outside the lock and hands it
// over with a few stores; the painter returns it when written. Three
// buffers cover fill, pending and writing. Only the latest panel is
// kept; a pending one that was never written goes straight back.
type painter struct {
	mu         sync.Mutex
	cond       *sync.Cond
	osd        OSD
	x, y       int
	w, h       int
	pend       *stage // the panel waiting to be written, or nil
	hid        bool   // a hide waits
	busy       bool   // a write is in progress
	closed     bool   // cancel queued work, hide after the active write, then exit
	done       chan struct{}
	free       []*stage
	made       int
	maxW, maxH int      // largest logical panel this playback can submit
	jobs       []func() // run in order with the writes, on the painter's goroutine
}

type stage struct {
	pix   []byte
	alpha []byte
}

func newPainter(size ...int) *painter {
	w, h := 720, 480
	if len(size) >= 2 && size[0] > 0 && size[1] > 0 {
		w, h = size[0], size[1]
	}
	p := &painter{done: make(chan struct{}), maxW: w, maxH: h}
	p.cond = sync.NewCond(&p.mu)
	go p.run()
	return p
}

// take returns a free staging buffer, making one of the three if needed.
func (p *painter) take() *stage {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return nil
	}
	if n := len(p.free); n > 0 {
		s := p.free[n-1]
		p.free = p.free[:n-1]
		return s
	}
	if p.made < 3 {
		p.made++
		return &stage{pix: make([]byte, p.maxW*p.maxH*4), alpha: make([]byte, p.maxW*p.maxH)}
	}
	return nil // fill, pending and writing all in use: this panel is dropped
}

// show copies the canvas into a free buffer and makes it the pending panel.
func (p *painter) show(osd OSD, x, y int, c *gfx.Canvas, alpha []byte) {
	s := p.take()
	if s == nil {
		return
	}
	n := c.W * c.H
	copy(s.pix, c.Pix[:n*4])
	if alpha != nil {
		copy(s.alpha, alpha[:n])
	} else {
		for i := range s.alpha[:n] {
			s.alpha[i] = 255
		}
	}
	p.mu.Lock()
	if p.closed {
		p.free = append(p.free, s)
		p.mu.Unlock()
		return
	}
	if p.pend != nil {
		p.free = append(p.free, p.pend) // never written: superseded
	}
	p.pend = s
	p.osd, p.x, p.y, p.w, p.h = osd, x, y, c.W, c.H
	p.hid = false
	p.mu.Unlock()
	p.cond.Broadcast()
}

// do queues work for the painter's goroutine, in order with its writes:
// an upload and the header store that shows it must not overtake a
// panel write still in progress, nor the other way round.
func (p *painter) do(f func()) {
	p.mu.Lock()
	if p.closed {
		p.mu.Unlock()
		return
	}
	p.jobs = append(p.jobs, f)
	p.mu.Unlock()
	p.cond.Broadcast()
}

// hide queues a hide, cancelling any panel waiting.
func (p *painter) hide(osd OSD) {
	p.mu.Lock()
	if p.closed {
		p.mu.Unlock()
		return
	}
	if p.pend != nil {
		p.free = append(p.free, p.pend)
		p.pend = nil
	}
	p.osd = osd
	p.hid = true
	p.mu.Unlock()
	p.cond.Broadcast()
}

// close cancels queued writes, hides after any in-flight write, then exits.
// It does not wait for the device write, so playback shutdown stays prompt.
func (p *painter) close(osd OSD) {
	p.mu.Lock()
	if !p.closed {
		if p.pend != nil {
			p.free = append(p.free, p.pend)
			p.pend = nil
		}
		p.osd = osd
		p.hid = true
		p.closed = true
		p.jobs = nil // queued operations belong to the screen being left
	}
	p.mu.Unlock()
	p.cond.Broadcast()
}

func (p *painter) waitClosed() { <-p.done }

func (p *painter) run() {
	defer func() {
		// a bad panel must not take the app down mid-playback
		if r := recover(); r != nil {
			log.Printf("painter: %v", r)
			p.mu.Lock()
			p.pend, p.hid = nil, false
			closed := p.closed
			p.mu.Unlock()
			if closed {
				close(p.done)
				return
			}
			go p.run()
		}
	}()
	c := &gfx.Canvas{}
	for {
		p.mu.Lock()
		for p.pend == nil && !p.hid && len(p.jobs) == 0 {
			p.cond.Wait()
		}
		if len(p.jobs) > 0 {
			f := p.jobs[0]
			p.jobs = p.jobs[1:]
			p.mu.Unlock()
			f()
			p.cond.Broadcast() // a flush may wait on the job
			continue
		}
		osd := p.osd
		if p.hid {
			p.hid = false
			p.busy = true
			closed := p.closed
			p.mu.Unlock()
			if osd != nil {
				osd.Hide()
			}
			p.mu.Lock()
			p.busy = false
			p.mu.Unlock()
			p.cond.Broadcast() // a flush may wait on the hide
			if closed {
				close(p.done)
				return
			}
			continue
		}
		if p.closed {
			p.mu.Unlock()
			return
		}
		s := p.pend
		p.pend = nil
		p.busy = true
		x, y, w, h := p.x, p.y, p.w, p.h
		p.mu.Unlock()
		c.W, c.H, c.Pix = w, h, s.pix[:w*h*4]
		osd.Show(x, y, c, s.alpha[:w*h])
		p.mu.Lock()
		p.free = append(p.free, s)
		p.busy = false
		p.mu.Unlock()
		p.cond.Broadcast()
	}
}

// flush waits until every queued write, hide and job has been done: for
// tests, which check the fake core right after a Tick.
func (p *painter) flush() {
	p.mu.Lock()
	for !p.closed && (p.pend != nil || p.hid || len(p.jobs) > 0 || p.busy) {
		p.cond.Wait()
	}
	p.mu.Unlock()
}
