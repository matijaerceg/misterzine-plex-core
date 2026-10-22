package ui

import (
	"strings"
	"testing"

	"plexcrt/internal/plex"
)

// A low cap transcodes to a smaller picture: 480p below 3 Mbit/s, 360p below
// 1; from 3 Mbit/s up the core's 720p.
func TestTranscodeSizeFollowsCap(t *testing.T) {
	for _, tc := range []struct{ kbps, w, h int }{
		{400, 640, 360}, {999, 640, 360}, {1000, 854, 480}, {2000, 854, 480},
		{3000, 1280, 720}, {8000, 1280, 720},
	} {
		if w, h := transcodeSize(tc.kbps); w != tc.w || h != tc.h {
			t.Errorf("cap %d: %dx%d, want %dx%d", tc.kbps, w, h, tc.w, tc.h)
		}
	}
	// the lowest step offered gets the smallest picture
	if w, _ := transcodeSize(Bitrates[0].Kbps); w != 640 {
		t.Fatalf("lowest step %d kbit/s is %d wide", Bitrates[0].Kbps, w)
	}
}

// The client profile the server is sent carries the core's limits at the
// picture the cap gets; no cap, or one past the core's limit, is the core's.
func TestClientProfileFollowsCap(t *testing.T) {
	if MaxVideoKbps != 8000 {
		t.Fatalf("core limit %d kbit/s", MaxVideoKbps)
	}
	extra := plex.ProfileExtra(2000, 23.976)
	for _, want := range []string{"name=video.width&value=854", "name=video.height&value=480", "name=video.bitDepth&value=8", "name=audio.channels&value=2"} {
		if !strings.Contains(extra, want) {
			t.Errorf("profile for 2000 kbit/s lacks %q: %s", want, extra)
		}
	}
	for _, kbps := range []int{0, 20000} {
		if extra := plex.ProfileExtra(kbps, 23.976); !strings.Contains(extra, "name=video.height&value=720") {
			t.Errorf("cap %d: profile %s", kbps, extra)
		}
	}
}
