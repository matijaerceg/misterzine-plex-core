package plex

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestSearchLocalTitles(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/hubs/search" || r.URL.Query().Get("query") != "A & B" || r.URL.Query().Get("type") != "1,2" || r.URL.Query().Get("includeExternalMedia") != "0" {
			t.Errorf("unexpected search request")
		}
		if r.Header.Get("X-Plex-Token") != "test-secret" || r.URL.Query().Has("X-Plex-Token") {
			t.Error("token must be in header only")
		}
		fmt.Fprint(w, `<MediaContainer><Hub><Video type="movie" ratingKey="1" key="/library/metadata/1" title="A &amp; B" year="1990" librarySectionID="4"/><Video type="episode" ratingKey="2" key="/library/metadata/2"/></Hub><Hub><Directory type="show" ratingKey="3" key="/library/metadata/3/children" title="A show"/><Video type="movie" ratingKey="1" key="/library/metadata/1"/><Directory type="show" ratingKey="external" key="https://external/1"/></Hub></MediaContainer>`)
	}))
	defer server.Close()
	c := New(server.URL, "test-secret", t.TempDir(), "")
	items, err := c.Search(context.Background(), " A & B ")
	if err != nil || len(items) != 2 {
		t.Fatalf("got %d items, error %v", len(items), err)
	}
	if items[0].Title != "A & B" || items[1].Type != "show" || items[0].Library != "4" || items[1].Library != "" {
		t.Fatal("incorrect metadata")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := c.Search(ctx, "cancelled"); err == nil {
		t.Fatal("cancelled search succeeded")
	}
}

func TestSearchEmptyAndFailure(t *testing.T) {
	for _, body := range []string{"failure", "<invalid"} {
		calls := 0
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			calls++
			if body == "failure" {
				w.WriteHeader(503)
			}
			fmt.Fprint(w, body)
		}))
		c := New(server.URL, "", t.TempDir(), "")
		if _, err := c.Search(context.Background(), " "); err != nil || calls != 0 {
			t.Fatal("empty query made request")
		}
		if _, err := c.Search(context.Background(), "title"); err == nil {
			t.Fatal("expected failure")
		}
		server.Close()
	}
}
