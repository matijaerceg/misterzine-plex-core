package ui

import (
	"context"
	"testing"

	"plexcrt/internal/plex"
)

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

func TestTapQuietDuringThemeAndPlayback(t *testing.T) {
	out := &tapPresenter{}
	a := &App{Out: out, Cfg: &Config{}}
	a.theme.players.Add(1)
	a.tap()
	if out.taps != 0 {
		t.Fatal("tick while a theme plays")
	}
	a.theme.players.Add(-1)
	a.playing = true
	a.tap()
	if out.taps != 0 {
		t.Fatal("tick during playback")
	}
	a.playing = false
	a.tap()
	if out.taps != 1 {
		t.Fatal("menus must tick")
	}
}

func TestThemePlayingWhileItsPlayerRuns(t *testing.T) {
	file, play := themeFile, themePlay
	defer func() { themeFile, themePlay = file, play }()
	started, release := make(chan struct{}), make(chan struct{})
	themeFile = func(*plex.Client, context.Context, string, string) (string, error) { return "f", nil }
	themePlay = func(context.Context, string, string) {
		close(started)
		<-release
	}
	var th Theme
	if th.Playing() {
		t.Fatal("idle theme playing")
	}
	th.Select(&plex.Client{}, "", "k", "")
	<-started
	if !th.Playing() {
		t.Fatal("running player not reported")
	}
	close(release)
	th.Stop()
	if th.Playing() {
		t.Fatal("stopped theme still playing")
	}
}
