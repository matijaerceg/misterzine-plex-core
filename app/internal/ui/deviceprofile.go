package ui

import "plexcrt/internal/plex"

// The H.264 decoder core's limits as the server is asked for them. The FPGA
// decodes H.264 High or Main profile, 8-bit 4:2:0, up to 1280x720 at 30
// frames/s or 854x480 at 60, and falls behind above about 8 Mbit/s at 720p;
// jfplay decodes the audio and downmixes it to stereo. Everything else is a
// server transcode to the same limits, which internal/plex asks for through
// the client profile (plex.ProfileExtra). Subtitles asked of the server
// (picture tracks, and text the app cannot draw: subtitles.go) are burned
// into the transcode.

// MaxVideoKbps is the most the core decodes comfortably at 720p.
const MaxVideoKbps = plex.MaxVideoKbps

// transcodeSize is the largest picture a transcode at a video cap in kbit/s
// is made at: 480p below 3 Mbit/s, 360p below 1 Mbit/s, else 720p.
func transcodeSize(videoKbps int) (w, h int) { return plex.TranscodeSize(videoKbps) }
