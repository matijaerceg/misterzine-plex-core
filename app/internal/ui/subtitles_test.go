package ui

import (
	"net/http"
	"net/http/httptest"
	"os/exec"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/plex"
)

// sampleSRT is a track as the server sends one: Windows line ends, a byte
// order mark, markup, an ASS override and break, an entity, a cue out of
// order, a cue without its blank line, and a long cue under two short ones.
const sampleSRT = "\xef\xbb\xbf1\r\n00:00:01,000 --> 00:00:03,500\r\n<i>Hello</i> there,\r\n{\\an8}<font color=\"#ffff00\">friend</font> &amp; you\r\n\r\n" +
	"3\r\n00:00:10.000 --> 00:00:12.000 X1:10 X2:20\r\nThird\\Nline two\r\n\r\n" +
	"2\r\n00:00:05,000 --> 00:00:06,000\r\nSecond\r\n4\r\n00:00:20,000 --> 00:00:40,000\r\nCaption\r\n\r\n" +
	"5\r\n00:00:22,000 --> 00:00:24,000\r\nA < B, Café\r\n\r\n" +
	"6\r\n00:00:30,000 --> 00:00:31,000\r\n<b></b>\r\n\r\n" +
	"junk\r\n7\r\n00:00:50,000 --> 00:00:49,000\r\nBackwards\r\n"

func TestParseSRTCleansAndOrdersCues(t *testing.T) {
	track := parseSRT([]byte(sampleSRT))
	want := []subtitleCue{
		{1, 3.5, []string{"Hello there,", "friend & you"}},
		{5, 6, []string{"Second"}},
		{10, 12, []string{"Third", "line two"}},
		{20, 40, []string{"Caption"}},
		{22, 24, []string{"A < B, Cafe"}},
	}
	if len(track) != len(want) {
		t.Fatalf("%d cues, want %d: %+v", len(track), len(want), track)
	}
	for i, c := range track {
		if c.start != want[i].start || c.end != want[i].end || strings.Join(c.lines, "|") != strings.Join(want[i].lines, "|") {
			t.Errorf("cue %d = %+v, want %+v", i, c, want[i])
		}
	}
}

func TestSubtitleTrackAtJoinsOverlappingCues(t *testing.T) {
	track := parseSRT([]byte(sampleSRT))
	for _, tc := range []struct {
		at   float64
		want string
	}{
		{0.5, ""}, {1, "Hello there,|friend & you"}, {3.49, "Hello there,|friend & you"}, {3.5, ""},
		{11, "Third|line two"}, {21, "Caption"}, {23, "Caption|A < B, Cafe"}, {39, "Caption"}, {40, ""},
	} {
		if got := strings.Join(track.at(tc.at), "|"); got != tc.want {
			t.Errorf("at %v: %q, want %q", tc.at, got, tc.want)
		}
	}
	if subtitleTrack(nil).at(5) != nil {
		t.Fatal("an empty track shows something")
	}
}

// A track in Latin letters, accents and all, is drawn; one in a script the
// atlases lack is left to the server.
func TestSubtitleDrawableByScript(t *testing.T) {
	for text, want := range map[string]bool{
		"Hello there": true,
		"Où êtes-vous? Dziękuję, čudno! Ça va": true,
		"Как дела? Hello":                      false,
		"今日は":                                  false,
		"Γεια σου":                             false,
		"♪ ♪ 123":                              true,
	} {
		if got := subtitleDrawable([]byte("1\n00:00:01,000 --> 00:00:02,000\n" + text + "\n")); got != want {
			t.Errorf("%q drawable %v, want %v", text, got, want)
		}
	}
}

// inkRows is the rows of a panel holding type (an alpha above the box's).
func inkRows(c *gfx.Canvas, alpha []byte) (first, last int) {
	first, last = -1, -1
	for y := 0; y < c.H; y++ {
		for x := 0; x < c.W; x++ {
			if alpha[y*c.W+x] > subtitleBoxAlpha+40 {
				if first < 0 {
					first = y
				}
				last = y
				break
			}
		}
	}
	return first, last
}

