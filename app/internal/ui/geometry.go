package ui

import (
	"fmt"
	"math"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
)

// Geometry is where video goes on the 720x480 raster, set on the calibration
// screen for sets that hide the picture's edges or draw it too wide or too
// narrow: each edge moved in from the raster's by an even number of pixels
// (left, right) or lines (top, bottom), and the picture's width in thousandths
// of the nominal 4:3 width (0 is 1000). Menus ignore it; a supporting worker
// computes picture and clipping rectangles for the core's scaler.
type Geometry struct {
	Left   int `json:"left"`
	Top    int `json:"top"`
	Right  int `json:"right"`
	Bottom int `json:"bottom"`
	Width  int `json:"width,omitempty"`
}

// The limits the playback geometry helper accepts.
const (
	GeometryMaxX     = 720 / 6
	GeometryMaxY     = 480 / 6
	GeometryWidthMin = 850
	GeometryWidthMax = 1150
	geometryStep     = 2 // pixels or lines: chroma rows and columns come in pairs, scanlines too
)

// Normal is g within the presenter's limits, edges even, width filled in.
func (g Geometry) Normal() Geometry {
	edge := func(v, hi int) int { return max(0, min(hi, v)) &^ 1 }
	g.Left, g.Right = edge(g.Left, GeometryMaxX), edge(g.Right, GeometryMaxX)
	g.Top, g.Bottom = edge(g.Top, GeometryMaxY), edge(g.Bottom, GeometryMaxY)
	if g.Width == 0 {
		g.Width = 1000
	}
	g.Width = max(GeometryWidthMin, min(GeometryWidthMax, g.Width))
	return g
}

// Env is the worker's --geometry argument.
func (g Geometry) Env() string {
	g = g.Normal()
	return fmt.Sprintf("%d,%d,%d,%d,%d", g.Left, g.Top, g.Right, g.Bottom, g.Width)
}

// Fit is where the presenter puts a frame of display aspect `aspect` and
// `lines` lines. Without calibration, exactly where it went before
// calibration existed; with it, the same shape, as large as fits the picture
// area at the calibrated width, centred. It must match fit() in
// arm/video_geometry.h operation for operation (both are tested against
// tools/testdata/fit_cases.txt), so the float sums use variables: Go folds
// constant arithmetic exactly, C rounds each step.
func (g Geometry) Fit(aspect float64, lines int) (x, y, w, h int) {
	g = g.Normal()
	fourThree, rw, rh := 4.0/3, 720.0, 480.0
	// on the whole 4:3 raster, as before calibration existed
	w, h = 720, 480
	if aspect > fourThree {
		h = 2 * int(math.Round(rh*fourThree/aspect/2))
	} else {
		w = 2 * int(math.Round(rw*aspect/fourThree/2))
	}
	w, h = max(w, 16), max(h, 16)
	if w >= 720-720/60 {
		w = 720 // near 4:3: no slivers of border
	}
	if lines&1 == 0 && lines <= 480 && abs(h-lines) <= 480/50 {
		h = lines // within 2% of its own line count: lines 1:1
	}
	// calibrated: that shape, its width scaled by the correction, as large
	// as fits the picture area
	aw, ah := 720-g.Left-g.Right, 480-g.Top-g.Bottom
	if aw != 720 || ah != 480 || g.Width != 1000 {
		k := float64(g.Width) / 1000
		nw, nh := aw, ah
		if float64(w)*float64(ah)*k > float64(aw)*float64(h) {
			nh = 2 * int(math.Round(float64(aw)*float64(h)/(float64(w)*k)/2))
		} else {
			nw = 2 * int(math.Round(float64(w)*float64(ah)*k/float64(h)/2))
		}
		w, h = nw, nh
		if aw-nw <= 2 {
			w = aw // a rounding step short: fill
		}
		if ah-nh <= 2 {
			h = ah
		}
		w, h = max(w, 16), max(h, 16)
	}
	return g.Left + ((aw-w)/2)&^1, g.Top + ((ah-h)/2)&^1, w, h
}

