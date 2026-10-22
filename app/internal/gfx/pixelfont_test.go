package gfx

import (
	"bytes"
	"testing"
)

func TestPixelFontMeasuresCellsWithoutTheLastGap(t *testing.T) {
	f := PixelFont{SX: 3, SY: 4}
	if f.Height() != 28 || f.Width("") != 0 || f.Width("A") != 15 || f.Width("AB") != 33 {
		t.Fatalf("height %d, widths %d %d %d; want 28, 0, 15, 33", f.Height(), f.Width(""), f.Width("A"), f.Width("AB"))
	}
	if f.Width("é") != f.Width("E") {
		t.Fatal("an accented letter is not one cell")
	}
	if got := f.Fit("ABCDEFGH", f.Width("ABC...")); got != "ABC..." {
		t.Fatalf("Fit = %q, want ABC...", got)
	}
	if got := f.Fit("AB", f.Width("AB")); got != "AB" {
		t.Fatalf("Fit of what fits = %q", got)
	}
}

// The blocks: the cell's lit columns SX wide and its rows SY tall, white,
// with the black shadow two pixels right and down where white does not
// cover it.
func TestPixelTextDrawsBlocksWithAShadow(t *testing.T) {
	c := NewCanvas(40, 30)
	c.Fill(0, 0, c.W, c.H, 0xFF0000)
	f := PixelFont{SX: 2, SY: 3}
	if x := c.PixelText(0, 0, f, White, Black, "I"); x != 12 {
		t.Fatalf("PixelText returned x %d, want 12", x)
	}
	at := func(x, y int) Color {
		o := (y*c.W + x) * 4
		return Color(c.Pix[o+2])<<16 | Color(c.Pix[o+1])<<8 | Color(c.Pix[o])
	}
	// I's top row is columns 1..3: pixels 2..7 of rows 0..2
	for _, p := range [][2]int{{2, 0}, {7, 2}} {
		if got := at(p[0], p[1]); got != White {
			t.Fatalf("pixel %v = %06x, want white", p, got)
		}
	}
	if got := at(1, 0); got != 0xFF0000 {
		t.Fatalf("pixel left of the cell = %06x, want the background", got)
	}
	if got := at(8, 2); got != Black {
		t.Fatalf("shadow pixel = %06x, want black", got)
	}
}

func TestPixelFontDrawsCapitalsForEverything(t *testing.T) {
	f := PixelFont{SX: 1, SY: 1}
	draw := func(s string) []byte {
		c := NewCanvas(60, 10)
		c.PixelText(0, 0, f, White, White, s)
		return c.Pix
	}
	for _, pair := range [][2]string{{"abc", "ABC"}, {"Éé", "EE"}, {"中", "?"}} {
		if !bytes.Equal(draw(pair[0]), draw(pair[1])) {
			t.Fatalf("%q is not drawn as %q", pair[0], pair[1])
		}
	}
	if bytes.Equal(draw("Z"), draw(" ")) || bytes.Equal(draw(string(PixelPlay)), draw("?")) {
		t.Fatal("a letter or a symbol has no cell")
	}
}
