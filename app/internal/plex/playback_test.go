package plex

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
)

// metadataXML is a film with one version: a 720p High 4.0 H.264 file with a
// 5.1 and a stereo track, an external SRT the server serves by key, an
// embedded ASS it does not, and a PGS track.
const metadataXML = `<MediaContainer size="1"><Video ratingKey="101" key="/library/metadata/101" type="movie" title="Film" duration="5400000" viewOffset="60000">
<Media id="7" duration="5400000" bitrate="4800" width="1280" height="720" aspectRatio="1.78" videoCodec="h264" videoFrameRate="24p" container="mkv">
<Part id="9" key="/library/parts/9/1700000000/file.mkv" duration="5400000" container="mkv">
<Stream id="21" streamType="1" codec="h264" index="0" bitrate="4200" bitDepth="8" width="1280" height="720" frameRate="23.976" level="40" profile="high" scanType="progressive" cabac="1" displayTitle="720p (H.264)"/>
<Stream id="22" streamType="2" codec="dca" index="1" channels="6" selected="1" default="1" language="English" languageTag="en" displayTitle="English (DTS 5.1)"/>
<Stream id="23" streamType="2" codec="aac" index="2" channels="2" language="English" languageTag="en" displayTitle="English (AAC Stereo)"/>
<Stream id="24" streamType="3" codec="srt" key="/library/streams/24" language="English" languageTag="en" selected="1" displayTitle="English (SRT External)"/>
<Stream id="25" streamType="3" codec="ass" index="3" language="English" languageTag="en" displayTitle="English (ASS)"/>
<Stream id="26" streamType="3" codec="pgs" index="4" language="English" languageTag="en" displayTitle="English (PGS)"/>
</Part></Media></Video></MediaContainer>`

// playbackServer is a fake server: the film's metadata, a transcode
// decision it can be told to refuse, and every other path answered empty.
// It records each request as "METHOD path" with its query and headers.
type playbackServer struct {
	mu       sync.Mutex
	reqs     []*http.Request
	refuse   string // transcodeDecisionText of a refusal, "" for conversion OK
	metadata string
	decision string
	srv      *httptest.Server
	c        *Client
}

func newPlaybackServer(t *testing.T) *playbackServer {
	t.Helper()
	f := &playbackServer{metadata: metadataXML}
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		f.reqs = append(f.reqs, r)
		f.mu.Unlock()
		if r.Header.Get("X-Plex-Token") != "tok-test" {
			t.Errorf("%s %s without the token header", r.Method, r.URL.Path)
		}
		switch {
		case r.URL.Path == "/library/metadata/101":
			_, _ = w.Write([]byte(f.metadata))
		case r.URL.Path == "/video/:/transcode/universal/decision":
			if f.refuse != "" {
				_, _ = w.Write([]byte(`<MediaContainer transcodeDecisionCode="2000" transcodeDecisionText="` + f.refuse + `"/>`))
				return
			}
			if f.decision != "" {
				_, _ = w.Write([]byte(f.decision))
				return
			}
			_, _ = w.Write([]byte(`<MediaContainer transcodeDecisionCode="1001" transcodeDecisionText="Direct play not available; Conversion OK.">
<Video ratingKey="101"><Media width="1280" height="720" videoCodec="h264" audioCodec="aac"><Part><Stream streamType="2" channels="2"/></Part></Media></Video></MediaContainer>`))
		case r.URL.Path == "/video/:/transcode/universal/stop":
			w.WriteHeader(http.StatusNotFound)
		case r.URL.Path == "/library/streams/24":
			_, _ = w.Write([]byte("1\n00:00:01,000 --> 00:00:02,000\nHello\n"))
		default:
			_, _ = w.Write([]byte(`<MediaContainer/>`))
		}
	}))
	t.Cleanup(f.srv.Close)
	f.c = New(f.srv.URL, "tok-test", t.TempDir(), "client-test")
	return f
}

// paths is each request as "METHOD path", in order.
func (f *playbackServer) paths() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []string
	for _, r := range f.reqs {
		out = append(out, r.Method+" "+r.URL.Path)
	}
	return out
}

// last is the newest request to a path, nil for none.
func (f *playbackServer) last(path string) *http.Request {
	f.mu.Lock()
	defer f.mu.Unlock()
	for i := len(f.reqs) - 1; i >= 0; i-- {
		if f.reqs[i].URL.Path == path {
			return f.reqs[i]
		}
	}
	return nil
}

