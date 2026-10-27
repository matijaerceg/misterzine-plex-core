package ui

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"plexcrt/internal/plex"
)

// The film the playback fakes serve: rating key "item", one part "part" in
// Matroska, 300 s long, with a 720p H.264 video stream (playVideoDirect
// unless the test says otherwise), a stereo track the server has selected
// (index 1), a stereo one (index 2), a text and a picture subtitle.
const playMetadata = `<MediaContainer size="1"><Video ratingKey="item" key="/library/metadata/item" type="movie" title="Film" duration="300000">
<Media id="1" bitrate="%[2]d" videoFrameRate="24p" container="mkv"><Part id="part" key="/library/parts/part/1700000000/file.mkv" duration="300000" container="mkv">
<Stream id="10" streamType="1" index="0" %[1]s/>
<Stream id="11" streamType="2" codec="ac3" index="1" channels="6" selected="1"/>
<Stream id="12" streamType="2" codec="aac" index="2" channels="2"/>
<Stream id="13" streamType="3" codec="srt" key="/library/streams/13"/>
<Stream id="14" streamType="3" codec="pgs" index="3"/>
</Part></Media></Video></MediaContainer>`

// playVideoDirect is a video stream the core plays as stored (4 Mbit/s,
// under the 6 Mbit/s 720p limit); playVideoTranscode one it cannot.
const (
	playVideoDirect    = `codec="h264" profile="high" level="40" bitDepth="8" width="1280" height="720" frameRate="23.976" bitrate="4000" scanType="progressive" cabac="1"`
	playVideoTranscode = `codec="hevc" profile="main" bitDepth="10" width="1920" height="1080" frameRate="23.976" bitrate="9000"`
)

// playRequest is one request a playServer saw.
type playRequest struct {
	method, path string
	q            url.Values
}

// playServer is a fake Plex server for playback: the film above, a
// transcode decision that accepts, and every other path answered empty.
// It records each request; hooks let a test hold one up.
type playServer struct {
	mu       sync.Mutex
	reqs     []playRequest
	video    string // the video stream's attributes
	channels int
	pgs      string // extra attributes of the picture subtitle track (selected="1", say)
	decision string
	// onMetadata and onTimeline run inside those calls (the timeline's with
	// its state), before the answer.
	onMetadata func(n int)
	onTimeline func(state string)
	metadata   int
	srv        *httptest.Server
	client     *plex.Client
}

func newPlayServer(t *testing.T, video string) *playServer {
	t.Helper()
	f := &playServer{video: video, channels: 2}
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		f.reqs = append(f.reqs, playRequest{r.Method, r.URL.Path, r.URL.Query()})
		onMetadata, onTimeline := f.onMetadata, f.onTimeline
		f.mu.Unlock()
		if r.Header.Get("X-Plex-Token") != "synthetic-token" {
			t.Errorf("%s %s without the token header", r.Method, r.URL.Path)
		}
		switch r.URL.Path {
		case "/library/metadata/item":
			f.mu.Lock()
			f.metadata++
			n := f.metadata
			f.mu.Unlock()
			if onMetadata != nil {
				onMetadata(n)
			}
			page := strings.Replace(playMetadata, `channels="6"`, fmt.Sprintf(`channels="%d"`, f.channels), 1)
			page = strings.Replace(page, `codec="pgs" index="3"`, `codec="pgs" index="3" `+f.pgs, 1)
			_, _ = fmt.Fprintf(w, page, f.video, 4500)
		case "/video/:/transcode/universal/decision":
			if f.decision != "" && r.URL.Query().Get("directStream") == "1" {
				_, _ = w.Write([]byte(f.decision))
				return
			}
			_, _ = w.Write([]byte(`<MediaContainer transcodeDecisionCode="1001" transcodeDecisionText="Direct play not available; Conversion OK.">
<Video ratingKey="item"><Media width="1280" height="720" videoCodec="h264" audioCodec="aac"/></Video></MediaContainer>`))
		case "/:/timeline":
			if onTimeline != nil {
				onTimeline(r.URL.Query().Get("state"))
			}
			_, _ = w.Write([]byte(`<MediaContainer/>`))
		case "/video/:/transcode/universal/stop":
			w.WriteHeader(http.StatusNotFound)
		default:
			_, _ = w.Write([]byte(`<MediaContainer/>`))
		}
	}))
	t.Cleanup(f.srv.Close)
	f.client = plex.New(f.srv.URL, "synthetic-token", t.TempDir(), "device")
	return f
}

// requests is every request to a path, in order.
func (f *playServer) requests(path string) []playRequest {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []playRequest
	for _, r := range f.reqs {
		if r.path == path {
			out = append(out, r)
		}
	}
	return out
}

