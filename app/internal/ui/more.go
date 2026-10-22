package ui

import (
	"strconv"
	"strings"
	"time"
)

// The rows More adds after Crop, Downmix boost and Subtitle size: two
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

// stepMore steps the value of the More row under the cursor for Left or
// Right, and reports whether that row has one to step.
func (p *Playing) stepMore(l *listMode, right bool) bool {
	if l.kind != "More" || l.cur >= len(l.items) {
		return false
	}
	switch l.items[l.cur] {
	case moreAutoplay:
		p.toggleAutoplay(l)
		return true
	case moreBitrate:
		step := l.step
		if step < 0 {
			step = p.app.Cfg.bitrateIndex()
		}
		if right {
			step++
		} else {
			step--
		}
		l.step = max(0, min(len(Bitrates)-1, step))
		l.vals[l.cur] = p.bitrateValue(l.step)
		l.loaded = false
		return true
	}
	return false
}

// toggleAutoplay turns Autoplay next on or off and saves it, as Options
// does: the end of this playback reads it (App.runsOn).
func (p *Playing) toggleAutoplay(l *listMode) {
	old := p.app.Cfg.snapshot()
	p.app.Cfg.NoAutoplay = !p.app.Cfg.NoAutoplay
	if err := p.app.Cfg.Save(); err != nil {
		*p.app.Cfg = old
		l.hint = "Save failed"
	} else {
		l.hint = ""
	}
	l.vals[l.cur] = onOff(!p.app.Cfg.NoAutoplay)
	l.loaded = false
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
	direct := p.isDirect()
	if p.direct != nil {
		add("Source", map[bool]string{true: "Direct play", false: "Transcode"}[direct])
	}
	if w, h := num("width"), num("height"); w > 0 && h > 0 {
		// the core decodes H.264 only: a direct stream is H.264 or is
		// refused, and every transcode is made H.264
		add("Video", itoa(w)+"x"+itoa(h)+" H.264")
	}
	if fps, err := strconv.ParseFloat(st["fps"], 64); err == nil && fps > 0 {
		add("Frame rate", strings.TrimRight(strings.TrimRight(strconv.FormatFloat(fps, 'f', 3, 64), "0"), ".")+" fps")
	}
	bitrate := ""
	if bps, err := strconv.ParseInt(st["video_bitrate"], 10, 64); err == nil && bps > 0 {
		bitrate = strconv.FormatFloat(float64(bps)/1e6, 'f', 1, 64) + " Mbps"
	}
	add("Bitrate", bitrate)
	if !direct {
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
	add("Audio", audio)
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
	pos := clock(int(p.pos))
	if p.dur > 0 {
		pos += " / " + clock(int(p.dur))
	}
	add("Position", pos)
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
