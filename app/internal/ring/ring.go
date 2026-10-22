// Package ring is the Go app's side of the H.264 decoder core's HPS
// interface (third_party/MiSTer_h264_decoder, interface 1.x): the app's
// frames go into one of two overlay pages in the Linux framebuffer
// (/dev/fb0), described to the core by the eight descriptor words 72-79 of
// the control block, which the core composites over the video (or over
// black); the status words and the input region are read from the same
// control block, mapped through /dev/mem.
//
//	0x31400000  the control block, 4 KB of 64-bit words (/dev/mem, O_SYNC)
//	            0-31, 40-47, 80-87 the core's status; 48-71 the input region;
//	            32-38 the player's session words; 72-79 the overlay descriptor
//	0x31800000  the ring (8 MB): the player's alone, never mapped here
//	0x22000000  MiSTer_fb's region (8 MB); /dev/fb0 maps the first smem_len
//	            bytes of it. Page p is at fb + p*opage: ARGB8888 sized to
//	            the core's raster (word 80), at most 1280x720, alpha forced
//	            opaque.
//
// The app draws a 480-line canvas, 720 wide (960 for a 16:9 display
// shape), which publishing scales onto a page, centred on the raster.
//
// The player (jfplay, libh264ring) is a separate process that holds the
// library's advisory lock (an exclusive flock on /tmp/h264ring.lock) for
// its whole run and is the ring's only writer. This package never takes
// that lock while the player runs: it writes only the overlay descriptor,
// and, when no session is open at all, starts an idle one under the lock
// (the core shows the overlay only during a session; see session.go).
package ring

import (
	"errors"
	"fmt"
	"math"
	"os"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"

	"plexcrt/internal/gfx"
)

const (
	W, H        = 720, 480
	NPage       = 2
	stride      = W * 4
	pageSize    = stride * H // 1,382,400: a multiple of 8
	maxPageSize = 1280 * 720 * 4
	// ackWait bounds the wait for the core to read a descriptor (it reads
	// them once a refresh, 16.7 or 20 ms) before a page is drawn again.
	ackWait = 60 * time.Millisecond
	// cadenceWait covers one 50 Hz field plus scheduling margin, while
	// bounding how long a stopped core can hold the render thread.
	cadenceWait = 25 * time.Millisecond
	// coreNameFresh is how long a reading of MiSTer's core name stands for
	// the writers: two of Watch's 50 ms polls, as long as a stalled
	// heartbeat takes to stop writes.
	coreNameFresh = 100 * time.Millisecond
)

// Ring is the mapped control block and overlay pages.
type Ring struct {
	c           ctrl
	coreLost    atomic.Bool  // latched once MiSTer names a different core
	coreNamed   atomic.Int64 // when MiSTer last named this core (Unix ns, 0: not yet)
	writeBeat   atomic.Uint32
	writeBeatAt atomic.Int64
	ctrlMem     []byte
	fb          []byte
	fbPhys      uint32
	pages       [NPage][]uint32
	npage       int
	// ow/oh are the physical overlay page dimensions. The application keeps
	// its ordinary screens in the 720x480 design space; playback panels can
	// use a wider logical canvas and the overlay maps both into these pages.
	ow, oh, ostride, opage int
	scaleX                 []int // reused horizontal nearest-neighbor map for page scaling
	// bars is the viewport each page's black bars were painted around, and
	// barsAt when (zero frame: none known; see publishFrame).
	bars   [NPage]barFrame
	barsAt [NPage]time.Time

	mu      sync.Mutex
	back    *gfx.Canvas // what Begin hands out; End copies it into a page
	cur     int         // the page last described (-1: none)
	want    desc        // the descriptor this app keeps asserted
	gen     uint32      // the generation this app last wrote (0: none yet)
	pending bool        // gen not yet seen in ovl_gen
	frame   bool        // what is shown is a frame from back (not the Overlay)
	ackLate int         // waits that ran out (diagnostics)
	shown0  uint32      // the core's shown-picture count at the last End

	ackD, copyD time.Duration // the last publish's acknowledgment wait and copy (diagnostics)

	dim     uint32   // Full minus the brightness asked for
	overlay *Overlay // current playback composition, protected by mu

	last, waited, ended    uint32
	lastT, waitedT, endedT time.Time
	cadence                bool
	cadenceField           uint32
	blink                  int // fbcon's cursor blink to put back (-1: unknown)
	sessionAt              time.Time
	lastKey                uint32 // Key()'s last value, for a torn read

	// edge is the last heartbeat WaitField saw begin, between edgeT and
	// edgeTo; period is the field's length measured from such edges.
	edge          uint32
	edgeT, edgeTo time.Time
	period        time.Duration
}

