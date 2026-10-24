package ui

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"plexcrt/internal/input"
	"plexcrt/internal/updates"
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

// frame does what the main loop does before each frame.
func frame(a *App, now time.Time) {
	if s, ok := a.top().(interface{ pollRefresh(time.Time) }); ok {
		s.pollRefresh(now)
	}
}

// frames runs the loop's frames from..to every 20 ms (the pad sends no
// repeats for OK, only the press and the release).
func frames(a *App, from, to time.Time) {
	for at := from; !at.After(to); at = at.Add(20 * time.Millisecond) {
		frame(a, at)
	}
}

func TestMemoReleaseBeforeHoldResets(t *testing.T) {
	a, _, p := memoApp(t)
	t0 := time.Now()
	a.key(input.Event{Key: input.Enter}, t0)
	frames(a, t0, t0.Add(900*time.Millisecond))
	a.key(input.Event{Key: input.Enter, Release: true}, t0.Add(900*time.Millisecond))
	frames(a, t0.Add(900*time.Millisecond), t0.Add(1500*time.Millisecond))
	if a.top() != p {
		t.Fatal("dismissed after an early release")
	}
	// pressed again: the earlier 0.9 s does not count
	t1 := t0.Add(1500 * time.Millisecond)
	a.key(input.Event{Key: input.Enter}, t1)
	frames(a, t1, t1.Add(900*time.Millisecond))
	if a.top() != p {
		t.Fatal("dismissed before a full hold")
	}
	if p.held(t1.Add(500*time.Millisecond)) != 0.5 {
		t.Fatalf("held %v", p.held(t1.Add(500*time.Millisecond)))
	}
}

func TestMemoPadHoldDismissesOnTheFrameAndSwallowsRelease(t *testing.T) {
	a, under, p := memoApp(t)
	t0 := time.Now()
	a.key(input.Event{Key: input.Enter}, t0)
	frames(a, t0, t0.Add(MemoHold-time.Millisecond))
	if a.top() != p {
		t.Fatal("dismissed before 1 s")
	}
	frame(a, t0.Add(MemoHold))
	if a.top() == Screen(p) {
		t.Fatal("a 1 s hold did not dismiss while OK was still down")
	}
	if !slices.Equal(a.Cfg.SeenMemos, []string{"test-a"}) {
		t.Fatalf("seen %v", a.Cfg.SeenMemos)
	}
	a.key(input.Event{Key: input.Enter, Release: true}, t0.Add(3*time.Second))
	if len(under.keys) != 0 {
		t.Fatalf("the release reached Home: %v", under.keys)
	}
	a.key(input.Event{Key: input.Enter}, t0.Add(4*time.Second))
	if len(under.keys) != 1 {
		t.Fatal("the next press was lost")
	}
}

func TestMemoKeyboardHoldSwallowsTypematic(t *testing.T) {
	a, under, p := memoApp(t)
	enter := input.Event{Key: input.Enter, Keyboard: true, ScanCode: 0x5A}
	rep, rel := enter, enter
	rep.Repeat, rel.Release = true, true
	t0 := time.Now()
	a.key(enter, t0)
	a.key(rep, t0.Add(500*time.Millisecond))
	frames(a, t0, t0.Add(MemoHold))
	if a.top() == Screen(p) {
		t.Fatal("a keyboard hold did not dismiss")
	}
	a.key(rep, t0.Add(1100*time.Millisecond))
	a.key(rel, t0.Add(1200*time.Millisecond))
	if len(under.keys) != 0 {
		t.Fatalf("the rest of the key press reached Home: %v", under.keys)
	}
}

func TestMemoReleaseAfterSecondDismisses(t *testing.T) {
	// a slow frame: the release lands before the frame that would time it
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

func TestPublishedMemosRewordOrFollowTheCompiledOnes(t *testing.T) {
	published := []updates.Memo{
		{ID: "test-b", Title: "B2", Text: "Second note, reworded."},
		{ID: "2026-11-new", Title: "New", Text: "Published later."},
	}
	got := mergeMemos(testMemos, published)
	want := []memo{testMemos[0], {ID: "test-b", Title: "B2", Text: "Second note, reworded."}, {ID: "2026-11-new", Title: "New", Text: "Published later."}}
	if !slices.Equal(got, want) {
		t.Fatalf("merged %+v", got)
	}
	if !slices.Equal(mergeMemos(testMemos, nil), testMemos) {
		t.Fatal("no published memos changed the list")
	}
	// A catalogue that arrives after the first look brings its memo up on
	// Home; one already dismissed stays away.
	cfg := &Config{path: filepath.Join(t.TempDir(), "config.json")}
	for _, m := range memos {
		cfg.SeenMemos = append(cfg.SeenMemos, m.ID)
	}
	a := &App{Cfg: cfg, stack: []Screen{&Home{home: true}}}
	a.showMemo()
	if len(a.stack) != 1 || !a.memoChecked {
		t.Fatal("a memo with nothing published")
	}
	a.updates.catalogue.Memos = []updates.Memo{{ID: "2026-11-new", Title: "New", Text: "Published later."}}
	a.memoChecked = false // as checkUpdates does when a catalogue lands
	a.showMemo()
	p, ok := a.top().(*MemoPage)
	if !ok || p.m.ID != "2026-11-new" {
		t.Fatalf("top %T", a.top())
	}
	t0 := time.Now()
	a.key(input.Event{Key: input.Enter}, t0)
	a.key(input.Event{Key: input.Enter, Release: true}, t0.Add(MemoHold))
	a.memoChecked = false
	a.showMemo()
	if len(a.stack) != 1 {
		t.Fatal("a dismissed published memo came back")
	}
}
