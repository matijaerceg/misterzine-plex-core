package plex

import (
	"fmt"
	"math"
)

// TranscodeSourceGeometry is the original size and display shape for the
// worker's stale-SAR check. Only an explicit video transcode gets this hint;
// direct playback and video copied during audio conversion keep their tags.
func (p PlaybackInfo) TranscodeSourceGeometry() string {
	if p.Direct || p.VideoCopy || p.VideoDecision != "transcode" {
		return ""
	}
	v := p.Part.Video()
	a := p.Part.Aspect
	if v == nil || v.Width <= 0 || v.Width > 65535 || v.Height <= 0 || v.Height > 65535 ||
		math.IsNaN(a) || math.IsInf(a, 0) || a < 0.05 || a > 20 {
		return ""
	}
	return fmt.Sprintf("%d,%d,%.6f", v.Width, v.Height, a)
}
