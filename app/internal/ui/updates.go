package ui

import (
	"context"
	"fmt"
	"os"
	"plexcrt/internal/beta"
	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/updates"
	"time"
)

type updateState struct {
	catalogue   updates.Catalogue
	checking    bool
	checkFailed bool      // the last check could not read the catalogue
	nextCheck   time.Time // of the automatic check
	nextStatus  time.Time
	reading     bool
	status      updates.Status
	message     string    // the updater could not start, or a choice was not saved
	launched    time.Time // an update started and its updater has not reported yet
	checked     time.Time // when a check last read the catalogue
}

func (a *App) checkUpdates(manual bool, now time.Time) {
	if a.Cfg == nil || a.betaDir() == "" || a.updates.checking {
		return
	}
	if !manual && now.Before(a.updates.nextCheck) {
		return
	}
	a.updates.checking = true
	a.updates.nextCheck = now.Add(6 * time.Hour)
	if manual {
		a.updates.message = ""
	}
	root := a.betaDir()
	go func() {
		cached, cacheErr := updates.Cached(root)
		var c updates.Catalogue
		var err error
		if file := os.Getenv("PLEXCRT_CATALOGUE_FILE"); file != "" {
			// a local catalogue stands in for the published one (testing)
			var data []byte
			if data, err = os.ReadFile(file); err == nil {
				c, err = updates.Parse(data)
			}
		} else {
			c, err = updates.Fetch(context.Background(), nil, updates.CatalogueURL)
		}
		if err == nil {
			_ = updates.SaveCache(root, c)
		}
		a.Later(func() {
			a.updates.checking = false
			a.updates.checkFailed = err != nil
			if err != nil {
				// a failure is no check: the first one usually runs before
				// the MiSTer has its network or its clock
				a.updates.nextCheck = time.Now().Add(5 * time.Minute)
				if cacheErr == nil && a.updates.catalogue.Releases == nil {
					a.updates.catalogue = cached
				}
				return
			}
			a.updates.catalogue = c
			a.updates.checked = time.Now()
		})
	}()
}
func (a *App) pollUpdates(now time.Time) {
	if a.Cfg == nil || a.betaDir() == "" {
		return
	}
	a.checkUpdates(false, now)
	if a.updates.reading || now.Before(a.updates.nextStatus) {
		return
	}
	a.updates.reading = true
	a.updates.nextStatus = now.Add(time.Second)
	root := a.betaDir()
	go func() {
		s := updates.ReadStatus(root)
		a.Later(func() {
			a.updates.reading = false
			if !a.updates.launched.IsZero() && s.Updated < float64(a.updates.launched.UnixNano())/1e9 {
				if time.Since(a.updates.launched) >= 10*time.Second && a.updates.status.Stage != "failed" {
					a.updates.status = updates.Status{Stage: "failed", Updated: float64(time.Now().UnixNano()) / 1e9,
						Release: a.updates.status.Release, Message: "The updater did not start. Run Install to repair update support."}
				}
				// the file still holds what came before the launch: keep saying
				// what this update is doing until its updater reports
				return
			}
			a.updates.launched = time.Time{}
			a.updates.status = s
		})
	}()
}

// ownChannel is the channel whose releases come first: a development build
// is told about releases as a public one is.
func ownChannel() string {
	if beta.Channel == "beta" {
		return "beta"
	}
	return "public"
}

// channelName is what the screens call a channel.
func channelName(channel string) string {
	switch channel {
	case "beta":
		return "Beta"
	case "public":
		return "Stable"
	}
	return "Development"
}

// offered lists the catalogue releases Updates can install, own channel first.
func (a *App) offered() []updates.Release {
	var out []updates.Release
	own := ownChannel()
	other := "beta"
	if own == "beta" {
		other = "public"
	}
	for _, channel := range []string{own, other} {
		if r, ok := a.updates.catalogue.Releases[channel]; ok && a.offers(r) {
			out = append(out, r)
		}
	}
	return out
}

