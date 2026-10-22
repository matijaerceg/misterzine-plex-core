// Package gfx is the software renderer for the app's 480-line frames: a BGRx
// canvas in the exact byte order of the H.264 core's overlay pages (xRGB8888
// little endian), so presenting is one copy; fills, blits, alpha-blended glyphs from
// the prerendered Roboto atlases, and images converted to the same layout.
package gfx

import "unsafe"

// Color is 0xRRGGBB.
type Color uint32

const (
	Black  Color = 0x000000
	White  Color = 0xFFFFFF
	Grey   Color = 0xD0D0D0 // large/bold text: full white blooms on a consumer set
	GreyHi Color = 0xE0E0E0
	GreyLo Color = 0xC0C0C0 // dimmest readable grey through composite
	Bg     Color = 0x0B0E14 // near black with a hint of blue
	Bar    Color = 0x1C2230 // dark surface: placeholders, dim panels
	Amber  Color = 0xE5A00D // Plex's amber
	Purple Color = 0xA98BFF // the MisterZine mark: kept light so it holds through composite
)

// Canvas is a W x H frame in BGRx byte order.
type Canvas struct {
	W, H int
	Pix  []byte
	// row is one canvas row of a solid colour in ordinary memory. Fills copy
	// from it: the canvas may be write-combined framebuffer memory (the
	// overlay pages), which must never be read. Per canvas, because text workers fill concurrently.
	row    []byte
	rowCol Color
}

// NewCanvas allocates a canvas.
func NewCanvas(w, h int) *Canvas { return &Canvas{W: w, H: h, Pix: make([]byte, w*h*4)} }

// Image is a picture in canvas layout (BGRx), ready to blit. Alpha marks a
// picture with a real alpha channel (premultiplied): it is drawn with
// BlitOver, on ordinary canvases only.
type Image struct {
	W, H  int
	Pix   []byte
	Alpha bool
}

// Dimmed returns a copy at the given brightness (0..255).
func (im *Image) Dimmed(bright int) *Image {
	out := &Image{W: im.W, H: im.H, Pix: make([]byte, len(im.Pix))}
	for i, v := range im.Pix {
		out.Pix[i] = byte(int(v) * bright / 255)
	}
	return out
}

func (c *Canvas) clip(x, y, w, h int) (x0, y0, x1, y1 int) {
	x0, y0, x1, y1 = x, y, x+w, y+h
	if x0 < 0 {
		x0 = 0
	}
	if y0 < 0 {
		y0 = 0
	}
	if x1 > c.W {
		x1 = c.W
	}
	if y1 > c.H {
		y1 = c.H
	}
	return
}

func (c *Canvas) solidRow(col Color, n int) []byte {
	if c.row == nil {
		c.row = make([]byte, c.W*4)
		c.rowCol = col + 1
	}
	if c.rowCol != col {
		b, g, r := byte(col), byte(col>>8), byte(col>>16)
		for i := 0; i < len(c.row); i += 4 {
			c.row[i], c.row[i+1], c.row[i+2], c.row[i+3] = b, g, r, 0
		}
		c.rowCol = col
	}
	return c.row[:n]
}

// Fill paints an opaque rectangle.
func (c *Canvas) Fill(x, y, w, h int, col Color) {
	x0, y0, x1, y1 := c.clip(x, y, w, h)
	if x0 >= x1 || y0 >= y1 {
		return
	}
	row := c.solidRow(col, (x1-x0)*4)
	for yy := y0; yy < y1; yy++ {
		off := (yy*c.W + x0) * 4
		copy(c.Pix[off:off+len(row)], row)
	}
}

// Rect is a hole for FillExcept.
type Rect struct{ X, Y, W, H int }

