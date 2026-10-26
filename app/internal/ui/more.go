package ui

import (
	"strconv"
	"strings"
	"time"

	"plexcrt/internal/gfx"
)

// The rows More adds after Crop, Downmix boost and Subtitle size (each
// stepped in place with Left and Right, stepMore): two
// settings that are the app's own (Options shows them too) and a read-only
// page of what is playing.
const (
	moreAutoplay = "Autoplay next"
	moreBitrate  = "Video bitrate"
	moreInfo     = "Playback info"
)

// isDirect reports whether the stream is the file itself (no transcode).
func (p *Playing) isDirect() bool { return p.direct != nil && p.direct() }

// autoplayMatters reports whether the playback is an episode, or has a next
// item in its queue: only then is there something to run on to.
func (p *Playing) autoplayMatters() bool {
	return p.item.Type == "episode" || (p.queue != nil && p.idx+1 < len(p.queue))
}

func onOff(on bool) string {
	if on {
		return "On"
	}
	return "Off"
}

// bitrateValue is the Video bitrate row's value for ladder step i. A direct
// stream does not use the cap, so the row says so; the step is still saved.
func (p *Playing) bitrateValue(i int) string {
	v := Bitrates[i].Label
	if p.isDirect() {
		v += ", direct"
	}
	return v
}

// moreRows appends the new rows to More's; step is the Video bitrate step
// picked and not yet applied (-1 for the one saved).
func (p *Playing) moreRows(items, vals []string, step int) ([]string, []string) {
	if p.autoplayMatters() {
		items = append(items, moreAutoplay)
		vals = append(vals, onOff(!p.app.Cfg.NoAutoplay))
	}
	if step < 0 {
		step = p.app.Cfg.bitrateIndex()
	}
	items = append(items, moreBitrate, moreInfo)
	vals = append(vals, p.bitrateValue(step), "")
	return items, vals
}

// reopenMore puts More up again with its cursor on the row named row.
func (p *Playing) reopenMore(row string) {
	p.openMore()
	l := p.list
	for i, item := range l.items {
		if item == row {
			l.cur = i
		}
	}
	p.showList(l)
}

// boostLabel is the Downmix boost row's value: the step's name, or the
// percentage of a gain set by hand.
func (p *Playing) boostLabel() string {
	if i := p.app.Cfg.audioBoostIndex(); i >= 0 {
		return AudioBoosts[i].Label
	}
	return itoa(p.app.Cfg.AudioBoostValue()) + "%"
}

// moreRange is where More row i's value stands among its choices (i of n;
// -1 for a value they do not offer), and whether Left and Right step it.
// Every row but Playback info does, in place: there is no page behind it.
func (p *Playing) moreRange(l *listMode, i int) (at, n int, ok bool) {
	if l.kind != "More" || i < 0 || i >= len(l.items) {
		return 0, 0, false
	}
	cfg := p.app.Cfg
	switch l.items[i] {
	case "Crop":
		return p.app.crop.index(), len(Crops), true
	case "Downmix boost":
		return cfg.audioBoostIndex(), len(AudioBoosts), true
	case "Subtitle size":
		return cfg.subtitleSizeIndex(), len(SubtitleSizes), true
	case moreAutoplay:
		return btoi(!cfg.NoAutoplay), 2, true // Off, On
	case moreBitrate:
		if l.step >= 0 {
			return l.step, len(Bitrates), true
		}
		return cfg.bitrateIndex(), len(Bitrates), true
	}
	return 0, 0, false
}