// events is the playback's server traffic as words: "timeline <state>",
// "decision", "stop", "select <query>" (a PUT on the part).
func (f *playServer) events() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []string
	for _, r := range f.reqs {
		switch {
		case r.path == "/:/timeline":
			out = append(out, "timeline "+r.q.Get("state"))
		case r.path == "/video/:/transcode/universal/decision":
			out = append(out, "decision")
		case r.path == "/video/:/transcode/universal/stop":
			out = append(out, "stop")
		case r.method == "PUT":
			q := r.q
			q.Del("allParts")
			out = append(out, "select "+q.Encode())
		}
	}
	return out
}

// player is a Player on the fake server with its files in a test folder.
func (f *playServer) player(t *testing.T) *Player {
	dir := t.TempDir()
	return &Player{Client: f.client, Binary: "jfplay", Fifo: dir + "/fifo", Status: dir + "/status", LogTo: dir + "/log"}
}

func playItem() *plex.Item { return &plex.Item{RatingKey: "item", PartID: "part"} }

func TestPlayerLaunchesAndReports(t *testing.T) {
	for _, direct := range []bool{true, false} {
		t.Run(map[bool]string{true: "direct", false: "transcode"}[direct], func(t *testing.T) {
			f := newPlayServer(t, map[bool]string{true: playVideoDirect, false: playVideoTranscode}[direct])
			if !direct {
				f.channels = 6
			}
			p := f.player(t)
			p.Kbps, p.Crop, p.Geometry = func() int { return 6000 }, func() Crop { return Crop14x9 }, func() string { return "12,8,10,6,940" }
			var args []string
			var cmd *exec.Cmd
			p.exec = func(_ string, a ...string) *exec.Cmd {
				args = append([]string(nil), a...)
				script := "printf 'state=playing\\nposition=121\\nduration=300\\n' > '" + p.Status + "'; echo synthetic-token >&2; sleep 1"
				cmd = exec.Command("sh", "-c", script)
				return cmd
			}
			s, err := p.Start(playItem(), 120)
			if err != nil {
				t.Fatal(err)
			}
			select {
			case <-s.Done:
			case <-time.After(4 * time.Second):
				t.Fatal("player did not exit")
			}
			joined := strings.Join(args, " ")
			if strings.Contains(joined, "synthetic-token") || strings.Contains(joined, "--headers") {
				t.Fatalf("the token is on the command line: %s", joined)
			}
			headers := ""
			for _, kv := range cmd.Env {
				if v, ok := strings.CutPrefix(kv, "JFPLAY_HEADERS="); ok {
					headers = v
				}
			}
			if headers != "X-Plex-Token: synthetic-token\r\nX-Plex-Client-Identifier: device\r\n" {
				t.Fatalf("JFPLAY_HEADERS = %q, want the token and the client identifier", headers)
			}
			if !strings.Contains(joined, "--analog-aspect 4") {
				t.Fatalf("missing crop argument: %s", joined)
			}
			if strings.Contains(joined, "--anti-twitter") {
				t.Fatalf("player overrides the core's OSD filter setting: %s", joined)
			}
			if !strings.Contains(joined, "--geometry 12,8,10,6,940") {
				t.Fatalf("missing saved calibration argument: %s", joined)
			}
			stream := args[len(args)-1]
			if strings.Contains(stream, "synthetic-token") {
				t.Fatalf("the stream URL carries the token: %s", stream)
			}
			decisions := f.requests("/video/:/transcode/universal/decision")
			if direct {
				if !strings.Contains(joined, "--base 0 --start-in-file 120") || stream != f.srv.URL+"/library/parts/part/1700000000/file.mkv" || !hasArg(args, "--direct") {
					t.Fatalf("direct args: %s", joined)
				}
				if !containsArgPair(args, "--audio", "1") || hasArg(args, "--surround-source") {
					t.Fatalf("direct audio: %s", joined)
				}
				if len(decisions) != 0 {
					t.Fatalf("a direct stream asked for a transcode decision")
				}
			} else {
				if !strings.Contains(joined, "--base 120") || strings.Contains(joined, "--start-in-file") || hasArg(args, "--direct") || hasArg(args, "--audio") {
					t.Fatalf("transcode args: %s", joined)
				}
				if !strings.HasPrefix(stream, f.srv.URL+"/video/:/transcode/universal/start.mkv?") || !hasArg(args, "--surround-source") {
					t.Fatalf("transcode stream: %s", joined)
				}
				if len(decisions) != 1 || decisions[0].q.Get("offset") != "120" || decisions[0].q.Get("maxVideoBitrate") != "6000" || decisions[0].q.Get("audioBoost") != "100" {
					t.Fatalf("decisions: %+v", decisions)
				}
			}
			logData, _ := os.ReadFile(p.LogTo)
			if strings.Contains(string(logData), "synthetic-token") {
				t.Fatal("token reached log")
			}
			want := []string{"timeline playing", "timeline stopped"}
			if !direct {
				want = []string{"decision", "timeline playing", "timeline stopped", "stop"}
			}
			if got := f.events(); strings.Join(got, ",") != strings.Join(want, ",") {
				t.Fatalf("server traffic %v, want %v", got, want)
			}
			stopped := f.requests("/:/timeline")[1].q
			if stopped.Get("ratingKey") != "item" || stopped.Get("time") != "121000" || stopped.Get("duration") != "300000" || stopped.Get("X-Plex-Session-Identifier") == "" {
				t.Fatalf("stopped report %v", stopped)
			}
		})
	}
}

