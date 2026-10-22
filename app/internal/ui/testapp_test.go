package ui

import (
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"

	"plexcrt/internal/gfx"
	"plexcrt/internal/plex"
)

// nopOSD is an OSD that does nothing; test doubles embed it and keep
// only the methods they watch.
type nopOSD struct{}

func (nopOSD) Show(int, int, *gfx.Canvas, []byte)   {}
func (nopOSD) Hide()                                {}
func (nopOSD) Upload(int, *gfx.Canvas, byte)        {}
func (nopOSD) ShowAt(int, int, int, int, int)       {}
func (nopOSD) Dot(int, int, uint32, bool)           {}
func (nopOSD) DotRun(int, int, int)                 {}
func (nopOSD) DotX() int                            { return 0 }
func (nopOSD) Bar(int, int, int, int, uint32, bool) {}

// testClient is a client of the test server at host with token (an empty
// token: the server asks for none).
func testClient(host, token, cacheDir string) *plex.Client {
	return plex.New(host, token, cacheDir, "test-device")
}

// plexPage answers a listing request with the items (Video or Directory
// XML elements) as Plex pages them: X-Plex-Container-Start and -Size
// applied, the total the whole listing's.
func plexPage(w io.Writer, r *http.Request, items ...string) {
	start, _ := strconv.Atoi(r.URL.Query().Get("X-Plex-Container-Start"))
	size, err := strconv.Atoi(r.URL.Query().Get("X-Plex-Container-Size"))
	if err != nil {
		size = len(items)
	}
	start = min(max(start, 0), len(items))
	end := min(len(items), start+max(size, 0))
	fmt.Fprintf(w, `<MediaContainer size="%d" totalSize="%d">%s</MediaContainer>`, end-start, len(items), strings.Join(items[start:end], ""))
}
