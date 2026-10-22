package ring

import (
	"bytes"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
	"unsafe"

	"plexcrt/internal/gfx"
)

// fake is a control block and framebuffer in ordinary memory, with a
// goroutine playing the core: every few ms it bumps the heartbeat (word 31,
// then word 3, as a seqlock), reads the overlay descriptor the way the
// core's burst does (72 first, 79 last, taken only when they agree) and
// reports its generation in word 46, and acknowledges a new nonce.
type fake struct {
	m     []uint32
	fb    []byte
	r     *Ring
	stop  chan struct{}
	done  chan struct{}
	ack   atomic.Bool // the core reads descriptors (false: a stalled core)
	mu    sync.Mutex
	seen  []desc // descriptors taken, in order
	torn  int
	pages []uint32
}

func newFake(t *testing.T, running bool) *fake {
	t.Helper()
	f := &fake{m: make([]uint32, ctrlLen/4), fb: make([]byte, NPage*pageSize), stop: make(chan struct{}), done: make(chan struct{})}
	f.set(wMagic, uint32(coreMagic&0xFFFFFFFF), uint32(coreMagic>>32))
	f.set(wVersion, 0x101|0x20<<16, 0x20|0x28<<16)
	f.set(wGeometry, ringByte, ringSize)
	f.set(wState, stateNoSession, 0)
	f.set(wRaster, 720|480<<12, 0)
	f.r = attach(f.m, f.fb, fbByte)
	f.r.c.nap = func(time.Duration) { time.Sleep(50 * time.Microsecond) }
	f.ack.Store(true)
	if running {
		go f.run()
	} else {
		close(f.done)
	}
	t.Cleanup(f.close)
	return f
}

// attach builds a Ring over memory a test owns: ctrl words and fb pages.
func attach(ctrlWords []uint32, fb []byte, fbPhys uint32) *Ring {
	r := &Ring{cur: -1, blink: -1, fb: fb, fbPhys: fbPhys}
	r.c.m = ctrlWords
	r.setPages()
	return r
}

func TestGeometryCapability(t *testing.T) {
	f := newFake(t, false)
	if f.r.GeometrySupported() {
		t.Fatal("legacy core falsely advertises geometry")
	}
	f.set(wVersion, 0x102, 0)
	if !f.r.GeometrySupported() {
		t.Fatal("geometry interface not detected")
	}
	f.set(wVersion, 0x200, 0)
	if f.r.GeometrySupported() {
		t.Fatal("unknown major version accepted")
	}
}

func (f *fake) set(w int, lo, hi uint32) {
	atomic.StoreUint32(&f.m[2*w], lo)
	atomic.StoreUint32(&f.m[2*w+1], hi)
}

// field moves the heartbeat to n the way the core does, both words of the
// seqlock: with only one, every status read retries until it gives up.
func (f *fake) field(n uint32) {
	f.set(wSeqTail, n, 0)
	f.set(wSeqHead, n, 0)
}

func (f *fake) lo(w int) uint32 { return atomic.LoadUint32(&f.m[2*w]) }
func (f *fake) hi(w int) uint32 { return atomic.LoadUint32(&f.m[2*w+1]) }

func (f *fake) close() {
	select {
	case <-f.stop:
	default:
		close(f.stop)
	}
	<-f.done
}

func (f *fake) run() {
	defer close(f.done)
	for seq := uint32(1); ; seq++ {
		select {
		case <-f.stop:
			return
		case <-time.After(2 * time.Millisecond):
		}
		if f.ack.Load() {
			lo := f.lo(wOvlGenLo)
			d := desc{
				on: f.lo(wOvlCtl)&ovlEnable != 0, format: f.lo(wOvlCtl) >> 1 & 3,
				base: f.lo(wOvlBase), width: f.lo(wOvlSize) & 0xFFFF, height: f.lo(wOvlSize) >> 16,
				stride: f.lo(wOvlStride), first: f.lo(wOvlBand) & 0xFFFF, last: f.lo(wOvlBand) >> 16,
			}
			if hi := f.lo(wOvlGenHi); hi == lo && lo != f.lo(wOvlStat) {
				f.mu.Lock()
				f.seen = append(f.seen, d)
				f.mu.Unlock()
				f.set(wOvlStat, lo, OvlAccepted)
			} else if hi != lo {
				f.torn++
			}
		}
		if n := f.lo(wNonce); n != 0 && n != f.hi(wAck) {
			f.set(wAck, f.lo(wWriteIdx), n)
			f.set(wState, stateReady|uint32(LiveSession)<<16, 0)
		}
		f.set(wSeqTail, seq, 0)
		f.set(wSeqHead, seq, 0)
	}
}

func canvas(c uint32) *gfx.Canvas {
	cv := gfx.NewCanvas(W, H)
	px := unsafe.Slice((*uint32)(unsafe.Pointer(&cv.Pix[0])), W*H)
	for i := range px {
		px[i] = c
	}
	return cv
}

func TestDescriptorWordOrder(t *testing.T) {
	f := newFake(t, false)
	var order []int
	var vals = map[int]uint32{}
	f.r.c.trace = func(w int, v uint32) {
		if w >= wOvl && w < wOvl+8 {
			order = append(order, w)
			vals[w] = v
		}
	}
	f.r.Present(canvas(0))
	want := []int{79, 73, 74, 75, 76, 77, 78, 72}
	if len(order) != len(want) {
		t.Fatalf("stores %v, want %v", order, want)
	}
	for i := range want {
		if order[i] != want[i] {
			t.Fatalf("stores %v, want %v", order, want)
		}
	}
	if vals[79] != vals[72] || vals[72] == 0 {
		t.Fatalf("generations 79=%d 72=%d", vals[79], vals[72])
	}
	if vals[73] != 1|FmtARGB8888<<1 || vals[74] != fbByte || vals[75] != 480<<16|720 ||
		vals[76] != 2880 || vals[77] != 479<<16 || vals[78] != 0 {
		t.Fatalf("descriptor %x", vals)
	}
	g := vals[72]
	order = nil
	f.r.Hide()
	if len(order) != 8 || order[0] != 79 || order[7] != 72 || vals[72] != g+1 {
		t.Fatalf("hide stores %v gen %d", order, vals[72])
	}
	for w := 73; w <= 78; w++ {
		if vals[w] != 0 {
			t.Fatalf("hide left word %d = %x", w, vals[w])
		}
	}
}