// squareWidth is the per-mille width that makes a sqW x sqH raster box a
// square on the set: nominally a pixel is 8/9 of a line wide.
func squareWidth(sqW, sqH int) int {
	return int(math.Round(1000 * 8 * float64(sqW) / (9 * float64(sqH))))
}

// geometryX maps the persistent 720-pixel calibration coordinates into the
// app's current logical canvas. A 960-wide canvas is the same display width
// represented by 720 anamorphic raster pixels.
func geometryX(x, canvasW int) int {
	return int(math.Round(float64(x) * float64(canvasW) / 720))
}

// VideoGeometry is read at each playback start on supporting cores.
func (a *App) VideoGeometry() string { return a.Cfg.Geometry.Env() }

func (a *App) calibrationLabel() string {
	if a.Player != nil && a.Player.Geometry != nil {
		return "Video calibration"
	}
	return "Video calibration (preview only)"
}

// The core leaves the first 12 and the last 8 pixels of every line black in
// 480i and 240p (the PlexCRT core did; unverified on the H.264 core), so an
// edge placed inside them could not be seen. The calibration shows the left and right
// edges past them, and an edge the user moves is saved past its end. An edge
// left alone keeps its saved value: the geometry is shared with 480p, and a
// picture area that reaches into the ends only loses what the core blanks.
const (
	LineEndLeft  = 12
	LineEndRight = 8
)

// lineEnds is how far in the calibration keeps the left and right edges: the
// blanked line ends, except in 480p (a preference older versions saved),
// which keeps every pixel.
func (a *App) lineEnds() (left, right int) {
	if a.Cfg.Progressive {
		return 0, 0
	}
	return LineEndLeft, LineEndRight
}

// Calibrate is the video geometry screen: the picture area's edges, and a
// square with a circle in it that a ruler can check. OK steps through the
// four edges and the square's top-right corner, the d-pad moves the one
// selected, Back saves and leaves.
type Calibrate struct {
	app        *App
	g          Geometry
	sel        int
	sqW, sqH   int // the square, in pixels and lines
	sqW0, sqH0 int // its size on opening: the bottom-left corner stays put
	width0     int // the saved width, which that size only approximates
	endL, endR int // the blanked line ends the left and right edges stay past
}

const (
	calTop = iota
	calRight
	calBottom
	calLeft
	calCorner
	calSteps
)

var calNames = [calSteps]string{"Top edge", "Right edge", "Bottom edge", "Left edge", "Aspect ratio"}

// calFill is the picture area: dark, so the lines and text stand out.
const calFill gfx.Color = 0x1C2230

// NewCalibrate opens the calibration with the saved geometry.
func NewCalibrate(a *App) *Calibrate {
	s := &Calibrate{app: a, g: a.Cfg.Geometry.Normal()}
	s.endL, s.endR = a.lineEnds()
	// Leave room below the shape for reassurance, measuring help and controls.
	// Its width still follows the saved correction, including on reopening.
	s.sqH = min(240, (480-s.g.Top-s.g.Bottom-100)&^1)
	s.sqW = 2 * int(math.Round(float64(s.sqH)*9/8*float64(s.g.Width)/1000/2))
	s.sqW0, s.sqH0, s.width0 = s.sqW, s.sqH, s.g.Width
	return s
}

// Back saves the geometry and leaves; there is no cancel.
func (s *Calibrate) Back() bool {
	cfg := s.app.Cfg
	before := *cfg
	cfg.Geometry = s.g.Normal()
	if err := cfg.Save(); err != nil {
		s.app.Log.Printf("config: %v", err)
		*cfg = before
		s.app.Notice, s.app.NoticeAt = "Could not save settings. Check free space and retry.", time.Now()
	}
	s.app.Pop()
	return true
}

