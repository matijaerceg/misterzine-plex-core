package plex

import (
	"context"
	"math"
	"strings"
	"testing"
)

func TestTranscodeSourceGeometry(t *testing.T) {
	base := PlaybackInfo{VideoDecision: "transcode", Part: MediaPart{Aspect: 1.33,
		Streams: []MediaStream{{Type: StreamVideo, Width: 720, Height: 480}}}}
	if got := base.TranscodeSourceGeometry(); got != "720,480,1.330000" {
		t.Fatalf("hint = %q", got)
	}
	for _, kind := range []string{"direct", "copy", "unknown decision", "missing aspect", "invalid aspect", "infinite aspect", "missing video", "missing dimensions"} {
		t.Run(kind, func(t *testing.T) {
			p := base
			switch kind {
			case "direct":
				p.Direct = true
			case "copy":
				p.VideoCopy = true
			case "unknown decision":
				p.VideoDecision = ""
			case "missing aspect":
				p.Part.Aspect = 0
			case "invalid aspect":
				p.Part.Aspect = math.NaN()
			case "infinite aspect":
				p.Part.Aspect = math.Inf(1)
			case "missing video":
				p.Part.Streams = nil
			case "missing dimensions":
				p.Part.Streams = []MediaStream{{Type: StreamVideo}}
			}
			if got := p.TranscodeSourceGeometry(); got != "" {
				t.Fatalf("unexpected hint %q", got)
			}
		})
	}
}

func TestTranscodeAspectComesFromSelectedVersion(t *testing.T) {
	f := newPlaybackServer(t)
	f.metadata = strings.Replace(versionsXML, `width="1280" height="720" aspectRatio="1.78"`,
		`width="1280" height="720" aspectRatio="1.33"`, 1)
	_, part, err := f.c.ItemAndPart(context.Background(), "101", "12")
	if err != nil {
		t.Fatal(err)
	}
	p := PlaybackInfo{VideoDecision: "transcode", Part: *part}
	if got := p.TranscodeSourceGeometry(); got != "1280,720,1.330000" {
		t.Fatalf("selected version hint = %q", got)
	}
}
