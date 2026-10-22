package ui

import (
	"bytes"
	"log"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"plexcrt/internal/gfx"
)

// More background results than the queue holds arrive during one playback
// (an autoplay posts one per finished episode): none is dropped, none runs
// while the playback has the screen, and all run in order afterwards.
func TestLaterKeepsEveryPostDuringPlayback(t *testing.T) {
	var logged bytes.Buffer
	a := &App{Log: log.New(&logged, "", 0), later: make(chan func(), 32), Wake: make(chan struct{}, 1),
		Out: &fakeOut{c: gfx.NewCanvas(8, 4)}, Player: &Player{Status: filepath.Join(t.TempDir(), "status")}}
	ctl := &Playing{painter: newPainter()}
	sess := &Session{Done: make(chan error, 1)}
	const posts = 40
	var ran []int
	go func() {
		for i := range posts {
			a.Later(func() { ran = append(ran, i) })
			if i%10 == 9 { // a batch at a time, as finished episodes come
				for wait := time.Now().Add(time.Second); len(a.later) != 0 && time.Now().Before(wait); {
					time.Sleep(time.Millisecond)
				}
			}
		}
		sess.Done <- nil
	}()
	a.playLoop(sess, ctl)
	if len(ran) != 0 {
		t.Fatalf("%d closures ran while the playback had the screen", len(ran))
	}
	a.runLater()
	if len(ran) != posts {
		t.Fatalf("%d of %d closures ran", len(ran), posts)
	}
	for i, v := range ran {
		if v != i {
			t.Fatalf("closure %d ran in place %d", v, i)
		}
	}
	if logged.Len() != 0 {
		t.Fatalf("a post was dropped: %q", logged.String())
	}
}

// A post the full queue drops is logged, once until the queue drains.
func TestLaterLogsADroppedPostOnce(t *testing.T) {
	var logged bytes.Buffer
	a := &App{Log: log.New(&logged, "", 0), later: make(chan func(), 1)}
	for range 3 {
		a.Later(func() {})
	}
	if n := strings.Count(logged.String(), "dropped"); n != 1 {
		t.Fatalf("a full queue logged %d times: %q", n, logged.String())
	}
	a.runLater()
	a.Later(func() {})
	a.Later(func() {})
	if n := strings.Count(logged.String(), "dropped"); n != 2 {
		t.Fatalf("a full queue after draining logged %d times in all: %q", n, logged.String())
	}
}
