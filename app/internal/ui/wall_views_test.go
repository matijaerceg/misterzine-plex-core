package ui

import (
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/plex"
)

// pagedServer is a synthetic server whose library 1 (films) lists its
// films in pages, as Plex does, with two collections: at first size films
// with rating keys 1000 up, in A to Z order. It counts the page requests
// and the most in flight at once.
type pagedServer struct {
	*httptest.Server

	mu       sync.Mutex
	keys     []int // the films' rating keys in A to Z order
	pages    int
	inFlight int
	most     int
	fails    func(start int) bool // whether a page fails
	onPage   func(start int)      // runs before a page is listed
}

func newPagedServer(t *testing.T, size int) *pagedServer {
	s := &pagedServer{}
	for i := range size {
		s.keys = append(s.keys, 1000+i)
	}
	s.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/library/sections/1/all":
			start, _ := strconv.Atoi(r.URL.Query().Get("X-Plex-Container-Start"))
			count, _ := strconv.Atoi(r.URL.Query().Get("X-Plex-Container-Size"))
			s.mu.Lock()
			s.pages++
			fails, onPage := s.fails, s.onPage
			s.mu.Unlock()
			if fails != nil && fails(start) {
				http.Error(w, "busy", http.StatusServiceUnavailable)
				return
			}
			if onPage != nil {
				onPage(start)
			}
			s.mu.Lock()
			s.inFlight++
			s.most = max(s.most, s.inFlight)
			keys := append([]int(nil), s.keys...)
			s.mu.Unlock()
			time.Sleep(2 * time.Millisecond) // long enough for requests to overlap
			var b strings.Builder
			end := min(len(keys), start+count)
			fmt.Fprintf(&b, `<MediaContainer size="%d" totalSize="%d">`, max(0, end-start), len(keys))
			for _, k := range keys[min(start, end):end] {
				fmt.Fprintf(&b, `<Video ratingKey="%d" key="/library/metadata/%d" type="movie" title="Film %d" thumb="/t/%d"/>`, k, k, k, k)
			}
			b.WriteString(`</MediaContainer>`)
			s.mu.Lock()
			s.inFlight--
			s.mu.Unlock()
			io.WriteString(w, b.String())
		case "/library/sections/1/collections":
			io.WriteString(w, `<MediaContainer size="2" totalSize="2">`+
				`<Directory ratingKey="901" key="/library/collections/901/children" type="collection" subtype="movie" title="First Set" childCount="2"/>`+
				`<Directory ratingKey="902" key="/library/collections/902/children" type="collection" subtype="movie" title="Second Set" childCount="3"/>`+
				`</MediaContainer>`)
		default:
			io.WriteString(w, `<MediaContainer size="0"></MediaContainer>`)
		}
	}))
	t.Cleanup(s.Close)
	return s
}

// insert adds a film to the library at A to Z position at.
func (s *pagedServer) insert(at, key int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.keys = append(s.keys[:at], append([]int{key}, s.keys[at:]...)...)
}

// remove takes the film at A to Z position at out of the library.
func (s *pagedServer) remove(at int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.keys = append(s.keys[:at], s.keys[at+1:]...)
}

func (s *pagedServer) counts() (pages, most int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.pages, s.most
}

func pagedTestApp(t *testing.T, s *pagedServer) *App {
	t.Helper()
	a := &App{Plex: plex.New(s.URL, "tok", t.TempDir(), ""), Wake: make(chan struct{}, 1), pagers: map[string]*Pager{},
		Cfg: &Config{NoTheme: true}, Log: log.New(io.Discard, "", 0), Art: NewArt(nil, 0, nil)}
	a.F = Fonts{Title: gfx.Load("med22"), Body: gfx.Load("med18"), Small: gfx.Load("reg16"), SmallBold: gfx.Load("med16"), Big: gfx.Load("bold28")}
	a.T = gfx.NewTextCache(1, nil)
	a.stack = []Screen{&splashTestScreen{}}
	return a
}

// withExtraViews puts views in the extras' place for one test.
func withExtraViews(t *testing.T, views func(s plex.Section) []wallView) {
	old := extraWallViews
	extraWallViews = func(_ *App, s plex.Section) []wallView { return views(s) }
	t.Cleanup(func() { extraWallViews = old })
}

