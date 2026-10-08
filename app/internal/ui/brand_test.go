package ui

import (
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"plexcrt/internal/beta"
	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/plex"
	"plexcrt/internal/updates"
)

// plainRows counts a mark's rows (or columns) of bare fill on each side of
// its letters.
func plainRows(im *gfx.Image, fill gfx.Color, columns bool) (before, after int) {
	n, m := im.H, im.W
	if columns {
		n, m = im.W, im.H
	}
	plain := func(i int) bool {
		for j := 0; j < m; j++ {
			x, y := j, i
			if columns {
				x, y = i, j
			}
			o := (y*im.W + x) * 4
			if gfx.Color(uint32(im.Pix[o+2])<<16|uint32(im.Pix[o+1])<<8|uint32(im.Pix[o])) != fill {
				return false
			}
		}
		return true
	}
	for before < n && plain(before) {
		before++
	}
	for after < n && plain(n-1-after) {
		after++
	}
	return before, after
}

func TestMarksAreCentredOnTheirLetters(t *testing.T) {
	a := &App{}
	for _, m := range []brandMark{{"BETA", gfx.Amber}, {"UPDATE", gfx.Purple}} {
		im := a.mark(m.text, m.fill)
		if im.H != betaBadgeH {
			t.Errorf("%s is %d px high, not %d", m.text, im.H, betaBadgeH)
		}
		above, below := plainRows(im, m.fill, false)
		if above-below > 1 || below-above > 1 {
			t.Errorf("%s: %d plain rows above the letters, %d below", m.text, above, below)
		}
		left, right := plainRows(im, m.fill, true)
		if left-right > 1 || right-left > 1 {
			t.Errorf("%s: %d plain columns left of the letters, %d right", m.text, left, right)
		}
	}
	if im := a.mark("BETA", gfx.Amber); im.W != betaBadgeW {
		t.Errorf("BETA is %d px wide, not %d", im.W, betaBadgeW)
	}
}

func TestUpdateMarkShowsOnHome(t *testing.T) {
	a := betaTestApp(t)
	marks := func() string {
		var s []string
		for _, m := range a.brandMarks() {
			s = append(s, m.text)
		}
		return strings.Join(s, " ")
	}
	a.stack = []Screen{&Home{}}
	if got := marks(); got != "BETA" {
		t.Fatalf("no update: %q", got)
	}
	r := updates.Release{ID: "next", Version: "0.3.0-beta.1", Channel: "beta"}
	a.updates.catalogue = updates.Catalogue{Schema: 1, Releases: map[string]updates.Release{"beta": r}}
	if got := marks(); got != "BETA UPDATE" {
		t.Fatalf("an update on Home: %q", got)
	}
	a.stack = append(a.stack, &Options{app: a})
	if got := marks(); got != "BETA" {
		t.Fatalf("an update behind Options: %q", got)
	}
	a.stack = a.stack[:1]
	beta.Channel = "public" // betaTestApp puts it back
	a.updates.catalogue.Releases = map[string]updates.Release{"public": {ID: "pub", Version: "0.3.0", Channel: "public"}}
	if got := marks(); got != "UPDATE" {
		t.Fatalf("a public build with an update: %q", got)
	}
	a.updates.catalogue.Releases = map[string]updates.Release{"beta": {ID: "next", Version: "0.3.0-beta.1", Channel: "beta"}}
	if got := marks(); got != "" {
		t.Fatalf("a beta on a public build with beta notifications off: %q", got)
	}
	a.updates.status = updates.Status{Stage: "ready", Release: &updates.Release{ID: "next", Version: "0.3.0-beta.1", Channel: "beta"}}
	if got := marks(); got != "UPDATE" {
		t.Fatalf("an update downloaded but not installed: %q", got)
	}
}

