package ui

import (
	"context"
	"fmt"
	"plexcrt/internal/plex"
	"strings"
)

func (a *App) openItem(original *plex.Item, at string) {
	item := *original
	client := a.Plex
	if item.Type == "movie" && item.Summary != "" && item.PartID != "" {
		a.Push(NewPreplay(a, original))
		return
	}
	a.requestServer(func(ctx context.Context) (func(), error) {
		it := &item
		if it.Type == "movie" || it.Type == "show" || (it.Type == "episode" && (it.GrandKey == "" || it.ParentKey == "")) {
			fresh, err := client.ItemContext(ctx, it.RatingKey)
			if err != nil {
				return nil, err
			}
			it = fresh
		}
		if it.Type == "movie" {
			return func() { a.takeFresh(original, it); a.Push(NewPreplay(a, original)) }, nil
		}
		show := it
		seasonKey, episodeKey := "", at
		if it.Type == "season" || it.Type == "episode" {
			showKey := it.ParentKey
			seasonKey = it.RatingKey
			if it.Type == "episode" {
				showKey = it.GrandKey
				seasonKey = it.ParentKey
				episodeKey = it.RatingKey
			}
			var err error
			show, err = client.ItemContext(ctx, showKey)
			if err != nil {
				return nil, err
			}
		}
		seasons, err := client.ItemsContext(ctx, show.Key, nil, 500)
		if err != nil {
			return nil, err
		}
		filtered := seasons[:0]
		for _, s := range seasons {
			if !strings.HasSuffix(s.Key, "/allLeaves") {
				filtered = append(filtered, s)
			}
		}
		seasons = filtered
		if len(seasons) == 0 {
			return nil, fmt.Errorf("no seasons available")
		}
		si := 0
		for i, s := range seasons {
			if s.RatingKey == seasonKey {
				si = i
			}
		}
		return func() {
			if seasonKey != "" || len(seasons) == 1 {
				a.Push(NewShowInSeason(a, show, seasons, si, episodeKey))
			} else {
				a.Push(NewShow(a, show, seasons))
			}
		}, nil
	})
}

func (a *App) markItem(it *plex.Item, watched bool, done func()) {
	client, key := a.Plex, it.RatingKey
	a.requestServer(func(ctx context.Context) (func(), error) {
		if err := client.ScrobbleContext(ctx, key, watched); err != nil {
			return nil, err
		}
		fresh, err := client.ItemContext(ctx, key)
		if err != nil {
			return nil, err
		}
		return func() {
			a.takeFresh(it, fresh)
			if watched {
				a.forgetVersion(it) // its next play is from the start
			}
			done()
		}, nil
	})
}
