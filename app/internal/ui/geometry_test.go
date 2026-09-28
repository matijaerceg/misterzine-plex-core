package ui

import (
	"bufio"
	"image"
	"image/color"
	"image/png"
	"io"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
)

// The presenter's own test (tools/plexfb_scale_test.c) reads the same table,
// so the calibration pattern and the played picture land in the same place.
func TestGeometryFitMatchesPresenterCases(t *testing.T) {
	f, err := os.Open(filepath.Join("..", "..", "..", "tools", "testdata", "fit_cases.txt"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	n := 0
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line, _, _ := strings.Cut(sc.Text(), "#")
		fields := strings.Fields(line)
		if len(fields) != 11 {
			continue
		}
		v := make([]int, 0, 10)
		var num, den float64
		for i, s := range fields {
			if i == 5 {
				a, b, _ := strings.Cut(s, "/")
				num, _ = strconv.ParseFloat(a, 64)
				den, _ = strconv.ParseFloat(b, 64)
				continue
			}
			x, err := strconv.Atoi(s)
			if err != nil {
				t.Fatalf("bad case %q", sc.Text())
			}
			v = append(v, x)
		}
		g := Geometry{Left: v[0], Top: v[1], Right: v[2], Bottom: v[3], Width: v[4]}
		if g.Normal() != g {
			t.Errorf("%q: case outside the limits", sc.Text())
		}
		x, y, w, h := g.Fit(num/den, v[5])
		if x != v[6] || y != v[7] || w != v[8] || h != v[9] {
			t.Errorf("%q: got %d %d %d %d", sc.Text(), x, y, w, h)
		}
		n++
	}
	if n < 30 {
		t.Fatalf("only %d cases read", n)
	}
}

func TestGeometryLimitsAndEnv(t *testing.T) {
	if got := (Geometry{}).Env(); got != "0,0,0,0,1000" {
		t.Fatalf("zero geometry sent as %q", got)
	}
	g := Geometry{Left: -4, Top: 81, Right: 121, Bottom: 7, Width: 2000}.Normal()
	if g != (Geometry{Left: 0, Top: 80, Right: 120, Bottom: 6, Width: GeometryWidthMax}) {
		t.Fatalf("normalised to %+v", g)
	}
	if got := (Geometry{Width: 10}).Normal().Width; got != GeometryWidthMin {
		t.Fatalf("width 10 normalised to %d", got)
	}
}

func calibrateApp(t *testing.T) (*App, *Calibrate) {
	t.Helper()
	a := New(nil, nil, nil, log.New(io.Discard, "", 0))
	a.Cfg = LoadConfig(filepath.Join(t.TempDir(), "settings.json"))
	a.Push(NewOptions(a))
	s := NewCalibrate(a)
	a.Push(s)
	return a, s
}

func press(s *Calibrate, keys ...input.Key) {
	for _, k := range keys {
		s.Key(input.Event{Key: k}, time.Now())
	}
}

func TestCalibrateMovesEachEdgeTheWayItIsPushed(t *testing.T) {
	a, _ := calibrateApp(t)
	a.Cfg.Progressive = true // 480p: no blanked line ends to stay past
	s := NewCalibrate(a)
	press(s, input.Down, input.Down, input.Down, input.Up)                  // top: in 3, out 1
	press(s, input.Enter, input.Left, input.Left, input.Up)                 // right: in 2; up does nothing
	press(s, input.Enter, input.Up, input.Up, input.Up)                     // bottom: in 3
	press(s, input.Enter, input.Right, input.Left, input.Left, input.Right) // left: past the raster's edge and back in
	want := Geometry{Top: 4, Right: 4, Bottom: 6, Left: 2, Width: 1000}
	if s.g != want {
		t.Fatalf("got %+v, want %+v", s.g, want)
	}
	// out past the raster's edge stops at it
	press(s, input.Enter, input.Enter, input.Up, input.Up, input.Up)
	if s.g.Top != 0 || s.sel != calTop {
		t.Fatalf("top pushed past the raster: %+v, selected %d", s.g, s.sel)
	}
}

func TestCalibrateKeepsLeftAndRightEdgesPastTheBlankedLineEnds(t *testing.T) {
	a, s := calibrateApp(t) // 480i: the core blanks the line ends
	if s.g.Left != LineEndLeft || s.g.Right != LineEndRight || s.g.Top != 0 {
		t.Fatalf("opened at %+v", s.g)
	}
	press(s, input.Enter, input.Right, input.Right, input.Left) // right: out stops at the end, then in 2
	press(s, input.Enter, input.Enter, input.Left, input.Right) // left: out stops at the end, then in 2
	if s.g.Right != LineEndRight+2 || s.g.Left != LineEndLeft+2 {
		t.Fatalf("edges at %+v", s.g)
	}
	// an area saved further in opens as it was
	a.Cfg.Geometry = Geometry{Left: 30, Right: 20, Width: 1000}
	if g := NewCalibrate(a).g; g.Left != 30 || g.Right != 20 {
		t.Fatalf("saved 30/20 opened at %+v", g)
	}
	// 480p keeps every pixel
	a.Cfg.Geometry, a.Cfg.Progressive = Geometry{}, true
	if g := NewCalibrate(a).g; g.Left != 0 || g.Right != 0 {
		t.Fatalf("480p opened at %+v", g)
	}
}

func TestCalibrateCornerSetsTheWidthFromTheSquare(t *testing.T) {
	_, s := calibrateApp(t)
	for s.sel != calCorner {
		press(s, input.Enter)
	}
	w0, h0 := s.sqW, s.sqH
	if squareWidth(w0, h0) != 1000 {
		t.Fatalf("opening square %dx%d is not square at the nominal width", w0, h0)
	}
	press(s, input.Right, input.Right, input.Right)
	if s.sqW != w0+6 || s.sqH != h0 || s.g.Width <= 1000 {
		t.Fatalf("right: square %dx%d, width %d", s.sqW, s.sqH, s.g.Width)
	}
	press(s, input.Up, input.Up, input.Up)
	if s.sqH != h0+6 || s.g.Width != squareWidth(w0+6, h0+6) {
		t.Fatalf("up: square %dx%d, width %d", s.sqW, s.sqH, s.g.Width)
	}
	// a square narrower than the limit allows stops there
	for i := 0; i < 200; i++ {
		press(s, input.Left)
	}
	if s.g.Width < GeometryWidthMin || squareWidth(s.sqW-2, s.sqH) >= GeometryWidthMin {
		t.Fatalf("left stopped at width %d, square %dx%d", s.g.Width, s.sqW, s.sqH)
	}
	// growing both sides keeps the shape but must not run off the screen
	for i := 0; i < 200; i++ {
		press(s, input.Right, input.Up)
	}
	if s.sqW > w0+72 || s.sqH > h0+64 || (480-s.sqH0)/2-(s.sqH-s.sqH0) < 16 {
		t.Fatalf("square grew to %dx%d from %dx%d", s.sqW, s.sqH, w0, h0)
	}
}

func TestCalibrateSquareStaysOnScreen(t *testing.T) {
	a, _ := calibrateApp(t)
	for _, g := range []Geometry{{Bottom: 80, Width: 1150}, {Top: 80, Width: 850}, {Left: 120, Width: 1150}, {Right: 120, Bottom: 80, Width: 1150}} {
		a.Cfg.Geometry = g
		s := NewCalibrate(a)
		s.sel = calCorner
		for i := 0; i < 60; i++ {
			press(s, input.Up, input.Right)
		}
		x, top, bottom := s.square(s.g)
		if top-cornerArrowH < 0 || x < 0 || x+s.sqW+cornerArrowW > 720 || bottom > 480 {
			t.Errorf("%+v: %dx%d square at x %d, lines %d..%d", g, s.sqW, s.sqH, x, top, bottom)
		}
	}
}

func TestCalibrateOnlyTheDpadChangesTheWidth(t *testing.T) {
	a, _ := calibrateApp(t)
	a.Cfg.Geometry = Geometry{Top: 80, Bottom: 80, Width: 1000}
	s := NewCalibrate(a)
	s.sel = calCorner
	if squareWidth(s.sqW, s.sqH) == 1000 {
		t.Fatal("pick a geometry whose opening square only approximates the width")
	}
	press(s, input.JumpFwd, input.JumpBack)
	if s.g.Width != 1000 {
		t.Fatalf("L and R changed the width to %d", s.g.Width)
	}
	press(s, input.Right, input.Left, input.Up, input.Down)
	if s.g.Width != 1000 {
		t.Fatalf("back at the opening square, width %d", s.g.Width)
	}
	// at the narrowest width the rounded opening square is a hair past the
	// limit; coming back to it still restores the saved width
	a.Cfg.Geometry = Geometry{Top: 80, Bottom: 80, Width: GeometryWidthMin}
	s = NewCalibrate(a)
	s.sel = calCorner
	if squareWidth(s.sqW, s.sqH) >= GeometryWidthMin {
		t.Fatal("pick a geometry whose opening square rounds below the limit")
	}
	press(s, input.Right, input.Left)
	if s.g.Width != GeometryWidthMin || s.sqW != s.sqW0 {
		t.Fatalf("back at the opening square, width %d, square %d wide (opened %d)", s.g.Width, s.sqW, s.sqW0)
	}
}

func TestCalibrateBackSavesAndLeaves(t *testing.T) {
	a, s := calibrateApp(t)
	press(s, input.Down, input.Down)
	for s.sel != calCorner {
		press(s, input.Enter)
	}
	press(s, input.Right, input.Right)
	a.key(input.Event{Key: input.Back}, time.Now())
	if _, ok := a.top().(*Options); !ok {
		t.Fatalf("Back left %T on top", a.top())
	}
	saved := LoadConfig(a.Cfg.path).Geometry
	if saved != s.g || saved.Top != 4 || saved.Width == 1000 {
		t.Fatalf("saved %+v, screen had %+v", saved, s.g)
	}
	if a.VideoGeometry() != saved.Env() {
		t.Fatalf("player gets %q", a.VideoGeometry())
	}
	// reopening shows the saved square shape
	again := NewCalibrate(a)
	if d := squareWidth(again.sqW, again.sqH) - saved.Width; d < -4 || d > 4 {
		t.Fatalf("reopened square %dx%d is width %d, saved %d", again.sqW, again.sqH, squareWidth(again.sqW, again.sqH), saved.Width)
	}
}

// Optional previews of the pattern: GEOMETRY_PREVIEW_DIR=dir go test -run Preview
func TestCalibratePreview(t *testing.T) {
	dir := os.Getenv("GEOMETRY_PREVIEW_DIR")
	if dir == "" {
		t.Skip("set GEOMETRY_PREVIEW_DIR to render previews")
	}
	if err := os.MkdirAll(dir, 0755); err != nil {
		t.Fatal(err)
	}
	_, s := calibrateApp(t)
	shots := []struct {
		name string
		g    Geometry
		sel  int
	}{
		{"top", Geometry{}, calTop},
		{"left-set", Geometry{Left: 18, Top: 12, Right: 14, Bottom: 10}, calLeft},
		{"corner", Geometry{Left: 18, Top: 12, Right: 14, Bottom: 10}, calCorner},
		{"limits", Geometry{Left: 120, Top: 80, Right: 120, Bottom: 80}, calBottom},
	}
	for _, shot := range shots {
		s.app.Cfg.Geometry = shot.g
		*s = *NewCalibrate(s.app)
		s.sel = shot.sel
		if shot.sel == calCorner {
			press(s, input.Right, input.Right, input.Up)
		}
		c := gfx.NewCanvas(720, 480)
		for i := 0; i < 15; i++ {
			s.Draw(c, time.Now())
			time.Sleep(20 * time.Millisecond)
		}
		// 720 source pixels occupy a 640-wide 4:3 display.
		out := image.NewRGBA(image.Rect(0, 0, 640, 480))
		for y := 0; y < 480; y++ {
			for x := 0; x < 640; x++ {
				p := (y*720 + x*720/640) * 4
				out.SetRGBA(x, y, color.RGBA{c.Pix[p+2], c.Pix[p+1], c.Pix[p], 255})
			}
		}
		file, err := os.Create(filepath.Join(dir, "geometry-"+shot.name+".png"))
		if err != nil {
			t.Fatal(err)
		}
		err = png.Encode(file, out)
		file.Close()
		if err != nil {
			t.Fatal(err)
		}
	}
}
