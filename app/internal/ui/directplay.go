package ui

import (
	"context"
	"errors"
	"fmt"
	"math"
	"os"
	"os/exec"
	"time"

	"plexcrt/internal/plex"
)

// Direct-stream eligibility: whether a file the server would send as stored
// is one the H.264 core can certainly play in real time. internal/plex decides
// it (plex.DirectEligible) from the metadata Plex probed, the core's own limits
// and the user's bitrate setting: a file above the chosen cap is transcoded to
// it, as the cap is there for a link that cannot carry more. What the
// metadata cannot say (CAVLC or CABAC when the server does not know, MBAFF or
// PAFF) jfplay checks before the first picture (--direct), and the app falls
// back to a transcode when it says no (fallbackLocked).

// workerNeedsTranscode reports whether a jfplay exit status asks for the same
// item to be played again as a server transcode.
func workerNeedsTranscode(code int) bool {
	return code == workerExitNeedsTranscode || code == workerExitRefused || code == workerExitTooLarge
}

// jfplay exit codes the app acts on (arm/jfplay.md).
const (
	// workerExitOpenFailed: the stream could not be opened. A patron's
	// server closed the small transcode's first connection without a byte
	// while it was still tearing down the transcoder the core showed no
	// picture of, so the app opens it once more (smallOpenRetryLocked).
	workerExitOpenFailed     = 4
	workerExitRefused        = 5 // the core refused the stream
	workerExitNeedsTranscode = 7 // the pre-check or the watchdog said transcode
	workerExitOpenTimeout    = 8 // the stream sent nothing while it was being opened
	// workerExitNoPicture: the core decoded pictures but showed none. A
	// patron's 1280x720 Intel hardware transcodes did this while the same
	// server's 854x480 ones played, so the app retries at that size once
	// (noPictureFallbackLocked).
	workerExitNoPicture = 9
	// workerExitTooLarge: the core is dropping the pictures as larger than
	// it decodes, which it shows nowhere but a counter jfplay watches. A
	// direct stream is replaced by a transcode (fallbackLocked) and a
	// transcode by the small one (noPictureFallbackLocked): an Intel hardware
	// encoder codes 1280x720 as 1280x736, above an older core's bound.
	workerExitTooLarge = 10
)

// A transcode started at an offset is given openTimeout to send its first
// bytes; a server that takes the request and sends nothing (a seek its
// hardware decoder never finishes) ends playback then (workerExitError)
// rather than at the socket's own limit (60 s), which stays for the rest.
const openTimeout = 20 * time.Second

// noPictureRestartDelay is how long the app waits before it asks for the
// small transcode, and again before it opens that once more: the server
// replaces the session's transcoder on the new decision, and a patron's
// server answered a request made 200 ms after the old worker was killed by
// closing the connection with no bytes, its hardware transcoder most likely
// still being torn down.
const noPictureRestartDelay = 1500 * time.Millisecond

// noPictureOpenRetryWindow is how soon after its start a small transcode's
// worker must fail to open (jfplay exit 4) for the app to open it once more:
// a failure later than that is not the server still busy with the old
// transcoder.
const noPictureOpenRetryWindow = 15 * time.Second

// noPictureSleep waits before a small transcode starts; tests replace it.
var noPictureSleep = time.Sleep