// Key: OK selects the next edge or the corner; the d-pad moves it. An edge
// moves the way it is pushed, out toward the raster's edge or in toward the
// middle; the corner moves the way it is pushed, and the picture's width
// follows the square's shape.
func (s *Calibrate) Key(ev input.Event, now time.Time) {
	if ev.Release {
		return
	}
	if ev.Key == input.Enter {
		if !ev.Repeat {
			s.sel = (s.sel + 1) % calSteps
		}
		return
	}
	dx := map[input.Key]int{input.Right: 1, input.Left: -1}[ev.Key] * geometryStep
	dy := map[input.Key]int{input.Down: 1, input.Up: -1}[ev.Key] * geometryStep
	if dx == 0 && dy == 0 {
		return // L, R and the like: nothing to move
	}
	g := &s.g
	switch s.sel {
	case calTop:
		g.Top += dy
	case calBottom:
		g.Bottom -= dy
	case calLeft:
		g.Left = max(g.Left, s.endL) + dx
	case calRight:
		g.Right = max(g.Right, s.endR) - dx
	case calCorner:
		// the corner stays near where it started, which spans the whole
		// width range (15% of the square is 49 pixels or 43 lines) but
		// keeps the square on the screen when both sides grow
		w, h := s.sqW+dx, s.sqH-dy
		if w < s.sqW0-72 || w > s.sqW0+72 || h < s.sqH0-64 || h > s.sqH0+64 {
			return
		}
		switch width := squareWidth(w, h); {
		case w == s.sqW0 && h == s.sqH0:
			// back where it started: exactly what was saved, which the
			// rounded square may put a hair outside the limits
			s.sqW, s.sqH, g.Width = w, h, s.width0
		case width >= GeometryWidthMin && width <= GeometryWidthMax:
			s.sqW, s.sqH, g.Width = w, h, width
		}
	}
	*g = g.Normal()
	switch s.sel { // a moved edge stays past its blanked line end
	case calLeft:
		g.Left = max(g.Left, s.endL)
	case calRight:
		g.Right = max(g.Right, s.endR)
	}
}

// pastEnds is g as the screen shows it: left and right edges out of the
// blanked line ends.
func (s *Calibrate) pastEnds(g Geometry) Geometry {
	g.Left, g.Right = max(g.Left, s.endL), max(g.Right, s.endR)
	return g
}

