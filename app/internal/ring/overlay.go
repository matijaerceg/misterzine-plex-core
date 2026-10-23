package ring

import (
	"math"
	"time"
	"unsafe"

	"plexcrt/internal/gfx"
)

// Overlay is what the playback screens draw over the video: a rectangle of
// pixels with alpha, the dot (a disc, the scrub and wait marker) and the
// bar (a filled rectangle). The core has the one overlay page, so every
// change here composes them into the page not on screen -- the lines they cover,
// transparent elsewhere, declared as the band so the core fetches nothing
// else -- and flips to it. It shares the Ring's two pages: a frame from
// End replaces it, and a Show replaces the frame.
type Overlay struct {
	r                  *Ring
	logicalW, logicalH int

	opaque     bool // compose over an opaque black screen while a new stream starts
	on         bool
	x, y, w, h int
	src        []byte // the rectangle's pixels, alpha merged in (BGRA)
	srcStride  int
	own        []byte // src's storage for Show
	region     []byte // Upload's content, for ShowAt
	regionVer  uint64 // increments when Upload changes the backing region
	shownVer   uint64 // region version in the last composed page
	regionOff  int
	regionSrc  bool
	mapX       []int // reusable nearest-neighbor source column map

	dotOn        bool
	dotX, dotY   int
	dotRGB       uint32
	dotAnchorX   int // last requested place; dotX is rebased as the run moves
	dotAnchored  bool
	drawnDotX    int
	drawnDotSet  bool
	runV, runMin int
	runMax       int
	runField     uint32 // the heartbeat when the run (re)started at dotX
	running      chan struct{}
	barOn        bool
	barX, barY   int
	barW, barH   int
	barRGB       uint32
	row          []uint32
	batchDepth   int
	batchDirty   bool

	dotLine   bool   // the dot drawn as a line with a shadow (SetDotLine)
	jitter    bool   // the rectangle's lines shake sideways (SetJitter)
	jitterGen uint32 // the shake's pattern, moved on by Shake
	shifts    []int  // each of the rectangle's lines' shift, for compose
}

const dotRadius = 7

// The dot as a line (SetDotLine): dotLineHalf rows above and below its
// centre, dotLineW pixels wide, and a black shadow two pixels right and
// down, at the 480-line scale.
const (
	dotLineHalf = 9
	dotLineW    = 4
)

// SetDotLine draws the dot as an upright line with a hard shadow in place
// of the disc: the VCR look's playhead. It takes effect at the next change.
func (o *Overlay) SetDotLine(on bool) {
	o.r.mu.Lock()
	defer o.r.mu.Unlock()
	o.dotLine = on
}

// RegionSize is how many bytes Upload can hold (as the old plane's region).
const RegionSize = 0x160000

// Overlay creates hidden playback controls, preserving any presented menu or loading frame.
func (r *Ring) Overlay() *Overlay {
	o := &Overlay{r: r, logicalW: W, logicalH: H, row: make([]uint32, r.ow)}
	r.mu.Lock()
	r.overlay = o
	if !r.frame {
		o.compose()
	}
	r.mu.Unlock()
	return o
}

// SetCanvasSize sets the logical design space used by playback panels and
// their sprites. The core still receives pixels in the native raster.
func (o *Overlay) SetCanvasSize(w, h int) {
	o.r.mu.Lock()
	defer o.r.mu.Unlock()
	if w > 0 && h > 0 {
		o.logicalW, o.logicalH = w, h
	}
}

func (o *Overlay) transform() (sx, sy float64, x0, y0 int) {
	// The logical canvas describes the displayed shape; map its axes
	// independently to the physical output raster. A 960x480 wide design
	// therefore fills both anamorphic 720x480 and square-pixel 1280x720.
	st, _ := o.r.Status()
	x0, y0, w, h := nativeViewport(st, o.logicalW, o.r.ow, o.r.oh)
	sx = float64(w) / float64(max(1, o.logicalW))
	sy = float64(h) / float64(max(1, o.logicalH))
	return sx, sy, x0, y0
}

func (o *Overlay) point(x, y int) (int, int) {
	sx, sy, x0, y0 := o.transform()
	return int(float64(x)*sx+0.5) + x0, int(float64(y)*sy+0.5) + y0
}

