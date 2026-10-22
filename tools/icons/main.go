// Command icons rasterises the playback bar's Lucide icons to 8-bit alpha
// masks for the app to embed. Run it from this directory: go run .
//
// It reads app/internal/ui/icons/<name>.svg and writes <name>.png beside
// each, a greyscale PNG cropped to the icon's ink. Lucide draws every icon
// as round-capped, round-joined 2-unit strokes on a 24-unit grid; this
// draws them as the union of round-ended segments of a fixed width in
// output pixels (strokeW), so a small icon keeps strokes as heavy as a big
// one, with 8x8 samples a pixel. It handles the SVG subset Lucide uses
// (path, rect, circle, line, polyline, polygon; fill="none"). Standard
// library only, and the same input always gives the same bytes.
package main

import (
	"bytes"
	"encoding/xml"
	"fmt"
	"image"
	"image/png"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// The icons and the pixel size of their 24-unit grid. The bar's glyphs are
// the Body font's height less 4 (25 - 4 = 21); the jump arrows are smaller,
// to leave room for the "10" in the narrow -10 / +10 cells.
var icons = []struct {
	name string
	size float64
}{
	{"rotate-ccw", 12},
	{"rotate-cw", 12},
	{"pause", 21},
	{"play", 21},
	{"skip-back", 21},
	{"skip-forward", 21},
	{"volume-2", 21},
	{"captions", 21},
	{"ellipsis", 21},
}

const (
	strokeW = 2.0 // the stroke width in output pixels
	samples = 8   // per pixel, per axis
)

func main() {
	dir := filepath.Join("..", "..", "app", "internal", "ui", "icons")
	if len(os.Args) > 1 {
		dir = os.Args[1]
	}
	for _, ic := range icons {
		src, err := os.ReadFile(filepath.Join(dir, ic.name+".svg"))
		if err != nil {
			fail(err)
		}
		lines, err := parseSVG(src)
		if err != nil {
			fail(fmt.Errorf("%s: %v", ic.name, err))
		}
		var buf bytes.Buffer
		if err := png.Encode(&buf, raster(lines, ic.size)); err != nil {
			fail(err)
		}
		if err := os.WriteFile(filepath.Join(dir, ic.name+".png"), buf.Bytes(), 0o644); err != nil {
			fail(err)
		}
	}
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "icons:", err)
	os.Exit(1)
}

type pt struct{ x, y float64 }

// polyline is one flattened subpath in grid units.
type polyline []pt

// raster draws the strokes at size pixels to the grid and crops to the ink.
func raster(lines []polyline, size float64) *image.Gray {
	const pad = 3
	n := int(math.Ceil(size)) + 2*pad
	s := size / 24
	type seg struct{ a, b pt }
	var segs []seg
	for _, l := range lines {
		for i := range l {
			a := pt{l[i].x*s + pad, l[i].y*s + pad}
			b := a
			if i+1 < len(l) {
				b = pt{l[i+1].x*s + pad, l[i+1].y*s + pad}
			} else if len(l) > 1 {
				continue
			}
			segs = append(segs, seg{a, b})
		}
	}
	hw := strokeW / 2
	img := image.NewGray(image.Rect(0, 0, n, n))
	for py := range n {
		for px := range n {
			hit := 0
			for sy := range samples {
				for sx := range samples {
					p := pt{float64(px) + (float64(sx)+0.5)/samples, float64(py) + (float64(sy)+0.5)/samples}
					for _, g := range segs {
						if dist(p, g.a, g.b) <= hw {
							hit++
							break
						}
					}
				}
			}
			img.Pix[py*img.Stride+px] = byte((hit*255 + samples*samples/2) / (samples * samples))
		}
	}
	// crop to the ink
	x0, y0, x1, y1 := n, n, -1, -1
	for y := range n {
		for x := range n {
			if img.Pix[y*img.Stride+x] != 0 {
				x0, y0, x1, y1 = min(x0, x), min(y0, y), max(x1, x), max(y1, y)
			}
		}
	}
	out := image.NewGray(image.Rect(0, 0, x1-x0+1, y1-y0+1))
	for y := y0; y <= y1; y++ {
		copy(out.Pix[(y-y0)*out.Stride:], img.Pix[y*img.Stride+x0:y*img.Stride+x1+1])
	}
	return out
}

// dist is p's distance from the segment a-b.
func dist(p, a, b pt) float64 {
	dx, dy := b.x-a.x, b.y-a.y
	t := 0.0
	if l := dx*dx + dy*dy; l > 0 {
		t = math.Max(0, math.Min(1, ((p.x-a.x)*dx+(p.y-a.y)*dy)/l))
	}
	return math.Hypot(p.x-a.x-t*dx, p.y-a.y-t*dy)
}