func TestNativeRasterUsesTwoFullPagesAndWideLayoutFillsTheRaster(t *testing.T) {
	f := newFake(t, false)
	f.fb = make([]byte, NPage*1280*720*4)
	f.r.fb = f.fb
	f.r.setOutput(1280, 720)
	f.r.setPages()
	wide := gfx.NewCanvas(960, 480)
	wide.Fill(0, 0, wide.W, wide.H, 0x123456)
	if err := f.r.Present(wide); err != nil {
		t.Fatal(err)
	}
	if got := f.r.want; got.width != 1280 || got.height != 720 || got.stride != 5120 || got.base != fbByte {
		t.Fatalf("native descriptor %+v", got)
	}
	page := f.r.pages[0]
	if page[360*1280+640] != 0xFF123456 {
		t.Fatalf("center pixel %08x", page[360*1280+640])
	}
	if page[360*1280] != 0xFF123456 || page[360*1280+1279] != 0xFF123456 {
		t.Fatal("wide layout did not fill native raster")
	}
}

// On a pillarboxed Native raster (a scope picture) each page gets its black
// bars once: later frames on it write the picture only. A page another
// writer took (the playback overlay), a mode write, or an old painting gets
// them again.
func TestPillarboxBarsArePaintedOncePerPage(t *testing.T) {
	f := newFake(t, false)
	f.set(wRaster, 1280|534<<12|1<<24, 0)
	f.set(wAspect, 12|5<<12, 0)
	f.fb = make([]byte, NPage*maxPageSize)
	f.r.fb = f.fb
	f.r.setOutput(1280, 534)
	f.r.setPages()
	c := gfx.NewCanvas(f.r.PlaybackCanvasSize())
	c.Fill(0, 0, c.W, c.H, 0x123456)
	st, _ := f.r.Status()
	vx, vy, vw, vh := nativeViewport(st, c.W, 1280, 534)
	if vx == 0 || vy != 0 || vh != 534 {
		t.Fatalf("viewport %d,%d %dx%d is not a pillarbox", vx, vy, vw, vh)
	}
	present := func(want int) []uint32 {
		t.Helper()
		f.r.pending = false // no core here to read the descriptor
		if err := f.r.Present(c); err != nil {
			t.Fatal(err)
		}
		if f.r.cur != want || f.r.want.first != 0 || f.r.want.last != 533 {
			t.Fatalf("page %d band %d..%d, want page %d, every line", f.r.cur, f.r.want.first, f.r.want.last, want)
		}
		return f.r.pages[want]
	}
	const marker = 0xFFFFFFFF
	bar, picture := 100*1280+5, 100*1280+vx
	page := present(0)
	if page[bar] != 0xFF000000 || page[100*1280+1279] != 0xFF000000 || page[picture] != 0xFF123456 {
		t.Fatalf("bars %08x %08x, picture %08x", page[bar], page[100*1280+1279], page[picture])
	}
	present(1)
	page[bar] = marker // stands for a bar painted again
	if page = present(0); page[bar] != marker || page[picture] != 0xFF123456 {
		t.Fatalf("a page with its bars: bar %08x, picture %08x", page[bar], page[picture])
	}
	f.r.barsAt[0] = time.Now().Add(-barsRepaint)
	present(1)
	if page = present(0); page[bar] != 0xFF000000 {
		t.Fatalf("bars painted %v ago were trusted", barsRepaint)
	}
	page[bar] = marker
	f.r.mu.Lock()
	f.r.cur = 1
	if p := f.r.flipTarget(); p != 0 { // the playback overlay draws on page 0
		t.Fatalf("flip target %d", p)
	}
	f.r.mu.Unlock()
	if page = present(0); page[bar] != 0xFF000000 {
		t.Fatal("bars of a page the overlay took were trusted")
	}
	present(1)
	page[bar] = marker
	f.r.mu.Lock()
	f.r.bars = [NPage]barFrame{} // as Watch does after a framebuffer mode write
	f.r.mu.Unlock()
	if page = present(0); page[bar] != 0xFF000000 {
		t.Fatal("bars were trusted after the framebuffer was cleared")
	}
	f.set(wAspect, 16|9<<12, 0) // the same raster filled: the picture covers the bars
	present(1)
	if page = present(0); page[bar] != 0xFF123456 {
		t.Fatalf("a filled raster left %08x at the side", page[bar])
	}
	f.set(wAspect, 12|5<<12, 0)
	present(1)
	if page = present(0); page[bar] != 0xFF000000 {
		t.Fatal("bars painted before a filled frame were trusted")
	}
}

// The playback panel ends at the canvas's bottom edge; on a raster whose
// height is not a whole multiple of the canvas's (964x542 from a 960x480
// design) it must still end at the raster's last line, not two lines short.
func TestNativePanelReachesTheBottomOfAnOddScaledRaster(t *testing.T) {
	f := newFake(t, false)
	f.fb = make([]byte, NPage*964*542*4)
	f.r.fb = f.fb
	f.r.setOutput(964, 542)
	f.r.setPages()
	o := f.r.Overlay()
	o.SetCanvasSize(960, 480)
	c := gfx.NewCanvas(960, 208)
	c.Fill(0, 0, c.W, c.H, gfx.Purple)
	alpha := make([]byte, c.W*c.H)
	for i := range alpha {
		alpha[i] = 255
	}
	o.Show(0, 272, c, alpha)
	if f.r.want.first != 306 || f.r.want.last != 541 || f.r.want.width != 964 {
		t.Fatalf("panel bounds %+v", f.r.want)
	}
	if got := f.r.pages[0][541*964+963]; got != 0xFF000000|uint32(gfx.Purple) {
		t.Fatalf("bottom-right pixel %08x", got)
	}
}

func TestNativePlaybackCanvasFillsWideRasterWithProportionalTextSpace(t *testing.T) {
	f := newFake(t, false)
	f.fb = make([]byte, NPage*1280*720*4)
	f.r.fb = f.fb
	f.r.setOutput(1280, 720)
	f.r.setPages()
	o := f.r.Overlay()
	o.SetCanvasSize(960, 480)
	c := gfx.NewCanvas(960, 40)
	c.Fill(0, 0, c.W, c.H, gfx.Purple)
	alpha := make([]byte, c.W*c.H)
	for i := range alpha {
		alpha[i] = 255
	}
	o.Show(0, 440, c, alpha)
	if f.r.want.width != 1280 || f.r.want.height != 720 || f.r.want.first != 660 || f.r.want.last != 719 {
		t.Fatalf("native playback bounds %+v", f.r.want)
	}
	if got := f.r.pages[0][690*1280+640]; got != 0xFF000000|uint32(gfx.Purple) {
		t.Fatalf("native playback pixel %08x", got)
	}
}

