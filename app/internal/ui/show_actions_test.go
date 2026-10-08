package ui

import (
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"slices"
	"sync/atomic"
	"testing"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/plex"
)

// showServer holds one show ("show") with three seasons of four episodes
// and a special, listed in order by the show's allLeaves.
type showServer struct {
	*httptest.Server
	keys     []string     // every episode, in the server's order
	listings atomic.Int32 // allLeaves requests
	fail     atomic.Bool  // the listing is refused
}

func newShowServer(t *testing.T) *showServer {
	s := &showServer{}
	for season := 0; season <= 3; season++ {
		n := 4
		if season == 0 {
			n = 1 // a special
		}
		for e := 1; e <= n; e++ {
			s.keys = append(s.keys, fmt.Sprintf("s%de%d", season, e))
		}
	}
	s.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/library/metadata/show/allLeaves" {
			http.NotFound(w, r)
			return
		}
		s.listings.Add(1)
		if s.fail.Load() {
			http.Error(w, "busy", 503)
			return
		}
		fmt.Fprintf(w, `<MediaContainer size="%d" totalSize="%d">`, len(s.keys), len(s.keys))
		for i, k := range s.keys {
			// some watched, some part watched: a shuffle leaves none out
			fmt.Fprintf(w, `<Video ratingKey=%q type="episode" title=%q viewCount="%d" viewOffset="%d"/>`, k, k, i%2, (i%3)*60000)
		}
		io.WriteString(w, "</MediaContainer>")
	}))
	t.Cleanup(s.Close)
	return s
}

// errPlayed is what the test player answers instead of playing: the notice
// it leaves shows that a playback was asked for.
var errPlayed = errors.New("played")

func showTestApp(t *testing.T, s *showServer) *App {
	a := &App{Plex: plex.New(s.URL, "tok", t.TempDir(), ""), Log: log.New(io.Discard, "", 0),
		Out: &fakeOut{c: gfx.NewCanvas(720, 480)}, Cfg: &Config{}, later: make(chan func(), 32),
		Art: NewArt(nil, 0, nil), T: gfx.NewTextCache(0, nil),
		Player: &Player{Access: func() error { return errPlayed }}}
	a.F = Fonts{Title: gfx.Load("med22"), Body: gfx.Load("med18"), Small: gfx.Load("reg16"), SmallBold: gfx.Load("med16"), Big: gfx.Load("bold28")}
	return a
}

// landShuffle takes the shuffle's listing on the render thread, as Run does.
func landShuffle(t *testing.T, a *App) {
	t.Helper()
	select {
	case f := <-a.later:
		f()
	case <-time.After(5 * time.Second):
		t.Fatal("the episodes were never listed")
	}
}

// twoSeasons is a show's seasons with season 2's episodes already listed,
// so a page opens on them at once. Their tracks are known: no fetches.
func twoSeasons(a *App) []*plex.Item {
	seasons := []*plex.Item{{Type: "season", RatingKey: "one", Key: "/one"}, {Type: "season", RatingKey: "two", Key: "/two"}}
	a.seasonData = &seasonData{client: a.Plex, key: "/two", until: time.Now().Add(time.Minute),
		eps: []*plex.Item{{RatingKey: "e1", Audio: []plex.Stream{{}}}, {RatingKey: "e2", Audio: []plex.Stream{{}}}}}
	return seasons
}

func TestShuffleQueueIsEveryEpisodeOnce(t *testing.T) {
	srv := newShowServer(t)
	a := showTestApp(t, srv)
	reordered := false
	for range 20 {
		queue, err := shuffleQueue(a.Plex, "show")
		if err != nil {
			t.Fatal(err)
		}
		var keys []string
		for _, it := range queue {
			keys = append(keys, it.RatingKey)
		}
		if !slices.Equal(keys, srv.keys) {
			reordered = true
		}
		slices.Sort(keys)
		if want := slices.Sorted(slices.Values(srv.keys)); !slices.Equal(keys, want) {
			t.Fatalf("the queue is not every episode once: %q", keys)
		}
	}
	if !reordered {
		t.Fatal("twenty shuffles of thirteen episodes all kept the server's order")
	}
}

