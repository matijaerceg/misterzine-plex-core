package ui

import (
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/plex"
)

var testLibraries = []plex.Section{{Key: "1", Title: "Films", Type: "movie"}, {Key: "2", Title: "Shows", Type: "show"}, {Key: "3", Title: "Cartoons", Type: "show"}}

func TestHiddenLibrariesSetting(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	c := LoadConfig(path)
	if data, _ := json.Marshal(c); strings.Contains(string(data), "hidden_libraries") {
		t.Fatal("nothing hidden still wrote hidden_libraries")
	}
	c.SetLibraryHidden("2", true)
	before := *c
	c.SetLibraryHidden("3", true)
	c.SetLibraryHidden("3", true)
	if !slices.Equal(c.HiddenLibraries, []string{"2", "3"}) || !slices.Equal(before.HiddenLibraries, []string{"2"}) {
		t.Fatalf("hidden %q, the copy taken before %q", c.HiddenLibraries, before.HiddenLibraries)
	}
	if err := c.Save(); err != nil {
		t.Fatal(err)
	}
	if got := LoadConfig(path); !got.LibraryHidden("2") || !got.LibraryHidden("3") || got.LibraryHidden("1") {
		t.Fatalf("saved and read back: %q", got.HiddenLibraries)
	}
	c.SetLibraryHidden("2", false)
	c.SetLibraryHidden("3", false)
	if c.HiddenLibraries != nil || c.LibraryHidden("2") {
		t.Fatalf("every library shown again, still hidden: %q", c.HiddenLibraries)
	}
	var none *Config
	if none.LibraryHidden("1") {
		t.Fatal("no settings hid a library")
	}
}

func TestHiddenLibrariesBelongToTheServer(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	c := LoadConfig(path)
	// the account's name is known: no lookup goes out
	c.Token, c.AccountName, c.ServerName, c.HiddenLibraries = "test-account", "Tester", "Den", []string{"2"}
	a := &App{Cfg: c, Connected: make(chan struct{}, 1), Log: log.New(io.Discard, "", 0)}
	l := &Login{app: a, gen: 1, tok: "test-account"}
	connect := func(name string) {
		l.finishConnect(1, plex.Server{Name: name, AccessToken: "test-server"}, "http://test")
		select {
		case <-a.Connected:
		default:
			t.Fatalf("did not connect to %s: %s", name, l.err)
		}
	}
	connect("Den")
	if !c.LibraryHidden("2") {
		t.Fatal("choosing the same server again showed its hidden libraries")
	}
	connect("Attic")
	if c.HiddenLibraries != nil {
		t.Fatalf("another server took the hidden keys %q", c.HiddenLibraries)
	}
	c.HiddenLibraries = []string{"2"}
	if err := c.SignOut(); err != nil || c.HiddenLibraries != nil {
		t.Fatalf("signed out, still hidden: %q (%v)", c.HiddenLibraries, err)
	}
}

