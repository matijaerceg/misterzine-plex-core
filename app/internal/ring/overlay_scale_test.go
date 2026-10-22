package ring

import (
	"bytes"
	"math/rand"
	"testing"

	"plexcrt/internal/gfx"
)

// refScaleCanvas is Show's scaled copy as it was, a pixel at a time: the
// reference scaleCanvas must match byte for byte.
func refScaleCanvas(dst []byte, w, h int, c *gfx.Canvas, alpha []byte) {
	mapX := make([]int, w)
	for xx := range mapX {
		mapX[xx] = min(c.W-1, xx*c.W/w)
	}
	for yy := 0; yy < h; yy++ {
		row := dst[yy*w*4 : (yy+1)*w*4]
		sourceY := min(c.H-1, yy*c.H/h)
		for xx := 0; xx < w; xx++ {
			sourceX := mapX[xx]
			src := (sourceY*c.W + sourceX) * 4
			dst := xx * 4
			copy(row[dst:dst+4], c.Pix[src:src+4])
			a := byte(255)
			if alpha != nil {
				a = alpha[sourceY*c.W+sourceX]
			}
			row[dst+3] = a
		}
	}
}

// refScaleRegion is ShowAt's copy as it was.
func refScaleRegion(own []byte, w, h int, region []byte, off, lw, lh int) {
	mapX := make([]int, w)
	for xx := range mapX {
		mapX[xx] = min(lw-1, xx*lw/w)
	}
	for yy := 0; yy < h; yy++ {
		sourceY := min(lh-1, yy*lh/h)
		for xx := 0; xx < w; xx++ {
			src := off + (sourceY*lw+mapX[xx])*4
			dst := (yy*w + xx) * 4
			copy(own[dst:dst+4], region[src:src+4])
		}
	}
}

func noise(rng *rand.Rand, b []byte) {
	for i := range b {
		b[i] = byte(rng.Intn(256))
	}
}

// scaleCases are source and output sizes the overlay meets: 480-line
// panels on 576 lines, a 960-wide design on 720 and 1280 columns, Native
// rasters of odd sizes, shrinking, and the degenerate ones.
var scaleCases = [][4]int{
	{720, 208, 720, 250}, {960, 208, 720, 208}, {960, 208, 1280, 312}, {960, 40, 1280, 60},
	{720, 104, 720, 124}, {960, 120, 964, 136}, {360, 400, 360, 480}, {360, 400, 480, 600},
	{360, 400, 270, 400}, {33, 7, 50, 11}, {50, 11, 33, 7}, {1, 1, 4, 6}, {5, 3, 1, 1}, {7, 9, 7, 9},
}

func TestScaleCanvasMatchesThePixelCopy(t *testing.T) {
	rng := rand.New(rand.NewSource(1))
	var mapX []int
	for _, tc := range scaleCases {
		sw, sh, w, h := tc[0], tc[1], tc[2], tc[3]
		c := gfx.NewCanvas(sw, sh)
		noise(rng, c.Pix)
		alpha := make([]byte, sw*sh)
		noise(rng, alpha)
		for _, a := range [][]byte{alpha, nil} {
			want := make([]byte, w*h*4)
			refScaleCanvas(want, w, h, c, a)
			got := make([]byte, w*h*4+64) // larger than needed, as o.own may be
			noise(rng, got)
			mapX = scaleCanvas(got, w, h, c, a, mapX)
			if !bytes.Equal(got[:w*h*4], want) {
				t.Fatalf("%dx%d to %dx%d (alpha %v): scaled pixels differ", sw, sh, w, h, a != nil)
			}
		}
	}
}

func TestScaleRegionMatchesThePixelCopy(t *testing.T) {
	rng := rand.New(rand.NewSource(2))
	region := make([]byte, 1<<20)
	noise(rng, region)
	var mapX []int
	cases := append(scaleCases, [4]int{360, 400, 360, 400}, [4]int{360, 400, 360, 398})
	for _, tc := range cases {
		lw, lh, w, h := tc[0], tc[1], tc[2], tc[3]
		for _, off := range []int{0, 8, 1440 * 13} {
			want := make([]byte, w*h*4)
			refScaleRegion(want, w, h, region, off, lw, lh)
			got := make([]byte, w*h*4+64)
			noise(rng, got)
			mapX = scaleRegion(got, w, h, region[off:off+lw*lh*4], lw, lh, mapX)
			if !bytes.Equal(got[:w*h*4], want) {
				t.Fatalf("%dx%d to %dx%d at %d: scaled pixels differ", lw, lh, w, h, off)
			}
		}
	}
}

// Through Show itself, on a Native raster: what compose takes is the
// reference copy of the panel at the size Show chose.
func TestShowScalesAsThePixelCopyDid(t *testing.T) {
	f := newFake(t, false)
	f.fb = make([]byte, NPage*1280*720*4)
	f.r.fb = f.fb
	f.r.setOutput(1280, 720)
	f.r.setPages()
	o := f.r.Overlay()
	o.SetCanvasSize(960, 480)
	rng := rand.New(rand.NewSource(3))
	c := gfx.NewCanvas(960, 208)
	noise(rng, c.Pix)
	alpha := make([]byte, c.W*c.H)
	noise(rng, alpha)
	o.Show(0, 272, c, alpha)
	if o.w == c.W && o.h == c.H {
		t.Fatalf("panel not scaled: %dx%d", o.w, o.h)
	}
	want := make([]byte, o.w*o.h*4)
	refScaleCanvas(want, o.w, o.h, c, alpha)
	if !bytes.Equal(o.src[:o.w*o.h*4], want) {
		t.Fatal("Show's scaled panel differs from the pixel copy")
	}
}

func BenchmarkScaleCanvas(b *testing.B) {
	for _, tc := range []struct {
		name         string
		sw, sh, w, h int
	}{
		{"panel-576i", 720, 208, 720, 250},
		{"panel-wide-720", 960, 208, 720, 208},
		{"panel-native-1280x720", 960, 208, 1280, 312},
		{"xl-subtitle-576i", 720, 108, 720, 130},
	} {
		c := gfx.NewCanvas(tc.sw, tc.sh)
		noise(rand.New(rand.NewSource(4)), c.Pix)
		alpha := make([]byte, tc.sw*tc.sh)
		dst := make([]byte, tc.w*tc.h*4)
		b.Run(tc.name+"/pixel", func(b *testing.B) {
			for i := 0; i < b.N; i++ {
				refScaleCanvas(dst, tc.w, tc.h, c, alpha)
			}
		})
		b.Run(tc.name+"/rows", func(b *testing.B) {
			var mapX []int
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				mapX = scaleCanvas(dst, tc.w, tc.h, c, alpha, mapX)
			}
		})
	}
}

func BenchmarkScaleRegion(b *testing.B) {
	region := make([]byte, RegionSize)
	for _, tc := range []struct {
		name         string
		lw, lh, w, h int
	}{
		{"list-480", 360, 400, 360, 400},
		{"list-576i", 360, 400, 360, 480},
		{"list-native-1280x720", 360, 400, 480, 600},
	} {
		dst := make([]byte, tc.w*tc.h*4)
		b.Run(tc.name+"/pixel", func(b *testing.B) {
			for i := 0; i < b.N; i++ {
				refScaleRegion(dst, tc.w, tc.h, region, 0, tc.lw, tc.lh)
			}
		})
		b.Run(tc.name+"/rows", func(b *testing.B) {
			var mapX []int
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				mapX = scaleRegion(dst, tc.w, tc.h, region[:tc.lw*tc.lh*4], tc.lw, tc.lh, mapX)
			}
		})
	}
}
