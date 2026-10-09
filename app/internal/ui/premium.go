package ui

import (
	"math"
	"path/filepath"

	"plexcrt/internal/access"
	"plexcrt/internal/gfx"
)

// The supporter extras are compiled into this package from a private
// repository with the premium build tag. They plug into the hooks that
// premium_free.go stubs out for the public build, where every hook leaves
// things exactly as they are. Each extra is a Feature in package access:
// its Options row shows to everyone, greyed with "Unlock forever" until a
// code covering it has been entered (a code is entered once and keeps its
// month's features for good on the card), and beta ones only with "Show
// beta features" on. A purple star after the label marks it either way.
// A row whose choices are partly everyone's and partly a code's marks the
// value instead (option.starred): a star after a gated choice, greyed while
// the card has no code for it.
//
// An extra's library view (premiumWallViews) is a wallView: it can show
// the listing in an order of its own (NewOrderedPager), keep its place
// for the session (forgetWallView drops it), start over on OK on its tab
// and hear when the library is left.

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

// unlockForever is the call to action wherever something needs a code the
// card does not have: a code is entered once and keeps what it covers for
// good.
const unlockForever = "Unlock forever"

// gated is an Options row for a feature: dropped while hidden (a beta
// feature with the toggle off), and when it needs a code the card does not
// have, greyed with unlockForever in place of its value and OK opening the
// code entry. ok reports whether the row is to be shown at all.
func (a *App) gated(row option, f access.Feature) (_ option, ok bool) {
	if !f.Visible(a.showBeta()) {
		return row, false
	}
	if f.Covered(a.access) {
		row.supporter = true
		return row, true
	}
	return option{label: row.label, locked: true, supporter: true, val: func() string { return unlockForever },
		do: func() { a.Push(NewCodeEntry(a, nil)) }}, true
}

// The supporter star after an extra's label in Options: five broad points
// (thin ones smear over composite) in the MisterZine purple, starH lines
// tall and 9/8 as wide for the raster's pixels, drawn over the page's
// background so it is copied, not blended, and made on first use.
const (
	supporterStarH   = 14
	supporterStarGap = 8 // between the label and the star
)

var supporterStarImg *gfx.Image

func supporterStar() *gfx.Image {
	if supporterStarImg != nil {
		return supporterStarImg
	}
	// the corners, point up, in square pixels: top at 0, the lower points
	// on the bottom line
	const inner = 0.5 // of the outer radius; a regular star's is 0.38
	r := float64(supporterStarH) / (1 + math.Cos(math.Pi/5))
	sw := 2 * r * math.Sin(2*math.Pi/5) // its width in square pixels
	var px, py [10]float64
	for i := range px {
		k := 1.0
		if i%2 == 1 {
			k = inner
		}
		ang := -math.Pi/2 + float64(i)*math.Pi/5
		px[i], py[i] = sw/2+k*r*math.Cos(ang), r+k*r*math.Sin(ang)
	}
	inside := func(x, y float64) bool {
		in := false
		for i, j := 0, len(px)-1; i < len(px); j, i = i, i+1 {
			if (py[i] > y) != (py[j] > y) && x < px[j]+(y-py[j])*(px[i]-px[j])/(py[i]-py[j]) {
				in = !in
			}
		}
		return in
	}
	w, h := int(math.Ceil(sw*9/8)), supporterStarH
	im := &gfx.Image{W: w, H: h, Pix: make([]byte, w*h*4)}
	mix := func(bg, fg gfx.Color, shift uint, cov float64) byte {
		b, f := float64(byte(bg>>shift)), float64(byte(fg>>shift))
		return byte(b + (f-b)*cov + 0.5)
	}
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			n := 0
			for sy := 0; sy < 4; sy++ {
				for sx := 0; sx < 4; sx++ {
					if inside((float64(x)+(float64(sx)+0.5)/4)*8/9, float64(y)+(float64(sy)+0.5)/4) {
						n++
					}
				}
			}
			cov, p := float64(n)/16, (y*w+x)*4
			im.Pix[p], im.Pix[p+1], im.Pix[p+2] = mix(gfx.Bg, gfx.Purple, 0, cov), mix(gfx.Bg, gfx.Purple, 8, cov), mix(gfx.Bg, gfx.Purple, 16, cov)
			im.Pix[p+3] = 255
		}
	}
	supporterStarImg = im
	return im
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
