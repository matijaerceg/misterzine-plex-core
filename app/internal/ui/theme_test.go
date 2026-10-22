package ui

import (
	"context"
	"encoding/binary"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"sync"
	"testing"
	"time"

	"plexcrt/internal/plex"
)

// Helpers exercise real pipes/process ownership without opening the sound device.
func TestThemeProcess(t *testing.T) {
	role := os.Getenv("PLEX_THEME_HELPER")
	if role == "" {
		return
	}
	if role == "decode" {
		buf := make([]byte, 1920)
		for i := 0; i < len(buf); i += 2 {
			binary.LittleEndian.PutUint16(buf[i:], 20000)
		}
		for {
			if _, err := os.Stdout.Write(buf); err != nil {
				os.Exit(0)
			}
		}
	}
	if role == "stalled" {
		time.Sleep(time.Hour)
	}
	if role == "audio" {
		f, err := os.Create(os.Getenv("PLEX_THEME_CAPTURE"))
		if err != nil {
			os.Exit(2)
		}
		buf := make([]byte, 1920)
		for {
			n, err := io.ReadFull(os.Stdin, buf)
			f.Write(buf[:n])
			if err != nil {
				break
			}
			time.Sleep(10 * time.Millisecond)
		}
		f.Close()
		os.Exit(0)
	}
}

func TestThemeFadeAndRelease(t *testing.T) {
	for _, role := range []string{"decode", "stalled"} {
		t.Run(role, func(t *testing.T) {
			file := filepath.Join(t.TempDir(), "pcm")
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			done := make(chan struct{})
			var decode, output *exec.Cmd
			go func() {
				defer close(done)
				playThemeCommands(ctx, func(hard context.Context) (*exec.Cmd, *exec.Cmd) {
					makeCmd := func(role string) *exec.Cmd {
						cmd := exec.CommandContext(hard, os.Args[0], "-test.run=^TestThemeProcess$")
						cmd.Env = append(os.Environ(), "PLEX_THEME_HELPER="+role, "PLEX_THEME_CAPTURE="+file)
						return cmd
					}
					decode, output = makeCmd(role), makeCmd("audio")
					return decode, output
				})
			}()
			time.Sleep(600 * time.Millisecond)
			cancel()
			select {
			case <-done:
			case <-time.After(2 * time.Second):
				t.Fatal("theme did not release audio")
			}
			if decode.ProcessState == nil || output.ProcessState == nil {
				t.Fatal("child was not reaped")
			}
			if role == "decode" {
				pcm, err := os.ReadFile(file)
				if err != nil {
					t.Fatal(err)
				}
				if len(pcm) < 48000 {
					t.Fatalf("too little PCM: %d", len(pcm))
				}
				peak := int16(0)
				for i := 0; i < len(pcm); i += 4 {
					v := int16(binary.LittleEndian.Uint16(pcm[i:]))
					if v > peak {
						peak = v
					}
					if binary.LittleEndian.Uint16(pcm[i:]) != binary.LittleEndian.Uint16(pcm[i+2:]) {
						t.Fatal("stereo gain mismatch")
					}
				}
				if peak < 5400 || peak > 5500 {
					t.Fatalf("gain peak=%d", peak)
				}
				if binary.LittleEndian.Uint16(pcm[len(pcm)-2:]) != 0 {
					t.Fatal("fade did not reach silence")
				}
			}
		})
	}
}

// Navigation does not wait for a theme's fade; the next theme waits for it
// before it plays (ALSA has one client), one cancelled meanwhile never
// plays, and Stop waits for them all.
func TestThemeNavigationDoesNotWaitForTheFade(t *testing.T) {
	file, play := themeFile, themePlay
	t.Cleanup(func() { themeFile, themePlay = file, play })
	themeFile = func(_ *plex.Client, _ context.Context, key, _ string) (string, error) { return key, nil }
	const fade = 300 * time.Millisecond
	var mu sync.Mutex
	var playing, most int
	var order []string
	started := make(chan string, 4)
	themePlay = func(ctx context.Context, file string) {
		mu.Lock()
		playing++
		most = max(most, playing)
		order = append(order, file)
		mu.Unlock()
		started <- file
		<-ctx.Done()
		time.Sleep(fade) // the fade, aplay draining and the reaping
		mu.Lock()
		playing--
		mu.Unlock()
	}
	quick := func(what string, f func()) {
		t.Helper()
		t0 := time.Now()
		f()
		if d := time.Since(t0); d > fade/3 {
			t.Fatalf("%s waited %v", what, d)
		}
	}
	waitStarted := func(want string) {
		t.Helper()
		select {
		case got := <-started:
			if got != want {
				t.Fatalf("%s played, want %s", got, want)
			}
		case <-time.After(2 * time.Second):
			t.Fatalf("%s did not play", want)
		}
	}
	var th Theme
	c := &plex.Client{}
	th.Select(c, "a", "")
	waitStarted("a")
	quick("moving to another show", func() { th.Select(c, "b", "") })
	quick("and on to a third", func() { th.Select(c, "c", "") })
	select {
	case got := <-started:
		t.Fatalf("%s played during the last theme's fade", got)
	case <-time.After(fade / 2):
	}
	waitStarted("c")
	quick("leaving for a page without music", func() { th.Select(c, "", "") })
	t0 := time.Now()
	th.Stop()
	if d := time.Since(t0); d < fade*9/10 {
		t.Fatalf("Stop returned %v into a %v fade", d, fade)
	}
	mu.Lock()
	defer mu.Unlock()
	if playing != 0 || most != 1 || !slices.Equal(order, []string{"a", "c"}) {
		t.Fatalf("after Stop: %d playing, at most %d at once, played %q", playing, most, order)
	}
}