// A full queue of render-thread work holds the listing's answer back but
// never drops it: the start bar and the held keys end only with it.
func TestShuffleAnswerWaitsForRoom(t *testing.T) {
	srv := newShowServer(t)
	a := showTestApp(t, srv)
	for len(a.later) < cap(a.later) {
		a.later <- func() {}
	}
	a.Shuffle(&plex.Item{RatingKey: "show"}, nil)
	for a.shuffling != nil {
		landShuffle(t, a) // the queued work first, then the answer
	}
	if a.Notice != errPlayed.Error() || !a.Starting.IsZero() {
		t.Fatalf("after a full queue: notice %q", a.Notice)
	}
}

// A shuffle runs on into its next episode with Autoplay off, and starts each
// from the beginning; an ordinary queue still does as Options say.
func TestShuffleRunsOnFromTheStart(t *testing.T) {
	a := &App{Cfg: &Config{NoAutoplay: true}}
	if !a.runsOn(true) || a.runsOn(false) {
		t.Fatal("with Autoplay off only a shuffle should run on")
	}
	a.Cfg.NoAutoplay = false
	if !a.runsOn(true) || !a.runsOn(false) {
		t.Fatal("with Autoplay on every queue should run on")
	}
	ep := &plex.Item{ViewOffset: 300}
	if startOf(ep, true) != 0 || startOf(ep, false) != 300 {
		t.Fatal("a shuffle must start episodes from the beginning, a season at their resume point")
	}
}

func TestPickerEndsWithShuffle(t *testing.T) {
	srv := newShowServer(t)
	a := showTestApp(t, srv)
	seasons := twoSeasons(a)
	backing := slices.Grow(seasons, 1) // room the tile must not be written into
	v := NewShow(a, &plex.Item{RatingKey: "show", Title: "Show"}, backing)
	a.stack = []Screen{v}
	row := v.picker.hubs[0].Items
	if len(row) != 3 || row[2].Type != ShuffleTile || backing[:3][2] != nil {
		t.Fatalf("picker row %v; the seasons' own array was written to: %v", row, backing[:3][2] != nil)
	}

	v.picker.focusSeason(2)
	a.key(input.Event{Key: input.Down}, time.Now())
	if v.episodes {
		t.Fatal("Down on the Shuffle tile opened a season")
	}
	// OK lists the episodes in the background: the page keeps drawing, with
	// the start indicator, and other keys wait
	a.key(input.Event{Key: input.Enter}, time.Now())
	if a.shuffling == nil || a.Starting.IsZero() || a.Notice != "" {
		t.Fatal("OK on the tile did not start listing the episodes")
	}
	if !v.Draw(gfx.NewCanvas(720, 480), time.Now().Add(time.Second)) {
		t.Fatal("the page stopped drawing while the episodes were listed")
	}
	a.key(input.Event{Key: input.Left}, time.Now())
	if v.picker.col[0] != 2 {
		t.Fatal("a key acted while the episodes were listed")
	}
	landShuffle(t, a)
	if a.Notice != errPlayed.Error() || a.shuffling != nil || !a.Starting.IsZero() {
		t.Fatalf("after the listing: notice %q", a.Notice)
	}

	// Back while listing gives up: nothing plays and the show stays
	a.Notice = ""
	a.key(input.Event{Key: input.Enter}, time.Now())
	a.key(input.Event{Key: input.Back}, time.Now())
	if a.shuffling != nil || !a.Starting.IsZero() || a.top() != v {
		t.Fatal("Back did not give up the shuffle in place")
	}
	landShuffle(t, a)
	if a.Notice != "" {
		t.Fatalf("a shuffle given up still played: %q", a.Notice)
	}

	v.picker.focusSeason(1)
	a.key(input.Event{Key: input.Down}, time.Now())
	if !v.episodes || !slices.Equal(v.season.seasons, seasons) {
		t.Fatal("the season page did not get the seasons alone")
	}

	srv.fail.Store(true)
	v.overview(time.Now())
	v.picker.focusSeason(2)
	a.key(input.Event{Key: input.Enter}, time.Now())
	landShuffle(t, a)
	if a.Notice != "Could not list the show's episodes." || !a.Starting.IsZero() {
		t.Fatalf("a refused listing: notice %q", a.Notice)
	}
	v.fade.Done()
}

