package ring

import (
	"encoding/binary"
	"math"
	"math/rand/v2"
	"os"
	"sync"
	"sync/atomic"
)

// The navigation tick. The PlexCRT core clicked in its FPGA mixer; the
// H.264 core has none, so the app writes a short synthesised tick straight
// to MiSTer's audio device (raw 48 kHz stereo S16LE, the format the core's
// audio path takes) on each selection change.
//
// A slightly different note each time: the notes are a major pentatonic
// scale on tickBase (0, 2, 4, 7 and 9 semitones up, about 1.5 to
// 2.5 kHz), and each tick picks one at random but never the previous one,
// so a run of moves sounds like a soft, varied patter rather than one
// repeated click. Tune by ear here: the base, the steps, the length, the
// decay and the level.
const (
	tickBase      = 1500.0 // Hz, the lowest note
	tickMillis    = 12     // length of one tick
	tickDecay     = 2.5    // decay time constant, in milliseconds
	tickAmplitude = 9000   // peak level, of 32767
	tickRate      = 48000  // samples per second per channel
)

// tickSteps are the notes, in semitones above tickBase.
var tickSteps = [...]int{0, 2, 4, 7, 9}

// TickDevice is where the tick is written; tests point it at a file.
var TickDevice = "/dev/MrAudio"

// tickNotes holds one synthesised buffer per step.
var tickNotes = func() [][]byte {
	notes := make([][]byte, len(tickSteps))
	for i, s := range tickSteps {
		notes[i] = synthTick(tickBase * math.Pow(2, float64(s)/12))
	}
	return notes
}()

// synthTick is a sine burst at freq with an exponential decay, as
// interleaved stereo S16LE. The last 1 ms fades linearly to zero so the
// tick ends without a click of its own.
func synthTick(freq float64) []byte {
	n := tickRate * tickMillis / 1000
	fade := tickRate / 1000
	buf := make([]byte, n*4)
	for i := 0; i < n; i++ {
		t := float64(i) / tickRate
		env := math.Exp(-t * 1000 / tickDecay)
		if rest := n - i; rest < fade {
			env *= float64(rest-1) / float64(fade)
		}
		v := int16(math.Round(tickAmplitude * env * math.Sin(2*math.Pi*freq*t)))
		binary.LittleEndian.PutUint16(buf[i*4:], uint16(v))
		binary.LittleEndian.PutUint16(buf[i*4+2:], uint16(v))
	}
	return buf
}

// ticker writes ticks from one goroutine at a time: a tick asked for while
// the last is still being written is dropped, never queued.
type ticker struct {
	busy atomic.Bool
	mu   sync.Mutex // the device and last note, held by the one writer
	dev  *os.File
	last int
}

var tick = ticker{last: -1}

// nextNote picks a note other than the last one.
func (k *ticker) nextNote() int {
	n := rand.IntN(len(tickNotes) - 1)
	if k.last >= 0 && n >= k.last {
		n++
	}
	k.last = n
	return n
}

// play writes one note to the device, opened lazily and kept open; a
// failed write closes it so the next tick reopens it. A missing device
// (development machines, tests) is silent.
func (k *ticker) play() {
	k.mu.Lock()
	defer k.mu.Unlock()
	note := tickNotes[k.nextNote()]
	if k.dev == nil {
		f, err := os.OpenFile(TickDevice, os.O_WRONLY, 0)
		if err != nil {
			return
		}
		k.dev = f
	}
	if _, err := k.dev.Write(note); err != nil {
		k.dev.Close()
		k.dev = nil
	}
}

// start plays a tick in the background unless one is still being written.
func (k *ticker) start() {
	if !k.busy.CompareAndSwap(false, true) {
		return
	}
	go func() {
		defer k.busy.Store(false)
		k.play()
	}()
}

// Tap plays the navigation tick without blocking the caller.
func (r *Ring) Tap() { tick.start() }
