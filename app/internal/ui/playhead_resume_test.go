package ui

import (
	"plexcrt/internal/input"
	"strings"
	"testing"
	"time"
)

func TestTimelineOKResumesPausedScrub(t *testing.T) {
	for _, previews := range []bool{false, true} {
		for _, afterGrace := range []bool{false, true} {
			t.Run(itoa(btoi(previews))+"/"+itoa(btoi(afterGrace)), func(t *testing.T) {
				p, _, _ := previewPlaying(t)
				if !previews {
					p.preview = nil
				}
				var commands []string
				p.send = func(command string) { commands = append(commands, command) }
				c := &coreOSD{}
				now := time.Now()
				p.framed(now)
				keyAt(p, c, input.Start, now)
				keyAt(p, c, input.Up, now.Add(time.Millisecond))
				now = now.Add(10 * time.Millisecond)
				keyAt(p, c, input.Right, now)
				now = tickFields(p, c, now, 90, nil)
				p.Key(input.Event{Key: input.Right, Release: true}, now)
				if afterGrace {
					now = tickFields(p, c, now, 60, nil)
				}
				if !p.paused {
					t.Fatal("releasing the scrub resumed a user pause")
				}
				commands = nil
				keyAt(p, c, input.Enter, now.Add(time.Millisecond))
				if p.paused {
					t.Fatal("OK on the playhead left playback paused")
				}
				if len(commands) != 2 || commands[0] != "resume" || !strings.HasPrefix(commands[1], "seek ") {
					t.Fatalf("OK sent %q; want resume followed by seek", commands)
				}
				p.Key(input.Event{Key: input.Enter, Repeat: true}, now.Add(2*time.Millisecond))
				p.Key(input.Event{Key: input.Enter, Release: true}, now.Add(3*time.Millisecond))
				if len(commands) != 2 {
					t.Fatalf("OK repeat/release sent extra commands: %q", commands)
				}
			})
		}
	}
}