// FillExcept paints the whole canvas except the given rectangles, which the
// caller covers itself, so every pixel of the frame is written exactly once.
// Holes must not overlap each other.
func (c *Canvas) FillExcept(col Color, holes []Rect) {
	row := c.solidRow(col, c.W*4)
	var segs [16]Rect
	for y := 0; y < c.H; y++ {
		n := 0
		for _, h := range holes {
			if y >= h.Y && y < h.Y+h.H && n < len(segs) {
				segs[n] = h
				n++
			}
		}
		off := y * c.W * 4
		if n == 0 {
			copy(c.Pix[off:off+c.W*4], row)
			continue
		}
		for i := 1; i < n; i++ {
			for j := i; j > 0 && segs[j].X < segs[j-1].X; j-- {
				segs[j], segs[j-1] = segs[j-1], segs[j]
			}
		}
		x := 0
		for i := 0; i < n; i++ {
			hx0, hx1 := segs[i].X, segs[i].X+segs[i].W
			if hx0 < 0 {
				hx0 = 0
			}
			if hx1 > c.W {
				hx1 = c.W
			}
			if hx0 > x {
				copy(c.Pix[off+x*4:off+hx0*4], row[:(hx0-x)*4])
			}
			if hx1 > x {
				x = hx1
			}
		}
		if x < c.W {
			copy(c.Pix[off+x*4:off+c.W*4], row[:(c.W-x)*4])
		}
	}
}

// BlitExcept copies a same-sized canvas into this one except the given
// rectangles, which the caller covers itself (a composed page under a
// row of posters). Holes must not overlap each other.
func (c *Canvas) BlitExcept(src *Canvas, holes []Rect) {
	var segs [16]Rect
	for y := 0; y < c.H; y++ {
		n := 0
		for _, h := range holes {
			if y >= h.Y && y < h.Y+h.H && n < len(segs) {
				segs[n] = h
				n++
			}
		}
		off := y * c.W * 4
		if n == 0 {
			copy(c.Pix[off:off+c.W*4], src.Pix[off:off+c.W*4])
			continue
		}
		for i := 1; i < n; i++ {
			for j := i; j > 0 && segs[j].X < segs[j-1].X; j-- {
				segs[j], segs[j-1] = segs[j-1], segs[j]
			}
		}
		x := 0
		for i := 0; i < n; i++ {
			hx0, hx1 := segs[i].X, segs[i].X+segs[i].W
			if hx0 < 0 {
				hx0 = 0
			}
			if hx1 > c.W {
				hx1 = c.W
			}
			if hx0 > x {
				copy(c.Pix[off+x*4:off+hx0*4], src.Pix[off+x*4:off+hx0*4])
			}
			if hx1 > x {
				x = hx1
			}
		}
		if x < c.W {
			copy(c.Pix[off+x*4:off+c.W*4], src.Pix[off+x*4:off+c.W*4])
		}
	}
}

// FillAlpha blends a rectangle of col at alpha a (0..255) over the canvas.
// It reads the destination: not for the overlay pages.
func (c *Canvas) FillAlpha(x, y, w, h int, col Color, a int) {
	if a >= 255 {
		c.Fill(x, y, w, h, col)
		return
	}
	if a <= 0 {
		return
	}
	x0, y0, x1, y1 := c.clip(x, y, w, h)
	b, g, r := int(byte(col)), int(byte(col>>8)), int(byte(col>>16))
	for yy := y0; yy < y1; yy++ {
		off := (yy*c.W + x0) * 4
		for xx := x0; xx < x1; xx++ {
			p := c.Pix[off : off+3 : off+3]
			p[0] += byte((b - int(p[0])) * a / 255)
			p[1] += byte((g - int(p[1])) * a / 255)
			p[2] += byte((r - int(p[2])) * a / 255)
			off += 4
		}
	}
}

// Frame draws a border of thickness t inside the rectangle.
func (c *Canvas) Frame(x, y, w, h, t int, col Color) {
	c.Fill(x, y, w, t, col)
	c.Fill(x, y+h-t, w, t, col)
	c.Fill(x, y, t, h, col)
	c.Fill(x+w-t, y, t, h, col)
}

// Blit copies an image with its top-left at x,y, clipped to the canvas.
func (c *Canvas) Blit(x, y int, img *Image) {
	c.BlitClip(x, y, img, 0, 0, c.W, c.H)
}

