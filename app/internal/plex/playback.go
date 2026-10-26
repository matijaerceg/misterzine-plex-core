package plex

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/xml"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
)

// Playback: which stream jfplay opens (PlaybackInfo), the transcode session
// behind it, and reporting what plays (/:/timeline). The file plays as
// stored when the H.264 core can certainly decode it (DirectEligible); the
// server converts everything else to a progressive H.264 Matroska over
// plain HTTP, capped at the core's limits through the Plex Web client
// profile plus X-Plex-Client-Profile-Extra.

// Stream types of a part, as Plex numbers them.
const (
	StreamVideo    = 1
	StreamAudio    = 2
	StreamSubtitle = 3
)

// MaxVideoKbps is the most the core decodes comfortably at 720p.
const MaxVideoKbps = 8000

// The core's limits for a file played as stored. Plex's metadata cannot say
// CAVLC or CABAC for sure, or MBAFF or PAFF; jfplay checks the SPS/PPS
// before the first picture (--direct) and the app falls back to a transcode
// when it says no. Values the server does not know are therefore not held
// against a file; only known out-of-range values are.
const (
	// directMaxKbpsHD is the highest average bitrate accepted for a direct
	// stream wider than directSDWidth (720p class). The core sustains about
	// 8 Mbit/s at 720p; the margin covers peaks above the average.
	directMaxKbpsHD = 6000
	// directMaxKbpsSD is the cap for directSDWidth wide and narrower.
	directMaxKbpsSD = 8000
	// directSDWidth is the widest picture the core decodes at 60 frames/s.
	directSDWidth = 854
	// Match the worker: at most 80 blocks wide and 3,600 16x16 blocks per picture.
	// Cropped dimensions are rounded up; jfplay checks the actual SPS before decoding.
	directMaxWidth, directMaxBlocks = 1280, 3600
	directMaxBlockRate              = 108000
	// directMaxFPSSD / directMaxFPSHD are the frame-rate limits for the two
	// size classes; directFPSSlack absorbs 29.97-style rounding in metadata.
	directMaxFPSSD, directMaxFPSHD, directFPSSlack = 60.0, 30.0, 0.5
	// directMaxLevel is H.264 level 4.1, as Plex reports it (41).
	directMaxLevel = 41
)

// TranscodeSize is the largest picture a transcode at a video cap in kbit/s
// is made at. The CRT shows at most 576 lines, so a low cap spends its bits
// on fewer pixels rather than on a blocky 720p: 480p below 3 Mbit/s, 360p
// below 1 Mbit/s. At 854 wide or less the core keeps 60 frames/s.
func TranscodeSize(videoKbps int) (w, h int) {
	switch {
	case videoKbps < 1000:
		return 640, 360
	case videoKbps < 3000:
		return 854, 480
	}
	return 1280, 720
}

// MediaPart is one file of an item's first media version, with its probed
// streams.
type MediaPart struct {
	ID        string
	Key       string // "/library/parts/<id>/<mtime>/file.<ext>": the file as stored
	Container string
	Duration  float64 // seconds
	Bitrate   int     // the version's total, kbit/s
	// FrameRateTag is the version's videoFrameRate: 24p, NTSC, PAL, 50p, 60p.
	FrameRateTag string
	Streams      []MediaStream
}

// MediaStream is a stream of a part with the details Plex probed; zero
// when the server does not know.
type MediaStream struct {
	ID       string
	Type     int // StreamVideo, StreamAudio, StreamSubtitle
	Index    int // the container's stream index (jfplay --audio)
	Codec    string
	Selected bool
	Default  bool
	Channels int
	Key      string // a subtitle track the server serves (/library/streams/<id>)
	Title    string
	Language string
	Tag      string
	// Video details.
	Profile   string  // high, main, ...
	Level     float64 // 41 for 4.1
	BitDepth  int
	Bitrate   int // kbit/s
	Width     int
	Height    int
	FrameRate float64
	ScanType  string // progressive, interlaced
	CABAC     string // "1", "0", or "" when the server does not say
}

