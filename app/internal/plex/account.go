package plex

import (
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
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
			URI      string `json:"uri"`
			Protocol string `json:"protocol"`
			Address  string `json:"address"`
			Port     int    `json:"port"`
			Local    bool   `json:"local"`
			Relay    bool   `json:"relay"`
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
		// plex.tv lists the plex.direct HTTPS form; Plex's own apps also try
		// the plain address, and the server's Secure connections setting
		// decides whether it answers. A relay is HTTPS only.
		seen := map[string]bool{}
		add := func(c Connection) {
			if c.URI != "" && !seen[c.URI] {
				seen[c.URI] = true
				s.Connections = append(s.Connections, c)
			}
		}
		for _, c := range r.Connections {
			add(Connection{URI: c.URI, Local: c.Local, Relay: c.Relay})
			// only on the home network: a plain connection carries the token and
			// everything after it in clear, which the internet must never see
			if c.Local && !c.Relay && c.Protocol != "http" && c.Address != "" && c.Port > 0 {
				add(Connection{URI: "http://" + net.JoinHostPort(c.Address, strconv.Itoa(c.Port)), Local: true})
			}
		}
		if r.Owned {
			out = append([]Server{s}, out...)
		} else {
			out = append(out, s)
		}
	}
	return out, nil
}

// errOtherServer is a connection that answered with another server's identity.
var errOtherServer = errors.New("answered by a different server")

// errNoIdentity is a connection that answered 200 without naming a server:
// a captive portal, a proxy, anything but Plex. It gets no token.
var errNoIdentity = errors.New("no server identity in reply")

// Reach finds the best connection to a server and returns it. Secure
// connections go first: every direct HTTPS connection is probed at once,
// local ranked above remote. Only when none answers are the plain HTTP
// connections tried (home network ones only, and only when plainHTTP
// allows them), and only after those the relay. Within a round, once one
// answers, a better one gets a moment longer, no more.
//
// The probe asks /identity without the token: that endpoint needs none,
// and a candidate earns the token only by answering with the expected
// machine identifier over the connection then chosen.
func Reach(s Server, plainHTTP bool, logf func(string, ...any)) (string, error) {
	return reach(s, plainHTTP, &http.Client{Timeout: 6 * time.Second}, logf)
}

// isPlain reports whether a connection is unencrypted.
func isPlain(c Connection) bool { return strings.HasPrefix(c.URI, "http://") }

func reach(s Server, plainHTTP bool, probe *http.Client, logf func(string, ...any)) (string, error) {
	if logf == nil {
		logf = func(string, ...any) {}
	}
	// The probes that lose run on after reach returns; they go quiet then,
	// so nothing reaches the caller's log once it has its answer.
	var logMu sync.Mutex
	quiet := false
	say := logf
	logf = func(format string, args ...any) {
		logMu.Lock()
		defer logMu.Unlock()
		if !quiet {
			say(format, args...)
		}
	}
	defer func() {
		logMu.Lock()
		quiet = true
		logMu.Unlock()
	}()
	logf("server connection: probing %d advertised connections", len(s.Connections))
	var secure, plain, relay []int
	for i, c := range s.Connections {
		logf("server connection: candidate %d %s", i+1, connectionKind(c))
		switch {
		case c.Relay:
			relay = append(relay, i)
		case isPlain(c):
			if c.Local && plainHTTP {
				plain = append(plain, i)
			} else {
				logf("server connection: candidate %d %s: not tried", i+1, connectionKind(c))
			}
		default:
			secure = append(secure, i)
		}
	}
	var last, blocked error
	for _, round := range [][]int{secure, plain, relay} {
		if len(round) == 0 {
			continue
		}
		best, roundLast, roundBlocked := probeRound(s, round, probe, logf)
		if roundLast != nil {
			last = roundLast
		}
		if roundBlocked != nil {
			blocked = roundBlocked
		}
		if best >= 0 {
			logf("server connection: selected candidate %d", best+1)
			if isPlain(s.Connections[best]) {
				logf("server connection: plain HTTP selected; the token and all traffic are unencrypted on the home network")
			}
			return s.Connections[best].URI, nil
		}
	}
	if blocked != nil {
		// the one failure the user can name a cause for, so it is the one reported
		logf("server connection: DNS refused a plex.direct name; routers with rebind protection do that")
		last = blocked
	}
	if last == nil {
		last = fmt.Errorf("no connections")
	}
	logf("server connection: no reachable advertised connection")
	return "", last
}

