package ui

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"plexcrt/internal/input"
	"plexcrt/internal/plex"
	"plexcrt/internal/ring"
)

func moreRow(t *testing.T, p *Playing, row string) {
	t.Helper()
	p.openMore()
	for i, item := range p.list.items {
		if item == row {
			p.list.cur = i
			return
		}
	}
	t.Fatalf("More has no %q row: %v", row, p.list.items)
}

func TestMoreAutoplayTogglesAndSaves(t *testing.T) {
	a := cropApp(t)
	p := playingCrop(a, 1.78)
	p.openMore()
	for _, item := range p.list.items {
		if item == moreAutoplay {
			t.Fatal("a movie has an Autoplay next row")
		}
	}
	p.item.Type = "episode"
	moreRow(t, p, moreAutoplay)
	if v := p.list.vals[p.list.cur]; v != "On" {
		t.Fatalf("autoplay = %q", v)
	}
	pressPlay(p, input.Enter)
	if !a.Cfg.NoAutoplay || p.list == nil || p.list.vals[p.list.cur] != "Off" {
		t.Fatalf("OK: no_autoplay %v, list %+v", a.Cfg.NoAutoplay, p.list)
	}
	if saved := LoadConfig(a.Cfg.path); !saved.NoAutoplay {
		t.Fatal("OK did not save Autoplay next")
	}
	pressPlay(p, input.Right)
	if a.Cfg.NoAutoplay || p.list.vals[p.list.cur] != "On" || a.runsOn(false) != true {
		t.Fatalf("Right: no_autoplay %v, list %+v", a.Cfg.NoAutoplay, p.list)
	}
	pressPlay(p, input.Left)
	if saved := LoadConfig(a.Cfg.path); !saved.NoAutoplay || a.runsOn(false) {
		t.Fatal("Left did not save Autoplay next off")
	}
}

func TestMoreBitrateSavesAndRestartsTranscodes(t *testing.T) {
	for _, direct := range []bool{false, true} {
		a := cropApp(t)
		a.Cfg.Bitrate = 8000
		var sent []string
		p := playingCrop(a, 1.78)
		p.send = func(line string) { sent = append(sent, line) }
		p.direct = func() bool { return direct }
		p.pos, p.dur = 600, 1800
		moreRow(t, p, moreBitrate)
		pressPlay(p, input.Left, input.Left)
		want := Bitrates[len(Bitrates)-3]
		if v := p.list.vals[p.list.cur]; !strings.HasPrefix(v, want.Label) || strings.Contains(v, "direct") != direct {
			t.Fatalf("direct %v: stepped value %q", direct, v)
		}
		if a.Cfg.Bitrate != 8000 || len(sent) != 0 {
			t.Fatalf("direct %v: stepping applied: %d %q", direct, a.Cfg.Bitrate, sent)
		}
		pressPlay(p, input.Enter)
		if a.Cfg.BitrateKbps() != want.Kbps || LoadConfig(a.Cfg.path).BitrateKbps() != want.Kbps {
			t.Fatalf("direct %v: bitrate %d not saved as %d", direct, a.Cfg.Bitrate, want.Kbps)
		}
		restart := "bitrate " + itoa(want.Kbps) + " 600"
		if direct && len(sent) != 0 || !direct && strings.Join(sent, ",") != restart {
			t.Fatalf("direct %v: commands %q", direct, sent)
		}
		if p.list != nil || p.pos != 600 {
			t.Fatalf("direct %v: list %+v at %v", direct, p.list, p.pos)
		}
	}
}

func TestMoreBitrateBackDropsTheStep(t *testing.T) {
	a := cropApp(t)
	a.Cfg.Bitrate = 8000
	p := playingCrop(a, 1.78)
	moreRow(t, p, moreBitrate)
	pressPlay(p, input.Left, input.Back)
	if a.Cfg.Bitrate != 8000 || p.list != nil {
		t.Fatalf("Back applied %d, list %+v", a.Cfg.Bitrate, p.list)
	}
}

