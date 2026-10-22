package ui

import (
	"bytes"
	"fmt"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/plex"
)

func drainSeason(t *testing.T, a *App, d *seasonData) {
	t.Helper()
	deadline := time.After(2 * time.Second)
	for d.loading {
		select {
		case f := <-a.later:
			f()
		case <-deadline:
			t.Fatal("season request did not finish")
		}
	}
}

func TestSeasonRetainsAllThumbsBeyondSharedCache(t *testing.T) {
	a := NewArt(nil, 0, nil)
	s := &Season{app: &App{Art: a}}
	for i := 0; i < 116; i++ { // a long season; eviction is simulated below
		s.eps = append(s.eps, &plex.Item{Thumb: fmt.Sprintf("thumb-%d", i)})
	}
	for batch := 0; len(s.thumbs) < len(s.eps) && batch < 40; batch++ {
		s.preloadThumbs()
		if len(a.wants) > 8 {
			t.Fatal("preload flooded the shared request queue")
		}
		for {
			r, ok := a.nextWant()
			if !ok {
				break
			}
			if !r.prefetch {
				t.Fatal("background thumbnail has visible priority")
			}
			a.have[r.key()] = &artEntry{img: &gfx.Image{W: StillW, H: StillH, Pix: make([]byte, StillW*StillH*4)}, at: time.Now()}
		}
		s.preloadThumbs()
		// Simulate shared-cache eviction; season-owned images must survive.
		a.have = map[artKey]*artEntry{}
	}
	if len(s.thumbs) != len(s.eps) {
		t.Fatalf("retained %d of %d thumbnails", len(s.thumbs), len(s.eps))
	}
	for _, it := range s.eps {
		if img, _, _ := s.episodeThumb(it, false); img == nil {
			t.Fatalf("thumbnail %s was evicted", it.Thumb)
		}
	}
}

func TestSeasonPrefetchReuseAndExpiry(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		fmt.Fprint(w, `<MediaContainer><Video ratingKey="1" type="episode" title="First" viewCount="1"/><Video ratingKey="2" type="episode" title="Next"/></MediaContainer>`)
	}))
	defer server.Close()
	a := &App{Plex: testClient(server.URL, "", t.TempDir()), later: make(chan func(), 32), Art: NewArt(nil, 0, nil)}
	sea := &plex.Item{Key: "/children"}
	a.prefetchSeason(sea, &plex.Item{})
	d := a.seasonData
	if a.seasonEpisodes(sea, true) != d {
		t.Fatal("opening duplicated the in-flight prefetch")
	}
	drainSeason(t, a, d)
	if a.seasonEpisodes(sea, true) != d || requests.Load() != 1 || len(d.eps) != 2 {
		t.Fatal("opening did not reuse the completed listing")
	}
	d.until = time.Now().Add(-time.Second)
	fresh := a.seasonEpisodes(sea, true)
	drainSeason(t, a, fresh)
	if fresh == d || requests.Load() != 2 {
		t.Fatal("expired listing was not refreshed")
	}
	a.Plex = testClient(server.URL, "another-account", t.TempDir())
	other := a.seasonEpisodes(sea, true)
	drainSeason(t, a, other)
	if other == fresh || requests.Load() != 3 {
		t.Fatal("listing reused across accounts")
	}
}

func TestSeasonPrefetchViewport(t *testing.T) {
	for _, cur := range []int{0, 1, 4, 6} {
		a := &App{Art: NewArt(nil, 0, nil)}
		d := &seasonData{key: "/children", until: time.Now().Add(time.Minute)}
		for i := 0; i < 7; i++ {
			ep := &plex.Item{Thumb: fmt.Sprint(i), ViewCount: 1}
			if i == cur {
				ep.ViewCount = 0
			}
			d.eps = append(d.eps, ep)
		}
		a.seasonData = d
		a.prefetchSeason(&plex.Item{Key: d.key}, &plex.Item{})
		first := max(0, cur-StillsAcross+1)
		for i := first; i < first+StillsAcross; i++ {
			r, ok := a.Art.nextWant()
			if !ok || r.thumb != fmt.Sprint(i) || !r.prefetch {
				t.Fatalf("cursor %d: unexpected artwork request %+v", cur, r)
			}
		}
		if _, ok := a.Art.nextWant(); ok {
			t.Fatal("prefetched beyond initial viewport")
		}
	}
}

func TestFadeCancellationInterruptsPacing(t *testing.T) {
	var f Fade
	page := gfx.NewCanvas(720, 480)
	// A future start keeps the worker asleep without depending on CPU speed.
	f.Layout(page, page, nil, 0, SeasonLift, time.Now().Add(time.Second))
	start := time.Now()
	f.Done()
	if time.Since(start) > 200*time.Millisecond || f.Running() {
		t.Fatal("cancellation waited for the pacing sleep")
	}
}

