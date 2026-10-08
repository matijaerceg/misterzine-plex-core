package ui

import (
	"path/filepath"

	"plexcrt/internal/access"
)

// The supporter extras are compiled into this package from a private
// repository with the premium build tag. They plug into the hooks that
// premium_free.go stubs out for the public build, where every hook leaves
// things exactly as they are. Each extra is a Feature in package access:
// its Options row shows to everyone, greyed with "Needs a code" until a
// code covering it has been entered, and beta ones only with "Show beta
// features" on.

// accessDir is where receipts live: beside the settings file.
func (a *App) accessDir() string {
	if a.Cfg == nil || a.Cfg.path == "" {
		return ""
	}
	return filepath.Dir(a.Cfg.path)
}

// loadAccess reads the saved receipts (the beta's included).
func (a *App) loadAccess() { a.access = access.Load(a.accessDir()) }

// Access is the coverage of the codes entered on this card.
func (a *App) Access() access.Month { return a.access }

func (a *App) showBeta() bool { return a.Cfg != nil && a.Cfg.ShowBeta }

// allowed reports whether a feature may run: visible, and covered by a code
// when it needs one.
func (a *App) allowed(f access.Feature) bool { return f.Allowed(a.access, a.showBeta()) }

// gated is an Options row for a feature: dropped while hidden (a beta
// feature with the toggle off), and when it needs a code the card does not
// have, greyed with the need in place of its value and OK opening the code
// entry. ok reports whether the row is to be shown at all.
func (a *App) gated(row option, f access.Feature) (_ option, ok bool) {
	if !f.Visible(a.showBeta()) {
		return row, false
	}
	if f.Covered(a.access) {
		return row, true
	}
	return option{label: row.label, locked: true, val: func() string { return "Needs a code" },
		do: func() { a.Push(NewCodeEntry(a, nil)) }}, true
}

// PremiumSettings is Config.Premium for the host: the extras' own settings,
// which the public build carries through untouched.
func (a *App) PremiumSettings() map[string]string {
	if a.Cfg == nil || len(a.Cfg.Premium) == 0 {
		return nil
	}
	out := map[string]string{}
	for k, v := range a.Cfg.Premium {
		out[k] = v
	}
	return out
}

// premiumSetting is one of the extras' settings, "" when unset.
func (a *App) premiumSetting(key string) string {
	if a.Cfg == nil {
		return ""
	}
	return a.Cfg.Premium[key]
}

// setPremiumSetting stores one of the extras' settings; "" removes it.
// The caller saves the config.
func (a *App) setPremiumSetting(key, value string) {
	if a.Cfg == nil {
		return
	}
	if value == "" {
		delete(a.Cfg.Premium, key)
		return
	}
	if a.Cfg.Premium == nil {
		a.Cfg.Premium = map[string]string{}
	}
	a.Cfg.Premium[key] = value
}

// accessChanged runs after a code is entered or forgotten: the extras
// re-read what they may do.
func (a *App) accessChanged() {
	a.loadAccess()
	a.premiumStart()
}
