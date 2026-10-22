package ui

import (
	"testing"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
)

// The screen beneath a chooser shows dimmed as it does behind the menu,
// and the frames it borrowed go back when it closes.
func TestChooserDimsTheScreenBeneathAndGivesItsFramesBack(t *testing.T) {
	a := &App{F: Fonts{Title: gfx.Load("bold28"), Body: gfx.Load("med18")}}
	under := &splashTestScreen{}
	a.stack = []Screen{under}
	ch := NewChooser(a, under, "Audio", []string{"English", "French"}, 0, func(int) {})
	a.Push(ch)
	c := gfx.NewCanvas(720, 480)
	ch.Draw(c, time.Now())
	// splashTestScreen fills 0x204060: BGRx 60 40 20, each scaled by 56/256
	want := [3]byte{0x60 * BackBright >> 8, 0x40 * BackBright >> 8, 0x20 * BackBright >> 8}
	o := (240*c.W + 700) * 4 // right of the panel
	if got := [3]byte{c.Pix[o], c.Pix[o+1], c.Pix[o+2]}; got != want {
		t.Fatalf("dimmed background %v, want %v", got, want)
	}
	snap, page := ch.snap, ch.page
	ch.Key(input.Event{Key: input.Left}, time.Now())
	if len(a.stack) != 1 || ch.snap != nil || ch.page != nil {
		t.Fatal("closing kept the chooser's frames")
	}
	if got := gfx.TakeCanvas(720, 480); got != snap && got != page {
		t.Fatal("the next pop-over did not get a spare frame")
	}
}
