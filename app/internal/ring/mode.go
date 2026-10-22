package ring

import (
	"os"
	"strconv"
	"strings"
)

// MiSTer main sizes the Linux framebuffer for its own HDMI mode (width x
// height x 4 bytes): at 720x480, or with direct video, /dev/fb0 holds a
// single 720x480 8888 page, and the overlay needs two to flip without
// tearing. Main writes that mode again whenever it sets a video mode (every
// core load), so Open enlarges it after the core is up and Watch puts it
// back when it shrinks. The core reads the overlay's page by its physical
// address, not through the mode, so the mode's pixel format does not
// matter, only how much memory it maps. Writing the mode clears the
// framebuffer; the app redraws.

var modeFile = "/sys/module/MiSTer_fb/parameters/mode"

const fullMode = "8888 1 1920 1080 7680"

func readMode() string {
	b, err := os.ReadFile(modeFile)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

// modeTooSmall reports whether a MiSTer_fb mode ("format rgb width height
// stride") maps less than the two overlay pages. A mode it cannot read is
// left alone.
func modeTooSmall(mode string) bool {
	return modeTooSmallFor(mode, NPage*pageSize)
}

func modeTooSmallFor(mode string, bytes int) bool {
	f := strings.Fields(mode)
	if len(f) != 5 {
		return false
	}
	var v [5]int
	for i, s := range f {
		n, err := strconv.Atoi(s)
		if err != nil {
			return false
		}
		v[i] = n
	}
	return v[3]*v[4] < bytes
}

// enlargeMode writes the 1920x1080 mode when the current one maps less than
// the pages, and returns the mode it replaced ("" when it wrote nothing).
func enlargeMode() (string, error) {
	return enlargeModeFor(NPage * pageSize)
}

func enlargeModeFor(bytes int) (string, error) {
	m := readMode()
	if !modeTooSmallFor(m, bytes) {
		return "", nil
	}
	return m, os.WriteFile(modeFile, []byte(fullMode+"\n"), 0)
}

// keepMapped puts back a framebuffer mode that maps less than the pages
// and returns the mode now in place.
func keepMapped(logf func(string, ...any), mode string) string {
	return keepMappedFor(logf, mode, NPage*pageSize)
}

func keepMappedFor(logf func(string, ...any), mode string, bytes int) string {
	from, err := enlargeModeFor(bytes)
	if err != nil {
		logf("watch: framebuffer mode %q maps less than two overlay pages and could not be changed: %v", from, err)
		return mode
	}
	if from == "" {
		return mode
	}
	now := readMode()
	logf("watch: framebuffer mode %q maps less than two overlay pages; set it to %q", from, now)
	return now
}
