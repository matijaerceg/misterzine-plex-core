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
		{errors.New("private.example secret-token"), "request failed"},
	} {
		wrapped := &url.Error{Op: "Get", URL: "https://private.example/?token=secret-token", Err: tc.err}
		if got := connectionOutcome(wrapped, 0); got != tc.want {
			t.Errorf("got %q, want %q", got, tc.want)
		}
	}
}

func TestFailedConnectionsAppearInReportLog(t *testing.T) {
	var buf bytes.Buffer
	logger := log.New(&buf, "", 0)
	s := Server{Name: "private-server", AccessToken: "secret-token", Connections: []Connection{
		{URI: "https://local.example", Local: true},
		{URI: "http://remote.example"},
		{URI: "https://relay.example", Relay: true},
	}}
	client := &http.Client{Transport: accountTransport(func(r *http.Request) (*http.Response, error) {
		if r.Header.Get("X-Plex-Token") != s.AccessToken || r.URL.Path != "/identity" {
			t.Error("probe lost its token or identity path")
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
	if uri, err := reach(s, client, logger.Printf); err == nil || uri != "" {
		t.Fatal("all failed probes must fail selection")
	}
	for _, want := range []string{"probing 3 advertised connections", "candidate 1 local HTTPS: DNS name not found", "candidate 2 remote HTTP: connection refused", "candidate 3 relay HTTPS: HTTP 401", "no reachable advertised connection"} {
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
	var buf bytes.Buffer
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
	_, err := reach(s, client, logger.Printf)
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
	var buf bytes.Buffer
	logger := log.New(&buf, "", 0)
	client := &http.Client{Transport: accountTransport(func(r *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(""))}, nil
	})}
	uri, err := reach(Server{Connections: []Connection{{URI: "http://local.example", Local: true}}}, client, logger.Printf)
	if uri != "http://local.example" || err != nil || !strings.Contains(buf.String(), "selected candidate 1") {
		t.Fatalf("successful local selection: %q %v %s", uri, err, buf.String())
	}
	buf.Reset()
	if _, err := reach(Server{}, client, logger.Printf); err == nil || !strings.Contains(buf.String(), "probing 0 advertised connections") {
		t.Fatalf("missing empty discovery evidence: %v %s", err, buf.String())
	}
}

// Another server at the plain local address must not get the session.
func TestReachRejectsADifferentServersIdentity(t *testing.T) {
	var buf bytes.Buffer
	s := Server{ID: "wanted-id", AccessToken: "secret-token", Connections: []Connection{
		{URI: "https://local.example:32400", Local: true},
		{URI: "http://local.example:32400", Local: true},
		{URI: "https://remote.example:32400"},
	}}
	client := &http.Client{Transport: accountTransport(func(r *http.Request) (*http.Response, error) {
		id := "wanted-id"
		switch r.URL.Scheme + "://" + r.URL.Host {
		case "https://local.example:32400":
			return nil, &tls.CertificateVerificationError{Err: x509.UnknownAuthorityError{}}
		case "http://local.example:32400":
			id = "other-id"
		}
		body := `<?xml version="1.0" encoding="UTF-8"?><MediaContainer size="0" claimed="1" machineIdentifier="` + id + `" version="1.0"></MediaContainer>`
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body))}, nil
	})}
	uri, err := reach(s, client, log.New(&buf, "", 0).Printf)
	if err != nil || uri != "https://remote.example:32400" {
		t.Fatalf("got %q %v, want the remote connection", uri, err)
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

// The plex.direct certificate can fail where the plain address answers, as
// Plex's own apps find; the server's Secure connections setting decides.
func TestReachPrefersHTTPSThenFallsBackToHTTP(t *testing.T) {
	conns := []Connection{
		{URI: "https://local.example:32400", Local: true},
		{URI: "http://local.example:32400", Local: true},
		{URI: "https://remote.example:32400"},
		{URI: "http://remote.example:32400"},
		{URI: "https://relay.example:8443", Relay: true},
	}
	for _, tc := range []struct {
		name    string
		answers []string // the connections that answer
		slow    string   // answers after the others
		want    string
		logged  string
	}{
		{"untrusted local certificate", []string{"http://local.example:32400", "https://remote.example:32400", "https://relay.example:8443"}, "",
			"http://local.example:32400", "candidate 2 local HTTP: HTTP 200"},
		{"secure local wins over plain", []string{"https://local.example:32400", "http://local.example:32400"}, "https://local.example:32400",
			"https://local.example:32400", "candidate 1 local HTTPS: HTTP 200"},
		{"plain remote", []string{"http://remote.example:32400", "https://relay.example:8443"}, "http://remote.example:32400",
			"http://remote.example:32400", "candidate 4 remote HTTP: HTTP 200"},
		{"relay last", []string{"https://relay.example:8443"}, "",
			"https://relay.example:8443", "candidate 5 relay HTTPS: HTTP 200"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var buf bytes.Buffer
			client := &http.Client{Transport: accountTransport(func(r *http.Request) (*http.Response, error) {
				uri := r.URL.Scheme + "://" + r.URL.Host
				if uri == tc.slow {
					time.Sleep(100 * time.Millisecond)
				}
				for _, a := range tc.answers {
					if a == uri {
						return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(""))}, nil
					}
				}
				if r.URL.Scheme == "https" {
					return nil, &tls.CertificateVerificationError{Err: x509.UnknownAuthorityError{}}
				}
				return nil, syscall.ECONNREFUSED
			})}
			uri, err := reach(Server{AccessToken: "secret-token", Connections: conns}, client, log.New(&buf, "", 0).Printf)
			if err != nil || uri != tc.want {
				t.Fatalf("got %q %v, want %q", uri, err, tc.want)
			}
			if !strings.Contains(buf.String(), tc.logged) {
				t.Errorf("missing %q from log: %s", tc.logged, buf.String())
			}
			if strings.Contains(buf.String(), ".example") {
				t.Errorf("log leaked a host: %s", buf.String())
			}
		})
	}
}
