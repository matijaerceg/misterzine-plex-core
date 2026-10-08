package ui

import (
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/plex"
)

// collectionServer is a synthetic server: library 1 (films) has two
// collections, library 2 (shows) none. The collections listing of
// library 1 waits for hold to close, so a test can look before it lands,
// and answers with an error while failing is set.
type collectionServer struct {
	*httptest.Server
	hold    chan struct{}
	mu      sync.Mutex
	asks    map[string]int
	failing bool
}

func newCollectionServer(t *testing.T) *collectionServer {
	s := &collectionServer{hold: make(chan struct{}), asks: map[string]int{}}
	s.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		s.asks[r.URL.Path]++
		failing := s.failing
		s.mu.Unlock()
		switch r.URL.Path {
		case "/library/sections/1/collections":
			if failing {
				http.Error(w, "busy", http.StatusServiceUnavailable)
				return
			}
			<-s.hold
			io.WriteString(w, `<MediaContainer size="2" totalSize="2">`+
				`<Directory ratingKey="901" key="/library/collections/901/children" type="collection" subtype="movie" title="First Set" thumb="/c/901" childCount="2"/>`+
				`<Directory ratingKey="902" key="/library/collections/9020/children" type="collection" subtype="movie" title="Second Set" thumb="/c/902" art="/a/902" childCount="3"/>`+
				`</MediaContainer>`)
		case "/library/sections/2/collections":
			io.WriteString(w, `<MediaContainer size="0" totalSize="0"></MediaContainer>`)
		case "/library/sections/1/all", "/library/sections/2/all":
			io.WriteString(w, `<MediaContainer size="2" totalSize="2">`+
				`<Video ratingKey="11" key="/library/metadata/11" type="movie" title="Alpha"/>`+
				`<Video ratingKey="12" key="/library/metadata/12" type="movie" title="Beta"/>`+
				`</MediaContainer>`)
		case "/library/collections/9020/children", "/library/collections/902/children":
			// the collection's own order; one wide film for the 4:3 filter to hide.
			// The server's key for it is not the usual path, to tell them apart.
			io.WriteString(w, `<MediaContainer size="3">`+
				`<Video ratingKey="23" key="/library/metadata/23" type="movie" title="Later Square"><Media aspectRatio="1.33"/></Video>`+
				`<Video ratingKey="21" key="/library/metadata/21" type="movie" title="Wide One"><Media aspectRatio="1.78"/></Video>`+
				`<Video ratingKey="22" key="/library/metadata/22" type="movie" title="Unmeasured"/>`+
				`</MediaContainer>`)
		case "/library/metadata/23":
			io.WriteString(w, `<MediaContainer size="1"><Video ratingKey="23" key="/library/metadata/23" type="movie" title="Later Square" summary="A synthetic film."><Media aspectRatio="1.33"/></Video></MediaContainer>`)
		default:
			io.WriteString(w, `<MediaContainer size="0"></MediaContainer>`)
		}
	}))
	t.Cleanup(func() {
		select {
		case <-s.hold:
		default:
			close(s.hold)
		}
		s.Close()
	})
	return s
}

func (s *collectionServer) asked(path string) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.asks[path]
}

func collectionTestApp(t *testing.T, s *collectionServer, fourThree bool) *App {
	t.Helper()
	a := &App{Plex: plex.New(s.URL, "tok", t.TempDir(), ""), Wake: make(chan struct{}, 1), pagers: map[string]*Pager{},
		Cfg: &Config{NoTheme: true, FourThree: fourThree}, Log: log.New(io.Discard, "", 0), Art: NewArt(nil, 0, nil)}
	a.F = Fonts{Title: gfx.Load("med22"), Body: gfx.Load("med18"), Small: gfx.Load("reg16"), SmallBold: gfx.Load("med16"), Big: gfx.Load("bold28")}
	a.T = gfx.NewTextCache(1, nil)
	a.stack = []Screen{&splashTestScreen{}}
	return a
}

