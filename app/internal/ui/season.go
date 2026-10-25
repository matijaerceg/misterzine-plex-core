package ui

import (
	"slices"
	"strings"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/plex"
)

// Season is a season's page: the show's logo and the season's facts over
// a strip of backdrop, a filmstrip of episode stills, and under it the
// highlighted episode's title, facts, synopsis and actions. Every episode
// is played and marked from here; the shoulder buttons step seasons.
type Season struct {
	periodic viewRefresh
	app      *App
	view     *Show
	show     *plex.Item
	seasons  []*plex.Item // the show's seasons, for stepping
	si       int          // which one this is
	eps      []*plex.Item
	thumbs   map[string]*artEntry // retained for this season, independent of the shared LRU
	cur      int
	colX     Anim
	acts     bool // the cursor is on the actions, not the filmstrip
	pick     bool // the cursor is on the season picker in the header
	act      int
	actions  []string
	cw       continueList
	err      error
	holes    []gfx.Rect
	fetched  map[string]bool // episodes whose streams have been asked for
	moved    time.Time       // the cursor last stepped along the filmstrip
	loading  bool            // the episode list is on its way
	loadID   uint64          // rejects a stale result even after A -> B -> A
	shown    *gfx.Canvas     // the page as drawn this frame (mid-fade: a step)

	page, pagePrev *gfx.Canvas // header composed once per season and picture state
	pageKey        string
	entry          *gfx.Canvas // prepared episode layout for the state transition
	entryKey       string
	fade           Fade
	logo           logoLayer
	actX           Anim // horizontal scroll of the action row
	actW           []int
	epAt           time.Time // when the season (its stills) last changed
	text           epText    // the focused episode's lines, laid out once
	pageGen        int       // counts compositions of the page, which may reuse its canvas
	plainGen       int       // the composition plain was found for
	plain          bool      // the page is bare background under the episode's text

	// The page with the logo at rest and the details drawn over it, kept
	// while only the filmstrip moves: a frame is then this layer around
	// the stills and the strip over it, with no text drawn. The episode's
	// text and the action row are drawn again only when they change.
	kept     *gfx.Canvas
	keptPage keptPage
	keptEp   epKey
	keptRow  keptRow
	keptActs []string
}

// keptPage is what the kept layer holds under its details.
type keptPage struct {
	page   *gfx.Canvas
	gen    int
	logo   *gfx.Image
	lx, ly int
}

// keptRow is where the kept layer's action row stands (with keptActs).
type keptRow struct {
	act, off int
	acts     bool
}

// epText is an episode's facts, fitted title and wrapped synopsis, laid
// out once rather than on every frame of a glide or a fade.
type epText struct {
	epKey
	facts  []string
	fitted string
	lines  []string
}

// epKey is what an episode's text is laid out from.
type epKey struct {
	it                        *plex.Item
	index, dur, offset, views int
	title, summary            string
}

const (
	SeasonArtH   = 136 // the backdrop strip at the top, faded out by the filmstrip
	SeasonLift   = 54  // the shared backdrop's vertical alignment in episode mode
	SeasonFade   = 80
	SeasonLogoW  = 260
	SeasonLogoH  = 56
	StillW       = 192 // three 16:9 stills across the safe area (3*192 + 2*16 = 608)
	StillH       = 96
	StillGap     = 16
	StillPitch   = StillW + StillGap
	StillsAcross = 3
	FilmY        = SafeY + 98
	EpTitleY     = FilmY + StillH + 20
	ActY         = SafeBottom - 34
	// TrackRest is how long the cursor must rest on an episode, without a
	// release, before its tracks are asked for. A release asks at once; this
	// is longer than the pad's repeat delay, so a held key asks for none.
	TrackRest = 450 * time.Millisecond
)

// The show's actions in an episode's row, before Remove from Continue
// Watching.
const (
	GoToShow    = "Go to show"
	ShuffleShow = "Shuffle show"
)

// NewSeason opens a season of a show at one of its episodes (by rating
// key; "" for the first unwatched or the first).
func NewSeason(app *App, show *plex.Item, seasons []*plex.Item, si int, at string) *Season {
	s := &Season{app: app, show: show, seasons: seasons, si: si}
	s.load(at)
	s.cw.refetch(app)
	return s
}

func (s *Season) season() *plex.Item { return s.seasons[s.si] }

// load fetches the season's episodes in the background; the page shows
// at once and fills in when they land. Opened at a given episode (from
// Continue Watching) the cursor starts on its Resume button.
func (s *Season) load(at string) {
	s.periodic.reset()
	sea := s.season()
	s.eps = nil
	s.thumbs = nil
	s.fetched = nil // a listing fetched again brings new items without tracks
	s.moved = time.Time{}
	s.err = nil
	s.loading = true
	s.loadID++
	id := s.loadID
	s.epAt = time.Now()
	s.cur = 0
	s.colX.Set(0)
	s.actX.Set(0)
	s.acts = false
	s.pick = false
	s.act = 0
	s.rebuild()
	data := s.app.seasonEpisodes(sea, true)
	apply := func() {
		eps, err := data.eps, data.err
		if s.loadID != id {
			return // stepped on to another season meanwhile
		}
		s.loading = false
		s.err = err
		s.eps = eps
		for i, e := range eps {
			if (at != "" && e.RatingKey == at) || (at == "" && e.ViewCount == 0) {
				s.cur = i
				break
			}
		}
		s.colX.Set(float64(s.scrollTarget()))
		s.epAt = time.Now()
		s.acts = at != ""
		s.rebuild()
		s.preloadThumbs()
	}
	if data.loading {
		data.wait = append(data.wait, apply)
	} else {
		apply()
	}
}

