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
	// section_in came from test launchers before it went to reports only: ignored
	want := DisplayCheck{INI: "MiSTer_alt_1.ini", VRR: "forced", VRRMode: 2, DVI: true,
		Overridden: []string{"video_mode"}}
	if !reflect.DeepEqual(d, want) {
		t.Fatalf("forced: %+v", d)
	}
	for _, s := range []string{"", "not json", `{"vrr": "auto", "vrr_mode": 1}`, `{"ini": "", "vrr": "unknown"}`} {
		if len(ParseDisplayCheck(s).Warnings(CoreOutput{})) != 0 {
			t.Fatalf("%q warns", s)
		}
	}
	// forced VRR: HDMI follows the core, in either family
	if ws := ParseDisplayCheck(`{"ini": "MiSTer.ini", "vrr": "forced", "vrr_mode": 2}`).Warnings(CoreOutput{PAL: true, Match: true}); len(ws) != 0 {
		t.Fatalf("VRR-only check: %+v", ws)
	}
}

func TestDisplayWarnings(t *testing.T) {
	ntsc, pal, match := CoreOutput{}, CoreOutput{PAL: true}, CoreOutput{Match: true}
	labels := func(d DisplayCheck, o CoreOutput) (out []string) {
		for _, w := range d.Warnings(o) {
			out = append(out, w.label+": "+w.value)
		}
		return out
	}
	for _, tc := range []struct {
		d    DisplayCheck
		o    CoreOutput
		want []string
	}{
		{DisplayCheck{INI: "MiSTer.ini", VRR: "off", HDMIHz: 60}, ntsc, nil},
		{DisplayCheck{INI: "MiSTer.ini", VRR: "off", HDMIHz: 59.94}, ntsc, nil},
		{DisplayCheck{INI: "MiSTer.ini", VRR: "off", HDMIHz: 50, HDMIMode: "video_mode=9"}, ntsc, []string{"HDMI refresh: 50 Hz"}},
		// the 576-line Output Modes run at 50 Hz
		{DisplayCheck{INI: "MiSTer.ini", VRR: "off", HDMIHz: 50, HDMIMode: "video_mode=9"}, pal, nil},
		{DisplayCheck{INI: "MiSTer.ini", VRR: "off", HDMIHz: 60}, pal, []string{"HDMI refresh: 60 Hz"}},
		// matching moves playback to the family a fixed rate misses
		{DisplayCheck{INI: "MiSTer.ini", VRR: "off", HDMIHz: 60}, match, []string{"HDMI refresh: 60 Hz"}},
		{DisplayCheck{INI: "MiSTer.ini", VRR: "off"}, match, nil},
		{DisplayCheck{INI: "MiSTer.ini", VRR: "unknown", DVI: true}, ntsc, []string{"HDMI sound: Off (DVI mode)"}},
		{DisplayCheck{INI: "MiSTer.ini", VRR: "off", HDMIHz: 75}, ntsc, []string{"HDMI refresh: 75 Hz"}},
		{DisplayCheck{INI: "MiSTer.ini", VRR: "off", DVI: true}, ntsc, []string{"HDMI sound: Off (DVI mode)"}},
		{DisplayCheck{INI: "MiSTer.ini", VRR: "off", Overridden: []string{"video_mode"}}, ntsc, []string{"INI section: Overridden"}},
		{DisplayCheck{INI: "MiSTer.ini", VRR: "forced", VRRMode: 2, DVI: true, Overridden: []string{"vrr_mode"}}, ntsc,
			[]string{"HDMI sound: Off (DVI mode)", "INI section: Overridden"}},
	} {
		if got := labels(tc.d, tc.o); !reflect.DeepEqual(got, tc.want) {
			t.Errorf("%+v %+v: %q, want %q", tc.d, tc.o, got, tc.want)
		}
	}
	text := func(w displayWarning) string {
		var parts []string
		for _, b := range w.blocks {
			parts = append(parts, b.text)
		}
		return strings.Join(parts, "\n")
	}
	has := func(name string, w displayWarning, want ...string) {
		t.Helper()
		for _, s := range want {
			if !strings.Contains(text(w), s) {
				t.Errorf("%s note lacks %q:\n%s", name, s, text(w))
			}
		}
	}
	has("refresh", DisplayCheck{INI: "MiSTer.ini", VRR: "auto", HDMIHz: 50, HDMIMode: "video_mode=9"}.Warnings(ntsc)[0],
		"HDMI runs at 50 Hz in MiSTer.ini (video_mode=9).", "Output Mode runs at 59.94 Hz", "unless your display uses VRR",
		"[MisterZine Plex Core]\nvideo_mode=8\nvideo_mode=8 is", "start Plex again")
	has("PAL refresh", DisplayCheck{INI: "MiSTer.ini", VRR: "off", HDMIHz: 60, HDMIMode: "video_mode=8"}.Warnings(pal)[0],
		"Output Mode runs at 50 Hz", "[MisterZine Plex Core]\nvideo_mode=9\nvideo_mode=9 is")
	// a PAL mode vsync_adjust cannot use: turning vsync_adjust off lets video_mode pick
	has("PAL mode", DisplayCheck{INI: "MiSTer.ini", VRR: "off", HDMIHz: 50, HDMIMode: "video_mode_pal=9", VsyncAdjust: 1}.Warnings(ntsc)[0],
		"(video_mode_pal=9).\n", "video_mode=8\nvsync_adjust=0\n")
	matched := DisplayCheck{INI: "MiSTer.ini", VRR: "off", HDMIHz: 60, HDMIMode: "video_mode=8"}.Warnings(match)[0]
	has("match", matched, "Refresh Rate Match", "[MisterZine Plex Core]\nvsync_adjust=1\nOr set Refresh Rate Match to Off")
	// matching off would leave a PAL Output Mode on a 60 Hz HDMI: not offered
	if s := text(DisplayCheck{INI: "MiSTer.ini", VRR: "off", HDMIHz: 60}.Warnings(CoreOutput{PAL: true, Match: true})[0]); strings.Contains(s, "Or set") {
		t.Errorf("PAL match note offers matching off:\n%s", s)
	}
	has("match without following", DisplayCheck{INI: "MiSTer.ini", VRR: "off", HDMIHz: 60, VsyncAdjust: 2}.Warnings(match)[0],
		"vsync_adjust is on, but MiSTer cannot follow the core")
	many := DisplayCheck{Overridden: []string{"a", "b", "c", "d", "e", "f"}}.Warnings(ntsc)[0]
	has("override", many, "your MiSTer INI changes what the [MisterZine Plex Core] section sets: a, b, c, d, and 2 more.",
		"Move the [MisterZine Plex Core] section to the end")
	all := DisplayCheck{INI: "MiSTer.ini", VRR: "auto", HDMIHz: 75, DVI: true, Overridden: []string{"a"}}
	for _, w := range all.Warnings(match) {
		if strings.Contains(text(w)+w.label+w.title, "Jellyfin") {
			t.Errorf("%s names Jellyfin:\n%s", w.label, text(w))
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

func TestOptionsShowWarningRows(t *testing.T) {
	a := cropApp(t)
	o := NewOptions(a)
	plain := len(o.items())
	a.Display = DisplayCheck{INI: "MiSTer.ini", VRR: "forced", VRRMode: 2}
	if n := len(o.items()); n != plain {
		t.Fatalf("forced VRR adds %d rows", n-plain)
	}
	a.Display = DisplayCheck{INI: "MiSTer.ini", VRR: "off", HDMIHz: 75}
	row := optionRow(o, "HDMI refresh")
	if row != optionRow(o, "Video crop")+1 {
		t.Fatalf("refresh row at %d, want right after Video crop", row)
	}
	if got := o.items()[row].val(); got != "75 Hz" {
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
	if !ok || note.w.title != "HDMI refresh" {
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
	a.Display = DisplayCheck{INI: "MiSTer_alt_1.ini", VRR: "auto", VRRMode: 1, HDMIHz: 50, HDMIMode: "video_mode=9", DVI: true,
		Overridden: []string{"video_mode", "vrr_mode"}}
	o := NewOptions(a)
	o.cur = optionRow(o, "HDMI refresh")
	draw := func(s Screen) *gfx.Canvas {
		c := gfx.NewCanvas(720, 480)
		for i := 0; i < 15; i++ { // text is cached off-thread: draw until it is there
			s.Draw(c, time.Now())
			time.Sleep(20 * time.Millisecond)
		}
		return c
	}
	shots := map[string]*gfx.Canvas{"options": draw(o)}
	for _, w := range a.Display.Warnings(CoreOutput{}) {
		shots[strings.ReplaceAll(strings.ToLower(w.label+" "+w.value), " ", "-")] = draw(NewDisplayNote(a, w))
	}
	for name, tc := range map[string]struct {
		d DisplayCheck
		o CoreOutput
	}{
		"pal-mode":         {DisplayCheck{INI: "MiSTer.ini", VRR: "off", HDMIHz: 50, HDMIMode: "video_mode_pal=9", VsyncAdjust: 1}, CoreOutput{}},
		"pal-output":       {DisplayCheck{INI: "MiSTer.ini", VRR: "off", HDMIHz: 60, HDMIMode: "video_mode=8"}, CoreOutput{PAL: true}},
		"match":            {DisplayCheck{INI: "MiSTer.ini", VRR: "auto", HDMIHz: 60, HDMIMode: "video_mode=8"}, CoreOutput{Match: true}},
		"match-no-follow":  {DisplayCheck{INI: "MiSTer_alt_1.ini", VRR: "off", HDMIHz: 60, HDMIMode: "video_mode_ntsc=8", VsyncAdjust: 2}, CoreOutput{Match: true}},
		"match-pal-output": {DisplayCheck{INI: "MiSTer.ini", VRR: "off", HDMIHz: 60, HDMIMode: "video_mode=8"}, CoreOutput{PAL: true, Match: true}},
	} {
		shots["refresh-"+name] = draw(NewDisplayNote(a, tc.d.Warnings(tc.o)[0]))
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
