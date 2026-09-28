package ui

import (
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
)

func TestParseDisplayCheck(t *testing.T) {
	d := ParseDisplayCheck(`{"ini": "MiSTer_alt_1.ini", "vrr": "forced", "vrr_mode": 2, "vsync_adjust": 0, "hdmi_hz": null,
		"hdmi_mode": "", "dvi": true, "overridden": ["video_mode"], "conditional": [], "section_in": "MiSTer.ini"}`)
	want := DisplayCheck{INI: "MiSTer_alt_1.ini", VRR: "forced", VRRMode: 2, DVI: true,
		Overridden: []string{"video_mode"}, SectionIn: "MiSTer.ini"}
	if !reflect.DeepEqual(d, want) || !d.VRRForced() {
		t.Fatalf("forced: %+v", d)
	}
	for _, s := range []string{"", "not json", `{"vrr": "auto", "vrr_mode": 1}`, `{"ini": "", "vrr": "unknown"}`} {
		if len(ParseDisplayCheck(s).Warnings()) != 0 {
			t.Fatalf("%q warns", s)
		}
	}
	// an older launcher's check: VRR only
	if ws := ParseDisplayCheck(`{"ini": "MiSTer.ini", "vrr": "forced", "vrr_mode": 2}`).Warnings(); len(ws) != 1 || ws[0].label != "HDMI VRR" {
		t.Fatalf("VRR-only check: %+v", ws)
	}
}

func TestDisplayWarnings(t *testing.T) {
	labels := func(d DisplayCheck) (out []string) {
		for _, w := range d.Warnings() {
			out = append(out, w.label+": "+w.value)
		}
		return out
	}
	for _, tc := range []struct {
		d    DisplayCheck
		want []string
	}{
		{DisplayCheck{INI: "MiSTer.ini", VRR: "off", HDMIHz: 60}, nil},
		{DisplayCheck{INI: "MiSTer.ini", VRR: "off", HDMIHz: 59.94}, nil},
		{DisplayCheck{INI: "MiSTer.ini", VRR: "off", HDMIHz: 50, HDMIMode: "video_mode=9"}, []string{"HDMI refresh: 50 Hz"}},
		{DisplayCheck{INI: "MiSTer.ini", VRR: "unknown", DVI: true}, []string{"HDMI sound: Off (DVI mode)"}},
		{DisplayCheck{INI: "MiSTer.ini", VRR: "off", HDMIHz: 75}, []string{"HDMI refresh: 75 Hz"}},
		{DisplayCheck{INI: "MiSTer.ini", VRR: "off", DVI: true}, []string{"HDMI sound: Off (DVI mode)"}},
		{DisplayCheck{INI: "MiSTer.ini", VRR: "off", Overridden: []string{"video_mode"}}, []string{"Plex INI section: Overridden"}},
		{DisplayCheck{INI: "MiSTer_alt_1.ini", VRR: "off", SectionIn: "MiSTer.ini"}, []string{"Plex INI section: In another INI"}},
		{DisplayCheck{INI: "MiSTer.ini", VRR: "forced", VRRMode: 2, DVI: true, Overridden: []string{"vrr_mode"}},
			[]string{"HDMI VRR: Forced on", "HDMI sound: Off (DVI mode)", "Plex INI section: Overridden"}},
	} {
		if got := labels(tc.d); !reflect.DeepEqual(got, tc.want) {
			t.Errorf("%+v: %q, want %q", tc.d, got, tc.want)
		}
	}
	text := func(w displayWarning) string {
		var parts []string
		for _, b := range w.blocks {
			parts = append(parts, b.text)
		}
		return strings.Join(parts, "\n")
	}
	refresh := DisplayCheck{INI: "MiSTer.ini", VRR: "auto", HDMIHz: 50, HDMIMode: "video_mode=9"}.Warnings()[0]
	for _, s := range []string{"HDMI runs at 50 Hz in MiSTer.ini (video_mode=9).", "unless your display uses VRR", "[MisterZine Plex Core]\nvideo_mode=8\nvideo_mode=8 is"} {
		if !strings.Contains(text(refresh), s) {
			t.Errorf("refresh note lacks %q:\n%s", s, text(refresh))
		}
	}
	// a PAL mode vsync_adjust cannot use: turning vsync_adjust off lets video_mode pick
	pal := DisplayCheck{INI: "MiSTer.ini", VRR: "off", HDMIHz: 50, HDMIMode: "video_mode_pal=9", VsyncAdjust: 1}.Warnings()[0]
	if s := "(video_mode_pal=9).\n"; !strings.Contains(text(pal), s) || !strings.Contains(text(pal), "video_mode=8\nvsync_adjust=0\n") {
		t.Errorf("PAL note:\n%s", text(pal))
	}
	many := DisplayCheck{Overridden: []string{"a", "b", "c", "d", "e", "f"}}.Warnings()[0]
	if !strings.Contains(text(many), "your MiSTer INI changes what the Plex section sets: a, b, c, d, and 2 more.") {
		t.Errorf("long override list:\n%s", text(many))
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
	note, ok := a.top().(*DisplayNote)
	if !ok || note.w.title != "HDMI VRR" {
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

func TestOptionsWarningRowsOpenTheirOwnNotes(t *testing.T) {
	a := cropApp(t)
	a.Display = DisplayCheck{INI: "MiSTer.ini", VRR: "off", HDMIHz: 50, HDMIMode: "video_mode=9", DVI: true}
	o := NewOptions(a)
	a.Push(o)
	crop := optionRow(o, "Video crop")
	for i, title := range []string{"HDMI refresh", "HDMI sound"} {
		o.cur = crop + 1 + i
		o.Key(input.Event{Key: input.Enter}, time.Now())
		note, ok := a.top().(*DisplayNote)
		if !ok || note.w.title != title {
			t.Fatalf("row %d opened %T %+v, want %s", o.cur, a.top(), note, title)
		}
		note.Back()
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
	a.Display = DisplayCheck{INI: "MiSTer_alt_1.ini", VRR: "forced", VRRMode: 2, DVI: true, Overridden: []string{"video_mode", "vrr_mode"}}
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
	shots := map[string]*gfx.Canvas{"options": draw(o)}
	for _, w := range a.Display.Warnings() {
		shots[strings.ReplaceAll(strings.ToLower(w.label+" "+w.value), " ", "-")] = draw(NewDisplayNote(a, w))
	}
	for _, d := range []DisplayCheck{
		{INI: "MiSTer.ini", VRR: "off", HDMIHz: 50, HDMIMode: "video_mode_pal=9", VsyncAdjust: 1},
		{INI: "MiSTer_alt_1.ini", VRR: "off", SectionIn: "MiSTer.ini"},
	} {
		w := d.Warnings()[0]
		shots[strings.ReplaceAll(strings.ToLower(w.label+" "+w.value), " ", "-")] = draw(NewDisplayNote(a, w))
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
		file, err := os.Create(filepath.Join(dir, "display-"+strings.NewReplacer("(", "", ")", "").Replace(name)+".png"))
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
