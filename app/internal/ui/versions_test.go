package ui

import (
	"fmt"
	"log"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/plex"
)

// testVersions are a synthetic title's versions, oldest file first: a 1080p
// original over the HD direct limit, a 720p copy and a 480p copy, all of
// which the server lists for every item of the rig as <key>-<media>.
var testVersions = []struct {
	media      string
	w, h, kbps int
}{{"11", 1920, 1080, 7800}, {"12", 1280, 720, 1200}, {"13", 854, 480, 700}}

// versionsXML is an item's record with the three versions: with their
// streams (the item's own record) or without (a listing's).
func versionsXML(key, typ string, streams bool) string {
	var b strings.Builder
	show := ""
	if typ == "episode" {
		show = ` grandparentRatingKey="show" parentRatingKey="season"`
	}
	fmt.Fprintf(&b, `<Video ratingKey="%s" key="/library/metadata/%s" type="%s" title="Title %s" duration="1000000"%s>`, key, key, typ, key, show)
	for _, v := range testVersions {
		id := key + "-" + v.media
		fmt.Fprintf(&b, `<Media id="%s" bitrate="%d" width="%d" height="%d" aspectRatio="1.78" videoCodec="h264" videoResolution="%d" videoFrameRate="24p" container="mkv">`, id, v.kbps, v.w, v.h, v.h)
		fmt.Fprintf(&b, `<Part id="p%s" key="/library/parts/p%s/1/file.mkv" file="/media/Title %s - %dp.mkv" duration="1000000" container="mkv">`, id, id, key, v.h)
		if streams {
			fmt.Fprintf(&b, `<Stream id="v%s" streamType="1" codec="h264" index="0" profile="high" level="40" bitDepth="8" width="%d" height="%d" frameRate="23.976" bitrate="%d" scanType="progressive" cabac="1"/>`, id, v.w, v.h, v.kbps-100)
			fmt.Fprintf(&b, `<Stream id="a%s" streamType="2" codec="aac" index="1" channels="2" selected="1" language="English" languageTag="en"/>`, id)
		}
		b.WriteString(`</Part></Media>`)
	}
	b.WriteString(`</Video>`)
	return b.String()
}

// versionRig is an app against a server holding a film and a season of
// two episodes, each in the three versions, whose player stops at stopAt of
// the items' 1000 s and records the stream each start opened.
type versionRig struct {
	a      *App
	logs   *syncBuffer
	mu     sync.Mutex
	played []string // each start's stream URL
}

func newVersionRig(t *testing.T, stopAt float64) *versionRig {
	t.Helper()
	r := &versionRig{logs: &syncBuffer{}}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		wrap := func(body string) { _, _ = w.Write([]byte(`<MediaContainer size="1">` + body + `</MediaContainer>`)) }
		switch p := req.URL.Path; {
		case p == "/library/metadata/film":
			wrap(versionsXML("film", "movie", true))
		case p == "/library/metadata/ep1" || p == "/library/metadata/ep2":
			wrap(versionsXML(strings.TrimPrefix(p, "/library/metadata/"), "episode", true))
		case p == "/library/metadata/season/children":
			wrap(versionsXML("ep1", "episode", false) + versionsXML("ep2", "episode", false))
		default:
			_, _ = w.Write([]byte(`<MediaContainer/>`))
		}
	}))
	t.Cleanup(srv.Close)
	client := plex.New(srv.URL, "synthetic-token", t.TempDir(), "device")
	dir := t.TempDir()
	status := dir + "/status"
	p := &Player{Client: client, Binary: "jfplay-test", Fifo: dir + "/fifo", Status: status, LogTo: dir + "/log"}
	p.exec = func(_ string, args ...string) *exec.Cmd {
		r.mu.Lock()
		r.played = append(r.played, args[len(args)-1])
		r.mu.Unlock()
		script := fmt.Sprintf("printf 'state=playing\\nposition=%g\\nduration=1000\\n' > '%s'", stopAt, status)
		return exec.Command("sh", "-c", script)
	}
	cfg := &Config{NoTheme: true, path: filepath.Join(t.TempDir(), "settings.json")}
	p.Kbps, p.DirectPlay = cfg.BitrateKbps, cfg.DirectPlay
	r.a = &App{Log: log.New(r.logs, "", 0), Out: &foreignOut{gfx.NewCanvas(8, 4)}, Plex: client, Player: p,
		Cfg: cfg, Wake: make(chan struct{}, 1), later: make(chan func(), 32), F: appFonts()}
	r.a.stack = []Screen{&splashTestScreen{}}
	return r
}

// playedParts are the parts the starts opened as stored ("pfilm-12") or
// had the server convert ("mediaIndex 0"), in order.
func (r *versionRig) playedParts() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	var out []string
	for _, s := range r.played {
		i := strings.Index(s, "/library/parts/")
		if i < 0 {
			u, err := url.Parse(s)
			if err != nil {
				out = append(out, s)
				continue
			}
			out = append(out, "mediaIndex "+u.Query().Get("mediaIndex"))
			continue
		}
		part := s[i+len("/library/parts/"):]
		out = append(out, part[:strings.IndexByte(part, '/')])
	}
	return out
}