func TestSessionBitrateRestartsWithTheNewCap(t *testing.T) {
	f := newPlayServer(t, playVideoTranscode)
	p := f.player(t)
	p.Kbps = func() int { return 8000 }
	status := p.Status
	var mu sync.Mutex
	var launches [][]string
	var child *exec.Cmd
	p.exec = func(_ string, args ...string) *exec.Cmd {
		cmd := exec.Command("sh", "-c", "printf 'state=playing\nposition=12\nduration=300\n' > '"+status+"'; exec sleep 30")
		mu.Lock()
		launches = append(launches, append([]string(nil), args...))
		child = cmd
		mu.Unlock()
		return cmd
	}
	s, err := p.Start(playItem(), 10)
	if err != nil {
		t.Fatal(err)
	}
	s.writeCommand = func(line string) {
		mu.Lock()
		defer mu.Unlock()
		if line == "stop" && child != nil && child.Process != nil {
			_ = child.Process.Kill()
		}
	}
	s.Send("bitrate 2000 x") // malformed: ignored
	s.Send("bitrate 2000 25")
	if s.Direct() {
		t.Fatal("the fixture is a transcode")
	}
	s.Stop()
	var caps []string
	for _, r := range f.requests("/video/:/transcode/universal/decision") {
		caps = append(caps, r.q.Get("maxVideoBitrate"))
	}
	if len(caps) < 2 || caps[0] != "8000" || caps[len(caps)-1] != "2000" {
		t.Fatalf("decision caps %v, want 8000 then 2000", caps)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(launches) != 2 || !hasArg(launches[1], "25") {
		t.Fatalf("launches %q", launches)
	}
}

func infoFixture(t *testing.T) (*App, *Playing) {
	a := cropApp(t)
	a.Cfg.Bitrate = 6000
	p := playingCrop(a, 1.78)
	p.item = &plex.Item{Type: "episode", Aspect: 1.78,
		Audio: []plex.Stream{{ID: "1", Title: "English AC3 5.1", Selected: true, Channels: 6}},
		Subs:  []plex.Stream{{ID: "3", Title: "English SRT", Selected: true, Text: true}}}
	p.direct = func() bool { return false }
	p.pos, p.dur = 600, 1800
	p.statusVals = map[string]string{"state": "playing", "width": "1280", "height": "720", "fps": "23.976",
		"video_bitrate": "4200000", "audio_codec": "ac3", "audio_channels_in": "6", "audio_boost": "150",
		"late": "3", "errors": "0", "refused": "0 none", "buffered_ms": "1500"}
	return a, p
}

func TestPlaybackInfoShowsWhatIsKnownAndRefreshes(t *testing.T) {
	_, p := infoFixture(t)
	moreRow(t, p, moreInfo)
	pressPlay(p, input.Enter)
	l := p.list
	if l == nil || l.kind != moreInfo || l.set != -1 {
		t.Fatalf("Playback info did not open: %+v", l)
	}
	want := map[string]string{"Source": "Transcode", "Video": "1280x720 H.264", "Frame rate": "23.976 fps",
		"Bitrate": "4.2 Mbps", "Bitrate cap": "6 Mbps", "Audio": "AC3 5.1", "Downmix": "Stereo", "Boost": "150%",
		"Subtitles": "English SRT", "Position": "10:00 / 30:00", "Late frames": "3", "Decode errors": "0",
		"Sound buffer": "1.5 s"}
	if len(l.items) != len(want) || len(l.vals) != len(l.items) {
		t.Fatalf("rows %v = %v", l.items, l.vals)
	}
	for i, item := range l.items {
		if l.vals[i] == "" || want[item] != l.vals[i] {
			t.Errorf("%s = %q, want %q", item, l.vals[i], want[item])
		}
	}
	p.statusVals = map[string]string{"late": "9", "errors": "1", "refused": "2 sps"}
	p.pos = 601
	p.refreshInfo(l.infoAt.Add(InfoRefresh / 2))
	if strings.Join(l.vals, ",") == "" || l.vals[len(l.vals)-1] == "2 sps" {
		t.Fatal("refreshed before a second")
	}
	l.loaded = true
	p.refreshInfo(l.infoAt.Add(InfoRefresh))
	got := map[string]string{}
	for i, item := range l.items {
		got[item] = l.vals[i]
	}
	if got["Late frames"] != "9" || got["Decode errors"] != "1" || got["Refused"] != "2 sps" || got["Position"] != "10:01 / 30:00" || l.loaded {
		t.Fatalf("refresh: %v loaded %v", got, l.loaded)
	}
	pressPlay(p, input.Enter)
	if p.list == nil || p.list.kind != "More" || p.list.items[p.list.cur] != moreInfo {
		t.Fatalf("OK did not go back to More: %+v", p.list)
	}
	pressPlay(p, input.Enter, input.Back)
	if p.list == nil || p.list.kind != "More" {
		t.Fatalf("Back did not go back to More: %+v", p.list)
	}
}

func TestPlaybackInfoDirectPlayHasNoCap(t *testing.T) {
	_, p := infoFixture(t)
	p.direct = func() bool { return true }
	p.openInfo(time.Now())
	for i, item := range p.list.items {
		if item == "Source" && p.list.vals[i] != "Direct play" || item == "Bitrate" && p.list.vals[i] != "4.2 Mbps" || item == "Bitrate cap" {
			t.Errorf("%s = %q", item, p.list.vals[i])
		}
	}
}

// Downmix boost steps in place with Left and Right, saved and sent to the
// worker at once, and stops at its ends; OK on it leaves More as it is.
func TestMoreBoostStepsInPlace(t *testing.T) {
	a := cropApp(t)
	var sent []string
	p := playingCrop(a, 1.78)
	p.send = func(line string) { sent = append(sent, line) }
	moreRow(t, p, "Downmix boost")
	if v := p.list.vals[p.list.cur]; v != "Large" {
		t.Fatalf("boost = %q", v)
	}
	pressPlay(p, input.Right) // at the end already
	if len(sent) != 0 || p.list == nil {
		t.Fatalf("Right past the end: %q, list %+v", sent, p.list)
	}
	pressPlay(p, input.Left)
	if p.list == nil || p.list.kind != "More" || p.list.vals[p.list.cur] != "Small" ||
		LoadConfig(a.Cfg.path).AudioBoostValue() != 175 || strings.Join(sent, ",") != "boost 175" {
		t.Fatalf("Left: list %+v, commands %q", p.list, sent)
	}
	pressPlay(p, input.Left, input.Left, input.Enter)
	if p.list == nil || p.list.kind != "More" || p.list.vals[p.list.cur] != "Off" || strings.Join(sent, ",") != "boost 175,boost 100" {
		t.Fatalf("Left to Off, then OK: list %+v, commands %q", p.list, sent)
	}
}

// A setting More cannot save is put back, sent nowhere, and the title
// says so.
func TestMoreValueSaveFailureRestores(t *testing.T) {
	for _, row := range []string{"Downmix boost", "Subtitle size", moreAutoplay} {
		a := cropApp(t)
		blocker := filepath.Join(t.TempDir(), "file")
		if err := os.WriteFile(blocker, nil, 0o644); err != nil {
			t.Fatal(err)
		}
		a.Cfg.path = filepath.Join(blocker, "settings.json") // a file as its folder: Save fails
		var sent []string
		p := playingCrop(a, 1.78)
		p.item.Type = "episode"
		p.send = func(line string) { sent = append(sent, line) }
		moreRow(t, p, row)
		before := p.list.vals[p.list.cur]
		boost, size, noAuto := a.Cfg.AudioBoostValue(), a.Cfg.SubtitleSizeValue(), a.Cfg.NoAutoplay
		pressPlay(p, input.Left)
		pressPlay(p, input.Right)
		if p.list == nil || p.list.hint != "Save failed" || p.list.vals[p.list.cur] != before || len(sent) != 0 ||
			a.Cfg.AudioBoostValue() != boost || a.Cfg.SubtitleSizeValue() != size || a.Cfg.NoAutoplay != noAuto {
			t.Fatalf("%s: list %+v, commands %q", row, p.list, sent)
		}
	}
}

// Subtitle size steps in place and stops at both ends.
func TestMoreSubtitleSizeStopsAtItsEnds(t *testing.T) {
	a := cropApp(t)
	p := playingCrop(a, 1.78)
	moreRow(t, p, "Subtitle size")
	pressPlay(p, input.Left) // at Normal already
	if a.Cfg.SubtitleSizeValue() != 100 || p.list.vals[p.list.cur] != "Normal" {
		t.Fatalf("Left past the end: %d", a.Cfg.SubtitleSizeValue())
	}
	pressPlay(p, input.Right, input.Right, input.Right, input.Enter)
	if p.list == nil || p.list.kind != "More" || a.Cfg.SubtitleSizeValue() != 200 ||
		LoadConfig(a.Cfg.path).SubtitleSizeValue() != 200 || p.list.vals[p.list.cur] != "Extra large" {
		t.Fatalf("Right to Extra large: %d, list %+v", a.Cfg.SubtitleSizeValue(), p.list)
	}
}

// Every row Left and Right step shows the arrows; Playback info and the
// track lists show none. At an end, the cursor row draws that arrow dim
// and the other rows leave it out.
func TestMoreArrowsShowWhereValuesStep(t *testing.T) {
	a := cropApp(t)
	a.Cfg.SubtitleSize = 200 // at its right end
	p := playingCrop(a, 1.78)
	p.item.Type = "episode"
	p.openMore()
	l := p.list
	l.cur = 0 // Crop, Off: at its left end
	for i, item := range l.items {
		left, right := p.listArrows(l, i)
		switch {
		case item == moreInfo:
			if left != arrowNone || right != arrowNone {
				t.Errorf("%s has arrows", item)
			}
		case item == "Crop":
			if left != arrowEnd || right != arrowOn {
				t.Errorf("Crop under the cursor at Off: %v %v", left, right)
			}
		case item == "Subtitle size":
			if left != arrowOn || right != arrowNone {
				t.Errorf("Subtitle size off the cursor at its end: %v %v", left, right)
			}
		default:
			if left == arrowNone && right == arrowNone {
				t.Errorf("%s has no arrows", item)
			}
		}
	}
	p.item.Audio = []plex.Stream{{ID: "1", Title: "One"}, {ID: "2", Title: "Two"}}
	p.openList("Audio")
	if left, right := p.listArrows(p.list, 0); left != arrowNone || right != arrowNone {
		t.Error("a track list has arrows")
	}
}

// Every More row is drawn whole, item and value with its arrows, with the
// longest values, from the list's margin on a 4:3 and a 16:9 raster, in
// both looks' fonts.
func TestMoreRowsAreNotCutShort(t *testing.T) {
	a := betaTestApp(t)
	longest := func(labels []string) string {
		l := ""
		for _, s := range labels {
			if len(s) > len(l) {
				l = s
			}
		}
		return l
	}
	var boosts, sizes []string
	for _, b := range AudioBoosts {
		boosts = append(boosts, b.Label)
	}
	for _, s := range SubtitleSizes {
		sizes = append(sizes, s.Label)
	}
	rows := map[string][]string{
		"Crop":          {"Off", "14:9", "Fill"},
		"Downmix boost": {longest(boosts)},
		"Subtitle size": {longest(sizes)},
		moreAutoplay:    {"On", "Off"},
		moreBitrate:     {Bitrates[0].Label, "8 Mbps (max)", Bitrates[0].Label + ", direct"},
	}
	for _, aspect := range []float64{1.33, 1.78} {
		p := playingCrop(a, aspect)
		p.item.Type = "episode"
		p.openMore()
		x := p.menuX()
		for i, item := range p.list.items {
			if _, _, ok := p.moreRange(p.list, i); !ok {
				continue
			}
			for _, v := range rows[item] {
				if gi, gv := listRowText(a.F.Body, x, item, v, listArrowsW); gi != item || gv != v {
					t.Errorf("%v: %q %q drawn as %q %q", aspect, item, v, gi, gv)
				}
				if strings.HasSuffix(v, ", direct") {
					continue // the block capitals are too wide for it: VCR cuts it
				}
				u := strings.ToUpper(v)
				if gi, gv := listRowText(vcrSmall, x, item, u, vcrArrowsW); gi != item || gv != u {
					t.Errorf("VCR %v: %q %q drawn as %q %q", aspect, item, u, gi, gv)
				}
			}
		}
	}
}

// The wider column still uploads More and Playback info whole, in rows
// the core can address.
func TestListColumnFitsTheRegion(t *testing.T) {
	_, p := infoFixture(t)
	p.openInfo(time.Now())
	maxRows := (ring.RegionSize / (OsdListW * 4)) &^ 1
	if h := p.list.height(); h >= maxRows || OsdListH >= maxRows {
		t.Fatalf("Playback info is %d rows, the region holds %d", h, maxRows)
	}
	if (OsdListW*4)&7 != 0 {
		t.Fatalf("a %d-byte row is not a multiple of 8", OsdListW*4)
	}
}
