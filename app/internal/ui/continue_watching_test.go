package ui

import (
	"fmt"
	"io"
	"log"
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

// continueServer is a Plex server with a Continue Watching list and the
// removal action; a removal takes the item off the list, as Plex does.
type continueServer struct {
	*httptest.Server
	mu       sync.Mutex
	keys     map[string]bool
	removed  []string
	fail     bool // the removal is refused
	failList bool // the list is refused
}

func newContinueServer(t *testing.T, keys ...string) *continueServer {
	s := &continueServer{keys: map[string]bool{}}
	for _, k := range keys {
		s.keys[k] = true
	}
	s.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		defer s.mu.Unlock()
		switch {
		case r.URL.Path == "/hubs/continueWatching/items":
			if s.failList {
				http.Error(w, "busy", 503)
				return
			}
			io.WriteString(w, "<MediaContainer>")
			for k := range s.keys {
				fmt.Fprintf(w, `<Video ratingKey=%q type="movie"/>`, k)
			}
			io.WriteString(w, "</MediaContainer>")
		case r.URL.Path == "/actions/removeFromContinueWatching" && r.Method == "PUT":
			if s.fail {
				http.Error(w, "refused", 500)
				return
			}
			k := r.URL.Query().Get("ratingKey")
			s.removed = append(s.removed, k)
			delete(s.keys, k)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(s.Close)
	return s
}

func (s *continueServer) set(f func()) {
	s.mu.Lock()
	defer s.mu.Unlock()
	f()
}

func (s *continueServer) removals() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return slices.Clone(s.removed)
}

func continueTestApp(t *testing.T, s *continueServer) *App {
	a := &App{Plex: plex.New(s.URL, "tok", t.TempDir(), ""), Log: log.New(io.Discard, "", 0), Wake: make(chan struct{}, 1)}
	a.F = Fonts{Title: gfx.Load("med22"), Body: gfx.Load("med18"), Small: gfx.Load("reg16"), SmallBold: gfx.Load("med16"), Big: gfx.Load("bold28")}
	return a
}

// settle waits for the list's answer to land (not for any wake-up: the
// page's other refresh wakes the app too).
func settle(t *testing.T, l *continueList) {
	t.Helper()
	for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); time.Sleep(5 * time.Millisecond) {
		if l.pending == nil || len(l.pending) > 0 {
			return
		}
	}
	t.Fatal("the Continue Watching answer did not land")
}

func continueHome(a *App, cw ...*plex.Item) *Home {
	h := &Home{app: a, home: true}
	h.applyHome([]*plex.Hub{
		{Title: "Continue Watching", Ident: "home.continue", Items: cw},
		{Title: "Films", Ident: "movie.recentlyadded", Key: "/hubs/sections/1", Items: []*plex.Item{{RatingKey: "r1", Type: "movie"}}},
	})
	h.refreshAt = time.Now().Add(time.Hour)
	return h
}

func TestPreplayRemovesFromContinueWatching(t *testing.T) {
	srv := newContinueServer(t, "m1", "m2")
	a := continueTestApp(t, srv)
	m1 := &plex.Item{RatingKey: "m1", Type: "movie", Title: "One", Summary: "s", PartID: "p", ViewOffset: 600}
	m2 := &plex.Item{RatingKey: "m2", Type: "movie", Title: "Two", Summary: "s", PartID: "p", ViewOffset: 60}
	h := continueHome(a, m1, m2)
	p := NewPreplay(a, m1)
	a.stack = []Screen{h, p}
	if slices.Contains(p.actions, RemoveContinue) {
		t.Fatal("the action showed before the list answered")
	}
	settle(t, &p.cw)
	p.pollRefresh(time.Now())
	if p.actions[len(p.actions)-1] != RemoveContinue {
		t.Fatalf("the action is not last: %q", p.actions)
	}

	p.cur = len(p.actions) - 1
	p.Key(input.Event{Key: input.Enter}, time.Now())
	if got := srv.removals(); !slices.Equal(got, []string{"m1"}) {
		t.Fatalf("removal sent for %v", got)
	}
	if slices.Contains(p.actions, RemoveContinue) || p.cur != 0 || !strings.HasPrefix(p.actions[0], "Resume") {
		t.Fatalf("after removal: actions %q, cursor %d", p.actions, p.cur)
	}
	if p.item.ViewOffset != 600 {
		t.Fatal("the removal touched the resume point")
	}
	// Home drops it at once and fetches the rows again when shown
	if items := h.hubs[0].Items; len(items) != 1 || items[0] != m2 || h.Focused() != m2 {
		t.Fatalf("home row after removal: %v, focused %v", items, h.Focused())
	}
	if !h.refreshAt.IsZero() || h.refreshResult != nil {
		t.Fatal("home was not set to fetch the rows again")
	}
}

