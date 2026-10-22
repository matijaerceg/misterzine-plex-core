package plex

import "testing"

// Fold keeps Central European, Baltic, Turkish and Romanian letters as
// their base letters, as subtitles in those languages need; other scripts
// still become spaces.
func TestFoldLatinExtended(t *testing.T) {
	for in, want := range map[string]string{
		"Źdźbło łąki":       "Zdzblo laki",
		"Příliš žluťoučký":  "Prilis zlutoucky",
		"Árvíztűrő ığdır":   "Arvizturo igdir",
		"Ştiinţă și țară":   "Stiinta si tara",
		"Čađa IJsselmeer Ĳ": "Cada IJsselmeer IJ",
		"Привет":            "      ",
		"Œuvre – “quoted”…": "OEuvre - \"quoted\"...",
	} {
		if got := Fold(in); got != want {
			t.Errorf("Fold(%q) = %q, want %q", in, got, want)
		}
	}
}
