// Package ui is the PlexCRT front end: screens drawn into a 720x480 canvas
// at 60 fps while anything moves, idle otherwise.
package ui

import (
	"log"
	"net/url"
	"os"
	"runtime"
	"runtime/debug"
	"strings"
	"syscall"
	"time"

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
	Mark      *gfx.Font // 24 Condensed Bold: "Plex" in the wordmark
	MarkZ     *gfx.Font // 26 Black: the Z
	MarkM     *gfx.Font // 17 Black: the M, smaller and raised
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
	Starting time.Time
	// Mark is the app's wordmark, rendered once.
	Mark  *Wordmark
	marks map[string]*gfx.Image // the BETA and UPDATE marks, by text
	// Cfg is the user's settings (Options screen) and sign-in.
	Cfg            *Config
	Showcase       bool // session-only capture privacy
	Version, Build string
	// Display is what the launcher read in the MiSTer INI; Options warn
	// about settings that hurt playback.
	Display DisplayCheck
	// BootModeFile is MiSTer's saved settings file for the core, where the
	// confirmed video mode is kept for the core's start; empty leaves it alone.
	BootModeFile string
	bootMode     bootModeState
	// ToMenu is set by the menu's Exit: Run returns, and the launcher loads
	// the MiSTer menu once the app has stopped.
	ToMenu bool
	// Connected is signalled by the sign-in screen once a server is saved.
	Connected chan struct{}
	// Notice is a line shown along the bottom for a few seconds (a file
	// the server refused to play).
	Notice   string
	NoticeAt time.Time
	// later holds closures for the render thread (results of background work).
	later      chan func()
	seasonData *seasonData // one selected season, shared with its opening page
	scr        *gfx.Canvas
	osd        OSD  // the playback overlay: the core's plane
	crop       Crop // the playback's crop: Options' at the start, then the playback menu's
	dim        idleDim

	stack  []Screen
	dirty  bool
	events <-chan input.Event

	secs   []plex.Section    // the libraries, fetched in the background
	pagers map[string]*Pager // listings kept for the session, by path and query
	// CacheDir is where artwork is kept (for a client made after sign-in).
	cacheDir      string
	aspects       Aspects // show shapes for the 4:3 filter
	lastSection   string  // the library the drawer opened last; it opens on it again
	theme         Theme
	lastFocus     focusPosition
	focusReady    bool
	accountLookup bool // UI-thread owned; prevents overlapping account-name requests
}

// SetCacheDir sets where artwork is cached.
func (a *App) SetCacheDir(dir string) { a.cacheDir = dir; a.aspects.load(dir) }

