package ui

import (
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"testing"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
)

func TestParseDisplayCheck(t *testing.T) {
	d := ParseDisplayCheck(`{"ini": "MiSTer_alt_1.ini", "vrr": "forced", "vrr_mode": 2}`)
	if d != (DisplayCheck{INI: "MiSTer_alt_1.ini", VRR: "forced", VRRMode: 2}) || !d.VRRForced() {
		t.Fatalf("forced: %+v", d)
	}
	for _, s := range []string{"", "not json", `{"vrr": "auto", "vrr_mode": 1}`, `{"ini": "", "vrr": "unknown"}`} {
		if ParseDisplayCheck(s).VRRForced() {
			t.Fatalf("%q reads as forced", s)
		}
	}
}

func optionRow(o *Options, label string) int {
	for i, it := range o.items() {
		if it.label == label {
			return i
		}
	}
	return -1
}

func TestOptionsShowForcedVRROnly(t *testing.T) {
	a := cropApp(t)
	o := NewOptions(a)
	if optionRow(o, "HDMI VRR") >= 0 {
		t.Fatal("VRR row without a forced setting")
	}
	a.Display = DisplayCheck{INI: "MiSTer.ini", VRR: "auto", VRRMode: 1}
	if optionRow(o, "HDMI VRR") >= 0 {
		t.Fatal("VRR row for the automatic setting")
	}
	a.Display = DisplayCheck{INI: "MiSTer.ini", VRR: "forced", VRRMode: 2}
	row := optionRow(o, "HDMI VRR")
	if row != optionRow(o, "Video crop")+1 {
		t.Fatalf("VRR row at %d, want right after Video crop", row)
	}
	if got := o.items()[row].val(); got != "Forced on" {
		t.Fatalf("value %q", got)
	}
	a.Push(o)
	o.cur = row
	now := time.Now()
	o.Key(input.Event{Key: input.Right}, now) // not a setting: nothing to step
	if _, ok := a.top().(*Options); !ok {
		t.Fatal("Right opened something")
	}
	o.Key(input.Event{Key: input.Enter}, now)
	note, ok := a.top().(*VRRNote)
	if !ok {
		t.Fatalf("OK opened %T", a.top())
	}
	note.Key(input.Event{Key: input.Enter}, now)
	if a.top() != Screen(o) {
		t.Fatalf("OK on the note left %T on top", a.top())
	}
	if optionRow(o, "Version") != len(o.items())-1 {
		t.Fatal("Version is no longer the last row")
	}
}

// Optional previews: DISPLAY_PREVIEW_DIR=dir go test -run DisplayPreview
func TestDisplayPreview(t *testing.T) {
	dir := os.Getenv("DISPLAY_PREVIEW_DIR")
	if dir == "" {
		t.Skip("set DISPLAY_PREVIEW_DIR to render previews")
	}
	if err := os.MkdirAll(dir, 0755); err != nil {
		t.Fatal(err)
	}
	a := cropApp(t)
	a.Display = DisplayCheck{INI: "MiSTer_alt_1.ini", VRR: "forced", VRRMode: 2}
	o := NewOptions(a)
	o.cur = optionRow(o, "HDMI VRR")
	draw := func(s Screen) *gfx.Canvas {
		c := gfx.NewCanvas(720, 480)
		for i := 0; i < 15; i++ { // text is cached off-thread: draw until it is there
			s.Draw(c, time.Now())
			time.Sleep(20 * time.Millisecond)
		}
		return c
	}
	for name, c := range map[string]*gfx.Canvas{"options": draw(o), "note": draw(NewVRRNote(a))} {
		// 720 source pixels occupy a 640-wide 4:3 display.
		out := image.NewRGBA(image.Rect(0, 0, 640, 480))
		for y := 0; y < 480; y++ {
			for x := 0; x < 640; x++ {
				p := (y*720 + x*720/640) * 4
				out.SetRGBA(x, y, color.RGBA{c.Pix[p+2], c.Pix[p+1], c.Pix[p], 255})
			}
		}
		file, err := os.Create(filepath.Join(dir, "vrr-"+name+".png"))
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