func (s *Season) focused() *plex.Item {
	if s.cur < len(s.eps) {
		return s.eps[s.cur]
	}
	return nil
}

func (s *Season) episodeThumb(it *plex.Item, prefetch bool) (*gfx.Image, time.Duration, bool) {
	thumb := it.Still
	if thumb == "" {
		thumb = it.Thumb
	}
	if e, ok := s.thumbs[thumb]; ok {
		if e == nil {
			return nil, 0, true
		}
		return e.img, time.Since(e.at), true
	}
	img, age, failed := s.app.Art.get(artReq{thumb: thumb, w: StillW, h: StillH, prefetch: prefetch})
	if img != nil || failed {
		if s.thumbs == nil {
			s.thumbs = make(map[string]*artEntry)
		}
		if img != nil {
			s.thumbs[thumb] = &artEntry{img: img, at: time.Now().Add(-age)}
		} else {
			s.thumbs[thumb] = nil
		}
	}
	return img, age, img != nil || failed
}

// Warm the entire season in small batches so visible requests keep priority
// and even seasons larger than the shared artwork cache remain ready to scroll.
// Each completion wakes the UI and advances the batch without requiring input.
func (s *Season) preloadThumbs() {
	pending := 0
	for n := 0; n < len(s.eps); n++ {
		it := s.eps[(s.cur+n)%len(s.eps)]
		if _, _, done := s.episodeThumb(it, true); !done {
			pending++
			if pending == 8 {
				break
			}
		}
	}
}

func (s *Season) rebuild() {
	s.entryKey = ""
	s.actions = s.actions[:0]
	it := s.focused()
	if it == nil {
		return
	}
	s.wantTracks(time.Now())
	if it.ViewOffset > 0 {
		s.actions = append(s.actions, "Resume "+clock(it.ViewOffset), "From start")
	} else {
		s.actions = append(s.actions, "Play")
	}
	if it.ViewCount > 0 {
		s.actions = append(s.actions, "Mark unwatched")
	} else {
		s.actions = append(s.actions, "Mark watched")
	}
	if len(it.Audio) > 1 {
		s.actions = append(s.actions, streamLabel("Audio", it.Audio))
	}
	if len(it.Subs) > 0 {
		s.actions = append(s.actions, streamLabel("Subtitles", it.Subs))
	}
	if s.view != nil && s.view.direct {
		// opened without the season picker (one season, Continue Watching,
		// search): Back leaves the show, so the picker gets an action
		s.actions = append(s.actions, GoToShow)
	}
	s.actions = append(s.actions, ShuffleShow)
	if s.cw.has(it.RatingKey) {
		s.actions = append(s.actions, RemoveContinue)
	}
	if s.act >= len(s.actions) {
		s.act = 0
	}
	f := s.app.F.Body
	s.actW = s.actW[:0]
	for _, a := range s.actions {
		s.actW = append(s.actW, f.Width(a))
	}
}

// wantTracks asks for the focused episode's tracks once the cursor rests
// on it (or is on its actions). The season listing carries no streams: the
// episode's record is fetched once, in the background, and the actions are
// rebuilt when it lands. Each record is a full decode of its streams, so
// holding Right along the filmstrip must not ask for every episode passed.
func (s *Season) wantTracks(now time.Time) {
	it := s.focused()
	if it == nil || len(it.Audio) > 0 || len(it.Subs) > 0 || s.fetched[it.RatingKey] {
		return
	}
	if !s.acts && !s.moved.IsZero() && now.Sub(s.moved) < TrackRest {
		return // still moving: the release, or the next poll, asks
	}
	if s.fetched == nil {
		s.fetched = map[string]bool{}
	}
	s.fetched[it.RatingKey] = true
	go func(it *plex.Item) {
		fresh, err := s.app.Plex.Item(it.RatingKey)
		if err != nil {
			return
		}
		s.app.Later(func() { s.streamsArrived(it, fresh) })
	}(it)
}

// streamsArrived fills in an episode's tracks from its full record. Audio and
// Subtitles go in before Remove from Continue Watching, so the cursor keeps
// its action rather than its place in the row.
func (s *Season) streamsArrived(it, fresh *plex.Item) {
	it.PartID, it.Audio, it.Subs = fresh.PartID, fresh.Audio, fresh.Subs
	s.app.applyStreams(it)
	if s.focused() == it {
		kind := actionKind(s.actions, s.act)
		s.rebuild()
		s.act = restoreAction(s.actions, kind)
		s.keepActVisible(time.Now())
	}
}

// actLeft is the x of action i in the unscrolled row.
func (s *Season) actLeft(i int) int {
	x := 0
	for k := 0; k < i && k < len(s.actW); k++ {
		x += s.actW[k] + 32
	}
	return x
}

