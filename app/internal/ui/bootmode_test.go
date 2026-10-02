package ui

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestWriteBootModeCreatesOnlyFor480p(t *testing.T) {
	path := filepath.Join(t.TempDir(), "MisterZine Plex Core.CFG")
	if changed, err := writeBootMode(path, false); err != nil || changed {
		t.Fatalf("480i with no file: changed %v, err %v", changed, err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("480i created the file: %v", err)
	}
	if changed, err := writeBootMode(path, true); err != nil || !changed {
		t.Fatalf("480p: changed %v, err %v", changed, err)
	}
	want := make([]byte, 16)
	want[1] = 0x02 // status[9]
	if got, _ := os.ReadFile(path); !bytes.Equal(got, want) {
		t.Fatalf("file % x, want % x", got, want)
	}
	if changed, err := writeBootMode(path, true); err != nil || changed {
		t.Fatalf("480p again: changed %v, err %v", changed, err)
	}
}

func TestWriteBootModeKeepsOtherSettings(t *testing.T) {
	path := filepath.Join(t.TempDir(), "MisterZine Plex Core.CFG")
	saved := []byte{0x40, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x80} // status[6], status[8], a high bit
	if err := os.WriteFile(path, saved, 0644); err != nil {
		t.Fatal(err)
	}
	if changed, err := writeBootMode(path, true); err != nil || !changed {
		t.Fatalf("480p: changed %v, err %v", changed, err)
	}
	got, _ := os.ReadFile(path)
	if got[0] != 0x40 || got[1] != 0x03 || got[15] != 0x80 || len(got) != 16 {
		t.Fatalf("480p: file % x", got)
	}
	if changed, err := writeBootMode(path, false); err != nil || !changed {
		t.Fatalf("480i: changed %v, err %v", changed, err)
	}
	if got, _ := os.ReadFile(path); !bytes.Equal(got, saved) {
		t.Fatalf("480i: file % x, want % x", got, saved)
	}
}

func TestWriteBootModePadsAShortFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "MisterZine Plex Core.CFG")
	if err := os.WriteFile(path, []byte{0x40}, 0644); err != nil {
		t.Fatal(err)
	}
	if changed, err := writeBootMode(path, true); err != nil || !changed {
		t.Fatalf("changed %v, err %v", changed, err)
	}
	got, _ := os.ReadFile(path)
	if len(got) != 16 || got[0] != 0x40 || got[1] != 0x02 {
		t.Fatalf("file % x", got)
	}
}
