// Package plex is the thin server client: hubs, sections, item lists and
// pre-sized artwork, all as XML over the server's local HTTP port.
package plex

import (
	"crypto/sha1"
	"encoding/hex"
	"encoding/xml"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Client talks to one server.
type Client struct {
	Host     string // http://ip:32400
	Token    string
	CacheDir string
	ClientID string
	http     *http.Client
	slow     *http.Client // for the hub endpoints, which a large library answers slowly
}

// New makes a client; the token is never logged.
func New(host, token, cacheDir, clientID string) *Client {
	os.MkdirAll(cacheDir, 0o755)
	if clientID == "" {
		clientID = "mister-plexcrt-0001"
	}
	return &Client{Host: host, Token: token, CacheDir: cacheDir, ClientID: clientID,
		http: &http.Client{Timeout: 10 * time.Second},
		slow: &http.Client{Timeout: 30 * time.Second}}
}

func (c *Client) req(path string, q url.Values) (*http.Request, error) {
	u := c.Host + path
	if len(q) > 0 {
		u += "?" + q.Encode()
	}
	r, err := http.NewRequest("GET", u, nil)
	if err != nil {
		return nil, err
	}
	r.Header.Set("X-Plex-Token", c.Token)
	r.Header.Set("X-Plex-Client-Identifier", c.ClientID)
	r.Header.Set("X-Plex-Product", Product)
	r.Header.Set("X-Plex-Device-Name", "MiSTer CRT")
	r.Header.Set("Accept", "application/xml")
	return r, nil
}

// Get fetches a path and returns the body.
func (c *Client) Get(path string, q url.Values) ([]byte, error) {
	return c.fetch(c.http, path, q)
}

// getSlow is Get with the longer timeout of the hub endpoints.
func (c *Client) getSlow(path string, q url.Values) ([]byte, error) {
	return c.fetch(c.slow, path, q)
}

func (c *Client) fetch(cl *http.Client, path string, q url.Values) ([]byte, error) {
	r, err := c.req(path, q)
	if err != nil {
		return nil, err
	}
	resp, err := cl.Do(r)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("%s: HTTP %d", path, resp.StatusCode)
	}
	return io.ReadAll(resp.Body)
}

// Item is a Video or Directory as the app sees it.
type Item struct {
	RatingKey  string
	Key        string // children path for directories
	Type       string // movie, show, season, episode, collection
	Subtype    string // what a collection holds: movie or show
	Title      string
	SortTitle  string
	Year       int
	Duration   int // seconds
	ViewOffset int // seconds
	ViewCount  int
	Summary    string
	Thumb      string
	Art        string
	Theme      string  // show theme audio path
	GrandTitle string  // show title for episodes
	GrandKey   string  // the show's rating key for episodes
	ParentKey  string  // the season's rating key for episodes, the show's for seasons
	Children   int     // seasons of a show
	Leaves     int     // episodes of a show or season
	Viewed     int     // of which watched
	Still      string  // an episode's own picture (Thumb is the show's poster)
	Logo       string  // clear logo, when the metadata was fetched in full
	Aspect     float64 // picture aspect of the first media part (1.33, 1.78, 2.35), 0 unknown
	Index      int     // episode number
	Parent     int     // season number
	Rating     float64
	Tagline    string
	Genres     []string
	Colors     [4]uint32 // the server's poster palette (top-left, top-right, bottom-right, bottom-left), 0 if none
	Markers    []Marker  // intro and credits, when the server has found them
	PartID     string    // the first media part, whose streams can be chosen
	Audio      []Stream  // its audio streams
	Subs       []Stream  // its subtitle streams
	Library    string    // the key of its library, when the server says (search results do)
}

// Marker is a span the server has found: "intro" or "credits", in seconds.
type Marker struct {
	Type       string
	Start, End float64
}

