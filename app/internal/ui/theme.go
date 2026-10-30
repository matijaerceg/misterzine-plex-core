package ui

import (
	"context"
	"encoding/binary"
	"io"
	"os"
	"os/exec"
	"syscall"
	"time"

	"plexcrt/internal/plex"
)

const (
	themeGain = 1.0 // preserve source level; the envelope only fades in and out
	// Frames held back from the sink so a theme that ends on its own fades out
	// over them. The clips Plex serves are mostly 30 s long and cut hard, which at
	// source volume sounded like the app stopping the music.
	themeTail = 48000 * 3 / 2
)

// Theme owns both children. Stop waits until theme output has been released, including
// when decoding, network access or an audio write stalls. Cancel, for
// navigation, does not wait: the fade runs out behind the next page, and
// the next theme waits for it before it writes to the shared menu audio pipe.
type Theme struct {
	play   func(context.Context, string, string)
	key    string
	cancel context.CancelFunc
	done   chan struct{} // closed once this player and every one before it are gone
}

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

// Stop is Cancel that waits until every player has released theme output: playback
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
	play := t.play
	if play == nil {
		play = themePlay
	}
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
			// The previous theme must finish its fade first
			select {
			case <-prev:
			case <-ctx.Done():
				return
			}
		}
		play(ctx, ffmpeg, file)
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
	if feedTheme(ctx, pcm, func(b []byte) error { _, err := audio.Write(b); return err }) != nil {
		kill()
		return
	}
	audio.Close()
}

// feedTheme carries decoded PCM to the sink under the envelope: a quarter-second
// fade in, a fast fade out when navigation cancels the theme, and a fade over
// the held tail when the decoder ends on its own. Decoding runs far ahead of
// real time, so holding the tail back delays nothing audible. It returns the
// first write error.
func feedTheme(ctx context.Context, pcm io.Reader, write func([]byte) error) error {
	buf := make([]byte, 480*4) // ten milliseconds, stereo samples share one gain
	room := make([]byte, 0, themeTail*4+len(buf))
	held := room
	gain, ending, tail, left := 0.0, false, 0, 0
	for {
		if !ending {
			n, err := io.ReadFull(pcm, buf)
			n -= n % 4
			if cap(held)-len(held) < n {
				held = append(room[:0], held...)
			}
			held = append(held, buf[:n]...)
			if err != nil {
				ending = true
				left = len(held) / 4
				tail = min(left, themeTail)
			}
		}
		stopping := ctx.Err() != nil
		n := len(held) - themeTail*4
		if ending {
			n = len(held)
		}
		n = min(max(n, 0), len(buf))
		for i := 0; i < n; i += 4 {
			if stopping {
				gain = max(0, gain-themeGain/7200)
			} else {
				gain = min(themeGain, gain+themeGain/12000)
			}
			if ending {
				// A linear ramp to silence at the last frame; a clip shorter than
				// the tail still rises first, so it is heard at all.
				left--
				gain = min(gain, themeGain*float64(left)/float64(tail))
			}
			for ch := 0; ch < 4; ch += 2 {
				v := int16(binary.LittleEndian.Uint16(held[i+ch:]))
				binary.LittleEndian.PutUint16(held[i+ch:], uint16(int16(float64(v)*gain)))
			}
		}
		if n > 0 {
			if err := write(held[:n]); err != nil {
				return err
			}
		}
		held = held[n:]
		if (ending && len(held) == 0) || (stopping && gain == 0) {
			return nil
		}
	}
}

// Dialogs within a show inherit that show's music; navigation pages do not.
func (a *App) syncTheme() {
	a.syncMenuAudio()
	if a.menuAudio == nil {
		a.theme.Cancel()
		return
	}
	a.theme.play = a.menuAudio.PlayTheme
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