// loadAll asks for every position until all have landed.
func loadAll(t *testing.T, p *Pager, n int) []*plex.Item {
	t.Helper()
	out := make([]*plex.Item, n)
	waitUntil(t, "every position", func() bool {
		missing := false
		for i := range out {
			if out[i] == nil {
				out[i] = p.Get(i)
				missing = missing || out[i] == nil
			}
		}
		return !missing
	})
	return out
}

// The public build has no extras: a library has exactly its own views and
// opens on A to Z, whatever it was left on.
func TestWallViewsWithoutExtras(t *testing.T) {
	s := newPagedServer(t, 10)
	a := pagedTestApp(t, s)
	if got := a.premiumWallViews(filmsLibrary); got != nil {
		t.Fatalf("extras without a code: %v", got)
	}
	w := NewWall(a, filmsLibrary)
	if len(w.views) != len(wallViews) || w.view != 0 || !w.az() {
		t.Fatalf("%d views, opened on %d", len(w.views), w.view)
	}
	for i, v := range w.views {
		if v.name != wallViews[i].name || v.order != nil || v.remember || v.renew != nil {
			t.Fatalf("view %d is %q", i, v.name)
		}
	}
}

// reverse is an order: the listing backwards.
func reverse(items []*plex.Item) []int {
	at := make([]int, len(items))
	for i := range at {
		at[i] = len(items) - 1 - i
	}
	return at
}

// An ordered pager walks its base to the end, a few pages at a time, then
// shows the items in the order given, the same on every page and on every
// visit; the order is asked for once.
func TestOrderedPagerStableAcrossPages(t *testing.T) {
	const size = 10*pageSize + 7
	s := newPagedServer(t, size)
	a := pagedTestApp(t, s)
	asked := 0
	counted := func(items []*plex.Item) []int {
		asked++
		if len(items) != size {
			t.Errorf("the order was asked for with %d items", len(items))
		}
		return reverse(items)
	}
	q := url.Values{"sort": {"titleSort"}}
	base := a.pager("/library/sections/1/all", q, nil)
	p := NewOrderedPager(base, counted)
	if p.Total() != -1 || p.Get(0) != nil {
		t.Fatal("the order showed before the listing was in")
	}
	waitUntil(t, "the whole listing", func() bool { return p.Total() == size })
	got := loadAll(t, p, size)
	for i, it := range got {
		if it.RatingKey != strconv.Itoa(1000+size-1-i) {
			t.Fatalf("position %d holds %s", i, it.RatingKey)
		}
	}
	if asked != 1 {
		t.Fatalf("the order was asked for %d times", asked)
	}
	if _, most := s.counts(); most > OrderedInFlight {
		t.Fatalf("%d pages loaded at once", most)
	}
	if p.Get(size) != nil || p.Get(-1) != nil {
		t.Fatal("a position outside the listing holds an item")
	}
	// a second visit shares the base's pages and gives the same order
	pages, _ := s.counts()
	again := NewOrderedPager(a.pager("/library/sections/1/all", q, nil), counted)
	for i := 0; i < size; i++ {
		if again.Get(i) != got[i] {
			t.Fatalf("position %d differs on the second visit", i)
		}
	}
	if now, _ := s.counts(); now != pages || asked != 2 {
		t.Fatalf("the second visit fetched pages again or asked %d times", asked)
	}
	if base.Find("1005") != 5 || again.Find("1005") != size-1-5 || again.Find("") != -1 || again.Find("1") != -1 {
		t.Fatal("Find does not give the item's position")
	}
	// an order naming an item twice shows the listing as it is
	odd := NewOrderedPager(base, func(items []*plex.Item) []int { return make([]int, len(items)) })
	for i := 0; i < size; i++ {
		if odd.Get(i) != base.Get(i) {
			t.Fatalf("a bad order moved position %d", i)
		}
	}
}