// actRowW is the unscrolled row's width to the end of its last label (no
// gap after it), so the row scrolled to its end shows no chevron.
func (s *Season) actRowW() int {
	n := len(s.actW)
	if n == 0 {
		return 0
	}
	return s.actLeft(n-1) + s.actW[n-1]
}

// keepActVisible scrolls the action row so the cursor's action shows.
func (s *Season) keepActVisible(now time.Time) {
	if s.act >= len(s.actW) {
		return
	}
	off := round(s.actX.Target())
	l, r := s.actLeft(s.act), s.actLeft(s.act)+s.actW[s.act]
	if l-off < 0 {
		off = l
	} else if r-off > SafeW-24 {
		off = r - (SafeW - 24)
	}
	// The 24 px above leave room for the chevron while more lies to the
	// right. At the end there is none: a row that fits never scrolls, and
	// one that got shorter (an action gone) is not left past its end.
	off = min(off, max(0, s.actRowW()-SafeW))
	s.actX.Go(float64(off), now)
}

func (s *Season) scrollTarget() int {
	first := round(s.colX.Target()) / StillPitch
	if s.cur < first {
		first = s.cur
	} else if s.cur >= first+StillsAcross {
		first = s.cur - StillsAcross + 1
	}
	return first * StillPitch
}

// Key handles one input event.
func (s *Season) Key(ev input.Event, now time.Time) {
	if ev.Release {
		s.colX.Settle(now)
		s.moved = time.Time{} // the cursor rests: the episode's tracks are wanted
		s.wantTracks(now)
		return
	}
	// A fresh navigation command can interrupt the entry animation. Its
	// prepared details describe the original selection, not the new one.
	if s.pageFade().Transitioning(now) {
		s.pageFade().Done()
		s.logoLayer().start = time.Time{}
	}
	switch ev.Key {
	case input.JumpBack, input.JumpFwd:
		if ev.Repeat {
			return
		}
		d := 1
		if ev.Key == input.JumpBack {
			d = -1
		}
		if s.si+d >= 0 && s.si+d < len(s.seasons) {
			s.si += d
			s.load("")
		}
		return
	}
	if len(s.eps) == 0 {
		return
	}
	if s.pick {
		switch ev.Key {
		case input.Left:
			if s.si > 0 {
				s.si--
				s.load("")
				s.pick = true
			}
		case input.Right:
			if s.si+1 < len(s.seasons) {
				s.si++
				s.load("")
				s.pick = true
			}
		case input.Down, input.Enter:
			s.pick = false
		case input.Up:
			s.toShow()
		}
		return
	}
	if s.acts {
		switch ev.Key {
		case input.Left:
			if s.act > 0 {
				s.act--
			}
		case input.Right:
			if s.act < len(s.actions)-1 {
				s.act++
			}
		case input.Up:
			// back to the filmstrip, where OK plays the first action: the
			// row returns to its start so that action shows
			s.acts = false
			s.act = 0
		case input.Enter:
			s.do(s.actions[s.act])
		}
		s.keepActVisible(now)
		return
	}
	switch ev.Key {
	case input.Left:
		if s.cur > 0 {
			s.cur--
			s.moved = now
		}
	case input.Right:
		if s.cur < len(s.eps)-1 {
			s.cur++
			s.moved = now
		}
	case input.Down:
		s.acts = true
		s.act = 0
	case input.Up:
		if len(s.seasons) > 1 {
			s.pick = true
		} else {
			s.toShow()
		}
	case input.Enter:
		s.do(s.actions[0])
	}
	s.rebuild()
	s.keepActVisible(now) // the new episode's row, or the action Down selected
	s.colX.Move(float64(s.scrollTarget()), now, ev.Repeat)
}

// toShow changes the layout of the owning show without changing the screen stack.
func (s *Season) toShow() {
	if s.view != nil {
		s.view.overview(time.Now())
	}
}

func (s *Season) do(a string) {
	it := s.focused()
	if a == RemoveContinue {
		if it != nil {
			s.app.removeContinue(it, &s.cw, func() {
				s.rebuild() // the action goes and the cursor returns to the first
				s.keepActVisible(time.Now())
			})
		}
		return
	}
	if a == GoToShow {
		// the same as Up to the picker; coming back, the cursor is on the
		// episode, not on an action that has gone
		s.acts, s.act = false, 0
		s.actX.Set(0)
		s.toShow()
		return
	}
	s.periodic.reset()
	if s.view != nil {
		s.view.periodic.reset()
	}
	s.app.seasonData = nil // playback or marking can change watched state
	// a playback brings the page up to date when it is over, which may be
	// after the beta code entry
	played := func(last *plex.Item, finished bool) { s.refreshAfter(it, last, finished) }
	switch {
	case strings.HasPrefix(a, "Audio"):
		s.app.chooseStream(it, "Audio", s.rebuild)
		return
	case strings.HasPrefix(a, "Subtitles"):
		s.app.chooseStream(it, "Subtitles", s.rebuild)
		return
	case strings.HasPrefix(a, "Resume"):
		s.app.PlayQueue(it, it.ViewOffset, s.eps, s.cur, played)
		return
	case a == "Play" || a == "From start":
		s.app.PlayQueue(it, 0, s.eps, s.cur, played)
		return
	case a == ShuffleShow:
		// it plays once the episodes are listed; the highlight stays where
		// the shuffle was started, wherever it ended
		done := func() { s.refreshAfter(it, nil, false) }
		if s.view != nil {
			s.view.shuffle(done)
		} else {
			s.app.Shuffle(s.show, done)
		}
		return
	case a == "Mark watched" || a == "Mark unwatched":
		s.app.markItem(it, a == "Mark watched", func() {
			s.refreshAfter(it, nil, false)
			s.rebuild()
			for i, b := range s.actions {
				if strings.HasPrefix(b, "Mark") {
					s.act = i
				}
			}
			s.keepActVisible(time.Now())
		})
		return
	}
	s.refreshAfter(it, nil, false)
}

