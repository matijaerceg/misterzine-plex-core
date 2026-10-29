// Package ui is the MisterZine Plex Core front end: screens drawn into a
// 720x480 canvas at 60 fps while anything moves, idle otherwise.
package ui

import (
	"context"
	"errors"
	"fmt"
	"log"
	"math/rand/v2"
	"net/url"
	"os"
	"runtime"
	"runtime/debug"
	"runtime/metrics"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"plexcrt/internal/access"
	"plexcrt/internal/beta"
	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/plex"
	"plexcrt/internal/ring"
)

// Fonts is the type scale settled on the CRT test card (Sept 2026).
type Fonts struct {
	Title     *gfx.Font // 22 Medium
	Body      *gfx.Font // 18 Medium
	BodyLight *gfx.Font // 18 Regular
	Small     *gfx.Font // 16 Regular
	SmallBold *gfx.Font // 16 Medium: facts over pictures (Regular flickers on 480i)
	Big       *gfx.Font // 28 Bold
}

// appFonts loads the type scale.
func appFonts() Fonts {
	return Fonts{Title: gfx.Load("med22"), Body: gfx.Load("med18"), BodyLight: gfx.Load("reg18"),
		Small: gfx.Load("reg16"), SmallBold: gfx.Load("med16"), Big: gfx.Load("bold28")}
}

// Backer is a screen that wants first refusal on Back; it returns true
// when it consumed the press.
type Backer interface {
	Back() bool
}

// Presenter is what the app draws to (the ring on the device, a file elsewhere).
type Presenter interface {
	Begin() *gfx.Canvas // the frame to draw into, write-only
	End()               // publish it
	WaitField(max time.Duration)
	Missed() bool  // did the last End land more than one field after the last WaitField
	Foreign() bool // has another process published since our last End
	Late() (draw, into time.Duration)
}

type cadencePresenter interface {
	EndEvery(uint32) bool
	ResetCadence()
}

// publishTimer is a Presenter that can say where its last End spent its time.
type publishTimer interface {
	PublishTimes() (ack, fill time.Duration)
}

// timing is one quantity of the pacing report: avg/worst in ms.
type timing struct {
	sum, worst time.Duration
	n          int
}

func (t *timing) add(d time.Duration) {
	t.sum += d
	t.n++
	t.worst = max(t.worst, d)
}

func (t timing) String() string {
	if t.n == 0 {
		return "-"
	}
	return fmt.Sprintf("%.1f/%.1f", float64(t.sum)/float64(t.n)/1e6, float64(t.worst)/1e6)
}

// gcTotals reads the GC cycles completed so far and their total pause, as
// wall time (the runtime counts a pause once per P).
func gcTotals(s []metrics.Sample) (uint64, time.Duration) {
	metrics.Read(s)
	var n uint64
	var pause time.Duration
	if s[0].Value.Kind() == metrics.KindUint64 {
		n = s[0].Value.Uint64()
	}
	if s[1].Value.Kind() == metrics.KindFloat64 {
		pause = time.Duration(s[1].Value.Float64() / float64(runtime.GOMAXPROCS(0)) * 1e9)
	}
	return n, pause
}

// Screen is one page of the UI.
type Screen interface {
	Key(ev input.Event, now time.Time)
	Draw(c *gfx.Canvas, now time.Time) bool
}

// App owns the screens, the canvas and the services.
type App struct {
	updates    updateState
	supporters supporterState
	Plex       *plex.Client
	Art        *Art
	F          Fonts
	Out        Presenter
	Player     *Player
	Log        *log.Logger
	T          *gfx.TextCache

	// Wake is signalled by background fetches (art, pages) to request a redraw.
	Wake chan struct{}
	// Starting is set while a play request is being brought up (screens
	// show it as a spinner); zero otherwise.
	Starting  time.Time
	shuffling *shuffleWait // a shuffle's episodes are being listed
	reading   *versionRead // a start is reading its item's versions
	// Mark is the app's wordmark, rendered once.
	Mark  *Wordmark
	marks map[string]*gfx.Image // the BETA and UPDATE marks, by text
	// Cfg is the user's settings (Options screen) and sign-in.
	Cfg            *Config
	Showcase       bool // session-only capture privacy
	Version, Build string
	FFmpeg         string // the decoder executable, for theme music
	// Display is what the launcher read in the MiSTer INI; Options warn
	// about settings that hurt playback.
	Display DisplayCheck
	// ToMenu is set by the menu's Exit: Run returns, and the launcher loads
	// the MiSTer menu once the app has stopped.
	ToMenu bool
	// Connected is signalled by the sign-in screen once a server is saved.
	Connected chan struct{}
	// Notice is a line shown along the bottom for a few seconds (a file
	// the server refused to play).
	serverOffline bool
	Notice        string
	NoticeAt      time.Time
	// later holds closures for the render thread (results of background work).
	// Run drains it; playLoop only moves them to held while a playback has
	// the screen (a long autoplay posts one per finished episode, and they
	// may change the items the playback is using), and runLater runs them in
	// order once the menus are back. laterFull notes a post dropped because
	// the queue was full, logged once until it drains.
	later       chan func()
	held        []func()
	laterFull   atomic.Bool
	seasonData  *seasonData // one selected season, shared with its opening page
	scr         *gfx.Canvas
	osd         OSD            // the playback overlay: the core's plane
	crop        Crop           // the playback's crop: Options' at the start, then the playback menu's
	subtitles   subtitleMemory // text tracks found undrawable this run (subtitles.go)
	dim         idleDim
	playing     bool            // a playback has the screen (playLoop), paused or not
	playReports <-chan struct{} // the latest session's stopped report, for ordered refreshes
	memoChecked bool            // Home has been reached this run and the memos looked at (memo.go)

	stack  []Screen
	dirty  bool
	events <-chan input.Event

	secs   []plex.Section        // the libraries, fetched in the background
	pagers map[string]*Pager     // listings kept for the session, by path and query
	places map[string]*wallPlace // the libraries' views that keep their place, by section key
	// CacheDir is where artwork is kept (for a client made after sign-in).
	cacheDir                        string
	aspects                         Aspects // show shapes for the 4:3 filter
	lastSection                     string  // the library the drawer opened last; it opens on it again
	theme                           Theme
	menuAudio                       *menuAudio
	menuAudioRunning, menuAudioHeld bool
	menuAudioRetry                  time.Time
	menuAudioFailures               int
	premiumAudioState               any // optional audio extension state, owned by this App
	menuNavDown, menuToneOn         bool
	menuNavRepeat                   bool
	menuNavKey                      input.Key
	lastFocus                       focusPosition
	focusReady                      bool
	accountLookup                   bool         // UI-thread owned; prevents overlapping account-name requests
	access                          access.Month // the coverage of the codes on this card (premium.go)
}

