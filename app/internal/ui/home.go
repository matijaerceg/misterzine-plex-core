package ui

import (
	"errors"
	"fmt"
	"log"
	"math"
	"net/url"
	"reflect"
	"strings"
	"sync"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/plex"
)

// Layout, in 720x480 frame pixels (each 8/9 as wide as tall on the tube, so
// a 2:3 poster is 135x180 and a 16:9 still is 196x98).
const (
	// generous: most consumer sets lose the outer edge of the raster
	SafeX, SafeY  = 56, 40
	SafeW, SafeH  = 608, 400
	SafeBottom    = SafeY + SafeH
	PosterW       = 135
	PosterH       = 180
	PosterGap     = 22
	PosterPitch   = PosterW + PosterGap
	Visible       = 4 // posters across the safe area (4*135 + 3*22 = 606)
	StripLabelH   = 34
	FadeIn        = 220 * time.Millisecond // pictures fade in when they land
	FocusPad      = 6
	FocusT        = 4 // even, so both fields carry it: an odd width flickers
	PillH         = 4 // progress pill
	PillInset     = 6
	WatchedBright = 150 // of 255, for watched posters on the wall
	BarW          = 4   // the focus bar beside a focused line of text
	BarGap        = 14  // between the bar and the text

	// the page: the focused item's backdrop over the whole frame, fading
	// into the background behind the posters; its logo and facts above
	// the focused row's label; the posters end at the safe bottom
	TilesY     = SafeBottom - PosterH
	StripY     = TilesY - StripLabelH
	FactsY     = 182 // the facts line; the logo or title sits above it
	HeroBright = 150 // of 255
	HeroFade   = 330 // px over which it fades to the background colour
	LogoW      = 300 // clear logos fit inside this box (hero)
	LogoH      = 80
	// the hero follows the focus only once it has rested this long, so a
	// held key glides over the tiles without a fade (or a fetch) per item
	HeroRest = 250 * time.Millisecond
	// chevrons: lit when there is a row that way
	ChevronOff = gfx.Color(0x4A5266)
)

// Home is a rows screen: a page composed for the focused item (backdrop,
// logo, facts) with one row of posters over it, the other rows reached by
// Up and Down. The home screen's hero follows the focus; a show's page
// pins the hero to the show and lists its seasons.
type Home struct {
	app           *App
	view          *Show
	hubs          []*plex.Hub
	fixed         *plex.Item // the hero item of a show page; nil: the focused item
	refreshAt     time.Time
	refreshResult chan homeResult
	updating      bool // a filter changed in Options: rows are being fetched again
	home          bool // the home screen: hamburger, Left at the edge opens the menu
	row           int
	col           []int
	rowAt         time.Time // when the focused row last changed (its posters fade in)
	rowY          Anim      // incoming row slides toward its resting position
	colX          []Anim    // per strip horizontal scroll in pixels
	err           error
	problem       netProblem // why err happened, in the user's terms
	connecting    bool       // err is being retried quietly: "Connecting..." instead
	graceUntil    time.Time  // until then no answer at all is retried quietly
	failedSince   time.Time  // start of the current run of failures
	empty         bool
	holes         []gfx.Rect // areas painted this frame, skipped by the page copy

	page, pagePrev *gfx.Canvas // composed page, and the one before it for the cross-fade
	pageKey        string      // item + row + which pictures were in
	pageRow        int
	fade           Fade
	logo           logoLayer
	focusAt        time.Time // when the focus last moved
	preloadAfter   time.Time
	artworkWarmed  bool
	animating      bool // last draw; used to schedule home frames on vsync
}

// NewHome loads the initial rows synchronously. A server that cannot be
// reached yet is retried in the background (see ConnectGrace).
func NewHome(app *App) *Home {
	h := &Home{app: app, home: true, graceUntil: time.Now().Add(ConnectGrace)}
	h.reload()
	return h
}

// focusSeason puts the cursor on season i, scrolled into view.
func (h *Home) focusSeason(i int) {
	if len(h.hubs) == 0 || i < 0 || i >= len(h.hubs[0].Items) {
		return
	}
	h.col[0] = i
	first := 0
	if i >= Visible {
		first = i - Visible + 1
	}
	h.colX[0].Set(float64(first * PosterPitch))
	h.focusAt = time.Time{}
}

// reload fetches the rows: Continue Watching, then each library's
// recently added, fetched together.
func (h *Home) reload() {
	h.refreshResult = nil // discard any older background request
	hubs, secs, err := fetchHome(h.app.Plex, h.app.Log)
	if err == nil {
		h.app.measureHubs(hubs)
	}
	h.load(homeResult{hubs, secs, err}, time.Now())
}

// load installs a fetch result and schedules the next background refresh.
func (h *Home) load(r homeResult, now time.Time) {
	if r.err != nil {
		h.fail(r.err, now)
		return
	}
	h.refreshAt = now.Add(30 * time.Second)
	h.connected(now)
	h.app.knownSections(r.secs)
	h.applyHome(r.hubs)
}

