package plex

import (
	"context"
	"reflect"
	"strings"
	"testing"
)

// versionsXML is a film in three versions, oldest file first as the server
// lists them: a 1080p original the core cannot decode as stored, a 720p
// copy with every track and a 480p copy without the subtitle track.
const versionsXML = `<MediaContainer size="1"><Video ratingKey="101" key="/library/metadata/101" type="movie" title="Film" duration="5400000">
<Media id="11" bitrate="7800" width="1920" height="1080" aspectRatio="1.78" videoCodec="h264" videoResolution="1080" videoFrameRate="24p" container="mkv">
<Part id="31" key="/library/parts/31/1/file.mkv" file="/media/Film (1999)/Film (1999) WEBDL-1080p.mkv" duration="5400000" container="mkv" indexes="sd">
<Stream id="41" streamType="1" codec="h264" index="0" bitrate="7400" bitDepth="8" width="1920" height="1080" frameRate="23.976" level="40" profile="high" cabac="1"/>
<Stream id="42" streamType="2" codec="aac" index="1" channels="2" selected="1" language="English" languageTag="en" displayTitle="English (AAC Stereo)"/>
<Stream id="43" streamType="3" codec="srt" index="2" language="English" languageTag="en" displayTitle="English (SRT)"/>
</Part></Media>
<Media id="12" bitrate="1200" width="1280" height="720" aspectRatio="1.78" videoCodec="h264" videoResolution="720" videoFrameRate="24p" container="mkv">
<Part id="32" key="/library/parts/32/1/file.mkv" file="/media/Film (1999)/Film (1999) - 720p.mkv" duration="5400000" container="mkv">
<Stream id="51" streamType="1" codec="h264" index="0" bitrate="1100" bitDepth="8" width="1280" height="720" frameRate="23.976" level="31" profile="high" cabac="1"/>
<Stream id="52" streamType="2" codec="aac" index="1" channels="2" selected="1" language="English" languageTag="en" displayTitle="English (AAC Stereo)"/>
<Stream id="53" streamType="3" codec="srt" index="2" language="English" languageTag="en" displayTitle="English (SRT)"/>
</Part></Media>
<Media id="13" bitrate="700" width="854" height="480" aspectRatio="1.78" videoCodec="h264" videoResolution="480" videoFrameRate="24p" container="mkv">
<Part id="33" key="/library/parts/33/1/file.mkv" file="/media/Film (1999)/Film (1999) - 480p.mkv" duration="5400000" container="mkv">
<Stream id="61" streamType="1" codec="h264" index="0" bitrate="600" bitDepth="8" width="854" height="480" frameRate="23.976" level="30" profile="high" cabac="1"/>
<Stream id="62" streamType="2" codec="aac" index="1" channels="2" selected="1" language="English" languageTag="en" displayTitle="English (AAC Stereo)"/>
</Part></Media></Video></MediaContainer>`

func TestItemVersions(t *testing.T) {
	f := newPlaybackServer(t)
	f.metadata = versionsXML
	it, err := f.c.Item("101")
	if err != nil {
		t.Fatal(err)
	}
	if len(it.Versions) != 3 || it.Versions[0].ID != "11" || it.Versions[2].File != "Film (1999) - 480p.mkv" {
		t.Fatalf("versions %+v", it.Versions)
	}
	// the first version is in force until another is chosen
	if it.PartID != "31" || it.Indexes != "sd" || len(it.Subs) != 1 || it.Version().ID != "11" {
		t.Fatalf("first version's fields: part %q indexes %q subs %+v", it.PartID, it.Indexes, it.Subs)
	}
	if !it.UseVersion("13") || it.PartID != "33" || it.Indexes != "" || len(it.Subs) != 0 || len(it.Audio) != 1 ||
		it.Audio[0].ID != "62" || it.VersionID != "13" || it.Version().ID != "13" {
		t.Fatalf("480p version's fields: part %q subs %+v audio %+v", it.PartID, it.Subs, it.Audio)
	}
	it.Audio[0].Selected = false // the item's tracks are its own copy
	if !it.Versions[2].Audio[0].Selected {
		t.Fatal("marking the item's track changed the version's")
	}
	if it.UseVersion("99") || it.VersionID != "13" {
		t.Fatal("an unknown version was taken")
	}
	if VersionIndex(it.Versions, "12") != 1 || VersionIndex(it.Versions, "99") != -1 {
		t.Fatal("version index")
	}

	f.metadata = metadataXML // one version: no list, nothing to choose
	one, err := f.c.Item("101")
	if err != nil {
		t.Fatal(err)
	}
	if one.Versions != nil || one.Version() != nil || one.UseVersion("7") {
		t.Fatalf("single version item %+v", one.Versions)
	}
}

