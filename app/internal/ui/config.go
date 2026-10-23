package ui

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"maps"
	"os"
	"path/filepath"
	"sync"
	"time"

	"plexcrt/internal/access"
)

// Config is the app's settings and sign-in, kept as JSON on the SD card.
// The tokens live only here and in memory; nothing logs them.
type Config struct {
	EarlyAccessUpdates bool     `json:"early_access_updates"`
	RecentSearches     []string `json:"recent_searches,omitempty"`
	NoTaps             bool     `json:"no_taps"`
	NoTheme            bool     `json:"no_theme"`
	Progressive        bool     `json:"progressive"`             // legacy 480p choice; now only picks the calibration's line ends
	FourThree          bool     `json:"only_4x3"`                // hide media wider than 4:3
	NoAutoplay         bool     `json:"no_autoplay"`             // do not run on to the next episode
	NoSkipButtons      bool     `json:"no_skip_buttons"`         // no Skip intro / Skip credits button over the markers
	Bitrate            int      `json:"bitrate"`                 // transcode cap in kbit/s; 0 is the default
	BitrateReset       int      `json:"bitrate_reset,omitempty"` // the BitrateResetGeneration last applied
	AudioBoost         int      `json:"audio_boost,omitempty"`   // surround downmix gain; 0 is the default
	SubtitleSize       int      `json:"subtitle_size,omitempty"` // drawn text subtitles, a percentage (SubtitleSizes); 0 is Normal
	PlaybackLook       string   `json:"playback_look,omitempty"` // the playback controls' look (PlaybackLooks); "" is Standard
	Geometry           Geometry `json:"geometry"`                // where video goes on the raster (menus ignore it)
	Crop               Crop     `json:"crop,omitempty"`          // what each playback starts cropping; nothing saved is off
	ShowBeta           bool     `json:"show_beta_features"`      // show (and run) the features still in beta
	// HiddenLibraries are the keys of the chosen server's libraries left
	// off Home, the menu and search (Options > Libraries).
	HiddenLibraries []string `json:"hidden_libraries,omitempty"`
	// SeenMemos are the ids of the start-up memos already dismissed.
	SeenMemos []string `json:"seen_memos,omitempty"`
	// Premium is the supporter extras' own settings, by key; the public
	// build keeps them without using them.
	Premium          map[string]string `json:"premium,omitempty"`
	ClientID         string            `json:"client_id"`
	Token            string            `json:"token"` // the plex.tv account token
	AccountName      string            `json:"account_name,omitempty"`
	HomeUserID       string            `json:"home_user_id,omitempty"` // selected Plex Home user
	HomeUserTitle    string            `json:"home_user_title,omitempty"`
	HomeToken        string            `json:"home_token,omitempty"` // selected user's plex.tv token
	HomeEnabled      bool              `json:"home_enabled,omitempty"`
	HomePickerNeeded bool              `json:"home_picker_needed,omitempty"`
	HomeRestricted   bool              `json:"home_restricted,omitempty"`
	AutoSignIn       bool              `json:"auto_sign_in,omitempty"`
	ServerURL        string            `json:"server_url"`   // the chosen server
	ServerToken      string            `json:"server_token"` // the token for that server
	ServerName       string            `json:"server_name"`
	ServerID         string            `json:"server_id,omitempty"` // the chosen server's clientIdentifier
	// Streams are the audio and subtitle tracks chosen, by movie or show
	// rating key: the app keeps the choice and passes it with each play
	// (streamChoiceKey), so every episode of a show starts on it.
	Streams     map[string]StreamChoice `json:"streams,omitempty"`
	LoadWarning string                  `json:"-"`
	LoadError   error                   `json:"-"`
	path        string
	saver       *settingsWriter // shared by the copies (snapshot): one writer for the file
}

// StreamChoice is a chosen audio track and subtitle track, as Plex stream
// ids; "" is the server's default, and Subtitle "-1" is off.
type StreamChoice struct {
	Audio    string `json:"audio,omitempty"`
	Subtitle string `json:"subtitle,omitempty"`
}

// snapshot is a copy to put back when a save fails. The extras' settings
// map is copied too, so a failed save leaves them as they were as well.
func (c *Config) snapshot() Config {
	s := *c
	s.Premium = maps.Clone(c.Premium)
	s.Streams = maps.Clone(c.Streams)
	return s
}

