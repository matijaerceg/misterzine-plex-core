package gfx

import "image"

// Mask paints col through an 8-bit coverage mask with its top-left at x,y,
// clipped to the canvas: each pixel moves towards col by the mask's value
// (255 is col, 0 leaves it). For anti-aliased icons. It reads the
// destination: not for the overlay pages.
func (c *Canvas) Mask(x, y int, m *image.Gray, col Color) {
	if m == nil {
		return
	}
	w, h := m.Rect.Dx(), m.Rect.Dy()
	x0, y0, x1, y1 := c.clip(x, y, w, h)
	b, g, r := int(byte(col)), int(byte(col>>8)), int(byte(col>>16))
	for yy := y0; yy < y1; yy++ {
		mrow := m.Pix[(yy-y)*m.Stride:]
		off := (yy*c.W + x0) * 4
		for xx := x0; xx < x1; xx++ {
			a := int(mrow[xx-x])
			p := c.Pix[off : off+3 : off+3]
			off += 4
			switch a {
			case 0:
			case 255:
				p[0], p[1], p[2] = byte(b), byte(g), byte(r)
			default:
				p[0] = byte(int(p[0]) + (b-int(p[0]))*a/255)
				p[1] = byte(int(p[1]) + (g-int(p[1]))*a/255)
				p[2] = byte(int(p[2]) + (r-int(p[2]))*a/255)
			}
		}
	}
}
