package ui

import (
	"slices"
	"testing"

	"plexcrt/internal/plex"
)

// panelKey's cached answer is always the one it would build afresh.
func TestPanelKeyFollowsEveryChange(t *testing.T) {
	it := &plex.Item{Title: "Synthetic", Type: "episode", GrandTitle: "Show", Parent: 1, Index: 2}
	p := &Playing{item: it, dur: 100, pos: 10}
	fresh := func() string {
		title, sub := heading(p.item)
		return title + sub + "|" + itoa(int(p.pos)) + "|" + itoa(p.focus) + "|" + itoa(btoi(p.paused)) + "|" +
			itoa(btoi(p.scrub)) + "|" + itoa(int(p.scrubTo)) + p.bufferKey()
	}
	for i, change := range []func(){
		func() {},
		func() { p.pos = 11 },
		func() { p.pos = 11.5 },
		func() { p.focus = 3 },
		func() { p.paused = true },
		func() { p.scrub, p.scrubTo = true, 40 },
		func() { p.scrubTo = 41 },
		func() { p.bufferStart, p.bufferEnd = 10, 30 },
		func() { it.Index = 3 },
		func() { it.Title = "Other" },
		func() { p.item = &plex.Item{Title: "Film", Year: 1999} },
		func() { p.item.Edition = "Extended" },
	} {
		change()
		if got, want := p.panelKey(), fresh(); got != want {
			t.Fatalf("change %d: key %q, want %q", i, got, want)
		}
		if got := p.panelKey(); got != fresh() {
			t.Fatalf("change %d: second key %q", i, got)
		}
	}
}

// One cue alone is handed out as it is, but not so that appending to it
// could reach the track.
func TestSubtitleTrackAtOneCueIsTheCuesLines(t *testing.T) {
	track := subtitleTrack{{start: 1, end: 3, lines: make([]string, 1, 4)}, {start: 2, end: 5, lines: []string{"b"}}}
	track[0].lines[0] = "a"
	one := track.at(1.5)
	if !slices.Equal(one, []string{"a"}) || &one[0] != &track[0].lines[0] {
		t.Fatalf("one cue: %q", one)
	}
	_ = append(one, "x")
	if track[0].lines[:2][1] == "x" {
		t.Fatal("appending to at's answer wrote into the cue")
	}
	if both := track.at(2.5); !slices.Equal(both, []string{"a", "b"}) {
		t.Fatalf("two cues: %q", both)
	}
	if allocs := testing.AllocsPerRun(20, func() { track.at(1.5) }); allocs != 0 {
		t.Fatalf("one cue allocates %v times", allocs)
	}
}

// A subtitle already up is not keyed again every field, and new lines or
// a new size still repaint it.
func TestShowSubtitleSkipsTheKeyWhileUnchanged(t *testing.T) {
	p, osd, _, _ := subtitledPlaying(t)
	p.showSubtitle(osd, []string{"Hello"})
	first := p.last
	if !isSubtitleKey(first) {
		t.Fatalf("last = %q", first)
	}
	lines := []string{"Hello"}
	if allocs := testing.AllocsPerRun(20, func() { p.showSubtitle(osd, lines) }); allocs != 0 {
		t.Fatalf("an unchanged subtitle allocates %v times", allocs)
	}
	p.showSubtitle(osd, []string{"There"})
	if p.last == first {
		t.Fatal("new lines kept the old key")
	}
	p.app.Cfg.SubtitleSize = 200
	before := p.last
	p.showSubtitle(osd, []string{"There"})
	if p.last == before {
		t.Fatal("a new size kept the old key")
	}
}