// Video is the part's video stream, nil for none.
func (p MediaPart) Video() *MediaStream {
	for i := range p.Streams {
		if p.Streams[i].Type == StreamVideo {
			return &p.Streams[i]
		}
	}
	return nil
}

// Stream is the part's stream with an ID, nil for none.
func (p MediaPart) Stream(id string) *MediaStream {
	for i := range p.Streams {
		if p.Streams[i].ID == id {
			return &p.Streams[i]
		}
	}
	return nil
}

// selected is the part's selected stream of a type (the default one when
// none is), nil for none.
func (p MediaPart) selected(kind int) *MediaStream {
	var def *MediaStream
	for i := range p.Streams {
		st := &p.Streams[i]
		if st.Type != kind {
			continue
		}
		if st.Selected {
			return st
		}
		if st.Default && def == nil {
			def = st
		}
	}
	return def
}

// Surround reports whether the audio stream with an ID (the part's selected
// one for "") has more than two channels.
func (p MediaPart) Surround(audioID string) bool {
	st := p.selected(StreamAudio)
	if audioID != "" {
		st = p.Stream(audioID)
	}
	return st != nil && st.Type == StreamAudio && st.Channels > 2
}

// fps is the video's frame rate: the stream's, else the version's tag.
func (p MediaPart) fps() float64 {
	if v := p.Video(); v != nil && v.FrameRate > 0 {
		return v.FrameRate
	}
	return map[string]float64{"24p": 23.976, "NTSC": 29.97, "PAL": 25, "25p": 25, "30p": 29.97, "50p": 50, "60p": 59.94}[p.FrameRateTag]
}

func (x *xmlItem) part() (*MediaPart, error) {
	if len(x.Medias) == 0 || len(x.Medias[0].Parts) == 0 {
		return nil, fmt.Errorf("item %s has no media part", x.RatingKey)
	}
	m, xp := x.Medias[0], x.Medias[0].Parts[0]
	p := &MediaPart{ID: xp.ID, Key: xp.Key, Container: xp.Container, Duration: float64(xp.Duration) / 1000, Bitrate: m.Bitrate, FrameRateTag: m.FrameRate}
	for _, st := range xp.Streams {
		p.Streams = append(p.Streams, MediaStream{ID: st.ID, Type: st.Type, Index: st.Index, Codec: st.Codec,
			Selected: st.Selected == 1, Default: st.Default == 1, Channels: st.Channels, Key: st.Key, Title: st.Title,
			Language: st.Lang, Tag: st.Tag, Profile: st.Profile, Level: st.Level, BitDepth: st.BitDepth, Bitrate: st.Bitrate,
			Width: st.Width, Height: st.Height, FrameRate: st.FrameRate, ScanType: st.ScanType, CABAC: st.CABAC})
	}
	return p, nil
}

// MediaPart fetches the first part of an item's first media version with
// its streams (GET /library/metadata/<rk>).
func (c *Client) MediaPart(ctx context.Context, ratingKey string) (*MediaPart, error) {
	r, err := c.req("/library/metadata/"+ratingKey, nil)
	if err != nil {
		return nil, err
	}
	data, err := c.fetchCtx(ctx, c.http, r)
	if err != nil {
		return nil, err
	}
	var mc xmlContainer
	if err := xml.Unmarshal(data, &mc); err != nil {
		return nil, err
	}
	for i := range mc.Items {
		if mc.Items[i].XMLName.Local == "Video" {
			return mc.Items[i].part()
		}
	}
	return nil, fmt.Errorf("item %s not found", ratingKey)
}

