package ui

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"
	"time"

	"plexcrt/internal/access"
	"plexcrt/internal/input"
)

// registerTestGrant registers one code for the tests. The registry keeps
// it for the process (only the private registry fills it for real), so each
// test here uses its own month and code.
func registerTestGrant(t *testing.T, month access.Month, code, legacy string) {
	t.Helper()
	sum := sha256.Sum256([]byte(code))
	access.Register(access.Grant{Month: month, SHA256: hex.EncodeToString(sum[:]), LegacyBatch: legacy})
}

func TestGatedRowLockedUntilCovered(t *testing.T) {
	registerTestGrant(t, 202609, "246810", "")
	a := betaTestApp(t)
	a.loadAccess()
	f := access.Feature{Premium: true, Since: 202609}
	row, ok := a.gated(option{label: "Screensaver", val: func() string { return "DVD" }}, f)
	if !ok || !row.locked || row.val() != "Needs a code" || row.label != "Screensaver" {
		t.Fatalf("uncovered row: %+v %v", row, ok)
	}
	row.do()
	if _, isEntry := a.top().(*BetaAccess); !isEntry {
		t.Fatalf("OK on a locked row opened %T", a.top())
	}
	for _, ch := range "246810" {
		a.key(input.Event{Keyboard: true, Text: ch, Key: input.None}, time.Now())
	}
	a.key(input.Event{Key: input.Enter}, time.Now())
	if a.Access() != 202609 {
		t.Fatalf("access after the code: %v", a.Access())
	}
	row, ok = a.gated(option{label: "Screensaver", val: func() string { return "DVD" }}, f)
	if !ok || row.locked || row.val() != "DVD" {
		t.Fatalf("covered row: %+v %v", row, ok)
	}
	// a beta extra hides until the toggle is on, code or not
	beta := access.Feature{Premium: true, Beta: true, Since: 202609}
	if _, ok := a.gated(option{label: "Beta thing"}, beta); ok {
		t.Fatal("beta row shown with the toggle off")
	}
	a.Cfg.ShowBeta = true
	if row, ok := a.gated(option{label: "Beta thing"}, beta); !ok || row.locked {
		t.Fatalf("beta row with the toggle on: %+v %v", row, ok)
	}
}

func TestBetaReceiptCountsAsAccess(t *testing.T) {
	a := betaTestApp(t)
	registerTestGrant(t, 202610, "012345", "fixture")
	// the beta's own unlock writes beta-unlocks/fixture-<sha>.receipt
	a.Push(NewBetaAccess(a, nil))
	enterFixture(a, time.Now())
	if a.Access() != 202610 {
		t.Fatalf("access after the beta unlock: %v", a.Access())
	}
	a.Push(&ForgetBetaAccess{app: a})
	a.key(input.Event{Key: input.Down}, time.Now())
	a.key(input.Event{Key: input.Enter}, time.Now())
	if a.Access() != 0 {
		t.Fatalf("access after forgetting: %v", a.Access())
	}
	if _, err := os.Stat(filepath.Join(a.accessDir(), "unlocks")); !os.IsNotExist(err) {
		t.Fatal("unlocks folder kept")
	}
}

func TestShowBetaFeaturesToggle(t *testing.T) {
	a := betaTestApp(t)
	o := NewOptions(a)
	a.Push(o)
	items := o.items()
	i := -1
	for j, it := range items {
		if it.label == "Show beta features" {
			i = j
		}
	}
	if i < 0 {
		t.Fatal("no Show beta features row")
	}
	for o.cur < i {
		o.Key(input.Event{Key: input.Down}, time.Now())
	}
	o.Key(input.Event{Key: input.Enter}, time.Now())
	if !a.Cfg.ShowBeta || !a.showBeta() {
		t.Fatal("toggle did not turn beta on")
	}
	saved := LoadConfig(a.Cfg.path)
	if !saved.ShowBeta {
		t.Fatal("toggle not saved")
	}
}

func TestPremiumSettingsRoundTrip(t *testing.T) {
	a := betaTestApp(t)
	a.setPremiumSetting("screensaver", "dvd")
	if err := a.Cfg.Save(); err != nil {
		t.Fatal(err)
	}
	saved := LoadConfig(a.Cfg.path)
	if saved.Premium["screensaver"] != "dvd" {
		t.Fatalf("premium settings saved as %v", saved.Premium)
	}
	a.setPremiumSetting("screensaver", "")
	if a.premiumSetting("screensaver") != "" || len(a.PremiumSettings()) != 0 {
		t.Fatal("setting not removed")
	}
}
