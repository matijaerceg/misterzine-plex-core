package ui

// Compare presented selections so redraws, releases and list boundaries stay quiet.
type focusPosition struct {
	screen  Screen
	a, b, c int
	p, q    bool
}

func (a *App) focusPosition() focusPosition {
	s := a.top()
	f := focusPosition{screen: s}
	switch s := s.(type) {
	case *Search:
		f.a, f.b, f.p = s.key, s.cur, s.results
	case *Login:
		f.a = s.cur
	case *Home:
		f.a = s.row
		if s.row >= 0 && s.row < len(s.col) {
			f.b = s.col[s.row]
		}
	case *Show:
		if s.episodes && s.season != nil {
			e := s.season
			f.a, f.b, f.c, f.p, f.q = e.si, e.cur, e.act+1, e.acts, e.pick
		} else if len(s.picker.col) > 0 {
			f.a, f.c = s.picker.col[0], -1
		}
	case *Wall:
		f.a, f.b, f.p = s.cur, s.view, s.tabs
	case *Updates:
		f.a = s.cur
	case *Options:
		f.a = s.cur
	case *Drawer:
		f.a = s.cur
	case *Chooser:
		f.a = s.cur
	case *Preplay:
		f.a = s.cur
	}
	return f
}

func (a *App) tap() {
	if a.Cfg != nil && !a.Cfg.NoTaps {
		if out, ok := a.Out.(interface{ Tap() }); ok {
			out.Tap()
		}
	}
}

func (a *App) selectionPresented() {
	f := a.focusPosition()
	if a.focusReady && f != a.lastFocus {
		a.tap()
	}
	a.lastFocus, a.focusReady = f, true
}

type playFocus struct {
	visible, scrub bool
	button, row    int
	list           string
}

func (p *Playing) selection() playFocus {
	if !p.visible {
		return playFocus{}
	}
	f := playFocus{visible: true, scrub: p.scrub, button: p.focus}
	if p.list != nil {
		f.list, f.row = p.list.kind, p.list.cur
	}
	return f
}