// Over a filtered listing (the 4:3 filter) the order waits for the walk
// to finish, so positions never move while it grows.
func TestOrderedPagerWaitsForFilteredWalk(t *testing.T) {
	const size = 130
	s := newPagedServer(t, size)
	a := pagedTestApp(t, s)
	keep := func(it *plex.Item) bool { n, _ := strconv.Atoi(it.RatingKey); return n%2 == 0 }
	base := a.pager("/library/sections/1/all", url.Values{"sort": {"titleSort"}}, keep)
	p := NewOrderedPager(base, func(items []*plex.Item) []int {
		if !base.Done() || len(items) != size/2 {
			t.Errorf("the order was asked for with %d items before the walk finished", len(items))
		}
		return reverse(items)
	})
	if !p.Filtered() {
		t.Fatal("the ordered pager does not report its base's filter")
	}
	waitUntil(t, "the walk", func() bool { return p.Total() >= 0 })
	if n := p.Total(); n != size/2 || !p.Done() {
		t.Fatalf("size %d once the walk finished", n)
	}
	if first := p.Get(0); first == nil || first.RatingKey != strconv.Itoa(1000+size-2) {
		t.Fatalf("first position %+v", first)
	}
}

// After a failed page the walk waits before asking again, rather than
// asking on every frame; with the 4:3 filter on too.
func TestOrderedPagerWaitsAfterAFailedPage(t *testing.T) {
	for _, keep := range []func(*plex.Item) bool{nil, func(*plex.Item) bool { return true }} {
		s := newPagedServer(t, 3*pageSize)
		s.fails = func(int) bool { return true }
		a := pagedTestApp(t, s)
		base := a.pager("/library/sections/1/all", url.Values{"sort": {"titleSort"}}, keep)
		p := NewOrderedPager(base, reverse)
		waitUntil(t, "the failure", func() bool { return p.Err() != nil })
		for end := time.Now().Add(300 * time.Millisecond); time.Now().Before(end); {
			if p.Total() != -1 || p.Get(0) != nil {
				t.Fatal("a failed listing showed")
			}
			time.Sleep(time.Millisecond) // a frame
		}
		if pages, _ := s.counts(); pages > 3 {
			t.Fatalf("filtered %v: %d requests in 300 ms after a failure", keep != nil, pages)
		}
		// the pause over, the walk goes on
		s.mu.Lock()
		s.fails = nil
		s.mu.Unlock()
		base.mu.Lock()
		for pg, at := range base.failed {
			base.failed[pg] = at.Add(-PageRetry)
		}
		base.mu.Unlock()
		waitUntil(t, "the listing after the pause", func() bool { return p.Total() == 3*pageSize })
	}
}

// A page that keeps failing waits PageRetry between requests while the
// pages round it load, and the listing shows once it is in.
func TestOrderedPagerPausesOnlyTheFailedPage(t *testing.T) {
	const size = 5 * pageSize
	s := newPagedServer(t, size)
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
	a := pagedTestApp(t, s)
	base := a.pager("/library/sections/1/all", url.Values{"sort": {"titleSort"}}, nil)
	p := NewOrderedPager(base, reverse)
	waitUntil(t, "the other pages", func() bool {
		p.Total()
		base.mu.Lock()
		defer base.mu.Unlock()
		return len(base.seen) == 4
	})
	for end := time.Now().Add(300 * time.Millisecond); time.Now().Before(end); {
		if p.Total() != -1 {
			t.Fatal("a listing with a page missing showed")
		}
		time.Sleep(time.Millisecond) // a frame
	}
	mu.Lock()
	n := asked
	failing = false
	mu.Unlock()
	if n > 2 {
		t.Fatalf("the failed page was asked for %d times in 300 ms", n)
	}
	base.mu.Lock()
	for pg, at := range base.failed {
		base.failed[pg] = at.Add(-PageRetry)
	}
	base.mu.Unlock()
	waitUntil(t, "the listing after the pause", func() bool { return p.Total() == size })
}

