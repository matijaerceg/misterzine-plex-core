package ui

import (
	"net/url"
	"strings"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/plex"
)

// Wall is a library browser: a grid of posters four across, scrolling by
// row. The focused row is whole; the row above peeks in as a sliver and
// the row below shows under a band carrying the focused item's title and
// facts. Tabs above switch the view; L/R jump a letter in A to Z, a
// screen otherwise; a scrollbar down the right edge carries the letter.
// A collection opens as a wall of its own.
type Wall struct {
	app     *App
	section plex.Section
	view    int        // in views
	views   []wallView // the library's views: wallViews with the extras' (syncViews)
	extras  []wallView // the extras' views that views was made with
	seek    string     // a remembered place's item, looked for once the listing is in
	coll    *plex.Item // the collection whose items this wall shows; nil for the library's views
	pager   *Pager
	letters []plex.Letter
	cur     int
	rowY    Anim
	holes   []gfx.Rect
	tabs    bool        // the cursor is on the view tabs above the grid
	fading  bool        // a poster faded in this frame: keep drawing
	band    *gfx.Canvas // the info band is composed here (text over posters)
	bandKey string
	bandAt  time.Time

	bandBase    *gfx.Canvas // shaded page slice, reused while posters slide over it
	bandPage    *gfx.Canvas
	bandPageKey string

	// the page behind the grid: the backdrop of the item last lingered
	// on, very faded, with the title and tabs composed over it
	page, pagePrev *gfx.Canvas
	pageKey        string
	pageBg         string // which backdrop the page holds
	fade           Fade
	focusAt        time.Time
	lingerArt      string
	blob           *gfx.Canvas // the abstract page for the lingered item's palette
	blobFor        [4]uint32
	blobBusy       bool

	collPager *Pager    // the library's collections listing, once asked for
	collAsked time.Time // when a failed collections listing was last asked again
}

// LingerRest is how long the cursor must rest before the page follows it.
const LingerRest = 2 * time.Second

const (
	WallArtBright = 44 // of 255: the backdrop is barely there
)

// Wall posters: four across, the focused row whole under the tabs, a
// scrollbar at the right edge.
const (
	WallPW       = 120
	WallPH       = 160
	WallGap      = 16
	WallPitch    = WallPW + WallGap
	WallCols     = 4
	WallRowPitch = WallPH + WallGap
	WallTabsY    = SafeY + 30
	WallPeek     = 12 // of the row above shows
	WallY0       = SafeY + 96
	WallTop      = WallY0 - WallGap - WallPeek // where posters start to show
	WallBandY    = SafeBottom - 62             // the info band: from here to the bottom of the frame
	WallBandH    = 480 - WallBandY
	WallBandX    = SafeX                        // it spans the posters
	WallBandW    = WallCols*WallPitch - WallGap // 528
	WallPeekTop  = WallTabsY + 30               // peeking rows show from under the tabs
	WallBarW     = 4
	WallBarX     = SafeX + SafeW - WallBarW
	// the view tabs: this far apart, closing up evenly (to no less than
	// WallTabMinGap) when there are too many to end before WallTabsRight
	WallTabGap    = 26
	WallTabMinGap = 12
	WallTabsRight = WallBarX - WallGap
)

const WallPrefetchRows = 3 // in both directions once the focused row rests

// CollectionsRetry spaces the requests for a collections listing that has
// failed, while a library's wall is on screen.
const CollectionsRetry = 30 * time.Second

type wallView struct {
	name        string // the tab's label, which also names the view
	path        string // with %s for the section key
	query       url.Values
	az          bool
	collections bool // the library's collections: a tab only once it has one
	// order, when set, shows the whole listing in an order of the view's
	// own: for the library and the listing's items, the index of each
	// position's item (NewOrderedPager)
	order func(s plex.Section, items []*plex.Item) []int
	// remember keeps the view's place for the session: the cursor comes
	// back with it, on the same item where the listing has it now, and
	// while it is the view the library was left on, the library opens on
	// it again (NewWall)
	remember bool
	// renew is OK on the view's tab while the cursor is on the tabs: the
	// view starts over (a fresh order) with its place forgotten, and the
	// cursor stays on the tab. Without it OK goes down to the grid.
	renew func(s plex.Section)
	// left runs when the library is left (its wall popped), before the
	// page under it shows, whichever view the wall was on. A page opened
	// over the wall and closed again, a collection's wall among them, does
	// not leave it.
	left func(s plex.Section)
}

