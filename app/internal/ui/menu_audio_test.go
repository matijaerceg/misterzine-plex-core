package ui

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"plexcrt/internal/updates"
	"strings"
	"testing"
	"time"
)

func TestMenuAudioHelper(t *testing.T) {
	if os.Getenv("MENU_AUDIO_HELPER") == "" {
		return
	}
	path := os.Getenv("MENU_AUDIO_EVENTS")
	if os.Getenv("MENU_AUDIO_PRIMING") == "" {
		fmt.Println("ready")
	}
	s := bufio.NewScanner(os.Stdin)
	for s.Scan() {
		f, _ := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0600)
		fmt.Fprintln(f, s.Text())
		f.Close()
	}
	_ = os.WriteFile(path+".released", []byte("released"), 0600)
	os.Exit(0)
}

func menuAudioCommand(t *testing.T, path string, priming bool) *exec.Cmd {
	t.Helper()
	c := exec.Command(os.Args[0], "-test.run=^TestMenuAudioHelper$")
	c.Env = append(os.Environ(), "MENU_AUDIO_HELPER=1", "MENU_AUDIO_EVENTS="+path)
	if priming {
		c.Env = append(c.Env, "MENU_AUDIO_PRIMING=1")
	}
	return c
}

func TestMenuAudioStopReapsBeforeReturning(t *testing.T) {
	for _, priming := range []bool{false, true} {
		for i := 0; i < 3; i++ {
			path := filepath.Join(t.TempDir(), "events")
			m, err := startMenuAudio(menuAudioCommand(t, path, priming))
			if err != nil {
				t.Fatal(err)
			}
			if !priming {
				deadline := time.Now().Add(3 * time.Second)
				for !m.ready.Load() && time.Now().Before(deadline) {
					time.Sleep(time.Millisecond)
				}
				if !m.ready.Load() {
					m.Stop()
					t.Fatal("worker never ready")
				}
			}
			m.Tap(2, 0)
			m.Stop()
			if m.cmd.ProcessState == nil || !m.cmd.ProcessState.Exited() {
				t.Fatal("Stop did not reap worker")
			}
			if _, err := os.Stat(path + ".released"); err != nil {
				t.Fatalf("next playback would start before audio released: %v", err)
			}
			if priming {
				if _, err := os.Stat(path); !os.IsNotExist(err) {
					t.Fatal("tap was queued during priming")
				}
			}
		}
	}
}

func TestMenuAudioDropsMutedAndPlaybackTaps(t *testing.T) {
	m := &menuAudio{taps: make(chan menuTap, 1)}
	m.ready.Store(true)
	a := &App{Cfg: &Config{}, menuAudio: m}
	a.playing = true
	a.tap()
	a.playing = false
	a.menuAudioHeld = true
	a.tap()
	a.menuAudioHeld = false
	a.Cfg.NoTaps = true
	a.tap()
	if len(m.taps) != 0 {
		t.Fatal("non-menu tap escaped")
	}
	a.Cfg.NoTaps = false
	a.tap()
	if len(m.taps) != 1 {
		t.Fatal("menu tap missing")
	}
	for i := 0; i < 1000; i++ {
		a.tap()
	}
	if len(m.taps) != 1 {
		t.Fatal("tap queue grew")
	}
}

func TestMenuAudioDisabledDoesNotLaunch(t *testing.T) {
	a := &App{Cfg: &Config{NoTaps: true, NoTheme: true}, menuAudioRunning: true, Player: &Player{Binary: "jfplay", exec: func(string, ...string) *exec.Cmd { t.Fatal("disabled sound launched a worker"); return nil }}}
	a.syncMenuAudio()
}

func TestMenuAudioActivationFailureReleasesHold(t *testing.T) {
	a := &App{menuAudioHeld: true}
	a.updates.status = updates.Status{Stage: "activating"}
	a.fail(nil, "updater exited")
	if a.menuAudioHeld {
		t.Fatal("failed activation left navigation audio suspended")
	}
}

func TestMenuAudioSettingsPreserveOlderVolume(t *testing.T) {
	for _, test := range []struct {
		json string
		want int
	}{
		{`{}`, 2}, {`{"no_taps":false}`, 2}, {`{"no_taps":true}`, 0},
		{`{"quiet_taps":true}`, 1}, {`{"no_taps":true,"quiet_taps":true}`, 0},
	} {
		var c Config
		if err := json.Unmarshal([]byte(test.json), &c); err != nil {
			t.Fatal(err)
		}
		if got := c.menuAudioLevel(); got != test.want {
			t.Errorf("%s: level=%d want%d", test.json, got, test.want)
		}
	}
	for level := 0; level < 3; level++ {
		c := Config{}
		c.setMenuAudioLevel(level)
		data, err := json.Marshal(c)
		if err != nil {
			t.Fatal(err)
		}
		var restored Config
		if err = json.Unmarshal(data, &restored); err != nil {
			t.Fatal(err)
		}
		if restored.menuAudioLevel() != level {
			t.Fatalf("level %d did not persist", level)
		}
	}
}

func TestMenuAudioSendsVolumeAndPitch(t *testing.T) {
	path := filepath.Join(t.TempDir(), "events")
	m, err := startMenuAudio(menuAudioCommand(t, path, false))
	if err != nil {
		t.Fatal(err)
	}
	defer m.Stop()
	deadline := time.Now().Add(3 * time.Second)
	accepted := false
	for time.Now().Before(deadline) {
		if m.Tap(1, 72) {
			accepted = true
			break
		}
		time.Sleep(time.Millisecond)
	}
	if !accepted {
		t.Fatal("ready worker never accepted tap")
	}
	for time.Now().Before(deadline) {
		data, _ := os.ReadFile(path)
		if strings.TrimSpace(string(data)) == "tap 1 72" {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("volume and pitch did not reach worker")
}

func TestMenuAudioRejectedTapsDoNotSubmit(t *testing.T) {
	m := &menuAudio{taps: make(chan menuTap)}
	if m.Tap(2, 60) {
		t.Fatal("accepted before ready")
	}
	m.ready.Store(true)
	if m.Tap(2, 60) {
		t.Fatal("accepted without writer")
	}
	if m.Tap(0, 60) {
		t.Fatal("accepted muted tap")
	}
}
