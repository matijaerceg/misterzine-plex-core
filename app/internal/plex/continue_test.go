package plex

import (
	"io"
	"net/http"
	"net/http/httptest"
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
