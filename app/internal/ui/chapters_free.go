//go:build !premium

package ui

import (
	"image"
	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/plex"
	"time"
)

type chapterState struct{}

func (a *App) chaptersEnabled() bool                                       { return false }
func (a *App) browseChapters(it *plex.Item, play func(int))                {}
func (p *Playing) playbackButtons() []string                               { return osdButtons }
func (p *Playing) openChapters(now time.Time)                              {}
func (p *Playing) openQuickChapters(now time.Time)                         {}
func (p *Playing) chapterInput(ev input.Event, now time.Time) (bool, bool) { return false, false }
func (p *Playing) chapterOverlay(osd OSD) bool                             { return false }
func (p *Playing) chapterStatus(values map[string]string, written time.Time, pos float64) bool {
	return false
}
func (p *Playing) chapterBrowsing() bool                { return false }
func (p *Playing) discardChapterChoice()                {}
func (p *Playing) resumeChapter(now time.Time)          {}
func (p *Playing) chapterTicks(c *gfx.Canvas, y, h int) {}
func (p *Playing) chapterCaption(scrubbing bool) string { return "" }
func chapterIcon() *image.Gray                          { return nil }