// A transcode cannot seek inside its stream: a seek restarts it at the new
// offset on the same transcode session, keeping a held pause.
func TestTranscodeSeekRestartsOnItsSession(t *testing.T) {
	f := newPlayServer(t, playVideoTranscode)
	p := f.player(t)
	status := p.Status
	var cmdMu sync.Mutex
	var child *exec.Cmd
	var launches [][]string
	p.exec = func(_ string, args ...string) *exec.Cmd {
		state := "playing"
		if hasArg(args, "--hold") {
			state = "paused"
		}
		cmd := exec.Command("sh", "-c", "printf 'state="+state+"\\nposition=4937\\nduration=6192.256\\n' > '"+status+"'; exec sleep 30")
		cmdMu.Lock()
		launches = append(launches, append([]string(nil), args...))
		child = cmd
		cmdMu.Unlock()
		return cmd
	}
	s, err := p.Start(playItem(), 4937)
	if err != nil {
		t.Fatal(err)
	}
	s.writeCommand = func(line string) {
		if line == "toggle" {
			if err := os.WriteFile(status, []byte("state=playing\nposition=5100\nduration=6192.256\n"), 0o600); err != nil {
				t.Error(err)
			}
			return
		}
		if line != "stop" {
			return
		}
		cmdMu.Lock()
		defer cmdMu.Unlock()
		if child != nil && child.Process != nil {
			_ = child.Process.Kill()
		}
	}
	// Keep the worker's status stale after Pause to model its reporting lag.
	s.Send("pause")
	s.Send("seek 5100")
	if !s.state.Paused {
		t.Fatal("seek restart did not preserve paused state")
	}
	s.Send("toggle")
	if s.state.Paused {
		t.Fatal("toggle after held seek restart did not resume")
	}
	s.Stop()

	decisions := f.requests("/video/:/transcode/universal/decision")
	if len(decisions) != 2 || decisions[0].q.Get("offset") != "4937" || decisions[1].q.Get("offset") != "5100" {
		t.Fatalf("decisions = %+v", decisions)
	}
	if session := decisions[0].q.Get("session"); session == "" || decisions[1].q.Get("session") != session {
		t.Fatalf("the seek made a new transcode session: %q then %q", session, decisions[1].q.Get("session"))
	}
	cmdMu.Lock()
	defer cmdMu.Unlock()
	if len(launches) != 2 {
		t.Fatalf("player launches = %d, want 2", len(launches))
	}
	for i, args := range launches {
		if !containsArgPair(args, "--base", []string{"4937", "5100"}[i]) || hasArg(args, "--start-in-file") {
			t.Fatalf("transcode launch %d args = %#v", i, args)
		}
	}
	if hasArg(launches[0], "--hold") || !hasArg(launches[1], "--hold") {
		t.Fatalf("seek restart hold arguments = %#v", launches)
	}
	if stops := f.requests("/video/:/transcode/universal/stop"); len(stops) != 1 || stops[0].q.Get("session") != decisions[0].q.Get("session") {
		t.Fatalf("transcode stops = %+v", stops)
	}
}