// refreshAfter brings the page up to date after a playback or a mark of
// episode it: the episode and the season from the server, the highlight
// moved on after a playback that left the queue at last (returned), the
// actions, and Continue Watching.
func (s *Season) refreshAfter(it, last *plex.Item, finished bool) {
	if last != nil {
		s.returned(last.RatingKey, finished)
	}
	app, client := s.app, s.app.Plex
	season := s.season()
	seasonID := season.RatingKey
	reportsDone := s.app.playReports
	go func() {
		if reportsDone != nil {
			<-reportsDone // don't let a stale item read overwrite the final stop position.
		}
		freshItem, itemErr := client.Item(it.RatingKey)
		freshSeason, seasonErr := client.Item(seasonID)
		app.Later(func() {
			if app.Plex != client {
				return
			}
			if itemErr == nil {
				app.takeFresh(it, freshItem)
			}
			if seasonErr == nil {
				*season = *freshSeason
				s.pageKey = "" // the facts changed
			}
			s.rebuild()
			s.cw.refetch(app) // a play or a mark can move episodes in or out
		})
	}()
}

// afterPlay is the episode to highlight once a playback returns: the one
// after the last episode played when that one finished (Playing.finished),
// or that episode itself when it was stopped early or ends the season.
// Episodes are matched by rating key, so a reloaded list works the same;
// -1 when the episode is not in the list.
func afterPlay(eps []*plex.Item, key string, finished bool) int {
	for i, e := range eps {
		if e.RatingKey != key {
			continue
		}
		if finished && i+1 < len(eps) {
			return i + 1
		}
		return i
	}
	return -1
}

// returned moves the highlight after a playback (see afterPlay) and
// scrolls the filmstrip so it is in view. Nothing plays; a new episode
// starts on its first action.
func (s *Season) returned(key string, finished bool) {
	i := afterPlay(s.eps, key, finished)
	if i < 0 || i == s.cur {
		return
	}
	s.cur = i
	s.act = 0
	s.actX.Set(0)
	s.colX.Set(float64(s.scrollTarget()))
}

// Draw paints the page.
func (s *Season) Draw(c *gfx.Canvas, now time.Time) bool {
	s.matchCanvas(c)
	s.holes = s.holes[:0]
	ox := round(s.colX.At(now))
	for j := range s.eps {
		x := SafeX + j*StillPitch - ox
		if x+StillW <= 0 || x >= c.W {
			continue
		}
		s.holes = append(s.holes, gfx.Rect{X: max(x, 0), Y: FilmY, W: min(x+StillW, c.W) - max(x, 0), H: StillH})
	}
	show, fading := s.preparePage(c, now)
	if !fading && s.keep(c, now) {
		c.BlitExcept(s.kept, s.holes)
		s.shown = s.page
		s.logoLayer().from = nil // at rest, as its draw leaves it
		anim := s.drawStrip(c, now, ox)
		s.preloadThumbs()
		return anim
	}
	anim := s.paintPage(c, show, fading, now)
	anim = s.drawStrip(c, now, ox) || anim
	s.preloadThumbs()
	if s.shown == nil {
		s.shown = s.page
	}
	if s.pageFade().Transitioning(now) {
		return anim // details already travel with the prepared slide target
	}
	return s.drawDetails(c, s.shown, now) || anim
}

func (s *Season) matchCanvas(c *gfx.Canvas) {
	if s.page == nil && s.pagePrev == nil && s.entry == nil && s.shown == nil {
		return
	}
	if canvasSizeIs(s.page, c.W, c.H) &&
		(s.pagePrev == nil || canvasSizeIs(s.pagePrev, c.W, c.H)) &&
		(s.entry == nil || canvasSizeIs(s.entry, c.W, c.H)) {
		return
	}
	s.pageFade().Done()
	s.page, s.pagePrev, s.entry, s.shown = nil, nil, nil, nil
	s.pageKey, s.entryKey = "", ""
}

