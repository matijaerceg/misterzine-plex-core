package plex

import (
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

func TestConnectionReportErrorsHidePrivateDetails(t *testing.T) {
	for _, tc := range []struct {
		err  error
		want string
	}{
		{&net.DNSError{Name: "private.example", Server: "192.0.2.1", IsNotFound: true}, "DNS name not found"},
		{&net.DNSError{Name: "private.example", IsTimeout: true}, "DNS timeout"},
		{&net.DNSError{Name: "private.example"}, "DNS lookup failed"},
		{&tls.CertificateVerificationError{Err: x509.HostnameError{Host: "private.example"}}, "TLS certificate name mismatch"},
		{&tls.CertificateVerificationError{Err: x509.CertificateInvalidError{Reason: x509.Expired, Detail: "private.example"}}, "TLS certificate expired or not yet valid"},
		{&tls.CertificateVerificationError{Err: x509.UnknownAuthorityError{}}, "TLS certificate not trusted"},
		{&tls.CertificateVerificationError{Err: x509.CertificateInvalidError{Reason: x509.NotAuthorizedToSign}}, "TLS certificate verification failed"},
		{&tls.CertificateVerificationError{Err: errors.New("private.example")}, "TLS certificate verification failed"},
		{tls.RecordHeaderError{Msg: "private.example"}, "TLS handshake failed"},
		{&net.OpError{Op: "dial", Err: syscall.ETIMEDOUT}, "timeout"},
		{syscall.ECONNREFUSED, "connection refused"},
		{syscall.ENETUNREACH, "network unreachable"},
		{syscall.ECONNRESET, "connection reset"},
		{io.EOF, "connection closed"},
		{errOtherServer, "answered by a different server"},
		{errNoIdentity, "no server identity in reply"},
		{errors.New("private.example secret-token"), "request failed"},
	} {
		wrapped := &url.Error{Op: "Get", URL: "https://private.example/?token=secret-token", Err: tc.err}
		if got := connectionOutcome(wrapped, 0); got != tc.want {
			t.Errorf("got %q, want %q", got, tc.want)
		}
	}
}

func TestFailedConnectionsAppearInReportLog(t *testing.T) {
	var buf syncBuffer
	logger := log.New(&buf, "", 0)
	s := Server{Name: "private-server", AccessToken: "secret-token", Connections: []Connection{
		{URI: "https://local.example", Local: true},
		{URI: "http://remote.example"},
		{URI: "https://relay.example", Relay: true},
	}}
	client := &http.Client{Transport: accountTransport(func(r *http.Request) (*http.Response, error) {
		if r.Header.Get("X-Plex-Token") != "" || r.URL.Path != "/identity" {
			t.Error("a probe must ask /identity without the token")
		}
		switch r.URL.Host {
		case "local.example":
			return nil, &net.DNSError{Name: r.URL.Host, IsNotFound: true}
		case "remote.example":
			return nil, syscall.ECONNREFUSED
		default:
			return &http.Response{StatusCode: 401, Body: io.NopCloser(strings.NewReader(""))}, nil
		}
	})}
	if uri, err := reach(s, true, client, logger.Printf); err == nil || uri != "" {
		t.Fatal("all failed probes must fail selection")
	}
	for _, want := range []string{"probing 3 advertised connections", "candidate 1 local HTTPS: DNS name not found", "candidate 2 remote HTTP: not tried", "candidate 3 relay HTTPS: HTTP 401", "no reachable advertised connection"} {
		if !strings.Contains(buf.String(), want) {
			t.Errorf("missing %q from log: %s", want, buf.String())
		}
	}
	for _, secret := range []string{".example", "secret-token", "private-server", "http://", "https://"} {
		if strings.Contains(buf.String(), secret) {
			t.Errorf("log leaked %q", secret)
		}
	}
}

// Report RXN6 (Oct 2026): a router with DNS rebind protection answered that
// the local plex.direct name does not exist, and the remote one timed out.
func TestReachNamesTheRouterRefusingTheLocalName(t *testing.T) {
	var buf syncBuffer
	logger := log.New(&buf, "", 0)
	const local = "192-168-1-9.0123456789abcdef.plex.direct"
	s := Server{Name: "private-server", AccessToken: "secret-token", Connections: []Connection{
		{URI: "https://" + local + ":32400", Local: true},
		{URI: "https://203-0-113-9.0123456789abcdef.plex.direct:32400"},
	}}
	client := &http.Client{Transport: accountTransport(func(r *http.Request) (*http.Response, error) {
		if r.URL.Hostname() == local {
			return nil, &net.DNSError{Err: "no such host", Name: local, IsNotFound: true}
		}
		return nil, &net.OpError{Op: "dial", Err: syscall.ETIMEDOUT}
	})}
	_, err := reach(s, true, client, logger.Printf)
	if err == nil || !LocalNameBlocked(err) {
		t.Fatalf("the refused local name was not reported as the cause: %v", err)
	}
	if !strings.Contains(buf.String(), "DNS refused a plex.direct name") {
		t.Errorf("no hint in the log: %s", buf.String())
	}
	for _, secret := range []string{"192-168", "0123456789abcdef", "secret-token", "private-server"} {
		if strings.Contains(buf.String(), secret) {
			t.Errorf("log leaked %q", secret)
		}
	}
	// a name that is not Plex's, or a DNS server that gave no answer, is something else
	for _, other := range []error{
		&net.DNSError{Err: "no such host", Name: "nas.example", IsNotFound: true},
		&net.DNSError{Err: "i/o timeout", Name: local, IsTimeout: true},
		syscall.ECONNREFUSED,
	} {
		if LocalNameBlocked(&url.Error{Op: "Get", URL: "https://x", Err: other}) {
			t.Errorf("%v was blamed on the router", other)
		}
	}
}

func TestConnectionReportSelectionAndEmptyList(t *testing.T) {
	var buf syncBuffer
	logger := log.New(&buf, "", 0)
	client := &http.Client{Transport: accountTransport(func(r *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(identityBody("some-id")))}, nil
	})}
	uri, err := reach(Server{Connections: []Connection{{URI: "http://local.example", Local: true}}}, true, client, logger.Printf)
	if uri != "http://local.example" || err != nil || !strings.Contains(buf.String(), "selected candidate 1") {
		t.Fatalf("successful local selection: %q %v %s", uri, err, buf.String())
	}
	buf.Reset()
	if _, err := reach(Server{}, true, client, logger.Printf); err == nil || !strings.Contains(buf.String(), "probing 0 advertised connections") {
		t.Fatalf("missing empty discovery evidence: %v %s", err, buf.String())
	}
}

