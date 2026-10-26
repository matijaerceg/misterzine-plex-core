package ui

import (
	"plexcrt/internal/gfx"
	"strconv"
	"strings"
	"time"
)

// Original metadata is kept separate from the worker's received-stream facts.
// In particular, a transcoder response can describe its planned audio output.
type playbackSource struct{ Video, Audio string }

func (s *Session) PlaybackSource() playbackSource {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.sourceInfo
}

func codecName(codec string) string {
	switch strings.ToLower(strings.TrimSpace(codec)) {
	case "h264", "avc":
		return "H.264"
	case "hevc", "h265":
		return "HEVC"
	case "dca", "dts":
		return "DTS"
	case "none", "":
		return ""
	}
	return strings.ToUpper(strings.TrimSpace(codec))
}

func videoDescription(codec string, w, h int) string {
	text := codecName(codec)
	if w > 0 && h > 0 {
		text = strings.TrimSpace(text + " " + itoa(w) + "x" + itoa(h))
	}
	return text
}

func audioDescription(codec string, channels int) string {
	return strings.TrimSpace(codecName(codec) + " " + channelLayout(channels))
}

func streamChange(source, received, mode string) string {
	if received == "" {
		return ""
	}
	if mode == "Transcoded" && source != "" && source != received {
		return source + " -> " + received
	}
	return received
}

// Explanations are deliberately curated: never display server URLs, raw policy
// strings or a guessed cause. Unknown reasons remain explicitly unspecified.
func conversionExplanation(reason string) string {
	r := strings.ToLower(reason)
	switch {
	case strings.Contains(r, "subtitle"):
		return "Subtitles are drawn into the picture"
	case strings.Contains(r, "audio channels"), strings.Contains(r, "channel audio"):
		return "Surround audio needs stereo"
	case strings.Contains(r, "audio codec"), strings.HasPrefix(r, "audio ") && r != "audio compatibility":
		return "Audio format is not supported directly"
	case r == "audio compatibility":
		return "Audio format or channels need conversion"
	case strings.Contains(r, "bitrate"):
		return "Bitrate exceeds the playback limit"
	case strings.Contains(r, "resolution"), strings.HasPrefix(r, "size "):
		return "Picture is too large for direct playback"
	case strings.Contains(r, "frames/s"), strings.Contains(r, "block rate"), strings.Contains(r, "framerate"):
		return "Frame rate is too high at this resolution"
	case strings.Contains(r, "bit depth"):
		return "Video colour depth needs conversion"
	case strings.Contains(r, "profile"), strings.Contains(r, "level"), r == "cavlc":
		return "Video encoding exceeds decoder support"
	case strings.Contains(r, "codec"):
		return "Video format needs H.264 conversion"
	case strings.HasPrefix(r, "container"):
		return "File container is not supported directly"
	case r == "decoder compatibility":
		return "Original video failed the decoder check"
	default:
		return "Server required it; reason not supplied"
	}
}