// fail shows that the server gave no rows: quietly retried while nothing
// answers within the grace period, otherwise as an error retried every 30 s.
func (h *Home) fail(err error, now time.Time) {
	problem := classify(err, now)
	connecting := unreachable(err) && now.Before(h.graceUntil)
	// once per cause, not once per retry
	if h.err == nil || problem != h.problem || connecting != h.connecting {
		h.app.Log.Printf("home: %v", err)
	}
	if h.err == nil {
		h.failedSince = now
	}
	h.err, h.problem, h.connecting = err, problem, connecting
	if connecting {
		h.refreshAt = now.Add(ConnectRetry)
	} else {
		h.refreshAt = now.Add(30 * time.Second)
	}
	h.setHubs(nil)
}

// connected ends a run of failures.
func (h *Home) connected(now time.Time) {
	if h.err != nil {
		h.app.Log.Printf("home: connected after %.0f s", now.Sub(h.failedSince).Seconds())
	}
	h.err, h.connecting = nil, false
}

type homeResult struct {
	hubs []*plex.Hub
	secs []plex.Section
	err  error
}

// fetchHome owns its data; the worker never reads or changes screen state.
// A row that fails is dropped and logged rather than failing the screen:
// a large library answers /hubs slowly, and one broken library must not
// hide the others. Only a server that answers nothing is an error. The
// libraries come back too, for the menu and the rows' "See all" tiles.
func fetchHome(client *plex.Client, lg *log.Logger) ([]*plex.Hub, []plex.Section, error) {
	var hubs []*plex.Hub
	var hubsErr error
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		hubs, hubsErr = client.Hubs(30)
	}()
	secs, err := client.Sections()
	if err != nil {
		wg.Wait()
		return nil, nil, err
	}
	rows := make([]*plex.Hub, len(secs))
	errs := make([]error, len(secs))
	for i, s := range secs {
		wg.Add(1)
		go func(i int, s plex.Section) {
			defer wg.Done()
			hub, err := client.SectionRecent(s.Key, 30)
			if err != nil || hub == nil {
				errs[i] = err
				return
			}
			name := "Recently Added"
			if strings.Contains(hub.Ident, "recentlyaired") {
				name = "Recently Aired"
			}
			hub.Title = name + " in " + s.Title
			// the row ends with a tile that opens the whole library, newest first
			hub.Items = append(hub.Items, &plex.Item{Type: "more", Title: "See all", Key: s.Key})
			rows[i] = hub
		}(i, s)
	}
	wg.Wait()
	if hubsErr != nil {
		lg.Printf("home: continue watching skipped: %v", hubsErr)
		hubs = nil
	}
	failed := 0
	for i, err := range errs {
		if err != nil {
			failed++
			lg.Printf("home: library %q skipped: %v", secs[i].Title, err)
		}
	}
	if hubsErr != nil && len(secs) > 0 && failed == len(secs) {
		return nil, nil, errs[0]
	}
	for _, r := range rows {
		if r != nil {
			hubs = append(hubs, r)
		}
	}
	return hubs, secs, nil
}

// shortErr is the error on one screen line: for a request, the path and
// the cause rather than the whole URL.
func shortErr(err error) string {
	s := err.Error()
	var ue *url.Error
	if errors.As(err, &ue) {
		path := ue.URL
		if u, perr := url.Parse(ue.URL); perr == nil {
			path = u.Path
		}
		s = path + ": " + ue.Err.Error()
	}
	if len(s) > 70 {
		s = s[:67] + "..."
	}
	return s
}

// pollHome runs on the render thread, including while the screen is idle.
func (h *Home) pollHome(now time.Time) {
	if !h.home {
		return
	}
	if h.refreshResult != nil {
		select {
		case result := <-h.refreshResult:
			h.refreshResult = nil
			h.updating = false
			h.app.dirty = true
			if result.err != nil && h.err == nil {
				h.refreshAt = now.Add(30 * time.Second)
				h.app.Log.Printf("home refresh: %v", result.err)
				return // keep the last usable rows during a network outage
			}
			h.load(result, now)
		default:
		}
		return
	}
	if now.Before(h.refreshAt) {
		return
	}
	result := make(chan homeResult, 1)
	h.refreshResult = result
	client, lg := h.app.Plex, h.app.Log
	go func() {
		hubs, secs, err := fetchHome(client, lg)
		if err == nil {
			h.app.measureHubs(hubs)
		}
		result <- homeResult{hubs, secs, err}
		select {
		case h.app.Wake <- struct{}{}:
		default:
		}
	}()
}

