package ui

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/ring"
)

// DisplayCheck is what the launcher read in the MiSTer INI for this core
// once it was loaded (MISTERZINE_PLEX_DISPLAY, from display_check in
// manager.py). It is empty when the app was started some other way.
type DisplayCheck struct {
	INI     string `json:"ini"`      // the file main read
	VRR     string `json:"vrr"`      // "forced", "auto", "off" or "unknown"
	VRRMode int    `json:"vrr_mode"` // 2 FreeSync, 3 VESA VRR, 4 MiSTer VRR
	// HDMIHz is the rate HDMI runs at whatever the core does; 0 when it
	// follows the core or that cannot be told. HDMIMode is the setting that
	// picks it, "video_mode=9" say.
	HDMIHz      float64  `json:"hdmi_hz"`
	HDMIMode    string   `json:"hdmi_mode"`
	VsyncAdjust int      `json:"vsync_adjust"`
	DVI         bool     `json:"dvi"`        // dvi_mode=1: no sound over HDMI
	Overridden  []string `json:"overridden"` // settings of this core's section a later [MiSTer] section changes
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

// CoreOutput is the refresh the core menu picks, read from the core's status
// as Options show: PAL for the 576-line Output Modes, which run at 50 Hz (the
// others at 59.94; Native HDMI playback runs exactly 24/30/60 fps sources at
// 60, and 50 Hz needs Refresh Rate Match), and Match when Refresh Rate Match
// lets playback switch to the other family. The zero value is the
// core's default, 480i60 without matching; it stands in when the core does
// not report its settings.
type CoreOutput struct {
	PAL, Match bool
}

// coreOutput reads CoreOutput from the running core.
func (a *App) coreOutput() CoreOutput {
	r, ok := a.Out.(*ring.Ring)
	if !ok {
		return CoreOutput{}
	}
	st, ok := r.Status()
	if !ok || !st.DisplayKnown {
		return CoreOutput{}
	}
	return CoreOutput{PAL: st.DisplayProfile == 2 || st.DisplayProfile == 3, Match: st.DisplayMatch}
}

// Hz is the rate of the core's Output Mode.
func (o CoreOutput) Hz() float64 {
	if o.PAL {
		return 50
	}
	return 59.94
}

// RefreshOff is whether a fixed HDMI rate drops or repeats the core's
// pictures often: it is far from the Output Mode's rate, or Refresh Rate
// Match can move playback to a rate HDMI does not follow.
func (d DisplayCheck) RefreshOff(o CoreOutput) bool {
	return d.HDMIHz > 0 && (o.Match || d.modeOff(o))
}

// modeOff is whether the fixed HDMI rate is far from the Output Mode's own.
// 60 Hz against 59.94 repeats one picture every 17 s, which is fine.
func (d DisplayCheck) modeOff(o CoreOutput) bool {
	return d.HDMIHz < o.Hz()-1.5 || d.HDMIHz > o.Hz()+1.5
}

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

// iniSection is this core's own INI section: main matches section names
// against the core's name (CONF_STR; CORE_NAME in manager.py).
const iniSection = "[MisterZine Plex Core]"

// MiSTer reads the INI as it loads the core, which starting the app does.
const restartApp = ", then start Plex again from the MiSTer menu"

// addLines is the advice all fixes share: at the end of the file the lines
// come after [MiSTer], so they win, and a second section of the same name is
// fine.
func addLines(why string, lines ...string) []noteBlock {
	blocks := []noteBlock{{text: why + " add these lines at the end of that file" + restartApp + ":"}, {text: iniSection, ini: true}}
	for _, l := range lines {
		blocks = append(blocks, noteBlock{text: l, ini: true})
	}
	return blocks
}

// Warnings are the Options rows for INI settings that hurt playback with the
// core's output o, in the order they show. Each names a problem in the INI
// MiSTer loaded; a section for this core kept only in another INI is not one
// (CRT and HDMI INIs are often set up that way), so only reports mention it.
// Forced VRR is not one either: HDMI then follows the core's 50 or 60 Hz, as
// it does with vsync_adjust.
func (d DisplayCheck) Warnings(o CoreOutput) []displayWarning {
	file := d.INI
	if file == "" {
		file = "your MiSTer INI"
	}
	var ws []displayWarning
	if d.RefreshOff(o) {
		hz := strconv.FormatFloat(d.HDMIHz, 'f', -1, 64) + " Hz"
		vrr := ""
		if d.VRR == "auto" {
			vrr = ", unless your display uses VRR"
		}
		mode := ""
		if d.HDMIMode != "" {
			mode = " (" + d.HDMIMode + ")"
		}
		blocks := []noteBlock{{text: "HDMI runs at " + hz + " in " + file + mode + "."}}
		// Turning matching off helps only when HDMI suits the Output Mode.
		matchOff := ""
		if !d.modeOff(o) {
			matchOff = "set Refresh Rate Match to Off in the core menu"
		}
		switch {
		case o.Match && d.VsyncAdjust == 0:
			blocks = append(blocks, noteBlock{text: "Refresh Rate Match in the core menu lets playback switch between 50 and 60 Hz. At a rate other than HDMI's, frames are dropped or repeated and motion judders" + vrr + "."})
			blocks = append(blocks, addLines("To have HDMI follow the core,", "vsync_adjust=1")...)
			if matchOff != "" {
				blocks = append(blocks, noteBlock{text: "Or " + matchOff + "."})
			}
		case o.Match:
			blocks = append(blocks,
				noteBlock{text: "Refresh Rate Match in the core menu lets playback switch between 50 and 60 Hz. At a rate other than HDMI's, frames are dropped or repeated and motion judders" + vrr + "."},
				noteBlock{text: "vsync_adjust is on, but MiSTer cannot follow the core: refresh_min or refresh_max leaves out its rate, video_mode_pal is set without video_mode_ntsc, or a custom video mode needs a pixel clock MiSTer cannot make. Change those settings" + restartApp + "."})
			if matchOff != "" {
				blocks = append(blocks, noteBlock{text: "Or " + matchOff + "."})
			}
		default:
			blocks = append(blocks, noteBlock{text: "The core's Output Mode runs at " + strconv.FormatFloat(o.Hz(), 'f', -1, 64) + " Hz, so frames are dropped or repeated and motion judders" + vrr + "."})
			// With vsync_adjust off, video_mode alone picks the mode: whatever
			// kept vsync_adjust from following the core no longer matters.
			lines, about := []string{"video_mode=8"}, "video_mode=8 is 1920x1080 at 60 Hz. Use 0 for 1280x720."
			if o.PAL {
				lines, about = []string{"video_mode=9"}, "video_mode=9 is 1920x1080 at 50 Hz. Use 7 for 1280x720."
			}
			if d.VsyncAdjust != 0 {
				lines = append(lines, "vsync_adjust=0")
			}
			blocks = append(append(blocks, addLines("For this core only,", lines...)...), noteBlock{text: about})
		}
		ws = append(ws, displayWarning{label: "HDMI refresh", value: hz, title: "HDMI refresh", blocks: blocks})
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
		ws = append(ws, displayWarning{label: "INI section", value: "Overridden", title: "INI section", blocks: []noteBlock{
			{text: "A [MiSTer] section further down " + file + " changes what the " + iniSection + " section sets: " + strings.Join(keys, ", ") + "."},
			{text: "MiSTer reads the file from top to bottom and later values win. Move the " + iniSection + " section to the end of the file" + restartApp + "."},
		}})
	}
	return ws
}

// DisplayNote is the screen a warning row opens: what the setting does to
// playback and how to change it.
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
