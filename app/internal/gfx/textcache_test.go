package gfx

import (
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// getNow waits for the cache to have rendered s.
func getNow(t testing.TB, tc *TextCache, f *Font, s string) *Image {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		if img := tc.Get(f, s, 0xffffff, 0); img != nil {
			return img
		}
		if time.Now().After(deadline) {
			t.Fatalf("line %q never rendered", s)
		}
		time.Sleep(50 * time.Microsecond)
	}
}

// A line drawn every frame stays cached however many other lines come
// and go; the cache used to drop everything at 600 lines.
func TestTextCacheKeepsLinesInUse(t *testing.T) {
	f := Load("med18")
	tc := NewTextCache(1, make(chan struct{}, 1))
	getNow(t, tc, f, "Continue Watching")
	for i := 0; i < 2000; i++ {
		getNow(t, tc, f, "line "+strconv.Itoa(i))
		if tc.Get(f, "Continue Watching", 0xffffff, 0) == nil {
			t.Fatalf("the line in use was dropped after %d others", i+1)
		}
	}
	tc.mu.Lock()
	n := len(tc.cur) + len(tc.old)
	tc.mu.Unlock()
	if n > 2*tc.gen {
		t.Fatalf("%d lines cached, want at most %d", n, 2*tc.gen)
	}
}

// A short line is there on the frame that first asks for it (the typed
// text of the keypad); a long one waits for the worker.
func TestTextCacheShortLineAtOnce(t *testing.T) {
	f := Load("med18")
	tc := NewTextCache(0, nil)
	if tc.Get(f, "plex.local", 0xffffff, 0) == nil {
		t.Fatal("a short line was missing on its first frame")
	}
	if tc.Get(f, strings.Repeat("x", syncLen+1), 0xffffff, 0) != nil {
		t.Fatal("a long line was rendered on the caller")
	}
}

// Warming a line queues it for the workers, short or long, and renders
// nothing on the caller.
func TestTextCacheWarmQueues(t *testing.T) {
	f := Load("med18")
	tc := NewTextCache(0, nil)
	tc.Warm(f, "Pilot", 0xffffff, 0)
	tc.Warm(f, "Pilot", 0xffffff, 0)
	if len(tc.work) != 1 || len(tc.cur) != 0 {
		t.Fatalf("%d queued and %d rendered, want 1 queued and none rendered", len(tc.work), len(tc.cur))
	}
	tc = NewTextCache(1, make(chan struct{}, 1))
	long := strings.Repeat("x", syncLen+1)
	tc.Warm(f, long, 0xffffff, 0)
	getNow(t, tc, f, long)
}

// A screenful of new short lines renders on the caller only up to the
// field's budget; the rest are queued.
func TestTextCacheSyncBudget(t *testing.T) {
	f := Load("med18")
	tc := NewTextCache(0, nil)
	tc.syncAt, tc.syncLeft = time.Now().Add(time.Hour), syncBudget // one long field
	got := 0
	for i := 0; i < 100; i++ {
		s := "Episode " + strconv.Itoa(100+i) + strings.Repeat(".", 19) // 30 characters
		if tc.Get(f, s, 0xffffff, 0) != nil {
			got++
		}
	}
	if want := syncBudget / 30; got != want {
		t.Fatalf("%d lines rendered on the caller, want %d", got, want)
	}
}

// Callers on several goroutines and the worker share the cache (run with
// -race).
func TestTextCacheConcurrent(t *testing.T) {
	f := Load("reg16")
	tc := NewTextCache(1, make(chan struct{}, 1))
	var wg sync.WaitGroup
	for g := 0; g < 4; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 2000; i++ {
				s := "line " + strconv.Itoa(i%700)
				if i%3 == 0 {
					s += strings.Repeat(" long", 10)
				}
				if img := tc.Get(f, s, 0xffffff, 0); img != nil && img.W != f.Width(s)+2 {
					t.Errorf("line %q is %d wide", s, img.W)
					return
				}
			}
		}()
	}
	wg.Wait()
}

func BenchmarkTextRenderShort(b *testing.B) {
	f := Load("med18")
	k := textKey{f, "The Long Way Round  S1E4  42m", 0xffffff, 0}
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		renderLine(k)
	}
}

func BenchmarkTextCacheHit(b *testing.B) {
	f := Load("med18")
	tc := NewTextCache(1, make(chan struct{}, 1))
	lines := make([]string, 40) // a screenful
	for i := range lines {
		lines[i] = "Season " + strconv.Itoa(i) + "  The Long Way Round"
		getNow(b, tc, f, lines[i])
	}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if tc.Get(f, lines[i%len(lines)], 0xffffff, 0) == nil {
			b.Fatal("miss")
		}
	}
}
