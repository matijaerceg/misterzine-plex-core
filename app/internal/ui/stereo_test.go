package ui

import "testing"

func TestAudioConversionKeepsOriginalVideoGuardAndFallback(t *testing.T) {
	f := newPlayServer(t, playVideoDirect)
	f.channels = 6
	f.decision = `<MediaContainer transcodeDecisionCode="1001"><Video><Media width="1280" height="720"><Part><Stream streamType="1" decision="copy"/><Stream streamType="2" channels="2" decision="transcode"/></Part></Media></Video></MediaContainer>`
	p, launches := fallbackPlayer(t, f, []int{workerExitNeedsTranscode, 0}, "42")
	s, err := p.Start(playItem(), 10)
	if err != nil {
		t.Fatal(err)
	}
	waitDone(t, s)
	got := launches()
	if len(got) != 2 || !hasArg(got[0], "--direct") || hasArg(got[1], "--direct") {
		t.Fatalf("copy guard/fallback: %v", got)
	}
	if !containsArgPair(got[0], "--base", "10") || hasArg(got[0], "--start-in-file") || !hasArg(got[0], "--surround-source") || hasArg(got[0], "--audio") {
		t.Fatalf("server stream used original-file semantics: %v", got[0])
	}
	q := f.requests("/video/:/transcode/universal/decision")
	if len(q) != 2 || q[0].q.Get("directStream") != "1" || q[1].q.Get("directStream") != "0" || q[1].q.Get("offset") != "42" || q[1].q.Get("maxVideoBitrate") != "6000" {
		t.Fatalf("copy fallback requests: %v", q)
	}
}
