package plex

import (
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

// A page past the end of a listing comes back empty with the listing's
// size, which it keeps; a hub listing counts its own items, an empty one
// none. Synthetic fixtures only.
func TestPageSizes(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/library/sections/1/all":
			if r.URL.Query().Get("X-Plex-Container-Start") == "0" {
				io.WriteString(w, `<MediaContainer size="2" totalSize="2">`+
					`<Video ratingKey="11" key="/library/metadata/11" type="movie" title="One"/>`+
					`<Video ratingKey="12" key="/library/metadata/12" type="movie" title="Two"/>`+
					`</MediaContainer>`)
				return
			}
			io.WriteString(w, `<MediaContainer size="0" totalSize="2" offset="60"></MediaContainer>`)
		case "/hubs/sections/1/continueWatching/items":
			io.WriteString(w, `<MediaContainer size="1" totalSize="1"><Hub title="Continue Watching" size="1">`+
				`<Video ratingKey="11" key="/library/metadata/11" type="movie" title="One"/>`+
				`</Hub></MediaContainer>`)
		case "/hubs/sections/2/continueWatching/items":
			io.WriteString(w, `<MediaContainer size="1" totalSize="1"><Hub title="Continue Watching" size="0"></Hub></MediaContainer>`)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	c := New(server.URL, "tok", t.TempDir(), "")
	for _, tc := range []struct {
		path         string
		start, items int
		total        int
	}{
		{"/library/sections/1/all", 0, 2, 2},
		{"/library/sections/1/all", 60, 0, 2},
		{"/hubs/sections/1/continueWatching/items", 0, 1, 1},
		{"/hubs/sections/2/continueWatching/items", 0, 0, 0},
	} {
		items, total, err := c.Page(tc.path, nil, tc.start, 60)
		if err != nil {
			t.Fatal(err)
		}
		if len(items) != tc.items || total != tc.total {
			t.Fatalf("%s from %d: %d items of %d, want %d of %d", tc.path, tc.start, len(items), total, tc.items, tc.total)
		}
	}
}
