package ui

import "plexcrt/internal/gfx"

// OSD is the overlay drawn over the video during playback: on the device
// it is the core's overlay plane (ring.Overlay), blended in the FPGA, so
// the UI writes pixels and they are on screen at the next field with no
// part in the video pipeline.
type OSD interface {
	Show(x, y int, c *gfx.Canvas, alpha []byte)
	Hide()
	Upload(off int, c *gfx.Canvas, alpha byte) // raw content into the region
	ShowAt(x, y, w, h, off int)                // show uploaded content: a header store
	Dot(x, y int, rgb uint32, on bool)         // the dot, composed into the overlay page; frame pixels
	DotRun(vx, xmin, xmax int)                 // moved vx px per field (ring.Overlay redraws it each heartbeat)
	DotX() int                                 // where it is now
	Bar(x, y, w, h int, rgb uint32, on bool)   // the bar, a filled rectangle in the overlay page
}
