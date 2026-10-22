package ui

import (
	"bytes"
	"testing"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/plex"
)

// The page keeps its still layer (backdrop, logo, facts, poster) and draws
// only the text column again on a press. Every frame must still match the
// page composed whole, as it was before the layer was kept.
func TestPreplayKeptLayerMatchesTheWholePage(t *testing.T) {
	a := cropApp(t)
	a.Art = NewArt(nil, 0, nil)
	long := time.Now().Add(-time.Hour) // landed long ago: no fade
	pattern := func(w, h int, seed byte, alpha bool) *gfx.Image {
		img := &gfx.Image{W: w, H: h, Pix: make([]byte, w*h*4), Alpha: alpha}
		for i := range img.Pix {
			img.Pix[i] = byte(i*7) ^ seed
		}
		if alpha { // premultiplied: no channel above its alpha
			for o := 0; o < len(img.Pix); o += 4 {
				for k := 0; k < 3; k++ {
					img.Pix[o+k] = min(img.Pix[o+k], img.Pix[o+3])
				}
			}
		}
		return img
	}
	put := func(r artReq, img *gfx.Image, at time.Time) {
		a.Art.mu.Lock()
		a.Art.have[r.key()] = &artEntry{img: img, at: at}
		a.Art.mu.Unlock()
	}
	backReq := artReq{thumb: "back", w: 720, h: 480, bright: BgBright, fade: BgFade}
	posterReq := artReq{thumb: "poster", w: PosterW, h: PosterH}
	put(backReq, pattern(720, 480, 0x5a, false), long)
	put(artReq{thumb: "logo", w: PreLogoW, h: PreLogoH, logo: true}, pattern(300, 70, 0x33, true), long)
	poster := pattern(PosterW, PosterH, 0x99, false)
	put(posterReq, poster, long)
	it := &plex.Item{RatingKey: "m1", Type: "movie", Title: "Fixture Film", Art: "back", Thumb: "poster", Logo: "logo",
		Year: 1999, Duration: 6000, ViewOffset: 1500, Genres: []string{"Drama", "Mystery"}, PartID: "p",
		Summary: "A synopsis long enough to need both of the page's lines and then some more, so that " +
			"it is cut with an ellipsis and the synopsis itself can take the cursor before the actions.",
		Audio: []plex.Stream{{ID: "1", Title: "English"}, {ID: "2", Title: "French", Selected: true}}}
	p := &Preplay{app: a, item: it}
	p.rebuild()
	now := time.Now()
	same := func(what string, w, h int) {
		t.Helper()
		out := gfx.NewCanvas(w, h)
		out.Fill(0, 0, w, h, 0xff00ff)
		p.Draw(out, now)
		want := gfx.NewCanvas(w, h)
		p.compose(want, now)
		if !bytes.Equal(out.Pix, want.Pix) {
			for i := range out.Pix {
				if out.Pix[i] != want.Pix[i] {
					px := i / 4
					t.Fatalf("%s: pixel %d,%d differs from the page composed whole", what, px%w, px/w)
				}
			}
		}
	}
	same("opened", 720, 480)
	if !p.more {
		t.Fatal("the fixture's synopsis must be cut so it can take the cursor")
	}
	for cur := -1; cur < len(p.actions); cur++ {
		p.cur = cur
		same("cursor on "+itoa(cur+1), 720, 480)
	}
	for cur := len(p.actions) - 1; cur >= -1; cur-- {
		p.cur = cur
		same("cursor back on "+itoa(cur+1), 720, 480)
	}
	p.cur = 0
	a.Starting = now.Add(-300 * time.Millisecond)
	same("starting", 720, 480)
	a.Starting = time.Time{}
	it.ViewOffset, it.ViewCount = 0, 1 // marked watched: the badge and facts change
	p.rebuild()
	same("marked", 720, 480)

	// a poster fading in: whole pages while it fades, then kept again
	put(posterReq, poster, time.Now())
	if !p.Draw(gfx.NewCanvas(720, 480), time.Now()) {
		t.Fatal("a fading poster did not keep the page animating")
	}
	put(posterReq, poster, long)
	same("faded in", 720, 480)
	p.cur = 1
	same("faded in, cursor moved", 720, 480)

	a.Art.mu.Lock()
	delete(a.Art.have, backReq.key())
	a.Art.mu.Unlock()
	same("no backdrop", 720, 480)
	p.cur = 0
	same("no backdrop, cursor moved", 720, 480)
	same("wide", 960, 480)
	p.cur = 1
	same("wide, cursor moved", 960, 480)
}
