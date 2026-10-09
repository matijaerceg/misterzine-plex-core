package ui

import (
	"net/url"
	"sync"
	"testing"
	"time"

	"plexcrt/internal/plex"
)

// A page whose fetch failed is asked for again only after PageRetry,
// however often it is wanted meanwhile (the wall asks for the pages it
// shows on every frame), its error showing all the while. The pause over,
// the next ask goes out and the error clears once the page is in. With the
// 4:3 filter on too.
func TestPagerWaitsAfterAFailedPage(t *testing.T) {
	for _, keep := range []func(*plex.Item) bool{nil, func(*plex.Item) bool { return true }} {
		s := newPagedServer(t, 3*pageSize)
		var mu sync.Mutex
		asked, failing := 0, true
		s.fails = func(start int) bool {
			mu.Lock()
			defer mu.Unlock()
			if start != 2*pageSize {
				return false
			}
			asked++
			return failing
		}
		count := func() int {
			mu.Lock()
			defer mu.Unlock()
			return asked
		}
		a := pagedTestApp(t, s)
		p := a.pager("/library/sections/1/all", url.Values{"sort": {"titleSort"}}, keep)
		idle := func() bool {
			p.mu.Lock()
			defer p.mu.Unlock()
			return len(p.inFlt) == 0
		}
		// the pages before the failing one land first, so none of them
		// clears its error by landing after it
		waitUntil(t, "the pages before", func() bool {
			p.mu.Lock()
			defer p.mu.Unlock()
			return p.items[pageSize] != nil || len(p.list) >= 2*pageSize
		})
		waitUntil(t, "the failed page", func() bool { p.Want(2 * pageSize); return p.Err() != nil && idle() })
		if n := count(); n != 1 {
			t.Fatalf("filtered %v: the failed page was asked for %d times by the time it failed", keep != nil, n)
		}
		mu.Lock()
		failing = false // the server is back, but the pause holds
		mu.Unlock()
		for end := time.Now().Add(300 * time.Millisecond); time.Now().Before(end); {
			p.Want(2 * pageSize) // a frame
			if p.Get(2*pageSize) != nil || p.Err() == nil {
				t.Fatalf("filtered %v: the page showed, or its error went, within the pause", keep != nil)
			}
			time.Sleep(time.Millisecond)
		}
		if n := count(); n != 1 {
			t.Fatalf("filtered %v: the failed page was asked for %d times within the pause", keep != nil, n)
		}
		// the pause over, the next ask goes out
		p.mu.Lock()
		for pg, at := range p.failed {
			p.failed[pg] = at.Add(-PageRetry)
		}
		p.mu.Unlock()
		waitUntil(t, "the page after the pause", func() bool { return p.Get(2*pageSize) != nil })
		if n := count(); n != 2 || p.Err() != nil {
			t.Fatalf("filtered %v: asked %d times in all, error %v once the page is in", keep != nil, n, p.Err())
		}
	}
}

// Pages load side by side: one that failed keeps its error showing while
// it is asked for during the pause, even when the page beside it lands
// after the failure, and the error goes once the page is in.
func TestPagerFailureOutlastsANeighbourLanding(t *testing.T) {
	s := newPagedServer(t, 3*pageSize)
	var mu sync.Mutex
	failing := true
	var p *Pager
	pager := func() *Pager {
		mu.Lock()
		defer mu.Unlock()
		return p
	}
	s.fails = func(start int) bool {
		mu.Lock()
		defer mu.Unlock()
		return start == 0 && failing
	}
	s.onPage = func(start int) {
		if start != pageSize {
			return
		}
		// the page beside the failed one lands after the failure
		for end := time.Now().Add(5 * time.Second); time.Now().Before(end); time.Sleep(time.Millisecond) {
			if q := pager(); q != nil && q.Err() != nil {
				return
			}
		}
	}
	a := pagedTestApp(t, s)
	q := a.pager("/library/sections/1/all", url.Values{"sort": {"titleSort"}}, nil) // asks for pages 0 and 1
	mu.Lock()
	p = q
	mu.Unlock()
	waitUntil(t, "the page beside", func() bool {
		q.mu.Lock()
		defer q.mu.Unlock()
		return q.items[pageSize] != nil && len(q.inFlt) == 0
	})
	for end := time.Now().Add(100 * time.Millisecond); time.Now().Before(end); time.Sleep(time.Millisecond) {
		q.Want(0) // a frame
		if q.Get(0) != nil || q.Err() == nil {
			t.Fatal("the failed page's error went with the page beside it in")
		}
	}
	mu.Lock()
	failing = false
	mu.Unlock()
	q.mu.Lock()
	for pg, at := range q.failed {
		q.failed[pg] = at.Add(-PageRetry)
	}
	q.mu.Unlock()
	waitUntil(t, "the page after the pause", func() bool { return q.Get(0) != nil })
	if err := q.Err(); err != nil {
		t.Fatalf("the error stayed once the page was in: %v", err)
	}
}
