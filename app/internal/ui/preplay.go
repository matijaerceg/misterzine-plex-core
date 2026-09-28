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
	cur      int         // -1: the synopsis
	more     bool        // the synopsis was cut: it can be opened
	page     *gfx.Canvas // the page is composed here (blending reads pixels,
	// which must not happen on the write-combined frame), then copied
}

const (
	PreX        = SafeX
	PreTextX    = SafeX + PosterW + 24
	BgBright    = 90  // of 255: the backdrop is a mood, text must win
	BgFade      = 260 // px at the bottom fading to the background colour
	PreLogoW    = 360
	PreLogoH    = 90
	PreFocusGap = 6 // space between the movie-page selection bar and text
	PreLines    = 2 // synopsis lines: short, so it never has to be read at length
)

// NewPreplay makes the page for a playable item. Hub listings omit the
// summary and genres, so the full record is fetched when it is missing.
func NewPreplay(app *App, it *plex.Item) *Preplay {
	p := &Preplay{app: app, item: it}
	if it.Summary == "" || it.PartID == "" {
		if fresh, err := app.Plex.Item(it.RatingKey); err == nil {
			*it = *fresh
		}
	}
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
			if p.app.removeContinue(p.item, &p.cw) {
				p.rebuild() // the action goes and the cursor returns to the first
			}
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
			p.app.Plex.Scrobble(p.item.RatingKey, a == "Mark watched")
			p.refresh()
			for i, b := range p.actions {
				if strings.HasPrefix(b, "Mark") {
					p.cur = i // stay on the mark, now its counterpart
				}
			}
		}
	}
}

func (p *Preplay) play(offset int) {
	p.app.PlayAt(p.item, offset)
	p.refresh()
}

func (p *Preplay) refresh() {
	p.periodic.reset()
	if fresh, err := p.app.Plex.Item(p.item.RatingKey); err == nil {
		*p.item = *fresh
	}
	p.rebuild()
	p.cw.refetch(p.app) // a play or a mark can move it in or out
}

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

// Draw composes the page off-frame and copies it in.
func (p *Preplay) Draw(out *gfx.Canvas, now time.Time) bool {
	if p.page == nil {
		p.page = gfx.NewCanvas(out.W, out.H)
	}
	c := p.page
	anim := p.compose(c, now)
	copy(out.Pix, c.Pix)
	return anim
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

func (p *Preplay) compose(c *gfx.Canvas, now time.Time) bool {
	it := p.item
	f := p.app.F
	anim := false
	art := it.Art
	if art == "" {
		art = it.Thumb
	}
	c.Fill(0, 0, c.W, c.H, gfx.Bg)
	if img, age := p.app.Art.GetBackdrop(art, c.W, c.H, BgBright, BgFade); img != nil {
		if t := fadeT(age); t > 0 {
			c.BlendSolidClip(0, 0, img, gfx.Bg, t, 0, 0, c.W, c.H)
			anim = true
		} else {
			c.Blit(0, 0, img)
		}
	}
	// title block: the logo's space is held while it is on its way, so
	// nothing below moves when it lands
	y := SafeY + 12
	var logo *gfx.Image
	logoPending := false
	if it.Logo != "" {
		var failed bool
		var age time.Duration
		logo, age, failed = p.app.Art.getLogoAge(it.Logo, PreLogoW, PreLogoH)
		logoPending = logo == nil && !failed
		if logo != nil {
			ly := y + PreLogoH - logo.H // sit on the box's baseline
			if t := fadeT(age); t > 0 {
				c.BlitOverT(PreX, ly, logo, 256-t)
				anim = true
			} else {
				c.BlitOver(PreX, ly, logo)
			}
			y += PreLogoH + 8
		}
	}
	if logo == nil {
		if logoPending {
			y += PreLogoH + 8
		} else {
			c.Text(PreX, y, f.Big, gfx.Grey, f.Big.Fit(it.Title, SafeW))
			y += f.Big.Height() + 2
		}
	}
	facts := heroFacts(it)
	if len(it.Genres) > 0 {
		g := it.Genres
		if len(g) > 3 {
			g = g[:3]
		}
		facts = append(facts, strings.Join(g, ", "))
	}
	dots(c, PreX, y, f.SmallBold, gfx.GreyHi, facts, SafeW)
	y += f.SmallBold.Height() + 16
	// below: the poster on the left, a short synopsis and the actions on
	// the right, all above the safe bottom
	py := y
	if img, age := p.app.Art.GetAge(it.Thumb, PosterW, PosterH); img != nil {
		if t := fadeT(age); t > 0 {
			c.BlendSolidClip(PreX, py, img, gfx.Bg, t, 0, 0, c.W, c.H)
			anim = true
		} else {
			c.Blit(PreX, py, img)
		}
		p.app.badge(c, it, PreX, py, PosterW, PosterH)
	} else {
		c.Fill(PreX, py, PosterW, PosterH, gfx.Bar)
	}
	tw := SafeX + SafeW - PreTextX
	lines := wrap(f.SmallBold, it.Summary, tw, PreLines)
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
		if i == p.cur {
			if col != gfx.Amber {
				col = gfx.White
			}
			c.Fill(PreTextX-PreFocusGap-BarW, ay+2, BarW, f.Body.Height()-4, gfx.GreyHi)
			if starting && (strings.HasPrefix(a, "Play") || strings.HasPrefix(a, "Resume")) {
				sweep(c, PreTextX, ay+f.Body.Height()+3, f.Body.Width(a), BarW, now.Sub(p.app.Starting))
				anim = true
			}
		}
		c.Text(PreTextX, ay, f.Body, col, a)
		ay += ah
	}
	return anim
}