// New builds the app around a client and a presenter.
func New(c *plex.Client, out Presenter, player *Player, lg *log.Logger) *App {
	a := &App{Plex: c, Out: out, Player: player, Log: lg, Wake: make(chan struct{}, 1), Connected: make(chan struct{}, 1), later: make(chan func(), 32)}
	// more Ps than cores so a decoding worker can never hold the drawing
	// loop off the scheduler; the OS then arbitrates by thread priority
	runtime.GOMAXPROCS(4)
	// the box has 512 MB shared with the transcoder pipeline: keep the heap
	// small and let the collector work harder rather than grow
	debug.SetGCPercent(100)
	debug.SetMemoryLimit(96 << 20)
	a.Art = NewArt(c, 2, a.Wake)
	a.T = gfx.NewTextCache(1, a.Wake)
	a.pagers = map[string]*Pager{}
	if c != nil {
		go a.loadSections()
	}
	a.F = Fonts{Title: gfx.Load("med22"), Body: gfx.Load("med18"), BodyLight: gfx.Load("reg18"),
		Small: gfx.Load("reg16"), SmallBold: gfx.Load("med16"), Big: gfx.Load("bold28"), Mark: gfx.Load("condit24"),
		MarkZ: gfx.Load("blackit26"), MarkM: gfx.Load("blackit17")}
	a.Mark = NewWordmark()
	warmFades(720, 480)
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

// Pop returns to the previous screen; false at the root.
func (a *App) Pop() bool {
	if len(a.stack) <= 1 {
		return false
	}
	a.stack = a.stack[:len(a.stack)-1]
	a.syncTheme()
	a.dirty = true
	return true
}

func (a *App) top() Screen { return a.stack[len(a.stack)-1] }

// Open acts on a selected item: the preplay page for a movie (or straight
// to playback when direct), a show's page of seasons, a season's page of
// episodes, and for an episode its season's page with it highlighted.
func (a *App) Open(it *plex.Item, direct bool) {
	switch it.Type {
	case "more":
		// the end of a home row: the library, newest first
		if s, ok := a.section(it.Key); ok {
			a.Push(NewWallView(a, s, 1))
		}
	case "movie":
		if direct {
			a.PlayAt(it, it.ViewOffset)
			return
		}
		a.Push(NewPreplay(a, it))
	case "show":
		seasons, err := a.seasonsOf(it)
		if err != nil {
			a.Log.Printf("seasons of %s: %v", it.Title, err)
			return
		}
		if it.Logo == "" || it.Summary == "" {
			if fresh, err := a.Plex.Item(it.RatingKey); err == nil {
				*it = *fresh
			}
		}
		if len(seasons) == 1 {
			a.Push(NewShowInSeason(a, it, seasons, 0, ""))
			return
		}
		a.Push(NewShow(a, it, seasons))
	case "season":
		a.openSeason(it.ParentKey, it.RatingKey, "")
	case "episode":
		if it.GrandKey == "" || it.ParentKey == "" {
			if fresh, err := a.Plex.Item(it.RatingKey); err == nil {
				*it = *fresh
			}
		}
		a.openSeason(it.GrandKey, it.ParentKey, it.RatingKey)
	}
}

// seasonsOf lists a show's seasons, without the "All episodes" pseudo-season.
func (a *App) seasonsOf(show *plex.Item) ([]*plex.Item, error) {
	items, err := a.Plex.Items(show.Key, nil, 500)
	if err != nil {
		return nil, err
	}
	out := items[:0]
	for _, s := range items {
		if strings.HasSuffix(s.Key, "/allLeaves") {
			continue
		}
		out = append(out, s)
	}
	return out, nil
}

// openSeason opens a season's page given the show's and the season's
// rating keys, highlighting the episode at (or the first unwatched).
func (a *App) openSeason(showKey, seasonKey, at string) {
	show, err := a.Plex.Item(showKey)
	if err != nil {
		a.Log.Printf("show %s: %v", showKey, err)
		return
	}
	seasons, err := a.seasonsOf(show)
	if err != nil {
		a.Log.Printf("seasons of %s: %v", show.Title, err)
		return
	}
	si := 0
	for i, s := range seasons {
		if s.RatingKey == seasonKey {
			si = i
		}
	}
	if len(seasons) == 0 {
		return
	}
	a.Push(NewShowInSeason(a, show, seasons, si, at))
}

// pager returns the listing for a path and query, kept for the session
// so a library reopens where its count and pages already are.
func (a *App) pager(path string, q url.Values, filter func(*plex.Item) bool) *Pager {
	key := path + "?" + q.Encode()
	if filter != nil {
		key += "|filtered"
	}
	if p := a.pagers[key]; p != nil {
		return p
	}
	var prepare func([]*plex.Item)
	if filter != nil {
		prepare = a.measureShows // shows need a probe before the filter can judge them
	}
	p := NewPager(a.Plex, path, q, a.Wake, filter, prepare)
	a.pagers[key] = p
	return p
}

// PlayAt plays an item from an offset in seconds (its resume point when
// offset equals the item's, the start when 0) and refreshes it afterwards.
func (a *App) PlayAt(it *plex.Item, offset int) { a.PlayQueue(it, offset, nil, 0) }

// PlayQueue is PlayAt with the items around it (a season's episodes), so
// the overlay's Prev and Next can move along them. The screen cuts to
// black at once, with the title, the bar and the times on the overlay
// and the wait dot running in the middle while the stream comes up;
// when the presenter publishes its first frame the dot goes and the UI
// drives the overlay until playback ends.
func (a *App) PlayQueue(it *plex.Item, offset int, queue []*plex.Item, idx int) {
	if a.Player == nil {
		return
	}
	if a.Player.Access != nil {
		if err := a.Player.Access(); err != nil {
			if err == beta.ErrLocked {
				a.Push(NewBetaAccess(a, func() { a.PlayQueue(it, offset, queue, idx) }))
			} else {
				a.Notice, a.NoticeAt = err.Error(), time.Now()
				a.dirty = true
			}
			return
		}
	}
	if os.Getenv("PLEXCRT_NOPLAY") != "" {
		// scripted walks: show the starting state for a moment, play nothing
		a.Log.Printf("would play %s (%s) at %d", it.Title, it.RatingKey, offset)
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
				h.refreshResult = nil
				h.refreshAt = time.Time{}
			}
		}
	}()
	if a.osd == nil {
		if r, ok := a.Out.(*ring.Ring); ok {
			a.osd = r.Overlay()
		}
	}
	a.theme.Stop() // ALSA is single-client: wait for aplay before the launcher
	defer a.syncTheme()
	a.Player.Reap()
	// each playback starts with Options' crop; one changed in the playback
	// menu holds through the queue (autoplay, Prev, Next) and ends with it
	a.crop = a.Cfg.Crop.valid()
	for {
		a.Log.Printf("play %s (%s) at %d", it.Title, it.RatingKey, offset)
		a.Starting = time.Now()
		a.blank()
		sess, err := a.Player.Start(it.RatingKey, offset)
		if err != nil {
			a.Log.Printf("play: %v", err)
			a.Notice, a.NoticeAt = err.Error(), time.Now()
			break
		}
		ctl := NewPlaying(a, it, queue, idx, sess.Send)
		ctl.pos = float64(offset)
		if offset < 0 {
			ctl.pos = float64(it.ViewOffset)
		}
		ctl.starting, ctl.waitSpec = a.osd != nil, os.Getenv("PLEXCRT_WAIT_DOT")
		next, ended := a.playLoop(sess, ctl)
		if msg, err := os.ReadFile("/tmp/plexplay.stat.err"); err == nil && len(msg) > 0 {
			a.Notice = plex.Fold(strings.TrimSpace(string(msg)))
			a.NoticeAt = time.Now()
			os.Remove("/tmp/plexplay.stat.err")
		}
		if fresh, err := a.Plex.Item(it.RatingKey); err == nil {
			*it = *fresh
		}
		if next == 0 && ended && queue != nil && idx+1 < len(queue) && !a.Cfg.NoAutoplay {
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
		offset = it.ViewOffset
	}
	a.Starting = time.Time{}
	a.dirty = true
}

