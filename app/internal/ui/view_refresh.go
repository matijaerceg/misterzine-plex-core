package ui

import (
	"plexcrt/internal/plex"
	"strings"
	"time"
)

const viewRefreshInterval = 30 * time.Second

type viewResult struct {
	items []*plex.Item
	err   error
}

// All state and result application belong to the UI thread. Workers only
// fetch into a buffered channel, so leaving a screen never blocks a worker.
type viewRefresh struct {
	next    time.Time
	pending chan viewResult
}

func (r *viewRefresh) reset() {
	r.pending = nil
	r.next = time.Now().Add(viewRefreshInterval)
}

func (r *viewRefresh) poll(a *App, now time.Time, fetch func() ([]*plex.Item, error), apply func([]*plex.Item)) {
	if r.pending != nil {
		select {
		case result := <-r.pending:
			r.pending = nil
			r.next = now.Add(viewRefreshInterval)
			if result.err == nil {
				apply(result.items)
				a.dirty = true
			} else if a.Log != nil {
				a.Log.Printf("view refresh: %v", result.err)
			}
		default:
		}
		return
	}
	if r.next.IsZero() {
		r.next = now.Add(viewRefreshInterval)
		return
	}
	if now.Before(r.next) {
		return
	}
	result := make(chan viewResult, 1)
	r.pending = result
	go func() {
		items, err := fetch()
		result <- viewResult{items, err}
		select {
		case a.Wake <- struct{}{}:
		default:
		}
	}()
}

// Refresh only watch state in existing lists. Membership, ordering, artwork,
// and already-fetched stream details stay intact.
func updateWatchState(current, fresh []*plex.Item) {
	byKey := make(map[string]*plex.Item, len(fresh))
	for _, it := range fresh {
		if it.RatingKey != "" {
			byKey[it.RatingKey] = it
		}
	}
	for _, it := range current {
		if f := byKey[it.RatingKey]; f != nil {
			it.ViewOffset, it.ViewCount, it.Viewed = f.ViewOffset, f.ViewCount, f.Viewed
		}
	}
}

func actionKind(actions []string, at int) string {
	if at < 0 {
		return "synopsis"
	}
	if at >= len(actions) {
		return ""
	}
	a := actions[at]
	for _, kind := range []string{"Resume", "Mark", "Audio", "Subtitles", "Remove"} {
		if strings.HasPrefix(a, kind) {
			return kind
		}
	}
	return "Play"
}

func restoreAction(actions []string, kind string) int {
	if kind == "synopsis" {
		return -1
	}
	for i := range actions {
		if actionKind(actions, i) == kind {
			return i
		}
	}
	return 0
}

func (p *Preplay) pollRefresh(now time.Time) {
	if p.cw.poll() {
		kind := actionKind(p.actions, p.cur)
		p.rebuild()
		p.cur = restoreAction(p.actions, kind)
		p.app.dirty = true
	}
	client, key := p.app.Plex, p.item.RatingKey
	p.periodic.poll(p.app, now, func() ([]*plex.Item, error) {
		it, err := client.Item(key)
		if err != nil {
			return nil, err
		}
		return []*plex.Item{it}, nil
	}, func(items []*plex.Item) {
		if len(items) == 0 {
			return
		}
		kind := actionKind(p.actions, p.cur)
		*p.item = *items[0]
		p.rebuild()
		p.cur = restoreAction(p.actions, kind)
	})
}

func (s *Season) pollRefresh(now time.Time) {
	// an answer that lands while the episodes load is kept for their rebuild
	if s.cw.poll() && !s.loading && len(s.eps) > 0 {
		kind := actionKind(s.actions, s.act)
		s.rebuild()
		s.act = restoreAction(s.actions, kind)
		s.keepActVisible(now)
		s.app.dirty = true
	}
	if s.loading || s.err != nil || len(s.eps) == 0 {
		return
	}
	client, key := s.app.Plex, s.season().Key
	s.periodic.poll(s.app, now, func() ([]*plex.Item, error) {
		return client.Items(key, nil, 500)
	}, func(items []*plex.Item) {
		kind := actionKind(s.actions, s.act)
		updateWatchState(s.eps, items)
		s.rebuild()
		s.act = restoreAction(s.actions, kind)
		s.keepActVisible(now)
	})
}

func (v *Show) pollRefresh(now time.Time) {
	// Avoid touching the layouts while a transition worker is using them.
	if v.transition != nil || v.fade.Running() {
		return
	}
	if v.episodes {
		v.season.pollRefresh(now)
		return
	}
	client, key := v.app.Plex, v.item.Key
	v.periodic.poll(v.app, now, func() ([]*plex.Item, error) {
		return client.Items(key, nil, 500)
	}, func(items []*plex.Item) {
		updateWatchState(v.picker.hubs[0].Items, items)
		v.picker.pageKey = ""
		if v.season != nil {
			v.season.pageKey = ""
			v.season.entryKey = ""
		}
	})
}
