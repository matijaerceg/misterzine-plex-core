package ui

import (
	"sync"

	"plexcrt/internal/gfx"
)

// Screens drawn every field wrap the same text to the same width again
// and again (a poster's title while its picture loads, the focused item's
// summary), so wrapped keeps the lines by font, text, width and line
// count. Like the text cache it holds two generations: a full current one
// becomes the old one, and lines found in the old one move back.
type wrapKey struct {
	f       *gfx.Font
	s       string
	maxW, n int
}

const wrapGen = 128

var wraps = struct {
	mu       sync.Mutex
	cur, old map[wrapKey][]string
}{cur: make(map[wrapKey][]string, wrapGen), old: make(map[wrapKey][]string, wrapGen)}

// wrapped is wrap, remembered. The lines are shared: callers must not
// change them.
func wrapped(f *gfx.Font, s string, maxW, n int) []string {
	k := wrapKey{f, s, maxW, n}
	wraps.mu.Lock()
	defer wraps.mu.Unlock()
	if lines, ok := wraps.cur[k]; ok {
		return lines
	}
	lines, ok := wraps.old[k]
	if ok {
		delete(wraps.old, k)
	} else {
		lines = wrap(f, s, maxW, n)
	}
	if len(wraps.cur) >= wrapGen {
		clear(wraps.old)
		wraps.cur, wraps.old = wraps.old, wraps.cur
	}
	wraps.cur[k] = lines
	return lines
}
