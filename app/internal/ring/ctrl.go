package ring

import (
	"sync/atomic"
	"time"
)

// ctrl is the control block seen as 32-bit halves: word w's low half is
// m[2w], its high half m[2w+1] (little-endian). On the MiSTer m is the
// /dev/mem mapping (O_SYNC: uncached, strongly ordered); in the tests a
// plain slice the test plays the core in.
//
// Every access is one aligned 32-bit atomic load or store. On ARMv7 Go's
// atomic store is DMB; STR; DMB, so each store is also the memory barrier
// the descriptor protocol asks for between its steps. Never Add or CAS on
// this memory: those are LDREX/STREX, which strongly-ordered memory does
// not support.
type ctrl struct {
	m []uint32
	// nap is how a retry waits (the tests make it a yield)
	nap func(time.Duration)
	// trace hears every store, in order (the tests)
	trace func(w int, v uint32)
}

func (c *ctrl) lo(w int) uint32 { return atomic.LoadUint32(&c.m[2*w]) }
func (c *ctrl) hi(w int) uint32 { return atomic.LoadUint32(&c.m[2*w+1]) }
func (c *ctrl) word(w int) uint64 {
	return uint64(c.lo(w)) | uint64(c.hi(w))<<32
}
func (c *ctrl) setLo(w int, v uint32) {
	atomic.StoreUint32(&c.m[2*w], v)
	if c.trace != nil {
		c.trace(w, v)
	}
}

func (c *ctrl) sleep(d time.Duration) {
	if c.nap != nil {
		c.nap(d)
		return
	}
	time.Sleep(d)
}

// Status is a consistent copy of the parts of the core's status block this
// app uses (interface.md "The control block").
type Status struct {
	Heartbeat        uint32 // seq_head: +1 every frame the core runs; still for a second = the core is gone
	State            uint8  // NO_SESSION 1, READY 2, PLAYING 3, ENDED 4, ERROR 5
	Err              uint8  // the session's first error code
	Live             uint8  // Live* flags
	Shown            uint32 // fetch_changes: pictures the display has taken (moves while video plays)
	Picture          bool   // fit_valid: a picture is on screen
	OvlGen           uint32 // the generation of the last consistent overlay descriptor the core read
	OvlState         uint8  // OvlOff, OvlAccepted, OvlRefused
	OvlErr           uint8  // OVL_E_*: why a descriptor was refused
	OvlTorn          uint8  // descriptors read mid-write (saturating)
	ARX, ARY         int    // the output's shape on HDMI
	RasterW          int    // the output the overlay's canvas is centred on
	RasterH          int
	RasterMode       int // 0 fitted (720 wide), 1 native, 2 native but this picture fitted
	VideoOut         int // 1 interlaced, 2 progressive, 3 native (HDMI)
	DisplayWide      bool
	DisplayKnown     bool
	DisplayProfile   int  // the OSD's Output Mode: 0 480i60, 1 480p60, 2 576i50, 3 576p50, 4 Native HDMI
	DisplayMatch     bool // Refresh Rate Match is 50/60: playback may switch to the other family
	EffectiveProfile int
}

func (s Status) OSDOpen() bool { return s.Live&LiveOSDOpen != 0 }
func (s Status) Session() bool { return s.Live&LiveSession != 0 }

// status reads the status block as its seqlock asks: word 31, the words,
// then word 3, again until the two agree (h264ring_status).
func (c *ctrl) status() (Status, bool) {
	for try := 0; try < 200; try++ {
		tail := c.lo(wSeqTail)
		st4 := c.word(wState)
		fetch := c.lo(wFetch)
		fit := c.hi(wFit)
		ovl := c.word(wOvlStat)
		asp := c.lo(wAspect)
		ras := c.lo(wRaster)
		display := c.lo(wDisplay)
		version := c.lo(wVersion) & 0xFFFF
		displayKnown := version>>8 == 1 && version&0xFF >= 3
		if !displayKnown {
			display = 0
		}
		if c.lo(wSeqHead) != tail {
			c.sleep(200 * time.Microsecond)
			continue
		}
		return Status{
			Heartbeat:        tail,
			State:            uint8(st4),
			Err:              uint8(st4 >> 8),
			Live:             uint8(st4 >> 16),
			Shown:            fetch,
			Picture:          fit>>13&1 != 0,
			OvlGen:           uint32(ovl),
			OvlState:         uint8(ovl>>32) & 3,
			OvlErr:           uint8(ovl>>36) & 15,
			OvlTorn:          uint8(ovl >> 40),
			ARX:              int(asp & 0xFFF),
			ARY:              int(asp >> 12 & 0xFFF),
			RasterW:          int(ras & 0xFFF),
			RasterH:          int(ras >> 12 & 0xFFF),
			RasterMode:       int(ras >> 24 & 3),
			VideoOut:         int(ras >> 27 & 3),
			DisplayWide:      display>>6&1 != 0,
			DisplayKnown:     displayKnown,
			DisplayProfile:   int(display & 7),
			DisplayMatch:     display>>3&1 != 0,
			EffectiveProfile: int(display >> 7 & 15),
		}, true
	}
	return Status{}, false
}

