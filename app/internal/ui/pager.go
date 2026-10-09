package ui

import (
	"net/url"
	"strings"
	"sync"
	"time"

	"plexcrt/internal/plex"
)

// Pager is a sparse view of a long server listing: items arrive in pages of
// pageSize around whatever the cursor is near, fetched in the background, so
// a 6,000-title library opens instantly and the alphabet jump lands anywhere.
type Pager struct {
	client *plex.Client
	path   string
	query  url.Values
	mu     sync.Mutex
	items  map[int]*plex.Item
	total  int
	loaded bool
	err    error // what Err reports
	// failErr is the last failed fetch's error, which err takes again
	// while a page that is asked for waits out PageRetry
	failErr error
	inFlt   map[int]bool // page index being fetched
	// when each page whose last fetch failed failed (it is asked for again
	// only after PageRetry); for a walk to the end (whole): the listing's
	// size each page was fetched with, how many pages (filtered, walks)
	// were fetched again after it changed, and a count of the changes to
	// the items shown
	failed  map[int]time.Time
	seen    map[int]int
	rewalks int
	gen     int
	Wake    chan struct{}
	// with a filter the listing is walked page by page from the start and
	// the kept items packed into list; total is then what has been kept
	// so far, and the alphabet index does not apply
	filter func(*plex.Item) bool
	// Prepare, if set, completes a page's items (in the fetching goroutine)
	// before the filter sees them: shows are probed for their shape
	Prepare func([]*plex.Item)
	list    []*plex.Item
	next    int  // next raw page to fetch
	done    bool // every raw page has been seen
	// a filtered walk during which the listing changed size is walked again
	// into stage, list showing meanwhile and done staying false; a failed
	// page gives the walk again up. pass is the size the walk started with,
	// mixed whether it changed since
	stage   []*plex.Item
	restage bool
	pass    int
	mixed   bool
	// an ordered pager (NewOrderedPager) fetches nothing itself: once base
	// has been walked to the end it holds base's items in list, in its own
	// order, total being their count; made is base's gen the order was made
	// for
	base  *Pager
	order func(items []*plex.Item) []int
	made  int
}

const pageSize = 60

// OrderedInFlight is how many of a listing's pages may load at once while
// an ordered pager walks it; the wall asks for the rest as pages land.
const OrderedInFlight = 4

// PageRetry is how long a page whose fetch failed waits before it is asked
// for again, however the listing is walked: the wall asks for the pages
// around the cursor on every frame (and an ordered pager's walk for the
// rest), which would otherwise send the request again on every frame the
// error shows.
const PageRetry = 5 * time.Second

// OrderedRewalks is how many times over a listing that changed size while
// it was walked is walked again; after that its pages are taken as they
// come.
const OrderedRewalks = 2

// NewPager starts loading the first page; wake is signalled as pages land.
// A filter, if given, hides items it rejects; prepare, if given, completes
// each page's items before the filter sees them.
func NewPager(c *plex.Client, path string, q url.Values, wake chan struct{}, filter func(*plex.Item) bool, prepare func([]*plex.Item)) *Pager {
	p := &Pager{client: c, path: path, query: q, items: map[int]*plex.Item{}, inFlt: map[int]bool{},
		failed: map[int]time.Time{}, seen: map[int]int{}, Wake: wake, total: -1, filter: filter, Prepare: prepare}
	p.Want(0)
	return p
}

// NewOrderedPager shows base's whole listing in an order of the caller's.
// Base is walked to the end first, a few pages at a time as the listing is
// asked for (the wall asks on every frame and as pages land), the size
// being -1 until then. order is then given the listing's items and returns
// the index of each position's item, each at most once (anything else
// shows the listing as it is): an order made from the items themselves
// holds however the listing changes. It is made again only when base's
// items change, the old one showing until the new listing is in. Base
// keeps the items, so its own view shares them.
func NewOrderedPager(base *Pager, order func(items []*plex.Item) []int) *Pager {
	return &Pager{base: base, order: order, total: -1, made: -1, Wake: base.Wake}
}

