package input

// The H.264 core's input region (control words 48-71; the vendored
// third_party/MiSTer_h264_decoder site/content/integrating/interface.md
// "The input region" and launch.md "Input"): MiSTer main holds every input
// device while a core runs and sends the core what they do; the core
// copies it here. Words, relative to 48:
//
//	0      [31:0] in_head (+1 each write), [63:32] ev_count (events queued
//	       since the core loaded: the next event's number)
//	1..6   pad 0..5: [15:0] buttons, [47:32] left stick, [63:48] right
//	       stick (each Y [15:8], X [7:0], signed, Y down-positive)
//	7      mouse: dx_sum [31:0], dy_sum [63:32]
//	8..15  the event queue: 32 entries of 16 bits, four a word (event n
//	       is entry n % 32: word 8 + (n%32)/4, bits 16*(n%4))
//	16     [31:0] wheel_sum, [39:32] mouse buttons, [40] OSD open,
//	       [63:48] ev_lost (events the core could not queue)
//	23     in_tail: in_head again
//
// An event: [15:14] its type -- 0 a key ([9] pressed, [8] E0, [7:0] the
// PS/2 set-2 code, the same [9:0] as the PlexCRT core's key word), 1 the
// mouse buttons changed ([7:0]), 2 MiSTer's menu ([0] opened), 3 a menu
// action chosen ([7:0]: 0 "Send Home to the program", 1 "Program menu").

// RegionWords is the input region's size in 64-bit words.
const RegionWords = 24

const (
	qWord  = 8  // the queue's first word, relative to 48
	qLen   = 32 // its entries
	wMisc  = 16 // wheel, mouse buttons, osd_open, ev_lost
	padMax = 6
)

// RegionSource is a source that can copy the whole region consistently
// (ring.Ring does). Poll prefers it to Joy/Key: it sees every event.
type RegionSource interface {
	InputRegion(*[RegionWords]uint64) bool
}

// The core's pad (launch.md "The gamepads", H264RING_PAD_*): MiSTer's own
// button mapping, so each bit is the user's own button for that role.
const (
	PadRight = 1 << 0
	PadLeft  = 1 << 1
	PadDown  = 1 << 2
	PadUp    = 1 << 3
	PadA     = 1 << 4
	PadB     = 1 << 5
	PadX     = 1 << 6
	PadY     = 1 << 7
	PadLB    = 1 << 8
	PadRB    = 1 << 9
	PadBack  = 1 << 10
	PadStart = 1 << 11
	PadLS    = 1 << 12
	PadRS    = 1 << 13
	PadLT    = 1 << 14
	PadRT    = 1 << 15
)

// LegacyJoy maps an H.264 core pad word to the PlexCRT core's joystick
// layout, which Poll and the UI are written for (one bit a Key):
//
//	bits 0-3  the d-pad, right left down up   <- pad bits 0-3 (the same)
//	bit 4     OK (Enter)                      <- B
//	bit 5     Back                            <- A
//	bit 6     L (JumpBack)                    <- LB
//	bit 7     R (JumpFwd)                     <- RB
//	bit 8     Start (pause/play)               <- Start
//
// Use B to confirm and A to go back with the H.264 core's pad mapping.
// These are gamepad actions only; keyboard Enter and Escape are unchanged.
// Start pauses or resumes playback. X, Y, the triggers, Back (Select) and
// the stick clicks have no role yet.
func LegacyJoy(pad uint32) uint32 {
	j := pad & 0xF
	if pad&PadB != 0 {
		j |= 1 << Enter
	}
	if pad&PadA != 0 {
		j |= 1 << Back
	}
	if pad&PadLB != 0 {
		j |= 1 << JumpBack
	}
	if pad&PadRB != 0 {
		j |= 1 << JumpFwd
	}
	if pad&PadStart != 0 {
		j |= 1 << Start
	}
	return j
}

// stickThreshold is how far (of 127) the left stick must lean to count as
// the d-pad: well past any resting drift.
const stickThreshold = 96

// stickDpad turns a left stick ([15:8] Y down-positive, [7:0] X) into
// d-pad bits.
func stickDpad(stick uint16) uint32 {
	x, y := int8(stick), int8(stick>>8)
	var j uint32
	switch {
	case x >= stickThreshold:
		j |= PadRight
	case x <= -stickThreshold:
		j |= PadLeft
	}
	switch {
	case y >= stickThreshold:
		j |= PadDown
	case y <= -stickThreshold:
		j |= PadUp
	}
	return j
}

// padsLegacy is every pad's buttons (and left stick as the d-pad) in the
// legacy layout, OR'd: any pad navigates.
func padsLegacy(in *[RegionWords]uint64) uint32 {
	var j uint32
	for p := 0; p < padMax; p++ {
		w := in[1+p]
		j |= LegacyJoy(uint32(w)&0xFFFF | stickDpad(uint16(w>>32)))
	}
	return j
}

// Event types in a queue entry's [15:14].
const (
	EvKey      = 0
	EvMouseBtn = 1
	EvOSD      = 2
	EvAction   = 3
)

// The menu's two actions for the program (an EvAction's number).
const (
	ActNumHome = 0 // "Send Home to the program"
	ActNumMenu = 1 // "Program menu"
)

func evCount(in *[RegionWords]uint64) uint32 { return uint32(in[0] >> 32) }

// OSDOpen is the region's osd_open bit.
func OSDOpen(in *[RegionWords]uint64) bool { return in[wMisc]>>40&1 != 0 }

// queue keeps this reader's place in the core's event queue.
type queue struct {
	count uint32
	init  bool
}

// next returns the events queued since the last call, oldest first, and
// how many were overwritten before they could be read (h264ring_input_
// events): more than 32 since the last read loses the oldest. The first
// call starts from now: earlier events are not this reader's.
func (q *queue) next(in *[RegionWords]uint64, out []uint16) ([]uint16, uint32) {
	evc := evCount(in)
	if !q.init {
		q.count, q.init = evc, true
		return out[:0], 0
	}
	n := evc - q.count // free-running: right across a wrap
	var lost uint32
	if n > 0x80000000 { // behind us: a reloaded core, start over
		q.count = evc
		return out[:0], 0
	}
	if n > qLen {
		lost = n - qLen
		q.count = evc - qLen
		n = qLen
	}
	out = out[:0]
	for k := uint32(0); k < n; k++ {
		slot := (q.count + k) % qLen
		out = append(out, uint16(in[qWord+slot/4]>>(16*(slot%4))))
	}
	q.count += n
	return out, lost
}

// LastKey is the region in the PlexCRT key word's shape: the event count
// (8 bits) << 11 | the newest key event's [9:0]. For Ring.Key.
func LastKey(in *[RegionWords]uint64) uint32 {
	evc := evCount(in)
	for k := uint32(0); k < qLen && k < evc; k++ {
		n := evc - 1 - k
		e := uint16(in[qWord+(n%qLen)/4] >> (16 * (n % 4)))
		if e>>14 == EvKey {
			return (evc&0xFF)<<11 | uint32(e)&0x3FF
		}
	}
	return (evc & 0xFF) << 11
}
