package safelog

import (
	"bytes"
	"strings"
	"testing"
)

func TestSplitCredentialRedaction(t *testing.T) {
	var b bytes.Buffer
	w := &Writer{Out: &b, Secrets: []string{"private+/token"}}
	for _, s := range []string{"failed https://server/?X-Plex-To", "ken=private%2B%2Ftoken&x=1\n", "Authorization: Bearer abc123\n", "private+/token"} {
		w.Write([]byte(s))
	}
	w.Flush()
	for _, secret := range []string{"private", "abc123"} {
		if strings.Contains(b.String(), secret) {
			t.Fatalf("credential escaped redaction: %s", secret)
		}
	}
	if !strings.Contains(b.String(), "&x=1") {
		t.Fatal("lost useful error context")
	}
}

// The redactor knows every credential name release/manager.py redacts.
func TestManagerCredentialNamesRedacted(t *testing.T) {
	for _, line := range []string{
		"GET https://server/Videos/1/stream?api_key=stale123&Static=true",
		"GET https://server/socket?access_token=stale123",
		"X-Emby-Token: stale123",
		`X-MediaBrowser-Token="stale123"`,
	} {
		got := Redact(line)
		if strings.Contains(got, "stale123") {
			t.Errorf("Redact(%q) = %q", line, got)
		}
	}
	if got := Redact("api_key=stale123&Static=true"); got != "api_key=[redacted]&Static=true" {
		t.Errorf("api_key: %q", got)
	}
}

func TestOversizedLineDropped(t *testing.T) {
	var b bytes.Buffer
	w := &Writer{Out: &b}
	w.Write([]byte(strings.Repeat("x", 70000)))
	w.Write([]byte("token=secret\n"))
	if strings.Contains(b.String(), "secret") || strings.Contains(b.String(), "xxx") {
		t.Fatal("oversized line leaked")
	}
}