var (
	errNotRunning = errors.New("the H.264 core is not running (no heartbeat in its status block)")
	// RBF is the core Open loads when another one is running (the MGL's
	// <rbf>, relative to /media/fat; MiSTer picks the newest PlexH264_*.rbf).
	// MISTERZINE_H264_RBF overrides it.
	RBF = "_Other/PlexH264"
)

// CoreFile is the core this run loads: the release's (MISTERZINE_H264_RBF,
// which the launcher sets), else RBF.
func CoreFile() string {
	if v := os.Getenv("MISTERZINE_H264_RBF"); v != "" {
		return v
	}
	return RBF
}

// Open loads the core if another is running, maps its control block and
// the framebuffer, and makes sure a session is open so the overlay shows.
// What it works around (a framebuffer mode it cannot enlarge, a session it
// cannot start) goes to logf.
func Open(logf func(string, ...any)) (*Ring, error) {
	rbf := CoreFile()
	if err := LaunchCore(rbf, 15*time.Second); err != nil {
		return nil, fmt.Errorf("loading the H.264 core (%s): %w", rbf, err)
	}
	cm, err := mapCtrl()
	if err != nil {
		return nil, err
	}
	r := &Ring{ctrlMem: cm, cur: -1, blink: -1}
	r.setOutput(W, H)
	r.c.m = unsafe.Slice((*uint32)(unsafe.Pointer(&cm[0])), ctrlLen/4)
	// a core loaded a moment ago takes a while to start its heartbeat
	deadline := time.Now().Add(5 * time.Second)
	for !r.c.alive(200 * time.Millisecond) {
		if time.Now().After(deadline) {
			syscall.Munmap(cm)
			return nil, errNotRunning
		}
	}
	if st, ok := r.c.status(); ok {
		w, h := outputSize(st)
		r.setOutput(w, h)
	}
	if from, err := enlargeMode(); err != nil {
		logf("ring: framebuffer mode %q maps less than two overlay pages and could not be changed: %v", from, err)
	}
	if err := r.mapFB(logf); err != nil {
		syscall.Munmap(cm)
		return nil, err
	}
	r.blink = quietCursor()
	if err := r.ensureSession(); err != nil {
		logf("ring: %v", err)
	}
	return r, nil
}

func (r *Ring) setPages() {
	if r.opage == 0 {
		r.setOutput(W, H)
	}
	r.npage = min(NPage, len(r.fb)/r.opage)
	r.bars = [NPage]barFrame{}
	for p := 0; p < r.npage; p++ {
		b := r.fb[p*r.opage : (p+1)*r.opage]
		r.pages[p] = unsafe.Slice((*uint32)(unsafe.Pointer(&b[0])), r.opage/4)
	}
}

func (r *Ring) setOutput(w, h int) {
	r.ow, r.oh = w, h
	r.ostride = (w*4 + 7) &^ 7
	r.opage = r.ostride * h
}

func outputSize(st Status) (w, h int) {
	w, h = st.RasterW, st.RasterH
	if w < 1 || h < 1 || w > 2048 || h > 2048 {
		return W, H
	}
	if w*h > 1280*720 {
		s := math.Sqrt(float64(1280*720) / float64(w*h))
		w, h = max(1, int(float64(w)*s)), max(1, int(float64(h)*s))
	}
	for ((w*4+7)&^7)*h > maxPageSize {
		if w >= h {
			w--
		} else {
			h--
		}
	}
	return w, h
}

