package ui

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"plexcrt/internal/input"
	"plexcrt/internal/plex"
)

func TestSurroundBoostMenuPersistsAndDoesNotRestart(t *testing.T) {
	a := cropApp(t)
	a.Cfg.AudioBoost = 100
	p := playingCrop(a, 4.0/3.0)
	var commands []string
	p.send = func(s string) { commands = append(commands, s) }
	pressPlay(p, input.Enter, input.Down, input.Enter, input.Down, input.Enter) // More, below Crop: Downmix boost, Small
	if strings.Join(commands, ",") != "boost 175" {
		t.Fatalf("commands = %q, want only a live boost", commands)
	}
	if LoadConfig(a.Cfg.path).AudioBoostValue() != 175 {
		t.Fatal("boost was not saved")
	}
	for _, row := range NewOptions(a).items() {
		if row.label == "Surround downmix boost" {
			if row.val() != "Small" {
				t.Fatalf("Options boost = %q", row.val())
			}
			return
		}
	}
	t.Fatal("boost missing from Options")
}

func TestWorkerSeekAcknowledgement(t *testing.T) {
	for _, outcome := range []string{"ready", "error", "cancel"} {
		t.Run(outcome, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "status")
			if err := os.WriteFile(path, []byte("seek_supported=1\nseek_id=0\nseek_state=ready\n"), 0600); err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			s := &Session{p: &Player{Status: path}, direct: true, ctx: ctx}
			s.writeCommand = func(command string) {
				if command != "seek 1 120.000" {
					t.Errorf("command = %q", command)
				}
				if outcome == "cancel" {
					cancel()
					return
				}
				if err := os.WriteFile(path, []byte("seek_supported=1\nseek_id=1\nseek_state="+outcome+"\n"), 0600); err != nil {
					t.Error(err)
				}
			}
			if got := s.tryWorkerSeek(120); got != (outcome == "ready") {
				t.Fatalf("accepted=%v for %s", got, outcome)
			}
		})
	}
}

func TestWorkerSeekRejectsStaleAcknowledgement(t *testing.T) {
	path := filepath.Join(t.TempDir(), "status")
	if err := os.WriteFile(path, []byte("seek_supported=1\nseek_id=0\nseek_state=ready\n"), 0600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	s := &Session{p: &Player{Status: path}, direct: true, ctx: ctx, writeCommand: func(string) {}}
	if s.tryWorkerSeek(120) {
		t.Fatal("accepted old seek acknowledgement")
	}
}

func TestWorkerSeekRequiresCapabilityAndFullTimeline(t *testing.T) {
	path := filepath.Join(t.TempDir(), "status")
	if err := os.WriteFile(path, []byte("seek_supported=1\n"), 0600); err != nil {
		t.Fatal(err)
	}
	s := &Session{p: &Player{Status: path}, writeCommand: func(string) { t.Fatal("sent seek to offset transcode") }}
	if s.tryWorkerSeek(120) {
		t.Fatal("accepted offset transcode")
	}
	s.direct = true
	_ = os.Remove(path)
	if s.tryWorkerSeek(120) {
		t.Fatal("accepted worker without capability")
	}
}

func TestBufferedIntervalRejectsMissingOrInvalidCoverage(t *testing.T) {
	for _, tc := range []struct {
		start, end         string
		wantStart, wantEnd float64
	}{
		{"10", "30", 10, 30}, {"-5", "999", 0, 100}, {"", "30", 0, 0},
		{"50", "20", 0, 0}, {"NaN", "20", 0, 0}, {"0", "+Inf", 0, 0},
	} {
		a, b := bufferedInterval(map[string]string{"buffered_valid": "1", "buffered_start": tc.start, "buffered_end": tc.end}, 100)
		if a != tc.wantStart || b != tc.wantEnd {
			t.Errorf("[%s,%s] => [%v,%v]", tc.start, tc.end, a, b)
		}
	}
	a, b := bufferedInterval(map[string]string{"buffered_valid": "1", "buffered_start": "10", "buffered_end": "30", "seek_state": "seeking"}, 100)
	if a != 0 || b != 0 {
		t.Fatal("old buffer retained during seek")
	}
	if a, b = bufferedInterval(map[string]string{"buffered_ms": "30000"}, 100); a != 0 || b != 0 {
		t.Fatal("audio-only buffer presented as video")
	}
}

func TestBufferedIntervalInvalidatesBothPanelCaches(t *testing.T) {
	p := &Playing{item: &plex.Item{Title: "Synthetic"}, dur: 100, pos: 10}
	panel, static := p.panelKey(), p.staticKey(false, false)
	p.bufferStart, p.bufferEnd = 10, 30
	if p.panelKey() == panel || p.staticKey(false, false) == static {
		t.Fatal("buffer change failed to invalidate drawing caches")
	}
	if start, end := p.bufferPixels(); start != SafeW/10 || end != 3*SafeW/10 {
		t.Fatalf("buffer pixels = %d..%d", start, end)
	}
}
