// Package ring is the MiSTer side of the PlexCRT frame ring: the header,
// status words, four frame slots that the core scans out of DDR and an
// overlay plane it blends over them, mapped through /dev/fb0 (see
// arm/plexfb.c and rtl/ddr_scanout.v for the layout).
//
//	BASE+0x00  header: magic, seq, buf, width, height, stride, fmt, u_off, v_off, flags
//	BASE+0x28  overlay: seq_a, x|y<<16, w|h<<16, addr, en, seq_b (a seqlock)
//	BASE+0x40  status: field_cnt, seq_shown, joy (joy1<<16|joy0), key (key_cnt<<11|ps2)
//	BASE+0x50  sprites: dot x|y<<16|en<<31, dot rgb, bar x|y<<16|en<<31, bar w|h<<16, bar rgb
//	BASE+0x88  brightness: 0x444D0000|level, level of 256 (see bright.go)
//	BASE+0x100000 + slot*0x160000  frame slots, xRGB8888 720x480
//	BASE+0x680000 .. 0x7E0000      overlay pixels, ARGB8888
package ring

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"

	"plexcrt/internal/gfx"
)

const (
	NSlot    = 4
	mapSize  = 0x7E0000 // what /dev/fb0 maps
	osdOff   = 0x680000
	osdSize  = 0x160000
	slot0    = 0x100000
	slotSize = 0x160000
	statOff  = 0x40
	magic    = 0x504C4558
	W, H     = 720, 480
)

// Ring is the mapped frame ring.
type Ring struct {
	video           VideoControl
	mem             []byte
	hdr             *[32]uint32
	stat            *[4]uint32
	slot            uint32 // slot handed out by Begin
	last            uint32 // field counter at the last observed change
	lastT           time.Time
	waited          uint32 // field counter when WaitField returned
	waitedT, endedT time.Time
	ended           uint32 // field counter at End
	seq             uint32 // header seq we last published
	pubSeq          uint32 // the same, readable from Watch's goroutine
	cadence         bool
	cadenceField    uint32 // field of the previous cadence-controlled publication
	dim             uint32 // Full minus the brightness asked of the core
}

// Open maps /dev/fb0. It fails if the core is not the one exporting the ring.
func Open() (*Ring, error) {
	f, err := os.OpenFile("/dev/fb0", os.O_RDWR, 0)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	// Look for the core through one page, which any mode maps, before
	// enlarging the mode: the write clears main's menu wallpaper as well.
	head, err := syscall.Mmap(int(f.Fd()), 0, 4096, syscall.PROT_READ, syscall.MAP_SHARED)
	if err != nil {
		return nil, err
	}
	running := (&Ring{hdr: (*[32]uint32)(unsafe.Pointer(&head[0])), stat: (*[4]uint32)(unsafe.Pointer(&head[statOff]))}).CoreRunning(2 * time.Second)
	syscall.Munmap(head)
	if !running {
		return nil, errNotRunning
	}
	var mem []byte
	for try := 0; ; try++ {
		from, werr := enlargeMode()
		mem, err = syscall.Mmap(int(f.Fd()), 0, mapSize, syscall.PROT_READ|syscall.PROT_WRITE, syscall.MAP_SHARED)
		if err == nil {
			break
		}
		// main's own mode write can land between ours and the mapping
		if err != syscall.EINVAL || try == 20 {
			if werr != nil {
				return nil, fmt.Errorf("framebuffer mode %q maps less than the frame ring and could not be changed: %v", from, werr)
			}
			return nil, fmt.Errorf("cannot map the frame ring (framebuffer mode %q): %w", readMode(), err)
		}
		time.Sleep(50 * time.Millisecond)
	}
	r := &Ring{mem: mem}
	r.hdr = (*[32]uint32)(unsafe.Pointer(&mem[0]))
	r.stat = (*[4]uint32)(unsafe.Pointer(&mem[statOff]))
	return r, nil
}

