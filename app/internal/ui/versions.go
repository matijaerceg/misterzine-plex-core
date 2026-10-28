package ui

import (
	"cmp"
	"fmt"
	"slices"
	"time"

	"plexcrt/internal/plex"
)

// Versions: a movie or episode the server holds in several files. A play
// from the start asks which (the chooser, with the version the item would
// play unasked selected: preferredVersion); a resume plays the version that
// last started, asking only when nobody recorded one (the server keeps one
// resume point for all versions and no word of which played). Later items
// of a queue, and shuffles, never ask (quietVersion). The Version row of the
// movie page and the episode actions changes it for the next play.

// versionCap is the video cap and the Direct play setting the versions are
// judged at.
func (a *App) versionCap() (kbps int, direct bool) {
	if a.Cfg == nil {
		return 0, true
	}
	return a.Cfg.BitrateKbps(), a.Cfg.DirectPlay()
}

// rememberedVersion is the version recorded for an item (noteVersion)
// while the item still has it, "" otherwise.
func (a *App) rememberedVersion(it *plex.Item) string {
	if a.Cfg == nil {
		return ""
	}
	ch, ok := a.Cfg.Versions[it.RatingKey]
	if !ok || ch.Media == "" || plex.VersionIndex(it.Versions, ch.Media) < 0 {
		return ""
	}
	return ch.Media
}

// versionKind is the kind of version an episode's show last started with,
// "" for none (and for a movie).
func (a *App) versionKind(it *plex.Item) string {
	if a.Cfg == nil || it.Type != "episode" {
		return ""
	}
	return a.Cfg.Streams[streamChoiceKey(it)].VersionKind
}

// preferredVersion is the version an item would play unasked, and why: the
// one recorded for it, else the first of its show's last kind, else the
// one that suits the cores (plex.PickVersion).
func (a *App) preferredVersion(it *plex.Item) (int, string) {
	if id := a.rememberedVersion(it); id != "" {
		return plex.VersionIndex(it.Versions, id), "remembered"
	}
	if i := plex.MatchVersion(it.Versions, a.versionKind(it)); i >= 0 {
		return i, "matched"
	}
	kbps, direct := a.versionCap()
	return plex.PickVersion(it.Versions, kbps, direct), "our pick"
}

// applyVersion puts in force the version an item plays: keep (the one it
// had) while the item still has it, else preferredVersion. A listing's
// record, without its versions' streams, keeps its first: the pick needs
// them.
func (a *App) applyVersion(it *plex.Item, keep string) {
	if len(it.Versions) < 2 {
		return
	}
	if keep != "" && it.UseVersion(keep) {
		return
	}
	if !it.Versions[0].Detailed() {
		return
	}
	i, _ := a.preferredVersion(it)
	it.UseVersion(it.Versions[i].ID)
}

// useVersion puts a version in force and marks the tracks chosen for the
// item's movie or show on its tracks.
func (a *App) useVersion(it *plex.Item, id string) {
	if it.UseVersion(id) {
		a.applyStreams(it)
	}
}

// noteVersion records an item's version (and for an episode its kind, for
// the show's next episodes), keeping the newest VersionsKept.
func (a *App) noteVersion(it *plex.Item, id string) {
	i := plex.VersionIndex(it.Versions, id)
	if a.Cfg == nil || id == "" || i < 0 {
		return
	}
	if a.Cfg.Versions == nil {
		a.Cfg.Versions = map[string]VersionChoice{}
	}
	a.Cfg.Versions[it.RatingKey] = VersionChoice{Media: id, At: time.Now().Unix()}
	if over := len(a.Cfg.Versions) - VersionsKept; over > 0 {
		keys := make([]string, 0, len(a.Cfg.Versions))
		for k := range a.Cfg.Versions {
			keys = append(keys, k)
		}
		slices.SortFunc(keys, func(x, y string) int {
			return cmp.Compare(a.Cfg.Versions[x].At, a.Cfg.Versions[y].At)
		})
		for _, k := range keys[:over] {
			if k != it.RatingKey {
				delete(a.Cfg.Versions, k)
			}
		}
	}
	if kind := it.Versions[i].Kind(); it.Type == "episode" && kind != "" {
		key := streamChoiceKey(it)
		ch := a.Cfg.Streams[key]
		ch.VersionKind = kind
		if a.Cfg.Streams == nil {
			a.Cfg.Streams = map[string]StreamChoice{}
		}
		a.Cfg.Streams[key] = ch
	}
	a.saveSettings()
}

// forgetVersion drops an item's recorded version: it finished, or was
// marked watched, and its next play is from the start.
func (a *App) forgetVersion(it *plex.Item) {
	if a.Cfg == nil {
		return
	}
	if _, ok := a.Cfg.Versions[it.RatingKey]; ok {
		delete(a.Cfg.Versions, it.RatingKey)
		a.saveSettings()
	}
}

