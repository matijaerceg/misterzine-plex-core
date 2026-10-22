package ring

import (
	"testing"
	"time"
)

func TestEndEveryBoundsAStalledHeartbeat(t *testing.T) {
	f := newFake(t, false)
	f.r.EndEvery(1) // establish cadence
	f.r.pending = false

	start := time.Now()
	missed := f.r.EndEvery(1)
	elapsed := time.Since(start)
	if !missed {
		t.Fatal("stalled heartbeat was not reported as missed")
	}
	if elapsed < cadenceWait || elapsed > 2*cadenceWait {
		t.Fatalf("stalled heartbeat wait took %s, want about %s", elapsed, cadenceWait)
	}
}

func TestCadenceTargetEveryField(t *testing.T) {
	for _, tc := range []struct {
		previous, current, want uint32
		missed                  bool
	}{
		{100, 100, 101, false}, {100, 101, 101, false},
		{100, 102, 102, true}, {0xffffffff, 0, 0, false},
		{0xffffffff, 1, 1, true},
	} {
		got, missed := cadenceTarget(tc.previous, tc.current, 1)
		if got != tc.want || missed != tc.missed {
			t.Fatalf("got %d/%v, want %d/%v", got, missed, tc.want, tc.missed)
		}
	}
}

func TestCadenceTargetPreservesParity(t *testing.T) {
	for _, tc := range []struct {
		previous, current, want uint32
		missed                  bool
	}{
		{100, 100, 102, false}, {100, 101, 102, false}, {100, 102, 102, false},
		{100, 103, 104, true}, {100, 104, 104, true}, {100, 105, 106, true},
		{0xfffffffe, 0xffffffff, 0, false}, {0xfffffffe, 0, 0, false},
		{0xfffffffe, 1, 2, true}, {0xffffffff, 0, 1, false},
	} {
		got, missed := cadenceTarget(tc.previous, tc.current, 2)
		if got != tc.want || missed != tc.missed {
			t.Fatalf("previous=%d current=%d: got %d/%v, want %d/%v", tc.previous, tc.current, got, missed, tc.want, tc.missed)
		}
	}
}
