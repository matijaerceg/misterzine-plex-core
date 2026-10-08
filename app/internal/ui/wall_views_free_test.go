//go:build !premium

package ui

import (
	"testing"

	"plexcrt/internal/access"
)

// The public build adds no library views: even with a code covering
// Random library order and the setting on, a library has its own five tabs
// and opens on A to Z.
func TestPublicBuildHasNoExtraLibraryViews(t *testing.T) {
	s := newPagedServer(t, 10)
	a := pagedTestApp(t, s)
	a.access = access.RandomSort.Since
	a.setPremiumSetting("random-sort", "")
	if got := a.premiumWallViews(filmsLibrary); got != nil {
		t.Fatalf("the public build offers %d extra views", len(got))
	}
	w := NewWall(a, filmsLibrary)
	if len(w.views) != len(wallViews) || w.view != 0 {
		t.Fatalf("%d views, opened on %d", len(w.views), w.view)
	}
}
