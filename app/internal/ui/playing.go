package ui

import (
	"math"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/plex"
	"plexcrt/internal/ring"
)

// Playing drives the overlay while a video plays: OK opens it, Up opens
// it on the timeline, Down and Back step out of it a level at a time (the
// timeline, then the buttons; Down keeps a scrub, Back drops it), Back
// stops once it is closed (not within BackGrace of a Back that cleared
// the screen), left and right seek ten seconds with
// it closed (a slim peek of the bar and the times shows the jump) and move
// along its buttons with it open. It hides itself after a few seconds
// unless paused. Audio and Subtitles
// open a list in the overlay; a skip button appears over an intro or
// credits marker; at the end a countdown runs on to the next episode.
// With nothing else up, a text subtitle track shows along the bottom
// (subtitles.go).
type Playing struct {
	app                    *App
	item                   *plex.Item
	metadata               chan *plex.Item // fetched off-thread, applied by Tick on the UI thread
	queue                  []*plex.Item    // the episodes around it, for Prev and Next
	idx                    int
	send                   func(string)
	direct                 func() bool // whether the stream is the file as stored (Session.Direct); nil is a transcode
	visible                bool
	shownAt                time.Time
	closedAt               time.Time     // when Back last cleared the screen: Back rests for BackGrace
	peekAt                 time.Time     // a closed-overlay seek: the bar and times peek until OsdFlash
	peekH                  int           // the peek's height, from the last compose
	peekFor                time.Duration // how long the peek stays after peekAt; 0 means OsdFlash
	peekDir                int           // the direction of the press that opened a strip scrub
	armed                  bool          // a strip gesture ended: the seek goes after SeekGrace unless more comes
	armAt                  time.Time     // when the last release happened
	peekScrub              bool          // the strip is in its scrub layout: the hold has passed the tap threshold
	static                 *gfx.Canvas   // the panel without the running time, for a cheap repaint each field
	staticFor              string        // what static shows
	alphaDone              bool          // the panel's alpha is drawn: kept until the skip button reuses the plane
	timeY                  int           // where the running time goes on the static panel
	scrubTick              int           // fields into a run: the time is repainted every other one
	focus                  int
	paused                 bool
	pos                    float64
	dur                    float64
	bufferStart, bufferEnd float64   // confirmed contiguous downloaded A/V interval
	statAt                 time.Time // when the launcher's status was last read
	seekAt                 time.Time // a seek was sent: the position jumps once the stream restarts
	seekTo                 float64
	canvas                 *gfx.Canvas
	alpha                  []byte
	dirty                  bool
	last                   string // what the overlay last showed, to skip identical redraws
	// the dot and the bar in the overlay page: set by compose, sent by Tick
	dotX, dotY int
	dotOn      bool
	barX, barY int
	barW       int
	barOn      bool
	btnX, btnW [8]int // button places from the last compose, for the bar
	btnY       int
	pillY      int
	composed   bool
	painter    *painter
	Next       int // set to +1 or -1 when Prev or Next was chosen; the queue continues

	list *listMode // an open audio or subtitle list
	// the worker's last status, as read: More > Playback info shows it
	statusVals map[string]string
	scrub      bool      // the cursor is on the timeline
	scrubTo    float64   // where it points
	held       int       // -1/+1 while left or right is held in scrub mode
	settle     bool      // a run just ended: take the dot's place from the core
	pausedAt   time.Time // when Pause was last pressed
	runVx      int       // the run speed last sent to the core
	heldAt     time.Time // since when
	skip       *plex.Marker
	skipOff    bool // the skip button was dismissed for this marker
	skipAt     time.Time
	// the wait dot (waitdot.go): it runs in the middle while the picture
	// is held up, from the start until the first frame and on any stall
	starting   bool        // no frame from the player (jfplay) yet
	ending     bool        // stopping: no more dot
	frameAt    time.Time   // the last frame, or now while paused: stalls are timed from it
	lastFrame  time.Time   // the last frame the player (jfplay) published
	hushAt     time.Time   // a seek was sent: its wait shows no dot, the strip says where it goes
	wait       *waitDot    // the dots, while they run
	waitSpec   string      // PLEXCRT_WAIT_DOT, for tuning on a set
	waitCanvas *gfx.Canvas // the dots' panel, alone or with the start strip under them
	waitAlpha  []byte
	// the text subtitles the app draws (subtitles.go): the cues of the
	// selected track, the track they (or the fetch on its way) are for, the
	// fetch's generation and its answers, and when the worker wrote the
	// position last (the drawn time runs on from it)
	subs     subtitleTrack
	subsFor  string
	subsGen  int
	subsDone chan subtitleFetch
	posAt    time.Time
	subSize  int      // the size and lines of the subtitle panel last put up
	subLines []string // (last is its key), compared without building one
	subPaint subtitlePaint
	// panelKey's last answer and what it was made from
	panelFor  panelState
	panelText string
	// the VCR look's shake (vcr.go): whether what is up shakes, the fields
	// counted towards the next pattern, and a shake waiting on the painter
	jittering bool
	shakeTick int
	shaking   atomic.Bool
	// the scrub's preview (preview.go): the backend (nil for none), whether
	// it was asked for, the hold that put it up, whether that hold paused
	// the playback, the frame the overlay shows and a count of its changes
	preview   previewer
	pvTried   bool
	pvOn      bool
	pvHold    time.Time
	pvPaused  bool
	pvImg     *gfx.Image
	pvGen     int
	alphaLift int // the lift the panel's alpha was drawn at
}

// panelState is what panelKey describes, kept to compare every field.
type panelState struct {
	item                 *plex.Item
	kind, title, series  string
	season, index, year  int
	pos, focus, scrubTo  int
	paused, scrub        bool
	bufferFrom, bufferTo int
}

type listMode struct {
	kind  string
	hint  string
	items []string
	vals  []string // More: each row's value, on the right
	cur   int
	set   int
	off   int // subtitles: item 0 is Off
	// More: the Video bitrate step Left and Right have picked, applied by
	// OK (-1 for none picked); Playback info: when its values were made
	step   int
	infoAt time.Time
	// The list is drawn once as a tall column in the overlay region and
	// the core is pointed at a window of it: a scroll is a header store.
	// at/to are the window's top in column pixels; base is the column
	// row the upload starts at (a very long list is uploaded in parts).
	at, to   int
	base     int
	loaded   bool
	uploaded int // rows uploaded from base
}

