package ui

import (
	"image"
	"image/png"
	"net/http"
	"net/http/httptest"
	"os"
	"sync"
	"testing"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/plex"
)

func TestArtVisibleBeforePrefetch(t *testing.T) {
	a := NewArt(nil, 0, nil)
	a.Get("visible", WallPW, WallPH)
	a.Prefetch("far", WallPW, WallPH)
	a.Prefetch("near", WallPW, WallPH)
	for _, want := range []string{"visible", "near", "far"} {
		r, ok := a.nextWant()
		if !ok || r.thumb != want {
			t.Fatalf("got %q, want %q", r.thumb, want)
		}
	}
}

func TestArtPromoteAndExpirePrefetch(t *testing.T) {
	a := NewArt(nil, 0, nil)
	a.Prefetch("old row", WallPW, WallPH)
	for i := 0; i <= wantTTL; i++ {
		a.Frame()
	}
	a.Prefetch("now visible", WallPW, WallPH)
	a.Get("now visible", WallPW, WallPH)
	a.Prefetch("now visible", WallPW, WallPH)
	a.Prefetch("new nearby row", WallPW, WallPH)
	r, ok := a.nextWant()
	if !ok || r.thumb != "now visible" || r.prefetch {
		t.Fatalf("visible promotion lost: %+v", r)
	}
	r, ok = a.nextWant()
	if !ok || r.thumb != "new nearby row" {
		t.Fatalf("new neighborhood missing: %+v", r)
	}
	if _, ok := a.nextWant(); ok {
		t.Fatal("stale neighborhood survived jump")
	}
}

func TestArtEvictionWhenAllEntriesAreRecent(t *testing.T) {
	a := NewArt(nil, 0, nil)
	for i := 0; i <= ArtCap; i++ {
		key := string(rune(i + 1))
		a.have[key] = &artEntry{used: a.frame}
		a.order = append(a.order, key)
	}
	a.evict()
	if len(a.have) != ArtCap {
		t.Fatal("cache exceeded its memory bound")
	}
}

func TestArtReservedWorkerLeavesPreloadsQueued(t *testing.T) {
	a := NewArt(nil, 0, nil)
	a.Prefetch("nearby", PosterW, PosterH)
	a.Warm(artReq{thumb: "distant", w: PosterW, h: PosterH})
	if _, ok := a.nextRequest(false); ok {
		t.Fatal("reserved worker took speculative work")
	}
	a.Get("visible", PosterW, PosterH)
	r, ok := a.nextRequest(false)
	if !ok || r.thumb != "visible" {
		t.Fatal("visible work did not reach reserved worker")
	}
	r, ok = a.nextRequest(true)
	if !ok || r.thumb != "nearby" || r.diskOnly {
		t.Fatal("nearby image should still decode")
	}
	r, ok = a.nextRequest(true)
	if !ok || r.thumb != "distant" || !r.diskOnly {
		t.Fatal("distant image should only warm disk cache")
	}
}

func TestArtVisibleLoadsWhileBackgroundDownloadBlocked(t *testing.T) {
	started := make(chan struct{})
	release := make(chan struct{})
	var once sync.Once
	defer once.Do(func() { close(release) })
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("url") == "slow" {
			close(started)
			<-release
		}
		png.Encode(w, image.NewRGBA(image.Rect(0, 0, 4, 4)))
	}))
	defer server.Close()
	// Release blocked handlers before Server.Close, including on test failure.
	defer once.Do(func() { close(release) })
	client := plex.New(server.URL, "", t.TempDir(), "test")
	a := NewArt(client, 2, make(chan struct{}, 16))
	a.Warm(artReq{thumb: "slow", w: 4, h: 4})
	select {
	case <-started:
	case <-time.After(3 * time.Second):
		t.Fatal("preload never started")
	}
	a.Get("visible", 4, 4)
	deadline := time.Now().Add(3 * time.Second)
	for a.Get("visible", 4, 4) == nil {
		if time.Now().After(deadline) {
			t.Fatal("visible image waited for unrelated background download")
		}
		time.Sleep(time.Millisecond)
	}
	once.Do(func() { close(release) })
	for a.Pending() {
		if time.Now().After(deadline) {
			t.Fatal("preload did not complete")
		}
		time.Sleep(time.Millisecond)
	}
	a.mu.Lock()
	_, decoded := a.have[(artReq{thumb: "slow", w: 4, h: 4}).key()]
	a.mu.Unlock()
	if decoded {
		t.Fatal("distant preload decoded an image into RAM")
	}
	// Reuse the downloaded file without contacting the server again.
	server.Close()
	a.Get("slow", 4, 4)
	deadline = time.Now().Add(3 * time.Second)
	for a.Get("slow", 4, 4) == nil {
		if time.Now().After(deadline) {
			t.Fatal("visible image did not reuse warmed disk cache")
		}
		time.Sleep(time.Millisecond)
	}
}

