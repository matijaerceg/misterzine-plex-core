package ui

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPlaybackFailureLogSurvivesNextPlayback(t *testing.T) {
	path := filepath.Join(t.TempDir(), "jfplay.log")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	want := strings.Repeat("x", 70*1024) + "startup stage=open-input result=-110\n"
	if _, err := f.WriteString(want); err != nil {
		t.Fatal(err)
	}
	s := &Session{p: &Player{LogTo: path}, lf: f}
	s.preserveFailureLog()
	if err := os.WriteFile(path, []byte("successful playback\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(path + ".failed")
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != want[len(want)-64*1024:] {
		t.Fatal("failed playback tail was lost or was not bounded")
	}
	// A later failure replaces the snapshot rather than growing it forever.
	s.preserveFailureLog()
	got, err = os.ReadFile(path + ".failed")
	if err != nil || string(got) != "successful playback\n" {
		t.Fatalf("replacement snapshot: %q, %v", got, err)
	}
}

func TestFailedWorkerPreservesLogBeforeDone(t *testing.T) {
	f := newPlayServer(t, playVideoTranscode)
	p, _ := fallbackPlayer(t, f, []int{4}, "640")
	s, err := p.Start(playItem(), 640)
	if err != nil {
		t.Fatal(err)
	}
	if waitDone(t, s) == nil {
		t.Fatal("worker startup failure was not reported")
	}
	data, err := os.ReadFile(p.LogTo + ".failed")
	if err != nil || !strings.Contains(string(data), "offset=640 s") {
		t.Fatalf("failure snapshot missing request context: %q, %v", data, err)
	}
}