func TestRasterSwitchRebuildsPagesForNativePALAndBackToMenu(t *testing.T) {
	f := newFake(t, true)
	f.fb = make([]byte, NPage*maxPageSize)
	f.r.fb = f.fb
	f.r.setOutput(W, H)
	f.r.setPages()
	if !f.r.syncOutput(Status{RasterW: 1280, RasterH: 720, RasterMode: 1}) {
		t.Fatal("native raster change was ignored")
	}
	if f.r.ow != 1280 || f.r.oh != 720 || f.r.npage != 2 {
		t.Fatalf("native pages %dx%d (%d pages)", f.r.ow, f.r.oh, f.r.npage)
	}
	if !f.r.syncOutput(Status{RasterW: 720, RasterH: 576}) {
		t.Fatal("PAL raster change was ignored")
	}
	if w, h := f.r.LayoutCanvasSize(); w != 720 || h != 480 {
		t.Fatalf("PAL layout %dx%d", w, h)
	}
	if f.r.ow != 720 || f.r.oh != 576 || f.r.npage != 2 {
		t.Fatalf("PAL pages %dx%d (%d pages)", f.r.ow, f.r.oh, f.r.npage)
	}
	pal := gfx.NewCanvas(720, 480)
	pal.Fill(0, 0, pal.W, pal.H, 0x123456)
	if err := f.r.Present(pal); err != nil {
		t.Fatal(err)
	}
	if got := f.r.pages[0][0]; got != 0xFF123456 {
		t.Fatalf("PAL first line %08x", got)
	}
	if got := f.r.pages[0][575*720]; got != 0xFF123456 {
		t.Fatalf("PAL last line %08x", got)
	}
	if !f.r.syncOutput(Status{RasterW: 720, RasterH: 480}) {
		t.Fatal("menu raster change was ignored")
	}
	if w, h := f.r.LayoutCanvasSize(); w != 720 || h != 480 {
		t.Fatalf("menu layout %dx%d", w, h)
	}
}

func TestPlaybackCanvasUsesSharedWideDisplayShape(t *testing.T) {
	f := newFake(t, false)
	f.set(wVersion, 0x103, 0)
	f.set(wDisplay, 1<<6, 0)
	if w, h := f.r.PlaybackCanvasSize(); w != 960 || h != 480 {
		t.Fatalf("wide playback canvas %dx%d", w, h)
	}
}

func TestNativePictureSizeFallbackUsesActualOutputAspect(t *testing.T) {
	f := newFake(t, false)
	f.set(wVersion, 0x103, 0)
	f.set(wDisplay, 1<<6, 0)   // user selected wide
	f.set(wAspect, 4|3<<12, 0) // source-sized fallback remains 4:3
	f.set(wRaster, 720|480<<12|1<<24, 0)
	if w, h := f.r.PlaybackCanvasSize(); w != 720 || h != 480 {
		t.Fatalf("4:3 native fallback canvas %dx%d", w, h)
	}
	f.set(wAspect, 16|9<<12, 0)
	f.set(wRaster, 1280|720<<12|1<<24, 0)
	f.r.setOutput(1280, 720)
	f.r.fb = make([]byte, NPage*maxPageSize)
	f.r.setPages()
	if w, h := f.r.PlaybackCanvasSize(); w != 960 || h != 480 {
		t.Fatalf("display-shaped native canvas %dx%d", w, h)
	}
}

func TestOutputSizeFitsNativeRastersWithinTwoPageBudget(t *testing.T) {
	for _, tc := range []struct{ w, h, wantW, wantH int }{
		{640, 360, 640, 360}, {720, 405, 720, 405}, {480, 854, 480, 854},
		{1280, 720, 1280, 720}, {1920, 1080, 1280, 720},
	} {
		w, h := outputSize(Status{RasterW: tc.w, RasterH: tc.h})
		if w != tc.wantW || h != tc.wantH {
			t.Errorf("outputSize(%dx%d) = %dx%d, want %dx%d", tc.w, tc.h, w, h, tc.wantW, tc.wantH)
		}
	}
}

func TestPortraitNativeCanvasAndOverlayKeepTheirShape(t *testing.T) {
	f := newFake(t, false)
	f.fb = make([]byte, NPage*1280*720*4)
	f.r.fb = f.fb
	f.r.setOutput(480, 854)
	f.r.setPages()
	f.set(wVersion, 0x103, 0)
	f.set(wRaster, 480|854<<12|1<<24, 0)
	f.set(wAspect, 9|16<<12, 0)
	canvas := gfx.NewCanvas(720, 480)
	canvas.Fill(0, 0, canvas.W, canvas.H, 0x123456)
	if err := f.r.Present(canvas); err != nil {
		t.Fatal(err)
	}
	page := f.r.pages[f.r.cur]
	if page[100] != 0xFF000000 || page[427*480+240] != 0xFF123456 || page[853*480+240] != 0xFF000000 {
		t.Fatalf("portrait canvas was stretched: corner=%08x center=%08x bottom=%08x", page[100], page[427*480+240], page[853*480+240])
	}
	o := f.r.Overlay()
	o.SetCanvasSize(720, 480)
	panel := gfx.NewCanvas(3, 3)
	px := unsafe.Slice((*uint32)(unsafe.Pointer(&panel.Pix[0])), 9)
	for i := range px {
		px[i] = 0x00ABCDEF
	}
	o.Show(0, 0, panel, nil)
	page = f.r.pages[f.r.cur]
	if page[247*480] != 0xFFABCDEF {
		t.Fatalf("portrait overlay did not share the fitted canvas: %08x", page[247*480])
	}
}

func TestUltrawideNativeFallbackFitsSixteenByNineCanvas(t *testing.T) {
	st := Status{RasterMode: 1, RasterW: 1280, RasterH: 720, ARX: 235, ARY: 100}
	x, y, w, h := nativeViewport(st, 960, 1280, 720)
	if x <= 0 || y != 0 || h != 720 || w < 960 || w > 980 {
		t.Fatalf("ultrawide viewport %d,%d %dx%d", x, y, w, h)
	}
}

