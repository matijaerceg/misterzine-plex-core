package ui

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"plexcrt/internal/plex"
)

// Shows are judged by a first episode: one sweep request per TV library
// answers for most, the rest are probed once, and everything is remembered
// on disk. An unknown show stays visible.
func TestShowsAreMeasuredOnceForTheFilter(t *testing.T) {
	var sweeps, probes atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/library/sections":
			fmt.Fprint(w, `<MediaContainer><Directory key="2" type="show" title="TV"/><Directory key="3" type="movie" title="Films"/></MediaContainer>`)
		case r.URL.Path == "/library/sections/2/all" && r.URL.Query().Get("type") == "4":
			sweeps.Add(1)
			if r.URL.Query().Get("episode.index") != "1" {
				t.Errorf("sweep should ask for first episodes: %s", r.URL)
			}
			// the wide show's season 2 comes first; season 1 must win
			fmt.Fprint(w, `<MediaContainer>
				<Video ratingKey="201" type="episode" grandparentRatingKey="16" parentIndex="2"><Media aspectRatio="1.33"/></Video>
				<Video ratingKey="101" type="episode" grandparentRatingKey="16" parentIndex="1"><Media aspectRatio="1.78"/></Video>
				<Video ratingKey="102" type="episode" grandparentRatingKey="43" parentIndex="1"><Media aspectRatio="1.33"/></Video>
				</MediaContainer>`)
		case strings.HasSuffix(r.URL.Path, "/allLeaves"):
			probes.Add(1)
			if r.URL.Query().Get("X-Plex-Container-Size") != "1" {
				t.Errorf("probe should ask for one episode: %s", r.URL)
			}
			fmt.Fprint(w, `<MediaContainer><Video ratingKey="9" type="episode" title="Special"><Media aspectRatio="2.35"/></Video></MediaContainer>`)
		default:
			t.Errorf("unexpected request %s", r.URL)
		}
	}))
	defer server.Close()
	dir := t.TempDir()
	a := &App{Plex: plex.New(server.URL, "", dir, "test"), Cfg: &Config{FourThree: true}}
	a.SetCacheDir(dir)
	wide := &plex.Item{RatingKey: "16", Type: "show", Title: "Wide"}
	square := &plex.Item{RatingKey: "43", Type: "show", Title: "Square"}
	odd := &plex.Item{RatingKey: "77", Type: "show", Title: "Specials only"}
	movie := &plex.Item{RatingKey: "7", Type: "movie", Aspect: 2.35}
	items := []*plex.Item{wide, square, odd, movie}
	// Recently added TV hubs can contain seasons instead of shows. They
	// must use the same parent-show measurement as the library wall.
	wideSeason := &plex.Item{RatingKey: "160", ParentKey: "16", Type: "season"}
	squareSeason := &plex.Item{RatingKey: "430", ParentKey: "43", Type: "season"}
	items = append(items, wideSeason, squareSeason)
	if !a.Keep(wide) || !a.Keep(square) || !a.Keep(odd) {
		t.Fatal("an unmeasured show must stay visible")
	}
	a.measureShows(items)
	if sweeps.Load() != 1 || probes.Load() != 1 {
		t.Fatalf("sweeps %d probes %d, want one sweep and one probe for the show it missed", sweeps.Load(), probes.Load())
	}
	if a.Keep(wide) || !a.Keep(square) || a.Keep(odd) || a.Keep(movie) {
		t.Fatal("filter did not use the measured shapes")
	}
	if wide.Aspect != 1.78 {
		t.Fatalf("season 1 should decide a show, got %v", wide.Aspect)
	}
	if a.Keep(wideSeason) || !a.Keep(squareSeason) {
		t.Fatal("recently added seasons did not use their parent show's shape")
	}
	h := &Home{app: a}
	h.applyHome([]*plex.Hub{{Items: []*plex.Item{wideSeason, squareSeason, {Type: "more"}}}})
	if len(h.hubs) != 1 || len(h.hubs[0].Items) != 2 || h.hubs[0].Items[0] != squareSeason {
		t.Fatal("Home did not remove the wide season and keep the 4:3 season and See all")
	}

	// a fresh app on the same cache folder knows the answers without asking
	b := &App{Plex: plex.New(server.URL, "", dir, "test"), Cfg: &Config{FourThree: true}}
	b.SetCacheDir(dir)
	again := []*plex.Item{{RatingKey: "16", Type: "show"}, {RatingKey: "43", Type: "show"}, {RatingKey: "77", Type: "show"},
		{RatingKey: "160", ParentKey: "16", Type: "season"}, {RatingKey: "430", ParentKey: "43", Type: "season"}}
	b.measureShows(again)
	if sweeps.Load() != 1 || probes.Load() != 1 {
		t.Fatal("remembered shows were asked about again")
	}
	if b.Keep(again[0]) || !b.Keep(again[1]) || b.Keep(again[2]) || b.Keep(again[3]) || !b.Keep(again[4]) {
		t.Fatal("remembered shapes were not applied")
	}

	// with the filter off nothing is asked
	c := &App{Plex: plex.New(server.URL, "", t.TempDir(), "test"), Cfg: &Config{}}
	c.SetCacheDir(t.TempDir())
	c.measureShows([]*plex.Item{{RatingKey: "99", Type: "show"}})
	if sweeps.Load() != 1 || probes.Load() != 1 {
		t.Fatal("asked with the filter off")
	}
}

func TestSeasonAspectProbeUsesParentShow(t *testing.T) {
	var probes atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/library/metadata/16/allLeaves" {
			t.Errorf("unexpected request %s", r.URL.Path)
		}
		probes.Add(1)
		fmt.Fprint(w, `<MediaContainer><Video type="episode"><Media aspectRatio="1.78"/></Video></MediaContainer>`)
	}))
	defer server.Close()
	dir := t.TempDir()
	a := &App{Plex: plex.New(server.URL, "", dir, "test"), Cfg: &Config{FourThree: true}}
	a.SetCacheDir(dir)
	// A finished sweep missed this show's first episode.
	a.aspects.swept = make(chan struct{})
	close(a.aspects.swept)
	season := &plex.Item{RatingKey: "160", ParentKey: "16", Type: "season"}
	orphan := &plex.Item{RatingKey: "170", Type: "season"}
	a.measureHubs([]*plex.Hub{{Items: []*plex.Item{season, orphan}}})
	if probes.Load() != 1 || a.Keep(season) || !a.Keep(orphan) {
		t.Fatal("season probe must use its parent; a missing parent must stay visible")
	}
	show := &plex.Item{RatingKey: "16", Type: "show"}
	a.measureShows([]*plex.Item{show})
	if probes.Load() != 1 || a.Keep(show) {
		t.Fatal("season probe did not populate the parent show's cache")
	}
}

func TestSeasonAspectPreservesExistingValue(t *testing.T) {
	a := &App{Cfg: &Config{FourThree: true}}
	a.aspects.known = map[string]float64{"16": 1.78}
	season := &plex.Item{RatingKey: "160", ParentKey: "16", Type: "season", Aspect: 1.33}
	if unknown := a.aspects.apply([]*plex.Item{season}); len(unknown) != 0 {
		t.Fatalf("existing season aspect was treated as unknown: %d", len(unknown))
	}
	if season.Aspect != 1.33 {
		t.Fatalf("existing season aspect changed to %v", season.Aspect)
	}
}
