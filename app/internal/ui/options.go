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
	get   func() bool // a toggle; nil otherwise
	set   func(bool)
	val   func() string // a stepped value; nil otherwise
	step  func(d int)   // d is -1 or +1
	do    func()        // an action
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
	// header is a section's name over its rows: it takes a row in the
	// list but is never the cursor.
	header bool
}

// optionSection is the header row that starts a section of Options.
func optionSection(name string) option { return option{label: name, header: true} }

// items is the list as shown, section headers included: Playback,
// Libraries (once the libraries are loaded), Picture, Sound, Extras,
// Account, App. Version stays the last row.
func (o *Options) items() []option {
	cfg := o.app.Cfg
	items := []option{
		optionSection("Playback"),
		{label: "Only show 4:3 media", get: func() bool { return cfg.FourThree }, set: func(v bool) { cfg.FourThree = v }, after: o.app.Reconfigured, busy: o.app.homeUpdating},
		{label: "Autoplay next episode", get: func() bool { return !cfg.NoAutoplay }, set: func(v bool) { cfg.NoAutoplay = !v }},
		{label: "Skip intro and credits buttons", get: func() bool { return !cfg.NoSkipButtons }, set: func(v bool) { cfg.NoSkipButtons = !v }},
		{label: "Video bitrate", val: func() string {
			return Bitrates[cfg.bitrateIndex()].Label
		}, step: func(d int) {
			i := max(0, min(len(Bitrates)-1, cfg.bitrateIndex()+d))
			cfg.Bitrate = Bitrates[i].Kbps
		}},
		{label: "Surround downmix boost", val: func() string {
			for _, b := range AudioBoosts {
				if b.Value == cfg.AudioBoostValue() {
					return b.Label
				}
			}
			return itoa(cfg.AudioBoostValue()) + "%"
		}, step: func(d int) {
			i := 0
			for j, b := range AudioBoosts {
				if b.Value == cfg.AudioBoostValue() {
					i = j
				}
			}
			i = max(0, min(len(AudioBoosts)-1, i+d))
			cfg.AudioBoost = AudioBoosts[i].Value
		}},
	}
	items = o.app.libraryOptions(items)
	items = append(items, []option{
		optionSection("Picture"),
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
		}},
	}...)
	for _, w := range o.app.Display.Warnings() {
		items = append(items, option{label: w.label, val: func() string { return w.value }, do: func() { o.app.Push(NewDisplayNote(o.app, w)) }})
	}
	items = append(items, []option{
		optionSection("Sound"),
		{label: "Theme music", get: func() bool { return !cfg.NoTheme }, set: func(v bool) { cfg.NoTheme = !v }, after: o.app.syncTheme},
		{label: "Navigation sounds", get: func() bool { return !cfg.NoTaps }, set: func(v bool) { cfg.NoTaps = !v }},
		optionSection("Extras"),
	}...)
	items = o.app.premiumOptions(items)
	items = append(items, option{label: "Show beta features", get: func() bool { return cfg.ShowBeta }, set: func(v bool) { cfg.ShowBeta = v }, after: o.app.accessChanged})
	items = append(items, optionSection("Account"))
	if cfg.Token != "" {
		items = append(items, option{label: "Choose server again", do: func() { o.app.Push(NewServerPicker(o.app)) }})
	}
	label := "Sign out"
	if cfg.Token != "" && cfg.AccountName != "" && !o.app.Showcase {
		label = "Sign out (" + cfg.AccountName + ")"
	}
	items = append(items, option{label: label, do: o.app.SignOut}, optionSection("App"))
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
// not a header, or i when there is none.
func nextOption(items []option, i, d int) int {
	for j := i + d; j >= 0 && j < len(items); j += d {
		if !items[j].header {
			return j
		}
	}
	return i
}

// onOption is cur moved onto a row that can be chosen: the list changes
// under the cursor (a sign-out, beta rows, warnings) and a header is
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

// Key handles one input event: up/down choose, OK/left/right toggle.
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
		before := *o.app.Cfg
		it := items[o.cur]
		switch {
		case it.get != nil:
			it.set(!it.get())
		case it.step != nil:
			if ev.Key == input.Left {
				it.step(-1)
			} else {
				it.step(1)
			}
		default:
			if ev.Key == input.Enter {
				it.do()
			}
			return
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

// Draw paints the list of options with their values on the right.
func (o *Options) Draw(c *gfx.Canvas, now time.Time) bool {
	c.Fill(0, 0, c.W, c.H, gfx.Bg)
	f := o.app.F
	o.app.text(c, MenuX, SafeY, f.Title, gfx.Grey, "Options")
	y := ListY0
	items := o.items()
	cur := onOption(items, o.cur)
	const visibleRows = 9
	first := centredFirst(cur, visibleRows, len(items))
	for i := first; i < min(len(items), first+visibleRows); i++ {
		it := items[i]
		if it.header {
			o.app.text(c, MenuX, y+13, f.SmallBold, gfx.GreyLo, it.label)
			y += MenuRowH
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
		labelW := MenuWidth
		if it.get != nil {
			labelW -= f.Body.Width("Off") + 24
		} else if it.val != nil {
			labelW -= f.Body.Width(it.val()) + 24
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
			o.app.textRight(c, MenuRight, y+9, f.Body, vc, it.val())
		}
		y += MenuRowH
	}
	// more rows than the window: a scrollbar from the first row's text to
	// the last's, headers counted as rows
	menuScrollbar(c, ListY0+9, visibleRows*MenuRowH-MenuRowH+f.Body.Height(), first, visibleRows, len(items))
	if o.app.Build != "" {
		o.app.text(c, MenuX, SafeBottom-48, f.Small, gfx.GreyLo, f.Small.Fit("Build: "+o.app.Build, MenuWidth))
	}
	o.app.text(c, MenuX, SafeBottom-24, f.SmallBold, gfx.Purple, patreonAddress)
	return false
}
