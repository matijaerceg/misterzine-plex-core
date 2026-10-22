package ui

import (
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/plex"
)

// uploadOSD keeps what the list code uploads.
type uploadOSD struct {
	nopOSD
	mu  sync.Mutex
	got *gfx.Canvas
}

func (o *uploadOSD) Upload(_ int, c *gfx.Canvas, _ byte) {
	o.mu.Lock()
	o.got = c
	o.mu.Unlock()
}

// Optional previews of the playback menu: CROP_PREVIEW_DIR=dir go test -run CropPreview
func TestCropPreview(t *testing.T) {
	dir := os.Getenv("CROP_PREVIEW_DIR")
	if dir == "" {
		t.Skip("set CROP_PREVIEW_DIR to render previews")
	}
	if err := os.MkdirAll(dir, 0755); err != nil {
		t.Fatal(err)
	}
	a := cropApp(t)
	a.crop = CropFill
	video := func() *gfx.Canvas {
		c := gfx.NewCanvas(720, 480)
		c.Fill(0, 0, 720, 480, 0x406080)
		return c
	}
	blend := func(dst *gfx.Canvas, x0, y0 int, src *gfx.Canvas, alpha func(i int) int) {
		for y := 0; y < src.H && y0+y < dst.H; y++ {
			for x := 0; x < src.W && x0+x < dst.W; x++ {
				a := alpha(y*src.W + x)
				s, d := (y*src.W+x)*4, ((y0+y)*dst.W+x0+x)*4
				for k := 0; k < 3; k++ {
					dst.Pix[d+k] = byte((int(src.Pix[s+k])*a + int(dst.Pix[d+k])*(255-a)) / 255)
				}
			}
		}
	}
	bar := func(aspect float64) *gfx.Canvas {
		p := playingCrop(a, aspect)
		p.item = &plex.Item{Type: "episode", GrandTitle: "The Show", Title: "An Episode", Parent: 2, Index: 5, Aspect: aspect}
		p.dur, p.pos = 1800, 600
		p.canvas, p.alpha = gfx.NewCanvas(720, 480), make([]byte, 720*480)
		for i := 0; i < 15; i++ { // text is cached off-thread: draw until it is there
			p.staticFor = ""
			p.compose(false)
			time.Sleep(20 * time.Millisecond)
		}
		c := video()
		panel := &gfx.Canvas{W: 720, H: OsdH, Pix: p.canvas.Pix[:720*OsdH*4]}
		blend(c, 0, OsdY, panel, func(i int) int { return int(p.alpha[i]) })
		c.Fill(p.btnX[p.focus], OsdY+p.btnY, p.btnW[p.focus], BarW, gfx.GreyHi)
		return c
	}
	list := func(open func(p *Playing)) *gfx.Canvas {
		p := playingCrop(a, 1.78)
		p.painter = newPainter()
		open(p)
		osd := &uploadOSD{}
		p.uploadList(osd)
		var up *gfx.Canvas
		for i := 0; i < 100 && up == nil; i++ {
			time.Sleep(10 * time.Millisecond)
			osd.mu.Lock()
			up = osd.got
			osd.mu.Unlock()
		}
		if up == nil {
			t.Fatal("nothing uploaded")
		}
		c := video()
		win := &gfx.Canvas{W: OsdListW, H: OsdListH, Pix: up.Pix[:OsdListW*OsdListH*4]}
		blend(c, 0, SafeY, win, func(int) int { return 240 })
		by := SafeY + OsdListTop + p.list.cur*OsdListRowH
		c.Fill(MenuX-MenuBarGap-BarW, by+2, BarW, a.F.Body.Height()-4, gfx.GreyHi)
		return c
	}
	options := func() *gfx.Canvas {
		o := NewOptions(a)
		for i, it := range o.items() {
			if it.label == "Video crop" {
				o.cur = i
			}
		}
		c := gfx.NewCanvas(720, 480)
		for i := 0; i < 15; i++ {
			o.Draw(c, time.Now())
			time.Sleep(20 * time.Millisecond)
		}
		return c
	}
	shots := map[string]*gfx.Canvas{
		"bar":        bar(1.78),
		"bar-dimmed": bar(1.33),
		"more":       list(func(p *Playing) { p.openMore() }),
		"crop":       list(func(p *Playing) { p.openCrop() }),
		"options":    options(),
	}
	for name, c := range shots {
		// 720 source pixels occupy a 640-wide 4:3 display.
		out := image.NewRGBA(image.Rect(0, 0, 640, 480))
		for y := 0; y < 480; y++ {
			for x := 0; x < 640; x++ {
				p := (y*720 + x*720/640) * 4
				out.SetRGBA(x, y, color.RGBA{c.Pix[p+2], c.Pix[p+1], c.Pix[p], 255})
			}
		}
		file, err := os.Create(filepath.Join(dir, "crop-"+name+".png"))
		if err != nil {
			t.Fatal(err)
		}
		err = png.Encode(file, out)
		file.Close()
		if err != nil {
			t.Fatal(err)
		}
	}
}
