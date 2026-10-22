package gfx

import (
	"image"
	"testing"
)

// Mask blends the colour by the mask's coverage, leaves uncovered pixels
// alone, and clips at the canvas edges.
func TestMask(t *testing.T) {
	c := NewCanvas(4, 2)
	c.Fill(0, 0, 4, 2, 0x204060)
	m := image.NewGray(image.Rect(0, 0, 3, 3))
	copy(m.Pix, []byte{0, 255, 128, 64, 0, 255, 255, 255, 255})
	c.Mask(2, -1, m, 0xFF8000) // only the mask's last two rows land, at columns 2 and 3
	px := func(x, y int) [3]byte { i := (y*c.W + x) * 4; return [3]byte{c.Pix[i+2], c.Pix[i+1], c.Pix[i]} }
	mix := func(from, to, a int) byte { return byte(from + (to-from)*a/255) }
	want := map[[2]int][3]byte{
		{2, 0}: {mix(0x20, 0xFF, 64), mix(0x40, 0x80, 64), mix(0x60, 0, 64)},
		{3, 0}: {0x20, 0x40, 0x60},
		{2, 1}: {0xFF, 0x80, 0},
		{3, 1}: {0xFF, 0x80, 0},
	}
	for y := range 2 {
		for x := range 4 {
			w, ok := want[[2]int{x, y}]
			if !ok {
				w = [3]byte{0x20, 0x40, 0x60}
			}
			if got := px(x, y); got != w {
				t.Errorf("%d,%d: got %x want %x", x, y, got, w)
			}
		}
	}
	c.Mask(0, 0, nil, White) // no mask, no paint
}
