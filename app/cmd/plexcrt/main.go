// plexcrt is the PlexCRT front end for MiSTer: draws into the core's frame
// ring, reads the pad through the core's status words, plays through the
// existing launcher.
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
	"syscall"
	"time"

	"plexcrt/internal/beta"
	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/plex"
	"plexcrt/internal/ring"
	"plexcrt/internal/ui"
)

var version = "0.1.0-beta.12"
var build = "development"

func main() {
	exe, _ := os.Executable()
	home := filepath.Dir(exe)
	host := flag.String("host", "", "server address for explicit legacy-token import")
	tokenFile := flag.String("token", "", "explicit legacy token file (requires -host)")
	cache := flag.String("cache", filepath.Join(home, "cache"), "artwork cache directory")
	dump := flag.String("dump", "", "render once to this PPM and exit")
	wait := flag.Duration("wait", 8*time.Second, "with -dump: how long to wait for artwork")
	script := flag.String("player", filepath.Join(home, "plexplay.py"), "launcher script")
	prof := flag.String("cpuprofile", "", "write a CPU profile here until exit")
	cfgPath := flag.String("config", filepath.Join(home, "plexcrt.json"), "settings file")
	showVersion := flag.Bool("version", false, "show version and exit")
	check := flag.Bool("check", false, "check installation without loading video")
	decoder := flag.String("ffmpeg", "", "decoder executable (default: beside the app)")
	flag.Parse()
	if *showVersion {
		fmt.Printf("MisterZine Plex Core %s (%s)\n", version, build)
		channel := beta.Channel
		if channel == "" {
			channel = "development"
		}
		fmt.Printf("Release channel: %s\n", channel)
		if beta.Batch != "" || beta.KeySHA256 != "" || beta.CodeSHA256 != "" {
			fmt.Printf("Patreon beta batch: %s\n", beta.Batch)
		}
		return
	}
	ff := filepath.Join(home, "ffmpeg")
	if _, err := os.Stat(ff); err != nil {
		ff = filepath.Join(home, "ffmpeg-7.0.2-armhf-static", "ffmpeg")
	}
	if *decoder != "" {
		ff = *decoder
	}
	os.Setenv("PLEX_FFMPEG", ff)
	os.Setenv("MISTERZINE_PLEX_OWNER", filepath.Clean(*script))
	if *dump == "" {
		if err := preflight(home, *script, *cfgPath, *cache, ff); err != nil {
			fmt.Fprintln(os.Stderr, "MisterZine Plex Core:", err)
			os.Exit(1)
		}
	}
	if *check {
		fmt.Printf("Installation ready: %s (%s)\n", version, build)
		return
	}
	// Prevent two copies of this install writing the same frame ring.
	lock, err := os.OpenFile(filepath.Join(home, "app.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		fmt.Fprintln(os.Stderr, "Cannot create app lock:", err)
		os.Exit(1)
	}
	defer lock.Close()
	if syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB) != nil {
		fmt.Fprintln(os.Stderr, "MisterZine Plex Core is already running.")
		return
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

	safeOutput := &safelog.Writer{Out: os.Stderr, Secrets: []string{cfg.Token, cfg.ServerToken}}
	defer safeOutput.Flush()
	lg := log.New(safeOutput, "", log.Ltime)
	lg.Printf("MisterZine Plex Core %s (%s)", version, build)
	// the server: from the sign-in on record, else the legacy token file
	// with the -host flag; with neither the app opens on the sign-in screen
	var client *plex.Client
	var playerEnv []string
	if cfg.SignedIn() {
		client = plex.New(cfg.ServerURL, cfg.ServerToken, *cache, cfg.ClientID)
		playerEnv = []string{"PLEX_HOST=" + cfg.ServerURL, "PLEX_TOKEN=" + cfg.ServerToken, "PLEX_CLIENT_ID=" + cfg.ClientID}
	} else if tok, err := os.ReadFile(*tokenFile); *host != "" && *tokenFile != "" && err == nil && strings.TrimSpace(string(tok)) != "" {
		client = plex.New(*host, strings.TrimSpace(string(tok)), *cache, cfg.ClientID)
		playerEnv = []string{"PLEX_HOST=" + *host, "PLEX_TOKEN=" + strings.TrimSpace(string(tok)), "PLEX_CLIENT_ID=" + cfg.ClientID}
	}

	if *dump != "" {
		app := ui.New(client, &fileOut{gfx.NewCanvas(720, 480)}, nil, lg)
		app.Cfg = cfg
		app.Version, app.Build = version, build
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
		return
	}

	r, err := ring.Open()
	if err != nil {
		lg.Fatalf("ring: %v (is MisterZine Plex Core loaded?)", err)
	}
	defer r.Close()
	player := &ui.Player{Script: *script, Fifo: "/tmp/plexplay.ctl", LogTo: filepath.Join(os.TempDir(), "plexplay.log"),
		Status: "/tmp/plexfb.stat", Env: playerEnv, Kbps: cfg.BitrateKbps, Boost: cfg.AudioBoostValue}
	player.Access = func() error { return beta.Check(filepath.Dir(*cfgPath)) }
	app := ui.New(client, r, player, lg)
	player.Geometry = app.VideoGeometry
	player.Crop, player.CropFile = app.VideoCrop, "/tmp/plexfb.crop"
	watching := make(chan struct{})
	go r.Watch(lg.Printf, app.WakeUp, watching)
	defer close(watching)
	app.Cfg = cfg
	app.Version, app.Build = version, build
	app.SetCacheDir(*cache)
	player.Reap()
	defer player.Reap()
	app.Start()
	if cfg.LoadWarning != "" {
		app.Notice = cfg.LoadWarning
		app.NoticeAt = time.Now()
	}

	stop := make(chan struct{})
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	go func() { <-sig; close(stop) }()
	events := merge(input.Poll(r, stop), input.Sim("/tmp/plexcrt.ctl", stop), stop)
	app.Run(events, stop)
	// Leave our core on black, but once MiSTer main has loaded another core
	// or the menu, this memory is main's picture.
	if r.CoreRunning(100 * time.Millisecond) {
		r.Blank()
	}
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
				out <- ev
			case ev := <-b:
				out <- ev
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

func preflight(home, script, cfg, cache, ff string) error {
	for _, name := range []string{"python3", "aplay"} {
		if _, err := exec.LookPath(name); err != nil {
			return fmt.Errorf("%s is missing; update MiSTer Linux and reinstall", name)
		}
	}
	for _, path := range []string{script, filepath.Join(home, "plexfb"), ff} {
		st, err := os.Stat(path)
		if err != nil || st.IsDir() {
			return fmt.Errorf("installation is incomplete (%s); run the installer again", filepath.Base(path))
		}
		if path != script && st.Mode()&0111 == 0 {
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
