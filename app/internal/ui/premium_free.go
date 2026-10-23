//go:build !premium

package ui

import (
	"time"

	"plexcrt/internal/plex"
)

// The public build's side of the hooks in premium.go: none of them changes
// anything.

// premiumStart applies the extras' settings once the app is built, and
// again after the access changes.
func (a *App) premiumStart() {}

// premiumOptions is the Options rows with the extras' own rows added. Its
// rows are appended to the extras' group, before Show beta features.
func (a *App) premiumOptions(items []option) []option { return items }

// premiumIdle is given each idle tick before the screen dims: waiting is
// whether the menus only wait for a press (false while a playback is up,
// paused or not, or a stream starts), since is how long. True when an
// extra has taken the screen (a screensaver), so dimming waits; an extra
// takes it only while waiting.
func (a *App) premiumIdle(now time.Time, waiting bool, since time.Duration) bool { return false }

// premiumHomeLogo is the logo Home draws at its top left, the chevron
// before it: the app's wordmark (a.Mark), another picture made with
// NewMark, or nil for none, when the BETA and UPDATE marks start where the
// wordmark would. It is asked on every frame Home shows, so it should not
// allocate.
func (a *App) premiumHomeLogo() *Wordmark { return a.Mark }

// premiumWallViews is the extras' views of a library, its tabs after
// Released; nil for none. It is asked on every frame the library shows,
// so it should not allocate; the tabs are remade when the names change.
func (a *App) premiumWallViews(s plex.Section) []wallView { return nil }

// premiumVersion is the extras' line for -version; "" in the public build.
func PremiumVersion() string { return "" }
