// plexcrt is the MisterZine Plex Core app for MiSTer: draws into the H.264
// core's overlay pages, reads the pad through the core's input region, plays
// through jfplay.
//
//	plexcrt                      run on the device (core must be loaded)
//	plexcrt -dump out.ppm        render the home screen once to a file, no ring
package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"plexcrt/internal/safelog"
	"runtime/pprof"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"plexcrt/internal/beta"
	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/plex"
	"plexcrt/internal/ring"
	"plexcrt/internal/ui"
	"plexcrt/internal/updates"
)

var version = "0.1.0-beta.16"
var build = "development"

// exitToMenu is the exit status after the menu's Exit: the launcher then
// loads the MiSTer menu (EXIT_TO_MENU in release/manager.py).
const exitToMenu = 3

func main() { os.Exit(run()) }

// run is the app; its deferred cleanup is done before main exits with its status.
func run() int {
	exe, _ := os.Executable()
	home := filepath.Dir(exe)
	host := flag.String("host", "", "server address for explicit legacy-token import")
	tokenFile := flag.String("token", "", "explicit legacy token file (requires -host)")
	cache := flag.String("cache", filepath.Join(home, "cache"), "artwork cache directory")
	dump := flag.String("dump", "", "render once to this PPM and exit")
	wait := flag.Duration("wait", 8*time.Second, "with -dump: how long to wait for artwork")
	playerPath := flag.String("player", filepath.Join(home, "jfplay"), "playback worker")
	prof := flag.String("cpuprofile", "", "write a CPU profile here until exit")
	cfgPath := flag.String("config", filepath.Join(home, "plexcrt.json"), "settings file")
	showVersion := flag.Bool("version", false, "show version and exit")
	check := flag.Bool("check", false, "check installation without loading video")
	decoder := flag.String("ffmpeg", "", "decoder executable (default: beside the app)")
	flag.Parse()
	if *showVersion {
		fmt.Printf("MisterZine Plex Core %s (%s)\n", version, build)
		channel := updates.Channel
		if channel == "" {
			channel = "development"
		}
		fmt.Printf("Release channel: %s\n", channel)
		if extras := ui.PremiumVersion(); extras != "" {
			fmt.Printf("Supporter extras: %s\n", extras)
		}
		if beta.Batch != "" || beta.KeySHA256 != "" || beta.CodeSHA256 != "" {
			fmt.Printf("Patreon beta batch: %s\n", beta.Batch)
		}
		return 0
	}
	ff := filepath.Join(home, "ffmpeg") // the installer places it beside the app
	if *decoder != "" {
		ff = *decoder
	}
	// MISTERZINE_PLEX_OWNER marks every process the app starts as this
	// install's: its children inherit it, and Player.Reap kills any process
	// whose environment carries it (or the MISTERZINE_JFPLAY_OWNER each
	// player launch sets) for this player, at start, at exit and before each
	// playback, so nothing left over keeps the core. The only other reader is updates/worker.go, which
	// strips it (and MISTERZINE_PLEX_READY_FILE) from the updater it starts so
	// the updater survives that cleanup. Both readers are in this program.
	os.Setenv("MISTERZINE_PLEX_OWNER", filepath.Clean(*playerPath))
	if *dump == "" {
		if err := preflight(home, *playerPath, *cfgPath, *cache, ff); err != nil {
			fmt.Fprintln(os.Stderr, "MisterZine Plex Core:", err)
			os.Exit(1)
		}
	}
	if *check {
		fmt.Printf("Installation ready: %s (%s)\n", version, build)
		return 0
	}
	// Prevent two copies of this install writing the same overlay pages.
	lock, err := os.OpenFile(filepath.Join(home, "app.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		fmt.Fprintln(os.Stderr, "Cannot create app lock:", err)
		os.Exit(1)
	}
	defer lock.Close()
	if syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB) != nil {
		fmt.Fprintln(os.Stderr, "MisterZine Plex Core is already running.")
		return 0
	}
	cfg := ui.LoadConfig(*cfgPath)
	if cfg.LoadError != nil {
		fmt.Fprintln(os.Stderr, "Cannot load settings:", cfg.LoadError)
		os.Exit(1)
	}
	if *prof != "" {
		pf, err := os.Create(*prof)
		if err == nil {
			pprof.StartCPUProfile(pf)
			defer pprof.StopCPUProfile()
		}
	}

	safeOutput := &safelog.Writer{Out: os.Stderr, Secrets: []string{cfg.Token, cfg.HomeToken, cfg.ServerToken}}
	defer safeOutput.Flush()
	lg := log.New(safeOutput, "", log.Ltime)
	lg.Printf("MisterZine Plex Core %s (%s)", version, build)
	// the server: from the sign-in on record, else the legacy token file
	// with the -host flag; with neither the app opens on the sign-in screen
	var client *plex.Client
	if cfg.ResumeWithoutPicker() {
		client = plex.New(cfg.ServerURL, cfg.ServerToken, *cache, cfg.ClientID)
	} else if tok, err := os.ReadFile(*tokenFile); *host != "" && *tokenFile != "" && err == nil && strings.TrimSpace(string(tok)) != "" {
		client = plex.New(*host, strings.TrimSpace(string(tok)), *cache, cfg.ClientID)
	}

	if *dump != "" {
		app := ui.New(client, &fileOut{gfx.NewCanvas(ui.DesignW, ui.DesignH)}, nil, lg)
		app.Cfg = cfg
		app.Version, app.Build = version, build
		app.FFmpeg = ff
		app.SetCacheDir(*cache)
		app.Start()
		app.DrawOnce()
		deadline := time.Now().Add(*wait)
		for app.Art.Pending() && time.Now().Before(deadline) {
			time.Sleep(100 * time.Millisecond)
		}
		app.DrawOnce()
		time.Sleep(300 * time.Millisecond) // let the text lines land
		c := app.DrawOnce()
		if err := c.WritePPM(*dump); err != nil {
			lg.Fatal(err)
		}
		fmt.Println("wrote", *dump)
		return 0
	}

	r, err := ring.Open(lg.Printf)
	if err != nil {
		lg.Fatalf("ring: %v (is the PlexH264 core loaded?)", err)
	}
	// The ring stays mapped until the process ends: the pad poller and the
	// watchdog may still be reading it as the app stops, and exiting unmaps it.
	player := &ui.Player{Client: client, Binary: *playerPath, Fifo: "/tmp/jfplay.ctl", LogTo: filepath.Join(os.TempDir(), "jfplay.log"),
		Status: "/tmp/jfplay.status", Kbps: cfg.BitrateKbps, DirectPlay: cfg.DirectPlay, Boost: cfg.AudioBoostValue, SubtitleSize: cfg.SubtitleSizeValue, Hide: r.Hide}
	player.Access = func() error { return beta.Check(filepath.Dir(*cfgPath)) }
	app := ui.New(client, r, player, lg)
	player.Crop = app.VideoCrop
	if r.GeometrySupported() {
		player.Geometry = app.VideoGeometry
	}
	watching := make(chan struct{})
	watchDone := make(chan struct{})
	go func() {
		defer close(watchDone)
		r.Watch(lg.Printf, app.WakeUp, watching)
	}()
	app.Cfg = cfg
	app.Version, app.Build = version, build
	app.FFmpeg = ff
	app.Display = ui.ParseDisplayCheck(os.Getenv("MISTERZINE_PLEX_DISPLAY"))
	app.SetCacheDir(*cache)
	player.Reap()
	defer player.Reap()
	app.Start()
	if cfg.LoadWarning != "" {
		app.Notice = cfg.LoadWarning
		app.NoticeAt = time.Now()
	}

	stop := make(chan struct{})
	var stopping sync.Once
	quit := func() { stopping.Do(func() { close(stop) }) }
	coreChanged := atomic.Bool{}
	coreWatchDone := make(chan struct{})
	go func() {
		defer close(coreWatchDone)
		tick := time.NewTicker(50 * time.Millisecond)
		defer tick.Stop()
		for {
			select {
			case <-stop:
				return
			case <-tick.C:
				if !r.CoreAvailable() {
					name, _ := ring.CoreName()
					coreChanged.Store(true)
					lg.Printf("core changed to %q; stopping app", name)
					quit()
					return
				}
			}
		}
	}()
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	go func() { <-sig; quit() }()
	events := merge(input.Poll(r, stop), input.Sim("/tmp/plexcrt.ctl", stop), stop)
	app.Run(events, stop)
	quit() // after the menu's Exit, the pad and the test FIFO stop too
	close(watching)
	<-watchDone
	<-coreWatchDone
	// Leave our core on black, but once MiSTer main has loaded another core
	// or the menu, this memory is main's picture.
	if !coreChanged.Load() && ring.CoreLoaded() && r.CoreRunning(100*time.Millisecond) {
		r.Blank()
	}
	if app.ToMenu {
		return exitToMenu
	}
	return 0
}