func TestItemAndPartOfVersion(t *testing.T) {
	f := newPlaybackServer(t)
	f.metadata = versionsXML
	it, part, err := f.c.ItemAndPart(context.Background(), "101", "12")
	if err != nil {
		t.Fatal(err)
	}
	if part.ID != "32" || part.MediaID != "12" || part.MediaIndex != 1 || part.Bitrate != 1200 || part.Video().Width != 1280 {
		t.Fatalf("part %+v", part)
	}
	if it.PartID != "32" || it.VersionID != "12" || len(it.Subs) != 1 || it.Subs[0].ID != "53" {
		t.Fatalf("item of the version: part %q subs %+v", it.PartID, it.Subs)
	}
	// a version the record no longer has: the first one
	_, part, err = f.c.ItemAndPart(context.Background(), "101", "99")
	if err != nil || part.MediaID != "11" || part.MediaIndex != 0 {
		t.Fatalf("missing version gave %+v, %v", part, err)
	}
}

func TestPlaybackInfoPlaysTheVersion(t *testing.T) {
	f := newPlaybackServer(t)
	f.metadata = versionsXML
	ctx := context.Background()
	// the 480p version plays as stored: its own file
	info, err := f.c.PlaybackInfo(ctx, PlaybackRequest{RatingKey: "101", MediaID: "13", SubtitleStream: "-1"})
	if err != nil {
		t.Fatal(err)
	}
	if !info.Direct || !strings.HasSuffix(info.URL, "/library/parts/33/1/file.mkv") || info.Part.MediaID != "13" {
		t.Fatalf("direct info %+v", info)
	}
	// the 1080p original converts: the transcoder is told its place
	if _, err := f.c.PlaybackInfo(ctx, PlaybackRequest{RatingKey: "101", MediaID: "11", SubtitleStream: "-1"}); err != nil {
		t.Fatal(err)
	}
	if q := f.last("/video/:/transcode/universal/decision").URL.Query(); q.Get("mediaIndex") != "0" {
		t.Fatalf("1080p mediaIndex %q", q.Get("mediaIndex"))
	}
	// a forced conversion of the 720p copy names it, and the start URL too
	info, err = f.c.PlaybackInfo(ctx, PlaybackRequest{RatingKey: "101", MediaID: "12", SubtitleStream: "-1", ForceTranscode: true})
	if err != nil {
		t.Fatal(err)
	}
	if q := f.last("/video/:/transcode/universal/decision").URL.Query(); q.Get("mediaIndex") != "1" {
		t.Fatalf("720p mediaIndex %q", q.Get("mediaIndex"))
	}
	if !strings.Contains(info.URL, "mediaIndex=1") {
		t.Fatalf("start URL %s", info.URL)
	}
	// a part handed over for another version is not used
	first, _ := f.c.MediaPart(ctx, "101", "")
	info, err = f.c.PlaybackInfo(ctx, PlaybackRequest{RatingKey: "101", MediaID: "13", SubtitleStream: "-1", Part: first})
	if err != nil || info.Part.MediaID != "13" {
		t.Fatalf("handed part of another version: %+v, %v", info, err)
	}
}

func versionsOf(t *testing.T, xml string) []Version {
	t.Helper()
	f := newPlaybackServer(t)
	f.metadata = xml
	it, err := f.c.Item("101")
	if err != nil {
		t.Fatal(err)
	}
	return it.Versions
}

