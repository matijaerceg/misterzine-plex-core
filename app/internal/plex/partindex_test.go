package plex

import (
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

// An item's part says whether the server has made preview frames, and
// PartIndex fetches them with the token in a header, never in the URL.
func TestPartIndexesAndTheirFetch(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/library/metadata/5":
			io.WriteString(w, `<MediaContainer><Video ratingKey="5" type="movie" title="A"><Media><Part id="77" indexes="sd"/></Media></Video></MediaContainer>`)
		case "/library/parts/77/indexes/sd":
			if r.Header.Get("X-Plex-Token") != "tok" || r.URL.Query().Get("X-Plex-Token") != "" || r.URL.Query().Get("interval") != "10000" {
				http.Error(w, "no", http.StatusUnauthorized)
				return
			}
			io.WriteString(w, "BIF")
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	c := New(server.URL, "tok", t.TempDir(), "")
	it, err := c.Item("5")
	if err != nil {
		t.Fatal(err)
	}
	if it.PartID != "77" || it.Indexes != "sd" {
		t.Fatalf("part %q indexes %q", it.PartID, it.Indexes)
	}
	data, err := c.PartIndex(it.PartID)
	if err != nil || string(data) != "BIF" {
		t.Fatalf("PartIndex: %q %v", data, err)
	}
}