// Stream is an audio or subtitle track of a media part.
type Stream struct {
	ID       string
	Title    string // "English (DTS 5.1)"
	Selected bool
}

// Fold maps text to the printable ASCII the glyph atlases hold: dashes,
// quotes and ellipses to their plain forms, Latin letters to their base
// letter, anything else to a space.
func Fold(s string) string {
	ascii := true
	for i := 0; i < len(s); i++ {
		if s[i] < 0x20 || s[i] > 0x7E {
			ascii = false
			break
		}
	}
	if ascii {
		return s
	}
	var b strings.Builder
	for _, r := range s {
		switch {
		case r >= 0x20 && r <= 0x7E:
			b.WriteRune(r)
		case r == '\t' || r == '\n' || r == 0xA0:
			b.WriteByte(' ')
		case r == 0x2013 || r == 0x2014 || r == 0x2212 || r == 0x2010 || r == 0x2011:
			b.WriteByte('-')
		case r == 0x2018 || r == 0x2019 || r == 0x2032 || r == 0x201A:
			b.WriteByte('\'')
		case r == 0x201C || r == 0x201D || r == 0x201E || r == 0x2033:
			b.WriteByte('"')
		case r == 0x2026:
			b.WriteString("...")
		case r == 0x2022 || r == 0xB7:
			b.WriteByte('-')
		case r >= 0xC0 && r <= 0xFF:
			b.WriteByte(latin1[r-0xC0])
		case r == 0x152:
			b.WriteString("OE")
		case r == 0x153:
			b.WriteString("oe")
		case r == 0x160:
			b.WriteByte('S')
		case r == 0x161:
			b.WriteByte('s')
		case r == 0x17D:
			b.WriteByte('Z')
		case r == 0x17E:
			b.WriteByte('z')
		case r == 0x178:
			b.WriteByte('Y')
		case r == 0x10C || r == 0x106:
			b.WriteByte('C')
		case r == 0x10D || r == 0x107:
			b.WriteByte('c')
		case r == 0x110:
			b.WriteByte('D')
		case r == 0x111:
			b.WriteByte('d')
		default:
			b.WriteByte(' ')
		}
	}
	return b.String()
}

// latin1 holds the base letters of U+00C0..U+00FF.
var latin1 = []byte("AAAAAAACEEEEIIIIDNOOOOOxOUUUUYTsaaaaaaaceeeeiiiidnooooo/ouuuuyty")

// Playable reports whether Enter should play rather than browse.
func (it *Item) Playable() bool { return it.Type == "movie" || it.Type == "episode" }

// Label is the list title: "S1E3 Title" for episodes.
func (it *Item) Label() string {
	if it.Type == "episode" {
		return fmt.Sprintf("S%dE%d  %s", it.Parent, it.Index, it.Title)
	}
	return it.Title
}

// Hub is a home-screen row.
type Hub struct {
	Title string
	Key   string
	Ident string // hubIdentifier: home.continue, home.movies.recent, ...
	Items []*Item
}

// IsContinueWatching reports whether the hub is one of the two that make
// up the Continue Watching row: in progress, and the next episodes.
func (h *Hub) IsContinueWatching() bool {
	return strings.HasPrefix(h.Ident, "home.continue") || strings.HasPrefix(h.Ident, "home.ondeck")
}

// Section is a library.
type Section struct {
	Key, Title, Type string
}

