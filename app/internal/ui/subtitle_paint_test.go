package ui

import (
	"bytes"
	"strings"
	"testing"

	"plexcrt/internal/gfx"
)

// refDrawSubtitle is drawSubtitle as it was, fresh storage every cue and
// the bilinear scaler at every size: the reference the reused storage and
// the 1:1 blit must match byte for byte. Without the box, the outline is the
// type's coverage grown by a pixel, made here the slow way.
func refDrawSubtitle(lines []string, size, w int, box bool) (*gfx.Canvas, []byte) {
	f, px := subtitleFace(size)
	scale := px * 256 / f.Px
	padX := subtitlePadX * px / subtitleNormalPx
	maxW := max(1, (w-2*SafeX-2*padX)*256/scale)
	var rows []string
	for _, l := range lines {
		rows = append(rows, wrapAll(f, l, maxW)...)
	}
	rows = rows[:min(len(rows), subtitleMaxLines)]
	lineH := f.Height() * scale / 256
	c := gfx.NewCanvas(w, lineH*len(rows))
	alpha := make([]byte, w*c.H)
	const margin = 6
	for i, row := range rows {
		tw := f.Width(row)
		src := gfx.NewCanvas(tw+2*margin, f.Height())
		src.Text(margin, 0, f, gfx.White, row)
		out := make([]int, src.W*src.H)
		for y := range src.H {
			for x := range src.W {
				if box {
					continue
				}
				for dy := -1; dy <= 1; dy++ {
					for dx := -1; dx <= 1; dx++ {
						sx, sy := x+dx, y+dy
						if sx >= 0 && sy >= 0 && sx < src.W && sy < src.H {
							out[y*src.W+x] = max(out[y*src.W+x], int(src.Pix[(sy*src.W+sx)*4]))
						}
					}
				}
			}
		}
		boxW := min(w, tw*scale/256+2*padX)
		x0, y0 := (w-boxW)/2, i*lineH
		for y := y0; box && y < y0+lineH; y++ {
			box := alpha[y*w+x0 : y*w+x0+boxW]
			for x := range box {
				box[x] = subtitleBoxAlpha
			}
		}
		refScaleCoverage(c, alpha, src, out, x0+padX-margin*scale/256, y0, scale, lineH)
	}
	return c, alpha
}

func refScaleCoverage(c *gfx.Canvas, alpha []byte, src *gfx.Canvas, out []int, x, y, scale, lineH int) {
	sw := src.W * scale / 256
	x0s, fxs := make([]int, sw), make([]int, sw)
	for ox := range sw {
		p := max(0, (2*ox+1)*256*256/(2*scale)-128)
		x0s[ox], fxs[ox] = min(p>>8, src.W-1), p&255
	}
	cov := func(sx, sy int) int { return int(src.Pix[(sy*src.W+sx)*4]) }
	ring := func(sx, sy int) int { return out[sy*src.W+sx] }
	for oy := range lineH {
		py := y + oy
		if py < 0 || py >= c.H {
			continue
		}
		p := max(0, (2*oy+1)*256*256/(2*scale)-128)
		sy0, fy := min(p>>8, src.H-1), p&255
		sy1 := min(sy0+1, src.H-1)
		for ox := range sw {
			px := x + ox
			if px < 0 || px >= c.W {
				continue
			}
			sx0, fx := x0s[ox], fxs[ox]
			sx1 := min(sx0+1, src.W-1)
			top := cov(sx0, sy0)*(256-fx) + cov(sx1, sy0)*fx
			bottom := cov(sx0, sy1)*(256-fx) + cov(sx1, sy1)*fx
			v := (top*(256-fy) + bottom*fy) >> 16
			top = ring(sx0, sy0)*(256-fx) + ring(sx1, sy0)*fx
			bottom = ring(sx0, sy1)*(256-fx) + ring(sx1, sy1)*fx
			o := (top*(256-fy) + bottom*fy) >> 16
			if v == 0 && o == 0 {
				continue
			}
			i := py*c.W + px
			o = 255 - (255-o)*(255-int(alpha[i]))/255
			a := 255 - (255-v)*(255-o)/255
			grey := byte(min(255, v*255/a))
			alpha[i] = byte(a)
			c.Pix[i*4], c.Pix[i*4+1], c.Pix[i*4+2] = grey, grey, grey
		}
	}
}