// merge joins the pad and the simulation FIFO into one stream.
func merge(a, b <-chan input.Event, stop <-chan struct{}) <-chan input.Event {
	out := make(chan input.Event, 64)
	go func() {
		defer close(out)
		for {
			select {
			case ev, ok := <-a:
				if !ok {
					return
				}
				input.Send(out, ev) // the poller's rule again: this buffer is the one a stall fills
			case ev := <-b:
				input.Send(out, ev)
			case <-stop:
				return
			}
		}
	}()
	return out
}

// fileOut is the headless presenter: one ordinary canvas.
type fileOut struct{ c *gfx.Canvas }

func (f *fileOut) Begin() *gfx.Canvas                   { return f.c }
func (f *fileOut) End()                                 {}
func (f *fileOut) Missed() bool                         { return false }
func (f *fileOut) Foreign() bool                        { return false }
func (f *fileOut) Late() (time.Duration, time.Duration) { return 0, 0 }
func (f *fileOut) WaitField(max time.Duration)          { time.Sleep(16 * time.Millisecond) }

func preflight(home, player, cfg, cache, ff string) error {
	for _, name := range []string{"aplay"} {
		if _, err := exec.LookPath(name); err != nil {
			return fmt.Errorf("%s is missing; update MiSTer Linux and reinstall", name)
		}
	}
	for _, path := range []string{player, ff} {
		st, err := os.Stat(path)
		if err != nil || st.IsDir() {
			return fmt.Errorf("installation is incomplete (%s); run the installer again", filepath.Base(path))
		}
		if path != player && st.Mode()&0111 == 0 {
			return fmt.Errorf("%s is not executable; reinstall", filepath.Base(path))
		}
	}
	if _, err := os.Stat("/dev/MrAudio"); err != nil {
		return fmt.Errorf("MiSTer audio device is missing; update MiSTer Linux")
	}
	for _, dir := range []string{filepath.Dir(cfg), cache} {
		if err := os.MkdirAll(dir, 0700); err != nil {
			return fmt.Errorf("cannot create settings/cache folder: %w", err)
		}
		f, err := os.CreateTemp(dir, ".write-check-*")
		if err != nil {
			return fmt.Errorf("settings/cache folder is not writable: %w", err)
		}
		_, err = f.Write([]byte("check"))
		if err == nil {
			err = f.Sync()
		}
		f.Close()
		os.Remove(f.Name())
		if err != nil {
			return fmt.Errorf("cannot save to SD card (check free space): %w", err)
		}
	}
	return nil
}
