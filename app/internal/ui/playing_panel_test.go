package ui

import (
	"testing"

	"plexcrt/internal/gfx"
	"plexcrt/internal/plex"
)

func TestPlayingPanelBackgroundReachesRasterBottom(t *testing.T) {
	app := betaTestApp(t)
	app.Out = &fakeOut{c: gfx.NewCanvas(720, 480)}
	p := &Playing{
		app:    app,
		item:   &plex.Item{Title: "A film", Duration: 120},
		canvas: gfx.NewCanvas(720, 480),
		alpha:  make([]byte, 720*480),
	}

	if OsdY != 480-24-OsdControlH {
		t.Fatalf("control panel starts at %d; want its existing safe-zone position", OsdY)
	}
	if OsdY+OsdH != 480 {
		t.Fatalf("panel spans y=%d..%d; want it to reach the 480px raster bottom", OsdY, OsdY+OsdH)
	}
	p.compose(false)
	if p.static.H != OsdH {
		t.Fatalf("static background is %dpx tall; want %d", p.static.H, OsdH)
	}
	bottom := (OsdH - 1) * p.canvas.W
	if p.alpha[bottom] != OsdAlpha || string(p.static.Pix[bottom*4:bottom*4+4]) != string(p.static.Pix[:4]) {
		t.Fatal("panel bottom has a transparent alpha or a missing background fill")
	}
	if OsdY+p.btnY >= 480 {
		t.Fatalf("control row starts at %d, past raster bottom", OsdY+p.btnY)
	}
}