// closePainter stops further overlay work and hides the OSD after playback ends.
func (p *Playing) closePainter(osd OSD) <-chan struct{} {
	if p.preview != nil {
		p.preview.Close()
		p.preview, p.pvImg = nil, nil
	}
	if l, ok := osd.(dotLiner); ok && p.app.vcr() {
		l.SetDotLine(false)
	}
	if j, ok := osd.(jitterer); ok && p.jittering {
		j.SetJitter(false) // the overlay outlives the playback
		p.jittering = false
	}
	if p.painter != nil {
		p.painter.close(osd)
		setOSDCanvasSize(osd, DesignW, DesignH)
		return p.painter.done
	}
	done := make(chan struct{})
	close(done)
	return done
}

// The list column.
const (
	OsdListW    = 512                // column width; 2048-byte rows: the VCR look's longest More row whole
	OsdListH    = SafeBottom - SafeY // the window: from the safe top down
	OsdListTop  = 64                 // the first row, below the title
	OsdListRowH = MenuRowH
	OsdListPad  = 16
)

// height is the column's height in pixels.
func (l *listMode) height() int { return OsdListTop + len(l.items)*OsdListRowH + OsdListPad }

// window aims the scroll so the cursor's row is inside it: scrolling up
// to the first item brings the title back.
func (l *listMode) window() {
	top := l.cur * OsdListRowH // the title above item 0 stays until then
	if l.cur == 0 {
		top = 0
	}
	if top < l.to {
		l.to = top
	}
	if bottom := OsdListTop + (l.cur+1)*OsdListRowH; bottom > l.to+OsdListH {
		l.to = bottom - OsdListH
	}
	l.to = max(0, min(l.to, l.height()-OsdListH))
}

// slide moves the window toward its aim in even steps that ease out:
// 12, 10, 6, 4 pixels over four fields for one row.
func (l *listMode) slide() bool {
	d := l.to - l.at
	if d == 0 {
		return false
	}
	step := (abs(d)/2 + 1) &^ 1
	step = max(4, min(step, 12))
	step = min(step, abs(d))
	if d < 0 {
		step = -step
	}
	l.at += step
	return true
}

func abs(v int) int {
	if v < 0 {
		return -v
	}
	return v
}

const (
	OsdBottom   = 480 - 24 // lift bottom controls and seek strips by 5% for CRT overscan
	OsdControlH = 184
	OsdY        = OsdBottom - OsdControlH
	OsdH        = 480 - OsdY // panel background reaches the output edge
	OsdAlpha    = 200
	OsdHide     = 4 * time.Second
	BackGrace   = 500 * time.Millisecond  // after a Back clears the screen, Back does not stop the playback
	OsdFlash    = 2 * time.Second         // how long a closed-overlay seek shows the bar
	OsdLinger   = 3500 * time.Millisecond // how long the start strip stays over the picture
	OsdBtnGap   = 30
	SkipHold    = 20 * time.Second // the skip button stays this long once playback is in the marker
)

var osdButtons = []string{"-10", "Pause", "+10", "Prev", "Next", "Audio", "Subs", "More"}

// NewPlaying makes the controller for an item; send writes to the launcher's FIFO.
func NewPlaying(app *App, it *plex.Item, queue []*plex.Item, idx int, send func(string)) *Playing {
	p := &Playing{app: app, item: it, queue: queue, idx: idx, send: send, focus: 1}
	p.dur = float64(it.Duration)
	w, h, _ := playbackCanvasSize(app)
	p.canvas = gfx.NewCanvas(w, h)
	p.alpha = make([]byte, w*h)
	p.painter = newPainter(w, h)
	setOSDCanvasSize(app.osd, w, h)
	if l, ok := app.osd.(dotLiner); ok {
		l.SetDotLine(app.vcr()) // the VCR playhead is a line
	}
	if (len(it.Markers) == 0 || it.PartID == "") && app.Plex != nil {
		p.metadata = make(chan *plex.Item, 1)
		client, id := app.Plex, it.RatingKey
		go func() {
			if fresh, err := client.Item(id); err == nil {
				select {
				case p.metadata <- fresh:
				default:
				}
			}
		}()
	}
	return p
}

func (p *Playing) canvasWidth() int {
	if p.canvas == nil || p.canvas.W == 0 {
		return DesignW
	}
	return p.canvas.W
}
func (p *Playing) canvasHeight() int {
	if p.canvas == nil || p.canvas.H == 0 {
		return DesignH
	}
	return p.canvas.H
}
func (p *Playing) safeX() int     { return SafeX }
func (p *Playing) safeW() int     { return max(1, p.canvasWidth()-2*p.safeX()) }
func (p *Playing) menuX() int     { return p.safeX() + 24 }
func (p *Playing) osdBottom() int { return p.canvasHeight() - 24 }
func (p *Playing) osdY() int      { return max(0, p.osdBottom()-OsdControlH) }

// osdHeight extends the translucent panel to the raster edge while the controls stay anchored to their safe-zone baseline.
func (p *Playing) osdHeight() int { return max(1, p.canvasHeight()-p.osdY()) }

// peekStripH is the peek's panel: its rows (peekH, ending at the safe-zone
// baseline) and the panel's background on down to the raster edge, as the
// full panel has it. The rows below peekH are the panel's fill.
func (p *Playing) peekStripH() int {
	return min(p.osdHeight(), p.peekH+p.canvasHeight()-p.osdBottom())
}

// status reads the launcher's position file.
func (p *Playing) status() {
	values, written, err := playerStatus.read("/tmp/jfplay.status")
	if err != nil {
		p.bufferStart, p.bufferEnd = 0, 0
		return
	}
	p.statusVals = values
	pos, err := strconv.ParseFloat(values["position"], 64)
	if err != nil {
		return
	}
	dur, _ := strconv.ParseFloat(values["duration"], 64)
	if values["seek_state"] == "seeking" {
		p.bufferStart, p.bufferEnd = 0, 0
		return // keep the requested playhead while old timestamps are retired.
	}
	if !p.seekAt.IsZero() {
		// until the stream restarts at the new place, show where we asked for
		// a report from before the restart is still the old place; ten-second
		// steps must not be swallowed by it, so the window is tight
		if time.Since(p.seekAt) < 3*time.Second && (pos < p.seekTo-4 || pos > p.seekTo+4) {
			p.bufferStart, p.bufferEnd = 0, 0
			return
		}
		p.seekAt = time.Time{}
	}
	p.pos, p.posAt = pos, written
	if time.Since(p.pausedAt) > 700*time.Millisecond {
		p.paused = values["state"] == "paused"
	}
	p.dur = playingDuration(float64(p.item.Duration), dur, p.direct != nil && p.direct())
	p.bufferStart, p.bufferEnd = bufferedInterval(values, p.dur)
}

