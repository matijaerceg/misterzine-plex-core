package ui

import "testing"

// A transcode's bar is the item's length when the server knows it: its
// container carries the whole item's length again, which the player then
// adds the start offset to. A direct stream's is the player's, read from
// the file as stored, whenever the player has one.
func TestPlayingDurationByStreamKind(t *testing.T) {
	for _, c := range []struct {
		item, player float64
		direct       bool
		want         float64
	}{
		{1402, 1913, false, 1402},    // transcode resumed at 511 s: the player says item plus offset
		{1402, 0, false, 1402},       // transcode, the player has none yet
		{0, 1913, false, 1913},       // transcode, the server has none: the player's stands
		{1402, 1403.5, true, 1403.5}, // direct: the file's own length wins
		{1402, 0, true, 1402},        // direct, the player has none yet
		{0, 1403.5, true, 1403.5},
		{0, 0, false, 0},
		{0, 0, true, 0},
		{0, -1, false, 0},
		{0, -1, true, 0},
	} {
		if got := playingDuration(c.item, c.player, c.direct); got != c.want {
			t.Errorf("playingDuration(%v, %v, direct %v) = %v, want %v", c.item, c.player, c.direct, got, c.want)
		}
	}
}
