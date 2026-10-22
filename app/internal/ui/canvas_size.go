package ui

import "plexcrt/internal/gfx"

// layoutCanvasSize reports the logical canvas currently requested by the
// output. The application defaults to the original 720x480 design size.
func layoutCanvasSize(app *App) (int, int) {
	if sized, ok := app.Out.(interface{ LayoutCanvasSize() (int, int) }); ok {
		if w, h := sized.LayoutCanvasSize(); w > 0 && h > 0 {
			return w, h
		}
	}
	return 720, 480
}

func canvasSizeIs(c *gfx.Canvas, w, h int) bool {
	return c != nil && c.W == w && c.H == h && len(c.Pix) >= w*h*4
}