// playingDuration is the length the bar shows. A direct stream's is the
// player's when it has one: it reads the file as stored, so it is exact.
// A transcode's is the server's for the item when it has one, else the
// player's: a transcode's container carries the whole item's length again,
// and the player adds the start offset to it, so after a resume or a seek
// the player's is the item's plus the offset.
func playingDuration(item, player float64, direct bool) float64 {
	if direct && player > 0 {
		return player
	}
	if item > 0 {
		return item
	}
	return max(0, player)
}

func (p *Playing) show(now time.Time) {
	p.visible = true
	p.shownAt = now
	p.focus = 1 // Pause, every time
	p.scrub = false
	p.dirty = true
}

// bufferedInterval deliberately ignores PCM-only buffering and invalid/stale
// ranges. Both audio and video must be covered by the worker's reported range.
func bufferedInterval(values map[string]string, duration float64) (float64, float64) {
	if values["buffered_valid"] != "1" {
		return 0, 0
	}
	start, e1 := strconv.ParseFloat(values["buffered_start"], 64)
	end, e2 := strconv.ParseFloat(values["buffered_end"], 64)
	if e1 != nil || e2 != nil || math.IsNaN(start) || math.IsNaN(end) || math.IsInf(start, 0) || math.IsInf(end, 0) || duration <= 0 || math.IsNaN(duration) || math.IsInf(duration, 0) || values["seek_state"] == "seeking" {
		return 0, 0
	}
	start, end = max(0, min(duration, start)), max(0, min(duration, end))
	if end <= start {
		return 0, 0
	}
	return start, end
}

func (p *Playing) bufferPixels() (int, int) {
	if p.dur <= 0 || p.bufferEnd <= p.bufferStart {
		return 0, 0
	}
	return int(float64(p.safeW()) * p.bufferStart / p.dur), int(float64(p.safeW()) * p.bufferEnd / p.dur)
}

func (p *Playing) bufferKey() string {
	a, b := p.bufferPixels()
	return "|buffer:" + itoa(a) + ":" + itoa(b)
}

// ScrubHold is how long a direction is held before the cursor starts to
// run; a shorter press is one ten-second step.
const ScrubHold = 220 * time.Millisecond

// SeekGrace is how long the strip waits after a release for another tap
// or hold before it sends the one seek for the whole gesture.
const SeekGrace = 400 * time.Millisecond

// running reports whether a held direction has passed the tap threshold:
// the core is then moving the dot on its own, field-locked.
func (p *Playing) running(now time.Time) bool {
	return p.scrub && p.held != 0 && now.Sub(p.heldAt) >= ScrubHold && p.dur > 0
}

// runSpeed is the hold's pixels per field: one at first, two after half a
// second (three was too fast to stop on a scene). Whole pixels per field
// keep the motion even on the tube.
func (p *Playing) runSpeed(now time.Time) int {
	hold := now.Sub(p.heldAt).Seconds() - ScrubHold.Seconds()
	return min(1+int(hold*2), 2)
}

// fromX is the film time the dot at frame column x stands for.
func (p *Playing) fromX(x int) float64 {
	return max(0, min(float64(x-p.safeX())*p.dur/float64(p.safeW()), p.dur-6))
}

func (p *Playing) seekBy(d float64) {
	p.seekTo = max(0, min(p.pos+d, p.dur-6))
	p.pos = p.seekTo
	p.seekAt = time.Now()
	p.bufferStart, p.bufferEnd = 0, 0
	p.hushAt = p.seekAt
	p.send("seek " + ftoa(p.seekTo))
	p.dirty = true
}

func (p *Playing) seekTo_(t float64) {
	p.seekTo = max(0, min(t, p.dur-6))
	p.pos = p.seekTo
	p.seekAt = time.Now()
	p.bufferStart, p.bufferEnd = 0, 0
	p.hushAt = p.seekAt
	if p.pvOn || p.pvPaused {
		// the gesture's seek: the preview goes, and a playback the hold
		// paused resumes, before the seek: a seek keeps a pause, and a
		// transcode's restart starts held while the session says paused
		p.endPreview(p.seekAt)
	}
	p.send("seek " + ftoa(p.seekTo))
	p.dirty = true
}

func ftoa(f float64) string { return itoa(int(f)) }

func trackRestartCommand(item *plex.Item, position float64) string {
	audio, subtitle := selectedStreams(item)
	if audio == "" {
		audio = "-1"
	}
	return "tracks " + audio + " " + subtitle + " " + ftoa(position)
}

// marker is the intro or credits marker the position is inside, if any.
func (p *Playing) marker() *plex.Marker {
	for i := range p.item.Markers {
		m := &p.item.Markers[i]
		if p.pos >= m.Start && p.pos < m.End-2 {
			return m
		}
	}
	return nil
}

// skipShown reports whether the skip button is up: over a marker for
// SkipHold from when the playback got into it (its start, or wherever a
// resume or a seek landed in it), until OK or Back, with nothing else on
// screen.
// OK and Back act on it only then. Options can turn it off; the markers
// still show on the timeline.
func (p *Playing) skipShown(now time.Time) bool {
	return p.skip != nil && !p.skipOff && now.Sub(p.skipAt) < SkipHold && !p.visible && !p.peeking(now) &&
		!p.app.Cfg.NoSkipButtons
}

// finished reports whether the playback got into its last 30 seconds
// without Prev or Next: it ran to its end, or was stopped in the closing
// credits. Autoplay needs it to have run to the end as well.
func (p *Playing) finished() bool {
	return p.Next == 0 && p.dur > 0 && p.pos >= p.dur-30
}

func (p *Playing) openList(kind string) {
	streams := p.item.Audio
	off := 0
	if kind == "Subtitles" {
		streams = p.item.Subs
		off = 1
	}
	l := &listMode{kind: kind, off: off, set: -1}
	if off == 1 {
		l.items = append(l.items, "Off")
		l.set = 0
	}
	for i, s := range streams {
		l.items = append(l.items, s.Title)
		if s.Selected {
			l.set = i + off
		}
	}
	l.cur = max(l.set, 0)
	p.showList(l)
}

// listValGap is the least room between a list item and its value.
const listValGap = 16

// listItemW is the width a list item starting at x may take: up to the
// tick's room, and short of a right-aligned value valW wide (0 for none)
// by listValGap, so the two never run into each other.
func listItemW(x, valW int) int {
	w := OsdListW - x - 52
	if valW > 0 {
		w = min(w, OsdListW-OsdListPad-valW-listValGap-x)
	}
	return w
}

