package plex

import (
	"fmt"
	"strconv"
	"strings"
)

// Version is one of an item's versions: a Media of its record, of which
// the app plays the first file.
type Version struct {
	ID         string    // the Media's ID: the version the app records
	Part       MediaPart // its first file, with the streams the server probed (none in listings)
	Indexes    string    // the part's preview indexes
	Aspect     float64
	Resolution string // the server's class: 1080, 720, 480, sd, 4k
	Codec      string // video codec: h264, hevc, ...
	Width      int
	Height     int
	File       string // the file's name, for telling apart versions that read the same
	Audio      []Stream
	Subs       []Stream
}

// Detailed reports whether the record carried the version's streams
// (an item's own record does, listings do not): labels and picks need them.
func (v Version) Detailed() bool { return len(v.Part.Streams) > 0 }

// versions lists the record's versions, nil when it has fewer than two.
func (x *xmlItem) versions() []Version {
	n := 0
	for _, m := range x.Medias {
		if len(m.Parts) > 0 {
			n++
		}
	}
	if n < 2 {
		return nil
	}
	out := make([]Version, 0, n)
	for i, m := range x.Medias {
		if len(m.Parts) == 0 {
			continue
		}
		xp := m.Parts[0]
		v := Version{ID: m.ID, Part: *x.mediaPart(i), Indexes: xp.Indexes, Aspect: m.Aspect, Resolution: strings.ToLower(m.Resolution),
			Codec: strings.ToLower(m.VideoCodec), Width: m.Width, Height: m.Height, File: baseName(xp.File)}
		v.Audio, v.Subs = tracks(xp)
		out = append(out, v)
	}
	return out
}