// keep brings the kept layer up to date and reports whether this frame
// can be drawn from it: nothing on the page moves but the filmstrip. The
// episode's text and the action row are drawn again, over their rows of
// the page, only when they change; the whole layer only when the page or
// the logo did.
func (s *Season) keep(c *gfx.Canvas, now time.Time) bool {
	l := s.logoLayer()
	it := s.focused()
	if s.page == nil || it == nil || s.err != nil || s.pageFade().Transitioning(now) || l.t(now) < 1 ||
		!s.app.Starting.IsZero() || s.actX.Running(now) {
		return false // something moves, or there are no details to keep
	}
	pk := keptPage{page: s.page, gen: s.pageGen, logo: l.img, lx: l.x, ly: l.y}
	tx := s.epText(it)
	rk := keptRow{act: s.act, acts: s.acts, off: round(s.actX.At(now))}
	if !canvasSizeIs(s.kept, c.W, c.H) {
		s.kept = gfx.NewCanvas(c.W, c.H)
		s.keptPage = keptPage{}
	}
	whole := s.keptPage != pk
	ep := whole || s.keptEp != tx.epKey
	row := whole || s.keptRow != rk || !slices.Equal(s.keptActs, s.actions)
	if !ep && !row {
		return true
	}
	ey0, ey1 := s.epRows()
	ry0, ry1 := s.actRows()
	if ey1 > ry0 {
		ep, row = true, true // they share rows: both are drawn again
	}
	if l.img != nil && l.y < ry1 && l.y+l.img.H > ey0 {
		whole, ep, row = true, true, true // the logo reaches down into them
	}
	restore := func(y0, y1 int) {
		y1 = min(y1, c.H)
		copy(s.kept.Pix[y0*c.W*4:y1*c.W*4], s.page.Pix[y0*c.W*4:y1*c.W*4])
	}
	if whole {
		s.kept.Copy(s.page)
		if l.img != nil {
			l.imageOver(s.kept, s.page, l.x, l.y, l.img, 256, nil, 0, 0, 0)
		}
		s.keptPage = pk
	} else {
		if ep {
			restore(ey0, ey1)
		}
		if row {
			restore(ry0, ry1)
		}
	}
	if ep {
		s.drawEpisode(s.kept, s.page, tx)
		s.keptEp = tx.epKey
		s.warmNear()
	}
	if row {
		s.drawActions(s.kept, s.page, now)
		s.keptRow = rk
		s.keptActs = append(s.keptActs[:0], s.actions...)
	}
	return true
}

// drawDetails is composed once into the slide target on entry. Repainting
// these glyphs on every moving frame competes with the background blender.
func (s *Season) drawDetails(c, page *gfx.Canvas, now time.Time) bool {
	f := s.app.F
	if s.err != nil {
		s.app.text(c, SafeX, EpTitleY, f.Body, gfx.White, "Cannot load this season.")
		return false
	}
	it := s.focused()
	if it == nil {
		if s.loading {
			sweep(c, SafeX, EpTitleY+f.Body.Height()+3, 120, BarW, now.Sub(s.epAt))
			return true
		}
		s.app.textOver(c, page, SafeX, EpTitleY, f.Body, gfx.White, "No episodes.")
		return false
	}
	s.drawEpisode(c, page, s.epText(it))
	return s.drawActions(c, page, now)
}

// drawEpisode draws the highlighted episode: its facts, then its title and
// synopsis; blended over the page, which may be mid-transition.
func (s *Season) drawEpisode(c, page *gfx.Canvas, tx *epText) {
	f := s.app.F
	y := EpTitleY
	x := SafeX
	for i, t := range tx.facts {
		if i > 0 {
			c.Fill(x+8, (y+f.SmallBold.Height()/2)&^1-1, 4, 4, gfx.White)
			x += 20
		}
		s.textOver(c, page, x, y, f.SmallBold, t)
		x += f.SmallBold.Width(t)
	}
	y += f.SmallBold.Height() + 2
	s.textOver(c, page, SafeX, y, f.Body, tx.fitted)
	y += f.Body.Height() + 4
	for _, line := range tx.lines {
		s.textOver(c, page, SafeX, y, f.SmallBold, line)
		y += f.SmallBold.Height() + 2
	}
}

// epRows are the rows the episode's text takes (two lines of synopsis at
// most), and actRows those of the action row with its chevrons.
func (s *Season) epRows() (int, int) {
	f := s.app.F
	return EpTitleY, EpTitleY + f.SmallBold.Height() + 2 + f.Body.Height() + 4 + 2*(f.SmallBold.Height()+2)
}
func (s *Season) actRows() (int, int) { return ActY - 6, ActY + 10 + s.app.F.Body.Height() }

// textOver draws one of the episode's lines in white over the page. Where
// the page is bare background the text cache's line is the same pixels,
// rendered off this thread, and it is copied instead when it is there.
func (s *Season) textOver(c, page *gfx.Canvas, x, y int, f *gfx.Font, str string) {
	if tc := s.app.T; tc != nil && page == s.page && s.plainText() {
		y0, y1 := s.epRows()
		if x >= 1 && x+f.Width(str)+1 <= page.W && y >= y0 && y+f.Height() <= y1 {
			if img := tc.Get(f, str, gfx.White, gfx.Bg); img != nil {
				c.Blit(x-1, y, img)
				return
			}
		}
	}
	s.app.textOver(c, page, x, y, f, gfx.White, str)
}

