package ui

import (
	"testing"

	"plexcrt/internal/plex"
)

// Hiding a library is app-wide: its items leave Continue Watching too.
func TestContinueWatchingLeavesOutHiddenLibraries(t *testing.T) {
	a := betaTestApp(t)
	a.Plex = &plex.Client{}
	a.secs = testLibraries
	a.Cfg.SetLibraryHidden("2", true)
	h := &Home{app: a, home: true}
	row := homeRow("home.continue", "c1", "c2", "c3")
	row.Items[0].Library = "1"
	row.Items[1].Library = "2"
	// an item whose library the server did not name stays
	h.applyHome([]*plex.Hub{row})
	if len(h.hubs) != 1 || len(h.hubs[0].Items) != 2 {
		t.Fatalf("Continue Watching after hiding library 2: %+v", h.hubs)
	}
	for _, it := range h.hubs[0].Items {
		if it.Library == "2" {
			t.Fatal("a hidden library's item stayed in Continue Watching")
		}
	}
}

// The copy Options keeps for a failed save holds the extras' settings as
// they were, not the live map.
func TestConfigSnapshotCopiesPremiumSettings(t *testing.T) {
	a := betaTestApp(t)
	a.setPremiumSetting("screensaver", "dvd")
	before := a.Cfg.snapshot()
	a.setPremiumSetting("screensaver", "off")
	a.setPremiumSetting("home_logo", "off")
	*a.Cfg = before
	if got := a.premiumSetting("screensaver"); got != "dvd" {
		t.Fatalf("after putting the copy back the setting is %q, want dvd", got)
	}
	if a.premiumSetting("home_logo") != "" {
		t.Fatal("a setting added after the copy survived putting it back")
	}
}
