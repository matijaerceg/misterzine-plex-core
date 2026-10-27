package ui

import (
	"testing"
	"time"

	"plexcrt/internal/input"
	"plexcrt/internal/plex"
)

// episodePlaying is a playback of the middle episode of a queue of three,
// the picture up and nothing on the overlay.
func episodePlaying(t *testing.T) (*Playing, *coreOSD, time.Time) {
	t.Helper()
	p := waitPlaying(t)
	p.queue = []*plex.Item{{RatingKey: "a"}, {RatingKey: "b"}, {RatingKey: "c"}}
	p.idx = 1
	c := &coreOSD{}
	now := time.Now()
	p.framed(now)
	tickAt(p, c, now)
	return p, c, now
}

func TestShoulderHoldGoesToTheNextEpisode(t *testing.T) {
	p, c, now := episodePlaying(t)
	if keyAt(p, c, input.JumpFwd, now) {
		t.Fatal("a press of R ended the playback at once")
	}
	if p.last != "episode|1|0" {
		t.Fatalf("no pill at the press: showing %q", p.last)
	}
	half := now.Add(EpisodeHold / 2)
	if p.Key(input.Event{Key: input.JumpFwd, Repeat: true}, half) {
		t.Fatal("a repeat before the hold's time ended the playback")
	}
	tickAt(p, c, half)
	if p.last != "episode|1|120" {
		t.Fatalf("the pill is not half full at half the hold: showing %q", p.last)
	}
	at := now.Add(EpisodeHold)
	if !p.Key(input.Event{Key: input.JumpFwd, Repeat: true}, at) || p.Next != 1 {
		t.Fatalf("the hold did not go to the next episode: Next %d", p.Next)
	}
}

func TestShoulderHoldGoesToThePreviousEpisode(t *testing.T) {
	p, c, now := episodePlaying(t)
	keyAt(p, c, input.JumpBack, now)
	if p.last != "episode|-1|0" {
		t.Fatalf("no pill at the press: showing %q", p.last)
	}
	at := now.Add(EpisodeHold + 100*time.Millisecond)
	if !p.Key(input.Event{Key: input.JumpBack, Repeat: true}, at) || p.Next != -1 {
		t.Fatalf("the hold did not go to the previous episode: Next %d", p.Next)
	}
}

func TestShoulderTapDoesNothing(t *testing.T) {
	p, c, now := episodePlaying(t)
	keyAt(p, c, input.JumpFwd, now)
	at := now.Add(200 * time.Millisecond)
	if p.Key(input.Event{Key: input.JumpFwd, Release: true}, at) {
		t.Fatal("the release ended the playback")
	}
	tickAt(p, c, at)
	if p.last != "" || p.Next != 0 || p.epHold != 0 {
		t.Fatalf("after a tap: showing %q, Next %d, hold %d", p.last, p.Next, p.epHold)
	}
	// a repeat that arrives after the release does nothing either
	if p.Key(input.Event{Key: input.JumpFwd, Repeat: true}, now.Add(EpisodeHold)) || p.Next != 0 {
		t.Fatal("a stray repeat after the release went to the next episode")
	}
}

func TestShoulderHoldNeedsAnEpisodeThatWay(t *testing.T) {
	p, c, now := episodePlaying(t)
	p.idx = 2 // the last episode: no next
	keyAt(p, c, input.JumpFwd, now)
	if p.last != "" || p.epHold != 0 {
		t.Fatalf("R on the last episode put up %q", p.last)
	}
	p.idx = 0 // the first: no previous
	keyAt(p, c, input.JumpBack, now)
	if p.last != "" || p.epHold != 0 {
		t.Fatalf("L on the first episode put up %q", p.last)
	}
	if p.Key(input.Event{Key: input.JumpBack, Repeat: true}, now.Add(EpisodeHold)) || p.Next != 0 {
		t.Fatal("a hold with no episode that way ended the playback")
	}
}

func TestShoulderHoldIgnoredWithAListUp(t *testing.T) {
	p, c, now := episodePlaying(t)
	p.show(now)
	p.openList("Audio")
	keyAt(p, c, input.JumpFwd, now)
	if p.epHold != 0 {
		t.Fatal("a shoulder press with a list up started an episode hold")
	}
}
