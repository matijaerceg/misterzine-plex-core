package gfx

import (
	"bytes"
	"image"
	"image/draw"
	_ "image/jpeg"
	_ "image/png"
	"os"
	"strconv"
)

// Decode turns a JPEG or PNG into canvas layout.
func Decode(data []byte) (*Image, error) {
	im, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	b := im.Bounds()
	// image/draw has the fast YCbCr->RGBA path; then swap to BGRx in place
	rgba := image.NewRGBA(image.Rect(0, 0, b.Dx(), b.Dy()))
	draw.Draw(rgba, rgba.Rect, im, b.Min, draw.Src)
	out := &Image{W: b.Dx(), H: b.Dy(), Pix: rgba.Pix}
	_, hasAlpha := im.(*image.NRGBA)
	if !hasAlpha {
		_, hasAlpha = im.(*image.RGBA)
	}
	out.Alpha = hasAlpha
	for o := 0; o < len(out.Pix); o += 4 {
		out.Pix[o], out.Pix[o+2] = out.Pix[o+2], out.Pix[o]
		if !hasAlpha {
			out.Pix[o+3] = 0
		}
	}
	return out, nil
}

// LoadFile decodes an image file.
func LoadFile(path string) (*Image, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return Decode(data)
}

// Crop returns the centre w x h of an image (or the image if smaller).
func (im *Image) Crop(w, h int) *Image {
	if im.W <= w && im.H <= h {
		return im
	}
	if w > im.W {
		w = im.W
	}
	if h > im.H {
		h = im.H
	}
	x0, y0 := (im.W-w)/2, (im.H-h)/2
	out := &Image{W: w, H: h, Pix: make([]byte, w*h*4)}
	for y := 0; y < h; y++ {
		so := ((y0+y)*im.W + x0) * 4
		copy(out.Pix[y*w*4:(y+1)*w*4], im.Pix[so:so+w*4])
	}
	return out
}

// ScaleH resamples the picture to h rows (bilinear between rows). The
// frame's pixels are 8/9 as wide as tall, so a picture fetched at square
// pixels is squeezed vertically by 8/9 to keep its shape.
func (im *Image) ScaleH(h int) *Image {
	if h == im.H || h < 2 || im.H < 2 {
		return im
	}
	out := &Image{W: im.W, H: h, Pix: make([]byte, im.W*h*4), Alpha: im.Alpha}
	rw := im.W * 4
	for y := 0; y < h; y++ {
		sy := y * (im.H - 1) * 256 / (h - 1) // 24.8 fixed point
		y0, f := sy>>8, sy&255
		y1 := y0 + 1
		if y1 >= im.H {
			y1 = im.H - 1
		}
		a, b, d := im.Pix[y0*rw:(y0+1)*rw], im.Pix[y1*rw:(y1+1)*rw], out.Pix[y*rw:(y+1)*rw]
		if f == 0 {
			copy(d, a)
			continue
		}
		for i := range d {
			d[i] = byte((int(a[i])*(256-f) + int(b[i])*f) >> 8)
		}
	}
	return out
}

// Shrink resamples the picture down to w x h with a box filter (every
// source pixel contributes once), for badges drawn large and shown small.
func (im *Image) Shrink(w, h int) *Image {
	if w >= im.W || h >= im.H || w < 1 || h < 1 {
		return im
	}
	out := &Image{W: w, H: h, Pix: make([]byte, w*h*4), Alpha: im.Alpha}
	for y := 0; y < h; y++ {
		y0, y1 := y*im.H/h, (y+1)*im.H/h
		for x := 0; x < w; x++ {
			x0, x1 := x*im.W/w, (x+1)*im.W/w
			var sum [4]int
			for sy := y0; sy < y1; sy++ {
				for sx := x0; sx < x1; sx++ {
					o := (sy*im.W + sx) * 4
					for i := range sum {
						sum[i] += int(im.Pix[o+i])
					}
				}
			}
			n := (y1 - y0) * (x1 - x0)
			o := (y*w + x) * 4
			for i := range sum {
				out.Pix[o+i] = byte((sum[i] + n/2) / n)
			}
		}
	}
	return out
}

// WritePPM saves the canvas as a binary PPM (for off-CRT checks).
func (c *Canvas) WritePPM(path string) error {
	out := make([]byte, 0, c.W*c.H*3+20)
	out = append(out, "P6\n"+strconv.Itoa(c.W)+" "+strconv.Itoa(c.H)+"\n255\n"...)
	for i := 0; i < len(c.Pix); i += 4 {
		out = append(out, c.Pix[i+2], c.Pix[i+1], c.Pix[i])
	}
	return os.WriteFile(path, out, 0o644)
}