func TestMediaPartAndItemStreams(t *testing.T) {
	f := newPlaybackServer(t)
	part, err := f.c.MediaPart(context.Background(), "101", "")
	if err != nil {
		t.Fatal(err)
	}
	if part.ID != "9" || part.Key != "/library/parts/9/1700000000/file.mkv" || part.Container != "mkv" || part.Duration != 5400 || part.Bitrate != 4800 || part.FrameRateTag != "24p" {
		t.Fatalf("part %+v", part)
	}
	v := part.Video()
	if v == nil || v.Codec != "h264" || v.Profile != "high" || v.Level != 40 || v.BitDepth != 8 || v.Width != 1280 || v.Height != 720 || v.FrameRate != 23.976 || v.Bitrate != 4200 || v.CABAC != "1" || v.Index != 0 {
		t.Fatalf("video %+v", v)
	}
	if st := part.Stream("23"); st == nil || st.Index != 2 || st.Channels != 2 || st.Type != StreamAudio {
		t.Fatalf("stereo track %+v", st)
	}
	if !part.Surround("") || !part.Surround("22") || part.Surround("23") || part.Surround("24") || part.Surround("99") {
		t.Fatal("surround by selected and by ID")
	}
	if sel := part.selected(StreamSubtitle); sel == nil || sel.ID != "24" {
		t.Fatalf("selected subtitle %+v", sel)
	}
	item, err := f.c.Item("101")
	if err != nil {
		t.Fatal(err)
	}
	if len(item.Audio) != 2 || item.Audio[0].Channels != 6 || !item.Audio[0].Selected || item.Audio[1].Channels != 2 {
		t.Fatalf("item audio %+v", item.Audio)
	}
	if len(item.Subs) != 3 || !item.Subs[0].Text || item.Subs[1].Text || item.Subs[2].Text || !item.Subs[0].Selected {
		t.Fatalf("item subtitles %+v", item.Subs)
	}
	if item.PartID != "9" {
		t.Fatalf("part id %q", item.PartID)
	}
}

func TestMediaPartMissing(t *testing.T) {
	f := newPlaybackServer(t)
	f.metadata = `<MediaContainer size="1"><Video ratingKey="101" type="movie" title="Film"/></MediaContainer>`
	if _, err := f.c.MediaPart(context.Background(), "101", ""); err == nil {
		t.Fatal("an item without media gave a part")
	}
}

func videoPart(v MediaStream, total int) MediaPart {
	v.Type = StreamVideo
	return MediaPart{ID: "9", Key: "/library/parts/9/1/file.mkv", Bitrate: total, Streams: []MediaStream{v, {ID: "2", Type: StreamAudio, Index: 1, Channels: 2}}}
}