type xmlItem struct {
	XMLName          xml.Name
	RatingKey        string `xml:"ratingKey,attr"`
	Key              string `xml:"key,attr"`
	Type             string `xml:"type,attr"`
	Subtype          string `xml:"subtype,attr"`
	Title            string `xml:"title,attr"`
	SortTitle        string `xml:"titleSort,attr"`
	Year             int    `xml:"year,attr"`
	Duration         int64  `xml:"duration,attr"` // ms: a month-long playlist passes the DE10's 32-bit int
	ViewOffset       int64  `xml:"viewOffset,attr"`
	ViewCount        int    `xml:"viewCount,attr"`
	Summary          string `xml:"summary,attr"`
	Thumb            string `xml:"thumb,attr"`
	Art              string `xml:"art,attr"`
	Theme            string `xml:"theme,attr"`
	GrandparentTitle string `xml:"grandparentTitle,attr"`
	GrandparentThumb string `xml:"grandparentThumb,attr"`
	GrandparentKey   string `xml:"grandparentRatingKey,attr"`
	ParentKey        string `xml:"parentRatingKey,attr"`
	ChildCount       int    `xml:"childCount,attr"`
	LeafCount        int    `xml:"leafCount,attr"`
	ViewedLeafCount  int    `xml:"viewedLeafCount,attr"`
	LibrarySectionID string `xml:"librarySectionID,attr"`
	Images           []struct {
		Type string `xml:"type,attr"`
		URL  string `xml:"url,attr"`
	} `xml:"Image"`
	Medias []struct {
		Aspect float64 `xml:"aspectRatio,attr"`
		Parts  []struct {
			ID      string `xml:"id,attr"`
			Streams []struct {
				ID       string `xml:"id,attr"`
				Type     int    `xml:"streamType,attr"`
				Title    string `xml:"displayTitle,attr"`
				Ext      string `xml:"extendedDisplayTitle,attr"`
				Lang     string `xml:"language,attr"`
				Tag      string `xml:"languageTag,attr"`
				Codec    string `xml:"codec,attr"`
				Selected int    `xml:"selected,attr"`
			} `xml:"Stream"`
		} `xml:"Part"`
	} `xml:"Media"`
	Index       int     `xml:"index,attr"`
	ParentIndex int     `xml:"parentIndex,attr"`
	Rating      float64 `xml:"rating,attr"`
	Tagline     string  `xml:"tagline,attr"`
	Genres      []struct {
		Tag string `xml:"tag,attr"`
	} `xml:"Genre"`
	Markers []struct {
		Type  string  `xml:"type,attr"`
		Start float64 `xml:"startTimeOffset,attr"`
		End   float64 `xml:"endTimeOffset,attr"`
	} `xml:"Marker"`
	Blur []struct {
		TL string `xml:"topLeft,attr"`
		TR string `xml:"topRight,attr"`
		BR string `xml:"bottomRight,attr"`
		BL string `xml:"bottomLeft,attr"`
	} `xml:"UltraBlurColors"`
}

