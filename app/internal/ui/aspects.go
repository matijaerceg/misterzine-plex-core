package ui

import (
	"encoding/json"
	"net/url"
	"os"
	"path/filepath"
	"sync"
	"time"

	"plexcrt/internal/plex"
)

// Aspects remembers the picture shape of shows, taken from each show's
// first episode, so the 4:3 filter can judge a show the way it judges a
// movie. The first time the filter needs them, every TV library is swept
// in one request each; the few shows that leaves out are probed one by one.
// Answers are kept on disk in the cache folder. Until a show is known it
// stays visible.
type Aspects struct {
	mu    sync.Mutex
	known map[string]float64 // show rating key -> aspect (0: seen, unknown)
	path  string
	swept chan struct{} // closed when the library sweep has finished; nil before it starts
	// when a library sweep last finished (unix seconds), kept on disk so
	// the idle screen can sweep again once a day for replaced episodes
	sweptAt    int64
	resweeping bool
}

// aspectFile is aspects2.json on disk.
type aspectFile struct {
	Swept int64              `json:"swept"`
	Shows map[string]float64 `json:"shows"`
}

const (
	aspectProbes  = 8                       // shows probed at once
	aspectBudget  = 6 * time.Second         // per batch; the rest stay visible until next time
	aspectWait    = 1500 * time.Millisecond // how long a listing waits for the sweep before showing
	aspectResweep = 24 * time.Hour          // the idle screen sweeps again after this
)

func (a *Aspects) load(dir string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	// aspects2: answers from before specials were skipped are measured again
	_ = os.Remove(filepath.Join(dir, "aspects.json"))
	a.path = filepath.Join(dir, "aspects2.json")
	a.known = map[string]float64{}
	a.swept = nil
	a.sweptAt = 0
	if data, err := os.ReadFile(a.path); err == nil {
		var f aspectFile
		if json.Unmarshal(data, &f) == nil {
			a.sweptAt = f.Swept
			for key, v := range f.Shows {
				a.known[key] = v
			}
		}
	}
}

func (a *Aspects) save() {
	a.mu.Lock()
	data, err := json.Marshal(aspectFile{Swept: a.sweptAt, Shows: a.known})
	path := a.path
	a.mu.Unlock()
	if err != nil || path == "" {
		return
	}
	tmp := path + ".tmp"
	if os.WriteFile(tmp, data, 0o600) == nil {
		_ = os.Rename(tmp, path)
	}
}

func (a *Aspects) set(key string, v float64) {
	a.mu.Lock()
	a.known[key] = v
	a.mu.Unlock()
}

// aspectShowKey identifies the show whose first episode decides the shape.
// Recently added hubs can supply seasons; use their parent show so they
// agree with the same show's entry in the library.
func aspectShowKey(it *plex.Item) string {
	switch it.Type {
	case "show":
		return it.RatingKey
	case "season":
		return it.ParentKey
	}
	return ""
}

// apply fills in the aspect of shows and seasons already known, without any request.
func (a *Aspects) apply(items []*plex.Item) (unknown []*plex.Item) {
	a.mu.Lock()
	defer a.mu.Unlock()
	for _, it := range items {
		key := aspectShowKey(it)
		if key == "" || it.Aspect != 0 {
			continue
		}
		if v, ok := a.known[key]; ok {
			it.Aspect = v
		} else {
			unknown = append(unknown, it)
		}
	}
	return unknown
}

// sweep starts the one-off library sweep if it has not started, and
// returns the channel closed when it is done; then is called on completion.
func (a *Aspects) sweep(client *plex.Client, then func()) <-chan struct{} {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.swept != nil {
		return a.swept
	}
	done := make(chan struct{})
	a.swept = done
	go func() {
		defer close(done)
		defer then()
		a.sweepLibraries(client)
	}()
	return done
}

// sweepLibraries asks every TV library for its first episodes, replaces
// the answers for the shows they name (shows they miss keep their probed
// answers), and saves with the time it finished.
func (a *Aspects) sweepLibraries(client *plex.Client) {
	secs, err := client.Sections()
	if err != nil {
		return
	}
	for _, s := range secs {
		if s.Type != "show" {
			continue
		}
		found, err := client.FirstEpisodeAspects(s.Key)
		if err != nil {
			continue
		}
		a.mu.Lock()
		for key, v := range found {
			a.known[key] = v
		}
		a.mu.Unlock()
	}
	a.mu.Lock()
	a.sweptAt = time.Now().Unix()
	a.mu.Unlock()
	a.save()
}

