package plex

// Keep numeric attributes as strings: a bad chapter must not make the whole
// movie's metadata fail to decode.
type xmlChapter struct {
	Title string `xml:"tag,attr"`
	Name  string `xml:"title,attr"`
	Start string `xml:"startTimeOffset,attr"`
	End   string `xml:"endTimeOffset,attr"`
	Thumb string `xml:"thumb,attr"`
}
