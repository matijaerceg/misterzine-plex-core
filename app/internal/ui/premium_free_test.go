//go:build !premium

package ui

import (
	"testing"

	"plexcrt/internal/access"
	"plexcrt/internal/gfx"
)

// The public build has no Home logo choice: whatever the settings say,
// Home keeps its wordmark and the marks stay beside it.
func TestPublicBuildKeepsTheHomeLogo(t *testing.T) {
	for _, v := range []string{"", "off", "kun"} {
		a := betaTestApp(t)
		a.access = access.NoHomeLogo.Since
		a.setPremiumSetting("home_logo", v)
		if a.premiumHomeLogo() != a.Mark {
			t.Fatalf("%q: the public build draws another Home logo", v)
		}
		c := composeHome(a)
		if !wordmarkInk(a, c) {
			t.Fatalf("%q: Home composed without its wordmark", v)
		}
		a.drawBrand(c)
		if m := a.brandMarks(); len(m) == 0 || !markAt(c, a.mark(m[0].text, m[0].fill), SafeX+16+a.Mark.W+12, SafeY) {
			t.Fatalf("%q: the BETA mark moved", v)
		}
	}
}

// NewMark keeps the picture's size for laying out and puts the
// wordmark's shadow around it.
func TestNewMarkShadowsAPicture(t *testing.T) {
	im := &gfx.Image{W: 10, H: 6, Pix: make([]byte, 10*6*4)}
	for i := range im.Pix {
		im.Pix[i] = 255
	}
	m := NewMark(im)
	if m.W != 10 || m.H != 6 || m.Over.W != 10+2*markPad || m.Over.H != 6+2*markPad {
		t.Fatalf("mark %dx%d, image %dx%d", m.W, m.H, m.Over.W, m.Over.H)
	}
	at := func(x, y int) byte { return m.Over.Pix[(y*m.Over.W+x)*4+3] }
	if at(markPad+5, markPad+3) != 255 || at(markPad-2, markPad+3) == 0 || at(0, 0) != 0 {
		t.Fatal("the picture or its shadow is missing")
	}
}