func TestVersionLabels(t *testing.T) {
	vs := versionsOf(t, versionsXML)
	got := VersionLabels(vs, 0, true)
	want := []string{"1080p H.264, 7.8 Mbps, server converts", "720p H.264, 1.2 Mbps, plays directly", "480p H.264, 700 kbps, plays directly"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("labels %q", got)
	}
	if got := VersionLabels(vs, 0, false); !strings.HasSuffix(got[1], "server converts") || !strings.HasSuffix(got[2], "server converts") {
		t.Fatalf("direct play off %q", got)
	}
	// two cuts that read the same are told apart by their files' names
	first := versionsXML[strings.Index(versionsXML, "<Media id=") : strings.Index(versionsXML, "</Media>")+len("</Media>")]
	second := strings.NewReplacer(`id="11"`, `id="14"`, "WEBDL-1080p", "- Theatrical").Replace(first)
	first = strings.Replace(first, "WEBDL-1080p", "- Director's Cut", 1)
	cuts := `<MediaContainer size="1"><Video ratingKey="101" type="movie" title="Film">` + first + second + `</Video></MediaContainer>`
	got = VersionLabels(versionsOf(t, cuts), 0, true)
	if !reflect.DeepEqual(got, []string{"1080p H.264, 7.8 Mbps, server converts - Director's Cut", "1080p H.264, 7.8 Mbps, server converts - Theatrical"}) {
		t.Fatalf("cuts %q", got)
	}
	same := strings.Replace(first, "- Director's Cut", "- Theatrical", 1) + strings.Replace(second, `id="31"`, `id="34"`, 1)
	got = VersionLabels(versionsOf(t, `<MediaContainer size="1"><Video ratingKey="101" type="movie" title="Film">`+same+`</Video></MediaContainer>`), 0, true)
	if got[0] != "1080p H.264, 7.8 Mbps, server converts - version 1" || got[1] != "1080p H.264, 7.8 Mbps, server converts - version 2" {
		t.Fatalf("identical files %q", got)
	}
	for in, want := range map[string]string{" - (Director's Cut)": "Director's Cut", "Film (2001)": "Film (2001)", "[Remux] ": "Remux", "(": "("} {
		if got := ownPart(in); got != want {
			t.Errorf("ownPart(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestPickVersion(t *testing.T) {
	vs := versionsOf(t, versionsXML)
	if i := PickVersion(vs, 0, true); i != 1 {
		t.Fatalf("pick %d, want the 720p copy (the largest that plays as stored)", i)
	}
	if i := PickVersion(vs, 1000, true); i != 2 {
		t.Fatalf("pick at a 1 Mbps cap %d, want the 480p copy", i)
	}
	if i := PickVersion(vs, 0, false); i != 1 {
		t.Fatalf("pick with direct play off %d, want the smallest of at least 720 lines", i)
	}
	big := []Version{{ID: "4k", Resolution: "4k", Width: 3840, Height: 2160}, {ID: "hd", Resolution: "1080", Width: 1920, Height: 1080}}
	if i := PickVersion(big, 0, true); i != 1 {
		t.Fatalf("pick of 4K and 1080p %d, want 1080p", i)
	}
	scope := []Version{{ID: "a", Width: 1280, Height: 536}, {ID: "b", Width: 1920, Height: 800}}
	if i := PickVersion(scope, 0, false); i != 0 {
		t.Fatalf("pick of scope films %d, want the 1280 wide (a 720)", i)
	}
	sd := []Version{{ID: "a", Resolution: "480", Width: 720, Height: 480}, {ID: "b", Resolution: "576", Width: 720, Height: 576}}
	if i := PickVersion(sd, 0, false); i != 1 {
		t.Fatalf("pick of SD versions %d, want the largest", i)
	}
	tie := []Version{{ID: "a", Width: 1920, Height: 1080, Part: MediaPart{Bitrate: 4000}}, {ID: "b", Width: 1920, Height: 1080, Part: MediaPart{Bitrate: 9000}}}
	if i := PickVersion(tie, 0, false); i != 1 {
		t.Fatalf("pick on a tie %d, want the higher bitrate", i)
	}
}

func TestMatchVersion(t *testing.T) {
	vs := versionsOf(t, versionsXML)
	if vs[2].Kind() != "480p h264" {
		t.Fatalf("kind %q", vs[2].Kind())
	}
	if MatchVersion(vs, "480p h264") != 2 || MatchVersion(vs, "4K hevc") != -1 || MatchVersion(vs, "") != -1 {
		t.Fatal("match")
	}
}
