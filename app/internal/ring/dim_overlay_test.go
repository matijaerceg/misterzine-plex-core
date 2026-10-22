package ring

import (
	"testing"
	"unsafe"

	"plexcrt/internal/gfx"
)

func TestBrightnessDimsOverlayAndRestoresIt(t *testing.T) {
	f := newFake(t, false)
	o := f.r.Overlay()
	panel := gfx.NewCanvas(2, 2)
	px := unsafe.Slice((*uint32)(unsafe.Pointer(&panel.Pix[0])), panel.W*panel.H)
	for i := range px {
		px[i] = 0x00FFFFFF
	}
	o.Show(20, 30, panel, nil)

	f.r.SetBrightness(Full / 4)
	if got := f.lo(wOvlBand); got != (H-1)<<16 {
		t.Fatalf("dim veil band = %x, want full screen", got)
	}
	page := f.r.pages[f.r.cur]
	if got := page[0]; got != 0xBF000000 && got != 0xC0000000 {
		t.Fatalf("veil outside panel = %08x, want black alpha 191 or 192", got)
	}
	if got := page[30*W+20]; got != 0xFF3F3F3F {
		t.Fatalf("dim white panel = %08x, want opaque RGB 63", got)
	}

	// Changing the existing panel while dimmed must preserve dimming.
	for i := range px {
		px[i] = 0x0000FF00
	}
	o.Show(20, 30, panel, nil)
	if got := f.r.pages[f.r.cur][30*W+20]; got != 0xFF003F00 {
		t.Fatalf("updated dim panel = %08x, want opaque RGB 0,63,0", got)
	}

	f.r.SetBrightness(Full)
	page = f.r.pages[f.r.cur]
	if got := page[30*W]; got>>24 != 0 {
		t.Fatalf("restored outside pixel = %08x, want transparent", got)
	}
	if got := page[30*W+20]; got != 0xFF00FF00 {
		t.Fatalf("restored panel = %08x, want original opaque green", got)
	}
	if got := f.lo(wOvlBand); got != 31<<16|30 {
		t.Fatalf("restored band = %x, want panel lines only", got)
	}

	o.Hide()
	f.r.SetBrightness(Full / 4)
	if got := f.lo(wOvlCtl) & ovlEnable; got == 0 {
		t.Fatalf("paused video lost its veil with no panel: ctl %x", f.lo(wOvlCtl))
	}
	f.r.SetBrightness(Full)
	if f.lo(wOvlCtl)&ovlEnable != 0 {
		t.Fatal("empty overlay remained visible after waking")
	}
}

func TestBrightnessKeepsFramesDimmedAcrossMenuUpdates(t *testing.T) {
	f := newFake(t, false)
	f.r.Present(canvas(0x00FFFFFF))
	f.r.SetBrightness(Full / 4)
	if got := f.r.pages[f.r.cur][0]; got != 0xFF3F3F3F {
		t.Fatalf("dimmed menu frame = %08x, want quarter-bright white", got)
	}
	f.r.Present(canvas(0x0000FF00))
	if got := f.r.pages[f.r.cur][0]; got != 0xFF003F00 {
		t.Fatalf("updated dimmed menu frame = %08x, want quarter-bright green", got)
	}
	f.r.SetBrightness(Full)
	if got := f.r.pages[f.r.cur][0]; got != 0xFF00FF00 {
		t.Fatalf("restored menu frame = %08x, want full green", got)
	}
}