// listValW is the room a list value has beside an item itemW wide that
// starts at x: a long value (Playback info's) is cut short, not the item.
func listValW(x, itemW int) int {
	return max(40, OsdListW-OsdListPad-listValGap-x-itemW)
}

// showList puts a list up, opened on its cursor.
func (p *Playing) showList(l *listMode) {
	l.window()
	l.at = l.to // open on the cursor, no slide
	p.list = l
	p.dirty = true
}

// openMore puts up More: every row but Playback info changes its value in
// place with Left and Right (stepMore).
func (p *Playing) openMore() {
	items, vals := []string{}, []string{}
	// every picture: Fill zooms a 4:3 one on a 16:9 raster too
	items = append(items, "Crop", "Downmix boost", "Subtitle size")
	vals = append(vals, p.app.crop.Label(), p.boostLabel(), SubtitleSizes[p.app.Cfg.subtitleSizeIndex()].Label)
	items, vals = p.moreRows(items, vals, -1)
	p.showList(&listMode{kind: "More", items: items, vals: vals, set: -1, step: -1})
}

// choose acts on OK in a list: an audio or subtitle track is applied and
// the stream restarted at the same position; in More, Autoplay next
// toggles, Video bitrate applies its step and Playback info opens (the
// other rows change with Left and Right, so OK leaves them be).
func (p *Playing) choose(l *listMode) {
	switch l.kind {
	case "More":
		switch l.items[l.cur] {
		case moreAutoplay:
			p.toggleAutoplay(l)
		case moreBitrate:
			p.applyBitrate(l)
		case moreInfo:
			p.openInfo(time.Now())
		}
	case moreInfo:
		p.closeList() // read only: OK goes back as Back does
	default:
		p.app.selectStream(p.item, l.kind, l.cur-l.off)
		p.list = nil
		p.restartTracks()
	}
}

// restartTracks asks the session for the selected tracks at the same
// position. The session owns a snapshot of the item, so the IDs travel
// with this command instead of relying on that snapshot to have changed.
// The session restarts the stream unless only a subtitle the app draws
// changed (Session.Send).
func (p *Playing) restartTracks() {
	target := max(0, min(p.pos, p.dur-6))
	now := time.Now()
	p.seekAt, p.hushAt = now, now
	p.seekTo, p.pos = target, target
	p.send(trackRestartCommand(p.item, p.seekTo))
	p.dirty = true
	p.hushAt = time.Time{}
}

// closeList returns from a track list to the controls.
func (p *Playing) closeList() {
	if p.list.kind == moreInfo {
		p.reopenMore(moreInfo)
		return
	}
	p.list = nil
}

// burnsSubtitle reports whether the server burns a subtitle into the
// stream: a selected track the app does not draw.
func (p *Playing) burnsSubtitle() bool {
	for _, s := range p.item.Subs {
		if s.Selected {
			return !p.app.drawsSubtitle(p.item.RatingKey, s)
		}
	}
	return false
}

// Key handles a pad event during playback; returns true when playback
// should stop (or move along the queue: Next is set).
// pauseKey reports a keyboard's Space or P: they pause and resume
// directly during playback. MiSTer main passes Space as scan code 0x29,
// which the input map reads as OK, so every other screen keeps it as OK.
func pauseKey(ev input.Event) bool {
	return ev.Keyboard && (ev.ScanCode == 0x29 || ev.ScanCode == 0x4D)
}

// togglePause is the Pause button: the launcher pauses or resumes, and the
// panel shows Play while paused.
func (p *Playing) togglePause(now time.Time) {
	p.paused = !p.paused
	p.pausedAt = now   // the launcher's report lags: believed again once it caught up
	p.pvPaused = false // the user's own pause or play from here on: the scrub leaves it be
	p.send("toggle")
	p.dirty = true
}

