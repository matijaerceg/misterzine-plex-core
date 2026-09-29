package ring

import (
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestVideoRollbackAndLease(t *testing.T) {
	r := &Ring{hdr: new([32]uint32)}
	stop := r.StartVideo(0, nil)
	defer stop()
	r.TryVideo(2)
	r.video.mu.Lock()
	r.video.deadline = time.Now().Add(40 * time.Millisecond)
	r.video.mu.Unlock()
	time.Sleep(350 * time.Millisecond)
	if v := atomic.LoadUint32(&r.hdr[29]); v != 0x56500000 {
		t.Fatalf("rollback failed: %x", v)
	}
	if r.FinishVideo(true) {
		t.Fatal("expired trial was confirmed")
	}
	r.TryVideo(2)
	if !r.FinishVideo(true) {
		t.Fatal("live trial not confirmed")
	}
	time.Sleep(300 * time.Millisecond)
	if atomic.LoadUint32(&r.hdr[29]) != 0x56500002 {
		t.Fatal("confirmation did not stick")
	}
	a, b := atomic.LoadUint32(&r.hdr[28]), atomic.LoadUint32(&r.hdr[30])
	if a != b || a&1 != 0 {
		t.Fatal("invalid seqlock")
	}
}

// renewed waits for the lease's next renewal.
func renewed(t *testing.T, r *Ring) {
	t.Helper()
	seq, deadline := atomic.LoadUint32(&r.hdr[28]), time.Now().Add(2*time.Second)
	for atomic.LoadUint32(&r.hdr[28]) == seq {
		if time.Now().After(deadline) {
			t.Fatal("the lease was not renewed")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// lateRenewal holds the request until the renewal due meanwhile comes well
// over leaseLate after the one before: it waits on the lock from about 250
// ms in, and the gap is measured at the renewal after it.
func lateRenewal(t *testing.T, r *Ring) {
	t.Helper()
	renewed(t, r)
	r.video.mu.Lock()
	time.Sleep(700 * time.Millisecond)
	r.video.mu.Unlock()
	renewed(t, r)
}

func TestLateLeaseRenewalIsLogged(t *testing.T) {
	r := &Ring{hdr: new([32]uint32)}
	lines := make(chan string, 4)
	stop := r.StartVideo(0, func(f string, a ...any) { lines <- fmt.Sprintf(f, a...) })
	defer stop()
	renewed(t, r)
	time.Sleep(300 * time.Millisecond)
	select {
	case l := <-lines:
		t.Fatalf("renewals on time were logged: %q", l)
	default:
	}
	lateRenewal(t, r)
	select {
	case l := <-lines:
		if !strings.HasPrefix(l, "video lease: 1 late renewal(s), the longest ") {
			t.Fatalf("logged %q", l)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("a late renewal was not logged")
	}
}

func TestLateRenewalNotesNeverPileUp(t *testing.T) {
	defer func(d time.Duration) { leaseNoteEvery = d }(leaseNoteEvery)
	leaseNoteEvery = 0
	r := &Ring{hdr: new([32]uint32)}
	var mu sync.Mutex
	inFlight, most := 0, 0
	entered, release, counts := make(chan struct{}, 8), make(chan struct{}), make(chan int, 8)
	stop := r.StartVideo(0, func(f string, a ...any) { // a note stuck behind a slow writer
		mu.Lock()
		inFlight++
		most = max(most, inFlight)
		mu.Unlock()
		entered <- struct{}{}
		<-release
		counts <- a[0].(int)
		mu.Lock()
		inFlight--
		mu.Unlock()
	})
	defer stop()
	lateRenewal(t, r)
	select {
	case <-entered:
	case <-time.After(2 * time.Second):
		t.Fatal("the first late renewal was not noted")
	}
	lateRenewal(t, r) // two more while that note is stuck
	lateRenewal(t, r)
	time.Sleep(300 * time.Millisecond)
	mu.Lock()
	if most != 1 {
		t.Fatalf("%d notes written at once", most)
	}
	mu.Unlock()
	close(release)
	var got []int
	for len(got) < 2 {
		select {
		case n := <-counts:
			got = append(got, n)
		case <-time.After(2 * time.Second):
			t.Fatalf("notes after the stuck one was let go: %v", got)
		}
	}
	// scheduler pauses on a busy machine may add to either count, never take away
	if got[0] < 1 || got[1] < 2 {
		t.Fatalf("late renewals counted %v, want the stuck note's then at least the 2 held back", got)
	}
}

func TestCRTProfileStatusAndConfirmation(t *testing.T) {
	r := &Ring{hdr: new([32]uint32)}
	for _, status := range []uint32{0x56500008, 0x5650000c} {
		atomic.StoreUint32(&r.hdr[27], status)
		mode, override, supported := r.VideoStatus()
		if !r.VideoLocked() || !supported || mode != 0 || override != (status&4 != 0) {
			t.Fatal("CRT status was misread")
		}
		r.TryVideo(2)
		if r.FinishVideo(true) {
			t.Fatal("CRT profile accepted 480p confirmation")
		}
	}
	atomic.StoreUint32(&r.hdr[27], 0x56500002)
	if r.VideoLocked() {
		t.Fatal("HDMI profile stayed locked")
	}
	r.TryVideo(2)
	if !r.FinishVideo(true) {
		t.Fatal("HDMI confirmation rejected")
	}
}
