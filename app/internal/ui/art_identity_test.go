package ui

import (
	"image"
	"image/png"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

func TestArtworkSwitchDiscardsOldDownloadsAndQueue(t *testing.T) {
	started, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(started)
		<-release
		png.Encode(w, image.NewRGBA(image.Rect(0, 0, 4, 4)))
	}))
	defer server.Close()
	defer once.Do(func() { close(release) })
	art := NewArt(testClient(server.URL, "old-profile", t.TempDir()), 1, make(chan struct{}, 1))
	art.Get("old", 4, 4)
	select {
	case <-started:
	case <-time.After(3 * time.Second):
		t.Fatal("artwork request did not start")
	}
	art.Prefetch("queued", 4, 4)
	art.SetClient(nil)
	once.Do(func() { close(release) })
	// The same worker can service this sentinel only after completing the old
	// request. With no client it fails locally, without another HTTP request.
	art.Get("sentinel", 4, 4)
	select {
	case <-art.Wake:
	case <-time.After(3 * time.Second):
		t.Fatal("artwork worker did not finish")
	}
	art.mu.Lock()
	defer art.mu.Unlock()
	if len(art.have) != 0 || len(art.wants) != 0 || len(art.busy) != 0 {
		t.Fatal("previous profile's artwork survived switching")
	}
	if !art.failed[(artReq{thumb: "sentinel", w: 4, h: 4}).key()] {
		t.Fatal("worker did not finish the new session's request")
	}
}