func (r *versionRig) item(t *testing.T, key string) *plex.Item {
	t.Helper()
	it, err := r.a.Plex.Item(key)
	if err != nil {
		t.Fatal(err)
	}
	return it
}

func (r *versionRig) listing(t *testing.T) []*plex.Item {
	t.Helper()
	eps, err := r.a.Plex.Items("/library/metadata/season/children", nil, 50)
	if err != nil || len(eps) != 2 {
		t.Fatalf("listing %v, %v", eps, err)
	}
	return eps
}

// chooser is the chooser on top, failing the test without one.
func (r *versionRig) chooser(t *testing.T) *Chooser {
	t.Helper()
	ch, ok := r.a.top().(*Chooser)
	if !ok {
		t.Fatalf("no chooser on top: %T; played %v", r.a.top(), r.playedParts())
	}
	return ch
}

// pick moves the chooser's cursor to i and presses OK, which plays.
func (r *versionRig) pick(t *testing.T, i int) {
	t.Helper()
	ch := r.chooser(t)
	ch.cur = i
	ch.Key(input.Event{Key: input.Enter}, time.Now())
}

func sameParts(got []string, want ...string) bool {
	return strings.Join(got, " ") == strings.Join(want, " ")
}

// A first play asks, the version that suits the cores (the 720p copy, the
// largest that plays as stored) selected; OK plays the one picked, and
// after runs only then. The pick is recorded for a resume.
func TestFirstPlayAsksForTheVersion(t *testing.T) {
	r := newVersionRig(t, 300)
	it := r.item(t, "film")
	afters := 0
	r.a.PlayQueue(it, 0, nil, 0, func(*plex.Item, bool) { afters++ })
	ch := r.chooser(t)
	if ch.title != "Play which version?" || ch.cur != 1 || len(ch.items) != 3 || !strings.HasSuffix(ch.items[1], "plays directly") {
		t.Fatalf("chooser %q at %d: %q", ch.title, ch.cur, ch.items)
	}
	if len(r.playedParts()) != 0 || afters != 0 {
		t.Fatal("played before the pick")
	}
	r.pick(t, 2)
	if !sameParts(r.playedParts(), "pfilm-13") || afters != 1 {
		t.Fatalf("played %v, after ran %d times", r.playedParts(), afters)
	}
	if got := r.a.Cfg.Versions["film"].Media; got != "film-13" {
		t.Fatalf("recorded %q", got)
	}
	if !strings.Contains(r.logs.String(), "version 3 of 3 (media film-13) 480p h264, chosen: picked") {
		t.Fatalf("log:\n%s", r.logs.String())
	}
	if it.VersionID != "film-13" || it.PartID != "pfilm-13" {
		t.Fatalf("item left on %q, part %q", it.VersionID, it.PartID)
	}
}

// Back on the chooser plays nothing and never runs after.
func TestBackOnTheVersionChooserPlaysNothing(t *testing.T) {
	r := newVersionRig(t, 300)
	afters := 0
	r.a.PlayQueue(r.item(t, "film"), 0, nil, 0, func(*plex.Item, bool) { afters++ })
	r.chooser(t)
	r.a.Pop()
	if len(r.playedParts()) != 0 || afters != 0 || r.a.Cfg.Versions != nil {
		t.Fatalf("played %v, after %d, recorded %v", r.playedParts(), afters, r.a.Cfg.Versions)
	}
}

// A resume plays the recorded version unasked; a resume nobody recorded a
// version for asks; From start asks with the recorded one selected.
func TestResumeAndFromStartVersions(t *testing.T) {
	r := newVersionRig(t, 300)
	r.a.Cfg.Versions = map[string]VersionChoice{"film": {Media: "film-13", At: 1}}
	it := r.item(t, "film")
	it.ViewOffset = 120
	r.a.PlayQueue(it, it.ViewOffset, nil, 0, nil)
	if !sameParts(r.playedParts(), "pfilm-13") {
		t.Fatalf("resume played %v (top %T), want the recorded 480p unasked", r.playedParts(), r.a.top())
	}
	if !strings.Contains(r.logs.String(), "chosen: remembered") {
		t.Fatalf("log:\n%s", r.logs.String())
	}

	r.a.PlayQueue(it, 0, nil, 0, nil)
	if ch := r.chooser(t); ch.cur != 2 {
		t.Fatalf("From start selected %d, want the recorded 480p", ch.cur)
	}
	r.a.Pop()

	delete(r.a.Cfg.Versions, "film")
	r.a.PlayQueue(it, 120, nil, 0, nil)
	if ch := r.chooser(t); ch.cur != 1 {
		t.Fatalf("unrecorded resume selected %d, want our pick", ch.cur)
	}
}

// A finished playback forgets the version: the next play is from the start.
func TestFinishingForgetsTheVersion(t *testing.T) {
	r := newVersionRig(t, 990)
	r.a.PlayQueue(r.item(t, "film"), 0, nil, 0, nil)
	r.pick(t, 0) // the 1080p original, which the server converts
	if !sameParts(r.playedParts(), "mediaIndex 0") {
		t.Fatalf("played %v", r.playedParts())
	}
	if _, ok := r.a.Cfg.Versions["film"]; ok {
		t.Fatal("a finished item kept its version")
	}
}

