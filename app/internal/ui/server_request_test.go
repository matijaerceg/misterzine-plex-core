package ui

import (
	"context"
	"errors"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/plex"
	"sync/atomic"
	"testing"
	"time"
)

type outageTestScreen struct{ presses int }

func (s *outageTestScreen) Key(input.Event, time.Time)       { s.presses++ }
func (s *outageTestScreen) Draw(*gfx.Canvas, time.Time) bool { return false }
func outageTestApp() (*App, *outageTestScreen) {
	root := &outageTestScreen{}
	return &App{stack: []Screen{root}, Wake: make(chan struct{}, 1), Log: log.New(io.Discard, "", 0)}, root
}
func settleServerRequest(t *testing.T, a *App) {
	t.Helper()
	// Older screen unit tests exercise a page without the normal root screen.
	if len(a.stack) == 1 {
		if _, ok := a.top().(*serverRequest); ok {
			a.stack = append([]Screen{&outageTestScreen{}}, a.stack...)
		}
	}
	deadline := time.Now().Add(4 * time.Second)
	for time.Now().Before(deadline) {
		a.runLater()
		s, ok := a.top().(*serverRequest)
		if !ok || s.failed {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("server request did not finish")
}
func TestServerRequestCancelKeepsNavigationResponsive(t *testing.T) {
	a, root := outageTestApp()
	entered, canceled := make(chan struct{}), make(chan struct{})
	applied := false
	a.requestServer(func(ctx context.Context) (func(), error) {
		close(entered)
		<-ctx.Done()
		close(canceled)
		return func() { applied = true }, nil
	})
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("worker did not start")
	}
	a.key(input.Event{Key: input.Back}, time.Now())
	a.key(input.Event{Key: input.Right}, time.Now())
	if a.top() != root || root.presses != 1 {
		t.Fatal("Back did not restore responsive cached screen")
	}
	select {
	case <-canceled:
	case <-time.After(time.Second):
		t.Fatal("request was not canceled")
	}
	a.runLater()
	if applied {
		t.Fatal("canceled response navigated")
	}
}
func TestServerRequestFailureRetryAndRecovery(t *testing.T) {
	a, root := outageTestApp()
	calls := 0
	applied := false
	a.requestServer(func(ctx context.Context) (func(), error) {
		calls++
		if calls == 1 {
			return nil, errors.New("offline")
		}
		return func() { applied = true }, nil
	})
	settleServerRequest(t, a)
	s, ok := a.top().(*serverRequest)
	if !ok || !s.failed || !a.serverOffline {
		t.Fatal("missing outage feedback")
	}
	a.key(input.Event{Key: input.Enter}, time.Now())
	settleServerRequest(t, a)
	if a.top() != root || !applied || a.serverOffline || calls != 2 {
		t.Fatal("retry did not recover")
	}
}
func TestServerRequestIgnoresLateSuccessAfterBack(t *testing.T) {
	a, root := outageTestApp()
	release := make(chan struct{})
	done := make(chan struct{})
	applied := false
	a.requestServer(func(context.Context) (func(), error) {
		<-release
		defer close(done)
		return func() { applied = true }, nil
	})
	a.key(input.Event{Key: input.Back}, time.Now())
	close(release)
	<-done
	a.runLater()
	if applied || a.top() != root {
		t.Fatal("late success changed page")
	}
}

func TestOpenItemCancelsStalledHTTP(t *testing.T) {
	entered, canceled := make(chan struct{}), make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(entered)
		<-r.Context().Done()
		close(canceled)
	}))
	defer srv.Close()
	a, root := outageTestApp()
	a.Plex = plex.New(srv.URL, "", "", "test-device")
	a.Open(&plex.Item{RatingKey: "film", Type: "movie"}, false)
	// If Open still waits for HTTP, this test never reaches Back.
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("HTTP request not started")
	}
	a.key(input.Event{Key: input.Back}, time.Now())
	select {
	case <-canceled:
	case <-time.After(time.Second):
		t.Fatal("Back did not cancel HTTP")
	}
	a.key(input.Event{Key: input.Right}, time.Now())
	if a.top() != root || root.presses != 1 {
		t.Fatal("cached navigation blocked")
	}
}

func TestMenuDoesNotFetchMissingLibraries(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { calls.Add(1); http.Error(w, "offline", 503) }))
	defer srv.Close()
	a, _ := outageTestApp()
	a.Plex = plex.New(srv.URL, "", "", "test-device")
	a.F = appFonts()
	a.Mark = NewWordmark()
	a.T = gfx.NewTextCache(1, a.Wake)
	a.Menu()
	if _, ok := a.top().(*Drawer); !ok {
		t.Fatal("menu did not open")
	}
	if calls.Load() != 0 {
		t.Fatal("menu made a blocking library request")
	}
}
