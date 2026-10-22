package ui

import (
	"testing"

	"plexcrt/internal/gfx"
	"plexcrt/internal/plex"
)

func TestPlayingControlsUseWideCanvasWithoutScalingFonts(t *testing.T) {
	f := &wideFakeOut{&fakeOut{c: gfx.NewCanvas(720, 480)}}
	a := betaTestApp(t)
	a.Out = f
	a.osd = &painterTestOSD{}
	p := NewPlaying(a, &plex.Item{Title: "A film", Duration: 120}, nil, 0, func(string) {})
	defer func() { <-p.closePainter(a.osd) }()

	if p.canvas.W != 960 || p.canvas.H != 480 {
		t.Fatalf("wide design canvas is %dx%d", p.canvas.W, p.canvas.H)
	}
	p.compose(false)
	if p.safeX() != SafeX || p.safeW() != 848 {
		t.Fatalf("wide safe area is %d+%d", p.safeX(), p.safeW())
	}
	left, right := p.btnX[0], p.btnX[len(p.btnX)-1]+p.btnW[len(p.btnW)-1]
	if left >= right || left < p.safeX() || right > p.safeX()+p.safeW() {
		t.Fatalf("button row bounds %d..%d exceed wide safe area %d..%d", left, right, p.safeX(), p.safeX()+p.safeW())
	}
}

func TestPlayingPanelBackgroundReachesRasterBottom(t *testing.T) {
	app := betaTestApp(t)
	app.Out = &mutableCanvasOut{fakeOut: &fakeOut{c: gfx.NewCanvas(720, 480)}, w: 720, h: 576}
	app.Plex = nil
	p := NewPlaying(app, &plex.Item{Title: "A film", Duration: 120}, nil, 0, func(string) {})
	defer func() { <-p.closePainter(app.osd) }()

	if got := p.osdY(); got != 368 {
		t.Fatalf("control panel starts at %d; want the existing 24px safe bottom with 184px control height (368)", got)
	}
	if got := p.osdHeight(); got != p.canvas.H-p.osdY() {
		t.Fatalf("panel height is %d; want it to reach raster bottom %d", got, p.canvas.H-p.osdY())
	}
	p.compose(false)
	if p.static.H != p.osdHeight() {
		t.Fatalf("static background is %dpx tall; want %d", p.static.H, p.osdHeight())
	}
	bottom := (p.osdHeight() - 1) * p.canvas.W
	if p.alpha[bottom] != OsdAlpha || string(p.static.Pix[bottom*4:bottom*4+4]) != string(p.static.Pix[:4]) {
		t.Fatal("panel bottom has a transparent alpha or a missing background fill")
	}
	if p.btnY+p.osdY() >= p.canvas.H {
		t.Fatalf("control row starts at %d, past raster bottom %d", p.btnY+p.osdY(), p.canvas.H)
	}
}

func TestPlayingPanelClampsWhenRasterIsShorterThanControls(t *testing.T) {
	app := betaTestApp(t)
	app.Out = &mutableCanvasOut{fakeOut: &fakeOut{c: gfx.NewCanvas(720, 160)}, w: 720, h: 160}
	app.Plex = nil
	p := NewPlaying(app, &plex.Item{Title: "A film", Duration: 120}, nil, 0, func(string) {})
	defer func() { <-p.closePainter(app.osd) }()

	if p.osdY() != 0 || p.osdHeight() != 160 {
		t.Fatalf("short-raster panel starts at %d with height %d; want a clipped panel within 0..160", p.osdY(), p.osdHeight())
	}
	p.compose(false)
}

type wideFakeOut struct{ *fakeOut }

func (*wideFakeOut) PlaybackCanvasSize() (int, int) { return 960, 480 }
func (*wideFakeOut) LayoutCanvasSize() (int, int)   { return 960, 480 }

func TestWallAddsPosterColumnsOnWideLayout(t *testing.T) {
	a := betaTestApp(t)
	a.Out = &wideFakeOut{&fakeOut{c: gfx.NewCanvas(960, 480)}}
	w := newWall(a, plex.Section{Key: "movies", Type: "movie"}, nil)
	if w.cols() != 6 || w.bandW() != 800 {
		t.Fatalf("wide wall is %d columns with a %d px band", w.cols(), w.bandW())
	}
}

func TestHomeUsesFifthPosterOnWideLayout(t *testing.T) {
	a := betaTestApp(t)
	a.Out = &wideFakeOut{&fakeOut{c: gfx.NewCanvas(960, 480)}}
	h := &Home{app: a}
	if h.visible() != 5 || h.safeW() != 848 {
		t.Fatalf("wide home layout has %d posters and %d safe pixels", h.visible(), h.safeW())
	}
}

func TestPlayingResizesCanvasWhenRasterChanges(t *testing.T) {
	out := &mutableCanvasOut{fakeOut: &fakeOut{c: gfx.NewCanvas(720, 480)}, w: 720, h: 480}
	a := betaTestApp(t)
	a.Out = out
	osd := &painterTestOSD{}
	p := NewPlaying(a, &plex.Item{Title: "A film"}, nil, 0, func(string) {})
	out.w, out.h = 960, 576
	p.resizeCanvas(osd)
	if p.canvas.W != 960 || p.canvas.H != 576 || p.painter.maxW != 960 || p.painter.maxH != 576 {
		t.Fatalf("resized panel %dx%d, painter max %dx%d", p.canvas.W, p.canvas.H, p.painter.maxW, p.painter.maxH)
	}
	<-p.closePainter(osd)
}

type mutableCanvasOut struct {
	*fakeOut
	w, h int
}

func (o *mutableCanvasOut) PlaybackCanvasSize() (int, int) { return o.w, o.h }
