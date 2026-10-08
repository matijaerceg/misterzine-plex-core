package ui

import (
	"context"
	"strings"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/plex"
)

// Search keeps keyboard focus independent from asynchronous results.
type Search struct {
	app                               *App
	query                             string
	key, cur                          int
	results, numbers, loading, closed bool
	items                             []*plex.Item
	recent                            []string
	message                           string
	generation                        int
	cancel                            context.CancelFunc
	labelBounds                       map[string][4]int
	labelImages                       map[string]*gfx.Image
	queryImage                        *gfx.Image
	queryDisplay                      string
}

func NewSearch(a *App) *Search {
	s := &Search{app: a}
	if a.Cfg != nil {
		s.recent = append([]string(nil), a.Cfg.RecentSearches...)
	}
	return s
}

func (s *Search) keys() []string {
	letters := "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
	toggle := "123"
	if s.numbers {
		letters = "0123456789'-&.!?():/+%=,#@"
		toggle = "ABC"
	}
	keys := make([]string, 30)
	for i, r := range letters {
		keys[i] = string(r)
	}
	keys[26], keys[27], keys[28], keys[29] = "Space", "Delete", "Clear", toggle
	return append(keys, "Results >")
}

func (s *Search) count() int {
	if strings.TrimSpace(s.query) == "" {
		return len(s.recent)
	}
	return len(s.items)
}

func (s *Search) Back() bool {
	if s.query != "" {
		s.change("")
		return true
	}
	s.closed = true
	if s.cancel != nil {
		s.cancel()
	}
	return false
}

func (s *Search) change(q string) {
	if len(q) > 64 {
		return
	}
	s.query, s.cur, s.results = q, 0, false
	s.renderQuery()
	s.items, s.message = nil, ""
	s.generation++
	if s.cancel != nil {
		s.cancel()
	}
	s.loading = strings.TrimSpace(q) != ""
	if !s.loading {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	s.cancel = cancel
	gen := s.generation
	go func() {
		defer cancel()
		timer := time.NewTimer(300 * time.Millisecond)
		defer timer.Stop()
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
		}
		items, err := s.app.Plex.Search(ctx, q)
		s.app.Later(func() { s.accept(gen, items, err) })
	}()
}

func (s *Search) accept(gen int, items []*plex.Item, err error) {
	if s.closed || gen != s.generation {
		return
	}
	s.loading = false
	if err != nil {
		s.message = "Search unavailable. Select Results to retry."
		return
	}
	s.app.aspects.apply(items)
	for _, it := range items {
		if s.app.Keep(it) && s.app.libraryShown(it) {
			s.items = append(s.items, it)
		}
	}
	if len(s.items) == 0 {
		s.message = "No matches. Try a shorter title."
	}
}

func (s *Search) enterResults() {
	if s.count() > 0 {
		s.results = true
	} else if !s.loading && strings.TrimSpace(s.query) != "" {
		s.change(s.query)
	}
}

func (s *Search) remember() {
	q := strings.TrimSpace(s.query)
	if q == "" {
		return
	}
	recent := []string{q}
	for _, old := range s.recent {
		if !strings.EqualFold(old, q) && len(recent) < 6 {
			recent = append(recent, old)
		}
	}
	s.recent = recent
	if s.app.Cfg != nil {
		s.app.Cfg.RecentSearches = append([]string(nil), recent...)
		if err := s.app.Cfg.Save(); err != nil {
			s.app.Notice = "Could not save recent searches"
			s.app.NoticeAt = time.Now()
		}
	}
}

