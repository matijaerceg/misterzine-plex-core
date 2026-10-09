package ui

import (
	"slices"
	"testing"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/plex"
)

// optionGroups splits Options at its gaps: the labels of each group of
// rows, in order.
func optionGroups(items []option) [][]string {
	groups := [][]string{nil}
	for _, it := range items {
		if it.header {
			groups = append(groups, nil)
			continue
		}
		groups[len(groups)-1] = append(groups[len(groups)-1], it.label)
	}
	return groups
}

// groupNames gives each row of Options the name of its group, the groups
// named in order. It fails unless the gaps make exactly that many groups,
// none of them empty: no gap opens or ends the list, none follows another,
// and a gap has no text.
func groupNames(t *testing.T, items []option, names ...string) map[string]string {
	t.Helper()
	for i, it := range items {
		if it.header && it.label != "" {
			t.Fatalf("the gap at %d says %q", i, it.label)
		}
	}
	groups := optionGroups(items)
	if len(groups) != len(names) {
		t.Fatalf("%d groups %q, want %d (%q)", len(groups), groups, len(names), names)
	}
	under := map[string]string{}
	for i, g := range groups {
		if len(g) == 0 {
			t.Fatalf("the %s group is empty: a gap opens or ends the list, or follows another", names[i])
		}
		for _, label := range g {
			under[label] = names[i]
		}
	}
	return under
}

func TestOptionsGroups(t *testing.T) {
	a := betaTestApp(t)
	a.Plex = &plex.Client{}
	a.Cfg.Token = "account-token"
	a.Display = DisplayCheck{INI: "MiSTer.ini", VRR: "forced", VRRMode: 2}
	o := &Options{app: a}
	items := o.items()
	groups := []string{"Playback", "Picture", "Sound", "Extras", "Account", "App"}
	under := groupNames(t, items, groups...)
	for label, want := range map[string]string{
		"Only show 4:3 media": "Playback", "Autoplay next episode": "Playback", "Skip intro and credits buttons": "Playback",
		"Video bitrate": "Playback", "Surround downmix boost": "Playback",
		"Video output": "Picture", "Video geometry": "Picture", "Video crop": "Picture", "HDMI VRR": "Picture",
		"Theme music": "Sound", "Navigation sounds": "Sound",
		"Show beta features":  "Extras",
		"Choose server again": "Account", "Sign out": "Account",
		"Updates": "App", "Send a report": "App", "Version": "App",
	} {
		if got, ok := under[label]; !ok || got != want {
			t.Errorf("%q under %q, want %q", label, got, want)
		}
	}
	if items[len(items)-1].label != "Version" {
		t.Fatal("Version is no longer the last row")
	}
	a.Plex = nil // signed out: Exit and Patreon join the App rows, Version still last
	items = o.items()
	under = groupNames(t, items, groups...)
	for _, label := range []string{"Exit to MiSTer menu", "Patreon"} {
		if under[label] != "App" {
			t.Errorf("%q under %q while signed out, want App", label, under[label])
		}
	}
	if items[len(items)-1].label != "Version" {
		t.Fatal("Version is not the last row while signed out")
	}
}

