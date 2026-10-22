// Package safelog removes credentials before log bytes reach disk or a terminal.
package safelog

import (
	"bytes"
	"io"
	"net/url"
	"regexp"
	"strings"
	"sync"
)

// token names the credentials release/manager.py redacts too; keep the two
// alternations the same.
var token = regexp.MustCompile(`(?i)(x-plex-token|x-emby-token|x-mediabrowser-token|authtoken|accesstoken|access_token|api_key|token)([= :"%]+)([^&\s"<>]+)`)
var bearer = regexp.MustCompile(`(?i)(authorization: ?bearer )[^\s]+`)

func Redact(s string, secrets ...string) string {
	for _, secret := range secrets {
		if secret != "" {
			s = strings.ReplaceAll(s, secret, "[redacted]")
			s = strings.ReplaceAll(s, url.QueryEscape(secret), "[redacted]")
		}
	}
	s = token.ReplaceAllString(s, "$1$2[redacted]")
	return bearer.ReplaceAllString(s, "$1[redacted]")
}

type Writer struct {
	mu       sync.Mutex
	Out      io.Writer
	Secrets  []string
	pending  []byte
	dropping bool
}

func (w *Writer) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	n := len(p)
	for len(p) > 0 {
		i := bytes.IndexByte(p, '\n')
		part := p
		if i >= 0 {
			part = p[:i+1]
		}
		if !w.dropping {
			if len(w.pending)+len(part) > 65536 {
				w.pending = nil
				w.dropping = true
			} else {
				w.pending = append(w.pending, part...)
			}
		}
		if i < 0 {
			break
		}
		var err error
		if w.dropping {
			_, err = io.WriteString(w.Out, "[oversized log line omitted]\n")
		} else {
			_, err = io.WriteString(w.Out, Redact(string(w.pending), w.Secrets...))
		}
		w.pending = nil
		w.dropping = false
		if err != nil {
			return n, err
		}
		p = p[i+1:]
	}
	return n, nil
}
func (w *Writer) Flush() {
	w.mu.Lock()
	defer w.mu.Unlock()
	if !w.dropping && len(w.pending) > 0 {
		io.WriteString(w.Out, Redact(string(w.pending), w.Secrets...))
	}
	w.pending = nil
}
