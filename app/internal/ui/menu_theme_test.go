package ui

import (
	"context"
	"encoding/binary"
	"io"
	"os"
	"os/exec"
	"testing"
	"time"
)

func TestMenuThemeFadeAndBlockedSinkCancellation(t *testing.T) {
	for _, blocked := range []bool{false, true} {
		t.Run(map[bool]string{false: "fade", true: "blocked"}[blocked], func(t *testing.T) {
			r, w, err := os.Pipe()
			if err != nil {
				t.Fatal(err)
			}
			defer r.Close()
			defer w.Close()
			m := &menuAudio{pcm: w, done: make(chan struct{})}
			m.ready.Store(true)
			captured := make(chan []byte, 1)
			if !blocked {
				go func() {
					var all []byte
					buf := make([]byte, 1920)
					for {
						n, e := r.Read(buf)
						all = append(all, buf[:n]...)
						if e != nil {
							break
						}
						time.Sleep(10 * time.Millisecond)
					}
					captured <- all
				}()
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			done := make(chan struct{})
			var child *exec.Cmd
			go func() {
				defer close(done)
				m.playThemeCommand(ctx, func(hard context.Context) *exec.Cmd {
					child = exec.CommandContext(hard, os.Args[0], "-test.run=^TestThemeProcess$")
					child.Env = append(os.Environ(), "PLEXCRT_THEME_HELPER=decode")
					return child
				})
			}()
			time.Sleep(650 * time.Millisecond)
			cancel()
			select {
			case <-done:
			case <-time.After(time.Second):
				t.Fatal("theme failed to release blocked PCM sink")
			}
			if child.ProcessState == nil {
				t.Fatal("decoder was not reaped")
			}
			w.Close()
			if !blocked {
				pcm := <-captured
				if len(pcm) < 48000 {
					t.Fatalf("too little audio: %d", len(pcm))
				}
				peak := int16(0)
				for i := 0; i+3 < len(pcm); i += 4 {
					v := int16(binary.LittleEndian.Uint16(pcm[i:]))
					if v > peak {
						peak = v
					}
					if v != int16(binary.LittleEndian.Uint16(pcm[i+2:])) {
						t.Fatal("stereo mismatch")
					}
				}
				if peak < 5400 || peak > 5500 {
					t.Fatalf("gain peak %d", peak)
				}
				if binary.LittleEndian.Uint16(pcm[len(pcm)-2:]) != 0 {
					t.Fatal("fade did not end at silence")
				}
			}
		})
	}
}

// Ensure the inherited pipe really accepts PCM, independently of command input.
func TestMenuAudioPCMTransport(t *testing.T) {
	cmd := exec.Command("sh", "-c", "printf ready\\n; dd bs=4 count=1 <&3 >/dev/null 2>/dev/null; cat >/dev/null")
	m, err := startMenuAudio(cmd)
	if err != nil {
		t.Fatal(err)
	}
	defer m.Stop()
	if err = m.pcm.SetWriteDeadline(time.Now().Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	if _, err = io.WriteString(m.pcm, "test"); err != nil {
		t.Fatal(err)
	}
}