var errNotRunning = errors.New("MisterZine Plex Core is not running; launch MisterZine Plex Core from Scripts")

// CoreRunning reports whether the core is still scanning the ring: within
// the given time its field counter moves on to a nonzero value beside its
// status signature. A framebuffer mode write zeroes both until the core's
// next vsync (every 16.7 ms), and any other core leaves the last values
// alone, so neither a wipe nor a stale counter reads as running. Once the
// core has gone, this memory is MiSTer main's again.
func (r *Ring) CoreRunning(within time.Duration) bool {
	start := r.Field()
	deadline := time.Now().Add(within)
	for {
		if f := r.Field(); f != start && f != 0 {
			if _, _, ok := r.VideoStatus(); ok {
				return true
			}
		}
		if !time.Now().Before(deadline) {
			return false
		}
		time.Sleep(2 * time.Millisecond)
	}
}

// Close unmaps the ring (the published frame stays on screen).
func (r *Ring) Close() { syscall.Munmap(r.mem) }

// Begin returns a canvas over the slot after the published one (never on
// screen, whoever published it). Draw into it with writes only: the memory
// is write-combined, so reading it back is slow.
func (r *Ring) Begin() *gfx.Canvas {
	r.slot = 0
	if atomic.LoadUint32(&r.hdr[0]) == magic {
		r.slot = (atomic.LoadUint32(&r.hdr[2]) + 1) % NSlot
	}
	off := slot0 + int(r.slot)*slotSize
	return gfx.Over(r.mem[off:off+W*H*4], W, H)
}

// End publishes the slot from Begin.
func (r *Ring) End() {
	r.cadence = false
	r.publish()
}

// ResetCadence releases the schedule when a transition finishes, even if the
// app then idles without publishing another ordinary frame.
func (r *Ring) ResetCadence() { r.cadence = false }

func (r *Ring) publish() {
	r.hdr[3], r.hdr[4], r.hdr[5], r.hdr[6], r.hdr[7], r.hdr[8], r.hdr[9] = W, H, W*4, 0, 0, 0, 0
	atomic.StoreUint32(&r.hdr[2], r.slot)
	atomic.StoreUint32(&r.hdr[0], magic)
	r.seq = atomic.LoadUint32(&r.hdr[1]) + 1
	atomic.StoreUint32(&r.pubSeq, r.seq)
	atomic.StoreUint32(&r.hdr[1], r.seq)
	r.ended = r.Field()
	r.endedT = time.Now()
}

// EndEvery publishes on a fixed field-counter cadence. Rendering happens
// before this wait, giving the renderer the full interval between vsyncs.
// The FPGA has already latched this field's header when Field changes, so
// each publication is captured at the following vsync. If rendering overruns,
// skip a whole cadence slot rather than alternating long and short intervals.
// Returns true if a scheduled slot was missed. A stopped core cannot hang it.
func (r *Ring) EndEvery(fields uint32) bool {
	if fields == 0 {
		r.End()
		return false
	}
	if !r.cadence {
		r.cadence = true
		r.cadenceField = r.Field()
		r.publish()
		return false
	}
	target, missed := cadenceTarget(r.cadenceField, r.Field(), fields)
	deadline := time.Now().Add(50 * time.Millisecond)
	for time.Now().Before(deadline) {
		current := r.Field()
		if int32(current-target) > 0 {
			target, _ = cadenceTarget(r.cadenceField, current, fields)
			missed = true
		}
		if current == target {
			break
		}
		r.WaitField(20 * time.Millisecond)
	}
	current := r.Field()
	if current != target {
		missed = true
	}
	r.publish()
	r.cadenceField = current
	return missed
}

func cadenceTarget(previous, current, fields uint32) (uint32, bool) {
	target := previous + fields
	late := int32(current - target)
	if late <= 0 {
		return target, false
	}
	return target + ((uint32(late)+fields-1)/fields)*fields, true
}