// syncOutput changes pages only after the core reports its new raster. The
// framebuffer is mapped at maximum supported size during Open, so changing
// native profiles can flip pages without remapping memory mid-playback.
func (r *Ring) syncOutput(st Status) bool {
	if !r.writesAllowed() {
		return false
	}
	w, h := outputSize(st)
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.ow == w && r.oh == h {
		return false
	}
	if r.fb != nil && len(r.fb) < NPage*((w*4+7)&^7)*h {
		w, h = W, H
		if r.ow == w && r.oh == h {
			return false
		}
	}
	// Stop the core from fetching the old descriptor before changing either
	// page geometry or page offsets. The acknowledgment is the handoff point.
	r.write(desc{})
	if !r.waitAck(ackWait) {
		return false
	}
	r.cur = -1
	r.frame = false
	if r.overlay != nil {
		o := r.overlay
		if o.running != nil {
			close(o.running)
			o.running = nil
		}
		o.on, o.src, o.srcStride = false, nil, 0
		o.own, o.regionSrc = nil, false
		o.dotOn, o.dotAnchored, o.drawnDotSet = false, false, false
		o.runV, o.runMin, o.runMax = 0, 0, 0
		o.barOn = false
	}
	r.setOutput(w, h)
	r.setPages()
	if r.overlay != nil {
		r.overlay.row = make([]uint32, w)
		stNow, ok := r.Status()
		r.overlay.logicalW, r.overlay.logicalH = playbackCanvasSize(stNow, ok, w, h)
	}
	r.back = nil
	if r.overlay != nil && r.overlay.opaque {
		r.overlay.compose()
	}
	return true
}

// PlaybackCanvasSize returns a logical canvas with the selected display
// shape and raster height. 16:9 adds room at the sides.
func playbackCanvasSize(st Status, ok bool, ow, oh int) (w, h int) {
	h = H // preserve the 480-line font/layout scale; the page fills taller PAL rasters
	wide := (ok && st.DisplayWide) || ow*480 > oh*720
	if ok && st.RasterMode == 1 && st.ARX > 0 && st.ARY > 0 {
		// Native picture-sized fallback reports the source AR even when the
		// requested shared display shape is wider than the actual scanout.
		wide = st.ARX*2 > st.ARY*3
		if st.RasterW > ow || st.RasterH > oh {
			// The framebuffer map could not hold two native pages. Keep the
			// centred legacy canvas proportional in that fallback.
			wide = ow*480 > oh*720
		}
	}
	if wide {
		return 960, h
	}
	return 720, h
}

func (r *Ring) PlaybackCanvasSize() (w, h int) {
	r.mu.Lock()
	defer r.mu.Unlock()
	st, ok := r.Status()
	return playbackCanvasSize(st, ok, r.ow, r.oh)
}

// LayoutCanvasSize is the app's shared-screen design space. The existing
// type scale stays 480 lines high; wide displays gain horizontal room.
func (r *Ring) LayoutCanvasSize() (w, h int) { return r.PlaybackCanvasSize() }

// Close takes the overlay down, unmaps everything and puts the console's
// cursor back. The session stays open (nothing in the interface closes
// one), so the player can start its own at once.
func (r *Ring) Close() {
	r.Hide()
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.ctrlMem == nil {
		return // a test's memory
	}
	if r.fb != nil {
		syscall.Munmap(r.fb)
		if r.writesAllowed() {
			restoreCursor(r.blink)
		}
	}
	syscall.Munmap(r.ctrlMem)
	r.fb, r.ctrlMem, r.npage = nil, nil, 0
}

// CoreRunning reports whether the core's heartbeat moves within the time
// given. Once the user loads another core (or the menu) its words stay in
// memory, so only the heartbeat tells.
func (r *Ring) CoreRunning(within time.Duration) bool { return r.c.alive(within) }

// Status is a consistent copy of the core's status (false if the core
// kept writing it, which a running core never does for long).
func (r *Ring) Status() (Status, bool) { return r.c.status() }

// Heartbeat is the core's seq_head: +1 every frame while it runs.
func (r *Ring) Heartbeat() uint32 { return r.c.lo(wSeqHead) }

// Begin returns the canvas to draw the next frame into (ordinary memory,
// so reading it back is fine; nothing of the last frame is guaranteed).
func (r *Ring) Begin() *gfx.Canvas {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.beginLocked()
}

func (r *Ring) beginLocked() *gfx.Canvas {
	st, ok := r.Status()
	w, h := playbackCanvasSize(st, ok, r.ow, r.oh)
	if r.back == nil || r.back.W != w || r.back.H != h {
		r.back = gfx.NewCanvas(w, h)
	}
	return r.back
}

