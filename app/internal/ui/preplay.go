package ui

import (
	"math"
	"strings"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/plex"
)

// Preplay is the page before a movie plays: dimmed backdrop, logo or
// title, facts, poster, a short synopsis (which opens in full) and a
// short stack of actions.
type Preplay struct {
	periodic viewRefresh
	app      *App
	item     *plex.Item
	actions  []string
	cw       continueList
	cur      int  // -1: the synopsis
	more     bool // the synopsis was cut: it can be opened
	// The page is composed here, then copied out: text and the logo blend
	// over what is beneath, and the frame from Begin is only ever written.
	page *gfx.Canvas
	// What page holds outside the text column (pageStill), the column's
	// corner of that still layer (under, from row column down), and the
	// synopsis wrapped once (lines, for summary).
	pageStill preplayKey
	column    int
	under     []byte
	lines     []string
	summary   string
}

// preplayKey is what the page's still layer shows: the backdrop, the logo
// or title, the facts, and the poster with its badge. While it stays the
// same only the text column (synopsis and actions) is drawn again.
type preplayKey struct {
	w, h                       int
	back, logo, poster         *gfx.Image
	logoPending                bool
	title, facts, kind         string
	offset, dur, views, leaves int
	viewed                     int
}

// preplayStill is the still layer for one frame.
type preplayStill struct {
	key                   preplayKey
	facts                 []string
	backT, logoT, posterT int // how much of each picture still fades in (of 256)
}

func (st *preplayStill) fading() bool { return st.backT > 0 || st.logoT > 0 || st.posterT > 0 }

const (
	PreX        = SafeX
	PreTextX    = SafeX + PosterW + 24
	BgBright    = 90  // of 255: the backdrop is a mood, text must win
	BgFade      = 260 // px at the bottom fading to the background colour
	PreLogoW    = 360
	PreLogoH    = 90
	PreFocusGap = 6 // space between the movie-page selection bar and text
	PreLines    = 2 // synopsis lines: short, so it never has to be read at length
	// PreColX is the left edge of the text column's corner of the page, with
	// room for the focus bar and any glyph that overhangs its origin.
	PreColX = PreTextX - PreFocusGap - BarW - 8
)

// NewPreplay makes the page for a playable item. Hub listings omit the
// summary and genres; openItem fetches missing metadata before constructing it.
func NewPreplay(app *App, it *plex.Item) *Preplay {
	p := &Preplay{app: app, item: it}
	app.applyStreams(it)
	p.rebuild()
	p.cw.refetch(app)
	return p
}

func (p *Preplay) rebuild() {
	it := p.item
	p.actions = p.actions[:0]
	if it.ViewOffset > 0 {
		p.actions = append(p.actions, "Resume from "+clock(it.ViewOffset), "Play from the start")
	} else {
		p.actions = append(p.actions, "Play")
	}
	if it.ViewCount > 0 {
		p.actions = append(p.actions, "Mark unwatched")
	} else {
		p.actions = append(p.actions, "Mark watched")
	}
	if len(it.Audio) > 1 {
		p.actions = append(p.actions, streamLabel("Audio", it.Audio))
	}
	if len(it.Subs) > 0 {
		p.actions = append(p.actions, streamLabel("Subtitles", it.Subs))
	}
	if p.cw.has(it.RatingKey) {
		p.actions = append(p.actions, RemoveContinue)
	}
	if p.cur >= len(p.actions) {
		p.cur = 0
	}
}

// Key handles one input event.
func (p *Preplay) Key(ev input.Event, now time.Time) {
	if ev.Release {
		return
	}
	switch ev.Key {
	case input.Up:
		if p.cur > 0 {
			p.cur--
		} else if p.cur == 0 && p.more {
			p.cur = -1
		}
	case input.Down:
		if p.cur < len(p.actions)-1 {
			p.cur++
		}
	case input.Enter:
		if p.cur < 0 {
			p.app.Push(NewFullText(p.app, p.item.Title, p.item.Summary))
			return
		}
		a := p.actions[p.cur]
		switch {
		case a == RemoveContinue:
			p.app.removeContinue(p.item, &p.cw, p.rebuild)
		case strings.HasPrefix(a, "Audio"):
			p.periodic.reset()
			p.app.chooseStream(p.item, "Audio", p.rebuild)
		case strings.HasPrefix(a, "Subtitles"):
			p.periodic.reset()
			p.app.chooseStream(p.item, "Subtitles", p.rebuild)
		case strings.HasPrefix(a, "Resume"):
			p.play(p.item.ViewOffset)
		case strings.HasPrefix(a, "Play"):
			p.play(0)
		case strings.HasPrefix(a, "Mark"):
			p.app.markItem(p.item, a == "Mark watched", func() {
				p.periodic.reset()
				p.rebuild()
				p.cw.refetch(p.app)
				for i, b := range p.actions {
					if strings.HasPrefix(b, "Mark") {
						p.cur = i
					}
				}
			})
		}
	}
}