// Foreign reports whether another process (the video presenter) has
// published a frame since our last End. A header wiped by a framebuffer
// mode write has lost its magic and is no one's frame.
func (r *Ring) Foreign() bool {
	return atomic.LoadUint32(&r.hdr[0]) == magic && atomic.LoadUint32(&r.hdr[1]) != r.seq
}

// Published is the header's frame number, which moves with every frame
// published by anyone, and false when the header has been wiped.
func (r *Ring) Published() (uint32, bool) {
	return atomic.LoadUint32(&r.hdr[1]), atomic.LoadUint32(&r.hdr[0]) == magic
}

// Present copies a canvas into the next slot and publishes it.
func (r *Ring) Present(c *gfx.Canvas) error {
	if c.W != W || c.H != H {
		return errors.New("canvas is not 720x480")
	}
	dst := r.Begin()
	copy(dst.Pix, c.Pix)
	r.End()
	return nil
}

// Blank publishes a black frame.
func (r *Ring) Blank() {
	c := r.Begin()
	c.Fill(0, 0, W, H, gfx.Black)
	r.End()
}

// Field returns the core's field counter (60 Hz).
func (r *Ring) Field() uint32 { return atomic.LoadUint32(&r.stat[0]) }

// TraceStatus samples display acknowledgement and publication for opt-in timing diagnostics.
func (r *Ring) TraceStatus() (field, published, shown uint32) {
	for {
		field = r.Field()
		shown = atomic.LoadUint32(&r.stat[1])
		published = atomic.LoadUint32(&r.hdr[1])
		if field == r.Field() {
			return
		}
	}
}

// WaitField blocks until the field counter changes, at most maxWait. It
// sleeps until a few ms before the field is due (16.68 ms after the last
// one) and spins for the rest: the kernel's sleep granularity is coarse
// enough to miss a field, and a missed field is a visible hitch.
func (r *Ring) WaitField(maxWait time.Duration) {
	const field = 16683 * time.Microsecond
	start := r.Field()
	now := time.Now()
	if start != r.last {
		r.last, r.lastT = start, now
	}
	if due := r.lastT.Add(field - 4*time.Millisecond); due.After(now) && due.Sub(now) < maxWait {
		time.Sleep(due.Sub(now))
	}
	deadline := now.Add(maxWait)
	for r.Field() == start && time.Now().Before(deadline) {
	}
	if f := r.Field(); f != start {
		r.last, r.lastT = f, time.Now()
	}
	r.waited = r.Field()
	r.waitedT = time.Now()
}

// Late is how long after WaitField returned the last End happened, and
// how far into its field WaitField returned (diagnostics for missed fields).
func (r *Ring) Late() (draw, into time.Duration) {
	return r.endedT.Sub(r.waitedT), r.waitedT.Sub(r.lastT)
}

// Missed reports whether the field counter moved on between the last
// WaitField and the last End: the frame took longer than a field.
func (r *Ring) Missed() bool { return r.ended != r.waited }

// Joy returns joystick_1<<16 | joystick_0.
func (r *Ring) Joy() uint32 { return atomic.LoadUint32(&r.stat[2]) }

// Key returns key_cnt<<16 | ps2_key (bit 9 pressed, bit 8 extended, 7:0 code).
func (r *Ring) Key() uint32 { return atomic.LoadUint32(&r.stat[3]) }

// Slot returns the currently published slot's pixels (for frame dumps).
func (r *Ring) Slot() []byte {
	slot := atomic.LoadUint32(&r.hdr[2]) % NSlot
	off := slot0 + int(slot)*slotSize
	return r.mem[off : off+W*H*4]
}

