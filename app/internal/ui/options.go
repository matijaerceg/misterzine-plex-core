package ui

import (
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/plex"
)

// Options is the settings screen: a short list of toggles.
type Options struct {
	app            *App
	cur            int
	versionPresses int
	versionAt      time.Time
}

type option struct {
	label string
	get   func() bool // a toggle, flipped by OK, left and right; nil otherwise
	set   func(bool)
	val   func() string // the value shown on the right; nil for none
	// step makes val a stepped value: left steps it by -1, right by +1, and
	// OK leaves it as it is
	step func(d int)
	// at is a stepped value's place among its choices: the index of the one
	// it has and how many there are. The selected row's arrows grey at the
	// end it is at; a row that steps sets it, and without it both arrows
	// show as live.
	at func() (i, n int)
	do func() // an action: OK runs it, on a stepped row too
	// after runs once a change is saved: Home refetched, the theme player
	// told, or nothing. Bitrate and the sound toggles change nothing on
	// screen, so stepping them must not refetch Home.
	after func()
	// busy reports that the last change is still being applied off-thread;
	// the row says so beside its value.
	busy func() bool
	// locked greys the row: a supporter extra the card has no code for.
	// Its value says what it needs and OK opens the code entry.
	locked bool
	// header is the gap between two groups of rows: half a row of nothing,
	// in the list but never the cursor.
	header bool
}

// extraOptions adds the extras' Options rows (premium.go); the tests put
// their own in its place.
var extraOptions = (*App).premiumOptions

// optionGap is the gap that starts a group of Options rows after the first.
func optionGap() option { return option{header: true} }