func TestResizeWaitTimeoutRetriesAndPreservesOpaqueOverlay(t *testing.T) {
	f := newFake(t, true)
	o := f.r.Overlay()
	o.SetOpaque(true)
	f.ack.Store(false)
	if f.r.syncOutput(Status{RasterW: 640, RasterH: 360}) {
		t.Fatal("resize switched pages without core acknowledgment")
	}
	if !o.opaque {
		t.Fatal("opaque backdrop intent was lost during timed out resize")
	}
	f.ack.Store(true)
	if !f.r.syncOutput(Status{RasterW: 640, RasterH: 360}) {
		t.Fatal("resize did not retry after acknowledgment became available")
	}
	if f.r.ow != 640 || f.r.oh != 360 || f.r.want.width != 640 || f.r.want.height != 360 || !f.r.want.on {
		t.Fatalf("resized opaque pages %+v, %dx%d", f.r.want, f.r.ow, f.r.oh)
	}
}

func TestNativeFramebufferCapacityFallbackKeepsTheCenteredCanvas(t *testing.T) {
	f := newFake(t, false)
	f.fb = make([]byte, NPage*pageSize)
	f.r.fb = f.fb
	f.r.setOutput(W, H)
	f.r.setPages()
	f.set(wVersion, 0x103, 0)
	f.set(wRaster, 1280|720<<12|1<<24, 0)
	f.set(wAspect, 16|9<<12, 0)
	if f.r.syncOutput(Status{RasterW: 1280, RasterH: 720, RasterMode: 1}) {
		t.Fatal("undersized framebuffer unexpectedly switched to native pages")
	}
	if w, h := f.r.PlaybackCanvasSize(); w != 720 || h != 480 {
		t.Fatalf("fallback layout %dx%d", w, h)
	}
}

func TestDescriptorCheckMatchesTheCore(t *testing.T) {
	ok := desc{on: true, format: FmtARGB8888, base: fbByte, width: 720, height: 480, stride: 2880, first: 0, last: 479}
	if e := ok.check(); e != 0 {
		t.Fatal(e)
	}
	for want, d := range map[int]desc{
		1: {on: true, format: 3, base: fbByte, width: 720, height: 480, stride: 2880, last: 479},
		2: {on: true, format: 2, base: fbByte, width: 0, height: 480, stride: 2880, last: 479},
		3: {on: true, format: 2, base: fbByte, width: 720, height: 480, stride: 2876, last: 479},
		4: {on: true, format: 2, base: fbByte + 4, width: 720, height: 480, stride: 2880, last: 479},
		5: {on: true, format: 2, base: fbByte, width: 720, height: 480, stride: 2880, first: 10, last: 480},
		6: {on: true, format: 2, base: fbByte + fbSize - pageSize + 8, width: 720, height: 480, stride: 2880, last: 479},
	} {
		if got := d.check(); got != want {
			t.Errorf("check %+v = %d, want %d", d, got, want)
		}
	}
}

func TestPagesFlipOnlyAfterTheCoreReadTheDescriptor(t *testing.T) {
	f := newFake(t, true)
	for i, c := range []uint32{0x112233, 0x445566, 0x778899} {
		f.r.Present(canvas(c))
		if f.r.cur != i%2 {
			t.Fatalf("frame %d in page %d", i, f.r.cur)
		}
	}
	f.r.mu.Lock()
	f.r.waitAck(time.Second)
	f.r.mu.Unlock()
	f.mu.Lock()
	seen := append([]desc(nil), f.seen...)
	f.mu.Unlock()
	if len(seen) != 3 {
		t.Fatalf("the core took %d descriptors, want each of 3: %+v", len(seen), seen)
	}
	for i, d := range seen {
		if d.base != fbByte+uint32(i%2*pageSize) {
			t.Fatalf("descriptor %d at 0x%x", i, d.base)
		}
	}
	if f.r.AckLate() != 0 {
		t.Fatalf("%d waits ran out with a running core", f.r.AckLate())
	}
	// page 0 holds the third frame, page 1 the second, both opaque
	if p := f.r.pages[0][1000]; p != 0xFF778899 {
		t.Fatalf("page 0 = %08x", p)
	}
	if p := f.r.pages[1][1000]; p != 0xFF445566 {
		t.Fatalf("page 1 = %08x", p)
	}
}

func TestAStalledCoreCannotHangPresent(t *testing.T) {
	f := newFake(t, true)
	f.ack.Store(false)
	start := time.Now()
	for i := 0; i < 3; i++ {
		f.r.Present(canvas(0))
	}
	if el := time.Since(start); el > 4*ackWait {
		t.Fatalf("three frames took %s", el)
	}
	if f.r.AckLate() != 2 {
		t.Fatalf("AckLate %d, want 2", f.r.AckLate())
	}
}

func TestGenerationStaysAheadOfAnotherWriter(t *testing.T) {
	if g := nextGen(5, 900, 899); g != 901 {
		t.Fatalf("nextGen = %d", g)
	}
	if g := nextGen(900, 1, 1); g != 901 { // the player's library counts from 1
		t.Fatalf("nextGen behind = %d", g)
	}
	if g := nextGen(0x7FFFFFFF, 0, 0); g != 1 {
		t.Fatalf("nextGen wrap = %d", g)
	}
	if !genReached(5, 5) || !genReached(6, 5) || genReached(4, 5) || !genReached(1, 0x7FFFFFFF) {
		t.Fatal("genReached")
	}
	f := newFake(t, true)
	f.r.Present(canvas(0))
	g := f.r.gen
	// the player's session start writes its descriptor (none) with gen 1
	f.r.mu.Lock()
	f.r.c.writeDesc(desc{}, 1)
	f.r.mu.Unlock()
	if !f.r.reassert() {
		t.Fatal("reassert did nothing")
	}
	if f.r.gen <= g || f.lo(wOvlGenLo) != f.r.gen || f.lo(wOvlCtl)&ovlEnable == 0 {
		t.Fatalf("after reassert gen %d (was %d), word 72 %d, ctl %x", f.r.gen, g, f.lo(wOvlGenLo), f.lo(wOvlCtl))
	}
	if f.r.reassert() {
		t.Fatal("reassert with our own words in place")
	}
}