// SetCacheDir sets where artwork is cached.
func (a *App) SetCacheDir(dir string) { a.cacheDir = dir; a.aspects.load(dir) }

// New builds the app around a client and a presenter.
func New(c *plex.Client, out Presenter, player *Player, lg *log.Logger) *App {
	a := &App{Plex: c, Out: out, Player: player, Log: lg, Wake: make(chan struct{}, 1), Connected: make(chan struct{}, 1), later: make(chan func(), 32)}
	if player != nil && player.DrawsSubtitle == nil {
		player.DrawsSubtitle = a.drawsSubtitle
	}
	if player != nil && player.SavedStreams == nil {
		player.SavedStreams = a.savedStreams
	}
	// more Ps than cores so a decoding worker can never hold the drawing
	// loop off the scheduler; the OS then arbitrates by thread priority
	runtime.GOMAXPROCS(4)
	// the box has 512 MB shared with the transcoder pipeline: keep the heap
	// small and let the collector work harder rather than grow
	debug.SetGCPercent(100)
	debug.SetMemoryLimit(96 << 20)
	a.Art = NewArt(c, ArtWorkers, a.Wake)
	a.T = gfx.NewTextCache(1, a.Wake)
	a.pagers = map[string]*Pager{}
	if c != nil {
		go a.loadSectionsFor(c)
	}
	a.F = appFonts()
	a.Mark = NewWordmark()
	warmFades(layoutCanvasSize(a)) // 960 wide on a 16:9 display
	return a
}

// Push shows a screen on top of the stack.
// WakeUp asks the loop for a redraw from another goroutine; never blocks.
func (a *App) WakeUp() {
	select {
	case a.Wake <- struct{}{}:
	default:
	}
}

func (a *App) Push(s Screen) { a.stack = append(a.stack, s); a.dirty = true; a.syncTheme() }

// leaver is a screen that acts as it is popped off the stack, before the
// screen under it shows (a library's wall tells its views it was left).
type leaver interface{ left() }

// Pop returns to the previous screen; false at the root.
func (a *App) Pop() bool {
	if len(a.stack) <= 1 {
		return false
	}
	gone := a.stack[len(a.stack)-1]
	a.stack = a.stack[:len(a.stack)-1]
	if l, ok := gone.(leaver); ok {
		l.left()
	}
	if _, ok := gone.(*Options); ok {
		a.flushSettings() // its changes are written as they stop (saveSettings)
	}
	a.syncTheme()
	a.dirty = true
	return true
}

func (a *App) top() Screen { return a.stack[len(a.stack)-1] }

// Open acts on a selected item: the preplay page for a movie (or straight
// to playback when direct), a show's page of seasons, a season's page of
// episodes, and for an episode its season's page with it highlighted.
func (a *App) Open(it *plex.Item, direct bool) {
	if it.Type == "more" {
		if sec, ok := a.section(it.Key); ok {
			a.Push(NewWallView(a, sec, 1))
		}
		return
	}
	if it.Type == "movie" && direct {
		a.PlayAt(it, it.ViewOffset)
		return
	}
	switch it.Type {
	case "movie", "show", "season", "episode":
		a.openItem(it, "")
	}
}

func (a *App) openSeason(showKey, seasonKey, at string) {
	a.openItem(&plex.Item{Type: "season", RatingKey: seasonKey, ParentKey: showKey}, at)
}

// pager returns the listing for a path and query, kept for the session
// so a library reopens where its count and pages already are.
func (a *App) pager(path string, q url.Values, filter func(*plex.Item) bool) *Pager {
	var prepare func([]*plex.Item)
	if filter != nil {
		prepare = a.measureShows // shows need a probe before the filter can judge them
	}
	return a.preparedPager(path, q, filter, prepare)
}

// preparedPager is pager with the caller's prepare for a filtered listing.
func (a *App) preparedPager(path string, q url.Values, filter func(*plex.Item) bool, prepare func([]*plex.Item)) *Pager {
	key := path + "?" + q.Encode()
	if filter != nil {
		key += "|filtered"
	}
	if p := a.pagers[key]; p != nil {
		return p
	}
	p := newPager(a.Plex, path, q, a.Wake, filter, prepare)
	p.Failed = func(err error) { a.SessionEnded(err) }
	p.Want(0)
	a.pagers[key] = p
	return p
}

// PlayAt plays an item from an offset in seconds (its resume point when
// offset equals the item's, the start when 0) and refreshes it afterwards.
func (a *App) PlayAt(it *plex.Item, offset int) { a.PlayQueue(it, offset, nil, 0, nil) }

// PlayQueue is PlayAt with the items around it (a season's episodes), so
// the overlay's Prev and Next can move along them. The screen cuts to
// black at once, with the title, the bar and the times on the overlay
// and the wait dot running in the middle while the stream comes up;
// when the player (jfplay) publishes its first frame the dot goes and the UI
// drives the overlay until playback ends. Then after, if given, learns
// the item the queue stopped on (it, when nothing played) and whether
// that one finished (Playing.finished), so a season page can move on to
// the episode after it. A playback held for the beta code or the version
// chooser (firstVersion) calls after once the code is in or the version
// picked and it has run; never, if the code entry or the chooser is left.
func (a *App) PlayQueue(it *plex.Item, offset int, queue []*plex.Item, idx int, after func(last *plex.Item, finished bool)) {
	a.playQueue(it, offset, queue, idx, after, false)
}

// Shuffle plays every episode of a show, watched or not, in a random order:
// each from its start, and on into the next whatever Options say about
// autoplay (without it a shuffle would be one random episode). The episodes
// are listed in the background with the start indicator running; as while
// a playback comes up, Back gives up and nothing else acts (see key). then,
// if given, runs once the shuffle has played (see PlayQueue's after).
func (a *App) Shuffle(show *plex.Item, then func()) {
	w := &shuffleWait{show: show}
	a.shuffling, a.Starting = w, time.Now()
	a.dirty = true
	client, key := a.Plex, show.RatingKey
	go func() {
		queue, err := shuffleQueue(client, key)
		// waits for room rather than being dropped as Later's work may be:
		// the start bar and the held keys end only with this answer
		a.later <- func() {
			if a.shuffling != w {
				return // given up
			}
			a.shuffling, a.Starting = nil, time.Time{}
			if err != nil || len(queue) == 0 {
				a.Log.Printf("shuffle %s: %d episodes, %v", show.Title, len(queue), err)
				a.Notice, a.NoticeAt = "Could not list the show's episodes.", time.Now()
				return
			}
			a.Log.Printf("shuffle %s: %d episodes", show.Title, len(queue))
			var after func(*plex.Item, bool)
			if then != nil {
				after = func(*plex.Item, bool) { then() }
			}
			a.playQueue(queue[0], 0, queue, 0, after, true)
		}
		a.WakeUp()
	}()
}

