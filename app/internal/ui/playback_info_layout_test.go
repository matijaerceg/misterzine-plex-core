package ui

import (
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"plexcrt/internal/access"
	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/ring"
	"testing"
	"time"
)

func TestInfoConversionExplainsKnownCausesOnly(t *testing.T) {
	for reason, want := range map[string]string{
		"Audio channels": "Surround audio needs stereo",
		"6-channel audio needs stereo conversion": "Surround audio needs stereo",
		"audio truehd":                    "Audio format is not supported directly",
		"codec hevc":                      "Video format needs H.264 conversion",
		"bitrate 12000 kbit/s above 6000": "Bitrate exceeds the playback limit",
		"Subtitle burn-in":                "Subtitles are drawn into the picture",
		"/stream?ApiKey=private":          "Server required it; reason not supplied",
	} {
		if got := conversionExplanation(reason); got != want {
			t.Errorf("%q: %q", reason, got)
		}
	}
}

func TestInfoSourceAndReceivedFormatsStayDistinct(t *testing.T) {
	_, p := infoFixture(t)
	p.sourceInfo = func() playbackSource { return playbackSource{Video: "HEVC 1920x1080", Audio: "DTS 5.1"} }
	p.statusVals["audio_codec"], p.statusVals["audio_channels_in"] = "aac", "2"
	p.conversionReason = func() string { return "Video codec; Audio channels" }
	p.openInfo(time.Now())
	rows := map[string]string{}
	for i, k := range p.list.items {
		rows[k] = p.list.vals[i]
	}
	for k, w := range map[string]string{"Video format": "HEVC 1920x1080 -> H.264 1280x720", "Audio format": "DTS 5.1 -> AAC stereo", "Sound output": "Stereo PCM", "Also": "Surround audio needs stereo"} {
		if rows[k] != w {
			t.Errorf("%s: %q", k, rows[k])
		}
	}
	p.streamModes = func() (string, string) { return "Original", "Original" }
	p.openInfo(time.Now())
	for _, k := range p.list.items {
		if k == "Conversion reason" || k == "Also" {
			t.Fatal("stale reason shown for unchanged streams")
		}
	}
}

func TestInfoFullPanelFitsBothLooks(t *testing.T) {
	for _, look := range []string{"", "vcr"} {
		a, p := infoFixture(t)
		a.access = access.PlaybackTheme.Since
		a.Cfg.PlaybackLook = look
		p.sourceInfo = func() playbackSource { return playbackSource{Video: "HEVC 1920x1080", Audio: "DTS 5.1"} }
		p.conversionReason = func() string { return "Video codec; Audio channels" }
		p.statusVals["output_width"], p.statusVals["output_height"], p.statusVals["output_interlaced"] = "720", "480", "1"
		p.statusVals["video_bitrate_recent"], p.statusVals["video_bitrate_average"] = "8200000", "6700000"
		p.statusVals["refused"] = "1 unsupported SPS"
		p.statusVals["deflicker"] = "1"
		p.openInfo(time.Now())
		l := p.list
		if l.height() > OsdListH || l.hint != "" {
			t.Fatalf("panel needs scrolling: %d, %v", l.height(), l.items)
		}
		if l.width()*OsdListH*4 > ring.RegionSize {
			t.Fatal("overlay memory overflow")
		}
		l.cur = len(l.items) - 1
		l.window()
		if l.to != 0 {
			t.Fatal("last row scrolls")
		}
		var font fitter = a.F.SmallBold

		valueW := l.width() - OsdListPad - (p.safeX() + 8 + 184)
		for i, k := range l.items {
			if font.Width(k) > 172 {
				t.Errorf("label clipped: %s", k)
			}
			value := l.vals[i]

			if font.Width(value) > valueW {
				t.Errorf("value clipped (%s): %s", look, value)
			}
		}
		c := gfx.NewCanvas(l.width(), OsdListH)
		p.drawInfo(c, 0)
		if dir := os.Getenv("MISTERZINE_INFO_RENDER"); dir != "" {
			out := image.NewRGBA(image.Rect(0, 0, 640, 480))
			for y := 0; y < c.H; y++ {
				for x := 0; x < 640; x++ {
					sx := x * 720 / 640
					if sx >= c.W {
						continue
					}
					i := (y*c.W + sx) * 4
					out.SetRGBA(x, y+SafeY, color.RGBA{c.Pix[i+2], c.Pix[i+1], c.Pix[i], 255})
				}
			}
			name := look
			if name == "" {
				name = "standard"
			}
			f, err := os.Create(filepath.Join(dir, "info-"+name+".png"))
			if err != nil {
				t.Fatal(err)
			}
			err = png.Encode(f, out)
			f.Close()
			if err != nil {
				t.Fatal(err)
			}
		}
	}
}