// The labels are short enough for all five tabs to fit across the frame,
// six with the tabs closed up.
var wallViews = []wallView{
	{name: "A to Z", path: "/library/sections/%s/all", query: url.Values{"sort": {"titleSort"}}, az: true},
	{name: "Added", path: "/library/sections/%s/all", query: url.Values{"sort": {"addedAt:desc"}}},
	{name: "Released", path: "/library/sections/%s/all", query: url.Values{"sort": {"originallyAvailableAt:desc"}}},
	{name: "Continue Watching", path: "/hubs/sections/%s/continueWatching/items"},
	// last, so a library without collections shows the views before it
	{name: "Collections", path: "/library/sections/%s/collections", collections: true},
}

// wallExtrasAt is where the extras' views go among a library's: after
// the sorts of the whole library, before Continue Watching.
const wallExtrasAt = 3

// extraWallViews is the extras' views for a library (premium.go); the
// tests put their own in its place.
var extraWallViews = (*App).premiumWallViews

// NewWall opens a section in its A to Z view, or in the view that keeps
// its place when the library was left on it (and it is still offered).
func NewWall(app *App, s plex.Section) *Wall {
	w := newWall(app, s, nil)
	if p := app.places[s.Key]; p != nil {
		w.view = max(0, viewNamed(w.views, p.last))
	}
	w.load()
	return w
}

// NewWallView opens a section in one of its views.
func NewWallView(app *App, s plex.Section, view int) *Wall {
	w := newWall(app, s, nil)
	w.view = max(0, min(len(w.views)-1, view))
	w.load()
	return w
}

// NewCollectionWall opens a collection's items, in the collection's own
// order, under the library's title with the collection's as the only tab.
// Back leaves it for the Collections tab where it was.
func NewCollectionWall(app *App, s plex.Section, coll *plex.Item) *Wall {
	w := newWall(app, s, coll)
	w.load()
	return w
}

func newWall(app *App, s plex.Section, coll *plex.Item) *Wall {
	w := &Wall{app: app, section: s, coll: coll}
	w.band = gfx.NewCanvas(WallBandW, WallBandH)
	w.syncViews()
	return w
}

// syncViews keeps the library's views in step with the extras: made once,
// and again when the extras offer other views (one turned on or off). The
// view shown stays by name; when it has gone, A to Z shows instead. A
// collection's wall has the library's own views, unused.
func (w *Wall) syncViews() {
	if w.coll != nil {
		w.views = wallViews
		return
	}
	extras := extraWallViews(w.app, w.section)
	if w.views != nil && sameViews(extras, w.extras) {
		return
	}
	views := wallViews
	if len(extras) > 0 {
		views = make([]wallView, 0, len(wallViews)+len(extras))
		views = append(append(append(views, wallViews[:wallExtrasAt]...), extras...), wallViews[wallExtrasAt:]...)
	}
	old := w.views
	w.views, w.extras = views, extras
	w.pageKey = ""
	if old == nil {
		return // being made: the view is chosen and loaded next
	}
	if at := viewNamed(views, old[w.view].name); at >= 0 {
		w.view = at
		return
	}
	w.view = 0
	w.load()
}

// sameViews reports whether two lists of extras' views name the same views.
func sameViews(a, b []wallView) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i].name != b[i].name {
			return false
		}
	}
	return true
}

// viewNamed is the index of the view called name, or -1.
func viewNamed(views []wallView, name string) int {
	for i, v := range views {
		if name != "" && v.name == name {
			return i
		}
	}
	return -1
}

// wallPlace is what the session remembers of a library's views that keep
// their place (wallView.remember).
type wallPlace struct {
	last  string              // the view the library was left on, if it is one of them
	spots map[string]wallSpot // where the cursor was in each, by name
}

// wallSpot is a cursor's place: its position and the item there.
type wallSpot struct {
	cur int
	key string // the item's rating key; "" when it had not loaded
}