// fetchCtx sends a request bound to ctx and returns the body of a 200.
func (c *Client) fetchCtx(ctx context.Context, cl *http.Client, r *http.Request) ([]byte, error) {
	if ctx != nil {
		r = r.WithContext(ctx)
	}
	resp, err := cl.Do(r)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, c.failed(r.URL.Path, resp.StatusCode)
	}
	return io.ReadAll(resp.Body)
}

// directContainers and directAudioCodecs are what jfplay's FFmpeg opens and
// decodes (toolchain/build_ffmpeg.sh: the mov, matroska and mpegts demuxers;
// the audio decoders), as Plex names them. jfplay exits 4, not 7, for a file
// it cannot open or a sound it cannot decode, and only 7 falls back to a
// transcode: so these are checked here before a file is offered as stored.
var (
	directContainers  = map[string]bool{"mkv": true, "mp4": true, "m4v": true, "mov": true, "mpegts": true, "ts": true}
	directAudioCodecs = map[string]bool{"aac": true, "ac3": true, "eac3": true, "dca": true, "dts": true, "mp3": true,
		"flac": true, "opus": true, "vorbis": true, "pcm": true}
)

// DirectAudioEligible reports whether jfplay decodes the audio track a
// direct stream would play: the one with an ID, else the part's selected
// one. Known mono/stereo tracks with supported codecs pass, as does a part
// without sound. Surround and unknown formats need server conversion.
func DirectAudioEligible(part MediaPart, audioID string) (bool, string) {
	st := part.selected(StreamAudio)
	if audioID != "" {
		st = part.Stream(audioID)
	}
	if st == nil || st.Type != StreamAudio {
		return true, ""
	}
	if st.Channels > 2 {
		return false, fmt.Sprintf("%d-channel audio needs stereo conversion", st.Channels)
	}
	if st.Channels <= 0 {
		return false, "unknown audio channel count"
	}
	if directAudioCodecs[strings.ToLower(st.Codec)] {
		return true, ""
	}
	return false, "audio " + st.Codec
}

// DirectEligible reports whether a part may be streamed as stored under a
// video cap in kbit/s (the user's setting; 0 for none), and why not when it
// may not. A file above the chosen cap is transcoded to it: the cap is
// there for a link that cannot carry more. The sound is DirectAudioEligible's.
func DirectEligible(part MediaPart, capKbps int) (bool, string) {
	if c := strings.ToLower(part.Container); c != "" && !directContainers[c] {
		return false, "container " + part.Container
	}
	video := part.Video()
	if video == nil {
		// No probe data: let jfplay's check and the fallback protect playback.
		return true, ""
	}
	if video.Codec != "" && !strings.EqualFold(video.Codec, "h264") {
		return false, "codec " + video.Codec
	}
	if p := strings.ToLower(strings.TrimSpace(video.Profile)); p != "" && p != "high" && p != "main" {
		return false, "profile " + video.Profile
	}
	level := video.Level
	if level > 0 && level < 10 { // some servers report 4.1 instead of 41
		level *= 10
	}
	if level > directMaxLevel+0.01 {
		return false, fmt.Sprintf("level %g", video.Level)
	}
	if video.BitDepth != 0 && video.BitDepth != 8 {
		return false, fmt.Sprintf("bit depth %d", video.BitDepth)
	}
	if video.CABAC == "0" {
		return false, "CAVLC"
	}
	blocks := ((int64(video.Width) + 15) / 16) * ((int64(video.Height) + 15) / 16)
	if video.Width > directMaxWidth || blocks > directMaxBlocks {
		return false, fmt.Sprintf("size %dx%d", video.Width, video.Height)
	}
	hd := video.Width > directSDWidth
	maxFPS, maxKbps := directMaxFPSSD, directMaxKbpsSD
	if hd {
		maxFPS, maxKbps = directMaxFPSHD, directMaxKbpsHD
	}
	if fps := part.fps(); fps > maxFPS+directFPSSlack {
		return false, fmt.Sprintf("%.3g frames/s at %d wide", fps, video.Width)
	}
	if rate := float64(blocks) * part.fps(); rate > directMaxBlockRate*1.01 {
		return false, fmt.Sprintf("picture block rate %.0f exceeds %d", rate, directMaxBlockRate)
	}
	bitrate := video.Bitrate
	if bitrate <= 0 {
		bitrate = part.Bitrate // the version's total: a conservative stand-in
	}
	if bitrate > maxKbps {
		return false, fmt.Sprintf("bitrate %d kbit/s above %d", bitrate, maxKbps)
	}
	if capKbps > 0 && bitrate > capKbps {
		return false, fmt.Sprintf("bitrate %d kbit/s above the %d chosen", bitrate, capKbps)
	}
	return true, ""
}

