package ui

import (
	"encoding/json"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"syscall"
	"testing"
	"time"

	"plexcrt/internal/input"
	"plexcrt/internal/plex"
)

func TestConfigRecoveryAndSignOut(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	c := LoadConfig(path)
	if c.LoadError != nil {
		t.Fatal(c.LoadError)
	}
	id := c.ClientID
	c.Token, c.AccountName = "test-account", "Alice"
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

// savedBitrate is the bitrate in the settings file at path, 0 for none.
func savedBitrate(path string) int {
	var s Config
	b, err := os.ReadFile(path)
	if err != nil || json.Unmarshal(b, &s) != nil {
		return 0
	}
	return s.Bitrate
}

// shortSaveDelay makes SaveLater wait d for the length of the test.
func shortSaveDelay(t *testing.T, d time.Duration) {
	was := saveDelay
	t.Cleanup(func() { saveDelay = was })
	saveDelay = d
}

// SaveLater writes once the changes stop, and only the last settings;
// Flush writes what is held at once and leaves the timer nothing.
func TestSaveLaterWaitsForTheChangesToStop(t *testing.T) {
	shortSaveDelay(t, 300*time.Millisecond)
	path := filepath.Join(t.TempDir(), "settings.json")
	c := &Config{path: path}
	failed := func(err error) { t.Error("deferred save:", err) }
	for _, kbps := range []int{1000, 2000, 3000, 4000} {
		c.Bitrate = kbps
		c.SaveLater(failed)
		time.Sleep(30 * time.Millisecond)
	}
	if got := savedBitrate(path); got != 0 {
		t.Fatalf("written while the steps came: %d", got)
	}
	deadline := time.Now().Add(2 * time.Second)
	for savedBitrate(path) == 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if got := savedBitrate(path); got != 4000 {
		t.Fatalf("after the steps stopped: %d, want the last, 4000", got)
	}
	c.Bitrate = 6000
	c.SaveLater(failed)
	if err := c.Flush(); err != nil || savedBitrate(path) != 6000 {
		t.Fatalf("flush: %v, saved %d", err, savedBitrate(path))
	}
	os.Remove(path)
	time.Sleep(saveDelay + 100*time.Millisecond)
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("the timer wrote again after the flush")
	}
	if err := c.Flush(); err != nil {
		t.Fatal("flush with nothing held:", err)
	}
}

// Save writes the newest settings: what SaveLater held, older, never lands
// after it.
func TestSaveTakesWhatSaveLaterHolds(t *testing.T) {
	shortSaveDelay(t, 100*time.Millisecond)
	path := filepath.Join(t.TempDir(), "settings.json")
	c := &Config{path: path, Bitrate: 1000}
	c.SaveLater(func(err error) { t.Error("deferred save:", err) })
	c.Bitrate = 2000
	if err := c.Save(); err != nil {
		t.Fatal(err)
	}
	time.Sleep(saveDelay + 100*time.Millisecond)
	if got := savedBitrate(path); got != 2000 {
		t.Fatalf("saved %d, want 2000", got)
	}
}

// A deferred write that fails is reported, and its settings stay held for
// the next flush.
func TestSaveLaterFailureIsReportedAndKept(t *testing.T) {
	shortSaveDelay(t, 50*time.Millisecond)
	path := filepath.Join(t.TempDir(), "settings.json")
	c := &Config{path: path, Bitrate: 1000}
	if err := c.Save(); err != nil {
		t.Fatal(err)
	}
	os.Mkdir(path+".bak", 0700) // the backup cannot be replaced
	failures := make(chan error, 4)
	c.Bitrate = 2000
	c.SaveLater(func(err error) { failures <- err })
	select {
	case <-failures:
	case <-time.After(2 * time.Second):
		t.Fatal("the failed write was not reported")
	}
	if got := savedBitrate(path); got != 1000 {
		t.Fatalf("a failed save changed the file: %d", got)
	}
	os.Remove(path + ".bak")
	if err := c.Flush(); err != nil || savedBitrate(path) != 2000 {
		t.Fatalf("flush after the failure: %v, saved %d", err, savedBitrate(path))
	}
}

// Options saves its steps in the background; leaving it writes them at once.
func TestLeavingOptionsWritesItsChanges(t *testing.T) {
	a := betaTestApp(t)
	o := NewOptions(a)
	a.Push(o)
	pressOption(t, o, "Video bitrate", input.Left)
	want := a.Cfg.Bitrate
	if want == 0 || savedBitrate(a.Cfg.path) != 0 {
		t.Fatalf("the step: bitrate %d, written %d before leaving", want, savedBitrate(a.Cfg.path))
	}
	a.Pop()
	if got := savedBitrate(a.Cfg.path); got != want {
		t.Fatalf("after leaving Options: saved %d, want %d", got, want)
	}
}

