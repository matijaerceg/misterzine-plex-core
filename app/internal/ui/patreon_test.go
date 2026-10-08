package ui

import (
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"testing"
	"time"

	"plexcrt/internal/beta"
	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/plex"
	"plexcrt/internal/updates"
)

func TestBetaAccessMovedFromOptionsToPatreon(t *testing.T) {
	a := betaTestApp(t)
	a.Plex = &plex.Client{}
	for _, it := range (&Options{app: a}).items() {
		if it.label == "Beta access" {
			t.Fatal("Beta access is still in Options")
		}
	}
	p := NewPatreon(a)
	a.Push(p)
	rows := p.rows()
	if len(rows) != 1 || rows[0].label != "Beta access" || rows[0].val() != "Locked" {
		t.Fatalf("Patreon rows on a locked beta: %+v", rows)
	}
	p.Key(input.Event{Key: input.Enter}, time.Now())
	if _, ok := a.top().(*Chooser); !ok {
		t.Fatalf("Beta access opened %T", a.top())
	}
}

func TestPatreonThanksOnlyAnUnlockedBeta(t *testing.T) {
	a := betaTestApp(t)
	if a.supporter() {
		t.Fatal("a locked beta counted as a supporter")
	}
	if err := beta.Current().Unlock(a.betaDir(), "012345"); err != nil {
		t.Fatal(err)
	}
	if !a.supporter() {
		t.Fatal("an unlocked beta is not thanked")
	}
	if got := NewPatreon(a).rows()[0].val(); got != "Unlocked" {
		t.Fatalf("Beta access reads %q", got)
	}
	beta.Channel = "public" // a public or development build plays without a code
	if a.supporter() {
		t.Fatal("a public build counted as a supporter")
	}
}

func TestPatreonOnAPublicBuildPointsAtUpdates(t *testing.T) {
	a := betaTestApp(t)
	beta.Channel = "public"
	t.Setenv("PLEXCRT_CATALOGUE_FILE", filepath.Join(t.TempDir(), "missing.json")) // no network
	p := NewPatreon(a)
	// only the MisterZine code row, on every build
	if rows := p.rows(); len(rows) != 1 || rows[0].label != "MisterZine code" {
		t.Fatalf("rows without early access on offer: %+v", rows)
	}
	p.Key(input.Event{Key: input.Down}, time.Now())
	// the catalogue keeps the beta that became this public release: not on offer
	a.Version = "1.0.0"
	a.updates.catalogue = updates.Catalogue{Schema: 1, Releases: map[string]updates.Release{
		"public": {ID: "pub", Version: "1.0.0", Channel: "public"}, "beta": {ID: "old", Version: "1.0.0-beta.1", Channel: "beta"}}}
	if v, rows := a.earlyAccess(), p.rows(); v != "" || len(rows) != 1 {
		t.Fatalf("an older beta offered as %q, rows %+v", v, rows)
	}
	a.updates.catalogue.Releases["beta"] = updates.Release{ID: "next", Version: "1.1.0-beta.1", Channel: "beta"}
	if v := a.earlyAccess(); v != "1.1.0-beta.1" {
		t.Fatalf("a newer beta offered as %q", v)
	}
	a.Push(p)
	p.Key(input.Event{Key: input.Enter}, time.Now())
	if _, ok := a.top().(*Updates); !ok {
		t.Fatalf("early access opened %T", a.top())
	}
}

// barRows returns the first and last rows of the handle in the scrollbar's column.
func barRows(c *gfx.Canvas) (top, bottom int) {
	top, bottom = -1, -1
	for y := 0; y < c.H; y++ {
		o := (y*c.W + WallBarX) * 4
		if gfx.Color(uint32(c.Pix[o+2])<<16|uint32(c.Pix[o+1])<<8|uint32(c.Pix[o])) == gfx.GreyLo {
			if top < 0 {
				top = y
			}
			bottom = y
		}
	}
	return top, bottom
}