func (x *xmlItem) item() *Item {
	it := &Item{RatingKey: x.RatingKey, Key: x.Key, Type: x.Type, Subtype: x.Subtype, Title: Fold(x.Title), SortTitle: Fold(x.SortTitle), Year: x.Year,
		Duration: int(x.Duration / 1000), ViewOffset: int(x.ViewOffset / 1000), ViewCount: x.ViewCount,
		Summary: Fold(x.Summary), Thumb: x.Thumb, Art: x.Art, Theme: x.Theme, GrandTitle: Fold(x.GrandparentTitle),
		Index: x.Index, Parent: x.ParentIndex, Rating: x.Rating, Tagline: Fold(x.Tagline), GrandKey: x.GrandparentKey,
		ParentKey: x.ParentKey, Children: x.ChildCount, Leaves: x.LeafCount, Viewed: x.ViewedLeafCount, Library: x.LibrarySectionID}
	if it.Type == "episode" && x.GrandparentThumb != "" {
		it.Still = x.Thumb
		it.Thumb = x.GrandparentThumb // the poster wall wants the show's poster
	}
	for _, im := range x.Images {
		if im.Type == "clearLogo" {
			it.Logo = im.URL
		}
	}
	if len(x.Medias) > 0 {
		it.Aspect = x.Medias[0].Aspect
		if len(x.Medias[0].Parts) > 0 {
			part := x.Medias[0].Parts[0]
			it.PartID = part.ID
			for _, st := range part.Streams {
				title := st.Ext // "Commentary (English AC3 Stereo)"; the plain title lacks the name
				if title == "" {
					title = st.Title
				}
				title = Fold(title)
				if strings.TrimSpace(strings.NewReplacer("(", "", ")", "", "SRT", "", "ASS", "").Replace(title)) == "" ||
					strings.HasPrefix(strings.TrimSpace(title), "(") {
					// a name in a script the atlases lack: the language in English
					// (from its tag), then the codec
					lang := Fold(st.Lang)
					if strings.TrimSpace(lang) == "" {
						lang = LangName(st.Tag)
					}
					title = strings.TrimSpace(lang + " " + strings.ToUpper(st.Codec))
				}
				s := Stream{ID: st.ID, Title: title, Selected: st.Selected == 1}
				switch st.Type {
				case 2:
					it.Audio = append(it.Audio, s)
				case 3:
					it.Subs = append(it.Subs, s)
				}
			}
		}
	}
	for _, g := range x.Genres {
		it.Genres = append(it.Genres, g.Tag)
	}
	for _, m := range x.Markers {
		it.Markers = append(it.Markers, Marker{Type: m.Type, Start: m.Start / 1000, End: m.End / 1000})
	}
	if len(x.Blur) > 0 {
		b := x.Blur[0]
		for i, h := range []string{b.TL, b.TR, b.BR, b.BL} {
			if v, err := strconv.ParseUint(h, 16, 32); err == nil {
				it.Colors[i] = uint32(v)
			}
		}
	}
	return it
}

type xmlContainer struct {
	Size  int       `xml:"size,attr"`
	Total int       `xml:"totalSize,attr"`
	Items []xmlItem `xml:",any"`
	Hubs  []struct {
		Title string    `xml:"title,attr"`
		Key   string    `xml:"key,attr"`
		Ident string    `xml:"hubIdentifier,attr"`
		Items []xmlItem `xml:",any"`
	} `xml:"Hub"`
}

// Sections lists movie and show libraries.
func (c *Client) Sections() ([]Section, error) {
	data, err := c.Get("/library/sections", nil)
	if err != nil {
		return nil, err
	}
	var mc xmlContainer
	if err := xml.Unmarshal(data, &mc); err != nil {
		return nil, err
	}
	var out []Section
	for _, d := range mc.Items {
		if d.Type == "movie" || d.Type == "show" {
			out = append(out, Section{Key: d.Key, Title: d.Title, Type: d.Type})
		}
	}
	return out, nil
}

// Items fetches a listing path (section view, children key) with a size cap.
func (c *Client) Items(path string, q url.Values, max int) ([]*Item, error) {
	if q == nil {
		q = url.Values{}
	}
	q.Set("X-Plex-Container-Start", "0")
	q.Set("X-Plex-Container-Size", strconv.Itoa(max))
	data, err := c.Get(path, q)
	if err != nil {
		return nil, err
	}
	var mc xmlContainer
	if err := xml.Unmarshal(data, &mc); err != nil {
		return nil, err
	}
	var out []*Item
	for i := range mc.Items {
		x := &mc.Items[i]
		if x.XMLName.Local != "Video" && x.XMLName.Local != "Directory" {
			continue
		}
		out = append(out, x.item())
	}
	return out, nil
}

// ShowAspect is the picture aspect of a show's first episode (0 when the
// server has not measured it), one small request per show.
func (c *Client) ShowAspect(ratingKey string) (float64, error) {
	q := url.Values{}
	q.Set("excludeFields", "summary,tagline")
	q.Set("excludeElements", "Genre,Director,Writer,Role,Country,Producer,Guid,Collection,Label,Field,Image,Stream,Marker,UltraBlurColors")
	items, err := c.Items("/library/metadata/"+ratingKey+"/allLeaves", q, 1)
	if err != nil {
		return 0, err
	}
	if len(items) == 0 {
		return 0, nil
	}
	return items[0].Aspect, nil
}