// One paint drawing cue after cue, at every size and width, box or none,
// and in any order, draws each exactly as fresh storage and the scaler did.
func TestSubtitlePaintMatchesTheScaler(t *testing.T) {
	if f, px := subtitleFace(100); px*256/f.Px != 256 {
		t.Fatalf("Normal is drawn at %d/256, not 1:1", px*256/f.Px)
	}
	cues := [][]string{
		{"Hello there"},
		{"- Where were you?", "- Out."},
		{strings.Repeat("a long subtitle line ", 4)},
		{"one", "two", "three", "four", "five", "six", "seven"},
		{"Mm."},
		{"W W W W W W W W W W W W W W W W W W W W W W W W W W W W W W W W W W W W W W W W W W W W W W W W"},
	}
	var s subtitlePaint
	for _, w := range []int{720, 960, 300} {
		for j, size := range []int{200, 100, 150, 100, 200} {
			for i, lines := range cues {
				box := (i+j)%2 == 0
				want, wantAlpha := refDrawSubtitle(lines, size, w, box)
				got, gotAlpha := s.draw(lines, size, w, box)
				if got.W != want.W || got.H != want.H || !bytes.Equal(got.Pix, want.Pix) || !bytes.Equal(gotAlpha, wantAlpha) {
					t.Fatalf("width %d size %d cue %d box %v: the panel differs (%dx%d, want %dx%d)", w, size, i, box, got.W, got.H, want.W, want.H)
				}
			}
		}
	}
}

func BenchmarkDrawSubtitle(b *testing.B) {
	lines := []string{"- Where were you last night?", "- Out, with the others."}
	for _, size := range []int{100, 200} {
		name := map[int]string{100: "normal", 200: "extra-large"}[size]
		b.Run(name+"/fresh-scaled", func(b *testing.B) {
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				refDrawSubtitle(lines, size, 720, true)
			}
		})
		b.Run(name+"/reused", func(b *testing.B) {
			var s subtitlePaint
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				s.draw(lines, size, 720, true)
			}
		})
	}
}

// Without the box (the default), nothing is drawn but the type and a thin
// dark ring round it: no alpha away from the glyphs, solid type white, the
// ring's pixels dark, at every size.
func TestDrawSubtitleOutlineWithoutBox(t *testing.T) {
	for _, sz := range SubtitleSizes {
		var s subtitlePaint
		c, alpha := s.draw([]string{"Hello there"}, sz.Value, 720, false)
		ring, solid := 0, 0
		for y := range c.H {
			for x := range c.W {
				i := y*c.W + x
				a, grey := alpha[i], c.Pix[i*4]
				if a == 0 {
					continue
				}
				// every drawn pixel lies by the type: within a ring scaled
				// with the size, and the scaler's blur
				r := 2 + 2*sz.Value/100
				near := false
				for dy := -r; dy <= r && !near; dy++ {
					for dx := -r; dx <= r; dx++ {
						j := (y+dy)*c.W + x + dx
						if y+dy >= 0 && y+dy < c.H && x+dx >= 0 && x+dx < c.W && c.Pix[j*4] > 128 && alpha[j] > 128 {
							near = true
							break
						}
					}
				}
				if !near {
					t.Fatalf("%s: alpha %d at %d,%d away from the type", sz.Label, a, x, y)
				}
				switch {
				case a == 255 && grey >= 240:
					solid++
				case a >= 128 && grey <= 40:
					ring++
				}
				if c.Pix[i*4+1] != grey || c.Pix[i*4+2] != grey {
					t.Fatalf("%s: pixel %d,%d is not grey", sz.Label, x, y)
				}
			}
		}
		if solid == 0 || ring < solid/4 {
			t.Fatalf("%s: %d white type pixels, %d dark ring pixels", sz.Label, solid, ring)
		}
		// the row through the middle is clear at both ends: no box
		row := c.H / 2
		if alpha[row*c.W+SafeX] != 0 || alpha[row*c.W+c.W-1-SafeX] != 0 {
			t.Fatalf("%s: a box behind the type", sz.Label)
		}
		// on, the same cue has its box
		_, boxed := s.draw([]string{"Hello there"}, sz.Value, 720, true)
		if boxed[row*c.W] != 0 || slicesMax(boxed[row*c.W:(row+1)*c.W]) == 0 {
			t.Fatalf("%s: the box", sz.Label)
		}
		left := row * c.W
		for boxed[left] == 0 {
			left++
		}
		if boxed[left] != subtitleBoxAlpha {
			t.Fatalf("%s: the box's edge is %d", sz.Label, boxed[left])
		}
	}
}

func slicesMax(b []byte) byte {
	m := byte(0)
	for _, v := range b {
		m = max(m, v)
	}
	return m
}
