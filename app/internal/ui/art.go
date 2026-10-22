package ui

import (
	"fmt"
	"runtime"
	"sync"
	"syscall"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/plex"
)

// Art fetches pictures in the background. Get never blocks: it returns the
// picture if decoded, else records the want and returns nil; Wake fires when
// one lands. Visible wants precede prefetches, newest first within each group.
// A want that no screen has repeated within the last few frames is dropped,
// so after a jump the
// posters on screen come first and the ones scrolled past are never fetched.
// The decoded set is bounded (LRU) so memory stays flat however far you scroll.
type Art struct {
	client          *plex.Client
	generation      uint64 // discards downloads from a previous account or server
	mu              sync.Mutex
	cond            *sync.Cond
	have            map[artKey]*artEntry
	order           []artKey // LRU, oldest first
	bytes           int      // pixels held in have
	backdrops       int      // backdrops in have
	warm            []artReq // persistent, low-priority home-screen cache warming
	warmed          map[artKey]bool
	wants           map[artKey]artReq // pending; workers take the newest (highest seq)
	wantSeq         uint64
	busy            map[artKey]bool
	failed          map[artKey]bool
	frame           uint64 // bumped by Frame; wants carry the frame they were last asked in
	Wake            chan struct{}
	backgroundUntil time.Time
	backgroundTimer *time.Timer
}

type artEntry struct {
	img      *gfx.Image
	band     *gfx.Image // wall poster under the title strip, shaded off-thread
	used     uint64
	at       time.Time // when it landed, for the fade-in
	size     int       // bytes of pixels held, the band's included
	backdrop bool      // a full-frame backdrop, also counted against ArtBackdrops
}

type artReq struct {
	thumb string
	w, h  int
	logo  bool // a clear logo: PNG with alpha, fitted inside w x h
	// a backdrop treatment: dimmed to bright/255 and faded into the
	// background over its bottom fade px (0,0: none)
	bright, fade int
	homeBackdrop bool // home-only positioning and stronger poster-area gradient
	asked        uint64
	seq          uint64 // when last asked for, in order: the newest goes first
	prefetch     bool   // spare work: visible requests always go first
	diskOnly     bool   // whole-home warming downloads without decoding
	noStore      bool   // never written to the disk cache, though a cached copy is read
}

// ArtBudget bounds the decoded pictures' pixels across visible and nearby
// rows, backdrops and other screens, whatever their sizes: a poster is
// 95 KB, a wall poster with its pre-shaded title-strip copy 150 KB, a
// backdrop 1.3 MB. The heap is held to 96 MB (App) and some 35 to 40 MB of
// it is the screens' own: the fade's 13 step pages alone are 18 MB, then
// each screen's composed pages, the presenter's frame, fonts and listings.
// 32 MB of pictures (some 200 wall posters) leaves the collector over 20 MB
// to work in.
const ArtBudget = 32 << 20

// ArtBackdrops bounds the backdrops within the budget, so that browsing
// heroes does not push the posters out: home's hero and the five around it
// it prefetches, a show's and a film's page, and a couple the cursor has
// just left.
const ArtBackdrops = 10

// wantTTL is how many frames a want survives without being asked again.
const wantTTL = 3

// wantCap is how many wants are kept, the newest.
const wantCap = 64

// artKey names a decoded picture: the request without its scheduling. It is
// a plain value, so looking a picture up every frame builds no string.
type artKey struct {
	thumb        string
	w, h         int
	bright, fade int
	logo         bool
	homeBackdrop bool
}

func (r artReq) key() artKey {
	k := artKey{thumb: r.thumb, w: r.w, h: r.h, logo: r.logo}
	if !r.logo && (r.homeBackdrop || r.fade > 0) {
		k.bright, k.fade, k.homeBackdrop = r.bright, r.fade, r.homeBackdrop
	}
	return k
}

// NewArt starts n fetch workers; wake is signalled when a picture lands.
func NewArt(c *plex.Client, n int, wake chan struct{}) *Art {
	a := &Art{client: c, have: map[artKey]*artEntry{}, wants: map[artKey]artReq{}, busy: map[artKey]bool{}, failed: map[artKey]bool{}, Wake: wake}
	a.cond = sync.NewCond(&a.mu)
	for i := 0; i < n; i++ {
		go a.worker(i == n-1)
	}
	return a
}

// SetClient forgets the previous account's decoded and queued artwork.
func (a *Art) SetClient(c *plex.Client) {
	a.mu.Lock()
	a.client = c
	a.generation++
	a.have = map[artKey]*artEntry{}
	a.wants = map[artKey]artReq{}
	a.busy = map[artKey]bool{}
	a.order = nil
	a.bytes, a.backdrops = 0, 0
	a.failed = map[artKey]bool{}
	a.warm, a.warmed = nil, nil
	a.mu.Unlock()
}

