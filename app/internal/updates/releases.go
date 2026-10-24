// Package updates describes published releases, independently of installation.
package updates

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"plexcrt/internal/beta"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const CatalogueURL = "https://raw.githubusercontent.com/matijaerceg/misterzine-plex-core/distribution/catalogue.json"

// Access is what a beta release asks for: the patron batch and the hash of
// its six-digit code, which the app verifies offline (internal/beta).
type Access struct {
	Batch  string `json:"batch"`
	SHA256 string `json:"sha256"`
}
type Release struct {
	ID      string       `json:"id"`
	Version string       `json:"version"`
	Channel string       `json:"channel"`
	Access  *Access      `json:"access,omitempty"`
	Source  *SourceAsset `json:"source"`
	Notes   string       `json:"notes"`
	URL     string       `json:"url"`
	DBURL   string       `json:"db_url"`
	Size    int64        `json:"size"`
	SHA256  string       `json:"sha256"`
}

// SourceAsset is the corresponding source bundle published beside a
// release (the player links GPL components).
type SourceAsset struct {
	Filename string `json:"filename"`
	Size     int64  `json:"size"`
	SHA256   string `json:"sha256"`
	URL      string `json:"url"`
}

// Catalogue has two slots per channel. Releases is the legacy slot that
// cards from 0.1.0-beta.27 and earlier read: their updater can only install
// the bridge release, so a pinned entry there stays the bridge forever.
// Current is what this and later builds install. LegacyPin names the pinned
// channels; the app only keeps it so a cached catalogue round-trips.
type Catalogue struct {
	Schema    int                `json:"schema"`
	Releases  map[string]Release `json:"releases"`
	Current   map[string]Release `json:"current,omitempty"`
	LegacyPin []string           `json:"legacy_pin,omitempty"`
	Memos     []Memo             `json:"memos,omitempty"`
}

// A Memo is a note from the developers published with the catalogue, so one
// can be added, reworded or withdrawn without an app release. The app shows
// each id once (internal/ui, memo.go); a memo with the id of one compiled
// into the app replaces its text.
type Memo struct {
	ID    string `json:"id"`
	Title string `json:"title"`
	Text  string `json:"text"`
}

const (
	MemoTitleMax = 80
	MemoTextMax  = 600
	MemosMax     = 20
)

var memoID = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)

// Valid says whether a memo can be shown: a plain id, a title and text of
// printable characters within the limits.
func (m Memo) Valid() bool {
	plain := func(s string, max int) bool {
		if s == "" || len(s) > max || strings.TrimSpace(s) != s {
			return false
		}
		for _, r := range s {
			if r < 0x20 || r == 0x7f {
				return false
			}
		}
		return true
	}
	return memoID.MatchString(m.ID) && plain(m.Title, MemoTitleMax) && plain(m.Text, MemoTextMax)
}

// validMemos keeps the memos that can be shown, in order, the first of each
// id, up to MemosMax. A bad memo never costs the catalogue: that would stop
// updates for everyone over a typo in a note.
func validMemos(list []Memo) []Memo {
	var out []Memo
	seen := map[string]bool{}
	for _, m := range list {
		if !m.Valid() || seen[m.ID] {
			continue
		}
		seen[m.ID] = true
		out = append(out, m)
		if len(out) == MemosMax {
			break
		}
	}
	return out
}

// Offered is the release this build installs for a channel: the current
// slot's, else the legacy slot's (a catalogue written by older tooling, or a
// channel not published since).
func (c Catalogue) Offered(channel string) (Release, bool) {
	if r, ok := c.Current[channel]; ok {
		return r, true
	}
	r, ok := c.Releases[channel]
	return r, ok
}

var ident = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]{0,95}$`)
var hash = regexp.MustCompile(`^[a-f0-9]{64}$`)
var semver = regexp.MustCompile(`^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$`)
var sourceFilename = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\.zip$`)

func validURL(s string) bool {
	u, err := url.Parse(s)
	return err == nil && u.Scheme == "https" && u.Hostname() != "" && u.User == nil && u.Fragment == "" && len(s) <= 2048 && !strings.ContainsAny(s, " \r\n\t")
}

