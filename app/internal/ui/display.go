package ui

import (
	"encoding/json"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
)

// DisplayCheck is what the launcher read in the MiSTer INI for this core
// once it was loaded (MISTERZINE_PLEX_DISPLAY, from display_check in
// manager.py). It is empty when the app was started some other way.
type DisplayCheck struct {
	INI     string `json:"ini"`      // the file main read
	VRR     string `json:"vrr"`      // "forced", "auto", "off" or "unknown"
	VRRMode int    `json:"vrr_mode"` // 2 FreeSync, 3 VESA VRR, 4 MiSTer VRR
}

// ParseDisplayCheck reads the launcher's variable; anything unreadable is
// an empty check, which shows nothing.
func ParseDisplayCheck(s string) DisplayCheck {
	var d DisplayCheck
	if s != "" && json.Unmarshal([]byte(s), &d) != nil {
		return DisplayCheck{}
	}
	return d
}

// VRRForced is whether MiSTer turns variable refresh rate on for Plex
// whatever the display reports. With the automatic setting it depends on the
// display, which the launcher cannot see, so Options stay quiet about it.
func (d DisplayCheck) VRRForced() bool { return d.VRR == "forced" }

// VRRNote is Options > HDMI VRR: why forced variable refresh rate is worth
// turning off for Plex, and the INI line that does it.
type VRRNote struct{ app *App }

func NewVRRNote(a *App) *VRRNote { return &VRRNote{app: a} }

func (n *VRRNote) Back() bool {
	n.app.Pop()
	return true
}

func (n *VRRNote) Key(ev input.Event, now time.Time) {
	if !ev.Release && !ev.Repeat && ev.Key == input.Enter {
		n.app.Pop()
	}
}

func (n *VRRNote) Draw(c *gfx.Canvas, now time.Time) bool {
	c.Fill(0, 0, c.W, c.H, gfx.Bg)
	a := n.app
	f := a.F
	a.text(c, MenuX, SafeY, f.Title, gfx.White, "HDMI VRR")
	y := 92
	para := func(s string, col gfx.Color) {
		for _, line := range wrapAll(f.Body, s, MenuWidth) {
			a.text(c, MenuX, y, f.Body, col, line)
			y += 26
		}
		y += 10
	}
	kind := map[int]string{2: " (FreeSync)", 3: " (VESA VRR)", 4: " (MiSTer VRR)"}[a.Display.VRRMode]
	file := a.Display.INI
	if file == "" {
		file = "your MiSTer INI"
	}
	para("Variable refresh rate"+kind+" is forced on in "+file+".", gfx.GreyHi)
	para("Plex always runs at 59.94 Hz, so VRR adds nothing here, and it has been reported to make 24 fps films stutter.", gfx.GreyHi)
	// At the end of the file the lines come after [MiSTer], so they win; a
	// second section of the same name is fine.
	para("To turn it off for Plex only, add these lines at the end of that file, then start Plex again from the MiSTer menu:", gfx.GreyHi)
	for _, line := range []string{"[MisterZine Plex Core]", "vrr_mode=0"} {
		a.text(c, MenuX, y, f.Big, gfx.Amber, line)
		y += 36
	}
	y += 14
	para("Press OK to go back.", gfx.White)
	a.text(c, MenuX, SafeBottom-24, f.SmallBold, gfx.Purple, patreonAddress)
	return false
}
