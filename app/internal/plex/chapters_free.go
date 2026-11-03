//go:build !premium

package plex

import (
	"net/url"
	"plexcrt/internal/chapters"
)

func (x *xmlItem) chaptersFor(index int) []chapters.Chapter { return nil }
func chapterMetadataQuery(q url.Values) url.Values          { return q }