func (p *Preplay) play(offset int) {
	p.app.PlayAt(p.item, offset)
	// The item already holds where the playback stopped (notePlayed), and
	// the server's record follows its stopped report (refreshPlayedItem): a
	// fetch now could still have the old resume point.
	p.periodic.reset()
	p.rebuild()
	p.app.afterReports(func() { p.cw.refetch(p.app) })
}

func (p *Preplay) refresh() { p.periodic.soon(); p.rebuild(); p.cw.refetch(p.app) }

// actionPitch is the distance between the page's action lines, the first
// at top. A long stack (resumable, both track choices, in Continue
// Watching) closes up a little so its last line stays inside the safe area.
func actionPitch(f *gfx.Font, top, n int) int {
	pitch := f.Height() + 10
	if n > 1 {
		pitch = min(pitch, (SafeBottom-top-f.Height())/(n-1))
	}
	return pitch
}

// Draw composes the page off-frame and copies it in. A Display Shape change
// while the page is open resizes the output canvas (720 or 960 wide), so the
// page follows it rather than being copied in at its old width.
func (p *Preplay) Draw(out *gfx.Canvas, now time.Time) bool {
	if !canvasSizeIs(p.page, out.W, out.H) {
		p.page = gfx.NewCanvas(out.W, out.H)
		p.pageStill = preplayKey{}
	}
	anim := p.composePage(now)
	copy(out.Pix, p.page.Pix)
	return anim
}

// composePage brings the page up to date. The still layer is drawn again
// only when it changed or a picture in it is fading in; otherwise the text
// column's corner is restored from under and the column drawn over it, so
// a press (or the start sweep) does not refill and reblit the whole frame.
func (p *Preplay) composePage(now time.Time) bool {
	c := p.page
	st := p.still(c.W, c.H)
	if st.fading() {
		y := p.drawStill(c, &st)
		p.pageStill = preplayKey{}
		p.drawColumn(c, y, now)
		return true
	}
	x0, rw := PreColX*4, (c.W-PreColX)*4
	if p.pageStill != st.key {
		p.column = p.drawStill(c, &st)
		p.under = p.under[:0]
		for y := p.column; y < c.H; y++ {
			o := y*c.W*4 + x0
			p.under = append(p.under, c.Pix[o:o+rw]...)
		}
		p.pageStill = st.key
	} else {
		for y := p.column; y < c.H; y++ {
			o, u := y*c.W*4+x0, (y-p.column)*rw
			copy(c.Pix[o:o+rw], p.under[u:u+rw])
		}
	}
	return p.drawColumn(c, p.column, now)
}

// sweep is the start indicator: the selection bar itself, dimmed, with a
// bright amber run travelling along it and back. Drawn in the bar's own
// place, so nothing new appears on the page while a play request is
// brought up. w and h are the bar's size; the long side is the track.
func sweep(c *gfx.Canvas, x, y, w, h int, t time.Duration) {
	const period = 1100 * time.Millisecond
	c.Fill(x, y, w, h, SweepDim)
	ph := float64(t%period) / float64(period)
	// ease in and out on each pass
	if ph > 0.5 {
		ph = 1 - ph
	}
	ph = ph * 2
	ph = ph * ph * (3 - 2*ph)
	long := max(w, h)
	run := max(long*2/5, 6)
	at := int(ph * float64(long-run))
	if w >= h {
		c.Fill(x+at, y, run, h, gfx.Amber)
	} else {
		c.Fill(x, y+at, w, run, gfx.Amber)
	}
}

// SweepDim is the bar's colour behind the run: amber at two fifths.
const SweepDim gfx.Color = 0x5C4005

// disc fills a circle of radius r (in frame rows) centred on cx,cy,
// widened by 9/8 so it is round on the tube.
func disc(c *gfx.Canvas, cx, cy int, r float64, col gfx.Color) {
	for dy := -int(r); dy <= int(r); dy++ {
		w := math.Sqrt(r*r-float64(dy*dy)) * 9 / 8
		hw := int(w + 0.5)
		if hw > 0 {
			c.Fill(cx-hw, cy+dy, 2*hw, 1, col)
		}
	}
}

// fadeT is how much of a picture that landed age ago is still hidden (of 256).
func fadeT(age time.Duration) int {
	if age >= FadeIn {
		return 0
	}
	return 256 - int(age*256/FadeIn)
}

// still looks up what the still layer shows this frame.
func (p *Preplay) still(w, h int) preplayStill {
	it := p.item
	var st preplayStill
	k := &st.key
	k.w, k.h = w, h
	art := it.Art
	if art == "" {
		art = it.Thumb
	}
	var age time.Duration
	if k.back, age = p.app.Art.GetBackdrop(art, w, h, BgBright, BgFade); k.back != nil {
		st.backT = fadeT(age)
	}
	if it.Logo != "" {
		var failed bool
		if k.logo, age, failed = p.app.Art.getLogoAge(it.Logo, PreLogoW, PreLogoH); k.logo != nil {
			st.logoT = fadeT(age)
		}
		k.logoPending = k.logo == nil && !failed
	}
	if k.logo == nil && !k.logoPending {
		k.title = it.Title
	}
	st.facts = heroFacts(it)
	if len(it.Genres) > 0 {
		g := it.Genres
		if len(g) > 3 {
			g = g[:3]
		}
		st.facts = append(st.facts, strings.Join(g, ", "))
	}
	k.facts = strings.Join(st.facts, "\x00")
	if k.poster, age = p.app.Art.GetAge(it.Thumb, PosterW, PosterH); k.poster != nil {
		st.posterT = fadeT(age)
	}
	k.kind, k.offset, k.dur, k.views = it.Type, it.ViewOffset, it.Duration, it.ViewCount
	k.leaves, k.viewed = it.Leaves, it.Viewed
	return st
}

