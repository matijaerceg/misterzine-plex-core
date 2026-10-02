package ui

import (
	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/ring"
	"time"
)

func (a *App) chooseVideo() {
	r, ok := a.Out.(*ring.Ring)
	if !ok {
		return
	}
	if r.VideoLocked() {
		a.Notice = "CRT profile: output is locked to 480i."
		a.NoticeAt = time.Now()
		return
	}
	_, override, supported := r.VideoStatus()
	if !supported || override {
		a.Notice = "Update the core to change video output."
		if override {
			a.Notice = "Set Video output to App settings in the core menu."
		}
		a.NoticeAt = time.Now()
		return
	}
	current := 0
	if a.Cfg.Progressive {
		current = 1
	}
	a.Push(NewChooser(a, a.top(), "Video output", []string{"480i (CRT)", "480p (HDMI)"}, current, func(i int) {
		mode := uint32(0)
		if i == 1 {
			mode = 2
		}
		if i == current {
			return
		}
		a.Push(&VideoConfirm{app: a, ring: r, mode: mode, deadline: r.TryVideo(mode)})
	}))
}

type VideoConfirm struct {
	app      *App
	ring     *ring.Ring
	mode     uint32
	deadline time.Time
	hold     videoHold
}

// The press that selected the mode must be released before a new hold can
// begin. Auto-repeat and repeated taps cannot accumulate confirmation time.
type videoHold struct {
	armed bool
	since time.Time
}

func (h *videoHold) key(ev input.Event, now time.Time) {
	if ev.Key != input.Enter {
		return
	}
	if ev.Release {
		h.armed = true
		h.since = time.Time{}
		return
	}
	if ev.Repeat || !h.armed {
		return
	}
	h.since = now
}
func (h *videoHold) ready(now time.Time) bool {
	return !h.since.IsZero() && now.Sub(h.since) >= 2*time.Second
}

func (v *VideoConfirm) Back() bool { v.ring.FinishVideo(false); v.app.Pop(); return true }

func (v *VideoConfirm) Key(ev input.Event, now time.Time) {
	v.hold.key(ev, now)
}

func (v *VideoConfirm) accept(now time.Time) {
	actual, override, supported := v.ring.VideoStatus()
	if !supported || override || actual != v.mode {
		return
	}
	if v.ring.FinishVideo(true) {
		old := v.app.Cfg.Progressive
		v.app.Cfg.Progressive = v.mode == 2
		if err := v.app.Cfg.Save(); err != nil {
			v.app.Cfg.Progressive = old
			mode := uint32(0)
			if old {
				mode = 2
			}
			v.ring.SetVideo(mode)
			v.app.Notice, v.app.NoticeAt = "Could not save video setting.", now
		} else {
			v.app.saveBootMode(v.ring)
		}
	}
	v.app.Pop()
}

func (v *VideoConfirm) Draw(c *gfx.Canvas, now time.Time) bool {
	if v.ring.VideoLocked() {
		v.ring.FinishVideo(false)
		v.app.Pop()
		v.app.Notice, v.app.NoticeAt = "CRT profile: output is locked to 480i.", now
		return v.app.top().Draw(c, now)
	}
	if !now.Before(v.deadline) {
		v.ring.FinishVideo(false)
		v.app.Pop()
		return v.app.top().Draw(c, now)
	}
	if v.hold.ready(now) {
		v.accept(now)
		if v.app.top() != v {
			return v.app.top().Draw(c, now)
		}
	}
	c.Fill(0, 0, c.W, c.H, gfx.Bg)
	v.app.text(c, SafeX, SafeY+60, v.app.F.Title, gfx.White, "Keep this video mode?")
	v.app.text(c, SafeX, SafeY+112, v.app.F.Body, gfx.GreyHi, "Hold OK for 2 seconds to keep this mode")
	v.app.text(c, SafeX, SafeY+146, v.app.F.Body, gfx.GreyHi, "Back: restore previous mode")
	c.Fill(SafeX, SafeY+192, SafeW, 4, gfx.Bar)
	if !v.hold.since.IsZero() {
		w := min(SafeW, int(float64(SafeW)*now.Sub(v.hold.since).Seconds()/2))
		c.Fill(SafeX, SafeY+192, w, 4, gfx.Amber)
	}
	v.app.text(c, SafeX, SafeY+220, v.app.F.Body, gfx.Amber,
		"Restoring in "+itoa(int(v.deadline.Sub(now).Seconds())+1)+" seconds")
	return true
}

func (a *App) videoLocked() bool {
	r, ok := a.Out.(*ring.Ring)
	return ok && r.VideoLocked()
}
