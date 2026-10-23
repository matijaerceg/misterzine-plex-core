package ui

import (
	"syscall"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/ring"
)

// previewer gives the scrub its small frames of the film. Frame returns
// the frame ready for film time t at display size, or nil; it never waits.
// Near tells the backend where the scrub is, so it prepares the frames
// there; it is called every Tick: with the scrub's place while a scrub is
// up, else with the playing position, so the frames round the picture are
// ready before a hold starts. Close drops everything when the playback
// ends. The backend is the server's (newPreviewer): nil is an item without
// previews.
//
// What a backend keeps and prepares, whatever its server serves:
//   - From its creation (the first Tick, at the start position) it
//     prepares round that position without waiting for a Near: a hold
//     in the first seconds either way has frames as soon as they can be
//     made.
//   - It keeps what holds the frames either side of the last Near, both
//     ways: for frames in sheets, the sheet under the position AND the one
//     before AND the one after (three, each fetched and decoded once while
//     it stays one of them), dropping a sheet only once it is none of the
//     three. It prepares them in that order: the one under the position,
//     then the neighbour the scrub moves towards (Near's direction: later
//     than the last Near is forward; forward before any), then the other.
//   - For single frames (the Plex BIF), it decodes first the frame the
//     dot will be at when the decode is done (its speed from successive
//     Nears times the decode time; the one under it when it stands), then
//     works outward from there, a few frames ahead the way the scrub moves
//     for each one behind, so a fast run finds frames where the dot is
//     going, not where it was.
//   - For single frames, once those round the scrub are in, it also
//     decodes a sparse set across the whole item (every Nth frame, a
//     bounded few megabytes, kept apart from the near ones) in the
//     background at its low priority, so a run anywhere has a frame at
//     once while the decodes round the dot catch up.
//   - Frame returns the nearest ready frame to t within a few frames (more
//     during a fast run: the dot moves faster than frames decode), else
//     the nearest of the sparse set, and nil only when none is near. For
//     frames in sheets, a run crossing into a sheet still decoding keeps
//     the last frame given from the sheet before until it lands.
//   - Its worker runs at nice 10 as the art workers do, but at normal
//     priority while a held run waits on it (the playback is paused
//     then), raised the moment the run starts so a decode under way
//     speeds up too, and for the first frames round the start position:
//     on the device a decode at nice 10 during a run took ten times as
//     long, and right after a playback started a trickplay sheet took
//     33 s at nice 10, so a hold in the first half minute had no frame.
//   - It never fetches or decodes on the caller's thread, and a failed
//     fetch or decode is retried a bounded number of times, not forever.
//
// What the UI does with it: during a held run the frame Frame gives floats
// above the panel or the strip, borderless; while Frame gives nil (the
// first sheet or file still on its way) a placeholder of the frame's size
// takes its place, a dark box at the panel's alpha with the wait dots
// swelling in its middle, until a frame is ready. A tap, an item without
// previews (nil) and the end of the hold show neither.
type previewer interface {
	Frame(t float64) *gfx.Image
	Near(t float64)
	Close()
}

// The preview's geometry: frames are PreviewH lines high, borderless (a
// frame or outline looked awkward on a 15 kHz set), and float PreviewGap
// lines above the panel or the strip. previewLift is the rows they take
// above it, even so the panel keeps its field.
const (
	PreviewH    = 90
	PreviewGap  = 10 // where the bordered picture's bottom edge was
	previewLift = PreviewH + PreviewGap
)

// previewSize is the frame's size on a cw x ch canvas shown as 4:3: 90
// lines high and as wide as shows 16:9 (180 on a 720-wide canvas).
func previewSize(cw, ch int) (w, h int) {
	ch = max(1, ch)
	return (160*cw*3 + 2*ch) / (4 * ch), PreviewH
}

