package ring

import (
	"os"
	"syscall"
	"testing"
	"unsafe"
)

// opaqueWordLoop is the plain copy copyOpaque must match: one word a pixel.
func opaqueWordLoop(dst, src []uint32) {
	for i, p := range src {
		dst[i] = p | 0xFF000000
	}
}

func TestCopyOpaqueMatchesWordLoop(t *testing.T) {
	src := make([]uint32, 800)
	for i := range src {
		src[i] = uint32(i) * 2654435761 // top bytes set and clear
	}
	check := func(soff, doff, n int) {
		t.Helper()
		want := make([]uint32, doff+n+9)
		for i := range want {
			want[i] = 0x12345678
		}
		got := append([]uint32(nil), want...)
		opaqueWordLoop(want[doff:], src[soff:soff+n])
		copyOpaque(got[doff:], src[soff:soff+n])
		for i := range want {
			if got[i] != want[i] {
				t.Fatalf("src+%d dst+%d n %d: word %d = %08x, want %08x", soff, doff, n, i, got[i], want[i])
			}
		}
	}
	for _, off := range []int{0, 1, 3, 7} {
		for n := 0; n <= 70; n++ {
			check(off, off, n)
			check(off, 5, n)
		}
		check(off, off, 720)
	}
}

// benchOpaque copies a 720x480 frame row by row into a page as publishFrame
// does, with each of fills: into ordinary memory, and into the framebuffer
// as well when RING_BENCH_FB names one (it draws over the screen's first
// page). The frame is larger than the CPU's caches, as on the device.
func benchOpaque(b *testing.B, fills []opaqueFill) {
	const w, h = 720, 480
	stride := (w*4 + 7) &^ 7 / 4
	src := make([]uint32, w*h)
	for i := range src {
		src[i] = uint32(i) * 2654435761 & 0xFFFFFF
	}
	targets := []struct {
		name string
		page []uint32
	}{{"mem", make([]uint32, stride*h)}}
	if path := os.Getenv("RING_BENCH_FB"); path != "" {
		targets = append(targets, struct {
			name string
			page []uint32
		}{"fb", mapBenchFB(b, path, stride*h*4)})
	}
	for _, target := range targets {
		for _, f := range fills {
			b.Run(target.name+"/"+f.name, func(b *testing.B) {
				page := target.page
				b.SetBytes(w * h * 4)
				for b.Loop() {
					for y := 0; y < h; y++ {
						f.fill(page[y*stride:y*stride+w], src[y*w:(y+1)*w])
					}
				}
			})
		}
	}
}

type opaqueFill struct {
	name string
	fill func(dst, src []uint32)
}

func mapBenchFB(b *testing.B, path string, n int) []uint32 {
	b.Helper()
	f, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		b.Fatal(err)
	}
	defer f.Close()
	m, err := syscall.Mmap(int(f.Fd()), 0, n, syscall.PROT_READ|syscall.PROT_WRITE, syscall.MAP_SHARED)
	if err != nil {
		b.Fatalf("mapping %d bytes of %s: %v", n, path, err)
	}
	b.Cleanup(func() { syscall.Munmap(m) })
	return unsafe.Slice((*uint32)(unsafe.Pointer(&m[0])), n/4)
}

func BenchmarkOpaqueCopy(b *testing.B) {
	benchOpaque(b, []opaqueFill{
		{"words", opaqueWordLoop},
		{"copyOpaque", copyOpaque},
		{"dim", func(dst, src []uint32) { fillOpaque(dst, src, Full/2) }},
	})
}
