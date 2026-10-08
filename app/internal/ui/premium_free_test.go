//go:build !premium

package ui

import (
	"testing"

	"plexcrt/internal/access"
	"plexcrt/internal/gfx"
)

// The public build has no Home logo toggle: whatever the settings say,
// Home keeps its wordmark and the marks stay beside it.
func TestPublicBuildKeepsTheHomeLogo(t *testing.T) {
	a := betaTestApp(t)
	a.access = access.NoHomeLogo.Since
	a.setPremiumSetting("home_logo", "off")
	if !a.premiumHomeLogo() {
		t.Fatal("the public build hides the Home logo")
	}
	c := composeHome(a)
	if !wordmarkInk(a, c) {
		t.Fatal("Home composed without its wordmark")
	}
	a.drawBrand(c)
	if !markAt(c, a.mark("BETA", gfx.Amber), SafeX+16+a.Mark.W+12, SafeY) {
		t.Fatal("the BETA mark moved")
	}
}
