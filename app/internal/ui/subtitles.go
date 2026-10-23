package ui

import (
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"

	"plexcrt/internal/gfx"
	"plexcrt/internal/plex"
)

// Subtitles. A text track (plex.Stream.Text: SRT, ASS, WebVTT ...) is
// fetched from the server as SRT and drawn by the app on the overlay, over
// the video, at the size chosen in Options (Subtitle size). It needs no
// transcode, and choosing one, turning it off or changing its size does
// not restart the stream. Picture tracks (PGS, VobSub, DVB) are burned
// into a transcode by the Plex server, and so is a text track in a script
// the glyph atlases lack (Cyrillic, Greek, CJK ...): the server takes the
// size with the request, so changing it starts that transcode over.

// subtitleCue is one subtitle: its lines, plain and folded to the atlases'
// ASCII, from start to end in item seconds.
type subtitleCue struct {
	start, end float64
	lines      []string
}

// subtitleTrack is a track's cues in start order.
type subtitleTrack []subtitleCue

// subtitleLookBack is how many cues before the time at hand at looks at
// for one still showing: a long cue (a caption) under shorter ones.
const subtitleLookBack = 16

// parseSRT reads an SRT file: cues of a timing line ("00:01:02,500 -->
// 00:01:04,000") and the text lines under it, up to a blank line. Numbers,
// stray lines and cues without text or time are skipped.
func parseSRT(data []byte) subtitleTrack {
	s := strings.TrimPrefix(string(data), "\xef\xbb\xbf")
	s = strings.ReplaceAll(strings.ReplaceAll(s, "\r\n", "\n"), "\r", "\n")
	lines := strings.Split(s, "\n")
	var t subtitleTrack
	for i := 0; i < len(lines); i++ {
		a, b, ok := srtTiming(lines[i])
		if !ok {
			continue
		}
		var text []string
		for i+1 < len(lines) && strings.TrimSpace(lines[i+1]) != "" {
			if _, _, next := srtTiming(lines[i+1]); next {
				break // a cue without its blank line: the next one's timing
			}
			if i+2 < len(lines) && isDigits(lines[i+1]) {
				if _, _, next := srtTiming(lines[i+2]); next {
					break // the next cue's number
				}
			}
			i++
			text = append(text, lines[i])
		}
		if cue := cleanCue(text); len(cue) > 0 && b > a {
			t = append(t, subtitleCue{start: a, end: b, lines: cue})
		}
	}
	sort.SliceStable(t, func(i, j int) bool { return t[i].start < t[j].start })
	return t
}

// srtTiming reads a timing line; what follows the end time (a position
// some files give) is ignored.
func srtTiming(line string) (a, b float64, ok bool) {
	l, r, found := strings.Cut(line, "-->")
	if !found {
		return 0, 0, false
	}
	end := strings.Fields(r)
	if len(end) == 0 {
		return 0, 0, false
	}
	a, okA := srtTime(strings.TrimSpace(l))
	b, okB := srtTime(end[0])
	return a, b, okA && okB
}

// srtTime reads h:mm:ss,mmm (or with a full stop, or without the hours)
// as seconds.
func srtTime(s string) (float64, bool) {
	parts := strings.Split(strings.Replace(s, ",", ".", 1), ":")
	if len(parts) < 2 || len(parts) > 3 {
		return 0, false
	}
	sec := 0
	for _, p := range parts[:len(parts)-1] {
		if !isDigits(p) {
			return 0, false
		}
		n, _ := strconv.Atoi(p)
		sec = sec*60 + n
	}
	last := parts[len(parts)-1]
	whole, frac, _ := strings.Cut(last, ".")
	if !isDigits(whole) || frac != "" && !isDigits(frac) {
		return 0, false
	}
	f, err := strconv.ParseFloat(last, 64)
	if err != nil {
		return 0, false
	}
	return float64(sec)*60 + f, true
}