// libraryServer answers the Home requests for testLibraries, Continue
// Watching included, and records which libraries' rows were asked for.
func libraryServer(t *testing.T, failHubs bool) (*plex.Client, func() []string) {
	var mu sync.Mutex
	var asked []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/xml")
		switch {
		case r.URL.Path == "/library/sections":
			io.WriteString(w, `<MediaContainer><Directory key="1" type="movie" title="Films"/><Directory key="2" type="show" title="Shows"/><Directory key="3" type="show" title="Cartoons"/><Directory key="4" type="artist" title="Music"/></MediaContainer>`)
		case r.URL.Path == "/hubs":
			if failHubs {
				http.Error(w, "boom", 500)
				return
			}
			io.WriteString(w, `<MediaContainer><Hub hubIdentifier="home.continue" title="Continue Watching"><Video ratingKey="9" key="/library/metadata/9" type="movie" title="Half seen" librarySectionID="2"/></Hub></MediaContainer>`)
		case strings.HasPrefix(r.URL.Path, "/hubs/sections/"):
			key := strings.TrimPrefix(r.URL.Path, "/hubs/sections/")
			mu.Lock()
			asked = append(asked, key)
			mu.Unlock()
			io.WriteString(w, `<MediaContainer><Hub hubIdentifier="movie.recentlyadded" title="Recently Added"><Video ratingKey="1`+key+`" key="/library/metadata/1`+key+`" type="movie" title="New"/></Hub></MediaContainer>`)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(server.Close)
	return plex.New(server.URL, "tok", t.TempDir(), ""), func() []string {
		mu.Lock()
		defer mu.Unlock()
		out := slices.Clone(asked)
		slices.Sort(out)
		return out
	}
}

func TestHomeLeavesOutHiddenLibraries(t *testing.T) {
	lg := log.New(io.Discard, "", 0)
	client, asked := libraryServer(t, false)
	hubs, secs, err := fetchHome(client, []string{"2"}, lg)
	if err != nil {
		t.Fatal(err)
	}
	var rows []string
	for _, h := range hubs {
		rows = append(rows, h.Title)
	}
	if want := []string{"Continue Watching", "Recently Added in Films", "Recently Added in Cartoons"}; !slices.Equal(rows, want) {
		t.Fatalf("rows %q, want %q", rows, want)
	}
	if !slices.Equal(asked(), []string{"1", "3"}) {
		t.Fatalf("asked for the rows of libraries %q; the hidden one must not be fetched", asked())
	}
	if len(secs) != 3 {
		t.Fatalf("%d libraries came back; the hidden one is still listed for Options", len(secs))
	}

	// every library hidden: Continue Watching alone, and no error
	hubs, secs, err = fetchHome(client, []string{"1", "2", "3"}, lg)
	if err != nil || len(hubs) != 1 || hubs[0].Title != "Continue Watching" || len(secs) != 3 {
		t.Fatalf("all hidden: %d rows, %d libraries, %v", len(hubs), len(secs), err)
	}
	// and with Continue Watching failing too, an empty Home rather than an error
	failing, _ := libraryServer(t, true)
	if hubs, secs, err = fetchHome(failing, []string{"1", "2", "3"}, lg); err != nil || len(hubs) != 0 || len(secs) != 3 {
		t.Fatalf("all hidden, Continue Watching failing: %d rows, %d libraries, %v", len(hubs), len(secs), err)
	}
}

func TestHomeSaysWhenEveryLibraryIsHidden(t *testing.T) {
	a := betaTestApp(t)
	a.secs = testLibraries
	h := &Home{app: a, home: true}
	h.applyHome(nil)
	hint := func() bool {
		c := gfx.NewCanvas(720, 480)
		for i := 0; i < 15; i++ { // text is cached off-thread: draw until it is there
			h.Draw(c, time.Now())
			time.Sleep(20 * time.Millisecond)
		}
		for y := SafeY + 70; y < SafeY+70+a.F.Small.Height(); y++ {
			for x := SafeX; x < SafeX+SafeW; x++ {
				o := (y*c.W + x) * 4
				if gfx.Color(uint32(c.Pix[o+2])<<16|uint32(c.Pix[o+1])<<8|uint32(c.Pix[o])) != gfx.Bg {
					return true
				}
			}
		}
		return false
	}
	if hint() {
		t.Fatal("an empty Home with libraries shown says they are hidden")
	}
	a.Cfg.HiddenLibraries = []string{"1", "2", "3"}
	if !a.allLibrariesHidden() || !hint() {
		t.Fatal("an empty Home with every library hidden does not say so")
	}
}

func TestMenuLeavesOutHiddenLibraries(t *testing.T) {
	a := betaTestApp(t)
	a.secs = testLibraries
	a.Cfg.HiddenLibraries = []string{"2"}
	a.lastSection = "3"
	items, cur := a.menuItems()
	var keys []string
	for _, it := range items {
		if it.Type == "section" {
			keys = append(keys, it.Key)
		}
	}
	if !slices.Equal(keys, []string{"1", "3"}) || items[cur].Key != "3" {
		t.Fatalf("menu lists libraries %q and opens on %q", keys, items[cur].Title)
	}
	// the library opened last is hidden: the menu opens on Home
	a.lastSection = "2"
	if items, cur = a.menuItems(); items[cur].Type != "home" {
		t.Fatalf("the hidden library opened last left the menu on %q", items[cur].Title)
	}
	// every library hidden: no libraries, Options still there
	a.Cfg.HiddenLibraries = []string{"1", "2", "3"}
	items, cur = a.menuItems()
	var types []string
	for _, it := range items {
		types = append(types, it.Type)
	}
	if !slices.Equal(types, []string{"home", "search", "options", "exit", "patreon"}) || cur != 0 {
		t.Fatalf("all hidden: menu %q, open on %d", types, cur)
	}
}

func TestSearchLeavesOutHiddenLibraries(t *testing.T) {
	results := func() []*plex.Item {
		return []*plex.Item{{Title: "In Films", Type: "movie", Library: "1"}, {Title: "In Shows", Type: "show", Library: "2"}, {Title: "Unsaid", Type: "movie"}}
	}
	s := &Search{app: &App{Cfg: &Config{HiddenLibraries: []string{"2"}}}, generation: 1, loading: true}
	s.accept(1, results(), nil)
	var titles []string
	for _, it := range s.items {
		titles = append(titles, it.Title)
	}
	if !slices.Equal(titles, []string{"In Films", "Unsaid"}) {
		t.Fatalf("results %q", titles)
	}
	all := &Search{app: &App{Cfg: &Config{HiddenLibraries: []string{"1", "2"}}}, generation: 1, loading: true}
	all.accept(1, []*plex.Item{results()[0], results()[1]}, nil)
	if len(all.items) != 0 || all.message == "" {
		t.Fatalf("every library hidden: %d results, message %q", len(all.items), all.message)
	}
}

func TestOptionsLibraryRows(t *testing.T) {
	a := betaTestApp(t)
	a.Plex = &plex.Client{}
	o := &Options{app: a}
	// nothing loaded yet: no Libraries section
	if headers, _ := optionSections(o.items()); slices.Contains(headers, "Libraries") {
		t.Fatalf("sections %q with no libraries loaded", headers)
	}
	a.secs = testLibraries
	items := o.items()
	headers, under := optionSections(items)
	if want := []string{"Playback", "Libraries", "Picture", "Sound", "Extras", "Account", "App"}; !slices.Equal(headers, want) {
		t.Fatalf("sections %q, want %q", headers, want)
	}
	for _, label := range []string{"Show Films", "Show Shows", "Show Cartoons"} {
		row := optionRow(o, label)
		if under[label] != "Libraries" || row < 0 || !items[row].get() {
			t.Fatalf("%q under %q, on %v; want an On toggle under Libraries", label, under[label], row >= 0 && items[row].get())
		}
	}
	if items[len(items)-1].label != "Version" {
		t.Fatal("Version is no longer the last row")
	}
	a.Showcase = true // captures: the rows take the menu's stand-in names
	if optionRow(o, "Show Films") >= 0 || optionRow(o, "Show Movies") < 0 || optionRow(o, "Show TV Shows 2") < 0 {
		t.Fatal("showcase mode shows the library names in Options")
	}
	a.Showcase = false
	a.Plex = nil // signed out: no Libraries section
	if headers, _ := optionSections(o.items()); slices.Contains(headers, "Libraries") {
		t.Fatalf("sections %q while signed out", headers)
	}
}

// libraryScreens is Home with Continue Watching and a row per library,
// the menu over it and Options over that, as when Options is opened from
// the menu.
func libraryScreens(t *testing.T) (*App, *Home, *Drawer, *Options) {
	a := betaTestApp(t)
	a.Plex = &plex.Client{}
	a.secs = testLibraries
	h := &Home{app: a, home: true}
	hubs := []*plex.Hub{homeRow("home.continue", "c1")}
	for _, s := range testLibraries {
		row := homeRow("recent."+s.Key, "r"+s.Key)
		row.Title = "Recently Added in " + s.Title
		row.Items = append(row.Items, &plex.Item{Type: "more", Title: "See all", Key: s.Key})
		hubs = append(hubs, row)
	}
	h.applyHome(hubs)
	h.refreshAt = time.Now().Add(time.Hour)
	items, _ := a.menuItems()
	opts := slices.IndexFunc(items, func(it *plex.Item) bool { return it.Type == "options" })
	d := NewDrawer(a, &splashTestScreen{}, items, opts)
	o := NewOptions(a)
	a.stack = []Screen{h, d, o}
	return a, h, d, o
}

func homeRowTitles(h *Home) []string {
	var out []string
	for _, hub := range h.hubs {
		out = append(out, hub.Title)
	}
	return out
}

func drawerLibraries(d *Drawer) []string {
	var out []string
	for _, it := range d.items {
		if it.Type == "section" {
			out = append(out, it.Key)
		}
	}
	return out
}

func TestOptionsLibraryToggle(t *testing.T) {
	a, h, d, o := libraryScreens(t)
	now := time.Now()
	o.cur = optionRow(o, "Show Shows")
	o.Key(input.Event{Key: input.Enter}, now)
	if !slices.Equal(a.Cfg.HiddenLibraries, []string{"2"}) || !LoadConfig(a.Cfg.path).LibraryHidden("2") {
		t.Fatalf("hidden %q, not saved", a.Cfg.HiddenLibraries)
	}
	if o.cur != optionRow(o, "Show Shows") || o.items()[o.cur].get() {
		t.Fatal("the cursor left the toggled row, or it still reads On")
	}
	// Home: the row goes at once and the rows are fetched again
	if want := []string{"", "Recently Added in Films", "Recently Added in Cartoons"}; !slices.Equal(homeRowTitles(h), want) {
		t.Fatalf("Home rows %q, want %q", homeRowTitles(h), want)
	}
	if !a.homeUpdating() || !h.refreshAt.IsZero() {
		t.Fatal("hiding a library did not refetch Home")
	}
	// the menu under Options: the library gone, still on Options
	if !slices.Equal(drawerLibraries(d), []string{"1", "3"}) || d.items[d.cur].Type != "options" {
		t.Fatalf("menu libraries %q, on %q", drawerLibraries(d), d.items[d.cur].Title)
	}

	// shown again: back in the menu at once, and in Home with the fetch
	o.Key(input.Event{Key: input.Right}, now)
	if a.Cfg.HiddenLibraries != nil || !slices.Equal(drawerLibraries(d), []string{"1", "2", "3"}) || d.items[d.cur].Type != "options" {
		t.Fatalf("shown again: hidden %q, menu %q on %q", a.Cfg.HiddenLibraries, drawerLibraries(d), d.items[d.cur].Title)
	}
	if !a.homeUpdating() {
		t.Fatal("showing a library again did not refetch Home")
	}
}

func TestEveryLibraryHidden(t *testing.T) {
	a, h, d, o := libraryScreens(t)
	now := time.Now()
	for _, label := range []string{"Show Films", "Show Shows", "Show Cartoons"} {
		o.cur = optionRow(o, label)
		o.Key(input.Event{Key: input.Enter}, now)
	}
	if !a.allLibrariesHidden() {
		t.Fatalf("hidden %q", a.Cfg.HiddenLibraries)
	}
	// Home keeps Continue Watching; the menu keeps Options
	if len(h.hubs) != 1 || h.Focused() == nil || h.Focused().RatingKey != "c1" {
		t.Fatalf("Home rows %q", homeRowTitles(h))
	}
	if len(drawerLibraries(d)) != 0 || d.items[d.cur].Type != "options" {
		t.Fatalf("menu libraries %q, on %q", drawerLibraries(d), d.items[d.cur].Title)
	}
	// the rows the next fetch brings in have no library rows either
	h.refreshResult = make(chan homeResult, 1)
	h.refreshResult <- homeResult{secs: testLibraries}
	h.pollHome(now)
	if !h.empty || a.homeUpdating() {
		t.Fatal("an empty fetch did not leave an empty Home")
	}
	h.Key(input.Event{Key: input.Left}, now) // no rows: nothing to move, nothing to crash
	// the Libraries rows stay in Options to show them again
	if optionRow(o, "Show Films") < 0 || o.items()[optionRow(o, "Show Films")].get() {
		t.Fatal("Options lost the hidden libraries' rows")
	}
}

func TestDuplicateLibraryNamesKeepTheCursor(t *testing.T) {
	a := betaTestApp(t)
	a.Plex = &plex.Client{}
	a.secs = []plex.Section{{Key: "1", Title: "Movies", Type: "movie"}, {Key: "5", Title: "Movies", Type: "movie"}}
	o := NewOptions(a)
	a.Push(o)
	first := optionRow(o, "Show Movies")
	o.cur = first + 1 // the second library of the name
	o.Key(input.Event{Key: input.Enter}, time.Now())
	if o.cur != first+1 || !slices.Equal(a.Cfg.HiddenLibraries, []string{"5"}) {
		t.Fatalf("cursor on %d (want %d), hidden %q", o.cur, first+1, a.Cfg.HiddenLibraries)
	}
}
