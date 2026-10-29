package ui

import (
	"errors"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"plexcrt/internal/plex"
)

// Which files play as stored (plex.DirectEligible, its limits and the user's
// cap) is tested in internal/plex; these tests cover what the session does
// with the answer.

func TestWorkerNeedsTranscodeCodes(t *testing.T) {
	for code, want := range map[int]bool{0: false, 3: false, 4: false, 5: true, 6: false, 7: true} {
		if workerNeedsTranscode(code) != want {
			t.Errorf("exit %d: needs transcode = %v", code, !want)
		}
	}
}

// fallbackPlayer is a Player on f whose workers write a playing status at
// position, then exit with the next code from codes (0 once they run out).
// Its bitrate cap is 6 Mbit/s, above playVideoDirect's 4. launches returns
// each worker's arguments.
func fallbackPlayer(t *testing.T, f *playServer, codes []int, position string) (*Player, func() [][]string) {
	t.Helper()
	p := f.player(t)
	p.Kbps = func() int { return 6000 }
	status := p.Status
	var mu sync.Mutex
	var launches [][]string
	p.exec = func(_ string, args ...string) *exec.Cmd {
		mu.Lock()
		n := len(launches)
		launches = append(launches, append([]string(nil), args...))
		mu.Unlock()
		code := 0
		if n < len(codes) {
			code = codes[n]
		}
		state := "playing"
		if code == workerExitOpenTimeout {
			state = "opening" // the stream never came: no picture was played
		}
		script := "printf 'state=" + state + "\\nposition=" + position + "\\nduration=300\\n' > '" + status + "'; sleep 0.4; exit " + strconv.Itoa(code)
		return exec.Command("sh", "-c", script)
	}
	return p, func() [][]string {
		mu.Lock()
		defer mu.Unlock()
		return append([][]string(nil), launches...)
	}
}

// A file the core plays is streamed as stored, under the user's cap, without
// asking the server for a transcode or changing its track selection.
func TestEligibleFilePlaysDirect(t *testing.T) {
	f := newPlayServer(t, playVideoDirect)
	p, launches := fallbackPlayer(t, f, nil, "10")
	s, err := p.Start(playItem(), 10)
	if err != nil {
		t.Fatal(err)
	}
	waitDone(t, s)
	if got := f.events(); strings.Join(got, ",") != "timeline playing,timeline stopped" {
		t.Fatalf("server traffic %v", got)
	}
	l := launches()
	if len(l) != 1 || !hasArg(l[0], "--direct") || l[0][len(l[0])-1] != f.srv.URL+"/library/parts/part/1700000000/file.mkv" {
		t.Fatalf("direct launch: %v", l)
	}
}

func TestIneligibleDirectRequestsTranscodeAtUserBitrate(t *testing.T) {
	// 7 Mbit/s at 720p is above what the core keeps up with
	f := newPlayServer(t, strings.Replace(playVideoDirect, `bitrate="4000"`, `bitrate="7000"`, 1))
	p, launches := fallbackPlayer(t, f, nil, "10")
	s, err := p.Start(playItem(), 10)
	if err != nil {
		t.Fatal(err)
	}
	waitDone(t, s)
	d := f.requests("/video/:/transcode/universal/decision")
	if len(d) != 1 || d[0].q.Get("maxVideoBitrate") != "6000" || d[0].q.Get("videoResolution") != "1280x720" || d[0].q.Get("offset") != "10" {
		t.Fatalf("decisions %+v", d)
	}
	if l := launches(); len(l) != 1 || hasArg(l[0], "--direct") {
		t.Fatalf("transcode launch: %v", l)
	}
	if log, _ := os.ReadFile(p.LogTo); !strings.Contains(string(log), "not eligible (bitrate 7000 kbit/s above 6000)") {
		t.Fatalf("log does not say why: %s", log)
	}
}