func TestOptionsScrollbarFollowsTheWindow(t *testing.T) {
	a := betaTestApp(t)
	a.Plex = &plex.Client{}
	o := &Options{app: a}
	n := len(o.items())
	if n <= 9 {
		t.Skipf("%d options fit without scrolling", n)
	}
	c := gfx.NewCanvas(720, 480)
	o.Draw(c, time.Now())
	top0, bottom0 := barRows(c)
	if top0 != ListY0+9 {
		t.Fatalf("handle starts at %d, want the first row's %d", top0, ListY0+9)
	}
	o.cur = n - 1
	o.Draw(c, time.Now())
	top1, bottom1 := barRows(c)
	if top1 <= top0 || bottom1-top1 != bottom0-top0 {
		t.Fatalf("handle at %d-%d, then %d-%d at the last row", top0, bottom0, top1, bottom1)
	}
	if want := ListY0 + 9 + 8*MenuRowH + a.F.Body.Height() - 1; bottom1 != want {
		t.Fatalf("handle ends at %d, want the last row's %d", bottom1, want)
	}
}

// Optional previews: PATREON_PREVIEW_DIR=dir go test -run PatreonPreview
func TestPatreonPreview(t *testing.T) {
	dir := os.Getenv("PATREON_PREVIEW_DIR")
	if dir == "" {
		t.Skip("set PATREON_PREVIEW_DIR to render previews")
	}
	a := betaTestApp(t)
	a.Plex = &plex.Client{}
	render := func(name string, s Screen) {
		c := gfx.NewCanvas(720, 480)
		for range 4 { // text arrives from the cache a frame or two later
			s.Draw(c, time.Now())
			time.Sleep(50 * time.Millisecond)
		}
		out := image.NewRGBA(image.Rect(0, 0, c.W, c.H))
		for y := 0; y < c.H; y++ {
			for x := 0; x < c.W; x++ {
				i := (y*c.W + x) * 4
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
	o := &Options{app: a}
	render("options-top", o)
	o.cur = len(o.items()) - 1
	render("options-bottom", o)
	a.updates.catalogue = updates.Catalogue{Schema: 1, Releases: map[string]updates.Release{"beta": {ID: "next", Version: "0.2.0-beta.14", Channel: "beta"}}}
	render("patreon-locked", NewPatreon(a))
	a.secs = []plex.Section{{Key: "1", Title: "Movies", Type: "movie"}, {Key: "2", Title: "TV Shows", Type: "show"}}
	items, _ := a.menuItems()
	a.stack = []Screen{&splashTestScreen{}}
	d := NewDrawer(a, a.stack[0], items, len(items)-1)
	d.openAt = time.Now().Add(-time.Second)
	render("drawer", d)
	d = NewDrawer(a, a.stack[0], items, len(items)-3)
	d.openAt = time.Now().Add(-time.Second)
	render("drawer-options", d)
	if err := beta.Current().Unlock(a.betaDir(), "012345"); err != nil {
		t.Fatal(err)
	}
	render("patreon-supporter", NewPatreon(a))
	// made-up names, as long as the longest on the site's list (21 letters)
	first := []string{"Alexandra", "Ben", "Casimir", "Dana", "Evangeline", "Finn", "Gwendolyn", "Hal"}
	last := []string{"Example", "Placeholder", "Sample", "Testington", "Fixture"}
	for i := 0; i < 39; i++ {
		a.supporters.list.Current = append(a.supporters.list.Current, Supporter{Name: first[i%len(first)] + " " + last[i%len(last)]})
	}
	a.supporters.list.Past = []Supporter{{Name: "Sam Sample"}, {Name: "Quinn Quartermaine-Ox"}}
	render("patreon-supporter-list", NewPatreon(a))
	sp := NewSupportersPage(a)
	render("supporters-top", sp)
	sp.top = len(a.creditLines()) - creditsRows
	render("supporters-end", sp)
	beta.Channel = "public"
	render("patreon-public", NewPatreon(a))
}