func TestPlayerTrackChangeRequestsNewDirectStreamAndSelectsAudioIndex(t *testing.T) {
	f := newPlayServer(t, playVideoDirect)
	p := f.player(t)
	status := p.Status
	var cmdMu sync.Mutex
	var child *exec.Cmd
	var launches [][]string
	p.exec = func(_ string, args ...string) *exec.Cmd {
		state := "playing"
		if hasArg(args, "--hold") {
			state = "paused"
		}
		cmd := exec.Command("sh", "-c", "printf 'state="+state+"\\nposition=12\\nduration=300\\n' > '"+status+"'; exec sleep 30")
		cmdMu.Lock()
		launches = append(launches, append([]string(nil), args...))
		child = cmd
		cmdMu.Unlock()
		return cmd
	}
	// The first item snapshot has no tracks; NewPlaying can receive them later
	// from its asynchronous metadata request.
	s, err := p.Start(playItem(), 10)
	if err != nil {
		t.Fatal(err)
	}
	s.writeCommand = func(line string) {
		if line == "toggle" {
			if err := os.WriteFile(status, []byte("state=playing\nposition=25\nduration=300\n"), 0o600); err != nil {
				t.Error(err)
			}
			return
		}
		if line != "stop" {
			return
		}
		cmdMu.Lock()
		defer cmdMu.Unlock()
		if child != nil && child.Process != nil {
			_ = child.Process.Kill()
		}
	}
	// The status file still says playing when the pause and track change are
	// issued back to back.
	s.Send("pause")
	s.Send("tracks 12 -1 25")
	if !s.state.Paused {
		t.Fatal("track restart did not preserve paused state")
	}
	s.Send("toggle")
	if s.state.Paused {
		t.Fatal("toggle after held track restart did not resume")
	}
	s.Stop()

	// the start's one read serves the tracks and its PlaybackInfo; the
	// track change reads again
	if got := len(f.requests("/library/metadata/item")); got != 2 {
		t.Fatalf("metadata calls = %d, want 2", got)
	}
	// the stereo track is made the part's selection; nothing is decided
	var selects []string
	for _, e := range f.events() {
		if e == "decision" {
			t.Fatalf("a direct track change asked for a transcode: %v", f.events())
		}
		if strings.HasPrefix(e, "select ") {
			selects = append(selects, e)
		}
	}
	if strings.Join(selects, ",") != "select audioStreamID=12" {
		t.Fatalf("track selections %v", selects)
	}
	cmdMu.Lock()
	defer cmdMu.Unlock()
	if len(launches) != 2 {
		t.Fatalf("player launches = %d, want 2", len(launches))
	}
	// the server's stream IDs become the file's indexes: its selection
	// (index 1) first, then the stereo track (index 2)
	if !containsArgPair(launches[0], "--audio", "1") || !containsArgPair(launches[1], "--audio", "2") {
		t.Fatalf("direct audio arguments = %#v", launches)
	}
	if hasArg(launches[0], "--hold") || !hasArg(launches[1], "--hold") {
		t.Fatalf("track restart hold arguments = %#v", launches)
	}
}

func containsArgPair(args []string, name, value string) bool {
	for i := 0; i+1 < len(args); i++ {
		if args[i] == name && args[i+1] == value {
			return true
		}
	}
	return false
}

// A listing's item comes without its tracks. The session fetches them
// before its first PlaybackInfo, so the start asks for the subtitle the
// server has selected (burned in here) instead of none, which would have
// had PlaybackInfo deselect it: the next episode of a queue played without
// the subtitles the user saw chosen until a track change.
func TestPlayerStartFetchesTheTracksOfAListingItem(t *testing.T) {
	f := newPlayServer(t, playVideoDirect)
	f.pgs = `selected="1"`
	p := f.player(t)
	p.exec = func(_ string, _ ...string) *exec.Cmd {
		return exec.Command("sh", "-c", "printf 'state=playing\nposition=1\nduration=300\n' > '"+p.Status+"'; sleep 1")
	}
	s, err := p.Start(playItem(), 0)
	if err != nil {
		t.Fatal(err)
	}
	s.Stop()
	for _, e := range f.events() {
		if e == "timeline stopped" {
			break // the stopped report selects the burned track again
		}
		if strings.HasPrefix(e, "select subtitle") {
			t.Fatalf("the start changed the part's subtitle: %v", f.events())
		}
	}
	if got := len(f.requests("/library/metadata/item")); got != 1 {
		t.Fatalf("metadata reads = %d, want 1: the tracks and the decision share one", got)
	}
	decisions := f.requests("/video/:/transcode/universal/decision")
	if len(decisions) == 0 || decisions[0].q.Get("subtitles") != "burn" {
		t.Fatalf("no transcode burning the subtitle in: %v", f.events())
	}
	_, subs := s.Streams()
	if len(subs) != 2 || subs[0].Selected || !subs[1].Selected {
		t.Fatalf("session subtitle tracks = %+v, want the picture track selected", subs)
	}
	if s.state.SubtitleStream != "14" {
		t.Fatalf("reported subtitle = %q, want 14", s.state.SubtitleStream)
	}
}

// The user's saved choice for the show (Player.SavedStreams) is marked on
// the fetched tracks: here the stereo track and no subtitles, so the start
// selects that track and, with nothing to burn in, plays the file as
// stored (the server's subtitle selection is left for direct play).
func TestPlayerStartMarksTheSavedChoiceOnFetchedTracks(t *testing.T) {
	f := newPlayServer(t, playVideoDirect)
	f.pgs = `selected="1"`
	p := f.player(t)
	p.SavedStreams = func(it *plex.Item) (string, string) {
		if it.RatingKey != "item" {
			t.Errorf("saved choice asked for item %q", it.RatingKey)
		}
		return "12", "-1"
	}
	p.exec = func(_ string, _ ...string) *exec.Cmd {
		return exec.Command("sh", "-c", "printf 'state=playing\nposition=1\nduration=300\n' > '"+p.Status+"'; sleep 1")
	}
	s, err := p.Start(playItem(), 0)
	if err != nil {
		t.Fatal(err)
	}
	s.Stop()
	var selects []string
	for _, e := range f.events() {
		if e == "decision" {
			t.Fatalf("a direct stream without subtitles asked for a transcode: %v", f.events())
		}
		if strings.HasPrefix(e, "select ") {
			selects = append(selects, e)
		}
	}
	if got := strings.Join(selects, ","); got != "select audioStreamID=12" {
		t.Fatalf("track selections %q", got)
	}
	audio, subs := s.Streams()
	if len(audio) != 2 || audio[0].Selected || !audio[1].Selected || subs[0].Selected || subs[1].Selected {
		t.Fatalf("session tracks audio %+v subs %+v", audio, subs)
	}
}

