package ui

import (
	"runtime"
	"syscall"
	"testing"
)

// The play loop runs at the ordinary priority on a thread Run raised, and
// the thread gets its own back afterwards; a thread at 0 is left alone.
func TestPlaybackPriorityIsOrdinaryAndRestored(t *testing.T) {
	type result struct {
		during, after int
		skip          string
	}
	done := make(chan result)
	go func() {
		runtime.LockOSThread() // never unlocked: the thread goes with the goroutine
		nice := func() int {
			prio, _ := syscall.Getpriority(syscall.PRIO_PROCESS, 0)
			return 20 - prio
		}
		if nice() != 0 {
			done <- result{skip: "the test runs above or below nice 0"}
			return
		}
		playbackPriority()() // at 0 already: nothing to do
		if syscall.Setpriority(syscall.PRIO_PROCESS, 0, 5) != nil {
			done <- result{skip: "cannot change this thread's priority"}
			return
		}
		restore := playbackPriority()
		during := nice()
		restore()
		done <- result{during: during, after: nice()}
	}()
	r := <-done
	if r.skip != "" {
		t.Skip(r.skip)
	}
	if r.during == 5 {
		t.Skip("no permission to raise a thread's priority")
	}
	if r.during != 0 || r.after != 5 {
		t.Fatalf("nice %d during the playback, %d after; want 0 and 5", r.during, r.after)
	}
}