// drawStill draws the backdrop, the title block, the facts and the poster,
// and returns the top of the text column. Everything in it is drawn at
// once (no cached text lines that land a frame later): the layer is kept.
func (p *Preplay) drawStill(c *gfx.Canvas, st *preplayStill) int {
	it, f, k := p.item, p.app.F, &st.key
	if img := k.back; img == nil || img.W < c.W || img.H < c.H {
		c.Fill(0, 0, c.W, c.H, gfx.Bg) // a backdrop, when there is one, covers it all
	}
	if img := k.back; img != nil {
		if st.backT > 0 {
			c.BlendSolidClip(0, 0, img, gfx.Bg, st.backT, 0, 0, c.W, c.H)
		} else {
			c.Blit(0, 0, img)
		}
	}
	// title block: the logo's space is held while it is on its way, so
	// nothing below moves when it lands
	y := SafeY + 12
	if logo := k.logo; logo != nil {
		ly := y + PreLogoH - logo.H // sit on the box's baseline
		if st.logoT > 0 {
			c.BlitOverT(PreX, ly, logo, 256-st.logoT)
		} else {
			c.BlitOver(PreX, ly, logo)
		}
		y += PreLogoH + 8
	} else if k.logoPending {
		y += PreLogoH + 8
	} else {
		c.Text(PreX, y, f.Big, gfx.Grey, f.Big.Fit(it.Title, SafeW))
		y += f.Big.Height() + 2
	}
	dots(c, PreX, y, f.SmallBold, gfx.GreyHi, st.facts, SafeW)
	y += f.SmallBold.Height() + 16
	// below: the poster on the left, a short synopsis and the actions on
	// the right, all above the safe bottom
	if img := k.poster; img != nil {
		if st.posterT > 0 {
			c.BlendSolidClip(PreX, y, img, gfx.Bg, st.posterT, 0, 0, c.W, c.H)
		} else {
			c.Blit(PreX, y, img)
		}
		p.app.badge(c, it, PreX, y, PosterW, PosterH)
	} else {
		c.Fill(PreX, y, PosterW, PosterH, gfx.Bar)
	}
	return y
}

// drawColumn draws the synopsis and the actions from y down, right of the
// poster: all of it inside the corner from PreColX across and y down.
func (p *Preplay) drawColumn(c *gfx.Canvas, y int, now time.Time) bool {
	it := p.item
	f := p.app.F
	anim := false
	tw := SafeX + SafeW - PreTextX
	if p.lines == nil || p.summary != it.Summary {
		p.lines = wrap(f.SmallBold, it.Summary, tw, PreLines)
		p.summary = it.Summary
	}
	lines := p.lines
	p.more = len(lines) > 0 && strings.HasSuffix(lines[len(lines)-1], "...")
	sy := y
	col := gfx.GreyLo
	if p.cur < 0 {
		col = gfx.GreyHi
		c.Fill(PreTextX-PreFocusGap-BarW, sy+2, BarW, len(lines)*(f.SmallBold.Height()+2)-6, gfx.GreyHi)
	}
	for _, line := range lines {
		c.Text(PreTextX, y, f.SmallBold, col, line)
		y += f.SmallBold.Height() + 2
	}
	// Actions keep a close left focus bar; playback progress runs below
	// the selected Play/Resume label.
	starting := !p.app.Starting.IsZero()
	ay := y + 14
	ah := actionPitch(f.Body, ay, len(p.actions))
	for i, a := range p.actions {
		col := gfx.GreyLo
		if a == "Play" || strings.HasPrefix(a, "Resume") {
			col = gfx.Amber
		}
		// a long track title is cut to the text column, inside the safe area
		label := f.Body.Fit(a, tw)
		if i == p.cur {
			if col != gfx.Amber {
				col = gfx.White
			}
			c.Fill(PreTextX-PreFocusGap-BarW, ay+2, BarW, f.Body.Height()-4, gfx.GreyHi)
			if starting && (strings.HasPrefix(a, "Play") || strings.HasPrefix(a, "Resume")) {
				sweep(c, PreTextX, ay+f.Body.Height()+3, f.Body.Width(label), BarW, now.Sub(p.app.Starting))
				anim = true
			}
		}
		c.Text(PreTextX, ay, f.Body, col, label)
		ay += ah
	}
	return anim
}