// A listing that changes size while it is walked is walked again, where
// its pages no longer fit or (with the 4:3 filter) from the start, so
// every film shows once: with a film added or taken out before the pages
// already in.
func TestOrderedPagerRewalksAChangedListing(t *testing.T) {
	const size = 3 * pageSize
	even := func(it *plex.Item) bool { n, _ := strconv.Atoi(it.RatingKey); return n%2 == 0 }
	for _, tc := range []struct {
		name   string
		keep   func(*plex.Item) bool
		change func(s *pagedServer)
	}{
		{"added", nil, func(s *pagedServer) { s.insert(0, 998) }},
		{"taken out", nil, func(s *pagedServer) { s.remove(0) }},
		{"added, filtered", even, func(s *pagedServer) { s.insert(0, 998) }},
		{"taken out, filtered", even, func(s *pagedServer) { s.remove(0) }},
	} {
		s := newPagedServer(t, size)
		var once sync.Once
		s.onPage = func(start int) {
			if start == 2*pageSize {
				once.Do(func() { tc.change(s) }) // every film moves one place
			}
		}
		a := pagedTestApp(t, s)
		asked := 0
		p := NewOrderedPager(a.pager("/library/sections/1/all", url.Values{"sort": {"titleSort"}}, tc.keep), func(items []*plex.Item) []int {
			asked++
			return reverse(items)
		})
		waitUntil(t, "the whole listing", func() bool { return p.Total() >= 0 })
		s.mu.Lock()
		want := map[string]bool{}
		for _, k := range s.keys {
			if key := strconv.Itoa(k); tc.keep == nil || k%2 == 0 {
				want[key] = true
			}
		}
		s.mu.Unlock()
		seen := map[string]int{}
		for i := 0; i < p.Total(); i++ {
			seen[p.Get(i).RatingKey]++
		}
		for k := range want {
			if seen[k] != 1 {
				t.Fatalf("%s: film %s shows %d times", tc.name, k, seen[k])
			}
		}
		if len(seen) != len(want) || asked == 0 {
			t.Fatalf("%s: %d films show, not %d; the order was asked for %d times", tc.name, len(seen), len(want), asked)
		}
	}
}

// A 4:3-filtered listing that changes again while it is walked again keeps
// showing the walk before, not done (so the wall builds no letters from
// it), until a walk goes through unchanged.
func TestFilteredRewalkKeepsTheListShown(t *testing.T) {
	const size = 3 * pageSize
	s := newPagedServer(t, size)
	a := pagedTestApp(t, s)
	var mu sync.Mutex
	var base *Pager
	var shown [][]string // the list shown during the second and third walks
	walks := 0
	listed := func() []string {
		base.mu.Lock()
		defer base.mu.Unlock()
		var keys []string
		for _, it := range base.list {
			keys = append(keys, it.RatingKey)
		}
		return keys
	}
	s.onPage = func(start int) {
		if start != 2*pageSize {
			return
		}
		mu.Lock()
		defer mu.Unlock()
		walks++
		if walks > 1 {
			shown = append(shown, listed())
			if base.Done() {
				t.Error("the listing is done while it is walked again")
			}
		}
		if walks <= 2 {
			s.insert(0, 990+walks) // every film moves one place
		}
	}
	mu.Lock()
	base = a.pager("/library/sections/1/all", url.Values{"sort": {"titleSort"}}, func(*plex.Item) bool { return true })
	mu.Unlock()
	p := NewOrderedPager(base, reverse)
	waitUntil(t, "the whole listing", func() bool { return p.Total() >= 0 })
	mu.Lock()
	defer mu.Unlock()
	if walks != 3 || len(shown) != 2 || strings.Join(shown[0], ",") != strings.Join(shown[1], ",") {
		t.Fatalf("%d walks; the list shown changed during the third", walks)
	}
	var want []string
	for _, k := range s.keys {
		want = append(want, strconv.Itoa(k))
	}
	if got := listed(); strings.Join(got, ",") != strings.Join(want, ",") || base.Total() != size+2 {
		t.Fatalf("the walked list has %d films, %d shown, not the library's %d", len(got), base.Total(), len(want))
	}
}