// videoCap is a user's cap in kbit/s as asked of the server: never above
// the core's limit, and the limit for none.
func videoCap(videoKbps int) int {
	if videoKbps <= 0 || videoKbps > MaxVideoKbps {
		return MaxVideoKbps
	}
	return videoKbps
}

// ProfileExtra is the X-Plex-Client-Profile-Extra value for a transcode at
// a video cap in kbit/s from a source at sourceFPS frames/s (0 unknown):
// stereo audio (so the server downmixes and boosts rather than the board),
// the core's limits at TranscodeSize (a source of 45 frames/s or more
// halved when that size is wider than directSDWidth), and the progressive
// H.264/AAC Matroska target over HTTP that start.mkv serves.
func ProfileExtra(videoKbps int, sourceFPS float64) string {
	w, h := TranscodeSize(videoCap(videoKbps))
	limit := func(name, value string) string {
		return "add-limitation(scope=videoCodec&scopeName=h264&type=upperBound&name=" + name + "&value=" + value + ")"
	}
	lines := []string{
		"add-limitation(scope=videoAudioCodec&scopeName=aac&type=upperBound&name=audio.channels&value=2&isRequired=true)",
		"add-limitation(scope=videoCodec&scopeName=h264&type=match&name=video.profile&list=high|main)",
		limit("video.level", strconv.Itoa(directMaxLevel)),
		limit("video.bitDepth", "8"),
		limit("video.width", strconv.Itoa(w)),
		limit("video.height", strconv.Itoa(h)),
	}
	// above 854 wide the core manages 30 frames/s, not 60: ask for exactly
	// half of a 50 or 60 frames/s source, every other frame (25 or 29.97)
	if w > directSDWidth && sourceFPS >= 45 {
		lines = append(lines, limit("video.frameRate", strconv.FormatFloat(sourceFPS/2, 'f', 3, 64)))
	} else {
		lines = append(lines, limit("video.frameRate", "60"))
	}
	lines = append(lines, "add-transcode-target(type=videoProfile&context=streaming&protocol=http&container=mkv&videoCodec=h264&audioCodec=aac&replace=true)")
	return strings.Join(lines, "+")
}

// playbackIdentity is who the transcoder is asked as: the server matches a
// built-in client profile from these, and Plex Web's (Chrome) is the one
// that works. The token and the client identifier are the client's own.
var playbackIdentity = map[string]string{
	"X-Plex-Product":          "Plex Web",
	"X-Plex-Version":          "4.0.0",
	"X-Plex-Platform":         "Chrome",
	"X-Plex-Platform-Version": "120.0",
	"X-Plex-Device":           "Linux",
	"X-Plex-Device-Name":      "MiSTer CRT",
}

// playbackReq is a GET to the server as the playback client.
func (c *Client) playbackReq(ctx context.Context, path string, q url.Values) (*http.Request, error) {
	u := c.Host + path
	if len(q) > 0 {
		u += "?" + q.Encode()
	}
	r, err := http.NewRequestWithContext(ctx, "GET", u, nil)
	if err != nil {
		return nil, err
	}
	r.Header.Set("X-Plex-Token", c.Token)
	r.Header.Set("X-Plex-Client-Identifier", c.ClientID)
	for k, v := range playbackIdentity {
		r.Header.Set(k, v)
	}
	r.Header.Set("Accept", "application/xml")
	return r, nil
}

