package ui

import (
	"slices"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/plex"
)

// Show is one screen with two layouts. Its identity, transition, logo and
// selected season survive a layout change; only leaving the show pops a screen.
// Home and Season supply the existing picker and episode layout drawing.
type Show struct {
	periodic    viewRefresh
	app         *App
	item        *plex.Item
	seasons     []*plex.Item // the picker's row without its Shuffle tile
	picker      *Home
	season      *Season
	episodes    bool
	direct      bool // opened at an episode: Back returns to its original caller
	fade        Fade
	logo        logoLayer
	transition  *Handoff
	cadenceAt   time.Time
	cadenceStep int
	presentedAt time.Time // animation time of the most recently drawn frame
	trace       *transitionTrace
}

// ShuffleTile is the type of the tile that ends the season picker's row:
// OK on it plays every episode of the show in a random order.
const ShuffleTile = "shuffle"

func NewShow(app *App, show *plex.Item, seasons []*plex.Item) *Show {
	v := &Show{app: app, item: show, seasons: seasons}
	v.picker = &Home{app: app, fixed: show, view: v}
	row := seasons
	if len(seasons) > 0 {
		// a row of its own: the seasons' slice never holds the tile
		row = append(slices.Clip(seasons), &plex.Item{Type: ShuffleTile, Title: "Shuffle"})
	}
	v.picker.setHubs([]*plex.Hub{{Title: "Seasons", Items: row}})
	v.picker.focusSeason(0)
	return v
}

func NewShowInSeason(app *App, show *plex.Item, seasons []*plex.Item, si int, at string) *Show {
	v := NewShow(app, show, seasons)
	v.picker.focusSeason(si)
	v.season = NewSeason(app, show, seasons, si, at)
	v.season.view = v
	v.episodes, v.direct = true, true
	v.season.rebuild() // the episode's actions gain Go to show
	return v
}

func (v *Show) Key(ev input.Event, now time.Time) {
	if !v.cadenceAt.IsZero() {
		now = v.presentedAt
	}
	if v.episodes {
		v.season.Key(ev, now)
	} else {
		v.picker.Key(ev, now)
	}
}

func (v *Show) Draw(c *gfx.Canvas, now time.Time) bool {
	if v.transition != nil {
		v.traceStart()
		v.cadenceAt, v.cadenceStep = now, 0
	} else if !v.fade.Running() || !v.fade.layout {
		v.cadenceAt = time.Time{}
	}
	if !v.cadenceAt.IsZero() {
		if t := v.trace; t != nil && t.Count < len(t.Frames) {
			t.Frames[t.Count] = transitionTraceFrame{Requested: v.cadenceStep, Ready: int(v.fade.ready.Load()), Begin: t.point()}
		}
		if v.cadenceStep > 0 && v.cadenceStep < v.fade.n {
			ready := v.fade.waitReady(v.cadenceStep, 4*time.Millisecond)
			if v.cadenceStep > ready && v.app.Log != nil {
				v.app.Log.Printf("show transition worker held step %d at %d", v.cadenceStep, ready)
			}
			v.cadenceStep = min(v.cadenceStep, ready)
		}
		now = v.cadenceAt.Add(time.Duration(v.cadenceStep) * transitionFrame)
		if t := v.trace; t != nil && t.Count < len(t.Frames) {
			t.Frames[t.Count].Chosen = v.cadenceStep
		}
		v.cadenceStep++
	}
	v.presentedAt = now
	var anim bool
	if v.episodes {
		anim = v.season.Draw(c, now)
	} else {
		anim = v.picker.Draw(c, now)
	}
	if !v.fade.Transitioning(now) {
		v.cadenceAt = time.Time{}
	}
	return anim
}

func (v *Show) pacedTransition() bool {
	return v.transition != nil || !v.cadenceAt.IsZero()
}

func (v *Show) Back() bool {
	if v.episodes && !v.direct {
		v.overview(time.Now())
		return true
	}
	v.fade.Done()
	return false
}

// begin keeps the existing layout alive as the transition source. Only a
// rapid reversal needs a snapshot of a shared intermediate fade buffer.
func (v *Show) begin(page *gfx.Canvas, now time.Time) {
	if page == nil {
		return
	}
	if !v.cadenceAt.IsZero() {
		now = v.presentedAt
	}
	artY := 0
	if v.episodes {
		artY = SeasonLift
	}
	if v.fade.Transitioning(now) {
		artY = v.fade.ArtY(now)
	}
	if frame, running := v.fade.Frame(now); running {
		page = snapshot(frame)
	}
	v.fade.Done()
	img, x, y := v.logo.cur(now)
	v.transition = &Handoff{Page: page, Logo: img, X: x, Y: y, ArtY: artY}
}

func (v *Show) takeTransition() *Handoff {
	h := v.transition
	v.transition = nil
	return h
}

func (v *Show) ensureSeason(si int, at string) {
	if v.season == nil {
		v.season = NewSeason(v.app, v.item, v.seasons, si, at)
		v.season.view = v
	} else if v.season.si != si || at != "" {
		v.season.si = si
		v.season.load(at)
	}
}

func (v *Show) prepareSeason(now time.Time) {
	// The shared fade may still read a hidden layout after a quick reversal.
	if v.fade.Running() || v.transition != nil {
		return
	}
	v.fade.Done() // a late worker must release the hidden layout before reuse
	v.ensureSeason(v.picker.col[0], "")
	v.season.prime(now)
}

func (v *Show) enterSeason(si int, at string, now time.Time) {
	v.begin(v.picker.page, now)
	v.ensureSeason(si, at)
	if v.season.err != nil {
		v.season.load(at) // an explicit opening retries a failed background load
	}
	v.episodes, v.direct = true, false
	v.app.dirty = true
}

func (v *Show) overview(now time.Time) {
	v.begin(v.season.page, now)
	if v.season.pick {
		v.season.pick = false
		v.season.entryKey = ""
	}
	if v.picker.col[0] != v.season.si {
		v.picker.focusSeason(v.season.si)
	}
	direct := v.direct
	v.episodes, v.direct = false, false
	if direct {
		v.season.rebuild() // Back returns here now: Go to show goes
	}
	v.app.dirty = true
}

// shuffle plays the whole show in a random order, then then (when not nil).
// Watched marks may have changed in any season, so the picker and the
// episode page fetch theirs again at once, not at the next periodic refresh.
func (v *Show) shuffle(then func()) {
	v.app.Shuffle(v.item, func() {
		v.periodic.soon()
		if v.season != nil {
			v.season.periodic.soon()
		}
		if then != nil {
			then()
		}
	})
}