// blank presents a black frame: the menu is gone the moment Play is pressed.
func (a *App) blank() {
	c := a.Out.Begin()
	c.Fill(0, 0, c.W, c.H, gfx.Black)
	a.Out.End()
}

// playLoop runs one playback: the wait dot until the picture is up, then
// keys go to the overlay controller, which brings the dot back whenever
// the frames stop. Returns the controller's Next (+1/-1 for the queue, 0
// to stop) and whether the stream ran to its end.
func (a *App) playLoop(sess *Session, ctl *Playing) (int, bool) {
	// The overlay is drawn once per field, right after the core's field
	// counter moves, and at once after a key. The dot's run and the
	// focus bar are sprites the core draws from single word stores.
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
	// two cores: more Ps only spin looking for work against the decoder
	defer runtime.GOMAXPROCS(runtime.GOMAXPROCS(2))
	up := false
	stopped := false
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
			}
			if a.osd != nil {
				// the menus use neither the plane nor the sprites, and the
				// wait dot may still be running
				a.osd.Hide()
				ctl.end(a.osd)
				a.osd.Dot(0, 0, 0, false)
				a.osd.Bar(0, 0, 0, 0, 0, false)
			}
			ended := !stopped && ctl.Next == 0 && ctl.dur > 0 && ctl.pos >= ctl.dur-30
			return ctl.Next, ended
		case ev, ok := <-a.events:
			if !ok {
				sess.Stop()
				continue
			}
			if a.wake(ev, time.Now()) {
				continue
			}
			if !up {
				if ev.Key == input.Back && !ev.Release && !ev.Repeat {
					if a.osd != nil {
						ctl.end(a.osd) // the dot goes with the press
					}
					sess.Stop() // gave up waiting
				}
				continue
			}
			if ctl.Key(ev, time.Now()) {
				if a.osd != nil {
					a.osd.Hide()
					ctl.end(a.osd)
				}
				stopped = true
				sess.Stop()
			} else if a.osd != nil {
				ctl.Tick(time.Now(), a.osd, false) // the overlay answers the key at once
				selectionPresented()
			}
		case <-tick.C:
			if fields != nil {
				f := fields.Field()
				if f == lastField {
					continue // not a new field yet
				}
				lastField = f
			}
			a.idle(time.Now(), up && ctl.paused)
			if !up {
				// Up is the presenter's first frame, not its launch: it starts
				// long before the stream gives it a picture. Without the ring
				// there is no frame to see, only the presenter's status file.
				if a.Out.Foreign() || a.osd == nil && a.Player.Started(a.Starting) {
					up = true // the dot goes; the strip runs out over the picture
					a.Starting = time.Time{}
					if frames != nil {
						lastFrame, _ = frames.Published()
					}
					if a.osd != nil {
						ctl.framed(time.Now(), a.osd)
					}
					continue
				}
				if a.osd != nil {
					// black under, the title and the bar over, the dot in the
					// middle, until the picture
					ctl.peekAt, ctl.peekFor = time.Now(), OsdLinger
					ctl.Tick(time.Now(), a.osd, true)
				}
				continue
			}
			if a.osd != nil {
				// a frame from the presenter (a wiped header is none): the
				// picture is moving, so no wait dot
				if frames != nil {
					if seq, ok := frames.Published(); ok && seq != lastFrame {
						lastFrame = seq
						ctl.framed(time.Now(), a.osd)
					}
				}
				ctl.Tick(time.Now(), a.osd, true)
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
	secs, err := a.Plex.Sections()
	if err != nil {
		a.Log.Printf("sections: %v", err)
		return
	}
	a.secs = secs
	select {
	case a.Wake <- struct{}{}:
	default:
	}
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
	if len(a.secs) == 0 {
		a.loadSections() // not in yet: one request, the first time only
	}
	items, cur := a.menuItems()
	a.Push(NewDrawer(a, a.stack[0], items, cur))
}

