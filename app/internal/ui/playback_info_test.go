package ui

import (
	"plexcrt/internal/input"
	"testing"
	"time"
)

func TestPlaybackInfoSeparatesStreamsAndMeasuredRates(t *testing.T) {
	_, p := infoFixture(t)
	p.streamModes = func() (string, string) { return "Original", "Transcoded" }
	p.conversionReason = func() string { return "Audio compatibility" }
	p.statusVals["video_bitrate_recent"] = "3200000"
	p.statusVals["video_bitrate_average"] = "2800000"
	p.statusVals["output_width"], p.statusVals["output_height"], p.statusVals["output_interlaced"] = "720", "480", "1"
	p.openInfo(time.Now())
	rows := map[string]string{}
	for i, key := range p.list.items {
		rows[key] = p.list.vals[i]
	}
	for key, want := range map[string]string{"Video": "Unchanged (no server conversion)", "Audio": "Converted by server", "Video bitrate": "Now 3.2 / Avg 2.8 Mbps", "MiSTer output": "720x480i", "Conversion reason": "Audio format or channels need conversion"} {
		if rows[key] != want {
			t.Errorf("%s=%q, want %q", key, rows[key], want)
		}
	}
	for _, key := range []string{"Source", "Position", "Bitrate cap", "Video nominal"} {
		if _, ok := rows[key]; ok {
			t.Errorf("unwanted row %s", key)
		}
	}
}

func TestSessionStreamModes(t *testing.T) {
	for _, tc := range []struct {
		direct, copy                       bool
		video, audio, wantVideo, wantAudio string
	}{
		{true, false, "", "", "Original", "Original"},
		{false, true, "copy", "transcode", "Original", "Transcoded"},
		{false, false, "transcode", "copy", "Transcoded", "Original"},
		{false, false, "", "", "", ""},
	} {
		s := &Session{direct: tc.direct, videoCopy: tc.copy, videoDecision: tc.video, audioDecision: tc.audio}
		v, a := s.StreamModes()
		if v != tc.wantVideo || a != tc.wantAudio {
			t.Errorf("modes %q/%q want %q/%q", v, a, tc.wantVideo, tc.wantAudio)
		}
	}
}

func TestPlaybackInfoScrollHint(t *testing.T) {
	l := &listMode{items: make([]string, 9)}
	l.infoScrollHint()
	if l.hint != "" {
		t.Fatal("short info should not suggest scrolling")
	}
	l.items = make([]string, 16)
	l.infoScrollHint()
	if l.hint != "Up/Down" {
		t.Fatal("overflow must explain scrolling")
	}
}

func TestPlaybackMenuWraps(t *testing.T) {
	_, p := infoFixture(t)
	p.openMore()
	p.Key(input.Event{Key: input.Up}, time.Now())
	if p.list.cur != len(p.list.items)-1 {
		t.Fatal("Up must wrap to last row")
	}
	p.Key(input.Event{Key: input.Down}, time.Now())
	if p.list.cur != 0 || p.list.to != 0 {
		t.Fatal("Down must wrap to first row and restore title")
	}
}