// shuffleWait is a show whose episodes are being listed for a shuffle.
type shuffleWait struct{ show *plex.Item }

// shuffleQueue is every episode of a show, all seasons and specials, in a
// random order.
func shuffleQueue(client *plex.Client, show string) ([]*plex.Item, error) {
	eps, err := client.ShowEpisodes(show)
	rand.Shuffle(len(eps), func(i, j int) { eps[i], eps[j] = eps[j], eps[i] })
	return eps, err
}

// runsOn says whether a queue counts down into its next item when one plays
// to its end: as Options say, but a shuffle always does.
func (a *App) runsOn(shuffled bool) bool { return shuffled || !a.Cfg.NoAutoplay }

// startOf is where an item reached along a queue (Prev, Next, the countdown)
// starts: its resume point, or in a shuffle its start.
func startOf(it *plex.Item, shuffled bool) int {
	if shuffled {
		return 0
	}
	return it.ViewOffset
}

func (a *App) playQueue(it *plex.Item, offset int, queue []*plex.Item, idx int, after func(last *plex.Item, finished bool), shuffled bool) {
	a.playSettled(it, offset, queue, idx, after, shuffled, "")
}

// playSettled is playQueue once the first item's version is settled, why
// saying how; "" settles it first (firstVersion), which may hold the play
// for the version chooser as the beta code entry holds it.
func (a *App) playSettled(it *plex.Item, offset int, queue []*plex.Item, idx int, after func(last *plex.Item, finished bool), shuffled bool, why string) {
	last, finished, held := it, false, false
	if after != nil {
		// deferred first, so it runs last: after the theme and Home
		defer func() {
			if !held {
				after(last, finished)
			}
		}()
	}
	if a.Player == nil {
		return
	}
	// Check before playback setup. Player.Start and StartAsync also check so
	// direct worker calls cannot bypass the beta gate.
	if a.Player.Access != nil {
		if err := a.Player.Access(); err != nil {
			if err == beta.ErrLocked {
				held = true // the code entry plays it, then calls after
				a.Push(NewBetaAccess(a, func() { a.playSettled(it, offset, queue, idx, after, shuffled, why) }))
			} else {
				a.Notice, a.NoticeAt = err.Error(), time.Now()
				a.dirty = true
			}
			return
		}
	}
	if why == "" {
		// a pick plays it, then calls after; Back plays nothing
		if why, held = a.firstVersion(it, offset, shuffled, func(why string) {
			a.playSettled(it, offset, queue, idx, after, shuffled, why)
		}); held {
			return
		}
	}
	if os.Getenv("PLEXCRT_NOPLAY") != "" {
		// scripted walks: show the starting state for a moment, play nothing
		a.Log.Printf("would play %s (%s) at %d", it.Title, it.RatingKey, offset)
		if len(it.Versions) > 1 {
			a.Log.Print(versionLog(it, why))
		}
		a.Starting = time.Now()
		for time.Since(a.Starting) < 1500*time.Millisecond {
			a.redraw()
			time.Sleep(50 * time.Millisecond)
		}
		a.Starting = time.Time{}
		a.dirty = true
		return
	}
	a.seasonData = nil
	defer func() {
		for _, screen := range a.stack {
			if h, ok := screen.(*Home); ok && h.home {
				// rows asked for before the stopped report is in would bring
				// back the old resume point: hold them until it is
				h.refreshResult = nil
				h.refreshAt = time.Now().Add(viewRefreshInterval)
				a.afterReports(func() {
					h.refreshResult = nil
					h.refreshAt = time.Time{}
					a.dirty = true
				})
			}
		}
	}()
	if a.osd == nil {
		if r, ok := a.Out.(*ring.Ring); ok {
			a.osd = r.Overlay()
		}
	}
	a.startingVersion(it, why)
	a.flushSettings() // a track or version just chosen, say: on the card before the play
	a.theme.Stop()    // Finish the theme before handing audio to playback.
	defer a.syncTheme()
	a.menuAudioHeld = true
	a.stopMenuAudio()
	defer func() {
		a.menuAudioHeld = false
		a.focusReady = false
		a.menuAudioRetry = time.Time{}
		a.syncMenuAudio()
	}()
	a.Player.Reap()
	a.crop = a.Cfg.Crop.valid()
	for {
		last, finished = it, false
		a.Log.Printf("play %s (%s) at %d", it.Title, it.RatingKey, offset)
		a.Starting = time.Now()
		a.blank()
		if backdrop, ok := a.osd.(interface{ SetOpaque(bool) }); ok {
			backdrop.SetOpaque(true)
		}
		sess, err := a.Player.StartAsync(it, offset)
		if err != nil {
			if backdrop, ok := a.osd.(interface{ SetOpaque(bool) }); ok {
				backdrop.SetOpaque(false)
			}
			a.Log.Printf("play: %v", err)
			a.Notice, a.NoticeAt = err.Error(), time.Now()
			break
		}
		ctl := NewPlaying(a, it, queue, idx, sess.SendUI)
		ctl.direct = sess.Direct
		ctl.streamModes = sess.StreamModes
		ctl.conversionReason = sess.ConversionReason
		ctl.sourceInfo = sess.PlaybackSource
		ctl.streams = sess.Streams
		ctl.version = sess.Version
		ctl.notice = sess.TakeNotice
		ctl.pos = float64(offset)
		if offset < 0 {
			ctl.pos = float64(it.ViewOffset)
		}
		ctl.starting, ctl.waitSpec = a.osd != nil, os.Getenv("PLEXCRT_WAIT_DOT")
		next, ended := a.playLoop(sess, ctl)
		a.playReports = sess.ReportsDone()
		finished = ctl.finished()
		a.notePlayed(it, sess, finished) // at once: the server has it only after the report
		a.refreshPlayedItem(it, a.playReports)
		if msg := readPlayerStatus(a.Player.Status)["error"]; msg != "" {
			a.Notice = plex.Fold(strings.TrimSpace(msg))
			a.NoticeAt = time.Now()
		}
		if next == 0 && ended && queue != nil && idx+1 < len(queue) && a.runsOn(shuffled) {
			// ran to the end: count down to the next episode
			if a.countdown(queue[idx+1]) {
				next = 1
			}
		}
		if next == 0 || queue == nil || idx+next < 0 || idx+next >= len(queue) {
			break
		}
		idx += next
		it = queue[idx]
		offset = startOf(it, shuffled)
		a.startingVersion(it, a.quietVersion(it)) // never asks along a queue
	}
	a.Starting = time.Time{}
	a.dirty = true
}

