package ui

import (
	"bytes"
	"errors"
	"io/fs"
	"os"
	"sync"

	"plexcrt/internal/ring"
)

// The core starts its raster in 480p when status bit 9 is set, so a scaler
// that locks onto the signal as the core loads (a RetroTINK 4K in Direct
// Video) never sees it switch from 480i once the app is up. MiSTer main keeps
// a core's status bits as 16 bytes in config/<core name>.CFG, loads them when
// the core starts and rewrites the file only when Save settings is picked in
// the core's menu. The app keeps the bit in step with the confirmed mode.
const (
	statusBytes  = 16
	bootModeByte = 9 / 8
	bootModeMask = 1 << (9 % 8)
)

// writeBootMode sets or clears the bit and keeps every other byte. A missing
// file already means 480i, so clearing never creates one. It reports whether
// the file was written.
func writeBootMode(path string, progressive bool) (bool, error) {
	old, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		if !progressive {
			return false, nil
		}
		old, err = nil, nil
	}
	if err != nil {
		return false, err
	}
	data := make([]byte, max(statusBytes, len(old)))
	copy(data, old)
	if progressive {
		data[bootModeByte] |= bootModeMask
	} else {
		data[bootModeByte] &^= bootModeMask
	}
	if bytes.Equal(data, old) {
		return false, nil
	}
	return true, atomicConfig(path, data)
}

// bootModeState hands the latest wanted value to one writer goroutine, so an
// SD card write never holds up a field and a later choice is never overwritten
// by an earlier one.
type bootModeState struct {
	mu                     sync.Mutex
	want, pending, running bool
}

// saveBootMode records the confirmed mode where the core reads it at load:
// 480p only while it is the saved choice and no CRT profile locks the core to
// 480i. Cores that do not report their video status are left alone.
func (a *App) saveBootMode(r *ring.Ring) {
	if a.BootModeFile == "" {
		return
	}
	if _, _, supported := r.VideoStatus(); !supported {
		return
	}
	on := a.Cfg.Progressive && !r.VideoLocked()
	s := &a.bootMode
	s.mu.Lock()
	s.want, s.pending = on, true
	start := !s.running
	s.running = true
	s.mu.Unlock()
	if start {
		go a.writeBootModes()
	}
}

func (a *App) writeBootModes() {
	s := &a.bootMode
	for {
		s.mu.Lock()
		if !s.pending {
			s.running = false
			s.mu.Unlock()
			return
		}
		on := s.want
		s.pending = false
		s.mu.Unlock()
		changed, err := writeBootMode(a.BootModeFile, on)
		mode := "480i"
		if on {
			mode = "480p"
		}
		switch {
		case err != nil:
			a.Log.Printf("video: could not save the start mode (%s) for the core: %v", mode, err)
		case changed:
			a.Log.Printf("video: the core will start in %s (saved in %s)", mode, a.BootModeFile)
		}
	}
}