func isDigits(s string) bool {
	s = strings.TrimSpace(s)
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// subtitleEntities are the HTML entities subtitle files use.
var subtitleEntities = strings.NewReplacer("&amp;", "&", "&lt;", "<", "&gt;", ">", "&quot;", `"`,
	"&apos;", "'", "&#39;", "'", "&nbsp;", " ")

// cleanCue makes a cue's text plain lines: markup dropped (<i>, <font
// color=...>, ASS overrides such as {\an8}), ASS line breaks and hard
// spaces taken as such, entities spelled out, and the text folded to the
// atlases' ASCII. Empty lines go.
func cleanCue(text []string) []string {
	s := strings.Join(text, "\n")
	s = strings.NewReplacer(`\N`, "\n", `\n`, "\n", `\h`, " ").Replace(s)
	var b strings.Builder
	var until byte // the end of the markup being skipped, 0 outside one
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case until != 0:
			if c == until {
				until = 0
			} else if c == '\n' && until == '>' {
				until = 0 // a "<" that was not a tag after all
				b.WriteByte(c)
			}
		case c == '{' && strings.HasPrefix(s[i+1:], `\`) && strings.IndexByte(s[i:], '}') > 0:
			until = '}'
		case c == '<' && i+1 < len(s) && (s[i+1] == '/' || isASCIILetter(s[i+1])) && strings.IndexByte(s[i:], '>') > 0:
			until = '>'
		default:
			b.WriteByte(c)
		}
	}
	var out []string
	for _, l := range strings.Split(subtitleEntities.Replace(b.String()), "\n") {
		if l = strings.Join(strings.Fields(plex.Fold(l)), " "); l != "" {
			out = append(out, l)
		}
	}
	return out
}

func isASCIILetter(c byte) bool { return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' }

// at is the text showing at sec: the lines of every cue on screen then,
// the earlier cue's first (two speakers), nil for none. One cue alone is
// its own lines, not a copy: this runs every field.
func (t subtitleTrack) at(sec float64) []string {
	n := sort.Search(len(t), func(i int) bool { return t[i].start > sec })
	var lines []string
	one := -1
	for i := max(0, n-subtitleLookBack); i < n; i++ {
		if t[i].end <= sec {
			continue
		}
		if one < 0 && lines == nil {
			one = i
			continue
		}
		if lines == nil {
			lines = append(lines, t[one].lines...)
		}
		lines = append(lines, t[i].lines...)
	}
	if lines == nil && one >= 0 {
		l := t[one].lines
		return l[:len(l):len(l)]
	}
	return lines
}

// subtitleDrawable reports whether a track is written in letters the
// atlases have, once folded: one whose letters more than now and then fold
// to nothing (Cyrillic, Greek, Arabic, CJK ...) is left to the server to
// burn in.
func subtitleDrawable(data []byte) bool {
	letters, missing := 0, 0
	for _, r := range string(data) {
		if !unicode.IsLetter(r) {
			continue
		}
		letters++
		if r > 0x7E && plex.Fold(string(r)) == " " {
			missing++
		}
	}
	return missing*20 <= letters // at most one letter in twenty
}

// subtitleMemory is the text tracks found undrawable this run, by item and
// stream: the server burns them in, from their next start on without the
// app fetching them first.
type subtitleMemory struct {
	mu      sync.Mutex
	undrawn map[subtitleStream]bool
}

// subtitleStream is a track of an item: a key that is looked up every
// field without building a string.
type subtitleStream struct{ item, stream string }

// drawsSubtitle reports whether the app draws subtitle track s of an item
// itself (Player.DrawsSubtitle): a text track not found undrawable. The
// server burns any other selected track into a transcode.
func (a *App) drawsSubtitle(ratingKey string, s plex.Stream) bool {
	if !s.Text {
		return false
	}
	a.subtitles.mu.Lock()
	defer a.subtitles.mu.Unlock()
	return !a.subtitles.undrawn[subtitleStream{ratingKey, s.ID}]
}

// undrawable remembers a text track the app cannot draw.
func (a *App) undrawable(ratingKey, id string) {
	a.subtitles.mu.Lock()
	defer a.subtitles.mu.Unlock()
	if a.subtitles.undrawn == nil {
		a.subtitles.undrawn = map[subtitleStream]bool{}
	}
	a.subtitles.undrawn[subtitleStream{ratingKey, id}] = true
}

// The drawn subtitles' look.
const (
	// subtitleNormalPx is Normal's type size on the 480-line canvas: about
	// libass's for an SRT burned into a transcode (its default 16 on 288
	// lines is 26 here), a little smaller for the box behind it. Large and
	// Extra large are that much larger (SubtitleSizes).
	subtitleNormalPx = 22
	// subtitleBoxAlpha is the box behind each line: dark enough to read
	// white over a white picture, light enough to see the picture through.
	subtitleBoxAlpha = 160
	// subtitleOutline is the dark ring round the type with the box off, in
	// atlas pixels: 1 at Normal, scaled with the larger sizes.
	subtitleOutline = 1
	// subtitlePadX is the box's room either side of a line at Normal.
	subtitlePadX = 10
	// subtitleMaxLines bounds what one moment shows; lines past it go.
	subtitleMaxLines = 6
	// subtitleLead bounds how far the drawn time runs on from the last
	// position the worker wrote (every 250 ms) while it plays.
	subtitleLead = 500 * time.Millisecond
)

// subtitleFace is the atlas a size (a percentage of Normal) is drawn from
// and the size in pixels it is scaled to: the largest bold atlas not above
// it, so Normal is drawn as it is and only the larger sizes are scaled.
func subtitleFace(size int) (*gfx.Font, int) {
	px := max(1, subtitleNormalPx*size/100)
	f := gfx.Load("bold22")
	if px >= 28 {
		f = gfx.Load("bold28")
	}
	return f, px
}

// subtitleMargin is the gap below the subtitles on a canvas h lines high:
// they sit on the safe area's bottom, clear of the tube's overscan.
func subtitleMargin(h int) int { return h * (480 - SafeBottom) / 480 }

// subtitlePaint is the subtitle panel's storage, kept from one cue to the next
// (a cue at Extra large is about a megabyte of it): the panel and its
// alpha it returns are good until the next draw.
type subtitlePaint struct {
	c, src   gfx.Canvas
	alpha    []byte
	x0s, fxs []int
}

// reuse makes c a clear w x h canvas on the storage it had.
func reuse(c *gfx.Canvas, w, h int) {
	pix := c.Pix[:cap(c.Pix)]
	if len(pix) < w*h*4 {
		pix = make([]byte, w*h*4)
	} else {
		pix = pix[:w*h*4]
		clear(pix)
	}
	*c = gfx.Canvas{W: w, H: h, Pix: pix}
}

// draw paints lines for a w-wide canvas at size (a percentage of Normal),
// on s's storage: white type, the lines wrapped to the safe width, each
// line centred on its own translucent box with box, or, without, ringed by
// a thin dark outline (the look of subtitles burned into the picture). The
// panel is w wide, transparent outside the boxes or outlines.
func (s *subtitlePaint) draw(lines []string, size, w int, box bool) (*gfx.Canvas, []byte) {
	f, px := subtitleFace(size)
	// the scale from the atlas, in 1/256ths
	scale := px * 256 / f.Px
	padX := subtitlePadX * px / subtitleNormalPx
	maxW := max(1, (w-2*SafeX-2*padX)*256/scale)
	var rows []string
	for _, l := range lines {
		rows = append(rows, wrapAll(f, l, maxW)...)
	}
	rows = rows[:min(len(rows), subtitleMaxLines)]
	lineH := f.Height() * scale / 256
	c := &s.c
	reuse(c, w, lineH*len(rows))
	if cap(s.alpha) < w*c.H {
		s.alpha = make([]byte, w*c.H)
	} else {
		s.alpha = s.alpha[:w*c.H]
		clear(s.alpha)
	}
	alpha := s.alpha
	const margin = 6 // room in the atlas canvas for a glyph's overhang
	for i, row := range rows {
		tw := f.Width(row)
		src := &s.src
		reuse(src, tw+2*margin, f.Height())
		src.Text(margin, 0, f, gfx.White, row)
		outlineCoverage(src, subtitleOutline, !box)
		boxW := min(w, tw*scale/256+2*padX)
		x0, y0 := (w-boxW)/2, i*lineH
		for y := y0; box && y < y0+lineH; y++ {
			b := alpha[y*w+x0 : y*w+x0+boxW]
			for x := range b {
				b[x] = subtitleBoxAlpha
			}
		}
		if scale == 256 {
			blitCoverage(c, alpha, src, x0+padX-margin, y0, lineH)
		} else {
			s.scaleCoverage(c, alpha, src, x0+padX-margin*scale/256, y0, scale, lineH)
		}
	}
	return c, alpha
}

// outlineCoverage puts the outline's coverage in src's second channel
// (src.Text left it the type's): with on, the type's coverage (the first
// channel) grown by r pixels each way, the most of it within reach;
// without, none.
func outlineCoverage(src *gfx.Canvas, r int, on bool) {
	for y := range src.H {
		for x := range src.W {
			m := byte(0)
			if !on {
				src.Pix[(y*src.W+x)*4+1] = 0
				continue
			}
			for dy := -r; dy <= r; dy++ {
				sy := y + dy
				if sy < 0 || sy >= src.H {
					continue
				}
				for dx := -r; dx <= r; dx++ {
					if sx := x + dx; sx >= 0 && sx < src.W {
						m = max(m, src.Pix[(sy*src.W+sx)*4])
					}
				}
			}
			src.Pix[(y*src.W+x)*4+1] = m
		}
	}
}

// compose lays coverage v of white type, over coverage o of black outline,
// on pixel i of the panel (black at the alpha already there): the alpha
// rises with both, and the grey is what makes the blend come out white
// over black.
func compose(c *gfx.Canvas, alpha []byte, i, v, o int) {
	base := 255 - (255-o)*(255-int(alpha[i]))/255
	a := 255 - (255-v)*(255-base)/255
	grey := byte(min(255, v*255/a))
	alpha[i] = byte(a)
	c.Pix[i*4], c.Pix[i*4+1], c.Pix[i*4+2] = grey, grey, grey
}

// blitCoverage is scaleCoverage at 1:1 (Normal, drawn from its own
// atlas), where the bilinear weights all fall on one source pixel: the
// coverage is the source's as it is.
func blitCoverage(c *gfx.Canvas, alpha []byte, src *gfx.Canvas, x, y, lineH int) {
	for oy := range lineH {
		py := y + oy
		if py < 0 || py >= c.H {
			continue
		}
		in := src.Pix[min(oy, src.H-1)*src.W*4:]
		for ox := range src.W {
			px := x + ox
			if px < 0 || px >= c.W {
				continue
			}
			v, o := int(in[ox*4]), int(in[ox*4+1])
			if v == 0 && o == 0 {
				continue
			}
			compose(c, alpha, py*c.W+px, v, o)
		}
	}
}

// scaleCoverage draws the white-on-black src scaled by scale/256 (lineH
// rows of it) into c from x, y, bilinear, as white over the black already
// there at the alpha already there: the type's coverage raises the alpha,
// and the colour is what makes the blend come out as white over the box.
func (s *subtitlePaint) scaleCoverage(c *gfx.Canvas, alpha []byte, src *gfx.Canvas, x, y, scale, lineH int) {
	sw := src.W * scale / 256
	// for each output column, the source column to its left and the weight
	// (of 256) of the one to its right
	if cap(s.x0s) < sw {
		s.x0s, s.fxs = make([]int, sw), make([]int, sw)
	}
	x0s, fxs := s.x0s[:sw], s.fxs[:sw]
	for ox := range sw {
		p := max(0, (2*ox+1)*256*256/(2*scale)-128) // the source position, in 256ths
		x0s[ox], fxs[ox] = min(p>>8, src.W-1), p&255
	}
	// the bilinear coverage of channel ch (0 the type, 1 the outline)
	cov := func(sx0, sx1, sy0, sy1, fx, fy, ch int) int {
		at := func(sx, sy int) int { return int(src.Pix[(sy*src.W+sx)*4+ch]) }
		top := at(sx0, sy0)*(256-fx) + at(sx1, sy0)*fx
		bottom := at(sx0, sy1)*(256-fx) + at(sx1, sy1)*fx
		return (top*(256-fy) + bottom*fy) >> 16
	}
	for oy := range lineH {
		py := y + oy
		if py < 0 || py >= c.H {
			continue
		}
		p := max(0, (2*oy+1)*256*256/(2*scale)-128)
		sy0, fy := min(p>>8, src.H-1), p&255
		sy1 := min(sy0+1, src.H-1)
		for ox := range sw {
			px := x + ox
			if px < 0 || px >= c.W {
				continue
			}
			sx0, fx := x0s[ox], fxs[ox]
			sx1 := min(sx0+1, src.W-1)
			v := cov(sx0, sx1, sy0, sy1, fx, fy, 0)
			o := cov(sx0, sx1, sy0, sy1, fx, fy, 1)
			if v == 0 && o == 0 {
				continue
			}
			compose(c, alpha, py*c.W+px, v, o)
		}
	}
}

// subtitleFetch is a fetched track, for the fetch (gen) that asked.
type subtitleFetch struct {
	gen  int
	id   string
	data []byte
	err  error
}

// syncSubtitles keeps the drawn track in step with the item's selection:
// a newly selected text track the app draws is fetched off-thread (Tick
// takes the answer); anything else drops the cues. It waits for the item's
// media part when the item came without one (its metadata brings it).
func (p *Playing) syncSubtitles() {
	want := ""
	for _, s := range p.item.Subs {
		if s.Selected && p.app.drawsSubtitle(p.item.RatingKey, s) {
			want = s.ID
		}
	}
	if want == p.subsFor || want != "" && (p.app.Plex == nil || p.item.PartID == "") {
		return
	}
	p.subsFor, p.subs = want, nil
	p.subsGen++
	if want == "" {
		return
	}
	if p.subsDone == nil {
		p.subsDone = make(chan subtitleFetch, 8)
	}
	client, item, source, gen, done := p.app.Plex, p.item.RatingKey, p.item.PartID, p.subsGen, p.subsDone
	go func() {
		data, err := client.SubtitleText(bg(), item, source, want)
		select {
		case done <- subtitleFetch{gen: gen, id: want, data: data, err: err}:
		default: // only stale answers can fill it
		}
	}()
}

// takeSubtitles applies the fetches that have come back: the cues of the
// track still wanted. A track in letters the atlases lack is remembered
// and the stream restarts with the server burning it in.
func (p *Playing) takeSubtitles() {
	for {
		select {
		case r := <-p.subsDone:
			if r.gen != p.subsGen {
				continue
			}
			if r.err != nil {
				p.app.Log.Printf("subtitles: %v", r.err)
				continue
			}
			if !subtitleDrawable(r.data) {
				p.app.Log.Printf("subtitles: track %s is in letters the app cannot draw; the server burns it in", r.id)
				p.app.undrawable(p.item.RatingKey, r.id)
				p.subsFor = ""
				p.restartTracks()
				continue
			}
			p.subs = parseSRT(r.data)
		default:
			return
		}
	}
}

// subtitleLines is what the drawn track shows now, nil for nothing: not
// over the wait dots, nor while a seek or a restart is on its way (the
// picture is still the old place's). The time runs on from the worker's
// last report while it plays, so a cue comes and goes on its frame rather
// than up to a report late.
func (p *Playing) subtitleLines(now time.Time) []string {
	if len(p.subs) == 0 || p.wait != nil || p.ending || !p.seekAt.IsZero() {
		return nil
	}
	t := p.pos
	if !p.paused && !p.posAt.IsZero() {
		t += min(max(now.Sub(p.posAt), 0), subtitleLead).Seconds()
	}
	return p.subs.at(t)
}

// showSubtitle puts the subtitle panel up for lines, or takes it down when
// there are none. It runs when nothing else is on the overlay.
func (p *Playing) showSubtitle(osd OSD, lines []string) {
	if len(lines) == 0 {
		if isSubtitleKey(p.last) {
			p.painter.hide(osd)
			p.last = ""
		}
		return
	}
	size, box := p.app.Cfg.SubtitleSizeValue(), p.app.Cfg.SubtitleBox
	if isSubtitleKey(p.last) && size == p.subSize && box == p.subBox && slices.Equal(lines, p.subLines) {
		return // up already: no key to build every field
	}
	key := "sub|" + itoa(size) + "|"
	if box {
		key += "box|"
	}
	key += strings.Join(lines, "\n")
	p.subSize, p.subBox, p.subLines = size, box, lines
	if key == p.last {
		return
	}
	p.last = key
	c, alpha := p.subPaint.draw(lines, size, p.canvasWidth(), box) // painter.show copies it
	y := max(0, p.canvasHeight()-subtitleMargin(p.canvasHeight())-c.H)
	p.painter.show(osd, 0, y, c, alpha)
}

// isSubtitleKey reports whether what the overlay last showed is the
// subtitle panel: it coming and going is not something Back waits for.
func isSubtitleKey(last string) bool { return strings.HasPrefix(last, "sub|") }