func TestOptionsCursorSkipsGaps(t *testing.T) {
	a := betaTestApp(t)
	a.Plex = &plex.Client{}
	a.secs = []plex.Section{{Key: "1", Title: "Films", Type: "movie"}} // the libraries' group too
	o := NewOptions(a)
	a.Push(o)
	items := o.items()
	var rows []int
	for i, it := range items {
		if !it.header {
			rows = append(rows, i)
		}
	}
	now := time.Now()
	o.Key(input.Event{Key: input.Up}, now)
	if o.cur != rows[0] {
		t.Fatalf("Up at the top left the cursor on %d, want the first row %d", o.cur, rows[0])
	}
	walk := func(key input.Key) []int {
		seen := []int{o.cur}
		for range items { // more presses than rows: the cursor stops at the end
			o.Key(input.Event{Key: key}, now)
			if items[o.cur].header {
				t.Fatalf("the cursor is on the gap at %d", o.cur)
			}
			if o.cur != seen[len(seen)-1] {
				seen = append(seen, o.cur)
			}
		}
		return seen
	}
	if down := walk(input.Down); !slices.Equal(down, rows) {
		t.Fatalf("Down visited %v, want every row %v", down, rows)
	}
	if o.cur != len(items)-1 {
		t.Fatalf("Down stopped at %d, not Version", o.cur)
	}
	up := walk(input.Up)
	slices.Reverse(up)
	if !slices.Equal(up, rows) {
		t.Fatalf("Up visited %v (reversed), want every row %v", up, rows)
	}

	// the list can change under the cursor: a gap is never the cursor
	picture := slices.IndexFunc(items, func(it option) bool { return it.label == "Video output" }) - 1
	if !items[picture].header {
		t.Fatalf("no gap before the picture rows: %q", items[picture].label)
	}
	if got := onOption(items, picture); got != picture+1 {
		t.Fatalf("cursor on the gap before Video output moved to %d, want the row below %d", got, picture+1)
	}
	if got := onOption([]option{{label: "row"}, optionGap()}, 1); got != 0 {
		t.Fatalf("a gap with nothing below moved the cursor to %d, want the row above", got)
	}
	if got := onOption(items, len(items)+2); got != len(items)-1 {
		t.Fatalf("a cursor past the end landed on %d, want the last row", got)
	}
	// (the sound rows, not the extras: the official build has the extras' rows there)
	sound := slices.IndexFunc(items, func(it option) bool { return it.label == "Theme music" }) - 1
	o.cur = sound
	o.Key(input.Event{Key: input.Enter}, now) // OK acts on the row below: Theme music
	if !items[sound].header || o.cur != sound+1 || a.Cfg.NoTheme {
		t.Fatalf("OK with the cursor on a gap: cursor %d, theme music %v; want %d toggled on", o.cur, !a.Cfg.NoTheme, sound+1)
	}
}

func TestOptionsCursorStaysOnTheChangedRow(t *testing.T) {
	// Show beta features brings beta extras in above itself and takes them away
	without := []option{optionGap(), {label: "Show beta features"}, optionGap(), {label: "Sign out"}}
	with := []option{optionGap(), {label: "A beta extra"}, {label: "Another"}, {label: "Show beta features"}, optionGap(), {label: "Sign out"}}
	if got := labelledOption(with, "Show beta features", 1); got != 3 {
		t.Fatalf("rows added above: cursor on %d, want the toggle at 3", got)
	}
	if got := labelledOption(without, "Show beta features", 3); got != 1 {
		t.Fatalf("rows taken away above: cursor on %d, want the toggle at 1", got)
	}
	if got := labelledOption(without, "Updates - downloading", 3); got != 3 {
		t.Fatalf("a row whose label changed moved the cursor to %d", got)
	}
}

func TestCentredFirst(t *testing.T) {
	for _, tc := range []struct{ cur, visible, total, want int }{
		{0, 9, 20, 0}, {4, 9, 20, 0}, // the start: the cursor walks down to the middle
		{5, 9, 20, 1}, {10, 9, 20, 6}, {15, 9, 20, 11}, // the middle row holds it
		{16, 9, 20, 11}, {19, 9, 20, 11}, // the end: it walks on to the bottom row
		{0, 9, 9, 0}, {8, 9, 9, 0}, {3, 9, 5, 0}, // a list that fits never scrolls
	} {
		if got := centredFirst(tc.cur, tc.visible, tc.total); got != tc.want {
			t.Errorf("centredFirst(%d, %d, %d) = %d, want %d", tc.cur, tc.visible, tc.total, got, tc.want)
		}
	}
	for total := 1; total < 30; total++ {
		for cur := 0; cur < total; cur++ {
			first := centredFirst(cur, 9, total)
			if cur < first || cur >= first+9 {
				t.Fatalf("total %d: cursor %d outside the window from %d", total, cur, first)
			}
			if first > 0 && first < total-9 && cur-first != 4 {
				t.Fatalf("total %d: cursor %d on window row %d, not the middle", total, cur, cur-first)
			}
		}
	}
}

// focusY is how far down the Options window the focus bar is drawn, in
// pixels from the first row's place; -1 for none.
func focusY(c *gfx.Canvas) int {
	x := MenuX - MenuBarGap - BarW
	for y := 0; y < c.H; y++ {
		o := (y*c.W + x) * 4
		if gfx.Color(uint32(c.Pix[o+2])<<16|uint32(c.Pix[o+1])<<8|uint32(c.Pix[o])) == gfx.GreyHi {
			return y - ListY0 - 9 - 2
		}
	}
	return -1
}