// BeginUpdate groups several overlay changes into one framebuffer publish.
// Calls may overlap with the dot runner or painter; Ring.mu serializes each
// change and the outermost EndUpdate publishes the latest combined state.
func (o *Overlay) BeginUpdate() {
	o.r.mu.Lock()
	o.batchDepth++
	o.r.mu.Unlock()
}

// EndUpdate publishes changes accumulated since BeginUpdate. Nested updates
// publish only when the outermost update ends.
func (o *Overlay) EndUpdate() {
	o.r.mu.Lock()
	defer o.r.mu.Unlock()
	if o.batchDepth == 0 {
		return
	}
	o.batchDepth--
	if o.batchDepth == 0 && o.batchDirty {
		o.batchDirty = false
		o.compose()
	}
}

// update composes immediately unless an app-owned update group is open.
func (o *Overlay) update() {
	if o.batchDepth != 0 {
		o.batchDirty = true
		return
	}
	o.compose()
}

// Hide takes the rectangle off (the dot and the bar stay as they are).
func (o *Overlay) Hide() {
	o.r.mu.Lock()
	defer o.r.mu.Unlock()
	if !o.on && o.r.overlayCurrent() {
		return
	}
	o.on = false
	o.update()
}

// SetOpaque makes the overlay cover the full screen with an opaque black
// background. It is used while a new stream is starting, when the core may
// still be holding the previous stream's last picture. The panel, dot and
// bar are composed over black until opaque mode is cleared.
func (o *Overlay) SetOpaque(on bool) {
	o.r.mu.Lock()
	defer o.r.mu.Unlock()
	if o.opaque == on && o.r.overlayCurrent() {
		return
	}
	o.opaque = on
	o.update()
}

// overlaySpan maps the logical run [a, a+n) of a canvas lim long onto the
// raster at scale s from o0: its start even, its length even -- except a run
// that reaches the canvas's far edge, which ends at the viewport's. Rounding
// the start and the length separately left the playback panel two lines
// short of the bottom on a 964x542 Native raster (found on the DE10
// 2026-10-19).
func overlaySpan(a, n, lim int, s float64, o0 int) (int, int) {
	p := (int(float64(a)*s+0.5) + o0) &^ 1
	if a+n >= lim {
		return p, int(float64(lim)*s+0.5) + o0 - p
	}
	return p, int(float64(n)*s+0.5) &^ 1
}

// Show publishes a BGRx canvas at x,y with an alpha plane of the same size
// (0..255 a pixel; nil for opaque).
func (o *Overlay) Show(x, y int, c *gfx.Canvas, alpha []byte) {
	o.r.mu.Lock()
	defer o.r.mu.Unlock()
	sx, sy, x0, y0 := o.transform()
	var w, h int
	x, w = overlaySpan(x, c.W, o.logicalW, sx, x0)
	y, h = overlaySpan(y, c.H, o.logicalH, sy, y0)
	if w == 0 || h == 0 || x < 0 || y < 0 || x+w > o.r.ow || y+h > o.r.oh {
		return
	}
	if len(o.own) < w*h*4 {
		o.own = make([]byte, w*h*4)
	}
	if w == c.W && h == c.H {
		for yy := 0; yy < h; yy++ {
			copy(o.own[yy*w*4:(yy+1)*w*4], c.Pix[yy*c.W*4:(yy+1)*c.W*4])
		}
		if alpha != nil {
			for i, a := range alpha[:c.W*c.H] {
				o.own[i*4+3] = a
			}
		} else {
			for i := 3; i < len(o.own); i += 4 {
				o.own[i] = 255
			}
		}
		o.on, o.x, o.y, o.w, o.h = true, x, y, w, h
		o.src, o.srcStride = o.own, w*4
		o.regionSrc = false
		o.update()
		return
	}
	o.mapX = scaleCanvas(o.own, w, h, c, alpha, o.mapX)
	o.on, o.x, o.y, o.w, o.h = true, x, y, w, h
	o.src, o.srcStride = o.own, w*4
	o.regionSrc = false
	o.update()
}

