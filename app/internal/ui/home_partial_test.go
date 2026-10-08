package ui

import (
	"errors"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"net/url"
	"plexcrt/internal/plex"
	"strings"
	"testing"
)

// A server whose Continue Watching hub fails and whose second library
// errors still shows the rows that answered; only a server that answers
// nothing fails the screen.
func TestHomeKeepsRowsThatAnswered(t *testing.T) {
	fail := map[string]bool{"/hubs": true, "/hubs/sections/2": true}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if fail[r.URL.Path] {
			http.Error(w, "boom", 500)
			return
		}
		w.Header().Set("Content-Type", "application/xml")
		switch r.URL.Path {
		case "/library/sections":
			io.WriteString(w, `<MediaContainer><Directory key="1" type="movie" title="Films"/><Directory key="2" type="show" title="Shows"/></MediaContainer>`)
		case "/hubs/sections/1":
			io.WriteString(w, `<MediaContainer><Hub hubIdentifier="movie.recentlyadded" title="Recently Added"><Video ratingKey="10" key="/library/metadata/10" type="movie" title="A"/></Hub></MediaContainer>`)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	client := plex.New(server.URL, "tok", t.TempDir(), "")
	hubs, secs, err := fetchHome(client, nil, log.New(io.Discard, "", 0))
	if err != nil {
		t.Fatalf("one failed library sank the home screen: %v", err)
	}
	if len(secs) == 0 {
		t.Fatal("the libraries did not come back with the rows")
	}
	if len(hubs) != 1 || !strings.HasSuffix(hubs[0].Title, "Films") || len(hubs[0].Items) != 2 {
		t.Fatalf("expected the Films row alone, got %+v", hubs)
	}

	fail["/hubs/sections/1"] = true
	if _, _, err := fetchHome(client, nil, log.New(io.Discard, "", 0)); err == nil {
		t.Fatal("a server that answered nothing did not fail")
	}

	fail["/library/sections"] = true
	if _, _, err := fetchHome(client, nil, log.New(io.Discard, "", 0)); err == nil {
		t.Fatal("an unreachable library list did not fail")
	}
}

func TestShortErrShowsPathAndCause(t *testing.T) {
	err := &url.Error{Op: "Get", URL: "https://1-2-3-4.plex.direct:32400/hubs?count=30&excludeFields=summary", Err: errors.New("context deadline exceeded")}
	if got := shortErr(err); got != "/hubs: context deadline exceeded" {
		t.Fatalf("got %q", got)
	}
	if got := shortErr(errors.New(strings.Repeat("x", 80))); len(got) != 70 {
		t.Fatalf("long error not shortened: %q", got)
	}
}
