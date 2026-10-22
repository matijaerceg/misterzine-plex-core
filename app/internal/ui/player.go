package ui

import (
	"context"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"plexcrt/internal/plex"
	"plexcrt/internal/ring"
	"plexcrt/internal/safelog"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

type Player struct {
	Client                      *plex.Client
	Binary, Fifo, Status, LogTo string
	// Access is checked before opening a playback log or contacting the
	// server.
	Access      func() error
	Kbps, Boost func() int
	// SubtitleSize is the size the server burns a subtitle into a
	// transcode at (Plex's percentage), read at each start; nil is 100.
	SubtitleSize func() int
	Crop         func() Crop
	Geometry     func() string
	// DrawsSubtitle reports whether the app draws a selected subtitle
	// track of an item itself (a text track: subtitles.go); the stream is
	// then asked for without subtitles. nil, or false, has the server burn
	// the track into a transcode.
	DrawsSubtitle func(ratingKey string, s plex.Stream) bool
	Hide          func()
	exec          func(string, ...string) *exec.Cmd
	stopGrace     time.Duration // how long a worker asked to stop has before it is killed; 0 is 3 s
	// reportWait bounds StartAsync's wait for the last session's stopped
	// report; 0 is 3 s
	reportWait time.Duration
	reportOnce sync.Once
	reports    chan func()
	lastMu     sync.Mutex
	last       *Session // the session StartAsync started last
}

type Session struct {
	p *Player
	// client is the Player's when the session started: its reports go to
	// that server and account even after the app signs in elsewhere.
	client *plex.Client
	item   *plex.Item
	// opMu serializes player lifecycle changes and status reports. mu only
	// protects fields shared with readers such as UI state.
	opMu                     sync.Mutex
	mu                       sync.Mutex
	cmd                      *exec.Cmd
	cmdDone                  chan struct{}
	lf                       *os.File
	state                    plex.PlayState
	direct, started, closing bool
	pausePending             bool
	url                      string
	writeCommand             func(string)
	Done                     chan error
	reported                 chan struct{}
	async                    bool
	ctx                      context.Context
	cancel                   context.CancelFunc
	doneOnce                 sync.Once
	uiMu                     sync.Mutex
	uiQueue                  []string
	uiWake                   chan struct{}
	uiStop                   bool
	stopRequested            bool
	seekID                   uint64 // opMu owns the in-process seek sequence
	surroundSource           bool
	// forceTranscode makes every later PlaybackInfo of this session ask for a
	// transcode; fellBack records that the one automatic fallback was used.
	forceTranscode, fellBack bool
	// session is the playback's transcode session id (plex.NewSession),
	// made at the first start: seeks, track changes and the fallback reuse
	// it, and the stopped report ends it.
	session string
	// audioIndex is the file's index of the audio track a direct stream
	// plays (jfplay --audio), -1 to leave it to jfplay.
	audioIndex int
	// burned is the subtitle track the running stream has burned in, "-1"
	// for none (burnedSubtitle).
	burned string
	// kbps is the video cap More > Video bitrate chose during this session
	// (0: the Player's Kbps). It travels with the command, so the worker
	// never reads the settings the UI thread writes.
	kbps int
}

func (p *Player) Started(t time.Time) bool {
	st, err := os.Stat(p.Status)
	return err == nil && !st.ModTime().Before(t.Add(-time.Second))
}

func (p *Player) Reap() {
	entries, _ := os.ReadDir("/proc")
	owner := filepath.Clean(p.Binary)
	var owned []int
	for _, entry := range entries {
		pid, err := strconv.Atoi(entry.Name())
		if err != nil || pid == os.Getpid() {
			continue
		}
		env, err := os.ReadFile("/proc/" + entry.Name() + "/environ")
		if err == nil && ownedPlayer(env, owner) {
			_ = syscall.Kill(pid, syscall.SIGTERM)
			owned = append(owned, pid)
		}
	}
	if len(owned) != 0 {
		time.Sleep(300 * time.Millisecond)
	}
	for _, pid := range owned {
		env, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/environ")
		if err == nil && ownedPlayer(env, owner) {
			_ = syscall.Kill(pid, syscall.SIGKILL)
		}
	}
}

func ownedPlayer(env []byte, owner string) bool {
	for _, field := range strings.Split(string(env), "\x00") {
		if field == "MISTERZINE_JFPLAY_OWNER="+owner || field == "MISTERZINE_PLEX_OWNER="+owner {
			return true
		}
	}
	return false
}

func (p *Player) Start(item *plex.Item, offset int) (*Session, error) {
	if p.Access != nil {
		if err := p.Access(); err != nil {
			return nil, err
		}
	}
	client := p.Client
	if client == nil {
		return nil, fmt.Errorf("playback has no Plex client")
	}
	if offset < 0 {
		offset = item.ViewOffset
	}
	lf, err := os.OpenFile(p.LogTo, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return nil, fmt.Errorf("cannot open playback log: %w", err)
	}
	s := &Session{p: p, client: client, item: copyPlaybackItem(item), lf: lf, Done: make(chan error, 1), reported: make(chan struct{}), ctx: context.Background()}
	if err := s.startContext(offset, false, s.ctx); err != nil {
		lf.Close()
		return nil, err
	}
	go s.watch()
	return s, nil
}

// StartAsync brings playback up in the background. It returns a session at
// once so the caller can keep drawing its starting screen while the server
// prepares a transcode or a slow server answers PlaybackInfo.
func (p *Player) StartAsync(item *plex.Item, offset int) (*Session, error) {
	if p.Access != nil {
		if err := p.Access(); err != nil {
			return nil, err
		}
	}
	client := p.Client
	if client == nil {
		return nil, fmt.Errorf("playback has no Plex client")
	}
	if offset < 0 {
		offset = item.ViewOffset
	}
	lf, err := os.OpenFile(p.LogTo, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return nil, fmt.Errorf("cannot open playback log: %w", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	s := &Session{p: p, client: client, item: copyPlaybackItem(item), lf: lf, Done: make(chan error, 1), reported: make(chan struct{}), async: true, ctx: ctx, cancel: cancel, uiWake: make(chan struct{}, 1)}
	_ = os.Remove(p.Status) // never let a canceled start consume an old session's position.
	p.startReporter()
	// Reserve the lifecycle before publishing the session to command callers.
	// An immediate seek must wait for initial startup, not launch ahead of it.
	s.opMu.Lock()
	p.lastMu.Lock()
	prev := p.last
	p.last = s
	p.lastMu.Unlock()
	// only a start of the same part needs the last one's stopped report
	// first (awaitReports); the next episode or another item goes at once
	wait := prev != nil && samePart(prev.item, item)
	go s.runUICommands()
	go func() {
		if wait {
			p.awaitReports(ctx, prev)
		}
		err := s.startContext(offset, false, ctx)
		s.opMu.Unlock()
		if err != nil {
			s.opMu.Lock()
			s.finishLocked(s.suppressStopCancellation(err))
			s.opMu.Unlock()
			return
		}
		go s.watch()
	}()
	return s, nil
}

// awaitReports waits, a few seconds at most, for prev's stopped report. That
// report selects again the subtitle a transcode had the server burn in;
// landing after the next start's PlaybackInfo of the same part, it would
// undo the subtitle choice that start made.
func (p *Player) awaitReports(ctx context.Context, prev *Session) {
	wait := p.reportWait
	if wait <= 0 {
		wait = 3 * time.Second
	}
	timer := time.NewTimer(wait)
	defer timer.Stop()
	select {
	case <-prev.reported:
	case <-ctx.Done():
	case <-timer.C:
	}
}

// samePart reports whether two playbacks play the same media part: the
// part's own ID when both know it, else the item's. Neither changes during
// a session, so prev's item may be read while it runs.
func samePart(a, b *plex.Item) bool {
	if a.PartID != "" && b.PartID != "" {
		return a.PartID == b.PartID
	}
	return a.RatingKey == b.RatingKey
}

func copyPlaybackItem(item *plex.Item) *plex.Item {
	copy := *item
	copy.Audio = append([]plex.Stream(nil), item.Audio...)
	copy.Subs = append([]plex.Stream(nil), item.Subs...)
	copy.Markers = append([]plex.Marker(nil), item.Markers...)
	return &copy
}

func (p *Player) startReporter() {
	p.reportOnce.Do(func() {
		p.reports = make(chan func(), 64)
		go func() {
			for report := range p.reports {
				report()
			}
		}()
	})
}

func (p *Player) reportAsync(report func(), progress bool) {
	if progress {
		select {
		case p.reports <- report:
		default: // UI position updates may be skipped when the server is slow.
		}
		return
	}
	// Lifecycle reports are rare and must stay ordered. This send runs on a
	// session worker, never on the render/input goroutine.
	p.reports <- report
}

func selectedStreams(item *plex.Item) (audio, subtitle string) {
	for _, v := range item.Audio {
		if v.Selected {
			audio = v.ID
			break
		}
	}
	subtitle = "-1"
	for _, v := range item.Subs {
		if v.Selected {
			subtitle = v.ID
			break
		}
	}
	return
}

// burnedSubtitle is the subtitle track the server is to burn into the
// stream for the selected one: "-1" for none, and for a track the app
// draws itself, which leaves the stream free to play as stored.
func (s *Session) burnedSubtitle(selected string) string {
	if selected == "-1" || s.p.DrawsSubtitle == nil {
		return selected
	}
	for _, st := range s.item.Subs {
		if st.ID == selected && s.p.DrawsSubtitle(s.item.RatingKey, st) {
			return "-1"
		}
	}
	return selected
}

func (s *Session) startContext(offset int, reuseDirect bool, ctx context.Context) error {
	p := s.p
	// A replacement worker should inherit the session's pause state. A newly
	// created session starts with the zero value, so this also leaves startup
	// behavior unchanged.
	s.mu.Lock()
	paused := s.state.Paused
	s.mu.Unlock()
	audio, subtitle := selectedStreams(s.item)
	base, inFile := offset, 0
	if !reuseDirect {
		kbps := 0
		if p.Kbps != nil {
			kbps = p.Kbps()
		}
		s.mu.Lock()
		if s.kbps > 0 {
			kbps = s.kbps
		}
		force := s.forceTranscode
		s.mu.Unlock()
		burn := s.burnedSubtitle(subtitle)
		info, err := s.playbackInfo(ctx, kbps, offset, audio, burn, force)
		if err != nil {
			return err
		}
		if info.URL == "" {
			return fmt.Errorf("the server offered no stream for this item")
		}
		s.surroundSource = info.Part.Surround(audio)
		s.mu.Lock()
		// a transcode left behind for the file as stored (a track change that
		// stopped burning a subtitle in) is ended rather than left to time out
		retire := s.state.Transcode && info.Direct && s.state.Session != ""
		old := s.state.Session
		s.mu.Unlock()
		if retire {
			s.stopTranscode(old)
		}
		s.mu.Lock() // Direct reads it from the UI thread
		s.direct = info.Direct
		s.mu.Unlock()
		s.url = info.URL
		duration := float64(s.item.Duration)
		if duration <= 0 {
			duration = info.Part.Duration
		}
		// the report names the selected subtitle, drawn or burned in
		s.state = plex.PlayState{RatingKey: s.item.RatingKey, PartID: info.Part.ID, Session: info.Session, Position: float64(offset), Duration: duration, AudioStream: audio, SubtitleStream: subtitle, Transcode: !info.Direct, Paused: paused}
		s.burned = burn
		// Plex's stream IDs are the server's; jfplay's --audio takes the
		// track's index in the file
		s.audioIndex = -1
		if st := directAudio(info.Part, audio); s.direct && st != nil {
			s.audioIndex = st.Index
		}
	}
	if s.direct {
		base, inFile = 0, offset
	}
	args := []string{"--base", strconv.Itoa(base)}
	if inFile > 0 {
		args = append(args, "--start-in-file", strconv.Itoa(inFile))
	}
	if s.direct && s.audioIndex >= 0 {
		args = append(args, "--audio", strconv.Itoa(s.audioIndex))
	}
	if paused {
		args = append(args, "--hold")
	}
	if s.direct {
		// jfplay checks the stream before the first picture and watches that
		// the core keeps up; it exits 7 when a transcode is needed.
		args = append(args, "--direct")
	}
	args = append(args, "--fifo", p.Fifo, "--status", p.Status)
	// jfplay loads the app's own build of the core when another runs, and
	// counts a core of that name as its own
	args = append(args, "--rbf", ring.CoreFile(), "--core-name", ring.AppCoreName)
	if p.Boost != nil {
		if v := p.Boost(); v >= 100 && v <= 300 {
			args = append(args, "--audio-boost", strconv.Itoa(v))
		}
	}
	if !s.direct && s.surroundSource {
		args = append(args, "--surround-source")
	}
	if p.Crop != nil {
		args = append(args, "--analog-aspect", strconv.Itoa(p.Crop().analogAspect()))
	}
	if p.Geometry != nil {
		if geometry := p.Geometry(); geometry != "" {
			args = append(args, "--geometry", geometry)
		}
	}
	args = append(args, s.url)
	_ = os.Remove(p.Status)
	run := p.exec
	if run == nil {
		run = exec.Command
	}
	cmd := run(p.Binary, args...)
	output := &safelog.Writer{Out: s.lf, Secrets: []string{s.client.Token}}
	cmd.Stdout, cmd.Stderr = output, output
	// The headers carry the token, so they go in the environment (readable by
	// this user only), not on the command line (readable by every process).
	cmd.Env = append(os.Environ(), "MISTERZINE_JFPLAY_OWNER="+filepath.Clean(p.Binary),
		"JFPLAY_HEADERS="+s.client.StreamHeaders())
	s.mu.Lock()
	if ctx.Err() != nil || s.closing || s.stopRequested {
		s.mu.Unlock()
		return context.Canceled
	}
	if err := cmd.Start(); err != nil {
		s.mu.Unlock()
		return err
	}
	s.cmd = cmd
	done := make(chan struct{})
	s.cmdDone = done
	s.mu.Unlock()
	go func() {
		err := cmd.Wait()
		output.Flush()
		close(done)
		s.opMu.Lock()
		defer s.opMu.Unlock()
		s.mu.Lock()
		current, closing := s.cmd == cmd, s.closing
		s.mu.Unlock()
		if current && !closing {
			if s.fallbackLocked(err) {
				return
			}
			s.finishLocked(err)
		}
	}()
	return nil
}

// directAudio is the audio track a direct stream plays: the one chosen
// (a Stream.ID), else the part's selected one. nil leaves the choice to
// jfplay (the file's default), as for a track the file does not have.
func directAudio(part plex.MediaPart, audio string) *plex.MediaStream {
	if audio != "" {
		if st := part.Stream(audio); st != nil && st.Type == plex.StreamAudio {
			return st
		}
		return nil
	}
	for i := range part.Streams {
		if st := &part.Streams[i]; st.Type == plex.StreamAudio && st.Selected {
			return st
		}
	}
	return nil
}

// stopTranscode ends a transcode session the playback no longer uses, in
// order with the reports.
func (s *Session) stopTranscode(session string) {
	stop := func() { _ = s.client.StopTranscode(context.Background(), session) }
	if s.async {
		s.p.reportAsync(stop, false)
	} else {
		stop()
	}
}

// playbackPriority puts the calling thread at the ordinary priority for a
// playback and returns what puts it back. Run raises its locked thread
// (nice -5) for the menus, and the play loop runs on that thread: there it
// would outrank jfplay (nice 0), which feeds the decoder. A thread already
// at 0 (a test's, not locked to its goroutine) is left as it is.
func playbackPriority() (restore func()) {
	prio, err := syscall.Getpriority(syscall.PRIO_PROCESS, 0) // 20 - nice
	if err != nil || prio == 20 || syscall.Setpriority(syscall.PRIO_PROCESS, 0, 0) != nil {
		return func() {}
	}
	return func() { syscall.Setpriority(syscall.PRIO_PROCESS, 0, 20-prio) }
}

// readPlayerStatus is the worker's status file as keys and values, nil
// when there is none. The map is shared (playerStatus): read it only.
func readPlayerStatus(path string) map[string]string {
	values, _, err := playerStatus.read(path)
	if err != nil {
		return nil
	}
	return values
}

// playerStatus is the worker's status file as last read. The play loop
// asks for it ten times a second and the session four times, but jfplay
// writes it every 250 ms, each time whole into a new file renamed over
// the old: the same file (inode, size and time) has the same contents.
var playerStatus statusFiles

// statusSettle is how long after its time a file is taken as written: one
// read sooner might share a timestamp with a write still to come, were
// the file ever rewritten in place.
const statusSettle = 50 * time.Millisecond

type statusFiles struct {
	mu    sync.Mutex
	files map[string]statusFile
}

type statusFile struct {
	ino     uint64
	size    int64
	written time.Time
	values  map[string]string
}

// read is the status file at path, parsed, and when it was written; the
// file is read and parsed again only when it has changed since.
func (c *statusFiles) read(path string) (map[string]string, time.Time, error) {
	st, err := os.Stat(path)
	if err != nil {
		c.mu.Lock()
		delete(c.files, path)
		c.mu.Unlock()
		return nil, time.Time{}, err
	}
	c.mu.Lock()
	cached, ok := c.files[path]
	c.mu.Unlock()
	if ok && cached.ino == statusInode(st) && cached.size == st.Size() && cached.written.Equal(st.ModTime()) {
		return cached.values, cached.written, nil
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, time.Time{}, err
	}
	defer f.Close()
	if st, err = f.Stat(); err != nil {
		return nil, time.Time{}, err
	}
	data, err := io.ReadAll(f)
	if err != nil {
		return nil, time.Time{}, err
	}
	values := map[string]string{}
	for _, line := range strings.Split(string(data), "\n") {
		if k, v, ok := strings.Cut(line, "="); ok {
			values[k] = v
		}
	}
	file := statusFile{ino: statusInode(st), size: st.Size(), written: st.ModTime(), values: values}
	c.mu.Lock()
	if time.Since(file.written) > statusSettle {
		if c.files == nil {
			c.files = map[string]statusFile{}
		}
		c.files[path] = file
	} else {
		delete(c.files, path)
	}
	c.mu.Unlock()
	return values, file.written, nil
}

func statusInode(st os.FileInfo) uint64 {
	if s, ok := st.Sys().(*syscall.Stat_t); ok {
		return uint64(s.Ino)
	}
	return 0
}

func (s *Session) update(report bool) {
	s.opMu.Lock()
	defer s.opMu.Unlock()
	s.updateLocked(report)
}

func (s *Session) updateLocked(report bool) {
	st := readPlayerStatus(s.p.Status)
	if st == nil {
		return
	}
	s.mu.Lock()
	if s.closing {
		s.mu.Unlock()
		return
	}
	if p, e := strconv.ParseFloat(st["position"], 64); e == nil {
		s.state.Position = p
	}
	if s.state.Duration <= 0 {
		// an item known without its length: the worker's, so the stopped
		// report can tell a film watched to the end
		if d, e := strconv.ParseFloat(st["duration"], 64); e == nil && d > 0 {
			s.state.Duration = d
		}
	}
	statusPaused := st["state"] == "paused"
	if s.pausePending {
		if statusPaused == s.state.Paused {
			s.pausePending = false // the worker has caught up with the last command
		}
	} else {
		s.state.Paused = statusPaused
	}
	state, started, ps := st["state"], s.started, s.state
	if state == "playing" && !s.started {
		s.started = true
	}
	s.mu.Unlock()
	if state == "playing" && !started {
		s.reportStart(ps)
	} else if report && started {
		s.reportProgress(ps)
	}
}

func (s *Session) reportStart(ps plex.PlayState) {
	if s.async {
		s.p.reportAsync(func() { _ = s.client.ReportStart(context.Background(), ps) }, false)
	} else {
		_ = s.client.ReportStart(context.Background(), ps)
	}
}

func (s *Session) reportProgress(ps plex.PlayState) {
	if s.async {
		s.p.reportAsync(func() { _ = s.client.ReportProgress(context.Background(), ps) }, true)
	} else {
		_ = s.client.ReportProgress(context.Background(), ps)
	}
}

func (s *Session) watch() {
	tick := time.NewTicker(250 * time.Millisecond)
	progress := time.NewTicker(10 * time.Second)
	defer tick.Stop()
	defer progress.Stop()
	for {
		select {
		case <-tick.C:
			s.mu.Lock()
			closing := s.closing
			s.mu.Unlock()
			if closing {
				return
			}
			s.update(false)
		case <-progress.C:
			s.update(true)
		}
	}
}

func (s *Session) write(line string) {
	if s.writeCommand != nil {
		s.writeCommand(line)
		return
	}
	f, err := os.OpenFile(s.p.Fifo, os.O_WRONLY|syscall.O_NONBLOCK, 0)
	if err == nil {
		_ = f.SetWriteDeadline(time.Now().Add(200 * time.Millisecond))
		_, _ = fmt.Fprintln(f, line)
		_ = f.Close()
	}
}

func (s *Session) Send(line string) {
	s.opMu.Lock()
	defer s.opMu.Unlock()
	s.mu.Lock()
	closing := s.closing || s.stopRequested
	s.mu.Unlock()
	if closing {
		return
	}
	fields := strings.Fields(line)
	if len(fields) == 2 && fields[0] == "boost" {
		if gain, err := strconv.Atoi(fields[1]); err == nil && gain >= 100 && gain <= 300 {
			s.write("boost " + strconv.Itoa(gain))
		}
		return
	}
	if len(fields) == 2 && fields[0] == "seek" {
		target, err := strconv.ParseFloat(fields[1], 64)
		if err != nil || target < 0 || math.IsNaN(target) || math.IsInf(target, 0) {
			return
		}
		s.updateLocked(false)
		s.mu.Lock()
		s.state.Position = target
		ps := s.state
		s.mu.Unlock()
		s.reportProgress(ps)
		if s.tryWorkerSeek(target) {
			return
		}
		if s.sessionContext().Err() != nil {
			return
		}
		s.stopProcessLocked()
		_ = os.Remove(s.p.Status) // retire the old position before a slow restart.
		s.mu.Lock()
		reuse := s.direct
		s.started = false
		s.mu.Unlock()
		err = s.startContext(int(target), reuse, s.sessionContext())
		if err != nil {
			s.finishLocked(s.suppressStopCancellation(err))
		}
		return
	}
	if len(fields) == 3 && fields[0] == "bitrate" {
		// More > Video bitrate: a new PlaybackInfo with the new cap, at
		// the position the UI had, the tracks as they are
		kbps, e1 := strconv.Atoi(fields[1])
		target, e2 := strconv.ParseFloat(fields[2], 64)
		if e1 != nil || e2 != nil || kbps <= 0 || target < 0 || math.IsNaN(target) || math.IsInf(target, 0) {
			return
		}
		s.updateLocked(false)
		s.mu.Lock()
		s.kbps = kbps
		s.state.Position = target
		ps := s.state
		s.mu.Unlock()
		s.reportProgress(ps)
		if s.sessionContext().Err() != nil {
			return
		}
		s.stopProcessLocked()
		_ = os.Remove(s.p.Status)
		s.mu.Lock()
		s.started = false
		s.mu.Unlock()
		if err := s.startContext(int(target), false, s.sessionContext()); err != nil {
			s.finishLocked(s.suppressStopCancellation(err))
		}
		return
	}
	if len(fields) == 4 && fields[0] == "tracks" {
		target, err := strconv.ParseFloat(fields[3], 64)
		if err != nil || target < 0 || math.IsNaN(target) || math.IsInf(target, 0) || !validStreamID(fields[1]) || !validStreamID(fields[2]) {
			return
		}
		s.updateLocked(false)
		s.item.Audio = setStreamID(s.item.Audio, fields[1])
		s.item.Subs = setStreamID(s.item.Subs, fields[2])
		audio := fields[1]
		if audio == "-1" {
			audio = ""
		}
		burn := s.burnedSubtitle(fields[2])
		s.mu.Lock()
		// The stream as it runs serves the new choice when the sound is the
		// same and so is what it has burned in: only a subtitle the app
		// draws changed (or one it draws went off).
		keep := s.cmd != nil && audio == s.state.AudioStream && burn == s.burned
		if !keep {
			s.state.Position = target
		}
		s.state.AudioStream = audio
		s.state.SubtitleStream = fields[2]
		ps := s.state
		s.mu.Unlock()
		s.reportProgress(ps)
		if keep {
			return
		}
		s.stopProcessLocked()
		_ = os.Remove(s.p.Status)
		s.mu.Lock()
		s.started = false
		s.mu.Unlock()
		// A track choice needs a new PlaybackInfo even for direct streams: it
		// selects the part's tracks on the server and may change the URL.
		if err := s.startContext(int(target), false, s.sessionContext()); err != nil {
			s.finishLocked(s.suppressStopCancellation(err))
		}
		return
	}
	if line == "toggle" || line == "pause" || line == "resume" || line == "stop" || strings.HasPrefix(line, "aspect ") {
		if line == "stop" || strings.HasPrefix(line, "aspect ") {
			s.write(line)
			return
		}
		// Read the current status before sending toggle: the child may update
		// its status as soon as it receives the command.
		s.updateLocked(false)
		s.mu.Lock()
		if line == "pause" {
			s.state.Paused = true
		} else if line == "resume" {
			s.state.Paused = false
		} else {
			s.state.Paused = !s.state.Paused
		}
		s.pausePending = true
		ps := s.state
		s.mu.Unlock()
		s.write(line)
		s.reportProgress(ps)
	}
}

// tryWorkerSeek keeps the open media session when the worker advertises support.
// A bounded acknowledgement wait runs on the command worker, never the UI loop.
// Old workers and failed seeks use the existing process-restart path.
func (s *Session) tryWorkerSeek(target float64) bool {
	if !s.direct {
		return false // a transcode restarts at the new offset on its session.
	}
	status := readPlayerStatus(s.p.Status)
	if status["seek_supported"] != "1" {
		return false
	}
	s.seekID++
	id := strconv.FormatUint(s.seekID, 10)
	s.write("seek " + id + " " + strconv.FormatFloat(target, 'f', 3, 64))
	timer := time.NewTimer(8 * time.Second)
	defer timer.Stop()
	poll := time.NewTicker(25 * time.Millisecond)
	defer poll.Stop()
	s.mu.Lock()
	done := s.cmdDone
	s.mu.Unlock()
	for {
		select {
		case <-s.sessionContext().Done():
			return false
		case <-done:
			return false
		case <-timer.C:
			return false
		case <-poll.C:
			status = readPlayerStatus(s.p.Status)
			if status["seek_id"] != id {
				continue
			}
			switch status["seek_state"] {
			case "ready":
				return true
			case "error":
				return false
			}
		}
	}
}

func validStreamID(id string) bool {
	if id == "-1" {
		return true
	}
	index, err := strconv.Atoi(id)
	return err == nil && index >= 0
}

func setStreamID(streams []plex.Stream, id string) []plex.Stream {
	found := id == "-1"
	for i := range streams {
		streams[i].Selected = id != "-1" && streams[i].ID == id
		found = found || streams[i].Selected
	}
	if id != "-1" && !found {
		streams = append(streams, plex.Stream{ID: id, Selected: true})
	}
	return streams
}

func (s *Session) sessionContext() context.Context {
	if s.ctx != nil {
		return s.ctx
	}
	return context.Background()
}

// StopUI cancels startup and replacement requests. Treat only that explicit
// cancellation as a clean end; other startup errors still reach the caller.
func (s *Session) suppressStopCancellation(err error) error {
	if !errors.Is(err, context.Canceled) {
		return err
	}
	s.mu.Lock()
	stopRequested := s.stopRequested
	s.mu.Unlock()
	if stopRequested {
		return nil
	}
	return err
}

// ReportsDone closes after this session's stopped report has been sent.
// UI refreshes can wait in the background before reading resume metadata.
func (s *Session) ReportsDone() <-chan struct{} { return s.reported }

// FinalPosition is where the playback stood when it was last read and the
// length its reports carry, in seconds: once Done has fired, what its
// stopped report gives the server. False when the playback never started
// playing.
func (s *Session) FinalPosition() (pos, dur float64, ok bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.state.Position, s.state.Duration, s.started
}

// Direct reports whether the stream plays the file as stored rather than a
// transcode. A track change or the fallback to a transcode can change it.
func (s *Session) Direct() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.direct
}

// SendUI queues a command for the session worker and returns immediately.
// Repeated seeks coalesce to the newest target, keeping rapid input bounded.
func (s *Session) SendUI(line string) {
	if !s.async {
		s.Send(line)
		return
	}
	fields := strings.Fields(line)
	seek := len(fields) == 2 && fields[0] == "seek"
	s.uiMu.Lock()
	if s.uiStop {
		s.uiMu.Unlock()
		return
	}
	if seek && len(s.uiQueue) > 0 && strings.HasPrefix(s.uiQueue[len(s.uiQueue)-1], "seek ") {
		s.uiQueue[len(s.uiQueue)-1] = line
		s.uiMu.Unlock()
		s.signalUI()
		return
	}
	if len(s.uiQueue) >= 8 {
		if seek {
			s.uiMu.Unlock()
			return
		}
		for i, queued := range s.uiQueue {
			if strings.HasPrefix(queued, "seek ") {
				s.uiQueue = append(s.uiQueue[:i], s.uiQueue[i+1:]...)
				break
			}
		}
		if len(s.uiQueue) >= 8 {
			s.uiMu.Unlock()
			return
		}
	}
	s.uiQueue = append(s.uiQueue, line)
	s.uiMu.Unlock()
	s.signalUI()
}

func (s *Session) StopUI() {
	if !s.async {
		s.Stop()
		return
	}
	s.mu.Lock()
	s.stopRequested = true // prevents a pending seek from starting a replacement.
	s.mu.Unlock()
	if s.cancel != nil {
		s.cancel()
	}
	s.uiMu.Lock()
	s.uiStop = true
	s.uiQueue = nil
	s.uiMu.Unlock()
	s.signalUI()
}

func (s *Session) signalUI() {
	select {
	case s.uiWake <- struct{}{}:
	default:
	}
}

func (s *Session) runUICommands() {
	for range s.uiWake {
		for {
			s.uiMu.Lock()
			if s.uiStop {
				s.uiMu.Unlock()
				s.Stop()
				return
			}
			if len(s.uiQueue) == 0 {
				s.uiMu.Unlock()
				break
			}
			line := s.uiQueue[0]
			s.uiQueue = s.uiQueue[1:]
			s.uiMu.Unlock()
			s.Send(line)
		}
	}
}

func (s *Session) stopProcessLocked() {
	s.mu.Lock()
	cmd := s.cmd
	done := s.cmdDone
	s.cmd = nil
	s.cmdDone = nil
	s.mu.Unlock()
	if cmd == nil || cmd.Process == nil {
		return
	}
	s.write("stop")
	if done == nil {
		return
	}
	grace := s.p.stopGrace
	if grace <= 0 {
		grace = 3 * time.Second
	}
	timer := time.NewTimer(grace)
	defer timer.Stop()
	select {
	case <-done:
		return
	case <-timer.C:
	}
	_ = cmd.Process.Kill()
	<-done
}

func (s *Session) finishLocked(err error) {
	s.mu.Lock()
	if s.closing {
		s.mu.Unlock()
		return
	}
	s.mu.Unlock()
	s.updateLocked(false)
	s.mu.Lock()
	if s.closing {
		s.mu.Unlock()
		return
	}
	s.closing = true
	ps := s.state
	s.mu.Unlock()
	if s.async {
		s.uiMu.Lock()
		s.uiStop = true
		s.uiQueue = nil
		s.uiMu.Unlock()
		s.signalUI() // retire the command worker on natural exit and startup failure.
	}
	if s.async {
		// Queue the terminal report before releasing Done so a subsequent
		// session's start report cannot overtake it.
		if ps.Session != "" {
			s.p.reportAsync(func() {
				_ = s.client.ReportStopped(context.Background(), ps)
				close(s.reported)
			}, false)
		} else {
			close(s.reported)
		}
	} else {
		_ = s.client.ReportStopped(context.Background(), ps)
		close(s.reported)
	}
	_ = s.lf.Close()
	s.doneOnce.Do(func() { s.Done <- err })
}

func (s *Session) Stop() {
	s.opMu.Lock()
	defer s.opMu.Unlock()
	s.mu.Lock()
	closing := s.closing
	s.mu.Unlock()
	if closing {
		return
	}
	s.stopProcessLocked()
	s.finishLocked(nil)
}
