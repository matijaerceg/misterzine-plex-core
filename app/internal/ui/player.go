package ui

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"plexcrt/internal/safelog"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// Player runs the existing launcher (arm/plexplay.py) for one item. The
// presenter (plexfb) draws into the same ring, so the UI stops presenting
// and instead drives the overlay through the launcher's control FIFO.
type Player struct {
	Script       string // path to plexplay.py
	Fifo         string // its control FIFO
	LogTo        string
	Status       string     // plexfb's status file; it appears the moment plexfb starts
	Env          []string   // PLEX_HOST, PLEX_TOKEN, PLEX_CLIENT_ID for the launcher
	Kbps         func() int // the transcode cap to ask for, read at each start
	Boost        func() int // the surround-to-stereo gain to ask for, read at each start
	SubtitleSize func() int // Plex's burned-in subtitle size, read at each start
	// Geometry is the presenter's picture area (PLEXFB_GEOMETRY), read at each start
	Geometry func() string
	// Crop is the presenter's crop, read at each start and written to
	// CropFile (PLEXFB_CROP_FILE), which it watches: SetCrop changes it mid-play
	Crop     func() Crop
	CropFile string
	Access   func() error // optional official-beta entitlement check
}

// Session is one running playback.
type Session struct {
	p    *Player
	cmd  *exec.Cmd
	lf   *os.File
	Done chan error
}

// Started reports whether the presenter has announced itself since t.
func (p *Player) Started(t time.Time) bool {
	st, err := os.Stat(p.Status)
	return err == nil && !st.ModTime().Before(t.Add(-time.Second))
}

// Start launches playback of a rating key from an offset in seconds
// (negative: the server's resume point).
// Reap kills playback processes left from an earlier run of the app (a
// crash mid-playback leaves the launcher, ffmpeg and plexfb publishing
// frames against the new UI).
func (p *Player) Reap() {
	// Only processes explicitly marked by this install belong to this player.
	// Never match a generic process name or a substring of its command line.
	entries, _ := os.ReadDir("/proc")
	owner := filepath.Clean(p.Script)
	var owned []int
	for _, entry := range entries {
		pid, err := strconv.Atoi(entry.Name())
		if err != nil || pid == os.Getpid() {
			continue
		}
		env, err := os.ReadFile("/proc/" + entry.Name() + "/environ")
		if err != nil {
			continue
		}
		if ownedPlayer(env, owner) {
			syscall.Kill(pid, syscall.SIGTERM)
			owned = append(owned, pid)
		}
	}
	if len(owned) > 0 {
		time.Sleep(300 * time.Millisecond)
	}
	for _, pid := range owned {
		// Re-check ownership before escalation; never trust a stale PID alone.
		env, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/environ")
		if err == nil && ownedPlayer(env, owner) {
			syscall.Kill(pid, syscall.SIGKILL)
		}
	}
}
func ownedPlayer(env []byte, owner string) bool {
	for _, field := range strings.Split(string(env), "\x00") {
		if field == "MISTERZINE_PLEX_OWNER="+owner {
			return true
		}
	}
	return false
}

func (p *Player) Start(ratingKey string, offset int) (*Session, error) {
	if p.Access != nil {
		if err := p.Access(); err != nil {
			return nil, err
		}
	}
	lf, err := os.OpenFile(p.LogTo, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return nil, fmt.Errorf("cannot open playback log: %w", err)
	}
	var secrets []string
	for _, field := range p.Env {
		if strings.HasPrefix(field, "PLEX_TOKEN=") {
			secrets = append(secrets, strings.TrimPrefix(field, "PLEX_TOKEN="))
		}
	}
	output := &safelog.Writer{Out: lf, Secrets: secrets}
	args := []string{p.Script, "rk:" + ratingKey}
	if offset >= 0 {
		args = append(args, strconv.Itoa(offset))
	}
	cmd := exec.Command("python3", args...)
	cmd.Stdout, cmd.Stderr = output, output
	cmd.Env = append(append(os.Environ(), "PYTHONUNBUFFERED=1", "MISTERZINE_PLEX_OWNER="+filepath.Clean(p.Script)), p.Env...)
	if p.Kbps != nil {
		cmd.Env = append(cmd.Env, "PLEX_BITRATE="+strconv.Itoa(p.Kbps()))
	}
	if p.Boost != nil {
		cmd.Env = append(cmd.Env, "PLEX_AUDIO_BOOST="+strconv.Itoa(p.Boost()))
	}
	if p.SubtitleSize != nil {
		cmd.Env = append(cmd.Env, "PLEX_SUBTITLE_SIZE="+strconv.Itoa(p.SubtitleSize()))
	}
	if p.Geometry != nil {
		cmd.Env = append(cmd.Env, "PLEXFB_GEOMETRY="+p.Geometry())
	}
	if p.Crop != nil && p.CropFile != "" {
		// without the file the presenter would follow a stale one: no crop
		if err := p.SetCrop(p.Crop()); err == nil {
			cmd.Env = append(cmd.Env, "PLEXFB_CROP_FILE="+p.CropFile)
		} else {
			fmt.Fprintf(output, "crop: %v\n", err)
		}
	}
	if err := cmd.Start(); err != nil {
		if lf != nil {
			lf.Close()
		}
		return nil, err
	}
	s := &Session{p: p, cmd: cmd, lf: lf, Done: make(chan error, 1)}
	go func() {
		err := cmd.Wait()
		output.Flush()
		if lf != nil {
			lf.Close()
		}
		s.Done <- err
	}()
	return s, nil
}

// Send writes a control line to the launcher (pause, resume, toggle,
// seek +10, stop).
func (s *Session) Send(line string) {
	f, err := os.OpenFile(s.p.Fifo, os.O_WRONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return
	}
	f.SetWriteDeadline(time.Now().Add(200 * time.Millisecond))
	fmt.Fprintln(f, line)
	f.Close()
}

// Stop asks the launcher to end playback; falls back to a signal.
func (s *Session) Stop() {
	s.Send("stop")
	select {
	case <-time.After(3 * time.Second):
		s.cmd.Process.Signal(syscall.SIGTERM)
	case err := <-s.Done:
		s.Done <- err
	}
}