// wallPlace is a library's remembered places, made on first use.
func (a *App) wallPlace(section string) *wallPlace {
	if a.places == nil {
		a.places = map[string]*wallPlace{}
	}
	p := a.places[section]
	if p == nil {
		p = &wallPlace{spots: map[string]wallSpot{}}
		a.places[section] = p
	}
	return p
}

// forgetWallView drops what the session remembers of a library's view:
// its cursor, and that the library was left on it.
func (a *App) forgetWallView(section, view string) {
	if p := a.places[section]; p != nil {
		delete(p.spots, view)
		if p.last == view {
			p.last = ""
		}
	}
}

// keep remembers the cursor of a view that keeps its place, once the
// place it came back to has been found.
func (w *Wall) keep() {
	if v := w.views[w.view]; w.coll == nil && v.remember && w.seek == "" {
		spot := wallSpot{cur: w.cur}
		if it := w.pager.Get(w.cur); it != nil {
			spot.key = it.RatingKey
		}
		w.app.wallPlace(w.section.Key).spots[v.name] = spot
	}
}

// findPlace puts the cursor back on a remembered place's item once the
// listing is in, wherever the listing has it now; without it the cursor
// stays at the remembered position.
func (w *Wall) findPlace() {
	if w.seek == "" || w.total() == 0 || !w.pager.Done() {
		return
	}
	if i := w.pager.Find(w.seek); i >= 0 && i != w.cur {
		w.cur = i
		w.rowY.Set(float64(w.cur / WallCols * WallRowPitch))
	}
	w.seek = ""
	w.keep()
}

func (w *Wall) load() {
	v := w.views[w.view]
	if w.coll != nil {
		// the path the server gave for the collection's items, else the usual one
		path := w.coll.Key
		if !strings.HasPrefix(path, "/library/") || !strings.HasSuffix(path, "/children") {
			path = "/library/collections/" + w.coll.RatingKey + "/children"
		}
		v = wallView{name: w.coll.Title, path: path}
	}
	q := url.Values{}
	for k, vals := range v.query {
		q[k] = vals
	}
	var filter func(*plex.Item) bool
	if w.app.Cfg != nil && w.app.Cfg.FourThree {
		filter = w.app.Keep // every view: the listing is walked and packed
	}
	path := strings.Replace(v.path, "%s", w.section.Key, 1)
	if v.collections {
		// the listing that decided the tab; collections have no picture of
		// their own to judge, the 4:3 filter applies to their items
		filter = nil
		w.pager = w.collections()
	} else if v.order != nil {
		s, order := w.section, v.order
		w.pager = NewOrderedPager(w.app.pager(path, q, filter), func(items []*plex.Item) []int { return order(s, items) })
	} else {
		w.pager = w.app.pager(path, q, filter)
	}
	w.letters = nil
	if v.az && filter == nil {
		go func() {
			ls, err := w.app.Plex.FirstChars(w.section.Key, q)
			if err == nil {
				w.letters = ls
			}
		}()
	}
	w.cur, w.seek = 0, ""
	if w.coll == nil {
		if v.remember {
			p := w.app.wallPlace(w.section.Key)
			spot := p.spots[v.name]
			p.last, w.cur, w.seek = v.name, spot.cur, spot.key
		} else if p := w.app.places[w.section.Key]; p != nil {
			p.last = ""
		}
	}
	w.rowY.Set(float64(w.cur / WallCols * WallRowPitch))
	w.bandKey = ""
}

func (w *Wall) total() int {
	t := w.pager.Total()
	if t < 0 {
		return 0
	}
	return t
}

// az reports whether the view is the library's A to Z, with its letters.
func (w *Wall) az() bool {
	views := w.views
	if views == nil {
		views = wallViews // a wall made bare, in the tests
	}
	return w.coll == nil && views[w.view].az
}

// collections is the library's collections listing, kept for the session
// like the views'; asking for it starts the fetch that decides the tab.
// The wall holds on to it, so drawing does not look it up every frame.
func (w *Wall) collections() *Pager {
	if w.collPager == nil {
		w.collPager = w.app.pager("/library/sections/"+w.section.Key+"/collections", url.Values{}, nil)
	}
	return w.collPager
}

