package ui

import (
	"crypto/x509"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/plex"
)

const sectionsURL = "https://1-2-3-4.0123456789abcdef.plex.direct:32400/library/sections"

func dialErr(err error) error {
	return &url.Error{Op: "Get", URL: sectionsURL, Err: &net.OpError{Op: "dial", Net: "tcp", Err: err}}
}

// As logged on a MiSTer that started Plex a second before its DHCP lease.
var noDNS = dialErr(&net.DNSError{Err: "dial udp [::1]:53: socket: address family not supported by protocol",
	Name: "1-2-3-4.0123456789abcdef.plex.direct", Server: "[::1]:53"})

// As logged behind a router with DNS rebind protection (report RXN6).
var refusedName = dialErr(&net.DNSError{Err: "no such host", Name: "1-2-3-4.0123456789abcdef.plex.direct", IsNotFound: true})

// A refused name is an answer, so the remedy shows at once, with no grace,
// on the Home screen and when signing in.
func TestRefusedLocalNameShowsTheRouterRemedyAtOnce(t *testing.T) {
	app := &App{Log: log.New(io.Discard, "", 0), Cfg: &Config{ServerName: "Den"},
		F: Fonts{Body: gfx.Load("med18"), Small: gfx.Load("reg16")}, T: gfx.NewTextCache(1, make(chan struct{}, 1))}
	now := time.Now()
	h := &Home{app: app, home: true, graceUntil: now.Add(ConnectGrace)}
	h.load(homeResult{err: refusedName}, now)
	if h.connecting || h.problem != problemLocalName || !h.refreshAt.Equal(now.Add(30*time.Second)) {
		t.Fatal("the refused name was retried quietly instead of shown")
	}
	headline, advice := h.problem.failure()
	if headline != routerBlocksName || advice != routerAdvice {
		t.Errorf("Home screen text: %q / %q", headline, advice)
	}
	if app.F.Small.Width(advice) > SafeW || app.F.Body.Width(headline) > SafeW {
		t.Error("the Home screen text does not fit its line")
	}
	h.Draw(gfx.NewCanvas(720, 480), now)

	signIn := reachFailure("server", refusedName)
	if !strings.Contains(signIn, routerAdvice) || len(wrap(app.F.Body, signIn, SafeW, 3)) > 2 {
		t.Errorf("sign-in text missing the remedy or longer than two lines: %q", signIn)
	}
	if got := reachFailure("server", dialErr(os.NewSyscallError("connect", syscall.ECONNREFUSED))); got != "Could not reach server. Press OK to retry." {
		t.Errorf("other failures changed: %q", got)
	}
}

func TestClassifyStartupFailures(t *testing.T) {
	set := time.Date(2026, 9, 24, 12, 0, 0, 0, time.UTC)
	unset := time.Unix(0, 0) // a MiSTer without a clock chip, before the network time
	cert := &url.Error{Op: "Get", URL: sectionsURL, Err: x509.CertificateInvalidError{Reason: x509.Expired}}
	for _, c := range []struct {
		name string
		err  error
		now  time.Time
		want netProblem
	}{
		{"no DNS server yet", noDNS, set, problemNetwork},
		{"no DNS server and no clock", noDNS, unset, problemNetwork},
		{"no route", dialErr(os.NewSyscallError("connect", syscall.ENETUNREACH)), set, problemNetwork},
		{"name does not resolve", dialErr(&net.DNSError{Err: "no such host", Name: "x", IsNotFound: true}), set, problemServer},
		{"router refuses the plex.direct name", refusedName, set, problemLocalName},
		{"router refuses it before the clock is set", refusedName, unset, problemLocalName},
		{"certificate before the clock is set", cert, unset, problemClock},
		{"certificate with the clock set", cert, set, problemServer},
		{"server refuses", dialErr(os.NewSyscallError("connect", syscall.ECONNREFUSED)), set, problemServer},
	} {
		if got := classify(c.err, c.now); got != c.want {
			t.Errorf("%s: got %d, want %d", c.name, got, c.want)
		}
		if !unreachable(c.err) {
			t.Errorf("%s: not seen as no answer", c.name)
		}
	}
	answered := fmt.Errorf("/library/sections: HTTP 401")
	if unreachable(answered) || unreachable(errors.New("XML syntax error")) {
		t.Error("an answer from the server was seen as no answer")
	}
	if got := classify(answered, unset); got != problemServer {
		t.Errorf("an answer before the clock is set was blamed on the clock: %d", got)
	}
}

func TestHomeRetriesQuietlyUntilTheServerAnswers(t *testing.T) {
	app := &App{Log: log.New(io.Discard, "", 0), Cfg: &Config{ServerName: "Den"},
		F: Fonts{Body: gfx.Load("med18"), Small: gfx.Load("reg16")}, T: gfx.NewTextCache(1, make(chan struct{}, 1))}
	now := time.Now()
	h := &Home{app: app, home: true, graceUntil: now.Add(ConnectGrace)}
	canvas := gfx.NewCanvas(720, 480)

	h.load(homeResult{err: noDNS}, now)
	if !h.connecting || h.problem != problemNetwork || !h.refreshAt.Equal(now.Add(ConnectRetry)) {
		t.Fatal("no answer at start was not retried quietly and soon")
	}
	h.Draw(canvas, now)

	answered := &Home{app: app, home: true, graceUntil: now.Add(ConnectGrace)}
	answered.load(homeResult{err: fmt.Errorf("/library/sections: HTTP 401")}, now)
	if answered.connecting || !answered.refreshAt.Equal(now.Add(30*time.Second)) {
		t.Fatal("an answer from the server was hidden behind Connecting")
	}

	// the grace period is over: the error shows, retried every 30 s
	later := now.Add(ConnectGrace)
	h.refreshResult = make(chan homeResult, 1)
	h.refreshResult <- homeResult{err: noDNS}
	h.pollHome(later)
	if h.connecting || h.err == nil || !h.refreshAt.Equal(later.Add(30*time.Second)) {
		t.Fatal("the failure was not shown after the grace period")
	}
	h.Draw(canvas, later)

	// OK retries in the background (no client: a fetch here would panic)
	h.Key(input.Event{Key: input.Enter}, later)
	if !h.connecting || !h.refreshAt.IsZero() {
		t.Fatal("OK did not schedule a background retry")
	}

	h.refreshResult = make(chan homeResult, 1)
	h.refreshResult <- homeResult{hubs: []*plex.Hub{homeRow("continue", "a")},
		secs: []plex.Section{{Key: "1", Title: "Films", Type: "movie"}}}
	h.pollHome(later)
	if h.err != nil || h.connecting || h.Focused().RatingKey != "a" {
		t.Fatal("the rows did not replace the error")
	}
	if _, ok := app.section("1"); !ok {
		t.Fatal("the libraries missed at start were not filled in")
	}
}

func TestFailedUpdateCheckRetriesSoon(t *testing.T) {
	t.Setenv("PLEXCRT_CATALOGUE_FILE", filepath.Join(t.TempDir(), "missing.json"))
	a := &App{Cfg: &Config{path: filepath.Join(t.TempDir(), "plexcrt.json")}, later: make(chan func(), 4)}
	now := time.Now()
	a.checkUpdates(false, now)
	select {
	case f := <-a.later:
		f()
	case <-time.After(5 * time.Second):
		t.Fatal("the check did not finish")
	}
	if !a.updates.nextCheck.Before(now.Add(10 * time.Minute)) {
		t.Fatal("a failed check waits hours before the next one")
	}
	a.checkUpdates(false, time.Now())
	if a.updates.checking {
		t.Fatal("the next check ran straight away")
	}
}