// Each size draws white type on a translucent box, centred, the larger
// sizes taller by their percentage; a long line wraps within the safe area.
func TestDrawSubtitleSizes(t *testing.T) {
	var heights []int
	for _, s := range SubtitleSizes {
		c, alpha := drawSubtitle([]string{"Hello there"}, s.Value, 720)
		if c.W != 720 || len(alpha) != c.W*c.H {
			t.Fatalf("%s: panel %dx%d", s.Label, c.W, c.H)
		}
		first, last := inkRows(c, alpha)
		if first < 0 {
			t.Fatalf("%s: no type drawn", s.Label)
		}
		heights = append(heights, last-first+1)
		// the box: translucent at its ends, nothing outside it, the type
		// opaque white within
		row := c.H / 2
		left := -1
		for x := 0; x < c.W; x++ {
			if alpha[row*c.W+x] != 0 {
				left = x
				break
			}
		}
		right := c.W - 1
		for alpha[row*c.W+right] == 0 {
			right--
		}
		if left <= 0 || alpha[row*c.W+left] != subtitleBoxAlpha || alpha[row*c.W+right] != subtitleBoxAlpha || abs(left-(c.W-1-right)) > 1 {
			t.Fatalf("%s: box from %d to %d (alpha %d, %d)", s.Label, left, right, alpha[row*c.W+left], alpha[row*c.W+right])
		}
		opaque := false
		for i, a := range alpha {
			if a == 255 {
				opaque = true
				if c.Pix[i*4] < 240 || c.Pix[i*4+1] != c.Pix[i*4] || c.Pix[i*4+2] != c.Pix[i*4] {
					t.Fatalf("%s: opaque type is not white", s.Label)
				}
			}
		}
		if !opaque {
			t.Fatalf("%s: no solid type", s.Label)
		}
	}
	for i, s := range SubtitleSizes {
		ratio := float64(heights[i]) / float64(heights[0])
		if want := float64(s.Value) / 100; ratio < want*0.85 || ratio > want*1.15 {
			t.Errorf("%s type %d high, %.2f of Normal's %d; want about %.2f", s.Label, heights[i], ratio, heights[0], want)
		}
	}
	long := strings.Repeat("a long subtitle line ", 4)
	normal, _ := drawSubtitle([]string{long}, 100, 720)
	xl, xlAlpha := drawSubtitle([]string{long}, 200, 720)
	if xl.H < 2*normal.H {
		t.Fatalf("the long line at Extra large is %d high, Normal %d: it did not wrap", xl.H, normal.H)
	}
	for y := 0; y < xl.H; y++ {
		for x := 0; x < SafeX; x++ {
			if xlAlpha[y*xl.W+x] != 0 || xlAlpha[y*xl.W+xl.W-1-x] != 0 {
				t.Fatalf("Extra large reaches outside the safe area at %d,%d", x, y)
			}
		}
	}
	many := make([]string, 10)
	for i := range many {
		many[i] = "line"
	}
	c, _ := drawSubtitle(many, 100, 720)
	if c.H != subtitleMaxLines*gfx.Load("bold22").Height() {
		t.Fatalf("ten lines drew %d rows high", c.H)
	}
}

// subtitledPlaying is a playback at 600 s with the picture up, a text
// track selected and its cues in hand: one from 599 to 603 s.
func subtitledPlaying(t *testing.T) (*Playing, *coreOSD, *[]string, time.Time) {
	t.Helper()
	p, c, sent, now := skipPlaying(t)
	p.item.Markers = nil
	p.item.RatingKey, p.item.PartID = "film", "src"
	p.item.Subs = []plex.Stream{{ID: "3", Title: "English", Text: true, Selected: true}, {ID: "4", Title: "Signs", Text: true}}
	p.subsFor = "3"
	p.subs = parseSRT([]byte("1\n00:09:59,000 --> 00:10:03,000\nHello\n"))
	return p, c, sent, now
}

