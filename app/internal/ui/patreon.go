package ui

import (
	"time"

	"plexcrt/internal/beta"
	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/updates"
)

// Patreon is the menu's last entry. It tells everyone else what supporting
// gets them and where, and thanks a supporter: a beta build whose code has
// been entered. Beta access and the list of supporters live here.
type Patreon struct {
	app *App
	cur int
}

func NewPatreon(a *App) *Patreon { return &Patreon{app: a} }

// supporter reports that this is a beta build its code has unlocked.
func (a *App) supporter() bool {
	return beta.IsBeta() && beta.Check(a.betaDir()) == nil
}

// earlyAccess is the early-access version on offer, from the last catalogue
// check: only one newer than this build. The catalogue keeps a beta after
// it has become the public release, and offering that would be a step
// back. Empty when there is none or no check has come back yet.
func (a *App) earlyAccess() string {
	if r, ok := a.updates.catalogue.Releases["beta"]; ok {
		if newer, ok := updates.Compare(r.Version, a.Version); ok && newer > 0 {
			return r.Version
		}
	}
	return ""
}

func (p *Patreon) rows() []option {
	a := p.app
	var rows []option
	if beta.IsBeta() {
		rows = append(rows, option{label: "Beta access", val: func() string {
			switch beta.Check(a.betaDir()) {
			case nil:
				return "Unlocked"
			case beta.ErrLocked:
				return "Locked"
			default:
				return "Build error"
			}
		}, do: a.chooseBetaAccess})
	} else if a.earlyAccess() != "" {
		// a public build installs early access, code and all, from Updates
		rows = append(rows, option{label: "See early access in Updates", do: func() { a.Push(NewUpdates(a)) }})
	}
	rows = append(rows, option{label: "MisterZine code", val: func() string { return a.Access().Short() }, do: func() { a.Push(NewCodeEntry(a, nil)) }})
	if s := a.supporters.list; len(s.Current)+len(s.Past) > 0 {
		label := "Supporters"
		if n := len(s.Current); n > 0 {
			label = "Our " + itoa(n) + " supporters"
		}
		rows = append(rows, option{label: label, do: func() { a.Push(NewSupportersPage(a)) }})
	}
	return rows
}

func (p *Patreon) Key(ev input.Event, now time.Time) {
	if ev.Release {
		return
	}
	rows := p.rows()
	switch ev.Key {
	case input.Up:
		p.cur = max(0, p.cur-1)
	case input.Down:
		p.cur = max(0, min(len(rows)-1, p.cur+1))
	case input.Enter:
		if !ev.Repeat && p.cur < len(rows) {
			rows[p.cur].do()
		}
	}
}

func (p *Patreon) Draw(c *gfx.Canvas, now time.Time) bool {
	c.Fill(0, 0, c.W, c.H, gfx.Bg)
	a := p.app
	f := a.F
	a.text(c, MenuX, SafeY, f.Title, gfx.White, "Patreon")
	headline := "Get new versions first"
	para := "Patreon members get each new version of MisterZine Plex Core early, before its free public release. Membership pays for the work on the next one."
	supporter := a.supporter()
	if supporter {
		headline = "Thank you for your support"
		para = "Your membership gets you each new version first and pays for the work on the next one."
	}
	y := 88
	a.text(c, MenuX, y, f.Big, gfx.White, headline)
	y += f.Big.Height() + 10
	for _, line := range wrapAll(f.Body, para, MenuWidth) {
		a.text(c, MenuX, y, f.Body, gfx.GreyHi, line)
		y += 26
	}
	if v := a.earlyAccess(); v != "" && !supporter {
		y += 6
		label := "In early access now: "
		a.text(c, MenuX, y, f.SmallBold, gfx.GreyLo, label)
		a.text(c, MenuX+f.SmallBold.Width(label), y, f.SmallBold, gfx.Amber, f.SmallBold.Fit(v, MenuWidth-f.SmallBold.Width(label)))
	}
	// the address and the rows keep their places whichever text is above
	a.text(c, MenuX, 270, f.Big, gfx.Purple, patreonAddress)
	y = 350
	rows := p.rows()
	p.cur = min(p.cur, max(0, len(rows)-1)) // the supporters row comes and goes with the list
	for i, it := range rows {
		col := gfx.GreyHi
		if i == p.cur {
			col = gfx.White
			menuFocusBar(c, MenuX, y, f.Body.Height())
		}
		labelW := MenuWidth
		if it.val != nil {
			v := it.val()
			labelW -= f.Body.Width(v) + 24
			a.textRight(c, MenuRight, y, f.Body, gfx.Amber, v)
		}
		a.text(c, MenuX, y, f.Body, col, f.Body.Fit(it.label, labelW))
		y += MenuRowH
	}
	return false
}

