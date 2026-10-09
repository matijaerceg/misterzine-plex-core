package ui

import (
	"path/filepath"
	"time"

	"plexcrt/internal/access"
	"plexcrt/internal/beta"
	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
)

const patreonAddress = "patreon.com/MisterZine"

const unlockAnimation = 1800 * time.Millisecond
const digitAnimation = 80 * time.Millisecond
const accessSurface gfx.Color = 0x292633

type digitMotion struct {
	previous  byte
	direction int
	at        time.Time
}

type accessPageState struct {
	selected int
	message  string
}

// BetaAccess retains the browsing screen and resumes one pending request only
// after access has been saved and the success animation has finished.
type BetaAccess struct {
	requirement beta.Requirement
	// premium is the supporter-code entry: the code goes to package access
	// (the extras) instead of the beta's playback gate.
	premium     bool
	version     string
	titleFont   *gfx.Font
	versionFont *gfx.Font
	motion      [6]digitMotion
	digitCell   *gfx.Canvas
	pageState   accessPageState
	pageReady   bool
	page        *gfx.Canvas
	app         *App
	back        *gfx.Canvas
	digits      [6]byte
	selected    int
	message     string
	opened      time.Time
	then        func()
}

func NewBetaAccess(a *App, then func()) *BetaAccess {
	b := &BetaAccess{requirement: beta.Current(), version: a.Version, app: a, then: then, back: gfx.NewCanvas(720, 480), titleFont: gfx.Load("condit24"), versionFont: gfx.Load("reg18")}
	if len(a.stack) > 0 {
		a.top().Draw(b.back, time.Now())
	}
	image := &gfx.Image{W: 720, H: 480, Pix: b.back.Pix}
	b.back.BlendSolidClip(0, 0, image, 0, 256-112, 0, 0, 720, 480)
	return b
}

// The supporter-code entry's title and the paragraph under it, wrapped
// to the panel: one code, entered once, keeps the features of its day for
// good; later ones come with a new code, and nobody has to stay
// subscribed.
const (
	codeEntryTitle = "UNLOCK FOREVER"
	codeEntryText  = "A code unlocks today's supporter features for good on this card. " +
		"Later features come with a new code. No need to stay subscribed."
	codeEntryLineH = 22
)

// NewCodeEntry is the supporter-code entry: a MisterZine code covering the
// extras, saved for good. then runs once it is accepted.
func NewCodeEntry(a *App, then func()) *BetaAccess {
	b := NewBetaAccess(a, then)
	b.premium = true
	return b
}

// hasCode reports whether this screen takes a code at all.
func (b *BetaAccess) hasCode() bool { return b.premium || b.requirement.CodeSHA256 != "" }

func (a *App) betaDir() string {
	if a.Cfg == nil || a.Cfg.path == "" {
		return ""
	}
	return filepath.Dir(a.Cfg.path)
}

func (b *BetaAccess) Back() bool {
	if !b.opened.IsZero() {
		return true
	}
	b.then = nil
	b.app.Pop()
	return true
}

func (b *BetaAccess) Keyboard(ev input.Event, now time.Time) bool {
	if ev.Text >= '0' && ev.Text <= '9' {
		if !ev.Release && !ev.Repeat && b.opened.IsZero() {
			b.setDigit(byte(ev.Text-'0'), 1, now)
			b.selected = min(5, b.selected+1)
			b.message = ""
		}
		return true
	}
	if ev.ScanCode == 0x66 { // Backspace edits; Escape still cancels.
		if !ev.Release && b.opened.IsZero() {
			b.selected = max(0, b.selected-1)
			b.setDigit(0, -1, now)
			b.message = ""
		}
		return true
	}
	if ev.Text != 0 {
		return true
	} // no Space=submit or WASD aliases while typing
	return false
}

func (b *BetaAccess) Key(ev input.Event, now time.Time) {
	if ev.Release || !b.opened.IsZero() {
		return
	}
	switch ev.Key {
	case input.Left:
		b.selected = max(0, b.selected-1)
	case input.Right:
		b.selected = min(5, b.selected+1)
	case input.Up:
		b.setDigit((b.digits[b.selected]+1)%10, 1, now)
		b.message = ""
	case input.Down:
		b.setDigit((b.digits[b.selected]+9)%10, -1, now)
		b.message = ""
	case input.Enter:
		if ev.Repeat {
			return
		}
		if !b.hasCode() {
			b.Back()
			return
		}
		code := make([]byte, 6)
		for i, d := range b.digits {
			code[i] = '0' + d
		}
		if b.app.betaDir() == "" {
			b.message = "Could not save access. Check storage and retry."
			return
		}
		var err error
		if b.premium {
			_, err = access.Unlock(b.app.betaDir(), string(code))
		} else {
			err = b.requirement.Unlock(b.app.betaDir(), string(code))
		}
		switch err {
		case nil:
			b.opened = now
			b.message = "Playback enabled"
			if b.premium {
				b.message = "Unlocked"
			}
			b.app.accessChanged()
		case beta.ErrLocked, access.ErrCode:
			b.message = "Invalid code."
		case beta.ErrBuild:
			b.message = beta.ErrBuild.Error()
		default:
			b.message = "Could not save access. Check storage and retry."
		}
	}
}