// items is the list as shown, the gaps between its groups included:
// playback, the libraries (once they are loaded), picture, sound, the
// extras, the account and the app. Version stays the last row.
func (o *Options) items() []option {
	cfg := o.app.Cfg
	items := []option{
		{label: "Only show 4:3 media", get: func() bool { return cfg.FourThree }, set: func(v bool) { cfg.FourThree = v }, after: o.app.Reconfigured, busy: o.app.homeUpdating},
		{label: "Autoplay next episode", get: func() bool { return !cfg.NoAutoplay }, set: func(v bool) { cfg.NoAutoplay = !v }},
		{label: "Skip intro and credits buttons", get: func() bool { return !cfg.NoSkipButtons }, set: func(v bool) { cfg.NoSkipButtons = !v }},
		{label: "Video bitrate", val: func() string {
			return Bitrates[cfg.bitrateIndex()].Label
		}, step: func(d int) {
			i := max(0, min(len(Bitrates)-1, cfg.bitrateIndex()+d))
			cfg.Bitrate = Bitrates[i].Kbps
		}, at: func() (int, int) { return cfg.bitrateIndex(), len(Bitrates) }},
		{label: "Surround downmix boost", val: func() string {
			if i := cfg.audioBoostIndex(); i >= 0 {
				return AudioBoosts[i].Label
			}
			return itoa(cfg.AudioBoostValue()) + "%"
		}, step: func(d int) {
			i := max(0, min(len(AudioBoosts)-1, max(0, cfg.audioBoostIndex())+d))
			cfg.AudioBoost = AudioBoosts[i].Value
		}, at: func() (int, int) {
			// a gain set by hand is none of the choices: both ways step
			return cfg.audioBoostIndex(), len(AudioBoosts)
		}},
	}
	items = o.app.libraryOptions(items)
	items = append(items, []option{
		optionGap(),
		{label: "Video output", val: func() string {
			if o.app.videoLocked() {
				return "480i (CRT profile)"
			}
			if cfg.Progressive {
				return "480p (HDMI)"
			}
			return "480i (CRT)"
		}, do: o.app.chooseVideo},
		{label: "Video geometry", do: func() { o.app.Push(NewCalibrate(o.app)) }},
		{label: "Video crop", val: func() string { return cfg.Crop.Label() }, step: func(d int) {
			cfg.Crop = Crops[max(0, min(len(Crops)-1, cfg.Crop.index()+d))].Mode
		}, at: func() (int, int) { return cfg.Crop.index(), len(Crops) }},
	}...)
	for _, w := range o.app.Display.Warnings() {
		items = append(items, option{label: w.label, val: func() string { return w.value }, do: func() { o.app.Push(NewDisplayNote(o.app, w)) }})
	}
	items = append(items, []option{
		optionGap(),
		{label: "Theme music", get: func() bool { return !cfg.NoTheme }, set: func(v bool) { cfg.NoTheme = !v }, after: o.app.syncTheme},
		{label: "Navigation sounds", get: func() bool { return !cfg.NoTaps }, set: func(v bool) { cfg.NoTaps = !v }},
		optionGap(),
	}...)
	items = extraOptions(o.app, items)
	items = append(items, option{label: "Show beta features", get: func() bool { return cfg.ShowBeta }, set: func(v bool) { cfg.ShowBeta = v }, after: o.app.accessChanged})
	items = append(items, optionGap())
	if cfg.Token != "" {
		items = append(items, option{label: "Choose server again", do: func() { o.app.Push(NewServerPicker(o.app)) }})
	}
	label := "Sign out"
	if cfg.Token != "" && cfg.AccountName != "" && !o.app.Showcase {
		label = "Sign out (" + cfg.AccountName + ")"
	}
	items = append(items, option{label: label, do: o.app.SignOut}, optionGap())
	updateLabel := "Updates"
	switch s := o.app.updates.status; {
	case s.Busy():
		updateLabel = "Updates - downloading"
	case o.app.prepared() != nil:
		updateLabel = "Updates - ready, restart to finish"
	case o.app.failure():
		updateLabel = "Updates - update failed"
	case o.app.updateAvailable():
		updateLabel = "Updates - update available"
	}
	items = append(items, option{label: updateLabel, do: func() { o.app.Push(NewUpdates(o.app)) }})
	items = append(items, option{label: "Send a report", do: func() { o.app.Push(NewReport(o.app)) }})
	if o.app.Plex == nil {
		// signed out there is no menu to hold Exit and Patreon: Back from
		// the sign-in screen comes here
		items = append(items,
			option{label: "Exit to MiSTer menu", do: func() { o.app.ToMenu = true }},
			option{label: "Patreon", do: func() { o.app.Push(NewPatreon(o.app)) }})
	}
	items = append(items, option{label: "Version", val: func() string {
		if o.app.Version == "" {
			return "development"
		}
		return o.app.Version
	}, do: func() {}})
	return items
}

// NewOptions makes the settings screen.
func NewOptions(app *App) *Options {
	app.loadAccountName()
	return &Options{app: app}
}

// Fetch optional display information off-thread, including for older saved logins.
// A failed lookup leaves sign-in intact and can retry when Options is reopened.
func (a *App) loadAccountName() {
	cfg := a.Cfg
	if cfg.Token == "" || cfg.AccountName != "" || a.accountLookup {
		return
	}
	id, token := cfg.ClientID, cfg.Token
	a.accountLookup = true
	go func() {
		name, err := plex.AccountName(id, token)
		a.Later(func() {
			a.accountLookup = false
			if a.Cfg != cfg || cfg.Token != token {
				return // signed out or changed account while the request was running
			}
			if err != nil || name == "" {
				return
			}
			next := *cfg
			next.AccountName = name
			if err := next.Save(); err != nil {
				a.Log.Printf("could not save account name")
				return
			}
			*cfg = next
		})
	}()
}

// nextOption is the first row past i in direction d (+1 or -1) that is
// not a gap, or i when there is none.
func nextOption(items []option, i, d int) int {
	for j := i + d; j >= 0 && j < len(items); j += d {
		if !items[j].header {
			return j
		}
	}
	return i
}