// arrange is an ordered pager's size, -1 until its order is made; until
// then it keeps base's walk going.
func (p *Pager) arrange() int {
	p.base.mu.Lock()
	gen := p.base.gen
	p.base.mu.Unlock()
	p.mu.Lock()
	size, made := p.total, p.made
	p.mu.Unlock()
	if made >= 0 && gen == made {
		return size
	}
	items := p.base.whole()
	if items == nil {
		return size
	}
	at := p.order(items)
	if !distinctIndices(at, len(items)) {
		at = make([]int, len(items))
		for i := range at {
			at[i] = i
		}
	}
	list := make([]*plex.Item, len(at))
	for k, j := range at {
		list[k] = items[j]
	}
	p.mu.Lock()
	p.list, p.total, p.made = list, len(list), gen
	p.mu.Unlock()
	return len(list)
}

// whole is the whole listing once every page of it is in, all fetched
// while the listing had the size it has now, nil before. Missing pages,
// and pages fetched before the listing changed size (their items may have
// moved), are asked for a few at a time and in order, up to OrderedRewalks
// times for a listing that keeps changing; a failed page is asked for
// again after PageRetry. A filtered listing is walked from the start
// again instead (by fetch), at the end of a walk during which it changed
// size.
func (p *Pager) whole() []*plex.Item {
	p.mu.Lock()
	if p.filter != nil {
		var out []*plex.Item
		if p.done {
			out = append(make([]*plex.Item, 0, len(p.list)), p.list...)
		}
		// the walk goes on by itself; this restarts one a failure stopped
		n := p.next
		walk := !p.done && len(p.inFlt) == 0 && !p.waiting(n)
		if walk {
			p.inFlt[n] = true
		}
		p.mu.Unlock()
		if walk {
			go p.fetch(n)
		}
		return out
	}
	total := p.total
	complete := total >= 0
	var fetch []int
	if total < 0 && len(p.inFlt) == 0 && !p.waiting(0) {
		p.inFlt[0] = true
		fetch = append(fetch, 0)
	}
	rewalk := p.rewalks < OrderedRewalks*(total/pageSize+1)
	for pg := 0; pg*pageSize < total; pg++ {
		was, ok := p.seen[pg]
		if ok && (was == total || !rewalk) {
			continue
		}
		complete = false
		if len(p.inFlt) >= OrderedInFlight {
			break
		}
		if !p.inFlt[pg] && !p.waiting(pg) {
			if ok {
				p.rewalks++
			}
			p.inFlt[pg] = true
			fetch = append(fetch, pg)
		}
	}
	var out []*plex.Item
	if complete && len(p.inFlt) == 0 { // a page still landing may change the size
		out = make([]*plex.Item, 0, total)
		for i := 0; i < total; i++ {
			if it := p.items[i]; it != nil {
				out = append(out, it)
			}
		}
	}
	p.mu.Unlock()
	for _, pg := range fetch {
		go p.fetch(pg)
	}
	return out
}

// paused reports whether page n failed less than PageRetry ago. The
// caller holds mu.
func (p *Pager) paused(n int) bool {
	at, ok := p.failed[n]
	return ok && time.Since(at) < PageRetry
}

// waiting is paused for a page that is asked for: while it waits, its
// failure is the pager's error again, even when another page has landed
// since (pages load side by side), so the error shows for as long as a
// page that is needed is missing. The caller holds mu.
func (p *Pager) waiting(n int) bool {
	if !p.paused(n) {
		return false
	}
	p.err = p.failErr
	return true
}

// distinctIndices reports whether at holds indices below n, each once.
func distinctIndices(at []int, n int) bool {
	if len(at) > n {
		return false
	}
	seen := make([]bool, n)
	for _, j := range at {
		if j < 0 || j >= n || seen[j] {
			return false
		}
		seen[j] = true
	}
	return true
}

