package ui

import (
	"fmt"
	"image"
	"image/png"
	"net/http"
	"net/http/httptest"
	"os"
	"sync"
	"testing"
	"time"

	"plexcrt/internal/gfx"
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

// testPicture is a picture of n bytes; the pixels are shared, only the
// size counts.
func testPicture(n int) *gfx.Image {
	return &gfx.Image{Pix: testPixels[:n]}
}

var testPixels = make([]byte, 2<<20)

// tk is a picture's key by name alone.
func tk(name string) artKey { return artKey{thumb: name} }

func TestArtEvictionWhenAllEntriesAreRecent(t *testing.T) {
	a := NewArt(nil, 0, nil)
	for i := 0; i <= ArtBudget>>20; i++ {
		a.add(tk(string(rune(i+1))), &artEntry{img: testPicture(1 << 20), used: a.frame})
	}
	if a.bytes != ArtBudget || len(a.have) != ArtBudget>>20 {
		t.Fatalf("cache exceeded its memory bound: %d bytes in %d pictures", a.bytes, len(a.have))
	}
}

// The budget counts bytes, not pictures: a backdrop makes room by dropping
// several posters, the least recently used first, while a picture used this
// frame is kept.
func TestArtBudgetEvictsLeastRecentlyUsedBytes(t *testing.T) {
	a := NewArt(nil, 0, nil)
	poster := PosterW * PosterH * 4
	n := ArtBudget / poster
	for i := 0; i < n; i++ {
		a.add(tk(itoa(i)), &artEntry{img: testPicture(poster)})
	}
	for i := 0; i <= wantTTL; i++ {
		a.Frame()
	}
	a.have[tk("0")].used = a.frame // on screen
	backdrop := 720 * 480 * 4
	a.add(tk("backdrop"), &artEntry{img: testPicture(backdrop), used: a.frame, backdrop: true})
	if a.bytes > ArtBudget {
		t.Fatalf("%d bytes held, budget %d", a.bytes, ArtBudget)
	}
	dropped := n + 1 - len(a.have)
	if want := (backdrop - (ArtBudget - n*poster) + poster - 1) / poster; dropped != want {
		t.Fatalf("dropped %d posters for a backdrop, want %d", dropped, want)
	}
	if a.have[tk("0")] == nil || a.have[tk("backdrop")] == nil {
		t.Fatal("dropped a picture in use")
	}
	for i := 1; i <= dropped; i++ {
		if a.have[tk(itoa(i))] != nil {
			t.Fatalf("poster %d survived a newer one", i)
		}
	}
	total := 0
	for _, e := range a.have {
		total += e.size
	}
	if total != a.bytes || len(a.order) != len(a.have) {
		t.Fatalf("accounting drifted: %d bytes counted, %d held; %d ordered, %d held", a.bytes, total, len(a.order), len(a.have))
	}
}

// Backdrops have a cap of their own within the budget: the oldest backdrop
// goes, not the posters around it.
func TestArtBackdropCap(t *testing.T) {
	a := NewArt(nil, 0, nil)
	for i := 0; i <= ArtBackdrops; i++ {
		a.add(tk("poster"+itoa(i)), &artEntry{img: testPicture(PosterW * PosterH * 4)})
		a.add(tk("backdrop"+itoa(i)), &artEntry{img: testPicture(720 * 480 * 4), backdrop: true})
		a.Frame()
		a.Frame()
	}
	if a.backdrops != ArtBackdrops || a.have[tk("backdrop0")] != nil || a.have[tk("backdrop1")] == nil {
		t.Fatalf("%d backdrops held, the oldest kept: %v", a.backdrops, a.have[tk("backdrop0")] != nil)
	}
	for i := 0; i <= ArtBackdrops; i++ {
		if a.have[tk("poster"+itoa(i))] == nil {
			t.Fatalf("poster %d made way for a backdrop", i)
		}
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
	client := testClient(server.URL, "", t.TempDir())
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
	a := NewArt(testClient(server.URL, "", dir), 0, nil)
	files := func() int {
		entries, err := os.ReadDir(dir)
		if err != nil {
			t.Fatal(err)
		}
		return len(entries)
	}
	r := artReq{thumb: "once", w: 8, h: 8, noStore: true}
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

// The queue is ordered by when each want was last asked for: a want asked
// again goes ahead of those since, and only the newest wantCap are kept.
func TestArtWantQueueOrder(t *testing.T) {
	a := NewArt(nil, 0, nil)
	for i := 0; i < wantCap+2; i++ {
		a.Get(itoa(i), WallPW, WallPH)
	}
	a.Get("2", WallPW, WallPH)
	if len(a.wants) != wantCap {
		t.Fatalf("%d wants kept, want %d", len(a.wants), wantCap)
	}
	want := []string{"2"}
	for i := wantCap + 1; i > 2; i-- {
		want = append(want, itoa(i))
	}
	for _, thumb := range want {
		if r, ok := a.nextWant(); !ok || r.thumb != thumb {
			t.Fatalf("got %q, want %q", r.thumb, thumb)
		}
	}
	if r, ok := a.nextWant(); ok {
		t.Fatalf("the oldest wants survived the cap: %q", r.thumb)
	}
}

// A wall frame asks for every poster on screen and the rows around it.
func BenchmarkArtGetHit(b *testing.B) {
	a := NewArt(nil, 0, nil)
	var thumbs []string
	for i := 0; i < 64; i++ {
		thumb := fmt.Sprintf("/library/metadata/%d/thumb/%d", i, 1600000000+i*7)
		thumbs = append(thumbs, thumb)
		img := &gfx.Image{W: WallPW, H: WallPH}
		a.have[(artReq{thumb: thumb, w: WallPW, h: WallPH}).key()] = &artEntry{img: img}
	}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if img, _ := a.GetAge(thumbs[i%len(thumbs)], WallPW, WallPH); img == nil {
			b.Fatal("miss")
		}
	}
}

// Posters still on their way are asked for again every frame.
func BenchmarkArtGetMiss(b *testing.B) {
	a := NewArt(nil, 0, nil)
	var thumbs []string
	for i := 0; i < 64; i++ {
		thumbs = append(thumbs, fmt.Sprintf("/library/metadata/%d/thumb/%d", i, 1600000000+i*7))
	}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if img := a.Get(thumbs[i%len(thumbs)], WallPW, WallPH); img != nil {
			b.Fatal("hit")
		}
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
