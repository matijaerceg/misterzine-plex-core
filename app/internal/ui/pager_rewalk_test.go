package ui

import (
	"net/url"
	"sync"
	"testing"

	"plexcrt/internal/plex"
)

// An ordered view (Random) over a filtered library keeps the walk going
// through whole. A walk whose page failed once and then came in, and whose
// walk again then fails on a page, shows no error while the walk again
// waits out PageRetry: the old failure does not come back. Then the walk
// again finishes and the view takes the listing as it is now.
func TestOrderedViewRewalkKeepsAnOldErrorAway(t *testing.T) {
	s := newPagedServer(t, 3*pageSize)
	var mu sync.Mutex
	calls := 0
	s.fails = func(start int) bool {
		mu.Lock()
		defer mu.Unlock()
		if start != pageSize {
			return false
		}
		calls++
		return calls == 1 || calls == 3 // the first walk's, then the walk again's
	}
	var once sync.Once
	s.onPage = func(start int) {
		if start == 2*pageSize {
			once.Do(func() { s.insert(0, 990) })
		}
	}
	a := pagedTestApp(t, s)
	base := a.pager("/library/sections/1/all", url.Values{"sort": {"titleSort"}}, func(*plex.Item) bool { return true })
	view := NewOrderedPager(base, func(items []*plex.Item) []int {
		at := make([]int, len(items))
		for i := range at {
			at[i] = i
		}
		return at
	})
	expire := func() {
		base.mu.Lock()
		for pg, at := range base.failed {
			base.failed[pg] = at.Add(-PageRetry)
		}
		base.mu.Unlock()
	}
	failedAt := func(n int, restage bool) func() bool {
		return func() bool {
			view.Total()
			base.mu.Lock()
			defer base.mu.Unlock()
			_, f := base.failed[n]
			return f && base.restage == restage && len(base.inFlt) == 0
		}
	}
	waitUntil(t, "the first walk's failure", failedAt(1, false))
	if view.Err() == nil {
		t.Fatal("the first walk's failure shows no error")
	}
	expire()
	waitUntil(t, "the walk again's failure", failedAt(1, true))
	for range 50 {
		if view.Total(); view.Err() != nil || base.Err() != nil {
			t.Fatalf("an error came back during the walk again's pause: %v", view.Err())
		}
	}
	expire()
	waitUntil(t, "the walk again", func() bool {
		view.Total()
		base.mu.Lock()
		defer base.mu.Unlock()
		return base.done && !base.restage
	})
	waitUntil(t, "the view", func() bool { return view.Total() == 3*pageSize+1 })
	if view.Err() != nil || view.Get(0).RatingKey != "990" {
		t.Fatalf("the view after the walk again: error %v, first %s", view.Err(), view.Get(0).RatingKey)
	}
}

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