func (h *Home) applyHome(hubs []*plex.Hub) {
	// the user's filters (Options) apply to the rows
	kept := hubs[:0]
	for _, hub := range hubs {
		items := hub.Items[:0]
		for _, it := range hub.Items {
			if h.app.Keep(it) {
				items = append(items, it)
			}
		}
		hub.Items = items
		if len(items) > 1 || (len(items) == 1 && items[0].Type != "more") {
			kept = append(kept, hub)
		}
	}
	if reflect.DeepEqual(h.hubs, kept) {
		h.empty = len(kept) == 0
		return
	}
	oldHubs, oldCol, oldScroll, oldRow := h.hubs, h.col, h.colX, h.row
	h.col = make([]int, len(kept))
	h.colX = make([]Anim, len(kept))
	h.row = 0
	for i, hub := range kept {
		for j, old := range oldHubs {
			if hub.Ident != old.Ident || hub.Key != old.Key || hub.Title != old.Title {
				continue
			}
			if j == oldRow {
				h.row = i
			}
			if oldCol[j] < len(old.Items) {
				selected := old.Items[oldCol[j]]
				h.col[i] = min(oldCol[j], len(hub.Items)-1)
				for k, item := range hub.Items {
					if item.RatingKey == selected.RatingKey && item.Key == selected.Key {
						h.col[i] = k
						break
					}
				}
			}
			first := round(oldScroll[j].Target()) / PosterPitch
			first = max(0, min(first, len(hub.Items)-Visible))
			first = min(first, h.col[i])
			first = max(first, h.col[i]-Visible+1)
			h.colX[i].Set(float64(first * PosterPitch))
			break
		}
	}
	h.setHubs(kept)
	h.pageKey = ""
}

func (h *Home) setHubs(hubs []*plex.Hub) {
	h.hubs = hubs
	h.artworkWarmed = false
	h.empty = len(hubs) == 0
	if len(h.col) != len(hubs) {
		h.col = make([]int, len(hubs))
		h.colX = make([]Anim, len(hubs))
	}
	if h.row >= len(hubs) {
		h.row = 0
	}
	for i := range hubs {
		if h.col[i] >= len(hubs[i].Items) {
			h.col[i] = 0
		}
	}
}

// Focused returns the item under the cursor.
func (h *Home) Focused() *plex.Item {
	if h.row >= len(h.hubs) {
		return nil
	}
	hub := h.hubs[h.row]
	if h.col[h.row] >= len(hub.Items) {
		return nil
	}
	return hub.Items[h.col[h.row]]
}

// Key handles one input event.
func (h *Home) Key(ev input.Event, now time.Time) {
	if len(h.hubs) == 0 {
		if ev.Key == input.Enter && h.home && !ev.Release && !ev.Repeat {
			// in the background, so a server that does not answer cannot
			// hold up the screen; an error shows Connecting... meanwhile
			h.connecting = h.err != nil
			h.refreshAt = time.Time{}
		}
		return
	}
	if h.home && (ev.Key == input.Left || ev.Key == input.Right) {
		// Cover the initial key-repeat delay, then extend on every repeat.
		delay := 600 * time.Millisecond
		if ev.Release {
			delay = HeroRest // let the final scroll and hero settle first
		}
		h.preloadAfter = now.Add(delay)
		if h.app.Art != nil {
			h.app.Art.DeferBackground(h.preloadAfter)
		}
	}
	if ev.Release {
		h.colX[h.row].Settle(now)
		return
	}
	oldRow := h.row
	hub := h.hubs[h.row]
	pitch, vis := PosterPitch, Visible
	switch ev.Key {
	case input.Left:
		if h.col[h.row] > 0 {
			h.col[h.row]--
		} else if !ev.Repeat && h.home {
			h.app.Menu() // off the left edge: same as Back
			return
		}
	case input.Right:
		if h.col[h.row] < len(hub.Items)-1 {
			h.col[h.row]++
		}
	case input.JumpBack:
		h.col[h.row] -= vis
		if h.col[h.row] < 0 {
			h.col[h.row] = 0
		}
	case input.JumpFwd:
		h.col[h.row] += vis
		if h.col[h.row] > len(hub.Items)-1 {
			h.col[h.row] = len(hub.Items) - 1
		}
	case input.Up:
		if h.row > 0 {
			h.row--
			h.rowAt = now
		}
	case input.Down:
		if it := h.Focused(); h.view != nil && it != nil && it.Type != ShuffleTile {
			h.view.enterSeason(h.col[0], "", now)
			return
		}
		if h.row < len(h.hubs)-1 {
			h.row++
			h.rowAt = now
		}
	case input.Enter:
		if it := h.Focused(); it != nil {
			if h.view != nil && it.Type == "season" {
				h.view.enterSeason(h.col[0], "", now)
				return
			}
			if h.view != nil && it.Type == ShuffleTile {
				h.view.shuffle(nil)
				return
			}
			h.app.Open(it, false)
		}
	}
	if h.row != oldRow {
		direction := 1
		if h.row < oldRow {
			direction = -1
		}
		h.rowY.Set(float64(direction * 48))
		h.rowY.Go(0, now)
	}
	h.focusAt = now
	// keep the focused tile inside the visible columns
	c := h.col[h.row]
	first := round(h.colX[h.row].Target()) / pitch
	if c < first {
		first = c
	} else if c >= first+vis {
		first = c - vis + 1
	}
	h.colX[h.row].Move(float64(first*pitch), now, ev.Repeat)
}