// onOption is cur moved onto a row that can be chosen: the list changes
// under the cursor (a sign-out, beta rows, warnings) and a gap is
// never the cursor. The next row down is preferred, then the one above.
func onOption(items []option, cur int) int {
	cur = max(0, min(len(items)-1, cur))
	if !items[cur].header {
		return cur
	}
	if i := nextOption(items, cur, 1); i != cur {
		return i
	}
	return nextOption(items, cur, -1)
}

// Key handles one input event: up/down choose; OK, left and right flip a
// toggle; left and right step a stepped value; OK runs a row's action.
func (o *Options) Key(ev input.Event, now time.Time) {
	if ev.Release {
		return
	}
	items := o.items()
	o.cur = onOption(items, o.cur)
	if o.cur == len(items)-1 && ev.Key == input.Enter {
		if ev.Repeat {
			return
		}
		if now.Sub(o.versionAt) > 2*time.Second {
			o.versionPresses = 0
		}
		o.versionAt = now
		o.versionPresses++
		if o.versionPresses == 3 {
			o.versionPresses = 0
			o.app.toggleShowcase(o, now)
		}
		return
	}
	o.versionPresses = 0
	switch ev.Key {
	case input.Up:
		o.cur = nextOption(items, o.cur, -1)
	case input.Down:
		o.cur = nextOption(items, o.cur, 1)
	case input.Enter, input.Left, input.Right:
		it := items[o.cur]
		toggle := it.get != nil && !it.locked
		step := it.step != nil && !it.locked && ev.Key != input.Enter
		if !toggle && !step {
			// OK runs the row's action: a button's, a locked extra's code
			// entry, a stepped row's own when it has one (and nothing when
			// it has none). Left and right change only toggles and
			// stepped values.
			if ev.Key == input.Enter && it.do != nil {
				it.do()
			}
			return
		}
		before := o.app.Cfg.snapshot()
		switch {
		case toggle:
			it.set(!it.get())
		case ev.Key == input.Left:
			it.step(-1)
		default:
			it.step(1)
		}
		if err := o.app.Cfg.Save(); err != nil {
			o.app.Log.Printf("config: %v", err)
			*o.app.Cfg = before
			o.app.Notice, o.app.NoticeAt = "Could not save settings. Check free space and retry.", now
			return
		}
		if it.after != nil {
			it.after()
		}
		// the change can add or take away rows above this one (Show beta
		// features and the beta extras): the cursor stays on the row it
		// changed rather than on whatever row now has its place
		next := o.items()
		o.cur = onOption(next, labelledOption(next, it.label, o.cur))
	}
}

// labelledOption is the row of items labelled label, or cur when no row is.
// cur itself wins when it has the label: two libraries can share a name.
func labelledOption(items []option, label string, cur int) int {
	if cur >= 0 && cur < len(items) && !items[cur].header && items[cur].label == label {
		return cur
	}
	for i, it := range items {
		if !it.header && it.label == label {
			return i
		}
	}
	return cur
}

// optionRows is how many rows high the Options window is, a gap counting
// as half a row.
const optionRows = 9

// halfRows is a row's height in half rows: a gap is one, a row two.
func halfRows(it option) int {
	if it.header {
		return 1
	}
	return 2
}

// optionWindow is the part of items in view with row cur selected: the
// rows from first up to end. top is first's place down the list and total
// the list's height, both in half rows. As centredFirst has it, the
// selection holds the middle of the window and walks towards the top or
// bottom only at the list's start and end, measured in half rows. The
// window opens on the row the centred window would, or on the next one
// when that would cut a row in half or open on a gap (a blank half row
// above the first row): the selection then sits up to a row above the
// middle.
func optionWindow(items []option, cur int) (first, end, top, total int) {
	at := 0 // cur's place down the list
	for i, it := range items {
		if i == cur {
			at = total
		}
		total += halfRows(it)
	}
	// the selection's middle on the window's
	want := centredFirst(at+1, 2*optionRows, total)
	for first < len(items) && (top < want || items[first].header) {
		top += halfRows(items[first])
		first++
	}
	h := 0
	for end = first; end < len(items) && h+halfRows(items[end]) <= 2*optionRows; end++ {
		h += halfRows(items[end])
	}
	return first, end, top, total
}

