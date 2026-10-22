package ui

import (
	"bytes"
	"testing"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/plex"
)

func benchWall() (*Wall, *gfx.Canvas) {
	p := &Pager{items: map[int]*plex.Item{}, total: 80, loaded: true}
	a := &App{Art: NewArt(nil, 0, nil), F: Fonts{Body: gfx.Load("med18"), SmallBold: gfx.Load("med16")}}
	for i := 0; i < p.total; i++ {
		thumb := "poster-" + itoa(i)
		p.items[i] = &plex.Item{RatingKey: itoa(i), Thumb: thumb, Title: "A library title", Year: 2026}
		img := &gfx.Image{W: WallPW, H: WallPH, Pix: make([]byte, WallPW*WallPH*4)}
		for j := range img.Pix {
			img.Pix[j] = byte(i + j)
		}
		r := artReq{thumb: thumb, w: WallPW, h: WallPH}
		a.Art.have[r.key()] = &artEntry{img: img, band: wallBandImage(img), at: time.Now().Add(-time.Second)}
	}
	w := &Wall{app: a, pager: p, cur: 20, band: gfx.NewCanvas(WallBandW, WallBandH), page: gfx.NewCanvas(720, 480)}
	w.page.Fill(0, 0, 720, 480, gfx.Bg)
	return w, w.page
}

// Compare every scroll offset with the original compose-then-tint renderer.
func TestWallBandPixels(t *testing.T) {
	w, page := benchWall()
	for j := range page.Pix {
		page.Pix[j] = byte(j / 17)
	}
	// Include a missing poster and an unloaded metadata slot.
	delete(w.app.Art.have, (artReq{thumb: "poster-25", w: WallPW, h: WallPH}).key())
	w.app.Art.failed[(artReq{thumb: "poster-25", w: WallPW, h: WallPH}).key()] = true
	w.pager.items[26] = nil
	w.pager.inFlt = map[int]bool{0: true, 1: true}
	for offset := 0; offset < WallRowPitch; offset++ {
		oy := 4*WallRowPitch + offset
		want := gfx.NewCanvas(WallBandW, WallBandH)
		for yy := 0; yy < want.H; yy++ {
			so := ((WallBandY+yy)*page.W + WallBandX) * 4
			copy(want.Pix[yy*want.W*4:(yy+1)*want.W*4], page.Pix[so:so+want.W*4])
		}
		for i, it := range w.pager.items {
			if it == nil {
				continue
			}
			y := WallY0 + (i/WallCols)*WallRowPitch - oy - WallBandY
			if y >= want.H || y+WallPH <= 0 {
				continue
			}
			x := i % WallCols * WallPitch
			if img := w.app.Art.Get(it.Thumb, WallPW, WallPH); img != nil {
				want.Blit(x, y, img)
			} else {
				want.Fill(x, y, WallPW, WallPH, gfx.Bar)
			}
		}
		want.FillAlpha(0, 0, want.W, want.H, gfx.Bg, 215)
		it := w.pager.Get(w.cur)
		want.Text(12, 10, w.app.F.Body, gfx.GreyHi, w.app.F.Body.Fit(it.Title, want.W-24))
		dots(want, 12, 10+w.app.F.Body.Height()+2, w.app.F.SmallBold, gfx.GreyLo, heroFacts(it), want.W-24)
		w.composeBand(page, time.Now(), oy)
		if !bytes.Equal(w.band.Pix, want.Pix) {
			t.Fatalf("strip differs at scroll offset %d", offset)
		}
	}
}

// The focused poster dims while the cursor is on the tabs, from one shaded
// copy made when that poster changes.
func TestWallFocusedPosterDimsOnTabs(t *testing.T) {
	w, _ := benchWall()
	it := w.pager.Get(w.cur)
	img := w.app.Art.Get(it.Thumb, WallPW, WallPH)
	c := gfx.NewCanvas(720, 480)
	x, y := SafeX, WallY0
	at := ((y+80)*c.W + x + 50) * 4
	src := img.Pix[(80*WallPW+50)*4]
	w.tabs = true
	w.drawPoster(c, it, x, y, true, false)
	if want := byte(int(src) * WatchedBright / 255); c.Pix[at] != want {
		t.Fatalf("focused poster on the tabs drew %d, want %d", c.Pix[at], want)
	}
	dim := w.dim
	w.drawPoster(c, it, x, y, true, false)
	if w.dim != dim {
		t.Fatal("the same poster was shaded again")
	}
	w.tabs = false
	w.drawPoster(c, it, x, y, true, false)
	if c.Pix[at] != src {
		t.Fatalf("focused poster in the grid drew %d, want %d", c.Pix[at], src)
	}
}

func TestWallPrefetchBounds(t *testing.T) {
	for _, cur := range []int{0, 20, 79} {
		w, _ := benchWall()
		w.cur = cur
		w.app.Art.have = map[artKey]*artEntry{}
		w.prefetchRows()
		want := 0
		for i := 0; i < w.total(); i++ {
			d := i/WallCols - cur/WallCols
			if d != 0 && d >= -WallPrefetchRows && d <= WallPrefetchRows {
				want++
			}
		}
		if len(w.app.Art.wants) != want {
			t.Fatalf("cursor %d: %d queued, want %d", cur, len(w.app.Art.wants), want)
		}
		for _, r := range w.app.Art.wants {
			if !r.prefetch {
				t.Fatal("nearby artwork queued as visible")
			}
		}
	}
}

// Exercise the moving strip on the same ARM CPU that draws the library.
func BenchmarkWallBandScroll(b *testing.B) {
	w, c := benchWall()
	now := time.Now()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		w.composeBand(c, now, 4*WallRowPitch+i%WallRowPitch)
	}
}