func TestAlphaFillAndBrightness(t *testing.T) {
	src := []uint32{0x00000000, 0x00FFFFFF, 0x00102030, 0xAB102030}
	dst := make([]uint32, len(src))
	fillOpaque(dst, src, Full)
	for i, want := range []uint32{0xFF000000, 0xFFFFFFFF, 0xFF102030, 0xFF102030} {
		if dst[i] != want {
			t.Fatalf("pixel %d = %08x, want %08x", i, dst[i], want)
		}
	}
	fillOpaque(dst, src, Full/2)
	for i, want := range []uint32{0xFF000000, 0xFF7F7F7F, 0xFF081018, 0xFF081018} {
		if dst[i] != want {
			t.Fatalf("half: pixel %d = %08x, want %08x", i, dst[i], want)
		}
	}
	f := newFake(t, false)
	f.r.Present(canvas(0x00204060))
	f.r.SetBrightness(Full / 4)
	if lvl, ok := f.r.Brightness(); lvl != Full/4 || !ok {
		t.Fatal(lvl, ok)
	}
	if p := f.r.pages[f.r.cur][0]; p != 0xFF081018 {
		t.Fatalf("dimmed frame shows %08x", p)
	}
}

func TestBandDrawsOnlyItsLines(t *testing.T) {
	f := newFake(t, false)
	f.r.PresentBand(canvas(0x00ABCDEF), 400, 459)
	p := f.r.pages[f.r.cur]
	if p[399*W] != 0 || p[400*W] != 0xFFABCDEF || p[459*W+719] != 0xFFABCDEF || p[460*W] != 0 {
		t.Fatal("band pixels")
	}
	if b := f.lo(wOvlBand); b != 459<<16|400 {
		t.Fatalf("band word %x", b)
	}
}

func TestOverlayComposesItsLinesOnly(t *testing.T) {
	f := newFake(t, false)
	o := f.r.Overlay()
	if f.lo(wOvlCtl) != 0 {
		t.Fatal("a new overlay is shown")
	}
	panel := gfx.NewCanvas(100, 20)
	px := unsafe.Slice((*uint32)(unsafe.Pointer(&panel.Pix[0])), 100*20)
	for i := range px {
		px[i] = 0x00336699
	}
	alpha := make([]byte, 100*20)
	for i := range alpha {
		alpha[i] = 0x80
	}
	o.Show(200, 300, panel, alpha)
	if b := f.lo(wOvlBand); b != 319<<16|300 {
		t.Fatalf("band %x", b)
	}
	page := f.r.pages[f.r.cur]
	if page[300*W+199] != 0 || page[300*W+200] != 0x80336699 || page[319*W+299] != 0x80336699 || page[319*W+300] != 0 {
		t.Fatal("panel pixels")
	}
	o.Dot(50, 100, 0xFF0000, true)
	if b := f.lo(wOvlBand); b != 319<<16|93 {
		t.Fatalf("band with the dot %x", b)
	}
	page = f.r.pages[f.r.cur]
	if page[100*W+50] != 0xFFFF0000 || page[100*W+60] != 0 || page[150*W+50] != 0 {
		t.Fatal("dot pixels")
	}
	o.Hide()
	o.Dot(0, 0, 0, false)
	if f.lo(wOvlCtl) != 0 {
		t.Fatal("nothing visible, yet shown")
	}
}

func TestOverlayOpaqueBackdropBlendsOverBlackAndCanBeCleared(t *testing.T) {
	f := newFake(t, false)
	o := f.r.Overlay()
	o.SetOpaque(true)
	if band := f.lo(wOvlBand); band != (H-1)<<16 {
		t.Fatalf("opaque band %x, want full screen", band)
	}
	page := f.r.pages[f.r.cur]
	if page[0] != 0xFF000000 || page[H*W-1] != 0xFF000000 {
		t.Fatalf("opaque background corners = %08x, %08x", page[0], page[H*W-1])
	}

	panel := gfx.NewCanvas(100, 20)
	px := unsafe.Slice((*uint32)(unsafe.Pointer(&panel.Pix[0])), 100*20)
	for i := range px {
		px[i] = 0x00336699
	}
	alpha := make([]byte, 100*20)
	for i := range alpha {
		alpha[i] = 0x80
	}
	o.Show(200, 300, panel, alpha)
	page = f.r.pages[f.r.cur]
	if got := page[300*W+200]; got != 0xFF1A334D {
		t.Fatalf("half-alpha panel over black = %08x, want ff1a334d", got)
	}
	if got := page[0]; got != 0xFF000000 {
		t.Fatalf("opaque background outside panel = %08x", got)
	}

	o.SetOpaque(false)
	if band := f.lo(wOvlBand); band != (319<<16 | 300) {
		t.Fatalf("transparent band after clearing backdrop = %x", band)
	}
	if got := f.r.pages[f.r.cur][300*W+200]; got != 0x80336699 {
		t.Fatalf("transparent panel pixel after clearing backdrop = %08x", got)
	}
}

func TestOverlayRepeatedDotAnchorKeepsRunPosition(t *testing.T) {
	f := newFake(t, false)
	o := f.r.Overlay()
	o.Dot(100, 100, 0xFF0000, true)
	o.DotRun(2, 50, 150)
	defer o.DotRun(0, 50, 150)

	f.field(1)
	if got := o.DotX(); got != 102 {
		t.Fatalf("dot after one field = %d, want 102", got)
	}
	// waitDot refreshes the same sprite anchor each field. That must not
	// reset the run origin and pull the moving dot back to x=100.
	o.Dot(100, 100, 0xFF0000, true)
	f.field(2)
	if got := o.DotX(); got != 104 {
		t.Fatalf("dot after repeated anchor and another field = %d, want 104", got)
	}
	// Updating the sprite at that same anchor must preserve the active run,
	// whether the appearance or visibility changes.
	o.Dot(100, 100, 0x00FF00, true)
	f.field(3)
	if got := o.DotX(); got != 106 {
		t.Fatalf("dot after color change = %d, want 106", got)
	}
	o.Dot(100, 100, 0x00FF00, false)
	f.field(4)
	if got := o.DotX(); got != 108 {
		t.Fatalf("dot after visibility change = %d, want 108", got)
	}
	// A genuinely new anchor repositions the sprite and starts the run there.
	o.Dot(120, 100, 0x00FF00, false)
	f.field(5)
	if got := o.DotX(); got != 122 {
		t.Fatalf("dot after new anchor = %d, want 122", got)
	}
}

