package ui

import (
	"os"
	"path/filepath"
	"plexcrt/internal/beta"
	"plexcrt/internal/plex"
	"testing"
)

func TestLockedPlayerDoesNotLaunchOrTouchLog(t *testing.T) {
	path := filepath.Join(t.TempDir(), "play.log")
	if err := os.WriteFile(path, []byte("keep"), 0600); err != nil {
		t.Fatal(err)
	}
	p := &Player{LogTo: path, Binary: "must-not-launch", Access: func() error { return beta.ErrLocked }}
	if session, err := p.Start(&plex.Item{RatingKey: "123"}, 0); session != nil || err != beta.ErrLocked {
		t.Fatal(session, err)
	}
	got, err := os.ReadFile(path)
	if err != nil || string(got) != "keep" {
		t.Fatal("locked playback touched log")
	}
}

func TestLockedPlayShowsLockBeforePlayback(t *testing.T) {
	a := &App{Player: &Player{Access: func() error { return beta.ErrLocked }}}
	a.PlayAt(&plex.Item{RatingKey: "123"}, 0)
	if _, ok := a.top().(*BetaAccess); !ok {
		t.Fatal("missing beta lock")
	}
	if !a.Starting.IsZero() {
		t.Fatal("locked playback started spinner")
	}
}
