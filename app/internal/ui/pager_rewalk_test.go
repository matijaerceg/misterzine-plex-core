package ui

import (
	"net/url"
	"sync"
	"testing"

	"plexcrt/internal/plex"
)

// With the 4:3 filter on, a library that changes size during the walk is
// walked again. A page of the walk again that fails leaves the first walk
// showing with no error, and the walk again picks up at that page after
// PageRetry even with the cursor at the top, ending on the whole listing.
func TestPagerRewalkSurvivesAFailedPage(t *testing.T) {
	s := newPagedServer(t, 3*pageSize)
	var mu sync.Mutex
	grown, failed, second := false, false, 0
	s.onPage = func(start int) {
		mu.Lock()
		defer mu.Unlock()
		if start == pageSize && !grown {
			// the library grows between the walk's first and second pages
			grown = true
			s.mu.Lock()
			s.keys = append(s.keys, 1000+3*pageSize)
			s.mu.Unlock()
		}
	}
	s.fails = func(start int) bool {
		mu.Lock()
		defer mu.Unlock()
		if start != pageSize || !grown {
			return false
		}
		second++
		if second == 1 && !failed {
			// the walk again's second page, once
			failed = true
			return true
		}
		return false
	}
	a := pagedTestApp(t, s)
	p := a.pager("/library/sections/1/all", url.Values{"sort": {"titleSort"}}, func(*plex.Item) bool { return true })
	p.Want(0)
	waitUntil(t, "the walk again's failed page", func() bool {
		p.mu.Lock()
		defer p.mu.Unlock()
		_, waiting := p.failed[1]
		return p.restage && waiting && len(p.inFlt) == 0
	})
	p.mu.Lock()
	shown, done := len(p.list), p.done
	p.mu.Unlock()
	if p.Err() != nil || shown == 0 || done {
		t.Fatalf("after the failure: error %v, %d shown, done %v", p.Err(), shown, done)
	}
	for range 50 {
		p.Want(0) // frames at the top, within the pause
		if p.Err() != nil {
			t.Fatal("the walk again's failure brought an error back")
		}
	}
	p.mu.Lock()
	for pg, at := range p.failed {
		p.failed[pg] = at.Add(-PageRetry)
	}
	p.mu.Unlock()
	waitUntil(t, "the walk again to finish", func() bool {
		p.Want(0)
		p.mu.Lock()
		defer p.mu.Unlock()
		return p.done && !p.restage
	})
	p.mu.Lock()
	defer p.mu.Unlock()
	seen := map[string]bool{}
	for _, it := range p.list {
		if seen[it.RatingKey] {
			t.Fatalf("%s kept twice", it.RatingKey)
		}
		seen[it.RatingKey] = true
	}
	if len(p.list) != 3*pageSize+1 || p.err != nil {
		t.Fatalf("after the walk again: %d shown, want %d; error %v", len(p.list), 3*pageSize+1, p.err)
	}
}