// ShowEpisodes lists every episode of a show, all its seasons and specials
// in the server's order, a page at a time. Tags such as cast and crew are
// left out: a long show's listing is large enough without them.
func (c *Client) ShowEpisodes(ratingKey string) ([]*Item, error) {
	const page, pages = 500, 100 // a server that never ends its listing is refused
	path := "/library/metadata/" + ratingKey + "/allLeaves"
	q := url.Values{}
	q.Set("excludeElements", "Genre,Director,Writer,Role,Country,Producer,Guid,Collection,Label,Field")
	q.Set("X-Plex-Container-Size", strconv.Itoa(page))
	var out []*Item
	for range pages {
		q.Set("X-Plex-Container-Start", strconv.Itoa(len(out)))
		data, err := c.Get(path, q)
		if err != nil {
			return nil, err
		}
		var mc xmlContainer
		if err := xml.Unmarshal(data, &mc); err != nil {
			return nil, err
		}
		n := 0
		for i := range mc.Items {
			if x := &mc.Items[i]; x.XMLName.Local == "Video" {
				out = append(out, x.item())
				n++
			}
		}
		// a short page is the last; so is the one that reaches the total
		if n < page || mc.Total > 0 && len(out) >= mc.Total {
			return out, nil
		}
	}
	return nil, fmt.Errorf("%s: more than %d episodes", path, page*pages)
}

// FirstEpisodeAspects is the picture aspect of every show in a TV library
// that has a first episode of some season, keyed by the show's rating key
// and taken from its lowest season: one request for the whole library.
func (c *Client) FirstEpisodeAspects(sectionKey string) (map[string]float64, error) {
	q := url.Values{}
	q.Set("type", "4")
	q.Set("episode.index", "1")
	q.Set("excludeFields", "summary,tagline")
	q.Set("excludeElements", "Genre,Director,Writer,Role,Country,Producer,Guid,Collection,Label,Field,Image,Stream,Marker,UltraBlurColors")
	q.Set("X-Plex-Container-Start", "0")
	q.Set("X-Plex-Container-Size", "20000")
	data, err := c.Get("/library/sections/"+sectionKey+"/all", q)
	if err != nil {
		return nil, err
	}
	var mc xmlContainer
	if err := xml.Unmarshal(data, &mc); err != nil {
		return nil, err
	}
	out := map[string]float64{}
	season := map[string]int{}
	for i := range mc.Items {
		x := &mc.Items[i]
		if x.GrandparentKey == "" || len(x.Medias) == 0 || x.Medias[0].Aspect == 0 {
			continue
		}
		if s, seen := season[x.GrandparentKey]; seen && s <= x.ParentIndex {
			continue
		}
		season[x.GrandparentKey] = x.ParentIndex
		out[x.GrandparentKey] = x.Medias[0].Aspect
	}
	return out, nil
}

// Page fetches items [start, start+size) of a listing and the total count.
func (c *Client) Page(path string, q url.Values, start, size int) ([]*Item, int, error) {
	if q == nil {
		q = url.Values{}
	}
	q.Set("X-Plex-Container-Start", strconv.Itoa(start))
	q.Set("X-Plex-Container-Size", strconv.Itoa(size))
	data, err := c.Get(path, q)
	if err != nil {
		return nil, 0, err
	}
	var mc xmlContainer
	if err := xml.Unmarshal(data, &mc); err != nil {
		return nil, 0, err
	}
	xs := mc.Items
	if len(xs) == 0 && len(mc.Hubs) > 0 {
		xs = mc.Hubs[0].Items // a hub listing (a section's continue watching)
	}
	var out []*Item
	for i := range xs {
		x := &xs[i]
		if x.XMLName.Local != "Video" && x.XMLName.Local != "Directory" {
			continue
		}
		out = append(out, x.item())
	}
	// a hub listing counts its items; a page past the end of a listing has
	// none, and keeps the listing's size
	total := mc.Total
	if total == 0 || len(mc.Items) == 0 && len(mc.Hubs) > 0 {
		total = len(out)
	}
	return out, total, nil
}

