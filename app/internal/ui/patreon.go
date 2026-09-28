package ui

import (
	"time"

	"plexcrt/internal/beta"
	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
)

// Patreon is the menu's last entry. It tells everyone else what supporting
// gets them and where, and thanks a supporter: a beta build whose code has
// been entered. Beta access lives here.
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
// check; empty when there is none or no check has come back yet.
func (a *App) earlyAccess() string {
	if r, ok := a.updates.catalogue.Releases["beta"]; ok {
		return r.Version
	}
	return ""
}

func (p *Patreon) rows() []option {
	a := p.app
	if beta.IsBeta() {
		return []option{{label: "Beta access", val: func() string {
			switch beta.Check(a.betaDir()) {
			case nil:
				return "Unlocked"
			case beta.ErrLocked:
				return "Locked"
			default:
				return "Build error"
			}
		}, do: a.chooseBetaAccess}}
	}
	if a.earlyAccess() != "" {
		// a public build installs early access, code and all, from Updates
		return []option{{label: "See early access in Updates", do: func() { a.Push(NewUpdates(a)) }}}
	}
	return nil
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
	for i, it := range p.rows() {
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
