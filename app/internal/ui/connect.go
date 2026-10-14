package ui

import (
	"errors"
	"net"
	"net/url"
	"syscall"
	"time"

	"plexcrt/internal/plex"
)

// Plex opened soon after the MiSTer is switched on can fail to reach a
// server although nothing is wrong: DHCP has not configured a DNS server
// yet, or, on a MiSTer without a clock chip, the clock still reads 1970
// until the network time arrives, and no server certificate is valid
// before then. A failure to get any answer is therefore retried quietly for
// ConnectGrace, every ConnectRetry, before it is shown as an error.
const (
	ConnectGrace = 60 * time.Second
	ConnectRetry = 2 * time.Second
)

// clockFloor: no release of this app is older, so an earlier clock has not
// been set yet.
var clockFloor = time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)

// netProblem is why a server could not be reached, in the user's terms.
type netProblem int

const (
	problemServer    netProblem = iota // no answer from the server
	problemNetwork                     // no route or no DNS server yet
	problemClock                       // the clock is not set, so no certificate is valid yet
	problemLocalName                   // the router refuses the server's plex.direct name
)

// Advice for a plex.direct name the router refuses, in the user's terms; the
// Home screen, the Plex Home screen and the server picker all show it.
const (
	routerBlocksName = "Your router blocks the server's name."
	routerAdvice     = "Allow plex.direct in its DNS rebind protection, or use 1.1.1.1 as DNS."
)

// unreachable reports whether err means no answer came at all, as opposed
// to an answer the server gave (an HTTP error, a reply that did not parse).
func unreachable(err error) bool {
	var ue *url.Error
	return errors.As(err, &ue)
}

func classify(err error, now time.Time) netProblem {
	if !unreachable(err) {
		return problemServer // it answered, so network and clock are fine
	}
	// "not found" is an answer from a working DNS server: the name itself
	// does not resolve, which waiting will not change
	if plex.LocalNameBlocked(err) {
		return problemLocalName
	}
	var dns *net.DNSError
	if (errors.As(err, &dns) && !dns.IsNotFound) || errors.Is(err, syscall.ENETUNREACH) {
		return problemNetwork
	}
	if now.Before(clockFloor) {
		return problemClock
	}
	return problemServer
}

// waiting is the line under "Connecting..." while a failure is retried.
func (p netProblem) waiting() string {
	switch p {
	case problemNetwork:
		return "Waiting for the network."
	case problemClock:
		return "Waiting for the MiSTer to set its clock from the internet."
	}
	return "Waiting for an answer."
}

// failure is the headline and advice once the failure is shown as an error.
func (p netProblem) failure() (string, string) {
	switch p {
	case problemNetwork:
		return "No network connection.", "Check the MiSTer's network cable or Wi-Fi."
	case problemClock:
		return "The MiSTer's clock is not set.", "It gets the time from the internet, and Plex needs it."
	case problemLocalName:
		return routerBlocksName, routerAdvice
	}
	return "Cannot reach the server.", "Check the network and confirm your Plex server is running."
}

// settled reports whether retrying soon is pointless: the failure is an
// answer, not silence, so the error shows at once instead of after the grace.
func (p netProblem) settled() bool {
	return p == problemLocalName
}

// reachFailure is the line for a server that could not be reached while
// signing in; a router refusing its name gets the remedy, the rest a retry.
func reachFailure(server string, err error) string {
	if plex.LocalNameBlocked(err) {
		return routerBlocksName + " " + routerAdvice + " OK: retry."
	}
	return "Could not reach " + server + ". Press OK to retry."
}