// parseSVG flattens the drawing elements of an SVG into polylines.
func parseSVG(src []byte) ([]polyline, error) {
	d := xml.NewDecoder(bytes.NewReader(src))
	var out []polyline
	for {
		tok, err := d.Token()
		if err != nil {
			break
		}
		el, ok := tok.(xml.StartElement)
		if !ok {
			continue
		}
		at := map[string]string{}
		for _, a := range el.Attr {
			at[a.Name.Local] = a.Value
		}
		f := func(k string) float64 { v, _ := strconv.ParseFloat(at[k], 64); return v }
		var path string
		switch el.Name.Local {
		case "svg":
			if at["viewBox"] != "0 0 24 24" || at["fill"] != "none" {
				return nil, fmt.Errorf("not a Lucide icon: viewBox %q fill %q", at["viewBox"], at["fill"])
			}
			continue
		case "path":
			path = at["d"]
		case "line":
			path = fmt.Sprintf("M%g %g L%g %g", f("x1"), f("y1"), f("x2"), f("y2"))
		case "polyline", "polygon":
			path = "M" + at["points"]
			if el.Name.Local == "polygon" {
				path += "Z"
			}
		case "circle":
			cx, cy, r := f("cx"), f("cy"), f("r")
			path = fmt.Sprintf("M%g %g A%g %g 0 1 0 %g %g A%g %g 0 1 0 %g %g Z", cx-r, cy, r, r, cx+r, cy, r, r, cx-r, cy)
		case "rect":
			x, y, w, h, rx, ry := f("x"), f("y"), f("width"), f("height"), f("rx"), f("ry")
			if _, ok := at["ry"]; !ok {
				ry = rx
			}
			if _, ok := at["rx"]; !ok {
				rx = ry
			}
			path = fmt.Sprintf("M%g %g H%g A%g %g 0 0 1 %g %g V%g A%g %g 0 0 1 %g %g H%g A%g %g 0 0 1 %g %g V%g A%g %g 0 0 1 %g %gZ",
				x+rx, y, x+w-rx, rx, ry, x+w, y+ry, y+h-ry, rx, ry, x+w-rx, y+h, x+rx, rx, ry, x, y+h-ry, y+ry, rx, ry, x+rx, y)
		default:
			continue
		}
		ls, err := parsePath(path)
		if err != nil {
			return nil, fmt.Errorf("%s %q: %v", el.Name.Local, path, err)
		}
		out = append(out, ls...)
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("nothing to draw")
	}
	return out, nil
}

// pathLexer reads SVG path data: commands, numbers and arc flags.
type pathLexer struct {
	s string
	i int
}

func (l *pathLexer) skip() {
	for l.i < len(l.s) && strings.ContainsRune(" \t\r\n,", rune(l.s[l.i])) {
		l.i++
	}
}

func (l *pathLexer) number() (float64, error) {
	l.skip()
	j := l.i
	if j < len(l.s) && (l.s[j] == '-' || l.s[j] == '+') {
		j++
	}
	dot, exp := false, false
	for j < len(l.s) {
		c := l.s[j]
		switch {
		case c >= '0' && c <= '9':
		case c == '.' && !dot && !exp:
			dot = true
		case (c == 'e' || c == 'E') && !exp:
			exp = true
			if j+1 < len(l.s) && (l.s[j+1] == '-' || l.s[j+1] == '+') {
				j++
			}
		default:
			goto done
		}
		j++
	}
done:
	v, err := strconv.ParseFloat(l.s[l.i:j], 64)
	if err != nil {
		return 0, fmt.Errorf("number at %d", l.i)
	}
	l.i = j
	return v, nil
}

func (l *pathLexer) flag() (bool, error) {
	l.skip()
	if l.i < len(l.s) && (l.s[l.i] == '0' || l.s[l.i] == '1') {
		l.i++
		return l.s[l.i-1] == '1', nil
	}
	return false, fmt.Errorf("flag at %d", l.i)
}

// atNumber reports whether a number (an implicit repeat) comes next.
func (l *pathLexer) atNumber() bool {
	l.skip()
	return l.i < len(l.s) && strings.ContainsRune("+-.0123456789", rune(l.s[l.i]))
}

