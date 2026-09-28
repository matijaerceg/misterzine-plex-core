package ui

import (
	"crypto/sha256"
	"encoding/hex"
	"image"
	"image/color"
	"image/png"
	"io"
	"log"
	"os"
	"path/filepath"
	"plexcrt/internal/beta"
	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/updates"
	"testing"
	"time"
)

func betaTestApp(t *testing.T) *App {
	t.Helper()
	ch, b, c, k := beta.Channel, beta.Batch, beta.CodeSHA256, beta.KeySHA256
	t.Cleanup(func() { beta.Channel, beta.Batch, beta.CodeSHA256, beta.KeySHA256 = ch, b, c, k })
	sum := sha256.Sum256([]byte("012345"))
	beta.Channel, beta.Batch, beta.CodeSHA256, beta.KeySHA256 = "beta", "fixture", hex.EncodeToString(sum[:]), ""
	a := &App{Cfg: &Config{path: filepath.Join(t.TempDir(), "settings.json"), NoTheme: true}, Version: "v0.2.0-beta.3", Build: "fixture", Log: log.New(io.Discard, "", 0)}
	a.F = Fonts{Title: gfx.Load("med22"), Body: gfx.Load("med18"), Small: gfx.Load("reg16"), SmallBold: gfx.Load("med16"), Big: gfx.Load("bold28")}
	a.Mark = NewWordmark()
	a.T = gfx.NewTextCache(1, nil)
	a.stack = []Screen{&splashTestScreen{}}
	return a
}
func enterFixture(a *App, now time.Time) {
	for _, ch := range "012345" {
		a.key(input.Event{Keyboard: true, Text: ch, Key: input.None}, now)
	}
	a.key(input.Event{Key: input.Enter}, now)
}

func TestCombinationInputAndContinuation(t *testing.T) {
	a := betaTestApp(t)
	calls := 0
	now := time.Now()
	b := NewBetaAccess(a, func() { calls++ })
	a.Push(b)
	b.Key(input.Event{Key: input.Down}, now)
	if b.digits[0] != 9 {
		t.Fatal("no digit wrapping")
	}
	b.Key(input.Event{Key: input.Up, Repeat: true}, now)
	if b.digits[0] != 0 {
		t.Fatal("repeat adjustment failed")
	}
	b.Key(input.Event{Key: input.Up, Release: true}, now)
	if b.digits[0] != 0 {
		t.Fatal("release changed digit")
	}
	b.Key(input.Event{Key: input.Enter, Repeat: true}, now)
	if b.message != "" {
		t.Fatal("repeat submitted")
	}
	b.Key(input.Event{Key: input.Enter}, now)
	if b.message == "" || !b.opened.IsZero() {
		t.Fatal("incorrect code not rejected")
	}
	enterFixture(a, now)
	if beta.Check(a.betaDir()) != nil || b.opened.IsZero() || calls != 0 {
		t.Fatal("unlock did not save before animation")
	}
	b.pollRefresh(now.Add(unlockAnimation / 2))
	if calls != 0 {
		t.Fatal("continued too early")
	}
	b.pollRefresh(now.Add(unlockAnimation))
	b.pollRefresh(now.Add(unlockAnimation + time.Second))
	if calls != 1 || len(a.stack) != 1 {
		t.Fatal("continuation did not run exactly once")
	}
}

func TestCombinationCancelAndSettings(t *testing.T) {
	a := betaTestApp(t)
	now := time.Now()
	called := false
	b := NewBetaAccess(a, func() { called = true })
	a.Push(b)
	a.key(input.Event{Key: input.Back}, now)
	b.pollRefresh(now.Add(unlockAnimation + time.Second))
	if called || len(a.stack) != 1 || beta.Check(a.betaDir()) != beta.ErrLocked {
		t.Fatal("cancel changed access or continued")
	}
	options := &Options{app: a}
	a.Push(options)
	b = NewBetaAccess(a, nil)
	a.Push(b)
	enterFixture(a, now)
	b.pollRefresh(now.Add(unlockAnimation + time.Second))
	if a.top() != options {
		t.Fatal("settings unlock did not return to settings")
	}
	// Account sign-out must not delete the separately saved access receipt.
	if err := a.Cfg.SignOut(); err != nil {
		t.Fatal(err)
	}
	if beta.Check(a.betaDir()) != nil {
		t.Fatal("sign-out lost unlock")
	}
}

