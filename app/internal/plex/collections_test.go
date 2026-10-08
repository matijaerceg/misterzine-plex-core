package plex

import (
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

// A library's collections are directories of type collection carrying a
// poster, a backdrop, what they hold and how many items; a collection's
// items list like a library's. Synthetic fixtures only.
func TestCollectionListing(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/library/sections/7/collections":
			if r.URL.Query().Get("X-Plex-Container-Start") != "0" || r.URL.Query().Get("X-Plex-Container-Size") != "2" {
				t.Errorf("collections page asked as %s", r.URL.RawQuery)
			}
			io.WriteString(w, `<MediaContainer size="2" totalSize="3">`+
				`<Directory ratingKey="901" key="/library/collections/901/children" type="collection" subtype="movie" `+
				`title="Example Trilogy" titleSort="Example Trilogy" thumb="/library/collections/901/composite/100" `+
				`art="/library/metadata/901/art/100" childCount="3" smart="0"/>`+
				`<Directory ratingKey="902" key="/library/collections/902/children" type="collection" subtype="show" `+
				`title="Caf&#233; Shows" thumb="/library/metadata/902/thumb/100" childCount="1" smart="1"/>`+
				`</MediaContainer>`)
		case "/library/collections/901/children":
			io.WriteString(w, `<MediaContainer size="3">`+
				`<Video ratingKey="11" key="/library/metadata/11" type="movie" title="Part One" year="2001" thumb="/t/11"><Media aspectRatio="1.33"/></Video>`+
				`<Video ratingKey="12" key="/library/metadata/12" type="movie" title="Part Two" year="2003" thumb="/t/12"/>`+
				`<Video ratingKey="13" key="/library/metadata/13" type="movie" title="Part Three" year="2005" thumb="/t/13"/>`+
				`</MediaContainer>`)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	c := New(server.URL, "tok", t.TempDir(), "")

	items, total, err := c.Page("/library/sections/7/collections", nil, 0, 2)
	if err != nil {
		t.Fatal(err)
	}
	if total != 3 || len(items) != 2 {
		t.Fatalf("total %d, %d items", total, len(items))
	}
	first := items[0]
	if first.RatingKey != "901" || first.Type != "collection" || first.Subtype != "movie" || first.Title != "Example Trilogy" ||
		first.Children != 3 || first.Thumb != "/library/collections/901/composite/100" || first.Art != "/library/metadata/901/art/100" {
		t.Fatalf("first collection decoded as %+v", first)
	}
	if second := items[1]; second.Title != "Cafe Shows" || second.Subtype != "show" || second.Children != 1 || second.Art != "" {
		t.Fatalf("second collection decoded as %+v", second)
	}
	if first.Playable() {
		t.Fatal("a collection reported as playable")
	}

	kids, total, err := c.Page("/library/collections/901/children", nil, 0, 60)
	if err != nil {
		t.Fatal(err)
	}
	if total != 3 || len(kids) != 3 || kids[0].Type != "movie" || kids[0].Aspect != 1.33 || kids[2].Title != "Part Three" {
		t.Fatalf("collection items: total %d, %+v", total, kids)
	}
}
