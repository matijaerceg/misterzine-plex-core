package ring

import (
	"runtime"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
	"unsafe"
)

// heartbeat plays a core's frame counter at an exact period (it spins, so
// the edges are where they should be), and records when each value began.
type heartbeat struct {
	r     *Ring
	began []atomic.Int64
	stop  chan struct{}
	done  chan struct{}
	once  sync.Once
}

func newHeartbeat(t *testing.T, period time.Duration, fields int) *heartbeat {
	t.Helper()
	words := make([]uint32, ctrlLen/4)
	h := &heartbeat{r: attach(words, nil, fbByte), began: make([]atomic.Int64, fields+64), stop: make(chan struct{}), done: make(chan struct{})}
	go func() {
		defer close(h.done)
		next := time.Now()
		for v := uint32(1); int(v) < len(h.began); v++ {
			next = next.Add(period)
			for time.Now().Before(next) {
				select {
				case <-h.stop:
					return
				default:
				}
			}
			h.began[v].Store(time.Now().UnixNano())
			atomic.StoreUint32(&words[2*wSeqHead], v)
		}
	}()
	t.Cleanup(h.close)
	return h
}

func (h *heartbeat) close() {
	h.once.Do(func() { close(h.stop); <-h.done })
}

// threadCPU is the CPU time the calling thread has run for.
func threadCPU() time.Duration {
	var ts syscall.Timespec
	syscall.Syscall(syscall.SYS_CLOCK_GETTIME, 3, uintptr(unsafe.Pointer(&ts)), 0) // CLOCK_THREAD_CPUTIME_ID
	return time.Duration(ts.Nano())
}

// waitFields calls WaitField for fields fields, drawing for draw after
// each as the render loop does, and reports the CPU time it took a field,
// how long after an edge it returned, and how many edges it slept through.
func waitFields(t *testing.T, period, draw time.Duration, fields int) (cpu, late, worst time.Duration, skipped int) {
	t.Helper()
	h := newHeartbeat(t, period, fields)
	// Stop this clock before the caller starts another timing measurement.
	defer h.close()
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	for h.r.Field() < 2 { // the generator is running
		runtime.Gosched()
	}
	for i := 0; i < 5; i++ { // as an animation's first fields find the phase
		h.r.WaitField(50 * time.Millisecond)
	}
	var waited time.Duration
	for i := 0; i < fields; i++ {
		start := h.r.Field()
		c0 := threadCPU()
		h.r.WaitField(50 * time.Millisecond)
		cpu += threadCPU() - c0
		got := h.r.waited
		if got != start+1 {
			skipped++
		}
		d := h.r.waitedT.Sub(time.Unix(0, h.began[got].Load()))
		waited += d
		worst = max(worst, d)
		end := time.Now().Add(draw)
		for time.Now().Before(end) { // drawing
		}
	}
	return cpu / time.Duration(fields), waited / time.Duration(fields), worst, skipped
}

// WaitField sleeps until shortly before the edge it expects, from the
// period it measured, and reads the heartbeat continuously only then: a
// field costs about a millisecond of CPU (with a fixed 60 Hz period it
// spun for the last 4 ms of each, the last 7 at 50 Hz), and it returns as
// soon after the edge as it did. The bounds leave room for a busy host.
func TestWaitFieldSleepsMostOfTheField(t *testing.T) {
	if testing.Short() {
		t.Skip("timing")
	}
	for _, c := range []struct {
		name   string
		period time.Duration
	}{{"60Hz", 16683 * time.Microsecond}, {"50Hz", 20 * time.Millisecond}} {
		t.Run(c.name, func(t *testing.T) {
			cpu, late, worst, skipped := waitFields(t, c.period, 6*time.Millisecond, 50)
			t.Logf("a field: %v CPU; returned %v after the edge on average, %v at worst; %d edges slept through", cpu, late, worst, skipped)
			if cpu > 3*time.Millisecond || late > 500*time.Microsecond || skipped > 2 {
				t.Fatal("WaitField spins too long, returns late or sleeps through edges")
			}
			h := newHeartbeat(t, c.period, 30)
			for i := 0; i < 20; i++ {
				h.r.WaitField(50 * time.Millisecond)
			}
			if d := h.r.period - c.period; d > fieldWake/2 || d < -fieldWake/2 {
				t.Fatalf("measured a period of %v", h.r.period)
			}
		})
	}
}

// edges feeds edgeSeen heartbeats from a start time at the intervals
// given, each seen within width, and returns the period it then holds.
func edges(r *Ring, at time.Time, width time.Duration, intervals ...time.Duration) (time.Time, time.Duration) {
	for _, d := range intervals {
		at = at.Add(d)
		r.edgeSeen(r.last+1, at.Add(-width/2), at.Add(width/2))
	}
	return at, r.period
}

func TestEdgeSeenMeasuresThePeriodAndNeverRunsPastAnEdge(t *testing.T) {
	const exact, polled = 2 * time.Microsecond, 250 * time.Microsecond
	field := 20 * time.Millisecond
	r := &Ring{}
	at := time.Now()
	// polled edges: the shortest period they allow, below the field's
	at, p := edges(r, at, polled, 0, field, field)
	if p > field || p < field-2*polled {
		t.Fatalf("polled edges gave %v", p)
	}
	at, p = edges(r, at, exact, field, field, field, field, field, field, field, field, field, field, field, field)
	if p > field || field-p > 50*time.Microsecond {
		t.Fatalf("exact edges gave %v", p)
	}
	// a field the heartbeat took 34 ms for raises the period one step only
	at, p = edges(r, at, exact, 34*time.Millisecond)
	if p > field+fieldWake/4 {
		t.Fatalf("one long field raised the period to %v", p)
	}
	at, p = edges(r, at, exact, field)
	if p > field {
		t.Fatalf("the next field left the period at %v", p)
	}
	// a faster refresh (60 Hz) is taken at once from polled edges
	at, p = edges(r, at, polled, 16683*time.Microsecond, 16683*time.Microsecond)
	if p > 16683*time.Microsecond {
		t.Fatalf("a faster refresh left the period at %v", p)
	}
	// a slower one (50 Hz again) in steps a sleep cannot run past an edge by
	for i := 0; i < 20; i++ {
		before := r.period
		at, p = edges(r, at, polled, field)
		if p > field || p-before > fieldWake/4 {
			t.Fatalf("a slower refresh moved the period from %v to %v", before, p)
		}
	}
	if p < field-2*polled {
		t.Fatalf("a slower refresh was not followed: %v", p)
	}
	// an edge slept through (seen only a field after the read before it)
	r.edgeSeen(r.last+1, at, at.Add(field))
	if !r.edgeT.IsZero() {
		t.Fatal("an edge slept through still predicts the next")
	}
}
