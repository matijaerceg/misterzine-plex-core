package ui

import (
	"os"
	"path/filepath"
	"plexcrt/internal/beta"
	"plexcrt/internal/input"
	"plexcrt/internal/updates"
	"strings"
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
	if v, rows := u.shows(); v != viewFailed || rows[0].label != "Try again" {
		t.Fatalf("failed: %v, %q", v, rows[0].label)
	}
	// a failure for a release this build has passed is over
	a.updates.status.Release = &updates.Release{ID: "older", Version: "0.2.0-beta.2", Channel: "beta"}
	if v, rows := u.shows(); v != viewAvailable || rows[0].label != "Update now" {
		t.Fatalf("a stale failure: %v, %q", v, rows[0].label)
	}
}

// A failure stays on screen whatever the catalogue says since: replaced by a
// newer release, or gone.
func TestUpdateFailureOutlivesTheCatalogue(t *testing.T) {
	a := betaTestApp(t)
	u := &Updates{app: a}
	failed := updates.Release{ID: "a", Version: "0.3.0-beta.1", Channel: "beta"}
	a.updates.status = updates.Status{Stage: "failed", Message: "Could not restart Plex. The previous release was restored.", Release: &failed}
	a.updates.catalogue = updates.Catalogue{Schema: 1, Releases: map[string]updates.Release{"beta": {ID: "b", Version: "0.3.0-beta.2", Channel: "beta"}}}
	if v, rows := u.shows(); v != viewFailed || rows[0].label != "Update to 0.3.0-beta.2" {
		t.Fatalf("replaced: %v, %q", v, rows[0].label)
	}
	a.updates.catalogue = updates.Catalogue{Schema: 1, Releases: map[string]updates.Release{}}
	if v, rows := u.shows(); v != viewFailed || rows[0].label != "Check again" {
		t.Fatalf("gone: %v, %q", v, rows[0].label)
	}
	// the updater never started: no release named, the failure still shows
	a.updates.status = updates.Status{Stage: "failed", Message: "The updater did not start. Run Install to repair update support."}
	if v, _ := u.shows(); v != viewFailed {
		t.Fatalf("no release named: %v", v)
	}
}

// A download left ready is not offered once the running build has caught up
// with it or passed it (a rollback, or a script installing that release):
// Restart now would put back what runs, or older.
func TestStaleReadyUpdateIsNotOffered(t *testing.T) {
	a := betaTestApp(t) // runs v0.2.0-beta.3, build "fixture"
	u := &Updates{app: a}
	for _, r := range []updates.Release{
		{ID: "fixture", Version: "0.2.0-beta.3", Channel: "beta"},
		{ID: "older", Version: "0.2.0-beta.2", Channel: "beta"},
	} {
		a.updates.status = updates.Status{Stage: "ready", Release: &r}
		if v, _ := u.shows(); v != viewCurrent || a.updateAvailable() {
			t.Fatalf("%s: view %v, update available %v", r.ID, v, a.updateAvailable())
		}
	}
	a.updates.status = updates.Status{Stage: "ready"}
	if v, _ := u.shows(); v == viewReady {
		t.Fatal("a ready download that names no release offered")
	}
}

// drain runs what a background check or status read handed back.
func drain(t *testing.T, a *App) {
	t.Helper()
	select {
	case f := <-a.later:
		f()
	case <-time.After(5 * time.Second):
		t.Fatal("nothing came back")
	}
}