// stepMore steps the value of the More row under the cursor for Left or
// Right, and reports whether that row has one to step. The values stop at
// their ends, as Options' do, and take effect at once: Crop for this
// playback, Downmix boost and Subtitle size saved (the boost sent to the
// worker, the size used from the next subtitle painted), Autoplay next
// saved. Video bitrate only picks a step: OK applies it, as it restarts
// a transcode.
func (p *Playing) stepMore(l *listMode, right bool) bool {
	at, n, ok := p.moreRange(l, l.cur)
	if !ok {
		return false
	}
	d := 1
	if !right {
		d = -1
	}
	to := max(0, min(n-1, at+d))
	if to == at {
		return true // at the end: nothing to do
	}
	cfg := p.app.Cfg
	switch l.items[l.cur] {
	case "Crop":
		crop := Crops[to].Mode
		p.app.setCrop(crop)
		p.send("aspect " + itoa(crop.analogAspect()))
		l.vals[l.cur] = p.app.crop.Label()
	case "Downmix boost":
		if p.saveMore(l, func() { cfg.AudioBoost = AudioBoosts[to].Value }) {
			p.send("boost " + itoa(cfg.AudioBoostValue()))
		}
		l.vals[l.cur] = p.boostLabel()
	case "Subtitle size":
		// the drawn subtitles take the size at their next paint and the
		// stream goes on as it is; one the server burns in takes it when
		// the transcode starts over from here
		if p.saveMore(l, func() { cfg.SubtitleSize = SubtitleSizes[to].Value }) && p.burnsSubtitle() {
			p.seekTo_(p.pos)
		}
		l.vals[l.cur] = SubtitleSizes[cfg.subtitleSizeIndex()].Label
	case moreAutoplay:
		p.saveMore(l, func() { cfg.NoAutoplay = to == 0 })
		l.vals[l.cur] = onOff(!cfg.NoAutoplay)
	case moreBitrate:
		l.step = to
		l.vals[l.cur] = p.bitrateValue(l.step)
	}
	l.loaded = false
	return true
}

// saveMore applies change to the settings and saves them, as Options
// does; a failed save puts the settings back and says so in the title.
func (p *Playing) saveMore(l *listMode, change func()) bool {
	old := p.app.Cfg.snapshot()
	change()
	if err := p.app.Cfg.Save(); err != nil {
		*p.app.Cfg = old
		l.hint = "Save failed"
		l.loaded = false
		return false
	}
	l.hint = ""
	l.loaded = false
	return true
}

// toggleAutoplay turns Autoplay next on or off (OK on its row) and saves
// it: the end of this playback reads it (App.runsOn).
func (p *Playing) toggleAutoplay(l *listMode) {
	cfg := p.app.Cfg
	p.saveMore(l, func() { cfg.NoAutoplay = !cfg.NoAutoplay })
	l.vals[l.cur] = onOff(!cfg.NoAutoplay)
}

// applyBitrate saves the Video bitrate step Left and Right picked (it is
// the app's setting, as in Options) and, for a transcode, restarts the
// stream at the same position with the new cap. A direct stream does not
// use the cap: it is only saved for the next playback.
func (p *Playing) applyBitrate(l *listMode) {
	if l.step < 0 || l.step == p.app.Cfg.bitrateIndex() {
		p.list = nil // nothing changed
		return
	}
	old := p.app.Cfg.snapshot()
	p.app.Cfg.Bitrate = Bitrates[l.step].Kbps
	if err := p.app.Cfg.Save(); err != nil {
		*p.app.Cfg = old
		l.hint = "Save failed"
		l.loaded = false
		return
	}
	p.list = nil
	if p.isDirect() {
		return
	}
	target := max(0, min(p.pos, p.dur-6))
	now := time.Now()
	p.seekAt, p.seekTo, p.pos = now, target, target
	p.bufferStart, p.bufferEnd = 0, 0
	p.send("bitrate " + itoa(p.app.Cfg.BitrateKbps()) + " " + ftoa(target))
	p.dirty = true
}

// InfoRefresh is how often an open Playback info takes the worker's status.
const InfoRefresh = time.Second

// openInfo puts up Playback info: read only, nothing to choose.
func (p *Playing) openInfo(now time.Time) {
	l := &listMode{kind: moreInfo, set: -1, step: -1}
	l.items, l.vals = p.infoRows()
	l.infoAt = now
	p.showList(l)
}