// refreshPlayedItem waits off-thread for the final report before refreshing resume state.
func (a *App) refreshPlayedItem(it *plex.Item, reports <-chan struct{}) {
	client, key := a.Plex, it.RatingKey
	go func() {
		if reports != nil {
			<-reports
		}
		fresh, err := client.Item(key)
		if err != nil {
			return
		}
		a.Later(func() {
			if a.Plex == client && a.playReports == reports && !a.playing {
				a.takeFresh(it, fresh)
			}
		})
	}()
}

// blank presents a black frame: the menu is gone the moment Play is pressed.
func (a *App) blank() {
	c := a.Out.Begin()
	c.Fill(0, 0, c.W, c.H, gfx.Black)
	a.Out.End()
}

// updateOverlay lets presenters that support batching publish a group of
// related sprite and panel changes in one framebuffer flip.
func updateOverlay(osd OSD, fn func()) {
	if batch, ok := osd.(interface {
		BeginUpdate()
		EndUpdate()
	}); ok {
		batch.BeginUpdate()
		defer batch.EndUpdate()
	}
	fn()
}

// playLoop runs one playback: the wait dot until the picture is up, then
// keys go to the overlay controller, which brings the dot back whenever
// the frames stop. Returns the controller's Next (+1/-1 for the queue, 0
// to stop) and whether the stream ran to its end.
func (a *App) playLoop(sess *Session, ctl *Playing) (int, bool) {
	// The overlay is drawn once per field, right after the core's field
	// counter moves, and at once after a key. The dot and focus bar are
	// software-composited into the framebuffer.
	//
	// The decoder has the machine: this loop wakes every half field and
	// no thread here outranks ffmpeg. Waking at 500 Hz from a raised
	// priority cost the decoder a late frame every two seconds.
	tick := time.NewTicker(8 * time.Millisecond)
	defer tick.Stop()
	fields, _ := a.Out.(interface{ Field() uint32 })
	var lastField uint32
	if fields != nil {
		lastField = fields.Field()
	}
	frames, _ := a.Out.(interface{ Published() (uint32, bool) })
	var lastFrame uint32
	setOpaque := func(on bool) {
		if backdrop, ok := a.osd.(interface{ SetOpaque(bool) }); ok {
			backdrop.SetOpaque(on)
		}
	}
	// two cores: more Ps only spin looking for work against the decoder
	defer runtime.GOMAXPROCS(runtime.GOMAXPROCS(2))
	defer playbackPriority()() // Run's thread, raised for the menus
	a.playing = true
	defer func() { a.playing = false }()
	defer setOpaque(false)
	// Finish the old renderer before any returned menu can publish a frame.
	defer func() { <-ctl.closePainter(a.osd) }()
	up := false
	stopped := false
	events := a.events
	var lastPlayFocus playFocus
	selectionPresented := func() {
		f := ctl.selection()
		if f.visible && f != lastPlayFocus {
			a.tap()
		}
		lastPlayFocus = f
	}
	for {
		select {
		case err := <-sess.Done:
			if err != nil {
				a.Log.Printf("play: %v", err)
				a.Notice, a.NoticeAt = plex.Fold(err.Error()), time.Now()
			}
			if a.osd != nil {
				// the menus use neither the overlay nor its dot and bar, and
				// the wait dot may still be running
				updateOverlay(a.osd, func() {
					a.osd.Hide()
					ctl.end()
					a.osd.Dot(0, 0, 0, false)
					a.osd.Bar(0, 0, 0, 0, 0, false)
				})
			}
			ended := !stopped && ctl.finished()
			return ctl.Next, ended
		case ev, ok := <-events:
			if !ok {
				events = nil
				stopped = true
				ctl.closePainter(a.osd)
				sess.StopUI()
				continue
			}
			if stopped {
				continue
			}
			if a.wake(ev, time.Now()) {
				continue
			}
			if !up {
				if ev.Key == input.Back && !ev.Release && !ev.Repeat {
					if a.osd != nil {
						updateOverlay(a.osd, func() { ctl.end() }) // the dot goes with the press
					}
					stopped = true
					ctl.closePainter(a.osd)
					sess.StopUI() // gave up waiting
				}
				continue
			}
			if ctl.Key(ev, time.Now()) {
				if a.osd != nil {
					updateOverlay(a.osd, func() {
						a.osd.Hide()
						ctl.end()
					})
				}
				stopped = true
				ctl.closePainter(a.osd)
				sess.StopUI()
			} else if a.osd != nil {
				updateOverlay(a.osd, func() { ctl.Tick(time.Now(), a.osd, false) }) // the overlay answers the key at once
				selectionPresented()
			}
		case <-tick.C:
			// background results keep coming through a long autoplay (one
			// per finished episode); keep room for them without running
			// them, as they may change the items the playback is using
			a.holdLater()
			if stopped {
				continue
			}
			if fields != nil {
				f := fields.Field()
				if f == lastField {
					continue // not a new field yet
				}
				lastField = f
			}
			a.idle(time.Now(), up && ctl.paused)
			if !up {
				// Up is the player's (jfplay's) first frame, not its launch: it
				// starts long before the stream gives it a picture. Without the
				// ring there is no frame to see, only the player's status file.
				foreign := a.Out.Foreign()
				if foreign || a.osd == nil && a.Player.Started(a.Starting) {
					if foreign {
						setOpaque(false)
					}
					up = true // the dot goes; the strip runs out over the picture
					a.Starting = time.Time{}
					if frames != nil {
						lastFrame, _ = frames.Published()
					}
					if a.osd != nil {
						ctl.framed(time.Now())
					}
					continue
				}
				if a.osd != nil {
					// black under, the title and the bar over, the dot in the
					// middle, until the picture
					ctl.peekAt, ctl.peekFor = time.Now(), OsdLinger
					updateOverlay(a.osd, func() { ctl.Tick(time.Now(), a.osd, true) })
				}
				continue
			}
			if a.osd != nil {
				// a frame from the player (jfplay; a wiped header is none): the
				// picture is moving, so no wait dot
				updateOverlay(a.osd, func() {
					if frames != nil {
						if seq, ok := frames.Published(); ok && seq != lastFrame {
							lastFrame = seq
							ctl.framed(time.Now())
						}
					}
					ctl.Tick(time.Now(), a.osd, true)
				})
				selectionPresented()
			}
		}
	}
}

