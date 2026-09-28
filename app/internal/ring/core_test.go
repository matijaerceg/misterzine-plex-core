package ring

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

// fakeCore writes the field counter and status signature every few ms, as
// the core does every vsync, until stopped.
func fakeCore(r *Ring) (stop func()) {
	done, finished := make(chan struct{}), make(chan struct{})
	go func() {
		defer close(finished)
		for f := atomic.LoadUint32(&r.stat[0]) + 1; ; f++ {
			atomic.StoreUint32(&r.hdr[27], 0x56500000)
			atomic.StoreUint32(&r.stat[0], f)
			select {
			case <-done:
				return
			case <-time.After(5 * time.Millisecond):
			}
		}
	}()
	return func() { close(done); <-finished }
}

// wipe is what a framebuffer mode write does to the status words.
func wipe(r *Ring) {
	atomic.StoreUint32(&r.stat[0], 0)
	atomic.StoreUint32(&r.hdr[27], 0)
}

func TestCoreRunning(t *testing.T) {
	r := fakeRing()
	if r.CoreRunning(30 * time.Millisecond) {
		t.Fatal("an empty ring read as a running core")
	}
	atomic.StoreUint32(&r.stat[0], 1234)
	atomic.StoreUint32(&r.hdr[27], 0x56500000)
	if r.CoreRunning(30 * time.Millisecond) {
		t.Fatal("a counter left behind by a core that has gone read as running")
	}
	stop := fakeCore(r)
	if !r.CoreRunning(100 * time.Millisecond) {
		t.Fatal("a running core was not seen")
	}
	stop()
	wipe(r)
	if r.CoreRunning(30 * time.Millisecond) {
		t.Fatal("a wiped ring read as running")
	}
	// A wipe while the core runs: it writes both words again at its next vsync.
	go func() {
		time.Sleep(10 * time.Millisecond)
		atomic.StoreUint32(&r.hdr[27], 0x56500000)
		atomic.StoreUint32(&r.stat[0], 1236)
	}()
	if !r.CoreRunning(100 * time.Millisecond) {
		t.Fatal("a core writing again after a wipe was not seen")
	}
	// Anything else painting over the counter lacks the signature.
	wipe(r)
	go func() {
		time.Sleep(10 * time.Millisecond)
		atomic.StoreUint32(&r.stat[0], 0x00FF8040)
	}()
	if r.CoreRunning(50 * time.Millisecond) {
		t.Fatal("a counter without the status signature read as running")
	}
}

func TestMapRingEnlargesOnlyForARunningCore(t *testing.T) {
	var enlarged, mapped int
	enlarge := func() (string, error) { enlarged++; return "", nil }
	refused := func() ([]byte, error) { mapped++; return nil, syscall.EINVAL }
	ok := func() ([]byte, error) { mapped++; return make([]byte, 8), nil }
	always := func(time.Duration) bool { return true }

	if _, err := mapRing(ok, enlarge, func(time.Duration) bool { return false }); err != errNotRunning || enlarged+mapped != 0 {
		t.Fatalf("no core: err %v, %d enlarged, %d mapped", err, enlarged, mapped)
	}

	// main's mode write lands between ours and the mapping: enlarge again
	enlarged, mapped = 0, 0
	calls := 0
	flaky := func() ([]byte, error) {
		if calls++; calls == 1 {
			return refused()
		}
		return ok()
	}
	if mem, err := mapRing(flaky, enlarge, always); err != nil || mem == nil || enlarged != 2 {
		t.Fatalf("retry: err %v, %d enlarged", err, enlarged)
	}

	// the core goes during the retry: the menu's mode is left alone
	enlarged, mapped = 0, 0
	checks := 0
	goes := func(time.Duration) bool { checks++; return checks == 1 }
	if _, err := mapRing(refused, enlarge, goes); err != errNotRunning || enlarged != 1 {
		t.Fatalf("core gone mid-retry: err %v, %d enlarged", err, enlarged)
	}
}

type watchRun struct {
	r      *Ring
	mode   string
	wakes  atomic.Int32
	mu     sync.Mutex
	logged []string
	stop   chan struct{}
	done   chan struct{}
}

func startWatch(t *testing.T, r *Ring, mode string) *watchRun {
	t.Helper()
	path := filepath.Join(t.TempDir(), "mode")
	old := modeFile
	modeFile = path
	os.WriteFile(path, []byte(mode+"\n"), 0o644)
	w := &watchRun{r: r, mode: path, stop: make(chan struct{}), done: make(chan struct{})}
	logf := func(f string, a ...any) {
		w.mu.Lock()
		w.logged = append(w.logged, fmt.Sprintf(f, a...))
		w.mu.Unlock()
	}
	go func() { defer close(w.done); r.Watch(logf, func() { w.wakes.Add(1) }, w.stop) }()
	t.Cleanup(func() { close(w.stop); <-w.done; modeFile = old })
	return w
}

func (w *watchRun) setMode(m string) { os.WriteFile(w.mode, []byte(m+"\n"), 0o644) }

func (w *watchRun) log() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return strings.Join(w.logged, "\n")
}

func TestWatchKeepsTheRingMappedWhileTheCoreRuns(t *testing.T) {
	r := fakeRing()
	defer fakeCore(r)()
	atomic.StoreUint32(&r.pubSeq, 1) // the app has published; the header reads wiped
	w := startWatch(t, r, fullMode)
	w.setMode("8888 1 1280 720 5120") // main's own late write
	time.Sleep(1200 * time.Millisecond)
	if got := readMode(); got != fullMode {
		t.Fatalf("mode left at %q with the core running", got)
	}
	if w.wakes.Load() == 0 {
		t.Fatal("a wiped header was not redrawn with the core running")
	}
	if strings.Contains(w.log(), "has stopped") {
		t.Fatalf("a running core was reported stopped:\n%s", w.log())
	}
}

// A short Reboot from the OSD loads the menu with the app still up: main's
// mode write is the menu's, and rewriting it clears the top of its wallpaper.
func TestWatchLeavesTheFramebufferAloneOnceTheCoreHasGone(t *testing.T) {
	r := fakeRing()
	stopCore := fakeCore(r)
	atomic.StoreUint32(&r.pubSeq, 1)
	w := startWatch(t, r, fullMode)
	time.Sleep(200 * time.Millisecond)
	stopCore()
	wipe(r) // the menu's mode write
	w.setMode("8888 1 1280 720 5120")
	time.Sleep(400 * time.Millisecond)
	wakes := w.wakes.Load()
	time.Sleep(900 * time.Millisecond)
	if got := readMode(); got != "8888 1 1280 720 5120" {
		t.Fatalf("the menu's mode was rewritten to %q after the core had gone", got)
	}
	if w.wakes.Load() != wakes {
		t.Fatalf("the app was woken to redraw %d more times after the core had gone", w.wakes.Load()-wakes)
	}
	if n := strings.Count(w.log(), "the core has stopped"); n != 1 {
		t.Fatalf("core stop reported %d times:\n%s", n, w.log())
	}
}
