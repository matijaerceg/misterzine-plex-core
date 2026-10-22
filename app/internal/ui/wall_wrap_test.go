package ui

import (
	"testing"
	"time"

	"plexcrt/internal/input"
	"plexcrt/internal/plex"
)

// wrapWall is a bare 4-wide wall of n loaded items with no tabs state.
func wrapWall(n int) *Wall {
	p := &Pager{items: map[int]*plex.Item{}, total: n, loaded: true, inFlt: map[int]bool{0: true, 1: true}}
	for i := 0; i < n; i++ {
		p.items[i] = &plex.Item{RatingKey: itoa(i), Thumb: "poster-" + itoa(i)}
	}
	a := &App{Art: NewArt(nil, 0, nil)}
	return &Wall{app: a, pager: p}
}

// A tap past the last row rounds to the first row's same column, Up on
// the tabs rounds to the last row, and a held run stops at the ends.
func TestWallRoundsAtTheEnds(t *testing.T) {
	w := wrapWall(10) // rows: 0-3, 4-7, 8-9
	now := time.Now()
	w.cur = 9
	w.Key(input.Event{Key: input.Down}, now)
	if w.cur != 1 || w.tabs {
		t.Fatalf("Down past the last row: cur %d tabs %v", w.cur, w.tabs)
	}
	w.cur = 1
	w.Key(input.Event{Key: input.Up}, now)
	if !w.tabs {
		t.Fatal("Up from the first row did not select the tabs")
	}
	w.Key(input.Event{Key: input.Up}, now)
	if w.tabs || w.cur != 9 {
		t.Fatalf("Up on the tabs: cur %d tabs %v (want the last row, column 1 clamped to 9)", w.cur, w.tabs)
	}
	w.cur = 3
	w.Key(input.Event{Key: input.Up}, now)
	w.Key(input.Event{Key: input.Up}, now)
	if w.cur != 9 {
		t.Fatalf("Up on the tabs from column 3: cur %d", w.cur)
	}
	// a held run stops
	w.cur = 9
	w.Key(input.Event{Key: input.Down, Repeat: true}, now)
	if w.cur != 9 {
		t.Fatalf("a held Down ran past the end to %d", w.cur)
	}
	w.cur = 1
	w.Key(input.Event{Key: input.Up}, now) // to the tabs
	w.Key(input.Event{Key: input.Up, Repeat: true}, now)
	if !w.tabs {
		t.Fatal("a held Up on the tabs rounded to the end")
	}
	// a collection has no tabs: Up from the first row rounds
	c := wrapWall(10)
	c.coll = &plex.Item{RatingKey: "c"}
	c.cur = 2
	c.Key(input.Event{Key: input.Up}, now)
	if c.cur != 9 || c.tabs {
		t.Fatalf("collection Up from the first row: cur %d tabs %v", c.cur, c.tabs)
	}
}

// A held Down asks for the rows below the screen (and Up the rows above)
// while they are still out of view, so their posters are on their way.
func TestHeldScrollAsksAhead(t *testing.T) {
	w := wrapWall(200)
	now := time.Now()
	w.cur = 40 // row 10
	w.Key(input.Event{Key: input.Down, Repeat: true}, now)
	if w.heldDir != 1 {
		t.Fatalf("heldDir %d after a repeat Down", w.heldDir)
	}
	wanted := func(i int) bool {
		_, ok := w.app.Art.wants[(artReq{thumb: "poster-" + itoa(i), w: WallPW, h: WallPH}).key()]
		return ok
	}
	w.prefetchAhead(10, now) // rows 10-14 drawn: 15 and 16 are ahead
	if !wanted(60) || !wanted(67) {
		t.Fatal("rows ahead of a held Down not asked for")
	}
	if wanted(68) || wanted(59) {
		t.Fatal("asked beyond WallAheadRows, or behind")
	}
	w.Key(input.Event{Release: true}, now)
	if w.heldDir != 0 {
		t.Fatal("the release did not end the held direction")
	}
	w.Key(input.Event{Key: input.Up, Repeat: true}, now)
	w.app.Art.wants = map[artKey]artReq{}
	w.prefetchAhead(10, now) // row 9 and 8 are ahead of an Up
	if !wanted(36) || !wanted(32) || wanted(28) || wanted(40) {
		t.Fatal("rows ahead of a held Up not asked for, or the wrong ones")
	}
}