func TestDirectEligible(t *testing.T) {
	ok720 := MediaStream{Codec: "h264", Profile: "high", Level: 41, BitDepth: 8, Width: 1280, Height: 720, FrameRate: 23.976, Bitrate: 5000}
	ok480 := MediaStream{Codec: "h264", Profile: "main", Level: 31, BitDepth: 8, Width: 854, Height: 480, FrameRate: 59.94, Bitrate: 7500}
	with := func(base MediaStream, f func(*MediaStream)) MediaStream {
		f(&base)
		return base
	}
	cases := []struct {
		name string
		part MediaPart
		want bool
	}{
		{"720p high", videoPart(ok720, 0), true},
		{"narrow 722 lines", videoPart(with(ok720, func(v *MediaStream) { v.Width, v.Height, v.FrameRate = 968, 722, 29.97 }), 0), true},
		{"rounded block boundary", videoPart(with(ok720, func(v *MediaStream) { v.Width, v.Height, v.FrameRate = 1280, 721, 29.97 }), 0), false},
		{"narrow tall within budget", videoPart(with(ok720, func(v *MediaStream) { v.Width, v.Height, v.FrameRate = 960, 960, 29.97 }), 0), true},
		{"narrow tall over rate", videoPart(with(ok720, func(v *MediaStream) { v.Width, v.Height, v.FrameRate = 848, 1024, 60 }), 0), false},
		{"over block budget", videoPart(with(ok720, func(v *MediaStream) { v.Width, v.Height, v.FrameRate = 1200, 800, 24 }), 0), false},
		{"480p60 main", videoPart(ok480, 0), true},
		{"no probe data trusts the worker's check", MediaPart{ID: "9"}, true},
		{"unknown values pass", videoPart(MediaStream{Codec: "h264"}, 0), true},
		{"level as decimal", videoPart(with(ok720, func(v *MediaStream) { v.Level = 4.1 }), 0), true},
		{"720p bitrate over HD cap", videoPart(with(ok720, func(v *MediaStream) { v.Bitrate = 6500 }), 0), false},
		{"480p bitrate within SD cap", videoPart(with(ok480, func(v *MediaStream) { v.Bitrate = 8000 }), 0), true},
		{"480p bitrate over SD cap", videoPart(with(ok480, func(v *MediaStream) { v.Bitrate = 8100 }), 0), false},
		{"version bitrate stands in", videoPart(with(ok720, func(v *MediaStream) { v.Bitrate = 0 }), 7000), false},
		{"720p60", videoPart(with(ok720, func(v *MediaStream) { v.FrameRate = 59.94 }), 0), false},
		{"720p29.97", videoPart(with(ok720, func(v *MediaStream) { v.FrameRate = 29.97 }), 0), true},
		{"480p over 60", videoPart(with(ok480, func(v *MediaStream) { v.FrameRate = 120 }), 0), false},
		{"level 4.2", videoPart(with(ok720, func(v *MediaStream) { v.Level = 42 }), 0), false},
		{"10-bit", videoPart(with(ok720, func(v *MediaStream) { v.BitDepth = 10 }), 0), false},
		{"High 10 profile", videoPart(with(ok720, func(v *MediaStream) { v.Profile = "high 10" }), 0), false},
		{"constrained baseline", videoPart(with(ok480, func(v *MediaStream) { v.Profile = "constrained baseline" }), 0), false},
		{"1080p", videoPart(with(ok720, func(v *MediaStream) { v.Width, v.Height = 1920, 1080 }), 0), false},
		{"hevc", videoPart(with(ok720, func(v *MediaStream) { v.Codec = "hevc" }), 0), false},
		{"CAVLC", videoPart(with(ok720, func(v *MediaStream) { v.CABAC = "0" }), 0), false},
		{"interlaced is only a hint", videoPart(with(ok480, func(v *MediaStream) { v.ScanType = "interlaced"; v.FrameRate = 29.97 }), 0), true},
	}
	for _, c := range cases {
		got, why := DirectEligible(c.part, MaxVideoKbps)
		if got != c.want {
			t.Errorf("%s: eligible = %v (%s), want %v", c.name, got, why, c.want)
		}
		if !got && why == "" {
			t.Errorf("%s: no reason given", c.name)
		}
	}
	// a 60p version tag stands in for an unknown stream rate
	hd := videoPart(with(ok720, func(v *MediaStream) { v.FrameRate = 0 }), 0)
	hd.FrameRateTag = "60p"
	if ok, _ := DirectEligible(hd, 0); ok {
		t.Fatal("a 60p tag at 720p was eligible")
	}
}

// A file above the user's cap is transcoded to it, even one the core plays.
func TestDirectEligibleRespectsUserCap(t *testing.T) {
	sd := MediaStream{Codec: "h264", Profile: "main", Level: 30, BitDepth: 8, Width: 720, Height: 480, FrameRate: 29.97}
	for _, c := range []struct {
		name         string
		video, total int // kbit/s; 0 for unknown
		capKbps      int
		want         bool
	}{
		{"within the lowest step", 380, 0, 400, true},
		{"above the lowest step", 900, 0, 400, false},
		{"at the 1 Mbps step", 1000, 0, 1000, true},
		{"just above the 1 Mbps step", 1001, 0, 1000, false},
		{"version total stands in", 0, 2500, 2000, false},
		{"no cap is the core's", 7500, 0, 0, true},
	} {
		v := sd
		v.Bitrate = c.video
		got, why := DirectEligible(videoPart(v, c.total), c.capKbps)
		if got != c.want {
			t.Errorf("%s: eligible = %v (%s), want %v", c.name, got, why, c.want)
		}
		if !got && !strings.Contains(why, "chosen") {
			t.Errorf("%s: reason %q does not name the chosen cap", c.name, why)
		}
	}
}

