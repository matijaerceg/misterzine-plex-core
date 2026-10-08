package ui

import (
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/plex"
)

// returnSeason is a season page of n episodes (rating keys e0, e1, ...)
// with the cursor on episode cur, as a playback leaves it.
func returnSeason(a *App, n, cur int) *Season {
	if a.F.Body == nil {
		a.F = Fonts{Body: gfx.Load("med18"), SmallBold: gfx.Load("med16")}
	}
	sea := &plex.Item{RatingKey: "season", Key: "/children", Title: "Season 1"}
	s := &Season{app: a, show: &plex.Item{RatingKey: "show", Title: "Show"}, seasons: []*plex.Item{sea}}
	for i := 0; i < n; i++ {
		// a track each: rebuild then asks the server for nothing
		s.eps = append(s.eps, &plex.Item{RatingKey: fmt.Sprint("e", i), Index: i + 1, Audio: []plex.Stream{{}}})
	}
	s.cur = cur
	s.colX.Set(float64(s.scrollTarget()))
	s.rebuild()
	return s
}

// stillInView reports whether episode i's still is whole on screen.
func stillInView(s *Season, i int) bool {
	x := SafeX + i*StillPitch - round(s.colX.Target())
	return x >= SafeX && x+StillW <= SafeX+SafeW
}

func TestPlaybackFinishedInItsLastThirtySeconds(t *testing.T) {
	for _, tc := range []struct {
		name     string
		pos, dur float64
		next     int
		want     bool
	}{
		{"ran to its end", 1799, 1800, 0, true},
		{"stopped in the closing credits", 1771, 1800, 0, true},
		{"stopped before the last 30 seconds", 1769, 1800, 0, false},
		{"stopped half way", 900, 1800, 0, false},
		{"Next in the closing credits", 1790, 1800, 1, false},
		{"no duration", 10, 0, 0, false},
	} {
		p := &Playing{pos: tc.pos, dur: tc.dur, Next: tc.next}
		if got := p.finished(); got != tc.want {
			t.Errorf("%s: finished %v, want %v", tc.name, got, tc.want)
		}
	}
}

func TestAfterPlayPicksTheEpisodeToGoOnWith(t *testing.T) {
	eps := []*plex.Item{{RatingKey: "a"}, {RatingKey: "b"}, {RatingKey: "c"}, {RatingKey: "d"}}
	for _, tc := range []struct {
		name  string
		key   string
		ended bool
		want  int
	}{
		{"finished", "b", true, 2},
		{"stopped early", "b", false, 1},
		{"stopped on the first", "a", false, 0},
		{"the season's last finished", "d", true, 3},
		{"the season's last stopped early", "d", false, 3},
		{"not on the page", "x", true, -1},
	} {
		if got := afterPlay(eps, tc.key, tc.ended); got != tc.want {
			t.Errorf("%s: afterPlay(%q, %v) = %d, want %d", tc.name, tc.key, tc.ended, got, tc.want)
		}
	}
	// a reloaded list holds new items with the same rating keys
	reloaded := []*plex.Item{{RatingKey: "a"}, {RatingKey: "b"}, {RatingKey: "c"}, {RatingKey: "d"}}
	if got := afterPlay(reloaded, "c", true); got != 3 {
		t.Errorf("reloaded list: afterPlay(c, ended) = %d, want 3", got)
	}
	if got := afterPlay(nil, "a", true); got != -1 {
		t.Errorf("empty list: afterPlay = %d, want -1", got)
	}
}