// countdown shows the next episode for ten seconds; OK plays it now,
// Back cancels. True to go on.
func (a *App) countdown(next *plex.Item) bool {
	deadline := time.Now().Add(10 * time.Second)
	tick := time.NewTicker(100 * time.Millisecond)
	defer tick.Stop()
	for {
		select {
		case ev, ok := <-a.events:
			if !ok || a.wake(ev, time.Now()) || ev.Release || ev.Repeat {
				continue
			}
			switch ev.Key {
			case input.Enter:
				return true
			case input.Back:
				return false
			}
		case <-tick.C:
			a.idle(time.Now(), false)
			left := time.Until(deadline)
			if left <= 0 {
				return true
			}
			a.Art.Frame()
			c := a.Out.Begin()
			a.drawCountdown(c, next, int(left.Seconds())+1)
			a.Out.End()
		}
	}
}

func (a *App) drawCountdown(c *gfx.Canvas, next *plex.Item, secs int) {
	c.Fill(0, 0, c.W, c.H, gfx.Bg)
	f := a.F
	y := SafeY + 40
	a.text(c, SafeX, y, f.SmallBold, gfx.GreyLo, "Up next in "+itoa(secs))
	y += f.SmallBold.Height() + 10
	a.text(c, SafeX, y, f.Big, gfx.Grey, f.Big.Fit(next.GrandTitle, SafeW))
	y += f.Big.Height() + 6
	a.text(c, SafeX, y, f.Body, gfx.GreyHi, f.Body.Fit("S"+itoa(next.Parent)+" E"+itoa(next.Index)+"  "+next.Title, SafeW))
	y += f.Body.Height() + 24
	still := next.Still
	if still == "" {
		still = next.Thumb
	}
	if img := a.Art.Get(still, StillW, StillH); img != nil {
		c.Blit(SafeX, y, img)
	} else {
		c.Fill(SafeX, y, StillW, StillH, gfx.Bar)
	}
	tx := SafeX + StillW + 24
	for i, line := range wrap(f.SmallBold, next.Summary, SafeX+SafeW-tx, 4) {
		a.text(c, tx, y+i*(f.SmallBold.Height()+2), f.SmallBold, gfx.GreyLo, line)
	}
	y += StillH + 30
	a.text(c, SafeX, y, f.Body, gfx.Amber, "Play now")
	a.text(c, SafeX+f.Body.Width("Play now")+40, y, f.Body, gfx.GreyLo, "Back: stop")
	// the countdown as a pill
	c.Fill(SafeX, SafeBottom-12, SafeW, PillH, 0x404040)
	c.Fill(SafeX, SafeBottom-12, SafeW*secs/10, PillH, gfx.Amber)
}

// redraw presents the top screen once, outside the main loop.
func (a *App) redraw() {
	a.Art.Frame()
	c := a.Out.Begin()
	a.drawScreen(c, time.Now())
	a.Out.End()
	a.selectionPresented()
}

func (a *App) loadSections() {
	if a.Plex == nil {
		return
	}
	secs, err := a.Plex.Sections()
	if err != nil {
		a.Log.Printf("sections: %v", err)
		a.SessionEnded(err)
		return
	}
	a.secs = secs
	a.WakeUp()
}

func (a *App) loadSectionsFor(client *plex.Client) {
	if client == nil {
		return
	}
	secs, err := client.Sections()
	if err != nil {
		a.Log.Printf("sections: %v", err)
		a.SessionEnded(err)
		return
	}
	a.Later(func() {
		if a.Plex != client {
			return
		}
		a.secs = secs
	})
}

// knownSections takes the libraries from a Home fetch while the list is
// missing, as it is when the server could not be reached at start.
func (a *App) knownSections(secs []plex.Section) {
	if len(a.secs) == 0 && len(secs) > 0 {
		a.secs = secs
	}
}

// Menu opens the drawer over the home screen: Home, the libraries, Options,
// Exit, Patreon.
func (a *App) Menu() {
	if a.Plex == nil {
		return // signing in: nothing to list
	}
	// The background section/Home fetch fills libraries when available.
	// Always let the drawer open, including Options and Exit, during an outage.
	items, cur := a.menuItems()
	a.Push(NewDrawer(a, a.stack[0], items, cur))
}

// menuItems lists the drawer's entries, with the one to open on: the
// library opened last, Home when there is none or it is hidden.
func (a *App) menuItems() ([]*plex.Item, int) {
	items := []*plex.Item{{Title: "Home", Type: "home"}, {Title: "Search", Type: "search"}}
	for _, s := range a.libraries() {
		items = append(items, &plex.Item{RatingKey: s.Key, Title: s.Title, Type: "section", Key: s.Key})
	}
	items = append(items, &plex.Item{Title: "Options", Type: "options"}, &plex.Item{Title: "Exit to MiSTer menu", Type: "exit"},
		&plex.Item{Title: "Patreon", Type: "patreon"})
	// open on the library visited last, so a long list needs no scrolling to return
	cur := 0
	for i, it := range items {
		if it.Type == "section" && it.Key == a.lastSection {
			cur = i
		}
	}
	return items, cur
}

// MenuPick acts on a drawer entry.
func (a *App) MenuPick(d *Drawer, it *plex.Item) {
	switch it.Type {
	case "home":
		d.Close(nil)
	case "search":
		d.Close(func() { a.Push(NewSearch(a)) })
	case "options":
		a.Push(NewOptions(a))
	case "patreon":
		a.Push(NewPatreon(a))
	case "section":
		if s, ok := a.section(it.Key); ok {
			a.lastSection = s.Key
			// the wall replaces the drawer once it has slid out: Back from it is home
			d.Close(func() { a.Push(NewWall(a, s)) })
		}
	case "exit":
		a.ToMenu = true // Run returns before the next frame
	}
}

// section finds a library by key.
func (a *App) section(key string) (plex.Section, bool) {
	for _, s := range a.secs {
		if s.Key == key {
			return s, true
		}
	}
	return plex.Section{}, false
}

// Later queues a closure to run on the render thread before the next frame
// (or the next field of a playback). A full queue drops it, and says so in
// the log, once until the queue is drained again.
func (a *App) Later(f func()) {
	select {
	case a.later <- f:
	default:
		if a.laterFull.CompareAndSwap(false, true) && a.Log != nil {
			a.Log.Printf("later: the render thread's queue is full; a background result was dropped")
		}
	}
	select {
	case a.Wake <- struct{}{}:
	default:
	}
}

// runLater runs the closures held during a playback, then the queued ones.
func (a *App) runLater() {
	a.pollServerRequest()
	held := a.held
	a.held = nil
	for _, f := range held {
		f()
		a.dirty = true
	}
	for {
		select {
		case f := <-a.later:
			f()
			a.dirty = true
			a.laterFull.Store(false)
		default:
			return
		}
	}
}

// holdLater empties the queue into held without running anything: playLoop
// calls it so Later keeps room during a long autoplay, while the closures,
// which may change the items the playback is using, wait for the menus.
func (a *App) holdLater() {
	for {
		select {
		case f := <-a.later:
			a.held = append(a.held, f)
			a.laterFull.Store(false)
		default:
			return
		}
	}
}