// Keyboard edits the same query without moving the on-screen key selection.
func (s *Search) Keyboard(ev input.Event, now time.Time) bool {
	if ev.Text != 0 {
		if !ev.Release {
			s.change(s.query + string(ev.Text))
		}
		return true
	}
	if ev.ScanCode == 0x66 || ev.ScanCode == 0x171 {
		if !ev.Release && len(s.query) > 0 {
			s.change(s.query[:len(s.query)-1])
		}
		return true
	}
	if ev.ScanCode == 0x0d {
		if !ev.Release && !ev.Repeat {
			if s.results {
				s.results = false
			} else {
				s.enterResults()
			}
		}
		return true
	}
	if ev.Key == input.Enter && !s.results {
		if !ev.Release && !ev.Repeat {
			s.enterResults()
		}
		return true
	}
	return false
}

func (s *Search) Key(ev input.Event, now time.Time) {
	if ev.Release {
		return
	}
	if ev.Key == input.JumpFwd {
		s.enterResults()
		return
	}
	if ev.Key == input.JumpBack {
		s.results = false
		return
	}
	if s.results {
		switch ev.Key {
		case input.Left:
			s.results = false
		case input.Up:
			s.cur = max(0, s.cur-1)
		case input.Down:
			s.cur = min(s.count()-1, s.cur+1)
		case input.Enter:
			if ev.Repeat || s.count() == 0 {
				return
			}
			if strings.TrimSpace(s.query) == "" {
				s.change(s.recent[s.cur])
				return
			}
			s.remember()
			s.app.Open(s.items[s.cur], false)
		}
		return
	}
	switch ev.Key {
	case input.Left:
		if s.key < 30 && s.key%6 > 0 {
			s.key--
		}
	case input.Right:
		if s.key == 30 || s.key%6 == 5 {
			s.enterResults()
		} else {
			s.key++
		}
	case input.Up:
		if s.key == 30 {
			s.key = 24
		} else {
			s.key = max(0, s.key-6)
		}
	case input.Down:
		s.key = min(30, s.key+6)
	case input.Enter:
		if ev.Repeat {
			return
		}
		k := s.keys()[s.key]
		switch k {
		case "Results >":
			s.enterResults()
		case "Space":
			s.change(s.query + " ")
		case "Delete":
			if len(s.query) > 0 {
				s.change(s.query[:len(s.query)-1])
			}
		case "Clear":
			s.change("")
		case "123", "ABC":
			s.numbers = !s.numbers
		case "":
		default:
			s.change(s.query + k)
		}
	}
}

