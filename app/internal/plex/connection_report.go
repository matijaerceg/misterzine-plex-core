package plex

import (
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"syscall"
)

// Only fixed labels and numeric statuses enter reports. Never format a raw
// error: even DNS and certificate errors can contain addresses or names.
func connectionKind(c Connection) string {
	kind := "remote"
	if c.Relay {
		kind = "relay"
	} else if c.Local {
		kind = "local"
	}
	scheme := "unknown protocol"
	if u, err := url.Parse(c.URI); err == nil {
		switch u.Scheme {
		case "http":
			scheme = "HTTP"
		case "https":
			scheme = "HTTPS"
		}
	}
	return kind + " " + scheme
}

func connectionOutcome(err error, status int) string {
	if status != 0 {
		return fmt.Sprintf("HTTP %d", status)
	}
	if err == nil {
		return "success"
	}
	var dns *net.DNSError
	var cert *tls.CertificateVerificationError
	var invalid x509.CertificateInvalidError
	var unknown x509.UnknownAuthorityError
	var hostname x509.HostnameError
	var record tls.RecordHeaderError
	var network net.Error
	switch {
	case errors.As(err, &dns):
		if dns.IsTimeout {
			return "DNS timeout"
		}
		if dns.IsNotFound {
			return "DNS name not found"
		}
		return "DNS lookup failed"
	case errors.As(err, &cert), errors.As(err, &invalid), errors.As(err, &unknown), errors.As(err, &hostname):
		return "TLS certificate verification failed"
	case errors.As(err, &record):
		return "TLS handshake failed"
	case errors.As(err, &network) && network.Timeout():
		return "timeout"
	case errors.Is(err, syscall.ECONNREFUSED):
		return "connection refused"
	case errors.Is(err, syscall.ENETUNREACH), errors.Is(err, syscall.EHOSTUNREACH):
		return "network unreachable"
	case errors.Is(err, syscall.ECONNRESET):
		return "connection reset"
	case errors.Is(err, io.EOF), errors.Is(err, io.ErrUnexpectedEOF):
		return "connection closed"
	default:
		return "request failed"
	}
}
