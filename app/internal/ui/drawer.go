package ui

import (
	"math"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/plex"
	"plexcrt/internal/updates"
)

// Drawer is the menu: a panel that slides in down the left over the home
// screen, which shows dimmed behind it. Home, the libraries, Options, Exit,
// Patreon.
type Drawer struct {
	app       *App
	under     Screen
	items     []*plex.Item
	cur       int
	first     int         // the first row shown: the list scrolls when it outgrows the panel
	back      *gfx.Image  // the home screen, dimmed
	snap      *gfx.Canvas // back's pixels: a spare frame, given back when the drawer goes
	page      *gfx.Canvas // the drawer panel, composed only when selection changes
	key       string      // what the page was composed for
	openAt    time.Time
	closeAt   time.Time // set while sliding out; Pop follows
	closeFrom int
	animating bool
	then      func() // runs once the drawer has slid out
}

const (
	DrawerW    = 324
	DrawerRowH = MenuRowH
	DrawerY0   = SafeY + 64
	// DrawerRows is how many entries fit above the version line at the foot.
	DrawerRows = (SafeBottom - 28 - DrawerY0) / DrawerRowH
	BackBright = 56 // of 256: the screen behind the menu or a chooser
)

// NewDrawer composes the menu over a snapshot of the screen beneath, with
// the entry at cur selected and in view.
func NewDrawer(app *App, under Screen, items []*plex.Item, cur int) *Drawer {
	d := &Drawer{app: app, under: under, items: items, animating: true}
	d.cur = max(0, min(len(items)-1, cur))
	d.scroll()
	w, h := layoutCanvasSize(app)
	d.prepare(w, h, time.Now())
	// Preparation must not consume the first part of the slide.
	d.openAt = time.Now()
	return d
}

// prepare snapshots the screen beneath, dimmed, and composes the panel,
// into spare canvases: nothing is allocated as the menu opens.
func (d *Drawer) prepare(w, h int, now time.Time) {
	d.left()
	d.snap = dimmedSnapshot(d.under, w, h, now)
	d.back = &gfx.Image{W: w, H: h, Pix: d.snap.Pix}
	d.page = gfx.TakeCanvas(DrawerW, h)
	d.compose()
	d.key = d.composeKey()
}

// left gives the canvases back once the drawer is off the stack.
func (d *Drawer) left() {
	gfx.GiveCanvas(d.snap)
	gfx.GiveCanvas(d.page)
	d.snap, d.page, d.back = nil, nil, nil
}

// dimmedSnapshot draws a screen into a spare frame and darkens it to
// BackBright in place, with the vectorized blend: the background of a
// pop-over. The caller gives the canvas back when it closes.
func dimmedSnapshot(under Screen, w, h int, now time.Time) *gfx.Canvas {
	snap := gfx.TakeCanvas(w, h)
	under.Draw(snap, now)
	snap.Darken(BackBright)
	return snap
}

// Close slides the drawer out, then runs then (after the Pop).
func (d *Drawer) Close(then func()) {
	if !d.closeAt.IsZero() {
		return
	}
	now := time.Now()
	d.closeFrom, _ = d.offset(now)
	d.closeAt = now
	d.animating = true
	d.then = then
}

// Back slides the drawer out.
func (d *Drawer) Back() bool {
	d.Close(nil)
	return true
}

// Key handles one input event: Up/Down choose, OK enters, Left/Right close.
func (d *Drawer) Key(ev input.Event, now time.Time) {
	if ev.Release || !d.closeAt.IsZero() {
		return
	}
	switch ev.Key {
	case input.Up:
		if d.cur > 0 {
			d.cur--
		}
	case input.Down:
		if d.cur < len(d.items)-1 {
			d.cur++
		}
	case input.Left, input.Right:
		if !ev.Repeat {
			d.Close(nil)
		}
	case input.Enter:
		d.app.MenuPick(d, d.items[d.cur])
	}
	d.scroll()
}

