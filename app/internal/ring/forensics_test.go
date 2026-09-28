package ring

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"unsafe"
)

func fakeRing() *Ring {
	mem := make([]byte, mapSize)
	return &Ring{mem: mem, hdr: (*[32]uint32)(unsafe.Pointer(&mem[0])), stat: (*[4]uint32)(unsafe.Pointer(&mem[statOff]))}
}

func TestCanariesTellClearFromPainter(t *testing.T) {
	r := fakeRing()
	r.plantCanaries()
	if hit, _, _ := r.canaryState(); hit != 0 {
		t.Fatalf("fresh canaries reported %d hits", hit)
	}
	for _, off := range canaryOffs {
		*r.word(off) = 0
	}
	if hit, zeroed, _ := r.canaryState(); hit != len(canaryOffs) || !zeroed {
		t.Fatalf("a clear read as hit=%d zeroed=%v", hit, zeroed)
	}
	r.plantCanaries()
	*r.word(canaryOffs[1]) = 0xff203040
	hit, zeroed, first := r.canaryState()
	if hit != 1 || zeroed || first != 0xff203040 {
		t.Fatalf("a painter read as hit=%d zeroed=%v first=%08x", hit, zeroed, first)
	}
	if !strings.Contains(describeCanaries(hit, zeroed, first), "painting") {
		t.Fatalf("description %q", describeCanaries(hit, zeroed, first))
	}
}

func TestCanariesStayOutOfTheRing(t *testing.T) {
	for _, off := range canaryOffs {
		if off < 0x80 || off+4 > slot0 {
			t.Fatalf("canary at 0x%x overlaps the header block or slot 0", off)
		}
	}
}

func TestMappersFindFramebufferAndPhysicalMappings(t *testing.T) {
	proc := t.TempDir()
	add := func(pid, comm, maps string, fds ...string) {
		dir := filepath.Join(proc, pid)
		os.MkdirAll(filepath.Join(dir, "fd"), 0755)
		os.WriteFile(filepath.Join(dir, "comm"), []byte(comm+"\n"), 0644)
		os.WriteFile(filepath.Join(dir, "maps"), []byte(maps), 0644)
		for i, target := range fds {
			os.Symlink(target, filepath.Join(dir, "fd", string(rune('3'+i))))
		}
	}
	add("10", "frontend", "b6000000-b6800000 rw-s 00000000 00:06 12 /dev/fb0\n", "/dev/fb0")
	add("11", "MiSTer", "b5000000-b5800000 rw-s 30000000 00:06 3 /dev/mem\nb4000000-b4001000 rw-s ff200000 00:06 3 /dev/mem\n")
	add("12", "zaparoo", "b3000000-b3001000 r--s 20000000 00:06 3 /dev/mem\n")
	add("13", "self", "b6000000-b6800000 rw-s 00000000 00:06 12 /dev/fb0\n")
	got := strings.Join(mappers(proc, 0x30000000, mapSize, 13), "; ")
	want := "frontend(10) fd+fb0-map; MiSTer(11) mem-rw"
	if got != want {
		t.Fatalf("mappers = %q, want %q", got, want)
	}
}
