package ui

import (
	"strings"
	"testing"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/plex"
)

// heroTestHome is a home screen of one row whose items have backdrops and
// logos, none of them loaded.
func heroTestHome(t *testing.T) (*Home, *gfx.Canvas) {
	t.Helper()
	a := betaTestApp(t)
	a.Art = NewArt(nil, 0, nil)
	h := &Home{app: a, home: true}
	hub := &plex.Hub{Title: "Recently Added"}
	for _, id := range []string{"a", "b", "c"} {
		hub.Items = append(hub.Items, &plex.Item{RatingKey: id, Title: "Film " + id, Art: "art-" + id, Logo: "logo-" + id})
	}
	h.setHubs([]*plex.Hub{hub})
	t.Cleanup(func() { h.pageFade().Done() })
	return h, gfx.NewCanvas(720, 480)
}

// landHero puts an item's backdrop or logo in the cache, as the loader does.
func landHero(h *Home, it *plex.Item, backdrop, logo bool) *gfx.Image {
	a := h.app.Art
	a.mu.Lock()
	defer a.mu.Unlock()
	if backdrop {
		img := &gfx.Image{W: 720, H: 480, Pix: make([]byte, 720*480*4)}
		a.add(h.backdropRequest(it.Art, 720, 480).key(), &artEntry{img: img, at: time.Now(), backdrop: true})
	}
	var img *gfx.Image
	if logo {
		img = &gfx.Image{W: 120, H: 40, Pix: make([]byte, 120*40*4), Alpha: true}
		a.add(artReq{thumb: it.Logo, w: LogoW, h: LogoH, logo: true}.key(), &artEntry{img: img, at: time.Now()})
	}
	return img
}

// heroComposes draws the page at each time and counts the compositions.
func heroComposes(h *Home, c *gfx.Canvas, times ...time.Time) int {
	n := 0
	for _, at := range times {
		before := h.pageKey
		h.drawPage(c, at)
		if h.pageKey != before {
			n++
		}
	}
	return n
}

// A hero whose backdrop and logo land soon after the cursor rests on it is
// composed once, with both; the page before stays up meanwhile.
func TestHomeHeroComposesOnceWhenArtLands(t *testing.T) {
	h, c := heroTestHome(t)
	items := h.hubs[0].Items
	now := time.Now()
	landHero(h, items[0], true, true)
	if heroComposes(h, c, now) != 1 {
		t.Fatal("the first page was not composed")
	}
	first := h.page

	h.col[0], h.focusAt = 1, now
	rested := now.Add(HeroRest)
	if n := heroComposes(h, c, now.Add(100*time.Millisecond), rested.Add(10*time.Millisecond)); n != 0 {
		t.Fatalf("composed %d times before the pictures landed", n)
	}
	if h.page != first || h.pageItem == "" || !strings.HasPrefix(h.pageItem, "a|") {
		t.Fatal("the previous page did not stay up while the pictures loaded")
	}
	landHero(h, items[1], true, false)
	if n := heroComposes(h, c, rested.Add(50*time.Millisecond)); n != 0 {
		t.Fatal("composed before the logo landed")
	}
	logo := landHero(h, items[1], false, true)
	var times []time.Time
	for d := 100 * time.Millisecond; d < 2*time.Second; d += 16 * time.Millisecond {
		times = append(times, rested.Add(d))
	}
	if n := heroComposes(h, c, times...); n != 1 {
		t.Fatalf("composed %d times once the pictures were in, want 1", n)
	}
	if h.pageKey != "b|art-b|0|art" {
		t.Fatalf("page %q", h.pageKey)
	}
	if h.logo.img != logo {
		t.Fatal("the logo is not over the page")
	}
}

// Pictures that take longer than HeroArtWait do not hold the page: it is
// composed with what is there, and again when the backdrop lands. A logo
// landing late fades in over the page without composing it again.
func TestHomeHeroLateArtComposesAgain(t *testing.T) {
	h, c := heroTestHome(t)
	items := h.hubs[0].Items
	now := time.Now()
	landHero(h, items[0], true, true)
	heroComposes(h, c, now)

	h.col[0], h.focusAt = 2, now
	late := now.Add(HeroRest + HeroArtWait)
	if n := heroComposes(h, c, late.Add(-time.Millisecond)); n != 0 {
		t.Fatal("composed before the wait was over")
	}
	if n := heroComposes(h, c, late); n != 1 || h.pageKey != "c|art-c|0" {
		t.Fatalf("after the wait: %d compositions, page %q", n, h.pageKey)
	}
	landHero(h, items[2], true, false)
	if n := heroComposes(h, c, late.Add(time.Second)); n != 1 || h.pageKey != "c|art-c|0|art" {
		t.Fatalf("a late backdrop: %d compositions, page %q", n, h.pageKey)
	}
	logo := landHero(h, items[2], false, true)
	if n := heroComposes(h, c, late.Add(2*time.Second)); n != 0 {
		t.Fatal("a late logo composed the page again")
	}
	if h.logo.img != logo {
		t.Fatal("the late logo is not over the page")
	}
}

// The logos of the heroes around the cursor are fetched with their backdrops.
func TestHomePrefetchesHeroLogos(t *testing.T) {
	h, _ := heroTestHome(t)
	h.col[0] = 1
	h.prefetchBackdrops(720, 480)
	logos := 0
	for {
		r, ok := h.app.Art.nextWant()
		if !ok {
			break
		}
		if r.logo {
			if !r.prefetch || r.w != LogoW || r.h != LogoH {
				t.Fatalf("logo request %+v cannot serve the hero", r)
			}
			logos++
		}
	}
	if logos != 3 {
		t.Fatalf("%d logos prefetched, want 3", logos)
	}
}