// tabCount is how many view tabs show: the collection's one, or the
// library's views with Collections last, once the library is known to
// have a collection (or while it is the view). Until its first page has
// landed there is no tab, rather than one that opens on nothing.
func (w *Wall) tabCount() int {
	if w.coll != nil {
		return 1
	}
	n := len(w.views)
	if w.view == n-1 || !w.views[n-1].collections {
		return n
	}
	if !w.holdsCollections() || w.collections().Total() <= 0 {
		n--
	}
	return n
}

// holdsCollections reports whether the library is of a kind that has them.
func (w *Wall) holdsCollections() bool {
	return w.section.Type == "movie" || w.section.Type == "show"
}

// retryCollections asks again for a collections listing that failed (a
// timeout, a server restarting): with its tab hidden nothing else would.
// Once on each opening of the library, then every CollectionsRetry; the
// run loop redraws at least once a second, so an idle wall retries too.
func (w *Wall) retryCollections(now time.Time) {
	if w.coll != nil || w.views[w.view].collections || !w.holdsCollections() {
		return
	}
	p := w.collections()
	if p.Total() >= 0 || p.Err() == nil || (!w.collAsked.IsZero() && now.Sub(w.collAsked) < CollectionsRetry) {
		return
	}
	w.collAsked = now
	p.Retry(0) // spaced out here, so PageRetry does not hold it back
}

// Key handles one input event.
func (w *Wall) Key(ev input.Event, now time.Time) {
	w.syncViews()
	w.findPlace()
	n := w.total()
	if ev.Release {
		w.rowY.Settle(now)
		return
	}
	if w.tabs {
		switch ev.Key {
		case input.Up:
			return
		case input.Left:
			if w.view > 0 {
				w.view--
				w.load()
			}
		case input.Right:
			if w.view < w.tabCount()-1 {
				w.view++
				w.load()
			}
		case input.Enter:
			if v := w.views[w.view]; v.renew != nil {
				if !ev.Repeat {
					v.renew(w.section)
					w.app.forgetWallView(w.section.Key, v.name)
					w.load()
				}
				return
			}
			w.tabs = false
		case input.Down:
			w.tabs = false
		}
		return
	}
	switch ev.Key {
	case input.Left:
		if w.cur > 0 {
			w.cur--
		}
	case input.Right:
		if w.cur < n-1 {
			w.cur++
		}
	case input.Up:
		if w.cur < WallCols {
			// above the first row: the view tabs (a collection has none)
			w.tabs = w.coll == nil
			return
		}
		w.cur -= WallCols
	case input.Down:
		if w.cur+WallCols < n {
			w.cur += WallCols
		} else if w.cur/WallCols < (n-1)/WallCols {
			w.cur = n - 1
		}
	case input.JumpBack:
		w.jump(-1)
	case input.JumpFwd:
		w.jump(1)
	case input.Enter:
		if it := w.pager.Get(w.cur); it != nil && it.Type == "collection" {
			w.app.Push(NewCollectionWall(w.app, w.section, it))
		} else if it != nil {
			w.app.Open(it, false)
		}
	}
	if w.cur >= n && n > 0 {
		w.cur = n - 1
	}
	w.pager.Want(w.cur)
	w.focusAt = now
	w.rowY.Move(float64(w.cur/WallCols*WallRowPitch), now, ev.Repeat)
	w.keep()
}

// Back moves the cursor up to the view tabs from anywhere in the grid;
// a second Back leaves the wall. A collection has no tabs to go to: Back
// returns to the library's Collections tab at once.
func (w *Wall) Back() bool {
	if w.tabs || w.coll != nil {
		return false
	}
	w.tabs = true
	return true
}

// left tells the views that ask (wallView.left) that the library has been
// left: the app pops its wall. A collection's wall closing leaves the
// library's open under it.
func (w *Wall) left() {
	if w.coll != nil {
		return
	}
	for _, v := range w.views {
		if v.left != nil {
			v.left(w.section)
		}
	}
}

// letterIndex is the A-Z index: the server's, or one built from a
// filtered walk once it has finished.
func (w *Wall) letterIndex() []plex.Letter {
	if len(w.letters) > 0 {
		return w.letters
	}
	if w.az() && w.pager.Filtered() && w.pager.Done() {
		w.letters = w.pager.Letters()
	}
	return w.letters
}