// previewImage scales a decoded source frame to the display size, off the
// UI thread: a box filter down, rows only when the width already fits.
func previewImage(src *gfx.Image, w, h int) *gfx.Image {
	if src == nil {
		return nil
	}
	if w < src.W && h < src.H {
		return src.Shrink(w, h)
	}
	return src.Crop(w, src.H).ScaleH(h)
}

// previewX is where the frame (ow wide) goes: centred on the
// dot's x and kept within the safe area.
func previewX(dotX, ow, safeX, safeW int) int {
	return max(safeX, min(dotX-ow/2, safeX+safeW-ow))
}

// previewTick runs every Tick, after the dot's place is taken. A hold that
// runs puts the preview up and pauses the playback (unless it already was
// paused); the gesture's seek or the scrub's end takes it down and
// resumes. A tap never gets here: it does not run.
func (p *Playing) previewTick(now time.Time) {
	if p.preview == nil {
		return
	}
	if p.running(now) && p.heldAt != p.pvHold {
		p.pvHold, p.pvOn = p.heldAt, true
		if !p.paused {
			// the frames are the thing to look at; the launcher's report
			// lags, so the state is ours until it catches up (pausedAt)
			p.paused, p.pausedAt, p.pvPaused = true, now, true
			p.send("pause")
			p.dirty = true
		}
	}
	if !p.scrub && (p.pvOn || p.pvPaused) {
		p.endPreview(now) // dropped: Back, Down without a seek, the timeout
	}
	// the backend prepares where the scrub is, or where the picture is
	// before any: the first hold then finds its frames ready
	if p.scrub {
		p.preview.Near(p.scrubTo)
	} else {
		p.preview.Near(p.pos)
	}
	// a held run shows its frame, or the placeholder while none is ready;
	// not while the stall's dots are up, nor without room above the panel
	// in the overlay region
	up := p.pvOn && p.wait == nil && (previewLift+p.osdHeight())*p.canvasWidth()*4 <= ring.RegionSize
	var img *gfx.Image
	if up {
		img = p.preview.Frame(p.scrubTo)
	}
	was := p.pvShown()
	if img != p.pvImg {
		p.pvImg = img
		p.pvGen++
		p.dirty = true
	}
	if ph := up && img == nil; ph && p.pvDot == nil {
		p.pvDot = newWaitDot("", now)
		p.pvGen++
		p.dirty = true
	} else if !ph && p.pvDot != nil {
		p.pvDot = nil
		p.pvGen++
		p.dirty = true
	}
	if p.pvDot != nil {
		// the dots swell from the clock: each new frame of them repaints
		if f := p.pvDot.frameAt(now); f != p.pvDot.frame {
			p.pvDot.frame = f
			p.pvGen++
			p.dirty = true
		}
	}
	if was && !p.pvShown() {
		// the overlay page keeps what is not drawn over: the next two
		// panels (one for each page) still take the rows, clear
		p.pvClear = 2
	}
}

// pvShown reports whether a frame or the placeholder is up.
func (p *Playing) pvShown() bool {
	return p.pvImg != nil || p.pvDot != nil
}

// shownLift notes a panel shown with lift rows above it: once the frame
// is gone, each one so shown is a page the rows are clear on.
func (p *Playing) shownLift(lift int) {
	if lift > 0 && !p.pvShown() && p.pvClear > 0 {
		p.pvClear--
	}
}

// endPreview takes the preview down and resumes a playback the scrub
// paused; a pause of the user's own stays. The gesture's seek follows it.
func (p *Playing) endPreview(now time.Time) {
	p.pvOn = false
	if p.pvPaused {
		p.pvPaused = false
		p.paused, p.pausedAt = false, now
		p.send("resume")
		p.dirty = true
	}
}

// lift is the rows above the panel this compose takes for the preview:
// while a frame or the placeholder shows, and for the panels that clear them after it.
func (p *Playing) lift() int {
	if !p.pvShown() && p.pvClear == 0 {
		return 0
	}
	return previewLift
}