func TestInfoRecentIssuesRebaselineAfterWorkerReset(t *testing.T) {
	_, p := infoFixture(t)
	now := time.Now()
	p.openInfo(now)
	if p.infoRecent != "Measuring..." {
		t.Fatal(p.infoRecent)
	}
	p.statusVals["late"] = "5"
	p.refreshInfo(now.Add(time.Second))
	if p.infoRecent != "2 late / 0 errors in 1.0s" {
		t.Fatal(p.infoRecent)
	}
	p.statusVals["late"] = "0"
	p.refreshInfo(now.Add(2 * time.Second))
	if p.infoRecent != "Measuring..." {
		t.Fatal(p.infoRecent)
	}
	p.refreshInfo(now.Add(3 * time.Second))
	if p.infoRecent != "0 late / 0 errors in 1.0s" {
		t.Fatal(p.infoRecent)
	}
}

func TestInfoArrowsNeverSelectOrLeave(t *testing.T) {
	_, p := infoFixture(t)
	var sent []string
	p.send = func(command string) { sent = append(sent, command) }
	p.openInfo(time.Now())
	l := p.list
	for _, key := range []input.Key{input.Up, input.Down, input.Left, input.Right} {
		for _, ev := range []input.Event{{Key: key}, {Key: key, Repeat: true}, {Key: key, Release: true}} {
			p.Key(ev, time.Now())
			if p.list != l || l.cur != 0 || l.to != 0 || l.at != 0 || len(sent) != 0 {
				t.Fatalf("Info arrow acted: %+v", ev)
			}
		}
	}
	p.Key(input.Event{Key: input.Back}, time.Now())
	l = p.list
	if l.kind != "More" || l.items[l.cur] != moreInfo {
		t.Fatal("Back must return to More's Info row")
	}
	for _, key := range []input.Key{input.Left, input.Right} {
		for _, ev := range []input.Event{{Key: key}, {Key: key, Repeat: true}, {Key: key, Release: true}} {
			p.Key(ev, time.Now())
			if p.list != l || l.items[l.cur] != moreInfo || len(sent) != 0 {
				t.Fatalf("More Info arrow acted: %+v", ev)
			}
		}
	}
	p.Key(input.Event{Key: input.Enter}, time.Now())
	if p.list.kind != moreInfo {
		t.Fatal("OK must still open Info")
	}
	p.Key(input.Event{Key: input.Enter}, time.Now())
	if p.list.kind != "More" {
		t.Fatal("OK must still return to More")
	}
}

func TestInfoHidesSelectionBarAndMoreRestoresIt(t *testing.T) {
	p := waitPlaying(t)
	p.starting = false
	p.visible = true
	p.pvTried = true
	now := time.Now()
	p.statAt = now
	p.openInfo(now)
	c := &coreOSD{barOn: true}
	defer p.closePainter(c)
	tickFields(p, c, now, 2, nil)
	if c.barOn {
		t.Fatal("Info retained selection bar")
	}
	p.Key(input.Event{Key: input.Back}, now)
	tickFields(p, c, now, 2, nil)
	if !c.barOn {
		t.Fatal("More lost its selection bar")
	}
}
