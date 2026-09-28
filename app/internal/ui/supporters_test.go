package ui

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
)

func TestMain(m *testing.M) {
	SupportersURL = "" // no test reaches the site; the ones that fetch serve their own
	os.Exit(m.Run())
}

const supportersFixture = `{"updated":"2026-09-28",
 "current":[{"name":"Alex Example","since":"2026-09"},{"name":"  "},{"name":"Zoë  Émile"}],
 "past":[{"name":"Sam Sample","since":"2026-08","until":"2026-09"}],
 "early_adopters":["Pat Tester"]}`

func TestDecodeSupporters(t *testing.T) {
	s, err := DecodeSupporters([]byte(supportersFixture))
	if err != nil {
		t.Fatal(err)
	}
	if len(s.Current) != 2 || s.Current[0].Name != "Alex Example" || s.Current[1].Name != "Zoe Emile" {
		t.Fatalf("current: %+v", s.Current)
	}
	if len(s.Past) != 1 || s.Past[0].Name != "Sam Sample" {
		t.Fatalf("past: %+v", s.Past)
	}
	if _, err := DecodeSupporters([]byte("<html>not found</html>")); err == nil {
		t.Fatal("a page that is not the list was taken for one")
	}
}

// drainLater runs what the background work handed back, until want calls
// have come or it gives up.
func drainLater(t *testing.T, a *App, want int) {
	t.Helper()
	for i := 0; i < want; i++ {
		select {
		case f := <-a.later:
			f()
		case <-time.After(5 * time.Second):
			t.Fatalf("%d of %d results came back", i, want)
		}
	}
}

func TestSupportersFetchedCachedAndKeptOffline(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(supportersFixture))
	}))
	t.Cleanup(func() { SupportersURL = "" })
	SupportersURL = srv.URL + "/supporters.json"
	cache := t.TempDir()
	a := &App{later: make(chan func(), 8)}
	a.SetCacheDir(cache)
	now := time.Now()
	a.checkSupporters(now)
	drainLater(t, a, 1) // no cache yet: the fetch only
	if n := len(a.supporters.list.Current); n != 2 || a.supporters.checking {
		t.Fatalf("%d current supporters after the fetch", n)
	}
	if _, err := os.Stat(filepath.Join(cache, "supporters.json")); err != nil {
		t.Fatalf("the list was not cached: %v", err)
	}
	a.checkSupporters(now.Add(time.Hour))
	if a.supporters.checking {
		t.Fatal("checked again within six hours")
	}

	srv.Close() // offline: the next run shows the cached list
	b := &App{later: make(chan func(), 8)}
	b.SetCacheDir(cache)
	b.checkSupporters(now)
	drainLater(t, b, 2) // the cache, then the failed fetch
	if n := len(b.supporters.list.Current); n != 2 {
		t.Fatalf("%d current supporters offline", n)
	}
	if !b.supporters.nextCheck.Before(time.Now().Add(10 * time.Minute)) {
		t.Fatal("a failed fetch waits hours before the next one")
	}
}

func TestSupportersRowOpensTheList(t *testing.T) {
	a := betaTestApp(t)
	p := NewPatreon(a)
	a.Push(p)
	if rows := p.rows(); len(rows) != 1 {
		t.Fatalf("rows before the list has come: %+v", rows)
	}
	s, _ := DecodeSupporters([]byte(supportersFixture))
	a.supporters.list = s
	rows := p.rows()
	if len(rows) != 2 || rows[1].label != "Our 2 supporters" {
		t.Fatalf("rows with the list: %+v", rows)
	}
	p.Key(input.Event{Key: input.Down}, time.Now())
	p.Key(input.Event{Key: input.Enter}, time.Now())
	if _, ok := a.top().(*SupportersPage); !ok {
		t.Fatalf("the supporters row opened %T", a.top())
	}
	lines := a.creditLines()
	want := []string{"Patreon supporters", "Alex Example|Zoe Emile", "", "Past supporters", "Sam Sample"}
	if len(lines) != len(want) {
		t.Fatalf("%d lines, want %d: %+v", len(lines), len(want), lines)
	}
	for i, l := range lines {
		got := l.heading
		for j, n := range l.names {
			if j > 0 {
				got += "|"
			}
			got += n
		}
		if got != want[i] {
			t.Fatalf("line %d is %q, want %q", i, got, want[i])
		}
	}
}

func TestSupportersPageScrollsWithinTheList(t *testing.T) {
	a := betaTestApp(t)
	for i := 0; i < 40; i++ {
		a.supporters.list.Current = append(a.supporters.list.Current, Supporter{Name: "Supporter " + itoa(i)})
	}
	s := NewSupportersPage(a)
	end := len(a.creditLines()) - creditsRows // 21 lines: a heading and 20 of names
	for range 30 {
		s.Key(input.Event{Key: input.Down}, time.Now())
	}
	if s.top != end {
		t.Fatalf("scrolled to %d, the end is %d", s.top, end)
	}
	s.Key(input.Event{Key: input.Left}, time.Now())
	if s.top != max(0, end-(creditsRows-1)) {
		t.Fatalf("a page up went to %d", s.top)
	}
	a.supporters.list.Current = a.supporters.list.Current[:3] // the list shrank while open
	s.Draw(gfx.NewCanvas(720, 480), time.Now())
	if s.top != 0 {
		t.Fatalf("top %d past a short list", s.top)
	}
}