// offers reports whether Updates may install r: it is newer than the running
// release, or the public release a beta build of the same version is told
// about. The running release and older ones never are.
func (a *App) offers(r updates.Release) bool {
	if r.ID == a.Build {
		return false
	}
	newer, ok := updates.Compare(r.Version, a.Version)
	return ok && newer > 0 || a.notifies(r)
}
func (a *App) notifies(r updates.Release) bool {
	return a.Cfg != nil && updates.Notify(r, a.Version, beta.Channel, a.Cfg.EarlyAccessUpdates)
}

// nextUpdate is the release Updates leads with and the UPDATE mark is about.
// A newer release it does not notify about (a beta on a public build with
// beta notifications off) is still offered, on a row of its own.
func (a *App) nextUpdate() *updates.Release {
	for _, r := range a.offered() {
		if a.notifies(r) {
			return &r
		}
	}
	return nil
}

// updateAvailable is what the UPDATE mark, the drawer badge and the Options
// row call attention with: a download to restart into, an update, or a
// failed one to try again.
func (a *App) updateAvailable() bool {
	return a.prepared() != nil || a.nextUpdate() != nil || a.failure()
}

// prepared is the release a finished download installs on Restart now, while
// it is one Updates would offer. A download left ready before a rollback, or
// before a script installed that release, is not: it would put back the
// running release or an older one.
func (a *App) prepared() *updates.Release {
	s := a.updates.status
	if s.Stage != "ready" || s.Release == nil || !a.offers(*s.Release) {
		return nil
	}
	return s.Release
}

// failure reports a failed update that still needs explaining: one that names
// no release (the updater never started), or one for a release still ahead of
// this build. It stays, whatever the catalogue says since, until the next
// update starts, or until a check made after it finds nothing to install:
// then there is nothing to try again.
func (a *App) failure() bool {
	s := a.updates.status
	if s.Stage != "failed" || s.Release != nil && !a.offers(*s.Release) {
		return false
	}
	at := time.Unix(0, int64(s.Updated*1e9))
	return !a.updates.checked.After(at) || len(a.offered()) > 0
}

// retry is what a failed update offers next: the failed release while it is
// offered, even quietly (a beta on a public build), else the update the mark
// is about, else any release offered.
func (a *App) retry() *updates.Release {
	s := a.updates.status
	offered := a.offered()
	for _, r := range offered {
		if s.Release != nil && s.Release.ID == r.ID {
			return &r
		}
	}
	if next := a.nextUpdate(); next != nil {
		return next
	}
	if len(offered) > 0 {
		return &offered[0]
	}
	return nil
}
func (a *App) startUpdate(action string, r *updates.Release) {
	if a.updates.status.Busy() || !a.Starting.IsZero() {
		return
	}
	if err := updates.Start(a.betaDir(), action, r); err != nil {
		a.updates.message = "Could not start the updater. Run MisterZine-Plex-Install to repair update support."
		return
	}
	stage, shown := "download", r
	if action == "activate" {
		stage, shown = "activating", a.prepared()
	}
	a.updates.launched = time.Now()
	a.updates.message = ""
	a.updates.status = updates.Status{Stage: stage, Release: shown}
}

// Updates is available on both public and beta builds; notifications are quieter
// than the full catalogue so public users are not repeatedly offered paid betas.
// The screen leads with where things stand and offers the one next step.
type Updates struct {
	app     *App
	cur     int
	release *updates.Release // needs a code this card does not hold
	shown   updateView       // the view last drawn
}
type updateAction struct {
	label string
	do    func()
}
type updateView int

const (
	viewChecking updateView = iota
	viewCheckFailed
	viewCurrent
	viewAvailable
	viewWorking
	viewReady
	viewFailed
	viewCode
)

func NewUpdates(a *App) *Updates {
	a.checkUpdates(true, time.Now())
	return &Updates{app: a, shown: -1}
}

// install starts r, or first asks for the code r needs.
func (u *Updates) install(r updates.Release) {
	a := u.app
	if r.Requirement().Check(a.betaDir()) != nil {
		u.release = &r
		return
	}
	a.startUpdate("prepare", &r)
}

