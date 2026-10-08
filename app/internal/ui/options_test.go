package ui

import (
	"slices"
	"testing"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/plex"
)

// optionSections lists the headers of Options in order and the header each
// row sits under.
func optionSections(items []option) (headers []string, under map[string]string) {
	under = map[string]string{}
	section := ""
	for _, it := range items {
		if it.header {
			headers = append(headers, it.label)
			section = it.label
			continue
		}
		under[it.label] = section
	}
	return headers, under
}

func TestOptionsSections(t *testing.T) {
	a := betaTestApp(t)
	a.Plex = &plex.Client{}
	a.Cfg.Token = "account-token"
	a.Display = DisplayCheck{INI: "MiSTer.ini", VRR: "forced", VRRMode: 2}
	o := &Options{app: a}
	items := o.items()
	headers, under := optionSections(items)
	if want := []string{"Playback", "Picture", "Sound", "Extras", "Account", "App"}; !slices.Equal(headers, want) {
		t.Fatalf("sections %q, want %q", headers, want)
	}
	if !items[0].header {
		t.Fatalf("the list starts with %q, not a section", items[0].label)
	}
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
	_, under = optionSections(items)
	for _, label := range []string{"Exit to MiSTer menu", "Patreon"} {
		if under[label] != "App" {
			t.Errorf("%q under %q while signed out, want App", label, under[label])
		}
	}
	if items[len(items)-1].label != "Version" {
		t.Fatal("Version is not the last row while signed out")
	}
}

func TestOptionsCursorSkipsHeaders(t *testing.T) {
	a := betaTestApp(t)
	a.Plex = &plex.Client{}
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
				t.Fatalf("the cursor is on the %q header", items[o.cur].label)
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

	// the list can change under the cursor: a header is never the cursor
	picture := slices.IndexFunc(items, func(it option) bool { return it.label == "Picture" })
	if got := onOption(items, picture); got != picture+1 {
		t.Fatalf("cursor on the Picture header moved to %d, want the row below %d", got, picture+1)
	}
	if got := onOption([]option{{label: "row"}, optionSection("last")}, 1); got != 0 {
		t.Fatalf("a header with nothing below moved the cursor to %d, want the row above", got)
	}
	if got := onOption(items, len(items)+2); got != len(items)-1 {
		t.Fatalf("a cursor past the end landed on %d, want the last row", got)
	}
	extras := slices.IndexFunc(items, func(it option) bool { return it.label == "Extras" })
	o.cur = extras
	o.Key(input.Event{Key: input.Enter}, now) // OK acts on the row below: Show beta features
	if o.cur != extras+1 || !a.Cfg.ShowBeta {
		t.Fatalf("OK with the cursor on a header: cursor %d, beta %v; want %d toggled on", o.cur, a.Cfg.ShowBeta, extras+1)
	}
}

func TestOptionsCursorStaysOnTheChangedRow(t *testing.T) {
	// Show beta features brings beta extras in above itself and takes them away
	without := []option{optionSection("Extras"), {label: "Show beta features"}, optionSection("Account"), {label: "Sign out"}}
	with := []option{optionSection("Extras"), {label: "A beta extra"}, {label: "Another"}, {label: "Show beta features"}, optionSection("Account"), {label: "Sign out"}}
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

// focusRow is the window row (0-8) the Options focus bar is drawn on, -1 for none.
func focusRow(c *gfx.Canvas) int {
	x := MenuX - MenuBarGap - BarW
	for y := 0; y < c.H; y++ {
		o := (y*c.W + x) * 4
		if gfx.Color(uint32(c.Pix[o+2])<<16|uint32(c.Pix[o+1])<<8|uint32(c.Pix[o])) == gfx.GreyHi {
			return (y - ListY0 - 9 - 2) / MenuRowH
		}
	}
	return -1
}

func TestOptionsWindowKeepsTheCursorCentred(t *testing.T) {
	a := betaTestApp(t)
	a.Plex = &plex.Client{}
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
		want := min(i, 4) // the start: from the top down to the middle
		if i > n-1-4 {
			want = 9 - (n - i) // the end: on from the middle to the bottom
		}
		if got := focusRow(c); got != want {
			t.Fatalf("row %d of %d (%q) drawn on window row %d, want %d", i, n, it.label, got, want)
		}
	}
	// a cursor left on a header is drawn on the row below it
	o.cur = 0
	o.Draw(c, time.Now())
	if got := focusRow(c); got != 1 {
		t.Fatalf("cursor on the first header drawn on window row %d, want 1", got)
	}
}
