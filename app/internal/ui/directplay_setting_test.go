package ui

import (
	"os"
	"os/exec"
	"strings"
	"sync"
	"testing"

	"plexcrt/internal/input"
	"plexcrt/internal/plex"
)

// Direct play off in the settings has an eligible file transcoded, with the
// setting as the reason.
func TestDirectPlayOffTranscodesAnEligibleFile(t *testing.T) {
	f := newPlayServer(t, playVideoDirect)
	p, launches := fallbackPlayer(t, f, nil, "10")
	p.DirectPlay = func() bool { return false }
	s, err := p.Start(playItem(), 10)
	if err != nil {
		t.Fatal(err)
	}
	if s.Direct() || s.ConversionReason() != "Direct play off" {
		t.Fatalf("direct %v, reason %q", s.Direct(), s.ConversionReason())
	}
	waitDone(t, s)
	if d := f.requests("/video/:/transcode/universal/decision"); len(d) != 1 || d[0].q.Get("maxVideoBitrate") != "6000" {
		t.Fatalf("decisions %+v", d)
	}
	if l := launches(); len(l) != 1 || hasArg(l[0], "--direct") {
		t.Fatalf("transcode launch: %v", l)
	}
	if log, _ := os.ReadFile(p.LogTo); strings.Contains(string(log), "not eligible") {
		t.Fatalf("the file is eligible; the log blames it: %s", log)
	}
	if conversionExplanation("Direct play off") != "Direct play is off in the settings" {
		t.Fatal("Playback info has no words for the reason")
	}
}

// The restart command decides the stream again under the settings as they
// are: a direct stream becomes a transcode once Direct play is off, and a
// transcode goes back to the file as stored once it is on.
func TestSessionRestartDecidesAgain(t *testing.T) {
	f := newPlayServer(t, playVideoDirect)
	p := f.player(t)
	p.Kbps = func() int { return 6000 }
	direct := true
	p.DirectPlay = func() bool { return direct }
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
	if !s.Direct() {
		t.Fatal("the fixture plays as stored")
	}
	s.Send("restart x")  // malformed: ignored
	s.Send("restart -1") // malformed: ignored
	direct = false
	s.Send("restart 25")
	if s.Direct() || s.ConversionReason() != "Direct play off" {
		t.Fatalf("after restart with direct play off: direct %v, reason %q", s.Direct(), s.ConversionReason())
	}
	direct = true
	s.Send("restart 40")
	if !s.Direct() {
		t.Fatal("after restart with direct play on: still a transcode")
	}
	s.Stop()
	if d := f.requests("/video/:/transcode/universal/decision"); len(d) != 1 || d[0].q.Get("offset") != "25" {
		t.Fatalf("decisions %+v, want one at 25", d)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(launches) != 3 || !hasArg(launches[0], "--direct") || hasArg(launches[1], "--direct") || !hasArg(launches[1], "25") || !hasArg(launches[2], "--direct") || !hasArg(launches[2], "40") {
		t.Fatalf("launches %q", launches)
	}
}

// More > Direct play toggles and saves the setting, and restarts the stream
// only where its decision would change.
func TestMoreDirectPlayTogglesSavesAndRestartsWhereItMatters(t *testing.T) {
	for _, direct := range []bool{true, false} {
		a := cropApp(t)
		var sent []string
		p := playingCrop(a, 1.78)
		p.send = func(line string) { sent = append(sent, line) }
		p.direct = func() bool { return direct }
		p.pos, p.dur = 600, 1800
		moreRow(t, p, moreDirect)
		if v := p.list.vals[p.list.cur]; v != "On" {
			t.Fatalf("direct %v: value %q", direct, v)
		}
		pressPlay(p, input.Right) // at the end: nothing to do
		if len(sent) != 0 || !a.Cfg.DirectPlay() {
			t.Fatalf("direct %v: Right at On: %q %v", direct, sent, a.Cfg.DirectPlay())
		}
		pressPlay(p, input.Left)
		if a.Cfg.DirectPlay() || LoadConfig(a.Cfg.path).DirectPlay() || p.list == nil || p.list.vals[p.list.cur] != "Off" {
			t.Fatalf("direct %v: Left: saved %v, list %+v", direct, a.Cfg.DirectPlay(), p.list)
		}
		// a direct stream starts over as a transcode; a transcode plays on
		if want := map[bool]string{true: "restart 600", false: ""}[direct]; strings.Join(sent, ",") != want {
			t.Fatalf("direct %v: commands %q, want %q", direct, sent, want)
		}
		sent = nil
		pressPlay(p, input.Enter) // OK toggles back on
		if !a.Cfg.DirectPlay() || !LoadConfig(a.Cfg.path).DirectPlay() || p.list.vals[p.list.cur] != "On" {
			t.Fatalf("direct %v: OK: saved %v, list %+v", direct, a.Cfg.DirectPlay(), p.list)
		}
		// a transcode starts over, which may make it the file as stored;
		// a direct stream (as p still reports) plays on
		if want := map[bool]string{true: "", false: "restart 600"}[direct]; strings.Join(sent, ",") != want {
			t.Fatalf("direct %v: OK commands %q, want %q", direct, sent, want)
		}
		if p.list == nil || p.pos != 600 {
			t.Fatalf("direct %v: list %+v at %v", direct, p.list, p.pos)
		}
	}
}

// An open More's Video bitrate row loses its ", direct" mark once the
// stream is a transcode, and gets it back.
func TestMoreBitrateRowFollowsTheStreamUnderAnOpenMore(t *testing.T) {
	a := cropApp(t)
	p := playingCrop(a, 1.78)
	direct := true
	p.direct = func() bool { return direct }
	moreRow(t, p, moreBitrate)
	if v := p.list.vals[p.list.cur]; !strings.HasSuffix(v, ", direct") {
		t.Fatalf("value %q", v)
	}
	p.list.loaded = true
	direct = false
	p.refreshMoreDirect()
	if v := p.list.vals[p.list.cur]; strings.Contains(v, "direct") || p.list.loaded {
		t.Fatalf("after the transcode: value %q, loaded %v", v, p.list.loaded)
	}
	direct = true
	p.refreshMoreDirect()
	if v := p.list.vals[p.list.cur]; !strings.HasSuffix(v, ", direct") {
		t.Fatalf("after direct play again: value %q", v)
	}
}

func TestOptionsDirectPlayToggle(t *testing.T) {
	a := cropApp(t)
	o := &Options{app: a}
	for _, it := range o.items() {
		if it.label != "Direct play" {
			continue
		}
		if !it.get() {
			t.Fatal("Direct play is off by default")
		}
		it.set(false)
		if a.Cfg.DirectPlay() || !a.Cfg.NoDirectPlay {
			t.Fatal("set(false) left direct play on")
		}
		return
	}
	t.Fatal("Options has no Direct play row")
}

func TestOptionsPlainHTTPToggle(t *testing.T) {
	a := cropApp(t)
	a.Cfg.Token = "account-token"
	a.Plex = &plex.Client{}
	o := &Options{app: a}
	for _, it := range o.items() {
		if it.label != "Plain HTTP connections" {
			continue
		}
		if !it.get() {
			t.Fatal("plain HTTP is off by default")
		}
		it.set(false)
		if a.Cfg.PlainHTTP() || !a.Cfg.NoPlainHTTP {
			t.Fatal("set(false) left plain HTTP on")
		}
		return
	}
	t.Fatal("Options has no Plain HTTP connections row")
}
