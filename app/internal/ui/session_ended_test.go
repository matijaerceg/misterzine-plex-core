package ui

import (
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
)

// A server that refuses the token (401) sends the app back to sign-in; any
// other failure leaves the sign-in alone.
func TestRefusedTokenOpensTheServerPicker(t *testing.T) {
	status := http.StatusInternalServerError
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "no", status)
	}))
	defer server.Close()
	cfg := &Config{path: filepath.Join(t.TempDir(), "settings.json"), ServerURL: server.URL, ServerToken: "server-token", Token: "account-token"}
	a := newHomeFlowApp(t, cfg)
	a.Plex = testClient(server.URL, "server-token", t.TempDir())

	_, err := a.Plex.Sections()
	if err == nil || a.SessionEnded(err) || a.Plex.Refused() {
		t.Fatalf("a server error ended the session: %v", err)
	}

	status = http.StatusUnauthorized
	_, err = a.Plex.Sections()
	if !a.SessionEnded(err) {
		t.Fatalf("a refusal did not end the session: %v", err)
	}
	drain(t, a)
	if a.Plex == nil || a.Cfg.Token != "account-token" {
		t.Fatal("still signed in after the server refused the token")
	}
	if l, ok := a.top().(*Login); !ok || !l.picker {
		t.Fatalf("not on the server picker: %T", a.top())
	}
}

// A refusal of a client the app has since replaced (another user or
// server) does not sign the new one out.
func TestRefusalOfAReplacedClientKeepsTheSignIn(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "no", http.StatusUnauthorized)
	}))
	defer server.Close()
	cfg := &Config{path: filepath.Join(t.TempDir(), "settings.json"), ServerURL: server.URL, ServerToken: "new-token", Token: "account-token"}
	a := newHomeFlowApp(t, cfg)
	old := testClient(server.URL, "old-token", t.TempDir())
	a.Plex = testClient(server.URL, "new-token", t.TempDir())
	_, err := old.Sections()
	if !a.SessionEnded(err) {
		t.Fatalf("not a refusal: %v", err)
	}
	drain(t, a)
	if a.Plex == nil || a.Cfg.ServerToken != "new-token" {
		t.Fatal("the old client's refusal signed the new one out")
	}
}