// BlitClip copies an image clipped to both the canvas and the given rectangle.
func (c *Canvas) BlitClip(x, y int, img *Image, cx, cy, cw, ch int) {
	if img == nil {
		return
	}
	x0, y0, x1, y1 := c.clip(x, y, img.W, img.H)
	if cx > x0 {
		x0 = cx
	}
	if cy > y0 {
		y0 = cy
	}
	if cx+cw < x1 {
		x1 = cx + cw
	}
	if cy+ch < y1 {
		y1 = cy + ch
	}
	if x0 >= x1 || y0 >= y1 {
		return
	}
	n := (x1 - x0) * 4
	for yy := y0; yy < y1; yy++ {
		so := ((yy-y)*img.W + (x0 - x)) * 4
		do := (yy*c.W + x0) * 4
		copy(c.Pix[do:do+n], img.Pix[so:so+n])
	}
}

// BlitOver composites a premultiplied-alpha image over the canvas. It reads
// the destination: for composed pages, never the overlay pages.
func (c *Canvas) BlitOver(x, y int, img *Image) {
	if img == nil {
		return
	}
	x0, y0, x1, y1 := c.clip(x, y, img.W, img.H)
	for yy := y0; yy < y1; yy++ {
		so := ((yy-y)*img.W + (x0 - x)) * 4
		do := (yy*c.W + x0) * 4
		for xx := x0; xx < x1; xx++ {
			a := int(img.Pix[so+3])
			if a == 255 {
				c.Pix[do], c.Pix[do+1], c.Pix[do+2] = img.Pix[so], img.Pix[so+1], img.Pix[so+2]
			} else if a > 0 {
				ia := 255 - a
				c.Pix[do] = byte(int(img.Pix[so]) + int(c.Pix[do])*ia/255)
				c.Pix[do+1] = byte(int(img.Pix[so+1]) + int(c.Pix[do+1])*ia/255)
				c.Pix[do+2] = byte(int(img.Pix[so+2]) + int(c.Pix[do+2])*ia/255)
			}
			so += 4
			do += 4
		}
	}
}

// BlitOverT is BlitOver with the image's alpha scaled by t/256 (fading a
// logo in). For composed pages only.
func (c *Canvas) BlitOverT(x, y int, img *Image, t int) {
	if img == nil || t <= 0 {
		return
	}
	if t >= 256 {
		c.BlitOver(x, y, img)
		return
	}
	x0, y0, x1, y1 := c.clip(x, y, img.W, img.H)
	for yy := y0; yy < y1; yy++ {
		so := ((yy-y)*img.W + (x0 - x)) * 4
		do := (yy*c.W + x0) * 4
		for xx := x0; xx < x1; xx++ {
			a := int(img.Pix[so+3]) * t >> 8
			if a > 0 {
				ia := 255 - a
				c.Pix[do] = byte(int(img.Pix[so])*t>>8 + int(c.Pix[do])*ia/255)
				c.Pix[do+1] = byte(int(img.Pix[so+1])*t>>8 + int(c.Pix[do+1])*ia/255)
				c.Pix[do+2] = byte(int(img.Pix[so+2])*t>>8 + int(c.Pix[do+2])*ia/255)
			}
			so += 4
			do += 4
		}
	}
}