// composeHome puts a Home with one film on the stack and composes its page
// with no backdrop, as a frame has it before the brand marks go over it.
func composeHome(a *App) *gfx.Canvas {
	it := &plex.Item{RatingKey: "1", Title: "A film", Type: "movie", Year: 1999}
	h := &Home{app: a, home: true, hubs: []*plex.Hub{{Title: "Recently Added", Items: []*plex.Item{it}}}, col: []int{0}}
	a.stack = []Screen{h}
	c := gfx.NewCanvas(720, 480)
	h.compose(c, it, nil, nil, false)
	return c
}

// wordmarkInk reports whether anything but the background is drawn where
// Home's wordmark goes: the chevron before it, the lettering and its shadow.
func wordmarkInk(a *App, c *gfx.Canvas) bool {
	for y := max(0, SafeY-8-markPad); y < SafeY-8+a.Mark.H+markPad; y++ {
		for x := SafeX; x < SafeX+16+a.Mark.W+markPad; x++ {
			o := (y*c.W + x) * 4
			if gfx.Color(uint32(c.Pix[o+2])<<16|uint32(c.Pix[o+1])<<8|uint32(c.Pix[o])) != gfx.Bg {
				return true
			}
		}
	}
	return false
}

// markAt reports whether the canvas holds im with its top-left at x, y.
func markAt(c *gfx.Canvas, im *gfx.Image, x, y int) bool {
	for j := 0; j < im.H; j++ {
		for i := 0; i < im.W; i++ {
			o, p := ((y+j)*c.W+x+i)*4, (j*im.W+i)*4
			if c.Pix[o] != im.Pix[p] || c.Pix[o+1] != im.Pix[p+1] || c.Pix[o+2] != im.Pix[p+2] {
				return false
			}
		}
	}
	return true
}

func TestHomeDrawsItsWordmarkWithTheMarksBesideIt(t *testing.T) {
	a := betaTestApp(t)
	c := composeHome(a)
	if !wordmarkInk(a, c) {
		t.Fatal("Home composed without its wordmark")
	}
	a.drawBrand(c)
	if !markAt(c, a.mark("BETA", gfx.Amber), SafeX+16+a.Mark.W+12, SafeY) {
		t.Fatal("the BETA mark is not beside the wordmark")
	}
}

func TestScrubRunTopsOutAtTheSecondSpeed(t *testing.T) {
	t0 := time.Now()
	p := &Playing{heldAt: t0}
	for _, c := range []struct {
		after time.Duration
		speed int
	}{{10 * time.Millisecond, 1}, {600 * time.Millisecond, 2}, {5 * time.Second, 2}} {
		if got := p.runSpeed(t0.Add(ScrubHold + c.after)); got != c.speed {
			t.Errorf("%v into the run: %d px per field, want %d", c.after, got, c.speed)
		}
	}
}

func TestMenuEndsWithExitThenPatreon(t *testing.T) {
	a := betaTestApp(t)
	a.secs = []plex.Section{{Key: "1", Title: "Films", Type: "movie"}}
	items, _ := a.menuItems()
	n := len(items)
	if items[n-3].Type != "options" || items[n-2].Type != "exit" || items[n-2].Title != "Exit to MiSTer menu" || items[n-1].Type != "patreon" {
		t.Fatalf("menu ends %q, %q, %q", items[n-3].Title, items[n-2].Title, items[n-1].Title)
	}
	a.MenuPick(nil, items[n-1])
	if _, ok := a.top().(*Patreon); !ok || a.ToMenu {
		t.Fatalf("Patreon opened %T", a.top())
	}
	a.MenuPick(nil, items[n-2])
	if !a.ToMenu {
		t.Fatal("Exit did not ask for the MiSTer menu")
	}
}