// present reports whether the words are the core's (magic and a version
// this package speaks): any other core, or none, leaves other values.
func (c *ctrl) present() bool {
	if c.word(wMagic) != coreMagic {
		return false
	}
	v := c.lo(wVersion) & 0xFFFF
	return v>>8 == ifMajor && v&0xFF >= ifMinor && c.hi(wGeometry) == ringSize
}

// alive reports whether the heartbeat moves within the given time.
func (c *ctrl) alive(within time.Duration) bool {
	if !c.present() {
		return false
	}
	s0 := c.lo(wSeqHead)
	deadline := time.Now().Add(within)
	for {
		if c.lo(wSeqHead) != s0 {
			return true
		}
		if !time.Now().Before(deadline) {
			return false
		}
		c.sleep(2 * time.Millisecond)
	}
}

// input copies the input region (words 48..71) consistently: in_tail
// (word 71) first, the words, in_head (word 48) last, again until they
// agree (h264ring_input). False if the core kept writing.
func (c *ctrl) input(dst *[inWords]uint64) bool {
	for try := 0; try < 200; try++ {
		tail := c.lo(wInput + inWords - 1)
		for i := range dst {
			dst[i] = c.word(wInput + i)
		}
		if c.lo(wInput) == tail && uint32(dst[0]) == tail && uint32(dst[inWords-1]) == tail {
			return true
		}
		c.sleep(50 * time.Microsecond)
	}
	return false
}

// desc is an overlay descriptor (words 73..77).
type desc struct {
	on            bool
	format        uint32
	base          uint32 // physical byte address, a multiple of 8
	width, height uint32
	stride        uint32
	first, last   uint32 // the band: the only lines the core fetches
}

// check refuses what the core would (h264ring_overlay_check), 0 if fine.
func (d desc) check() int {
	if !d.on {
		return 0
	}
	if d.format > FmtARGB8888 {
		return 1
	}
	if d.width < 1 || d.width > ovlMaxSide || d.height < 1 || d.height > ovlMaxSide {
		return 2
	}
	bpp := uint32(2)
	if d.format == FmtARGB8888 {
		bpp = 4
	}
	if d.stride%8 != 0 || d.stride < d.width*bpp || d.stride > 0xFFFF {
		return 3
	}
	if d.base%8 != 0 {
		return 4
	}
	if d.first > d.last || d.last >= d.height {
		return 5
	}
	end := uint64(d.height-1)*uint64(d.stride) + uint64(d.width*bpp)
	if d.base < fbByte || uint64(d.base)+end > fbByte+fbSize {
		return 6
	}
	return 0
}

// writeDesc publishes a descriptor under generation gen: word 79 FIRST,
// the fields, word 72 LAST, a barrier between each step (the core's burst
// reads 72 first and 79 last and takes the words only when they agree).
// Each atomic store is fenced on both sides, so the order holds.
func (c *ctrl) writeDesc(d desc, gen uint32) {
	c.setLo(wOvlGenHi, gen)
	var ctl, base, size, stride, band uint32
	if d.on {
		ctl = ovlEnable | d.format<<ovlFmtLSB
		base, size, stride, band = d.base, d.height<<16|d.width, d.stride, d.last<<16|d.first
	}
	c.setLo(wOvlCtl, ctl)
	c.setLo(wOvlBase, base)
	c.setLo(wOvlSize, size)
	c.setLo(wOvlStride, stride)
	c.setLo(wOvlBand, band)
	c.setLo(wOvlRsvd, 0)
	c.setLo(wOvlGenLo, gen)
}

// readDesc reads words 73..77 back as a descriptor (an off one with all
// fields 0, as writeDesc writes it).
func (c *ctrl) readDesc() desc {
	ctl := c.lo(wOvlCtl)
	if ctl&ovlEnable == 0 {
		return desc{}
	}
	size, band := c.lo(wOvlSize), c.lo(wOvlBand)
	return desc{
		on: true, format: ctl >> ovlFmtLSB & 3, base: c.lo(wOvlBase),
		width: size & 0xFFFF, height: size >> 16, stride: c.lo(wOvlStride),
		first: band & 0xFFFF, last: band >> 16,
	}
}

// nextGen is a generation newer than ours, than what is in word 72 and
// than what the core last read, never 0, in 31 bits (as the library keeps
// it): the player's library numbers its own descriptors from 1, so a
// private counter could fall behind what the core reports and every wait
// would then time out.
func nextGen(ours, inWord, core uint32) uint32 {
	g := ours
	for _, v := range [...]uint32{inWord, core} {
		if int32((v-g)<<1) > 0 { // v ahead of g, in 31-bit serial arithmetic
			g = v
		}
	}
	g = (g + 1) & 0x7FFFFFFF
	if g == 0 {
		g = 1
	}
	return g
}

// genReached reports whether a status generation is at or past gen (in
// 31-bit serial arithmetic, as h264ring_overlay_wait compares).
func genReached(core, gen uint32) bool { return int32((core-gen)<<1) >= 0 }