// gappedRows is a list of rows in groups of the sizes given, with a gap
// between each two groups.
func gappedRows(sizes ...int) []option {
	var items []option
	for g, n := range sizes {
		if g > 0 {
			items = append(items, optionGap())
		}
		for i := range n {
			items = append(items, option{label: "row " + itoa(g) + "." + itoa(i)})
		}
	}
	return items
}

// halfRowsBefore is how far down items row i starts, in half rows.
func halfRowsBefore(items []option, i int) int {
	at := 0
	for _, it := range items[:i] {
		at += halfRows(it)
	}
	return at
}

// The window holds the selection in its middle, measured in half rows (a
// gap's height), and walks towards the top or bottom only at the list's
// start and end. It never opens on a gap or part of a row, so the
// selection can sit up to a row above the middle, and it holds as many
// rows as fit.
func TestOptionWindow(t *testing.T) {
	const window = 2 * optionRows // in half rows
	for _, sizes := range [][]int{{3, 5, 3, 2, 1, 2, 4}, {1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1}, {20}, {4, 4}, {2, 1, 2}, {9}, {8, 1}, {1, 9, 1}} {
		items := gappedRows(sizes...)
		lastFirst := 0
		for cur, it := range items {
			if it.header {
				continue
			}
			first, end, top, total := optionWindow(items, cur)
			at := halfRowsBefore(items, cur)
			h := halfRowsBefore(items, end) - top
			if top != halfRowsBefore(items, first) || total != halfRowsBefore(items, len(items)) {
				t.Fatalf("%v, cursor %d: top %d, total %d", sizes, cur, top, total)
			}
			if items[first].header {
				t.Fatalf("%v, cursor %d: the window opens on a gap", sizes, cur)
			}
			if cur < first || cur >= end {
				t.Fatalf("%v: cursor %d outside the window %d to %d", sizes, cur, first, end)
			}
			if h > window || (end < len(items) && h+halfRows(items[end]) <= window) {
				t.Fatalf("%v, cursor %d: the window holds %d half rows to %d", sizes, cur, h, end)
			}
			if first < lastFirst {
				t.Fatalf("%v: the window went back up to %d with the cursor going down to %d", sizes, first, cur)
			}
			lastFirst = first
			switch want := at + 1 - optionRows; {
			case total <= window && (first != 0 || end != len(items)):
				t.Fatalf("%v, cursor %d: a list that fits scrolled", sizes, cur)
			case want <= 0 && top != 0:
				t.Fatalf("%v, cursor %d: the start of the list scrolled away", sizes, cur)
			case want >= total-window && end != len(items):
				t.Fatalf("%v, cursor %d: the end of the list is out of view", sizes, cur)
			case want > 0 && want < total-window && (at-top < optionRows-3 || at-top > optionRows-1):
				t.Fatalf("%v, cursor %d: %d half rows down the window, not the middle", sizes, cur, at-top)
			}
		}
	}
}

func TestOptionsWindowKeepsTheCursorCentred(t *testing.T) {
	a := betaTestApp(t)
	a.Plex = &plex.Client{}
	a.secs = []plex.Section{{Key: "1", Title: "Films", Type: "movie"}} // the libraries' group too
	o := &Options{app: a}
	items := o.items()
	n := len(items)
	if n <= 9+8 {
		t.Fatalf("%d rows: too few to scroll through the middle", n)
	}
	c := gfx.NewCanvas(720, 480)
	for i, it := range items {
		if it.header {
			continue
		}
		o.cur = i
		o.Draw(c, time.Now())
		_, _, top, _ := optionWindow(items, i)
		want := (halfRowsBefore(items, i) - top) * MenuRowH / 2 // a gap is half a row high
		if got := focusY(c); got != want {
			t.Fatalf("row %d of %d (%q) drawn %d down the window, want %d", i, n, it.label, got, want)
		}
	}
	// a cursor left on a gap is drawn on the row below it
	gap := slices.IndexFunc(items, func(it option) bool { return it.header })
	o.cur = gap + 1
	o.Draw(c, time.Now())
	below := focusY(c)
	o.cur = gap
	o.Draw(c, time.Now())
	if got := focusY(c); got != below {
		t.Fatalf("cursor on the first gap drawn %d down the window, want %d (the row below)", got, below)
	}
}