// Requirement is the access a prospective update asks for, in the beta
// gate's terms: checked against the saved receipts without changing the
// running build's own requirement.
func (r Release) Requirement() beta.Requirement {
	req := beta.Requirement{Channel: r.Channel}
	if r.Access != nil {
		req.Batch = r.Access.Batch
		req.CodeSHA256 = r.Access.SHA256
	}
	return req
}
func (r Release) Validate() error {
	if !ident.MatchString(r.ID) || !semver.MatchString(r.Version) || !hash.MatchString(r.SHA256) || !validURL(r.URL) || !validURL(r.DBURL) || r.Size <= 0 || r.Size > 256<<20 || len(r.Notes) > 16000 {
		return fmt.Errorf("invalid release metadata")
	}
	if r.Channel != "public" && r.Channel != "beta" {
		return fmt.Errorf("invalid channel")
	}
	if r.Channel == "public" && (r.Access != nil || strings.Contains(r.Version, "-")) {
		return fmt.Errorf("invalid public release")
	}
	if r.Source == nil || !sourceFilename.MatchString(r.Source.Filename) || r.Source.Size <= 0 || r.Source.Size > 1<<30 || !hash.MatchString(r.Source.SHA256) || !validURL(r.Source.URL) {
		return fmt.Errorf("invalid corresponding-source metadata")
	}
	return r.Requirement().Validate()
}
func Parse(data []byte) (Catalogue, error) {
	var c Catalogue
	if len(data) > 128<<10 {
		return c, fmt.Errorf("catalogue too large")
	}
	if err := json.Unmarshal(data, &c); err != nil {
		return c, err
	}
	if c.Schema != 1 || c.Releases == nil || len(c.Releases) > 2 || len(c.Current) > 2 {
		return c, fmt.Errorf("unsupported catalogue")
	}
	// An id may sit in both slots (the newest release before anything is
	// pinned), but never twice within one.
	for _, slot := range []map[string]Release{c.Releases, c.Current} {
		ids := map[string]bool{}
		for ch, r := range slot {
			if ch != r.Channel || ids[r.ID] {
				return c, fmt.Errorf("conflicting release")
			}
			if err := r.Validate(); err != nil {
				return c, err
			}
			ids[r.ID] = true
		}
	}
	c.Memos = validMemos(c.Memos)
	return c, nil
}
func Fetch(ctx context.Context, client *http.Client, address string) (Catalogue, error) {
	if !validURL(address) {
		return Catalogue{}, fmt.Errorf("invalid catalogue URL")
	}
	if client == nil {
		client = &http.Client{Timeout: 20 * time.Second}
	}
	req, err := http.NewRequestWithContext(ctx, "GET", address, nil)
	if err != nil {
		return Catalogue{}, err
	}
	req.Header.Set("User-Agent", "MisterZine-Plex")
	resp, err := client.Do(req)
	if err != nil {
		return Catalogue{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK || !validURL(resp.Request.URL.String()) {
		return Catalogue{}, fmt.Errorf("catalogue unavailable")
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, 128<<10+1))
	if err != nil {
		return Catalogue{}, err
	}
	return Parse(data)
}

func Cached(root string) (Catalogue, error) {
	data, err := os.ReadFile(filepath.Join(root, "updates/catalogue.json"))
	if err != nil {
		return Catalogue{}, err
	}
	return Parse(data)
}
func SaveCache(root string, c Catalogue) error {
	data, err := json.Marshal(c)
	if err != nil {
		return err
	}
	if _, err = Parse(data); err != nil {
		return err
	}
	dir := filepath.Join(root, "updates")
	if err = os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	f, err := os.CreateTemp(dir, ".catalogue-")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err = f.Write(data); err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(f.Name(), filepath.Join(dir, "catalogue.json"))
}

// Compare implements release precedence, including numeric beta components.
// The boolean is false for local build labels that are not release versions.
func Compare(a, b string) (int, bool) {
	aa, bb := semver.FindStringSubmatch(a), semver.FindStringSubmatch(b)
	if aa == nil || bb == nil {
		return 0, false
	}
	for i := 1; i <= 3; i++ {
		x, e := strconv.ParseUint(aa[i], 10, 64)
		y, f := strconv.ParseUint(bb[i], 10, 64)
		if e != nil || f != nil {
			return 0, false
		}
		if x < y {
			return -1, true
		}
		if x > y {
			return 1, true
		}
	}
	if aa[4] == bb[4] {
		return 0, true
	}
	if aa[4] == "" {
		return 1, true
	}
	if bb[4] == "" {
		return -1, true
	}
	x, y := strings.Split(aa[4], "."), strings.Split(bb[4], ".")
	for i := 0; i < min(len(x), len(y)); i++ {
		if x[i] == y[i] {
			continue
		}
		nx, ex := strconv.ParseUint(x[i], 10, 64)
		ny, ey := strconv.ParseUint(y[i], 10, 64)
		if ex == nil && ey == nil {
			if nx < ny {
				return -1, true
			}
			return 1, true
		}
		if ex == nil {
			return -1, true
		}
		if ey == nil {
			return 1, true
		}
		if x[i] < y[i] {
			return -1, true
		}
		return 1, true
	}
	if len(x) < len(y) {
		return -1, true
	}
	return 1, true
}
func Notify(r Release, current, channel string, early bool) bool {
	newer, ok := Compare(r.Version, current)
	if !ok || newer < 0 {
		return false
	}
	if newer == 0 {
		return channel == "beta" && r.Channel == "public"
	}
	if channel == "beta" {
		return true
	}
	return r.Channel == "public" || early
}