// firstVersion settles the version a queue's first item plays. A play from
// the start asks (the chooser), as does a resume nobody recorded a version
// for; a resume of a recorded version, and a shuffle, do not. It returns
// how the version was settled ("" for an item with one), or held while the
// chooser is up or the item's versions are read: play then starts it,
// told how.
func (a *App) firstVersion(it *plex.Item, offset int, shuffled bool, play func(why string)) (why string, held bool) {
	if len(it.Versions) < 2 {
		return "", false
	}
	if shuffled {
		return a.quietVersion(it), false
	}
	resume := offset > 0 || offset < 0 && it.ViewOffset > 0
	if id := a.rememberedVersion(it); resume && id != "" {
		a.useVersion(it, id)
		return "remembered", false
	}
	if it.Versions[0].Detailed() {
		a.askVersion(it, play)
		return "", true
	}
	// a listing's item: the lines need the versions' streams
	a.readVersions(it, func() {
		if len(it.Versions) < 2 {
			play("") // one version left: nothing to ask
			return
		}
		a.askVersion(it, play)
	})
	return "", true
}

// askVersion opens the chooser for the version to play, the one the item
// would play unasked selected; a pick plays it, Back plays nothing.
func (a *App) askVersion(it *plex.Item, play func(why string)) {
	kbps, direct := a.versionCap()
	cur, _ := a.preferredVersion(it)
	a.Push(NewChooser(a, a.top(), "Play which version?", plex.VersionLabels(it.Versions, kbps, direct), cur, func(i int) {
		a.useVersion(it, it.Versions[i].ID)
		play("picked")
	}))
}

// chooseVersion opens the chooser for an item's Version row over the
// current screen: a pick puts the version in force and records it for the
// next play, then done runs.
func (a *App) chooseVersion(it *plex.Item, done func()) {
	kbps, direct := a.versionCap()
	cur := 0
	if v := it.Version(); v != nil {
		cur = max(plex.VersionIndex(it.Versions, v.ID), 0)
	}
	a.Push(NewChooser(a, a.top(), "Version", plex.VersionLabels(it.Versions, kbps, direct), cur, func(i int) {
		a.useVersion(it, it.Versions[i].ID)
		a.noteVersion(it, it.Versions[i].ID)
		done()
	}))
}

// quietVersion settles the version of a queue's later item, or a
// shuffle's, unasked (preferredVersion) and returns why ("" for an item
// with one version). A listing's item without its versions' streams cannot
// be judged here: our pick is left to its start, which reads the item's
// record anyway (Session.fetchStreams).
func (a *App) quietVersion(it *plex.Item) string {
	if len(it.Versions) < 2 {
		return ""
	}
	i, why := a.preferredVersion(it)
	if why == "our pick" && !it.Versions[0].Detailed() {
		it.VersionID = ""
		return why
	}
	a.useVersion(it, it.Versions[i].ID)
	return why
}

// startingVersion logs the version an item starts with and how it was
// settled, and records it so a resume plays it again.
func (a *App) startingVersion(it *plex.Item, why string) {
	if len(it.Versions) < 2 {
		return
	}
	a.Log.Print(versionLog(it, why))
	a.noteVersion(it, it.VersionID)
}

// versionLog is the log line of the version an item starts with.
func versionLog(it *plex.Item, why string) string {
	if it.VersionID == "" {
		return fmt.Sprintf("version of %d: %s, made once the start reads the record", len(it.Versions), why)
	}
	return versionLine(it.Versions, it.VersionID) + ", chosen: " + why
}

// versionLine names a version for the logs: "version 2 of 3 (media 12)
// 480p h264".
func versionLine(vs []plex.Version, id string) string {
	i := plex.VersionIndex(vs, id)
	if i < 0 {
		return fmt.Sprintf("version ? of %d (media %s)", len(vs), id)
	}
	return fmt.Sprintf("version %d of %d (media %s) %s", i+1, len(vs), id, vs[i].Kind())
}

// versionInfo is Playback info's Version value: "2 of 3, 480p H.264".
func versionInfo(vs []plex.Version, id string) string {
	i := plex.VersionIndex(vs, id)
	if i < 0 {
		return ""
	}
	return fmt.Sprintf("%d of %d, %s", i+1, len(vs), plex.VersionNames(vs)[i])
}

// versionRow is the Version action of an item with versions whose streams
// are in ("Version: 720p H.264"), "" otherwise.
func versionRow(it *plex.Item) string {
	if len(it.Versions) < 2 || !it.Versions[0].Detailed() {
		return ""
	}
	i := max(plex.VersionIndex(it.Versions, it.Version().ID), 0)
	return "Version: " + plex.VersionNames(it.Versions)[i]
}

// versionRead is an item whose versions a start is reading.
type versionRead struct{ it *plex.Item }

// readVersions reads an item's record in the background, with the start
// indicator running and Back giving up as while a shuffle lists its
// episodes (see key), then takes it and runs then.
func (a *App) readVersions(it *plex.Item, then func()) {
	client := a.Plex
	if client == nil {
		then()
		return
	}
	w := &versionRead{it: it}
	a.reading, a.Starting = w, time.Now()
	a.dirty = true
	key := it.RatingKey
	go func() {
		fresh, err := client.Item(key)
		// waits for room rather than being dropped, as a shuffle's answer does
		a.later <- func() {
			if a.reading != w {
				return // given up
			}
			a.reading, a.Starting = nil, time.Time{}
			a.dirty = true
			if err != nil {
				a.Log.Printf("versions of %s: %v", it.Title, err)
				a.Notice, a.NoticeAt = "Could not read this title's versions.", time.Now()
				return
			}
			a.takeFresh(it, fresh)
			then()
		}
		a.WakeUp()
	}()
}
