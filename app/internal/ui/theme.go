package ui

import (
	"context"
	"encoding/binary"
	"io"
	"os"
	"os/exec"
	"sync/atomic"
	"syscall"
	"time"

	"plexcrt/internal/plex"
)

const themeGain = 0.275 // half the previous 0.55 level

// Theme owns both children. Stop waits until ALSA has been released, including
// when decoding, network access or an audio write stalls. Cancel, for
// navigation, does not wait: the fade runs out behind the next page, and
// the next theme waits for it before it opens the device.
type Theme struct {
	key    string
	cancel context.CancelFunc
	done   chan struct{} // closed once this player and every one before it are gone
	// players counts themes writing audio right now, fades included; the
	// UI thread reads it (Playing) while the players' goroutines change it.
	players atomic.Int32
}

// Playing reports a theme song writing audio, its fade included: the
// navigation tick stays quiet then, so two writers never interleave on the
// audio device.
func (t *Theme) Playing() bool { return t.players.Load() > 0 }

// The tests' seams: where the theme comes from and what plays it.
var (
	themeFile = (*plex.Client).ThemeFile
	themePlay = playTheme
)

// Cancel stops the theme without waiting for its fade.
func (t *Theme) Cancel() {
	if t.cancel != nil {
		t.cancel()
		t.cancel = nil
	}
	t.key = ""
}

// Stop is Cancel that waits until every player has released ALSA: playback
// needs the device.
func (t *Theme) Stop() {
	t.Cancel()
	if t.done != nil {
		<-t.done
		t.done = nil
	}
}

// Select plays key's theme once, decoded by ffmpeg; an empty key stops the
// one playing.
func (t *Theme) Select(c *plex.Client, ffmpeg, key, path string) {
	if key == t.key {
		return
	} // includes a theme that already finished: play once
	t.Cancel()
	if key == "" || c == nil {
		return
	}
	t.key = key
	ctx, cancel := context.WithCancel(context.Background())
	prev, done := t.done, make(chan struct{})
	t.cancel, t.done = cancel, done
	go func() {
		defer func() {
			if prev != nil {
				<-prev // done says the earlier players are gone too
			}
			close(done)
		}()
		file, err := themeFile(c, ctx, key, path)
		if err != nil || ctx.Err() != nil {
			return
		}
		if prev != nil {
			// ALSA is single-client: the last theme's fade first
			select {
			case <-prev:
			case <-ctx.Done():
				return
			}
		}
		t.players.Add(1)
		defer t.players.Add(-1)
		themePlay(ctx, ffmpeg, file)
	}()
}

func playTheme(ctx context.Context, ffmpeg, file string) {
	playThemeCommands(ctx, func(hard context.Context) (*exec.Cmd, *exec.Cmd) {
		decode := exec.CommandContext(hard, ffmpeg,
			"-nostdin", "-v", "error", "-i", file, "-f", "s16le", "-ac", "2", "-ar", "48000", "pipe:1")
		output := exec.CommandContext(hard, "/usr/bin/aplay", "-q", "-t", "raw", "-f", "S16_LE",
			"-c", "2", "-r", "48000", "--buffer-time=40000", "--period-time=10000", "-")
		return decode, output
	})
}

func playThemeCommands(ctx context.Context, commands func(context.Context) (*exec.Cmd, *exec.Cmd)) {
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
	decode, output := commands(hard)
	pcm, err := decode.StdoutPipe()
	if err != nil {
		return
	}
	defer pcm.Close()
	audio, err := output.StdinPipe()
	if err != nil {
		return
	}
	defer audio.Close()
	// Bound queued PCM to about 21 ms; a default 64 KB pipe would delay a
	// navigation fade by a third of a second before ALSA even sees it.
	if f, ok := audio.(*os.File); ok {
		syscall.Syscall(syscall.SYS_FCNTL, f.Fd(), 1031 /* F_SETPIPE_SZ */, 4096)
	}
	if ctx.Err() != nil {
		return
	}
	if err = output.Start(); err != nil {
		return
	}
	defer output.Wait() // always reap aplay before Stop returns
	if err = decode.Start(); err != nil {
		kill()
		return
	}
	defer func() { decode.Process.Kill(); decode.Wait() }()
	buf := make([]byte, 480*4) // ten milliseconds, stereo samples share one gain
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
			if _, err = audio.Write(buf[:n]); err != nil {
				kill()
				return
			}
		}
		if readErr != nil || (stopping && gain == 0) {
			audio.Close()
			return
		}
	}
}

// Dialogs within a show inherit that show's music; navigation pages do not.
func (a *App) syncTheme() {
	if a.Cfg == nil || a.Cfg.NoTheme || a.Plex == nil {
		a.theme.Cancel()
		return
	}
	var key, path string
	for i := len(a.stack) - 1; i >= 0; i-- {
		switch s := a.stack[i].(type) {
		case *Show:
			key, path = s.item.RatingKey, s.item.Theme
		case *Home:
			if s.fixed != nil {
				key, path = s.fixed.RatingKey, s.fixed.Theme
			}
		case *Preplay:
			if s.item.Type == "episode" {
				key = s.item.GrandKey
			}
		case *Chooser, *FullText, *BetaAccess, *ForgetBetaAccess, *Updates:
			continue
		}
		break
	}
	a.theme.Select(a.Plex, a.FFmpeg, key, path)
}