func TestTranscodeSizeAndProfileExtra(t *testing.T) {
	for _, tc := range []struct{ kbps, w, h int }{
		{400, 640, 360}, {999, 640, 360}, {1000, 854, 480}, {2000, 854, 480},
		{3000, 1280, 720}, {8000, 1280, 720}, {0, 1280, 720}, {20000, 1280, 720},
	} {
		w, h := TranscodeSize(videoCap(tc.kbps))
		if w != tc.w || h != tc.h {
			t.Errorf("cap %d: %dx%d, want %dx%d", tc.kbps, w, h, tc.w, tc.h)
		}
	}
	extra := ProfileExtra(4000, 23.976)
	for _, want := range []string{
		"add-limitation(scope=videoAudioCodec&scopeName=aac&type=upperBound&name=audio.channels&value=2&isRequired=true)",
		"type=match&name=video.profile&list=high|main)",
		"name=video.level&value=41)", "name=video.bitDepth&value=8)",
		"name=video.width&value=1280)", "name=video.height&value=720)", "name=video.frameRate&value=60)",
		"add-transcode-target(type=videoProfile&context=streaming&protocol=http&container=mkv&videoCodec=h264&audioCodec=aac&replace=true)",
	} {
		if !strings.Contains(extra, want) {
			t.Errorf("profile extra lacks %q: %s", want, extra)
		}
	}
	if strings.Count(extra, "+") != 7 {
		t.Fatalf("profile lines are not joined with +: %s", extra)
	}
	// a 60 frames/s source is halved at 720p, kept at 480p
	if e := ProfileExtra(4000, 59.94); !strings.Contains(e, "name=video.frameRate&value=29.970)") {
		t.Fatalf("720p from 60p: %s", e)
	}
	if e := ProfileExtra(2000, 59.94); !strings.Contains(e, "name=video.frameRate&value=60)") || !strings.Contains(e, "name=video.width&value=854)") {
		t.Fatalf("480p from 60p: %s", e)
	}
}

func TestPlaybackInfoDirect(t *testing.T) {
	f := newPlaybackServer(t)
	f.metadata = strings.Replace(f.metadata, `channels="6"`, `channels="2"`, 1)
	info, err := f.c.PlaybackInfo(context.Background(), PlaybackRequest{RatingKey: "101", StartSeconds: 60, VideoKbps: 6000, SubtitleStream: "-1"})
	if err != nil {
		t.Fatal(err)
	}
	if !info.Direct || info.URL != f.srv.URL+"/library/parts/9/1700000000/file.mkv" || info.Session == "" || info.Part.ID != "9" {
		t.Fatalf("direct info %+v", info)
	}
	if strings.Contains(info.URL, "tok-test") {
		t.Fatal("token in the stream URL")
	}
	if got := strings.Join(f.paths(), ","); got != "GET /library/metadata/101" {
		t.Fatalf("a direct start made other requests: %s", got)
	}
	// another audio track is made the part's selection first; the one
	// already selected is not sent again
	if _, err := f.c.PlaybackInfo(context.Background(), PlaybackRequest{RatingKey: "101", AudioStream: "23", Session: "s"}); err != nil {
		t.Fatal(err)
	}
	put := f.last("/library/parts/9")
	if put == nil || put.Method != "PUT" || put.URL.Query().Get("audioStreamID") != "23" || put.URL.Query().Get("allParts") != "1" {
		t.Fatalf("audio selection %v", put)
	}
	n := len(f.paths())
	if _, err := f.c.PlaybackInfo(context.Background(), PlaybackRequest{RatingKey: "101", AudioStream: "22", Session: "s"}); err != nil {
		t.Fatal(err)
	}
	if got := f.paths()[n:]; strings.Join(got, ",") != "GET /library/metadata/101" {
		t.Fatalf("the selected track was selected again: %v", got)
	}
	if h := f.c.StreamHeaders(); h != "X-Plex-Token: tok-test\r\nX-Plex-Client-Identifier: client-test\r\n" {
		t.Fatalf("stream headers %q", h)
	}
}

