package ring

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"
	"syscall"
	"unsafe"
)

var iomemFile = "/proc/iomem"

// rangeFree reports whether [base, base+n) overlaps none of /proc/iomem's
// "System RAM" lines: the library's rule, never map memory Linux uses.
func rangeFree(base, n uint64) bool {
	f, err := os.Open(iomemFile)
	if err != nil {
		return true // nothing to check against
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		if strings.HasPrefix(line, " ") || !strings.Contains(line, "System RAM") {
			continue
		}
		span, _, _ := strings.Cut(strings.TrimSpace(line), " ")
		a, b, ok := strings.Cut(span, "-")
		if !ok {
			continue
		}
		lo, err1 := strconv.ParseUint(a, 16, 64)
		hi, err2 := strconv.ParseUint(b, 16, 64)
		if err1 == nil && err2 == nil && !(hi < base || lo >= base+n) {
			return false
		}
	}
	return true
}

// mapCtrl maps the control block's 4 KB as the library does: /dev/mem
// O_SYNC (an uncached mapping), after checking it is not System RAM. Only
// the control block: the ring is the player's.
func mapCtrl() ([]byte, error) {
	if !rangeFree(ctrlByte, ctrlLen) {
		return nil, fmt.Errorf("the control block at 0x%x is System RAM: not a MiSTer with the core's memory reserved", ctrlByte)
	}
	fd, err := syscall.Open("/dev/mem", syscall.O_RDWR|syscall.O_SYNC|syscall.O_CLOEXEC, 0)
	if err != nil {
		return nil, fmt.Errorf("/dev/mem: %w", err)
	}
	defer syscall.Close(fd) // the mapping outlives the descriptor
	m, err := syscall.Mmap(fd, ctrlByte, ctrlLen, syscall.PROT_READ|syscall.PROT_WRITE, syscall.MAP_SHARED)
	if err != nil {
		return nil, fmt.Errorf("mapping the control block: %w", err)
	}
	return m, nil
}

// fbFix is the head of struct fb_fix_screeninfo: char id[16], unsigned
// long smem_start, __u32 smem_len (unsigned long is the word size).
type fbFix struct {
	ID        [16]byte
	SmemStart uintptr
	SmemLen   uint32
	_         [64]byte // the rest, which this package does not read
}

const fbioGetFScreenInfo = 0x4602

// mapFB maps /dev/fb0 whole and lays the pages out at its start, after
// checking the driver's memory lies inside the region the core reads.
func (r *Ring) mapFB() error {
	f, err := os.OpenFile("/dev/fb0", os.O_RDWR, 0)
	if err != nil {
		return err
	}
	defer f.Close()
	var fix fbFix
	if _, _, e := syscall.Syscall(syscall.SYS_IOCTL, f.Fd(), fbioGetFScreenInfo, uintptr(unsafe.Pointer(&fix))); e != 0 {
		return fmt.Errorf("/dev/fb0: FBIOGET_FSCREENINFO: %w", e)
	}
	start, n := uint64(fix.SmemStart), uint64(fix.SmemLen)
	if n == 0 || start < fbByte || start+n > fbByte+fbSize {
		return fmt.Errorf("/dev/fb0 is 0x%x+0x%x, not inside the region the core reads (0x%x+0x%x)", start, n, fbByte, fbSize)
	}
	if n < uint64(NPage*r.opage) {
		// Native pages are useful only when both can flip without tearing.
		// Keep the larger video and use a centered logical canvas instead.
		r.setOutput(W, H)
		fmt.Fprintf(os.Stderr, "ring: /dev/fb0 maps %d bytes; using centered %dx%d overlay pages instead of native raster\n", n, W, H)
	}
	if n < uint64(r.opage) {
		return fmt.Errorf("/dev/fb0 maps %d bytes, less than one %dx%d page", n, r.ow, r.oh)
	}
	m, err := syscall.Mmap(int(f.Fd()), 0, int(n), syscall.PROT_READ|syscall.PROT_WRITE, syscall.MAP_SHARED)
	if err != nil {
		return fmt.Errorf("mapping /dev/fb0: %w", err)
	}
	r.fb, r.fbPhys = m, uint32(start)
	r.setPages()
	return nil
}

// The console draws its blinking cursor into the framebuffer on its own,
// a flickering speck in the overlay; the library stops the blink and
// hides the cursor while it has the framebuffer mapped, and so does this.
var blinkFile = "/sys/class/graphics/fbcon/cursor_blink"

func quietCursor() int {
	blink := -1
	if b, err := os.ReadFile(blinkFile); err == nil {
		if v, err := strconv.Atoi(strings.TrimSpace(string(b))); err == nil {
			blink = v
		}
	}
	cursor(false, 0, blink >= 0)
	return blink
}

func restoreCursor(blink int) { cursor(true, blink, blink >= 0) }

func cursor(show bool, blink int, setBlink bool) {
	if f, err := os.OpenFile("/dev/tty1", os.O_WRONLY|syscall.O_NOCTTY, 0); err == nil {
		seq := "\033[?25l"
		if show {
			seq = "\033[?25h"
		}
		f.WriteString(seq)
		f.Close()
	}
	if setBlink {
		os.WriteFile(blinkFile, []byte(strconv.Itoa(blink)+"\n"), 0)
	}
}