// A failure with nothing left to install ends at the first check made after
// it: Check again is a way out, not a loop back to the same failure.
func TestCheckAgainEndsAFailureWithNothingToInstall(t *testing.T) {
	a := betaTestApp(t)
	a.later = make(chan func(), 4)
	file := filepath.Join(t.TempDir(), "catalogue.json")
	if err := os.WriteFile(file, []byte(`{"schema":1,"releases":{}}`), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PLEXCRT_CATALOGUE_FILE", file)
	u := &Updates{app: a}
	a.updates.status = updates.Status{Stage: "failed", Updated: float64(time.Now().Add(-time.Minute).UnixNano()) / 1e9, Message: "Could not read update status."}
	v, rows := u.shows()
	if v != viewFailed || rows[0].label != "Check again" || !a.updateAvailable() {
		t.Fatalf("before the check: %v, %q", v, rows[0].label)
	}
	rows[0].do()
	drain(t, a)
	if v, _ := u.shows(); v != viewCurrent || a.updateAvailable() {
		t.Fatalf("after a check that found nothing: %v", v)
	}
}

// A beta installed from its quiet row on a public build is tried again from
// the failure, not left to a second row; Options says it failed.
func TestQuietBetaFailureOffersTryAgain(t *testing.T) {
	a := betaTestApp(t)
	beta.Channel = "public" // betaTestApp puts it back
	a.Version = "0.2.0"
	u := &Updates{app: a}
	r := updates.Release{ID: "next", Version: "0.3.0-beta.1", Channel: "beta"}
	a.updates.catalogue = updates.Catalogue{Schema: 1, Releases: map[string]updates.Release{"beta": r}}
	a.updates.status = updates.Status{Stage: "failed", Message: "Update could not be prepared: OSError.", Release: &r}
	v, rows := u.shows()
	if v != viewFailed || len(rows) != 2 || rows[0].label != "Try again" || rows[1].label != "Beta notifications: Off" {
		t.Fatalf("view %v, %d rows, first %q", v, len(rows), rows[0].label)
	}
	label := ""
	for _, it := range (&Options{app: a}).items() {
		if strings.HasPrefix(it.label, "Updates") {
			label = it.label
		}
	}
	if label != "Updates - update failed" || !a.updateAvailable() {
		t.Fatalf("Options says %q, mark %v", label, a.updateAvailable())
	}
}

// An updater that never reports keeps its failure on screen: the status file,
// still from before the launch, does not bring the old state back.
func TestSilentUpdaterFailureStays(t *testing.T) {
	a := betaTestApp(t)
	a.later = make(chan func(), 4)
	a.updates.nextCheck = time.Now().Add(time.Hour) // no catalogue check here
	r := updates.Release{ID: "next", Version: "0.3.0-beta.1", Channel: "beta"}
	a.updates.catalogue = updates.Catalogue{Schema: 1, Releases: map[string]updates.Release{"beta": r}}
	a.updates.status = updates.Status{Stage: "download", Release: &r}
	a.updates.launched = time.Now().Add(-11 * time.Second)
	for i := 0; i < 2; i++ {
		a.updates.nextStatus = time.Time{}
		a.pollUpdates(time.Now())
		drain(t, a)
		s := a.updates.status
		if s.Stage != "failed" || s.Release == nil || s.Release.ID != "next" {
			t.Fatalf("read %d: %+v", i, s)
		}
	}
	if v, rows := (&Updates{app: a}).view(); v != viewFailed || rows[0].label != "Try again" {
		t.Fatalf("view %v, %q", v, rows[0].label)
	}
}

func writeStatus(t *testing.T, a *App, data string) {
	t.Helper()
	dir := filepath.Join(a.betaDir(), "updates")
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "status.json"), []byte(data), 0600); err != nil {
		t.Fatal(err)
	}
}
func readStatus(t *testing.T, a *App) {
	t.Helper()
	a.updates.nextStatus = time.Time{}
	a.pollUpdates(time.Now())
	drain(t, a)
}

// An updater's status counts once the file changes after the launch, whatever
// its stamp says: the board's clock may have been set back since.
func TestUpdaterStatusCountsAfterAClockStep(t *testing.T) {
	a := betaTestApp(t)
	a.later = make(chan func(), 4)
	a.updates.nextCheck = time.Now().Add(time.Hour)
	a.updates.launched, a.updates.before, a.updates.seen = time.Now(), 100, 100
	a.updates.status = updates.Status{Stage: "download"}
	writeStatus(t, a, `{"stage":"ready","updated":50,"release":{"id":"next","version":"0.3.0-beta.1","channel":"beta"}}`)
	readStatus(t, a)
	if a.prepared() == nil || !a.updates.launched.IsZero() {
		t.Fatalf("a status stamped before the launch was ignored: %+v", a.updates.status)
	}
}

// A status file that cannot be read is a failure from when it is seen, not
// from its missing stamp: a check made earlier does not end it.
func TestUnreadableStatusAfterACheckShows(t *testing.T) {
	a := betaTestApp(t)
	a.later = make(chan func(), 4)
	a.updates.nextCheck = time.Now().Add(time.Hour)
	a.updates.checked = time.Now().Add(-time.Minute)
	a.updates.catalogue = updates.Catalogue{Schema: 1, Releases: map[string]updates.Release{}}
	writeStatus(t, a, `{`)
	readStatus(t, a)
	if v, rows := (&Updates{app: a}).view(); v != viewFailed || rows[0].label != "Check again" {
		t.Fatalf("view %v, %+v", v, a.updates.status)
	}
}

// An updater that cannot be launched is a failure like any other: Options
// says so, and neither the old status file nor a check brings back the offer.
func TestUpdaterLaunchErrorIsAFailure(t *testing.T) {
	a := betaTestApp(t) // the settings folder has no updater to launch
	a.later = make(chan func(), 4)
	a.updates.nextCheck = time.Now().Add(time.Hour)
	file := filepath.Join(t.TempDir(), "catalogue.json")
	if err := os.WriteFile(file, []byte(`{"schema":1,"releases":{"public":{"id":"pub","version":"0.3.0","channel":"public","notes":"","url":"https://example.org/p.zip","db_url":"https://example.org/p.json.zip","size":1,"sha256":"`+strings.Repeat("a", 64)+`"}}}`), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PLEXCRT_CATALOGUE_FILE", file)
	a.checkUpdates(true, time.Now())
	drain(t, a)
	u := &Updates{app: a}
	_, rows := u.view()
	rows[0].do() // Update now
	s := a.updates.status
	if s.Stage != "failed" || s.Release == nil || s.Release.ID != "pub" || !strings.Contains(s.Message, "MisterZine-Plex-Install") {
		t.Fatalf("launch error: %+v", s)
	}
	readStatus(t, a)
	a.checkUpdates(true, time.Now())
	drain(t, a)
	v, rows := u.view()
	if v != viewFailed || rows[0].label != "Try again" {
		t.Fatalf("after a status read and a check: %v, %+v", v, a.updates.status)
	}
	label := ""
	for _, it := range (&Options{app: a}).items() {
		if strings.HasPrefix(it.label, "Updates") {
			label = it.label
		}
	}
	if label != "Updates - update failed" {
		t.Fatalf("Options says %q", label)
	}
}
