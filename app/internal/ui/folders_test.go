package ui

import (
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/plex"
)

// folderServer is a synthetic server whose library 1 has two root
// folders; the first holds a subfolder and two films, one of them wide.
type folderServer struct {
	*httptest.Server
	mu   sync.Mutex
	asks []string // path?query of every request
}

func newFolderServer(t *testing.T) *folderServer {
	s := &folderServer{}
	s.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		s.asks = append(s.asks, r.URL.Path+"?"+r.URL.Query().Get("parent"))
		s.mu.Unlock()
		switch {
		case r.URL.Path == "/library/sections/1/folder" && r.URL.Query().Get("parent") == "":
			io.WriteString(w, `<MediaContainer size="2" totalSize="2">`+
				`<Directory key="/library/sections/1/folder?parent=12" title="Artist One"/>`+
				`<Directory key="/library/sections/1/folder?parent=13" title="Artist Two"/>`+
				`</MediaContainer>`)
		case r.URL.Path == "/library/sections/1/folder" && r.URL.Query().Get("parent") == "12":
			io.WriteString(w, `<MediaContainer size="3" totalSize="3">`+
				`<Directory key="/library/sections/1/folder?parent=14" title="Live"/>`+
				`<Video ratingKey="31" key="/library/metadata/31" type="movie" title="Square Clip"><Media aspectRatio="1.33"/></Video>`+
				`<Video ratingKey="32" key="/library/metadata/32" type="movie" title="Wide Clip"><Media aspectRatio="1.78"/></Video>`+
				`</MediaContainer>`)
		case r.URL.Path == "/library/metadata/31":
			io.WriteString(w, `<MediaContainer size="1"><Video ratingKey="31" key="/library/metadata/31" type="movie" title="Square Clip" summary="A synthetic clip."><Media aspectRatio="1.33"/></Video></MediaContainer>`)
		default:
			io.WriteString(w, `<MediaContainer size="0" totalSize="0"></MediaContainer>`)
		}
	}))
	t.Cleanup(s.Close)
	return s
}

func (s *folderServer) asked(pathParent string) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	n := 0
	for _, a := range s.asks {
		if a == pathParent {
			n++
		}
	}
	return n
}

// The Folders tab lists the library's root folders; OK on one opens its
// contents as a wall of its own, named after it, through the 4:3 filter
// (which hides wide files, never folders); a file opens as anywhere
// else, and Back comes out folder by folder to the Folders tab.
func TestWallFoldersTab(t *testing.T) {
	s := newFolderServer(t)
	a := &App{Plex: plex.New(s.URL, "tok", t.TempDir(), ""), Wake: make(chan struct{}, 1), pagers: map[string]*Pager{},
		Cfg: &Config{NoTheme: true, FourThree: true}, Log: log.New(io.Discard, "", 0), Art: NewArt(nil, 0, nil)}
	a.F = appFonts()
	a.T = gfx.NewTextCache(1, nil)
	a.stack = []Screen{&splashTestScreen{}}
	now := time.Now()
	press := func(k input.Key) { a.key(input.Event{Key: k}, now) }

	folders := viewNamed(wallViews, "Folders")
	if folders != len(wallViews)-2 || wallExtrasAt >= folders {
		t.Fatalf("Folders is view %d of %d, the extras go at %d", folders, len(wallViews), wallExtrasAt)
	}
	library := NewWallView(a, filmsLibrary, folders)
	a.Push(library)
	waitUntil(t, "the root folders", func() bool { return library.pager.Done() && library.total() == 2 })
	if s.asked("/library/sections/1/folder?") == 0 {
		t.Fatal("the library's folders were not asked for")
	}
	root := library.pager.Get(0)
	if root == nil || !root.IsFolder() || root.Title != "Artist One" {
		t.Fatalf("first root folder %+v", root)
	}
	c := gfx.NewCanvas(720, 480)
	library.Draw(c, now) // folder tiles without pictures draw their names

	press(input.Enter)
	folder, ok := a.top().(*Wall)
	if !ok || folder == library || folder.coll != root {
		t.Fatalf("OK on a folder opened %T", a.top())
	}
	waitUntil(t, "the folder's items", func() bool { return folder.pager.Done() && folder.total() >= 0 })
	if s.asked("/library/sections/1/folder?12") == 0 {
		t.Fatal("the folder was not listed at the path the server gave")
	}
	if folder.total() != 2 {
		t.Fatalf("the 4:3 filter kept %d of the folder's items", folder.total())
	}
	if sub, file := folder.pager.Get(0), folder.pager.Get(1); !sub.IsFolder() || sub.Title != "Live" || file.RatingKey != "31" {
		t.Fatalf("the folder holds %+v and %+v", sub, file)
	}
	if folder.tabCount() != 1 || folder.az() {
		t.Fatal("a folder has its name as its only tab, with no letters")
	}
	folder.Draw(c, now)
	tab := false
	for x := SafeX; x < SafeX+a.F.SmallBold.Width("Artist One") && !tab; x++ {
		for y := WallTabsY; y < WallTabsY+a.F.SmallBold.Height(); y++ {
			if o := (y*c.W + x) * 4; string(c.Pix[o:o+4]) != string(c.Pix[(y*c.W+c.W-1)*4:(y*c.W+c.W-1)*4+4]) {
				tab = true
				break
			}
		}
	}
	if !tab {
		t.Fatal("the folder's name is not drawn as its tab")
	}

	press(input.Right)
	press(input.Enter)
	settleServerRequest(t, a)
	if p, ok := a.top().(*Preplay); !ok || p.item.RatingKey != "31" {
		t.Fatalf("OK on a file in the folder opened %T", a.top())
	}
	press(input.Back)
	if a.top() != folder {
		t.Fatal("Back from the film did not return to the folder")
	}
	press(input.Up)
	if folder.tabs {
		t.Fatal("Up put a folder on tabs it does not have")
	}
	press(input.Back)
	if a.top() != library || library.view != folders || library.cur != 0 || library.tabs {
		t.Fatalf("one Back from the folder went to %T, view %d, item %d", a.top(), library.view, library.cur)
	}

	// a long folder name is cut to the posters' width as the tab
	long := NewFolderWall(a, filmsLibrary, &plex.Item{Key: "/library/sections/1/folder?parent=13", Title: strings.Repeat("A very long folder name ", 8)})
	long.compose(c, nil, 0, long.tabCount())
	edge := -1
	for y := WallTabsY; y < WallTabsY+a.F.SmallBold.Height()+8; y++ {
		for x := 0; x < c.W; x++ {
			if o := (y*c.W + x) * 4; string(c.Pix[o:o+4]) != string(c.Pix[y*c.W*4:y*c.W*4+4]) && x > edge {
				edge = x
			}
		}
	}
	if edge >= SafeX+WallBandW {
		t.Fatalf("the folder's tab runs to x=%d, past the posters at %d", edge, SafeX+WallBandW)
	}
}