// A noStore picture is served and decoded but never written to the disk
// cache; one the cache holds already is read from it, not from the server.
func TestArtNoStoreLeavesDiskCacheAlone(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		png.Encode(w, image.NewRGBA(image.Rect(0, 0, 8, 9)))
	}))
	defer server.Close()
	dir := t.TempDir()
	a := NewArt(plex.New(server.URL, "", dir, "test"), 0, nil)
	files := func() int {
		entries, err := os.ReadDir(dir)
		if err != nil {
			t.Fatal(err)
		}
		return len(entries)
	}
	r := artReq{thumb: "shown once", w: 8, h: 8, noStore: true}
	img, err := a.fetch(r)
	if err != nil || img == nil || img.W != 8 || img.H != 8 {
		t.Fatalf("noStore picture not served: %v", err)
	}
	if n := files(); n != 0 {
		t.Fatalf("noStore wrote %d files to the disk cache", n)
	}
	r.noStore = false
	if _, err := a.fetch(r); err != nil {
		t.Fatal(err)
	}
	if n := files(); n != 1 {
		t.Fatalf("a stored fetch left %d files in the disk cache", n)
	}
	server.Close()
	r.noStore = true
	if img, err := a.fetch(r); err != nil || img == nil {
		t.Fatalf("noStore did not read the cached copy: %v", err)
	}
	if n := files(); n != 1 {
		t.Fatalf("the disk cache holds %d files after reading one", n)
	}
}

func TestHomeBackdropPositionAndFade(t *testing.T) {
	img := &gfx.Image{W: 1, H: 480, Pix: make([]byte, 480*4)}
	for y := 0; y < 480; y++ {
		img.Pix[y*4], img.Pix[y*4+1], img.Pix[y*4+2] = byte(y%256), 200, 200
	}
	homeBackdropTreat(img, 255)
	if img.Pix[0] != 60 {
		t.Fatal("home art did not shift up by one eighth")
	}
	if img.Pix[260*4+1] >= 100 {
		t.Fatal("poster area is not dark enough")
	}
	for y := 350; y < 480; y++ {
		if img.Pix[y*4] != byte(gfx.Bg&255) || img.Pix[y*4+1] != byte(gfx.Bg>>8&255) || img.Pix[y*4+2] != byte(gfx.Bg>>16&255) {
			t.Fatal("bottom edge is not seamless")
		}
	}
	plain := artReq{thumb: "art", w: 720, h: 480, bright: HeroBright, fade: HeroFade}
	home := plain
	home.homeBackdrop = true
	if plain.key() == home.key() {
		t.Fatal("home treatment changed shared show artwork")
	}
}

func TestArtNavigationPauseKeepsVisibleWorkAndResumes(t *testing.T) {
	wake := make(chan struct{}, 1)
	a := NewArt(nil, 0, wake)
	a.Prefetch("nearby", PosterW, PosterH)
	a.Warm(artReq{thumb: "distant", w: PosterW, h: PosterH})
	a.DeferBackground(time.Now().Add(time.Hour))
	if _, ok := a.nextRequest(true); ok {
		t.Fatal("speculative work started during navigation pause")
	}
	a.Get("visible", PosterW, PosterH)
	r, ok := a.nextRequest(true)
	if !ok || r.thumb != "visible" {
		t.Fatal("pause blocked visible artwork")
	}
	a.DeferBackground(time.Now().Add(10 * time.Millisecond))
	select {
	case <-wake:
	case <-time.After(time.Second):
		t.Fatal("background work did not wake after release")
	}
	r, ok = a.nextRequest(true)
	if !ok || r.thumb != "nearby" {
		t.Fatal("nearby preload did not resume")
	}
	r, ok = a.nextRequest(true)
	if !ok || r.thumb != "distant" {
		t.Fatal("all-row queue did not survive pause")
	}
}
