package ui

import (
	"bufio"
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"os"
	"os/exec"
	"plexcrt/internal/input"
	"plexcrt/internal/ring"
	"sync/atomic"
	"syscall"
	"time"
)

// menuAudio owns the audio input only while browsing. Preparation is asynchronous;
// taps have no queue, so navigation can never accumulate delayed sounds.
type menuAudio struct {
	pcm     *os.File
	cmd     *exec.Cmd
	in      io.WriteCloser
	ready   atomic.Bool
	taps    chan menuTap
	tones   chan menuTap
	stop    chan struct{}
	done    chan struct{}
	written chan struct{}
	scanned chan struct{}
}

type menuTap struct{ level, note int }

// Keeping NoTaps and an optional quiet flag preserves old settings unchanged:
// enabled navigation sounds remain Loud, and disabled sounds remain Off.
func (c *Config) menuAudioLevel() int {
	if c == nil || c.NoTaps {
		return 0
	}
	if c.QuietTaps {
		return 1
	}
	return 2
}

func (c *Config) setMenuAudioLevel(level int) {
	level = max(0, min(2, level))
	c.NoTaps, c.QuietTaps = level == 0, level == 1
}

func startMenuAudio(cmd *exec.Cmd) (*menuAudio, error) {
	reader, writer, err := os.Pipe()
	if err != nil {
		return nil, err
	}
	defer reader.Close()
	success := false
	defer func() {
		if !success {
			writer.Close()
		}
	}()
	syscall.Syscall(syscall.SYS_FCNTL, writer.Fd(), 1031, 4096)
	cmd.ExtraFiles = append(cmd.ExtraFiles, reader)
	cmd.Env = append(os.Environ(), cmd.Env...)
	cmd.Env = append(cmd.Env, fmt.Sprintf("MZ_MENU_PCM_FD=%d", 2+len(cmd.ExtraFiles)))
	in, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		in.Close()
		return nil, err
	}
	if err = cmd.Start(); err != nil {
		in.Close()
		out.Close()
		return nil, err
	}
	success = true
	m := &menuAudio{pcm: writer, cmd: cmd, in: in, taps: make(chan menuTap), tones: make(chan menuTap, 1), stop: make(chan struct{}), done: make(chan struct{}), written: make(chan struct{}), scanned: make(chan struct{})}
	go func() {
		defer close(m.scanned)
		s := bufio.NewScanner(out)
		if s.Scan() && s.Text() == "ready" {
			m.ready.Store(true)
		}
		for s.Scan() {
		} // drain diagnostics without blocking the worker
	}()
	go func() {
		defer close(m.written)
		for {
			select {
			case <-m.stop:
				return
			case <-m.done:
				return
			case tone := <-m.tones:
				command := "end\n"
				if tone.level > 0 {
					command = fmt.Sprintf("ton %d %d\n", tone.level, tone.note)
				}
				if _, err := io.WriteString(in, command); err != nil {
					return
				}
			case tap := <-m.taps:
				if _, err := fmt.Fprintf(in, "tap %d %d\n", tap.level, tap.note); err != nil {
					return
				}
			}
		}
	}()
	go func() { <-m.scanned; _ = cmd.Wait(); m.ready.Store(false); close(m.done) }()
	return m, nil
}

// Tone replaces pending tone control; releases cannot be dropped behind a busy
// pipe writer. Only the most recent desired pitch is relevant, never a backlog.
func (m *menuAudio) Tone(level, note int) bool {
	if m == nil || !m.ready.Load() || m.tones == nil {
		return false
	}
	if level != 0 && (level < 1 || level > 2 || note < 48 || note > 96) {
		return false
	}
	select {
	case <-m.tones:
	default:
	}
	m.tones <- menuTap{level, note}
	return true
}

func (a *App) silenceMenuTone() {
	if a.menuToneOn {
		a.menuAudio.Tone(0, 0)
		a.menuToneOn = false
	}
}

func (a *App) menuAudioInput(ev input.Event) {
	if ev.Release {
		if a.menuNavDown && ev.Key == a.menuNavKey {
			a.menuNavDown = false
			a.silenceMenuTone()
		}
		return
	}
	a.menuNavRepeat = ev.Repeat
	if ev.Key == input.Up || ev.Key == input.Down || ev.Key == input.Left || ev.Key == input.Right {
		a.menuNavDown, a.menuNavKey = true, ev.Key
	} else {
		a.menuNavDown = false
		a.silenceMenuTone()
	}
}

func (m *menuAudio) Tap(level, note int) bool {
	if m == nil || !m.ready.Load() || level < 1 || level > 2 {
		return false
	}
	if note != 0 && (note < 48 || note > 96) {
		note = 0
	}
	select {
	case m.taps <- menuTap{level, note}:
		return true
	default:
		return false
	}
}

