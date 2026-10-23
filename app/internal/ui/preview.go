package ui

import (
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
//   - Frame returns the nearest ready frame to t within a few frames (more
//     during a fast run: the dot moves faster than frames decode) and nil
//     only when none is near.
//   - Its worker runs at nice 10 as the art workers do, but at normal
//     priority while a held run waits on it (the playback is paused
//     then): on the device a decode at nice 10 during a run took ten
//     times as long, and the run outpaced every frame.
//   - It never fetches or decodes on the caller's thread, and a failed
//     fetch or decode is retried a bounded number of times, not forever.
type previewer interface {
	Frame(t float64) *gfx.Image
	Near(t float64)
	Close()
}

// The preview's geometry: frames are PreviewH lines high, with a 1 px
// GreyLo frame and a 1 px black outline round them, and float PreviewGap
// lines above the panel or the strip. previewLift is the rows they take
// above it, even so the panel keeps its field.
const (
	PreviewH    = 90
	PreviewGap  = 8
	previewLift = PreviewH + 4 + PreviewGap
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

// previewX is where the outlined frame (ow wide) goes: centred on the
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
	var img *gfx.Image
	if p.pvOn && p.wait == nil {
		img = p.preview.Frame(p.scrubTo)
	}
	if img != nil && (previewLift+p.osdHeight())*p.canvasWidth()*4 > ring.RegionSize {
		img = nil // no room above the panel in the overlay region
	}
	if img != p.pvImg {
		if img == nil {
			// the overlay page keeps what is not drawn over: the next
			// two panels (one for each page) still take the rows, clear
			p.pvClear = 2
		}
		p.pvImg = img
		p.pvGen++
		p.dirty = true
	}
}

// shownLift notes a panel shown with lift rows above it: once the frame
// is gone, each one so shown is a page the rows are clear on.
func (p *Playing) shownLift(lift int) {
	if lift > 0 && p.pvImg == nil && p.pvClear > 0 {
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
// while a frame shows, and for the panels that clear them after it.
func (p *Playing) lift() int {
	if p.pvImg == nil && p.pvClear == 0 {
		return 0
	}
	return previewLift
}

// previewKey tells the overlay's keys apart while a frame shows or its
// rows are being cleared.
func (p *Playing) previewKey() string {
	if p.pvImg == nil && p.pvClear == 0 {
		return ""
	}
	return "|pv" + itoa(p.pvGen) + "." + itoa(p.pvClear)
}

// drawPreview paints the frame into the lift rows above the panel: clear
// but for the frame, which is opaque, over the dot's place. The rows are
// cleared whole every time, pixels and alpha: the page is written as it
// is given, and an earlier frame or strip left in them would stay there.
func (p *Playing) drawPreview(lift int) {
	w := p.canvas.W
	c := &gfx.Canvas{W: w, H: lift, Pix: p.canvas.Pix[:w*lift*4]}
	alpha := p.alpha[:w*lift]
	clear(c.Pix)
	clear(alpha)
	img := p.pvImg
	if img == nil || p.dur <= 0 {
		return
	}
	ow, oh := img.W+4, img.H+4
	dotX := p.safeX() + int(float64(p.safeW())*p.scrubTo/p.dur+0.5)
	x, y := previewX(dotX, ow, p.safeX(), p.safeW()), lift-PreviewGap-oh
	c.Fill(x, y, ow, oh, gfx.Black)
	c.Frame(x+1, y+1, ow-2, oh-2, 1, gfx.GreyLo)
	c.Blit(x+2, y+2, img)
	for r := max(0, y); r < min(lift, y+oh); r++ {
		row := alpha[r*w : (r+1)*w]
		for i := max(0, x); i < min(w, x+ow); i++ {
			row[i] = 255
		}
	}
}