func TestConfigMalformedWithoutBackup(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	os.WriteFile(path, []byte(`{"server_token":"partial",`), 0600)
	c := LoadConfig(path)
	if c.LoadError != nil || c.ServerToken != "" || c.LoadWarning == "" {
		t.Fatal("partial account survived damaged JSON")
	}
	matches, _ := filepath.Glob(path + ".corrupt-*")
	if len(matches) != 1 {
		t.Fatal("damaged file not preserved")
	}
}
func TestOwnedPlayerRequiresExactMarker(t *testing.T) {
	for _, env := range []string{"PATH=/usr/bin\x00", "OTHER=ffmpeg\x00", "MISTERZINE_PLEX_OWNER=/other/jfplay\x00", "MISTERZINE_JFPLAY_OWNER=/other/jfplay\x00"} {
		if ownedPlayer([]byte(env), "/app/jfplay") {
			t.Fatal("unrelated process matched")
		}
	}
	for _, env := range []string{"MISTERZINE_JFPLAY_OWNER=/app/jfplay\x00", "MISTERZINE_PLEX_OWNER=/app/jfplay\x00"} {
		if !ownedPlayer([]byte("PATH=/usr/bin\x00"+env), "/app/jfplay") {
			t.Fatalf("owned child not recognized by %q", env)
		}
	}
}

func TestReapLeavesUnrelatedProcessRunning(t *testing.T) {
	owner := "/test/misterzine/jfplay"
	owned := exec.Command("sleep", "30")
	owned.Env = append(os.Environ(), "MISTERZINE_JFPLAY_OWNER="+owner)
	unrelated := exec.Command("sleep", "30")
	for _, cmd := range []*exec.Cmd{owned, unrelated} {
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		defer cmd.Process.Kill()
	}
	(&Player{Binary: owner}).Reap()
	if err := owned.Wait(); err == nil {
		t.Fatal("owned child was not terminated")
	}
	if err := unrelated.Process.Signal(syscall.Signal(0)); err != nil {
		t.Fatal("cleanup terminated an unrelated child")
	}
	unrelated.Process.Kill()
	unrelated.Wait()
}

func TestBitrateClampsSavedValuesToOfferedSteps(t *testing.T) {
	for _, tc := range []struct{ saved, want int }{{0, 8000}, {100, 400}, {400, 400}, {500, 400}, {1000, 1000}, {1500, 1000}, {2000, 2000}, {2500, 2000}, {3000, 3000}, {4000, 4000}, {5000, 4000}, {6000, 6000}, {7000, 6000}, {8000, 8000}, {20000, 8000}} {
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
	}{{0, "8 Mbps (max)"}, {12000, "8 Mbps (max)"}, {5000, "4 Mbps"}, {4000, "4 Mbps"}, {3000, "3 Mbps"}, {2000, "2 Mbps"}, {1000, "1 Mbps"}, {400, "0.4 Mbps, low res"}, {50, "0.4 Mbps, low res"}} {
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
	if a.Cfg.Bitrate != 8000 || row.val() != "8 Mbps (max)" {
		t.Fatalf("stepping up from the default: %d %q", a.Cfg.Bitrate, row.val())
	}
	row.step(-1)
	if a.Cfg.Bitrate != 6000 || row.val() != "6 Mbps" {
		t.Fatalf("stepping down from the default: %d %q", a.Cfg.Bitrate, row.val())
	}
	for i := 0; i < len(Bitrates)+1; i++ {
		row.step(-1)
	}
	if a.Cfg.Bitrate != 400 || row.val() != "0.4 Mbps, low res" {
		t.Fatalf("stepping down to the end: %d %q", a.Cfg.Bitrate, row.val())
	}
}

// A choice saved by an older build, which offered 3 Mbps at the lowest,
// loads as the same step.
func TestBitrateSavedByOlderBuildLoads(t *testing.T) {
	for _, kbps := range []int{3000, 4000, 6000, 8000} {
		path := filepath.Join(t.TempDir(), "settings.json")
		os.WriteFile(path, []byte(`{"client_id":"misterzine-test","bitrate":`+strconv.Itoa(kbps)+`}`), 0600)
		c := LoadConfig(path)
		if c.LoadError != nil || c.LoadWarning != "" || c.BitrateKbps() != kbps {
			t.Fatalf("saved %d: loaded %d (%v %q)", kbps, c.BitrateKbps(), c.LoadError, c.LoadWarning)
		}
	}
}

// Plex sign-in: a connection the user cancelled, or one whose save failed,
// never leaves the account half signed in.
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