// A filtered walk again that fails on a page keeps the walk before
// showing, without an error and not yet done; once PageRetry has passed
// and the wall asks again, it picks up at that page and ends on the
// listing as it is now.
func TestFilteredRewalkRetriesAfterAFailure(t *testing.T) {
	const size = 3 * pageSize
	s := newPagedServer(t, size)
	var mu sync.Mutex
	first := 0
	s.fails = func(start int) bool {
		mu.Lock()
		defer mu.Unlock()
		if start == 0 {
			first++
		}
		return start == 0 && first == 2 // the walk again's first page
	}
	var once sync.Once
	s.onPage = func(start int) {
		if start == 2*pageSize {
			once.Do(func() { s.insert(0, 990) })
		}
	}
	a := pagedTestApp(t, s)
	base := a.pager("/library/sections/1/all", url.Values{"sort": {"titleSort"}}, func(*plex.Item) bool { return true })
	waitUntil(t, "the walk again's failure", func() bool {
		base.mu.Lock()
		defer base.mu.Unlock()
		_, failed := base.failed[0]
		return base.restage && failed && len(base.inFlt) == 0
	})
	if base.Done() || base.Err() != nil || base.Total() != size+1 || base.Get(0).RatingKey != "1000" {
		t.Fatalf("after the failure: done %v, error %v, the walk before shows %d films from %s",
			base.Done(), base.Err(), base.Total(), base.Get(0).RatingKey)
	}
	base.mu.Lock()
	for pg, at := range base.failed {
		base.failed[pg] = at.Add(-PageRetry)
	}
	base.mu.Unlock()
	waitUntil(t, "the walk again", func() bool { base.Get(0); return base.Done() }) // frames only, no button
	mu.Lock()
	defer mu.Unlock()
	if first != 3 || base.Err() != nil || base.Total() != size+1 || base.Get(0).RatingKey != "990" {
		t.Fatalf("%d first pages; the walk shows %d films from %s, error %v", first, base.Total(), base.Get(0).RatingKey, base.Err())
	}
}

// shuffledView is a synthetic extra: the library backwards, rotated by
// one more place on each renewal, keeping its place.
type shuffledView struct {
	turns, renewals int
}

func (v *shuffledView) view() wallView {
	return wallView{name: "Random", path: "/library/sections/%s/all", query: url.Values{"sort": {"titleSort"}},
		order: func(_ plex.Section, items []*plex.Item) []int {
			n := len(items)
			at := make([]int, n)
			for i := range at {
				at[i] = (n - 1 - i + v.turns) % n
			}
			return at
		},
		remember: true,
		renew:    func(plex.Section) { v.turns++; v.renewals++ }}
}

