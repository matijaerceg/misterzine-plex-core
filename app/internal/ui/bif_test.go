package ui

import (
	"encoding/binary"
	"fmt"
	"sync"
	"testing"
	"time"

	"plexcrt/internal/gfx"
)

// bifFile makes a BIF of n frames every ten seconds with the given unit
// (0 for the default), each frame's bytes its index repeated.
func bifFile(n int, unit uint32, frameLen int) []byte {
	le := binary.LittleEndian
	head := make([]byte, 64+8*(n+1))
	copy(head, bifMagic)
	le.PutUint32(head[12:], uint32(n))
	le.PutUint32(head[16:], unit)
	step := uint32(10)
	if unit != 0 {
		step = 10000 / unit
	}
	data := head
	for i := 0; i <= n; i++ {
		ts := uint32(i) * step
		if i == n {
			ts = 0xFFFFFFFF
		}
		le.PutUint32(head[64+8*i:], ts)
		le.PutUint32(head[64+8*i+4:], uint32(len(head)+i*frameLen))
	}
	for i := 0; i < n; i++ {
		for j := 0; j < frameLen; j++ {
			data = append(data, byte(i))
		}
	}
	return data
}

func TestParseBIFReadsTheIndex(t *testing.T) {
	for _, unit := range []uint32{0, 1000, 1} {
		b, err := parseBIF(bifFile(5, unit, 3))
		if err != nil {
			t.Fatalf("unit %d: %v", unit, err)
		}
		if len(b.at) != 5 || b.at[2] != 20000 {
			t.Fatalf("unit %d: times %v", unit, b.at)
		}
		if f := b.jpeg(3); len(f) != 3 || f[0] != 3 {
			t.Fatalf("unit %d: frame 3 is %v", unit, f)
		}
		for _, c := range []struct {
			t    float64
			want int
		}{{0, 0}, {9.9, 0}, {10, 1}, {25, 2}, {49, 4}, {500, 4}, {-3, 0}} {
			if got := b.frame(c.t); got != c.want {
				t.Fatalf("unit %d: frame at %v is %d, want %d", unit, c.t, got, c.want)
			}
		}
	}
}

func TestParseBIFRefusesWhatDoesNotHoldTogether(t *testing.T) {
	good := bifFile(4, 0, 10)
	cases := map[string][]byte{
		"empty":     nil,
		"short":     good[:40],
		"truncated": good[:len(good)-5], // the last frame runs past the end
		"index cut": good[:64+8*3],
	}
	bad := append([]byte(nil), good...)
	bad[0] = 'X'
	cases["magic"] = bad
	huge := append([]byte(nil), good...)
	binary.LittleEndian.PutUint32(huge[12:], 1<<30)
	cases["count"] = huge
	back := append([]byte(nil), good...)
	binary.LittleEndian.PutUint32(back[64+8*2+4:], 70) // into the index, and backwards
	cases["offset"] = back
	early := append([]byte(nil), good...)
	binary.LittleEndian.PutUint32(early[64+8*1:], 0xFFFFFFFF)
	cases["early end"] = early
	for name, data := range cases {
		if _, err := parseBIF(data); err == nil {
			t.Errorf("%s: parsed", name)
		}
	}
}

// The decoder keeps at most bifCache frames, the least recently used going.
func TestBIFPreviewKeepsAFewFrames(t *testing.T) {
	b := &bifPreview{want: -1, frames: map[int]*bifFrame{}}
	for i := 0; i < bifCache+5; i++ {
		b.add(i, nil)
	}
	if len(b.frames) != bifCache || b.frames[0] != nil || b.frames[bifCache+4] == nil {
		t.Fatalf("kept %d frames", len(b.frames))
	}
}

// The decodes lead the way the scrub moves: the frame under it, then
// more ahead than behind, and the other way round when it turns.
func TestBIFDecodesAheadOfTheScrub(t *testing.T) {
	idx, err := parseBIF(bifFile(100, 0, 1))
	if err != nil {
		t.Fatal(err)
	}
	b := &bifPreview{want: -1, dir: 1, frames: map[int]*bifFrame{}, index: idx}
	b.cond = sync.NewCond(&b.mu)
	order := func() string {
		var got []int
		for i := b.next(); i >= 0 && len(got) < 5; i = b.next() {
			got = append(got, i)
			b.frames[i] = &bifFrame{img: &gfx.Image{}}
		}
		clear(b.frames)
		return fmt.Sprint(got)
	}
	b.Near(500)
	if got := order(); got != "[50 51 52 53 49]" {
		t.Fatalf("at the start: %s", got)
	}
	b.Near(400)
	if got := order(); got != "[40 39 38 37 41]" {
		t.Fatalf("going back: %s", got)
	}
	// a run: the decodes aim where the dot will be when they are done
	b.Near(500)
	b.speed, b.dec, b.movedAt = 40, 0.1, time.Now()
	if got := order(); got != "[56 57 58 59 55]" {
		t.Fatalf("in a run: %s", got)
	}
	b.movedAt = time.Now().Add(-time.Second)
	if got := order(); got != "[50 51 52 53 49]" {
		t.Fatalf("at rest again: %s", got)
	}
	if len(bifOrder) != 1+bifAhead+bifBehind {
		t.Fatalf("order %v", bifOrder)
	}
}
