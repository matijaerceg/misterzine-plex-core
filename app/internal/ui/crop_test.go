package ui

import (
	"io"
	"log"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"plexcrt/internal/input"
	"plexcrt/internal/plex"
)

func TestCropNamesAndCoreValues(t *testing.T) {
	for _, tc := range []struct {
		crop   Crop
		valid  Crop
		label  string
		aspect int
	}{{"", CropOff, "Off", 2}, {CropOff, CropOff, "Off", 2}, {Crop14x9, Crop14x9, "14:9", 4}, {CropFill, CropFill, "Fill", 3}} {
		if tc.crop.valid() != tc.valid || tc.crop.Label() != tc.label || tc.crop.analogAspect() != tc.aspect {
			t.Errorf("%q: valid %q, label %q, aspect %d", tc.crop, tc.crop.valid(), tc.crop.Label(), tc.crop.analogAspect())
		}
	}
	if len(Crops) != 3 {
		t.Fatalf("got %d crop choices", len(Crops))
	}
}

func cropApp(t *testing.T) *App {
	t.Helper()
	a := New(nil, nil, &Player{}, log.New(io.Discard, "", 0))
	a.Cfg = LoadConfig(filepath.Join(t.TempDir(), "settings.json"))
	return a
}

func TestOptionsCropStepsAndSaves(t *testing.T) {
	a := cropApp(t)
	o := NewOptions(a)
	row := -1
	for i, it := range o.items() {
		if it.label == "Video crop" {
			row = i
		}
	}
	if row < 0 {
		t.Fatal("no Video crop row")
	}
	o.cur = row
	o.Key(input.Event{Key: input.Right}, time.Now())
	if got := o.items()[row].val(); got != "14:9" {
		t.Fatalf("crop = %q", got)
	}
	o.Key(input.Event{Key: input.Enter}, time.Now())
	a.Cfg.Flush()
	if saved := LoadConfig(a.Cfg.path); saved.Crop != Crop14x9 {
		t.Fatalf("saved %q", saved.Crop)
	}
}

func playingCrop(a *App, aspect float64) *Playing {
	p := &Playing{app: a, item: &plex.Item{Title: "Film", Aspect: aspect}, send: func(string) {}, visible: true}
	for i, button := range osdButtons {
		if button == "More" {
			p.focus = i
		}
	}
	return p
}

func pressPlay(p *Playing, keys ...input.Key) {
	for _, key := range keys {
		p.Key(input.Event{Key: key}, time.Now())
	}
}

func TestPlaybackMenuChangesCoreAspectForThisPlayback(t *testing.T) {
	a := cropApp(t)
	a.Cfg.Crop = CropOff
	a.crop = a.Cfg.Crop.valid()
	var sent []string
	p := playingCrop(a, 1.78)
	p.send = func(line string) { sent = append(sent, line) }
	pressPlay(p, input.Enter)
	if p.list == nil || p.list.kind != "More" || p.list.vals[0] != "Off" {
		t.Fatalf("More did not show crop: %+v", p.list)
	}
	pressPlay(p, input.Enter, input.Down, input.Enter)
	if a.crop != Crop14x9 || strings.Join(sent, ",") != "aspect 4" {
		t.Fatalf("14:9 crop %q, commands %q", a.crop, sent)
	}
	pressPlay(p, input.Enter, input.Enter, input.Down, input.Enter)
	if p.list != nil || a.crop != CropFill || strings.Join(sent, ",") != "aspect 4,aspect 3" {
		t.Fatalf("crop %q, commands %q, list %+v", a.crop, sent, p.list)
	}
	if a.Cfg.Crop != CropOff {
		t.Fatalf("playback menu changed saved default to %q", a.Cfg.Crop)
	}
	pressPlay(p, input.Enter, input.Enter)
	if p.list == nil || p.list.kind != "Crop" || p.list.set != 2 {
		t.Fatalf("reopened crop choices: %+v", p.list)
	}
	pressPlay(p, input.Back)
	if p.list == nil || p.list.kind != "More" || p.list.vals[0] != "Fill" {
		t.Fatalf("Back did not return to More: %+v", p.list)
	}
}

func TestCropMenuShowsForEveryPicture(t *testing.T) {
	a := cropApp(t)
	for _, tc := range []struct {
		aspect float64
		want   bool
	}{{0, true}, {1.33, true}, {4.0 / 3.0, true}, {1.78, true}, {2.39, true}} {
		p := playingCrop(a, tc.aspect)
		p.openMore()
		got := p.list != nil && len(p.list.items) > 0 && p.list.items[0] == "Crop"
		if got != tc.want {
			t.Errorf("aspect %v: crop menu %v", tc.aspect, got)
		}
		more := len(osdButtons) - 1
		if dimmed := p.dimmed(more); dimmed {
			t.Errorf("aspect %v: More dimmed %v", tc.aspect, dimmed)
		}
	}
}