func parsePath(d string) ([]polyline, error) {
	l := &pathLexer{s: d}
	var out []polyline
	var cur polyline
	var p, start, ctrl pt
	var cmd byte
	nums := func(n int) ([]float64, error) {
		v := make([]float64, n)
		for i := range v {
			var err error
			if v[i], err = l.number(); err != nil {
				return nil, err
			}
		}
		return v, nil
	}
	flush := func() {
		if len(cur) > 0 {
			out = append(out, cur)
		}
		cur = nil
	}
	for {
		l.skip()
		if l.i >= len(l.s) {
			break
		}
		if c := l.s[l.i]; strings.IndexByte("MmLlHhVvCcSsAaZz", c) >= 0 {
			cmd = c
			l.i++
		} else if cmd == 0 {
			return nil, fmt.Errorf("no command at %d", l.i)
		}
		rel := cmd >= 'a'
		base := pt{}
		if rel {
			base = p
		}
		prevCtrl := ctrl
		ctrl = pt{math.NaN(), 0}
		switch cmd | 0x20 {
		case 'm':
			v, err := nums(2)
			if err != nil {
				return nil, err
			}
			flush()
			p = pt{base.x + v[0], base.y + v[1]}
			start = p
			cur = polyline{p}
			// further pairs are lines
			if rel {
				cmd = 'l'
			} else {
				cmd = 'L'
			}
		case 'l':
			v, err := nums(2)
			if err != nil {
				return nil, err
			}
			p = pt{base.x + v[0], base.y + v[1]}
			cur = append(cur, p)
		case 'h':
			v, err := nums(1)
			if err != nil {
				return nil, err
			}
			p.x = base.x + v[0]
			if !rel {
				p.x = v[0]
			}
			cur = append(cur, p)
		case 'v':
			v, err := nums(1)
			if err != nil {
				return nil, err
			}
			p.y = base.y + v[0]
			if !rel {
				p.y = v[0]
			}
			cur = append(cur, p)
		case 'c', 's':
			n := 6
			if cmd|0x20 == 's' {
				n = 4
			}
			v, err := nums(n)
			if err != nil {
				return nil, err
			}
			var c1 pt
			if n == 6 {
				c1 = pt{base.x + v[0], base.y + v[1]}
				v = v[2:]
			} else if !math.IsNaN(prevCtrl.x) {
				c1 = pt{2*p.x - prevCtrl.x, 2*p.y - prevCtrl.y}
			} else {
				c1 = p
			}
			c2 := pt{base.x + v[0], base.y + v[1]}
			e := pt{base.x + v[2], base.y + v[3]}
			for i := 1; i <= 32; i++ {
				t := float64(i) / 32
				u := 1 - t
				cur = append(cur, pt{
					u*u*u*p.x + 3*u*u*t*c1.x + 3*u*t*t*c2.x + t*t*t*e.x,
					u*u*u*p.y + 3*u*u*t*c1.y + 3*u*t*t*c2.y + t*t*t*e.y,
				})
			}
			p, ctrl = e, c2
		case 'a':
			r, err := nums(3)
			if err != nil {
				return nil, err
			}
			large, err := l.flag()
			if err != nil {
				return nil, err
			}
			sweep, err := l.flag()
			if err != nil {
				return nil, err
			}
			v, err := nums(2)
			if err != nil {
				return nil, err
			}
			e := pt{base.x + v[0], base.y + v[1]}
			cur = append(cur, arc(p, e, r[0], r[1], r[2], large, sweep)...)
			p = e
		case 'z':
			if len(cur) > 0 {
				cur = append(cur, start)
			}
			p = start
			flush()
			cur = polyline{p}
			cmd = 0
			if l.atNumber() {
				return nil, fmt.Errorf("number after Z at %d", l.i)
			}
		}
	}
	flush()
	// a lone point after Z is not a drawing
	kept := out[:0]
	for _, pl := range out {
		if len(pl) > 1 {
			kept = append(kept, pl)
		}
	}
	return kept, nil
}

// arc flattens an SVG elliptical arc from a to b (SVG 1.1 F.6.5), b last.
func arc(a, b pt, rx, ry, rotDeg float64, large, sweep bool) []pt {
	rx, ry = math.Abs(rx), math.Abs(ry)
	if rx == 0 || ry == 0 || a == b {
		return []pt{b}
	}
	phi := rotDeg * math.Pi / 180
	cp, sp := math.Cos(phi), math.Sin(phi)
	dx, dy := (a.x-b.x)/2, (a.y-b.y)/2
	x1 := cp*dx + sp*dy
	y1 := -sp*dx + cp*dy
	if lam := x1*x1/(rx*rx) + y1*y1/(ry*ry); lam > 1 {
		rx, ry = rx*math.Sqrt(lam), ry*math.Sqrt(lam)
	}
	num := rx*rx*ry*ry - rx*rx*y1*y1 - ry*ry*x1*x1
	den := rx*rx*y1*y1 + ry*ry*x1*x1
	k := math.Sqrt(math.Max(0, num/den))
	if large == sweep {
		k = -k
	}
	cx1, cy1 := k*rx*y1/ry, -k*ry*x1/rx
	cx := cp*cx1 - sp*cy1 + (a.x+b.x)/2
	cy := sp*cx1 + cp*cy1 + (a.y+b.y)/2
	ang := func(ux, uy, vx, vy float64) float64 {
		return math.Atan2(ux*vy-uy*vx, ux*vx+uy*vy)
	}
	t1 := ang(1, 0, (x1-cx1)/rx, (y1-cy1)/ry)
	dt := ang((x1-cx1)/rx, (y1-cy1)/ry, (-x1-cx1)/rx, (-y1-cy1)/ry)
	if !sweep && dt > 0 {
		dt -= 2 * math.Pi
	} else if sweep && dt < 0 {
		dt += 2 * math.Pi
	}
	n := max(4, int(math.Ceil(math.Abs(dt)/(math.Pi/32))))
	out := make([]pt, 0, n)
	for i := 1; i < n; i++ {
		t := t1 + dt*float64(i)/float64(n)
		x, y := rx*math.Cos(t), ry*math.Sin(t)
		out = append(out, pt{cp*x - sp*y + cx, sp*x + cp*y + cy})
	}
	return append(out, b)
}
