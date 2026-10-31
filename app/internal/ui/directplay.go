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
	return code == workerExitNeedsTranscode || code == workerExitRefused
}

// jfplay exit codes the app acts on (arm/jfplay.md).
const (
	workerExitRefused        = 5 // the core refused the stream
	workerExitNeedsTranscode = 7 // the pre-check or the watchdog said transcode
	workerExitOpenTimeout    = 8 // the stream sent nothing while it was being opened
	// workerExitNoPicture: the core decoded pictures but showed none. A
	// patron's 1280x720 Intel hardware transcodes did this while the same
	// server's 854x480 ones played, so the app retries at that size once
	// (noPictureFallbackLocked).
	workerExitNoPicture = 9
)

// A transcode started at an offset is given openTimeout to send its first
// bytes; a server that takes the request and sends nothing (a seek its
// hardware decoder never finishes) ends playback then (workerExitError)
// rather than at the socket's own limit (60 s), which stays for the rest.
const openTimeout = 20 * time.Second

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
// (the pre-check failed, the core refused it, or it could not keep up) with a
// server transcode at the same position. It runs at most once a session, so
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
	s.restartTranscodeLocked("direct stream needs a transcode (jfplay exit %d); restarting at %.3f s", code)
	return true
}

// noPictureFallbackLocked replaces a stream the core decoded but never
// showed (jfplay exit 9) with a transcode of at most 854x480 at the same
// position: a patron's server made 1280x720 transcodes with an Intel
// hardware encoder that the core never showed, while its 854x480 ones
// played. Every later start of the session stays at that size, so it runs
// at most once a session and a small transcode that fails in turn ends
// playback with its error. It reports whether it took over the worker's
// exit; opMu is held.
func (s *Session) noPictureFallbackLocked(err error) bool {
	code := workerExitCode(err)
	if code != workerExitNoPicture {
		return false
	}
	s.mu.Lock()
	if s.smallTranscode || s.closing || s.stopRequested {
		s.mu.Unlock()
		return false
	}
	s.smallTranscode = true
	s.mu.Unlock()
	s.restartTranscodeLocked("no picture shown (jfplay exit %d); restarting at %.3f s as a transcode of at most 854x480", code)
	return true
}

// restartTranscodeLocked starts the session's item again as a transcode at
// the finished worker's position, logging why (a format taking the exit code
// and the position). opMu is held.
func (s *Session) restartTranscodeLocked(why string, code int) {
	s.updateLocked(false) // the worker's final position
	s.mu.Lock()
	ps, started := s.state, s.started
	s.started = false
	s.forceTranscode = true
	s.cmd, s.cmdDone = nil, nil
	s.mu.Unlock()
	s.logf(why, code, ps.Position)
	if started && ps.Session != "" {
		// end the stream's play session; the transcode reports its own start
		if s.async {
			s.p.reportAsync(func() { _ = s.client.ReportStopped(context.Background(), ps) }, false)
		} else {
			_ = s.client.ReportStopped(context.Background(), ps)
		}
	}
	_ = os.Remove(s.p.Status)
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
// decoded but never showed, after the small transcode retry was used. The
// playback log says so for the report; the error carries the worker's exit.
// Other errors pass through unchanged.
func (s *Session) workerExitError(err error) error {
	switch code := workerExitCode(err); code {
	case workerExitOpenTimeout:
		s.logf("stream open timed out (jfplay exit %d): the server accepted the request but sent no video", code)
		return noVideoError{err}
	case workerExitNoPicture:
		s.logf("no picture shown (jfplay exit %d): the core decoded the video but showed none", code)
		return noPictureError{err}
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
