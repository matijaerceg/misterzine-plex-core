package ui

import (
	"encoding/json"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"plexcrt/internal/plex"
	"syscall"
	"testing"
)

func TestConfigRecoveryAndSignOut(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	c := LoadConfig(path)
	if c.LoadError != nil {
		t.Fatal(c.LoadError)
	}
	id := c.ClientID
	c.Token = "test-account"
	c.AccountName = "Alice"
	c.ServerToken = "test-server"
	c.ServerURL = "http://test"
	c.Bitrate = 1000
	if err := c.Save(); err != nil {
		t.Fatal(err)
	}
	c.Bitrate = 2000
	if err := c.Save(); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(path, []byte("{broken"), 0600)
	c = LoadConfig(path)
	if c.LoadError != nil || c.LoadWarning == "" || c.Bitrate != 1000 || c.ClientID != id {
		t.Fatal("valid backup not recovered")
	}
	if err := c.SignOut(); err != nil {
		t.Fatal(err)
	}
	for _, p := range []string{path, path + ".bak"} {
		var saved Config
		b, _ := os.ReadFile(p)
		if json.Unmarshal(b, &saved) != nil || saved.Token != "" || saved.ServerToken != "" || saved.AccountName != "" {
			t.Fatal("sign-out left recovery credentials")
		}
	}
}

func TestSubtitleSizeDefaultChoicesAndPersistence(t *testing.T) {
	c := LoadConfig(filepath.Join(t.TempDir(), "settings.json"))
	if c.SubtitleSizeValue() != 100 || c.subtitleSizeIndex() != 0 {
		t.Fatalf("missing setting should mean Normal: %d / %d", c.SubtitleSizeValue(), c.subtitleSizeIndex())
	}
	for i, want := range []int{100, 150, 200} {
		c.SubtitleSize = want
		if got := c.subtitleSizeIndex(); got != i {
			t.Fatalf("size %d has index %d, want %d", want, got, i)
		}
	}
	if err := c.Save(); err != nil {
		t.Fatal(err)
	}
	loaded := LoadConfig(c.path)
	if loaded.SubtitleSizeValue() != 200 {
		t.Fatalf("saved size loaded as %d", loaded.SubtitleSizeValue())
	}
	loaded.SubtitleSize = 999
	if loaded.SubtitleSizeValue() != 100 || loaded.subtitleSizeIndex() != 0 {
		t.Fatal("unknown setting did not safely fall back to Normal")
	}
}
func TestConfigFailedSavePreservesPrimary(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	c := LoadConfig(path)
	original, _ := os.ReadFile(path)
	os.Mkdir(path+".bak", 0700)
	c.Bitrate = 9000
	if c.Save() == nil {
		t.Fatal("expected backup write failure")
	}
	after, _ := os.ReadFile(path)
	if string(after) != string(original) {
		t.Fatal("failed save changed primary")
	}
}
func TestConfigMalformedWithoutBackup(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	os.WriteFile(path, []byte(`{"token":"partial",`), 0600)
	c := LoadConfig(path)
	if c.LoadError != nil || c.Token != "" || c.LoadWarning == "" {
		t.Fatal("partial account survived damaged JSON")
	}
	matches, _ := filepath.Glob(path + ".corrupt-*")
	if len(matches) != 1 {
		t.Fatal("damaged file not preserved")
	}
}
func TestOwnedPlayerRequiresExactMarker(t *testing.T) {
	for _, env := range []string{"PATH=/usr/bin\x00", "OTHER=ffmpeg\x00", "MISTERZINE_PLEX_OWNER=/other/plexplay.py\x00"} {
		if ownedPlayer([]byte(env), "/app/plexplay.py") {
			t.Fatal("unrelated process matched")
		}
	}
	if !ownedPlayer([]byte("MISTERZINE_PLEX_OWNER=/app/plexplay.py\x00"), "/app/plexplay.py") {
		t.Fatal("owned child not recognized")
	}
}

func TestReapLeavesUnrelatedProcessRunning(t *testing.T) {
	owner := "/test/misterzine/plexplay.py"
	owned := exec.Command("sleep", "30")
	owned.Env = append(os.Environ(), "MISTERZINE_PLEX_OWNER="+owner)
	unrelated := exec.Command("sleep", "30")
	for _, cmd := range []*exec.Cmd{owned, unrelated} {
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		defer cmd.Process.Kill()
	}
	(&Player{Script: owner}).Reap()
	if err := owned.Wait(); err == nil {
		t.Fatal("owned child was not terminated")
	}
	if err := unrelated.Process.Signal(syscall.Signal(0)); err != nil {
		t.Fatal("cleanup terminated an unrelated child")
	}
	unrelated.Process.Kill()
	unrelated.Wait()
}

func TestCancelledConnectionCannotSaveAccount(t *testing.T) {
	c := LoadConfig(filepath.Join(t.TempDir(), "settings.json"))
	l := &Login{app: &App{Cfg: c}, gen: 2, tok: "test-account"}
	l.finishConnect(1, plex.Server{AccessToken: "test-server"}, "http://test")
	if c.Token != "" || c.SignedIn() {
		t.Fatal("cancelled connection changed account")
	}
}

func TestConnectionSaveFailureDoesNotSignIn(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	c := LoadConfig(path)
	os.Mkdir(path+".bak", 0700)
	a := &App{Cfg: c, Connected: make(chan struct{}, 1), Log: log.New(io.Discard, "", 0)}
	l := &Login{app: a, gen: 1, tok: "test-account"}
	l.finishConnect(1, plex.Server{AccessToken: "test-server"}, "http://test")
	if c.SignedIn() || c.Token != "" || l.err == "" || len(a.Connected) != 0 {
		t.Fatal("failed save reported successful sign-in")
	}
}

func TestBitrateClampsOlderSavedHighValues(t *testing.T) {
	for _, tc := range []struct{ saved, want int }{{0, 3000}, {500, 1000}, {1000, 1000}, {1500, 1500}, {2000, 2000}, {2500, 2000}, {3000, 3000}, {4500, 3000}, {6000, 3000}, {20000, 3000}} {
		c := Config{Bitrate: tc.saved}
		if c.BitrateKbps() != tc.want {
			t.Fatalf("saved %d: got %d, want %d", tc.saved, c.BitrateKbps(), tc.want)
		}
	}
}

func TestBitrateOptionShowsAndStepsOfferedCaps(t *testing.T) {
	for _, tc := range []struct {
		saved int
		label string
	}{{0, "Max (2 Mbps)"}, {6000, "Max (2 Mbps)"}, {2500, "1.2 Mbps"}, {1500, "1 Mbps"}, {1000, "0.4 Mbps, low res"}} {
		c := Config{Bitrate: tc.saved}
		if got := Bitrates[c.bitrateIndex()].Label; got != tc.label {
			t.Fatalf("saved %d: shows %q, want %q", tc.saved, got, tc.label)
		}
	}
	a := &App{Cfg: &Config{}}
	o := &Options{app: a}
	var row option
	for _, it := range o.items() {
		if it.label == "Video bitrate" {
			row = it
		}
	}
	row.step(+1)
	if a.Cfg.Bitrate != 3000 || row.val() != "Max (2 Mbps)" {
		t.Fatalf("stepping up from the default: %d %q", a.Cfg.Bitrate, row.val())
	}
	for i := 0; i < 5; i++ {
		row.step(-1)
	}
	if a.Cfg.Bitrate != 1000 || row.val() != "0.4 Mbps, low res" {
		t.Fatalf("stepping down to the end: %d %q", a.Cfg.Bitrate, row.val())
	}
}