func TestSeasonLateArtworkKeepsSlide(t *testing.T) {
	a := &App{Art: NewArt(nil, 0, nil), F: Fonts{Big: gfx.Load("bold28"), SmallBold: gfx.Load("med16"), Body: gfx.Load("med18")}}
	show := &plex.Item{RatingKey: "show", Title: "Show", Art: "backdrop", Logo: "logo"}
	sea := &plex.Item{RatingKey: "season", Title: "Season 1"}
	s := &Season{app: a, show: show, seasons: []*plex.Item{sea}}
	out := gfx.NewCanvas(720, 480)
	now := time.Now()
	s.view = &Show{}
	s.view.transition = &Handoff{Page: gfx.NewCanvas(720, 480)}
	s.drawPage(out, now)
	defer s.pageFade().Done()
	page, key := s.page, s.pageKey
	r := artReq{thumb: "backdrop", w: 720, h: 480, bright: HeroBright, fade: HeroFade}
	a.Art.have[r.key()] = &artEntry{img: &gfx.Image{W: 720, H: 480, Pix: make([]byte, 720*480*4)}}
	s.drawPage(out, now.Add(50*time.Millisecond))
	if s.page != page || s.pageKey != key || s.pageFade().start != now {
		t.Fatal("late artwork replaced the active slide")
	}
	s.drawPage(out, now.Add(transDur+time.Millisecond))
	if s.pageKey == key {
		t.Fatal("late artwork never applied after the slide")
	}
}

func TestSeasonStaleLoadDoesNotOverwriteReturn(t *testing.T) {
	a := &App{F: Fonts{Body: gfx.Load("med18")}}
	one, two := &plex.Item{Key: "one"}, &plex.Item{Key: "two"}
	d := &seasonData{key: one.Key, loading: true}
	a.seasonData = d
	s := &Season{app: a, seasons: []*plex.Item{one, two}}
	s.load("first")
	a.seasonData = &seasonData{key: two.Key, loading: true}
	s.si = 1
	s.load("")
	a.seasonData, s.si = d, 0
	s.load("second")
	d.eps = []*plex.Item{{RatingKey: "first", Audio: []plex.Stream{{}}}, {RatingKey: "second", Audio: []plex.Stream{{}}}}
	for _, apply := range d.wait {
		apply()
	}
	if s.focused().RatingKey != "second" || s.loading {
		t.Fatal("stale request replaced the latest episode selection")
	}
}

// Stepping to another season and back lists the first one again as new
// items; their tracks must be asked for again, not skipped as already asked.
func TestSeasonTracksReturnAfterSteppingBack(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/children"):
			n := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/library/metadata/s"), "/children")
			plexPage(w, r, `<Video ratingKey="e`+n+`" type="episode" title="Pilot"/>`)
		case strings.HasPrefix(r.URL.Path, "/library/metadata/"):
			id := strings.TrimPrefix(r.URL.Path, "/library/metadata/")
			fmt.Fprintf(w, `<MediaContainer size="1"><Video ratingKey=%q type="episode"><Media><Part id="src">`+
				`<Stream id="1" streamType="2"/><Stream id="2" streamType="2"/><Stream id="3" streamType="3"/>`+
				`</Part></Media></Video></MediaContainer>`, id)
		default:
			fmt.Fprint(w, `<MediaContainer size="0"/>`)
		}
	}))
	defer server.Close()
	a := &App{Plex: testClient(server.URL, "", t.TempDir()), later: make(chan func(), 32),
		Art: NewArt(nil, 0, nil), F: Fonts{Body: gfx.Load("med18")}}
	one := &plex.Item{Key: "/library/metadata/s1/children"}
	two := &plex.Item{Key: "/library/metadata/s2/children"}
	s := &Season{app: a, seasons: []*plex.Item{one, two}}
	hasTracks := func() bool {
		deadline := time.After(2 * time.Second)
		for {
			if it := s.focused(); it != nil && len(it.Audio) > 0 {
				return slices.ContainsFunc(s.actions, func(a string) bool { return strings.HasPrefix(a, "Audio") })
			}
			select {
			case f := <-a.later:
				f()
			case <-deadline:
				return false
			}
		}
	}
	for step, si := range []int{0, 1, 0} {
		s.si = si
		s.load("")
		drainSeason(t, a, a.seasonData)
		if !hasTracks() {
			t.Fatalf("step %d (season %d): episode has no Audio action", step, si+1)
		}
	}
}