func TestPlaybackInfoTranscode(t *testing.T) {
	f := newPlaybackServer(t)
	// above the 2 Mbit/s cap: a transcode at 854x480; the server's selected
	// SRT is one the app draws, so it is deselected rather than burned in
	info, err := f.c.PlaybackInfo(context.Background(), PlaybackRequest{RatingKey: "101", Session: "sess-1", StartSeconds: 61.9, VideoKbps: 2000, AudioBoost: 175, SubtitleSize: 150})
	if err != nil {
		t.Fatal(err)
	}
	if info.Direct || info.Session != "sess-1" || info.Width != 1280 || !strings.Contains(info.Decision, "Conversion OK") {
		t.Fatalf("transcode info %+v", info)
	}
	want := "GET /library/metadata/101,PUT /library/parts/9,GET /video/:/transcode/universal/decision"
	if got := strings.Join(f.paths(), ","); got != want {
		t.Fatalf("requests %s, want %s", got, want)
	}
	if put := f.last("/library/parts/9"); put.URL.Query().Get("subtitleStreamID") != "0" {
		t.Fatalf("drawn subtitle not deselected: %v", put.URL)
	}
	d := f.last("/video/:/transcode/universal/decision")
	q := d.URL.Query()
	for k, v := range map[string]string{
		"path": "/library/metadata/101", "mediaIndex": "0", "partIndex": "0", "protocol": "http", "directPlay": "0", "directStream": "0",
		"videoResolution": "854x480", "maxVideoBitrate": "2000", "videoQuality": "100", "audioBoost": "175", "subtitles": "burn", "subtitleSize": "150",
		"session": "sess-1", "X-Plex-Session-Identifier": "sess-1", "copyts": "1", "offset": "61", "fastSeek": "1",
		"location": "wan", "mediaBufferSize": "12288", "hasMDE": "1",
	} {
		if q.Get(k) != v {
			t.Errorf("decision %s = %q, want %q", k, q.Get(k), v)
		}
	}
	if !strings.Contains(q.Get("X-Plex-Client-Profile-Extra"), "name=video.width&value=854)") {
		t.Fatalf("profile extra %q", q.Get("X-Plex-Client-Profile-Extra"))
	}
	if d.Header.Get("X-Plex-Platform") != "Chrome" || d.Header.Get("X-Plex-Product") != "Plex Web" || d.Header.Get("X-Plex-Client-Identifier") != "client-test" {
		t.Fatalf("decision headers %v", d.Header)
	}
	u, err := url.Parse(info.URL)
	if err != nil {
		t.Fatal(err)
	}
	sq := u.Query()
	if u.Path != "/video/:/transcode/universal/start.mkv" || sq.Get("session") != "sess-1" || sq.Get("offset") != "61" || sq.Get("X-Plex-Platform") != "Chrome" || sq.Get("X-Plex-Client-Identifier") != "client-test" {
		t.Fatalf("start url %s", info.URL)
	}
	if sq.Has("X-Plex-Token") || strings.Contains(info.URL, "tok-test") {
		t.Fatal("token in the start URL")
	}
	// a forced transcode of an eligible file, with the PGS track burned in
	n := len(f.paths())
	info, err = f.c.PlaybackInfo(context.Background(), PlaybackRequest{RatingKey: "101", Session: "sess-1", VideoKbps: 6000, SubtitleStream: "26", ForceTranscode: true})
	if err != nil || info.Direct {
		t.Fatalf("forced transcode %+v %v", info, err)
	}
	if put := f.last("/library/parts/9"); put.URL.Query().Get("subtitleStreamID") != "26" {
		t.Fatalf("burned subtitle not selected: %v", put.URL)
	}
	if got := f.paths()[n:]; len(got) != 3 {
		t.Fatalf("forced transcode requests %v", got)
	}
	if q := f.last("/video/:/transcode/universal/decision").URL.Query(); q.Get("videoResolution") != "1280x720" || q.Get("maxVideoBitrate") != "6000" || q.Get("offset") != "0" || q.Get("audioBoost") != "100" || q.Get("subtitleSize") != "100" {
		t.Fatalf("forced decision query %v", q)
	}
}

func TestPlaybackInfoRefused(t *testing.T) {
	f := newPlaybackServer(t)
	f.refuse = "This file cannot be converted."
	_, err := f.c.PlaybackInfo(context.Background(), PlaybackRequest{RatingKey: "101", ForceTranscode: true})
	if err == nil || !strings.Contains(err.Error(), "This file cannot be converted.") {
		t.Fatalf("refusal error %v", err)
	}
}