func hasArg(args []string, want string) bool {
	for _, arg := range args {
		if arg == want {
			return true
		}
	}
	return false
}

func TestTrackRestartCommandCarriesSelectedStreamIDs(t *testing.T) {
	item := &plex.Item{
		Audio: []plex.Stream{{ID: "1"}, {ID: "4", Selected: true}},
		Subs:  []plex.Stream{{ID: "7"}},
	}
	if got := trackRestartCommand(item, 33); got != "tracks 4 -1 33" {
		t.Fatalf("track restart command = %q", got)
	}
}

func TestPlayerSeekCoalescingKeepsTrackChangeOrder(t *testing.T) {
	s := &Session{async: true, uiWake: make(chan struct{}, 1)}
	s.SendUI("seek 10")
	s.SendUI("tracks 4 -1 10")
	s.SendUI("seek 20")
	s.SendUI("seek 21")
	want := []string{"seek 10", "tracks 4 -1 10", "seek 21"}
	if strings.Join(s.uiQueue, "|") != strings.Join(want, "|") {
		t.Fatalf("queued commands = %#v, want %#v", s.uiQueue, want)
	}
}

// TestPlayerChildWait is a helper process, not a test: lifecyclePlayer's
// first worker, which ignores stop until it is killed.
func TestPlayerChildWait(t *testing.T) {
	if os.Getenv("PLEXCRT_PLAYER_HELPER") == "wait" {
		time.Sleep(time.Minute)
	}
}

// TestPlayerChildExit is a helper process, not a test: a worker that exits
// at once.
func TestPlayerChildExit(t *testing.T) {}

// lifecyclePlayer plays the film as stored; it counts PlaybackInfo calls
// (metadata fetches) and stopped reports, and notes whether a replacement
// worker was launched only after the first had been reaped.
func lifecyclePlayer(t *testing.T) (*Player, *atomic.Int32, *atomic.Int32, *atomic.Bool) {
	t.Helper()
	var playbackInfo, stopped atomic.Int32
	f := newPlayServer(t, playVideoDirect)
	f.onMetadata = func(int) { playbackInfo.Add(1) }
	f.onTimeline = func(state string) {
		if state == "stopped" {
			stopped.Add(1)
		}
	}
	p := f.player(t)
	// the first worker never answers stop: a short grace keeps the tests quick
	p.stopGrace = 100 * time.Millisecond
	var launches atomic.Int32
	// the player sets the worker's environment from its own: the helper
	// reads this one (only TestPlayerChildWait acts on it)
	t.Setenv("PLEXCRT_PLAYER_HELPER", "wait")
	var firstMu sync.Mutex
	var first *exec.Cmd
	var replacementAfterReap atomic.Bool
	p.exec = func(_ string, args ...string) *exec.Cmd {
		launch := launches.Add(1)
		testName := "TestPlayerChildExit"
		if launch == 1 {
			testName = "TestPlayerChildWait"
		}
		cmd := exec.Command(os.Args[0], "-test.run=^"+testName+"$")
		firstMu.Lock()
		if launch == 1 {
			first = cmd
		} else if first != nil && first.ProcessState != nil {
			replacementAfterReap.Store(true)
		}
		firstMu.Unlock()
		return cmd
	}
	return p, &playbackInfo, &stopped, &replacementAfterReap
}

func TestPlayerSeekWaitsForForcedKillAndReportsStoppedOnce(t *testing.T) {
	p, _, stopped, replacementAfterReap := lifecyclePlayer(t)
	s, err := p.Start(playItem(), 0)
	if err != nil {
		t.Fatal(err)
	}
	s.Send("seek 25")
	select {
	case <-s.Done:
	case <-time.After(5 * time.Second):
		t.Fatal("player did not finish after the replacement process exited")
	}
	if got := stopped.Load(); got != 1 {
		t.Fatalf("stopped reports = %d, want 1", got)
	}
	if !replacementAfterReap.Load() {
		t.Fatal("replacement process launched before the previous process was reaped")
	}
}