func TestSeasonShuffleShow(t *testing.T) {
	srv := newShowServer(t)
	a := showTestApp(t, srv)
	v := NewShow(a, &plex.Item{RatingKey: "show"}, twoSeasons(a))
	a.stack = []Screen{v}
	v.enterSeason(1, "", time.Now())
	s := v.season
	i := slices.Index(s.actions, ShuffleShow)
	if i < 0 {
		t.Fatalf("no %q in %q", ShuffleShow, s.actions)
	}
	s.acts, s.act = true, i
	a.key(input.Event{Key: input.Enter}, time.Now())
	if a.shuffling == nil || srv.listings.Load() > 1 {
		t.Fatal("Shuffle show did not start listing the episodes")
	}
	landShuffle(t, a)
	if srv.listings.Load() != 1 || a.Notice != errPlayed.Error() {
		t.Fatalf("Shuffle show: %d listings, notice %q", srv.listings.Load(), a.Notice)
	}
	if now := time.Now(); now.Before(s.periodic.next) || now.Before(v.periodic.next) {
		t.Fatal("the watched marks were not fetched again at once after the shuffle")
	}
	if !v.episodes || s.actions[s.act] != ShuffleShow {
		t.Fatalf("the page moved: episodes %v, cursor on %q", v.episodes, s.actions[s.act])
	}
}

// Go to show is offered where Back would leave the show, and only there.
func TestGoToShow(t *testing.T) {
	a := &App{F: Fonts{Body: gfx.Load("med18")}}
	seasons := twoSeasons(a)
	v := NewShowInSeason(a, &plex.Item{}, seasons, 1, "e2")
	s := v.season
	i := slices.Index(s.actions, GoToShow)
	if i < 0 || !s.acts {
		t.Fatalf("an episode opened directly offers %q", s.actions)
	}
	s.act = i
	v.Key(input.Event{Key: input.Enter}, time.Now())
	if v.episodes || v.picker.col[0] != 1 {
		t.Fatalf("Go to show: episodes %v, picker on %d", v.episodes, v.picker.col[0])
	}
	if slices.Contains(s.actions, GoToShow) || s.acts {
		t.Fatalf("back on the season the actions are %q, on them %v", s.actions, s.acts)
	}
	if v.Back() {
		t.Fatal("Back from the picker must leave the show")
	}
	v.Key(input.Event{Key: input.Down}, time.Now())
	if !v.episodes || s.focused().RatingKey != "e2" || slices.Contains(s.actions, GoToShow) {
		t.Fatalf("returning: episodes %v, actions %q", v.episodes, s.actions)
	}
	if !v.Back() || v.episodes {
		t.Fatal("the season entered from the picker must Back to it")
	}

	// a single season opens without the picker; Go to show is its picker
	one := []*plex.Item{seasons[1]}
	v = NewShowInSeason(a, &plex.Item{}, one, 0, "")
	s = v.season
	s.acts, s.act = true, slices.Index(s.actions, GoToShow)
	v.Key(input.Event{Key: input.Enter}, time.Now())
	if v.episodes || v.picker.Focused() != one[0] || len(v.picker.hubs[0].Items) != 2 {
		t.Fatal("a single season's Go to show did not land on its picker")
	}
}