// LoadConfig reads the config file; a missing file gives the defaults. A
// client identifier is made on first run and kept.
func LoadConfig(path string) *Config {
	c := &Config{path: path}
	data, err := os.ReadFile(path)
	needsSave := err != nil
	if err == nil {
		if json.Unmarshal(data, c) != nil {
			// Preserve damaged input before recovering; never silently overwrite it.
			if err := os.Rename(path, path+".corrupt-"+time.Now().Format("20060102-150405")); err != nil {
				c.LoadError = fmt.Errorf("cannot preserve damaged settings: %w", err)
				return c
			}
			c = &Config{path: path, LoadWarning: "Settings were damaged. Please sign in again."}
			if backup, e := os.ReadFile(path + ".bak"); e == nil {
				var recovered Config
				if json.Unmarshal(backup, &recovered) == nil && recovered.ClientID != "" {
					recovered.path = path
					recovered.LoadWarning = "Recovered settings from backup."
					c = &recovered
				}
			}
		}
	} else if !os.IsNotExist(err) {
		c.LoadError = fmt.Errorf("cannot read settings: %w", err)
		return c
	}
	if c.ClientID == "" {
		var b [8]byte
		if _, err := rand.Read(b[:]); err != nil {
			c.LoadError = err
			return c
		}
		c.ClientID = "misterzine-" + hex.EncodeToString(b[:])
		needsSave = true
	}
	if c.BitrateReset < BitrateResetGeneration {
		c.Bitrate = Bitrates[len(Bitrates)-1].Kbps
		c.BitrateReset = BitrateResetGeneration
		needsSave = true
	}
	if needsSave || c.LoadWarning != "" {
		if e := c.Save(); e != nil {
			c.LoadError = e
		}
	}
	return c
}

// BitrateResetGeneration moves every install to the top Video bitrate once.
// Generation 1 is the move to the FPGA H.264 decoder core: the software
// decoder releases before it pushed people to low caps, and that saved choice
// would otherwise outlive the update. A settings file below this generation
// is set to the top step on load; a change made afterwards stays. Bump it
// only to deliberately reset everyone's bitrate again.
const BitrateResetGeneration = 1

// DefaultBitrate is the core's own limit (MaxVideoKbps): the video cap a
// wired connection needs nothing below.
const DefaultBitrate = 8000

// Bitrates are the video caps offered, in kbit/s. The steps below 3 Mbps are
// for a weak Wi-Fi link to the server; their transcodes are also made
// smaller (transcodeSize), and a direct stream above the cap is transcoded.
var Bitrates = []struct {
	Kbps  int
	Label string
}{{400, "0.4 Mbps, low res"}, {1000, "1 Mbps"}, {2000, "2 Mbps"}, {3000, "3 Mbps"}, {4000, "4 Mbps"}, {6000, "6 Mbps"}, {8000, "8 Mbps (max)"}}

// BitrateKbps is the cap in force: the offered one at or below the saved
// value, so the request is always the step Options shows. Every step older
// builds offered is still offered, so a saved choice loads unchanged.
func (c *Config) BitrateKbps() int {
	return Bitrates[c.bitrateIndex()].Kbps
}

// bitrateIndex is the offered cap at or below the saved one (the lowest for
// anything smaller, the default when nothing is saved).
func (c *Config) bitrateIndex() int {
	saved := c.Bitrate
	if saved <= 0 {
		saved = DefaultBitrate
	}
	i := 0
	for j, b := range Bitrates {
		if b.Kbps <= saved {
			i = j
		}
	}
	return i
}

// AudioBoosts are the surround downmix gains, expressed as percentages.
// The playback worker limits boosted peaks; stereo sources stay unchanged.
var AudioBoosts = []struct {
	Label string
	Value int
}{{"Off", 100}, {"Small", 175}, {"Large", 300}}

const DefaultAudioBoost = 300

// SubtitleSizes are the sizes of subtitles, as a percentage of Normal: the
// text subtitles the app draws (subtitles.go) and those the server burns in.
var SubtitleSizes = []struct {
	Label string
	Value int
}{{"Normal", 100}, {"Large", 150}, {"Extra large", 200}}