func TestOverlayBatchCoalescesConcurrentPainterAndSpriteUpdates(t *testing.T) {
	f := newFake(t, true)
	o := f.r.Overlay()
	before := f.r.gen

	o.BeginUpdate()
	o.Dot(100, 100, 0xFFFFFF, true)
	o.BeginUpdate()
	o.Bar(200, 300, 40, 4, 0xFFFFFF, true)
	o.EndUpdate()
	if f.r.gen != before {
		t.Fatalf("nested batch published generation %d before outer end (was %d)", f.r.gen, before)
	}
	panel := gfx.NewCanvas(2, 2)
	px := unsafe.Slice((*uint32)(unsafe.Pointer(&panel.Pix[0])), 4)
	for i := range px {
		px[i] = 0x00336699
	}
	painterDone := make(chan struct{})
	go func() {
		o.Show(10, 20, panel, nil)
		close(painterDone)
	}()
	<-painterDone
	o.EndUpdate()
	if got := f.r.gen; got != before+1 {
		t.Fatalf("batch published %d generations, want 1", got-before)
	}
	page := f.r.pages[f.r.cur]
	if got := page[100*W+100]; got != 0xFFFFFFFF {
		t.Fatalf("batched dot pixel = %08x, want ffffffff", got)
	}
	if got := page[300*W+200]; got != 0xFFFFFFFF {
		t.Fatalf("batched bar pixel = %08x, want ffffffff", got)
	}
	if got := page[20*W+10]; got != 0xFF336699 {
		t.Fatalf("concurrent painter pixel = %08x, want ff336699", got)
	}
}

func TestOverlayUnchangedSpriteCallsDoNotFlip(t *testing.T) {
	f := newFake(t, true)
	o := f.r.Overlay()
	o.Dot(100, 100, 0xFF0000, true)
	dotGen := f.r.gen
	o.Dot(100, 100, 0xFF0000, true)
	if f.r.gen != dotGen {
		t.Fatalf("unchanged dot published generation %d after %d", f.r.gen, dotGen)
	}
	o.Dot(100, 100, 0x00FF00, true)
	if f.r.gen == dotGen {
		t.Fatal("dot color change was not published")
	}

	o.Bar(200, 300, 40, 4, 0xFFFFFF, true)
	barGen := f.r.gen
	o.Bar(200, 300, 40, 4, 0xFFFFFF, true)
	if f.r.gen != barGen {
		t.Fatalf("unchanged bar published generation %d after %d", f.r.gen, barGen)
	}
	o.Bar(200, 300, 40, 4, 0xFFFFFF, false)
	if f.r.gen == barGen {
		t.Fatal("bar visibility change was not published")
	}
}

func TestOverlayUnchangedHideAndShowAtDoNotFlip(t *testing.T) {
	f := newFake(t, true)
	o := f.r.Overlay()
	o.Hide()
	hideGen := f.r.gen
	o.Hide()
	if f.r.gen != hideGen {
		t.Fatalf("unchanged hide published generation %d after %d", f.r.gen, hideGen)
	}

	c := gfx.NewCanvas(16, 8)
	px := unsafe.Slice((*uint32)(unsafe.Pointer(&c.Pix[0])), c.W*c.H)
	for i := range px {
		px[i] = 0x00112233
	}
	o.Upload(0, c, 255)
	o.ShowAt(20, 30, 16, 8, 0)
	showGen := f.r.gen
	o.ShowAt(20, 30, 16, 8, 0)
	if f.r.gen != showGen {
		t.Fatalf("unchanged ShowAt published generation %d after %d", f.r.gen, showGen)
	}

	px[0] = 0x00445566
	o.Upload(0, c, 255)
	o.ShowAt(20, 30, 16, 8, 0)
	if f.r.gen == showGen {
		t.Fatal("ShowAt did not publish newly uploaded region contents")
	}
	if got := f.r.pages[f.r.cur][30*W+20]; got != 0xFF445566 {
		t.Fatalf("updated ShowAt pixel = %08x", got)
	}
}

func TestOverlayUnchangedSpriteRepairsReplacedDescriptor(t *testing.T) {
	f := newFake(t, true)
	o := f.r.Overlay()
	o.Dot(100, 100, 0xFF0000, true)
	oldGen := f.r.gen
	f.r.mu.Lock()
	f.r.c.writeDesc(desc{}, oldGen+100)
	f.r.mu.Unlock()
	o.Dot(100, 100, 0xFF0000, true)
	if f.r.gen <= oldGen+100 || f.lo(wOvlCtl)&ovlEnable == 0 {
		t.Fatalf("same dot did not reassert overlay: gen %d control %x", f.r.gen, f.lo(wOvlCtl))
	}
}

func TestOverlayHideRepairsReplacedVisibleDescriptor(t *testing.T) {
	f := newFake(t, true)
	o := f.r.Overlay()
	gen := f.r.gen
	f.r.mu.Lock()
	f.r.c.writeDesc(desc{on: true, format: FmtARGB8888, base: fbByte, width: W, height: H,
		stride: stride, last: H - 1}, gen+100)
	f.r.mu.Unlock()
	o.Hide()
	if f.r.gen <= gen+100 || f.lo(wOvlCtl)&ovlEnable != 0 {
		t.Fatalf("hide did not clear replaced descriptor: gen %d control %x", f.r.gen, f.lo(wOvlCtl))
	}
}

func TestOverlayUnchangedSpriteRestoresAfterFrameReplacement(t *testing.T) {
	f := newFake(t, true)
	o := f.r.Overlay()
	o.Dot(100, 100, 0xFF0000, true)
	overlayGen := f.r.gen
	f.r.Present(canvas(0x00123456))
	frameGen := f.r.gen
	if frameGen == overlayGen || !f.r.frame {
		t.Fatal("frame did not replace overlay")
	}
	o.Dot(100, 100, 0xFF0000, true)
	if f.r.gen == frameGen || f.r.frame || f.lo(wOvlCtl)&ovlEnable == 0 {
		t.Fatal("unchanged dot did not restore overlay after frame")
	}
	if got := f.r.pages[f.r.cur][100*W+100]; got != 0xFFFF0000 {
		t.Fatalf("restored dot pixel = %08x", got)
	}
}

func TestOverlayDotRunStopsPublishing(t *testing.T) {
	f := newFake(t, true)
	o := f.r.Overlay()
	o.Dot(100, 100, 0xFFFFFF, true)
	o.DotRun(1, 0, W)
	gen := func() uint32 {
		f.r.mu.Lock()
		defer f.r.mu.Unlock()
		return f.r.gen
	}
	start := gen()
	deadline := time.Now().Add(time.Second)
	for gen() == start && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if gen() == start {
		t.Fatal("moving dot did not publish")
	}
	o.DotRun(0, 0, W)
	time.Sleep(30 * time.Millisecond)
	stopped := gen()
	time.Sleep(30 * time.Millisecond)
	if got := gen(); got != stopped {
		t.Fatalf("stopped dot kept publishing: generation %d then %d", stopped, got)
	}
}