// Upload stores a BGRx canvas at byte offset off of the region, with one
// alpha for every pixel, row after row (c.W*4 bytes a row), for ShowAt.
func (o *Overlay) Upload(off int, c *gfx.Canvas, alpha byte) {
	n := c.W * c.H * 4
	if off < 0 || off+n > RegionSize {
		return
	}
	o.r.mu.Lock()
	defer o.r.mu.Unlock()
	if o.region == nil {
		o.region = make([]byte, RegionSize)
	}
	dst := o.region[off : off+n]
	copy(dst, c.Pix[:n])
	for i := 3; i < n; i += 4 {
		dst[i] = alpha
	}
	o.regionVer++
}

// ShowAt shows a w x h rectangle at x,y whose pixels start at byte offset
// off of the uploaded region (w*4 bytes a row): scrolling uploaded content
// by its offset.
func (o *Overlay) ShowAt(x, y, w, h, off int) {
	o.r.mu.Lock()
	defer o.r.mu.Unlock()
	sx, sy, x0, y0 := o.transform()
	lw, lh := w, h
	x, y = int(float64(x)*sx+0.5)+x0, int(float64(y)*sy+0.5)+y0
	w, h = int(float64(w)*sx+0.5)&^1, int(float64(h)*sy+0.5)&^1
	x, y, off = x&^1, y&^1, off&^7
	if w <= 0 || h <= 0 || x < 0 || y < 0 || x+w > o.r.ow || y+h > o.r.oh || off < 0 || off+lw*lh*4 > RegionSize {
		return
	}
	if o.region == nil {
		o.region = make([]byte, RegionSize)
	}
	if o.on && o.regionSrc && o.x == x && o.y == y && o.w == w && o.h == h &&
		o.regionOff == off && o.shownVer == o.regionVer && o.r.overlayCurrent() {
		return
	}
	if len(o.own) < w*h*4 {
		o.own = make([]byte, w*h*4)
	}
	o.mapX = scaleRegion(o.own, w, h, o.region[off:off+lw*lh*4], lw, lh, o.mapX)
	o.on, o.x, o.y, o.w, o.h = true, x, y, w, h
	o.src, o.srcStride = o.own, w*4
	o.regionSrc, o.regionOff = true, off
	o.update()
}

// columnMap is the nearest source column of sw for each of w output
// columns, in m's storage when it is large enough.
func columnMap(m []int, w, sw int) []int {
	if cap(m) < w {
		m = make([]int, w)
	} else {
		m = m[:w]
	}
	for x := range m {
		m[x] = min(sw-1, x*sw/w)
	}
	return m
}

// scaleCanvas scales c nearest-neighbour into dst, w x h pixels, its
// alpha from the plane (nil for opaque). It works a word a pixel, and an
// output row whose source row is the one above's (scaling up) is a copy
// of that row. It returns mapX, the column map's storage.
func scaleCanvas(dst []byte, w, h int, c *gfx.Canvas, alpha []byte, mapX []int) []int {
	mapX = columnMap(mapX, w, c.W)
	out := unsafe.Slice((*uint32)(unsafe.Pointer(&dst[0])), len(dst)/4)[:w*h]
	src := unsafe.Slice((*uint32)(unsafe.Pointer(&c.Pix[0])), len(c.Pix)/4)
	last := -1
	for yy := 0; yy < h; yy++ {
		row := out[yy*w : (yy+1)*w]
		sy := min(c.H-1, yy*c.H/h)
		if sy == last {
			copy(row, out[(yy-1)*w:yy*w])
			continue
		}
		last = sy
		in := src[sy*c.W : (sy+1)*c.W]
		if alpha == nil {
			for x, sx := range mapX {
				row[x] = in[sx] | 0xFF000000
			}
			continue
		}
		a := alpha[sy*c.W : (sy+1)*c.W]
		for x, sx := range mapX {
			row[x] = in[sx]&0xFFFFFF | uint32(a[sx])<<24
		}
	}
	return mapX
}

