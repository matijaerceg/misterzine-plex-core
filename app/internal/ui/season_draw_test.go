package ui

import (
	"bytes"
	"testing"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/plex"
)

// artPattern is a synthetic picture; with alpha, premultiplied.
func artPattern(w, h int, seed byte, alpha bool) *gfx.Image {
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

// putArt has a picture land at the given time.
func putArt(a *App, r artReq, img *gfx.Image, at time.Time) {
	a.Art.mu.Lock()
	a.Art.have[r.key()] = &artEntry{img: img, at: at}
	a.Art.mu.Unlock()
}

var seasonLogoReq = artReq{thumb: "logo", w: SeasonLogoW, h: SeasonLogoH, logo: true}

// seasonFixture is a season page of synthetic episodes whose pictures have
// all landed long ago (no fade), for 720 and 960 wide canvases.
func seasonFixture(tb testing.TB) *Season {
	tb.Helper()
	a := &App{Art: NewArt(nil, 0, nil), T: gfx.NewTextCache(1, nil),
		F: Fonts{Body: gfx.Load("med18"), SmallBold: gfx.Load("med16"), Big: gfx.Load("bold28")}}
	long := time.Now().Add(-time.Hour)
	for _, w := range []int{720, 960} {
		putArt(a, artReq{thumb: "back", w: w, h: 480, bright: HeroBright, fade: HeroFade}, artPattern(w, 480, 0x5a, false), long)
	}
	putArt(a, seasonLogoReq, artPattern(220, 50, 0x33, true), long)
	show := &plex.Item{RatingKey: "show", Title: "Fixture Show", Art: "back", Logo: "logo"}
	seasons := []*plex.Item{{RatingKey: "s1", Title: "Season 1", Leaves: 12, Viewed: 3}, {RatingKey: "s2", Title: "Season 2"}}
	s := &Season{app: a, show: show, seasons: seasons}
	for i := 0; i < 12; i++ {
		ep := &plex.Item{RatingKey: "e" + itoa(i+1), Type: "Episode", Index: i + 1, Title: "Episode title number " + itoa(i+1),
			Summary: "A synopsis long enough to wrap onto both of the page's lines and then some more, so " +
				"that it is cut short with an ellipsis at the end of the second line.",
			Duration: 1320, Thumb: "still" + itoa(i), Audio: []plex.Stream{{ID: "1"}, {ID: "2"}}}
		if i < 3 {
			ep.ViewCount = 1
		}
		if i == 3 {
			ep.ViewOffset = 600
		}
		if i == 5 {
			ep.Summary = "Short."
		}
		putArt(a, artReq{thumb: ep.Thumb, w: StillW, h: StillH}, artPattern(StillW, StillH, byte(i*29), false), long)
		s.eps = append(s.eps, ep)
	}
	s.epAt = long
	s.rebuild()
	return s
}

// holdKey steps the cursor as a held Left or Right does, turning at the
// season's ends.
func holdKey(s *Season, dir *input.Key, now time.Time) {
	if (*dir == input.Right && s.cur == len(s.eps)-1) || (*dir == input.Left && s.cur == 0) {
		*dir = input.Left + input.Right - *dir
	}
	s.Key(input.Event{Key: *dir, Repeat: true}, now)
}

// seasonWhole draws the frame Draw just drew as Draw drew every frame
// before the layer was kept, from the state Draw left: the page as shown
// around the stills, the logo over it, the filmstrip, then the details
// blended over the page line by line.
func seasonWhole(c *gfx.Canvas, s *Season, now time.Time) {
	c.Fill(0, 0, c.W, c.H, 0xff00ff)
	c.BlitExcept(s.shown, s.holes)
	s.logoLayer().draw(c, s.shown, now)
	s.drawStrip(c, now, round(s.colX.At(now)))
	if !s.pageFade().Transitioning(now) {
		tc := s.app.T
		s.app.T = nil // every line blended over the page, none from the cache
		s.drawDetails(c, s.shown, now)
		s.app.T = tc
	}
}

// The page keeps a layer of itself with the logo and the details and draws
// only the filmstrip over it while nothing else moves. Every frame must
// match the frame drawn whole, as it was before: through the entry slide,
// a glide, the actions, the season picker, a still and the logo landing,
// a mark, refreshed season facts, a start and a wider canvas.
func TestSeasonKeptLayerMatchesTheWholeFrame(t *testing.T) {
	s := seasonFixture(t)
	a := s.app
	long := time.Now().Add(-time.Hour)
	a.Art.mu.Lock()
	delete(a.Art.have, seasonLogoReq.key()) // the logo lands later
	a.Art.mu.Unlock()
	s.view = &Show{app: a}
	defer s.pageFade().Done()
	from := gfx.NewCanvas(720, 480)
	from.Fill(0, 0, 720, 480, 0x203040)
	s.view.transition = &Handoff{Page: from, Logo: artPattern(200, 40, 0x77, true), X: SafeX + 30, Y: SafeY + 60}
	w, h := 720, 480
	now := time.Now()
	kept := 0 // frames drawn from an up to date kept layer
	// clocked: a still fades in by the wall clock, so a frame and the
	// frame drawn whole after it may fall either side of a step of the
	// fade; such a frame is drawn again until both agree
	var c, want *gfx.Canvas
	frame := func(what string, clocked bool) {
		t.Helper()
		if !canvasSizeIs(c, w, h) {
			c, want = gfx.NewCanvas(w, h), gfx.NewCanvas(w, h)
		}
		for try := 0; ; try++ {
			c.Fill(0, 0, w, h, 0x00ff00) // nothing of an earlier frame shows through
			s.Draw(c, now)
			seasonWhole(want, s, now)
			if bytes.Equal(c.Pix, want.Pix) {
				break
			}
			if !clocked || try == 20 {
				for i := range c.Pix {
					if c.Pix[i] != want.Pix[i] {
						o := i &^ 3
						t.Fatalf("%s: pixel %d,%d is %v, drawn whole %v", what, o/4%w, o/4/w, c.Pix[o:o+3], want.Pix[o:o+3])
					}
				}
			}
		}
		if s.kept != nil && s.keptPage.page == s.page && s.keptPage.gen == s.pageGen &&
			s.focused() != nil && s.keptEp == epKeyOf(s.focused()) {
			kept++
		}
		now = now.Add(transitionFrame)
	}
	frames := func(what string, n int) {
		t.Helper()
		for i := 0; i < n; i++ {
			frame(what, false)
		}
	}
	frames("entry slide", transitionSteps+4)
	dir := input.Right
	glide := func(what string, steps int) {
		t.Helper()
		for i := 0; i < steps; i++ {
			holdKey(s, &dir, now)
			frames(what, 8)
		}
		s.Key(input.Event{Key: dir, Release: true}, now)
		frames(what+", settling", 12)
	}
	glide("glide", 4)

	// the logo lands: the page fades to it and the logo dissolves in
	putArt(a, seasonLogoReq, artPattern(220, 50, 0x33, true), long)
	frames("logo landing", 20)
	before := kept
	glide("glide with the logo", 16) // to the end and back
	if kept-before < 16*8 {
		t.Fatalf("%d of the glide's frames drawn from the kept layer", kept-before)
	}

	// the actions: along the row (it scrolls), and back to the filmstrip
	s.Key(input.Event{Key: input.Down}, now)
	frames("actions", 3)
	for range s.actions {
		s.Key(input.Event{Key: input.Right}, now)
		frames("along the actions", 12)
	}
	s.Key(input.Event{Key: input.Left}, now)
	frames("back along the actions", 12)
	s.Key(input.Event{Key: input.Up}, now)
	frames("back to the filmstrip", 12)

	// the season picker in the header, and back
	s.Key(input.Event{Key: input.Up}, now)
	frames("picker", 16)
	s.Key(input.Event{Key: input.Down}, now)
	frames("picker left", 16)

	// a still not there yet, then landing and fading in
	next := s.eps[s.cur+2]
	r := artReq{thumb: next.Thumb, w: StillW, h: StillH}
	a.Art.mu.Lock()
	delete(a.Art.have, r.key())
	a.Art.mu.Unlock()
	delete(s.thumbs, next.Thumb)
	dir = input.Right
	holdKey(s, &dir, now)
	frames("a still on its way", 12)
	putArt(a, r, artPattern(StillW, StillH, 0x42, false), time.Now())
	for end := time.Now().Add(FadeIn + 50*time.Millisecond); time.Now().Before(end); {
		frame("a still fading in", true)
	}
	frames("a still landed", 4)

	// the whole row fading in, as when the season changes
	s.epAt = now
	frames("the row fading in", 12)

	// a mark, the season's facts refreshed, a start
	s.focused().ViewCount = 1
	s.rebuild()
	frames("marked", 3)
	s.seasons[s.si].Viewed++
	s.pageKey = ""
	frames("season facts", 16)
	// refreshed while the picker shows: the page is composed again in
	// place, ready for the way back
	s.seasons[s.si].Viewed++
	s.pageKey = ""
	s.prime(now)
	frames("season facts, primed", 4)
	a.Starting = now
	frames("starting", 6)
	a.Starting = time.Time{}
	frames("started", 3)

	// a 16:9 display's wider canvas
	w = 960
	frames("wide", 16)
	glide("wide glide", 3)
	if s.kept.W != 960 {
		t.Fatal("the kept layer was not made again for the wider canvas")
	}
}

// BenchmarkSeasonGlide is a frame of the filmstrip gliding along the
// episodes with Right (then Left) held: a frame every field and a step
// every repeat. Step is the frame of a step alone, a new episode's details.
func BenchmarkSeasonGlide(b *testing.B) {
	for _, w := range []int{720, 960} {
		for _, every := range []int{0, 1} {
			name := itoa(w)
			if every == 1 {
				name += "/step"
			}
			b.Run(name, func(b *testing.B) {
				s := seasonFixture(b)
				c := gfx.NewCanvas(w, 480)
				now := time.Now()
				s.Draw(c, now)
				dir := input.Right
				next := now
				b.ReportAllocs()
				b.ResetTimer()
				for i := 0; i < b.N; i++ {
					at := now.Add(time.Duration(i) * transitionFrame)
					if every == 1 {
						holdKey(s, &dir, at)
					} else if !at.Before(next) {
						holdKey(s, &dir, at)
						next = next.Add(RepeatDur)
					}
					s.Draw(c, at)
				}
			})
		}
	}
}
