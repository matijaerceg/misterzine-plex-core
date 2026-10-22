package ui

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/plex"
)

// Holding Right along the filmstrip asks for no episode's tracks on the
// way; the episode the cursor rests on is asked for on the release, or by
// the poll once it has rested TrackRest without one.
func TestSeasonAsksForTracksOnlyWhereTheCursorRests(t *testing.T) {
	var mu sync.Mutex
	var asked []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/library/metadata/s/children":
			var eps []string
			for i := 0; i < 8; i++ {
				eps = append(eps, fmt.Sprintf(`<Video ratingKey="e%d" type="episode" title="Ep %d"/>`, i, i))
			}
			plexPage(w, r, eps...)
		case strings.HasPrefix(r.URL.Path, "/library/metadata/"):
			id := strings.TrimPrefix(r.URL.Path, "/library/metadata/")
			mu.Lock()
			asked = append(asked, id)
			mu.Unlock()
			fmt.Fprintf(w, `<MediaContainer size="1"><Video ratingKey=%q type="episode"><Media><Part id="src">`+
				`<Stream id="1" streamType="2"/><Stream id="2" streamType="2"/></Part></Media></Video></MediaContainer>`, id)
		default:
			fmt.Fprint(w, `<MediaContainer size="0"/>`)
		}
	}))
	defer server.Close()
	a := &App{Plex: testClient(server.URL, "", t.TempDir()), later: make(chan func(), 32),
		Art: NewArt(nil, 0, nil), F: Fonts{Body: gfx.Load("med18")}}
	s := &Season{app: a, seasons: []*plex.Item{{Key: "/library/metadata/s/children"}}}
	s.load("")
	drainSeason(t, a, a.seasonData)
	tracks := func(id string) {
		t.Helper()
		deadline := time.After(2 * time.Second)
		for {
			if it := s.focused(); it.RatingKey == id && len(it.Audio) > 0 &&
				slices.ContainsFunc(s.actions, func(a string) bool { return strings.HasPrefix(a, "Audio") }) {
				return
			}
			select {
			case f := <-a.later:
				f()
			case <-deadline:
				t.Fatalf("no Audio action for %s", id)
			}
		}
	}
	tracks("e0") // the listing lands with the cursor resting on the first

	now := time.Now()
	s.Key(input.Event{Key: input.Right}, now)
	for i := 1; i <= 4; i++ {
		now = now.Add(140 * time.Millisecond)
		s.Key(input.Event{Key: input.Right, Repeat: true, Count: i}, now)
		s.pollRefresh(now)
	}
	if len(s.fetched) != 1 {
		t.Fatalf("asked for tracks while moving: %v", s.fetched)
	}
	s.Key(input.Event{Key: input.Right, Release: true, Count: 4}, now)
	tracks("e5")

	// no release: the poll asks once the cursor has rested
	now = time.Now()
	s.Key(input.Event{Key: input.Right}, now)
	s.pollRefresh(now.Add(TrackRest / 2))
	if s.fetched["e6"] {
		t.Fatal("asked before the cursor rested")
	}
	s.pollRefresh(now.Add(TrackRest))
	tracks("e6")

	mu.Lock()
	defer mu.Unlock()
	if !slices.Equal(asked, []string{"e0", "e5", "e6"}) {
		t.Fatalf("asked for %v, want e0 e5 e6", asked)
	}
}
