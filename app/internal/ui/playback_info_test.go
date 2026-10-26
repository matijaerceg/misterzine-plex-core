package ui

import (
	"testing"
	"time"
)

func TestPlaybackInfoSeparatesStreamsAndMeasuredRates(t *testing.T) {
	_, p := infoFixture(t)
	p.streamModes = func() (string, string) { return "Original", "Transcoded" }
	p.conversionReason = func() string { return "Audio needs conversion" }
	p.statusVals["video_bitrate_recent"] = "3200000"
	p.statusVals["video_bitrate_average"] = "2800000"
	p.statusVals["output_width"], p.statusVals["output_height"], p.statusVals["output_interlaced"] = "720", "480", "1"
	p.openInfo(time.Now())
	rows := map[string]string{}
	for i, key := range p.list.items {
		rows[key] = p.list.vals[i]
	}
	for key, want := range map[string]string{"Video": "H.264 · Original", "Audio": "AC3 5.1 · Transcoded", "Video now": "3.2 Mbps", "Video avg": "2.8 Mbps", "Core output": "720x480i", "Conversion": "Audio needs conversion"} {
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
