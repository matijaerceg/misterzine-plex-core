// Package access is permanent, month-based access to the supporter extras:
// the same code registry as every MisterZine app with gated features.
// A month names what a code covers, never when it runs out; the app uses
// no clock or network check. This is a convenience gate, not protection
// against a modified build.
package access

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// Month is a code's coverage, as YYYYMM.
type Month int

func (m Month) Valid() bool { return m >= 202601 && m <= 999912 && m%100 >= 1 && m%100 <= 12 }
func (m Month) String() string {
	if !m.Valid() {
		return "None"
	}
	return fmt.Sprintf("%s %d", time.Month(m%100), m/100)
}

// Short is the month on an Options row: "Sep 2026", or what no code means.
func (m Month) Short() string {
	if !m.Valid() {
		return "No code entered"
	}
	return fmt.Sprintf("%.3s %d", time.Month(m%100).String(), m/100)
}

// Feature separates readiness from access. Premium needs a code covering
// Since; Beta needs "Show beta features" on. Graduation clears Beta only.
type Feature struct {
	Premium, Beta bool
	Since         Month
}

func (f Feature) Covered(month Month) bool {
	return !f.Premium || (f.Since.Valid() && month.Valid() && month >= f.Since)
}
func (f Feature) Visible(showBeta bool) bool { return !f.Beta || showBeta }
func (f Feature) Allowed(month Month, showBeta bool) bool {
	return f.Visible(showBeta) && f.Covered(month)
}

// The features, with their thresholds. A threshold never rises: fixes and
// improvements stay included. The first Plex code (the initial beta,
// September 2026) covers the first supporter extras.
var (
	Screensaver = Feature{Premium: true, Since: 202609}
	RandomSort  = Feature{Premium: true, Since: 202609}
	NoHomeLogo  = Feature{Premium: true, Since: 202609}
)

// Entry names a feature for the access overview and the coverage register.
type Entry struct {
	ID, Name string
	Feature
}

// Catalog lists every gated feature, in the order the overview shows them.
func Catalog() []Entry {
	return []Entry{
		{"screensaver", "Screensaver", Screensaver},
		{"random-sort", "Random library order", RandomSort},
		{"no-home-logo", "Hide the Home logo", NoHomeLogo},
	}
}

var ErrCode = errors.New("access: unrecognised MisterZine code")

// Grant is an issued code's public verifier, shared by all official apps.
// Never remove an issued grant. LegacyBatch names the beta batch whose
// receipt (beta-unlocks/<batch>-<sha>.receipt) counts as this grant.
type Grant struct {
	Month       Month
	SHA256      string
	LegacyBatch string
}

var grants []Grant

// Register is called by the private registry at startup. An invalid or
// ambiguous registry stops the build at startup instead of misgranting.
func Register(g Grant) {
	b, err := hex.DecodeString(g.SHA256)
	if !g.Month.Valid() || err != nil || len(b) != sha256.Size || hex.EncodeToString(b) != g.SHA256 {
		panic("invalid access grant")
	}
	if g.LegacyBatch != "" && filepath.Base(g.LegacyBatch) != g.LegacyBatch {
		panic("invalid legacy batch")
	}
	for _, old := range grants {
		if old.SHA256 == g.SHA256 || old.Month == g.Month {
			panic("duplicate access grant")
		}
	}
	grants = append(grants, g)
}

// Grants is the registry, for the coverage export.
func Grants() []Grant { return append([]Grant(nil), grants...) }

func receipt(dir string, g Grant) string { return filepath.Join(dir, "unlocks", g.SHA256+".receipt") }
func has(path string) bool {
	b, err := os.ReadFile(path)
	return err == nil && string(b) == "unlocked\n"
}

// Load reads the saved receipts, the beta ones included, and returns the
// highest coverage. Unknown or damaged files grant nothing.
func Load(dir string) Month {
	if dir == "" {
		return 0
	}
	var best Month
	for _, g := range grants {
		ok := has(receipt(dir, g))
		if g.LegacyBatch != "" {
			ok = ok || has(filepath.Join(dir, "beta-unlocks", g.LegacyBatch+"-"+g.SHA256+".receipt"))
		}
		if ok && g.Month > best {
			best = g.Month
		}
	}
	return best
}

// Unlock checks a six-digit code and saves its receipt. It returns the
// highest coverage even when saving fails; an unrecognised code returns
// zero and ErrCode. Older receipts stay.
func Unlock(dir, code string) (Month, error) {
	if len(code) != 6 {
		return 0, ErrCode
	}
	for _, c := range code {
		if c < '0' || c > '9' {
			return 0, ErrCode
		}
	}
	sum := sha256.Sum256([]byte(code))
	for _, g := range grants {
		if hex.EncodeToString(sum[:]) != g.SHA256 {
			continue
		}
		month := max(g.Month, Load(dir))
		if dir == "" {
			return month, errors.New("access: no settings directory")
		}
		path := receipt(dir, g)
		if has(path) {
			return month, nil
		}
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			return month, err
		}
		f, err := os.CreateTemp(filepath.Dir(path), ".unlock-*")
		if err != nil {
			return month, err
		}
		defer os.Remove(f.Name())
		if _, err = f.WriteString("unlocked\n"); err == nil {
			err = f.Sync()
		}
		closeErr := f.Close()
		if err == nil {
			err = closeErr
		}
		if err == nil {
			err = os.Rename(f.Name(), path)
		}
		return month, err
	}
	return 0, ErrCode
}

// Forget removes every saved receipt, the beta ones included, and no
// settings. It returns the coverage still on disk if a folder would not go.
func Forget(dir string) (Month, error) {
	if dir == "" {
		return 0, errors.New("access: no settings directory")
	}
	info, err := os.Stat(dir)
	if err != nil {
		return Load(dir), err
	}
	if !info.IsDir() {
		return 0, errors.New("access: settings path is not a directory")
	}
	err = errors.Join(os.RemoveAll(filepath.Join(dir, "unlocks")), os.RemoveAll(filepath.Join(dir, "beta-unlocks")))
	return Load(dir), err
}