// StreamHeaders is the JFPLAY_HEADERS value for jfplay (the environment,
// not the command line): the token and the client identity, one
// CRLF-terminated line each. The URL never carries the token.
func (c *Client) StreamHeaders() string {
	return "X-Plex-Token: " + c.Token + "\r\nX-Plex-Client-Identifier: " + c.ClientID + "\r\n"
}

// NewSession is a fresh transcode session id: one for a whole playback, as
// plex-for-kodi does. A seek or a restart re-issues decision and start on
// it and the server replaces the transcoder; StopTranscode ends it once.
func NewSession() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	s := hex.EncodeToString(b[:])
	return s[:8] + "-" + s[8:12] + "-" + s[12:16] + "-" + s[16:20] + "-" + s[20:]
}

// PlaybackRequest is what to ask for one start of an item.
type PlaybackRequest struct {
	RatingKey    string
	Session      string  // NewSession(); "" makes one
	StartSeconds float64 // where the stream begins
	VideoKbps    int     // the user's cap; 0 or above MaxVideoKbps is MaxVideoKbps
	AudioStream  string  // Stream.ID, "" for the part's selection
	// SubtitleStream is the Stream.ID the server burns into a transcode;
	// "" or "-1" for none (a track the app draws is none here).
	SubtitleStream string
	SubtitleSize   int // 100, 150 or 200; 0 is 100
	AudioBoost     int // the surround downmix gain, 100..300; 0 is 100
	// ForceTranscode asks for a server transcode even when the file could
	// play as stored: the client decided the core cannot play it.
	ForceTranscode bool
}

// PlaybackInfo is the answer: how the item plays.
type PlaybackInfo struct {
	ConversionReason             string
	VideoDecision, AudioDecision string
	Session                      string
	Part                         MediaPart
	Direct                       bool   // the file as stored plays; else a server-generated stream
	VideoCopy                    bool   // server copies video while converting audio; still needs worker precheck
	URL                          string // what jfplay opens; never carries the token (StreamHeaders does)
	// Decision is the server's transcodeDecisionText, and Width and Height
	// the transcode's picture when the server says it.
	Decision      string
	Width, Height int
}

// burnedSubtitle is the stream the request has the server burn in, "0"
// (Plex's none) when there is none.
func (r PlaybackRequest) burnedSubtitle() string {
	if r.SubtitleStream == "" || r.SubtitleStream == "-1" {
		return "0"
	}
	return r.SubtitleStream
}