func TestContinueRemovalRefusedKeepsTheAction(t *testing.T) {
	srv := newContinueServer(t, "m1")
	srv.set(func() { srv.fail = true })
	a := continueTestApp(t, srv)
	m1 := &plex.Item{RatingKey: "m1", Type: "movie", Summary: "s", PartID: "p", ViewOffset: 600}
	h := continueHome(a, m1)
	p := NewPreplay(a, m1)
	a.stack = []Screen{h, p}
	settle(t, &p.cw)
	p.pollRefresh(time.Now())
	p.cur = len(p.actions) - 1
	p.Key(input.Event{Key: input.Enter}, time.Now())
	if p.actions[p.cur] != RemoveContinue || a.Notice == "" {
		t.Fatalf("refused removal: actions %q, cursor %d, notice %q", p.actions, p.cur, a.Notice)
	}
	if len(h.hubs[0].Items) != 1 || h.refreshAt.IsZero() {
		t.Fatal("a refused removal changed Home")
	}
}

// An answer fetched before the removal lands after it: it must not bring
// the action back.
func TestContinueAnswerFromBeforeRemovalIsDropped(t *testing.T) {
	srv := newContinueServer(t, "m1")
	a := continueTestApp(t, srv)
	m1 := &plex.Item{RatingKey: "m1", Type: "movie", Summary: "s", PartID: "p", ViewOffset: 600}
	p := &Preplay{app: a, item: m1}
	p.cw.keys = map[string]bool{"m1": true}
	p.rebuild()
	stale := make(chan map[string]bool, 1)
	p.cw.pending = stale
	p.cur = len(p.actions) - 1
	p.Key(input.Event{Key: input.Enter}, time.Now())
	stale <- map[string]bool{"m1": true}
	p.pollRefresh(time.Now())
	if slices.Contains(p.actions, RemoveContinue) {
		t.Fatal("an answer from before the removal brought the action back")
	}
}

func TestSeasonRemovesEpisodeFromContinueWatching(t *testing.T) {
	srv := newContinueServer(t, "e2")
	a := continueTestApp(t, srv)
	e1 := &plex.Item{RatingKey: "e1", Type: "episode", Title: "Ep 1", ViewCount: 1}
	e2 := &plex.Item{RatingKey: "e2", Type: "episode", Title: "Ep 2", ViewOffset: 300}
	s := &Season{app: a, show: &plex.Item{RatingKey: "sh"}, seasons: []*plex.Item{{RatingKey: "se", Key: "/library/metadata/se/children"}},
		eps: []*plex.Item{e1, e2}, cur: 1, acts: true, fetched: map[string]bool{"e1": true, "e2": true}}
	s.rebuild()
	s.cw.refetch(a)
	settle(t, &s.cw)
	s.act = 2 // Mark watched
	s.pollRefresh(time.Now())
	if s.actions[len(s.actions)-1] != RemoveContinue || s.actions[s.act] != "Mark watched" {
		t.Fatalf("after the answer: actions %q, cursor on %q", s.actions, s.actions[s.act])
	}
	if len(s.actW) != len(s.actions) {
		t.Fatal("the action widths were not measured")
	}
	s.cur = 0 // an episode that is not in Continue Watching
	s.rebuild()
	if slices.Contains(s.actions, RemoveContinue) {
		t.Fatal("the action showed for an episode not in Continue Watching")
	}

	s.cur = 1
	s.rebuild()
	s.act = len(s.actions) - 1
	s.do(s.actions[s.act])
	if got := srv.removals(); !slices.Equal(got, []string{"e2"}) {
		t.Fatalf("removal sent for %v", got)
	}
	if slices.Contains(s.actions, RemoveContinue) || s.act != 0 || !strings.HasPrefix(s.actions[0], "Resume") {
		t.Fatalf("after removal: actions %q, cursor %d", s.actions, s.act)
	}
}