func (p *Playing) Key(ev input.Event, now time.Time) bool {
	if pauseKey(ev) && p.list == nil {
		if ev.Release || ev.Repeat {
			return false
		}
		p.togglePause(now)
		if p.paused && !p.visible {
			// the panel is where a pause shows (Play in place of Pause), and
			// it stays up while paused, as after OK, Pause
			p.show(now)
			p.peekAt = time.Time{}
		}
		p.shownAt = now
		return false
	}
	if ev.Release {
		if ev.Key == input.Left || ev.Key == input.Right {
			if p.running(now) {
				p.settle = true // the core has the dot: adopt its place next field
			}
			p.held = 0
			if p.scrub && !p.visible {
				// the controls hidden: a tap steps the dot ten seconds, a hold
				// ran it along the strip; the seek waits SeekGrace for more
				if p.settle && p.app.osd != nil {
					p.scrubTo = p.fromX(p.app.osd.DotX())
				} else if !p.settle {
					p.scrubTo = max(0, min(p.scrubTo+float64(10*p.peekDir), p.dur-6))
				}
				p.peekScrub = true // the dot and its time stay up through the grace
				p.armed, p.armAt = true, now
				p.peekAt, p.peekFor = now, 0
				p.dirty = true
			} else if p.scrub {
				// the panel's scrubber: the same grace, no OK needed
				if p.settle && p.app.osd != nil {
					p.scrubTo = p.fromX(p.app.osd.DotX())
				}
				p.armed, p.armAt = true, now
				p.shownAt = now
			}
		}
		return false
	}
	if l := p.list; l != nil {
		switch ev.Key {
		case input.Up, input.Down:
			from := l.cur
			if ev.Key == input.Up && l.cur > 0 {
				l.cur--
			} else if ev.Key == input.Down && l.cur < len(l.items)-1 {
				l.cur++
			}
			l.window()
			if p.arrowsMove(l, from) {
				l.loaded = false // the cursor row's arrows are brighter
			}
		case input.Left, input.Right:
			if p.stepMore(l, ev.Key == input.Right) {
				break // a value row of More: the value steps
			}
			if !ev.Repeat {
				p.closeList()
			}
		case input.Back:
			if !ev.Repeat {
				p.closeList()
			}
		case input.Enter:
			if !ev.Repeat {
				p.choose(l)
			}
		}
		p.shownAt = now
		p.dirty = true
		return false
	}
	if p.scrub && p.visible {
		switch ev.Key {
		case input.Left, input.Right:
			if ev.Repeat {
				break // the hold runs the cursor from Tick, not the key repeat
			}
			d := 1
			if ev.Key == input.Left {
				d = -1
			}
			p.armed = false // the gesture goes on
			p.scrubTo = max(0, min(p.scrubTo+float64(10*d), p.dur-6))
			p.held, p.heldAt = d, now
		case input.Enter:
			if !ev.Repeat {
				if (p.running(now) || p.settle) && p.app.osd != nil {
					p.scrubTo = p.fromX(p.app.osd.DotX())
				}
				p.armed = false
				p.seekTo_(p.scrubTo)
			}
		case input.Down:
			if !ev.Repeat {
				// down to the buttons, with the scrub: one still in its grace
				// (or its hold) goes now, as it would have in a moment
				if p.armed || p.running(now) {
					if (p.running(now) || p.settle) && p.app.osd != nil {
						p.scrubTo = p.fromX(p.app.osd.DotX())
					}
					p.seekTo_(p.scrubTo)
				}
				p.scrub, p.armed, p.held = false, false, 0
			}
		case input.Back:
			if !ev.Repeat {
				p.scrub = false // back to the buttons, dropping an unsent scrub
				p.armed = false
			}
		case input.Up:
		}
		p.visible = true // scrubbing keeps the overlay up, even past its timeout
		p.shownAt = now
		p.dirty = true
		return false
	}
	switch ev.Key {
	case input.Up:
		if ev.Repeat {
			return false
		}
		if !p.visible {
			p.visible = true
		}
		p.scrub = true
		p.scrubTo = p.pos
		p.held = 0
		p.shownAt = now
		p.dirty = true
	case input.Down:
		if !ev.Repeat && p.visible {
			p.visible = false // off the buttons row: the opposite of Up bringing it
			p.dirty = true
		}
	case input.Enter:
		if ev.Repeat {
			return false
		}
		if p.skipShown(now) {
			p.seekTo_(p.skip.End) // the skip button
			p.skipOff = true
			return false
		}
		if !p.visible {
			p.show(now)
			return false
		}
		p.shownAt = now
		switch osdButtons[p.focus] {
		case "-10":
			p.seekBy(-10)
		case "+10":
			p.seekBy(10)
		case "Pause":
			p.togglePause(now)
		case "Prev":
			if p.idx > 0 {
				p.Next = -1
				return true
			}
		case "Next":
			if p.idx+1 < len(p.queue) {
				p.Next = 1
				return true
			}
		case "Audio":
			if len(p.item.Audio) > 1 {
				p.openList("Audio")
			}
		case "Subs":
			if len(p.item.Subs) > 0 {
				p.openList("Subtitles")
			}
		case "More":
			p.openMore()
		}
	case input.Left, input.Right:
		d := 1
		if ev.Key == input.Left {
			d = -1
		}
		if p.visible {
			for i := 0; i < len(osdButtons); i++ {
				p.focus = (p.focus + d + len(osdButtons)) % len(osdButtons)
				if !p.dimmed(p.focus) {
					break
				}
			}
			p.shownAt = now
			p.dirty = true
		} else if !ev.Repeat {
			// the strip scrubs like the panel: a hold runs the dot from Tick,
			// a tap steps it; the seek goes once nothing has been pressed
			// for SeekGrace, so taps and holds add up into one seek
			if !p.scrub {
				p.scrubTo = p.pos // a fresh gesture starts from the picture
			}
			p.scrub = true
			p.armed = false
			p.held, p.heldAt, p.peekDir = d, now, d
			p.peekAt, p.peekFor = now, 0
			p.dirty = true
		}
	case input.Back:
		if ev.Repeat {
			return false
		}
		if p.peeking(now) {
			p.peekAt = time.Time{}
			p.scrub, p.held, p.armed = false, 0, false
			p.closedAt = now
			p.dirty = true
			return false
		}
		if p.skipShown(now) {
			p.skipOff = true // dismiss the skip button
			p.closedAt = now
			p.dirty = true
			return false
		}
		if p.visible {
			p.visible = false
			p.scrub = false
			p.closedAt = now
			p.dirty = true
			return false
		}
		if now.Sub(p.closedAt) < BackGrace {
			return false // a second press of the one that cleared the screen
		}
		return true
	}
	return false
}