// With nothing else up the cue shows along the bottom, above the safe
// area's edge; it goes at its end, and its going is nothing Back waits for.
func TestPlayingDrawsSubtitlesWhenNothingElseIsUp(t *testing.T) {
	p, c, _, now := subtitledPlaying(t)
	tickAt(p, c, now)
	p.painter.flush()
	if !isSubtitleKey(p.last) || !c.shown || c.showY+c.showH != 480-subtitleMargin(480) || c.showW != 720 {
		t.Fatalf("subtitle panel: showing %q at %d, %dx%d", p.last, c.showY, c.showW, c.showH)
	}
	// the controls replace it, and it comes back when they go
	if keyAt(p, c, input.Enter, now.Add(time.Second)) || isSubtitleKey(p.last) {
		t.Fatalf("OK over a subtitle: showing %q", p.last)
	}
	p.Key(input.Event{Key: input.Down}, now.Add(2*time.Second))
	tickAt(p, c, now.Add(2*time.Second))
	if !isSubtitleKey(p.last) {
		t.Fatalf("the subtitle did not come back after the controls: showing %q", p.last)
	}
	p.pos = 603
	tickAt(p, c, now.Add(5*time.Second))
	p.painter.flush()
	if p.last != "" || c.shown {
		t.Fatalf("the subtitle stayed past its cue: showing %q", p.last)
	}
	p.pos = 600
	tickAt(p, c, now.Add(10*time.Second))
	if !isSubtitleKey(p.last) || !keyAt(p, c, input.Back, now.Add(10*time.Second+100*time.Millisecond)) {
		t.Fatal("Back over a subtitle did not stop the playback")
	}
}

// Off, or a seek on its way, shows no subtitle; the drawn time runs on
// from the worker's last report while playing, not while paused.
func TestPlayingSubtitleTiming(t *testing.T) {
	p, _, _, now := subtitledPlaying(t)
	p.pos, p.posAt = 598.8, now
	if p.subtitleLines(now) != nil {
		t.Fatal("a cue showed before its time")
	}
	if p.subtitleLines(now.Add(300*time.Millisecond)) == nil {
		t.Fatal("the time did not run on from the last report")
	}
	p.paused = true
	if p.subtitleLines(now.Add(300*time.Millisecond)) != nil {
		t.Fatal("the time ran on while paused")
	}
	p.paused = false
	p.pos = 598
	if p.subtitleLines(now.Add(5*time.Second)) != nil {
		t.Fatal("the time ran on past the lead from a stale report")
	}
	p.pos = 600
	p.seekAt = now
	if p.subtitleLines(now) != nil {
		t.Fatal("a subtitle showed while a seek was on its way")
	}
	p.seekAt = time.Time{}
	p.app.selectStream(p.item, "Subtitles", -1)
	p.syncSubtitles()
	if p.subtitleLines(now) != nil || p.subsFor != "" {
		t.Fatal("subtitles off still shows the cue")
	}
}

// More > Subtitle size saves the size and repaints the subtitle larger,
// without a word to the session.
func TestSubtitleSizeFromMoreRepaintsWithoutRestart(t *testing.T) {
	p, c, sent, now := subtitledPlaying(t)
	tickAt(p, c, now)
	p.painter.flush()
	normal := c.showH
	pressPlay(p, input.Enter) // the controls
	for i, b := range osdButtons {
		if b == "More" {
			p.focus = i
		}
	}
	pressPlay(p, input.Enter)
	if p.list == nil || p.list.kind != "More" || p.list.items[len(p.list.items)-1] != "Subtitle size" || p.list.vals[len(p.list.vals)-1] != "Normal" {
		t.Fatalf("More: %+v", p.list)
	}
	p.list.cur = len(p.list.items) - 1
	pressPlay(p, input.Enter)
	if p.list == nil || p.list.kind != "Subtitle size" || p.list.set != 0 {
		t.Fatalf("Subtitle size list: %+v", p.list)
	}
	pressPlay(p, input.Down, input.Enter)
	if p.list != nil || p.app.Cfg.SubtitleSize != 150 || LoadConfig(p.app.Cfg.path).SubtitleSizeValue() != 150 {
		t.Fatalf("Large chosen: list %+v, size %d", p.list, p.app.Cfg.SubtitleSize)
	}
	if len(*sent) != 0 {
		t.Fatalf("the size change sent %q", *sent)
	}
	pressPlay(p, input.Back) // the controls go
	tickAt(p, c, now.Add(time.Second))
	p.painter.flush()
	if !isSubtitleKey(p.last) || c.showH <= normal {
		t.Fatalf("Large drew %d high, Normal %d", c.showH, normal)
	}
}

