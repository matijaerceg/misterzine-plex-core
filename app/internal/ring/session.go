package ring

import (
	"errors"
	"fmt"
	"os"
	"syscall"
	"time"
)

// The overlay shows only during a session (overlay.md "Showing it"; the
// vendored docs/jellyfin.md section 7, F1): with the core freshly loaded,
// or after the menu's Reset, nothing this app draws is on screen until some
// program writes a session nonce. The player opens its own session for
// each playback; for the browse screens before and between them, this app
// opens an idle one: no records, nothing in the ring.
//
// The library's lock (hps/lib/h264ring_linux.c) is an advisory, exclusive,
// non-blocking flock on /tmp/h264ring.lock, held from h264ring_open_devmem
// to h264ring_close: a second program feeding the core gets -EBUSY. The
// player holds it for its whole run, so this app must never hold it while
// the player might start: it takes it only for the handshake below (a few
// ms) and only when it is free, and releases it at once. The session it
// opened stays open after the lock is gone (closing a handle does not end
// a session); the player's own session start replaces it, writing the
// player's descriptor (none) over ours, which Watch then writes again.
var lockFile = "/tmp/h264ring.lock"

var errLocked = errors.New("another program holds the core (its lock is taken)")

// ensureSession opens an idle session when none is open.
func (r *Ring) ensureSession() error {
	r.sessionAt = time.Now()
	if st, ok := r.c.status(); ok && st.Session() {
		return nil
	}
	fd, err := syscall.Open(lockFile, syscall.O_RDWR|syscall.O_CREAT|syscall.O_CLOEXEC, 0o666)
	if err != nil {
		return fmt.Errorf("session lock: %w", err)
	}
	defer syscall.Close(fd) // releases the flock
	if syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB) != nil {
		return errLocked
	}
	return r.startSession(2 * time.Second)
}

// startSession runs the session handshake (interface.md "The session",
// the library's new_session), called with the lock held: this program's
// pause, settings and rumble words (none), the write index rounded down to
// 16, this app's overlay descriptor (or none) -- all before the nonce, and
// then the nonce alone, and the core's acknowledgement.
func (r *Ring) startSession(timeout time.Duration) error {
	if !r.writesAllowed() {
		return errors.New("session: app core ownership was lost")
	}
	st, ok := r.c.status()
	if !ok {
		return errors.New("session: the status block is not readable")
	}
	ack := r.c.hi(wAck)
	cur := r.c.lo(wNonce)
	if !r.writesAllowed() {
		return errors.New("session: app core ownership was lost")
	}
	r.c.setLo(wPause, 0)
	if !r.writesAllowed() {
		return errors.New("session: app core ownership was lost")
	}
	r.c.setLo(wSettings, 0)
	for k := 0; k < 3; k++ {
		if !r.writesAllowed() {
			return errors.New("session: app core ownership was lost")
		}
		r.c.setLo(wRumble+k, 0)
	}
	if wi := r.c.lo(wWriteIdx); wi&15 != 0 {
		if !r.writesAllowed() {
			return errors.New("session: app core ownership was lost")
		}
		r.c.setLo(wWriteIdx, wi&^15)
	}
	r.mu.Lock()
	r.write(r.want) // ours, or none: never a previous program's page
	r.mu.Unlock()
	if !r.writesAllowed() {
		return errors.New("session: app core ownership was lost")
	}
	nonce := uint32(time.Now().UnixNano()*2654435761) ^ uint32(os.Getpid()) ^ st.Heartbeat
	for nonce == 0 || nonce == ack || nonce == cur {
		nonce++
	}
	if !r.writesAllowed() {
		return errors.New("session: app core ownership was lost")
	}
	r.c.setLo(wNonce, nonce)
	deadline := time.Now().Add(timeout)
	for {
		if !r.writesAllowed() {
			return errors.New("session: app core ownership was lost")
		}
		if r.c.hi(wAck) == nonce {
			return nil
		}
		if !time.Now().Before(deadline) {
			return fmt.Errorf("session: the core did not acknowledge the nonce within %s", timeout)
		}
		r.c.sleep(time.Millisecond)
	}
}
