package ring

import (
	"runtime"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// VideoControl publishes a leased request separately from frame and overlay
// producers. The timer runs even if the UI is waiting for a network request.
type VideoControl struct {
	mu             sync.Mutex
	mode, previous uint32
	deadline       time.Time
}

// The core shows ring video, and keeps the requested mode, only while the
// lease moves at least every 120 fields (2 s). A patron saw the picture go
// black for about 2 s at a time with the sound playing on, which is what a
// lapsed lease looks like. The lease runs on a thread of its own at the
// player's priority (plexplay runs ffmpeg and plexfb near nice -15) and
// sleeps in the kernel rather than on the Go scheduler's timers. That is
// insurance: on the DE10, eight nice -15 busy loops and a 300 MB SD write
// together never delayed the old nice 0 goroutine past 0.36 s, so the cause
// is still open, and the late-renewal line below is there to settle it.
const (
	leaseEvery = 250 * time.Millisecond
	leaseLate  = 500 * time.Millisecond // a renewal further apart than this is logged
	leaseNice  = -15
)

var leaseNoteEvery = 5 * time.Second // tests shorten it

// StartVideo keeps the lease until the returned function is called. logf,
// when not nil, hears about late renewals, at most one line every 5 s.
func (r *Ring) StartVideo(mode uint32, logf func(string, ...any)) func() {
	r.SetVideo(mode)
	var stopping, noting atomic.Bool
	done := make(chan struct{})
	go func() {
		defer close(done)
		// Never unlocked: the thread ends with the loop, and its priority with it.
		runtime.LockOSThread()
		syscall.Setpriority(syscall.PRIO_PROCESS, 0, leaseNice) // this thread only, on Linux; needs root
		var last, noted time.Time
		var late int
		var worst time.Duration
		for !stopping.Load() {
			now := time.Now()
			if gap := now.Sub(last); !last.IsZero() && gap > leaseLate {
				late++
				worst = max(worst, gap)
			}
			// Written off this thread, which should only ever renew (the log's
			// lock is shared with every other writer), and one at a time:
			// renewals late meanwhile go in the next.
			if late > 0 && logf != nil && now.Sub(noted) >= leaseNoteEvery && !noting.Load() {
				noting.Store(true)
				n, w := late, worst
				go func() {
					defer noting.Store(false)
					logf("video lease: %d late renewal(s), the longest %.2f s after the one before (the core blanks the picture at 2 s)", n, w.Seconds())
				}()
				late, worst, noted = 0, 0, now
			}
			last = now
			r.renewVideo()
			sleep(leaseEvery)
		}
	}()
	return func() { stopping.Store(true); <-done; atomic.StoreUint32(&r.hdr[29], 0); r.clearBrightness() }
}

// renewVideo publishes the current request with a new lease sequence.
func (r *Ring) renewVideo() {
	r.video.mu.Lock()
	if !r.video.deadline.IsZero() && !time.Now().Before(r.video.deadline) {
		r.video.mode = r.video.previous
		r.video.deadline = time.Time{}
	}
	mode := r.video.mode
	r.video.mu.Unlock()
	seq := (atomic.LoadUint32(&r.hdr[28]) + 2) &^ 1
	atomic.StoreUint32(&r.hdr[28], seq|1)
	atomic.StoreUint32(&r.hdr[29], 0x56500000|mode)
	atomic.StoreUint32(&r.hdr[30], seq)
	atomic.StoreUint32(&r.hdr[28], seq)
	r.writeBrightness()
}

// sleep waits in the kernel, finishing the time a signal interrupted.
func sleep(d time.Duration) {
	ts := syscall.NsecToTimespec(int64(d))
	for syscall.Nanosleep(&ts, &ts) == syscall.EINTR {
	}
}

// SetVideo restores a known preference without starting another trial.
func (r *Ring) SetVideo(mode uint32) {
	r.video.mu.Lock()
	defer r.video.mu.Unlock()
	if mode != 2 {
		mode = 0
	}
	r.video.mode = mode
	r.video.deadline = time.Time{}
}

func (r *Ring) VideoStatus() (mode uint32, override, supported bool) {
	v := atomic.LoadUint32(&r.hdr[27])
	return v & 3, v&4 != 0, v&0xfffffff0 == 0x56500000
}

// VideoLocked reports the core's active CRT-profile safety interlock.
func (r *Ring) VideoLocked() bool {
	v := atomic.LoadUint32(&r.hdr[27])
	return v&0xfffffff0 == 0x56500000 && v&8 != 0
}

// Tap is read by the core each scanline and goes straight to its audio mixer.
func (r *Ring) Tap() {
	atomic.AddUint32(&r.hdr[31], 1)
}

func (r *Ring) TryVideo(mode uint32) time.Time {
	r.video.mu.Lock()
	defer r.video.mu.Unlock()
	r.video.previous = r.video.mode
	r.video.mode = mode
	r.video.deadline = time.Now().Add(15 * time.Second)
	return r.video.deadline
}

func (r *Ring) FinishVideo(keep bool) bool {
	r.video.mu.Lock()
	defer r.video.mu.Unlock()
	valid := !r.video.deadline.IsZero() && time.Now().Before(r.video.deadline)
	if !valid {
		return false
	}
	if r.VideoLocked() {
		keep = false
	}
	if !keep {
		r.video.mode = r.video.previous
	}
	r.video.deadline = time.Time{}
	return keep
}