// Start shows the first screen: home when a server is on record (or a
// client was given), the sign-in otherwise.
func (a *App) Start() {
	// New controls start hidden; preserve any existing frame until the first menu.
	if r, ok := a.Out.(*ring.Ring); ok && a.osd == nil {
		a.osd = r.Overlay()
	}
	a.loadAccess()
	a.premiumStart()
	if a.Plex != nil {
		a.Push(NewHome(a))
		return
	}
	if a.Cfg.Token != "" && a.Cfg.SignedIn() {
		a.Push(NewHomeUsers(a, a.Cfg.Token))
		return
	}
	a.Push(NewLogin(a))
}

// Connect switches to the server in the config (after sign-in) and
// starts over at home.
func (a *App) Connect() {
	cfg := a.Cfg
	c := plex.New(cfg.ServerURL, cfg.ServerToken, a.cacheDir, cfg.ClientID)
	a.Plex = c
	a.Art.SetClient(c)
	a.secs = nil
	a.pagers = map[string]*Pager{}
	a.places = nil
	a.seasonData, a.lastSection = nil, ""
	a.lastFocus, a.focusReady = focusPosition{}, false
	if a.Player != nil {
		a.Player.Client = a.Plex
	}
	a.stack = nil
	a.Push(NewHome(a))
}

// SwitchUser closes the current library before asking Plex which household
// member is watching. Old pages and search results cannot cross the switch.
func (a *App) SwitchUser() {
	if a.Cfg.Token == "" {
		return
	}
	a.signedOut()
	a.Push(NewHomeUsers(a, a.Cfg.Token))
}

// SignOut forgets the sign-in and returns to the sign-in screen.
func (a *App) SignOut() {
	if err := a.Cfg.SignOut(); err != nil {
		a.Log.Printf("config: %v", err)
		a.Notice, a.NoticeAt = "Could not save sign-out. Check free space and retry.", time.Now()
		return
	}
	a.signedOut()
	a.Push(NewLogin(a))
}

// signedOut drops the client and everything listed through it.
func (a *App) signedOut() {
	a.Plex = nil
	a.Art.SetClient(nil)
	a.secs = nil
	a.pagers = map[string]*Pager{}
	a.places = nil
	a.seasonData, a.lastSection = nil, ""
	a.lastFocus, a.focusReady = focusPosition{}, false
	a.stack = nil
}

// SessionEnded reports whether err is the server refusing the token (access
// removed, the token revoked, or the server briefly unable to check it with
// plex.tv) and, when it is, opens the server picker. The plex.tv account
// stays signed in: only this server's token is in doubt. Safe from any
// goroutine.
func (a *App) SessionEnded(err error) bool {
	if !errors.Is(err, plex.ErrUnauthorized) {
		return false
	}
	a.Later(func() {
		if a.Plex == nil {
			return // already signed out
		}
		if !a.Plex.Refused() || len(a.Connected) > 0 {
			// a client replaced (Switch user, another server), or saved to
			// replace it: the refusal was of the old one, answering screens
			// on their way out
			return
		}
		if len(a.stack) > 0 {
			if l, up := a.top().(*Login); up && l.picker {
				return
			}
		}
		a.Log.Printf("token refused by the server: choosing a server again")
		a.Push(NewServerPicker(a))
		a.Notice, a.NoticeAt = "The server no longer accepts this sign-in. Choose a server again.", time.Now()
	})
	return true
}

// streamLabel is the action text for the chosen audio or subtitle stream.
func streamLabel(kind string, streams []plex.Stream) string {
	for _, s := range streams {
		if s.Selected {
			return kind + ": " + s.Title
		}
	}
	if kind == "Subtitles" {
		return "Subtitles: Off"
	}
	if len(streams) > 0 {
		return kind + ": " + streams[0].Title
	}
	return ""
}

// streamChoiceKey is where an item's track choice is kept: by show for an
// episode (a show's episodes share their tracks), by item otherwise.
func streamChoiceKey(it *plex.Item) string {
	if it.Type == "episode" && it.GrandKey != "" {
		return it.GrandKey
	}
	return it.RatingKey
}

// applyStreams marks the tracks chosen for the item's movie or show, if
// the item has them; the server's default stays marked otherwise.
func (a *App) applyStreams(it *plex.Item) {
	if a.Cfg == nil || it == nil {
		return
	}
	ch, ok := a.Cfg.Streams[streamChoiceKey(it)]
	if !ok {
		return
	}
	markStream(it.Audio, ch.Audio)
	markStream(it.Subs, ch.Subtitle)
}

// savedStreams is the user's choice of tracks for an item's movie or show
// (Player.SavedStreams): "" for none saved, "-1" for no subtitles.
func (a *App) savedStreams(it *plex.Item) (audio, subtitle string) {
	if a.Cfg == nil || it == nil {
		return "", ""
	}
	ch := a.Cfg.Streams[streamChoiceKey(it)]
	return ch.Audio, ch.Subtitle
}

// markStream makes the track with ID the chosen one of streams ("-1": none
// of them). "" leaves them be, as does an ID none of them has: that is
// another file's track, and the server's default stands.
func markStream(streams []plex.Stream, id string) {
	if id == "" {
		return
	}
	found := false
	for _, s := range streams {
		found = found || s.ID == id
	}
	if !found && id != "-1" {
		return
	}
	for k := range streams {
		streams[k].Selected = streams[k].ID == id
	}
}

// takeFresh replaces an item with its fresh record, which marks the
// server's default tracks and has its first version in force, and puts in
// force again the version it had and marks the chosen tracks. Every other
// copy of the item (forEachItem) takes its watch state.
func (a *App) takeFresh(it, fresh *plex.Item) {
	keep := it.VersionID
	*it = *fresh
	a.applyVersion(it, keep)
	a.applyStreams(it)
	a.forEachItem(it.RatingKey, func(c *plex.Item) {
		if c != it {
			copyWatchState(c, it)
		}
	})
}

// selectStream makes stream i of an item's audio or subtitle tracks the
// chosen one (-1: no subtitles), marks it in the item and keeps the choice
// in the settings for its movie or show. The choice goes with each play,
// and the server makes it the part's default then (plex PlaybackInfo).
func (a *App) selectStream(it *plex.Item, kind string, i int) {
	streams := it.Audio
	if kind == "Subtitles" {
		streams = it.Subs
	}
	id := "-1"
	if i >= 0 && i < len(streams) {
		id = streams[i].ID
	} else if kind != "Subtitles" {
		return
	}
	for k := range streams {
		streams[k].Selected = k == i
	}
	if a.Cfg == nil {
		return
	}
	key := streamChoiceKey(it)
	ch := a.Cfg.Streams[key]
	if kind == "Subtitles" {
		ch.Subtitle = id
	} else {
		ch.Audio = id
	}
	if a.Cfg.Streams == nil {
		a.Cfg.Streams = map[string]StreamChoice{}
	}
	a.Cfg.Streams[key] = ch
	a.saveSettings() // written before the play starts at the latest
}