func TestSeasonReturnMovesToTheNextEpisodeInView(t *testing.T) {
	// the third still across, the right edge: the one after it is off screen
	s := returnSeason(&App{}, 8, 2)
	s.acts, s.act = true, 1 // From start
	s.returned("e2", true)
	if s.cur != 3 {
		t.Fatalf("the episode after the finished one is not selected: cur %d, want 3", s.cur)
	}
	if !stillInView(s, 3) {
		t.Fatalf("the filmstrip did not scroll the selection into view (offset %v)", s.colX.Target())
	}
	if s.colX.Running(time.Now()) || round(s.colX.At(time.Now())) != round(s.colX.Target()) {
		t.Fatal("the filmstrip is not already in place when the page comes back")
	}
	if !s.acts || s.act != 0 || s.actX.Target() != 0 {
		t.Fatalf("the cursor should stay on the actions, on the new episode's first: acts %v, act %d", s.acts, s.act)
	}
	s.rebuild()
	if s.actions[0] != "Play" {
		t.Fatalf("the next episode's first action is %q, want Play", s.actions[0])
	}
}

func TestSeasonReturnAfterTheQueueMoved(t *testing.T) {
	// started on the second, autoplay or Next took it to the sixth
	s := returnSeason(&App{}, 8, 1)
	s.returned("e5", false) // stopped early: that one stays selected
	if s.cur != 5 || !stillInView(s, 5) {
		t.Fatalf("stopped on e5: cur %d, in view %v", s.cur, stillInView(s, 5))
	}
	s = returnSeason(&App{}, 8, 1)
	s.returned("e5", true) // finished: the one after it
	if s.cur != 6 || !stillInView(s, 6) {
		t.Fatalf("finished e5: cur %d, in view %v", s.cur, stillInView(s, 6))
	}
	// Prev back to the first and finished there
	s = returnSeason(&App{}, 8, 6)
	s.returned("e0", true)
	if s.cur != 1 || !stillInView(s, 1) {
		t.Fatalf("finished e0 after Prev: cur %d, in view %v", s.cur, stillInView(s, 1))
	}
}

func TestSeasonReturnKeepsTheLastEpisodeAndAnEarlyStop(t *testing.T) {
	s := returnSeason(&App{}, 5, 4)
	s.acts, s.act = true, 1
	before := s.colX.Target()
	s.returned("e4", true) // the season's last finished
	if s.cur != 4 || s.act != 1 || s.colX.Target() != before {
		t.Fatalf("the season's last finished: cur %d, act %d, offset %v; want it kept as it was", s.cur, s.act, s.colX.Target())
	}
	s = returnSeason(&App{}, 5, 2)
	s.returned("e2", false) // stopped early, where it started
	if s.cur != 2 {
		t.Fatalf("stopped early: cur %d, want 2", s.cur)
	}
	s.returned("gone", true) // not on the page any more: nothing moves
	if s.cur != 2 {
		t.Fatalf("an unknown episode moved the cursor to %d", s.cur)
	}
}

func TestSeasonReturnSurvivesTheWatchRefresh(t *testing.T) {
	// the listing as the server has it once the playback marked e1 watched
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `<MediaContainer><Video ratingKey="e0" type="episode" viewCount="1"/><Video ratingKey="e1" type="episode" viewCount="1"/><Video ratingKey="e2" type="episode"/><Video ratingKey="e3" type="episode"/></MediaContainer>`)
	}))
	defer server.Close()
	a := &App{Plex: plex.New(server.URL, "", t.TempDir(), "test"), later: make(chan func(), 32), Log: log.New(io.Discard, "", 0)}
	s := returnSeason(a, 4, 1)
	s.eps[0].ViewCount = 1
	s.returned("e1", true)
	s.periodic.next = time.Now().Add(-time.Second) // due: the playback took longer than the interval
	deadline := time.Now().Add(2 * time.Second)
	for s.eps[1].ViewCount == 0 {
		if time.Now().After(deadline) {
			t.Fatal("the watch state never refreshed")
		}
		s.pollRefresh(time.Now())
		time.Sleep(5 * time.Millisecond)
	}
	if s.cur != 2 || s.focused().RatingKey != "e2" {
		t.Fatalf("the refresh moved the selection to %d", s.cur)
	}
}
