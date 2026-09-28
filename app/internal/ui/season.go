package ui

import (
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
	// the season listing carries no streams: fetch the episode's record
	// once, in the background, and rebuild when it lands
	if len(it.Audio) == 0 && len(it.Subs) == 0 && !s.fetched[it.RatingKey] {
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

// streamsArrived fills in an episode's tracks from its full record. Audio and
// Subtitles go in before Remove from Continue Watching, so the cursor keeps
// its action rather than its place in the row.
func (s *Season) streamsArrived(it, fresh *plex.Item) {
	it.PartID, it.Audio, it.Subs = fresh.PartID, fresh.Audio, fresh.Subs
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
		}
	case input.Right:
		if s.cur < len(s.eps)-1 {
			s.cur++
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
		if it != nil && s.app.removeContinue(it, &s.cw) {
			s.rebuild() // the action goes and the cursor returns to the first
			s.keepActVisible(time.Now())
		}
		return
	}
	s.periodic.reset()
	if s.view != nil {
		s.view.periodic.reset()
	}
	s.app.seasonData = nil // playback or marking can change watched state
	switch {
	case strings.HasPrefix(a, "Audio"):
		s.app.chooseStream(it, "Audio", s.rebuild)
		return
	case strings.HasPrefix(a, "Subtitles"):
		s.app.chooseStream(it, "Subtitles", s.rebuild)
		return
	case strings.HasPrefix(a, "Resume"):
		s.app.PlayQueue(it, it.ViewOffset, s.eps, s.cur)
	case a == "Play" || a == "From start":
		s.app.PlayQueue(it, 0, s.eps, s.cur)
	case a == "Mark watched":
		s.app.Plex.Scrobble(it.RatingKey, true)
	case a == "Mark unwatched":
		s.app.Plex.Scrobble(it.RatingKey, false)
	}
	if fresh, err := s.app.Plex.Item(it.RatingKey); err == nil {
		*it = *fresh
	}
	if fresh, err := s.app.Plex.Item(s.season().RatingKey); err == nil {
		*s.season() = *fresh
		s.pageKey = "" // the facts changed
	}
	s.rebuild()
	s.cw.refetch(s.app) // a play or a mark can move episodes in or out
	if strings.HasPrefix(a, "Mark") {
		// stay on the mark, now its counterpart
		for i, b := range s.actions {
			if strings.HasPrefix(b, "Mark") {
				s.act = i
			}
		}
		s.keepActVisible(time.Now())
	}
}

// Draw paints the page.
func (s *Season) Draw(c *gfx.Canvas, now time.Time) bool {
	s.holes = s.holes[:0]
	ox := round(s.colX.At(now))
	for j := range s.eps {
		x := SafeX + j*StillPitch - ox
		if x+StillW <= 0 || x >= c.W {
			continue
		}
		s.holes = append(s.holes, gfx.Rect{X: max(x, 0), Y: FilmY, W: min(x+StillW, c.W) - max(x, 0), H: StillH})
	}
	anim := s.drawPage(c, now)
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

// drawDetails is composed once into the slide target on entry. Repainting
// these glyphs on every moving frame competes with the background blender.
func (s *Season) drawDetails(c, page *gfx.Canvas, now time.Time) bool {
	anim := false
	f := s.app.F
	if s.err != nil {
		s.app.text(c, SafeX, EpTitleY, f.Body, gfx.White, "Cannot load this season.")
		return anim
	}
	it := s.focused()
	if it == nil {
		if s.loading {
			sweep(c, SafeX, EpTitleY+f.Body.Height()+3, 120, BarW, now.Sub(s.epAt))
			return true
		}
		s.app.textOver(c, page, SafeX, EpTitleY, f.Body, gfx.White, "No episodes.")
		return anim
	}
	// the highlighted episode: its facts, then its title; blended over
	// the page, which may be mid-transition
	y := EpTitleY
	facts := []string{"Episode " + itoa(it.Index)}
	if it.Duration > 0 {
		facts = append(facts, hm(it.Duration))
	}
	if it.ViewOffset > 0 {
		facts = append(facts, clock(it.ViewOffset)+" of "+clock(it.Duration))
	} else if it.ViewCount > 0 {
		facts = append(facts, "Watched")
	}
	x := SafeX
	for i, t := range facts {
		if i > 0 {
			c.Fill(x+8, (y+f.SmallBold.Height()/2)&^1-1, 4, 4, gfx.White)
			x += 20
		}
		s.app.textOver(c, page, x, y, f.SmallBold, gfx.White, t)
		x += f.SmallBold.Width(t)
	}
	y += f.SmallBold.Height() + 2
	s.app.textOver(c, page, SafeX, y, f.Body, gfx.White, f.Body.Fit(it.Title, SafeW))
	y += f.Body.Height() + 4
	for _, line := range wrap(f.SmallBold, it.Summary, SafeW, 2) {
		s.app.textOver(c, page, SafeX, y, f.SmallBold, gfx.White, line)
		y += f.SmallBold.Height() + 2
	}
	// actions in a row along the bottom, composed into a strip over the
	// page: it scrolls when longer than the safe width, words crossing the
	// edge fade out, and chevrons mark what lies beyond
	starting := !s.app.Starting.IsZero()
	off := round(s.actX.At(now))
	startingAct := s.act
	if starting && !s.acts {
		startingAct, off = 0, 0 // filmstrip playback uses the first Play/Resume action
	}
	anim = anim || s.actX.Running(now)
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

// dotsLine is dots for the frame: cached text lines on the background.
func (s *Season) dotsLine(c *gfx.Canvas, x, y int, f *gfx.Font, col gfx.Color, tokens []string) {
	for i, t := range tokens {
		if i > 0 {
			c.Fill(x+8, (y+f.Height()/2)&^1-1, 4, 4, col)
			x += 20
		}
		s.app.text(c, x, y, f, col, t)
		x += f.Width(t)
	}
}

// drawPage composes the header (backdrop strip, logo, facts) once per
// season and picture state, cross-fading between states.
func (s *Season) drawPage(c *gfx.Canvas, now time.Time) bool {
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
	art := heroArt(s.show)
	img, _ := s.app.Art.GetBackdrop(art, 720, 480, HeroBright, HeroFade)
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
			s.page = gfx.NewCanvas(720, 480)
		}
		s.compose(s.page, img, logo, s.show.Logo != "" && logo == nil && !failed)
		s.pageKey = key
		s.entryKey = ""
	}
	if s.entryKey != key {
		if s.entry == nil {
			s.entry = gfx.NewCanvas(720, 480)
		}
		s.entry.Copy(s.page)
		s.drawDetails(s.entry, s.page, now)
		s.entryKey = key
	}
}