// previewKey tells the overlay's keys apart while a frame or the
// placeholder shows (pvGen counts the dots' frames too) or its
// rows are being cleared.
func (p *Playing) previewKey() string {
	if !p.pvShown() && p.pvClear == 0 {
		return ""
	}
	return "|pv" + itoa(p.pvGen) + "." + itoa(p.pvClear)
}

// drawPreview paints the frame into the lift rows above the panel: clear
// but for the frame, opaque and borderless, over the dot's place, or the
// placeholder in its place while no frame is ready. The rows are cleared
// whole every time, pixels and alpha: the page is written as it is given,
// and an earlier frame or strip left in them would stay there.
func (p *Playing) drawPreview(lift int) {
	w := p.canvas.W
	c := &gfx.Canvas{W: w, H: lift, Pix: p.canvas.Pix[:w*lift*4]}
	alpha := p.alpha[:w*lift]
	clear(c.Pix)
	clear(alpha)
	img := p.pvImg
	if img == nil && p.pvDot == nil || p.dur <= 0 {
		return
	}
	fw, fh := previewSize(p.canvasWidth(), p.canvasHeight())
	if img != nil {
		fw, fh = img.W, img.H
	}
	dotX := p.safeX() + int(float64(p.safeW())*p.scrubTo/p.dur+0.5)
	x, y := previewX(dotX, fw, p.safeX(), p.safeW()), lift-PreviewGap-fh
	if img == nil {
		p.drawPlaceholder(c, alpha, x, y, fw, fh)
		return
	}
	c.Blit(x, y, img)
	for r := max(0, y); r < min(lift, y+fh); r++ {
		row := alpha[r*w : (r+1)*w]
		for i := max(0, x); i < min(w, x+fw); i++ {
			row[i] = 255
		}
	}
}

// drawPlaceholder paints the box a frame on its way stands in for: black
// at the panel's alpha, the wait dots at their frame in its middle, each
// dot's edge blended into the box (the dots' coverage over the box's).
func (p *Playing) drawPlaceholder(c *gfx.Canvas, alpha []byte, x, y, fw, fh int) {
	w := c.W
	if len(p.pvDotAlpha) != len(alpha) {
		p.pvDotAlpha = make([]byte, len(alpha))
	}
	cov := p.pvDotAlpha
	clear(cov)
	p.pvDot.draw(c, cov, x+fw/2, y+fh/2, p.pvDot.frame)
	for r := max(0, y); r < min(c.H, y+fh); r++ {
		for i := max(0, x); i < min(w, x+fw); i++ {
			k := r*w + i
			a := int(cov[k])
			out := OsdAlpha + a*(255-OsdAlpha)/255
			alpha[k] = byte(out)
			// straight alpha: the dot's colour at its coverage over black
			px := c.Pix[k*4 : k*4+3]
			for j := range px {
				px[j] = byte(int(px[j]) * a / out)
			}
		}
	}
}

// previewNice is the nice a preview worker decodes at: normal priority
// while a held run waits on it or while it prepares the first frames round
// the start (boot), else nice 10 as the art workers do.
func previewNice(running, boot bool) int {
	if running || boot {
		return 0
	}
	return 10
}

// workerPrio is a preview worker thread's priority. The worker sets it
// between decodes; Near raises it from the UI thread the moment a run
// starts, so a decode already under way speeds up too (on Linux a
// priority is per thread, set by its id).
type workerPrio struct {
	tid  int // the worker's thread, 0 before it starts
	nice int
	set  func(tid, nice int) // syscall.Setpriority on the thread; tests replace it
}

func newWorkerPrio() workerPrio {
	return workerPrio{nice: -1, set: func(tid, nice int) { syscall.Setpriority(syscall.PRIO_PROCESS, tid, nice) }}
}

// to sets the worker's nice to n, if it has started and is not at n.
func (w *workerPrio) to(n int) {
	if w.tid != 0 && w.nice != n {
		w.set(w.tid, n)
		w.nice = n
	}
}
