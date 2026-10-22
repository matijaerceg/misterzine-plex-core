package ring

import (
	"sync"
	"sync/atomic"
	"time"

	"plexcrt/internal/input"
)

// What the PlexCRT core did in hardware and the H.264 core does not: the
// CRT video-mode lease, the brightness word, the audio tap. The methods
// stay so the UI builds unchanged; the brightness is now applied to the
// pixels as they are copied into a page.

// Full is full brightness.
const Full = 256

// GeometrySupported reports the additive picture-rectangle interface.
func (r *Ring) GeometrySupported() bool {
	v := r.c.lo(wVersion) & 0xFFFF
	return v>>8 == 1 && v >= 0x102
}

// SetBrightness scales every pixel published from now on by level/256
// (clamped to 0..Full), and shows the last frame again at that level.
func (r *Ring) SetBrightness(level int) {
	level = max(0, min(level, Full))
	r.mu.Lock()
	defer r.mu.Unlock()
	r.dim = uint32(Full - level)
	if r.frame && r.back != nil && r.want.on {
		r.publishFrame(r.back.Pix, int(r.want.first), int(r.want.last))
	} else if r.overlay != nil {
		r.overlay.compose()
	}
}

// Brightness is the level asked for; always supported (done in software).
func (r *Ring) Brightness() (level int, supported bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return int(Full - r.dim), true
}

// VideoControl held the PlexCRT core's CRT-profile request. The H.264 core
// takes its video settings from MiSTer's menu (or a settings request), so
// what is kept here is only the preference, which nothing on screen reads.
type VideoControl struct {
	mu             sync.Mutex
	mode, previous uint32
	deadline       time.Time
}

// StartVideo is a no-op lease; the returned function ends it.
func (r *Ring) StartVideo(mode uint32, logf func(string, ...any)) func() {
	r.SetVideo(mode)
	return func() {}
}

// SetVideo records a preference.
func (r *Ring) SetVideo(mode uint32) {
	r.video.mu.Lock()
	defer r.video.mu.Unlock()
	if mode != 2 {
		mode = 0
	}
	r.video.mode = mode
	r.video.deadline = time.Time{}
}

// VideoStatus: the H.264 core has no CRT-profile word (supported false).
func (r *Ring) VideoStatus() (mode uint32, override, supported bool) { return 0, false, false }

// VideoLocked: there is no CRT-profile interlock.
func (r *Ring) VideoLocked() bool { return false }

// TryVideo starts a 15 s trial of a preference (kept for the UI).
func (r *Ring) TryVideo(mode uint32) time.Time {
	r.video.mu.Lock()
	defer r.video.mu.Unlock()
	r.video.previous = r.video.mode
	r.video.mode = mode
	r.video.deadline = time.Now().Add(15 * time.Second)
	return r.video.deadline
}

// FinishVideo ends a trial, keeping or reverting the preference.
func (r *Ring) FinishVideo(keep bool) bool {
	r.video.mu.Lock()
	defer r.video.mu.Unlock()
	valid := !r.video.deadline.IsZero() && time.Now().Before(r.video.deadline)
	if !valid {
		return false
	}
	if !keep {
		r.video.mode = r.video.previous
	}
	r.video.deadline = time.Time{}
	return keep
}

// Tap was a click into the PlexCRT core's audio mixer; the H.264 core's
// audio is the player's.
func (r *Ring) Tap() {}

// InputRegion copies the core's input region (words 48-71) consistently:
// the input package's RegionSource.
func (r *Ring) InputRegion(dst *[input.RegionWords]uint64) bool { return r.c.input(dst) }

// Joy returns pads 1 and 0 in the old status word's layout (pad1<<16 |
// pad0, see input.LegacyJoy). For the input package's legacy path only.
func (r *Ring) Joy() uint32 {
	var in [input.RegionWords]uint64
	if !r.c.input(&in) {
		return 0
	}
	return input.LegacyJoy(uint32(in[2]))<<16 | input.LegacyJoy(uint32(in[1]))
}

// Key returns the old status word's shape, event count<<11 | the latest
// key event's [9:0] (pressed, extended, code). Events between two reads
// are lost this way: Poll reads the queue through InputRegion instead.
func (r *Ring) Key() uint32 {
	var in [input.RegionWords]uint64
	if !r.c.input(&in) {
		return atomic.LoadUint32(&r.lastKey)
	}
	k := input.LastKey(&in)
	atomic.StoreUint32(&r.lastKey, k)
	return k
}