// PlaybackInfo decides how to play an item. It fetches the part, makes the
// audio track the request names the part's selection (the transcoder
// follows the part's selected streams), and unless a transcode is required
// (a subtitle to burn in, or ForceTranscode) offers the file as stored when
// DirectEligible says so under the cap. Otherwise the subtitle to burn in
// (or none) is selected, the server is asked for its decision and the
// transcode's start URL is returned. A decision the server refuses is an
// error carrying its text.
func (c *Client) PlaybackInfo(ctx context.Context, r PlaybackRequest) (*PlaybackInfo, error) {
	part, err := c.MediaPart(ctx, r.RatingKey)
	if err != nil {
		return nil, err
	}
	info := &PlaybackInfo{Session: r.Session, Part: *part}
	if info.Session == "" {
		info.Session = NewSession()
	}
	if r.AudioStream != "" {
		if sel := part.selected(StreamAudio); sel == nil || sel.ID != r.AudioStream {
			if err := c.SelectAudio(part.ID, r.AudioStream); err != nil {
				return nil, err
			}
		}
	}
	burn := r.burnedSubtitle()
	if !r.ForceTranscode && burn == "0" {
		ok, _ := DirectEligible(*part, r.VideoKbps)
		if ok {
			ok, _ = DirectAudioEligible(*part, r.AudioStream)
		}
		if ok {
			if part.Key == "" {
				return nil, fmt.Errorf("item %s: the server names no file for its part", r.RatingKey)
			}
			info.Direct, info.URL = true, c.Host+part.Key
			return info, nil
		}
	}
	// the transcoder burns in the part's selected subtitle: the one asked
	// for, or none (a track the app draws must not be burned in as well)
	selected := "0"
	if sel := part.selected(StreamSubtitle); sel != nil {
		selected = sel.ID
	}
	if selected != burn {
		if err := c.SelectSubtitle(part.ID, burn); err != nil {
			return nil, err
		}
	}
	copyVideo, videoReason := DirectEligible(*part, r.VideoKbps)
	switch {
	case burn != "0":
		info.ConversionReason = "Subtitle burn-in"
	case r.ForceTranscode:
		info.ConversionReason = "Decoder compatibility"
	case !copyVideo:
		info.ConversionReason = videoReason
	default:
		_, why := DirectAudioEligible(*part, r.AudioStream)
		info.ConversionReason = why
		if why == "" {
			info.ConversionReason = "Audio compatibility"
		}
	}
	copyVideo = copyVideo && !r.ForceTranscode && burn == "0"
	q := c.transcodeQuery(r, info.Session, *part)
	if copyVideo {
		// The client already checked the video cap. A Plex maxVideoBitrate
		// request can force video encoding even for an eligible source.
		q.Del("maxVideoBitrate")
		q.Del("videoResolution")
		q.Del("videoQuality")
		q.Set("directStream", "1")
		q.Set("X-Plex-Client-Profile-Name", "Chrome")
		q.Set("audioChannels", "2")
		q.Set("X-Plex-Client-Profile-Extra", "add-limitation(scope=videoAudioCodec&scopeName=aac&type=upperBound&name=audio.channels&value=2&isRequired=true)+add-transcode-target(type=videoProfile&context=streaming&protocol=http&container=mkv&videoCodec=h264&audioCodec=aac&replace=true)")
	}
	for {
		d, err := c.playbackDecision(ctx, q)
		if err != nil {
			return nil, err
		}
		if copyVideo && !d.copiesVideo() {
			// Never accept an uncapped encode if the server declined video copy.
			copyVideo = false
			info.ConversionReason = "Server video policy"
			q = c.transcodeQuery(r, info.Session, *part)
			continue
		}
		for _, media := range d.Media {
			for _, st := range media.Streams {
				if st.Type == StreamAudio && st.Channels > 2 {
					return nil, fmt.Errorf("the server did not provide stereo audio")
				}
			}
		}
		if len(d.Media) > 0 {
			for _, st := range d.Media[0].Streams {
				if st.Type == StreamVideo {
					info.VideoDecision = st.Decision
				}
				if st.Type == StreamAudio {
					info.AudioDecision = st.Decision
				}
			}
		}
		if info.AudioDecision == "transcode" {
			_, why := DirectAudioEligible(*part, r.AudioStream)
			if why != "" && why != info.ConversionReason {
				info.ConversionReason += "; " + why
			}
		}
		info.Decision, info.VideoCopy = d.Text, copyVideo
		if len(d.Media) > 0 {
			info.Width, info.Height = d.Media[0].Width, d.Media[0].Height
		}
		info.URL = c.transcodeURL(q)
		break
	}
	return info, nil
}

// playbackDecision includes per-stream decisions: the container being
// transcoded does not mean its video was re-encoded.
type playbackDecision struct {
	Code  string `xml:"transcodeDecisionCode,attr"`
	Text  string `xml:"transcodeDecisionText,attr"`
	Media []struct {
		Width   int `xml:"width,attr"`
		Height  int `xml:"height,attr"`
		Streams []struct {
			Type     int    `xml:"streamType,attr"`
			Decision string `xml:"decision,attr"`
			Channels int    `xml:"channels,attr"`
		} `xml:"Part>Stream"`
	} `xml:"Video>Media"`
}

