package plex

import (
	"context"
	"encoding/xml"
	"io"
	"net/url"
	"strings"
)

// Search returns local movie/show matches, capped per hub by the server.
func (c *Client) Search(ctx context.Context, query string) ([]*Item, error) {
	query = strings.TrimSpace(query)
	if query == "" {
		return nil, nil
	}
	r, err := c.req("/hubs/search", url.Values{"query": {query}, "limit": {"30"}, "type": {"1,2"}, "includeCollections": {"0"}, "includeExternalMedia": {"0"}})
	if err != nil {
		return nil, err
	}
	resp, err := c.http.Do(r.WithContext(ctx))
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, c.failed("search", resp.StatusCode)
	}
	var mc xmlContainer
	if err := xml.NewDecoder(io.LimitReader(resp.Body, 4<<20)).Decode(&mc); err != nil {
		return nil, err
	}
	var out []*Item
	seen := map[string]bool{}
	for _, hub := range mc.Hubs {
		for _, x := range hub.Items {
			if (x.Type != "movie" && x.Type != "show") || x.RatingKey == "" || !strings.HasPrefix(x.Key, "/library/metadata/") || seen[x.RatingKey] {
				continue
			}
			seen[x.RatingKey] = true
			out = append(out, x.item())
		}
	}
	return out, nil
}
