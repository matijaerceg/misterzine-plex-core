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
)

func TestConnectionReportErrorsHidePrivateDetails(t *testing.T) {
	for _, tc := range []struct {
		err  error
		want string
	}{
		{&net.DNSError{Name: "private.example", Server: "192.0.2.1", IsNotFound: true}, "DNS name not found"},
		{&net.DNSError{Name: "private.example", IsTimeout: true}, "DNS timeout"},
		{&net.DNSError{Name: "private.example"}, "DNS lookup failed"},
		{&tls.CertificateVerificationError{Err: x509.HostnameError{Host: "private.example"}}, "TLS certificate verification failed"},
		{tls.RecordHeaderError{Msg: "private.example"}, "TLS handshake failed"},
		{&net.OpError{Op: "dial", Err: syscall.ETIMEDOUT}, "timeout"},
		{syscall.ECONNREFUSED, "connection refused"},
		{syscall.ENETUNREACH, "network unreachable"},
		{syscall.ECONNRESET, "connection reset"},
		{io.EOF, "connection closed"},
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
