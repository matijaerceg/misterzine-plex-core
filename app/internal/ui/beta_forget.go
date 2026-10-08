package ui

import (
	"time"

	"plexcrt/internal/access"
	"plexcrt/internal/beta"
	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
)

func (a *App) chooseBetaAccess() {
	items := []string{"Forget beta access", "Back"}
	locked := beta.Check(a.betaDir()) == beta.ErrLocked
	if locked {
		items = append([]string{"Enter beta code"}, items...)
	}
	a.Push(NewChooser(a, a.top(), "Beta access", items, -1, func(i int) {
		if locked && i == 0 {
			a.Push(NewBetaAccess(a, nil))
			return
		}
		if locked {
			i--
		}
		if i == 0 {
			a.Push(&ForgetBetaAccess{app: a})
		}
	}))
}

// ForgetBetaAccess defaults to Cancel so opening or holding OK cannot erase access.
type ForgetBetaAccess struct {
	app     *App
	confirm bool
}

func (s *ForgetBetaAccess) Key(ev input.Event, now time.Time) {
	if ev.Release || ev.Repeat {
		return
	}
	switch ev.Key {
	case input.Up:
		s.confirm = false
	case input.Down:
		s.confirm = true
	case input.Enter:
		if s.confirm {
			_, accessErr := access.Forget(s.app.betaDir())
			err := beta.Forget(s.app.betaDir())
			s.app.accessChanged()
			if err != nil || accessErr != nil {
				s.app.Notice = "Could not forget all beta access. Check storage and retry."
				s.app.NoticeAt = now
				return
			}
			s.app.Notice = "Saved beta access forgotten."
			s.app.NoticeAt = now
		}
		s.app.Pop()
	}
}

func (s *ForgetBetaAccess) Draw(c *gfx.Canvas, now time.Time) bool {
	a, f := s.app, s.app.F
	c.Fill(0, 0, c.W, c.H, gfx.Bg)
	a.text(c, MenuX, SafeY, f.Title, gfx.Grey, "Forget beta access?")
	for i, line := range []string{
		"Clears all saved codes on this installation.",
		"You'll need a code again for beta releases and extras.",
		"Plex sign-in and settings will be kept.",
	} {
		a.text(c, MenuX, ListY0+i*30, f.Small, gfx.GreyHi, line)
	}
	for i, label := range []string{"Cancel", "Forget beta access"} {
		y := ListY0 + 120 + i*MenuRowH
		col := gfx.GreyHi
		if (i == 1) == s.confirm {
			col = gfx.White
			menuFocusBar(c, MenuX, y, f.Body.Height())
		}
		a.text(c, MenuX, y, f.Body, col, label)
	}
	return false
}