// stepArrowW is the room each arrow beside a stepped value takes: the
// arrow (the chevrons are 6 wide) and the space between it and the value.
const stepArrowW = 6 + 8

// stepArrows draws the arrows either side of the selected stepped value,
// whose text runs from x0 to x1, with their tops at y: amber, or greyed at
// the end of the choices the value is at.
func stepArrows(c *gfx.Canvas, it option, x0, x1, y int) {
	lc, rc := gfx.Amber, gfx.Amber
	if it.at != nil {
		i, n := it.at()
		if i == 0 {
			lc = gfx.GreyLo
		}
		if i == n-1 {
			rc = gfx.GreyLo
		}
	}
	// a chevron reaches 3 left of its centre and 2 right of it
	chevronLeft(c, x0-stepArrowW+3, y, lc)
	chevronRight(c, x1+stepArrowW-3, y, rc)
}

// Draw paints the list of options with their values on the right.
func (o *Options) Draw(c *gfx.Canvas, now time.Time) bool {
	c.Fill(0, 0, c.W, c.H, gfx.Bg)
	f := o.app.F
	o.app.text(c, MenuX, SafeY, f.Title, gfx.Grey, "Options")
	y := ListY0
	items := o.items()
	cur := onOption(items, o.cur)
	first, end, top, total := optionWindow(items, cur)
	for i := first; i < end; i++ {
		it := items[i]
		if it.header {
			y += MenuRowH / 2 // the gap between two groups: nothing drawn
			continue
		}
		col := gfx.GreyHi
		if it.locked {
			col = gfx.GreyLo
		}
		if i == cur {
			col = gfx.White
			menuFocusBar(c, MenuX, y+9, f.Body.Height())
		}
		stepped := it.step != nil && it.val != nil && !it.locked
		labelW := MenuWidth
		if it.get != nil {
			labelW -= f.Body.Width("Off") + 24
		} else if it.val != nil {
			labelW -= f.Body.Width(it.val()) + 24
		}
		if stepped {
			// room for the arrows whether or not they show, so the label
			// does not change as the cursor comes and goes
			labelW -= 2 * stepArrowW
		}
		o.app.text(c, MenuX, y+9, f.Body, col, f.Body.Fit(it.label, labelW))
		if it.get != nil {
			v := "Off"
			vc := gfx.GreyLo
			if it.get() {
				v, vc = "On", gfx.Amber
			}
			o.app.textRight(c, MenuRight, y+9, f.Body, vc, v)
			if it.busy != nil && it.busy() {
				// the change took at once; the rows behind are still catching up
				o.app.textRight(c, MenuRight-f.Body.Width(v)-16, y+13, f.SmallBold, gfx.GreyLo, "updating")
			}
		}
		if it.val != nil {
			vc := gfx.Amber
			if it.locked {
				vc = gfx.GreyLo
			}
			v := it.val()
			if stepped && i == cur {
				// left and right step it: an arrow either side says so
				right := MenuRight - stepArrowW
				o.app.textRight(c, right, y+9, f.Body, vc, v)
				stepArrows(c, it, right-f.Body.Width(v), right, y+9+f.Body.Height()/2-6)
			} else {
				o.app.textRight(c, MenuRight, y+9, f.Body, vc, v)
			}
		}
		y += MenuRowH
	}
	// more rows than the window: a scrollbar from the first row's text to
	// the last's, the list measured in half rows (a gap's height)
	menuScrollbar(c, ListY0+9, optionRows*MenuRowH-MenuRowH+f.Body.Height(), min(top, total-2*optionRows), 2*optionRows, total)
	if o.app.Build != "" {
		o.app.text(c, MenuX, SafeBottom-48, f.Small, gfx.GreyLo, f.Small.Fit("Build: "+o.app.Build, MenuWidth))
	}
	o.app.text(c, MenuX, SafeBottom-24, f.SmallBold, gfx.Purple, patreonAddress)
	return false
}
