package ui

import (
	"plexcrt/internal/plex"
	"testing"
)

func TestScrollbarUsesSortTitle(t *testing.T) {
	items := []*plex.Item{{Title: "The 'Burbs", SortTitle: "'Burbs"}, {Title: "The Matrix", SortTitle: "Matrix"}, {Title: "Zulu"}}
	p := &Pager{filter: func(*plex.Item) bool { return true }, list: items, done: true}
	w := &Wall{pager: p}
	for i, want := range []string{"'", "M", "Z"} {
		w.cur = i
		if got := w.marker(3); got != want {
			t.Fatalf("marker %d: got %q want %q", i, got, want)
		}
	}
	letters := p.Letters()
	for i, want := range []string{"#", "M", "Z"} {
		if letters[i].Key != want {
			t.Fatalf("index %d: %q", i, letters[i].Key)
		}
	}
}

// A run of letter jumps lands on items the pager has not loaded yet; the
// scrollbar's letter then comes from the index, so each jump shows where
// it went without waiting for the page.
func TestScrollbarLetterAheadOfTheLoad(t *testing.T) {
	// nothing has landed; every page is still on its way
	p := &Pager{items: map[int]*plex.Item{}, total: 30, loaded: true, inFlt: map[int]bool{0: true, 1: true, 2: true, 3: true}}
	w := &Wall{pager: p, letters: []plex.Letter{{Key: "A", Size: 10}, {Key: "B", Size: 5}, {Key: "C", Size: 15}}}
	for cur, want := range map[int]string{0: "A", 9: "A", 10: "B", 14: "B", 15: "C", 29: "C", 30: ""} {
		w.cur = cur
		if got := w.marker(30); got != want {
			t.Fatalf("marker at %d: got %q want %q", cur, got, want)
		}
	}
}
