package ui

import (
	"crypto/sha256"
	"encoding/hex"
	"testing"
	"time"

	"plexcrt/internal/beta"
	"plexcrt/internal/input"
)

// The supporter entry and the beta's playback entry take the same code:
// entered on either, it opens the other too, so nobody is asked twice.
func TestOneCodeServesBothEntries(t *testing.T) {
	registerTestGrant(t, 999905, "112233", "fixture")
	a := betaTestApp(t)
	sum := sha256.Sum256([]byte("112233"))
	beta.CodeSHA256 = hex.EncodeToString(sum[:]) // this beta's code is the supporter code
	enter := func(code string) {
		a.Push(NewCodeEntry(a, nil))
		for _, ch := range code {
			a.key(input.Event{Keyboard: true, Text: ch, Key: input.None}, time.Now())
		}
		a.key(input.Event{Key: input.Enter}, time.Now())
	}
	enter("112233")
	if a.Access() != 999905 {
		t.Fatalf("access after the supporter entry: %v", a.Access())
	}
	if err := beta.Current().Check(a.betaDir()); err != nil {
		t.Fatalf("playback still locked after the supporter entry: %v", err)
	}
	// and a code that is not this beta's still unlocks the extras
	registerTestGrant(t, 999907, "445566", "")
	a = betaTestApp(t)
	beta.CodeSHA256 = hex.EncodeToString(sum[:])
	enter("445566")
	if a.Access() != 999907 || beta.Current().Check(a.betaDir()) == nil {
		t.Fatalf("a later code: access %v, playback %v", a.Access(), beta.Current().Check(a.betaDir()))
	}
}