// Refresh re-reads one item after playback (view offset, watched state).
func (h *Home) Refresh(it *plex.Item) {
	fresh, err := h.app.Plex.Item(it.RatingKey)
	if err != nil {
		return
	}
	*it = *fresh
}

// Draw paints the screen; returns true while something is still animating.
func (h *Home) Draw(c *gfx.Canvas, now time.Time) bool {
	if h.err != nil {
		c.Fill(0, 0, c.W, c.H, gfx.Bg)
		if h.connecting {
			server := "your Plex server"
			if h.app.Cfg != nil && h.app.Cfg.ServerName != "" {
				server = h.app.Cfg.ServerName
			}
			h.app.text(c, SafeX, SafeY+40, h.app.F.Body, gfx.GreyHi, h.app.F.Body.Fit("Connecting to "+server+"...", SafeW))
			h.app.text(c, SafeX, SafeY+70, h.app.F.Small, gfx.GreyLo, h.problem.waiting())
			return false
		}
		headline, advice := h.problem.failure()
		h.app.text(c, SafeX, SafeY+40, h.app.F.Body, gfx.GreyHi, headline)
		h.app.text(c, SafeX, SafeY+70, h.app.F.Small, gfx.GreyLo, advice)
		h.app.text(c, SafeX, SafeY+110, h.app.F.Small, gfx.GreyLo, "OK: retry. Back: menu, then Options to choose a server.")
		h.app.text(c, SafeX, SafeY+160, h.app.F.Small, gfx.GreyLo, shortErr(h.err))
		return false
	}
	if h.empty {
		c.Fill(0, 0, c.W, c.H, gfx.Bg)
		h.app.text(c, SafeX, SafeY+40, h.app.F.Body, gfx.GreyHi, "Nothing to show yet.")
		return false
	}
	// the page is copied in around the posters, so each frame pixel is
	// written once (the frame is write-combined)
	h.holes = h.holes[:0]
	ox := round(h.colX[h.row].At(now))
	ty := TilesY + round(h.rowY.At(now))
	for j := range h.hubs[h.row].Items {
		x := SafeX + j*PosterPitch - ox
		if x+PosterW <= 0 || x >= c.W {
			continue
		}
		h.holes = append(h.holes, gfx.Rect{X: max(x, 0), Y: max(ty, 0), W: min(x+PosterW, c.W) - max(x, 0), H: min(ty+PosterH, c.H) - max(ty, 0)})
	}
	t0 := time.Now()
	anim := h.drawPage(c, now)
	t1 := time.Now()
	anim = h.drawStrip(c, now) || anim
	if !now.Before(h.preloadAfter) {
		h.prefetchPosters()
		h.prefetchBackdrops(c.W, c.H)
		h.warmHomeArtwork(c.W, c.H)
	}
	if h.fixed != nil {
		if now.Sub(h.focusAt) < HeroRest {
			anim = true // wake once the selection has settled
		} else if sea := h.Focused(); sea != nil && sea.Type == "season" {
			h.app.prefetchSeason(sea, h.fixed)
			if h.view != nil {
				h.view.prepareSeason(now)
			}
		}
	}
	if d := time.Since(t0); d > 16*time.Millisecond {
		h.app.Log.Printf("slow home frame: page %.1f ms, strip %.1f ms, fading %v, holes %d", float64(t1.Sub(t0))/1e6, float64(time.Since(t1))/1e6, h.pageFade().Running(), len(h.holes))
	}
	h.animating = anim
	return anim
}

// heroItem is what the page shows: the pinned item or the focused one.
func (h *Home) heroItem() *plex.Item {
	if h.fixed != nil {
		return h.fixed
	}
	it := h.Focused()
	if it != nil && it.Type == "more" && h.col[h.row] > 0 {
		return h.hubs[h.row].Items[h.col[h.row]-1] // the row's end keeps the last item's page
	}
	return it
}

// heroArt is the backdrop path for an item (the show's for an episode).
func heroArt(it *plex.Item) string {
	if it.Art != "" {
		return it.Art
	}
	return it.Thumb
}

