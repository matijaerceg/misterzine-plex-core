package ui

import (
	"bytes"
	"fmt"
	"log"
	"net/http"
	"net/http/httptest"
	"os/exec"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/plex"
)

// resumeRig is an app whose player plays an item from wherever it is asked
// and stops at stopAt, against a server that holds each stopped report
// until release and answers the item with serverAt until then, after with
// laterAt.
type resumeRig struct {
	a        *App
	logs     *syncBuffer
	release  chan struct{}
	released atomic.Bool
}

type syncBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.b.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.b.String()
}

func newResumeRig(t *testing.T, stopAt float64, serverAt, laterAt int) *resumeRig {
	t.Helper()
	r := &resumeRig{release: make(chan struct{}), logs: &syncBuffer{}}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		switch req.URL.Path {
		case "/:/timeline":
			if req.URL.Query().Get("state") == "stopped" {
				<-r.release
			}
			_, _ = w.Write([]byte(`<MediaContainer/>`))
		case "/library/metadata/item":
			at := serverAt
			if r.released.Load() {
				at = laterAt
			}
			x := strings.ReplaceAll(fmt.Sprintf(playMetadata, playVideoDirect, 4500), `duration="300000"`, `duration="1000000"`)
			x = strings.Replace(x, `title="Film"`, fmt.Sprintf(`title="Film" viewOffset="%d"`, at*1000), 1)
			_, _ = w.Write([]byte(x))
		default:
			_, _ = w.Write([]byte(`<MediaContainer/>`))
		}
	}))
	t.Cleanup(func() {
		r.free()
		srv.Close()
	})
	client := plex.New(srv.URL, "synthetic-token", t.TempDir(), "device")
	dir := t.TempDir()
	status := dir + "/status"
	p := &Player{Client: client, Binary: "jfplay-test", Fifo: dir + "/fifo", Status: status, LogTo: dir + "/log"}
	p.exec = func(string, ...string) *exec.Cmd {
		script := fmt.Sprintf("printf 'state=playing\\nposition=%g\\nduration=1000\\n' > '%s'", stopAt, status)
		return exec.Command("sh", "-c", script)
	}
	r.a = &App{Log: log.New(r.logs, "", 0), Out: &foreignOut{gfx.NewCanvas(8, 4)}, Plex: client, Player: p,
		Cfg: &Config{NoTheme: true}, Wake: make(chan struct{}, 1), later: make(chan func(), 32)}
	return r
}

func (r *resumeRig) free() {
	if r.released.CompareAndSwap(false, true) {
		close(r.release)
	}
}

// settle runs the render thread's queued work until done says the
// server's answer after the release has been taken.
func (r *resumeRig) settle(t *testing.T, done func() bool) {
	t.Helper()
	for end := time.Now().Add(5 * time.Second); time.Now().Before(end); time.Sleep(10 * time.Millisecond) {
		r.a.runLater()
		if done() {
			return
		}
	}
	t.Fatal("the server's record was never asked for")
}

func filmCopy() *plex.Item {
	return &plex.Item{RatingKey: "item", Type: "movie", Title: "Film", Duration: 1000, ViewOffset: 702, PartID: "part"}
}

// Back pressed at 714: the item and every screen's copy of it resume from
// 714 at once, while the stopped report is still on its way and the server
// still says 702, and take the server's record once that is in.
func TestResumePointFollowsPlaybackBeforeTheServer(t *testing.T) {
	r := newResumeRig(t, 714.4, 702, 716)
	it, row, ep := filmCopy(), filmCopy(), filmCopy()
	home := &Home{app: r.a, home: true, hubs: []*plex.Hub{{Title: "Continue Watching", Items: []*plex.Item{row}}}}
	season := &Season{app: r.a, eps: []*plex.Item{ep}}
	r.a.stack = []Screen{home, season}

	r.a.PlayQueue(it, it.ViewOffset, nil, 0, nil)
	for name, c := range map[string]*plex.Item{"played": it, "home row": row, "season": ep} {
		if c.ViewOffset != 714 {
			t.Errorf("%s copy resumes at %d before the report, want 714", name, c.ViewOffset)
		}
	}
	if home.refreshAt.IsZero() {
		t.Error("Home's rows are asked for before the stopped report is in")
	}

	go func() { time.Sleep(200 * time.Millisecond); r.free() }()
	r.a.PlayQueue(it, it.ViewOffset, nil, 0, nil)
	if !strings.Contains(r.logs.String(), "play Film (item) at 714") {
		t.Fatalf("second play did not resume at 714:\n%s", r.logs.String())
	}
	r.settle(t, func() bool { return it.ViewOffset == 716 })
	for name, c := range map[string]*plex.Item{"played": it, "home row": row, "season": ep} {
		if c.ViewOffset != 716 {
			t.Errorf("%s copy at %d after the server's record, want its 716", name, c.ViewOffset)
		}
	}
	if !home.refreshAt.IsZero() {
		t.Error("Home's rows were not asked for again once the report was in")
	}
}

// A playback stopped in its last tenth is watched: no resume point, the
// check mark, in every copy.
func TestResumePointClearsWhenPlaybackEnds(t *testing.T) {
	r := newResumeRig(t, 990, 702, 0)
	it, row := filmCopy(), filmCopy()
	r.a.stack = []Screen{&Home{app: r.a, home: true, hubs: []*plex.Hub{{Items: []*plex.Item{row}}}}}
	r.a.PlayQueue(it, it.ViewOffset, nil, 0, nil)
	for name, c := range map[string]*plex.Item{"played": it, "home row": row} {
		if c.ViewOffset != 0 || c.ViewCount != 1 {
			t.Errorf("%s copy: offset %d, count %d; want 0, 1", name, c.ViewOffset, c.ViewCount)
		}
	}
}

// foreignOut is a presenter whose picture is another process's from the
// start: playLoop sees the playback up at once and draws nothing.
type foreignOut struct{ c *gfx.Canvas }

func (p *foreignOut) Begin() *gfx.Canvas                   { return p.c }
func (p *foreignOut) End()                                 {}
func (p *foreignOut) WaitField(time.Duration)              {}
func (p *foreignOut) Missed() bool                         { return false }
func (p *foreignOut) Foreign() bool                        { return true }
func (p *foreignOut) Late() (time.Duration, time.Duration) { return 0, 0 }