// baseName is a server path's last element, for Windows servers too.
func baseName(p string) string {
	return p[strings.LastIndexAny(p, `/\`)+1:]
}

// Version is the chosen version, nil for an item with one.
func (it *Item) Version() *Version {
	if len(it.Versions) == 0 {
		return nil
	}
	for i := range it.Versions {
		if it.Versions[i].ID == it.VersionID {
			return &it.Versions[i]
		}
	}
	return &it.Versions[0]
}

// UseVersion makes the version with an ID the chosen one: the item's part,
// preview indexes, aspect and tracks become that version's (its server
// defaults marked). It reports whether the item has that version.
func (it *Item) UseVersion(id string) bool {
	for i := range it.Versions {
		v := &it.Versions[i]
		if v.ID != id {
			continue
		}
		it.VersionID = id
		it.PartID, it.Indexes = v.Part.ID, v.Indexes
		if v.Aspect != 0 {
			it.Aspect = v.Aspect
		}
		it.Audio = append([]Stream(nil), v.Audio...)
		it.Subs = append([]Stream(nil), v.Subs...)
		return true
	}
	return false
}

// VersionIndex is the place of the version with an ID, -1 for none.
func VersionIndex(vs []Version, id string) int {
	for i := range vs {
		if vs[i].ID == id {
			return i
		}
	}
	return -1
}

// class is the version's picture class in lines: the server's
// videoResolution, else the picture's own size (a 1280x536 scope film is
// a 720 like a 1280x720 one).
func (v Version) class() int {
	switch v.Resolution {
	case "4k":
		return 2160
	case "sd":
		return 480
	}
	if n, err := strconv.Atoi(v.Resolution); err == nil && n > 0 {
		return n
	}
	w, h := v.size()
	return max(h, w*9/16)
}

// size is the picture's size: the version's, else its video stream's.
func (v Version) size() (w, h int) {
	if v.Width > 0 && v.Height > 0 {
		return v.Width, v.Height
	}
	if s := v.Part.Video(); s != nil {
		return s.Width, s.Height
	}
	return 0, 0
}

func (v Version) pixels() int {
	w, h := v.size()
	return w * h
}

// resolutionName is the class as people say it: 1080p, 720p, SD, 4K.
func (v Version) resolutionName() string {
	switch c := v.class(); {
	case v.Resolution == "4k" || c >= 2000:
		return "4K"
	case v.Resolution == "sd":
		return "SD"
	case c > 0:
		return strconv.Itoa(c) + "p"
	}
	return ""
}

// codecNames are the video codecs as the chooser names them.
var codecNames = map[string]string{"h264": "H.264", "hevc": "HEVC", "h265": "HEVC", "av1": "AV1", "vp9": "VP9",
	"mpeg2video": "MPEG-2", "mpeg4": "MPEG-4", "msmpeg4v3": "DivX", "vc1": "VC-1", "wmv3": "WMV"}

func (v Version) codecName() string {
	if n := codecNames[v.Codec]; n != "" {
		return n
	}
	return strings.ToUpper(v.Codec)
}

// Kind is what a show's episodes match a pick by: class and codec,
// "720p h264".
func (v Version) Kind() string {
	return strings.TrimSpace(v.resolutionName() + " " + v.Codec)
}

// plays reports whether the version plays as stored at the cap, with
// direct play allowed at all (Options). Without its streams (a listing's
// record) nobody can tell, and it counts as converted.
func (v Version) plays(capKbps int, direct bool) bool {
	if !direct || !v.Detailed() {
		return false
	}
	ok, _ := DirectEligible(v.Part, capKbps)
	return ok
}

// Name is the version as its Version row names it: "720p H.264".
func (v Version) Name() string {
	return strings.TrimSpace(v.resolutionName() + " " + v.codecName())
}

// label is the version's line: "720p H.264, 1.2 Mbps, plays directly".
func (v Version) label(capKbps int, direct bool) string {
	var parts []string
	if s := v.Name(); s != "" {
		parts = append(parts, s)
	}
	if b := v.Part.Bitrate; b >= 1000 {
		parts = append(parts, fmt.Sprintf("%.1f Mbps", float64(b)/1000))
	} else if b > 0 {
		parts = append(parts, fmt.Sprintf("%d kbps", b))
	}
	if v.plays(capKbps, direct) {
		parts = append(parts, "plays directly")
	} else {
		parts = append(parts, "server converts")
	}
	return strings.Join(parts, ", ")
}

// VersionLabels are the chooser's lines for versions at the user's cap,
// told apart where two read the same (apart).
func VersionLabels(vs []Version, capKbps int, direct bool) []string {
	out := make([]string, len(vs))
	for i, v := range vs {
		out[i] = v.label(capKbps, direct)
	}
	return apart(vs, out)
}

// VersionNames are the versions' names (Name), told apart where two read
// the same (apart).
func VersionNames(vs []Version) []string {
	out := make([]string, len(vs))
	for i, v := range vs {
		out[i] = v.Name()
	}
	return apart(vs, out)
}

// apart tells apart the versions' lines that read the same by their files'
// names (the part the names do not share: "Director's Cut"), else by their
// place.
func apart(vs []Version, out []string) []string {
	count := map[string]int{}
	for _, s := range out {
		count[s]++
	}
	names := make([]string, len(vs))
	for i, v := range vs {
		names[i] = strings.TrimSuffix(v.File, extension(v.File))
	}
	pre, suf := commonEnds(names)
	for i := range vs {
		if count[out[i]] < 2 {
			continue
		}
		own := names[i]
		if len(own) >= pre+suf {
			own = own[pre : len(own)-suf]
		}
		own = ownPart(Fold(own))
		if own == "" {
			own = fmt.Sprintf("version %d", i+1)
		}
		if out[i] == "" {
			out[i] = own
		} else {
			out[i] += " - " + own
		}
	}
	return out
}

// ownPart is a name's own part without the separators around it and the
// brackets that enclose it: " - (Director's Cut)" is "Director's Cut".
func ownPart(s string) string {
	s = strings.Trim(s, " -_.")
	for len(s) >= 2 && (s[0] == '(' && s[len(s)-1] == ')' || s[0] == '[' && s[len(s)-1] == ']') {
		s = strings.Trim(s[1:len(s)-1], " -_.")
	}
	return s
}

func extension(name string) string {
	if i := strings.LastIndexByte(name, '.'); i > 0 {
		return name[i:]
	}
	return ""
}

// commonEnds is the length of the prefix and of the suffix all names share
// (bytes; the names are told apart, not shown whole).
func commonEnds(names []string) (pre, suf int) {
	if len(names) == 0 {
		return 0, 0
	}
	first := names[0]
	pre, suf = len(first), len(first)
	for _, n := range names[1:] {
		p := 0
		for p < pre && p < len(n) && n[p] == first[p] {
			p++
		}
		pre = p
		s := 0
		for s < suf && s < len(n) && n[len(n)-1-s] == first[len(first)-1-s] {
			s++
		}
		suf = s
	}
	if pre+suf > len(first) {
		suf = len(first) - pre
	}
	return pre, suf
}

// PickVersion is the version that suits the cores best (the chooser's
// pre-selection, and the version played when nobody can be asked): the
// largest picture that plays as stored at the cap, the higher bitrate on a
// tie; with none, the smallest of at least 720 lines (the output tops out
// at 720p, so more only costs the server); with none of those, the largest.
func PickVersion(vs []Version, capKbps int, direct bool) int {
	best := -1
	for i, v := range vs {
		if v.plays(capKbps, direct) && (best < 0 || larger(v, vs[best])) {
			best = i
		}
	}
	if best >= 0 {
		return best
	}
	for i, v := range vs {
		if v.class() >= 720 && (best < 0 || smaller(v, vs[best])) {
			best = i
		}
	}
	if best >= 0 {
		return best
	}
	for i, v := range vs {
		if best < 0 || larger(v, vs[best]) {
			best = i
		}
	}
	return max(best, 0)
}

func larger(a, b Version) bool {
	if a.pixels() != b.pixels() {
		return a.pixels() > b.pixels()
	}
	return a.Part.Bitrate > b.Part.Bitrate
}

func smaller(a, b Version) bool {
	if a.pixels() != b.pixels() {
		return a.pixels() < b.pixels()
	}
	return a.Part.Bitrate > b.Part.Bitrate
}

// MatchVersion is the first version of a Kind, -1 for none.
func MatchVersion(vs []Version, kind string) int {
	if kind == "" {
		return -1
	}
	for i := range vs {
		if vs[i].Kind() == kind {
			return i
		}
	}
	return -1
}
