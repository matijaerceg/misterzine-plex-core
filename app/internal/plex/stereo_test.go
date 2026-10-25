package plex

import (
	"context"
	"net/url"
	"strings"
	"testing"
)

const stereoCopyDecision = `<MediaContainer transcodeDecisionCode="1001"><Video><Media width="968" height="722"><Part><Stream streamType="1" codec="h264" decision="copy"/><Stream streamType="2" codec="aac" channels="2" decision="transcode"/></Part></Media></Video></MediaContainer>`

func TestDirectAudioRequiresKnownMonoOrStereo(t *testing.T) {
	for _, tc := range []struct {
		codec    string
		channels int
		want     bool
	}{
		{"aac", 1, true}, {"aac", 2, true}, {"ac3", 2, true}, {"aac", 6, false}, {"eac3", 8, false}, {"aac", 0, false}, {"truehd", 2, false},
	} {
		part := MediaPart{Streams: []MediaStream{{Type: StreamAudio, Selected: true, Codec: tc.codec, Channels: tc.channels}}}
		got, _ := DirectAudioEligible(part, "")
		if got != tc.want {
			t.Errorf("%s/%d = %v", tc.codec, tc.channels, got)
		}
	}
}

func TestSurroundCopiesEligibleTallVideo(t *testing.T) {
	f := newPlaybackServer(t)
	f.metadata = strings.ReplaceAll(strings.ReplaceAll(f.metadata, `width="1280"`, `width="968"`), `height="720"`, `height="722"`)
	f.decision = stereoCopyDecision
	info, err := f.c.PlaybackInfo(context.Background(), PlaybackRequest{RatingKey: "101", VideoKbps: 6000, SubtitleStream: "-1", StartSeconds: 120})
	if err != nil {
		t.Fatal(err)
	}
	if info.Direct || !info.VideoCopy || info.Width != 968 || info.Height != 722 {
		t.Fatalf("wrong stream: %+v", info)
	}
	u, _ := url.Parse(info.URL)
	q := u.Query()
	if q.Get("directStream") != "1" || q.Has("maxVideoBitrate") || q.Has("videoResolution") || q.Get("offset") != "120" {
		t.Fatalf("audio-only query: %v", q)
	}
	if !strings.Contains(q.Get("X-Plex-Client-Profile-Extra"), "audio.channels&value=2") {
		t.Fatal("missing stereo limit")
	}
}

func TestDeclinedVideoCopyRetriesWithNormalVideoLimits(t *testing.T) {
	f := newPlaybackServer(t) // no copy decision: the server proposes encoding
	info, err := f.c.PlaybackInfo(context.Background(), PlaybackRequest{RatingKey: "101", VideoKbps: 6000, SubtitleStream: "-1"})
	if err != nil {
		t.Fatal(err)
	}
	if info.Direct || info.VideoCopy {
		t.Fatal("uncapped encode accepted as copy")
	}
	q := f.last("/video/:/transcode/universal/decision").URL.Query()
	if q.Get("directStream") != "0" || q.Get("maxVideoBitrate") != "6000" || q.Get("videoResolution") != "1280x720" {
		t.Fatalf("unbounded fallback: %v", q)
	}
	n := 0
	for _, p := range f.paths() {
		if p == "GET /video/:/transcode/universal/decision" {
			n++
		}
	}
	if n != 2 {
		t.Fatalf("decisions %d", n)
	}
}

func TestSurroundCannotBypassVideoCapOrForcedTranscode(t *testing.T) {
	for _, r := range []PlaybackRequest{{RatingKey: "101", VideoKbps: 2000, SubtitleStream: "-1"}, {RatingKey: "101", VideoKbps: 6000, SubtitleStream: "-1", ForceTranscode: true}, {RatingKey: "101", VideoKbps: 6000, SubtitleStream: "26"}} {
		f := newPlaybackServer(t)
		info, err := f.c.PlaybackInfo(context.Background(), r)
		if err != nil {
			t.Fatal(err)
		}
		if info.Direct || info.VideoCopy {
			t.Fatal("unsafe video copy")
		}
		if q := f.last("/video/:/transcode/universal/decision").URL.Query(); q.Get("directStream") != "0" || q.Get("maxVideoBitrate") == "" {
			t.Fatalf("unsafe query: %v", q)
		}
	}
}

func TestServerSurroundOutputIsRejected(t *testing.T) {
	f := newPlaybackServer(t)
	f.decision = strings.Replace(stereoCopyDecision, `channels="2"`, `channels="6"`, 1)
	if _, err := f.c.PlaybackInfo(context.Background(), PlaybackRequest{RatingKey: "101", VideoKbps: 6000, SubtitleStream: "-1"}); err == nil {
		t.Fatal("surround server output accepted")
	}
}
