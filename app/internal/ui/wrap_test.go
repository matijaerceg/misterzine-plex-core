package ui

import (
	"reflect"
	"strings"
	"testing"

	"plexcrt/internal/gfx"
)

// oldSplitWords and oldWrap are the versions that built every word a
// character at a time; the rewrite must give the same lines.
func oldSplitWords(s string) []string {
	var out []string
	w := ""
	for i := 0; i < len(s); i++ {
		if s[i] == ' ' {
			if w != "" {
				out = append(out, w)
			}
			w = ""
			continue
		}
		w += string(s[i])
	}
	if w != "" {
		out = append(out, w)
	}
	return out
}

func oldWrap(f *gfx.Font, s string, maxW, n int) []string {
	var out []string
	line := ""
	for _, w := range oldSplitWords(s) {
		t := w
		if line != "" {
			t = line + " " + w
		}
		if f.Width(t) <= maxW || line == "" {
			line = t
			continue
		}
		if len(out) == n-1 {
			out = append(out, f.Fit(t+" "+strings.Repeat(".", 3), maxW))
			return out
		}
		out = append(out, line)
		line = w
	}
	if line != "" {
		out = append(out, f.Fit(line, maxW))
	}
	return out
}

var wrapCases = []string{
	"",
	" ",
	"     ",
	"one",
	" one",
	"one ",
	"  one  two   three  ",
	"one\ntwo\n\nthree", // newlines are not breaks
	"tab\tseparated\twords",
	"Supercalifragilisticexpialidocious-and-then-some-more-without-a-break at all",
	"a b c d e f g h i j k l m n o p q r s t u v w x y z a b c d e f g h i j k l m n o p",
	"After the fall of the city, a small band of survivors crosses the frozen north in search of the last ship said to sail before winter closes the sea.",
	"x                                                                         y",
}

func TestSplitWordsMatchesOld(t *testing.T) {
	for _, s := range wrapCases {
		if got, want := splitWords(s), oldSplitWords(s); !reflect.DeepEqual(got, want) {
			t.Errorf("splitWords(%q) = %q, want %q", s, got, want)
		}
	}
	// past ASCII the old version turned each byte into a rune of its
	// own ("é" came out as "Ã©"); the words are now the input's bytes
	if got := splitWords("café  crème"); !reflect.DeepEqual(got, []string{"café", "crème"}) {
		t.Errorf("splitWords kept %q, want the input's bytes", got)
	}
}

func TestWrapMatchesOld(t *testing.T) {
	for _, name := range []string{"reg16", "med18"} {
		f := gfx.Load(name)
		for _, s := range wrapCases {
			for _, maxW := range []int{0, 40, 120, 300, 600} {
				for _, n := range []int{0, 1, 2, 4, 1 << 20} {
					if got, want := wrap(f, s, maxW, n), oldWrap(f, s, maxW, n); !reflect.DeepEqual(got, want) {
						t.Errorf("%s wrap(%q, %d, %d) = %q, want %q", name, s, maxW, n, got, want)
					}
				}
			}
		}
	}
}

// wrapped gives wrap's lines, wraps text drawn every frame only once, and
// holds no more than two generations.
func TestWrappedRemembers(t *testing.T) {
	f := gfx.Load("reg16")
	s := wrapCases[11]
	if got, want := wrapped(f, s, 300, 4), wrap(f, s, 300, 4); !reflect.DeepEqual(got, want) {
		t.Fatalf("wrapped = %q, want %q", got, want)
	}
	if n := testing.AllocsPerRun(10, func() { wrapped(f, s, 300, 4) }); n != 0 {
		t.Fatalf("a remembered wrap allocates %v times", n)
	}
	for i := 0; i < 5*wrapGen; i++ {
		wrapped(f, "title "+itoa(i), 120, 4)
		if n := testing.AllocsPerRun(1, func() { wrapped(f, s, 300, 4) }); n != 0 {
			t.Fatalf("the wrap in use was forgotten after %d others", i+1)
		}
	}
	wraps.mu.Lock()
	n := len(wraps.cur) + len(wraps.old)
	wraps.mu.Unlock()
	if n > 2*wrapGen {
		t.Fatalf("%d wraps remembered, want at most %d", n, 2*wrapGen)
	}
}

var benchSummary = "After the fall of the city, a small band of survivors crosses the frozen north in search of the last ship said to sail before winter closes the sea. On the way they find that the ship was never meant for them."

func BenchmarkSplitWords(b *testing.B) {
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		splitWords(benchSummary)
	}
}

func BenchmarkWrapSummary(b *testing.B) {
	f := gfx.Load("reg16")
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		wrap(f, benchSummary, 300, 6)
	}
}

func BenchmarkWrapTitle(b *testing.B) {
	f := gfx.Load("med18")
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		wrap(f, "The Lord of the Rings: The Return of the King", 170, 4)
	}
}

func BenchmarkWrappedSummary(b *testing.B) {
	f := gfx.Load("reg16")
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		wrapped(f, benchSummary, 300, 6)
	}
}