// drawPage composes the page when the hero item or the row changes and
// cross-fades from the previous one. Composition happens once per change
// into an ordinary canvas (text blending reads pixels); each frame is then
// a copy around the posters, or a blend of two canvases.
func (h *Home) drawPage(c *gfx.Canvas, now time.Time) bool {
	it := h.heroItem()
	if it == nil {
		return false
	}
	art := heroArt(it)
	key := it.RatingKey + "|" + art + "|" + itoa(h.row)
	if h.page != nil && !strings.HasPrefix(h.pageKey, key) && h.pageRow == h.row && now.Sub(h.focusAt) < HeroRest {
		// still moving along the row: keep the page, and keep drawing until it rests
		c.BlitExcept(h.page, h.holes)
		h.logoLayer().draw(c, h.page, now)
		return true
	}
	img, _, _ := h.app.Art.get(h.backdropRequest(art, c.W, c.H))
	if img != nil {
		key += "|art"
	}
	var logo *gfx.Image
	logoPending := false
	if it.Logo != "" {
		var failed bool
		if logo, failed = h.app.Art.GetLogo(it.Logo, LogoW, LogoH); logo != nil {
			key += "|logo"
		} else {
			logoPending = !failed
		}
	}
	sliding := h.pageFade().Transitioning(now)
	if key != h.pageKey && !sliding {
		h.pageFade().Done() // the worker may still be reading the previous page
		h.page, h.pagePrev = h.pagePrev, h.page
		if h.page == nil {
			h.page = gfx.NewCanvas(c.W, c.H)
		}
		h.compose(h.page, it, img, logo, logoPending)
		h.pageKey = key
		h.pageRow = h.row
		if h.pagePrev != nil {
			h.pageFade().Start(h.pagePrev, h.page, now)
		}
	}
	// the logo rides above the page; a season page hands it back to us
	lx, ly := SafeX, h.logoY(logo)
	if hd := h.takeTransition(); hd != nil {
		h.pageFade().Layout(hd.Page, h.page, img, hd.ArtY, 0, now)
		h.logoLayer().enterFrom(hd, logo, lx, ly, now)
	} else if !sliding {
		h.logoLayer().set(logo, lx, ly, now, animDur)
	}
	show, fading := h.pageFade().Frame(now)
	if !fading {
		show = h.page
	}
	c.BlitExcept(show, h.holes)
	moving := h.logoLayer().draw(c, show, now)
	if h.fixed != nil {
		// Each season keeps its name above its own poster as the row scrolls.
		ox := round(h.colX[h.row].At(now))
		for j, it := range h.hubs[h.row].Items {
			if it.Type == ShuffleTile {
				continue // it says what it is on the tile, as See all does
			}
			x := SafeX + j*PosterPitch - ox
			f := h.app.F.Body
			h.app.textOver(c, show, x, StripY, f, gfx.White, f.Fit(it.Title, PosterW))
		}
	}
	return fading || moving
}

// logoY is where the logo's top goes: sitting on the facts line.
func (h *Home) logoY(logo *gfx.Image) int {
	fy := FactsY
	if h.home {
		fy += 6
	}
	if h.fixed != nil {
		fy -= h.app.F.SmallBold.Height() + 4
	}
	lh := LogoH
	if logo != nil {
		lh = logo.H
	}
	return fy - 6 - lh
}

// compose paints the backdrop (already dimmed and faded by the art
// loader), the hamburger, the hero's logo or title and facts, and the
// focused row's label with its chevrons.
func (h *Home) compose(c *gfx.Canvas, it *plex.Item, img, logo *gfx.Image, logoPending bool) {
	f := h.app.F
	if img != nil {
		c.Blit(0, 0, img)
	} else {
		c.Fill(0, 0, c.W, c.H, gfx.Bg)
	}
	if h.home {
		// a left chevron: the drawer is off the left edge
		chevronLeft(c, SafeX+3, SafeY-8+h.app.Mark.H*60/100-6, gfx.GreyLo)
		h.app.Mark.Place(c, SafeX+16, SafeY-8)
	}
	title := it.Title
	if it.Type == "episode" {
		title = it.GrandTitle
	}
	facts := heroFacts(it)
	fy := FactsY
	if h.home {
		fy += 6
	}
	if h.fixed != nil {
		fy -= f.SmallBold.Height() + 4 // room for a line of synopsis
	}
	if logo == nil && !logoPending {
		c.Text(SafeX, fy-2-f.Big.Height(), f.Big, gfx.White, f.Big.Fit(title, SafeW))
	}
	dots(c, SafeX, fy, f.SmallBold, gfx.White, facts, SafeW)
	if h.fixed != nil && it.Summary != "" {
		c.Text(SafeX, fy+f.SmallBold.Height()+4, f.SmallBold, gfx.White, f.SmallBold.Fit(it.Summary, SafeW))
	}
	// the row label, chevrons before it (a show's page labels the row
	// with the focused season per frame instead)
	if h.fixed != nil {
		return
	}
	label := h.app.hubLabel(h.hubs[h.row])
	ly := StripY
	x := SafeX
	if len(h.hubs) > 1 {
		// white when there is a row that way, half-transparent white otherwise
		chevronA(c, SafeX+6, ly+3, true, h.row > 0)
		chevronA(c, SafeX+6, ly+15, false, h.row+1 < len(h.hubs))
		x += 22
	}
	c.Text(x, ly, f.Body, gfx.White, f.Body.Fit(label, SafeW-40))
}

// hamburger draws the three-bar menu glyph with its top-left at x,y.
func hamburger(c *gfx.Canvas, x, y int, col gfx.Color) {
	for i := 0; i < 3; i++ {
		c.Fill(x, y+2+i*7, 22, 2, col)
	}
}

