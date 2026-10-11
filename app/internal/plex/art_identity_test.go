package plex

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestArtworkCacheSeparatesAccountsAndServers(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(r.Header.Get("X-Plex-Token")))
	}))
	defer server.Close()
	dir := t.TempDir()
	for _, token := range []string{"first-profile", "second-profile"} {
		client := New(server.URL, token, dir, "client")
		if _, err := client.Art("/library/metadata/1/thumb", 40, 60); err != nil {
			t.Fatal(err)
		}
		data, err := client.ArtData("/library/metadata/1/thumb", 40, 60)
		if err != nil || string(data) != token {
			t.Fatalf("artwork from wrong profile: %q, %v", data, err)
		}
	}
	a := New("http://server-one", "same-token", dir, "client")
	b := New("http://server-two", "same-token", dir, "client")
	first, _, _ := a.pictureSource("same-path", 40, 60, false)
	second, _, _ := b.pictureSource("same-path", 40, 60, false)
	if first == second || strings.Contains(first, "same-token") {
		t.Fatal("artwork cache identity is not isolated or contains credentials")
	}
}