// scroll keeps the selection inside the window of rows that fit.
func (d *Drawer) scroll() {
	if d.cur < d.first {
		d.first = d.cur
	}
	if d.cur >= d.first+DrawerRows {
		d.first = d.cur - DrawerRows + 1
	}
	d.first = max(0, min(d.first, len(d.items)-DrawerRows))
}

func (d *Drawer) composeKey() string { return itoa(d.first) + ":" + itoa(d.cur) }

// offset is how far the panel still sits off the left edge.
func (d *Drawer) offset(now time.Time) (int, bool) {
	var p float64
	moving := false
	if !d.closeAt.IsZero() {
		p = float64(now.Sub(d.closeAt)) / float64(animDur)
		if p >= 1 {
			return -DrawerW, false
		}
		moving = true
		return d.closeFrom - round(float64(DrawerW+d.closeFrom)*math.Pow(max(0, p), 3)), true // ease in going out
	} else {
		p = float64(now.Sub(d.openAt)) / float64(animDur)
		if p >= 1 {
			p = 1
		} else {
			moving = true
		}
		p = 1 - math.Pow(1-p, 3) // ease out coming in
	}
	return -DrawerW + int(float64(DrawerW)*p+0.5), moving
}

// Draw slides the prepared panel, copying each output pixel just once.
func (d *Drawer) Draw(c *gfx.Canvas, now time.Time) bool {
	if d.back == nil || d.back.W != c.W || d.back.H != c.H || d.page.H != c.H {
		d.prepare(c.W, c.H, now)
	}
	off, moving := d.offset(now)
	d.animating = moving
	if !d.closeAt.IsZero() && !moving {
		// slid out: leave; the screen beneath draws the next frame
		then := d.then
		d.closeAt = time.Time{}
		d.app.Pop()
		if then != nil {
			then()
		}
		return d.app.top().Draw(c, now)
	}
	key := d.composeKey()
	if key != d.key {
		d.compose()
		d.key = key
	}
	edge := max(0, min(c.W, DrawerW+off))
	c.BlitClip(0, 0, d.back, edge, 0, c.W-edge, c.H)
	panel := gfx.Image{W: d.page.W, H: d.page.H, Pix: d.page.Pix}
	c.Blit(off, 0, &panel)
	return moving
}

func (d *Drawer) compose() {
	c := d.page
	c.Fill(0, 0, c.W, c.H, gfx.Bg)
	d.app.Mark.Place(c, MenuX, SafeY-8)
	if updates.Channel == "beta" {
		d.app.betaBadge(c, MenuX+d.app.Mark.W+12, SafeY)
		d.app.text(c, MenuX, SafeBottom-20, d.app.F.SmallBold, gfx.Amber, d.app.F.SmallBold.Fit(d.app.Version, DrawerW-MenuX-12))
	}
	f := d.app.F.Body
	y := DrawerY0
	last := min(len(d.items), d.first+DrawerRows)
	for i := d.first; i < last; i++ {
		it := d.items[i]
		col := gfx.GreyHi
		if it.Type == "patreon" {
			col = gfx.Purple // the app's Patreon colour, as on the address lines
		}
		if i == d.cur {
			col = gfx.White
			menuFocusBar(c, MenuX, y, f.Height())
		}
		title := it.Title
		if it.Type == "options" && d.app.updateAvailable() {
			// a badge: an update is waiting under Options
			disc(c, MenuX+f.Width(title)+14, y+f.Height()/2, 4, gfx.Amber)
		}
		if it.Type == "section" && d.app.Showcase {
			if section, ok := d.app.section(it.Key); ok {
				title = d.app.libraryLabel(section)
			} else {
				title = "Library"
			}
		}
		c.Text(MenuX, y, f, col, f.Fit(title, DrawerW-MenuX-24))
		y += DrawerRowH
	}
	// more entries above or below the window: a chevron at the edge
	cx := MenuX + (DrawerW-MenuX-24)/2
	if d.first > 0 {
		chevron(c, cx, DrawerY0-10, true, gfx.GreyLo)
	}
	if last < len(d.items) {
		chevron(c, cx, y+2, false, gfx.GreyLo)
	}
}
