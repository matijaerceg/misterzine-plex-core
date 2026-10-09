package access

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func register(t *testing.T, m Month, code, legacy string) Grant {
	t.Helper()
	sum := sha256.Sum256([]byte(code))
	g := Grant{m, hex.EncodeToString(sum[:]), legacy}
	Register(g)
	return g
}

func isolate(t *testing.T) {
	old := grants
	grants = nil
	t.Cleanup(func() { grants = old })
}

func TestPermanentAccess(t *testing.T) {
	isolate(t)
	g := register(t, 202609, "123456", "initial-beta")
	register(t, 202612, "654321", "")
	dir := t.TempDir()
	if Load(dir) != 0 {
		t.Fatal("fresh install unlocked")
	}
	if _, err := Unlock(dir, "999999"); !errors.Is(err, ErrCode) {
		t.Fatal(err)
	}
	if _, err := Unlock(dir, "12345"); !errors.Is(err, ErrCode) {
		t.Fatal("short code accepted")
	}
	if m, err := Unlock(dir, "123456"); m != 202609 || err != nil {
		t.Fatal(m, err)
	}
	if Load(dir) != 202609 {
		t.Fatal("code lost on reload")
	}
	if m, err := Unlock(dir, "654321"); m != 202612 || err != nil {
		t.Fatal(m, err)
	}
	if m, err := Unlock(dir, "123456"); m != 202612 || err != nil {
		t.Fatal("older code reduced access", m, err)
	}
	// the beta's own receipt counts as the September grant
	legacy := t.TempDir()
	path := filepath.Join(legacy, "beta-unlocks", g.LegacyBatch+"-"+g.SHA256+".receipt")
	os.MkdirAll(filepath.Dir(path), 0755)
	os.WriteFile(path, []byte("unlocked\n"), 0644)
	if Load(legacy) != 202609 {
		t.Fatal("beta receipt not honoured")
	}
	os.WriteFile(path, []byte("broken"), 0644)
	if Load(legacy) != 0 {
		t.Fatal("damaged receipt granted access")
	}
	if m, err := Unlock("", "123456"); m != 202609 || err == nil {
		t.Fatal("valid unsaved code", m, err)
	}
}

func TestFeatureLifecycle(t *testing.T) {
	for _, premium := range []bool{false, true} {
		f := Feature{Premium: premium, Beta: true, Since: 202609}
		if f.Visible(false) || f.Allowed(202612, false) || (f.Allowed(202608, true) == premium) {
			t.Fatal("beta gate bypassed", f)
		}
		if !f.Visible(true) || !f.Allowed(202609, true) {
			t.Fatal("qualifying beta hidden", f)
		}
		if f.Allowed(0, true) == premium {
			t.Fatal("code requirement wrong", f)
		}
		f.Beta = false
		if !f.Visible(false) || !f.Allowed(202609, false) {
			t.Fatal("graduation lost access", f)
		}
		if f.Allowed(0, false) == premium {
			t.Fatal("graduation changed the code requirement", f)
		}
	}
	if (Feature{Premium: true}).Allowed(202610, true) {
		t.Fatal("missing threshold fails open")
	}
	for _, e := range Catalog() {
		if !e.Premium || !e.Since.Valid() {
			t.Fatal("catalogue entry without a threshold", e)
		}
	}
}

func TestForgetKeepsSettingsAndCode(t *testing.T) {
	isolate(t)
	g := register(t, 202609, "123456", "initial-beta")
	dir := t.TempDir()
	if _, err := Unlock(dir, "123456"); err != nil {
		t.Fatal(err)
	}
	legacy := filepath.Join(dir, "beta-unlocks")
	os.MkdirAll(legacy, 0755)
	os.WriteFile(filepath.Join(legacy, g.LegacyBatch+"-"+g.SHA256+".receipt"), []byte("unlocked\n"), 0644)
	os.WriteFile(filepath.Join(dir, "plexcrt.json"), []byte("keep settings"), 0644)
	if m, err := Forget(dir); err != nil || m != 0 || Load(dir) != 0 {
		t.Fatal(m, err)
	}
	for _, name := range []string{"unlocks", "beta-unlocks"} {
		if _, err := os.Stat(filepath.Join(dir, name)); !os.IsNotExist(err) {
			t.Fatal("receipt directory retained", err)
		}
	}
	b, _ := os.ReadFile(filepath.Join(dir, "plexcrt.json"))
	if string(b) != "keep settings" {
		t.Fatal("settings changed")
	}
	if m, err := Unlock(dir, "123456"); err != nil || m != 202609 {
		t.Fatal("code revoked", m, err)
	}
	if _, err := Forget(""); err == nil {
		t.Fatal("empty root accepted")
	}
}

func TestRegisterRefusesBadGrants(t *testing.T) {
	isolate(t)
	bad := []Grant{
		{Month: 202613, SHA256: hex.EncodeToString(make([]byte, 32))},
		{Month: 202609, SHA256: "abc"},
		{Month: 202609, SHA256: hex.EncodeToString(make([]byte, 32)), LegacyBatch: "a/b"},
	}
	for _, g := range bad {
		func() {
			defer func() {
				if recover() == nil {
					t.Fatal("accepted", g)
				}
			}()
			Register(g)
		}()
	}
	register(t, 202609, "111111", "")
	func() {
		defer func() {
			if recover() == nil {
				t.Fatal("duplicate month accepted")
			}
		}()
		register(t, 202609, "222222", "")
	}()
}

// Covering is what the codes held cover, for the Patreon page and the
// code entry: the latest month and before, or what no code means.
func TestMonthCovering(t *testing.T) {
	if got := Month(202609).Covering(); got != "Through Sep 2026" {
		t.Fatalf("Sep 2026 covers %q", got)
	}
	if got := Month(0).Covering(); got != Month(0).Short() || got != "No code entered" {
		t.Fatalf("no code covers %q", got)
	}
}