func TestStatusDecoding(t *testing.T) {
	f := newFake(t, false)
	f.set(wState, statePlaying|uint32(LiveSession|LiveOSDOpen)<<16, 0)
	f.set(wOvlStat, 77, OvlRefused|5<<4|3<<8)
	f.set(wRaster, 1280|720<<12|1<<24|3<<27, 0)
	f.set(wAspect, 16|9<<12, 0)
	f.set(wSeqTail, 42, 0)
	f.set(wSeqHead, 42, 0)
	st, ok := f.r.Status()
	if !ok || st.Heartbeat != 42 || st.State != statePlaying || !st.Session() || !st.OSDOpen() ||
		st.OvlGen != 77 || st.OvlState != OvlRefused || st.OvlErr != 5 || st.OvlTorn != 3 ||
		st.RasterW != 1280 || st.RasterH != 720 || st.RasterMode != 1 || st.VideoOut != 3 || st.ARX != 16 || st.ARY != 9 {
		t.Fatalf("%+v %v", st, ok)
	}
	f.set(wSeqTail, 43, 0) // the core mid-write: never a torn copy
	if _, ok := f.r.Status(); ok {
		t.Fatal("a torn status read as consistent")
	}
	if f.r.CoreRunning(10 * time.Millisecond) {
		t.Fatal("a still heartbeat read as running")
	}
}

func TestCoreRunningNeedsTheMagicAndAHeartbeat(t *testing.T) {
	f := newFake(t, true)
	if !f.r.CoreRunning(time.Second) {
		t.Fatal("running core not seen")
	}
	f.close()
	if f.r.CoreRunning(30 * time.Millisecond) {
		t.Fatal("a stopped core read as running")
	}
	f2 := newFake(t, true)
	f2.set(wVersion, 0x200, 0) // another major version
	if f2.r.CoreRunning(30 * time.Millisecond) {
		t.Fatal("an interface 2.x core accepted")
	}
}

func TestIdleSessionHandshakeAndLock(t *testing.T) {
	defer func(old string) { lockFile = old }(lockFile)
	lockFile = filepath.Join(t.TempDir(), "h264ring.lock")
	f := newFake(t, true)
	f.set(wWriteIdx, 0x1237, 0) // a cold boot's random index
	var order []int
	var mu sync.Mutex
	f.r.c.trace = func(w int, v uint32) { mu.Lock(); order = append(order, w); mu.Unlock() }

	// the player holds the lock: no session, nothing written
	fd, err := syscall.Open(lockFile, syscall.O_RDWR|syscall.O_CREAT, 0o666)
	if err != nil {
		t.Fatal(err)
	}
	if err := syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatal(err)
	}
	if err := f.r.ensureSession(); err != errLocked {
		t.Fatalf("with the lock taken: %v", err)
	}
	if len(order) != 0 {
		t.Fatalf("wrote %v while the player held the lock", order)
	}
	syscall.Close(fd)

	if err := f.r.ensureSession(); err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	got := append([]int(nil), order...)
	mu.Unlock()
	if got[len(got)-1] != wNonce {
		t.Fatalf("the nonce was not written last: %v", got)
	}
	for _, w := range []int{wPause, wSettings, wRumble, wWriteIdx, wOvlGenHi, wOvlGenLo} {
		found := false
		for _, g := range got[:len(got)-1] {
			found = found || g == w
		}
		if !found {
			t.Fatalf("word %d not written before the nonce: %v", w, got)
		}
	}
	if f.lo(wWriteIdx) != 0x1230 || f.hi(wAck) != f.lo(wNonce) {
		t.Fatalf("write index %x, ack %x nonce %x", f.lo(wWriteIdx), f.hi(wAck), f.lo(wNonce))
	}
	// the lock was released: the player can take it now
	fd, _ = syscall.Open(lockFile, syscall.O_RDWR, 0)
	defer syscall.Close(fd)
	if err := syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatalf("lock still held after the handshake: %v", err)
	}
	// a session open: nothing more to do, and nothing written
	mu.Lock()
	order = nil
	mu.Unlock()
	if err := f.r.ensureSession(); err != nil || len(order) != 0 {
		t.Fatalf("with a session open: %v, wrote %v", err, order)
	}
}

func TestLaunchCoreWritesTheMGLOnlyWhenNeeded(t *testing.T) {
	dir := t.TempDir()
	defer func(a, b, c string) { coreNameFile, mglFile, cmdFile = a, b, c }(coreNameFile, mglFile, cmdFile)
	coreNameFile, mglFile, cmdFile = filepath.Join(dir, "CORENAME"), filepath.Join(dir, "h264ring.mgl"), filepath.Join(dir, "MiSTer_cmd")
	os.WriteFile(cmdFile, nil, 0o644)

	os.WriteFile(coreNameFile, []byte("MisterZine Plex Core\n"), 0o644)
	if name, ok := CoreName(); !ok || name != "MisterZine Plex Core" || !CoreLoaded() {
		t.Fatalf("app core identity: %q, %v, loaded %v", name, ok, CoreLoaded())
	}
	if err := LaunchCore("", time.Second); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(mglFile); err == nil {
		t.Fatal("an MGL written with the core loaded")
	}

	// the upstream decoder, or the Jellyfin app's older core, is another app's
	os.WriteFile(coreNameFile, []byte("H264\n"), 0o644)
	if CoreLoaded() {
		t.Fatal("the H264 core taken for the Plex app's")
	}
	os.WriteFile(coreNameFile, []byte("MENU"), 0o644)
	if name, ok := CoreName(); !ok || name != "MENU" || CoreLoaded() {
		t.Fatalf("other core identity: %q, %v, loaded %v", name, ok, CoreLoaded())
	}
	go func() {
		time.Sleep(150 * time.Millisecond)
		os.WriteFile(coreNameFile, []byte(AppCoreName), 0o644)
	}()
	if err := LaunchCore("_Other/PlexH264_test", 2*time.Second); err != nil {
		t.Fatal(err)
	}
	mgl, _ := os.ReadFile(mglFile)
	if string(mgl) != "<mistergamedescription>\n  <rbf>_Other/PlexH264_test</rbf>\n</mistergamedescription>\n" {
		t.Fatalf("MGL %q", mgl)
	}
	cmd, _ := os.ReadFile(cmdFile)
	if string(cmd) != "load_core "+mglFile+"\n" {
		t.Fatalf("command %q", cmd)
	}

	os.WriteFile(coreNameFile, []byte("MENU"), 0o644)
	if err := LaunchCore("", 250*time.Millisecond); err == nil || !strings.Contains(err.Error(), "did not load") {
		t.Fatalf("timeout: %v", err)
	}
}

