package ring

import (
	"sync/atomic"

	"plexcrt/internal/input"
)

// The Ring's side of what the UI asks of its output: the picture-rectangle
// interface, brightness (done in software, on the pixels as they are copied
// into a page) and the input region. Tap, the Navigation sounds tick, is in
// tick.go.

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

// InputRegion copies the core's input region (words 48-71) consistently:
// the input package's RegionSource.
func (r *Ring) InputRegion(dst *[input.RegionWords]uint64) bool { return r.c.input(dst) }

// Joy returns pads 1 and 0 in the old status word's layout (pad1<<16 |
// pad0, see input.LegacyJoy). Joy and Key only make the Ring an
// input.Source: Poll reads it through InputRegion.
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