// Frame marks the start of a frame; wants not repeated since a few frames
// ago expire.
func (a *Art) Frame() {
	a.mu.Lock()
	a.frame++
	a.mu.Unlock()
}

// DeferBackground pauses speculative requests, but never visible artwork.
// A deadline survives a lost key release without leaving preloading disabled.
func (a *Art) DeferBackground(until time.Time) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.backgroundUntil = until
	if a.backgroundTimer == nil {
		a.backgroundTimer = time.AfterFunc(time.Until(until), func() {
			a.mu.Lock()
			defer a.mu.Unlock()
			if time.Now().Before(a.backgroundUntil) {
				return
			}
			a.cond.Broadcast()
			select {
			case a.Wake <- struct{}{}:
			default:
			}
		})
	} else {
		a.backgroundTimer.Reset(time.Until(until))
	}
}

// Only one worker may start speculative work. The others remain available
// for visible requests even while a slow preload is in flight.
func (a *Art) worker(background bool) {
	// decoding must never steal a field from the drawing loop: the worker
	// keeps its own OS thread and lowers that thread's priority
	runtime.LockOSThread()
	syscall.Setpriority(syscall.PRIO_PROCESS, 0, 10)
	for {
		a.mu.Lock()
		var r artReq
		for {
			// newest want that is still current
			if next, ok := a.nextRequest(background); ok {
				r = next
				goto found
			}
			a.cond.Wait()
		}
	found:
		k := r.key()
		a.busy[k] = true
		client, generation := a.client, a.generation
		a.mu.Unlock()

		var img *gfx.Image
		var err error
		if r.diskOnly {
			_, err = artFile(client, r)
		} else {
			img, err = fetchArt(client, r)
		}
		var band *gfx.Image
		if err == nil && !r.diskOnly && r.w == WallPW && r.h == WallPH && !r.logo && r.fade == 0 {
			band = wallBandImage(img)
		}

		a.mu.Lock()
		if generation != a.generation {
			a.mu.Unlock()
			continue
		}
		delete(a.busy, k)
		if err != nil {
			a.failed[k] = true
		} else if !r.diskOnly {
			a.add(k, &artEntry{img: img, band: band, used: a.frame, at: time.Now(), backdrop: r.fade > 0})
		}
		a.mu.Unlock()
		select {
		case a.Wake <- struct{}{}:
		default:
		}
	}
}

// nextRequest is called under mu. Discard stale work, then take the newest
// visible request, falling back (when background allows) to the newest
// nearby-row request.
func (a *Art) nextRequest(background bool) (artReq, bool) {
	background = background && !time.Now().Before(a.backgroundUntil)
	var next artReq
	found := false
	for k, r := range a.wants {
		if r.asked+wantTTL < a.frame {
			delete(a.wants, k)
			continue
		}
		if !found || next.prefetch && !r.prefetch || next.prefetch == r.prefetch && r.seq > next.seq {
			next, found = r, true
		}
	}
	if found && (!next.prefetch || background) {
		delete(a.wants, next.key())
		return next, true
	}
	if background {
		for len(a.warm) > 0 {
			r := a.warm[0]
			a.warm = a.warm[1:]
			k := r.key()
			if a.have[k] == nil && !a.busy[k] && !a.failed[k] {
				return r, true
			}
		}
	}
	return artReq{}, false
}