func (d playbackDecision) copiesVideo() bool {
	if len(d.Media) == 0 {
		return false
	}
	for _, st := range d.Media[0].Streams {
		if st.Type == StreamVideo {
			return st.Decision == "copy"
		}
	}
	return false
}

func (c *Client) playbackDecision(ctx context.Context, q url.Values) (*playbackDecision, error) {
	req, err := c.playbackReq(ctx, "/video/:/transcode/universal/decision", q)
	if err != nil {
		return nil, err
	}
	data, err := c.fetchCtx(ctx, c.slow, req)
	if err != nil {
		return nil, err
	}
	var d playbackDecision
	if err := xml.Unmarshal(data, &d); err != nil {
		return nil, fmt.Errorf("transcode decision: %w", err)
	}
	if d.Code != "" && d.Code != "1000" && d.Code != "1001" {
		if d.Text == "" {
			d.Text = "Cannot play this file."
		}
		return nil, fmt.Errorf("the server will not convert this file: %s", d.Text)
	}
	return &d, nil
}

// transcodeQuery is the universal transcoder's parameters for a request,
// shared by the decision and the start.
func (c *Client) transcodeQuery(r PlaybackRequest, session string, part MediaPart) url.Values {
	cap := videoCap(r.VideoKbps)
	w, h := TranscodeSize(cap)
	size, boost := r.SubtitleSize, r.AudioBoost
	if size <= 0 {
		size = 100
	}
	if boost <= 0 {
		boost = 100
	}
	offset := int(r.StartSeconds)
	if offset < 0 {
		offset = 0
	}
	q := url.Values{
		"path": {"/library/metadata/" + r.RatingKey}, "mediaIndex": {"0"}, "partIndex": {"0"},
		"protocol": {"http"}, "directPlay": {"0"}, "directStream": {"0"},
		"videoResolution": {fmt.Sprintf("%dx%d", w, h)}, "maxVideoBitrate": {strconv.Itoa(cap)}, "videoQuality": {"100"},
		"audioBoost": {strconv.Itoa(boost)}, "subtitles": {"burn"}, "subtitleSize": {strconv.Itoa(size)},
		"X-Plex-Client-Profile-Extra": {ProfileExtra(cap, part.fps())},
		"session":                     {session}, "X-Plex-Session-Identifier": {session},
		"copyts": {"1"}, "offset": {strconv.Itoa(offset)}, "fastSeek": {"1"},
		"location": {"wan"}, "mediaBufferSize": {"12288"}, "hasMDE": {"1"},
	}
	return q
}

// transcodeURL is the stream for a decided query: the identity goes in the
// query too (the worker's HTTP client sends no X-Plex headers of its own),
// the token never does.
func (c *Client) transcodeURL(q url.Values) string {
	out := url.Values{} // the decision's query stays as it was sent
	for k, v := range q {
		out[k] = v
	}
	for k, v := range playbackIdentity {
		out.Set(k, v)
	}
	out.Set("X-Plex-Client-Identifier", c.ClientID)
	return c.Host + "/video/:/transcode/universal/start.mkv?" + out.Encode()
}

// StopTranscode ends a transcode session; the server answers 404 once it
// has torn the session down itself (the socket closed), which is no error.
func (c *Client) StopTranscode(ctx context.Context, session string) error {
	if session == "" {
		return nil
	}
	r, err := c.playbackReq(ctx, "/video/:/transcode/universal/stop", url.Values{"session": {session}})
	if err != nil {
		return err
	}
	resp, err := c.http.Do(r)
	if err != nil {
		return err
	}
	io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))
	resp.Body.Close()
	if resp.StatusCode/100 != 2 && resp.StatusCode != 404 {
		return c.failed(r.URL.Path, resp.StatusCode)
	}
	return nil
}