// jump moves a letter (A to Z views) or a screen otherwise.
func (w *Wall) jump(dir int) {
	n := w.total()
	letters := w.letterIndex()
	if len(letters) == 0 {
		w.cur += dir * WallCols * 2
		if w.cur < 0 {
			w.cur = 0
		}
		if w.cur > n-1 {
			w.cur = max(0, n-1)
		}
		return
	}
	// letter offsets from the first-character index
	off := 0
	starts := make([]int, len(letters))
	for i, l := range letters {
		starts[i] = off
		off += l.Size
	}
	li := 0
	for i := range starts {
		if starts[i] <= w.cur {
			li = i
		}
	}
	li += dir
	if li < 0 {
		li = 0
	}
	if li >= len(starts) {
		li = len(starts) - 1
	}
	w.cur = starts[li]
}

// Refresh re-reads one item after playback.
func (w *Wall) Refresh(it *plex.Item) {
	if fresh, err := w.app.Plex.Item(it.RatingKey); err == nil {
		*it = *fresh
	}
}

// Draw paints the wall.
func (w *Wall) Draw(c *gfx.Canvas, now time.Time) bool {
	w.syncViews()
	w.findPlace()
	n := w.total()
	if n > 0 && w.cur >= n && w.pager.Done() {
		// a remembered place in a listing that has shrunk since
		w.cur = n - 1
		w.rowY.Set(float64(w.cur / WallCols * WallRowPitch))
		w.keep()
	}
	oy := round(w.rowY.At(now))
	rows := (n + WallCols - 1) / WallCols
	firstRow := max(0, (oy-WallRowPitch)/WallRowPitch)
	w.holes = w.holes[:0]
	w.fading = false
	page, pageAnim := w.drawPage(c, now)
	// the band goes first: it is composed from the posters under it
	w.composeBand(page, now, oy)
	for r := firstRow; r <= firstRow+4 && r < rows; r++ {
		y := WallY0 + r*WallRowPitch - oy
		if y > c.H {
			break
		}
		for col := 0; col < WallCols; col++ {
			i := r*WallCols + col
			if i >= n {
				break
			}
			x := SafeX + col*WallPitch
			it := w.pager.Get(i)
			w.drawPoster(c, it, x, y, i == w.cur)
		}
	}
	c.Blit(WallBandX, WallBandY, &gfx.Image{W: w.band.W, H: w.band.H, Pix: w.band.Pix})
	w.holes = append(w.holes, gfx.Rect{X: WallBandX, Y: WallBandY, W: WallBandW, H: WallBandH})
	c.BlitExcept(page, w.holes)
	// a scrollbar down the right edge, the letter (or the count) beside its handle
	if rows > 1 {
		trackY, trackH := WallTop, SafeBottom-WallTop
		thumbH := max(20, trackH/rows)
		thumbY := trackY + (trackH-thumbH)*(w.cur/WallCols)/(rows-1)
		c.Fill(WallBarX, trackY, WallBarW, trackH, gfx.Bar)
		c.Fill(WallBarX, thumbY, WallBarW, thumbH, gfx.GreyLo)
		if s := w.marker(n); s != "" {
			f := w.app.F.SmallBold
			w.app.textOver(c, page, WallBarX-10-f.Width(s), min(max(thumbY+thumbH/2-f.Height()/2, trackY), SafeBottom-f.Height()), f, gfx.GreyLo, s)
		}
	}
	if err := w.pager.Err(); err != nil {
		w.app.textOver(c, page, SafeX, WallY0, w.app.F.Body, gfx.GreyHi, "Cannot load this library.")
		w.app.textOver(c, page, SafeX, WallY0+30, w.app.F.Small, gfx.GreyLo, w.app.F.Small.Fit(err.Error(), SafeW))
	} else if w.pager.Total() < 0 {
		w.app.textOver(c, page, SafeX, WallY0, w.app.F.Body, gfx.GreyLo, "Loading...")
	} else if n == 0 {
		w.app.textOver(c, page, SafeX, WallY0, w.app.F.Body, gfx.GreyLo, "Nothing here.")
	}
	if !w.rowY.Running(now) {
		w.prefetchRows()
	}
	return w.rowY.Running(now) || w.fading || pageAnim
}