// playbackInfo asks the server how to play the session's item. The request
// lets internal/plex offer the file as stored unless a transcode is already
// required (a subtitle to burn in, or force); a transcode is always asked for
// at the user's bitrate setting. Every start of a session uses the session's
// one transcode session id, so a seek or a track change re-issues the
// decision on it and the server replaces its transcoder. small asks for a
// transcode of at most 854x480 (noPictureFallbackLocked), which is always a
// transcode.
func (s *Session) playbackInfo(ctx context.Context, kbps, offset int, audio, subtitle string, force, small bool) (*plex.PlaybackInfo, error) {
	if small {
		force = true
	}
	p := s.p
	size := 0
	if p.SubtitleSize != nil {
		size = p.SubtitleSize()
	}
	s.mu.Lock()
	if s.session == "" {
		s.session = plex.NewSession()
	}
	session := s.session
	s.mu.Unlock()
	// jfplay applies the surround gain itself (--audio-boost with
	// --surround-source), so the server's downmix is asked for at 100 %:
	// the gain stays live (Send "boost") and is never applied twice.
	req := plex.PlaybackRequest{RatingKey: s.item.RatingKey, Session: session, StartSeconds: float64(offset),
		VideoKbps: kbps, AudioStream: audio, SubtitleStream: subtitle, SubtitleSize: size, AudioBoost: 100,
		ForceTranscode: force, SmallTranscode: small, MediaID: s.item.VersionID, Part: s.part}
	if force && !p.directPlay() {
		req.ForceReason = "Direct play off"
	}
	s.part = nil // the start's read only: a restart reads the selection afresh
	s.logf("playback request: offset=%d s cap=%d kbit/s force_transcode=%t small_transcode=%t", offset, kbps, force, small)
	decisionStart := time.Now()
	info, err := s.client.PlaybackInfo(ctx, req)
	s.logf("playback decision: elapsed_ms=%d success=%t", time.Since(decisionStart).Milliseconds(), err == nil)
	if err != nil {
		return nil, err
	}
	if info.VideoCopy {
		s.logf("audio-only conversion: original video, server stereo AAC")
		return info, nil
	}
	if info.Direct {
		if v := info.Part.Video(); v != nil && v.ScanType == "interlaced" {
			s.logf("direct stream is interlaced; jfplay checks for MBAFF before playing")
		}
		return info, nil
	}
	if subtitle == "-1" && !force {
		ok, why := plex.DirectEligible(info.Part, kbps)
		if ok {
			ok, why = plex.DirectAudioEligible(info.Part, audio)
		}
		if !ok {
			s.logf("direct stream not eligible (%s); requesting a transcode", why)
		}
	}
	if kbps <= 0 || kbps > MaxVideoKbps {
		kbps = MaxVideoKbps
	}
	s.logf("transcode: %s (%dx%d, at most %d kbit/s)", info.Decision, info.Width, info.Height, kbps)
	return info, nil
}

// logf writes an app line into the playback log, beside jfplay's output.
func (s *Session) logf(format string, args ...any) {
	if s.lf != nil {
		_, _ = fmt.Fprintf(s.lf, "app: "+format+"\n", args...)
	}
}

// fallbackLocked replaces a direct stream whose worker asked for a transcode
// (the pre-check failed, the core refused it, dropped its pictures as too
// large, or could not keep up) with a server transcode at the same position. It runs at most once a session, so
// a transcode that fails in turn ends playback with its error. It reports
// whether it took over the worker's exit; opMu is held.
func (s *Session) fallbackLocked(err error) bool {
	code := workerExitCode(err)
	if !workerNeedsTranscode(code) {
		return false
	}
	s.mu.Lock()
	if (!s.direct && !s.videoCopy) || s.fellBack || s.closing || s.stopRequested {
		s.mu.Unlock()
		return false
	}
	s.fellBack = true
	s.mu.Unlock()
	s.restartTranscodeLocked(0, "direct stream needs a transcode (jfplay exit %d); restarting at %.3f s", code)
	return true
}

// noPictureFallbackLocked replaces a stream the core decoded but never
// showed (jfplay exit 9), or a transcode whose pictures it dropped as too
// large (exit 10), with a transcode of at most 854x480 at the same
// position: a patron's server made 1280x720 transcodes with an Intel
// hardware encoder that the core never showed, while its 854x480 ones
// played. Every later start of the session stays at that size, so it runs
// at most once a session and a small transcode that fails in turn ends
// playback with its error. It reports whether it took over the worker's
// exit; opMu is held.
func (s *Session) noPictureFallbackLocked(err error) bool {
	code := workerExitCode(err)
	why := "no picture shown"
	switch code {
	case workerExitNoPicture:
	case workerExitTooLarge:
		why = "pictures too large for the core"
	default:
		return false
	}
	s.mu.Lock()
	if s.smallTranscode || s.closing || s.stopRequested {
		s.mu.Unlock()
		return false
	}
	s.smallTranscode = true
	s.mu.Unlock()
	s.restartTranscodeLocked(noPictureRestartDelay, "%s (jfplay exit %d); restarting at %.3f s as a transcode of at most 854x480", why, code)
	return true
}

