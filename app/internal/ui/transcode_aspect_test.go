package ui

import (
	"fmt"
	"net/http"
	"strings"
	"testing"
)

func TestPlayerPassesSourceShapeOnlyForVideoTranscode(t *testing.T) {
	for _, mode := range []string{"transcode", "direct", "copy"} {
		t.Run(mode, func(t *testing.T) {
			video := strings.Replace(playVideoDirect, `width="1280" height="720"`, `width="720" height="480"`, 1)
			f := newPlayServer(t, video)
			if mode == "copy" {
				f.channels = 6
			}
			decision := "transcode"
			if mode == "copy" {
				decision = "copy"
			}
			f.decision = fmt.Sprintf(`<MediaContainer transcodeDecisionCode="1001"><Video><Media width="640" height="480"><Part><Stream streamType="1" decision="%s"/><Stream streamType="2" channels="2" decision="transcode"/></Part></Media></Video></MediaContainer>`, decision)
			original := f.srv.Config.Handler
			f.srv.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/video/:/transcode/universal/decision" {
					fmt.Fprint(w, f.decision)
					return
				}
				if r.URL.Path == "/library/metadata/item" {
					x := strings.Replace(fmt.Sprintf(playMetadata, video, 4000), `<Media id="1"`, `<Media id="1" aspectRatio="1.33"`, 1)
					if mode != "copy" {
						x = strings.Replace(x, `codec="ac3" index="1" channels="6"`, `codec="aac" index="1" channels="2"`, 1)
					}
					fmt.Fprint(w, x)
					return
				}
				original.ServeHTTP(w, r)
			})
			p, launches := fallbackPlayer(t, f, []int{0}, "0")
			if mode == "transcode" {
				p.Kbps = func() int { return 2000 }
			}
			s, err := p.Start(playItem(), 0)
			if err != nil {
				t.Fatal(err)
			}
			waitDone(t, s)
			got := launches()
			if len(got) != 1 {
				t.Fatalf("launches %v", got)
			}
			if mode == "transcode" {
				if !containsArgPair(got[0], "--transcode-source", "720,480,1.330000") {
					t.Fatalf("missing source shape: %v", got[0])
				}
			} else if hasArg(got[0], "--transcode-source") {
				t.Fatalf("shape hint on %s: %v", mode, got[0])
			}
		})
	}
}