// Draw paints the pattern: black outside the picture area, the area's edges
// as lines (the selected one amber), where a 4:3 picture lands filled, and the
// square and circle on the aspect-ratio step. Instructions stay central,
// where overscan cannot hide them.
func (s *Calibrate) Draw(c *gfx.Canvas, now time.Time) bool {
	// the picture where playback puts it; the edges and square past
	// the blanked line ends
	px, py, pw, ph := s.g.Normal().Fit(4.0/3, 480)
	g := s.pastEnds(s.g.Normal())
	f := s.app.F
	c.Fill(0, 0, c.W, c.H, gfx.Black)
	pxOnCanvas, pwOnCanvas := geometryX(px, c.W), geometryX(px+pw, c.W)-geometryX(px, c.W)
	c.Fill(pxOnCanvas, py, pwOnCanvas, ph, calFill)

	// the picture area's edges: 2 lines across (1 flickers at 480i), 4
	// pixels down (thinner verticals wash out through composite)
	ax, ay := geometryX(g.Left, c.W), g.Top
	aright := geometryX(720-g.Right, c.W)
	aw, ah := aright-ax, 480-g.Top-g.Bottom
	col := func(sel int) gfx.Color {
		if s.sel == sel {
			return gfx.Amber
		}
		return gfx.GreyLo
	}
	c.Fill(ax, ay, aw, 2, col(calTop))
	c.Fill(ax, ay+ah-2, aw, 2, col(calBottom))
	c.Fill(ax, ay, 4, ah, col(calLeft))
	c.Fill(ax+aw-4, ay, 4, ah, col(calRight))
	// Arrows stay near the selected edge, but far enough in to remain visible
	// when the line has just disappeared beyond the screen.
	mx, my := ax+aw/2, ay+ah/2
	switch s.sel {
	case calTop:
		chevron(c, mx, ay+32, true, gfx.Amber)
		chevron(c, mx, ay+44, false, gfx.Amber)
	case calBottom:
		chevron(c, mx, ay+ah-50, true, gfx.Amber)
		chevron(c, mx, ay+ah-38, false, gfx.Amber)
	case calLeft:
		chevronLeft(c, ax+40, my-6, gfx.Amber)
		chevronRight(c, ax+56, my-6, gfx.Amber)
	case calRight:
		chevronLeft(c, ax+aw-56, my-6, gfx.Amber)
		chevronRight(c, ax+aw-40, my-6, gfx.Amber)
	}

	if s.sel != calCorner {
		// Edge instructions do not need a shape to measure. Keep the text
		// independent of the moving edges, with room for the complete wording.
		cx := c.W / 2
		s.app.textCenterOn(c, cx, 130, f.Title, gfx.Amber, calFill,
			fmt.Sprintf("%s (%d of %d)", calNames[s.sel], s.sel+1, calSteps))
		in := [...]string{"DOWN", "LEFT", "UP", "RIGHT"}[s.sel]
		out := [...]string{"UP", "RIGHT", "DOWN", "LEFT"}[s.sel]
		edge := [...]string{"top", "right", "bottom", "left"}[s.sel]
		lines := []string{
			"Press " + in + " until you see the line,",
			"then press " + out + " until it's disappeared",
			"beyond the screen's " + edge + " edge.",
			"Stop there.",
		}
		for i, line := range lines {
			s.app.textCenterOn(c, cx, 176+i*26, f.Body, gfx.GreyHi, calFill, line)
		}
		s.app.textCenterOn(c, cx, 298, f.Body, gfx.GreyHi, calFill, "If the line can't be hidden, move it")
		s.app.textCenterOn(c, cx, 324, f.Body, gfx.GreyHi, calFill, "as close to the edge as it'll go.")
		s.app.textCenterOn(c, cx, 376, f.SmallBold, gfx.GreyLo, calFill, "OK: next   Back: save and exit")
		return false
	}

	sx, sy, bottom := s.square(g)
	sqDrawW := s.sqW // 9:8 compensates for the display's 8:9 horizontal pixel aspect
	squareCenterX := geometryX(sx+s.sqW/2, c.W)
	sx = squareCenterX - sqDrawW/2
	sq := gfx.Amber
	c.Fill(sx, sy, sqDrawW, 2, sq)
	c.Fill(sx, bottom-2, sqDrawW, 2, sq)
	c.Fill(sx, sy, 4, s.sqH, sq)
	c.Fill(sx+sqDrawW-4, sy, 4, s.sqH, sq)
	cx, cy := sx+sqDrawW/2, sy+s.sqH/2
	inside := drawEllipse(c, cx, cy, sqDrawW/2, s.sqH/2, 4, 3, sq)
	cornerArrow(c, sx+sqDrawW, sy, gfx.Amber)

	// Shape is the target; the correction percentage is not a score.
	title, body := f.Title, f.Body
	lines := []string{"Make the square", "as wide as it is tall.", "The circle should", "look round."}
	step := fmt.Sprintf("%d of %d", s.sel+1, calSteps)
	if sqDrawW < 240 || s.sqH < 220 {
		title, body = f.SmallBold, f.SmallBold
	}
	if sqDrawW < 210 || s.sqH < 200 {
		// At the smallest sizes, keep the same visual targets in short form
		// so the heading and guidance still fit inside the circle.
		lines = []string{"Equal sides", "Round circle"}
	}
	ty := cy - (title.Height()+2+f.SmallBold.Height()+4+len(lines)*body.Height())/2
	s.centre(c, cx, ty, title, gfx.Amber, calNames[s.sel], inside)
	ty += title.Height() + 2
	s.centre(c, cx, ty, f.SmallBold, gfx.Amber, step, inside)
	ty += f.SmallBold.Height() + 4
	for _, line := range lines {
		s.centre(c, cx, ty, body, gfx.GreyHi, line, inside)
		ty += body.Height()
	}
	by := bottom + 6
	for _, line := range []string{
		"If it already does, leave it as it is.",
		"Use a ruler or tape measure if needed.",
		"OK: next   Back: save and exit",
	} {
		s.app.textCenterOn(c, mx, by, f.SmallBold, gfx.GreyHi, calFill, line)
		by += f.SmallBold.Height()
	}
	return false
}

