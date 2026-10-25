package ui

import (
	"context"
	"errors"
	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"time"
)

const serverRequestTimeout = 12 * time.Second

type serverResult struct {
	apply func()
	err   error
}
type serverRequest struct {
	app    *App
	fetch  func(context.Context) (func(), error)
	cancel context.CancelFunc
	result chan serverResult
	failed bool
	choice int
}

// Workers fetch private results only. The UI applies them only while this
// request remains on top; Back cancels immediately and discards late answers.
func (a *App) requestServer(fetch func(context.Context) (func(), error)) {
	s := &serverRequest{app: a, fetch: fetch}
	a.Push(s)
	s.start()
}
func (s *serverRequest) start() {
	if s.cancel != nil {
		s.cancel()
	}
	ctx, cancel := context.WithTimeout(context.Background(), serverRequestTimeout)
	s.cancel, s.failed, s.choice = cancel, false, 0
	result := make(chan serverResult, 1)
	s.result = result
	go func() {
		defer cancel()
		apply, err := s.fetch(ctx)
		if err == nil {
			err = ctx.Err()
		}
		result <- serverResult{apply, err}
		s.app.WakeUp()
	}()
}
func (s *serverRequest) left() {
	if s.cancel != nil {
		s.cancel()
	}
	s.result = nil
}
func (s *serverRequest) Key(ev input.Event, now time.Time) {
	if ev.Release || ev.Repeat || !s.failed {
		return
	}
	switch ev.Key {
	case input.Up, input.Down, input.Left, input.Right:
		s.choice = 1 - s.choice
	case input.Enter:
		if s.choice == 0 {
			s.start()
		} else {
			s.app.Pop()
		}
	}
}
func (s *serverRequest) Draw(c *gfx.Canvas, now time.Time) bool {
	c.Fill(0, 0, c.W, c.H, gfx.Bg)
	title, detail := "Connecting to Plex...", "Back to cancel"
	if s.failed {
		title, detail = "Can't reach Plex", "Check the server and your connection."
	}
	s.app.text(c, SafeX, SafeY+90, s.app.F.Title, gfx.White, title)
	s.app.text(c, SafeX, SafeY+140, s.app.F.Body, gfx.White, detail)
	if s.failed {
		for i, label := range []string{"Retry", "Back"} {
			if i == s.choice {
				label = "> " + label
			}
			s.app.text(c, SafeX, SafeY+200+i*35, s.app.F.Body, gfx.White, label)
		}
	}
	return false
}
func (a *App) pollServerRequest() {
	if len(a.stack) == 0 {
		return
	}
	s, ok := a.top().(*serverRequest)
	if !ok || s.result == nil {
		return
	}
	select {
	case r := <-s.result:
		s.result = nil
		a.dirty = true
		if r.err != nil {
			s.failed = true
			if a.Log != nil {
				a.Log.Printf("server request: %v", r.err)
			}
			a.serverResult(r.err)
			a.SessionEnded(r.err)
			return
		}
		a.serverResult(nil)
		a.Pop()
		if r.apply != nil {
			r.apply()
		}
	default:
	}
}

// Called on the UI thread; cached screens remain usable during an outage.
func (a *App) serverResult(err error) {
	if errors.Is(err, context.Canceled) {
		return
	}
	a.serverOffline = err != nil
	a.dirty = true
}