func TestPlayerConcurrentStopAndSeekReportsStoppedOnce(t *testing.T) {
	p, playbackInfo, stopped, _ := lifecyclePlayer(t)
	s, err := p.Start(playItem(), 0)
	if err != nil {
		t.Fatal(err)
	}
	start := make(chan struct{})
	var ops sync.WaitGroup
	ops.Add(2)
	go func() { defer ops.Done(); <-start; s.Send("seek 25") }()
	go func() { defer ops.Done(); <-start; s.Stop() }()
	close(start)
	done := make(chan struct{})
	go func() { ops.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("concurrent stop and seek did not finish")
	}
	select {
	case <-s.Done:
	case <-time.After(time.Second):
		t.Fatal("session did not finish")
	}
	s.Stop()
	s.Send("seek 40")
	if got := stopped.Load(); got != 1 {
		t.Fatalf("stopped reports = %d, want 1", got)
	}
	if got := playbackInfo.Load(); got != 1 {
		t.Fatalf("PlaybackInfo calls = %d, want 1", got)
	}
}

func TestPlayerStopReportsFinalPositionAfterGracefulExit(t *testing.T) {
	f := newPlayServer(t, playVideoDirect)
	dir := t.TempDir()
	fifo, status, ready := dir+"/fifo", dir+"/status", dir+"/ready"
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	p := &Player{Client: f.client, Binary: "jfplay", Fifo: fifo, Status: status, LogTo: dir + "/log"}
	p.exec = func(_ string, _ ...string) *exec.Cmd {
		script := fmt.Sprintf("printf 'state=playing\\nposition=10\\nduration=300\\n' > %s; exec 3<>%s; printf ready > %s; IFS= read -r line <&3; printf 'state=playing\\nposition=77\\nduration=300\\n' > %s", shellQuote(status), shellQuote(fifo), shellQuote(ready), shellQuote(status))
		return exec.Command("sh", "-c", script)
	}
	s, err := p.Start(playItem(), 0)
	if err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(time.Second)
	for {
		if _, err := os.Stat(ready); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("player helper did not open its FIFO")
		}
		time.Sleep(5 * time.Millisecond)
	}
	started := time.Now()
	s.Stop()
	if elapsed := time.Since(started); elapsed >= 2*time.Second {
		t.Fatalf("graceful stop took %s, want less than 2 seconds", elapsed)
	}
	var stoppedAt string
	for _, r := range f.requests("/:/timeline") {
		if r.q.Get("state") == "stopped" {
			stoppedAt = r.q.Get("time")
		}
	}
	if stoppedAt != "77000" {
		t.Fatalf("stopped position = %q ms, want 77000", stoppedAt)
	}
}

