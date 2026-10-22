package ui

import (
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"plexcrt/internal/input"
	"plexcrt/internal/plex"
)

// A run of letter jumps (held, or tapped faster than JumpRunGap) asks the
// server for nothing while it lasts; the landing page is asked for once
// the run has rested JumpSettle.
func TestJumpRunFetchesOnlyTheLandingPage(t *testing.T) {
	var pages atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		pages.Add(1)
		w.Header().Set("Content-Type", "text/xml")
		w.Write([]byte(`<MediaContainer size="0" totalSize="400"></MediaContainer>`))
	}))
	defer server.Close()
	p := newPager(testClient(server.URL, "token", t.TempDir()), "/library/sections/1/all", nil, make(chan struct{}, 1), nil, nil)
	p.total, p.loaded = 400, true
	a := &App{Art: NewArt(nil, 0, nil)}
	w := &Wall{app: a, pager: p}
	for _, k := range "ABCDEFGHIJ" {
		w.letters = append(w.letters, plex.Letter{Key: string(k), Size: 40})
	}
	settled := func() int {
		time.Sleep(50 * time.Millisecond) // the fetches are goroutines
		return int(pages.Load())
	}
	t0 := time.Now()
	w.Key(input.Event{Key: input.JumpFwd}, t0)
	if settled() == 0 {
		t.Fatal("a lone jump did not ask for its page")
	}
	pages.Store(0)
	// a held run: repeats at the cadence
	now := t0.Add(time.Second)
	for i := 0; i < 6; i++ {
		now = now.Add(RepeatDur)
		w.Key(input.Event{Key: input.JumpFwd, Repeat: true}, now)
		w.settle(now)
	}
	if got := settled(); got != 0 {
		t.Fatalf("a held run asked for %d pages before resting", got)
	}
	if !w.inRun(now) || w.cur != 7*40 {
		t.Fatalf("run state %v at cur %d", w.inRun(now), w.cur)
	}
	w.settle(now.Add(JumpSettle))
	if got := settled(); got == 0 {
		t.Fatal("the rested run did not ask for its landing page")
	}
	if w.inRun(now.Add(JumpSettle)) || !w.runUntil.IsZero() {
		t.Fatal("the run did not end on settling")
	}
	pages.Store(0)
	// taps faster than JumpRunGap are a run too; slower ones are not
	now = now.Add(time.Second)
	w.Key(input.Event{Key: input.JumpBack}, now)
	w.Key(input.Event{Key: input.JumpBack}, now.Add(JumpRunGap/2))
	if !w.inRun(now.Add(JumpRunGap / 2)) {
		t.Fatal("two quick taps are not a run")
	}
	now = now.Add(2 * time.Second)
	w.Key(input.Event{Key: input.JumpBack}, now)
	if w.inRun(now) {
		t.Fatal("a tap after a rest counts as a run")
	}
}

// During a run the wall reads items and posters without queueing fetches
// for them.
func TestJumpRunPeeksWithoutWanting(t *testing.T) {
	p := &Pager{items: map[int]*plex.Item{}, total: 80, loaded: true, inFlt: map[int]bool{}}
	p.items[0] = &plex.Item{RatingKey: "1", Thumb: "poster-1"}
	a := &App{Art: NewArt(nil, 0, nil)}
	w := &Wall{app: a, pager: p}
	now := time.Now()
	w.runUntil = now.Add(time.Hour)
	if w.item(0, now) == nil || w.item(1, now) != nil {
		t.Fatal("peek does not see the loaded item, or sees an unloaded one")
	}
	if len(p.inFlt) != 0 {
		t.Fatal("a peek started a page fetch")
	}
	if w.app.Art.Have("poster-1", WallPW, WallPH) != nil || len(w.app.Art.wants) != 0 {
		t.Fatal("Have found or wanted a poster that is not decoded")
	}
}