// nativeViewport letterboxes/pillarboxes the app's physical display shape
// inside a Native picture-sized raster. SD and fitted outputs already use
// their complete raster, including anamorphic 720x480/576 modes.
func nativeViewport(st Status, logicalW, ow, oh int) (x, y, w, h int) {
	if st.RasterMode != 1 || ow <= 0 || oh <= 0 {
		return 0, 0, ow, oh
	}
	targetAR := float64(4) / 3
	if logicalW >= 900 {
		targetAR = float64(16) / 9
	}
	pixelAR := 1.0
	if st.ARX > 0 && st.ARY > 0 {
		rasterW, rasterH := st.RasterW, st.RasterH
		if rasterW <= 0 || rasterH <= 0 {
			rasterW, rasterH = ow, oh
		}
		pixelAR = (float64(st.ARX) / float64(st.ARY)) / (float64(rasterW) / float64(rasterH))
	}
	viewportAR := targetAR / pixelAR
	w, h = ow, oh
	if float64(ow)/float64(oh) > viewportAR {
		w = int(float64(oh)*viewportAR + 0.5)
	} else {
		h = int(float64(ow)/viewportAR + 0.5)
	}
	return (ow - w) / 2, (oh - h) / 2, w, h
}

// End publishes the canvas from Begin, every line of it.
func (r *Ring) End() {
	r.cadence = false
	r.EndBand(0, r.Begin().H-1)
}

// EndBand publishes lines first..last of the canvas from Begin; the core
// fetches only those, and every other line shows the video (or black).
func (r *Ring) EndBand(first, last int) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.beginLocked()
	r.publishFrame(r.back.Pix, first, last)
}

// Present copies a canvas the size of Begin's into the next page and publishes it.
func (r *Ring) Present(c *gfx.Canvas) error { return r.PresentBand(c, 0, H-1) }

// PresentBand is Present for lines first..last only.
func (r *Ring) PresentBand(c *gfx.Canvas, first, last int) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	b := r.beginLocked()
	if c.W != b.W || c.H != b.H {
		return errors.New("canvas dimensions do not match display layout")
	}
	first, last = max(0, first), min(b.H-1, last)
	if first <= last && &c.Pix[0] != &b.Pix[0] {
		// kept, so that a brightness change can show it again
		rowBytes := b.W * 4
		copy(b.Pix[first*rowBytes:(last+1)*rowBytes], c.Pix[first*rowBytes:(last+1)*rowBytes])
	}
	r.publishFrame(b.Pix, first, last)
	return nil
}