// menuItems lists the drawer's entries, with the one to open on.
func (a *App) menuItems() ([]*plex.Item, int) {
	items := []*plex.Item{{Title: "Home", Type: "home"}, {Title: "Search", Type: "search"}}
	for _, s := range a.secs {
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

// Later queues a closure to run on the render thread before the next frame.
func (a *App) Later(f func()) {
	select {
	case a.later <- f:
	default:
	}
	select {
	case a.Wake <- struct{}{}:
	default:
	}
}

func (a *App) runLater() {
	for {
		select {
		case f := <-a.later:
			f()
			a.dirty = true
		default:
			return
		}
	}
}

// Start shows the first screen: home when a server is on record (or a
// client was given), the sign-in otherwise.
func (a *App) Start() {
	// the core keeps its overlay plane and sprites across a restart of
	// this process: take them down before anything is on screen
	if r, ok := a.Out.(*ring.Ring); ok && a.osd == nil {
		a.osd = r.Overlay()
		a.osd.Dot(0, 0, 0, false)
		a.osd.Bar(0, 0, 0, 0, 0, false)
	}
	if a.Plex != nil {
		a.Push(NewHome(a))
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
	if a.Player != nil {
		a.Player.Env = []string{"PLEX_HOST=" + cfg.ServerURL, "PLEX_TOKEN=" + cfg.ServerToken, "PLEX_CLIENT_ID=" + cfg.ClientID}
	}
	a.stack = nil
	a.Push(NewHome(a))
}

// SignOut forgets the sign-in and returns to the sign-in screen.
func (a *App) SignOut() {
	if err := a.Cfg.SignOut(); err != nil {
		a.Log.Printf("config: %v", err)
		a.Notice, a.NoticeAt = "Could not save sign-out. Check free space and retry.", time.Now()
		return
	}
	a.Plex = nil
	a.secs = nil
	a.pagers = map[string]*Pager{}
	a.stack = nil
	a.Push(NewLogin(a))
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

// selectStream makes stream i of an item's audio or subtitle tracks the
// part's default on the server (-1: no subtitles) and marks it in the item.
func (a *App) selectStream(it *plex.Item, kind string, i int) {
	streams := it.Audio
	if kind == "Subtitles" {
		streams = it.Subs
	}
	if it.PartID == "" {
		return
	}
	var err error
	if kind == "Subtitles" {
		id := "0"
		if i >= 0 && i < len(streams) {
			id = streams[i].ID
		}
		err = a.Plex.SelectSubtitle(it.PartID, id)
	} else {
		if i < 0 || i >= len(streams) {
			return
		}
		err = a.Plex.SelectAudio(it.PartID, streams[i].ID)
	}
	if err != nil {
		a.Log.Printf("select %s: %v", kind, err)
		return
	}
	for k := range streams {
		streams[k].Selected = k == i
	}
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
	defer a.theme.Stop()
	if r, ok := a.Out.(*ring.Ring); ok {
		mode := uint32(0)
		if a.Cfg.Progressive {
			mode = 2
		}
		defer r.StartVideo(mode, a.Log.Printf)()
		a.saveBootMode(r)
	}
	a.events = events
	a.dirty = true
	runtime.LockOSThread()
	syscall.Setpriority(syscall.PRIO_PROCESS, 0, -5)
	animating := false
	readyFile := os.Getenv("MISTERZINE_PLEX_READY_FILE")
	var worst, total time.Duration
	frames, late := 0, 0
	lastStat := time.Now()
	idle := time.NewTicker(time.Second) // re-present when idle: another
	defer idle.Stop()                   // process may have blanked the ring
	for {
		select {
		case <-stop:
			return
		default:
		}
		cadenced := a.pacedTransition()
		if animating {
			// one frame per field while something moves; drain input meanwhile
			// Show layout transitions instead render ahead and publish every
			// vsync, using the complete field drawing budget.
			if !cadenced {
				a.Out.WaitField(20 * time.Millisecond)
			}
		drain:
			for {
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
				default:
					break drain
				}
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
		a.idle(time.Now(), a.menuWaiting()) // the idle tick checks it every second
		a.pollUpdates(time.Now())
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
			animating = a.drawScreen(c, t0)
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
				a.Log.Printf("frames %d: avg %.1f ms, worst %.1f ms, missed fields %d", frames, float64(total)/float64(frames)/1e6, float64(worst)/1e6, late)
				worst, total, late, frames = 0, 0, 0, 0
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
	if a.wake(ev, now) {
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
		a.scr = gfx.NewCanvas(max(w, 720), max(h, 64))
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