// refreshInfo remakes an open Playback info's values once a second.
func (p *Playing) refreshInfo(now time.Time) {
	l := p.list
	if l == nil || l.kind != moreInfo || now.Sub(l.infoAt) < InfoRefresh {
		return
	}
	l.infoAt = now
	items, vals := p.infoRows()
	if strings.Join(items, "\n") == strings.Join(l.items, "\n") && strings.Join(vals, "\n") == strings.Join(l.vals, "\n") {
		return
	}
	l.items, l.vals = items, vals
	l.cur = min(l.cur, len(items)-1)
	l.window()
	l.loaded = false
	p.dirty = true
}

// infoRows are Playback info's rows: only what the app knows, from the
// session (direct or transcode), the item's tracks, the settings and the
// worker's status file (jfplay.c writes its fields). A field the worker
// has not reported is left out. No titles: only the track names the Audio
// and Subs lists show anyway.
func (p *Playing) infoRows() (items, vals []string) {
	add := func(item, val string) {
		if val != "" {
			items, vals = append(items, item), append(vals, val)
		}
	}
	st := p.statusVals
	num := func(k string) int {
		n, _ := strconv.Atoi(strings.TrimSpace(st[k]))
		return n
	}
	videoMode, audioMode := "", ""
	if p.streamModes != nil {
		videoMode, audioMode = p.streamModes()
	} else if p.direct != nil && p.isDirect() {
		videoMode, audioMode = "Original", "Original"
	}
	withMode := func(value, mode string) string {
		if value == "" || mode == "" {
			return value
		}
		return value + " · " + mode
	}
	if w, h := num("width"), num("height"); w > 0 && h > 0 {
		add("Video", withMode("H.264", videoMode))
		add("Resolution", itoa(w)+"x"+itoa(h))
	}
	if fps, err := strconv.ParseFloat(st["fps"], 64); err == nil && fps > 0 {
		add("Frame rate", strings.TrimRight(strings.TrimRight(strconv.FormatFloat(fps, 'f', 3, 64), "0"), ".")+" fps")
	}
	rate := func(key string) string {
		bps, err := strconv.ParseInt(st[key], 10, 64)
		if err != nil || bps <= 0 {
			return ""
		}
		return strconv.FormatFloat(float64(bps)/1e6, 'f', 1, 64) + " Mbps"
	}
	add("Video now", rate("video_bitrate_recent"))
	add("Video avg", rate("video_bitrate_average"))
	if rate("video_bitrate_average") == "" {
		add("Video nominal", rate("video_bitrate"))
	}
	if videoMode == "Transcoded" {
		add("Bitrate cap", strconv.FormatFloat(float64(p.app.Cfg.BitrateKbps())/1000, 'f', -1, 64)+" Mbps")
	}
	audio := strings.ToUpper(strings.TrimSpace(st["audio_codec"]))
	if audio == "NONE" {
		audio = ""
	}
	ch := num("audio_channels_in")
	if ch <= 0 {
		for _, a := range p.item.Audio {
			if a.Selected {
				ch = a.Channels
			}
		}
	}
	if layout := channelLayout(ch); layout != "" {
		audio = strings.TrimSpace(audio + " " + layout)
	}
	add("Audio", withMode(audio, audioMode))
	if ch > 2 {
		// jfplay mixes surround down to the stereo output with the boost
		add("Downmix", "Stereo")
		if b := num("audio_boost"); b > 0 {
			add("Boost", itoa(b)+"%")
		}
	}
	sub := "Off"
	for _, s := range p.item.Subs {
		if s.Selected {
			sub = s.Title
		}
	}
	add("Subtitles", sub)
	if w, h := num("output_width"), num("output_height"); w > 0 && h > 0 {
		scan := "p"
		if num("output_interlaced") != 0 {
			scan = "i"
		}
		add("Core output", itoa(w)+"x"+itoa(h)+scan)
	}
	if p.conversionReason != nil {
		add("Conversion", p.conversionReason())
	}
	if st != nil {
		add("Late frames", itoa(num("late")))
		add("Decode errors", itoa(num("errors")))
		if r := strings.TrimSpace(st["refused"]); r != "" && !strings.HasPrefix(r, "0") {
			add("Refused", r)
		}
		if ms, ok := st["buffered_ms"]; ok {
			n, _ := strconv.Atoi(strings.TrimSpace(ms))
			add("Sound buffer", strconv.FormatFloat(float64(n)/1000, 'f', 1, 64)+" s")
		}
	}
	return items, vals
}

