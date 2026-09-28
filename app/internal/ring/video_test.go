package ring

import (
	"fmt"
	"strings"
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

func TestLateLeaseRenewalIsLogged(t *testing.T) {
	r := &Ring{hdr: new([32]uint32)}
	lines := make(chan string, 4)
	stop := r.StartVideo(0, func(f string, a ...any) { lines <- fmt.Sprintf(f, a...) })
	defer stop()
	time.Sleep(300 * time.Millisecond)
	select {
	case l := <-lines:
		t.Fatalf("renewals on time were logged: %q", l)
	default:
	}
	r.video.mu.Lock() // the renewal waits on the request
	time.Sleep(700 * time.Millisecond)
	r.video.mu.Unlock()
	select {
	case l := <-lines:
		if !strings.HasPrefix(l, "video lease: 1 late renewal(s), the longest 0.") {
			t.Fatalf("logged %q", l)
		}
	case <-time.After(time.Second):
		t.Fatal("a renewal 0.7 s late was not logged")
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
