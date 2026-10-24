package ui

import (
	"slices"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/updates"
)

// A memo is a short note from the developers, bundled with the release. Each
// one shows once, over Home, the first time Home is reached after start-up,
// and stays until OK is held for MemoHold. Its id is kept in the config when
// it is dismissed, so it never shows again; a new note takes a new id.
type memo struct {
	ID    string // never reused: the config remembers dismissed ids
	Title string
	Text  string
}

// memos lists the notes, oldest first. Add a new one at the end with a new
// id; the first one not yet dismissed is the one shown.
var memos = []memo{
	{
		ID:    "2026-10-stable-soon",
		Title: "Close to stable release!",
		Text:  "We're close to a stable first release. Thanks for your support and issue reports so far! If you run into anything, please report it on Discord, GitHub or the MiSTer forum. -Matija",
	},
	{
		ID:    "2026-10-beta28",
		Title: "Welcome to beta.28",
		Text:  "Beta 28 is a major release and moves the core to Ben Owen's new H.264 decoder. If the in-app update showed this as beta 27.1, the update automatically bumped you to beta 28. Thanks for testing! -Matija",
	},
}

// MemoHold is how long OK must be held to dismiss a memo.
const MemoHold = time.Second

// unseenMemo is the first memo in list not dismissed in the config.
func unseenMemo(cfg *Config, list []memo) (memo, bool) {
	for _, m := range list {
		if cfg == nil || !slices.Contains(cfg.SeenMemos, m.ID) {
			return m, true
		}
	}
	return memo{}, false
}

// mergeMemos is the compiled list with the catalogue's memos laid over it: a
// published memo with a compiled one's id rewords it in place, any other is
// added after. So a note can be published, changed or, by a new id, shown
// again without an app release, and the compiled notes still show offline.
func mergeMemos(compiled []memo, published []updates.Memo) []memo {
	out := slices.Clone(compiled)
	for _, p := range published {
		m := memo{ID: p.ID, Title: p.Title, Text: p.Text}
		if i := slices.IndexFunc(out, func(c memo) bool { return c.ID == p.ID }); i >= 0 {
			out[i] = m
		} else {
			out = append(out, m)
		}
	}
	return out
}

// showMemo puts the unseen memo, if any, over Home: only when Home is on
// top and connected, with no playback or stream start in the way. It looks
// once per run, and again when a catalogue arrives (updates.go), since the
// first look usually comes before the MiSTer has its network.
func (a *App) showMemo() {
	if a.memoChecked || a.playing || !a.Starting.IsZero() || len(a.stack) == 0 {
		return
	}
	h, ok := a.top().(*Home)
	if !ok || !h.home || h.err != nil || h.connecting {
		return // not Home, or Home still connecting: wait for it
	}
	a.memoChecked = true
	if m, ok := unseenMemo(a.Cfg, mergeMemos(memos, a.updates.catalogue.Memos)); ok {
		a.Push(&MemoPage{app: a, m: m})
	}
}

// MemoPage is the memo's popup. Only a held OK takes it away.
type MemoPage struct {
	app    *App
	m      memo
	downAt time.Time   // when OK went down; zero while it is up
	press  input.Event // that press, so the rest of it can be swallowed
}

// Back is used up: the memo stays until OK is held.
func (p *MemoPage) Back() bool { return true }

// Keyboard takes every key, so typing cannot reach the page under it.
func (p *MemoPage) Keyboard(ev input.Event, now time.Time) bool {
	p.Key(ev, now)
	return true
}

// Key times the hold of OK; every other button does nothing.
func (p *MemoPage) Key(ev input.Event, now time.Time) {
	if ev.Key != input.Enter {
		return
	}
	switch {
	case ev.Release:
		if !p.downAt.IsZero() && now.Sub(p.downAt) >= MemoHold {
			p.dismiss(ev, now)
			return
		}
		p.downAt = time.Time{} // let go early: start again
	case ev.Repeat:
		// a keyboard's typematic repeat; the pad's OK does not repeat
		if !p.downAt.IsZero() && now.Sub(p.downAt) >= MemoHold {
			p.dismiss(ev, now)
		}
	default:
		p.downAt, p.press = now, ev
	}
}

// pollRefresh runs before each frame. The pad never repeats OK, so the hold
// is timed here: Draw keeps frames coming while OK is down, and the memo
// closes the frame the hold completes, with the release still to come.
func (p *MemoPage) pollRefresh(now time.Time) {
	if !p.downAt.IsZero() && now.Sub(p.downAt) >= MemoHold {
		p.dismiss(p.press, now)
	}
}

// held is how far through the hold OK is, 0..1.
func (p *MemoPage) held(now time.Time) float64 {
	if p.downAt.IsZero() {
		return 0
	}
	return min(1, float64(now.Sub(p.downAt))/float64(MemoHold))
}

// dismiss records the memo as seen and closes it. The rest of the press
// (its repeats and release) is swallowed, so it cannot open the item under
// it on Home (ev is the press, or a repeat or release of it). A failed save still closes it for this run.
func (p *MemoPage) dismiss(ev input.Event, now time.Time) {
	a := p.app
	if a.Cfg != nil {
		before := a.Cfg.snapshot()
		a.Cfg.SeenMemos = append(slices.Clone(a.Cfg.SeenMemos), p.m.ID)
		if err := a.Cfg.Save(); err != nil {
			if a.Log != nil {
				a.Log.Printf("config: %v", err)
			}
			*a.Cfg = before
			a.Notice, a.NoticeAt = "Could not save settings. Check free space and retry.", now
		}
	}
	if !ev.Release {
		// as a waking press: its repeats and the release still due are used up
		a.dim.wokeBy, a.dim.woken = input.Event{Key: ev.Key, Keyboard: ev.Keyboard, ScanCode: ev.ScanCode}, true
	}
	a.Pop()
}

const (
	memoX, memoW = SafeX + 40, SafeW - 80
	memoPad      = 24
	memoBarW     = 240
)

func (p *MemoPage) Draw(c *gfx.Canvas, now time.Time) bool {
	f := p.app.F
	c.Fill(0, 0, c.W, c.H, gfx.Bg)
	lines := wrapAll(f.Body, p.m.Text, memoW-2*memoPad)
	lineH := f.Body.Height() + 6
	h := memoPad + f.Title.Height() + 12 + 2 + 16 + len(lines)*lineH + 20 + f.Small.Height() + 8 + 2 + memoPad
	y := max(SafeY, SafeY+(SafeH-h)/2)
	c.Fill(memoX, y, memoW, h, gfx.Bar)
	c.Frame(memoX, y, memoW, h, 2, gfx.GreyLo)
	ty := y + memoPad
	c.TextCenter(c.W/2, ty, f.Title, gfx.White, p.m.Title)
	ty += f.Title.Height() + 12
	c.Fill(memoX+memoPad, ty, memoW-2*memoPad, 2, gfx.Amber)
	ty += 2 + 16
	for _, l := range lines {
		c.Text(memoX+memoPad, ty, f.Body, gfx.White, l)
		ty += lineH
	}
	ty += 20
	c.TextCenter(c.W/2, ty, f.Small, gfx.GreyLo, "Hold OK to dismiss")
	ty += f.Small.Height() + 8
	bx := (c.W - memoBarW) / 2
	c.Fill(bx, ty, memoBarW, 2, 0x404040)
	held := p.held(now)
	if held > 0 {
		c.Fill(bx, ty, int(float64(memoBarW)*held), 2, gfx.Amber)
	}
	return held > 0
}