func TestCombinationStorageFailure(t *testing.T) {
	a := betaTestApp(t)
	if err := os.WriteFile(filepath.Join(a.betaDir(), "beta-unlocks"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	b := NewBetaAccess(a, nil)
	a.Push(b)
	enterFixture(a, time.Now())
	if !b.opened.IsZero() || b.message != "Could not save access. Check storage and retry." {
		t.Fatal("save failure reported success")
	}
}

// Optional deterministic preview output, containing synthetic data only.
func TestBetaScreenPreview(t *testing.T) {
	dir := os.Getenv("BETA_PREVIEW_DIR")
	if dir == "" {
		t.Skip("preview output not requested")
	}
	a := betaTestApp(t)
	now := time.Now()
	b := NewBetaAccess(a, nil)
	a.Push(b)
	render := func(name string) {
		c := gfx.NewCanvas(720, 480)
		a.drawScreen(c, now)
		time.Sleep(50 * time.Millisecond)
		a.drawScreen(c, now)
		out := image.NewRGBA(image.Rect(0, 0, c.W, c.H))
		for y := 0; y < c.H; y++ {
			for x := 0; x < c.W; x++ {
				i := (y*c.W + x) * 4
				out.SetRGBA(x, y, color.RGBA{c.Pix[i+2], c.Pix[i+1], c.Pix[i], 255})
			}
		}
		if err := os.MkdirAll(dir, 0700); err != nil {
			t.Fatal(err)
		}
		f, err := os.Create(filepath.Join(dir, name+".png"))
		if err != nil {
			t.Fatal(err)
		}
		defer f.Close()
		if err := png.Encode(f, out); err != nil {
			t.Fatal(err)
		}
	}
	render("beta-lock")
	b.Key(input.Event{Key: input.Enter}, now)
	render("beta-incorrect")
	enterFixture(a, now)
	now = now.Add(250 * time.Millisecond)
	render("beta-unlocked")
	a.Pop()
	a.Push(&Options{app: a, cur: 9})
	render("beta-options")
	a.chooseBetaAccess()
	render("beta-access-menu")
	a.Pop()
	a.Push(&ForgetBetaAccess{app: a})
	render("beta-forget")
	a.Pop()
	a.Pop()
	r := updates.Release{ID: "preview", Version: "0.3.0-beta.1", Channel: "beta", Notes: "A synthetic release for testing the installer and update screens.", Size: 12 << 20, Access: &updates.Access{Batch: "next", SHA256: beta.CodeSHA256}}
	a.updates.catalogue = updates.Catalogue{Schema: 1, Releases: map[string]updates.Release{"beta": r}}
	u := &Updates{app: a}
	a.Push(u)
	render("updates")
	u.release = &r
	render("update-new-code")
	u.release = nil
	for _, stage := range []string{"download", "verify", "install"} {
		a.updates.status = updates.Status{Stage: stage, Release: &r}
		render("update-" + stage)
	}
	a.updates.status = updates.Status{Stage: "ready", Release: &r}
	render("update-ready")
	a.updates.status = updates.Status{Stage: "failed", Release: &r, Message: "Update could not be prepared: the card is full. Your current version will keep working.", Detail: "Free 250 MB on the SD card and try again."}
	render("update-failed")
	a.updates.status = updates.Status{}
	a.updates.catalogue = updates.Catalogue{}
	a.updates.checking = true
	render("updates-checking")
	a.updates.checking = false
	render("updates-current")
	a.updates.checkFailed = true
	render("updates-check-failed")
	a.updates.checkFailed = false
	beta.Channel = "public"
	a.Version = "0.2.0"
	a.updates.catalogue = updates.Catalogue{Schema: 1, Releases: map[string]updates.Release{"beta": r}}
	render("updates-public")
}

func TestDigitAnimationDoesNotQueueInput(t *testing.T) {
	a := betaTestApp(t)
	b := NewBetaAccess(a, nil)
	now := time.Now()
	frame := gfx.NewCanvas(720, 480)
	for i := 0; i < 27; i++ {
		b.Key(input.Event{Key: input.Up, Repeat: i > 0}, now.Add(time.Duration(i)*time.Millisecond))
	}
	if b.digits[0] != 7 {
		t.Fatal("rapid repeats were delayed or lost")
	}
	if !b.Draw(frame, now.Add(30*time.Millisecond)) {
		t.Fatal("digit change did not animate")
	}
	b.Key(input.Event{Key: input.Up, Release: true}, now.Add(31*time.Millisecond))
	if b.Draw(frame, now.Add(time.Second)) || b.digits[0] != 7 {
		t.Fatal("animation or value continued after release")
	}
	b.Key(input.Event{Key: input.Down}, now.Add(time.Second))
	if b.digits[0] != 6 {
		t.Fatal("reversing direction was delayed")
	}
	b.Key(input.Event{Key: input.Right}, now.Add(time.Second))
	b.Key(input.Event{Key: input.Down}, now.Add(time.Second))
	if b.digits[1] != 9 {
		t.Fatal("wraparound failed")
	}
}