// publishFrame copies lines first..last of a BGRx frame into the page not
// on screen, alpha forced opaque (the app draws xRGB with 0 in the top
// byte, which the core shows as transparent) and scaled by the brightness,
// then describes that page. Called with mu held.
func (r *Ring) publishFrame(pix []byte, first, last int) {
	r.ackD, r.copyD = 0, 0
	if !r.writesAllowed() {
		return
	}
	st, ok := r.Status()
	sw, sh := playbackCanvasSize(st, ok, r.ow, r.oh)
	first, last = max(0, first), min(sh-1, last)
	if first > last || r.npage == 0 {
		return
	}
	t := time.Now()
	p := r.nextPage()
	acked := time.Now()
	r.ackD = acked.Sub(t)
	if !r.writesAllowed() { // the acknowledgment wait may span a core switch
		return
	}
	page := r.pages[p]
	src := unsafe.Slice((*uint32)(unsafe.Pointer(&pix[0])), sw*sh)
	vx, vy, vw, vh := nativeViewport(st, sw, r.ow, r.oh)
	fullViewport := vx == 0 && vy == 0 && vw == r.ow && vh == r.oh
	now := time.Now()
	frame := barFrame{r.ow, r.oh, r.ostride, vx, vy, vw, vh}
	barred := !fullViewport && r.bars[p] == frame && now.Sub(r.barsAt[p]) < barsRepaint
	if fullViewport {
		r.bars[p] = barFrame{} // the frame covers any bars a page had
	}
	if fullViewport && r.ow == sw && r.oh == sh {
		for y := first; y <= last; y++ {
			fillOpaque(page[y*(r.ostride/4):y*(r.ostride/4)+sw], src[y*sw:(y+1)*sw], Full-r.dim)
		}
		r.describe(p, first, last)
		r.frame = true
		r.shown0 = r.c.lo(wFetch)
		r.ended = r.Field()
		r.endedT = time.Now()
		r.copyD = r.endedT.Sub(acked)
		return
	}
	// Preserve the design's 4:3 proportions as it is placed on a larger
	// raster. The unused side bands are opaque black so menus remain legible:
	// painted once a page and geometry (see barFrame), then only the picture.
	xScale, yScale := float64(vw)/float64(sw), float64(vh)/float64(sh)
	if cap(r.scaleX) < vw {
		r.scaleX = make([]int, vw)
	} else {
		r.scaleX = r.scaleX[:vw]
	}
	xMap := r.scaleX
	for x := range xMap {
		xMap[x] = min(sw-1, int(float64(x)/xScale))
	}
	firstOut := max(0, vy+int(float64(first)*yScale))
	lastOut := min(r.oh-1, vy+int(float64(last+1)*yScale)-1)
	if first == 0 && last == sh-1 && !fullViewport {
		if !barred {
			r.paintBars(page, frame)
			r.bars[p], r.barsAt[p] = frame, now
			barred = true
		}
		firstOut, lastOut = 0, r.oh-1
	}
	for py := max(firstOut, vy); py <= min(lastOut, vy+vh-1); py++ {
		row := page[py*(r.ostride/4) : py*(r.ostride/4)+r.ow]
		sy := min(sh-1, int(float64(py-vy)/yScale))
		if !fullViewport && !barred { // a band: its lines' side bars only
			fillBlack(row[:vx])
			fillBlack(row[vx+vw:])
		}
		source := src[sy*sw : (sy+1)*sw]
		if r.dim == 0 {
			for x, sx := range xMap {
				row[vx+x] = source[sx] | 0xFF000000
			}
		} else {
			for x, sx := range xMap {
				row[vx+x] = opaque(source[sx], Full-r.dim)
			}
		}
	}
	r.describe(p, firstOut, lastOut)
	r.frame = true
	r.shown0 = r.c.lo(wFetch)
	r.ended = r.Field()
	r.endedT = time.Now()
	r.copyD = r.endedT.Sub(acked)
}

// barFrame is the page geometry and viewport a page's black bars frame.
type barFrame struct{ ow, oh, ostride, vx, vy, vw, vh int }

// barsRepaint is how long painted bars are trusted: anything else that
// draws on the framebuffer (a console message) does not stay longer.
const barsRepaint = time.Second

// paintBars fills a page opaque black outside the viewport.
func (r *Ring) paintBars(page []uint32, f barFrame) {
	for y := 0; y < f.oh; y++ {
		row := page[y*(f.ostride/4) : y*(f.ostride/4)+f.ow]
		if y < f.vy || y >= f.vy+f.vh {
			fillBlack(row)
			continue
		}
		fillBlack(row[:f.vx])
		fillBlack(row[f.vx+f.vw:])
	}
}

func fillBlack(row []uint32) {
	for x := range row {
		row[x] = 0xFF000000
	}
}

// flipTarget waits until the core has read our last descriptor, so that
// the page it no longer names is free, and returns that page. With one
// page (a framebuffer mode too small for two) it draws over the shown one.
// The caller may draw anywhere on it: its bars are no longer known.
func (r *Ring) flipTarget() int {
	p := r.nextPage()
	r.bars[p] = barFrame{}
	return p
}

// nextPage is flipTarget for publishFrame, which keeps a page's bars.
func (r *Ring) nextPage() int {
	r.waitAck(ackWait)
	if r.npage < 2 || r.cur < 0 {
		return 0
	}
	return r.cur ^ 1
}

// waitAck waits until ovl_gen reaches our generation, someone else has
// written the descriptor since (it is theirs the core reads now), or the
// time runs out (a core that stopped, or no core: counted, then drawn on).
func (r *Ring) waitAck(within time.Duration) bool {
	if !r.pending {
		return true
	}
	deadline := time.Now().Add(within)
	for {
		st, ok := r.c.status()
		if ok && genReached(st.OvlGen, r.gen) {
			r.pending = false
			return true
		}
		if r.c.lo(wOvlGenLo) != r.gen {
			r.pending = false
			return false
		}
		if !time.Now().Before(deadline) {
			r.ackLate++
			r.pending = false
			return false
		}
		r.c.sleep(500 * time.Microsecond)
	}
}