func (s *Search) Draw(c *gfx.Canvas, now time.Time) bool {
	c.Fill(0, 0, c.W, c.H, gfx.Bg)
	f := s.app.F
	text := func(x, y int, font *gfx.Font, col gfx.Color, value string) { s.app.text(c, x, y, font, col, value) }
	text(SafeX, SafeY, f.Title, gfx.White, "Search")
	if s.queryImage == nil || s.queryDisplay != s.query {
		s.renderQuery()
	}
	c.Blit(SafeX, 64, s.queryImage)
	c.Fill(SafeX, 94, SafeW, 2, gfx.Amber)
	for i, k := range s.keys() {
		x, y, w := SafeX+(i%6)*48, 116+(i/6)*45, 44
		if i == 30 {
			x, y, w = SafeX, 350, 284
		}
		col := gfx.GreyHi
		if !s.results && i == s.key {
			// Cached text is drawn over gfx.Bg; an outline keeps its backdrop
			// consistent and the focused glyph readable on the device.
			c.Fill(x, y, w, 2, gfx.Amber)
			c.Fill(x, y+36, w, 2, gfx.Amber)
			c.Fill(x, y, 2, 38, gfx.Amber)
			c.Fill(x+w-2, y, 2, 38, gfx.Amber)
			col = gfx.Amber
		}
		font := f.Body
		if len(k) > 1 {
			font = f.Small
		}
		// Short labels keep the six-column keyboard readable on a CRT.
		label := k
		if k == "Space" {
			label = "SP"
		}
		if k == "Delete" {
			label = "DEL"
		}
		if k == "Clear" {
			label = "CLR"
		}
		if s.labelBounds == nil {
			s.labelBounds = make(map[string][4]int)
		}
		cacheKey := font.Name + ":" + label
		bounds, ok := s.labelBounds[cacheKey]
		if !ok {
			left, top, width, height := font.InkBounds(label)
			bounds = [4]int{left, top, width, height}
			s.labelBounds[cacheKey] = bounds
		}
		if strip := s.labelImage(font, label, col); strip != nil {
			tx, ty := x+(w-bounds[2])/2-bounds[0], y+(38-bounds[3])/2-bounds[1]
			// Clip unused atlas padding so punctuation cannot erase the border.
			c.BlitClip(tx-1, ty, strip, x+2, y+2, w-4, 34)
		}
	}
	heading := "Matches (" + itoa(len(s.items)) + ")"
	if strings.TrimSpace(s.query) == "" {
		heading = "Recent searches"
	}
	if s.loading {
		heading = "Searching..."
	}
	text(352, 112, f.Body, gfx.GreyHi, heading)
	first := max(0, s.cur-5)
	for i := first; i < min(s.count(), first+6); i++ {
		y := 150 + (i-first)*40
		title, detail := "", ""
		if strings.TrimSpace(s.query) == "" {
			title = s.recent[i]
		} else {
			it := s.items[i]
			title = it.Title
			detail = "Movie"
			if it.Type == "show" {
				detail = "Show"
			}
			if it.Year > 0 {
				detail += "  " + itoa(it.Year)
			}
		}
		if s.results && s.cur == i {
			c.Fill(338, y, 4, f.Body.Height(), gfx.Amber)
		}
		text(352, y, f.Body, gfx.White, f.Body.Fit(title, SafeX+SafeW-352))
		text(352, y+22, f.Small, gfx.GreyLo, detail)
	}
	if s.message != "" {
		for i, line := range wrapAll(f.Body, s.message, SafeX+SafeW-352) {
			text(352, 155+i*26, f.Body, gfx.GreyLo, line)
		}
	} else if s.count() == 0 && !s.loading && s.query == "" {
		text(352, 155, f.Body, gfx.GreyLo, "Choose letters to begin")
	}
	if s.count() > 6 {
		text(352, 394, f.Small, gfx.GreyLo, "More matches: up/down")
	}
	back := "Back: return"
	if s.query != "" {
		back = "Back: clear"
	}
	text(SafeX, 432, f.Small, gfx.GreyLo, "L: letters   R: results   "+back)
	return false
}

// Query edits and key focus must not wait for a background text worker. Render
// tiny strips in ordinary RAM, then only blit into write-combined frame memory.
func (s *Search) renderQuery() {
	f := s.app.F.Body
	if f == nil {
		return
	} // headless state tests do not load fonts
	q := s.query
	if q == "" {
		q = "Type a movie or show title"
	}
	for f.Width(q) > SafeW && len(q) > 0 {
		q = q[1:]
	}
	c := gfx.NewCanvas(SafeW, f.Height())
	c.Fill(0, 0, c.W, c.H, gfx.Bg)
	c.Text(0, 0, f, gfx.GreyHi, q)
	s.queryImage = &gfx.Image{W: c.W, H: c.H, Pix: c.Pix}
	s.queryDisplay = s.query
}

func (s *Search) labelImage(f *gfx.Font, label string, col gfx.Color) *gfx.Image {
	if s.labelImages == nil {
		s.labelImages = make(map[string]*gfx.Image)
	}
	key := f.Name + ":" + label + ":" + itoa(int(col))
	if img := s.labelImages[key]; img != nil {
		return img
	}
	c := gfx.NewCanvas(f.Width(label)+2, f.Height())
	c.Fill(0, 0, c.W, c.H, gfx.Bg)
	c.Text(1, 0, f, col, label)
	img := &gfx.Image{W: c.W, H: c.H, Pix: c.Pix}
	s.labelImages[key] = img
	return img
}
