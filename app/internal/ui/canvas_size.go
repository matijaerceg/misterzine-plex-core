package ui

import "plexcrt/internal/gfx"

// DesignW x DesignH is the canvas the screens were designed for; a wider
// output (16:9) widens the layouts that have a wider form.
const DesignW, DesignH = 720, 480

// layoutCanvasSize reports the logical canvas currently requested by the
// output. The application defaults to the design size.
func layoutCanvasSize(app *App) (int, int) {
	if sized, ok := app.Out.(interface{ LayoutCanvasSize() (int, int) }); ok {
		if w, h := sized.LayoutCanvasSize(); w > 0 && h > 0 {
			return w, h
		}
	}
	return DesignW, DesignH
}

// playbackCanvasSize is the overlay canvas the output wants during
// playback; the design size, ok false, when it does not say.
func playbackCanvasSize(app *App) (w, h int, ok bool) {
	if sized, ok := app.Out.(interface{ PlaybackCanvasSize() (int, int) }); ok {
		w, h := sized.PlaybackCanvasSize()
		return w, h, true
	}
	return DesignW, DesignH, false
}

// setOSDCanvasSize tells an overlay that takes one the canvas size it shows.
func setOSDCanvasSize(osd OSD, w, h int) {
	if sized, ok := osd.(interface{ SetCanvasSize(int, int) }); ok {
		sized.SetCanvasSize(w, h)
	}
}

func canvasSizeIs(c *gfx.Canvas, w, h int) bool {
	return c != nil && c.W == w && c.H == h && len(c.Pix) >= w*h*4
}