func TestSeasonPreparedDetailsAndInputInterrupt(t *testing.T) {
	a := &App{Art: NewArt(nil, 0, nil), F: Fonts{Big: gfx.Load("bold28"), SmallBold: gfx.Load("med16"), Body: gfx.Load("med18")}}
	show := &plex.Item{RatingKey: "show", Title: "Show"}
	sea := &plex.Item{RatingKey: "season", Title: "Season 1"}
	ep := &plex.Item{RatingKey: "episode", Title: "Episode title", Summary: "Episode summary", Duration: 1320, Audio: []plex.Stream{{}}}
	s := &Season{app: a, show: show, seasons: []*plex.Item{sea}, eps: []*plex.Item{ep}}
	s.rebuild()
	out := gfx.NewCanvas(720, 480)
	now := time.Now()
	s.view = &Show{}
	s.view.transition = &Handoff{Page: gfx.NewCanvas(720, 480)}
	s.drawPage(out, now)
	defer s.pageFade().Done()
	want := snapshot(s.page)
	s.drawDetails(want, s.page, now)
	if !bytes.Equal(s.pageFade().to.Pix, want.Pix) {
		t.Fatal("slide target differs from settled episode details")
	}
	s.Key(input.Event{Key: input.Down}, now.Add(50*time.Millisecond))
	if s.pageFade().Running() || !s.acts {
		t.Fatal("fresh input did not interrupt the slide and reach the actions")
	}
}

func TestShowStateRetainsSelectionAndStack(t *testing.T) {
	a := &App{F: Fonts{Body: gfx.Load("med18")}}
	seasons := []*plex.Item{{RatingKey: "season", Key: "/season"}}
	a.seasonData = &seasonData{key: "/season", until: time.Now().Add(time.Minute),
		eps: []*plex.Item{{RatingKey: "1", Audio: []plex.Stream{{}}}, {RatingKey: "2", Audio: []plex.Stream{{}}}}}
	v := NewShow(a, &plex.Item{RatingKey: "show"}, seasons)
	a.stack = []Screen{&Home{}, v}
	now := time.Now()
	v.enterSeason(0, "", now)
	season := v.season
	season.cur, season.acts, season.act = 1, true, 1
	if !v.Back() || v.episodes || len(a.stack) != 2 {
		t.Fatal("Back did not change layout in place")
	}
	v.enterSeason(0, "", now)
	if v.season != season || season.cur != 1 || !season.acts || season.act != 1 || len(a.stack) != 2 {
		t.Fatal("switching layouts rebuilt the season or lost its selection")
	}
	v.overview(now)
	if v.Back() {
		t.Fatal("Back from the picker must leave the show")
	}
}

func TestShowDirectEpisodeBack(t *testing.T) {
	a := &App{F: Fonts{Body: gfx.Load("med18")}}
	seasons := []*plex.Item{{Key: "/season"}}
	a.seasonData = &seasonData{key: "/season", until: time.Now().Add(time.Minute),
		eps: []*plex.Item{{RatingKey: "1", Audio: []plex.Stream{{}}}}}
	v := NewShowInSeason(a, &plex.Item{}, seasons, 0, "1")
	if !v.episodes || !v.season.acts || v.Back() {
		t.Fatal("direct episode entry lost its original Back behavior")
	}
	v.overview(time.Now())
	v.enterSeason(0, "", time.Now())
	if !v.Back() || v.episodes {
		t.Fatal("picker entry must return to the picker")
	}
}

func TestShowTransitionSlidesBackdropWithoutBand(t *testing.T) {
	a := &App{F: Fonts{Big: gfx.Load("bold28"), SmallBold: gfx.Load("med16"), Body: gfx.Load("med18")}}
	show, sea := &plex.Item{Title: "Show"}, &plex.Item{Title: "Season 1"}
	art := &gfx.Image{W: 720, H: 480, Pix: make([]byte, 720*480*4)}
	for i := range art.Pix {
		art.Pix[i] = byte(i / 17)
	}
	from, to := gfx.NewCanvas(720, 480), gfx.NewCanvas(720, 480)
	h := &Home{app: a, fixed: show}
	s := &Season{app: a, show: show, seasons: []*plex.Item{sea}}
	h.compose(from, show, art, nil, true)
	s.compose(to, art, nil, true)
	for _, reverse := range []bool{false, true} {
		var f Fade
		a, b, ay, by := from, to, 0, SeasonLift
		if reverse {
			a, b, ay, by = to, from, SeasonLift, 0
		}
		f.Layout(a, b, art, ay, by, time.Now())
		f.wg.Wait()
		for i, frame := range f.steps {
			yoff := layoutY(ay, by, i+1, f.n)
			// Left of the up chevron and above intentional header shading.
			for y := 0; y < 32; y++ {
				o, src := y*720*4, (y+yoff)*720*4
				if !bytes.Equal(frame.Pix[o:o+250*4], art.Pix[src:src+250*4]) {
					t.Fatalf("reverse=%v step=%d: backdrop band at row %d", reverse, i+1, y)
				}
			}
		}
		f.Done()
	}
}