// scaleRegion is scaleCanvas for uploaded pixels, lw x lh with their alpha
// in place: at 1:1 (a list on a 480-line raster) one copy.
func scaleRegion(dst []byte, w, h int, region []byte, lw, lh int, mapX []int) []int {
	if w == lw && h == lh {
		copy(dst[:w*h*4], region[:w*h*4])
		return mapX
	}
	mapX = columnMap(mapX, w, lw)
	out := unsafe.Slice((*uint32)(unsafe.Pointer(&dst[0])), len(dst)/4)[:w*h]
	src := unsafe.Slice((*uint32)(unsafe.Pointer(&region[0])), len(region)/4)[:lw*lh]
	last := -1
	for yy := 0; yy < h; yy++ {
		row := out[yy*w : (yy+1)*w]
		sy := min(lh-1, yy*lh/h)
		if sy == last {
			copy(row, out[(yy-1)*w:yy*w])
			continue
		}
		last = sy
		in := src[sy*lw : (sy+1)*lw]
		for x, sx := range mapX {
			row[x] = in[sx]
		}
	}
	return mapX
}

// Dot places the dot (a disc of radius 7 rows centred on x,y, frame
// pixels) or hides it.
func (o *Overlay) Dot(x, y int, rgb uint32, on bool) {
	o.r.mu.Lock()
	defer o.r.mu.Unlock()
	x, y = o.point(x, y)
	rgb &= 0xFFFFFF
	same := o.dotAnchored && o.dotAnchorX == x && o.dotY == y && o.dotRGB == rgb && o.dotOn == on
	dotPositionCurrent := !o.dotOn || o.runV != 0 || o.drawnDotSet && o.drawnDotX == o.dotXLocked()
	if same && dotPositionCurrent && o.r.overlayCurrent() {
		return
	}
	if !o.dotAnchored || o.dotAnchorX != x {
		o.dotX = x
		o.runField = o.r.Field()
	}
	o.dotAnchorX, o.dotAnchored = x, true
	o.dotY, o.dotRGB, o.dotOn = y, rgb, on
	o.update()
}

// DotRun moves the dot vx pixels every field (0 stops), within xmin..xmax:
// a goroutine redraws it each heartbeat. Read where it is with DotX.
func (o *Overlay) DotRun(vx, xmin, xmax int) {
	o.r.mu.Lock()
	defer o.r.mu.Unlock()
	sx, _, x0, _ := o.transform()
	o.dotX = o.dotXLocked()
	vx, xmin, xmax = runPixels(vx, sx), int(float64(xmin)*sx+0.5)+x0, int(float64(xmax)*sx+0.5)+x0
	o.runField = o.r.Field()
	o.runV, o.runMin, o.runMax = vx, max(0, xmin), max(0, xmax)
	if vx != 0 && o.running == nil {
		o.running = make(chan struct{})
		go o.run(o.running)
	} else if vx == 0 && o.running != nil {
		close(o.running)
		o.running = nil
	}
}

func (o *Overlay) run(stop chan struct{}) {
	last := o.r.Field()
	// one ticker for the run: a timer made every 4 ms was garbage the
	// collector had to clear while a scrub ran
	tick := time.NewTicker(4 * time.Millisecond)
	defer tick.Stop()
	for {
		select {
		case <-stop:
			return
		case <-tick.C:
		}
		if f := o.r.Field(); f != last {
			last = f
			o.r.mu.Lock()
			if o.dotOn {
				o.update()
			}
			o.r.mu.Unlock()
		}
	}
}

// runPixels is a run's vx frame pixels a field in raster pixels, rounded
// the same both ways and never to a standstill. Rounding the signed value
// up by a half (int(vx*sx+0.5)) truncated a leftward run towards zero: at
// 1:1 a run left stood still at one pixel a field and crawled at one where
// a run right moved two.
func runPixels(vx int, sx float64) int {
	if vx == 0 {
		return 0
	}
	n := max(1, int(math.Abs(float64(vx))*sx+0.5))
	if vx < 0 {
		return -n
	}
	return n
}

// DotX is where the dot is now.
func (o *Overlay) DotX() int {
	o.r.mu.Lock()
	defer o.r.mu.Unlock()
	x, _ := o.inversePoint(o.dotXLocked(), 0)
	return x
}

func (o *Overlay) inversePoint(x, y int) (int, int) {
	sx, sy, x0, y0 := o.transform()
	return int(float64(x-x0)/sx + 0.5), int(float64(y-y0)/sy + 0.5)
}

func (o *Overlay) dotXLocked() int {
	if o.runV == 0 {
		return o.dotX
	}
	x := o.dotX + o.runV*int(int32(o.r.Field()-o.runField))
	return max(o.runMin, min(o.runMax, x))
}