// describe points the core at page p with band first..last.
func (r *Ring) describe(p, first, last int) {
	d := desc{
		on: true, format: FmtARGB8888,
		base:  r.fbPhys + uint32(p*r.opage),
		width: uint32(r.ow), height: uint32(r.oh), stride: uint32(r.ostride),
		first: uint32(first), last: uint32(last),
	}
	if d.check() != 0 {
		return // outside the region the core reads: it would refuse it
	}
	r.write(d)
	r.cur = p
}

func opaque(pixel, level uint32) uint32 {
	if level >= Full {
		return pixel | 0xFF000000
	}
	rb := (pixel & 0xFF00FF) * level >> 8 & 0xFF00FF
	g := (pixel & 0x00FF00) * level >> 8 & 0x00FF00
	return 0xFF000000 | rb | g
}

// write publishes d under a new generation and remembers it as ours.
func (r *Ring) write(d desc) {
	if !r.writesAllowed() {
		return
	}
	st, _ := r.c.status()
	if !r.writesAllowed() {
		return
	}
	r.gen = nextGen(r.gen, r.c.lo(wOvlGenLo), st.OvlGen)
	r.c.writeDesc(d, r.gen)
	r.want = d
	r.pending = true
}

// overlayCurrent reports whether the core still sees the descriptor this
// Ring last published. A video frame or another writer can replace it without
// changing the Overlay's cached pixels, so pixel-state no-ops must check both
// the generation pair and descriptor before skipping a publish.
func (r *Ring) overlayCurrent() bool {
	return r.overlayDescriptorCurrent(r.want)
}

func (r *Ring) overlayDescriptorCurrent(want desc) bool {
	if r.frame || r.gen == 0 || r.want != want {
		return false
	}
	lo, hi := r.c.lo(wOvlGenLo), r.c.lo(wOvlGenHi)
	if lo != r.gen || hi != r.gen {
		return false
	}
	d := r.c.readDesc()
	return d == want && r.c.lo(wOvlGenLo) == lo && r.c.lo(wOvlGenHi) == hi
}

// Hide takes the overlay off (the descriptor's show bit clear): for video
// played full screen with no UI over it. The next End shows it again.
func (r *Ring) Hide() {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.c.m == nil {
		return
	}
	if !r.writesAllowed() {
		return
	}
	r.write(desc{})
	r.frame = false
}

// Blank takes the overlay down: with nothing playing the core shows black.
func (r *Ring) Blank() { r.Hide() }

// reassert writes our descriptor again, under a newer generation, if
// someone else (the player's session start, which writes its own or none)
// has written words 72-79 since ours. True if it did.
func (r *Ring) reassert() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.writesAllowed() {
		return false
	}
	if r.gen == 0 || r.c.lo(wOvlGenLo) == r.gen && r.c.lo(wOvlGenHi) == r.gen && r.c.readDesc() == r.want {
		return false // the generation alone is not enough: the player's library also counts from 1
	}
	r.write(r.want)
	return true
}

// CoreAvailable reads MiSTer's core name and latches a core switch as soon
// as MiSTer publishes it. A real mapped ring also treats a missing or empty
// name as loss; attached host-side test rings have no MiSTer name file.
// Watch and the app's watchdog call it every 50 ms, which keeps the answer
// the writers use (coreAvailable) fresh.
func (r *Ring) CoreAvailable() bool {
	if r.coreLost.Load() {
		return false
	}
	name, ok := CoreName()
	if !ok && r.ctrlMem != nil || ok && !appCore(name) {
		r.coreLost.Store(true)
		return false
	}
	r.coreNamed.Store(time.Now().UnixNano())
	return true
}

// coreAvailable is the writers' check, made several times a frame: the
// last reading of the name while it is under coreNameFresh old, a reading
// otherwise (no Watch running). MiSTer names a new core only once the FPGA
// is reconfigured, which stops the heartbeat writesAllowed checks first.
func (r *Ring) coreAvailable() bool {
	if r.coreLost.Load() {
		return false
	}
	if at := r.coreNamed.Load(); at != 0 && time.Now().UnixNano()-at < int64(coreNameFresh) {
		return true
	}
	return r.CoreAvailable()
}