// probeRound probes the connections at idx at once and returns the index
// of the best that answers, or -1, with the last failure and any failure
// that was a blocked plex.direct name.
func probeRound(s Server, idx []int, probe *http.Client, logf func(string, ...any)) (best int, last, blocked error) {
	rank := func(c Connection) int {
		r := 2
		switch {
		case c.Relay:
			return 4
		case c.Local:
			r = 0
		}
		if isPlain(c) {
			r++
		}
		return r
	}
	type result struct {
		i   int
		err error
	}
	ch := make(chan result, len(idx))
	for _, i := range idx {
		go func(i int, c Connection) {
			started := time.Now()
			finish := func(err error, status int) {
				logf("server connection: candidate %d %s: %s (%d ms)", i+1, connectionKind(c), connectionOutcome(err, status), time.Since(started).Milliseconds())
				ch <- result{i, err}
			}
			r, err := http.NewRequest("GET", c.URI+"/identity", nil)
			if err != nil {
				finish(err, 0)
				return
			}
			resp, err := probe.Do(r)
			if err != nil {
				finish(err, 0)
				return
			}
			var id struct {
				MachineIdentifier string `xml:"machineIdentifier,attr"`
			}
			if resp.StatusCode == 200 {
				xml.NewDecoder(io.LimitReader(resp.Body, 64<<10)).Decode(&id)
			}
			resp.Body.Close()
			switch {
			case resp.StatusCode != 200:
				err = fmt.Errorf("%s: HTTP %d", c.URI, resp.StatusCode)
			case id.MachineIdentifier == "":
				// a body that is missing or does not parse names no server
				finish(errNoIdentity, 0)
				return
			case s.ID != "" && id.MachineIdentifier != s.ID:
				// a plain address proves nothing about who answers there, and a
				// LAN address can belong to another machine on another network
				finish(errOtherServer, 0)
				return
			}
			finish(err, resp.StatusCode)
		}(i, s.Connections[i])
	}
	best = -1
	done := map[int]bool{}
	// beatable reports whether a probe still running could rank above best
	beatable := func() bool {
		for _, i := range idx {
			if !done[i] && rank(s.Connections[i]) < rank(s.Connections[best]) {
				return true
			}
		}
		return false
	}
	var grace <-chan time.Time
	for n := 0; n < len(idx); n++ {
		select {
		case r := <-ch:
			done[r.i] = true
			if r.err != nil {
				last = r.err
				if LocalNameBlocked(r.err) {
					blocked = r.err
				}
			} else if best < 0 || rank(s.Connections[r.i]) < rank(s.Connections[best]) {
				best = r.i
			}
			if best < 0 {
				continue
			}
			if !beatable() {
				return best, last, blocked
			}
			if grace == nil {
				grace = time.After(1500 * time.Millisecond)
			}
		case <-grace:
			return best, last, blocked
		}
	}
	return best, last, blocked
}

// LocalNameBlocked reports whether err is DNS answering that a plex.direct
// name does not exist. plex.tv names a server's local connection
// <ip>.<hash>.plex.direct, resolving to a home-network address, and routers
// with DNS rebind protection (on by default in OpenWrt, pfSense, Fritz!Box)
// refuse such answers. Plex's own remedy is an exception for plex.direct on
// the router, so the app says so instead of blaming the server.
func LocalNameBlocked(err error) bool {
	var dns *net.DNSError
	return errors.As(err, &dns) && dns.IsNotFound && strings.HasSuffix(dns.Name, ".plex.direct")
}