// Tick refreshes the position and redraws the overlay when needed. It
// runs once per field (field true) and right after a key (field false).
func (p *Playing) Tick(now time.Time, osd OSD, field bool) {
	p.resizeCanvas(osd)
	if p.metadata != nil {
		select {
		case fresh := <-p.metadata:
			p.item.Markers, p.item.PartID, p.item.Indexes = fresh.Markers, fresh.PartID, fresh.Indexes
			p.item.Audio, p.item.Subs = fresh.Audio, fresh.Subs
			p.app.applyStreams(p.item)
			p.pvTried = p.preview != nil // the part may have previews after all
			p.dirty = true
		default:
		}
	}
	if !p.pvTried {
		p.pvTried = true
		start := p.pos
		if start == 0 {
			start = float64(p.item.ViewOffset)
		}
		w, h := previewSize(p.canvasWidth(), p.canvasHeight())
		p.preview = newPreviewer(p.app, p.item, w, h, start)
	}
	p.syncSubtitles()
	p.takeSubtitles()
	if now.Sub(p.statAt) > 100*time.Millisecond {
		p.statAt = now
		p.status()
	}
	p.waiting(now)
	if field && p.scrub && p.held != 0 {
		p.shownAt = now // a hold keeps the overlay up
		if !p.visible {
			p.peekAt = now // and the strip
		}
	}
	if p.scrub && !p.visible && p.running(now) {
		p.peekScrub = true // a hold, not a tap: the strip takes the scrub layout
	} else if !p.scrub {
		p.peekScrub = false
	}
	if p.armed && p.held == 0 {
		p.peekAt = now // the strip stays through the grace
		if now.Sub(p.armAt) >= SeekGrace {
			// nothing pressed since the release: the gesture is over
			p.armed = false
			if !p.visible {
				p.scrub = false // the strip returns to its plain layout
			}
			p.seekTo_(p.scrubTo)
			p.peekAt, p.peekFor = now, 0
			p.dirty = true
		}
	}
	// the dot's run is the core's: send the speed, follow its place
	vx := 0
	if p.running(now) {
		vx = p.held * p.runSpeed(now)
	}
	if vx != p.runVx {
		osd.DotRun(vx, p.safeX(), p.safeX()+p.safeW())
		p.runVx = vx
	}
	if vx != 0 || p.settle {
		p.scrubTo = p.fromX(osd.DotX())
		if vx == 0 {
			p.settle = false
		}
	}
	p.previewTick(now)
	if m := p.marker(); m != p.skip {
		p.skip = m
		p.skipOff = false
		p.skipAt = now
		p.dirty = true
	}
	if p.visible && !p.paused && p.list == nil && now.Sub(p.shownAt) > OsdHide {
		p.visible = false
		p.scrub, p.held = false, 0
		p.dirty = true
	}
	if !p.peekAt.IsZero() && !p.peeking(now) {
		p.peekAt = time.Time{}
		p.dirty = true
	}
	p.shake(osd, field)
	peek := p.peeking(now)
	skipBtn := p.skipShown(now)
	if !p.visible && !skipBtn && !peek {
		// nothing else up: the drawn subtitles, if any are showing now
		lines := p.subtitleLines(now)
		if p.dirty {
			osd.Dot(0, 0, 0, false)
			osd.Bar(0, 0, 0, 0, 0, false)
			p.dirty = false
			if p.wait == nil && len(lines) == 0 {
				p.painter.hide(osd)
				p.last = ""
			}
		}
		p.setJitter(osd, p.wait != nil) // the VCR blocks waver, the subtitles stay put
		if p.wait == nil {
			p.showSubtitle(osd, lines)
		}
		if p.wait != nil {
			// the dots alone, repainted as the swell moves on
			if frame := p.wait.frameAt(now); frame != p.wait.frame || p.last != "wait" {
				p.wait.frame, p.last = frame, "wait"
				c, alpha, y := p.waitPanel(frame, nil, nil)
				p.painter.show(osd, 0, y, c, alpha)
			}
		}
		return
	}
	var key string
	var x, y int
	if p.list != nil {
		l := p.list
		p.refreshInfo(now)
		osd.Dot(0, 0, 0, false)
		moved := false
		if field {
			moved = l.slide()
		}
		// the window must lie within what is uploaded
		if !l.loaded || l.at < l.base || l.at+OsdListH > l.base+l.uploaded {
			p.uploadList(osd)
			moved = true
		}
		if moved || p.last != "list" {
			p.setJitter(osd, true)
			p.last = "list"
			off := (l.at - l.base) * OsdListW * 4
			p.painter.do(func() { osd.ShowAt(0, SafeY, OsdListW, OsdListH, off) })
		}
		// the cursor is the overlay's bar, beside its row
		by := SafeY + OsdListTop + l.cur*OsdListRowH - l.at
		osd.Bar(p.menuX()-MenuBarGap-BarW, by+2, BarW, p.app.F.Body.Height()-4, p.barColour(),
			by >= SafeY && by+OsdListRowH <= SafeY+OsdListH)
		return
	}
	if field {
		p.scrubTick++
	}
	if peek {
		// the title, the bar and the times, along the bottom edge; the dot
		// on the bar while a hold scrubs
		osd.Bar(0, 0, 0, 0, 0, false)
		key = "peek|" + itoa(int(p.pos)) + "|" + itoa(btoi(p.peekScrub)) + "|" + itoa(int(p.scrubTo)) + p.bufferKey() + p.previewKey()
		frame := -1
		if p.wait != nil {
			frame = p.wait.frameAt(now) // the dots over the start strip: repainted as they swell
			key += "|w" + itoa(frame)
		}
		if key != p.last && !(vx != 0 && p.scrubTick&1 == 1) {
			p.setJitter(osd, true)
			p.last = key
			p.compose(true)
			h := p.peekStripH() + p.lift() // the preview's rows above it, when up
			strip, alpha := &gfx.Canvas{W: p.canvas.W, H: h, Pix: p.canvas.Pix[:p.canvas.W*h*4]}, p.alpha[:p.canvas.W*h]
			if p.wait != nil {
				p.wait.frame = frame
				c, a, y := p.waitPanel(frame, strip, alpha)
				p.painter.show(osd, 0, y, c, a)
			} else {
				p.painter.show(osd, 0, p.canvasHeight()-h, strip, alpha)
			}
		}
		if p.scrub && p.dur > 0 {
			// the dot: loaded at the press (hidden, so the run starts from
			// here), shown once the hold runs; the core places it meanwhile
			if vx == 0 || !p.dotOn {
				p.dotOn = p.peekScrub
				osd.Dot(p.safeX()+int(float64(p.safeW())*p.scrubTo/p.dur+0.5), p.osdBottom()-p.peekH+p.pillY+PillH/2, p.dotColour(), p.dotOn)
			}
		} else {
			p.dotOn = false
			osd.Dot(0, 0, 0, false)
		}
		p.dirty = false
		return
	}
	if skipBtn {
		osd.Dot(0, 0, 0, false)
		osd.Bar(0, 0, 0, 0, 0, false)
		// lower right of the safe area, off the picture's centre; the
		// controls never show at the same time
		x, y = p.safeX()+p.safeW()-240, (p.osdBottom()-40)&^1
		key = p.skipKey()
		if key != p.last {
			p.setJitter(osd, true)
			p.last = key
			p.composeSkip()
			p.painter.show(osd, x, y, &gfx.Canvas{W: 240, H: 40, Pix: p.canvas.Pix[:240*40*4]}, p.alpha[:240*40])
		}
		return
	}
	// the sprites first, before any pixel work: one store each, on
	// screen within a line
	if p.composed {
		p.sprites()
		if vx == 0 {
			osd.Dot(p.dotX, p.dotY, p.dotColour(), p.dotOn)
		}
		osd.Bar(p.barX, p.barY, p.barW, BarW, p.barColour(), p.barOn)
	}
	key = p.panelKey() + p.previewKey()
	if key == p.last && p.composed {
		return // nothing to repaint
	}
	if vx != 0 && p.scrubTick&1 == 1 && p.composed {
		return // a run: the time is repainted every other field
	}
	p.compose(false)
	if !p.composed {
		p.composed = true
		p.sprites()
		osd.Dot(p.dotX, p.dotY, p.dotColour(), p.dotOn)
		osd.Bar(p.barX, p.barY, p.barW, BarW, p.barColour(), p.barOn)
	}
	p.last = key
	p.setJitter(osd, true)
	lh := p.lift() + p.osdHeight() // the preview's rows above the panel, when up
	p.painter.show(osd, 0, p.osdY()-p.lift(), &gfx.Canvas{W: p.canvas.W, H: lh, Pix: p.canvas.Pix[:p.canvas.W*lh*4]}, p.alpha[:p.canvas.W*lh])
	p.dirty = false
}

// resizeCanvas follows a raster or display-shape change reported by the
// core. The old painter drains and hides its panel before the replacement
// canvas is installed, so no stale-sized write can land afterward.
func (p *Playing) resizeCanvas(osd OSD) {
	w, h, ok := playbackCanvasSize(p.app)
	if !ok {
		return
	}
	if p.canvas != nil && p.canvas.W == w && p.canvas.H == h {
		return
	}
	if p.painter != nil {
		p.painter.close(osd)
		p.painter.waitClosed()
	}
	p.canvas = gfx.NewCanvas(w, h)
	p.alpha = make([]byte, w*h)
	p.static = nil
	p.staticFor = ""
	p.alphaDone = false
	p.last = ""
	p.composed = false
	p.painter = newPainter(w, h)
	p.shaking.Store(false) // a shake queued on the old painter was dropped
	setOSDCanvasSize(osd, w, h)
	p.dirty = true
}