// Another server at the plain local address must not get the session.
func TestReachRejectsADifferentServersIdentity(t *testing.T) {
	var buf syncBuffer
	s := Server{ID: "wanted-id", AccessToken: "secret-token", Connections: []Connection{
		{URI: "https://local.example:32400", Local: true},
		{URI: "http://local.example:32400", Local: true},
		{URI: "https://remote.example:32400"},
	}}
	client := &http.Client{Transport: accountTransport(func(r *http.Request) (*http.Response, error) {
		id := "wanted-id"
		switch r.URL.Scheme + "://" + r.URL.Host {
		case "https://local.example:32400", "https://remote.example:32400":
			return nil, &tls.CertificateVerificationError{Err: x509.UnknownAuthorityError{}}
		case "http://local.example:32400":
			id = "other-id"
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(identityBody(id)))}, nil
	})}
	uri, err := reach(s, true, client, log.New(&buf, "", 0).Printf)
	if err == nil || uri != "" {
		t.Fatalf("got %q %v, want no connection", uri, err)
	}
	if !strings.Contains(buf.String(), "candidate 2 local HTTP: answered by a different server") {
		t.Errorf("missing the rejection from log: %s", buf.String())
	}
	for _, secret := range []string{".example", "other-id", "wanted-id", "secret-token"} {
		if strings.Contains(buf.String(), secret) {
			t.Errorf("log leaked %q", secret)
		}
	}
}

// identityBody is what /identity answers for a server with that identifier.
func identityBody(id string) string {
	return `<?xml version="1.0" encoding="UTF-8"?><MediaContainer size="0" claimed="1" machineIdentifier="` + id + `" version="1.0"></MediaContainer>`
}