// Queue far rows first so the nearest missing rows are served first. Drawing
// has already requested the visible posters, which have higher priority.
func (w *Wall) prefetchRows() {
	n := w.total()
	row := w.cur / WallCols
	for distance := WallPrefetchRows; distance >= 1; distance-- {
		for _, r := range []int{row - distance, row + distance} {
			if r < 0 {
				continue
			}
			for i := r * WallCols; i < (r+1)*WallCols && i < n; i++ {
				if it := w.pager.Get(i); it != nil {
					w.app.Art.Prefetch(it.Thumb, WallPW, WallPH)
				}
			}
		}
	}
}

// drawPage prepares the page shared by the grid and the title strip: the
// backdrop of the item lingered on (once the cursor has rested), the
// section title with its size, and the view tabs. It is recomposed when
// any of those change, cross-fading between backdrops.
func (w *Wall) drawPage(c *gfx.Canvas, now time.Time) (*gfx.Canvas, bool) {
	// the page follows the cursor only after a long rest and never while
	// the grid moves; the gradient is made off-thread and lands via Later
	if it := w.pager.Get(w.cur); it != nil && it.Colors != [4]uint32{} && !w.blobBusy &&
		now.Sub(w.focusAt) >= LingerRest && !w.rowY.Running(now) && it.Colors != w.blobFor {
		w.blobBusy = true
		cols := it.Colors
		go func() {
			page := blobPage(c.W, c.H, cols)
			w.app.Later(func() {
				w.blob, w.blobFor, w.blobBusy = page, cols, false
			})
		}()
	}
	img := (*gfx.Image)(nil)
	if w.blob != nil {
		img = &gfx.Image{W: w.blob.W, H: w.blob.H, Pix: w.blob.Pix}
	}
	tabs := w.tabCount()
	if tabs < len(w.views) {
		w.retryCollections(now)
	}
	key := itoa(w.view) + "/" + itoa(tabs)
	if w.blob != nil {
		key += "|" + itoa(int(w.blobFor[0])) + "." + itoa(int(w.blobFor[2]))
	}
	if w.tabs {
		key += "|tabs"
	}
	total := w.app.pager("/library/sections/"+w.section.Key+"/all", url.Values{"sort": {"titleSort"}}, nil).Total()
	key += "|" + itoa(total)
	if key != w.pageKey {
		w.fade.Done()
		w.page, w.pagePrev = w.pagePrev, w.page
		if w.page == nil {
			w.page = gfx.NewCanvas(c.W, c.H)
		}
		w.compose(w.page, img, total, tabs)
		bg := ""
		if w.blob != nil {
			bg = itoa(int(w.blobFor[0])) + "." + itoa(int(w.blobFor[2]))
		}
		if w.pagePrev != nil && bg != w.pageBg {
			w.fade.StartFor(w.pagePrev, w.page, now, 600*time.Millisecond) // a new palette: slow fade
		}
		w.pageBg = bg
		w.pageKey = key
	}
	show, fading := w.fade.Frame(now)
	if !fading {
		show = w.page
	}
	return show, fading
}

func (w *Wall) compose(c *gfx.Canvas, img *gfx.Image, total, tabs int) {
	if img != nil {
		c.Blit(0, 0, img)
	} else {
		c.Fill(0, 0, c.W, c.H, gfx.Bg)
	}
	f := w.app.F
	title := w.app.libraryLabel(w.section)
	tx := f.Body.Width(title)
	c.Text(SafeX, SafeY-2, f.Body, gfx.GreyHi, f.Body.Fit(title, SafeW-80))
	if total > 0 && !w.app.Showcase {
		c.Text(SafeX+min(tx, SafeW-80)+14, SafeY+2, f.SmallBold, gfx.GreyLo, itoa(total))
	}
	// A clean underline identifies the active view. It brightens and thickens
	// when navigation is on the tabs, without surrounding the label in a box.
	x := SafeX
	ty := WallTabsY
	gap := w.tabGap(tabs)
	for i := 0; i < tabs; i++ {
		name := w.views[i].name
		if w.coll != nil {
			name = f.SmallBold.Fit(w.coll.Title, WallBandW)
		}
		col := gfx.GreyLo
		if i == w.view {
			col = gfx.GreyHi
			if w.tabs {
				col = gfx.White
			}
		}
		tw := f.SmallBold.Width(name)
		c.Text(x, ty, f.SmallBold, col, name)
		if i == w.view {
			lineColor, lineH := gfx.GreyLo, 2
			if w.tabs {
				lineColor, lineH = gfx.Amber, 4
			}
			c.Fill(x, ty+f.SmallBold.Height()+4, tw, lineH, lineColor)
		}
		x += tw + gap
	}
}

