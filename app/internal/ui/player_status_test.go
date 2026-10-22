package ui

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

// The status file is parsed again only when jfplay has replaced it.
func TestPlayerStatusIsReadAgainOnlyWhenReplaced(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "jfplay.status")
	var c statusFiles
	put := func(text string, age time.Duration) {
		t.Helper()
		tmp := path + ".tmp"
		if err := os.WriteFile(tmp, []byte(text), 0o600); err != nil {
			t.Fatal(err)
		}
		at := time.Now().Add(-age)
		if err := os.Chtimes(tmp, at, at); err != nil {
			t.Fatal(err)
		}
		if err := os.Rename(tmp, path); err != nil {
			t.Fatal(err)
		}
	}
	same := func(a, b map[string]string) bool {
		return reflect.ValueOf(a).UnsafePointer() == reflect.ValueOf(b).UnsafePointer()
	}
	put("position=10.000\nstate=playing\n", time.Second)
	first, written, err := c.read(path)
	if err != nil || first["position"] != "10.000" || time.Since(written) < time.Second {
		t.Fatalf("first read %v %v %v", first, written, err)
	}
	if again, _, _ := c.read(path); !same(first, again) {
		t.Fatal("an unchanged file was parsed again")
	}
	put("position=10.250\nstate=playing\n", time.Second) // same size, a new file
	if next, _, _ := c.read(path); same(first, next) || next["position"] != "10.250" {
		t.Fatalf("a replaced file was not read: %v", next)
	}
	// written just now: a rewrite in the same timestamp could follow, so
	// the read is not kept
	put("position=10.500\nstate=playing\n", 0)
	fresh, _, _ := c.read(path)
	if again, _, _ := c.read(path); same(fresh, again) || again["position"] != "10.500" {
		t.Fatal("a file read as it was written was kept")
	}
	os.Remove(path)
	if gone, _, err := c.read(path); err == nil || gone != nil {
		t.Fatal("a removed file still reads")
	}
	if readPlayerStatus(path) != nil {
		t.Fatal("readPlayerStatus of no file is not nil")
	}
}