// plainText reports whether the page is bare background (as a fill leaves
// it) across the episode's text rows; checked once per composition.
func (s *Season) plainText() bool {
	if s.plainGen == s.pageGen {
		return s.plain
	}
	s.plainGen, s.plain = s.pageGen, true
	y0, y1 := s.epRows()
	if y1 > s.page.H {
		s.plain = false
		return false
	}
	bg := gfx.Bg
	b, g, r := byte(bg), byte(bg>>8), byte(bg>>16)
	px := s.page.Pix[y0*s.page.W*4 : y1*s.page.W*4]
	for i := 0; i < len(px); i += 4 {
		if px[i] != b || px[i+1] != g || px[i+2] != r || px[i+3] != 0 {
			s.plain = false
			break
		}
	}
	return s.plain
}

// warmNear has the text cache render the lines of the episodes either side
// of the cursor, so a step along the filmstrip finds them ready.
func (s *Season) warmNear() {
	tc := s.app.T
	if tc == nil || !s.plainText() {
		return
	}
	f := s.app.F
	for j := s.cur - 1; j <= s.cur+1; j += 2 {
		if j < 0 || j >= len(s.eps) {
			continue
		}
		tx := s.layText(s.eps[j])
		for _, t := range tx.facts {
			tc.Warm(f.SmallBold, t, gfx.White, gfx.Bg)
		}
		tc.Warm(f.Body, tx.fitted, gfx.White, gfx.Bg)
		for _, line := range tx.lines {
			tc.Warm(f.SmallBold, line, gfx.White, gfx.Bg)
		}
	}
}

// drawActions draws the actions in a row along the bottom, composed into a
// strip over the page: it scrolls when longer than the safe width, words
// crossing the edge fade out, and chevrons mark what lies beyond.
func (s *Season) drawActions(c, page *gfx.Canvas, now time.Time) bool {
	f := s.app.F
	starting := !s.app.Starting.IsZero()
	off := round(s.actX.At(now))
	startingAct := s.act
	if starting && !s.acts {
		startingAct, off = 0, 0 // filmstrip playback uses the first Play/Resume action
	}
	anim := s.actX.Running(now)
	rowW := s.actRowW()
	sy, sh := ActY-6, f.Body.Height()+16
	sx0, sx1 := SafeX-8, SafeX+SafeW+8
	st := s.app.scratch(sx1-sx0, sh)
	for yy := 0; yy < sh; yy++ {
		so := ((sy+yy)*page.W + sx0) * 4
		copy(st.Pix[yy*st.W*4:(yy+1)*st.W*4], page.Pix[so:so+st.W*4])
	}
	for i, a := range s.actions {
		x := SafeX + s.actLeft(i) - off - sx0
		w := s.actW[i]
		if x+w <= 0 || x >= st.W {
			continue
		}
		col := gfx.GreyLo
		if strings.HasPrefix(a, "Play") || strings.HasPrefix(a, "Resume") {
			col = gfx.Amber
		}
		if (s.acts && i == s.act) || (starting && i == startingAct) {
			if col != gfx.Amber {
				col = gfx.White
			}
			if starting && i == startingAct {
				sweep(st, x, 6+f.Body.Height()+4, w, BarW, now.Sub(s.app.Starting))
				anim = true
			} else {
				st.Fill(x, 6+f.Body.Height()+4, w, BarW, gfx.GreyHi)
			}
		}
		st.Text(x, 6, f.Body, col, a)
	}
	// the edges fade to the page over 36 px when there is more that way
	edgeFade := func(x0, dir int) {
		for k := 0; k < 36; k++ {
			x := x0 + k*dir
			if x < 0 || x >= st.W {
				continue
			}
			a := 255 - k*255/36
			for yy := 0; yy < sh; yy++ {
				so := ((sy+yy)*page.W + sx0 + x) * 4
				d := st.Pix[(yy*st.W+x)*4 : (yy*st.W+x)*4+3]
				p := page.Pix[so : so+3]
				d[0] = byte(int(p[0]) + (int(d[0])-int(p[0]))*(255-a)/255)
				d[1] = byte(int(p[1]) + (int(d[1])-int(p[1]))*(255-a)/255)
				d[2] = byte(int(p[2]) + (int(d[2])-int(p[2]))*(255-a)/255)
			}
		}
	}
	if off > 0 {
		edgeFade(0, 1)
	}
	if rowW-off > SafeW {
		edgeFade(st.W-1, -1)
	}
	c.Blit(sx0, sy, &gfx.Image{W: st.W, H: st.H, Pix: st.Pix})
	if off > 0 {
		chevronLeft(c, SafeX-20, ActY+f.Body.Height()/2-6, gfx.GreyLo)
	}
	if rowW-off > SafeW {
		chevronRight(c, SafeX+SafeW+16, ActY+f.Body.Height()/2-6, gfx.GreyLo)
	}

	return anim
}

// epText lays out an episode's text, again only when what it shows changed.
func (s *Season) epText(it *plex.Item) *epText {
	t := &s.text
	if t.epKey != epKeyOf(it) {
		*t = s.layText(it)
	}
	return t
}

// epKeyOf is what an episode's text shows now.
func epKeyOf(it *plex.Item) epKey {
	return epKey{it: it, index: it.Index, dur: it.Duration, offset: it.ViewOffset, views: it.ViewCount,
		title: it.Title, summary: it.Summary}
}

