package plex

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// The plex.tv side: signing in with a link code, and finding the
// account's servers. Nothing here logs a token.

// Product is what plex.tv and the servers see this client as.
const Product = "MisterZine Plex Core"

// Pin is a sign-in code from plex.tv/link.
type Pin struct {
	ID      int
	Code    string
	Expires time.Time
}

// Server is one of the account's media servers with its connections.
type Server struct {
	Name        string
	ID          string // its clientIdentifier: unique, where names need not be
	AccessToken string // the token to use with this server (differs from the account's for shared servers)
	Owned       bool
	Connections []Connection
}

// Connection is one way to reach a server.
type Connection struct {
	URI   string
	Local bool
	Relay bool
}

func tvReq(method, path, token, clientID string, q url.Values) (*http.Request, error) {
	u := "https://plex.tv" + path
	if len(q) > 0 {
		u += "?" + q.Encode()
	}
	r, err := http.NewRequest(method, u, nil)
	if err != nil {
		return nil, err
	}
	r.Header.Set("X-Plex-Client-Identifier", clientID)
	r.Header.Set("X-Plex-Product", Product)
	r.Header.Set("X-Plex-Version", "0.1")
	r.Header.Set("X-Plex-Platform", "MiSTer")
	r.Header.Set("X-Plex-Device", "DE10-Nano")
	r.Header.Set("X-Plex-Device-Name", "MiSTer CRT")
	r.Header.Set("Accept", "application/json")
	if token != "" {
		r.Header.Set("X-Plex-Token", token)
	}
	return r, nil
}

var tvClient = &http.Client{Timeout: 20 * time.Second}

// AccountName looks up the signed-in account, never the selected server's owner.
func AccountName(clientID, token string) (string, error) {
	r, err := tvReq("GET", "/api/v2/user", token, clientID, nil)
	if err != nil {
		return "", err
	}
	body, err := tvDo(r)
	if err != nil {
		return "", err
	}
	var user struct {
		Username string `json:"username"`
		Title    string `json:"title"`
	}
	if err := json.Unmarshal(body, &user); err != nil {
		return "", err
	}
	if name := strings.TrimSpace(user.Username); name != "" {
		return name, nil
	}
	return strings.TrimSpace(user.Title), nil
}

func tvDo(r *http.Request) ([]byte, error) {
	resp, err := tvClient.Do(r)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode/100 != 2 {
		return nil, fmt.Errorf("plex.tv %s: HTTP %d", r.URL.Path, resp.StatusCode)
	}
	return body, nil
}

// NewPin asks plex.tv for a link code.
func NewPin(clientID string) (*Pin, error) {
	r, err := tvReq("POST", "/api/v2/pins", "", clientID, nil)
	if err != nil {
		return nil, err
	}
	body, err := tvDo(r)
	if err != nil {
		return nil, err
	}
	var p struct {
		ID        int    `json:"id"`
		Code      string `json:"code"`
		ExpiresAt string `json:"expiresAt"`
	}
	if err := json.Unmarshal(body, &p); err != nil {
		return nil, err
	}
	exp, _ := time.Parse(time.RFC3339, p.ExpiresAt)
	if exp.IsZero() {
		exp = time.Now().Add(15 * time.Minute)
	}
	return &Pin{ID: p.ID, Code: p.Code, Expires: exp}, nil
}

// CheckPin returns the account token once the code has been entered, "" until then.
func CheckPin(clientID string, id int) (string, error) {
	r, err := tvReq("GET", "/api/v2/pins/"+strconv.Itoa(id), "", clientID, nil)
	if err != nil {
		return "", err
	}
	body, err := tvDo(r)
	if err != nil {
		return "", err
	}
	var p struct {
		AuthToken string `json:"authToken"`
	}
	if err := json.Unmarshal(body, &p); err != nil {
		return "", err
	}
	return p.AuthToken, nil
}

// Servers lists the account's media servers, the owned ones first.
func Servers(clientID, token string) ([]Server, error) {
	q := url.Values{"includeHttps": {"1"}, "includeRelay": {"1"}, "includeIPv6": {"0"}}
	r, err := tvReq("GET", "/api/v2/resources", token, clientID, q)
	if err != nil {
		return nil, err
	}
	body, err := tvDo(r)
	if err != nil {
		return nil, err
	}
	var rs []struct {
		Name        string `json:"name"`
		ID          string `json:"clientIdentifier"`
		Provides    string `json:"provides"`
		AccessToken string `json:"accessToken"`
		Owned       bool   `json:"owned"`
		Connections []struct {
			URI   string `json:"uri"`
			Local bool   `json:"local"`
			Relay bool   `json:"relay"`
		} `json:"connections"`
	}
	if err := json.Unmarshal(body, &rs); err != nil {
		return nil, err
	}
	var out []Server
	for _, r := range rs {
		if !strings.Contains(r.Provides, "server") {
			continue
		}
		s := Server{Name: Fold(r.Name), ID: r.ID, AccessToken: r.AccessToken, Owned: r.Owned}
		if s.AccessToken == "" {
			s.AccessToken = token
		}
		for _, c := range r.Connections {
			s.Connections = append(s.Connections, Connection{URI: c.URI, Local: c.Local, Relay: c.Relay})
		}
		if r.Owned {
			out = append([]Server{s}, out...)
		} else {
			out = append(out, s)
		}
	}
	return out, nil
}

// Reach probes a server's connections at once and returns the best that
// answers: local first, then direct, then relay. Once one answers, a
// better one gets a moment longer, no more.
func Reach(s Server) (string, error) {
	rank := func(c Connection) int {
		switch {
		case c.Relay:
			return 2
		case c.Local:
			return 0
		}
		return 1
	}
	type result struct {
		i   int
		err error
	}
	ch := make(chan result, len(s.Connections))
	probe := &http.Client{Timeout: 6 * time.Second}
	for i, c := range s.Connections {
		go func(i int, c Connection) {
			r, err := http.NewRequest("GET", c.URI+"/identity", nil)
			if err != nil {
				ch <- result{i, err}
				return
			}
			r.Header.Set("X-Plex-Token", s.AccessToken)
			resp, err := probe.Do(r)
			if err != nil {
				ch <- result{i, err}
				return
			}
			resp.Body.Close()
			if resp.StatusCode != 200 {
				err = fmt.Errorf("%s: HTTP %d", c.URI, resp.StatusCode)
			}
			ch <- result{i, err}
		}(i, c)
	}
	best := -1
	var last error
	var grace <-chan time.Time
	for n := 0; n < len(s.Connections); n++ {
		select {
		case r := <-ch:
			if r.err != nil {
				last = r.err
				continue
			}
			if best < 0 || rank(s.Connections[r.i]) < rank(s.Connections[best]) {
				best = r.i
			}
			if rank(s.Connections[best]) == 0 {
				return s.Connections[best].URI, nil
			}
			if grace == nil {
				grace = time.After(1500 * time.Millisecond)
			}
		case <-grace:
			return s.Connections[best].URI, nil
		}
	}
	if best >= 0 {
		return s.Connections[best].URI, nil
	}
	if last == nil {
		last = fmt.Errorf("no connections")
	}
	return "", last
}