// smallOpenRetryLocked opens a small transcode once more when its worker
// could not open the stream (jfplay exit 4) soon after it started: the
// server that showed no picture took the new decision but closed the first
// connection without a byte, still tearing down its old transcoder. It runs
// at most once a session, after the same wait, so a second failure ends
// playback with its error. It reports whether it took over the worker's
// exit; opMu is held.
func (s *Session) smallOpenRetryLocked(err error) bool {
	code := workerExitCode(err)
	if code != workerExitOpenFailed {
		return false
	}
	s.mu.Lock()
	ran := time.Since(s.startedAt)
	if !s.smallTranscode || s.smallRetried || s.closing || s.stopRequested || ran > noPictureOpenRetryWindow {
		s.mu.Unlock()
		return false
	}
	s.smallRetried = true
	s.mu.Unlock()
	s.restartTranscodeLocked(noPictureRestartDelay, "small transcode did not open (jfplay exit %d) %.1f s after its start; starting it once more at %.3f s", code, ran.Seconds())
	return true
}

// restartTranscodeLocked starts the session's item again as a transcode at
// the finished worker's position, logging why: a format taking args and
// then the position. A wait above zero gives the server that long before the
// new decision, unless playback is stopped meanwhile. opMu is held.
func (s *Session) restartTranscodeLocked(wait time.Duration, why string, args ...any) {
	s.updateLocked(false) // the worker's final position
	s.mu.Lock()
	ps, started := s.state, s.started
	s.started = false
	s.forceTranscode = true
	s.cmd, s.cmdDone = nil, nil
	s.mu.Unlock()
	s.logf(why, append(args, ps.Position)...)
	if started && ps.Session != "" {
		// end the stream's play session; the transcode reports its own start
		if s.async {
			s.p.reportAsync(func() { _ = s.client.ReportStopped(context.Background(), ps) }, false)
		} else {
			_ = s.client.ReportStopped(context.Background(), ps)
		}
	}
	_ = os.Remove(s.p.Status)
	if wait > 0 {
		s.mu.Lock()
		stopping := s.closing || s.stopRequested
		s.mu.Unlock()
		if stopping {
			return
		}
		noPictureSleep(wait)
		// a stop asked for during the wait ends the session without a restart:
		// Stop finishes it once it has opMu
		s.mu.Lock()
		stopping = s.closing || s.stopRequested
		s.mu.Unlock()
		if stopping {
			return
		}
	}
	// startContext takes whole seconds: round to nearest rather than truncate
	if err := s.startContext(int(math.Round(ps.Position)), false, s.sessionContext()); err != nil {
		s.finishLocked(s.suppressStopCancellation(err))
	}
}

// workerExitCode is a worker's exit status, -1 when it did not exit with one.
func workerExitCode(err error) int {
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		return ee.ExitCode()
	}
	return -1
}

// workerExitError words a worker exit that ends the session. jfplay exit 8
// is a stream that sent nothing while it was being opened: the server took
// the request and answered with no video. Exit 9 is a stream the core
// decoded but never showed, and exit 10 one whose pictures it dropped as too
// large, after the small transcode retry was used. The playback log says so
// for the report; the error carries the worker's exit. Other errors pass
// through unchanged.
func (s *Session) workerExitError(err error) error {
	switch code := workerExitCode(err); code {
	case workerExitOpenTimeout:
		s.logf("stream open timed out (jfplay exit %d): the server accepted the request but sent no video", code)
		return noVideoError{err}
	case workerExitNoPicture:
		s.logf("no picture shown (jfplay exit %d): the core decoded the video but showed none", code)
		return noPictureError{err}
	case workerExitTooLarge:
		s.logf("pictures too large (jfplay exit %d): the core dropped them as larger than it decodes", code)
		return tooLargeError{err}
	}
	return err
}

// noVideoError is the failure line for a stream that never came.
type noVideoError struct{ err error }

func (e noVideoError) Error() string {
	return "The server accepted the request but sent no video"
}
func (e noVideoError) Unwrap() error { return e.err }

// noPictureError is the failure line for a stream the core never showed.
type noPictureError struct{ err error }

func (e noPictureError) Error() string {
	return "The video was received but the decoder showed no picture"
}
func (e noPictureError) Unwrap() error { return e.err }

// tooLargeError is the failure line for a stream whose pictures the core dropped.
type tooLargeError struct{ err error }

func (e tooLargeError) Error() string {
	return "The video is larger than the decoder can show"
}
func (e tooLargeError) Unwrap() error { return e.err }
