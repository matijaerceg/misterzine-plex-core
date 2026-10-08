package plex

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"sync/atomic"
	"testing"
)

// A show's episodes come a page at a time until the last, whether or not
// the server gives the total, and a listing that never ends is refused.
func TestShowEpisodesPages(t *testing.T) {
	const n = 1000 // two full pages: the end is only seen by the total or an empty third
	var requests atomic.Int32
	var total, ignoreStart atomic.Bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		if r.URL.Path != "/library/metadata/7/allLeaves" || q.Get("excludeElements") == "" {
			http.NotFound(w, r)
			return
		}
		requests.Add(1)
		start, _ := strconv.Atoi(q.Get("X-Plex-Container-Start"))
		size, _ := strconv.Atoi(q.Get("X-Plex-Container-Size"))
		if ignoreStart.Load() {
			start = 0
		}
		end := min(n, start+size)
		if total.Load() {
			fmt.Fprintf(w, `<MediaContainer size="%d" totalSize="%d">`, end-start, n)
		} else {
			fmt.Fprintf(w, `<MediaContainer size="%d">`, end-start)
		}
		for i := start; i < end; i++ {
			fmt.Fprintf(w, `<Video ratingKey="%d" type="episode"/>`, i)
		}
		io.WriteString(w, "</MediaContainer>")
	}))
	defer server.Close()
	c := New(server.URL, "tok", t.TempDir(), "")

	for _, withTotal := range []bool{true, false} {
		total.Store(withTotal)
		requests.Store(0)
		eps, err := c.ShowEpisodes("7")
		if err != nil {
			t.Fatal(err)
		}
		if len(eps) != n {
			t.Fatalf("total %v: %d episodes", withTotal, len(eps))
		}
		for i, ep := range eps {
			if ep.RatingKey != strconv.Itoa(i) {
				t.Fatalf("total %v: episode %d is %s", withTotal, i, ep.RatingKey)
			}
		}
		if want := map[bool]int32{true: 2, false: 3}[withTotal]; requests.Load() != want {
			t.Fatalf("total %v: %d requests, want %d", withTotal, requests.Load(), want)
		}
	}

	total.Store(false)
	ignoreStart.Store(true)
	if eps, err := c.ShowEpisodes("7"); err == nil {
		t.Fatalf("a listing that never ends gave %d episodes", len(eps))
	}
}