func TestOptionsHoldExitWhileSignedOut(t *testing.T) {
	a := betaTestApp(t)
	o := &Options{app: a}
	find := func() int {
		for i, it := range o.items() {
			if it.label == "Exit to MiSTer menu" {
				return i
			}
		}
		return -1
	}
	a.Plex = &plex.Client{}
	if find() >= 0 {
		t.Fatal("Exit in Options while the menu holds it")
	}
	a.Plex = nil // signed out: Back from the sign-in screen opens Options
	i := find()
	if items := o.items(); i < 0 || items[i+1].label != "Patreon" || items[len(items)-1].label != "Version" {
		t.Fatalf("Exit at %d, then Patreon; Version must stay last", i)
	}
	o.cur = i
	o.Key(input.Event{Key: input.Enter}, time.Now())
	if !a.ToMenu {
		t.Fatal("Exit in Options did not ask for the MiSTer menu")
	}
}

// exitScreen asks for the MiSTer menu on any press, and counts its frames.
type exitScreen struct {
	app    *App
	frames int
}

func (s *exitScreen) Key(ev input.Event, now time.Time)      { s.app.ToMenu = true }
func (s *exitScreen) Draw(c *gfx.Canvas, now time.Time) bool { s.frames++; return false }

func TestRunReturnsOnExitBeforeDrawing(t *testing.T) {
	a := betaTestApp(t)
	a.Out = &fakeOut{c: gfx.NewCanvas(720, 480)}
	a.Wake, a.Connected, a.later = make(chan struct{}, 1), make(chan struct{}), make(chan func(), 8)
	s := &exitScreen{app: a}
	a.stack = []Screen{s}
	events := make(chan input.Event, 1)
	events <- input.Event{Key: input.Enter}
	done := make(chan struct{})
	go func() { a.Run(events, make(chan struct{})); close(done) }()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Run went on after Exit")
	}
	if s.frames != 0 {
		t.Fatalf("%d frames drawn after Exit", s.frames)
	}
}

// Optional previews of Home's header: BRAND_PREVIEW_DIR=dir go test -run BrandPreview
func TestBrandPreview(t *testing.T) {
	dir := os.Getenv("BRAND_PREVIEW_DIR")
	if dir == "" {
		t.Skip("set BRAND_PREVIEW_DIR to render previews")
	}
	a := betaTestApp(t)
	a.stack = []Screen{&Home{}}
	render := func(name string) {
		c := gfx.NewCanvas(720, 480)
		c.Fill(0, 0, c.W, c.H, gfx.Bar)
		chevronLeft(c, SafeX+3, SafeY-8+a.Mark.H*60/100-6, gfx.GreyLo)
		a.Mark.Place(c, SafeX+16, SafeY-8)
		a.drawBrand(c)
		// the header, three times over so single pixels show
		const x0, y0, w, h, k = 40, 20, 300, 50, 3
		out := image.NewRGBA(image.Rect(0, 0, w*k, h*k))
		for y := 0; y < h*k; y++ {
			for x := 0; x < w*k; x++ {
				i := ((y0+y/k)*c.W + x0 + x/k) * 4
				out.SetRGBA(x, y, color.RGBA{c.Pix[i+2], c.Pix[i+1], c.Pix[i], 255})
			}
		}
		f, err := os.Create(filepath.Join(dir, name+".png"))
		if err != nil {
			t.Fatal(err)
		}
		defer f.Close()
		if err := png.Encode(f, out); err != nil {
			t.Fatal(err)
		}
	}
	render("home-beta")
	a.updates.catalogue = updates.Catalogue{Schema: 1, Releases: map[string]updates.Release{"beta": {ID: "next", Version: "0.3.0-beta.1", Channel: "beta"}}}
	render("home-beta-update")
	beta.Channel = "public"
	a.updates.catalogue.Releases = map[string]updates.Release{"public": {ID: "pub", Version: "0.3.0", Channel: "public"}}
	render("home-public-update")
}

type fakeOut struct{ c *gfx.Canvas }

func (f *fakeOut) Begin() *gfx.Canvas                   { return f.c }
func (f *fakeOut) End()                                 {}
func (f *fakeOut) WaitField(time.Duration)              {}
func (f *fakeOut) Missed() bool                         { return false }
func (f *fakeOut) Foreign() bool                        { return false }
func (f *fakeOut) Late() (time.Duration, time.Duration) { return 0, 0 }
