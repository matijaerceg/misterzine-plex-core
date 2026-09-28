package ui

import (
	"maps"
	"time"

	"plexcrt/internal/plex"
)

// RemoveContinue is the last action on a movie's page and in an episode's
// actions while the item is in Continue Watching.
const RemoveContinue = "Remove from Continue Watching"

// continueList is the server's Continue Watching list as rating keys, held
// by a movie or season page. The page fetches it off-thread when it opens,
// after a play or a mark, and every viewRefreshInterval after that (a
// change made on another client, a fetch that failed), and takes the
// answer on the render thread (pollRefresh). Until an answer lands, or
// when the server has no list, nothing counts as in it and the action
// stays hidden.
type continueList struct {
	keys    map[string]bool
	pending chan map[string]bool // a nil answer: the fetch failed
	next    time.Time            // when to ask again; zero: never asked
}

// refetch asks the server again; an answer still on its way is dropped.
func (l *continueList) refetch(a *App) {
	if a.Plex == nil {
		return
	}
	l.next = time.Now().Add(viewRefreshInterval)
	result := make(chan map[string]bool, 1)
	l.pending = result
	client, lg := a.Plex, a.Log
	go func() {
		keys, err := client.ContinueWatching()
		if err != nil && lg != nil {
			lg.Printf("continue watching: %v", err)
		}
		result <- keys
		select {
		case a.Wake <- struct{}{}:
		default:
		}
	}()
}

// poll takes an answer that has landed, or asks again when it is time;
// true when the list changed.
func (l *continueList) poll(a *App, now time.Time) bool {
	if l.pending == nil {
		if !l.next.IsZero() && !now.Before(l.next) {
			l.refetch(a)
		}
		return false
	}
	select {
	case keys := <-l.pending:
		l.pending = nil
		if keys == nil || maps.Equal(keys, l.keys) {
			return false
		}
		l.keys = keys
		return true
	default:
		return false
	}
}

func (l *continueList) has(key string) bool { return l.keys[key] }

// removeContinue takes an item out of Continue Watching on the server, then
// out of the page's list and the Home row at once, not at their next
// fetch. False when the server refused; the notice line says so.
func (a *App) removeContinue(it *plex.Item, l *continueList) bool {
	if err := a.Plex.RemoveFromContinueWatching(it.RatingKey); err != nil {
		a.Log.Printf("remove from continue watching %s: %v", it.RatingKey, err)
		a.Notice, a.NoticeAt = "Could not remove it from Continue Watching.", time.Now()
		a.dirty = true
		return false
	}
	l.pending = nil // an answer from before the removal would still hold it
	delete(l.keys, it.RatingKey)
	for _, screen := range a.stack {
		if h, ok := screen.(*Home); ok && h.home {
			h.dropContinue(it.RatingKey)
		}
	}
	a.dirty = true
	return true
}

// dropContinue takes an item out of the Continue Watching row and has the
// rows fetched again when Home is next shown, discarding any fetch that
// began before the removal.
func (h *Home) dropContinue(key string) {
	h.refreshResult = nil
	h.refreshAt = time.Time{}
	hubs := make([]*plex.Hub, 0, len(h.hubs))
	found := false
	for _, hub := range h.hubs {
		cp := *hub
		if hub.IsContinueWatching() {
			cp.Items = nil
			for _, it := range hub.Items {
				if it.RatingKey == key {
					found = true
					continue
				}
				cp.Items = append(cp.Items, it)
			}
		}
		hubs = append(hubs, &cp)
	}
	if found {
		h.applyHome(hubs)
	}
}
