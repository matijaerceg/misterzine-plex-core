package ui

import (
	"testing"
	"time"

	"plexcrt/internal/input"
	"plexcrt/internal/plex"
)

func hasOption(items []option, label string) bool {
	for _, row := range items {
		if row.label == label {
			return true
		}
	}
	return false
}

func TestHomeGateHidesActionsThatCouldBypassSelection(t *testing.T) {
	a := betaTestApp(t)
	a.Cfg.Token = "account-token"
	a.Cfg.HomeUserID = "owner"
	o := &Options{app: a}
	for _, label := range []string{"Switch user", "Choose server again", "Sign in automatically"} {
		if hasOption(o.items(), label) {
			t.Fatalf("%q available before user selection", label)
		}
	}
	if !hasOption(o.items(), "Sign out") {
		t.Fatal("sign-out missing from gate")
	}
	a.Plex = &plex.Client{}
	a.Cfg.HomePickerNeeded = true
	if !hasOption(o.items(), "Switch user") || !hasOption(o.items(), "Sign in automatically") {
		t.Fatal("full selected user cannot switch or enable automatic sign-in")
	}
	a.Cfg.HomeRestricted = true
	if hasOption(o.items(), "Sign in automatically") {
		t.Fatal("restricted user may change automatic sign-in")
	}
}

func TestHomePINControllerEntryAndBack(t *testing.T) {
	h := &HomeUsers{phase: "pin", user: plex.HomeUser{ID: "child", Protected: true}}
	h.Key(input.Event{Key: input.Up}, time.Now())
	h.Key(input.Event{Key: input.Enter}, time.Now())
	h.Key(input.Event{Key: input.Down}, time.Now())
	h.Key(input.Event{Key: input.Enter}, time.Now())
	if h.pin != "10" {
		t.Fatalf("controller digits = %q, want 10", h.pin)
	}
	h.Back()
	if h.pin != "1" || h.phase != "pin" {
		t.Fatal("Back should erase one digit")
	}
	h.Back()
	h.Back()
	if h.pin != "" || h.phase != "users" {
		t.Fatal("Back on empty PIN should return to users")
	}
}
