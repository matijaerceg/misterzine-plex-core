package ring

import (
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The increments are f_sc / 81 MHz * 2^40, truncated, computed exactly.
func TestYCIncrementsFollowTheFormula(t *testing.T) {
	for _, c := range []struct {
		mhz string
		inc int64
	}{{"3.579545", ycNTSC}, {"4.43361875", ycPAL}, {"3.575611", ycPALM}} {
		r, _ := new(big.Rat).SetString(c.mhz)
		r.Mul(r, new(big.Rat).SetInt(new(big.Int).Lsh(big.NewInt(1), 40)))
		r.Quo(r, big.NewRat(81, 1))
		want := new(big.Int).Quo(r.Num(), r.Denom()).Int64()
		if c.inc != want {
			t.Errorf("%s MHz: %d, want %d", c.mhz, c.inc, want)
		}
	}
}

func TestYCLinesStayWithinMainsTable(t *testing.T) {
	lines := YCLines(AppCoreName)
	if len(lines) >= 20 {
		t.Fatalf("%d lines: main keeps 20 per core", len(lines))
	}
	if lines[0] != "MisterZine Plex Core_59.9=48589522835" || lines[1] != "MisterZine Plex Core_59.9i=48589522835" {
		t.Fatalf("lines %q", lines[:2])
	}
	seen := map[string]bool{}
	for _, l := range lines {
		key, _, _ := strings.Cut(l, "=")
		if len(key) >= 64 || seen[key] {
			t.Fatalf("key %q too long for main or repeated", key)
		}
		seen[key] = true
	}
}

func TestEnsureYCCreatesTheFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "yc.txt")
	n, err := EnsureYC(path, AppCoreName)
	if err != nil || n != len(ycModes) {
		t.Fatalf("added %d, %v", n, err)
	}
	b, _ := os.ReadFile(path)
	want := "; MisterZine Plex Core: composite/S-Video colour for its fixed 81 MHz video clock\n" + strings.Join(YCLines(AppCoreName), "\n") + "\n"
	if string(b) != want {
		t.Fatalf("file %q", b)
	}
	// a second run changes nothing
	if n, err := EnsureYC(path, AppCoreName); n != 0 || err != nil {
		t.Fatalf("second run added %d, %v", n, err)
	}
	if b2, _ := os.ReadFile(path); string(b2) != want {
		t.Fatalf("second run rewrote the file: %q", b2)
	}
}

func TestEnsureYCKeepsTheRestAndAddsOnlyMissingKeys(t *testing.T) {
	path := filepath.Join(t.TempDir(), "yc.txt")
	// an upstream-style file, no final newline, one of our keys already set
	// (another case, another value, a comment after it): the user's line wins
	orig := ";\n; NTSC / PAL Section\nNES_60.1=91625968981 ;note\n  misterzine plex core_50.0i=123 ;mine\nSNES_50.0=114532461227"
	os.WriteFile(path, []byte(orig), 0o644)
	n, err := EnsureYC(path, AppCoreName)
	if err != nil || n != len(ycModes)-1 {
		t.Fatalf("added %d, %v", n, err)
	}
	b, _ := os.ReadFile(path)
	if !strings.HasPrefix(string(b), orig+"\n; ") {
		t.Fatalf("existing content changed: %q", b)
	}
	if strings.Contains(string(b), "Core_50.0i=") {
		t.Fatal("a key the file already had was added again")
	}
	if !strings.HasSuffix(string(b), "MisterZine Plex Core_60.0im=48536121863\n") {
		t.Fatalf("tail %q", b[len(b)-60:])
	}
}

// A key main would not match (space before '=', or commented out) is not ours.
func TestEnsureYCReadsKeysAsMainDoes(t *testing.T) {
	keys := ycKeys([]byte("A_59.9 =1\n;B_59.9=1\nC_50.0=1 ;x\r\n\tD_60.0i=2\r\nnoequals\n"))
	for k, want := range map[string]bool{"a_59.9 ": true, "a_59.9": false, "b_59.9": false, "c_50.0": true, "d_60.0i": true, "noequals": false} {
		if keys[k] != want {
			t.Errorf("key %q: %v, want %v (%v)", k, keys[k], want, keys)
		}
	}
}

func TestEnsureYCKeepsCRLF(t *testing.T) {
	path := filepath.Join(t.TempDir(), "yc.txt")
	orig := "NES_60.1=91625968981\r\nMisterZine Plex Core_59.9=1\r\n"
	os.WriteFile(path, []byte(orig), 0o644)
	n, err := EnsureYC(path, AppCoreName)
	if err != nil || n != len(ycModes)-1 {
		t.Fatalf("added %d, %v", n, err)
	}
	b, _ := os.ReadFile(path)
	s := string(b)
	if !strings.HasPrefix(s, orig) || strings.Count(s, "\n") != strings.Count(s, "\r\n") {
		t.Fatalf("line ends mixed: %q", s)
	}
}

func TestEnsureYCWithoutACard(t *testing.T) {
	path := filepath.Join(t.TempDir(), "missing", "yc.txt")
	if n, err := EnsureYC(path, AppCoreName); err == nil || n != 0 {
		t.Fatalf("no card: %d, %v", n, err)
	}
	if _, err := os.Stat(filepath.Dir(path)); err == nil {
		t.Fatal("the card's directory was created")
	}
	// PinYC logs and returns
	defer func(p string) { ycFile = p }(ycFile)
	ycFile = path
	var logged []string
	PinYC(func(f string, a ...any) { logged = append(logged, f) })
	if len(logged) != 1 || !strings.Contains(logged[0], "not updated") {
		t.Fatalf("logged %q", logged)
	}
}

func TestEnsureYCReadOnlyFile(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root writes read-only files")
	}
	path := filepath.Join(t.TempDir(), "yc.txt")
	os.WriteFile(path, []byte("NES_60.1=1\n"), 0o444)
	if n, err := EnsureYC(path, AppCoreName); err == nil || n != 0 {
		t.Fatalf("read-only: %d, %v", n, err)
	}
	if b, _ := os.ReadFile(path); string(b) != "NES_60.1=1\n" {
		t.Fatalf("file changed: %q", b)
	}
}

// An unreadable yc.txt (here a directory in its place) is left alone.
func TestEnsureYCUnreadable(t *testing.T) {
	path := filepath.Join(t.TempDir(), "yc.txt")
	os.Mkdir(path, 0o755)
	if n, err := EnsureYC(path, AppCoreName); err == nil || n != 0 {
		t.Fatalf("unreadable: %d, %v", n, err)
	}
}