// The action row scrolled to its last action shows no chevron past it; at
// its start a row that runs past the safe width still does.
func TestSeasonActionRowEndHasNoChevron(t *testing.T) {
	a := continueTestApp(t, newContinueServer(t))
	ep := &plex.Item{RatingKey: "e1", Type: "episode", ViewOffset: 300, PartID: "p",
		Subs: []plex.Stream{{ID: "1", Title: "English (SRT)", Selected: true}}}
	s := &Season{app: a, show: &plex.Item{}, seasons: []*plex.Item{{}}, eps: []*plex.Item{ep}, acts: true,
		fetched: map[string]bool{"e1": true}}
	s.cw.keys = map[string]bool{"e1": true}
	s.rebuild()
	if s.actRowW() <= SafeW {
		t.Fatalf("the fixture row (%d px) does not need scrolling", s.actRowW())
	}
	now := time.Now()
	s.act = len(s.actions) - 1
	s.keepActVisible(now)
	if off := round(s.actX.Target()); s.actRowW()-off > SafeW {
		t.Fatalf("scrolled to the end, the row still reaches %d px past its start (safe width %d)", s.actRowW()-off, SafeW)
	}
}

// Scrolled to the trailing action, Up to the filmstrip and Down again: the
// first action is selected and the row is back at its start, so OK never
// acts on a label off the screen.
func TestSeasonActionRowReturnsToStart(t *testing.T) {
	a := continueTestApp(t, newContinueServer(t))
	ep := &plex.Item{RatingKey: "e1", Type: "episode", ViewOffset: 300, PartID: "p",
		Subs: []plex.Stream{{ID: "1", Title: "English (SRT)", Selected: true}}}
	s := &Season{app: a, show: &plex.Item{}, seasons: []*plex.Item{{}}, eps: []*plex.Item{ep}, acts: true,
		fetched: map[string]bool{"e1": true}}
	s.cw.keys = map[string]bool{"e1": true}
	s.rebuild()
	now := time.Now()
	for range s.actions {
		s.Key(input.Event{Key: input.Right}, now)
	}
	if s.act != len(s.actions)-1 || round(s.actX.Target()) == 0 {
		t.Fatalf("the row did not scroll to its last action (act %d, offset %d)", s.act, round(s.actX.Target()))
	}
	s.Key(input.Event{Key: input.Up}, now)
	if s.acts || round(s.actX.Target()) != 0 {
		t.Fatalf("on the filmstrip the row stays scrolled to %d", round(s.actX.Target()))
	}
	s.Key(input.Event{Key: input.Down}, now)
	if !s.acts || s.act != 0 || round(s.actX.Target()) != 0 {
		t.Fatalf("Down selected action %d with the row at %d", s.act, round(s.actX.Target()))
	}
}