// Blend writes a mix of two same-sized images (t of 256 towards b) with its
// top-left at x,y. It reads only the sources, so it is safe on the frame.
// Two 8-bit lanes are mixed per multiply, on 32-bit words.
func (c *Canvas) Blend(x, y int, a, b *Image, t int) {
	x0, y0, x1, y1 := c.clip(x, y, a.W, a.H)
	if x0 >= x1 || y0 >= y1 || b.W != a.W || b.H != a.H {
		return
	}
	if t <= 0 {
		c.BlitClip(x, y, a, 0, 0, c.W, c.H)
		return
	}
	if t >= 256 {
		c.BlitClip(x, y, b, 0, 0, c.W, c.H)
		return
	}
	n := x1 - x0
	ta, tb := uint32(256-t), uint32(t)
	n4 := n / 4
	for yy := y0; yy < y1; yy++ {
		so := ((yy-y)*a.W + (x0 - x)) * 4
		do := (yy*c.W + x0) * 4
		if n4 > 0 {
			blendRow(unsafe.Pointer(&c.Pix[do]), unsafe.Pointer(&a.Pix[so]), unsafe.Pointer(&b.Pix[so]), n4, ta, tb)
		}
		for i := n4 * 16; i < n*4; i++ {
			c.Pix[do+i] = byte((uint32(a.Pix[so+i])*ta + uint32(b.Pix[so+i])*tb) >> 8)
		}
	}
}

// BlendBackdrop shifts two layouts over one continuously aligned backdrop.
// Uncovered rows sample that backdrop instead of fading a black canvas edge
// across it. Both layouts' artwork must use the same artY after their shifts.
func (c *Canvas) BlendBackdrop(a *Image, sa int, b *Image, sb int, backdrop *Image, artY, t int) {
	if a.W != c.W || b.W != c.W {
		return
	}
	bgRow := c.solidRow(Bg, c.W*4)
	ta, tb := uint32(256-t), uint32(t)
	n4 := c.W / 4
	for y := 0; y < c.H; y++ {
		base := bgRow
		if backdrop != nil && backdrop.W == c.W && y+artY >= 0 && y+artY < backdrop.H {
			base = backdrop.Pix[(y+artY)*c.W*4 : (y+artY+1)*c.W*4]
		}
		ra, rb := base, base
		if ya := y - sa; ya >= 0 && ya < a.H {
			ra = a.Pix[ya*a.W*4 : (ya+1)*a.W*4]
		}
		if yb := y - sb; yb >= 0 && yb < b.H {
			rb = b.Pix[yb*b.W*4 : (yb+1)*b.W*4]
		}
		do := y * c.W * 4
		blendRow(unsafe.Pointer(&c.Pix[do]), unsafe.Pointer(&ra[0]), unsafe.Pointer(&rb[0]), n4, ta, tb)
		for i := n4 * 16; i < c.W*4; i++ {
			c.Pix[do+i] = byte((uint32(ra[i])*ta + uint32(rb[i])*tb) >> 8)
		}
	}
}

// BlendSolidClip writes an image mixed towards a solid colour (t of 256
// towards the colour: 256 is the colour, 0 the image), clipped to the
// canvas and to a rectangle; for fading pictures in. Reads only the source.
func (c *Canvas) BlendSolidClip(x, y int, img *Image, col Color, t int, cx, cy, cw, ch int) {
	if img == nil {
		return
	}
	if t <= 0 {
		c.BlitClip(x, y, img, cx, cy, cw, ch)
		return
	}
	x0, y0, x1, y1 := c.clip(x, y, img.W, img.H)
	x0, y0, x1, y1 = max(x0, cx), max(y0, cy), min(x1, cx+cw), min(y1, cy+ch)
	if x0 >= x1 || y0 >= y1 {
		return
	}
	n := x1 - x0
	row := c.solidRow(col, n*4)
	ta, tb := uint32(256-t), uint32(t)
	n4 := n / 4
	for yy := y0; yy < y1; yy++ {
		so := ((yy-y)*img.W + (x0 - x)) * 4
		do := (yy*c.W + x0) * 4
		if n4 > 0 {
			blendRow(unsafe.Pointer(&c.Pix[do]), unsafe.Pointer(&img.Pix[so]), unsafe.Pointer(&row[0]), n4, ta, tb)
		}
		for i := n4 * 16; i < n*4; i++ {
			c.Pix[do+i] = byte((uint32(img.Pix[so+i])*ta + uint32(row[i])*tb) >> 8)
		}
	}
}

// Copy replaces the whole canvas with another of the same size.
func (c *Canvas) Copy(src *Canvas) { copy(c.Pix, src.Pix) }