func TestCoreSwitchStopsFramebufferAndDescriptorWrites(t *testing.T) {
	f := newFake(t, false)
	old := coreNameFile
	coreNameFile = filepath.Join(t.TempDir(), "CORENAME")
	t.Cleanup(func() { coreNameFile = old })
	if err := os.WriteFile(coreNameFile, []byte("MisterZine Plex Core\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if !f.r.coreAvailable() {
		t.Fatal("app core was marked unavailable")
	}
	if err := os.WriteFile(coreNameFile, []byte("Other Core\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	fb := append([]byte(nil), f.fb...)
	ctrl := append([]uint32(nil), f.m...)
	if f.r.CoreAvailable() {
		t.Fatal("core switch was not detected")
	}
	f.r.End()
	f.r.Overlay().Show(0, 0, gfx.NewCanvas(1, 1), nil)
	f.r.Hide()
	if !bytes.Equal(fb, f.fb) {
		t.Fatal("framebuffer changed after the core switch")
	}
	if !slices.Equal(ctrl, f.m) {
		t.Fatal("control block changed after the core switch")
	}
	if err := os.WriteFile(coreNameFile, []byte("MisterZine Plex Core\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if f.r.coreAvailable() {
		t.Fatal("core loss latch cleared after the name reverted")
	}
}

func TestMappedRingRejectsMissingCoreIdentity(t *testing.T) {
	f := newFake(t, false)
	old := coreNameFile
	coreNameFile = filepath.Join(t.TempDir(), "missing-CORENAME")
	t.Cleanup(func() { coreNameFile = old })
	if !f.r.coreAvailable() {
		t.Fatal("host fake should tolerate a missing core name")
	}
	f.r.ctrlMem = []byte{0} // marks a real mapped control block
	if f.r.CoreAvailable() {
		t.Fatal("mapped ring should reject a missing core identity")
	}
}

// The writers check the core several times a frame: they take the last
// reading of MiSTer's core name while it is fresh (Watch reads it every
// 50 ms), and read it themselves once it is stale, so a ring nobody
// watches still stops at a core switch.
func TestWritersReuseAFreshCoreNameReading(t *testing.T) {
	f := newFake(t, false)
	old := coreNameFile
	coreNameFile = filepath.Join(t.TempDir(), "CORENAME")
	t.Cleanup(func() { coreNameFile = old })
	if err := os.WriteFile(coreNameFile, []byte("MisterZine Plex Core\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	f.r.ctrlMem = []byte{0}
	if !f.r.CoreAvailable() {
		t.Fatal("app core was marked unavailable")
	}
	if err := os.WriteFile(coreNameFile, []byte("Other Core\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if !f.r.coreAvailable() {
		t.Fatal("a fresh reading was read again")
	}
	f.r.coreNamed.Store(time.Now().Add(-coreNameFresh).UnixNano())
	if f.r.coreAvailable() {
		t.Fatal("a stale reading was trusted")
	}
	f.r.coreNamed.Store(time.Now().UnixNano())
	if f.r.coreAvailable() {
		t.Fatal("core loss latch cleared by a fresh stamp")
	}
}

func TestMappedRingSuppressesWritesUntilHeartbeatResumes(t *testing.T) {
	f := newFake(t, false)
	old := coreNameFile
	coreNameFile = filepath.Join(t.TempDir(), "CORENAME")
	t.Cleanup(func() { coreNameFile = old })
	if err := os.WriteFile(coreNameFile, []byte("MisterZine Plex Core\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	f.r.ctrlMem = []byte{0}
	f.set(wSeqHead, 123, 0)
	f.set(wSeqTail, 123, 0)
	f.r.writeBeat.Store(123)
	f.r.writeBeatAt.Store(time.Now().Add(-200 * time.Millisecond).UnixNano())
	fb := append([]byte(nil), f.fb...)
	ctrl := append([]uint32(nil), f.m...)
	if f.r.writesAllowed() {
		t.Fatal("stalled heartbeat allowed writes")
	}
	f.r.End()
	if !bytes.Equal(fb, f.fb) || !slices.Equal(ctrl, f.m) {
		t.Fatal("stalled heartbeat changed framebuffer or control block")
	}
	f.set(wSeqHead, 124, 0) // same-core reset resumed
	f.set(wSeqTail, 124, 0)
	if !f.r.writesAllowed() {
		t.Fatal("resumed heartbeat did not restore write permission")
	}
	f.r.End()
	if bytes.Equal(fb, f.fb) {
		t.Fatal("framebuffer stayed blocked after heartbeat resumed")
	}
}

func TestRangeFreeReadsIomem(t *testing.T) {
	defer func(old string) { iomemFile = old }(iomemFile)
	iomemFile = filepath.Join(t.TempDir(), "iomem")
	os.WriteFile(iomemFile, []byte("00000000-1fffffff : System RAM\n  00008000-00afffff : Kernel code\nff200000-ff20ffff : ff200000.bridge\n"), 0o644)
	if !rangeFree(ctrlByte, ctrlLen) {
		t.Fatal("the control block reads as System RAM")
	}
	if rangeFree(0x1ffff000, 0x2000) {
		t.Fatal("an overlap with System RAM missed")
	}
}

func TestPlaybackControlsPreserveLoadingFrame(t *testing.T) {
	f := newFake(t, false)
	f.r.Present(canvas(0x00204060))
	before, gen, page := f.r.c.readDesc(), f.r.gen, f.r.cur
	o := f.r.Overlay()
	if !f.r.frame || f.r.c.readDesc() != before || f.r.gen != gen || f.r.cur != page {
		t.Fatal("creating playback controls cleared the loading frame")
	}
	o.Hide()
	if f.r.frame || f.lo(wOvlCtl) != 0 {
		t.Fatal("explicitly hiding playback controls did not release the frame")
	}
}