// SupportersPage lists the Patreon supporters, current then past, two names
// to a line. Nothing on it is chosen: Up/Down scroll a line, Left/Right a
// page, and the scrollbar shows where the list is.
type SupportersPage struct {
	app *App
	top int // the first line in view
}

func NewSupportersPage(a *App) *SupportersPage { return &SupportersPage{app: a} }

const (
	creditsY0    = ListY0 + 44
	creditsPitch = 28
	creditsRows  = (SafeBottom - creditsY0) / creditsPitch
)

// creditLine is a group's heading, a line of up to two names, or a gap.
type creditLine struct {
	heading string
	names   []string
}

func (a *App) creditLines() []creditLine {
	var lines []creditLine
	group := func(heading string, list []Supporter) {
		if len(list) == 0 {
			return
		}
		if len(lines) > 0 {
			lines = append(lines, creditLine{})
		}
		lines = append(lines, creditLine{heading: heading})
		for i := 0; i < len(list); i += 2 {
			l := creditLine{names: []string{list[i].Name}}
			if i+1 < len(list) {
				l.names = append(l.names, list[i+1].Name)
			}
			lines = append(lines, l)
		}
	}
	group("Patreon supporters", a.supporters.list.Current)
	group("Past supporters", a.supporters.list.Past)
	return lines
}

func (s *SupportersPage) Key(ev input.Event, now time.Time) {
	if ev.Release {
		return
	}
	switch ev.Key {
	case input.Up:
		s.top--
	case input.Down:
		s.top++
	case input.Left:
		s.top -= creditsRows - 1
	case input.Right:
		s.top += creditsRows - 1
	}
	s.top = max(0, min(s.top, len(s.app.creditLines())-creditsRows))
}

func (s *SupportersPage) Draw(c *gfx.Canvas, now time.Time) bool {
	c.Fill(0, 0, c.W, c.H, gfx.Bg)
	a := s.app
	f := a.F
	a.text(c, MenuX, SafeY, f.Title, gfx.White, "Supporters")
	a.text(c, MenuX, ListY0, f.Body, gfx.GreyHi, f.Body.Fit("Thank you to everyone who supports MisterZine on Patreon.", MenuWidth))
	lines := a.creditLines()
	s.top = max(0, min(s.top, len(lines)-creditsRows)) // the list can change while open
	colW := MenuWidth / 2
	for i := 0; i < creditsRows && s.top+i < len(lines); i++ {
		l, y := lines[s.top+i], creditsY0+i*creditsPitch
		if l.heading != "" {
			a.text(c, MenuX, y+3, f.SmallBold, gfx.Purple, l.heading)
		}
		for j, name := range l.names {
			a.text(c, MenuX+j*colW, y, f.Body, gfx.GreyHi, f.Body.Fit(name, colW-24))
		}
	}
	menuScrollbar(c, creditsY0, (creditsRows-1)*creditsPitch+f.Body.Height(), s.top, creditsRows, len(lines))
	return false
}