// tabGap is the space between the view tabs when tabs of them show:
// WallTabGap, closed up evenly when they would run past WallTabsRight.
func (w *Wall) tabGap(tabs int) int {
	if tabs < 2 || w.coll != nil {
		return WallTabGap
	}
	width := 0
	for _, v := range w.views[:tabs] {
		width += w.app.F.SmallBold.Width(v.name)
	}
	return max(WallTabMinGap, min(WallTabGap, (WallTabsRight-SafeX-width)/(tabs-1)))
}

// marker is what rides beside the scrollbar handle: the letter in A to Z
// views, the position otherwise.
func (w *Wall) marker(n int) string {
	if n == 0 {
		return ""
	}
	if w.az() {
		if it := w.pager.Get(w.cur); it != nil && it.SortLabel() != "" {
			return strings.ToUpper(it.SortLabel()[:1])
		}
		return ""
	}
	if w.app.Showcase {
		return ""
	}
	s := itoa(w.cur+1) + " / " + itoa(n)
	if w.pager.Filtered() && !w.pager.Done() {
		s += "+"
	}
	return s
}

// composeBand paints the info band: the posters under it dimmed further,
// and the focused item's title and facts over them.
func (w *Wall) composeBand(page *gfx.Canvas, now time.Time, oy int) {
	if w.bandBase == nil {
		w.bandBase = gfx.NewCanvas(WallBandW, WallBandH)
	}
	if w.bandPage != page || w.bandPageKey != w.pageKey {
		for yy := 0; yy < WallBandH; yy++ {
			so := ((WallBandY+yy)*page.W + WallBandX) * 4
			copy(w.bandBase.Pix[yy*WallBandW*4:(yy+1)*WallBandW*4], page.Pix[so:so+WallBandW*4])
		}
		w.bandBase.FillAlpha(0, 0, WallBandW, WallBandH, gfx.Bg, 215)
		w.bandPage, w.bandPageKey = page, w.pageKey
		w.bandKey = ""
	}
	n := w.total()
	it := w.pager.Get(w.cur)
	key := itoa(oy) + "|" + itoa(w.cur)
	if it != nil {
		key += "|" + it.RatingKey + "|" + itoa(it.ViewCount) + "|" + itoa(it.ViewOffset)
	}
	// which posters are under the band, and whether they have landed
	rowUnder := (oy + WallBandY - WallY0) / WallRowPitch
	for r := rowUnder - 1; r <= rowUnder+1; r++ {
		if r < 0 {
			continue
		}
		y := WallY0 + r*WallRowPitch - oy - WallBandY
		if y >= WallBandH || y+WallPH <= 0 {
			continue
		}
		for col := 0; col < WallCols; col++ {
			i := r*WallCols + col
			if i >= n {
				break
			}
			if p := w.pager.Get(i); p != nil {
				if img := w.app.Art.wallBand(p.Thumb); img != nil {
					key += "|" + itoa(i)
				}
			}
		}
	}
	if key == w.bandKey {
		return
	}
	w.bandKey = key
	b := w.band
	b.Copy(w.bandBase)
	for r := rowUnder - 1; r <= rowUnder+1; r++ {
		if r < 0 {
			continue
		}
		y := WallY0 + r*WallRowPitch - oy - WallBandY
		if y >= b.H || y+WallPH <= 0 {
			continue
		}
		for col := 0; col < WallCols; col++ {
			i := r*WallCols + col
			if i >= n {
				break
			}
			p := w.pager.Get(i)
			if p == nil {
				continue
			}
			if img := w.app.Art.wallBand(p.Thumb); img != nil {
				b.Blit(col*WallPitch, y, img)
			} else {
				b.Blit(col*WallPitch, y, wallBandPlaceholder)
			}
		}
	}
	if it == nil {
		return
	}
	f := w.app.F
	title := it.Title
	if it.Type == "episode" {
		title = it.GrandTitle
	}
	b.Text(12, 10, f.Body, gfx.GreyHi, f.Body.Fit(title, b.W-24))
	dots(b, 12, 10+f.Body.Height()+2, f.SmallBold, gfx.GreyLo, heroFacts(it), b.W-24)
}

