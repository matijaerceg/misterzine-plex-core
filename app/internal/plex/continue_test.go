package plex

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestContinueWatchingListAndRemoval(t *testing.T) {
	var removed []string
	missing := false
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/hubs/continueWatching/items" && !missing:
			io.WriteString(w, `<MediaContainer size="3"><Video ratingKey="11" type="movie" title="A"/>`+
				`<Video ratingKey="22" type="episode" title="B"/><Video type="clip" title="no key"/></MediaContainer>`)
		case r.URL.Path == "/actions/removeFromContinueWatching" && r.Method == "PUT":
			removed = append(removed, r.URL.Query().Get("ratingKey"))
			io.WriteString(w, `<MediaContainer size="0"></MediaContainer>`)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	c := New(server.URL, "tok", t.TempDir(), "")

	keys, err := c.ContinueWatching()
	if err != nil {
		t.Fatal(err)
	}
	if len(keys) != 2 || !keys["11"] || !keys["22"] {
		t.Fatalf("keys %v", keys)
	}
	if err := c.RemoveFromContinueWatching("11"); err != nil {
		t.Fatal(err)
	}
	if len(removed) != 1 || removed[0] != "11" {
		t.Fatalf("removal sent %v", removed)
	}

	// a server without the list: an error, which hides the action
	missing = true
	if _, err := c.ContinueWatching(); err == nil {
		t.Fatal("a missing list was not an error")
	}
}

// A music playlist a month long is a millisecond duration past 2^31, which
// a 32-bit int (the DE10's) cannot hold. It must not cost the whole row.
// Run with GOARCH=386 to see the 32-bit case on a 64-bit machine.
func TestHubsTakeMillisecondsPast32Bits(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/hubs" {
			http.NotFound(w, r) // an older server: the two hubs make the row
			return
		}
		io.WriteString(w, `<MediaContainer size="2">`+
			`<Hub hubIdentifier="home.continue" title="Continue Watching">`+
			`<Video ratingKey="11" type="movie" title="A" duration="2601097000" viewOffset="2500000000"/></Hub>`+
			`<Hub hubIdentifier="home.playlists" title="Playlists">`+
			`<Playlist ratingKey="33" type="playlist" title="All music" duration="2601097000"/></Hub>`+
			`</MediaContainer>`)
	}))
	defer server.Close()
	hubs, err := New(server.URL, "tok", t.TempDir(), "").Hubs(30)
	if err != nil {
		t.Fatal(err)
	}
	if len(hubs) != 1 || len(hubs[0].Items) != 1 {
		t.Fatalf("hubs %v", hubs)
	}
	if it := hubs[0].Items[0]; it.Duration != 2601097 || it.ViewOffset != 2500000 {
		t.Fatalf("duration %d, offset %d", it.Duration, it.ViewOffset)
	}
}

func TestHubIsContinueWatching(t *testing.T) {
	for ident, want := range map[string]bool{
		"home.continue": true, "home.ondeck": true, "home.ondeck.1": true,
		"home.movies.recent": false, "movie.recentlyadded": false, "": false,
	} {
		if got := (&Hub{Ident: ident}).IsContinueWatching(); got != want {
			t.Errorf("%q: %v", ident, got)
		}
	}
}

// A busy server fills home.continue to the cap; a show whose last episode
// was just finished sits only in home.ondeck, past the row's end. The
// server's Continue Watching list orders both by recency, and the row
// takes that order exactly, keeping the hub's identity.
func TestHubsTakeTheServersContinueWatchingOrder(t *testing.T) {
	missing := false
	var cwQuery string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/hubs":
			io.WriteString(w, `<MediaContainer size="3">`+
				`<Hub hubIdentifier="home.continue" key="/hubs/home/continueWatching" title="Continue Watching" more="1">`+
				`<Video ratingKey="1" type="movie" title="In progress 1"/><Video ratingKey="2" type="episode" title="In progress 2"/></Hub>`+
				`<Hub hubIdentifier="home.ondeck" key="/hubs/home/onDeck" title="On Deck">`+
				`<Video ratingKey="2" type="episode" title="In progress 2"/><Video ratingKey="9" type="episode" title="Next episode"/></Hub>`+
				`<Hub hubIdentifier="home.movies.recent" key="/hubs/home/recentlyAdded" title="Recently Added">`+
				`<Video ratingKey="5" type="movie" title="New"/></Hub>`+
				`</MediaContainer>`)
		case r.URL.Path == "/hubs/continueWatching/items" && !missing:
			cwQuery = r.URL.RawQuery
			io.WriteString(w, `<MediaContainer size="4">`+
				`<Video ratingKey="9" type="episode" title="Next episode"><Media id="90"/></Video>`+
				`<Video ratingKey="2" type="episode" title="In progress 2"/>`+
				`<Video ratingKey="1" type="movie" title="In progress 1"/>`+
				`<Video ratingKey="7" type="movie" title="Past the cap"/>`+
				`</MediaContainer>`)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	c := New(server.URL, "tok", t.TempDir(), "")

	hubs, err := c.Hubs(3)
	if err != nil {
		t.Fatal(err)
	}
	if len(hubs) != 1 {
		t.Fatalf("hubs %v", hubs)
	}
	h := hubs[0]
	if h.Ident != "home.continue" || h.Title != "Continue Watching" || h.Key != "/hubs/home/continueWatching" || !h.IsContinueWatching() {
		t.Fatalf("hub %+v", h)
	}
	var got []string
	for _, it := range h.Items {
		got = append(got, it.RatingKey)
	}
	if strings.Join(got, ",") != "9,2,1" {
		t.Fatalf("order %v, want the server's, capped at 3", got)
	}
	if strings.Contains(cwQuery, "Media") {
		t.Fatalf("the row needs Media: %s", cwQuery)
	}

	// an older server without the list: the two hubs merged
	missing = true
	hubs, err = c.Hubs(30)
	if err != nil {
		t.Fatal(err)
	}
	got = nil
	for _, it := range hubs[0].Items {
		got = append(got, it.RatingKey)
	}
	if len(hubs) != 1 || strings.Join(got, ",") != "1,2,9" {
		t.Fatalf("fallback order %v", got)
	}
}
