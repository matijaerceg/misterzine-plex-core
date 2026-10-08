package ui

import (
	"slices"
	"testing"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/plex"
)

func TestPreplayFitsLongTrackLabels(t *testing.T) {
	a := cropApp(t)
	audio := "Commentary by film critic Adrian Martin (English AAC Stereo)"
	subs := "English Signs and Songs for the Hearing Impaired (SRT External)"
	it := &plex.Item{RatingKey: "m1", Type: "movie", Title: "Fixture Film", Summary: "A short synopsis.", PartID: "p",
		Audio: []plex.Stream{{ID: "1", Title: "English (AAC Stereo)"}, {ID: "2", Title: audio, Selected: true}},
		Subs:  []plex.Stream{{ID: "3", Title: subs, Selected: true}}}
	p := &Preplay{app: a, item: it}
	p.rebuild()
	// the actions keep the whole text: only the drawing is cut
	for _, want := range []string{"Audio: " + audio, "Subtitles: " + subs} {
		if !slices.Contains(p.actions, want) {
			t.Fatalf("actions %q lack %q", p.actions, want)
		}
		if a.F.Body.Width(want) <= SafeX+SafeW-PreTextX {
			t.Fatalf("%q fits without cutting: the test needs a longer title", want)
		}
	}
	right := SafeX + SafeW
	c := gfx.NewCanvas(720, 480)
	for cur := range p.actions { // selected (white, with its bar) and not
		p.cur = cur
		p.Draw(c, time.Now())
		ink := 0
		for y := 0; y < c.H; y++ {
			for x := right - 40; x < c.W; x++ {
				o := (y*c.W + x) * 4
				if gfx.Color(uint32(c.Pix[o+2])<<16|uint32(c.Pix[o+1])<<8|uint32(c.Pix[o])) == gfx.Bg {
					continue
				}
				if x >= right {
					t.Fatalf("cursor on %q: text at x %d, past the safe area's right edge %d", p.actions[cur], x, right)
				}
				ink++
			}
		}
		if ink == 0 {
			t.Fatal("the cut labels stop well short of the edge")
		}
	}
}