func TestPlayerToggleReportsIntendedStateWhenStatusUpdatesImmediately(t *testing.T) {
	f := newPlayServer(t, playVideoDirect)
	status := t.TempDir() + "/status"
	if err := os.WriteFile(status, []byte("state=playing\nposition=12\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	s := &Session{
		p:       &Player{Client: f.client, Status: status},
		client:  f.client,
		state:   plex.PlayState{RatingKey: "item", Position: 12},
		started: true,
		writeCommand: func(line string) {
			if line != "toggle" {
				t.Errorf("command = %q, want toggle", line)
			}
			if err := os.WriteFile(status, []byte("state=paused\nposition=12\n"), 0o600); err != nil {
				t.Error(err)
			}
		},
	}
	s.Send("toggle")
	if got := f.events(); strings.Join(got, ",") != "timeline paused" {
		t.Fatalf("progress report missed the intended paused state: %v", got)
	}
}

func TestPlayerStartAsyncCanBeCanceledDuringPlaybackInfo(t *testing.T) {
	entered := make(chan struct{})
	release := make(chan struct{})
	var launches atomic.Int32
	f := newPlayServer(t, playVideoDirect)
	f.onMetadata = func(int) {
		close(entered)
		<-release
	}
	defer close(release)
	p := f.player(t)
	p.exec = func(_ string, _ ...string) *exec.Cmd {
		launches.Add(1)
		return exec.Command("sh", "-c", "sleep 30")
	}
	started := time.Now()
	s, err := p.StartAsync(playItem(), 0)
	if err != nil {
		t.Fatal(err)
	}
	if elapsed := time.Since(started); elapsed > 100*time.Millisecond {
		t.Fatalf("StartAsync took %s; want an immediate return", elapsed)
	}
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("PlaybackInfo did not start in background")
	}
	s.StopUI()
	select {
	case err := <-s.Done:
		if err != nil {
			t.Fatalf("canceled startup returned %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("canceling startup did not finish promptly")
	}
	if got := launches.Load(); got != 0 {
		t.Fatalf("launched %d child processes after startup was canceled", got)
	}
}

// A session reports to the server it started on: signing in elsewhere
// during playback (the Player's client replaced) leaves its reports where
// they belong.
func TestPlayerSessionReportsToItsOwnServer(t *testing.T) {
	f, other := newPlayServer(t, playVideoDirect), newPlayServer(t, playVideoDirect)
	p := f.player(t)
	p.exec = func(_ string, _ ...string) *exec.Cmd {
		return exec.Command("sh", "-c", "printf 'state=playing\\nposition=12\\nduration=300\\n' > '"+p.Status+"'; sleep 0.5")
	}
	s, err := p.StartAsync(playItem(), 0)
	if err != nil {
		t.Fatal(err)
	}
	p.Client = other.client
	select {
	case <-s.Done:
	case <-time.After(4 * time.Second):
		t.Fatal("player did not exit")
	}
	select {
	case <-s.ReportsDone():
	case <-time.After(2 * time.Second):
		t.Fatal("the stopped report was not sent")
	}
	if got := f.events(); len(got) == 0 || got[len(got)-1] != "timeline stopped" {
		t.Fatalf("the session's server saw %v, want its stopped report last", got)
	}
	if got := other.requests("/:/timeline"); len(got) != 0 {
		t.Fatalf("the other server got the session's reports: %+v", got)
	}
}

// The next start's PlaybackInfo of the same part waits for the last
// session's stopped report (which selects a burned-in subtitle again), but
// not for long; a start of another part (the next episode) does not wait.
func TestPlayerStartAsyncWaitsForTheLastStoppedReport(t *testing.T) {
	for _, c := range []struct {
		name        string
		held, other bool
	}{{"sent", false, false}, {"held", true, false}, {"other part", true, true}} {
		t.Run(c.name, func(t *testing.T) {
			stopping := make(chan struct{})
			release := make(chan struct{})
			var once sync.Once
			var metadata atomic.Int32
			f := newPlayServer(t, playVideoDirect)
			f.onMetadata = func(int) { metadata.Add(1) }
			f.onTimeline = func(state string) {
				if state == "stopped" {
					once.Do(func() {
						close(stopping)
						<-release
					})
				}
			}
			var releaseOnce sync.Once
			free := func() { releaseOnce.Do(func() { close(release) }) }
			defer free()
			p := f.player(t)
			p.reportWait = 2 * time.Second
			if c.held && !c.other {
				p.reportWait = 200 * time.Millisecond
			}
			p.exec = func(_ string, _ ...string) *exec.Cmd {
				return exec.Command("sh", "-c", "printf 'state=playing\\nposition=12\\nduration=300\\n' > '"+p.Status+"'; sleep 0.2")
			}
			first, err := p.StartAsync(playItem(), 0)
			if err != nil {
				t.Fatal(err)
			}
			select {
			case <-stopping:
			case <-time.After(4 * time.Second):
				t.Fatal("the first session did not report stopped")
			}
			next := playItem()
			if c.other {
				next.PartID = "other-part"
			}
			asked := time.Now()
			second, err := p.StartAsync(next, 0)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(second.StopUI)
			switch {
			case c.other:
				// the report is held for longer than reportWait: another
				// part's start goes ahead without it
				waitUntil(t, "the second PlaybackInfo", func() bool { return metadata.Load() == 2 })
				if waited := time.Since(asked); waited >= p.reportWait {
					t.Fatalf("another part's start waited %v for the last stopped report", waited)
				}
				free()
			case c.held:
				// the report never comes: the start goes ahead after reportWait
				waitUntil(t, "the second PlaybackInfo", func() bool { return metadata.Load() == 2 })
				free()
			default:
				time.Sleep(300 * time.Millisecond)
				if got := metadata.Load(); got != 1 {
					t.Fatalf("PlaybackInfo calls before the stopped report = %d, want 1", got)
				}
				free()
				waitUntil(t, "the second PlaybackInfo", func() bool { return metadata.Load() == 2 })
			}
			<-first.ReportsDone()
			select {
			case <-second.Done:
			case <-time.After(4 * time.Second):
				t.Fatal("the second session did not finish")
			}
		})
	}
}

func TestPlayerSuppressesCanceledStartupOnlyAfterStopRequest(t *testing.T) {
	s := &Session{}
	wrapped := fmt.Errorf("PlaybackInfo failed: %w", context.Canceled)
	if got := s.suppressStopCancellation(wrapped); got != wrapped {
		t.Fatalf("unexpected cancellation without StopUI request: %v", got)
	}
	s.mu.Lock()
	s.stopRequested = true
	s.mu.Unlock()
	if got := s.suppressStopCancellation(wrapped); got != nil {
		t.Fatalf("cancellation after StopUI request = %v, want nil", got)
	}
	unrelated := fmt.Errorf("server rejected playback")
	if got := s.suppressStopCancellation(unrelated); got != unrelated {
		t.Fatalf("unrelated error after StopUI request = %v, want %v", got, unrelated)
	}
}

func TestPlayerImmediateSeekWaitsForInitialStartup(t *testing.T) {
	initialEntered := make(chan struct{})
	releaseInitial := make(chan struct{})
	var releaseOnce sync.Once
	release := func() { releaseOnce.Do(func() { close(releaseInitial) }) }
	var launches atomic.Int32
	f := newPlayServer(t, playVideoTranscode)
	f.onMetadata = func(n int) {
		if n == 1 {
			close(initialEntered)
			<-releaseInitial
		}
	}
	defer release()
	p := f.player(t)
	status := p.Status
	var childMu sync.Mutex
	var first, current *exec.Cmd
	var replacementReaped atomic.Bool
	p.exec = func(_ string, _ ...string) *exec.Cmd {
		cmd := exec.Command("sh", "-c", "printf 'state=playing\\nposition=12\\nduration=300\\n' > '"+status+"'; exec sleep 30")
		childMu.Lock()
		if launches.Add(1) == 1 {
			first = cmd
		} else if first != nil && first.ProcessState != nil {
			replacementReaped.Store(true)
		}
		current = cmd
		childMu.Unlock()
		return cmd
	}
	s, err := p.StartAsync(playItem(), 0)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.StopUI)
	s.writeCommand = func(line string) {
		if line != "stop" {
			return
		}
		childMu.Lock()
		cmd := current
		childMu.Unlock()
		if cmd != nil && cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
	}
	select {
	case <-initialEntered:
	case <-time.After(time.Second):
		t.Fatal("initial PlaybackInfo did not start")
	}
	s.SendUI("seek 25")
	time.Sleep(100 * time.Millisecond)
	if got := len(f.requests("/library/metadata/item")); got != 1 {
		t.Fatalf("PlaybackInfo calls before initial response = %d, want 1", got)
	}
	if got := launches.Load(); got != 0 {
		t.Fatalf("children launched before initial response = %d, want 0", got)
	}
	release()
	deadline := time.Now().Add(3 * time.Second)
	for (len(f.requests("/video/:/transcode/universal/decision")) < 2 || launches.Load() < 2) && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	// one transcode decision at start, one for the seek
	if got := f.requests("/video/:/transcode/universal/decision"); len(got) != 2 || got[1].q.Get("offset") != "25" {
		t.Fatalf("decisions = %+v, want initial start then seek restart", got)
	}
	if got := launches.Load(); got != 2 {
		t.Fatalf("child launches = %d, want exactly two serialized launches", got)
	}
	if !replacementReaped.Load() {
		t.Fatal("replacement launch happened before the initial child was reaped")
	}
	s.StopUI()
	select {
	case <-s.Done:
	case <-time.After(time.Second):
		t.Fatal("session did not stop after replacement launch")
	}
}

func TestPlayerUISeekAndStopDoNotWaitForDelayedReports(t *testing.T) {
	enteredReport := make(chan struct{})
	releaseReport := make(chan struct{})
	var reportEntered atomic.Bool
	f := newPlayServer(t, playVideoDirect)
	f.onTimeline = func(state string) {
		if state != "playing" {
			return
		}
		if reportEntered.CompareAndSwap(false, true) {
			close(enteredReport)
		}
		<-releaseReport
	}
	defer close(releaseReport)
	p := f.player(t)
	status := p.Status
	var launches atomic.Int32
	var stopCommands atomic.Int32
	var childMu sync.Mutex
	var child *exec.Cmd
	p.exec = func(_ string, _ ...string) *exec.Cmd {
		launches.Add(1)
		cmd := exec.Command("sh", "-c", "printf 'state=playing\\nposition=15\\nduration=300\\n' > '"+status+"'; exec sleep 30")
		childMu.Lock()
		child = cmd
		childMu.Unlock()
		return cmd
	}
	s, err := p.StartAsync(playItem(), 0)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.StopUI)
	s.writeCommand = func(line string) {
		if line != "stop" {
			return
		}
		stopCommands.Add(1)
		childMu.Lock()
		cmd := child
		childMu.Unlock()
		if cmd != nil && cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
	}
	select {
	case <-enteredReport:
	case <-time.After(time.Second):
		t.Fatal("playing report did not reach delayed endpoint")
	}
	s.SendUI("seek 25")
	deadline := time.Now().Add(time.Second)
	for launches.Load() < 2 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if got := launches.Load(); got < 2 {
		t.Fatalf("seek did not launch replacement while HTTP report was blocked (launches=%d, stop commands=%d)", got, stopCommands.Load())
	}
	if got := len(f.requests("/library/metadata/item")); got != 1 {
		t.Fatalf("direct seek PlaybackInfo calls = %d, want 1", got)
	}
	s.StopUI()
	select {
	case <-s.Done:
	case <-time.After(time.Second):
		t.Fatal("stop waited for the blocked reporting endpoint")
	}
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}