// Letter is one entry of a section's first-character index.
type Letter struct {
	Key  string
	Size int
}

// FirstChars returns the A-Z index of a section (for the alphabet jump).
func (c *Client) FirstChars(section string, q url.Values) ([]Letter, error) {
	data, err := c.Get("/library/sections/"+section+"/firstCharacter", q)
	if err != nil {
		return nil, err
	}
	var mc struct {
		Dirs []struct {
			Key  string `xml:"key,attr"`
			Size int    `xml:"size,attr"`
		} `xml:"Directory"`
	}
	if err := xml.Unmarshal(data, &mc); err != nil {
		return nil, err
	}
	var out []Letter
	for _, d := range mc.Dirs {
		out = append(out, Letter{d.Key, d.Size})
	}
	return out, nil
}

// Item fetches one item's metadata, with its markers.
func (c *Client) Item(ratingKey string) (*Item, error) {
	items, err := c.Items("/library/metadata/"+ratingKey, url.Values{"includeMarkers": {"1"}}, 1)
	if err != nil {
		return nil, err
	}
	if len(items) == 0 {
		return nil, fmt.Errorf("item %s not found", ratingKey)
	}
	return items[0], nil
}

// Hubs returns the home rows: continue watching, then recently added per library.
func (c *Client) Hubs(count int) ([]*Hub, error) {
	q := url.Values{"count": {strconv.Itoa(count)}, "excludeFields": {"summary,tagline"},
		"excludeElements": {"Genre,Director,Writer,Role,Country,Producer,Guid,Collection,Label,Field,UltraBlurColors"}}
	data, err := c.getSlow("/hubs", q)
	if err != nil {
		return nil, err
	}
	var mc xmlContainer
	if err := xml.Unmarshal(data, &mc); err != nil {
		return nil, err
	}
	var out []*Hub
	for _, h := range mc.Hubs {
		if len(h.Items) == 0 {
			continue
		}
		// home.continue, home.ondeck, home.movies.recent, home.television.recent;
		// music, photos and playlists are not for this client
		ident := h.Ident
		if strings.Contains(ident, "music") || strings.Contains(ident, "photo") || strings.Contains(ident, "playlist") {
			continue
		}
		// Continue Watching holds everything in progress (films included);
		// On Deck adds the next unwatched episodes. They are shown as one
		// row: Continue Watching first, then what On Deck adds to it.
		hub := &Hub{Title: Fold(h.Title), Key: h.Key, Ident: ident}
		if !hub.IsContinueWatching() {
			continue // the recently added rows come per library (SectionRecent)
		}
		for i := range h.Items {
			x := &h.Items[i]
			if x.XMLName.Local != "Video" && x.XMLName.Local != "Directory" {
				continue
			}
			hub.Items = append(hub.Items, x.item())
		}
		if strings.HasPrefix(ident, "home.ondeck") {
			hub.Title = "Continue Watching"
			if cw := findHub(out, "home.continue"); cw != nil {
				cw.Items = mergeItems(cw.Items, hub.Items)
				continue
			}
		}
		if strings.HasPrefix(ident, "home.continue") {
			hub.Title = "Continue Watching"
			if od := findHub(out, "home.ondeck"); od != nil {
				od.Items = mergeItems(hub.Items, od.Items)
				continue
			}
		}
		out = append(out, hub)
	}
	return out, nil
}

func findHub(hubs []*Hub, prefix string) *Hub {
	for _, h := range hubs {
		if strings.HasPrefix(h.Ident, prefix) {
			return h
		}
	}
	return nil
}