// square is where the square goes: it grows and shrinks from its bottom-left
// corner, which starts it centred in the picture area, unless that would put
// its top or the corner's arrow off the screen.
func (s *Calibrate) square(g Geometry) (x, top, bottom int) {
	mx, my := g.Left+(720-g.Left-g.Right)/2, g.Top+(480-g.Top-g.Bottom)/2
	bottom = max(min((my+s.sqH0/2)&^1, 360, 480-g.Bottom-74), s.sqH+cornerArrowH+4)
	x = min(mx-s.sqW0/2, 720-8-s.sqW-cornerArrowW)
	return x, bottom - s.sqH, bottom
}

// centre draws one line centred on cx, cut to the circle's inside at that height.
func (s *Calibrate) centre(c *gfx.Canvas, cx, y int, f *gfx.Font, col gfx.Color, text string, inside func(y0, y1 int) int) {
	s.app.textCenterOn(c, cx, y, f, col, calFill, f.Fit(text, inside(y, y+f.Height())-8))
}

// cornerArrowW and cornerArrowH are how far cornerArrow reaches right of
// the corner and above it.
const cornerArrowW, cornerArrowH = 30, 24

// cornerArrow shows horizontal and vertical movement near the top-right
// corner, with a gap from the square so neither pair looks like a target.
func cornerArrow(c *gfx.Canvas, x, y int, col gfx.Color) {
	chevronLeft(c, x-30, y-24, col)
	chevronRight(c, x-12, y-24, col)
	chevron(c, x+24, y+10, true, col)
	chevron(c, x+24, y+26, false, col)
}

// drawEllipse strokes the ellipse centred on cx, cy with radii rx, ry, the
// stroke tx pixels wide at the sides and ty lines at the top and bottom. It
// returns the width inside the stroke over a band of rows.
func drawEllipse(c *gfx.Canvas, cx, cy, rx, ry, tx, ty int, col gfx.Color) func(y0, y1 int) int {
	half := func(r, rr int, dy float64) int {
		v := 1 - dy*dy/float64(rr*rr)
		if v <= 0 {
			return -1
		}
		return int(math.Round(float64(r) * math.Sqrt(v)))
	}
	irx, iry := rx-tx, ry-ty
	for yy := cy - ry; yy < cy+ry; yy++ {
		dy := float64(yy) + 0.5 - float64(cy)
		xo := half(rx, ry, dy)
		if xo < 0 {
			continue
		}
		xi := half(irx, iry, dy)
		if xi < 0 {
			c.Fill(cx-xo, yy, 2*xo, 1, col)
			continue
		}
		c.Fill(cx-xo, yy, xo-xi, 1, col)
		c.Fill(cx+xi, yy, xo-xi, 1, col)
	}
	return func(y0, y1 int) int {
		w := 2 * irx
		for yy := y0; yy < y1; yy++ {
			w = min(w, 2*half(irx, iry, float64(yy)+0.5-float64(cy)))
		}
		return max(w, 0)
	}
}