// chevronA is chevron in white, at half alpha when off (composed pages only).
func chevronA(c *gfx.Canvas, cx, y int, up, on bool) {
	a := 128
	if on {
		a = 255
	}
	for i := 0; i < 6; i++ {
		w := 2 * (i + 1)
		yy := y + i
		if !up {
			yy = y + 5 - i
		}
		c.FillAlpha(cx-w/2, yy, w, 1, gfx.White, a)
	}
}

// chevron draws a small solid triangle pointing up or down, centred on cx.
func chevron(c *gfx.Canvas, cx, y int, up bool, col gfx.Color) {
	for i := 0; i < 6; i++ {
		w := 2 * (i + 1)
		yy := y + i
		if !up {
			yy = y + 5 - i
		}
		c.Fill(cx-w/2, yy, w, 1, col)
	}
}

// chevronRight draws a small solid triangle pointing right, centred on cx.
func chevronRight(c *gfx.Canvas, cx, y int, col gfx.Color) {
	for i := 0; i < 6; i++ {
		hh := 6 - i
		c.Fill(cx-3+i, y+6-hh, 1, 2*hh, col)
	}
}

// heroFacts are the short tokens under the hero title.
func heroFacts(it *plex.Item) []string {
	var t []string
	switch it.Type {
	case "episode":
		t = append(t, fmt.Sprintf("S%d E%d", it.Parent, it.Index), it.Title)
	case "show":
		if it.Year > 0 {
			t = append(t, itoa(it.Year))
		}
		if it.Children > 0 {
			t = append(t, plural(it.Children, "season"))
		}
		if it.Leaves > 0 {
			t = append(t, plural(it.Leaves, "episode"))
		}
	case "season":
		if it.Leaves > 0 {
			t = append(t, plural(it.Leaves, "episode"))
		}
	case "collection":
		word := "item"
		if it.Subtype == "movie" || it.Subtype == "show" {
			word = it.Subtype
		}
		if it.Children > 0 {
			t = append(t, plural(it.Children, word))
		}
	default:
		if it.Year > 0 {
			t = append(t, itoa(it.Year))
		}
	}
	if it.Duration > 0 {
		t = append(t, hm(it.Duration))
	}
	if it.Playable() && it.ViewCount > 0 && it.ViewOffset == 0 {
		t = append(t, "Watched")
	}
	if it.Leaves > 0 {
		if left := it.Leaves - it.Viewed; left == 0 {
			t = append(t, "Watched")
		} else if left < it.Leaves {
			t = append(t, itoa(left)+" unwatched")
		}
	}
	return t
}

func plural(n int, word string) string {
	if n == 1 {
		return "1 " + word
	}
	return itoa(n) + " " + word + "s"
}

// dots draws tokens separated by small square dots, on an ordinary canvas.
func dots(c *gfx.Canvas, x, y int, f *gfx.Font, col gfx.Color, tokens []string, maxW int) {
	right := x + maxW
	for i, t := range tokens {
		if i > 0 {
			c.Fill(x+8, (y+f.Height()/2)&^1-1, 4, 4, col)
			x += 20
		}
		if x >= right {
			return
		}
		t = f.Fit(t, right-x)
		x = c.Text(x, y, f, col, t)
	}
}

// prefetchPosters warms nearby rows and a screenful on either side of the
// current viewport. The bounded neighborhood leaves cache room for hero art;
// visible requests always take priority over this background work.
func (h *Home) prefetchPosters() {
	if h.app.Art == nil {
		return
	}
	for distance := 2; distance >= 0; distance-- {
		for row := max(0, h.row-distance); row <= min(len(h.hubs)-1, h.row+distance); row++ {
			if abs(row-h.row) != distance {
				continue
			}
			first := round(h.colX[row].Target()) / PosterPitch
			start, end := first, first+Visible
			if row == h.row {
				start, end = first-Visible, first+2*Visible
			}
			for j := max(0, start); j < min(len(h.hubs[row].Items), end); j++ {
				it := h.hubs[row].Items[j]
				if it.Type != "more" {
					h.app.Art.Prefetch(it.Thumb, PosterW, PosterH)
				}
			}
		}
	}
}

// Keep just the nearest hero candidates warm: full-screen decoded art is
// much larger than a poster. Art reuses both its bounded memory cache and
// the Plex client's disk cache when these become visible.
func (h *Home) prefetchBackdrops(w, height int) {
	if h.app.Art == nil || !h.home {
		return
	}
	for row := max(0, h.row-1); row <= min(len(h.hubs)-1, h.row+1); row++ {
		first, last := h.col[row], h.col[row]
		if row == h.row {
			first, last = first-1, last+1
		}
		for j := max(0, first); j <= min(len(h.hubs[row].Items)-1, last); j++ {
			it := h.hubs[row].Items[j]
			if it.Type != "more" {
				req := h.backdropRequest(heroArt(it), w, height)
				req.prefetch = true
				h.app.Art.get(req)
			}
		}
	}
}