// mergeItems appends the items of b that a does not already hold.
func mergeItems(a, b []*Item) []*Item {
	seen := map[string]bool{}
	for _, it := range a {
		seen[it.RatingKey] = true
	}
	for _, it := range b {
		if !seen[it.RatingKey] {
			a = append(a, it)
			seen[it.RatingKey] = true
		}
	}
	return a
}

// SectionRecent returns a library's recently added hub (recently aired for
// a show library without one), or nil.
func (c *Client) SectionRecent(section string, count int) (*Hub, error) {
	q := url.Values{"count": {strconv.Itoa(count)}, "excludeFields": {"summary,tagline"},
		"excludeElements": {"Genre,Director,Writer,Role,Country,Producer,Guid,Collection,Label,Field,UltraBlurColors"}}
	data, err := c.getSlow("/hubs/sections/"+section, q)
	if err != nil {
		return nil, err
	}
	var mc xmlContainer
	if err := xml.Unmarshal(data, &mc); err != nil {
		return nil, err
	}
	var pick *Hub
	for _, h := range mc.Hubs {
		ident := h.Ident
		added := strings.Contains(ident, "recentlyadded")
		if !added && !(strings.Contains(ident, "recentlyaired") && pick == nil) {
			continue
		}
		hub := &Hub{Title: Fold(h.Title), Key: h.Key, Ident: ident}
		for i := range h.Items {
			x := &h.Items[i]
			if x.XMLName.Local != "Video" && x.XMLName.Local != "Directory" {
				continue
			}
			hub.Items = append(hub.Items, x.item())
		}
		if len(hub.Items) == 0 {
			continue
		}
		pick = hub
		if added {
			break
		}
	}
	return pick, nil
}

// Put sends a PUT to a path (stream selection, Continue Watching).
func (c *Client) Put(path string, q url.Values) error {
	r, err := c.req(path, q)
	if err != nil {
		return err
	}
	r.Method = "PUT"
	resp, err := c.http.Do(r)
	if err != nil {
		return err
	}
	resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("%s: HTTP %d", path, resp.StatusCode)
	}
	return nil
}

// SelectAudio makes an audio stream the part's default (what plays).
func (c *Client) SelectAudio(partID, streamID string) error {
	return c.Put("/library/parts/"+partID, url.Values{"audioStreamID": {streamID}, "allParts": {"1"}})
}

// SelectSubtitle makes a subtitle stream the part's default; "0" for none.
func (c *Client) SelectSubtitle(partID, streamID string) error {
	return c.Put("/library/parts/"+partID, url.Values{"subtitleStreamID": {streamID}, "allParts": {"1"}})
}

// Scrobble marks an item watched (true) or unwatched (false).
func (c *Client) Scrobble(ratingKey string, watched bool) error {
	path := "/:/scrobble"
	if !watched {
		path = "/:/unscrobble"
	}
	_, err := c.Get(path, url.Values{"key": {ratingKey}, "identifier": {"com.plexapp.plugins.library"}})
	return err
}

// ContinueWatching returns the rating keys in the server's Continue
// Watching list: everything in progress and the next episodes, the two
// hubs of the Home row together and without the row's cap. A server
// without the list answers with an error.
func (c *Client) ContinueWatching() (map[string]bool, error) {
	q := url.Values{"excludeFields": {"summary,tagline"},
		"excludeElements": {"Genre,Director,Writer,Role,Country,Producer,Guid,Collection,Label,Field,UltraBlurColors,Media"}}
	data, err := c.getSlow("/hubs/continueWatching/items", q)
	if err != nil {
		return nil, err
	}
	var mc xmlContainer
	if err := xml.Unmarshal(data, &mc); err != nil {
		return nil, err
	}
	keys := map[string]bool{}
	for i := range mc.Items {
		x := &mc.Items[i]
		if (x.XMLName.Local == "Video" || x.XMLName.Local == "Directory") && x.RatingKey != "" {
			keys[x.RatingKey] = true
		}
	}
	return keys, nil
}