// A view that keeps its place comes back to the same tile in the same
// order: after an item's page, after another tab, and when the library
// is opened again, on it; when the listing has changed since, on the same
// item. OK on its tab starts it over; the cursor stays on the tabs. When
// the extra goes away, the library shows A to Z.
func TestWallViewKeepsItsPlace(t *testing.T) {
	const size = 150
	s := newPagedServer(t, size)
	a := pagedTestApp(t, s)
	sv := &shuffledView{}
	on := true
	extras := []wallView{sv.view()}
	withExtraViews(t, func(plex.Section) []wallView {
		if on {
			return extras
		}
		return nil
	})
	now := time.Now()
	press := func(k input.Key) { a.key(input.Event{Key: k}, now) }
	c := gfx.NewCanvas(720, 480)

	w := NewWall(a, filmsLibrary)
	a.Push(w)
	if w.view != 0 || len(w.views) != len(wallViews)+1 || w.views[wallExtrasAt].name != "Random" {
		t.Fatalf("views %d, opened on %d", len(w.views), w.view)
	}
	press(input.Back) // to the tabs
	for range wallExtrasAt {
		press(input.Right)
	}
	if w.views[w.view].name != "Random" {
		t.Fatalf("Right three times went to %q", w.views[w.view].name)
	}
	waitUntil(t, "the listing", func() bool { return w.total() == size })
	order := loadAll(t, w.pager, size)
	if order[0].RatingKey != strconv.Itoa(1000+size-1) {
		t.Fatalf("the view starts with %s", order[0].RatingKey)
	}
	press(input.Down)
	for range 5 {
		press(input.Right)
	}
	press(input.Down)
	press(input.Down)
	if w.cur != 13 {
		t.Fatalf("cursor at %d", w.cur)
	}

	// an item's page and back: the same tile, the same order
	press(input.Enter)
	if _, ok := a.top().(*Preplay); !ok {
		t.Fatalf("OK on a film opened %T", a.top())
	}
	press(input.Back)
	if a.top() != w || w.cur != 13 || w.pager.Get(13) != order[13] {
		t.Fatal("Back from the film lost the place")
	}

	// another tab and back
	press(input.Back)
	press(input.Left)
	if w.cur != 0 || w.views[w.view].name != "Released" {
		t.Fatalf("Left went to %q at %d", w.views[w.view].name, w.cur)
	}
	press(input.Right)
	if w.cur != 13 || w.pager.Get(13) != order[13] {
		t.Fatalf("back on the view the cursor is at %d", w.cur)
	}

	// the library left and opened again opens on the view, in place
	press(input.Back)
	if a.top() == w {
		t.Fatal("Back from the tabs kept the wall")
	}
	w = NewWall(a, filmsLibrary)
	a.Push(w)
	if w.views[w.view].name != "Random" || w.cur != 13 || w.tabs {
		t.Fatalf("reopened on %q at %d", w.views[w.view].name, w.cur)
	}
	for i := 0; i < size; i++ {
		if w.pager.Get(i) != order[i] {
			t.Fatalf("position %d moved on reopening", i)
		}
	}
	w.Draw(c, now)
	if w.rowY.At(now) != float64(13/WallCols*WallRowPitch) {
		t.Fatal("the grid did not scroll to the remembered row")
	}

	// OK on the tab starts the view over; a held OK does not repeat it
	press(input.Up)
	press(input.Up)
	press(input.Up)
	press(input.Up)
	if !w.tabs {
		t.Fatal("Up from the first row did not reach the tabs")
	}
	press(input.Enter)
	if sv.renewals != 1 || w.cur != 0 || !w.tabs {
		t.Fatalf("OK on the tab: %d renewals, cursor %d, tabs %v", sv.renewals, w.cur, w.tabs)
	}
	if w.pager.Get(0) == order[0] {
		t.Fatal("the view did not start over in a new order")
	}
	a.key(input.Event{Key: input.Enter, Repeat: true}, now)
	if sv.renewals != 1 {
		t.Fatal("a held OK started the view over again")
	}
	press(input.Down)
	if w.tabs || sv.renewals != 1 {
		t.Fatal("Down from the tab did not go to the grid")
	}
	press(input.Right)
	press(input.Back)
	press(input.Back)
	w = NewWall(a, filmsLibrary)
	a.Push(w)
	if w.views[w.view].name != "Random" || w.cur != 1 {
		t.Fatalf("after starting over the library reopened at %d", w.cur)
	}

	// a film added at the end and the listings fetched again (a settings
	// change): the backwards order now has the remembered film one later,
	// and the cursor follows it there
	held := w.pager.Get(1)
	press(input.Back)
	press(input.Back)
	a.pagers = map[string]*Pager{}
	s.insert(size, 5000)
	w = NewWall(a, filmsLibrary)
	a.Push(w)
	waitUntil(t, "the longer listing", func() bool { return w.total() == size+1 })
	w.Draw(c, now)
	if it := w.pager.Get(w.cur); w.cur != 2 || it == nil || it.RatingKey != held.RatingKey {
		t.Fatalf("the cursor is at %d, not on film %s", w.cur, held.RatingKey)
	}
	if w.rowY.At(now) != 0 {
		t.Fatal("the grid is not on the film's row")
	}

	// OK on a tab of the library's own goes down to the grid as before
	press(input.Back)
	press(input.Left)
	press(input.Enter)
	if w.tabs || sv.renewals != 1 {
		t.Fatal("OK on Released did not go down to the grid")
	}

	// the extra gone, the wall on it falls back to A to Z, and so does
	// the library opened again
	press(input.Back)
	press(input.Right)
	on = false
	w.Draw(c, now)
	if w.view != 0 || len(w.views) != len(wallViews) || !w.az() || w.cur != 0 {
		t.Fatalf("with the extra gone the wall shows view %d at %d", w.view, w.cur)
	}
	if NewWall(a, filmsLibrary).view != 0 {
		t.Fatal("the library reopened on a view that has gone")
	}
	on = true
	if w := NewWall(a, filmsLibrary); w.view != 0 {
		t.Fatal("the library reopened on the view after it had shown A to Z")
	}
}