func TestShowDownOpensSelectedSeasonLikeOK(t *testing.T) {
	for _, key := range []input.Key{input.Down, input.Enter} {
		a := &App{F: Fonts{Body: gfx.Load("med18")}}
		seasons := []*plex.Item{{Type: "season", Key: "/one"}, {Type: "season", Key: "/two"}}
		a.seasonData = &seasonData{key: "/two", until: time.Now().Add(time.Minute),
			eps: []*plex.Item{{RatingKey: "episode", Audio: []plex.Stream{{}}}}}
		v := NewShow(a, &plex.Item{}, seasons)
		v.picker.focusSeason(1)
		v.Key(input.Event{Key: key}, time.Now())
		if !v.episodes || v.season.si != 1 {
			t.Fatalf("key %v did not open selected season", key)
		}
		v.Key(input.Event{Key: input.Up}, time.Now())
		v.Key(input.Event{Key: input.Up}, time.Now())
		if v.episodes || v.picker.col[0] != 1 {
			t.Fatal("Up did not return to the same season")
		}
	}
}

func TestLogoScratchPixelsAndReuse(t *testing.T) {
	page, got := gfx.NewCanvas(720, 480), gfx.NewCanvas(720, 480)
	for i := range page.Pix {
		page.Pix[i] = byte(i / 13)
	}
	im := &gfx.Image{W: 260, H: 56, Pix: make([]byte, 260*56*4)}
	for i := range im.Pix {
		im.Pix[i] = byte(i / 7)
	}
	var l logoLayer
	for _, x := range []int{56, -10, 690, 56} {
		got.Copy(page)
		l.imageOver(got, page, x, 60, im, 123, nil, 0, 0, 0)
		want := gfx.NewCanvas(720, 480)
		want.Copy(page)
		want.BlitOverT(x, 60, im, 123)
		if !bytes.Equal(got.Pix, want.Pix) {
			t.Fatal("logo composition changed")
		}
	}
	buf := &l.scratch.Pix[0]
	l.imageOver(got, page, 60, 70, im, 256, nil, 0, 0, 0)
	if buf != &l.scratch.Pix[0] {
		t.Fatal("steady logo reallocated its buffer")
	}
}

func BenchmarkTransitionLogo(b *testing.B) {
	page, out := gfx.NewCanvas(720, 480), gfx.NewCanvas(720, 480)
	im := &gfx.Image{W: 260, H: 56, Pix: make([]byte, 260*56*4)}
	var l logoLayer
	l.imageOver(out, page, 56, 60, im, 256, nil, 0, 0, 0)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		l.imageOver(out, page, 56, 60, im, 256, nil, 0, 0, 0)
	}
}

func TestShowTransitionUsesOneQuantizedClock(t *testing.T) {
	a := &App{Art: NewArt(nil, 0, nil), T: gfx.NewTextCache(0, nil),
		F: Fonts{Body: gfx.Load("med18"), SmallBold: gfx.Load("med16"), Big: gfx.Load("bold28")}}
	seasons := []*plex.Item{{Type: "season", RatingKey: "season", Key: "/season"}}
	a.seasonData = &seasonData{key: "/season", until: time.Now().Add(time.Minute),
		eps: []*plex.Item{{RatingKey: "episode", Title: "Episode", Audio: []plex.Stream{{}}}}}
	v := NewShow(a, &plex.Item{Title: "Show"}, seasons)
	v.picker.page = gfx.NewCanvas(720, 480)
	out := gfx.NewCanvas(720, 480)
	start := time.Now()
	v.enterSeason(0, "", start)
	v.Draw(out, start)
	v.fade.wg.Wait()
	defer v.fade.Done()
	for i := 1; i <= transitionSteps; i++ {
		// Scheduling jitter must not advance one layer ahead of the others.
		v.Draw(out, start.Add(5*time.Second))
		if want := start.Add(time.Duration(i) * transitionFrame); v.presentedAt != want {
			t.Fatalf("step %d: animation time=%v want=%v", i, v.presentedAt, want)
		}
		if i < transitionSteps && !v.pacedTransition() {
			t.Fatal("transition stopped pacing early")
		}
	}
	if v.pacedTransition() {
		t.Fatal("normal navigation remained capped after transition")
	}
}
