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
// A worker whose stream does not open (exit 4) writes no status, as jfplay
// is still in its open then. Its bitrate cap is 6 Mbit/s, above
// playVideoDirect's 4. launches returns each worker's arguments.
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
		script := "printf 'state=" + state + "\\nposition=" + position + "\\nduration=300\\n' > '" + status + "'; "
		if code == workerExitOpenFailed {
			script = ""
		}
		script += "sleep 0.4; exit " + strconv.Itoa(code)
		return exec.Command("sh", "-c", script)
	}
	return p, func() [][]string {
		mu.Lock()
		defer mu.Unlock()
		return append([][]string(nil), launches...)
	}
}

// recordSleeps replaces noPictureSleep for the test with one that does not
// wait and records each wait with the worker launch it came before.
func recordSleeps(t *testing.T, launches func() [][]string) func() []string {
	t.Helper()
	var mu sync.Mutex
	var sleeps []string
	noPictureSleep = func(d time.Duration) {
		mu.Lock()
		defer mu.Unlock()
		sleeps = append(sleeps, d.String()+" before launch "+strconv.Itoa(len(launches())+1))
	}
	t.Cleanup(func() { noPictureSleep = time.Sleep })
	return func() []string {
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), sleeps...)
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

// A stream the core decoded but never showed (exit 9) is played again at the
// same position as a transcode of at most 854x480, once: the second exit 9
// ends playback with the no-picture error, which carries the worker's exit.
// After the direct fallback the small retry is still available. The server
// is given noPictureRestartDelay before the small transcode, and the direct
// fallback no wait.
func TestNoPictureRetriesSmallTranscodeOnce(t *testing.T) {
	for name, tc := range map[string]struct {
		video  string
		codes  []int
		sizes  []string // each decision's videoResolution
		sleeps []string
	}{
		"transcode": {playVideoTranscode, []int{workerExitNoPicture, workerExitNoPicture}, []string{"1280x720", "854x480"}, []string{"1.5s before launch 2"}},
		"direct":    {playVideoDirect, []int{workerExitNeedsTranscode, workerExitNoPicture, workerExitNoPicture}, []string{"1280x720", "854x480"}, []string{"1.5s before launch 3"}},
	} {
		t.Run(name, func(t *testing.T) {
			f := newPlayServer(t, tc.video)
			p, launches := fallbackPlayer(t, f, tc.codes, "42")
			sleeps := recordSleeps(t, launches)
			s, err := p.Start(playItem(), 10)
			if err != nil {
				t.Fatal(err)
			}
			err = waitDone(t, s)
			if err == nil || !strings.Contains(err.Error(), "showed no picture") {
				t.Fatalf("playback ended with %v, want the no-picture error", err)
			}
			var ee *exec.ExitError
			if !errors.As(err, &ee) || ee.ExitCode() != workerExitNoPicture {
				t.Fatalf("error %v does not carry the worker's exit", err)
			}
			if l := launches(); len(l) != len(tc.codes) || !containsArgPair(l[len(l)-1], "--base", "42") {
				t.Fatalf("launches %v", l)
			}
			d := f.requests("/video/:/transcode/universal/decision")
			if len(d) != len(tc.sizes) {
				t.Fatalf("decisions %+v", d)
			}
			for i, want := range tc.sizes {
				if got := d[i].q.Get("videoResolution"); got != want {
					t.Errorf("decision %d at %s, want %s", i, got, want)
				}
			}
			last := d[len(d)-1].q
			if last.Get("offset") != "42" || last.Get("session") != d[0].q.Get("session") {
				t.Fatalf("small transcode decision %v", last)
			}
			if extra := last.Get("X-Plex-Client-Profile-Extra"); !strings.Contains(extra, "name=video.height&value=480") {
				t.Fatalf("small transcode profile: %s", extra)
			}
			log, _ := os.ReadFile(p.LogTo)
			if !strings.Contains(string(log), "restarting at 42.000 s as a transcode of at most 854x480") || !strings.Contains(string(log), "small_transcode=true") {
				t.Fatalf("log does not say so: %s", log)
			}
			if got := sleeps(); strings.Join(got, ",") != strings.Join(tc.sleeps, ",") {
				t.Fatalf("waits %v, want %v", got, tc.sleeps)
			}
		})
	}
}

