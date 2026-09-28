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

// DecodeSupporters parses supporters.json. Names are folded to what the
// fonts can draw and trimmed, and blank ones dropped, so a damaged file
// cannot put an empty row on the page.
func DecodeSupporters(b []byte) (Supporters, error) {
	var s Supporters
	if err := json.Unmarshal(b, &s); err != nil {
		return Supporters{}, err
	}
	clean := func(in []Supporter) []Supporter {
		var out []Supporter
		for _, p := range in {
			p.Name = strings.Join(strings.Fields(plex.Fold(p.Name)), " ")
			if p.Name != "" && len(out) < 2000 {
				out = append(out, p)
			}
		}
		return out
	}
	s.Current, s.Past = clean(s.Current), clean(s.Past)
	return s, nil
}

type supporterState struct {
	list      Supporters
	checking  bool
	nextCheck time.Time
	cacheRead bool // the cached copy has been tried, once per run
}

// checkSupporters refreshes the list alongside the release check, every six
// hours, sooner after a failure. The first check of a run puts the cached
// copy up while the fetch is out, so the list is there offline too.
func (a *App) checkSupporters(now time.Time) {
	st := &a.supporters
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
					a.Later(func() {
						if st.list.Current == nil && st.list.Past == nil {
							st.list = s // unless a list is up already
						}
					})
				}
			}
		}
		b, err := fetchSupporters(address)
		var s Supporters
		if err == nil {
			s, err = DecodeSupporters(b)
		}
		if err == nil && cache != "" {
			tmp := cache + ".tmp"
			if os.WriteFile(tmp, b, 0o600) == nil {
				_ = os.Rename(tmp, cache)
			}
		}
		a.Later(func() {
			st.checking = false
			if err != nil {
				st.nextCheck = time.Now().Add(5 * time.Minute)
				if a.Log != nil {
					a.Log.Printf("supporters: %v", err)
				}
				return
			}
			st.list = s
		})
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
