package ui

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"plexcrt/internal/plex"
)

// SupportersURL is the MisterZine site's list of Patreon supporters, the
// one the MisterZine app's Credits page shows. The site's update workflow
// keeps it in step with Patreon, so a name added there reaches this app on
// its next check, without a release. The names are never in this source.
// Tests blank it, so they stay off the network.
var SupportersURL = "https://misterzine.fyi/supporters.json"

// Supporter is one Patreon member as supporters.json lists them.
type Supporter struct {
	Name string `json:"name"`
}

// Supporters is who supports MisterZine on Patreon now and who has in the
// past. The file's early adopters tested the MisterZine app, not this one,
// so they are not read.
type Supporters struct {
	Current []Supporter `json:"current"`
	Past    []Supporter `json:"past"`
}

// maxSupporterName caps a name: the longest on the list is 21 letters, and
// a runaway one must not cost the page's text fitting its time.
const maxSupporterName = 48

// DecodeSupporters parses supporters.json. A file without the current list
// is not one, whatever else it holds (an error reply, say), so it cannot
// replace a good list or its cached copy. Names are folded to what the
// fonts can draw, trimmed and capped, and blank ones dropped, so a damaged
// file cannot put an empty row on the page.
func DecodeSupporters(b []byte) (Supporters, error) {
	var raw struct {
		Current *[]Supporter `json:"current"`
		Past    []Supporter  `json:"past"`
	}
	if err := json.Unmarshal(b, &raw); err != nil {
		return Supporters{}, err
	}
	if raw.Current == nil {
		return Supporters{}, fmt.Errorf("not a supporters list")
	}
	clean := func(in []Supporter) []Supporter {
		var out []Supporter
		for _, p := range in {
			name := strings.Join(strings.Fields(plex.Fold(p.Name)), " ")
			if len(name) > maxSupporterName { // folded to ASCII: bytes are letters
				name = strings.TrimSpace(name[:maxSupporterName])
			}
			if name != "" && len(out) < 2000 {
				out = append(out, Supporter{Name: name})
			}
		}
		return out
	}
	return Supporters{Current: clean(*raw.Current), Past: clean(raw.Past)}, nil
}

// supporterState is the render thread's, except the slot, where the one
// check that is ever out leaves what it found. Later is not used: it drops
// a closure when its queue is full, and a lost result would hold the next
// check back for good.
type supporterState struct {
	list      Supporters
	checking  bool
	nextCheck time.Time
	cacheRead bool // the cached copy has been tried, once per run

	mu   sync.Mutex
	slot supporterSlot
}

type supporterSlot struct {
	cached  *Supporters // the cached copy, read at the start of a run
	done    bool        // the check has finished: fetched or err
	fetched Supporters
	err     error
}

// checkSupporters refreshes the list alongside the release check, every six
// hours, sooner after a failure. It runs on the render thread on every pass
// of the loop, so it also takes up what a finished check left. The first
// check of a run puts the cached copy up while the fetch is out, so the
// list is there offline too.
func (a *App) checkSupporters(now time.Time) {
	st := &a.supporters
	st.mu.Lock()
	slot := st.slot
	if slot.done {
		st.slot = supporterSlot{}
	} else {
		st.slot.cached = nil
	}
	st.mu.Unlock()
	if slot.cached != nil && st.list.Current == nil && st.list.Past == nil {
		st.list = *slot.cached // unless a list is up already
		a.dirty = true
	}
	if slot.done {
		st.checking = false
		if slot.err != nil {
			st.nextCheck = now.Add(5 * time.Minute)
			if a.Log != nil {
				a.Log.Printf("supporters: %v", slot.err)
			}
		} else {
			st.list = slot.fetched
			a.dirty = true
		}
	}
	if SupportersURL == "" || st.checking || now.Before(st.nextCheck) {
		return
	}
	st.checking = true
	st.nextCheck = now.Add(6 * time.Hour)
	cache := ""
	if a.cacheDir != "" {
		cache = filepath.Join(a.cacheDir, "supporters.json")
	}
	readCache := !st.cacheRead
	st.cacheRead = true
	address := SupportersURL
	go func() {
		if readCache && cache != "" {
			if b, err := os.ReadFile(cache); err == nil {
				if s, err := DecodeSupporters(b); err == nil {
					st.mu.Lock()
					st.slot.cached = &s
					st.mu.Unlock()
					a.WakeUp()
				}
			}
		}
		b, err := fetchSupporters(address)
		var s Supporters
		if err == nil {
			s, err = DecodeSupporters(b)
		}
		if err == nil && cache != "" {
			tmp := cache + ".tmp" // one check at a time: the name is this one's
			if os.WriteFile(tmp, b, 0o600) == nil {
				_ = os.Rename(tmp, cache)
			}
		}
		st.mu.Lock()
		st.slot.done, st.slot.fetched, st.slot.err = true, s, err
		st.mu.Unlock()
		a.WakeUp()
	}()
}

// fetchSupporters gets the file whole; it is a few kilobytes. The query
// defeats the site's CDN cache, as the MisterZine app does.
func fetchSupporters(address string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, "GET", address+"?t="+strconv.FormatInt(time.Now().UnixMilli(), 10), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "MisterZine-Plex")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("status %d", resp.StatusCode)
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, 256<<10+1))
	if err == nil && len(b) > 256<<10 {
		err = fmt.Errorf("list too large")
	}
	return b, err
}