// sprites places the dot and the bar from the current state and the
// geometry the last compose left behind.
func (p *Playing) sprites() {
	p.dotOn = p.scrub && p.dur > 0
	if p.dotOn {
		p.dotX = p.safeX() + int(float64(p.safeW())*p.scrubTo/p.dur+0.5)
		p.dotY = p.osdY() + p.pillY + PillH/2
	}
	p.barOn = !p.scrub
	if p.barOn {
		p.barX, p.barY, p.barW = p.btnX[p.focus], p.osdY()+p.btnY, p.btnW[p.focus]
	}
}

// dimmed reports whether button i has nothing to do for this item.
func (p *Playing) dimmed(i int) bool {
	switch osdButtons[i] {
	case "Prev":
		return p.idx == 0
	case "Next":
		return p.idx+1 >= len(p.queue)
	case "Audio":
		return len(p.item.Audio) < 2
	case "Subs":
		return len(p.item.Subs) == 0
	case "More":
		return false
	}
	return false
}

// heading is the overlay's title line: the show on the left with the
// season, episode and episode title on the right, or the film with its
// year on the right.
func heading(it *plex.Item) (title, sub string) {
	if it.Type == "episode" {
		return it.GrandTitle, "S" + itoa(it.Parent) + " E" + itoa(it.Index) + "  " + it.Title
	}
	if it.Year > 0 {
		return it.Title, itoa(it.Year)
	}
	return it.Title, ""
}

// panelKey describes what the panel would show, without drawing it. Tick
// asks every field: the string is built again only when that changed.
func (p *Playing) panelKey() string {
	it := p.item
	a, b := p.bufferPixels()
	s := panelState{it, it.Type, it.Title, it.GrandTitle, it.Parent, it.Index, it.Year,
		int(p.pos), p.focus, int(p.scrubTo), p.paused, p.scrub, a, b}
	if s == p.panelFor && p.panelText != "" {
		return p.panelText
	}
	title, sub := heading(it)
	p.panelFor = s
	p.panelText = title + sub + "|" + itoa(int(p.pos)) + "|" + itoa(p.focus) + "|" + itoa(btoi(p.paused)) + "|" + itoa(btoi(p.scrub)) + "|" + itoa(int(p.scrubTo)) + p.bufferKey()
	return p.panelText
}

// skipKey describes the skip button.
func (p *Playing) skipKey() string {
	if p.skip != nil && strings.Contains(p.skip.Type, "credit") {
		return "skip|Skip credits"
	}
	return "skip|Skip intro"
}

// peeking reports whether a closed-overlay seek is still showing its bar.
func (p *Playing) peeking(now time.Time) bool {
	stay := p.peekFor
	if stay == 0 {
		stay = OsdFlash
	}
	return !p.peekAt.IsZero() && now.Sub(p.peekAt) < stay && !p.visible && p.list == nil
}

// compose paints the panel; for a peek only the title, the bar and the
// times, and peekH is set to the rows they take.
func (p *Playing) compose(peek bool) {
	// the panel starts lift rows down while a preview floats above it
	lift := p.lift()
	base := lift * p.canvas.W
	c := &gfx.Canvas{W: p.canvas.W, H: p.osdHeight(), Pix: p.canvas.Pix[base*4 : (base+p.canvas.W*p.osdHeight())*4]}
	alpha := p.alpha[base : base+c.W*c.H]
	if !p.alphaDone || p.alphaLift != lift {
		// alpha: the panel, its top edge eased in; the same for every panel
		for y := 0; y < c.H; y++ {
			a := OsdAlpha
			if y < 20 && !p.app.vcr() { // the VCR band has a hard edge
				a = OsdAlpha * y / 20
			}
			row := alpha[y*c.W : (y+1)*c.W]
			for x := range row {
				row[x] = byte(a)
			}
		}
		p.alphaDone, p.alphaLift = true, lift
	}
	// everything but the running time is drawn once per state into the
	// static panel; a scrub then repaints the time over a copy each field
	// instead of composing the whole panel (which held the loop to 15 Hz)
	timed := p.scrub && (!peek || p.peekScrub)
	key := p.staticKey(peek, timed)
	if p.static == nil {
		p.static = gfx.NewCanvas(p.canvas.W, p.osdHeight())
	}
	vcr := p.app.vcr()
	if key != p.staticFor {
		if vcr {
			p.composeStaticVCR(p.static, peek, timed)
		} else {
			p.composeStatic(p.static, peek, timed)
		}
		p.staticFor = key
	}
	copy(c.Pix, p.static.Pix)
	if timed && vcr {
		p.vcrRunningTime(c)
	} else if timed {
		c.TextCenter(p.safeX()+p.safeW()/2, p.timeY, p.app.F.Body, gfx.White, clock(int(p.scrubTo)))
	}
	if vcr && p.app.vcrClear() {
		p.vcrClearBand(c, alpha)
	}
	if lift > 0 {
		p.drawPreview(lift) // per compose, over the static copy's rows above
	}
}

// staticKey describes the static panel, without the running time.
func (p *Playing) staticKey(peek, timed bool) string {
	it := p.item
	return it.Title + it.GrandTitle + "|" + itoa(int(p.pos)) + "|" + itoa(p.focus) + "|" + itoa(btoi(p.paused)) +
		"|" + itoa(btoi(p.scrub)) + "|" + itoa(btoi(peek)) + "|" + itoa(btoi(timed)) + p.bufferKey()
}

