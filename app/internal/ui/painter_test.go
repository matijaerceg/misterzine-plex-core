package ui

import (
	"sync"
	"testing"

	"plexcrt/internal/gfx"
)

type painterTestOSD struct {
	nopOSD
	mu    sync.Mutex
	order []string
}

func (o *painterTestOSD) add(s string) {
	o.mu.Lock()
	o.order = append(o.order, s)
	o.mu.Unlock()
}
func (o *painterTestOSD) Show(int, int, *gfx.Canvas, []byte) { o.add("show") }
func (o *painterTestOSD) Hide()                              { o.add("hide") }

func TestPainterCloseCancelsQueuedWorkThenHidesAndExits(t *testing.T) {
	p := newPainter()
	o := &painterTestOSD{}
	entered, release := make(chan struct{}), make(chan struct{})
	p.do(func() { close(entered); <-release; o.add("job") })
	<-entered
	p.show(o, 0, 0, gfx.NewCanvas(1, 1), nil)
	p.do(func() { o.add("queued-job") })
	p.close(o)
	p.do(func() { o.add("late-job") })
	close(release)
	p.waitClosed()
	p.do(func() { o.add("after-close-job") })
	p.hide(o)
	o.mu.Lock()
	defer o.mu.Unlock()
	if len(o.order) != 2 || o.order[0] != "job" || o.order[1] != "hide" {
		t.Fatalf("painter operations = %v, want [job hide]", o.order)
	}
}
