package ui

import (
	"os/exec"
	"strings"
	"sync"
	"testing"
	"time"

	"plexcrt/internal/input"
	"plexcrt/internal/plex"
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
