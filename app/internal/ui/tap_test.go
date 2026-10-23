package ui

import "testing"

type tapPresenter struct {
	Presenter
	taps int
}

func (p *tapPresenter) Tap() { p.taps++ }

func TestTapsFollowPresentedSelection(t *testing.T) {
	out := &tapPresenter{}
	s := &Options{}
	a := &App{Out: out, Cfg: &Config{}, stack: []Screen{s}}
	a.selectionPresented()
	a.selectionPresented()
	if out.taps != 0 {
		t.Fatal("startup/redraw clicked")
	}
	s.cur++
	a.selectionPresented()
	a.selectionPresented()
	if out.taps != 1 {
		t.Fatal("selection must click exactly once")
	}
	a.stack = append(a.stack, &Chooser{})
	a.selectionPresented()
	if out.taps != 2 {
		t.Fatal("new screen selection must click")
	}
	a.Cfg.NoTaps = true
	a.stack = a.stack[:1]
	a.selectionPresented()
	a.Cfg.NoTaps = false
	a.selectionPresented()
	if out.taps != 2 {
		t.Fatal("muted changes must not replay")
	}
}

func TestPlaybackSelectionIgnoresProgress(t *testing.T) {
	p := &Playing{visible: true, focus: 1}
	before := p.selection()
	p.pos = 20
	p.paused = true
	if before != p.selection() {
		t.Fatal("progress or pause is not a selection change")
	}
	p.focus++
	if before == p.selection() {
		t.Fatal("button selection ignored")
	}
	p.list = &listMode{kind: "Audio"}
	before = p.selection()
	p.list.cur++
	if before == p.selection() {
		t.Fatal("track selection ignored")
	}
	p.visible = false
	if p.selection().visible {
		t.Fatal("hidden overlay has no selection")
	}
}