// channelLayout names a channel count the way players do.
func channelLayout(ch int) string {
	switch {
	case ch <= 0:
		return ""
	case ch == 1:
		return "mono"
	case ch == 2:
		return "stereo"
	case ch == 6:
		return "5.1"
	case ch == 8:
		return "7.1"
	}
	return itoa(ch) + " ch"
}

// The arrows beside a value that Left and Right step: small solid
// triangles listArrowW wide and listArrowH tall, listArrowGap from the
// value either side (the VCR look sets its font's < and > instead).
const (
	listArrowW   = 5
	listArrowH   = 9
	listArrowGap = 6
	listArrowsW  = 2 * (listArrowW + listArrowGap) // the room both take
)

// arrowState is how one of a row's arrows is drawn.
type arrowState int

const (
	arrowNone arrowState = iota // no arrow
	arrowEnd                    // the value is at that end: nothing more that way
	arrowOn                     // a press that way changes the value
)

// listArrows is how row i draws its arrows: none on a row Left and Right
// do not step. The rule at an end of the range: on the cursor row the
// arrow that way is drawn dim, on any other row it is left out, so the
// cursor row always shows the pair and the rest show only where a press
// would go.
func (p *Playing) listArrows(l *listMode, i int) (left, right arrowState) {
	at, n, ok := p.moreRange(l, i)
	if !ok {
		return arrowNone, arrowNone
	}
	end := arrowNone
	if i == l.cur {
		end = arrowEnd
	}
	left, right = arrowOn, arrowOn
	if at == 0 {
		left = end
	}
	if at == n-1 {
		right = end
	}
	return left, right
}

// arrowsMove reports whether a cursor move from row from changes how the
// arrows draw: the cursor row's are brighter, so a steppable row it left
// or reached is drawn again.
func (p *Playing) arrowsMove(l *listMode, from int) bool {
	if from == l.cur {
		return false
	}
	_, _, a := p.moreRange(l, from)
	_, _, b := p.moreRange(l, l.cur)
	return a || b
}

// arrowColour is an arrow's colour in the standard look: GreyHi on the
// cursor row and GreyLo, as the value, on the others; dim (GreyLo) at an
// end. ok is false for no arrow.
func arrowColour(s arrowState, cursor bool) (gfx.Color, bool) {
	switch {
	case s == arrowNone:
		return 0, false
	case s == arrowOn && cursor:
		return gfx.GreyHi, true
	}
	return gfx.GreyLo, true
}

// listArrow draws a solid triangle listArrowW x listArrowH with its left
// edge at x, centred on row cy, its point to the left or the right.
func listArrow(c *gfx.Canvas, x, cy int, left bool, col gfx.Color) {
	for j := range listArrowW { // j columns from the point
		cx := x + j
		if !left {
			cx = x + listArrowW - 1 - j
		}
		h := 2*j + 1 // 1, 3, 5, 7, 9: listArrowH at the base
		c.Fill(cx, cy-h/2, 1, h, col)
	}
}

// fitter is a font as the list rows use it: the Body font or the VCR
// look's pixel font.
type fitter interface {
	Width(s string) int
	Fit(s string, maxW int) string
}

// listRowText is a list row's item and value as drawn from x, each cut to
// its room: the value gives way to the item (a long Playback info value is
// cut, not the item), and arrowsW is the room the value's arrows take
// beside it (0 for none).
func listRowText(f fitter, x int, item, val string, arrowsW int) (string, string) {
	if val == "" && arrowsW == 0 {
		return f.Fit(item, listItemW(x, 0)), ""
	}
	val = f.Fit(val, listValW(x, f.Width(item))-arrowsW)
	return f.Fit(item, listItemW(x, f.Width(val)+arrowsW)), val
}