// RemoveFromContinueWatching takes an item out of Continue Watching. The
// server keeps its resume point, and playing it again puts it back
// (Plex Media Server 1.43).
func (c *Client) RemoveFromContinueWatching(ratingKey string) error {
	return c.Put("/actions/removeFromContinueWatching", url.Values{"ratingKey": {ratingKey}})
}

// Art fetches a transcoded picture (poster or backdrop) at w x h, cropped by
// the server to cover the box, cached on disk as JPEG. Returns the file path.
func (c *Client) Art(thumb string, w, h int) (string, error) {
	return c.picture(thumb, w, h, false)
}

// Logo fetches a clear logo as a PNG with alpha that fits inside w x h
// (never upscaled), cached on disk. Returns the file path.
func (c *Client) Logo(logo string, w, h int) (string, error) {
	return c.picture(logo, w, h, true)
}

func (c *Client) picture(src string, w, h int, logo bool) (string, error) {
	if src == "" {
		return "", fmt.Errorf("no art")
	}
	ext, q := ".jpg", url.Values{"width": {strconv.Itoa(w)}, "height": {strconv.Itoa(h)}, "minSize": {"1"},
		"upscale": {"1"}, "format": {"jpeg"}, "url": {src}}
	if logo {
		ext, q = ".png", url.Values{"width": {strconv.Itoa(w)}, "height": {strconv.Itoa(h)}, "minSize": {"0"},
			"upscale": {"0"}, "format": {"png"}, "url": {src}}
	}
	sum := sha1.Sum([]byte(fmt.Sprintf("%s|%dx%d", src, w, h)))
	path := filepath.Join(c.CacheDir, hex.EncodeToString(sum[:8])+ext)
	if _, err := os.Stat(path); err == nil {
		return path, nil
	}
	data, err := c.Get("/photo/:/transcode", q)
	if err != nil {
		return "", err
	}
	tmp := path + ".part"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return "", err
	}
	return path, os.Rename(tmp, path)
}

// langNames are English names for language tags whose native names are
// written in scripts the fonts do not cover.
var langNames = map[string]string{
	"ar": "Arabic", "el": "Greek", "he": "Hebrew", "iw": "Hebrew", "ja": "Japanese", "ko": "Korean",
	"zh": "Chinese", "yue": "Cantonese", "ru": "Russian", "uk": "Ukrainian", "bg": "Bulgarian",
	"sr": "Serbian", "mk": "Macedonian", "be": "Belarusian", "kk": "Kazakh", "th": "Thai",
	"hi": "Hindi", "bn": "Bengali", "ta": "Tamil", "te": "Telugu", "ml": "Malayalam", "kn": "Kannada",
	"mr": "Marathi", "gu": "Gujarati", "pa": "Punjabi", "ur": "Urdu", "fa": "Persian", "ps": "Pashto",
	"ka": "Georgian", "hy": "Armenian", "am": "Amharic", "km": "Khmer", "lo": "Lao", "my": "Burmese",
	"si": "Sinhala", "ne": "Nepali", "mn": "Mongolian", "bo": "Tibetan", "vi": "Vietnamese",
	"ms": "Malay", "id": "Indonesian", "tl": "Filipino", "fil": "Filipino", "sw": "Swahili",
	"tr": "Turkish", "az": "Azerbaijani", "uz": "Uzbek", "ky": "Kyrgyz", "tg": "Tajik",
}

// LangName is the English name of a language tag ("ar", "zh-Hant"), or
// "Language xx" when unknown; "" for no tag.
func LangName(tag string) string {
	if tag == "" {
		return ""
	}
	base := strings.ToLower(strings.SplitN(tag, "-", 2)[0])
	if n, ok := langNames[base]; ok {
		return n
	}
	return "Language " + strings.ToUpper(base)
}
