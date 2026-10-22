package ui

import (
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
)

// Chooser is a pop-over list: the screen beneath dims, a panel down the
// left lists the choices with the current one ticked. The panel widens
// for long names, and a name that still does not fit wraps to a second
// line. OK picks, Back leaves things as they were.
type Chooser struct {
	app     *App
	under   Screen
	title   string
	items   []string
	lines   [][]string
	cur     int
	current int // the one in force now (-1: none)
	pick    func(i int)
	back    *gfx.Image  // the screen beneath, dimmed
	snap    *gfx.Canvas // back's pixels; it and page are spares, given back on leaving
	page    *gfx.Canvas
	key     int
	width   int
}

const (
	ChooserMinW = 400
	ChooserPad  = 60 // right of the text: the tick and air
	ChooserLine = 26
	ChooserRowH = MenuRowH
)

// NewChooser composes the list over a snapshot of the screen beneath.
func NewChooser(app *App, under Screen, title string, items []string, current int, pick func(int)) *Chooser {
	ch := &Chooser{app: app, under: under, title: title, items: items, cur: max(current, 0), current: current, pick: pick, key: -1}
	f := app.F.Body
	ch.width = ChooserMinW
	for _, s := range items {
		if w := MenuX + f.Width(s) + ChooserPad; w > ch.width {
			ch.width = w
		}
	}
	if ch.width > MenuRight {
		ch.width = MenuRight
	}
	for _, s := range items {
		ch.lines = append(ch.lines, wrap(f, s, ch.width-MenuX-ChooserPad, 2))
	}
	w, h := layoutCanvasSize(app)
	ch.prepare(w, h, time.Now())
	return ch
}

// prepare snapshots the screen beneath, dimmed as behind the menu, into
// spare canvases.
func (ch *Chooser) prepare(w, h int, now time.Time) {
	ch.left()
	ch.snap = dimmedSnapshot(ch.under, w, h, now)
	ch.back = &gfx.Image{W: w, H: h, Pix: ch.snap.Pix}
	ch.page = gfx.TakeCanvas(w, h)
	ch.key = -1
}

// left gives the canvases back once the chooser is off the stack.
func (ch *Chooser) left() {
	gfx.GiveCanvas(ch.snap)
	gfx.GiveCanvas(ch.page)
	ch.snap, ch.page, ch.back = nil, nil, nil
}

// Key: Up/Down move, OK picks and closes, Left/Right close.
func (ch *Chooser) Key(ev input.Event, now time.Time) {
	if ev.Release {
		return
	}
	switch ev.Key {
	case input.Up:
		if ch.cur > 0 {
			ch.cur--
		}
	case input.Down:
		if ch.cur < len(ch.items)-1 {
			ch.cur++
		}
	case input.Left, input.Right:
		if !ev.Repeat {
			ch.app.Pop()
		}
	case input.Enter:
		ch.app.Pop()
		ch.pick(ch.cur)
	}
}

// Draw copies the composed page in, recomposing it when the cursor moved.
func (ch *Chooser) Draw(c *gfx.Canvas, now time.Time) bool {
	if ch.page.W != c.W || ch.page.H != c.H {
		ch.prepare(c.W, c.H, now)
	}
	if ch.key != ch.cur {
		ch.compose()
		ch.key = ch.cur
	}
	c.Copy(ch.page)
	return false
}

// tick draws a check mark on its own, centred on cx,cy.
func tick(c *gfx.Canvas, cx, cy int, col gfx.Color) {
	for i := 0; i < 4; i++ {
		c.Fill(cx-7+i, cy-1+i, 3, 3, col)
	}
	for i := 0; i < 8; i++ {
		c.Fill(cx-3+i, cy+2-i, 3, 3, col)
	}
}

func (ch *Chooser) rowH(i int) int {
	return ChooserRowH + (len(ch.lines[i])-1)*ChooserLine
}

func (ch *Chooser) compose() {
	c := ch.page
	c.Blit(0, 0, ch.back)
	c.Fill(0, 0, ch.width, c.H, gfx.Bg)
	f := ch.app.F
	c.Text(MenuX, SafeY, f.Title, gfx.Grey, ch.title)
	// scroll so the cursor's row is in view
	first := 0
	for {
		h := 0
		for i := first; i <= ch.cur; i++ {
			h += ch.rowH(i)
		}
		if ListY0+8+h <= SafeBottom || first == ch.cur {
			break
		}
		first++
	}
	y := ListY0 + 8
	for i := first; i < len(ch.items); i++ {
		if y+ch.rowH(i) > SafeBottom+8 {
			break
		}
		col := gfx.GreyHi
		if i == ch.cur {
			col = gfx.White
			menuFocusBar(c, MenuX, y, f.Body.Height()+(len(ch.lines[i])-1)*ChooserLine)
		}
		ly := y
		for _, line := range ch.lines[i] {
			c.Text(MenuX, ly, f.Body, col, line)
			ly += ChooserLine
		}
		if i == ch.current {
			tick(c, ch.width-40, y+f.Body.Height()/2, gfx.GreyHi)
		}
		y += ch.rowH(i)
	}
}