// A subtitle the server burns in takes a new size when its transcode
// starts over from the same place.
func TestSubtitleSizeRestartsABurnedSubtitle(t *testing.T) {
	p, _, sent, _ := subtitledPlaying(t)
	p.item.Subs = []plex.Stream{{ID: "5", Title: "Signs (PGS)", Selected: true}}
	p.list = &listMode{kind: "Subtitle size", items: []string{"Normal", "Large"}}
	p.list.cur = 1
	p.choose(p.list)
	if p.app.Cfg.SubtitleSizeValue() != 150 || len(*sent) != 1 || (*sent)[0] != "seek 600" {
		t.Fatalf("Large over a burned subtitle: size %d, sent %q", p.app.Cfg.SubtitleSizeValue(), *sent)
	}
}

// A selected text track is fetched whole; one in letters the atlases lack
// is remembered and handed back to the server with a restart.
func TestPlayingFetchesTextSubtitles(t *testing.T) {
	var mu sync.Mutex
	var paths []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		paths = append(paths, r.URL.Path)
		mu.Unlock()
		switch r.URL.Path {
		case "/library/streams/3":
			_, _ = w.Write([]byte("1\n00:09:59,000 --> 00:10:03,000\nHello\n"))
		case "/library/streams/4":
			_, _ = w.Write([]byte("1\n00:09:59,000 --> 00:10:03,000\nПривет, как дела\n"))
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()
	p, c, sent, now := subtitledPlaying(t)
	p.app.Plex = testClient(srv.URL, "synthetic-token", t.TempDir())
	p.subsFor, p.subs = "", nil
	deadline := time.Now().Add(3 * time.Second)
	for len(p.subs) == 0 && time.Now().Before(deadline) {
		tickAt(p, c, now)
		time.Sleep(5 * time.Millisecond)
	}
	if len(p.subs) != 1 || p.subsFor != "3" {
		t.Fatalf("track 3 not taken: %+v (%q)", p.subs, p.subsFor)
	}
	p.app.selectStream(p.item, "Subtitles", 1)
	for len(*sent) == 0 && time.Now().Before(deadline) {
		tickAt(p, c, now)
		time.Sleep(5 * time.Millisecond)
	}
	if len(*sent) != 1 || (*sent)[0] != "tracks -1 4 600" {
		t.Fatalf("an undrawable track sent %q, want a restart with it", *sent)
	}
	if p.app.drawsSubtitle("film", p.item.Subs[1]) || !p.app.drawsSubtitle("film", p.item.Subs[0]) || len(p.subs) != 0 {
		t.Fatal("the undrawable track was not left to the server")
	}
	tickAt(p, c, now)
	mu.Lock()
	defer mu.Unlock()
	if len(paths) != 2 {
		t.Fatalf("requests %q: the undrawable track was fetched again", paths)
	}
}

// A text track the app draws leaves the stream free to play as stored;
// switching between drawn tracks or turning them off keeps the stream, and
// a picture track is burned into a transcode with a restart.
func TestSessionDrawnSubtitlesKeepTheStream(t *testing.T) {
	var mu sync.Mutex
	var requests []string
	record := func(r string) {
		mu.Lock()
		requests = append(requests, r)
		mu.Unlock()
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/library/metadata/film":
			record("probe")
			_, _ = w.Write([]byte(`<MediaContainer size="1"><Video ratingKey="film" type="movie"><Media container="mkv">` +
				`<Part id="src" key="/library/parts/src/1/file.mkv" container="mkv">` +
				`<Stream id="3" streamType="3" codec="srt" key="/library/streams/3"/>` +
				`<Stream id="4" streamType="3" codec="srt" key="/library/streams/4"/>` +
				`<Stream id="5" streamType="3" codec="pgs"/>` +
				`</Part></Media></Video></MediaContainer>`))
		case r.Method == http.MethodPut && r.URL.Path == "/library/parts/src":
			record("subtitle " + r.URL.Query().Get("subtitleStreamID"))
		case r.URL.Path == "/video/:/transcode/universal/decision":
			record("transcode")
			_, _ = w.Write([]byte(`<MediaContainer transcodeDecisionCode="1001" transcodeDecisionText="Direct play not available; Conversion OK."/>`))
		default:
			_, _ = w.Write([]byte(`<MediaContainer size="0"/>`))
		}
	}))
	defer srv.Close()
	dir := t.TempDir()
	status := dir + "/status"
	p := &Player{Client: testClient(srv.URL, "synthetic-token", t.TempDir()), Binary: "jfplay", Fifo: dir + "/fifo", Status: status, LogTo: dir + "/log",
		DrawsSubtitle: func(_ string, s plex.Stream) bool { return s.Text }}
	var cmdMu sync.Mutex
	var child *exec.Cmd
	launches := 0
	p.exec = func(_ string, args ...string) *exec.Cmd {
		cmd := exec.Command("sh", "-c", "printf 'state=playing\\nposition=25\\nduration=300\\n' > '"+status+"'; exec sleep 30")
		cmdMu.Lock()
		child = cmd
		launches++
		cmdMu.Unlock()
		return cmd
	}
	item := &plex.Item{RatingKey: "film", PartID: "src", Subs: []plex.Stream{{ID: "3", Text: true, Selected: true}, {ID: "4", Text: true}, {ID: "5"}}}
	s, err := p.Start(item, 20)
	if err != nil {
		t.Fatal(err)
	}
	s.writeCommand = func(line string) {
		if line != "stop" {
			return
		}
		cmdMu.Lock()
		defer cmdMu.Unlock()
		if child != nil && child.Process != nil {
			_ = child.Process.Kill()
		}
	}
	defer s.Stop()
	launched := func() int { cmdMu.Lock(); defer cmdMu.Unlock(); return launches }
	if !s.direct || launched() != 1 || s.state.SubtitleStream != "3" {
		t.Fatalf("drawn track: direct %v, launches %d, reported %q", s.direct, launched(), s.state.SubtitleStream)
	}
	for _, step := range []struct {
		cmd      string
		launches int
	}{{"tracks -1 4 25", 1}, {"tracks -1 -1 25", 1}, {"tracks -1 3 25", 1}, {"tracks -1 5 25", 2}, {"tracks -1 4 25", 3}} {
		s.Send(step.cmd)
		if got := launched(); got != step.launches {
			t.Fatalf("%s: %d launches, want %d", step.cmd, got, step.launches)
		}
		if want := strings.Fields(step.cmd)[2]; s.state.SubtitleStream != want {
			t.Fatalf("%s: reports subtitle %q", step.cmd, s.state.SubtitleStream)
		}
	}
	mu.Lock()
	defer mu.Unlock()
	// the start's probe; the picture track selected on the part and burned
	// into a transcode; the drawn track's probe again, played as stored
	want := []string{"probe", "probe", "subtitle 5", "transcode", "probe"}
	if !slices.Equal(requests, want) {
		t.Fatalf("server requests %q, want %q", requests, want)
	}
}