func waitUntil(t *testing.T, what string, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !ok() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

var (
	filmsLibrary = plex.Section{Key: "1", Title: "Films", Type: "movie"}
	showsLibrary = plex.Section{Key: "2", Title: "Shows", Type: "show"}
)

// The Collections tab shows only once the library is known to have a
// collection: not while the listing is on its way, not for a library
// without any, and never for a library that cannot hold them.
func TestWallCollectionsTabOnlyWithCollections(t *testing.T) {
	s := newCollectionServer(t)
	a := collectionTestApp(t, s, false)
	now := time.Now()

	films := NewWallView(a, filmsLibrary, 3)
	if n := films.tabCount(); n != len(wallViews)-1 {
		t.Fatalf("%d tabs before the collections listing landed", n)
	}
	films.tabs = true
	films.Key(input.Event{Key: input.Right}, now)
	if films.view != 3 {
		t.Fatal("moved to a Collections tab that is not shown")
	}
	close(s.hold)
	waitUntil(t, "the collections listing", func() bool { return films.collections().Total() >= 0 })
	if n := films.tabCount(); n != len(wallViews) {
		t.Fatalf("%d tabs once the library listed two collections", n)
	}
	films.Key(input.Event{Key: input.Right}, now)
	if films.view != len(wallViews)-1 || !wallViews[films.view].collections {
		t.Fatalf("Right from Continue Watching went to view %d", films.view)
	}
	if films.pager != films.collections() || films.pager.Filtered() {
		t.Fatal("the tab does not show the collections listing")
	}
	if it := films.pager.Get(1); it == nil || it.Type != "collection" || it.Title != "Second Set" || it.Thumb != "/c/902" {
		t.Fatalf("second collection %+v", it)
	}
	if got := heroFacts(films.pager.Get(1)); len(got) != 1 || got[0] != "3 movies" {
		t.Fatalf("the band reads %q", got)
	}
	// settings changes drop the listings; the tab in use stays while its
	// count is fetched again
	a.pagers = map[string]*Pager{}
	if films.tabCount() != len(wallViews) {
		t.Fatal("the Collections tab vanished while it was the view")
	}

	shows := NewWall(a, showsLibrary)
	waitUntil(t, "the empty collections listing", func() bool { return shows.collections().Total() >= 0 })
	if n := shows.tabCount(); n != len(wallViews)-1 {
		t.Fatalf("a library without collections shows %d tabs", n)
	}

	other := NewWall(a, plex.Section{Key: "3", Title: "Clips", Type: "artist"})
	if n := other.tabCount(); n != len(wallViews)-1 || s.asked("/library/sections/3/collections") != 0 {
		t.Fatal("a library that cannot hold collections was asked for them")
	}
}

// A collections listing that failed is asked again while the library is
// on screen, spaced out, so the tab still appears once the server answers.
func TestWallCollectionsRetryAfterFailure(t *testing.T) {
	s := newCollectionServer(t)
	close(s.hold)
	s.mu.Lock()
	s.failing = true
	s.mu.Unlock()
	a := collectionTestApp(t, s, false)
	const path = "/library/sections/1/collections"
	films := NewWall(a, filmsLibrary)
	p := films.collections()
	idle := func() bool {
		p.mu.Lock()
		defer p.mu.Unlock()
		return len(p.inFlt) == 0
	}
	waitUntil(t, "the failed listing", func() bool { return p.Err() != nil && idle() })
	if films.tabCount() != len(wallViews)-1 {
		t.Fatal("a failed listing showed the tab")
	}
	now := time.Now()
	asked := s.asked(path)
	films.retryCollections(now)
	waitUntil(t, "the first retry", func() bool { return s.asked(path) > asked && idle() })
	asked = s.asked(path)
	films.retryCollections(now.Add(CollectionsRetry - time.Second))
	if !idle() || s.asked(path) != asked {
		t.Fatal("asked again before the retry interval")
	}
	s.mu.Lock()
	s.failing = false
	s.mu.Unlock()
	films.retryCollections(now.Add(CollectionsRetry))
	waitUntil(t, "the recovered listing", func() bool { return p.Total() >= 0 })
	if films.tabCount() != len(wallViews) {
		t.Fatal("the tab did not appear once the server answered")
	}
	waitUntil(t, "the retry to settle", idle)
	asked = s.asked(path)
	films.retryCollections(now.Add(3 * CollectionsRetry))
	if !idle() || s.asked(path) != asked {
		t.Fatal("a listing that landed was asked for again")
	}
}

// All five tabs fit inside the frame's safe area at 720x480, before the
// scrollbar at its right edge; a collection's single tab is cut to the
// posters' width however long its title.
func TestWallTabsFit(t *testing.T) {
	s := newCollectionServer(t)
	a := collectionTestApp(t, s, false)
	w := NewWallView(a, filmsLibrary, len(wallViews)-1)
	right := func(tabs int) int {
		c := gfx.NewCanvas(720, 480)
		w.compose(c, nil, 0, tabs)
		edge := -1
		for y := WallTabsY; y < WallTabsY+a.F.SmallBold.Height()+8; y++ {
			for x := 0; x < c.W; x++ {
				o := (y*c.W + x) * 4
				if string(c.Pix[o:o+4]) != string(c.Pix[y*c.W*4:y*c.W*4+4]) && x > edge {
					edge = x
				}
			}
		}
		return edge
	}
	four, five := right(len(wallViews)-1), right(len(wallViews))
	if five <= four+20 {
		t.Fatalf("the fifth tab was not drawn: %d then %d", four, five)
	}
	if five >= WallBarX {
		t.Fatalf("the tabs run to x=%d, into the scrollbar at %d", five, WallBarX)
	}

	coll := NewCollectionWall(a, filmsLibrary, &plex.Item{RatingKey: "902", Type: "collection", Title: strings.Repeat("A very long collection title ", 8)})
	w = coll
	if edge := right(coll.tabCount()); edge >= SafeX+WallBandW {
		t.Fatalf("the collection's tab runs to x=%d, past the posters at %d", edge, SafeX+WallBandW)
	}
}

// OK on a collection opens its items as a wall, in the collection's order
// and through the 4:3 filter; an item opens as anywhere else, and Back
// comes out to the Collections tab on the same collection.
func TestWallOpensCollection(t *testing.T) {
	s := newCollectionServer(t)
	close(s.hold)
	a := collectionTestApp(t, s, true)
	now := time.Now()
	library := NewWallView(a, filmsLibrary, len(wallViews)-1)
	a.Push(library)
	waitUntil(t, "the collections", func() bool { return library.total() == 2 })
	if library.pager.Filtered() {
		t.Fatal("the 4:3 filter walked the collections themselves")
	}
	a.key(input.Event{Key: input.Right}, now)
	a.key(input.Event{Key: input.Enter}, now)
	coll, ok := a.top().(*Wall)
	if !ok || coll == library || coll.coll == nil || coll.coll.RatingKey != "902" {
		t.Fatalf("OK on the second collection opened %T", a.top())
	}
	waitUntil(t, "the collection's items", func() bool { return coll.pager.Done() && coll.total() >= 0 })
	if !coll.pager.Filtered() || coll.total() != 2 {
		t.Fatalf("the 4:3 filter kept %d of the collection's items", coll.total())
	}
	if first, second := coll.pager.Get(0), coll.pager.Get(1); first.RatingKey != "23" || second.RatingKey != "22" {
		t.Fatalf("items %s, %s: not the collection's order less the wide film", first.RatingKey, second.RatingKey)
	}
	if s.asked("/library/collections/9020/children") == 0 || s.asked("/library/collections/902/children") != 0 {
		t.Fatal("the collection's items were not asked for at the path the server gave")
	}
	if coll.tabCount() != 1 || coll.az() {
		t.Fatal("a collection has its title as its only tab, with no letters")
	}
	c := gfx.NewCanvas(720, 480)
	coll.Draw(c, now) // the page composes with the collection's tab

	// Up from the first row has no tabs to go to
	a.key(input.Event{Key: input.Up}, now)
	if coll.tabs {
		t.Fatal("Up put a collection on tabs it does not have")
	}
	a.key(input.Event{Key: input.Enter}, now)
	if p, ok := a.top().(*Preplay); !ok || p.item.RatingKey != "23" {
		t.Fatalf("OK on a film in the collection opened %T", a.top())
	}
	a.key(input.Event{Key: input.Back}, now)
	if a.top() != coll {
		t.Fatal("Back from the film did not return to the collection")
	}
	a.key(input.Event{Key: input.Back}, now)
	if a.top() != library {
		t.Fatalf("one Back from the collection went to %T", a.top())
	}
	if library.view != len(wallViews)-1 || library.cur != 1 || library.tabs {
		t.Fatalf("returned to view %d, item %d, tabs %v", library.view, library.cur, library.tabs)
	}

	// a collection without a usable key of its own: the usual path
	odd := NewCollectionWall(a, filmsLibrary, &plex.Item{RatingKey: "902", Key: "/elsewhere/children", Type: "collection", Title: "Second Set"})
	waitUntil(t, "the usual path", func() bool { return odd.pager.Done() && odd.total() == 2 })
	if s.asked("/library/collections/902/children") == 0 || s.asked("/elsewhere/children") != 0 {
		t.Fatal("a collection without a library key was not opened at the usual path")
	}
}

// Drawing asks on every frame whether the Collections tab shows; once the
// listing is in, that costs no allocations.
func TestWallTabCheckDoesNotAllocate(t *testing.T) {
	s := newCollectionServer(t)
	close(s.hold)
	a := collectionTestApp(t, s, false)
	now := time.Now()
	for _, lib := range []plex.Section{filmsLibrary, showsLibrary} {
		w := NewWall(a, lib)
		waitUntil(t, "the collections", func() bool { return w.collections().Total() >= 0 })
		if n := testing.AllocsPerRun(100, func() {
			if w.tabCount() < len(wallViews) {
				w.retryCollections(now)
			}
		}); n != 0 {
			t.Fatalf("%s: %v allocations per frame", lib.Title, n)
		}
	}
}