// The row scrolled to its end with the cursor on the action before Remove;
// the list then drops the episode. The shorter row is not left scrolled past
// its end, and the cursor's action still shows.
func TestSeasonShorterRowIsNotOverScrolled(t *testing.T) {
	a := continueTestApp(t, newContinueServer(t))
	ep := &plex.Item{RatingKey: "e1", Type: "episode", ViewOffset: 300, PartID: "p",
		Subs: []plex.Stream{{ID: "1", Title: "English (SRT)", Selected: true}}}
	s := &Season{app: a, show: &plex.Item{}, seasons: []*plex.Item{{}}, eps: []*plex.Item{ep}, acts: true,
		fetched: map[string]bool{"e1": true}}
	s.cw.keys = map[string]bool{"e1": true}
	s.rebuild()
	now := time.Now()
	s.act = len(s.actions) - 1
	s.keepActVisible(now)
	s.act-- // Subtitles
	s.keepActVisible(now)
	before := round(s.actX.Target())

	s.cw.pending = make(chan map[string]bool, 1)
	s.cw.pending <- map[string]bool{} // the list no longer holds it
	s.pollRefresh(now)
	if slices.Contains(s.actions, RemoveContinue) || !strings.HasPrefix(s.actions[s.act], "Subtitles") {
		t.Fatalf("after the list changed: %q, cursor %d", s.actions, s.act)
	}
	off, limit := round(s.actX.Target()), max(0, s.actRowW()-SafeW)
	if off > limit || off >= before {
		t.Fatalf("the shorter row stays scrolled to %d (was %d, its end is at %d)", off, before, limit)
	}
	if l, r := s.actLeft(s.act)-off, s.actLeft(s.act)+s.actW[s.act]-off; l < 0 || r > SafeW {
		t.Fatalf("the cursor's action is off the row (%d..%d)", l, r)
	}
}

// The chevron's 24 px are kept only while more lies to the right: a row
// that fits never scrolls, even with its last action selected, and a long
// row's last action ends at the safe edge.
func TestSeasonRowScrollBounds(t *testing.T) {
	now := time.Now()
	for _, c := range []struct {
		widths []int
		want   int
	}{
		{[]int{200, 200, 120}, 0},           // 584 px
		{[]int{200, 200, 121}, 0},           // 585 px: inside the old 24 px reserve
		{[]int{200, 200, 144}, 0},           // 608 px: exactly the safe width
		{[]int{300, 300, 300}, 964 - SafeW}, // longer: the end lands on the safe edge
	} {
		s := &Season{actions: make([]string, len(c.widths)), actW: c.widths, acts: true}
		s.act = len(c.widths) - 1
		s.keepActVisible(now)
		if got := round(s.actX.Target()); got != c.want {
			t.Errorf("row %v (%d px), last action: scrolled %d, want %d", c.widths, s.actRowW(), got, c.want)
		}
	}
}

// The episode's tracks can land after the Continue Watching answer, with the
// cursor already on Remove: Audio and Subtitles go in before it, and the
// cursor stays on Remove rather than on whatever took its place.
func TestSeasonStreamsKeepRemoveSelected(t *testing.T) {
	a := continueTestApp(t, newContinueServer(t))
	ep := &plex.Item{RatingKey: "e1", Type: "episode", ViewOffset: 300}
	s := &Season{app: a, show: &plex.Item{}, seasons: []*plex.Item{{}}, eps: []*plex.Item{ep}, acts: true,
		fetched: map[string]bool{"e1": true}}
	s.cw.keys = map[string]bool{"e1": true}
	s.rebuild()
	s.act = len(s.actions) - 1
	if s.actions[s.act] != RemoveContinue {
		t.Fatalf("fixture: %q", s.actions)
	}
	s.streamsArrived(ep, &plex.Item{PartID: "p",
		Audio: []plex.Stream{{ID: "1", Title: "English", Selected: true}, {ID: "2", Title: "French"}},
		Subs:  []plex.Stream{{ID: "3", Title: "English (SRT)"}}})
	if len(s.actions) != 6 || s.actions[s.act] != RemoveContinue {
		t.Fatalf("after the tracks landed: %q, cursor on %q", s.actions, s.actions[s.act])
	}
}