// Overlay is the plane the core blends over whatever is on screen: the
// playback controls over the video. Show writes a rectangle of pixels
// and points the core at it; the change lands at the next field, and
// nothing in the frame ring is touched. Rectangles up to half the
// region are double-buffered, so a visible overlay can be redrawn every
// field without tearing.
type Overlay struct {
	r      *Ring
	seq    uint32
	buf    int
	field  uint32 // the field counter at the last Show
	dotX   int    // the x last asked of the core
	dotSet bool
	row    []byte
	// what each buffer holds, so a Show writes only the rows that changed
	held [2][]byte
	raw  [2][]byte // the pixels each buffer was last given, before the alpha merge
	geom [2][4]int
	x, y int
	w, h int
}

// Overlay returns the ring's overlay plane, hidden.
func (r *Ring) Overlay() *Overlay {
	o := &Overlay{r: r}
	o.Hide()
	return o
}

// header publishes the geometry under the seqlock: the core takes it only
// when both sequence words match, else it keeps the last one.
func (o *Overlay) header(x, y, w, h, addr, en uint32) {
	o.seq++
	atomic.StoreUint32(&o.r.hdr[10], o.seq) // after the pixels
	o.r.hdr[11] = x | y<<16
	o.r.hdr[12] = w | h<<16
	o.r.hdr[13] = addr
	o.r.hdr[14] = en
	atomic.StoreUint32(&o.r.hdr[15], o.seq)
}

// Hide takes the overlay off.
func (o *Overlay) Hide() { o.header(0, 0, 0, 0, osdOff, 0) }

// RegionSize is how many bytes of overlay pixels the core can address.
const RegionSize = osdSize

// Upload writes a BGRx canvas into the region at byte offset off, as ARGB
// with one alpha for every pixel, row after row (w*4 bytes per row). It
// is for content shown with ShowAt, such as a tall list the core scrolls
// by address; nothing is remembered about it.
func (o *Overlay) Upload(off int, c *gfx.Canvas, alpha byte) {
	n := c.W * c.H * 4
	if off < 0 || off+n > osdSize {
		return
	}
	if len(o.row) < c.W*4 {
		o.row = make([]byte, c.W*4)
	}
	dst := o.r.mem[osdOff+off:]
	row := o.row[:c.W*4]
	for yy := 0; yy < c.H; yy++ {
		copy(row, c.Pix[yy*c.W*4:(yy+1)*c.W*4])
		for xx := 3; xx < len(row); xx += 4 {
			row[xx] = alpha
		}
		copy(dst[yy*c.W*4:], row)
	}
}

// ShowAt shows a w x h rectangle at x,y whose pixels start at byte offset
// off of the region (w*4 bytes per row): a header store only, taken at
// the next vsync, so scrolling uploaded content costs nothing. The
// buffers' change tracking is dropped, since the content may span them.
func (o *Overlay) ShowAt(x, y, w, h, off int) {
	o.geom = [2][4]int{}
	o.header(uint32(x&^1), uint32(y&^1), uint32(w&^1), uint32(h&^1), uint32(osdOff+(off&^7)), 1)
}

