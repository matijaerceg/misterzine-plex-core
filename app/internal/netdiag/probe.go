// Package netdiag records network relationships without recording destinations.
package netdiag

import (
	"context"
	"fmt"
	"net"
	"net/http/httptrace"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
)

// Probe retains only in-memory addresses from the attempted connection. It
// neither resolves names again nor sends additional traffic after a failure.
type Probe struct {
	mu  sync.Mutex
	ips []net.IP
}

func Observe(ctx context.Context, rawURL string) (context.Context, *Probe) {
	p := &Probe{}
	if u, err := url.Parse(rawURL); err == nil {
		p.add(net.ParseIP(u.Hostname()))
	}
	trace := &httptrace.ClientTrace{ConnectStart: func(network, address string) {
		host, _, err := net.SplitHostPort(address)
		if err == nil {
			p.add(net.ParseIP(host))
		}
	}}
	return httptrace.WithClientTrace(ctx, trace), p
}

func (p *Probe) add(ip net.IP) {
	if ip == nil {
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, old := range p.ips {
		if old.Equal(ip) {
			return
		}
	}
	p.ips = append(p.ips, ip)
}

// Log uses only fixed labels, ordinals and relationships. With an HTTP proxy,
// the traced destination can be the proxy, so do not call it the server.
func (p *Probe) Log(logf func(string, ...any)) {
	p.mu.Lock()
	ips := append([]net.IP(nil), p.ips...)
	p.mu.Unlock()
	var networks []*net.IPNet
	interfaces, err := net.Interfaces()
	known := err == nil
	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			known = false
			continue
		}
		for _, addr := range addrs {
			if n, ok := addr.(*net.IPNet); ok {
				networks = append(networks, n)
			}
		}
	}
	arp, arpErr := os.ReadFile("/proc/net/arp")
	if len(ips) == 0 {
		logf("probe network: destination unknown (no resolved address)")
		return
	}
	for i, ip := range ips {
		logf("probe network: destination %d %s", i+1, relation(ip, networks, known, string(arp), arpErr == nil))
	}
}

func relation(ip net.IP, networks []*net.IPNet, known bool, arp string, arpKnown bool) string {
	if ip.To4() == nil {
		return "IPv6; subnet/ARP not assessed"
	}
	subnet := "no"
	for _, n := range networks {
		if n.Contains(ip) {
			subnet = "yes"
			break
		}
	}
	if subnet == "no" && !known {
		subnet = "unknown"
	}
	state := "not-applicable"
	if subnet == "yes" {
		state = "absent"
		if !arpKnown {
			state = "unknown"
		}
		for _, line := range strings.Split(arp, "\n") {
			fields := strings.Fields(line)
			if len(fields) < 6 || !net.ParseIP(fields[0]).Equal(ip) {
				continue
			}
			flags, err := strconv.ParseUint(fields[2], 0, 32)
			if err != nil {
				state = "unknown"
				continue
			}
			state = "incomplete"
			if flags&2 != 0 {
				state = "cached-complete"
				break
			}
		}
	} else if subnet == "unknown" {
		state = "unknown"
	}
	return fmt.Sprintf("IPv4 same_subnet=%s arp=%s (cache only; not a fresh reply test)", subnet, state)
}
