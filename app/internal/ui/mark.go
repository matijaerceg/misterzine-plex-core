package ui

import (
	_ "embed"
	"math"

	"plexcrt/internal/gfx"
)

// The exported brand artwork, embedded so deployment needs only the app binary.
//
//go:embed assets/misterzine-stacked-v1.png
var wordmarkPNG []byte

type Wordmark struct {
	Over *gfx.Image // premultiplied alpha: BlitOver on composed pages
	Flat *gfx.Image // on the background colour: Blit anywhere
	W, H int        // of the lettering itself, for laying out beside it
}

const (
	markPad  = 14 // room around the letters for the shadow
	markBlur = 5  // box blur radius, applied three times: a wide, smooth fall-off
)

// NewWordmark scales the supplied artwork for the canvas's 8:9 pixels.
func NewWordmark() *Wordmark {
	source, err := gfx.Decode(wordmarkPNG)
	if err != nil {
		panic("invalid embedded wordmark: " + err.Error())
	}
	// Trim transparent export margins so placement means the visible artwork.
	left, top, right, bottom := source.W, source.H, 0, 0
	for y := 0; y < source.H; y++ {
		for x := 0; x < source.W; x++ {
			if source.Pix[(y*source.W+x)*4+3] != 0 {
				left, top = min(left, x), min(top, y)
				right, bottom = max(right, x+1), max(bottom, y+1)
			}
		}
	}
	const tw = 143
	sw, shgt := right-left, bottom-top
	if sw <= 0 || shgt <= 0 {
		panic("empty embedded wordmark")
	}
	lineH := (tw*shgt*8 + sw*9/2) / (sw * 9)
	markW := tw
	w, h := markW+2*markPad, lineH+2*markPad
	col := gfx.NewCanvas(w, h)
	// Area sampling keeps thin edges smooth when reducing the large export.
	for y := 0; y < lineH; y++ {
		y0, y1 := float64(y*shgt)/float64(lineH), float64((y+1)*shgt)/float64(lineH)
		for x := 0; x < tw; x++ {
			x0, x1 := float64(x*sw)/tw, float64((x+1)*sw)/tw
			var sum [4]float64
			for sy := int(y0); sy < int(math.Ceil(y1)); sy++ {
				wy := min(y1, float64(sy+1)) - max(y0, float64(sy))
				for sx := int(x0); sx < int(math.Ceil(x1)); sx++ {
					weight := wy * (min(x1, float64(sx+1)) - max(x0, float64(sx)))
					off := ((top+sy)*source.W + left + sx) * 4
					for c := range sum {
						sum[c] += float64(source.Pix[off+c]) * weight
					}
				}
			}
			i := (y+markPad)*w + x + markPad
			area := (x1 - x0) * (y1 - y0)
			for c := range sum {
				col.Pix[i*4+c] = byte(sum[c]/area + 0.5)
			}
		}
	}
	return shadowedMark(col, markW, lineH)
}

// NewMark is a picture already at its drawn size (premultiplied, as
// gfx.Decode gives it) as a Wordmark: the wordmark's shadow around it, its
// W and H the picture's own. An extra's Home logo is made this way.
func NewMark(im *gfx.Image) *Wordmark {
	w, h := im.W+2*markPad, im.H+2*markPad
	col := gfx.NewCanvas(w, h)
	for y := 0; y < im.H; y++ {
		copy(col.Pix[((y+markPad)*w+markPad)*4:], im.Pix[y*im.W*4:(y+1)*im.W*4])
	}
	return shadowedMark(col, im.W, im.H)
}

// shadowedMark puts the shadow under the premultiplied picture in col,
// which has markPad of room on each side of the w x h picture.
func shadowedMark(col *gfx.Canvas, markW, lineH int) *Wordmark {
	w, h := col.W, col.H
	alpha := make([]float32, w*h)
	for i := range alpha {
		alpha[i] = float32(col.Pix[i*4+3]) / 255
	}
	// the shadow: the coverage blurred wide, three box passes
	sh := make([]float32, w*h)
	copy(sh, alpha)
	tmp := make([]float32, w*h)
	for pass := 0; pass < 3; pass++ {
		boxBlur(sh, tmp, w, h, markBlur)
	}
	over := &gfx.Image{W: w, H: h, Pix: make([]byte, w*h*4), Alpha: true}
	for i := 0; i < w*h; i++ {
		s := sh[i] * 0.40 // shadow strength
		if s > 1 {
			s = 1
		}
		a := alpha[i]
		// letters over the shadow (black), premultiplied
		outA := a + s*(1-a)
		b := float32(col.Pix[i*4]) / 255
		g := float32(col.Pix[i*4+1]) / 255
		r := float32(col.Pix[i*4+2]) / 255
		over.Pix[i*4] = byte(b*255 + 0.5)
		over.Pix[i*4+1] = byte(g*255 + 0.5)
		over.Pix[i*4+2] = byte(r*255 + 0.5)
		over.Pix[i*4+3] = byte(outA*255 + 0.5)
	}
	flat := gfx.NewCanvas(w, h)
	flat.Fill(0, 0, w, h, gfx.Bg)
	flat.BlitOver(0, 0, over)
	return &Wordmark{Over: over, Flat: &gfx.Image{W: w, H: h, Pix: flat.Pix}, W: markW, H: lineH}
}

// boxBlur blurs a in place (using tmp) with a box of radius r, each axis.
func boxBlur(a, tmp []float32, w, h, r int) {
	n := float32(2*r + 1)
	for y := 0; y < h; y++ {
		row := a[y*w : (y+1)*w]
		out := tmp[y*w : (y+1)*w]
		var sum float32
		for x := -r; x <= r; x++ {
			if x >= 0 && x < w {
				sum += row[x]
			}
		}
		for x := 0; x < w; x++ {
			out[x] = sum / n
			if x-r >= 0 {
				sum -= row[x-r]
			}
			if x+r+1 < w {
				sum += row[x+r+1]
			}
		}
	}
	for x := 0; x < w; x++ {
		var sum float32
		for y := -r; y <= r; y++ {
			if y >= 0 && y < h {
				sum += tmp[y*w+x]
			}
		}
		for y := 0; y < h; y++ {
			a[y*w+x] = sum / n
			if y-r >= 0 {
				sum -= tmp[(y-r)*w+x]
			}
			if y+r+1 < h {
				sum += tmp[(y+r+1)*w+x]
			}
		}
	}
}

// Place draws the mark with its lettering's top-left at x,y on a
// composed page.
func (m *Wordmark) Place(c *gfx.Canvas, x, y int) {
	c.BlitOver(x-markPad, y-markPad, m.Over)
}

// PlaceFlat draws the mark on the background colour, for direct drawing.
func (m *Wordmark) PlaceFlat(c *gfx.Canvas, x, y int) {
	c.Blit(x-markPad, y-markPad, m.Flat)
}