// Queue every home item, including distant rows and offscreen columns.
// The loader deduplicates this persistent backlog and services it last.
func (h *Home) warmHomeArtwork(w, height int) {
	if !h.home || h.app.Art == nil || h.artworkWarmed {
		return
	}
	for _, hub := range h.hubs {
		for _, it := range hub.Items {
			if it.Type == "more" {
				continue
			}
			h.app.Art.Warm(artReq{thumb: it.Thumb, w: PosterW, h: PosterH})
			h.app.Art.Warm(h.backdropRequest(heroArt(it), w, height))
		}
	}
	h.artworkWarmed = true
}

func (h *Home) backdropRequest(thumb string, w, height int) artReq {
	return artReq{thumb: thumb, w: w, h: height, bright: HeroBright, fade: HeroFade, homeBackdrop: h.home}
}

// drawStrip paints the focused row's posters, sliding and fading them in
// from the direction of vertical travel after a row change.
func (h *Home) drawStrip(c *gfx.Canvas, now time.Time) bool {
	hub := h.hubs[h.row]
	ox := round(h.colX[h.row].At(now))
	anim := h.colX[h.row].Running(now) || h.rowY.Running(now)
	y := TilesY + round(h.rowY.At(now))
	rowT := 0 // of 256 still hidden
	if since := now.Sub(h.rowAt); since < animDur {
		rowT = 256 - int(since*256/animDur)
		anim = true
	}
	for j, it := range hub.Items {
		x := SafeX + j*PosterPitch - ox
		if x+PosterW <= 0 || x >= c.W {
			continue
		}
		anim = h.drawTile(c, it, x, y, j == h.col[h.row], rowT) || anim
	}
	return anim
}

// drawTile paints one poster over the page. Posters beyond the safe area
// are drawn into the bleed, so the neighbours peek in as far as the set
// shows. A poster fades in when it lands, and with the row when the row
// changes. The page copy has already skipped the poster's rectangle, so
// the poster and its frame are painted afterwards.
func (h *Home) drawTile(c *gfx.Canvas, it *plex.Item, x, y int, focus bool, rowT int) bool {
	w, ht := PosterW, PosterH
	whole := x >= SafeX-FocusPad && x+w <= SafeX+SafeW
	if it.Type == "more" {
		// the end of the row: a plain tile that opens the library
		c.Fill(x, y, w, ht, gfx.Bar)
		if whole {
			f := h.app.F.Body
			h.app.textCenterOn(c, x+w/2, y+ht/2-f.Height()-2, f, gfx.GreyHi, gfx.Bar, "See all")
			chevronRight(c, x+w/2, y+ht/2+10, gfx.GreyLo)
		}
		if focus {
			c.Frame(x-FocusPad, y-FocusPad, w+2*FocusPad, ht+2*FocusPad, FocusT, gfx.GreyHi)
		}
		return false
	}
	if it.Type == ShuffleTile {
		// the end of a show's seasons: a plain tile that plays them all
		c.Fill(x, y, w, ht, gfx.Bar)
		starting := focus && !h.app.Starting.IsZero() // the episodes are being listed
		if whole {
			f, g := h.app.F.Body, h.app.F.SmallBold
			ty := y + ht/2 - f.Height() - 2
			h.app.textCenterOn(c, x+w/2, ty, f, gfx.GreyHi, gfx.Bar, it.Title)
			if starting {
				tw := f.Width(it.Title)
				sweep(c, x+(w-tw)/2, ty+f.Height()+4, tw, BarW, time.Since(h.app.Starting))
			}
			h.app.textCenterOn(c, x+w/2, ty+f.Height()+12, g, gfx.GreyLo, gfx.Bar, "all episodes")
		}
		if focus {
			c.Frame(x-FocusPad, y-FocusPad, w+2*FocusPad, ht+2*FocusPad, FocusT, gfx.GreyHi)
		}
		return starting
	}
	img, age := h.app.Art.GetAge(it.Thumb, w, ht)
	fading := false
	if img != nil {
		t := rowT
		if age < FadeIn {
			t = max(t, 256-int(age*256/FadeIn))
		}
		if t > 0 {
			c.BlendSolidClip(x, y, img, gfx.Bg, t, 0, 0, c.W, c.H)
			fading = true
		} else {
			c.Blit(x, y, img)
		}
	} else {
		c.Fill(x, y, w, ht, gfx.Bar)
		if whole {
			f := h.app.F.SmallBold
			lines := wrap(f, it.Title, w-16, 4)
			ty := y + ht/2 - len(lines)*f.Height()/2
			for _, l := range lines {
				h.app.textCenterOn(c, x+w/2, ty, f, gfx.GreyLo, gfx.Bar, l)
				ty += f.Height()
			}
		}
	}
	if !whole {
		return fading
	}
	h.app.badge(c, it, x, y, w, ht)
	if focus {
		c.Frame(x-FocusPad, y-FocusPad, w+2*FocusPad, ht+2*FocusPad, FocusT, gfx.GreyHi)
	}
	return fading
}