// A file the core plays but above the chosen bitrate is transcoded to that
// bitrate, at the smaller picture a low cap gets.
func TestDirectAboveUserBitrateRequestsTranscode(t *testing.T) {
	f := newPlayServer(t, playVideoDirect)
	p, launches := fallbackPlayer(t, f, nil, "10")
	p.Kbps = func() int { return 2000 }
	s, err := p.Start(playItem(), 10)
	if err != nil {
		t.Fatal(err)
	}
	waitDone(t, s)
	d := f.requests("/video/:/transcode/universal/decision")
	if len(d) != 1 || d[0].q.Get("maxVideoBitrate") != "2000" || d[0].q.Get("videoResolution") != "854x480" {
		t.Fatalf("decisions %+v", d)
	}
	if extra := d[0].q.Get("X-Plex-Client-Profile-Extra"); !strings.Contains(extra, "name=video.height&value=480") {
		t.Fatalf("transcode profile not capped at 480 lines: %s", extra)
	}
	if l := launches(); len(l) != 1 || hasArg(l[0], "--direct") {
		t.Fatalf("transcode launch: %v", l)
	}
}

// A subtitle the app does not draw is burned into a transcode at the chosen
// size; the part's selection is made that track first.
func TestBurnedSubtitleTranscodesAtChosenSize(t *testing.T) {
	f := newPlayServer(t, playVideoDirect)
	p, launches := fallbackPlayer(t, f, nil, "10")
	p.SubtitleSize = func() int { return 150 }
	item := playItem()
	item.Subs = []plex.Stream{{ID: "13", Text: true}, {ID: "14", Selected: true}}
	s, err := p.Start(item, 10)
	if err != nil {
		t.Fatal(err)
	}
	waitDone(t, s)
	// the stop puts the chosen track back as the selection (a drawn one was deselected)
	want := "select subtitleStreamID=14,decision,timeline playing,timeline stopped,stop,select subtitleStreamID=14"
	if got := f.events(); strings.Join(got, ",") != want {
		t.Fatalf("server traffic %v, want %s", got, want)
	}
	d := f.requests("/video/:/transcode/universal/decision")[0].q
	if d.Get("subtitles") != "burn" || d.Get("subtitleSize") != "150" {
		t.Fatalf("decision %v", d)
	}
	if l := launches(); len(l) != 1 || hasArg(l[0], "--direct") {
		t.Fatalf("transcode launch: %v", l)
	}
}

// Turning a burned subtitle off plays the file as stored again, and the
// transcode it leaves is ended at once rather than left to time out.
func TestTrackChangeToDirectEndsTheTranscode(t *testing.T) {
	f := newPlayServer(t, playVideoDirect)
	p := f.player(t)
	status := p.Status
	var mu sync.Mutex
	var child *exec.Cmd
	var launches [][]string
	p.exec = func(_ string, args ...string) *exec.Cmd {
		cmd := exec.Command("sh", "-c", "printf 'state=playing\\nposition=30\\nduration=300\\n' > '"+status+"'; exec sleep 30")
		mu.Lock()
		launches = append(launches, append([]string(nil), args...))
		child = cmd
		mu.Unlock()
		return cmd
	}
	item := playItem()
	item.Subs = []plex.Stream{{ID: "14", Selected: true}}
	s, err := p.Start(item, 10)
	if err != nil {
		t.Fatal(err)
	}
	s.writeCommand = func(line string) {
		if line != "stop" {
			return
		}
		mu.Lock()
		defer mu.Unlock()
		if child != nil && child.Process != nil {
			_ = child.Process.Kill()
		}
	}
	s.Send("tracks -1 -1 30")
	mu.Lock()
	l := append([][]string(nil), launches...)
	mu.Unlock()
	if len(l) != 2 || hasArg(l[0], "--direct") || !hasArg(l[1], "--direct") || !containsArgPair(l[1], "--start-in-file", "30") {
		t.Fatalf("launches %v", l)
	}
	if stops := f.requests("/video/:/transcode/universal/stop"); len(stops) != 1 {
		t.Fatalf("the transcode left behind was not ended: %v", f.events())
	}
	s.Stop()
	// the direct stream's stopped report has no transcode to end
	if stops := f.requests("/video/:/transcode/universal/stop"); len(stops) != 1 {
		t.Fatalf("transcode stops after the end: %v", f.events())
	}
}

