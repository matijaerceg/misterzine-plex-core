package ui

import (
	"testing"

	"plexcrt/internal/plex"
)

func TestHeading(t *testing.T) {
	cases := []struct {
		item       plex.Item
		title, sub string
	}{
		{plex.Item{Type: "movie", Title: "Star Voyager", Year: 1984}, "Star Voyager", "1984"},
		{plex.Item{Type: "movie", Title: "Star Voyager", Edition: "Director's Cut", Year: 1984}, "Star Voyager", "1984  Director's Cut"},
		{plex.Item{Type: "movie", Title: "Undated"}, "Undated", ""},
		{plex.Item{Type: "episode", Title: "Pilot", GrandTitle: "Starlight Stories", Parent: 1, Index: 4, Year: 1992}, "Starlight Stories", "S1 E4  Pilot"},
	}
	for _, c := range cases {
		it := c.item
		title, sub := heading(&it)
		if title != c.title || sub != c.sub {
			t.Errorf("%s: got %q / %q, want %q / %q", c.item.Title, title, sub, c.title, c.sub)
		}
	}
}