// Find is the position of the loaded item with the rating key, or -1;
// nothing is fetched.
func (p *Pager) Find(key string) int {
	if key == "" {
		return -1
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.base != nil || p.filter != nil {
		for i, it := range p.list {
			if it != nil && it.RatingKey == key {
				return i
			}
		}
		return -1
	}
	at := -1
	for i, it := range p.items {
		if it != nil && it.RatingKey == key && (at < 0 || i < at) {
			at = i
		}
	}
	return at
}

// Done reports whether a filtered walk has seen the whole listing.
func (p *Pager) Done() bool {
	if p.base != nil {
		return p.base.Done()
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.filter == nil || p.done
}

// Filtered reports whether the listing is a filtered walk (no letter index).
func (p *Pager) Filtered() bool {
	if p.base != nil {
		return p.base.Filtered()
	}
	return p.filter != nil
}

// Total is the listing size, or -1 until the first page lands.
func (p *Pager) Total() int {
	if p.base != nil {
		return p.arrange()
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.filter != nil {
		if !p.loaded {
			return -1
		}
		return len(p.list)
	}
	return p.total
}

// Err is the last fetch error, gone once a page lands. A page that failed
// brings it back whenever it is asked for while it waits out PageRetry.
func (p *Pager) Err() error {
	if p.base != nil {
		return p.base.Err()
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.err
}

// Get returns item i if loaded; nil queues its page.
func (p *Pager) Get(i int) *plex.Item {
	if p.base != nil {
		p.arrange()
		p.mu.Lock()
		defer p.mu.Unlock()
		if i >= 0 && i < len(p.list) {
			return p.list[i]
		}
		return nil
	}
	return p.get(i, true)
}

// get is Get; ahead also queues the page after i's.
func (p *Pager) get(i int, ahead bool) *plex.Item {
	p.mu.Lock()
	var it *plex.Item
	if p.filter != nil {
		if i >= 0 && i < len(p.list) {
			it = p.list[i]
		}
	} else {
		it = p.items[i]
	}
	p.mu.Unlock()
	if it == nil {
		p.want(i, ahead)
	}
	return it
}

// Want makes sure the page holding i (and its neighbours) is loading.
func (p *Pager) Want(i int) {
	if p.base != nil {
		p.arrange()
		return
	}
	p.want(i, true)
}

// Retry is Want without waiting out PageRetry for the page holding i (for
// a filtered walk, the page it stopped at): for a caller that spaces its
// own retries.
func (p *Pager) Retry(i int) {
	p.mu.Lock()
	n := i / pageSize
	if p.filter != nil {
		n = p.next
	}
	delete(p.failed, n)
	p.mu.Unlock()
	p.Want(i)
}

// want is Want; without ahead only i's page is asked for, and only while
// fewer than OrderedInFlight pages are loading. A page that failed is
// asked for again only after PageRetry, its error showing meanwhile.
func (p *Pager) want(i int, ahead bool) {
	if i < 0 {
		return
	}
	if p.filter != nil {
		// keep a page of kept items ahead of the cursor, one fetch at a time
		p.mu.Lock()
		fetch := !p.done && len(p.inFlt) == 0 && i+pageSize/2 >= len(p.list) && !p.waiting(p.next)
		if fetch {
			p.inFlt[p.next] = true
		}
		n := p.next
		p.mu.Unlock()
		if fetch {
			go p.fetch(n)
		}
		return
	}
	pg := i / pageSize
	last := pg + 1
	if !ahead {
		last = pg
	}
	for n := pg; n <= last; n++ {
		p.mu.Lock()
		if p.total >= 0 && n*pageSize >= p.total {
			p.mu.Unlock()
			continue
		}
		if p.inFlt[n] || p.items[n*pageSize] != nil || p.waiting(n) || (!ahead && len(p.inFlt) >= OrderedInFlight) {
			p.mu.Unlock()
			continue
		}
		p.inFlt[n] = true
		p.mu.Unlock()
		go p.fetch(n)
	}
}

func (p *Pager) fetch(n int) {
	q := url.Values{}
	for k, v := range p.query {
		q[k] = v
	}
	// the wall needs titles, art and progress only; the rest is fetched per item
	q.Set("excludeFields", "summary,tagline")
	ex := "Genre,Director,Writer,Role,Country,Producer,Media,Guid,Collection,Label,Field,Image"
	if p.filter != nil {
		ex = strings.Replace(ex, "Media,", "", 1) // the filter reads the media's aspect
	}
	q.Set("excludeElements", ex)
	items, total, err := p.client.Page(p.path, q, n*pageSize, pageSize)
	if err == nil && p.filter != nil && p.Prepare != nil {
		p.Prepare(items)
	}
	p.mu.Lock()
	delete(p.inFlt, n)
	if p.failed == nil {
		p.failed, p.seen = map[int]time.Time{}, map[int]int{}
	}
	if err != nil && p.restage {
		// the walk before stands, as it would have without the walk again
		p.restage, p.stage, p.done = false, nil, true
	} else if err != nil {
		p.err, p.failErr = err, err
		p.failed[n] = time.Now()
	} else {
		delete(p.failed, n)
		p.err = nil
		p.total = total
		p.seen[n] = total
		p.loaded = true
		p.gen++
		if p.filter != nil {
			if n == 0 {
				p.pass, p.mixed = total, false
			} else if total != p.pass {
				p.mixed = true
			}
			for _, it := range items {
				switch {
				case !p.filter(it):
				case p.restage:
					p.stage = append(p.stage, it)
				default:
					p.list = append(p.list, it)
				}
			}
			p.next = n + 1
			if n*pageSize+len(items) >= total || len(items) == 0 {
				// a walk during which the listing changed size may have
				// missed items or kept them twice: walk again, showing the
				// walk before until one goes through unchanged
				again := p.mixed && p.rewalks < OrderedRewalks
				if p.restage && !again {
					p.list, p.restage = p.stage, false
				}
				p.stage = nil
				if again {
					p.restage, p.next = true, 0
					p.rewalks++
				} else {
					p.done = true
				}
			}
			if !p.done {
				// keep walking to the end, so the count and the scrollbar
				// settle within seconds and the letter index can be built
				p.inFlt[p.next] = true
				go p.fetch(p.next)
			}
		} else {
			for i, it := range items {
				p.items[n*pageSize+i] = it
			}
		}
	}
	p.mu.Unlock()
	select {
	case p.Wake <- struct{}{}:
	default:
	}
}

// Letters builds a first-letter index from a finished filtered walk.
func (p *Pager) Letters() []plex.Letter {
	if p.base != nil {
		return nil // an order of its own has no letters
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	var out []plex.Letter
	for _, it := range p.list {
		k := "#"
		if title := it.SortLabel(); len(title) > 0 {
			ch := title[0]
			if ch >= 'a' && ch <= 'z' {
				ch -= 'a' - 'A'
			}
			if ch >= 'A' && ch <= 'Z' {
				k = string(ch)
			}
		}
		if len(out) > 0 && out[len(out)-1].Key == k {
			out[len(out)-1].Size++
		} else {
			out = append(out, plex.Letter{Key: k, Size: 1})
		}
	}
	return out
}

// Replace swaps one item (after playback refreshed it).
func (p *Pager) Replace(i int, it *plex.Item) {
	p.mu.Lock()
	if p.base != nil {
		if i >= 0 && i < len(p.list) {
			p.list[i] = it
		}
		p.mu.Unlock()
		return
	}
	if p.filter != nil {
		if i >= 0 && i < len(p.list) {
			p.list[i] = it
		}
	} else {
		p.items[i] = it
	}
	p.mu.Unlock()
}
