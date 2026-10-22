package ui

import (
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/plex"
)

// List is a vertical list of items with the focused one's poster and a
// few lines about it on the right: libraries, a show's seasons, a season's
// episodes.
type List struct {
	app   *App
	title string
	items []*plex.Item
	cur   int
	top   Anim // scroll in rows
	enter func(it *plex.Item, play bool)
	art   string // poster for the whole list (a season's show), if any
	err   error
}

const (
	ListRows  = 8
	ListRowH  = 44
	ListY0    = SafeY + 40
	ListW     = 380
	ListSideX = 440
)

// NewList makes a list screen.
func NewList(app *App, title string, items []*plex.Item, enter func(*plex.Item, bool)) *List {
	return &List{app: app, title: title, items: items, enter: enter}
}

// Key handles one input event.
func (l *List) Key(ev input.Event, now time.Time) {
	n := len(l.items)
	if ev.Release {
		l.top.Settle(now)
		return
	}
	switch ev.Key {
	case input.Up:
		if l.cur > 0 {
			l.cur--
		}
	case input.Down:
		if l.cur < n-1 {
			l.cur++
		}
	case input.Left, input.JumpBack:
		l.cur -= ListRows
		if l.cur < 0 {
			l.cur = 0
		}
	case input.Right, input.JumpFwd:
		l.cur += ListRows
		if l.cur > n-1 {
			l.cur = n - 1
		}
	case input.Enter:
		if l.cur < n && l.enter != nil {
			l.enter(l.items[l.cur], false)
		}
	}
	first := round(l.top.Target())
	if l.cur < first {
		first = l.cur
	} else if l.cur >= first+ListRows {
		first = l.cur - ListRows + 1
	}
	l.top.Move(float64(first), now, ev.Repeat)
}

// Draw paints the list.
func (l *List) Draw(c *gfx.Canvas, now time.Time) bool {
	c.Fill(0, 0, c.W, c.H, gfx.Bg)
	f := l.app.F
	l.app.text(c, SafeX, SafeY, f.Title, gfx.Grey, l.title)
	if len(l.items) == 0 {
		l.app.text(c, SafeX, ListY0, f.Body, gfx.GreyLo, "Nothing here.")
		return false
	}
	off := l.top.At(now)
	for i, it := range l.items {
		y := ListY0 + round((float64(i)-off)*ListRowH)
		if y+ListRowH < ListY0 || y > c.H {
			continue
		}
		col := gfx.GreyHi
		if it.ViewCount > 0 && it.Playable() {
			col = gfx.GreyLo
		}
		if i == l.cur {
			col = gfx.White
			focusBar(c, SafeX, y+9, f.Body.Height())
		}
		l.app.textOn(c, SafeX, y+9, f.Body, col, gfx.Bg, f.Body.Fit(it.Label(), ListW-8))
		if it.ViewOffset > 0 && it.Duration > 0 {
			c.Fill(SafeX+4, y+ListRowH-10, ListW-8, PillH, 0x404040)
			c.Fill(SafeX+4, y+ListRowH-10, (ListW-8)*it.ViewOffset/it.Duration, PillH, gfx.Amber)
		}
	}
	c.Fill(0, 0, c.W, ListY0-4, gfx.Bg)
	l.app.text(c, SafeX, SafeY, f.Title, gfx.Grey, l.title)
	c.Fill(0, c.H-SafeY, c.W, SafeY, gfx.Bg)
	// side panel: poster and details of the focused item
	it := l.items[l.cur]
	thumb := it.Thumb
	if thumb == "" {
		thumb = l.art
	}
	y := ListY0
	if thumb != "" {
		if img := l.app.Art.Get(thumb, PosterW, PosterH); img != nil {
			c.Blit(ListSideX, ListY0, img)
		} else {
			c.Fill(ListSideX, ListY0, PosterW, PosterH, gfx.Bar)
		}
		y += PosterH + 12
	}
	if it.Year > 0 || it.Duration > 0 {
		s := ""
		if it.Year > 0 {
			s = itoa(it.Year)
		}
		if it.Duration > 0 {
			if s != "" {
				s += "   "
			}
			s += hm(it.Duration)
		}
		l.app.text(c, ListSideX, y, f.Small, gfx.GreyLo, s)
		y += f.Small.Height() + 2
	}
	if it.ViewOffset > 0 {
		l.app.text(c, ListSideX, y, f.Small, gfx.Amber, "Resume at "+clock(it.ViewOffset))
		y += f.Small.Height() + 2
	}
	for _, line := range wrapped(f.Small, it.Summary, SafeX+SafeW-ListSideX, 6) {
		if y+f.Small.Height() > c.H-SafeY {
			break
		}
		l.app.text(c, ListSideX, y, f.Small, gfx.GreyLo, line)
		y += f.Small.Height()
	}
	return l.top.Running(now)
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var b [12]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		b[i] = '-'
	}
	return string(b[i:])
}

// clock formats seconds as h:mm:ss or m:ss.
func clock(sec int) string {
	h, m, s := sec/3600, sec%3600/60, sec%60
	if h > 0 {
		return itoa(h) + ":" + pad2(m) + ":" + pad2(s)
	}
	return itoa(m) + ":" + pad2(s)
}

func pad2(n int) string {
	if n < 10 {
		return "0" + itoa(n)
	}
	return itoa(n)
}