func (b *BetaAccess) pollRefresh(now time.Time) {
	if b.opened.IsZero() || now.Sub(b.opened) < unlockAnimation {
		return
	}
	then := b.then
	b.then = nil
	b.opened = time.Time{}
	b.app.Pop()
	if then != nil {
		then()
	}
}

// Input changes the submitted value immediately. Animation never queues input,
// and every repeat replaces the previous animation with the newest value.
func (b *BetaAccess) setDigit(value byte, direction int, now time.Time) {
	i := b.selected
	if value == b.digits[i] {
		return
	}
	b.motion[i] = digitMotion{previous: b.digits[i], direction: direction, at: now}
	b.digits[i] = value
}

func (b *BetaAccess) Draw(c *gfx.Canvas, now time.Time) bool {
	if b.page == nil {
		b.page = gfx.NewCanvas(c.W, c.H)
	}
	state := accessPageState{b.selected, b.message}
	if !b.pageReady || state != b.pageState {
		b.compose(b.page, now)
		b.pageState = state
		b.pageReady = true
	}
	moving := !b.opened.IsZero()
	if b.hasCode() {
		b.page.Fill(210, 266, 300, 47, accessSurface)
		if b.digitCell == nil {
			b.digitCell = gfx.NewCanvas(40, 36)
		}
		for i, d := range b.digits {
			dx := 218 + i*48
			col := gfx.GreyHi
			if i == b.selected {
				col = gfx.White
				b.page.Fill(dx+5, 306, 30, 3, gfx.Purple)
			}
			cell := b.digitCell
			cell.Fill(0, 0, 40, 36, accessSurface)
			motion := b.motion[i]
			age := now.Sub(motion.at)
			offset := 0
			if !motion.at.IsZero() && age < digitAnimation && age >= 0 {
				remaining := 1 - float64(age)/float64(digitAnimation)
				offset = round(32*remaining*remaining) * motion.direction
				moving = true
				cell.Text((40-b.app.F.Big.Width("0"))/2, 4+offset-32*motion.direction, b.app.F.Big, col, string(rune('0'+motion.previous)))
			}
			cell.Text((40-b.app.F.Big.Width("0"))/2, 4+offset, b.app.F.Big, col, string(rune('0'+d)))
			b.page.Blit(dx, 268, &gfx.Image{W: 40, H: 36, Pix: cell.Pix})
		}
	}
	c.Blit(0, 0, &gfx.Image{W: b.page.W, H: b.page.H, Pix: b.page.Pix})
	return moving
}

func (b *BetaAccess) compose(c *gfx.Canvas, now time.Time) bool {
	c.Blit(0, 0, &gfx.Image{W: b.back.W, H: b.back.H, Pix: b.back.Pix})
	const x, y, w, h = 92, 108, 536, 312
	// Lift the surface above dark artwork without a heavy lock-style frame.
	c.Fill(x+5, y+5, w, h, 0x08090D)
	c.Fill(x, y, w, h, accessSurface)
	f := b.app.F
	center := func(yy int, font *gfx.Font, color gfx.Color, s string) {
		c.Text((c.W-font.Width(s))/2, yy, font, color, s)
	}
	if b.premium {
		center(128, b.titleFont, gfx.Purple, codeEntryTitle)
		center(158, b.versionFont, gfx.Amber, "Your access: "+b.app.Access().Covering())
		for i, line := range wrap(f.Body, codeEntryText, w-16, 3) {
			// wrapped to the panel, which is narrower than the menus
			center(196+i*codeEntryLineH, f.Body, gfx.GreyHi, line)
		}
		for i, line := range wrap(f.SmallBold, b.message, w-32, 2) {
			center(321+i*19, f.SmallBold, gfx.Purple, line)
		}
		center(374, f.Body, gfx.Purple, patreonAddress)
		return !b.opened.IsZero()
	}
	center(128, b.titleFont, gfx.Purple, "EARLY ACCESS")
	center(158, b.versionFont, gfx.Amber, b.version)
	if b.requirement.CodeSHA256 == "" {
		for i, line := range []string{"This release uses a patron key file.", "Extract its key ZIP onto your MiSTer SD card.", "Return to the app and press Play again."} {
			center(207+i*28, f.Body, gfx.White, line)
		}
		center(374, f.Body, gfx.Purple, patreonAddress)
		return false
	}
	center(203, f.Body, gfx.White, "Playback in this early-access release requires")
	center(228, f.Body, gfx.White, "a code from a paid Patreon tier.")
	for i, line := range wrap(f.SmallBold, b.message, w-32, 2) {
		center(321+i*19, f.SmallBold, gfx.Purple, line)
	}
	center(374, f.Body, gfx.Purple, patreonAddress)
	return !b.opened.IsZero()
}