// infoRows is bounded to fifteen rows, including up to two explanations. Keep
// source, server conversion and local output distinct, with diagnostics last.
func (p *Playing) infoRows() (items, vals []string) {
	add := func(label, value string) {
		if value != "" {
			items = append(items, label)
			vals = append(vals, value)
		}
	}
	st := p.statusVals
	number := func(key string) int { n, _ := strconv.Atoi(strings.TrimSpace(st[key])); return n }
	vm, am := "", ""
	if p.streamModes != nil {
		vm, am = p.streamModes()
	} else if p.direct != nil && p.isDirect() {
		vm, am = "Original", "Original"
	}
	source := playbackSource{}
	if p.sourceInfo != nil {
		source = p.sourceInfo()
	}
	mode := func(v string) string {
		switch v {
		case "Original":
			return "Unchanged (no server conversion)"
		case "Transcoded":
			return "Converted by server"
		}
		return "Server conversion unknown"
	}
	if number("width") > 0 && number("height") > 0 {
		add("Video", mode(vm))
		add("Video format", streamChange(source.Video, videoDescription("h264", number("width"), number("height")), vm))
	}
	if fps, err := strconv.ParseFloat(st["fps"], 64); err == nil && fps > 0 {
		add("Frame rate", strconv.FormatFloat(fps, 'f', -1, 64)+" fps")
	}
	rate := func(key string) string {
		n, err := strconv.ParseInt(st[key], 10, 64)
		if err != nil || n <= 0 {
			return ""
		}
		return strconv.FormatFloat(float64(n)/1e6, 'f', 1, 64)
	}
	now, avg := rate("video_bitrate_recent"), rate("video_bitrate_average")
	bits := ""
	if now != "" {
		bits = "Now " + now
	}
	if avg != "" {
		if bits != "" {
			bits += " / "
		}
		bits += "Avg " + avg
	}
	if bits != "" {
		bits += " Mbps"
	} else if n := rate("video_bitrate"); n != "" {
		bits = n + " Mbps (nominal)"
	}
	if vm == "Transcoded" {
		if bits != "" {
			bits = strings.TrimSuffix(bits, " Mbps") + " / "
		}
		bits += "Limit " + strconv.FormatFloat(float64(p.app.Cfg.BitrateKbps())/1000, 'f', -1, 64) + " Mbps"
	}
	add("Video bitrate", bits)
	audio := audioDescription(st["audio_codec"], number("audio_channels_in"))
	if audio != "" {
		add("Audio", mode(am))
		add("Audio format", streamChange(source.Audio, audio, am))
		output := "Stereo PCM"
		if number("audio_channels_in") > 2 {
			output += " / Surround mix"
			if n := number("audio_boost"); n > 100 {
				output += " / Boost " + itoa(n) + "%"
			}
		}
		add("Sound output", output)
	}
	if vm == "Transcoded" || am == "Transcoded" {
		reason := ""
		if p.conversionReason != nil {
			reason = p.conversionReason()
		}
		explanations := []string{}
		for _, part := range strings.Split(reason, "; ") {
			explanation := conversionExplanation(part)
			found := false
			for _, v := range explanations {
				if v == explanation {
					found = true
				}
			}
			if !found {
				explanations = append(explanations, explanation)
			}
		}
		for i, v := range explanations {
			if i == 2 {
				break
			}
			label := "Conversion reason"
			if i > 0 {
				label = "Also"
			}
			add(label, v)
		}
	}
	sub := "Off"
	for _, s := range p.item.Subs {
		if s.Selected {
			sub = s.Title
		}
	}
	add("Subtitles", sub)
	if w, h := number("output_width"), number("output_height"); w > 0 && h > 0 {
		scan := "p"
		if number("output_interlaced") != 0 {
			scan = "i"
		}
		output := itoa(w) + "x" + itoa(h) + scan
		if v, ok := st["deflicker"]; ok && (v == "0" || v == "1") {
			state := "Off"
			if v == "1" {
				state = "On"
			}
			output += " / De-flicker " + state
		}
		add("MiSTer output", output)
	}
	if st != nil {
		// Totals are labelled honestly; they are not a live health verdict.
		if _, ok := st["late"]; ok {
			add("Recent issues", p.infoRecent)
			add("Playback totals", itoa(number("late"))+" late frames / "+itoa(number("errors"))+" decode errors")
		}
		if r := strings.TrimSpace(st["refused"]); r != "" && !strings.HasPrefix(r, "0") {
			add("Decoder rejected", r)
		}
		if _, ok := st["buffered_ms"]; ok {
			add("Sound buffer", strconv.FormatFloat(float64(number("buffered_ms"))/1000, 'f', 1, 64)+" seconds ready")
		}
	}
	return
}

// The info panel uses the safe right edge and fixed columns. Values update once
// a second without moving their labels. Both looks fit fifteen rows at 480i.
func (p *Playing) drawInfo(c *gfx.Canvas, base int) {
	l := p.list
	x := p.safeX() + 8
	right := l.width() - OsdListPad
	vx := x + 184
	bg := gfx.Bg
	if p.app.vcr() {
		bg = vcrBlue
	}
	c.Fill(0, 0, c.W, c.H, bg)
	f := p.app.F.SmallBold
	labelColour, valueColour := gfx.Grey, gfx.GreyHi
	if p.app.vcr() {
		labelColour, valueColour = vcrText, vcrLo
	}
	if base == 0 {
		c.Text(x, 10, p.app.F.Body, gfx.White, "Playback info")
	}
	for i, label := range l.items {
		y := l.top() + i*l.rowH() - base
		if y < 0 || y+l.rowH() > c.H {
			continue
		}
		c.Text(x, y, f, labelColour, f.Fit(label, vx-x-12))
		c.Text(vx, y, f, valueColour, f.Fit(l.vals[i], right-vx))
	}
}

// Compare adjacent visible-panel samples. The first sample (and a worker counter
// reset) establishes a baseline rather than pretending historical errors are new.
func (p *Playing) sampleInfoHealth(now time.Time) {
	late, e1 := strconv.Atoi(p.statusVals["late"])
	errors, e2 := strconv.Atoi(p.statusVals["errors"])
	if e1 != nil || e2 != nil {
		p.infoSampleAt = time.Time{}
		p.infoRecent = ""
		return
	}
	p.infoRecent = "Measuring..."
	if !p.infoSampleAt.IsZero() && now.After(p.infoSampleAt) && late >= p.infoLate && errors >= p.infoErrors {
		p.infoRecent = itoa(late-p.infoLate) + " late / " + itoa(errors-p.infoErrors) + " errors in " + strconv.FormatFloat(now.Sub(p.infoSampleAt).Seconds(), 'f', 1, 64) + "s"
	}
	p.infoLate, p.infoErrors, p.infoSampleAt = late, errors, now
}