func TestTimelineReports(t *testing.T) {
	f := newPlaybackServer(t)
	ctx := context.Background()
	st := PlayState{RatingKey: "101", PartID: "9", Session: "sess-1", Position: 61.5, Duration: 5400}
	if err := f.c.ReportStart(ctx, st); err != nil {
		t.Fatal(err)
	}
	q := f.last("/:/timeline").URL.Query()
	for k, v := range map[string]string{"ratingKey": "101", "key": "/library/metadata/101", "state": "playing", "time": "61500", "duration": "5400000",
		"X-Plex-Session-Identifier": "sess-1", "identifier": "com.plexapp.plugins.library", "hasMDE": "1", "continuing": "0"} {
		if q.Get(k) != v {
			t.Errorf("timeline %s = %q, want %q", k, q.Get(k), v)
		}
	}
	st.Paused = true
	if err := f.c.ReportProgress(ctx, st); err != nil {
		t.Fatal(err)
	}
	if q := f.last("/:/timeline").URL.Query(); q.Get("state") != "paused" {
		t.Fatalf("paused progress state %q", q.Get("state"))
	}
	// stopped near the end: the timeline, the transcode session ended (404
	// is fine), and the item marked watched
	n := len(f.paths())
	st.Paused, st.Position, st.Transcode = false, 5000, true
	if err := f.c.ReportStopped(ctx, st); err != nil {
		t.Fatal(err)
	}
	want := "GET /:/timeline,GET /video/:/transcode/universal/stop,GET /:/scrobble"
	if got := strings.Join(f.paths()[n:], ","); got != want {
		t.Fatalf("stopped requests %s, want %s", got, want)
	}
	if q := f.last("/video/:/transcode/universal/stop").URL.Query(); q.Get("session") != "sess-1" {
		t.Fatalf("stop session %v", q)
	}
	// a transcode with a subtitle chosen (one the app drew had it
	// deselected for the transcoder): the part's selection again after
	n = len(f.paths())
	st.Position, st.SubtitleStream = 100, "24"
	if err := f.c.ReportStopped(ctx, st); err != nil {
		t.Fatal(err)
	}
	want = "GET /:/timeline,GET /video/:/transcode/universal/stop,PUT /library/parts/9"
	if got := strings.Join(f.paths()[n:], ","); got != want {
		t.Fatalf("stopped requests %s, want %s", got, want)
	}
	if q := f.last("/library/parts/9").URL.Query(); q.Get("subtitleStreamID") != "24" {
		t.Fatalf("subtitle selection after the transcode %v", q)
	}
	st.SubtitleStream = "-1"
	// a direct stop short of the end: the timeline alone
	n = len(f.paths())
	st.Position, st.Transcode = 100, false
	if err := f.c.ReportStopped(ctx, st); err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(f.paths()[n:], ","); got != "GET /:/timeline" {
		t.Fatalf("direct stop requests %s", got)
	}
	if err := f.c.StopTranscode(ctx, ""); err != nil || len(f.paths()) != n+1 {
		t.Fatal("an empty session was stopped")
	}
}

func TestSubtitleText(t *testing.T) {
	f := newPlaybackServer(t)
	data, err := f.c.SubtitleText(context.Background(), "101", "9", "24")
	if err != nil || !strings.Contains(string(data), "Hello") {
		t.Fatalf("subtitle text %q %v", data, err)
	}
	r := f.last("/library/streams/24")
	if r.Method != "GET" || r.URL.Query().Get("format") != "srt" || r.URL.Query().Get("encoding") != "utf-8" {
		t.Fatalf("subtitle request %s", r.URL)
	}
}

func TestNewSession(t *testing.T) {
	a, b := NewSession(), NewSession()
	if len(a) != 36 || a == b || strings.Count(a, "-") != 4 || a[14] != '4' {
		t.Fatalf("session ids %s %s", a, b)
	}
}

// A container jfplay cannot open, or a sound it cannot decode, is
// transcoded: jfplay would exit 4, which does not fall back.
func TestDirectContainerAndAudio(t *testing.T) {
	ok := MediaStream{Codec: "h264", Profile: "high", Level: 40, BitDepth: 8, Width: 1280, Height: 720, FrameRate: 23.976, Bitrate: 4000}
	part := videoPart(ok, 0)
	part.Container = "avi"
	if got, why := DirectEligible(part, MaxVideoKbps); got || why == "" {
		t.Fatalf("an AVI offered as stored (%s)", why)
	}
	part.Container = "mkv"
	part.Streams[1].Codec, part.Streams[1].Selected = "truehd", true
	part.Streams = append(part.Streams, MediaStream{ID: "3", Type: StreamAudio, Index: 2, Codec: "aac", Channels: 2})
	if got, _ := DirectEligible(part, MaxVideoKbps); !got {
		t.Fatal("the video alone is eligible")
	}
	if got, why := DirectAudioEligible(part, ""); got || why != "audio truehd" {
		t.Fatalf("selected TrueHD: %v %q", got, why)
	}
	if got, _ := DirectAudioEligible(part, "3"); !got {
		t.Fatal("the AAC track chosen is decodable")
	}
}
