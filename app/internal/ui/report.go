package ui

import (
	"bufio"
	"bytes"
	"context"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
)

// Report is Options > Send a report: it says what a report holds, sends it
// on OK and shows the code the service filed it under. The report itself is
// the manager's, so the Scripts entry and this screen send the same thing.
type Report struct {
	app     *App
	sending bool
	sent    bool
	code    string
	problem string
	saved   string
}

func NewReport(a *App) *Report { return &Report{app: a} }

// reportOutcome is what `manager.py report` prints: the saved path, then
// either the code or why the upload failed.
type reportOutcome struct {
	saved, code, problem string
}

func parseReportOutput(out []byte) reportOutcome {
	var r reportOutcome
	sc := bufio.NewScanner(bytes.NewReader(out))
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		switch {
		case strings.HasPrefix(line, "saved: "):
			r.saved = strings.TrimSpace(line[7:])
		case strings.HasPrefix(line, "code: "):
			r.code = strings.TrimSpace(line[6:])
		case strings.HasPrefix(line, "error: "):
			r.problem = strings.TrimSpace(line[7:])
		}
	}
	if r.code == "" && r.problem == "" {
		r.problem = "The report could not be made. Run MisterZine-Plex-Diagnostics from MiSTer Menu instead."
	}
	return r
}

func (r *Report) send() {
	root := r.app.betaDir()
	if root == "" || r.sending {
		return
	}
	r.sending = true
	a := r.app
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, "python3", filepath.Join(root, "manager.py"), "report", "--card", filepath.Dir(root))
		out, err := cmd.Output()
		outcome := parseReportOutput(out)
		if err != nil && outcome.code == "" && outcome.problem == "" {
			outcome.problem = "The report could not be made. Run MisterZine-Plex-Diagnostics from MiSTer Menu instead."
		}
		a.Later(func() {
			r.sending = false
			r.sent = true
			r.saved, r.code, r.problem = outcome.saved, outcome.code, outcome.problem
			if r.code != "" {
				a.Log.Printf("report sent as %s", r.code)
			} else {
				a.Log.Printf("report not sent: %s", r.problem)
			}
		})
	}()
}

func (r *Report) Back() bool {
	if r.sending {
		return true // the upload gives up within a minute; nothing to do until then
	}
	r.app.Pop()
	return true
}

func (r *Report) Key(ev input.Event, now time.Time) {
	if ev.Release || ev.Repeat || ev.Key != input.Enter {
		return
	}
	if r.sent {
		r.app.Pop()
		return
	}
	r.send()
}

// Draw paints the explanation, then the outcome. The code uses the large
// font: it is what the player copies into a post.
func (r *Report) Draw(c *gfx.Canvas, now time.Time) bool {
	c.Fill(0, 0, c.W, c.H, gfx.Bg)
	a := r.app
	f := a.F
	a.text(c, MenuX, SafeY, f.Title, gfx.White, "Send a report")
	y := 92
	para := func(s string, col gfx.Color) {
		for _, line := range wrapAll(f.Body, s, MenuWidth) {
			a.text(c, MenuX, y, f.Body, col, line)
			y += 26
		}
		y += 10
	}
	switch {
	case r.sending:
		// Later wakes the loop when the upload ends; no need to redraw meanwhile.
		para("Sending...", gfx.Amber)
	case r.sent && r.code != "":
		para("Sent. Post this code where you asked for help:", gfx.GreyHi)
		a.text(c, MenuX, y+8, f.Big, gfx.Amber, r.code)
		y += 60
		para("The report is deleted after 30 days. Nothing about you or your MiSTer is kept beyond what the report says.", gfx.GreyLo)
		para("Press OK to go back.", gfx.GreyHi)
	case r.sent:
		para("Not sent. "+r.problem, gfx.Amber)
		if r.saved != "" {
			para("A copy is saved on the card as "+cardRelative(r.saved)+". You can send that file instead.", gfx.GreyHi)
		}
		para("Press OK to go back.", gfx.GreyHi)
	default:
		para("A report describes this MiSTer to the developer: the app and launcher logs, the video settings MisterZine reads from the MiSTer INI, which MiSTer main is running, and the framebuffer state.", gfx.GreyHi)
		para("It can name media titles and playback details. Sign-in tokens, the server address and account files are never included.", gfx.GreyHi)
		para("Press OK to send it, or Back to cancel.", gfx.White)
	}
	a.text(c, MenuX, SafeBottom-24, f.SmallBold, gfx.Purple, patreonAddress)
	return false
}

// cardRelative shortens a path under the card root to what a player sees in
// a file browser: /media/fat/misterzine-plex/report.txt -> misterzine-plex/report.txt.
func cardRelative(path string) string {
	parts := strings.Split(filepath.ToSlash(path), "/")
	if len(parts) >= 2 {
		return strings.Join(parts[len(parts)-2:], "/")
	}
	return path
}