// A page left open asks again every refresh interval: an item removed on
// another client loses the action, and a first fetch that failed is retried.
func TestContinueListAsksAgain(t *testing.T) {
	srv := newContinueServer(t, "m1")
	srv.set(func() { srv.failList = true })
	a := continueTestApp(t, srv)
	m1 := &plex.Item{RatingKey: "m1", Type: "movie", Summary: "s", PartID: "p", ViewOffset: 600}
	p := NewPreplay(a, m1)
	settle(t, &p.cw)
	p.pollRefresh(time.Now())
	if slices.Contains(p.actions, RemoveContinue) {
		t.Fatal("a failed fetch showed the action")
	}

	srv.set(func() { srv.failList = false })
	later := time.Now().Add(viewRefreshInterval)
	p.pollRefresh(later) // time to ask again
	settle(t, &p.cw)
	p.pollRefresh(later)
	if !slices.Contains(p.actions, RemoveContinue) {
		t.Fatal("the failed fetch was not retried")
	}

	srv.set(func() { delete(srv.keys, "m1") }) // removed on another client
	p.cur = len(p.actions) - 1
	later = later.Add(2 * viewRefreshInterval)
	p.pollRefresh(later)
	settle(t, &p.cw)
	p.pollRefresh(later)
	if slices.Contains(p.actions, RemoveContinue) || p.cur != 0 {
		t.Fatalf("the removal elsewhere was not picked up: %q, cursor %d", p.actions, p.cur)
	}
}

// The periodic refresh keeps the cursor on the action rather than moving it
// to the second Play.
func TestRefreshKeepsCursorOnRemove(t *testing.T) {
	actions := []string{"Resume 10:00", "From start", "Mark watched", RemoveContinue}
	if got := restoreAction(actions, actionKind(actions, 3)); got != 3 {
		t.Fatalf("cursor restored to %d", got)
	}
}

func TestHomeDropContinue(t *testing.T) {
	a := &App{}
	one, two := &plex.Item{RatingKey: "1"}, &plex.Item{RatingKey: "2"}

	h := continueHome(a, one, two)
	h.row, h.col[0] = 0, 1 // on the second
	h.dropContinue("1")
	if h.Focused() != two || len(h.hubs) != 2 {
		t.Fatalf("focus moved off the item left in place: %v", h.Focused())
	}

	h = continueHome(a, one)
	h.dropContinue("1")
	if len(h.hubs) != 1 || h.hubs[0].IsContinueWatching() || h.row != 0 {
		t.Fatalf("an emptied row stayed: %d rows", len(h.hubs))
	}

	h = continueHome(a, one)
	h.dropContinue("elsewhere")
	if len(h.hubs[0].Items) != 1 || !h.refreshAt.IsZero() {
		t.Fatal("an item beyond the row changed it, or no refetch was set")
	}
}

// Six actions (resumable, two tracks, in Continue Watching) still end above
// the safe area's bottom on the movie page, a little closer together; five
// keep their spacing. The longest label fits the width.
func TestPreplaySixActionsFit(t *testing.T) {
	a := continueTestApp(t, newContinueServer(t))
	f := a.F
	// the tallest layout: a logo box, the facts line and two synopsis lines
	top := SafeY + 12 + PreLogoH + 8 + f.SmallBold.Height() + 16 + PreLines*(f.SmallBold.Height()+2) + 14
	if got := actionPitch(f.Body, top, 5); got != f.Body.Height()+10 {
		t.Fatalf("five actions closed up to %d", got)
	}
	pitch := actionPitch(f.Body, top, 6)
	if bottom := top + 5*pitch + f.Body.Height(); bottom > SafeBottom {
		t.Fatalf("six actions end at %d, below the safe bottom %d", bottom, SafeBottom)
	}
	if pitch < f.Body.Height()+8 {
		t.Fatalf("six actions pressed to %d px apart", pitch)
	}
	if w := f.Body.Width(RemoveContinue); PreTextX+w > SafeX+SafeW {
		t.Fatalf("%q is %d px wide, past the safe area", RemoveContinue, w)
	}
}