// Stop returns only once the worker has exited and released the hardware lock.
func (m *menuAudio) Stop() {
	if m == nil {
		return
	}
	m.ready.Store(false)
	if m.pcm != nil {
		m.pcm.Close()
	}
	close(m.stop)
	_ = m.in.Close()
	timer := time.NewTimer(1500 * time.Millisecond)
	defer timer.Stop()
	select {
	case <-m.done:
	case <-timer.C:
		_ = m.cmd.Process.Kill()
		<-m.done
	}
	<-m.written
}

func (a *App) stopMenuAudio() {
	a.theme.Stop()
	a.menuNavDown, a.menuToneOn = false, false
	if a.menuAudio != nil {
		a.menuAudio.Stop()
		a.menuAudio = nil
	}
}

func (a *App) menuAudioSettingChanged() {
	a.menuAudioRetry = time.Time{}
	a.menuAudioFailures = 0
	a.syncMenuAudio()
}

func (a *App) syncMenuAudio() {
	if !a.menuAudioRunning || a.menuAudioHeld || a.playing || a.ToMenu || a.Cfg == nil || (a.Cfg.NoTaps && a.Cfg.NoTheme) {
		a.stopMenuAudio()
		return
	}
	if a.menuAudio != nil {
		if a.menuAudio.ready.Load() {
			a.menuAudioFailures = 0
		}
		select {
		case <-a.menuAudio.done:
			a.stopMenuAudio()
		default:
			return
		}
	}
	if a.Player == nil || a.Player.Binary == "" || a.menuAudioFailures >= 3 || time.Now().Before(a.menuAudioRetry) {
		return
	}
	a.menuAudioRetry = time.Now().Add(5 * time.Second)
	a.menuAudioFailures++
	run := a.Player.exec
	if run == nil {
		run = exec.Command
	}
	m, err := startMenuAudio(run(a.Player.Binary, "--menu-audio", "--core-name", ring.AppCoreName))
	if err != nil {
		if a.Log != nil {
			a.Log.Printf("navigation audio: %v", err)
		}
		return
	}
	a.menuAudio = m
}

// PlayTheme decodes only audio. The menu worker mixes PCM with navigation clicks;
// it alone owns the FPGA input. Bounded pipe writes keep cancellation responsive.
func (m *menuAudio) PlayTheme(ctx context.Context, ffmpeg, file string) {
	m.playThemeCommand(ctx, func(hard context.Context) *exec.Cmd {
		return exec.CommandContext(hard, ffmpeg, "-nostdin", "-v", "error", "-i", file,
			"-f", "s16le", "-ac", "2", "-ar", "48000", "pipe:1")
	})
}

func (m *menuAudio) playThemeCommand(ctx context.Context, command func(context.Context) *exec.Cmd) {
	hard, kill := context.WithCancel(context.Background())
	defer kill()
	finished := make(chan struct{})
	defer close(finished)
	go func() {
		select {
		case <-ctx.Done():
		case <-finished:
			return
		}
		timer := time.NewTimer(500 * time.Millisecond)
		defer timer.Stop()
		select {
		case <-timer.C:
			kill()
		case <-finished:
		}
	}()
	cmd := command(hard)
	pcm, err := cmd.StdoutPipe()
	if err != nil {
		return
	}
	defer pcm.Close()
	if ctx.Err() != nil {
		return
	}
	if err = cmd.Start(); err != nil {
		return
	}
	defer func() { kill(); cmd.Wait() }()
	for !m.ready.Load() {
		select {
		case <-ctx.Done():
			return
		case <-m.done:
			return
		case <-time.After(5 * time.Millisecond):
		}
	}
	buf := make([]byte, 480*4)
	gain := 0.0
	for {
		n, readErr := io.ReadFull(pcm, buf)
		n -= n % 4
		stopping := ctx.Err() != nil
		for i := 0; i < n; i += 4 {
			if stopping {
				gain = max(0, gain-themeGain/7200)
			} else {
				gain = min(themeGain, gain+themeGain/12000)
			}
			for ch := 0; ch < 4; ch += 2 {
				v := int16(binary.LittleEndian.Uint16(buf[i+ch:]))
				binary.LittleEndian.PutUint16(buf[i+ch:], uint16(int16(float64(v)*gain)))
			}
		}
		if n > 0 {
			if err = m.pcm.SetWriteDeadline(time.Now().Add(200 * time.Millisecond)); err != nil {
				return
			}
			if _, err = m.pcm.Write(buf[:n]); err != nil {
				return
			}
		}
		if readErr != nil || (stopping && gain == 0) {
			return
		}
	}
}
