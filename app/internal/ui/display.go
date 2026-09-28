package ui

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
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
	// HDMIHz is the rate HDMI runs at whatever the core does; 0 when it
	// follows the core or main takes the display's own mode.
	HDMIHz     float64  `json:"hdmi_hz"`
	VideoMode  string   `json:"video_mode"`
	DVI        bool     `json:"dvi"`        // dvi_mode=1: no sound over HDMI
	Overridden []string `json:"overridden"` // Plex settings a later [MiSTer] section changes
	SectionIn  string   `json:"section_in"` // another INI with the Plex section this one lacks
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

// RefreshOff is whether HDMI runs at a fixed rate far enough from Plex's
// 59.94 Hz to drop or repeat frames often. 60 Hz repeats one every 17 s.
func (d DisplayCheck) RefreshOff() bool { return d.HDMIHz > 0 && (d.HDMIHz < 58.5 || d.HDMIHz > 61.5) }

// A noteBlock is a paragraph of a warning's note, or a line to put in the
// INI, drawn large so it can be copied from the screen.
type noteBlock struct {
	text string
	ini  bool
}

// A displayWarning is one Options row about the INI and the note it opens.
type displayWarning struct {
	label, value, title string
	blocks              []noteBlock
}

const restartPlex = ", then start Plex again from the MiSTer menu"

// addLines is the advice all fixes share: at the end of the file the lines
// come after [MiSTer], so they win, and a second section of the same name is
// fine.
func addLines(why string, lines ...string) []noteBlock {
	blocks := []noteBlock{{text: why + " add these lines at the end of that file" + restartPlex + ":"}, {text: "[MisterZine Plex Core]", ini: true}}
	for _, l := range lines {
		blocks = append(blocks, noteBlock{text: l, ini: true})
	}
	return blocks
}

// Warnings are the Options rows for INI settings that hurt Plex, in the
// order they show.
func (d DisplayCheck) Warnings() []displayWarning {
	file := d.INI
	if file == "" {
		file = "your MiSTer INI"
	}
	var ws []displayWarning
	if d.VRRForced() {
		kind := map[int]string{2: " (FreeSync)", 3: " (VESA VRR)", 4: " (MiSTer VRR)"}[d.VRRMode]
		ws = append(ws, displayWarning{label: "HDMI VRR", value: "Forced on", title: "HDMI VRR", blocks: append([]noteBlock{
			{text: "Variable refresh rate" + kind + " is forced on in " + file + "."},
			{text: "Plex always runs at 59.94 Hz, so VRR adds nothing here, and it has been reported to make 24 fps films stutter."},
		}, addLines("To turn it off for Plex only,", "vrr_mode=0")...)})
	}
	if d.RefreshOff() {
		hz := strconv.FormatFloat(d.HDMIHz, 'f', -1, 64) + " Hz"
		judder := "Plex runs at 59.94 Hz, so frames are dropped or repeated and motion judders"
		if d.VRR == "auto" {
			judder += ", unless your display uses VRR"
		}
		mode := ""
		if d.VideoMode != "" {
			mode = " (video_mode=" + d.VideoMode + ")"
		}
		blocks := append([]noteBlock{
			{text: "HDMI runs at " + hz + " in " + file + mode + "."},
			{text: judder + "."},
		}, addLines("For Plex only,", "video_mode=8")...)
		ws = append(ws, displayWarning{label: "HDMI refresh", value: hz, title: "HDMI refresh",
			blocks: append(blocks, noteBlock{text: "video_mode=8 is 1920x1080 at 60 Hz. Use 0 for 1280x720."})})
	}
	if d.DVI {
		ws = append(ws, displayWarning{label: "HDMI sound", value: "Off (DVI mode)", title: "HDMI sound", blocks: append([]noteBlock{
			{text: "DVI mode is on in " + file + " (dvi_mode=1), so HDMI carries no sound. Sound still plays from the analog audio output."},
		}, addLines("For sound over HDMI on a TV or HDMI monitor,", "dvi_mode=0")...)})
	}
	if len(d.Overridden) > 0 {
		keys := d.Overridden
		if len(keys) > 4 {
			keys = append(append([]string{}, keys[:4]...), fmt.Sprintf("and %d more", len(d.Overridden)-4))
		}
		ws = append(ws, displayWarning{label: "Plex INI section", value: "Overridden", title: "Plex INI section", blocks: []noteBlock{
			{text: "A [MiSTer] section further down " + file + " changes what the Plex section sets: " + strings.Join(keys, ", ") + "."},
			{text: "MiSTer reads the file from top to bottom and later values win. Move the [MisterZine Plex Core] section to the end of the file" + restartPlex + "."},
		}})
	}
	if d.SectionIn != "" {
		ws = append(ws, displayWarning{label: "Plex INI section", value: "In another INI", title: "Plex INI section", blocks: []noteBlock{
			{text: "The [MisterZine Plex Core] section is in " + d.SectionIn + ", but MiSTer read " + file + " for Plex, so those settings are not used."},
			{text: "Copy the section to the end of " + file + restartPlex + "."},
		}})
	}
	return ws
}

// DisplayNote is the screen a warning row opens: what the setting does to
// Plex and how to change it.
type DisplayNote struct {
	app *App
	w   displayWarning
}

func NewDisplayNote(a *App, w displayWarning) *DisplayNote { return &DisplayNote{app: a, w: w} }

func (n *DisplayNote) Back() bool {
	n.app.Pop()
	return true
}

func (n *DisplayNote) Key(ev input.Event, now time.Time) {
	if !ev.Release && !ev.Repeat && ev.Key == input.Enter {
		n.app.Pop()
	}
}

func (n *DisplayNote) Draw(c *gfx.Canvas, now time.Time) bool {
	c.Fill(0, 0, c.W, c.H, gfx.Bg)
	a := n.app
	f := a.F
	a.text(c, MenuX, SafeY, f.Title, gfx.White, n.w.title)
	y := 92
	for i, b := range n.w.blocks {
		if b.ini {
			a.text(c, MenuX, y, f.Big, gfx.Amber, f.Big.Fit(b.text, MenuWidth))
			y += 36
			if i+1 == len(n.w.blocks) || !n.w.blocks[i+1].ini {
				y += 14
			}
			continue
		}
		for _, line := range wrapAll(f.Body, b.text, MenuWidth) {
			a.text(c, MenuX, y, f.Body, gfx.GreyHi, line)
			y += 26
		}
		y += 10
	}
	a.text(c, MenuX, y, f.Body, gfx.White, "Press OK to go back.")
	return false
}