// chooseStream opens the chooser for an item's audio or subtitle tracks
// over the current screen; done runs after a pick.
func (a *App) chooseStream(it *plex.Item, kind string, done func()) {
	streams := it.Audio
	if kind == "Subtitles" {
		streams = it.Subs
	}
	var items []string
	cur := -1
	off := 0
	if kind == "Subtitles" {
		items = append(items, "Off")
		off = 1
	}
	for i, s := range streams {
		items = append(items, s.Title)
		if s.Selected {
			cur = i + off
		}
	}
	if kind == "Subtitles" && cur < 0 {
		cur = 0
	}
	a.Push(NewChooser(a, a.top(), kind, items, cur, func(i int) {
		a.selectStream(it, kind, i-off)
		done()
	}))
}

// Keep reports whether an item passes the user's filters (Options).
func (a *App) Keep(it *plex.Item) bool {
	if a.Cfg == nil || !a.Cfg.FourThree {
		return true
	}
	// shows and seasons carry no aspect; only what has been measured is hidden
	return it.Aspect == 0 || it.Aspect < 1.5
}

// Reconfigured re-reads what the settings affect: the home rows and the
// kept library listings.
func (a *App) Reconfigured() {
	a.syncTheme()
	a.pagers = map[string]*Pager{}
	if len(a.stack) > 0 {
		if h, ok := a.stack[0].(*Home); ok {
			// fetch the rows again off-thread: Options must answer at once, and
			// the 4:3 filter's first measurement can take seconds. The row shows
			// it is updating until the new rows land.
			h.refreshResult = nil
			h.refreshAt = time.Time{}
			h.updating = true
			h.pageKey = ""
		}
	}
}

// homeUpdating reports whether Home is still refetching after a filter change.
func (a *App) homeUpdating() bool {
	if len(a.stack) > 0 {
		if h, ok := a.stack[0].(*Home); ok {
			return h.updating
		}
	}
	return false
}

// Run drives input, drawing and presentation until stop closes or the
// menu's Exit sets ToMenu.
func (a *App) Run(events <-chan input.Event, stop <-chan struct{}) {
	a.menuAudioRunning = true
	a.syncMenuAudio()
	a.syncTheme()
	defer func() { a.menuAudioRunning = false; a.stopMenuAudio() }()
	defer a.theme.Stop()
	defer a.flushSettings()
	a.events = events
	a.dirty = true
	runtime.LockOSThread()
	syscall.Setpriority(syscall.PRIO_PROCESS, 0, -5)
	animating := false
	readyFile := os.Getenv("MISTERZINE_PLEX_READY_FILE")
	var worst, total time.Duration
	frames, late := 0, 0
	lastStat := time.Now()
	var draw, wait, ack, fill timing // the pacing report's breakdown
	timer, _ := a.Out.(publishTimer)
	gcs := []metrics.Sample{{Name: "/gc/cycles/total:gc-cycles"}, {Name: "/cpu/classes/gc/pause:cpu-seconds"}}
	gcN, gcPause := gcTotals(gcs)
	idle := time.NewTicker(time.Second) // re-present when idle: another
	defer idle.Stop()                   // process may have blanked the ring
	drain := func() bool {
		for {
			select {
			case ev, ok := <-events:
				if !ok {
					return false
				}
				a.key(ev, time.Now())
			case <-a.Wake:
				a.dirty = true
			case <-a.Connected:
				a.Connect()
			default:
				return true
			}
		}
	}
	for {
		select {
		case <-stop:
			return
		default:
		}
		cadenced := a.pacedTransition()
		fieldWait := time.Duration(-1) // the WaitField before this frame, if any
		if animating {
			// one frame per field while something moves; drain input meanwhile
			// Show layout transitions instead render ahead and publish every
			// vsync, using the complete field drawing budget.
			if !drain() {
				return
			}
			if !cadenced {
				w := time.Now()
				a.Out.WaitField(20 * time.Millisecond)
				fieldWait = time.Since(w)
			}
			if !drain() {
				return
			}
			a.dirty = true
		} else {
			select {
			case ev, ok := <-events:
				if !ok {
					return
				}
				a.key(ev, time.Now())
			case <-a.Wake:
				a.dirty = true
			case <-a.Connected:
				a.Connect()
			case <-idle.C:
				a.dirty = true
			case <-stop:
				return
			}
		}
		if a.ToMenu {
			a.Log.Printf("exit to the MiSTer menu")
			return
		}
		a.runLater()
		a.showMemo()
		a.idle(time.Now(), a.menuWaiting()) // the idle tick checks it every second
		a.pollUpdates(time.Now())
		a.syncMenuAudio()
		if h, ok := a.top().(*Home); ok {
			h.pollHome(time.Now())
		} else if h, ok := a.stack[0].(*Home); ok && h.updating {
			h.pollHome(time.Now()) // a filter change refetches behind Options
		}
		if screen, ok := a.top().(interface{ pollRefresh(time.Time) }); ok {
			screen.pollRefresh(time.Now())
		}
		if a.dirty {
			waited := animating // this frame was started by WaitField
			t0 := time.Now()
			a.Art.Frame()
			c := a.Out.Begin()
			warmFadesFor(c.W, c.H)
			animating = a.drawScreen(c, t0)
			if a.serverOffline && a.Notice == "" {
				a.text(c, SafeX, SafeBottom+6, a.F.SmallBold, gfx.White, "Server unavailable")
			}
			if a.Notice != "" {
				if time.Since(a.NoticeAt) > 6*time.Second {
					a.Notice = ""
				} else {
					c.Fill(0, SafeBottom-2, c.W, c.H-SafeBottom+2, gfx.Bg)
					a.text(c, SafeX, SafeBottom+6, a.F.SmallBold, gfx.Amber, a.F.SmallBold.Fit(a.Notice, SafeW))
					animating = true
				}
			}
			cadenced = cadenced || a.pacedTransition()
			drawn := time.Now()
			if v, ok := a.top().(*Show); ok {
				v.traceDrawn()
			}
			cadenceMissed := false
			if out, ok := a.Out.(cadencePresenter); ok && cadenced {
				cadenceMissed = out.EndEvery(1)
				if !a.pacedTransition() {
					out.ResetCadence()
				}
			} else {
				a.Out.End()
			}
			ended := time.Now()
			a.selectionPresented()
			if v, ok := a.top().(*Show); ok {
				v.tracePublished()
			}
			a.dirty = false
			d := time.Since(t0)
			if cadenced {
				d = drawn.Sub(t0)
			} // exclude the deliberate vsync wait
			total += d
			if d > worst {
				worst = d
			}
			draw.add(drawn.Sub(t0))
			var ackD, fillD time.Duration
			if timer != nil {
				ackD, fillD = timer.PublishTimes()
				ack.add(ackD)
				fill.add(fillD)
			}
			if cadenced {
				wait.add(max(0, ended.Sub(drawn)-ackD-fillD)) // EndEvery's wait for its field
			} else if fieldWait >= 0 {
				wait.add(fieldWait)
			}
			if cadenceMissed {
				late++
				a.Log.Printf("missed animation cadence")
			} else if waited && !cadenced && a.Out.Missed() {
				late++
				dd, into := a.Out.Late()
				a.Log.Printf("missed field: drew %.1f ms starting %.1f ms into the field (frame %.1f ms)", float64(dd)/1e6, float64(into)/1e6, float64(d)/1e6)
			}
			// pacing report: every 600 drawn frames, or after a burst of
			// at least 60 once things go quiet for a few seconds
			if readyFile != "" {
				if err := os.WriteFile(readyFile, []byte("ready\n"), 0600); err == nil {
					readyFile = ""
				}
			}
			if frames++; frames%600 == 0 || (frames >= 60 && time.Since(lastStat) > 5*time.Second) {
				n, pause := gcTotals(gcs)
				a.Log.Printf("frames %d: avg %.1f ms, worst %.1f ms, missed fields %d; fps=%.1f draw=%v wait=%v ack=%v copy=%v gc=%d gcpause=%.2f",
					frames, float64(total)/float64(frames)/1e6, float64(worst)/1e6, late,
					float64(frames)/time.Since(lastStat).Seconds(), draw, wait, ack, fill, n-gcN, float64(pause-gcPause)/1e6)
				worst, total, late, frames = 0, 0, 0, 0
				draw, wait, ack, fill = timing{}, timing{}, timing{}, timing{}
				gcN, gcPause = n, pause
				lastStat = time.Now()
			}
		}
	}
}

