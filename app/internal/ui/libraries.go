package ui

import (
	"slices"

	"plexcrt/internal/plex"
)

// LibraryHidden reports whether a library is left off Home, the menu and
// search (Options > Libraries).
func (c *Config) LibraryHidden(key string) bool {
	return c != nil && slices.Contains(c.HiddenLibraries, key)
}

// SetLibraryHidden hides or shows a library. The list is made anew, so a
// copy of the settings taken before (Options' undo of a failed save)
// keeps its own.
func (c *Config) SetLibraryHidden(key string, hidden bool) {
	var next []string
	for _, k := range c.HiddenLibraries {
		if k != key {
			next = append(next, k)
		}
	}
	if hidden {
		next = append(next, key)
	}
	c.HiddenLibraries = next
}

// shownSections is secs without the hidden ones.
func shownSections(secs []plex.Section, hidden []string) []plex.Section {
	var out []plex.Section
	for _, s := range secs {
		if !slices.Contains(hidden, s.Key) {
			out = append(out, s)
		}
	}
	return out
}

// hiddenLibraries is a copy of the hidden keys for a Home fetch, which
// owns its data off-thread.
func (a *App) hiddenLibraries() []string {
	if a.Cfg == nil {
		return nil
	}
	return slices.Clone(a.Cfg.HiddenLibraries)
}

// libraries are the libraries the menu lists: those the app has loaded,
// less the hidden ones.
func (a *App) libraries() []plex.Section {
	if a.Cfg == nil {
		return a.secs
	}
	return shownSections(a.secs, a.Cfg.HiddenLibraries)
}

// libraryShown reports whether an item's library is shown; an item whose
// library the server did not name is.
func (a *App) libraryShown(it *plex.Item) bool {
	return it.Library == "" || !a.Cfg.LibraryHidden(it.Library)
}

// allLibrariesHidden reports that there are libraries and none is shown.
func (a *App) allLibrariesHidden() bool {
	return len(a.secs) > 0 && len(a.libraries()) == 0
}

// libraryOptions adds Options' group of libraries: a toggle per library the
// app has loaded. With none loaded (signed out, the server not reached
// yet) there is no group.
func (a *App) libraryOptions(items []option) []option {
	if a.Plex == nil || len(a.secs) == 0 {
		return items
	}
	cfg := a.Cfg
	items = append(items, optionGap())
	for _, s := range a.secs {
		key := s.Key
		items = append(items, option{label: "Show " + a.libraryLabel(s),
			get: func() bool { return !cfg.LibraryHidden(key) }, set: func(v bool) { cfg.SetLibraryHidden(key, !v) },
			after: a.librariesChanged, busy: a.homeUpdating})
	}
	return items
}

// librariesChanged applies a library hidden or shown: Home fetches its
// rows again (a hidden library's row goes at once; one shown again comes
// with the fetch) and the menu under Options lists what is left.
func (a *App) librariesChanged() {
	a.Reconfigured()
	for _, s := range a.stack {
		switch s := s.(type) {
		case *Home:
			if s.home {
				s.dropHiddenRows()
			}
		case *Drawer:
			s.relist(a.menuItems())
		}
	}
}

// dropHiddenRows takes the rows of hidden libraries off Home: a library's
// row is the one that ends in its See all tile.
func (h *Home) dropHiddenRows() {
	kept := make([]*plex.Hub, 0, len(h.hubs))
	for _, hub := range h.hubs {
		if !h.app.Cfg.LibraryHidden(rowLibrary(hub)) {
			kept = append(kept, hub)
		}
	}
	if len(kept) != len(h.hubs) {
		h.applyHome(kept)
	}
}

// rowLibrary is the key of the library a Home row is from, "" for the
// rows that are not one library's (Continue Watching).
func rowLibrary(hub *plex.Hub) string {
	if n := len(hub.Items); n > 0 && hub.Items[n-1].Type == "more" {
		return hub.Items[n-1].Key
	}
	return ""
}

// relist swaps in the menu's entries again, the cursor staying on the
// entry it was on (Options, when a library was hidden there) and
// otherwise going where the new list opens.
func (d *Drawer) relist(items []*plex.Item, cur int) {
	if d.cur >= 0 && d.cur < len(d.items) {
		was := d.items[d.cur]
		for i, it := range items {
			if it.Type == was.Type && it.Key == was.Key {
				cur = i
				break
			}
		}
	}
	d.items = items
	d.cur = max(0, min(len(items)-1, cur))
	d.scroll()
	if d.page != nil {
		d.compose()
		d.key = d.composeKey()
	}
}
