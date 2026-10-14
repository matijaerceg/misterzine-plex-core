package ui

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"plexcrt/internal/input"
)

var testMemos = []memo{{ID: "test-a", Title: "A", Text: "First note."}, {ID: "test-b", Title: "B", Text: "Second note."}}

func memoApp(t *testing.T) (*App, *keyScreen, *MemoPage) {
	t.Helper()
	under := &keyScreen{}
	a := &App{Cfg: &Config{path: filepath.Join(t.TempDir(), "config.json")}, stack: []Screen{under}}
	p := &MemoPage{app: a, m: testMemos[0]}
	a.Push(p)
	return a, under, p
}

func TestMemoShortTapDoesNotDismiss(t *testing.T) {
	a, _, p := memoApp(t)
	t0 := time.Now()
	a.key(input.Event{Key: input.Enter}, t0)
	a.key(input.Event{Key: input.Enter, Release: true}, t0.Add(200*time.Millisecond))
	if a.top() != p || len(a.Cfg.SeenMemos) != 0 {
		t.Fatal("a tap dismissed the memo")
	}
	a.key(input.Event{Key: input.Back}, t0)
	a.key(input.Event{Key: input.Down}, t0)
	if a.top() != p {
		t.Fatal("another button dismissed the memo")
	}
}

func TestMemoReleaseBeforeHoldResets(t *testing.T) {
	a, _, p := memoApp(t)
	t0 := time.Now()
	a.key(input.Event{Key: input.Enter}, t0)
	a.key(input.Event{Key: input.Enter, Release: true}, t0.Add(900*time.Millisecond))
	// pressed again: the earlier 0.9 s does not count
	t1 := t0.Add(1000 * time.Millisecond)
	a.key(input.Event{Key: input.Enter}, t1)
	a.key(input.Event{Key: input.Enter, Repeat: true, Count: 1}, t1.Add(400*time.Millisecond))
	if a.top() != p {
		t.Fatal("dismissed before a full hold")
	}
	if p.held(t1.Add(500*time.Millisecond)) != 0.5 {
		t.Fatalf("held %v", p.held(t1.Add(500*time.Millisecond)))
	}
}

func TestMemoHoldDismissesAndSwallowsPress(t *testing.T) {
	a, under, p := memoApp(t)
	t0 := time.Now()
	a.key(input.Event{Key: input.Enter}, t0)
	for i := 1; i <= 5; i++ {
		at := t0.Add(400*time.Millisecond + time.Duration(i-1)*140*time.Millisecond)
		a.key(input.Event{Key: input.Enter, Repeat: true, Count: i}, at)
		if at.Sub(t0) < MemoHold && a.top() != p {
			t.Fatalf("dismissed at %v", at.Sub(t0))
		}
	}
	a.key(input.Event{Key: input.Enter, Repeat: true, Count: 6}, t0.Add(1100*time.Millisecond))
	if a.top() == Screen(p) {
		t.Fatal("a 1 s hold did not dismiss")
	}
	a.key(input.Event{Key: input.Enter, Repeat: true, Count: 7}, t0.Add(1240*time.Millisecond))
	a.key(input.Event{Key: input.Enter, Release: true, Count: 7}, t0.Add(1300*time.Millisecond))
	if len(under.keys) != 0 {
		t.Fatalf("the rest of the press reached Home: %v", under.keys)
	}
	a.key(input.Event{Key: input.Enter}, t0.Add(2*time.Second))
	if len(under.keys) != 1 {
		t.Fatal("the next press was lost")
	}
}

func TestMemoHoldReleasedAfterSecondDismisses(t *testing.T) {
	a, _, p := memoApp(t)
	t0 := time.Now()
	a.key(input.Event{Key: input.Enter}, t0)
	a.key(input.Event{Key: input.Enter, Release: true}, t0.Add(MemoHold))
	if a.top() == Screen(p) {
		t.Fatal("release after a 1 s hold did not dismiss")
	}
}

func TestMemoSeenOncePerID(t *testing.T) {
	a, _, _ := memoApp(t)
	t0 := time.Now()
	a.key(input.Event{Key: input.Enter}, t0)
	a.key(input.Event{Key: input.Enter, Release: true}, t0.Add(MemoHold))
	data, err := os.ReadFile(a.Cfg.path)
	if err != nil {
		t.Fatal(err)
	}
	var saved Config
	if err := json.Unmarshal(data, &saved); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(saved.SeenMemos, []string{"test-a"}) {
		t.Fatalf("saved %v", saved.SeenMemos)
	}
	loaded := LoadConfig(a.Cfg.path)
	m, ok := unseenMemo(loaded, testMemos)
	if !ok || m.ID != "test-b" {
		t.Fatalf("next memo %v %v", m.ID, ok)
	}
	loaded.SeenMemos = append(loaded.SeenMemos, "test-b")
	if _, ok := unseenMemo(loaded, testMemos); ok {
		t.Fatal("a memo showed after all were seen")
	}
}

func TestShowMemoNothingWhenAllSeen(t *testing.T) {
	cfg := &Config{}
	for _, m := range memos {
		cfg.SeenMemos = append(cfg.SeenMemos, m.ID)
	}
	h := &Home{home: true}
	a := &App{Cfg: cfg, stack: []Screen{h}}
	a.showMemo()
	if len(a.stack) != 1 || !a.memoChecked {
		t.Fatalf("stack %d", len(a.stack))
	}
	// with one unseen it shows once, and only on a connected Home
	b := &App{Cfg: &Config{}, stack: []Screen{&Home{home: true, connecting: true}}}
	b.showMemo()
	if len(b.stack) != 1 {
		t.Fatal("memo over a connecting Home")
	}
	b.stack[0].(*Home).connecting = false
	b.playing = true
	b.showMemo()
	if len(b.stack) != 1 {
		t.Fatal("memo during playback")
	}
	b.playing = false
	b.showMemo()
	b.showMemo()
	if len(b.stack) != 2 {
		t.Fatalf("stack %d", len(b.stack))
	}
}