// layText lays out an episode's text.
func (s *Season) layText(it *plex.Item) epText {
	f := s.app.F
	facts := []string{"Episode " + itoa(it.Index)}
	if it.Duration > 0 {
		facts = append(facts, hm(it.Duration))
	}
	if it.ViewOffset > 0 {
		facts = append(facts, clock(it.ViewOffset)+" of "+clock(it.Duration))
	} else if it.ViewCount > 0 {
		facts = append(facts, "Watched")
	}
	return epText{epKey: epKeyOf(it), facts: facts, fitted: f.Body.Fit(it.Title, SafeW), lines: wrap(f.SmallBold, it.Summary, SafeW, 2)}
}

// preparePage brings the page up to date and returns the one to show now
// (mid-fade: a step) and whether it is fading.
func (s *Season) preparePage(c *gfx.Canvas, now time.Time) (*gfx.Canvas, bool) {
	sea := s.season()
	art := heroArt(s.show)
	key := sea.RatingKey + "|" + art
	if s.pick {
		key += "|pick"
	}
	img, _ := s.app.Art.GetBackdrop(art, c.W, c.H, HeroBright, HeroFade)
	if img != nil {
		key += "|art"
	}
	var logo *gfx.Image
	logoPending := false
	if s.show.Logo != "" {
		var failed bool
		if logo, failed = s.app.Art.GetLogo(s.show.Logo, SeasonLogoW, SeasonLogoH); logo != nil {
			key += "|logo"
		} else {
			logoPending = !failed
		}
	}
	sliding := s.pageFade().Transitioning(now)
	if key != s.pageKey && !sliding {
		s.pageFade().Done()
		s.page, s.pagePrev = s.pagePrev, s.page
		if s.page == nil {
			s.page = gfx.NewCanvas(c.W, c.H)
		}
		s.compose(s.page, img, logo, logoPending)
		if s.pagePrev != nil && strings.HasPrefix(s.pageKey, sea.RatingKey+"|") {
			s.pageFade().Start(s.pagePrev, s.page, now) // a picture landed: fade it in
		}
		s.pageKey = key
	}
	// the logo rides above the page; the show page hands it to us
	lx, ly := SafeX, SafeY+(SeasonLogoH-LogoHOr(logo, SeasonLogoH))/2
	if hd := s.takeTransition(); hd != nil {
		target := s.entry
		if target == nil || s.entryKey != s.pageKey {
			target = s.page
			if s.focused() != nil {
				target = snapshot(s.page)
				s.drawDetails(target, s.page, now)
			}
		}
		s.pageFade().Layout(hd.Page, target, img, hd.ArtY, SeasonLift, now)
		s.logoLayer().enterFrom(hd, logo, lx, ly, now)
	} else if !sliding {
		s.logoLayer().set(logo, lx, ly, now, animDur)
	}
	show, fading := s.pageFade().Frame(now)
	if !fading {
		show = s.page
	}
	return show, fading
}

// paintPage copies the page around the stills and draws the logo over it.
func (s *Season) paintPage(c, show *gfx.Canvas, fading bool, now time.Time) bool {
	c.BlitExcept(show, s.holes)
	s.shown = show
	moving := s.logoLayer().draw(c, show, now)
	return fading || moving
}

// LogoHOr is a logo's height, or a default when there is none yet.
func LogoHOr(logo *gfx.Image, def int) int {
	if logo == nil {
		return def
	}
	return logo.H
}

func (s *Season) compose(c *gfx.Canvas, img, logo *gfx.Image, logoPending bool) {
	f := s.app.F
	s.pageGen++
	c.Fill(0, 0, c.W, c.H, gfx.Bg)
	if img != nil {
		// the show page's backdrop, kept only as a header: below the logo
		// it eases into the background before the filmstrip
		c.BlitClip(0, -SeasonLift, img, 0, 0, c.W, SeasonArtH)
		for y := SeasonArtH - SeasonFade; y < SeasonArtH; y++ {
			t := y - (SeasonArtH - SeasonFade) + 1
			c.FillAlpha(0, y, c.W, 1, gfx.Bg, min(255, t*t*255/(SeasonFade*SeasonFade)))
		}
	}
	sea := s.season()
	y := SafeY
	if logo == nil && !logoPending {
		c.Text(SafeX, y+(SeasonLogoH-f.Big.Height())/2, f.Big, gfx.White, f.Big.Fit(s.show.Title, SafeW))
	}
	// up, top centre: the show's page is above this one
	chevronA(c, c.W/2, SafeY-2, true, true)
	y += SeasonLogoH + 8
	// the season's name, with chevrons either side when there are others
	// to step to (Up puts the cursor on it; Left/Right step)
	x := SafeX
	if len(s.seasons) > 1 {
		col := ChevronOff
		if s.si > 0 {
			col = gfx.GreyLo
		}
		chevronLeft(c, x+4, y+f.SmallBold.Height()/2-6, col)
		x += 16
	}
	name := f.SmallBold
	tcol := gfx.White
	if s.pick {
		tcol = gfx.Amber
	}
	x0 := x
	x = c.Text(x, y, name, tcol, sea.Title)
	if s.pick {
		_, top, _, height := name.InkBounds(sea.Title)
		c.Fill(x0, (y+top+height+2)&^1, x-x0, 2, gfx.Amber)
	}
	if len(s.seasons) > 1 {
		col := ChevronOff
		if s.si+1 < len(s.seasons) {
			col = gfx.GreyLo
		}
		chevronRight(c, x+12, y+f.SmallBold.Height()/2-6, col)
		x += 22
	}
	facts := []string{}
	if sea.Leaves > 0 {
		facts = append(facts, plural(sea.Leaves, "episode"))
		if left := sea.Leaves - sea.Viewed; left == 0 {
			facts = append(facts, "Watched")
		} else if left < sea.Leaves {
			facts = append(facts, itoa(left)+" unwatched")
		}
	}
	if len(facts) > 0 {
		c.Fill(x+8, (y+f.SmallBold.Height()/2)&^1-1, 4, 4, gfx.White)
		dots(c, x+20, y, f.SmallBold, gfx.White, facts, SafeX+SafeW-x-20)
	}
}

