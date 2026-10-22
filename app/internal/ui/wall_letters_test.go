package ui

import (
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/plex"
)

// Two loads in a row: the first load's letters, arriving after the
// second's, are dropped, and the letters land on the UI goroutine.
func TestWallKeepsOnlyTheNewerLoadsLetters(t *testing.T) {
	var mu sync.Mutex
	first := true
	letter := "N"                  // the letter the server has films under
	held := make(chan struct{})    // the first load is asking
	release := make(chan struct{}) // let the first load have its answer
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/firstCharacter") {
			plexPage(w, r) // the listing itself: empty
			return
		}
		mu.Lock()
		hold := first
		first = false
		mu.Unlock()
		if hold {
			close(held)
			<-release
		}
		mu.Lock()
		fmt.Fprintf(w, `<MediaContainer size="1"><Directory key="%s" size="3"/></MediaContainer>`, letter)
		mu.Unlock()
	}))
	defer srv.Close()
	defer func() {
		select {
		case <-release:
		default:
			close(release)
		}
	}()

	a := &App{Plex: testClient(srv.URL, "tok", t.TempDir()), Wake: make(chan struct{}, 1), later: make(chan func(), 32),
		pagers: map[string]*Pager{}, Cfg: &Config{NoTheme: true}, Log: log.New(io.Discard, "", 0), Art: NewArt(nil, 0, nil)}
	a.F = appFonts()
	a.T = gfx.NewTextCache(1, nil)
	a.stack = []Screen{&splashTestScreen{}}

	w := NewWallView(a, plex.Section{Key: "1", Type: "movie", Title: "Films"}, 0) // A to Z: the first load
	select {
	case <-held:
	case <-time.After(5 * time.Second):
		t.Fatal("the first load never asked for its letters")
	}
	w.load() // the second load, while the first is still asking
	waitUntil(t, "the second load's letters", func() bool {
		a.runLater()
		return len(w.letters) > 0
	})
	want := []plex.Letter{{Key: "N", Size: 3}}
	if !reflect.DeepEqual(w.letters, want) {
		t.Fatalf("letters after the second load = %v, want %v", w.letters, want)
	}

	mu.Lock()
	letter = "O" // what the first load is told, now late
	mu.Unlock()
	close(release)
	waitUntil(t, "the first load's late letters", func() bool { return len(a.later) > 0 })
	a.runLater()
	if !reflect.DeepEqual(w.letters, want) {
		t.Fatalf("the first load's late letters replaced the second's: %v, want %v", w.letters, want)
	}
}