// badge marks a poster the way the desktop app does: a progress pill
// for a partly watched film or episode, a check for a watched one, and
// for shows and seasons the number of unwatched episodes.
func (a *App) badge(c *gfx.Canvas, it *plex.Item, x, y, w, h int) {
	if it.Playable() {
		if it.ViewOffset > 0 && it.Duration > 0 {
			pw := w - 2*PillInset
			c.Fill(x+PillInset, y+h-PillInset-PillH, pw, PillH, 0x404040)
			c.Fill(x+PillInset, y+h-PillInset-PillH, pw*it.ViewOffset/it.Duration, PillH, gfx.Amber)
		} else if it.ViewCount > 0 {
			check(c, x+w-6-12, y+6+12)
		}
		return
	}
	if it.Leaves == 0 {
		return
	}
	left := it.Leaves - it.Viewed
	if left <= 0 {
		check(c, x+w-6-12, y+6+12)
		return
	}
	f := a.F.SmallBold
	s := itoa(left)
	bw := f.Width(s) + 14
	bh := f.Height() + 2
	c.Fill(x+w-6-bw, y+6, bw, bh, gfx.Amber)
	a.textOn(c, x+w-6-bw+7, y+7, f, gfx.Bg, gfx.Amber, s)
}

// check draws a watched mark: a light disc with a dark tick, centred on
// cx,cy, round on the tube (pixels are 8/9 as wide as tall).
func check(c *gfx.Canvas, cx, cy int) {
	const r = 12.0
	for dy := -12; dy <= 12; dy++ {
		half := math.Sqrt(r*r-float64(dy*dy)) * 9 / 8
		hw := int(half + 0.5)
		if hw > 0 {
			c.Fill(cx-hw, cy+dy, 2*hw, 1, gfx.GreyHi)
		}
	}
	// the tick: a short stroke down-right, a longer one up-right, 3 px thick
	for i := 0; i < 4; i++ {
		c.Fill(cx-7+i, cy-1+i, 3, 3, gfx.Bg)
	}
	for i := 0; i < 8; i++ {
		c.Fill(cx-3+i, cy+2-i, 3, 3, gfx.Bg)
	}
}

// focusBar draws the mark beside a focused line of text: a short bar to
// the left of x, as tall as the text.
func focusBar(c *gfx.Canvas, x, y, h int) {
	c.Fill(x-BarGap-BarW, y+2, BarW, h-4, gfx.GreyHi)
}

// itemLine is the one-line description of an item (lists, walls).
func itemLine(it *plex.Item) string {
	s := it.Title
	if it.Type == "episode" {
		s = fmt.Sprintf("%s  S%dE%d  %s", it.GrandTitle, it.Parent, it.Index, it.Title)
	} else if it.Year > 0 {
		s = fmt.Sprintf("%s (%d)", it.Title, it.Year)
	}
	if it.Duration > 0 {
		s += "  " + hm(it.Duration)
	}
	return s
}

func hm(sec int) string {
	if sec >= 3600 {
		return fmt.Sprintf("%dh %02dm", sec/3600, sec%3600/60)
	}
	return fmt.Sprintf("%dm", sec/60)
}

// wrap breaks s into at most n lines that fit maxW, on spaces.
func wrap(f *gfx.Font, s string, maxW, n int) []string {
	var out []string
	line := ""
	for _, w := range splitWords(s) {
		t := w
		if line != "" {
			t = line + " " + w
		}
		if f.Width(t) <= maxW || line == "" {
			line = t
			continue
		}
		if len(out) == n-1 {
			// more follows than fits: the last line is cut with an ellipsis
			out = append(out, f.Fit(t+" "+strings.Repeat(".", 3), maxW))
			return out
		}
		out = append(out, line)
		line = w
	}
	if line != "" {
		out = append(out, f.Fit(line, maxW))
	}
	return out
}

// wrapAll breaks s into as many lines as it takes.
func wrapAll(f *gfx.Font, s string, maxW int) []string {
	return wrap(f, s, maxW, 1<<20)
}

func splitWords(s string) []string {
	var out []string
	w := ""
	for i := 0; i < len(s); i++ {
		if s[i] == ' ' {
			if w != "" {
				out = append(out, w)
			}
			w = ""
			continue
		}
		w += string(s[i])
	}
	if w != "" {
		out = append(out, w)
	}
	return out
}

func (h *Home) pageFade() *Fade {
	if h.view != nil {
		return &h.view.fade
	}
	return &h.fade
}
func (h *Home) logoLayer() *logoLayer {
	if h.view != nil {
		return &h.view.logo
	}
	return &h.logo
}
func (h *Home) takeTransition() *Handoff {
	if h.view == nil {
		return nil
	}
	return h.view.takeTransition()
}