// view says what the screen shows and the rows it offers there.
func (u *Updates) view() (updateView, []updateAction) {
	a := u.app
	s := a.updates.status
	switch {
	case s.Busy():
		return viewWorking, nil
	case u.release != nil:
		r := *u.release
		return viewCode, []updateAction{
			{"Enter code and update", func() {
				b := NewBetaAccess(a, func() { u.release = nil; a.startUpdate("prepare", &r) })
				b.requirement = r.Requirement()
				b.version = r.Version
				a.Push(b)
			}},
			{"Install for browsing", func() { u.release = nil; a.startUpdate("prepare", &r) }},
			{"Cancel", func() { u.release = nil }},
		}
	case a.prepared() != nil:
		return viewReady, []updateAction{{"Restart now", func() { a.startUpdate("activate", nil) }}, {"Later", func() { a.Pop() }}}
	}
	var v updateView
	var rows []updateAction
	var lead *updates.Release // the release the first row installs
	check := updateAction{"Check again", func() { a.checkUpdates(true, time.Now()) }}
	switch {
	case a.failure():
		// the way on is whatever is offered now, which may not be the
		// release that failed
		v, rows = viewFailed, []updateAction{check}
		if lead = a.retry(); lead != nil {
			r := *lead
			label := "Update to " + r.Version
			if s.Release == nil || s.Release.ID == r.ID {
				label = "Try again"
			}
			rows[0] = updateAction{label, func() { u.install(r) }}
		}
	case a.nextUpdate() != nil:
		// an update known from an earlier check is offered while the next
		// check runs, and when that check cannot reach the catalogue
		lead = a.nextUpdate()
		r := *lead
		v, rows = viewAvailable, []updateAction{{"Update now", func() { u.install(r) }}}
	case a.updates.checking:
		v = viewChecking
	case a.updates.checkFailed:
		v, rows = viewCheckFailed, []updateAction{{"Try again", func() { a.checkUpdates(true, time.Now()) }}}
	default:
		v, rows = viewCurrent, []updateAction{check}
	}
	for _, r := range a.offered() {
		if lead != nil && r.ID == lead.ID {
			continue
		}
		rows = append(rows, updateAction{"Install " + channelName(r.Channel) + " " + r.Version, func() { u.install(r) }})
	}
	if beta.Channel != "beta" {
		label := "Beta notifications: Off"
		if a.Cfg.EarlyAccessUpdates {
			label = "Beta notifications: On"
		}
		rows = append(rows, updateAction{label, func() {
			a.Cfg.EarlyAccessUpdates = !a.Cfg.EarlyAccessUpdates
			if err := a.Cfg.Save(); err != nil {
				a.Cfg.EarlyAccessUpdates = !a.Cfg.EarlyAccessUpdates
				a.updates.message = "Could not save notification preference."
			}
		}})
	}
	return v, rows
}

// shows is what Draw calls: it brings the focus back to the top row whenever
// the screen changes what it shows, so a finished download lands on Restart now.
func (u *Updates) shows() (updateView, []updateAction) {
	v, rows := u.view()
	if v != u.shown {
		u.shown = v
		u.cur = 0
	}
	u.cur = max(0, min(u.cur, len(rows)-1))
	return v, rows
}
func (u *Updates) Back() bool {
	if u.release != nil {
		u.release = nil
		return true
	}
	u.app.Pop()
	return true
}
func (u *Updates) Key(ev input.Event, now time.Time) {
	if ev.Release {
		return
	}
	v, rows := u.view()
	if v != u.shown || len(rows) == 0 {
		// the screen changed since it was drawn: the press was for what was there
		return
	}
	u.cur = max(0, min(u.cur, len(rows)-1))
	switch ev.Key {
	case input.Up:
		u.cur = max(0, u.cur-1)
	case input.Down:
		u.cur = min(len(rows)-1, u.cur+1)
	case input.Enter:
		if !ev.Repeat {
			rows[u.cur].do()
		}
	}
}

// stageText says what a busy updater is doing. The worker's own messages
// name its internals, so the screen keeps its own words for them.
func stageText(stage string) string {
	switch stage {
	case "verify":
		return "Checking the download..."
	case "install":
		return "Getting it ready..."
	case "activating":
		return "Restarting Plex..."
	}
	return "Downloading..."
}

