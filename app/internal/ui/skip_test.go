package ui

import (
	"os"
	"strings"
	"testing"
	"time"

	"plexcrt/internal/input"
	"plexcrt/internal/plex"
)

// skipPlaying is a playback at 600 s inside an intro marker from 590 s to
// 700 s, the picture up, with what it sends to the launcher recorded.
func skipPlaying(t *testing.T) (*Playing, *coreOSD, *[]string, time.Time) {
	t.Helper()
	p := waitPlaying(t)
	sent := &[]string{}
	p.send = func(s string) { *sent = append(*sent, s) }
	p.item.Markers = []plex.Marker{{Type: "intro", Start: 590, End: 700}}
	c := &coreOSD{}
	now := time.Now()
	p.framed(now, c)
	return p, c, sent, now
}

// tickAt runs one field at a time with the picture moving.
func tickAt(p *Playing, c *coreOSD, at time.Time) {
	p.framed(at, c)
	c.vsync()
	p.Tick(at, c, true)
}

func TestSkipButtonHoldsTwentySeconds(t *testing.T) {
	if SkipHold != 20*time.Second {
		t.Fatalf("SkipHold is %v, want 20 s", SkipHold)
	}
	p, c, _, now := skipPlaying(t)
	tickAt(p, c, now)
	if p.last != "skip|Skip intro" {
		t.Fatalf("no skip button over the intro: showing %q", p.last)
	}
	tickAt(p, c, now.Add(SkipHold-time.Second))
	if p.last != "skip|Skip intro" {
		t.Fatalf("the skip button went before its time: showing %q", p.last)
	}
	tickAt(p, c, now.Add(SkipHold))
	if p.last != "" || p.skipShown(now.Add(SkipHold)) {
		t.Fatalf("the skip button outlived its hold: showing %q", p.last)
	}
	// gone, OK opens the controls instead of skipping
	at := now.Add(SkipHold + 2*time.Second)
	if keyAt(p, c, input.Enter, at) || !p.visible || p.pos != 600 {
		t.Fatalf("OK after the button went: visible %v, at %v; want the controls at 600", p.visible, p.pos)
	}
}

func TestSkipButtonEndsBeforeTheMarker(t *testing.T) {
	p, c, _, now := skipPlaying(t)
	p.pos = 697
	tickAt(p, c, now)
	if !p.skipShown(now) {
		t.Fatal("no skip button three seconds before the marker's end")
	}
	p.pos = 698
	tickAt(p, c, now.Add(time.Second))
	if p.skipShown(now.Add(time.Second)) || p.last != "" {
		t.Fatalf("the skip button stayed into the marker's last two seconds: showing %q", p.last)
	}
}

func TestSkipButtonOKSkipsAndBackDismisses(t *testing.T) {
	p, c, sent, now := skipPlaying(t)
	tickAt(p, c, now)
	at := now.Add(10 * time.Second)
	if p.Key(input.Event{Key: input.Enter}, at) {
		t.Fatal("OK on the skip button stopped the playback")
	}
	if len(*sent) != 1 || (*sent)[0] != "seek 700" || p.visible || !p.skipOff {
		t.Fatalf("OK on the skip button: sent %q, controls %v, dismissed %v; want a seek to the marker's end", *sent, p.visible, p.skipOff)
	}
	p.Tick(at, c, false)
	if p.last != "" {
		t.Fatalf("the skip button stayed after OK: showing %q", p.last)
	}

	p, c, sent, now = skipPlaying(t)
	tickAt(p, c, now)
	if keyAt(p, c, input.Back, now.Add(time.Second)) {
		t.Fatal("Back on the skip button stopped the playback")
	}
	if len(*sent) != 0 || !p.skipOff || p.last != "" {
		t.Fatalf("Back on the skip button: sent %q, dismissed %v, showing %q", *sent, p.skipOff, p.last)
	}
}

func TestSkipButtonsTurnedOff(t *testing.T) {
	p, c, sent, now := skipPlaying(t)
	p.app.Cfg.NoSkipButtons = true
	for f := 0; f < 5; f++ {
		at := now.Add(time.Duration(f) * time.Second)
		tickAt(p, c, at)
		if p.last != "" || p.skipShown(at) {
			t.Fatalf("a skip button showed with the buttons off: %q", p.last)
		}
	}
	if keyAt(p, c, input.Enter, now.Add(5*time.Second)) || !p.visible || len(*sent) != 0 {
		t.Fatalf("OK over the intro with the buttons off: controls %v, sent %q; want the controls", p.visible, *sent)
	}

	p, c, _, now = skipPlaying(t)
	p.app.Cfg.NoSkipButtons = true
	tickAt(p, c, now)
	if !keyAt(p, c, input.Back, now.Add(time.Second)) {
		t.Fatal("Back over the intro with nothing on screen did not stop the playback")
	}
	if len(p.item.Markers) != 1 {
		t.Fatal("the markers were dropped with the buttons off")
	}
}

func TestSkipButtonsOptionDefaultsOnAndSaves(t *testing.T) {
	a := cropApp(t)
	o := NewOptions(a)
	autoplay, row := -1, -1
	for i, it := range o.items() {
		switch it.label {
		case "Autoplay next episode":
			autoplay = i
		case "Skip intro and credits buttons":
			row = i
		}
	}
	if row < 0 || row != autoplay+1 {
		t.Fatalf("the skip buttons row is at %d, want right after Autoplay next episode (%d)", row, autoplay)
	}
	if !o.items()[row].get() {
		t.Fatal("the skip buttons are off by default")
	}
	o.cur = row
	o.Key(input.Event{Key: input.Enter}, time.Now())
	if !a.Cfg.NoSkipButtons || o.items()[row].get() {
		t.Fatal("OK did not turn the skip buttons off")
	}
	data, err := os.ReadFile(a.Cfg.path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `"no_skip_buttons": true`) {
		t.Fatalf("the setting was not saved: %s", data)
	}
	if !LoadConfig(a.Cfg.path).NoSkipButtons {
		t.Fatal("the setting did not survive a reload")
	}
}
