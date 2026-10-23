package ring

import (
	"bytes"
	"encoding/binary"
	"os"
	"path/filepath"
	"testing"
)

func TestTickNotes(t *testing.T) {
	want := tickRate * tickMillis / 1000 * 4
	if len(tickNotes) != len(tickSteps) {
		t.Fatalf("%d notes for %d steps", len(tickNotes), len(tickSteps))
	}
	for i, n := range tickNotes {
		if len(n) != want {
			t.Fatalf("note %d: %d bytes, want %d", i, len(n), want)
		}
		peak := 0
		for j := 0; j < len(n); j += 4 {
			l := int(int16(binary.LittleEndian.Uint16(n[j:])))
			r := int(int16(binary.LittleEndian.Uint16(n[j+2:])))
			if l != r {
				t.Fatalf("note %d: channels differ at %d", i, j/4)
			}
			peak = max(peak, l, -l)
		}
		if peak > tickAmplitude || peak < tickAmplitude/4 {
			t.Fatalf("note %d: peak %d", i, peak)
		}
		if last := int16(binary.LittleEndian.Uint16(n[len(n)-4:])); last != 0 {
			t.Fatalf("note %d ends at %d", i, last)
		}
		for k := 0; k < i; k++ {
			if bytes.Equal(n, tickNotes[k]) {
				t.Fatalf("notes %d and %d are the same", k, i)
			}
		}
	}
}

func TestTickNeverRepeats(t *testing.T) {
	k := ticker{last: -1}
	seen := map[int]bool{}
	prev := -1
	for i := 0; i < 1000; i++ {
		n := k.nextNote()
		if n == prev || n < 0 || n >= len(tickNotes) {
			t.Fatalf("note %d after %d", n, prev)
		}
		seen[n], prev = true, n
	}
	if len(seen) != len(tickNotes) {
		t.Fatalf("only %d of %d notes used", len(seen), len(tickNotes))
	}
}

func TestTickWritesANote(t *testing.T) {
	old := TickDevice
	defer func() { TickDevice = old }()
	TickDevice = filepath.Join(t.TempDir(), "audio")
	k := ticker{last: -1}
	k.play() // missing device: silent
	if k.dev != nil {
		t.Fatal("opened a missing device")
	}
	if err := os.WriteFile(TickDevice, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	k.play()
	k.dev.Close()
	got, err := os.ReadFile(TickDevice)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, tickNotes[k.last]) {
		t.Fatalf("wrote %d bytes, not note %d", len(got), k.last)
	}
}

func TestTickDropsWhileBusy(t *testing.T) {
	k := ticker{last: -1}
	k.busy.Store(true)
	k.start()
	if k.last != -1 {
		t.Fatal("tick ran while one was in flight")
	}
}