// The next episode of a queue never asks: it plays the kind the show last
// started with, even from a listing's record without the versions' streams.
func TestQueueMatchesTheShowsVersion(t *testing.T) {
	r := newVersionRig(t, 300)
	eps := r.listing(t)
	r.a.PlayQueue(r.item(t, "ep1"), 0, nil, 0, nil)
	r.pick(t, 2)
	if kind := r.a.Cfg.Streams["show"].VersionKind; kind != "480p h264" {
		t.Fatalf("show's kind %q", kind)
	}
	// the queue's next item, as playQueue's loop settles and starts it
	next := eps[1]
	why := r.a.quietVersion(next)
	if why != "matched" || next.VersionID != "ep2-13" {
		t.Fatalf("next episode %q on %q", why, next.VersionID)
	}
	r.a.startingVersion(next, why)
	r.a.playSettled(next, 0, nil, 0, nil, false, why)
	if _, ok := r.a.top().(*Chooser); ok || !sameParts(r.playedParts(), "pep1-13", "pep2-13") {
		t.Fatalf("played %v (top %T), want both episodes' 480p unasked", r.playedParts(), r.a.top())
	}
	if !strings.Contains(r.logs.String(), "version 3 of 3 (media ep2-13) 480p h264, chosen: matched") {
		t.Fatalf("log:\n%s", r.logs.String())
	}
}

// A shuffle never asks; a listing's episode nobody chose a version for gets
// the one that suits the cores from its start, and the item takes it.
func TestShuffleNeverAsks(t *testing.T) {
	r := newVersionRig(t, 300)
	eps := r.listing(t)
	r.a.playQueue(eps[0], 0, eps, 0, nil, true)
	if _, ok := r.a.top().(*Chooser); ok {
		t.Fatal("a shuffle asked")
	}
	if !sameParts(r.playedParts(), "pep1-12") {
		t.Fatalf("played %v, want our pick, the 720p", r.playedParts())
	}
	if eps[0].VersionID != "ep1-12" || r.a.Cfg.Versions["ep1"].Media != "ep1-12" {
		t.Fatalf("item on %q, recorded %v", eps[0].VersionID, r.a.Cfg.Versions)
	}
}

// A listing's item reads its record before asking: the lines need the
// versions' streams.
func TestListingItemReadsItsVersionsFirst(t *testing.T) {
	r := newVersionRig(t, 300)
	eps := r.listing(t)
	r.a.PlayQueue(eps[0], 0, eps, 0, nil)
	if r.a.reading == nil || r.a.Starting.IsZero() {
		t.Fatal("no read of the versions under way")
	}
	for end := time.Now().Add(5 * time.Second); r.a.reading != nil && time.Now().Before(end); time.Sleep(10 * time.Millisecond) {
		r.a.runLater()
	}
	ch := r.chooser(t)
	if ch.cur != 1 || !strings.HasSuffix(ch.items[1], "plays directly") || !eps[0].Versions[0].Detailed() {
		t.Fatalf("chooser at %d: %q", ch.cur, ch.items)
	}
}

// A fresh record keeps the version in force, and the Version row shows it.
func TestFreshRecordKeepsTheVersion(t *testing.T) {
	r := newVersionRig(t, 300)
	it := r.item(t, "film")
	r.a.useVersion(it, "film-13")
	r.a.takeFresh(it, r.item(t, "film"))
	if it.VersionID != "film-13" || it.PartID != "pfilm-13" || it.Audio[0].ID != "afilm-13" {
		t.Fatalf("fresh record on %q, part %q, audio %+v", it.VersionID, it.PartID, it.Audio)
	}
	if row := versionRow(it); row != "Version: 480p H.264" {
		t.Fatalf("row %q", row)
	}
	one := &plex.Item{RatingKey: "x", PartID: "p"}
	if versionRow(one) != "" {
		t.Fatal("a single version item has a Version row")
	}
}

// The movie page's Version row changes the version for the next play and
// records it.
func TestPreplayVersionRow(t *testing.T) {
	r := newVersionRig(t, 300)
	it := r.item(t, "film")
	p := NewPreplay(r.a, it)
	r.a.Push(p)
	if it.VersionID != "film-12" {
		t.Fatalf("page opened on %q, want our pick", it.VersionID)
	}
	at := restoreAction(p.actions, "Version")
	if p.actions[at] != "Version: 720p H.264" {
		t.Fatalf("actions %q", p.actions)
	}
	p.cur = at
	p.Key(input.Event{Key: input.Enter}, time.Now())
	r.pick(t, 0)
	if it.VersionID != "film-11" || r.a.Cfg.Versions["film"].Media != "film-11" || p.actions[p.cur] != "Version: 1080p H.264" {
		t.Fatalf("after the row's pick: %q, recorded %v, row %q", it.VersionID, r.a.Cfg.Versions, p.actions[p.cur])
	}
}