// With an extra view the library has six tabs; Collections stays the last
// and shows only once the library has some.
func TestWallSixTabs(t *testing.T) {
	s := newPagedServer(t, 10)
	a := pagedTestApp(t, s)
	sv := &shuffledView{}
	withExtraViews(t, func(plex.Section) []wallView { return []wallView{sv.view()} })
	w := NewWall(a, filmsLibrary)
	waitUntil(t, "the collections", func() bool { return w.collections().Total() >= 0 })
	if n := w.tabCount(); n != len(wallViews)+1 {
		t.Fatalf("%d tabs", n)
	}
	w.tabs = true
	for range len(wallViews) {
		w.Key(input.Event{Key: input.Right}, time.Now())
	}
	if !w.views[w.view].collections || w.view != len(w.views)-1 {
		t.Fatalf("the last tab is %q", w.views[w.view].name)
	}
	shows := NewWall(a, plex.Section{Key: "7", Title: "Clips", Type: "artist"})
	if n := shows.tabCount(); n != len(wallViews) {
		t.Fatalf("a library without collections has %d tabs", n)
	}

	// five tabs keep their spacing; six close up to fit before the scrollbar
	if gap := w.tabGap(len(wallViews)); gap != WallTabGap {
		t.Fatalf("five tabs %d apart", gap)
	}
	five, six := tabsRightEdge(w, len(wallViews)), tabsRightEdge(w, len(wallViews)+1)
	if six <= five+20 {
		t.Fatalf("the sixth tab was not drawn: %d then %d", five, six)
	}
	if six >= WallTabsRight || six >= WallBarX {
		t.Fatalf("six tabs run to x=%d, past %d", six, WallTabsRight)
	}
	if gap := w.tabGap(len(wallViews) + 1); gap < WallTabMinGap || gap >= WallTabGap {
		t.Fatalf("six tabs %d apart", gap)
	}
}

// Drawing checks the extras' views on every frame; while they stay the
// same that costs no allocations.
func TestWallViewSyncDoesNotAllocate(t *testing.T) {
	s := newPagedServer(t, 10)
	a := pagedTestApp(t, s)
	sv := &shuffledView{}
	extras := []wallView{sv.view()}
	for _, views := range [][]wallView{nil, extras} {
		withExtraViews(t, func(plex.Section) []wallView { return views })
		w := NewWall(a, filmsLibrary)
		if n := testing.AllocsPerRun(100, w.syncViews); n != 0 {
			t.Fatalf("%d extras: %v allocations per frame", len(views), n)
		}
	}
}

// A view that asks is told when its library is left: once, as the wall is
// popped, whichever view it was on. A film's page or a collection's wall
// opened over the wall and closed again does not leave the library.
func TestWallViewHearsTheLibraryLeft(t *testing.T) {
	s := newPagedServer(t, 10)
	a := pagedTestApp(t, s)
	var left []string
	withExtraViews(t, func(plex.Section) []wallView {
		return []wallView{
			{name: "Hears", path: "/library/sections/%s/all", left: func(s plex.Section) { left = append(left, s.Key) }},
			{name: "Quiet", path: "/library/sections/%s/all"},
		}
	})
	now := time.Now()
	press := func(k input.Key) { a.key(input.Event{Key: k}, now) }
	w := NewWall(a, filmsLibrary)
	a.Push(w)
	waitUntil(t, "the listing", func() bool { return w.pager.Get(0) != nil })

	press(input.Enter) // a film's page, and back
	if _, ok := a.top().(*Preplay); !ok {
		t.Fatalf("OK on a film opened %T", a.top())
	}
	press(input.Back)
	coll := &plex.Item{RatingKey: "901", Key: "/library/collections/901/children", Type: "collection", Title: "First Set"}
	a.Push(NewCollectionWall(a, filmsLibrary, coll)) // a collection's wall, and back
	press(input.Back)
	if a.top() != w || len(left) != 0 {
		t.Fatalf("pages over the wall told the views %v, on top %T", left, a.top())
	}

	press(input.Back) // to the tabs
	if a.top() != w || len(left) != 0 {
		t.Fatalf("Back to the tabs told the views %v", left)
	}
	press(input.Right) // on another view than the one that hears
	press(input.Back)
	if a.top() == w || len(left) != 1 || left[0] != filmsLibrary.Key {
		t.Fatalf("leaving the library told the views %v", left)
	}
}

// tabsRightEdge is the rightmost pixel the first tabs of a wall's tabs
// paint, the active one's underline included.
func tabsRightEdge(w *Wall, tabs int) int {
	c := gfx.NewCanvas(720, 480)
	w.compose(c, nil, 0, tabs)
	edge := -1
	for y := WallTabsY; y < WallTabsY+w.app.F.SmallBold.Height()+8; y++ {
		for x := 0; x < c.W; x++ {
			o := (y*c.W + x) * 4
			if string(c.Pix[o:o+4]) != string(c.Pix[y*c.W*4:y*c.W*4+4]) && x > edge {
				edge = x
			}
		}
	}
	return edge
}
