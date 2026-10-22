package ui

import (
	"os"
	"testing"

	"plexcrt/internal/gfx"
	"plexcrt/internal/ring"
)

func BenchmarkTransitionBackdrop(b *testing.B) {
	a, z, out := gfx.NewCanvas(720, 480), gfx.NewCanvas(720, 480), gfx.NewCanvas(720, 480)
	ai := &gfx.Image{W: 720, H: 480, Pix: a.Pix}
	zi := &gfx.Image{W: 720, H: 480, Pix: z.Pix}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		out.BlendBackdrop(ai, -27, zi, 27, ai, 27, 128)
	}
}

// Run only on an idle DE10. Writes an unpublished slot, never changes scanout.
func BenchmarkTransitionRingCopy(b *testing.B) {
	if os.Getenv("PLEXCRT_BENCH_RING") != "1" {
		b.Skip("requires idle hardware and PLEXCRT_BENCH_RING=1")
	}
	r, err := ring.Open(b.Logf)
	if err != nil {
		b.Fatal(err)
	}
	defer r.Close()
	dst, src := r.Begin(), gfx.NewCanvas(720, 480)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		dst.Copy(src)
	}
}

func BenchmarkTransitionComposition(b *testing.B) {
	if os.Getenv("PLEXCRT_BENCH_RING") != "1" {
		b.Skip("requires idle hardware and PLEXCRT_BENCH_RING=1")
	}
	r, err := ring.Open(b.Logf)
	if err != nil {
		b.Fatal(err)
	}
	defer r.Close()
	dst, page, stage := r.Begin(), gfx.NewCanvas(720, 480), gfx.NewCanvas(720, 480)
	poster := &gfx.Image{W: PosterW, H: PosterH, Pix: make([]byte, PosterW*PosterH*4)}
	logo := &gfx.Image{W: 260, H: 56, Pix: make([]byte, 260*56*4)}
	holes := []gfx.Rect{}
	for i := 0; i < 4; i++ {
		holes = append(holes, gfx.Rect{X: SafeX + i*PosterPitch, Y: TilesY, W: PosterW, H: PosterH})
	}
	var layer logoLayer
	draw := func(c *gfx.Canvas) {
		c.BlitExcept(page, holes)
		layer.imageOver(c, page, 56, 60, logo, 128, logo, 56, 60, 128)
		for _, h := range holes {
			c.Blit(h.X, h.Y, poster)
		}
		c.Frame(SafeX-FocusPad, TilesY-FocusPad, PosterW+2*FocusPad, PosterH+2*FocusPad, FocusT, gfx.White)
	}
	for _, staged := range []bool{false, true} {
		name := "direct"
		if staged {
			name = "staged"
		}
		b.Run(name, func(b *testing.B) {
			for i := 0; i < b.N; i++ {
				if staged {
					draw(stage)
					dst.Copy(stage)
				} else {
					draw(dst)
				}
			}
		})
	}
}
