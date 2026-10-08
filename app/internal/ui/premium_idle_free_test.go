//go:build !premium

package ui

import (
	"testing"
	"time"
)

// The public build's hooks change nothing.
func TestPublicHooksTakeNothing(t *testing.T) {
	a, out, s := dimApp()
	t0 := time.Now()
	for _, waiting := range []bool{true, false} {
		if a.premiumIdle(t0, waiting, time.Hour) {
			t.Fatal("the public build took the screen")
		}
	}
	items := []option{{label: "One"}, {label: "Two"}}
	if got := a.premiumOptions(items); len(got) != 2 || got[0].label != "One" || got[1].label != "Two" {
		t.Fatalf("the public build changed the Options rows: %+v", got)
	}
	a.premiumStart()
	if PremiumVersion() != "" || len(a.stack) != 1 || a.top() != s || out.sets != 0 {
		t.Fatal("the public build's hooks changed the app")
	}
}