// chevronLeft draws a small solid triangle pointing left, centred on cx.
func chevronLeft(c *gfx.Canvas, cx, y int, col gfx.Color) {
	for i := 0; i < 6; i++ {
		hh := i + 1
		c.Fill(cx-3+i, y+6-hh, 1, 2*hh, col)
	}
}

// drawStrip paints the filmstrip: stills fade in as they land and when
// the season changes; the highlighted one is framed.
func (s *Season) drawStrip(c *gfx.Canvas, now time.Time, ox int) bool {
	anim := s.colX.Running(now)
	rowT := 0
	if since := now.Sub(s.epAt); since < animDur {
		rowT = 256 - int(since*256/animDur)
		anim = true
	}
	for j, it := range s.eps {
		x := SafeX + j*StillPitch - ox
		if x+StillW <= 0 || x >= c.W {
			continue
		}
		whole := x >= SafeX-FocusPad && x+StillW <= SafeX+SafeW
		img, age, _ := s.episodeThumb(it, false)
		if img != nil {
			t := rowT
			if age < FadeIn {
				t = max(t, 256-int(age*256/FadeIn))
			}
			if t > 0 {
				c.BlendSolidClip(x, FilmY, img, gfx.Bg, t, 0, 0, c.W, c.H)
				anim = true
			} else {
				c.Blit(x, FilmY, img)
			}
		} else {
			c.Fill(x, FilmY, StillW, StillH, gfx.Bar)
			if whole {
				s.app.textCenterOn(c, x+StillW/2, FilmY+StillH/2-s.app.F.SmallBold.Height()/2, s.app.F.SmallBold, gfx.GreyLo, gfx.Bar, "Episode "+itoa(it.Index))
			}
		}
		if !whole {
			continue
		}
		s.app.badge(c, it, x, FilmY, StillW, StillH)
		if j == s.cur {
			fc := gfx.GreyHi
			if s.acts || s.pick {
				fc = ChevronOff // the cursor is elsewhere: the still stays marked, quietly
			}
			c.Frame(x-FocusPad, FilmY-FocusPad, StillW+2*FocusPad, StillH+2*FocusPad, FocusT, fc)
		}
	}
	return anim
}

func (s *Season) pageFade() *Fade {
	if s.view != nil {
		return &s.view.fade
	}
	return &s.fade
}
func (s *Season) logoLayer() *logoLayer {
	if s.view != nil {
		return &s.view.logo
	}
	return &s.logo
}
func (s *Season) takeTransition() *Handoff {
	if s.view == nil {
		return nil
	}
	return s.view.takeTransition()
}

// prime prepares the hidden episode layout while the season picker is at rest.
// It never starts a fade or changes the shared logo.
func (s *Season) prime(now time.Time) {
	if s.loading || s.err != nil || s.focused() == nil {
		return
	}
	w, h := layoutCanvasSize(s.app)
	if !canvasSizeIs(s.page, w, h) || (s.pagePrev != nil && !canvasSizeIs(s.pagePrev, w, h)) ||
		(s.entry != nil && !canvasSizeIs(s.entry, w, h)) {
		s.pageFade().Done()
		s.page, s.pagePrev, s.entry, s.shown = nil, nil, nil, nil
		s.pageKey, s.entryKey = "", ""
	}
	art := heroArt(s.show)
	img, _ := s.app.Art.GetBackdrop(art, w, h, HeroBright, HeroFade)
	logo, failed := s.app.Art.GetLogo(s.show.Logo, SeasonLogoW, SeasonLogoH)
	key := s.season().RatingKey + "|" + art
	if s.pick {
		key += "|pick"
	}
	if img != nil {
		key += "|art"
	}
	if logo != nil {
		key += "|logo"
	}
	if s.pageKey != key {
		if s.page == nil {
			s.page = gfx.NewCanvas(w, h)
		}
		s.compose(s.page, img, logo, s.show.Logo != "" && logo == nil && !failed)
		s.pageKey = key
		s.entryKey = ""
	}
	if s.entryKey != key {
		if s.entry == nil {
			s.entry = gfx.NewCanvas(w, h)
		}
		s.entry.Copy(s.page)
		s.drawDetails(s.entry, s.page, now)
		s.entryKey = key
	}
}