// Secure connections are tried first, and a plain one only when none
// answers: on the home network, and only while the setting allows it. The
// plex.direct certificate can fail where the plain address answers, as
// Plex's own apps find; the server's Secure connections setting decides.
func TestReachTriesSecureConnectionsBeforePlain(t *testing.T) {
	conns := []Connection{
		{URI: "https://local.example:32400", Local: true},
		{URI: "http://local.example:32400", Local: true},
		{URI: "https://remote.example:32400"},
		{URI: "http://remote.example:32400"}, // Servers() no longer makes one; it must stay untried if a list has it
		{URI: "https://relay.example:8443", Relay: true},
	}
	for _, tc := range []struct {
		name      string
		answers   []string // the connections that answer
		slow      string   // answers after the others
		plainHTTP bool
		want      string
		logged    []string
		untried   []string // connections no probe may ask
	}{
		{"untrusted local certificate, remote secure answers", []string{"http://local.example:32400", "https://remote.example:32400", "https://relay.example:8443"}, "", true,
			"https://remote.example:32400", []string{"candidate 3 remote HTTPS: HTTP 200"}, []string{"http://local.example:32400", "https://relay.example:8443"}},
		{"a slow secure local still beats an instant plain one", []string{"https://local.example:32400", "http://local.example:32400"}, "https://local.example:32400", true,
			"https://local.example:32400", []string{"candidate 1 local HTTPS: HTTP 200"}, []string{"http://local.example:32400"}},
		{"plain local once every secure path failed", []string{"http://local.example:32400", "https://relay.example:8443"}, "", true,
			"http://local.example:32400", []string{"candidate 2 local HTTP: HTTP 200", "plain HTTP selected"}, []string{"https://relay.example:8443"}},
		{"plain remote is never tried", []string{"http://remote.example:32400", "https://relay.example:8443"}, "", true,
			"https://relay.example:8443", []string{"candidate 4 remote HTTP: not tried", "candidate 5 relay HTTPS: HTTP 200"}, []string{"http://remote.example:32400"}},
		{"plain forbidden by the setting", []string{"http://local.example:32400", "https://relay.example:8443"}, "", false,
			"https://relay.example:8443", []string{"candidate 2 local HTTP: not tried", "candidate 5 relay HTTPS: HTTP 200"}, []string{"http://local.example:32400"}},
		{"relay last", []string{"https://relay.example:8443"}, "", true,
			"https://relay.example:8443", []string{"candidate 5 relay HTTPS: HTTP 200"}, nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var buf syncBuffer
			client := &http.Client{Transport: accountTransport(func(r *http.Request) (*http.Response, error) {
				uri := r.URL.Scheme + "://" + r.URL.Host
				for _, u := range tc.untried {
					if u == uri {
						t.Errorf("%s was probed", uri)
					}
				}
				if r.Header.Get("X-Plex-Token") != "" {
					t.Errorf("%s was sent the token", uri)
				}
				if uri == tc.slow {
					time.Sleep(100 * time.Millisecond)
				}
				for _, a := range tc.answers {
					if a == uri {
						return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(identityBody("id")))}, nil
					}
				}
				if r.URL.Scheme == "https" {
					return nil, &tls.CertificateVerificationError{Err: x509.UnknownAuthorityError{}}
				}
				return nil, syscall.ECONNREFUSED
			})}
			uri, err := reach(Server{ID: "id", AccessToken: "secret-token", Connections: conns}, tc.plainHTTP, client, log.New(&buf, "", 0).Printf)
			if err != nil || uri != tc.want {
				t.Fatalf("got %q %v, want %q", uri, err, tc.want)
			}
			for _, want := range tc.logged {
				if !strings.Contains(buf.String(), want) {
					t.Errorf("missing %q from log: %s", want, buf.String())
				}
			}
			if strings.Contains(buf.String(), ".example") || strings.Contains(buf.String(), "secret-token") {
				t.Errorf("log leaked a host or the token: %s", buf.String())
			}
		})
	}
}

// A 200 that names no server is not Plex: a captive portal, a proxy. It is
// not chosen, so it never sees the token.
func TestReachRejectsAnAnswerWithoutIdentity(t *testing.T) {
	var buf syncBuffer
	s := Server{ID: "wanted-id", AccessToken: "secret-token", Connections: []Connection{
		{URI: "https://local.example:32400", Local: true},
		{URI: "http://local.example:32400", Local: true},
	}}
	for _, body := range []string{"", "<html>sign in to the network</html>", `<MediaContainer size="0"></MediaContainer>`} {
		buf.Reset()
		client := &http.Client{Transport: accountTransport(func(r *http.Request) (*http.Response, error) {
			return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body))}, nil
		})}
		uri, err := reach(s, true, client, log.New(&buf, "", 0).Printf)
		if err == nil || uri != "" {
			t.Fatalf("body %q: got %q %v, want no connection", body, uri, err)
		}
		if !strings.Contains(buf.String(), "candidate 1 local HTTPS: no server identity in reply") || !strings.Contains(buf.String(), "candidate 2 local HTTP: no server identity in reply") {
			t.Errorf("body %q: missing the rejection from log: %s", body, buf.String())
		}
	}
}

// syncBuffer is a log sink the probes' goroutines may write while the test
// reads it.
type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

func (b *syncBuffer) Reset() {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.buf.Reset()
}

// The probes that lose run on after reach has its answer; they log nothing
// from then on, as the caller may be reading or closing its log.
func TestReachLosersGoQuietOnceItReturns(t *testing.T) {
	var buf syncBuffer
	slow := make(chan struct{})
	finished := make(chan struct{})
	client := &http.Client{Transport: accountTransport(func(r *http.Request) (*http.Response, error) {
		if r.URL.Host == "remote.example:32400" {
			<-slow
			defer close(finished)
			return nil, syscall.ECONNREFUSED
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(identityBody("id")))}, nil
	})}
	conns := []Connection{{URI: "https://local.example:32400", Local: true}, {URI: "https://remote.example:32400"}}
	uri, err := reach(Server{Connections: conns}, true, client, log.New(&buf, "", 0).Printf)
	if err != nil || uri != conns[0].URI {
		t.Fatalf("got %q %v, want the local connection", uri, err)
	}
	before := buf.String()
	close(slow)
	<-finished
	time.Sleep(50 * time.Millisecond) // the loser's log line would follow its answer
	if after := buf.String(); after != before {
		t.Fatalf("a losing probe logged after reach returned: %q", strings.TrimPrefix(after, before))
	}
}