// Bar places the bar, a filled rectangle, or hides it.
func (o *Overlay) Bar(x, y, w, h int, rgb uint32, on bool) {
	o.r.mu.Lock()
	defer o.r.mu.Unlock()
	sx, sy, x0, y0 := o.transform()
	x, y = int(float64(x)*sx+0.5)+x0, int(float64(y)*sy+0.5)+y0
	w, h = int(float64(w)*sx+0.5), int(float64(h)*sy+0.5)
	rgb &= 0xFFFFFF
	if o.barX == x && o.barY == y && o.barW == w && o.barH == h && o.barRGB == rgb && o.barOn == on &&
		o.r.overlayCurrent() {
		return
	}
	o.barX, o.barY, o.barW, o.barH, o.barRGB, o.barOn = x, y, w, h, rgb, on
	o.update()
}

// SetJitter makes the rectangle's lines waver sideways, a pixel at most
// and the sprites on them with them, as an old deck's picture wavered on
// tape: the VCR look of the playback controls. The video under them stays
// put. It takes effect at the next change.
func (o *Overlay) SetJitter(on bool) {
	o.r.mu.Lock()
	defer o.r.mu.Unlock()
	o.jitter = on
}

// Shake moves the waver on a step and shows it, while the rectangle is
// up and wavering. A dimmed screen holds still: its veil makes every line
// of the page a compose's work.
func (o *Overlay) Shake() {
	o.r.mu.Lock()
	defer o.r.mu.Unlock()
	o.jitterGen++
	if o.jitter && o.on && o.r.dim == 0 {
		o.update()
	}
}

// jitterShifts fills shifts, one a line of the rectangle, with step gen's
// sideways shift in raster pixels at s raster pixels a design pixel: two
// slow waves down the lines that crawl a little at each step, their sum
// under a pixel, swelling and settling over some seconds. A deck's drum
// speeds up and slows down a little all the time, so its lines waver
// smoothly from one to the next (ntsc-rs's VHS edge wave is half a pixel
// by default); rounded to whole pixels, most lines sit in place and some
// stretches of them one pixel over.
func jitterShifts(shifts []int, gen uint32, s float64) {
	t := float64(gen)
	a := 0.55 + 0.25*math.Sin(t*0.05)
	for y := range shifts {
		fy := float64(y)
		d := a * (0.7*math.Sin(fy*(2*math.Pi/64)+t*0.12) + 0.3*math.Sin(fy*(2*math.Pi/23)-t*0.08+1.3))
		shifts[y] = int(math.Round(d * s))
	}
}

// shiftRow copies src into dst k pixels to the right (left for negative
// k), the end it uncovers continuing src's edge pixel: a panel that spans
// the raster keeps its background to the edge.
func shiftRow(dst, src []uint32, k int) {
	n := len(dst)
	switch {
	case k == 0 || n == 0:
		copy(dst, src)
	case k > 0:
		k = min(k, n)
		copy(dst[k:], src[:n-k])
		for x := range dst[:k] {
			dst[x] = src[0]
		}
	default:
		k = min(-k, n)
		copy(dst[:n-k], src[k:])
		for x := n - k; x < n; x++ {
			dst[x] = src[n-1]
		}
	}
}