// writesAllowed is a non-blocking ownership and heartbeat check. During FPGA
// reconfiguration CORENAME can still name the old core, but its field counter
// stops first. Keep writes off mapped memory until the same core resumes.
func (r *Ring) writesAllowed() bool {
	if !r.coreAvailable() {
		return false
	}
	if r.ctrlMem == nil { // attached test rings have no live heartbeat source
		return true
	}
	beat := r.c.lo(wSeqHead)
	now := time.Now().UnixNano()
	if r.writeBeat.Load() != beat {
		r.writeBeat.Store(beat)
		r.writeBeatAt.Store(now)
		return true
	}
	at := r.writeBeatAt.Load()
	if at == 0 {
		r.writeBeatAt.CompareAndSwap(0, now)
		return true
	}
	return now-at <= int64(100*time.Millisecond)
}

// AckLate is how many page flips went ahead without the core having read
// the descriptor before (no running core, or a stalled one).
func (r *Ring) AckLate() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.ackLate
}

// Foreign reports whether the player's video is on screen and has moved
// on since our last End.
func (r *Ring) Foreign() bool {
	st, ok := r.c.status()
	return ok && st.Picture && st.Shown != r.shown0
}

// Published is the core's count of pictures the display has taken: it
// moves while video plays. False while no picture is shown.
func (r *Ring) Published() (uint32, bool) {
	st, ok := r.c.status()
	return st.Shown, ok && st.Picture
}

// Field returns the core's heartbeat, which advances once a frame (a
// field when the output is interlaced).
func (r *Ring) Field() uint32 { return r.c.lo(wSeqHead) }

// TraceStatus samples the heartbeat, the generation published and the
// generation the core last read, for opt-in timing diagnostics.
func (r *Ring) TraceStatus() (field, published, shown uint32) {
	st, _ := r.c.status()
	r.mu.Lock()
	defer r.mu.Unlock()
	return st.Heartbeat, r.gen, st.OvlGen
}

const (
	// fieldWake is how long before the edge it expects WaitField wakes; it
	// reads the heartbeat continuously from then until fieldWake after the
	// edge, and every fieldPoll outside that window (no edge known yet, or
	// not where expected). Its sleeps are the kernel's (exactSleep), which
	// wake within tens of microseconds; Go's own round to the millisecond.
	fieldWake = time.Millisecond
	fieldPoll = 200 * time.Microsecond
	// fieldPhase is how many fields an edge's time predicts the next by.
	fieldPhase = 30
)

// WaitField blocks until the heartbeat changes, at most maxWait. Once it
// has timed a few edges it sleeps until fieldWake before the next and
// returns as close after it as continuous reading did: 1 ms of reading a
// field instead of the 4 (60 Hz) to 7 (50 Hz) it took with a fixed period.
func (r *Ring) WaitField(maxWait time.Duration) {
	start := r.Field()
	now := time.Now()
	if start != r.last {
		r.last, r.lastT = start, now
	}
	deadline := now.Add(maxWait)
	var due time.Time // the edge expected (zero: not known)
	if n := start + 1 - r.edge; !r.edgeT.IsZero() && r.period > 0 && n >= 1 && n <= fieldPhase {
		due = r.edgeT.Add(time.Duration(n) * r.period)
		if wake := due.Add(-fieldWake); wake.After(now) {
			exactSleep(min(wake.Sub(now), maxWait))
		}
	}
	// the edge came between two reads: the last that saw start (the first
	// read, before any sleep), the first that did not
	f, seen := start, now
	for {
		f = r.Field()
		t := time.Now()
		if f != start {
			r.edgeSeen(f, seen, t)
			break
		}
		if seen = t; !t.Before(deadline) {
			break
		}
		if due.IsZero() || t.Before(due.Add(-fieldWake)) || t.After(due.Add(fieldWake)) {
			exactSleep(min(fieldPoll, deadline.Sub(t)))
		}
	}
	r.waited = f
	r.waitedT = time.Now()
}