// PlayState is a playback report. Position and Duration are in seconds;
// the timeline takes milliseconds.
type PlayState struct {
	RatingKey      string
	PartID         string
	Session        string // X-Plex-Session-Identifier; "" before a start
	Position       float64
	Duration       float64 // the item's
	Paused         bool
	AudioStream    string
	SubtitleStream string
	// Transcode says a server transcode runs for this state: ReportStopped
	// ends it.
	Transcode bool
}

// timeline tells the server the state of this playback (/:/timeline):
// every ten seconds while playing or paused so it keeps the transcoder
// alive and records the resume point, and once at the end.
func (c *Client) timeline(ctx context.Context, s PlayState, state string) error {
	q := url.Values{
		"ratingKey": {s.RatingKey}, "key": {"/library/metadata/" + s.RatingKey},
		"state": {state}, "time": {strconv.Itoa(int(s.Position * 1000))}, "duration": {strconv.Itoa(int(s.Duration * 1000))},
		"X-Plex-Session-Identifier": {s.Session},
		"identifier":                {"com.plexapp.plugins.library"}, "hasMDE": {"1"}, "continuing": {"0"},
	}
	r, err := c.playbackReq(ctx, "/:/timeline", q)
	if err != nil {
		return err
	}
	_, err = c.fetchCtx(ctx, c.http, r)
	return err
}

// ReportStart says playback began.
func (c *Client) ReportStart(ctx context.Context, s PlayState) error {
	return c.timeline(ctx, s, "playing")
}

// ReportProgress updates the position, playing or paused.
func (c *Client) ReportProgress(ctx context.Context, s PlayState) error {
	state := "playing"
	if s.Paused {
		state = "paused"
	}
	return c.timeline(ctx, s, state)
}

// ReportStopped ends playback: the timeline's stopped state, the transcode
// session ended, and, as every client does past 90 %, the item marked
// watched (which clears its resume point). A transcode had the part's
// subtitle deselected when the app drew it (PlaybackInfo): once the
// transcoder is gone the chosen one is the part's selection again, so the
// choice outlives the play here and in the user's other Plex apps.
func (c *Client) ReportStopped(ctx context.Context, s PlayState) error {
	err := c.timeline(ctx, s, "stopped")
	if s.Transcode {
		if e := c.StopTranscode(ctx, s.Session); err == nil {
			err = e
		}
		if sub := s.SubtitleStream; s.PartID != "" && sub != "" && sub != "-1" && sub != "0" {
			if e := c.SelectSubtitle(s.PartID, sub); err == nil {
				err = e
			}
		}
	}
	if s.Duration > 0 && s.Position >= 0.9*s.Duration {
		if e := c.Scrobble(s.RatingKey, true); err == nil {
			err = e
		}
	}
	return err
}

// subtitleLimit bounds a subtitle file: a feature's SRT is a few hundred
// kilobytes.
const subtitleLimit = 8 << 20

// SubtitleText fetches a text subtitle track (a Stream with Text) of a
// part as a file (/library/streams/<id>), asked for as UTF-8 SRT so the
// server converts what it can; the whole track comes, with the item's own
// times. The rating key and part are the track's home, as the player knows
// it; the stream ID alone names it on the server.
func (c *Client) SubtitleText(ctx context.Context, ratingKey, partID, streamID string) ([]byte, error) {
	r, err := c.req("/library/streams/"+url.PathEscape(streamID), url.Values{"encoding": {"utf-8"}, "format": {"srt"}})
	if err != nil {
		return nil, err
	}
	r.Header.Del("Accept")
	data, err := c.fetchCtx(ctx, c.slow, r)
	if err != nil {
		return nil, err
	}
	if len(data) > subtitleLimit {
		return nil, fmt.Errorf("subtitle track %s larger than %d bytes", streamID, subtitleLimit)
	}
	return data, nil
}