// Apply exactly the strip's existing tint once, off the drawing thread.
func wallBandImage(img *gfx.Image) *gfx.Image {
	c := gfx.NewCanvas(img.W, img.H)
	c.Blit(0, 0, img)
	c.FillAlpha(0, 0, c.W, c.H, gfx.Bg, 215)
	return &gfx.Image{W: c.W, H: c.H, Pix: c.Pix}
}

var wallBandPlaceholder = func() *gfx.Image {
	c := gfx.NewCanvas(WallPW, WallPH)
	c.Fill(0, 0, c.W, c.H, gfx.Bar)
	return wallBandImage(&gfx.Image{W: c.W, H: c.H, Pix: c.Pix})
}()

// drawPoster paints one poster clipped to the grid's band and records the
// painted area as a hole for the background fill. What lies under the
// info band is left to it.
func (w *Wall) drawPoster(c *gfx.Canvas, it *plex.Item, x, y int, focus bool) {
	// peeking rows may run into the overscan: only the tabs bound them above
	cy0, cy1 := WallPeekTop, c.H
	// the band covers part of the next row
	if y < WallBandY+WallBandH && y+WallPH > WallBandY {
		if y < WallBandY {
			cy1 = min(cy1, WallBandY)
		} else {
			cy0 = max(cy0, WallBandY+WallBandH)
		}
	}
	hy0, hy1 := max(y, cy0), min(y+WallPH, cy1)
	if hy0 >= hy1 {
		return
	}
	whole := y >= cy0 && y+WallPH <= cy1
	var img *gfx.Image
	var age time.Duration
	if it != nil {
		img, age = w.app.Art.GetAge(it.Thumb, WallPW, WallPH)
		if focus && w.tabs && img != nil && img.Dim != nil {
			img = img.Dim // reuse the loader's shaded copy; no per-frame dimming
		}
	}
	w.holes = append(w.holes, gfx.Rect{X: x, Y: hy0, W: WallPW, H: hy1 - hy0})
	if img != nil {
		if age < FadeIn {
			c.BlendSolidClip(x, y, img, gfx.Bg, 256-int(age*256/FadeIn), 0, cy0, c.W, cy1-cy0)
			w.fading = true
		} else {
			c.BlitClip(x, y, img, 0, cy0, c.W, cy1-cy0)
		}
	} else {
		c.Fill(x, hy0, WallPW, hy1-hy0, gfx.Bar)
		if it != nil && whole {
			f := w.app.F.SmallBold
			lines := wrap(f, it.Title, WallPW-16, 4)
			ty := y + WallPH/2 - len(lines)*f.Height()/2
			for _, l := range lines {
				w.app.textCenterOn(c, x+WallPW/2, ty, f, gfx.GreyLo, gfx.Bar, l)
				ty += f.Height()
			}
		}
	}
	if !whole || it == nil {
		return
	}
	w.app.badge(c, it, x, y, WallPW, WallPH)
	if focus {
		frameColor := gfx.GreyHi
		if w.tabs {
			frameColor = ChevronOff // retain the grid position without claiming focus
		}
		c.Frame(x-FocusPad, y-FocusPad, WallPW+2*FocusPad, WallPH+2*FocusPad, FocusT, frameColor)
		w.holes = append(w.holes, frameHoles(x, y, WallPW, WallPH)...)
	}
}

// frameHoles are the four bars of a focus frame around a tile at x,y:
// exactly the FocusT-thick lines Frame paints, so the gap between the
// frame and the tile is filled by the background pass like everything else.
func frameHoles(x, y, w, h int) []gfx.Rect {
	ox, oy, ow, oh := x-FocusPad, y-FocusPad, w+2*FocusPad, h+2*FocusPad
	return []gfx.Rect{
		{X: ox, Y: oy, W: ow, H: FocusT},
		{X: ox, Y: oy + oh - FocusT, W: ow, H: FocusT},
		{X: ox, Y: oy + FocusT, W: FocusT, H: oh - 2*FocusT},
		{X: ox + ow - FocusT, Y: oy + FocusT, W: FocusT, H: oh - 2*FocusT},
	}
}