// compose draws the rectangle, the bar and the dot into the page not on
// screen and flips to it; with none of them visible it hides the overlay.
// Called with r.mu held.
func (o *Overlay) compose() {
	r := o.r
	if !r.writesAllowed() {
		return
	}
	first, last := r.oh, -1
	span := func(y0, y1 int) {
		y0, y1 = max(0, y0), min(r.oh-1, y1)
		if y0 <= y1 {
			first, last = min(first, y0), max(last, y1)
		}
	}
	if o.opaque || r.dim != 0 {
		span(0, r.oh-1)
	}
	if o.on {
		span(o.y, o.y+o.h-1)
	}
	if o.barOn && o.barW > 0 && o.barH > 0 {
		span(o.barY, o.barY+o.barH-1)
	}
	dx := o.dotXLocked()
	radius, lineW := 0, 0 // the dot's, worked out once: transform reads the core's status
	if o.dotOn {
		sx, sy, _, _ := o.transform()
		radius = int(float64(dotRadius)*min(sx, sy) + 0.5)
		if o.dotLine {
			radius = int(float64(dotLineHalf)*sy + 0.5)
			lineW = max(2, int(float64(dotLineW)*sx+0.5))
			span(o.dotY-radius, o.dotY+radius+2) // and its shadow
		} else {
			span(o.dotY-radius, o.dotY+radius)
		}
	}
	if first > last || r.npage == 0 {
		if !r.overlayDescriptorCurrent(desc{}) {
			r.write(desc{})
		}
		r.frame = false
		return
	}
	p := r.flipTarget()
	if !r.writesAllowed() {
		return
	}
	page := r.pages[p]
	jit := o.jitter && o.on
	if jit {
		if cap(o.shifts) < o.h {
			o.shifts = make([]int, o.h)
		}
		o.shifts = o.shifts[:o.h]
		sx, _, _, _ := o.transform()
		jitterShifts(o.shifts, o.jitterGen, sx)
	}
	for y := first; y <= last; y++ {
		row := o.row
		if o.opaque {
			for x := range row {
				row[x] = 0xFF000000
			}
		} else {
			clear(row)
		}
		if o.on && y >= o.y && y < o.y+o.h {
			s := o.src[(y-o.y)*o.srcStride:]
			px := unsafe.Slice((*uint32)(unsafe.Pointer(&s[0])), o.w)
			if o.opaque {
				for x, src := range px {
					a := (src >> 24) & 0xFF
					r := ((src >> 16) & 0xFF) * a
					g := ((src >> 8) & 0xFF) * a
					b := (src & 0xFF) * a
					row[o.x+x] = 0xFF000000 | ((r+127)/255)<<16 | ((g+127)/255)<<8 | (b+127)/255
				}
			} else {
				copy(row[o.x:o.x+o.w], px)
			}
		}
		if o.barOn && y >= o.barY && y < o.barY+o.barH {
			for x := max(0, o.barX); x < min(r.ow, o.barX+o.barW); x++ {
				row[x] = 0xFF000000 | o.barRGB
			}
		}
		if o.dotOn && o.dotLine {
			x0 := dx - lineW/2
			if dy := y - o.dotY - 2; dy >= -radius && dy <= radius {
				for x := max(0, x0+2); x < min(r.ow, x0+2+lineW); x++ {
					row[x] = 0xFF000000 // the shadow, under the line where they meet
				}
			}
			if dy := y - o.dotY; dy >= -radius && dy <= radius {
				for x := max(0, x0); x < min(r.ow, x0+lineW); x++ {
					row[x] = 0xFF000000 | o.dotRGB
				}
			}
		} else if o.dotOn {
			if dy := y - o.dotY; dy >= -radius && dy <= radius {
				half := 0
				for half*half+dy*dy <= radius*radius {
					half++
				}
				for x := max(0, dx-half+1); x < min(r.ow, dx+half); x++ {
					row[x] = 0xFF000000 | o.dotRGB
				}
			}
		}
		if r.dim != 0 {
			// A black veil attenuates the video beneath transparent pixels.
			// Convert the combined result back to straight alpha, so panels
			// and sprites dim by the same amount as the paused picture.
			level := uint32(Full) - r.dim
			for x, pixel := range row {
				a := pixel >> 24
				alpha := 255 - (255-a)*level/Full
				if a == 0 {
					row[x] = alpha << 24
					continue
				}
				if alpha == 0 {
					row[x] = 0
					continue
				}
				denom := uint32(Full) * alpha
				red := ((pixel >> 16) & 255) * a * level / denom
				green := ((pixel >> 8) & 255) * a * level / denom
				blue := (pixel & 255) * a * level / denom
				row[x] = alpha<<24 | red<<16 | green<<8 | blue
			}
		}
		dst := page[y*(r.ostride/4) : y*(r.ostride/4)+r.ow]
		if jit && y >= o.y && y < o.y+o.h {
			shiftRow(dst, row, o.shifts[y-o.y])
		} else {
			copy(dst, row)
		}
	}
	r.describe(p, first, last)
	o.drawnDotX, o.drawnDotSet = dx, true
	if o.regionSrc {
		o.shownVer = o.regionVer
	}
	r.frame = false
}
