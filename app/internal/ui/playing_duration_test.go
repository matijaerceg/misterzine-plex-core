package ui

import "testing"

// The bar's length is the item's when the server knows it: a transcode's
// container carries the whole item's length again, which the player then
// adds the start offset to.
func TestPlayingDurationPrefersTheItems(t *testing.T) {
	for _, c := range []struct{ item, player, want float64 }{
		{1402, 1913, 1402}, // resumed at 511 s: the player says item plus offset
		{1402, 0, 1402},    // the player has none yet
		{0, 1913, 1913},    // the server has none: the player's stands
		{0, 0, 0},
		{0, -1, 0},
	} {
		if got := playingDuration(c.item, c.player); got != c.want {
			t.Errorf("playingDuration(%v, %v) = %v, want %v", c.item, c.player, got, c.want)
		}
	}
}
