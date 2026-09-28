package ring

import (
	"sync/atomic"
	"testing"
	"time"
)

func TestBrightnessWord(t *testing.T) {
	r := fakeRing()
	word := func() uint32 { return atomic.LoadUint32(r.word(brightOff)) }
	r.writeBrightness()
	if word() != brightTag|Full {
		t.Fatalf("a new ring must ask for full brightness, wrote %08x", word())
	}
	for _, c := range []struct{ in, want int }{{64, 64}, {-5, 0}, {999, Full}, {Full, Full}} {
		r.SetBrightness(c.in)
		if word() != brightTag|uint32(c.want) {
			t.Fatalf("SetBrightness(%d) wrote %08x", c.in, word())
		}
	}
}

func TestBrightnessSurvivesWipeAndClearsOnStop(t *testing.T) {
	r := fakeRing()
	word := func() uint32 { return atomic.LoadUint32(r.word(brightOff)) }
	r.SetBrightness(64)
	stop := r.StartVideo(0, nil)
	atomic.StoreUint32(r.word(brightOff), 0) // the framebuffer driver clears the ring
	time.Sleep(350 * time.Millisecond)
	if word() != brightTag|64 {
		t.Fatalf("the lease did not put the dim back: %08x", word())
	}
	stop()
	if word() != 0 {
		t.Fatalf("a stopped app must leave the core at full brightness: %08x", word())
	}
}

func TestBrightnessEcho(t *testing.T) {
	r := fakeRing()
	o := &Overlay{r: r}
	atomic.StoreUint32(&r.hdr[26], 123) // an older core: the dot only
	if _, ok := r.Brightness(); ok {
		t.Fatal("an older core reported dimming")
	}
	atomic.StoreUint32(&r.hdr[26], 64<<16|123)
	if level, ok := r.Brightness(); !ok || level != 64 || o.DotX() != 123 {
		t.Fatalf("echo misread: level %d ok %v dot %d", level, ok, o.DotX())
	}
	atomic.StoreUint32(&r.hdr[26], Full<<16)
	if level, ok := r.Brightness(); !ok || level != Full {
		t.Fatalf("full brightness misread: %d %v", level, ok)
	}
}