// A small transcode whose stream the server closes unopened (exit 4) soon
// after the no-picture restart is opened once more, after the same wait, at
// the same position, on the same session and still small; a second exit 4
// ends playback with the worker's exit. An ordinary transcode that does not
// open is not retried.
func TestSmallTranscodeReopensOnce(t *testing.T) {
	small := []string{"1.5s before launch 2", "1.5s before launch 3"}
	for name, tc := range map[string]struct {
		codes  []int
		sizes  []string // each decision's videoResolution
		sleeps []string
		fails  bool
	}{
		"plays":    {[]int{workerExitNoPicture, workerExitOpenFailed, 0}, []string{"1280x720", "854x480", "854x480"}, small, false},
		"fails":    {[]int{workerExitNoPicture, workerExitOpenFailed, workerExitOpenFailed}, []string{"1280x720", "854x480", "854x480"}, small, true},
		"ordinary": {[]int{workerExitOpenFailed}, []string{"1280x720"}, nil, true},
	} {
		t.Run(name, func(t *testing.T) {
			f := newPlayServer(t, playVideoTranscode)
			p, launches := fallbackPlayer(t, f, tc.codes, "42")
			sleeps := recordSleeps(t, launches)
			s, err := p.Start(playItem(), 10)
			if err != nil {
				t.Fatal(err)
			}
			err = waitDone(t, s)
			if !tc.fails && err != nil {
				t.Fatalf("playback ended with %v, want a clean end", err)
			}
			if tc.fails {
				var ee *exec.ExitError
				if !errors.As(err, &ee) || ee.ExitCode() != workerExitOpenFailed {
					t.Fatalf("playback ended with %v, want the worker's open failure", err)
				}
			}
			l := launches()
			if len(l) != len(tc.codes) {
				t.Fatalf("launches %v, want %d", l, len(tc.codes))
			}
			for i := 1; i < len(l); i++ {
				if !containsArgPair(l[i], "--base", "42") {
					t.Fatalf("launch %d did not resume at the first worker's position: %v", i+1, l[i])
				}
			}
			d := f.requests("/video/:/transcode/universal/decision")
			if len(d) != len(tc.sizes) {
				t.Fatalf("decisions %+v", d)
			}
			for i, want := range tc.sizes {
				q := d[i].q
				if got := q.Get("videoResolution"); got != want {
					t.Errorf("decision %d at %s, want %s", i, got, want)
				}
				if q.Get("session") != d[0].q.Get("session") {
					t.Errorf("decision %d on session %s, want %s", i, q.Get("session"), d[0].q.Get("session"))
				}
				if i > 0 && q.Get("offset") != "42" {
					t.Errorf("decision %d at offset %s, want 42", i, q.Get("offset"))
				}
			}
			if got := sleeps(); strings.Join(got, ",") != strings.Join(tc.sleeps, ",") {
				t.Fatalf("waits %v, want %v", got, tc.sleeps)
			}
			log, _ := os.ReadFile(p.LogTo)
			want := 0
			if len(tc.codes) > 1 {
				want = 1
			}
			if n := strings.Count(string(log), "small transcode did not open (jfplay exit 4)"); n != want || (want == 1 && !strings.Contains(string(log), "starting it once more at 42.000 s")) {
				t.Fatalf("log has %d re-open lines, want %d: %s", n, want, log)
			}
		})
	}
}

// A stop asked for while the app waits before the small transcode ends the
// session there: no decision is asked for and no worker started.
func TestStopDuringNoPictureWaitStartsNothing(t *testing.T) {
	f := newPlayServer(t, playVideoTranscode)
	p, launches := fallbackPlayer(t, f, []int{workerExitNoPicture}, "42")
	var mu sync.Mutex
	var s *Session
	noPictureSleep = func(time.Duration) {
		mu.Lock()
		defer mu.Unlock()
		s.mu.Lock()
		s.stopRequested = true // what StopUI does before its Stop
		s.mu.Unlock()
	}
	t.Cleanup(func() { noPictureSleep = time.Sleep })
	mu.Lock()
	started, err := p.Start(playItem(), 10)
	s = started
	mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		s.mu.Lock()
		stopping := s.stopRequested
		s.mu.Unlock()
		if stopping || time.Now().After(deadline) {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	s.Stop()
	if err := waitDone(t, s); err != nil {
		t.Fatalf("playback ended with %v, want a clean end", err)
	}
	if l := launches(); len(l) != 1 {
		t.Fatalf("launches %v, want only the first", l)
	}
	if d := f.requests("/video/:/transcode/universal/decision"); len(d) != 1 {
		t.Fatalf("decisions %+v, want only the first", d)
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
