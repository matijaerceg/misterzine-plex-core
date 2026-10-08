//go:build !premium

package ui

import "time"

// The public build's side of the hooks in premium.go: none of them changes
// anything.

// premiumStart applies the extras' settings once the app is built, and
// again after the access changes.
func (a *App) premiumStart() {}

// premiumOptions is the Options rows with the extras' own rows added. Its
// rows are appended under the Extras header, before Show beta features.
func (a *App) premiumOptions(items []option) []option { return items }

// premiumIdle is given each idle tick before the screen dims: waiting is
// whether the menus only wait for a press, since is how long. True when an
// extra has taken the screen (a screensaver), so dimming waits.
func (a *App) premiumIdle(now time.Time, waiting bool, since time.Duration) bool { return false }

// premiumVersion is the extras' line for -version; "" in the public build.
func PremiumVersion() string { return "" }