// Warm schedules an image once for this server, behind visible and nearby
// work. Unlike viewport requests it survives frame expiry, so every home row
// eventually reaches the disk cache without pinning all decoded art in RAM.
func (a *Art) Warm(r artReq) {
	if r.thumb == "" {
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.warmed == nil {
		a.warmed = make(map[artKey]bool)
	}
	k := r.key()
	if a.warmed[k] {
		return
	}
	a.warmed[k] = true
	r.prefetch = true
	r.diskOnly = true
	a.warm = append(a.warm, r)
	a.cond.Broadcast()
}

// Prefetch warms a nearby poster without competing with queued visible art.
func (a *Art) Prefetch(thumb string, w, h int) {
	a.get(artReq{thumb: thumb, w: w, h: h, prefetch: true})
}

func (a *Art) wallBand(thumb string) *gfx.Image {
	img, _, _ := a.getImage(artReq{thumb: thumb, w: WallPW, h: WallPH}, true)
	return img
}

// add takes a decoded picture in, as the newest, and evicts beyond the
// budget. Called under mu.
func (a *Art) add(k artKey, e *artEntry) {
	if old := a.have[k]; old != nil {
		a.drop(k, old)
	} else {
		a.order = append(a.order, k)
	}
	e.size = 0
	if e.img != nil {
		e.size += len(e.img.Pix)
	}
	if e.band != nil {
		e.size += len(e.band.Pix)
	}
	a.have[k] = e
	a.bytes += e.size
	if e.backdrop {
		a.backdrops++
	}
	a.evict()
}

// drop forgets a decoded picture; its key leaves order separately.
func (a *Art) drop(k artKey, e *artEntry) {
	delete(a.have, k)
	a.bytes -= e.size
	if e.backdrop {
		a.backdrops--
	}
}

// evict drops the least recently used backdrops beyond their cap, then the
// least recently used pictures beyond the budget.
func (a *Art) evict() {
	a.evictWhile(func() bool { return a.backdrops > ArtBackdrops }, true)
	a.evictWhile(func() bool { return a.bytes > ArtBudget }, false)
}

// evictWhile drops pictures oldest first, only backdrops if asked, while
// over holds.
func (a *Art) evictWhile(over func() bool, backdrops bool) {
	remaining := len(a.order)
	for i := 0; over() && i < len(a.order); {
		// the order list is only approximately LRU: promote entries used
		// this frame instead of dropping them
		k := a.order[i]
		e := a.have[k]
		if e != nil && backdrops && !e.backdrop {
			i++
			continue
		}
		a.order = append(a.order[:i], a.order[i+1:]...)
		if e == nil {
			continue
		}
		if e.used+1 >= a.frame && remaining > 0 {
			remaining--
			a.order = append(a.order, k)
			continue
		}
		a.drop(k, e)
	}
}

// The frame's pixels are 8/9 as wide as tall on the tube. Pictures are
// fetched at square pixels for the shape they will have on screen (a
// poster box of 135x180 frame px is 135x203 square px) and squeezed
// vertically here, so nothing is cropped; logos are fetched 8/9 as wide.
func artFile(client *plex.Client, r artReq) (string, error) {
	if client == nil {
		return "", fmt.Errorf("no artwork client")
	}
	if r.logo {
		return client.Logo(r.thumb, r.w*8/9, r.h)
	}
	return client.Art(r.thumb, r.w, (r.h*9+4)/8)
}

// fetchData is fetchFile for noStore: the picture's bytes, from the disk
// cache when it holds them, else from the server without caching them.
func artData(client *plex.Client, r artReq) ([]byte, error) {
	if client == nil {
		return nil, fmt.Errorf("no artwork client")
	}
	if r.logo {
		return client.LogoData(r.thumb, r.w*8/9, r.h)
	}
	return client.ArtData(r.thumb, r.w, (r.h*9+4)/8)
}

// load decodes the picture as fetched, before any treatment.
func loadArt(client *plex.Client, r artReq) (*gfx.Image, error) {
	if r.noStore {
		data, err := artData(client, r)
		if err != nil {
			return nil, err
		}
		return gfx.Decode(data)
	}
	path, err := artFile(client, r)
	if err != nil {
		return nil, err
	}
	return gfx.LoadFile(path)
}

func (a *Art) fetch(r artReq) (*gfx.Image, error) {
	a.mu.Lock()
	client := a.client
	a.mu.Unlock()
	return fetchArt(client, r)
}

func fetchArt(client *plex.Client, r artReq) (*gfx.Image, error) {
	img, err := loadArt(client, r)
	if err != nil {
		return nil, err
	}
	if r.logo {
		return img, nil
	}
	img = img.Crop(r.w, (r.h*9+4)/8).ScaleH(r.h)
	if r.homeBackdrop {
		homeBackdropTreat(img, r.bright)
	} else if r.fade > 0 {
		fadeTreat(img, r.bright, r.fade)
	}
	return img, nil
}

// fadeTreat dims a backdrop to bright/255 and fades its bottom fade px
// into the background colour, so what is below continues seamlessly and
// text sits in the fade. Done once, off the render thread.
func fadeTreat(img *gfx.Image, bright, fade int) {
	bb, bg, br := int(gfx.Bg&0xFF), int(gfx.Bg>>8&0xFF), int(gfx.Bg>>16&0xFF)
	for y := 0; y < img.H; y++ {
		mix := 0 // of 256 towards the background
		if y >= img.H-fade {
			f := y - (img.H - fade) + 1
			mix = min(256, f*f*256/(fade*fade)) // ease in, ending on the background itself
		}
		row := img.Pix[y*img.W*4 : (y+1)*img.W*4]
		for i := 0; i < len(row); i += 4 {
			b := int(row[i]) * bright / 255
			g := int(row[i+1]) * bright / 255
			r := int(row[i+2]) * bright / 255
			row[i] = byte(b + (bb-b)*mix>>8)
			row[i+1] = byte(g + (bg-g)*mix>>8)
			row[i+2] = byte(r + (br-r)*mix>>8)
		}
	}
}

// Home art sits 12.5% higher. Its smooth, shorter gradient is almost dark
// by the poster midline and reaches the background at y=350 on a 480-line
// frame. Prepare it once on the artwork worker, never during animation.
func homeBackdropTreat(img *gfx.Image, bright int) {
	shift := img.H / 8
	copy(img.Pix, img.Pix[shift*img.W*4:])
	start, end := img.H*130/480, img.H*350/480
	bb, bg, br := int(gfx.Bg&255), int(gfx.Bg>>8&255), int(gfx.Bg>>16&255)
	for y := 0; y < img.H; y++ {
		t := max(0, min(256, (y-start)*256/max(1, end-start)))
		mix := t * t * (768 - 2*t) / (256 * 256) // smoothstep, with a tighter middle
		row := img.Pix[y*img.W*4 : (y+1)*img.W*4]
		for i := 0; i < len(row); i += 4 {
			b, g, r := int(row[i])*bright/255, int(row[i+1])*bright/255, int(row[i+2])*bright/255
			row[i], row[i+1], row[i+2] = byte(b+(bb-b)*mix/256), byte(g+(bg-g)*mix/256), byte(r+(br-r)*mix/256)
		}
	}
}

// Get returns the picture or nil (wanted, failed or no art).
func (a *Art) Get(thumb string, w, h int) *gfx.Image {
	img, _, _ := a.get(artReq{thumb: thumb, w: w, h: h})
	return img
}

// GetAge returns the picture and how long ago it landed (for fading in).
func (a *Art) GetAge(thumb string, w, h int) (*gfx.Image, time.Duration) {
	img, age, _ := a.get(artReq{thumb: thumb, w: w, h: h})
	return img, age
}

// GetBackdrop returns a backdrop dimmed to bright/255 and faded into the
// background over its bottom fade px, and how long ago it landed.
func (a *Art) GetBackdrop(thumb string, w, h, bright, fade int) (*gfx.Image, time.Duration) {
	img, age, _ := a.get(artReq{thumb: thumb, w: w, h: h, bright: bright, fade: fade})
	return img, age
}

// GetLogo returns a clear logo fitted inside w x h, or nil, and whether
// fetching it has failed (so a title can be shown instead).
func (a *Art) GetLogo(logo string, w, h int) (*gfx.Image, bool) {
	img, _, failed := a.get(artReq{thumb: logo, w: w, h: h, logo: true})
	return img, failed
}

// getLogoAge is GetLogo with how long ago the logo landed.
func (a *Art) getLogoAge(logo string, w, h int) (*gfx.Image, time.Duration, bool) {
	return a.get(artReq{thumb: logo, w: w, h: h, logo: true})
}

func (a *Art) get(r artReq) (*gfx.Image, time.Duration, bool) {
	return a.getImage(r, false)
}

func (a *Art) getImage(r artReq, band bool) (*gfx.Image, time.Duration, bool) {
	if r.thumb == "" {
		return nil, 0, true
	}
	k := r.key()
	a.mu.Lock()
	defer a.mu.Unlock()
	if e, ok := a.have[k]; ok {
		e.used = a.frame
		if band {
			return e.band, time.Since(e.at), false
		}
		return e.img, time.Since(e.at), false
	}
	if a.failed[k] {
		return nil, 0, true
	}
	if a.busy[k] {
		return nil, 0, false
	}
	r.asked = a.frame
	// refresh an existing want (it becomes the newest) or add one
	if old, ok := a.wants[k]; ok && old.asked == a.frame && !old.prefetch {
		// A background touch must not demote a visible want this frame.
		r.prefetch = false
	}
	a.wantSeq++
	r.seq = a.wantSeq
	a.wants[k] = r
	if len(a.wants) > wantCap {
		a.dropOldestWant()
	}
	a.cond.Broadcast()
	return nil, 0, false
}

// dropOldestWant forgets the want asked for longest ago. Called under mu.
func (a *Art) dropOldestWant() {
	var oldest artKey
	seq := ^uint64(0)
	for k, r := range a.wants {
		if r.seq < seq {
			oldest, seq = k, r.seq
		}
	}
	delete(a.wants, oldest)
}

// Pending reports whether anything is still being fetched or wanted.
func (a *Art) Pending() bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	return len(a.busy) > 0 || len(a.wants) > 0 || len(a.warm) > 0
}