const (
	updateHeadY = 96  // the headline
	updateRowsY = 216 // the first row, the same in every view but the code one
)

func (u *Updates) Draw(c *gfx.Canvas, now time.Time) bool {
	c.Fill(0, 0, c.W, c.H, gfx.Bg)
	a := u.app
	f := a.F
	a.text(c, MenuX, SafeY, f.Title, gfx.Grey, "Updates")
	v, rows := u.shows()
	s := a.updates.status
	installed := "Installed: " + a.Version + " - " + channelName(beta.Channel)
	y := updateHeadY
	head := func(text string, col gfx.Color) {
		a.text(c, MenuX, y, f.Big, col, f.Big.Fit(text, MenuWidth))
		y += 44
	}
	line := func(font *gfx.Font, col gfx.Color, text string) {
		a.text(c, MenuX, y, font, col, font.Fit(text, MenuWidth))
		y += 28
	}
	release := func(r *updates.Release) string {
		return r.Version + " - " + channelName(r.Channel)
	}
	var note string
	var noteDetail string
	switch v {
	case viewCode:
		r := u.release
		line(f.Body, gfx.Amber, release(r))
		y += 8
		for _, text := range []string{"This release requires a new Patreon code.", "Your current version will keep working."} {
			line(f.Body, gfx.GreyHi, text)
		}
		a.text(c, MenuX, y+4, f.SmallBold, gfx.Purple, patreonAddress)
		y += 60
	case viewWorking:
		head(stageText(s.Stage), gfx.Grey)
		if s.Stage != "activating" {
			line(f.Body, gfx.GreyHi, "You can leave this screen, it keeps going.")
		}
		if s.Release != nil {
			line(f.SmallBold, gfx.GreyLo, "Updating to "+release(s.Release))
		}
	case viewReady:
		head(a.prepared().Version+" is ready", gfx.Amber)
		line(f.Body, gfx.GreyHi, "Plex will restart to finish updating.")
	case viewFailed:
		head("Update failed", gfx.Grey)
		if s.Release != nil {
			line(f.Body, gfx.GreyHi, release(s.Release))
		}
		line(f.SmallBold, gfx.GreyLo, installed)
		note, noteDetail = s.Message, s.Detail
		if note == "" {
			note = "The update did not finish. Your current version will keep working."
		}
	case viewAvailable:
		r := a.nextUpdate()
		head(r.Version+" is available", gfx.Amber)
		line(f.Body, gfx.GreyHi, fmt.Sprintf("%s - %.1f MB", channelName(r.Channel), float64(r.Size)/(1024*1024)))
		line(f.SmallBold, gfx.GreyLo, installed)
	case viewChecking:
		head("Checking for updates...", gfx.Grey)
		line(f.SmallBold, gfx.GreyLo, installed)
	case viewCheckFailed:
		head("Couldn't check for updates", gfx.Grey)
		line(f.Body, gfx.GreyHi, "Check the network and try again.")
		line(f.SmallBold, gfx.GreyLo, installed)
	case viewCurrent:
		head("You're up to date", gfx.Grey)
		line(f.Body, gfx.GreyHi, a.Version+" - "+channelName(beta.Channel))
	}
	y = max(y, updateRowsY)
	for i, it := range rows {
		col := gfx.GreyHi
		if i == u.cur {
			col = gfx.White
			menuFocusBar(c, MenuX, y, f.Body.Height())
		}
		a.text(c, MenuX, y, f.Body, col, f.Body.Fit(it.label, MenuWidth))
		y += MenuRowH
	}
	if a.updates.message != "" && v != viewWorking {
		note, noteDetail = a.updates.message, ""
	}
	if note != "" {
		const lines = 4
		y += 16
		room := lines
		if noteDetail != "" {
			room--
		}
		for _, text := range wrap(f.SmallBold, note, MenuWidth, room) {
			a.text(c, MenuX, y, f.SmallBold, gfx.Purple, text)
			y += 23
		}
		if noteDetail != "" {
			a.text(c, MenuX, y, f.SmallBold, gfx.GreyLo, f.SmallBold.Fit(noteDetail, MenuWidth))
		}
	}
	return false
}
