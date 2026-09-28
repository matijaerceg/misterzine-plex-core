package ui

import (
	"plexcrt/internal/beta"
	"plexcrt/internal/input"
	"plexcrt/internal/updates"
	"testing"
	"time"
)

func TestTargetCodeDoesNotUnlockCurrentRelease(t *testing.T) {
	a := betaTestApp(t)
	r := updates.Release{Version: "0.3.0-beta.1", Channel: "beta", Access: &updates.Access{Batch: "next-fixture", SHA256: beta.CodeSHA256}}
	u := &Updates{app: a, release: &r}
	a.Push(u)
	_, rows := u.view()
	rows[0].do()
	b := a.top().(*BetaAccess)
	now := time.Now()
	enterFixture(a, now)
	if b.opened.IsZero() || r.Requirement().Check(a.betaDir()) != nil {
		t.Fatal("target receipt was not saved")
	}
	if beta.Check(a.betaDir()) == nil {
		t.Fatal("target code unlocked current access batch")
	}
	// Stop before completion; no update worker should be launched by this fixture.
}
func TestUpdateChoicesAndCancel(t *testing.T) {
	a := betaTestApp(t)
	u := &Updates{app: a}
	if v, rows := u.view(); v != viewCurrent || len(rows) != 1 {
		t.Fatal("unpublished channels shown")
	}
	r := updates.Release{ID: "next", Version: "0.3.0-beta.1", Channel: "beta", Access: &updates.Access{Batch: "next", SHA256: beta.CodeSHA256}}
	a.updates.catalogue = updates.Catalogue{Schema: 1, Releases: map[string]updates.Release{"beta": r}}
	if !a.updateAvailable() {
		t.Fatal("new beta not indicated")
	}
	v, rows := u.shows()
	if v != viewAvailable || rows[0].label != "Update now" {
		t.Fatalf("an update is not the lead: %v %q", v, rows[0].label)
	}
	u.Key(input.Event{Key: input.Enter}, time.Now())
	if u.release == nil {
		t.Fatal("new code confirmation missing")
	}
	// a press before the code screen is drawn was meant for the screen before
	u.Key(input.Event{Key: input.Enter}, time.Now())
	if _, ok := a.top().(*BetaAccess); ok || u.release == nil {
		t.Fatal("a press acted on a screen not yet drawn")
	}
	u.shows()
	u.cur = 2
	u.Key(input.Event{Key: input.Enter}, time.Now())
	if u.release != nil || a.updates.status.Busy() {
		t.Fatal("cancel started update")
	}
}

// The running release, another build of its version and older releases are
// never offered: there is no reinstall or downgrade from Updates.
func TestUpdatesOffersOnlyNewerReleases(t *testing.T) {
	a := betaTestApp(t) // runs v0.2.0-beta.3, build "fixture"
	u := &Updates{app: a}
	for _, c := range []map[string]updates.Release{
		{"beta": {ID: "fixture", Version: "0.2.0-beta.3", Channel: "beta"}},
		{"beta": {ID: "rebuild", Version: "0.2.0-beta.3", Channel: "beta"}},
		{"beta": {ID: "old", Version: "0.2.0-beta.2", Channel: "beta"}, "public": {ID: "pub", Version: "0.1.0", Channel: "public"}},
	} {
		a.updates.catalogue = updates.Catalogue{Schema: 1, Releases: c}
		if v, rows := u.view(); len(a.offered()) != 0 || v != viewCurrent || len(rows) != 1 || a.updateAvailable() {
			t.Fatalf("%v: offered %d, view %v, %d rows", c, len(a.offered()), v, len(rows))
		}
	}
	// newer in both channels: the running build's own channel leads
	a.updates.catalogue.Releases = map[string]updates.Release{
		"beta":   {ID: "next", Version: "0.3.0-beta.1", Channel: "beta"},
		"public": {ID: "pub", Version: "0.2.0", Channel: "public"},
	}
	v, rows := u.view()
	if v != viewAvailable || a.nextUpdate().ID != "next" || len(rows) != 2 || rows[1].label != "Install Stable 0.2.0" {
		t.Fatalf("view %v, rows %d", v, len(rows))
	}
}

func TestPublicBuildListsTheBetaQuietly(t *testing.T) {
	a := betaTestApp(t)
	beta.Channel = "public" // betaTestApp puts it back
	a.Version = "0.2.0"
	u := &Updates{app: a}
	a.updates.catalogue = updates.Catalogue{Schema: 1, Releases: map[string]updates.Release{"beta": {ID: "next", Version: "0.3.0-beta.1", Channel: "beta"}}}
	v, rows := u.view()
	if v != viewCurrent || a.updateAvailable() || len(rows) != 3 || rows[1].label != "Install Beta 0.3.0-beta.1" || rows[2].label != "Beta notifications: Off" {
		t.Fatalf("view %v, rows %d", v, len(rows))
	}
	rows[2].do()
	if v, _ := u.view(); !a.Cfg.EarlyAccessUpdates || v != viewAvailable || !a.updateAvailable() {
		t.Fatal("beta notifications on did not make the beta the update")
	}
}

func TestUpdateViewsFollowTheUpdater(t *testing.T) {
	a := betaTestApp(t)
	u := &Updates{app: a}
	r := updates.Release{ID: "next", Version: "0.3.0-beta.1", Channel: "beta"}
	a.updates.checking = true
	if v, rows := u.shows(); v != viewChecking || len(rows) != 0 {
		t.Fatalf("checking: %v, %d rows", v, len(rows))
	}
	a.updates.checking, a.updates.checkFailed = false, true
	if v, rows := u.shows(); v != viewCheckFailed || rows[0].label != "Try again" {
		t.Fatalf("a failed check: %v", v)
	}
	// an update already known is still offered when the next check fails
	a.updates.catalogue = updates.Catalogue{Schema: 1, Releases: map[string]updates.Release{"beta": r}}
	if v, _ := u.shows(); v != viewAvailable {
		t.Fatalf("a known update behind a failed check: %v", v)
	}
	a.updates.status = updates.Status{Stage: "download", Release: &r}
	if v, rows := u.shows(); v != viewWorking || len(rows) != 0 {
		t.Fatalf("working: %v, %d rows", v, len(rows))
	}
	u.Key(input.Event{Key: input.Enter}, time.Now()) // nothing to press, nothing to panic
	u.Key(input.Event{Key: input.Down}, time.Now())
	a.updates.status = updates.Status{Stage: "ready", Release: &r}
	if v, rows := u.shows(); v != viewReady || u.cur != 0 || rows[0].label != "Restart now" {
		t.Fatalf("ready: %v, focus on row %d", v, u.cur)
	}
	a.updates.status = updates.Status{Stage: "failed", Message: "Update could not be prepared: no space. Your current version will keep working.", Release: &r}
	if v, rows := u.shows(); v != viewAvailable || rows[0].label != "Try again" {
		t.Fatalf("failed: %v, %q", v, rows[0].label)
	}
	// a failure about another release does not change the offer
	a.updates.status.Release = &updates.Release{ID: "older", Version: "0.2.0-beta.9", Channel: "beta"}
	if _, rows := u.shows(); rows[0].label != "Update now" {
		t.Fatalf("a stale failure: %q", rows[0].label)
	}
}