// SubtitleSizeValue is the size in force: Normal for nothing saved or a
// size not offered.
func (c *Config) SubtitleSizeValue() int {
	if c.SubtitleSize <= 0 {
		return 100
	}
	for _, s := range SubtitleSizes {
		if s.Value == c.SubtitleSize {
			return c.SubtitleSize
		}
	}
	return 100
}

// PlaybackLooks are the looks of the playback controls: the app's own,
// the same with icons for the buttons' words (icons.go), and an old deck's blocky on-screen display that wavers like tape
// (vcr.go), on its blue band or straight over the picture.
var PlaybackLooks = []struct {
	Label string
	Value string
}{{"Standard", ""}, {"Icons", "icons"}, {"VCR", "vcr"}, {"VCR, no band", "vcr-clear"}}

func (c *Config) playbackLookIndex() int {
	for i, l := range PlaybackLooks {
		if l.Value == c.PlaybackLook {
			return i
		}
	}
	return 0
}

// playbackLook is the look the playback controls take: the saved one when
// a code covers the themes (access.PlaybackTheme), else Standard. The saved
// value stays, so it comes back once the card has the code.
func (a *App) playbackLook() string {
	if a.Cfg == nil || !a.allowed(access.PlaybackTheme) {
		return ""
	}
	return a.Cfg.PlaybackLook
}

// vcr reports whether the playback controls take the VCR look.
func (a *App) vcr() bool { l := a.playbackLook(); return l == "vcr" || l == "vcr-clear" }

// icons reports whether the playback bar's buttons are drawn as icons;
// everything else about that look is the standard one.
func (a *App) icons() bool { return a.playbackLook() == "icons" }

// vcrClear reports whether the VCR controls go without their band.
func (a *App) vcrClear() bool { return a.playbackLook() == "vcr-clear" }

func (c *Config) subtitleSizeIndex() int {
	for i, s := range SubtitleSizes {
		if s.Value == c.SubtitleSizeValue() {
			return i
		}
	}
	return 0
}

// AudioBoostValue is the downmix gain in force.
func (c *Config) AudioBoostValue() int {
	if c.AudioBoost <= 0 {
		return DefaultAudioBoost
	}
	return max(100, min(300, c.AudioBoost))
}

// audioBoostIndex is the place in AudioBoosts of the gain in force, -1 for
// a gain they do not offer (set by hand).
func (c *Config) audioBoostIndex() int {
	for i, b := range AudioBoosts {
		if b.Value == c.AudioBoostValue() {
			return i
		}
	}
	return -1
}

// SignedIn reports whether a server is on record.
func (c *Config) SignedIn() bool { return c.ServerURL != "" && c.ServerToken != "" }

// ResumeWithoutPicker allows a saved server session only for an explicit
// automatic sign-in choice with a known profile, or a legacy server-only login.
func (c *Config) ResumeWithoutPicker() bool {
	return c.SignedIn() && (c.Token == "" || (c.AutoSignIn && c.HomeUserID != "" && c.HomeToken != ""))
}

// SignOut forgets the account and the server.
func (c *Config) SignOut() error {
	next := c.snapshot()
	next.RecentSearches = nil
	next.HiddenLibraries = nil // the keys belong to the server forgotten here
	next.Streams = nil         // so do the rating keys
	next.AccountName = ""
	next.HomeUserID, next.HomeUserTitle, next.HomeToken = "", "", ""
	next.HomeRestricted, next.AutoSignIn, next.HomeEnabled, next.HomePickerNeeded = false, false, false, false
	next.Token, next.ServerURL, next.ServerToken, next.ServerName, next.ServerID = "", "", "", "", ""
	data, _ := json.MarshalIndent(&next, "", "  ")
	err := c.saves().now(func() error {
		// Clear recovery credentials first so a later corrupt primary cannot undo sign-out.
		if err := atomicConfig(c.path+".bak", data); err != nil {
			return err
		}
		return atomicConfig(c.path, data)
	})
	if err != nil {
		return err
	}
	*c = next
	return nil
}

