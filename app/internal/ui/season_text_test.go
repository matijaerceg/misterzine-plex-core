package ui

import (
	"slices"
	"testing"

	"plexcrt/internal/gfx"
	"plexcrt/internal/plex"
)

// The episode's lines are laid out once, and again as soon as anything
// they show changes (another episode, a mark, a refreshed record).
func TestSeasonEpisodeTextIsLaidOutOnce(t *testing.T) {
	a := &App{F: Fonts{SmallBold: gfx.Load("med16"), Body: gfx.Load("med18")}}
	s := &Season{app: a}
	ep := &plex.Item{RatingKey: "e1", Index: 3, Title: "Pilot", Duration: 1320,
		Summary: "A long synopsis that goes on well past the two lines the page has room for, " +
			"so the wrap has to cut it short and end the second line with an ellipsis after " +
			"several more words than could ever fit across the safe area of the screen."}
	first := s.epText(ep)
	lines := first.lines
	if again := s.epText(ep); &again.lines[0] != &lines[0] {
		t.Fatal("laid out again with nothing changed")
	}
	if want := wrap(a.F.SmallBold, ep.Summary, SafeW, 2); !slices.Equal(lines, want) {
		t.Fatalf("lines %q, want %q", lines, want)
	}
	ep.ViewCount = 1
	if got := s.epText(ep).facts; !slices.Contains(got, "Watched") {
		t.Fatalf("a mark did not reach the facts: %q", got)
	}
	ep.Summary = "Short."
	if got := s.epText(ep).lines; !slices.Equal(got, []string{"Short."}) {
		t.Fatalf("a new synopsis was not wrapped again: %q", got)
	}
	other := &plex.Item{RatingKey: "e2", Index: 4, Title: "Second"}
	if got := s.epText(other); got.fitted != "Second" || got.facts[0] != "Episode 4" {
		t.Fatalf("another episode kept the old text: %q %q", got.fitted, got.facts)
	}
}
