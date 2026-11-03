//go:build !premium

package ui

import (
	"plexcrt/internal/access"
	"plexcrt/internal/chapters"
	"plexcrt/internal/input"
	"plexcrt/internal/plex"
	"slices"
	"testing"
	"time"
)

func TestPublicBuildCannotEnableChapters(t *testing.T) {
	a := cropApp(t)
	a.access = access.Chapters.Since
	a.setPremiumSetting("chapters", "on")
	if a.chaptersEnabled() {
		t.Fatal("public build enabled private feature")
	}
	it := &plex.Item{Type: "movie", Chapters: []chapters.Chapter{{Start: 0}, {Start: 60}}}
	pre := &Preplay{app: a, item: it}
	pre.rebuild()
	if slices.Contains(pre.actions, chaptersLabel) {
		t.Fatal("public chapter action")
	}
	p := &Playing{app: a, item: it, send: func(s string) { t.Fatalf("unexpected chapter command: %s", s) }}
	p.openMore()
	if slices.Contains(p.list.items, chaptersLabel) || slices.Contains(p.playbackButtons(), chaptersLabel) {
		t.Fatal("public playback chapter entry")
	}
	p.list = nil
	p.Key(input.Event{Key: input.JumpFwd}, time.Now())
	p.Key(input.Event{Key: input.JumpFwd, Release: true}, time.Now())
	a.browseChapters(it, func(int) { t.Fatal("public chapter playback") })
}