// edgeSeen takes heartbeat f as having begun between from and to. Edges
// read continuously are timed to fieldExact, and two of them measure the
// period; a polled one (a first field, a refresh rate just changed) only
// bounds it. Only a period too long can sleep past an edge, so a shorter
// one is taken at once and a longer one by fieldStep a field: a heartbeat
// that stumbled once cannot make the next sleep miss.
func (r *Ring) edgeSeen(f uint32, from, to time.Time) {
	const (
		fieldExact = 50 * time.Microsecond
		fieldStep  = fieldWake / 4
	)
	r.last, r.lastT = f, to
	if to.Sub(from) > fieldWake {
		// slept through it: the edge came early, or the wake late; until
		// edges are timed again, poll
		r.edgeT = time.Time{}
		return
	}
	if n := time.Duration(f - r.edge); !r.edgeT.IsZero() && n >= 1 && n <= 4*fieldPhase {
		shortest, longest := from.Sub(r.edgeTo)/n, to.Sub(r.edgeT)/n
		exact := to.Sub(from) <= fieldExact && r.edgeTo.Sub(r.edgeT) <= fieldExact
		p := shortest // polled: all that is sure
		if exact {
			p = (shortest + longest) / 2
		}
		switch {
		case shortest < 8*time.Millisecond || longest > 50*time.Millisecond:
			// not a field: a stalled or restarted core
		case r.period == 0 || exact && p < r.period || r.period > longest:
			r.period = p
		case !exact && r.period >= shortest:
			// polled, and the period fits it
		default:
			r.period += min((p-r.period)/4+1, fieldStep)
		}
	}
	r.edge, r.edgeT, r.edgeTo = f, from, to
}

// exactSleep sleeps on the kernel's high-resolution timer: Go's own sleeps
// wait in the network poller, which counts whole milliseconds. The render
// thread is locked to its OS thread, which this blocks.
func exactSleep(d time.Duration) {
	ts := syscall.NsecToTimespec(int64(d))
	for d > 0 && syscall.Nanosleep(&ts, &ts) == syscall.EINTR {
	}
}

// EndEvery publishes on a fixed heartbeat cadence (see cadenceTarget).
// Rendering happens before this wait, giving the renderer the full
// interval. Returns true if a scheduled slot was missed. A stopped core
// cannot hang it.
func (r *Ring) EndEvery(fields uint32) bool {
	if fields == 0 {
		r.End()
		return false
	}
	if !r.cadence {
		r.cadence = true
		r.cadenceField = r.Field()
		r.EndBand(0, H-1)
		return false
	}
	target, missed := cadenceTarget(r.cadenceField, r.Field(), fields)
	deadline := time.Now().Add(cadenceWait)
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
	r.EndBand(0, H-1)
	r.cadenceField = current
	return missed
}

// ResetCadence releases the schedule when a transition finishes.
func (r *Ring) ResetCadence() { r.cadence = false }

func cadenceTarget(previous, current, fields uint32) (uint32, bool) {
	target := previous + fields
	late := int32(current - target)
	if late <= 0 {
		return target, false
	}
	return target + ((uint32(late)+fields-1)/fields)*fields, true
}

// Late is how long after WaitField returned the last End happened, and
// how far into its field WaitField returned (diagnostics for missed fields).
func (r *Ring) Late() (draw, into time.Duration) {
	return r.endedT.Sub(r.waitedT), r.waitedT.Sub(r.lastT)
}

// PublishTimes is how long the last End waited for the core to take the
// previous descriptor and how long its copy into the page took (zero when
// it published nothing), for the pacing log.
func (r *Ring) PublishTimes() (ack, fill time.Duration) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.ackD, r.copyD
}

// Missed reports whether the heartbeat moved on between the last
// WaitField and the last End: the frame took longer than a field.
func (r *Ring) Missed() bool { return r.ended != r.waited }

// fillOpaque copies BGRx pixels into a page as ARGB8888 with alpha 255,
// each channel scaled by level/256 (Full: unchanged, and copied in blocks
// on ARM: see copyOpaque).
func fillOpaque(dst, src []uint32, level uint32) {
	if level >= Full {
		copyOpaque(dst, src)
		return
	}
	dst = dst[:len(src)]
	for i, p := range src {
		rb := (p & 0xFF00FF) * level >> 8 & 0xFF00FF
		g := (p & 0xFF00) * level >> 8 & 0xFF00
		dst[i] = 0xFF000000 | rb | g
	}
}
