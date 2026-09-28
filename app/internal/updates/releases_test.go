package updates

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func fixture() Release {
	return Release{ID: "fixture", Version: "1.2.0", Channel: "public", URL: "https://example.org/package.zip", DBURL: "https://example.org/public.json.zip", Size: 123, SHA256: strings.Repeat("a", 64)}
}
func TestReleasePrecedenceAndNotifications(t *testing.T) {
	for _, tc := range []struct {
		a, b string
		want int
	}{
		{"1.0.0-beta.10", "1.0.0-beta.2", 1}, {"1.0.0", "1.0.0-beta.99", 1},
		{"1.0.0", "1.1.0-beta.1", -1}, {"v1.0.0", "1.0.0", 0},
		{"1.0.0-beta", "1.0.0-beta.1", -1}, {"1.0.0-1", "1.0.0-beta", -1},
	} {
		if got, ok := Compare(tc.a, tc.b); !ok || got != tc.want {
			t.Errorf("%s vs %s: %d %v", tc.a, tc.b, got, ok)
		}
	}
	if _, ok := Compare("development", "1.0.0"); ok {
		t.Fatal("local label accepted")
	}
	r := fixture()
	if !Notify(r, "1.2.0-beta.1", "beta", false) {
		t.Fatal("public catch-up missing")
	}
	if !Notify(r, "1.2.0", "beta", false) || Notify(r, "1.2.0", "public", false) {
		t.Fatal("equal-version public catch-up must notify only beta installations")
	}
	if Notify(r, "1.3.0-beta.1", "beta", false) {
		t.Fatal("older public notified")
	}
	r.Channel = "beta"
	r.Version = "1.3.0-beta.1"
	if Notify(r, "1.2.0", "public", false) || !Notify(r, "1.2.0", "public", true) {
		t.Fatal("opt-in ignored")
	}
}
func TestCatalogueValidationAndHTTPS(t *testing.T) {
	c := Catalogue{Schema: 1, Releases: map[string]Release{"public": fixture()}}
	data, _ := json.Marshal(c)
	if _, err := Parse(data); err != nil {
		t.Fatal(err)
	}
	for _, bad := range []string{`{}`, `{"schema":1}`, `{"schema":2,"releases":{}}`, strings.Repeat(" ", 129<<10)} {
		if _, err := Parse([]byte(bad)); err == nil {
			t.Fatal("invalid catalogue accepted")
		}
	}
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write(data) }))
	defer srv.Close()
	if _, err := Fetch(context.Background(), srv.Client(), srv.URL); err != nil {
		t.Fatal(err)
	}
	if _, err := Fetch(context.Background(), nil, "http://example.org"); err == nil {
		t.Fatal("insecure catalogue accepted")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := Fetch(ctx, srv.Client(), srv.URL); err == nil {
		t.Fatal("cancelled check succeeded")
	}
	c.Releases["beta"] = fixture()
	data, _ = json.Marshal(c)
	if _, err := Parse(data); err == nil {
		t.Fatal("channel mismatch accepted")
	}
	r := fixture()
	r.Channel = "beta"
	if r.Validate() == nil {
		t.Fatal("incomplete beta accepted")
	}
	r = fixture()
	r.Access = &Access{Batch: "fixture", SHA256: strings.Repeat("a", 64)}
	if r.Validate() == nil {
		t.Fatal("public access metadata accepted")
	}
}
func TestWorkerStatusAfterInterruption(t *testing.T) {
	root := t.TempDir()
	os.Mkdir(filepath.Join(root, "updates"), 0700)
	path := filepath.Join(root, "updates/status.json")
	os.WriteFile(path, []byte(`{"stage":"download","pid":0}`), 0600)
	if s := ReadStatus(root); s.Stage != "failed" || s.Busy() {
		t.Fatal(s)
	}
	os.WriteFile(path, []byte(`{"stage":"ready","pid":0}`), 0600)
	if s := ReadStatus(root); s.Stage != "ready" {
		t.Fatal(s)
	}
	os.WriteFile(path, []byte(`garbled`), 0600)
	if s := ReadStatus(root); s.Stage != "failed" {
		t.Fatal(s)
	}
}

func TestWorkerDoesNotInheritPlaybackCleanupOwnership(t *testing.T) {
	t.Setenv("MISTERZINE_PLEX_OWNER", "/synthetic/plexplay.py")
	t.Setenv("MISTERZINE_PLEX_READY_FILE", "/synthetic/started")
	root := filepath.Join(t.TempDir(), "misterzine-plex")
	os.Mkdir(root, 0700)
	for _, name := range []string{"manager.py", "catalogue.py", "menu_launcher.py"} {
		os.WriteFile(filepath.Join(root, name), []byte("# fixture"), 0600)
	}
	script := `import json, os, pathlib, sys
root=pathlib.Path(sys.argv[sys.argv.index('--card')+1])/'misterzine-plex'
stage='failed' if 'MISTERZINE_PLEX_OWNER' in os.environ or 'MISTERZINE_PLEX_READY_FILE' in os.environ else 'ready'
(root/'updates/status.json').write_text(json.dumps({'stage':stage}))
`
	os.WriteFile(filepath.Join(root, "update_service.py"), []byte(script), 0600)
	r := fixture()
	exited, err := Start(root, "prepare", &r)
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-exited:
	case <-time.After(3 * time.Second):
		t.Fatal("the worker's exit was not reported")
	}
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		s := ReadStatus(root)
		if s.Stage == "failed" {
			t.Fatal("worker inherited app cleanup ownership")
		}
		if s.Stage == "ready" {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("fixture worker did not finish")
}