// Show publishes a BGRx canvas as the overlay at x,y (made even), with an
// alpha plane of the same size (0..255 per pixel; nil for opaque).
func (o *Overlay) Show(x, y int, c *gfx.Canvas, alpha []byte) {
	w, h := c.W&^1, c.H&^1
	x, y = x&^1, y&^1
	if w == 0 || h == 0 || x+w > W || y+h > H || w*h*4 > osdSize {
		return
	}
	off := 0
	if w*h*4*2 <= osdSize {
		// alternate buffers, except within one field: the last header has
		// not been latched yet, so its buffer is not on screen either
		if f := o.r.Field(); f != o.field {
			o.field = f
			o.buf ^= 1
		}
		off = o.buf * (osdSize / 2)
	} else {
		// a single buffer spans both halves: the other copy is stale
		o.geom[o.buf^1] = [4]int{}
	}
	dst := o.r.mem[osdOff+off:]
	if len(o.row) < w*4 {
		o.row = make([]byte, w*4)
	}
	same := o.geom[o.buf] == [4]int{x, y, w, h} && len(o.held[o.buf]) >= w*h*4
	if !same {
		if len(o.held[o.buf]) < w*h*4 {
			o.held[o.buf] = make([]byte, max(w*h*4, osdSize/2)) // a full-screen panel is single-buffered
		}
		o.geom[o.buf] = [4]int{x, y, w, h}
	}
	held := o.held[o.buf]
	if len(o.raw[o.buf]) < w*h*4 {
		o.raw[o.buf] = make([]byte, max(w*h*4, osdSize/2))
	}
	raw := o.raw[o.buf]
	for yy := 0; yy < h; yy++ {
		src := c.Pix[yy*c.W*4 : yy*c.W*4+w*4]
		rawRow := raw[yy*w*4 : (yy+1)*w*4]
		if same && bytes.Equal(src, rawRow) {
			continue // the same pixels as last time: nothing to merge or write
		}
		copy(rawRow, src)
		row := o.row[:w*4]
		copy(row, src)
		if alpha != nil {
			a := alpha[yy*c.W : yy*c.W+w]
			for xx := 0; xx < w; xx++ {
				row[xx*4+3] = a[xx]
			}
		} else {
			for xx := 0; xx < w; xx++ {
				row[xx*4+3] = 255
			}
		}
		was := held[yy*w*4 : (yy+1)*w*4]
		if same && bytes.Equal(row, was) {
			continue // this row is already in the buffer
		}
		copy(was, row)
		copy(dst[yy*w*4:], row) // sequential writes into write-combined memory
	}
	o.header(uint32(x), uint32(y), uint32(w), uint32(h), uint32(osdOff+off), 1)
}

// Dot places the core's dot sprite (a disc of radius 7 rows) at x,y in
// frame pixels, or hides it. The x is taken at the next vsync, when it
// differs from the last one asked for (the load toggle); y and the
// visibility apply within a line.
func (o *Overlay) Dot(x, y int, rgb uint32, on bool) {
	o.r.hdr[21] = rgb & 0xFFFFFF
	// an atomic store ends with a barrier, which drains the write-combining
	// buffer: a plain store could sit in it for an unpredictable time
	atomic.StoreUint32(&o.r.hdr[20], sprite(x, y, on))
	if x != o.dotX || !o.dotSet {
		o.dotX, o.dotSet = x, true
		atomic.StoreUint32(&o.r.hdr[25], o.r.hdr[25]^1<<28)
	}
}

// DotRun makes the core move the dot vx pixels every field (0 stops),
// within xmin..xmax. The dot's place is then the core's: read it with DotX.
func (o *Overlay) DotRun(vx, xmin, xmax int) {
	v := o.r.hdr[25] & (1 << 28) // the load bit stays as Dot left it
	v |= uint32(max(0, xmin)&0x3FF) | uint32(max(0, xmax)&0x3FF)<<10 | uint32(vx&0xFF)<<20
	atomic.StoreUint32(&o.r.hdr[25], v)
}

// DotX is where the core has the dot, as of the last scan line.
func (o *Overlay) DotX() int { return int(atomic.LoadUint32(&o.r.hdr[26]) & 0x3FF) }

// Bar places the core's bar sprite, a filled rectangle, or hides it.
func (o *Overlay) Bar(x, y, w, h int, rgb uint32, on bool) {
	o.r.hdr[23] = uint32(w&0x3FF) | uint32(h&0x3FF)<<16
	o.r.hdr[24] = rgb & 0xFFFFFF
	atomic.StoreUint32(&o.r.hdr[22], sprite(x, y, on))
}

func sprite(x, y int, on bool) uint32 {
	v := uint32(max(0, x)&0x3FF) | uint32(max(0, y)&0x3FF)<<16
	if on {
		v |= 1 << 31
	}
	return v
}
