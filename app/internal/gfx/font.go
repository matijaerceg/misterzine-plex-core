package gfx

import (
	"embed"
	"encoding/json"
	"fmt"
	"strings"
)

//go:embed all:fonts
var fontFS embed.FS

// Font is a prerendered proportional atlas: 95 cells of 8-bit coverage,
// ASCII 32..126, drawn with the CRT's 9/8 horizontal stretch baked in.
type Font struct {
	Name  string
	Px    int
	cellW int
	cellH int
	ox    int
	adv   [95]int
	pix   []byte
}

// Height is the cell height, the line pitch to use for stacked text.
func (f *Font) Height() int { return f.cellH }

var fonts = map[string]*Font{}

// Load returns the named atlas (reg16, med18, bold22, cond18, ...).
func Load(name string) *Font {
	if f, ok := fonts[name]; ok {
		return f
	}
	meta, err := fontFS.ReadFile("fonts/" + name + ".json")
	if err != nil {
		panic(fmt.Sprintf("font %s: %v", name, err))
	}
	var m struct {
		Px, CellW, CellH, Ox int
		Adv                  []int
	}
	if err := json.Unmarshal(meta, &m); err != nil {
		panic(fmt.Sprintf("font %s: %v", name, err))
	}
	pix, err := fontFS.ReadFile("fonts/" + name + ".a8")
	if err != nil {
		panic(fmt.Sprintf("font %s: %v", name, err))
	}
	f := &Font{Name: name, Px: m.Px, cellW: m.CellW, cellH: m.CellH, ox: m.Ox, pix: pix}
	copy(f.adv[:], m.Adv)
	fonts[name] = f
	return f
}

func glyph(ch byte) int {
	if ch < 32 || ch > 126 {
		return '?' - 32
	}
	return int(ch) - 32
}

// Width measures a string in pixels.
func (f *Font) Width(s string) int {
	w := 0
	for i := 0; i < len(s); i++ {
		w += f.adv[glyph(s[i])]
	}
	return w
}

// InkBounds measures visible glyph pixels relative to the text origin, ignoring
// the atlas padding. Callers placing fixed labels can cache the result.
func (f *Font) InkBounds(s string) (left, top, width, height int) {
	left, top = f.Width(s)+f.cellW, f.cellH
	right, bottom, pen := -1, -1, 0
	for i := 0; i < len(s); i++ {
		gi := glyph(s[i])
		pix := f.pix[gi*f.cellW*f.cellH:]
		for y := 0; y < f.cellH; y++ {
			for x := 0; x < f.cellW; x++ {
				if pix[y*f.cellW+x] == 0 {
					continue
				}
				left, top = min(left, pen+x-f.ox), min(top, y)
				right, bottom = max(right, pen+x-f.ox), max(bottom, y)
			}
		}
		pen += f.adv[gi]
	}
	if right < left {
		return 0, 0, 0, 0
	}
	return left, top, right - left + 1, bottom - top + 1
}

// Fit truncates s with an ellipsis so it fits in maxW pixels.
func (f *Font) Fit(s string, maxW int) string {
	if f.Width(s) <= maxW {
		return s
	}
	ell := f.Width("...")
	for n := len(s) - 1; n > 0; n-- {
		t := strings.TrimRight(s[:n], " ")
		if f.Width(t)+ell <= maxW {
			return t + "..."
		}
	}
	return ""
}

// Text draws s with its cell top at y and returns the x after the last glyph.
func (c *Canvas) Text(x, y int, f *Font, col Color, s string) int {
	return c.TextAlpha(x, y, f, col, 255, s)
}

// TextAlpha is Text with the glyphs' coverage scaled by alpha (0..255), so
// the text shows through to what is under it: 128 is half-transparent.
func (c *Canvas) TextAlpha(x, y int, f *Font, col Color, alpha int, s string) int {
	b, g, r := int(byte(col)), int(byte(col>>8)), int(byte(col>>16))
	for i := 0; i < len(s); i++ {
		gi := glyph(s[i])
		src := f.pix[gi*f.cellW*f.cellH:]
		for yy := 0; yy < f.cellH; yy++ {
			py := y + yy
			if py < 0 || py >= c.H {
				continue
			}
			row := src[yy*f.cellW : (yy+1)*f.cellW]
			for xx, a := range row {
				if a == 0 {
					continue
				}
				px := x + xx - f.ox
				if px < 0 || px >= c.W {
					continue
				}
				o := (py*c.W + px) * 4
				if alpha < 255 {
					a = byte(int(a) * alpha / 255)
					if a == 0 {
						continue
					}
				}
				if a == 255 {
					c.Pix[o], c.Pix[o+1], c.Pix[o+2] = byte(b), byte(g), byte(r)
					continue
				}
				p := c.Pix[o : o+3 : o+3]
				p[0] += byte((b - int(p[0])) * int(a) / 255)
				p[1] += byte((g - int(p[1])) * int(a) / 255)
				p[2] += byte((r - int(p[2])) * int(a) / 255)
			}
		}
		x += f.adv[gi]
	}
	return x
}

// TextRight draws s ending at x.
func (c *Canvas) TextRight(x, y int, f *Font, col Color, s string) {
	c.Text(x-f.Width(s), y, f, col, s)
}

// TextCenter draws s centred on x.
func (c *Canvas) TextCenter(x, y int, f *Font, col Color, s string) {
	c.Text(x-f.Width(s)/2, y, f, col, s)
}