// resweepAspects sweeps the TV libraries again once the last sweep is
// aspectResweep old, so a show whose first episode was replaced is judged
// again. Called on every idle tick; it returns at once unless due.
func (a *App) resweepAspects(now time.Time) {
	if a.Plex == nil || a.Cfg == nil || !a.Cfg.FourThree {
		return
	}
	s := &a.aspects
	s.mu.Lock()
	running := s.resweeping
	if s.swept != nil {
		select {
		case <-s.swept:
		default:
			running = true // the first sweep is still going
		}
	}
	if running || s.path == "" || now.Sub(time.Unix(s.sweptAt, 0)) < aspectResweep {
		s.mu.Unlock()
		return
	}
	s.resweeping = true
	s.mu.Unlock()
	client := a.Plex
	go func() {
		s.sweepLibraries(client)
		s.mu.Lock()
		s.resweeping = false
		s.mu.Unlock()
		a.Later(a.refilterHome)
	}()
}

// measureShows fills in the aspect of every show and season in items: from the
// library sweep first, then by probing what it missed (a few at a time,
// within a time budget). Safe from any goroutine; meant for the workers
// that fetch listings.
func (a *App) measureShows(items []*plex.Item) {
	if a.Plex == nil || a.Cfg == nil || !a.Cfg.FourThree {
		return
	}
	client := a.Plex
	deadline := time.Now().Add(aspectBudget)
	if unknown := a.aspects.apply(items); len(unknown) == 0 {
		return
	}
	// a cold cache: give the sweep a moment, then show what is known and
	// let the sweep's completion refilter the home rows
	select {
	case <-a.aspects.sweep(client, func() { a.Later(a.refilterHome) }):
	case <-time.After(aspectWait):
		a.aspects.apply(items)
		return
	}
	unknown := a.aspects.apply(items)
	if len(unknown) == 0 {
		return
	}
	sem := make(chan struct{}, aspectProbes)
	var wg sync.WaitGroup
	for _, it := range unknown {
		if time.Now().After(deadline) {
			break
		}
		wg.Add(1)
		sem <- struct{}{}
		go func(it *plex.Item) {
			defer wg.Done()
			defer func() { <-sem }()
			key := aspectShowKey(it)
			v, err := client.ShowAspect(key)
			if err != nil {
				return // left unknown: visible now, probed again next time
			}
			a.aspects.set(key, v)
			it.Aspect = v
		}(it)
	}
	wg.Wait()
	a.aspects.save()
}

// refilterHome asks the home screen to fetch its rows again, now that the
// sweep can judge the shows in them.
func (a *App) refilterHome() {
	if len(a.stack) > 0 {
		if h, ok := a.stack[0].(*Home); ok {
			h.refreshAt = time.Time{}
		}
	}
	a.pagers = map[string]*Pager{} // library views opened next start from known shapes
}

// measureHubs runs measureShows over every row of a home fetch.
func (a *App) measureHubs(hubs []*plex.Hub) {
	var items []*plex.Item
	for _, hub := range hubs {
		items = append(items, hub.Items...)
	}
	a.measureShows(items)
}

// collectionsPager is a collections listing. Under the 4:3 filter each
// page's collections are looked into (a few at a time, within a time
// budget) before they show, and those holding nothing the filter keeps
// are left out; the listing is kept for the session like any other, so
// that is once per listing. A collection that could not be looked into
// (an error, the budget spent) stays visible.
func (a *App) collectionsPager(path string, q url.Values, fourThree bool) *Pager {
	if !fourThree {
		return a.pager(path, q, nil)
	}
	var mu sync.Mutex
	empty := map[string]bool{} // collection rating key -> the filter keeps none of its items
	keep := func(it *plex.Item) bool {
		mu.Lock()
		defer mu.Unlock()
		return !empty[it.RatingKey]
	}
	look := func(items []*plex.Item) {
		deadline := time.Now().Add(aspectBudget)
		sem := make(chan struct{}, aspectProbes)
		var wg sync.WaitGroup
		for _, it := range items {
			if it.Type != "collection" || it.Key == "" || time.Now().After(deadline) {
				continue
			}
			wg.Add(1)
			sem <- struct{}{}
			go func(it *plex.Item) {
				defer wg.Done()
				defer func() { <-sem }()
				if a.filtersEmpty(it, deadline) {
					mu.Lock()
					empty[it.RatingKey] = true
					mu.Unlock()
				}
			}(it)
		}
		wg.Wait()
	}
	return a.preparedPager(path, q, keep, look)
}

// filtersEmpty reports whether the 4:3 filter keeps none of a collection's
// items, reading its listing until one is kept. Shows take only the shapes
// already known, without a probe: one not yet measured keeps its collection.
func (a *App) filtersEmpty(coll *plex.Item, deadline time.Time) bool {
	for start := 0; time.Now().Before(deadline); {
		items, total, err := a.Plex.Page(coll.Key, nil, start, pageSize)
		if err != nil {
			return false
		}
		a.aspects.apply(items)
		for _, it := range items {
			if a.Keep(it) {
				return false
			}
		}
		start += len(items)
		if len(items) == 0 || start >= total {
			return true
		}
	}
	return false
}
