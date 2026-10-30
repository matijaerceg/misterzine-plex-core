package ring

import (
	"bytes"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// Composite / S-Video colour: pinning the subcarrier through MiSTer main's yc.txt.
//
// With MiSTer.ini vga_mode=svideo or cvbs, main (video.cpp set_yc_mode) sets the
// framework's Y/C encoder's 40-bit phase increment to
//
//	PHASE_INC = f_sc / CLK_VIDEO * 2^40
//
// with CLK_VIDEO estimated from one measurement of the core's video, taken again
// after every mode change or OSD Reset. The estimate wanders a little (80.99 MHz
// measured), so the colour can come up wrong or crawl. A yc.txt line keyed
// "<core name>_<fps %.1f>[i][s|m]" replaces the estimate. This core's CLK_VIDEO
// is a fixed 81 MHz on every raster (h264/vid_pll.sv, 50 x 81 / 5 / 10,
// integer-N), so the exact increment depends only on the subcarrier:
//
//	NTSC                        3.579545   MHz / 81 MHz * 2^40 = 48589522835
//	PAL, and PAL-60 (ntsc_mode=1) 4.43361875 MHz / 81 MHz * 2^40 = 60182905787
//	PAL-M (ntsc_mode=2)          3.575611   MHz / 81 MHz * 2^40 = 48536121863
//
// (truncated, as main truncates its own estimate). The rates main measures
// (h264/sync_gen.sv): 59.94 Hz rasters print 59.9 (480p, 240p at 59.91 Hz,
// 480i per field), the 60.00 Hz standard prints 60.0, the 625-line rasters print
// 50.0 (576p, 288p at 49.99 Hz, 576i per field). Main treats a rate below 55 Hz as
// PAL and adds no s/m suffix there. Main reads yc.txt only when it loads a core
// (video_init) and keeps at most 20 lines starting with the core's name, so the
// lines must be there before the core loads, and there are 14 of them.
const (
	ycNTSC = 48589522835
	ycPAL  = 60182905787
	ycPALM = 48536121863
)

var ycModes = []struct {
	suffix string
	inc    int64
}{
	{"59.9", ycNTSC}, {"59.9i", ycNTSC}, {"60.0", ycNTSC}, {"60.0i", ycNTSC},
	{"50.0", ycPAL}, {"50.0i", ycPAL},
	{"59.9s", ycPAL}, {"59.9is", ycPAL}, {"60.0s", ycPAL}, {"60.0is", ycPAL},
	{"59.9m", ycPALM}, {"59.9im", ycPALM}, {"60.0m", ycPALM}, {"60.0im", ycPALM},
}

// ycFile is main's yc.txt (it opens "yc.txt" relative to the SD card's root).
var ycFile = "/media/fat/yc.txt"

// YCLines are the yc.txt lines for a core named core, in file order.
func YCLines(core string) []string {
	out := make([]string, len(ycModes))
	for i, m := range ycModes {
		out[i] = core + "_" + m.suffix + "=" + strconv.FormatInt(m.inc, 10)
	}
	return out
}

// ycKeys are the keys main would read from a yc.txt: per line, CR dropped, the
// text from ';' on ignored, leading blanks skipped, then everything up to '='.
func ycKeys(b []byte) map[string]bool {
	keys := map[string]bool{}
	for _, line := range strings.Split(string(b), "\n") {
		line = strings.ReplaceAll(line, "\r", "")
		line, _, _ = strings.Cut(line, ";")
		line = strings.TrimLeft(line, " \t")
		if key, _, ok := strings.Cut(line, "="); ok && key != "" {
			keys[strings.ToLower(key)] = true
		}
	}
	return keys
}

// EnsureYC appends to path the lines of YCLines(core) whose keys it lacks,
// creating the file if needed, and reports how many it added. The existing
// content is left byte for byte (a key already there, whatever its value, is
// the user's or upstream's and wins). The card's directory must exist.
func EnsureYC(path, core string) (int, error) {
	if _, err := os.Stat(filepath.Dir(path)); err != nil {
		return 0, err
	}
	b, err := os.ReadFile(path)
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return 0, err
	}
	have := ycKeys(b)
	eol := "\n"
	if bytes.Contains(b, []byte("\r\n")) {
		eol = "\r\n"
	}
	var add strings.Builder
	n := 0
	for _, line := range YCLines(core) {
		key, _, _ := strings.Cut(line, "=")
		if !have[strings.ToLower(key)] {
			add.WriteString(line + eol)
			n++
		}
	}
	if n == 0 {
		return 0, nil
	}
	head := ""
	if len(b) > 0 && b[len(b)-1] != '\n' {
		head = eol
	}
	head += "; " + core + ": composite/S-Video colour for its fixed 81 MHz video clock" + eol
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o644)
	if err != nil {
		return 0, err
	}
	if _, err = f.WriteString(head + add.String()); err == nil {
		err = f.Sync()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return 0, err
	}
	return n, nil
}

// PinYC makes sure MiSTer main's yc.txt holds this app's lines, before the core
// is loaded. It never fails the launch: a missing or read-only card is logged.
func PinYC(logf func(string, ...any)) {
	n, err := EnsureYC(ycFile, AppCoreName)
	switch {
	case err != nil:
		logf("yc.txt not updated (%v); composite/S-Video colour stays on MiSTer's estimate", err)
	case n > 0:
		logf("yc.txt: added %d composite/S-Video colour lines for %s", n, AppCoreName)
	}
}