func (a *App) pacedTransition() bool {
	if _, ok := a.Out.(cadencePresenter); !ok {
		return false
	}
	if d, ok := a.top().(*Drawer); ok {
		return d.animating
	}
	if h, ok := a.top().(*Home); ok && h.home {
		return h.animating
	}
	v, ok := a.top().(*Show)
	return ok && v.pacedTransition()
}

func (a *App) key(ev input.Event, now time.Time) {
	a.menuAudioInput(ev)
	if a.wake(ev, now) {
		return
	}
	if a.shuffling != nil || a.reading != nil {
		// a shuffle is listing its episodes, or a start reading its item's
		// versions: Back gives up, nothing else acts
		if ev.Key == input.Back && !ev.Repeat && !ev.Release {
			a.shuffling, a.reading, a.Starting = nil, nil, time.Time{}
			a.dirty = true
		}
		return
	}
	// Text screens get keyboard editing before legacy aliases (Backspace=Back,
	// Space=OK, WASD=arrows). Controller events keep their existing behavior.
	if ev.Keyboard {
		if target, ok := a.top().(interface {
			Keyboard(input.Event, time.Time) bool
		}); ok && target.Keyboard(ev, now) {
			a.dirty = true
			return
		}
	}
	if ev.Key == input.Back {
		if ev.Repeat || ev.Release {
			return
		}
		if b, ok := a.top().(Backer); ok && b.Back() {
			a.dirty = true
			return
		}
		if !a.Pop() {
			a.Menu() // Back on Home opens the menu
		}
		return
	}
	a.top().Key(ev, now)
	a.dirty = true
}

// DrawOnce renders the top screen (used by the headless dump).
func (a *App) DrawOnce() *gfx.Canvas {
	c := a.Out.Begin()
	a.top().Draw(c, time.Now())
	a.drawBrand(c)
	a.Out.End()
	return c
}

// textOver draws a line of text over a composed page onto the frame: the
// page's pixels under the text are copied to a scratch canvas, the text
// blended there, and the strip blitted. For the few lines a screen must
// draw per frame over a picture (the frame itself must not be read).
func (a *App) textOver(c, page *gfx.Canvas, x, y int, f *gfx.Font, col gfx.Color, s string) {
	if s == "" {
		return
	}
	w, h := f.Width(s)+2, f.Height()
	x0, y0 := x-1, y
	if x0 < 0 || y0 < 0 || x0+w > page.W || y0+h > page.H {
		return
	}
	strip := a.scratch(w, h)
	for yy := 0; yy < h; yy++ {
		so := ((y0+yy)*page.W + x0) * 4
		copy(strip.Pix[yy*w*4:(yy+1)*w*4], page.Pix[so:so+w*4])
	}
	strip.Text(1, 0, f, col, s)
	c.Blit(x0, y0, &gfx.Image{W: w, H: h, Pix: strip.Pix})
}

// scratch returns a canvas of at least w x h for one-frame work (the
// render thread only).
func (a *App) scratch(w, h int) *gfx.Canvas {
	if a.scr == nil || len(a.scr.Pix) < w*h*4 {
		a.scr = gfx.NewCanvas(max(w, DesignW), max(h, 64))
	}
	return &gfx.Canvas{W: w, H: h, Pix: a.scr.Pix[:w*h*4]}
}

// Text helpers: every line goes through the cache, so the render thread
// only ever blits.
func (a *App) text(c *gfx.Canvas, x, y int, f *gfx.Font, col gfx.Color, s string) {
	c.Line(a.T, x, y, f, col, gfx.Bg, s)
}
func (a *App) textOn(c *gfx.Canvas, x, y int, f *gfx.Font, col, bg gfx.Color, s string) {
	c.Line(a.T, x, y, f, col, bg, s)
}
func (a *App) textClip(c *gfx.Canvas, x, y int, f *gfx.Font, col gfx.Color, s string, cy0, cy1 int) {
	c.LineClip(a.T, x, y, f, col, gfx.Bg, s, cy0, cy1)
}
func (a *App) textRight(c *gfx.Canvas, x, y int, f *gfx.Font, col gfx.Color, s string) {
	c.LineRight(a.T, x, y, f, col, gfx.Bg, s)
}
func (a *App) textCenterOn(c *gfx.Canvas, x, y int, f *gfx.Font, col, bg gfx.Color, s string) {
	c.LineCenter(a.T, x, y, f, col, bg, s)
}

// bg is the context of the UI's server requests. The app has no lifetime
// context of its own (it runs until the process ends), so nothing cancels
// them but their own timeouts.
func bg() context.Context { return context.Background() }