// composeStatic paints the panel into c: the title, the pill, the times
// (or, with timed, room for the running time at timeY) and the buttons.
func (p *Playing) composeStatic(c *gfx.Canvas, peek, timed bool) {
	f := p.app.F
	c.Fill(0, 0, c.W, c.H, gfx.Bg)
	it := p.item
	title, sub := heading(it)
	y := 14
	{
		p.app.text(c, p.safeX(), y, f.Body, gfx.GreyHi, f.Body.Fit(title, p.safeW()-320))
		if sub != "" {
			p.app.textRight(c, p.safeX()+p.safeW(), y+3, f.SmallBold, gfx.GreyLo, f.SmallBold.Fit(sub, 300))
		}
		y += f.Body.Height() + 14
	}
	// the pill, marker spans on it, a dot while scrubbing, and the times:
	// elapsed of total on the left, remaining on the right
	pw := p.safeW()
	p.pillY = y + 6
	c.Fill(p.safeX(), y+6, pw, PillH, 0x404040)
	if p.dur > 0 {
		if x0, x1 := p.bufferPixels(); x1 > x0 {
			c.Fill(p.safeX()+x0, y+6, x1-x0, PillH, 0xA699BC)
		}
		for _, m := range it.Markers {
			x0 := p.safeX() + int(float64(pw)*m.Start/p.dur)
			x1 := p.safeX() + int(float64(pw)*m.End/p.dur)
			c.Fill(x0, y+6, max(2, x1-x0), PillH, 0x5A6070)
		}
		c.Fill(p.safeX(), y+6, int(float64(pw)*p.pos/p.dur), PillH, gfx.Amber)
	}
	y += PillH + 14
	if timed {
		// the time the dot stands for goes in the middle, in the body
		// face, so it reads steadily while the dot runs: compose draws it
		p.timeY = y - 3
	} else {
		c.Text(p.menuX(), y, f.SmallBold, gfx.GreyLo, clock(int(p.pos))+" / "+clock(int(p.dur)))
		if p.dur > 0 {
			c.TextRight(p.safeX()+p.safeW(), y, f.SmallBold, gfx.GreyLo, "-"+clock(int(p.dur-p.pos)))
		}
	}
	y += f.SmallBold.Height() + 12
	if peek {
		p.peekH = y
		return
	}
	// the buttons, centred, the focused one white with a bar under it
	labels := make([]string, len(osdButtons))
	total := 0
	for i, b := range osdButtons {
		if b == "Pause" && p.paused {
			b = "Play"
		}
		labels[i] = b
		total += p.btnCellW(b)
	}
	total += OsdBtnGap * (len(labels) - 1)
	x := (c.W - total) / 2
	for i, b := range labels {
		col := gfx.GreyLo
		if b == "Play" {
			col = gfx.Amber
		}
		if i == p.focus && !p.scrub {
			if col != gfx.Amber {
				col = gfx.White
			}
		}
		w := p.btnCellW(b)
		p.btnX[i], p.btnW[i], p.btnY = x, w, y+f.Body.Height()+3
		if p.dimmed(i) {
			col = ChevronOff
		}
		if p.app.icons() {
			osdIcon(c, f, b, x, y, w, f.Body.Height(), col)
		} else {
			c.Text(x, y, f.Body, col, b) // a colour change on focus would miss the cache for a frame
		}
		x += w + OsdBtnGap
	}
}

// btnCellW is the width of button label b's cell: its word's, or in the
// Icons look its glyph's where that is wider.
func (p *Playing) btnCellW(b string) int {
	if p.app.icons() {
		return iconCellW(p.app.F, b)
	}
	return p.app.F.Body.Width(b)
}

// composeSkip paints the small skip button (240x40) at the canvas origin.
// It shares the alpha plane's first rows with the panel, so the panel's
// eased top edge is drawn again the next time the panel goes up.
func (p *Playing) composeSkip() {
	c := &gfx.Canvas{W: 240, H: 40, Pix: p.canvas.Pix[:240*40*4]}
	f := p.app.F
	c.Fill(0, 0, c.W, c.H, gfx.Bg)
	for i := range p.alpha[:240*40] {
		p.alpha[i] = OsdAlpha
	}
	p.alphaDone = false
	label := "Skip intro"
	if p.skip != nil && strings.Contains(p.skip.Type, "credit") {
		label = "Skip credits"
	}
	if p.app.vcr() {
		p.composeSkipVCR(c, label)
		return
	}
	c.Text(24, 8, f.Body, gfx.White, label)
	chevronRight(c, 24+f.Body.Width(label)+18, 14, gfx.GreyLo)

}

// composeList paints an audio or subtitle list down the left, full height.
// uploadList draws the part of the column around the window into the
// overlay region: the whole list when it fits (the usual case), else a
// stretch with headroom either way, redone when the window leaves it.
func (p *Playing) uploadList(osd OSD) {
	l := p.list
	f := p.app.F
	maxRows := (ring.RegionSize / (OsdListW * 4)) &^ 1
	h := l.height()
	base := 0
	if h > maxRows {
		base = max(0, min(l.at-(maxRows-OsdListH)/2, h-maxRows)) &^ 1
	}
	// at least the window's height: what the core shows below a short
	// list must be this list's background, not what was there before
	rows := max(min(h-base, maxRows), OsdListH)
	c := gfx.NewCanvas(OsdListW, rows)
	if p.app.vcr() {
		p.drawListVCR(c, base)
		l.base, l.uploaded, l.loaded = base, rows, true
		p.painter.do(func() { osd.Upload(0, c, 240) })
		return
	}
	c.Fill(0, 0, c.W, c.H, gfx.Bg)
	if base == 0 {
		title := l.kind
		if l.hint != "" {
			title += " (" + l.hint + ")"
		}
		c.Text(p.menuX(), 16, f.Title, gfx.Grey, title)
	}
	for i, item := range l.items {
		y := OsdListTop + i*OsdListRowH - base
		if y+OsdListRowH <= 0 || y >= rows {
			continue
		}
		left, right := p.listArrows(l, i)
		arrowsW := 0
		if left != arrowNone || right != arrowNone {
			arrowsW = listArrowsW
		}
		val := ""
		if i < len(l.vals) {
			val = l.vals[i]
		}
		item, val = listRowText(f.Body, p.menuX(), item, val, arrowsW)
		c.Text(p.menuX(), y, f.Body, gfx.GreyHi, item)
		if i == l.set {
			tick(c, OsdListW-30, y+f.Body.Height()/2, gfx.GreyHi)
		}
		vr := OsdListW - OsdListPad // the value's right edge
		if arrowsW > 0 {
			vr -= listArrowW + listArrowGap
			cy := y + f.Body.Height()/2
			if col, ok := arrowColour(left, i == l.cur); ok {
				listArrow(c, vr-f.Body.Width(val)-listArrowGap-listArrowW, cy, true, col)
			}
			if col, ok := arrowColour(right, i == l.cur); ok {
				listArrow(c, OsdListW-OsdListPad-listArrowW, cy, false, col)
			}
		}
		if val != "" {
			c.TextRight(vr, y, f.Body, gfx.GreyLo, val)
		}
	}
	l.base, l.uploaded, l.loaded = base, rows, true
	p.painter.do(func() { osd.Upload(0, c, 240) })
}

func btoi(b bool) int {
	if b {
		return 1
	}
	return 0
}
