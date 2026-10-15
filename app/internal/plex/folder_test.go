package plex

import (
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

// A folder view's listing mixes folders (Directories without a rating key
// or a type, their Key the path of their own listing) and files; both
// come through Page, the folders as such. Synthetic fixtures only.
func TestFolderListing(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/library/sections/1/folder" && r.URL.Query().Get("parent") == "":
			io.WriteString(w, `<MediaContainer size="2" totalSize="2">`+
				`<Directory key="/library/sections/1/folder?parent=12" title="Artist One"/>`+
				`<Directory key="/library/sections/1/folder?parent=13" title="Artist Two"/>`+
				`</MediaContainer>`)
		case r.URL.Path == "/library/sections/1/folder" && r.URL.Query().Get("parent") == "12":
			io.WriteString(w, `<MediaContainer size="2" totalSize="2">`+
				`<Directory key="/library/sections/1/folder?parent=14" title="Live"/>`+
				`<Video ratingKey="31" key="/library/metadata/31" type="movie" title="First Clip" thumb="/t/31"/>`+
				`</MediaContainer>`)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	c := New(server.URL, "tok", t.TempDir(), "")

	path, q := FolderListing("1", "")
	items, total, err := c.Page(path, q, 0, 60)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 2 || total != 2 {
		t.Fatalf("%d root folders of %d", len(items), total)
	}
	root := items[0]
	if !root.IsFolder() || root.Title != "Artist One" || root.Key != "/library/sections/1/folder?parent=12" {
		t.Fatalf("root folder %+v", root)
	}

	path, q = FolderListing("1", root.Key)
	if path != "/library/sections/1/folder" || q.Get("parent") != "12" {
		t.Fatalf("the folder's listing is %s?%s", path, q.Encode())
	}
	items, total, err = c.Page(path, q, 0, 60)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 2 || total != 2 {
		t.Fatalf("%d items of %d in the folder", len(items), total)
	}
	if sub := items[0]; !sub.IsFolder() || sub.Title != "Live" {
		t.Fatalf("subfolder %+v", sub)
	}
	if file := items[1]; file.IsFolder() || !file.Playable() || file.RatingKey != "31" || file.Thumb != "/t/31" {
		t.Fatalf("file %+v", file)
	}

	// a key given as a whole URL: its host dropped
	path, q = FolderListing("1", "http://example.invalid:32400/library/sections/1/folder?parent=9")
	if path != "/library/sections/1/folder" || q.Get("parent") != "9" {
		t.Fatalf("an absolute key lists %s?%s", path, q.Encode())
	}
}
