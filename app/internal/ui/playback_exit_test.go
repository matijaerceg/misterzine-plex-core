package ui

import (
	"errors"
	"io"
	"log"
	"testing"
)

func TestPlaybackStartupFailureIsVisibleAndRendererRetired(t *testing.T) {
	a := &App{Log: log.New(io.Discard, "", 0)}
	ctl := &Playing{painter: newPainter()}
	s := &Session{Done: make(chan error, 1)}
	s.Done <- errors.New("Server could not prepare playback")
	a.playLoop(s, ctl)
	if a.Notice != "Server could not prepare playback" || a.NoticeAt.IsZero() {
		t.Fatalf("startup failure not shown: %q", a.Notice)
	}
	select {
	case <-ctl.painter.done:
	default:
		t.Fatal("playback returned before its renderer stopped")
	}
}
