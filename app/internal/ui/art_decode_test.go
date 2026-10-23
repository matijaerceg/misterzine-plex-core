package ui

import (
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// Decodes run one at a time whatever the worker count, so the drawing
// loop always has a runtime slot.
func TestDecodesRunOneAtATime(t *testing.T) {
	if cap(decodeSlot) != ArtDecoders || ArtDecoders != 1 {
		t.Fatalf("decode slots %d, ArtDecoders %d", cap(decodeSlot), ArtDecoders)
	}
	var running, most atomic.Int32
	var wg sync.WaitGroup
	for i := 0; i < ArtWorkers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			decoding(func() {
				n := running.Add(1)
				for {
					m := most.Load()
					if n <= m || most.CompareAndSwap(m, n) {
						break
					}
				}
				time.Sleep(5 * time.Millisecond)
				running.Add(-1)
			})
		}()
	}
	wg.Wait()
	if most.Load() != 1 {
		t.Fatalf("%d decodes ran at once", most.Load())
	}
}