func TestDirectFallsBackToTranscodeOnce(t *testing.T) {
	for _, code := range []int{workerExitNeedsTranscode, workerExitRefused} {
		t.Run(strconv.Itoa(code), func(t *testing.T) {
			f := newPlayServer(t, playVideoDirect)
			// the direct worker plays to 42 s and asks for a transcode; the
			// transcode worker asks again, which must not loop
			p, launches := fallbackPlayer(t, f, []int{code, code}, "42")
			s, err := p.Start(playItem(), 10)
			if err != nil {
				t.Fatal(err)
			}
			if waitDone(t, s) == nil {
				t.Fatal("second refusal did not end playback with an error")
			}
			l := launches()
			if len(l) != 2 {
				t.Fatalf("launches = %d, want direct then one transcode", len(l))
			}
			if !hasArg(l[0], "--direct") || hasArg(l[1], "--direct") {
				t.Fatalf("launch args = %v", l)
			}
			if !containsArgPair(l[1], "--base", "42") {
				t.Fatalf("transcode did not resume at the direct position: %v", l[1])
			}
			d := f.requests("/video/:/transcode/universal/decision")
			if len(d) != 1 || d[0].q.Get("offset") != "42" {
				t.Fatalf("decisions %+v", d)
			}
			want := []string{
				"timeline playing", "timeline stopped", // the direct stream
				"decision", "timeline playing", "timeline stopped", "stop", // the transcode
			}
			if got := f.events(); strings.Join(got, ",") != strings.Join(want, ",") {
				t.Fatalf("server traffic %v, want %v", got, want)
			}
			// one playback, one session throughout
			session := d[0].q.Get("session")
			for _, r := range f.requests("/:/timeline") {
				if r.q.Get("X-Plex-Session-Identifier") != session {
					t.Fatalf("timeline session %q, transcode session %q", r.q.Get("X-Plex-Session-Identifier"), session)
				}
			}
		})
	}
}

func TestOtherWorkerErrorsDoNotFallBack(t *testing.T) {
	f := newPlayServer(t, playVideoDirect)
	p, launches := fallbackPlayer(t, f, []int{6}, "42")
	s, err := p.Start(playItem(), 10)
	if err != nil {
		t.Fatal(err)
	}
	if waitDone(t, s) == nil {
		t.Fatal("stream failure was not reported")
	}
	if l := launches(); len(l) != 1 {
		t.Fatalf("launches = %d, want 1", len(l))
	}
}

func waitDone(t *testing.T, s *Session) error {
	t.Helper()
	select {
	case err := <-s.Done:
		return err
	case <-time.After(6 * time.Second):
		t.Fatal("session did not end")
		return nil
	}
}

// A transcode started at an offset is given the open timeout; when its
// worker sees no stream (exit 8) playback ends with the no-video error,
// which carries the worker's exit. A start from the beginning and a direct
// stream get no open timeout but end the same way.
func TestOpenTimeoutEndsPlaybackWithNoVideoError(t *testing.T) {
	for name, tc := range map[string]struct {
		video   string
		offset  int
		timeout string
	}{"resume": {playVideoTranscode, 375, "20"}, "from-start": {playVideoTranscode, 0, ""}, "direct": {playVideoDirect, 10, ""}} {
		t.Run(name, func(t *testing.T) {
			f := newPlayServer(t, tc.video)
			p, launches := fallbackPlayer(t, f, []int{workerExitOpenTimeout}, "1")
			s, err := p.Start(playItem(), tc.offset)
			if err != nil {
				t.Fatal(err)
			}
			err = waitDone(t, s)
			if err == nil || !strings.Contains(err.Error(), "sent no video") {
				t.Fatalf("playback ended with %v, want the no-video error", err)
			}
			var ee *exec.ExitError
			if !errors.As(err, &ee) || ee.ExitCode() != workerExitOpenTimeout {
				t.Fatalf("error %v does not carry the worker's exit", err)
			}
			l := launches()
			if len(l) != 1 {
				t.Fatalf("launches %v, want one", l)
			}
			if hasArg(l[0], "--open-timeout") != (tc.timeout != "") || (tc.timeout != "" && !containsArgPair(l[0], "--open-timeout", tc.timeout)) {
				t.Fatalf("open timeout: %v", l[0])
			}
		})
	}
}