func atomicConfig(path string, data []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	f, err := os.CreateTemp(dir, ".settings-*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	defer os.Remove(tmp)
	if _, err = f.Write(data); err == nil {
		err = f.Sync()
	}
	if closeErr := f.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// Save atomically replaces settings and retains the last valid configuration.
// What SaveLater holds is written with it: these settings include it.
func (c *Config) Save() error {
	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	path := c.path
	return c.saves().now(func() error { return writeConfig(path, data) })
}

func writeConfig(path string, data []byte) error {
	if old, e := os.ReadFile(path); e == nil && json.Valid(old) {
		if e = atomicConfig(path+".bak", old); e != nil {
			return e
		}
	}
	return atomicConfig(path, data)
}

// saveDelay is how long SaveLater waits for the changes to stop: a held
// left or right on Options steps every RepeatDur, and each write syncs
// the SD card.
var saveDelay = 500 * time.Millisecond

// SaveLater saves the settings as they are now, in the background once
// they have stopped changing for saveDelay, as Save would. Only the UI
// thread calls it (it reads the settings here); failed hears of a failed
// write from the writing goroutine. Flush writes what is held at once.
func (c *Config) SaveLater(failed func(error)) {
	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		failed(err)
		return
	}
	s := c.saves()
	s.mu.Lock()
	defer s.mu.Unlock()
	s.data, s.path, s.failed = data, c.path, failed
	if s.timer == nil {
		s.timer = time.AfterFunc(saveDelay, s.deferred)
	} else {
		s.timer.Reset(saveDelay)
	}
}

// Flush writes what SaveLater holds now, after any write under way: before
// playback, on leaving Options and on the way out. When it fails the
// settings stay held for the next save.
func (c *Config) Flush() error {
	return c.saves().flush()
}

const saveFailed = "Could not save settings. Check free space and retry."

// saveSettings saves the settings the UI thread just changed without
// waiting for the SD card (SaveLater); a failure shows on the notice line.
func (a *App) saveSettings() {
	a.Cfg.SaveLater(func(err error) {
		a.Log.Printf("config: %v", err)
		a.Later(func() { a.Notice, a.NoticeAt = saveFailed, time.Now() })
	})
}

// flushSettings writes what saveSettings has yet to, at once.
func (a *App) flushSettings() {
	if a.Cfg == nil {
		return
	}
	if err := a.Cfg.Flush(); err != nil {
		a.Log.Printf("config: %v", err)
		a.Notice, a.NoticeAt = saveFailed, time.Now()
	}
}

// saves is the file's writer, made with the first save.
func (c *Config) saves() *settingsWriter {
	if c.saver == nil {
		c.saver = &settingsWriter{}
	}
	return c.saver
}

// settingsWriter writes one settings file, one write at a time, and holds the
// settings SaveLater has yet to write.
type settingsWriter struct {
	write  sync.Mutex // held through each write
	mu     sync.Mutex // guards the rest
	data   []byte     // held for writing; nil for nothing
	path   string
	timer  *time.Timer
	failed func(error)
}

// take is what is held, no longer held.
func (s *settingsWriter) take() (data []byte, path string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	data, path, s.data = s.data, s.path, nil
	if s.timer != nil {
		s.timer.Stop()
	}
	return data, path
}

// hold puts back settings a write failed to keep, unless newer ones came.
func (s *settingsWriter) hold(data []byte, path string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.data == nil {
		s.data, s.path = data, path
	}
}

// now runs write, which saves settings at least as new as those held, in
// their place.
func (s *settingsWriter) now(write func() error) error {
	s.write.Lock()
	defer s.write.Unlock()
	data, path := s.take()
	err := write()
	if err != nil && data != nil {
		s.hold(data, path)
	}
	return err
}

func (s *settingsWriter) flush() error {
	s.write.Lock()
	defer s.write.Unlock()
	data, path := s.take()
	if data == nil {
		return nil
	}
	err := writeConfig(path, data)
	if err != nil {
		s.hold(data, path)
	}
	return err
}

// deferred is the timer's write.
func (s *settingsWriter) deferred() {
	if err := s.flush(); err != nil {
		s.mu.Lock()
		failed := s.failed
		s.mu.Unlock()
		if failed != nil {
			failed(err)
		}
	}
}
