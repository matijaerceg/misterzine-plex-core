package netdiag

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestRelationAndPrivacy(t *testing.T) {
	_, network, _ := net.ParseCIDR("10.50.0.2/24")
	for _, tc := range []struct {
		ip, arp, want   string
		known, arpKnown bool
	}{
		{"10.50.0.9", "10.50.0.9 0x1 0x2 aa:bb:cc:dd:ee:ff * secret-host", "same_subnet=yes arp=cached-complete", true, true},
		{"10.50.0.9", "10.50.0.9 0x1 0x0 00:00:00:00:00:00 * eth0", "same_subnet=yes arp=incomplete", true, true},
		{"10.50.0.9", "", "same_subnet=yes arp=absent", true, true},
		{"10.50.0.9", "", "same_subnet=yes arp=unknown", true, false},
		{"10.1.2.3", "", "same_subnet=no arp=not-applicable", true, true},
		{"10.1.2.3", "", "same_subnet=unknown arp=unknown", false, true},
		{"2001:db8::1", "", "IPv6; subnet/ARP not assessed", true, true},
	} {
		got := relation(net.ParseIP(tc.ip), []*net.IPNet{network}, tc.known, tc.arp, tc.arpKnown)
		if !strings.Contains(got, tc.want) {
			t.Fatalf("got %s want %s", got, tc.want)
		}
		for _, secret := range []string{tc.ip, "aa:bb", "secret-host"} {
			if strings.Contains(got, secret) {
				t.Fatal("diagnostic leaked an address/name")
			}
		}
	}
}

func TestProbeFailureLogsWithoutNetworkIdentifiers(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := listener.Addr().String()
	listener.Close()
	ctx, p := Observe(context.Background(), "http://"+address)
	req, _ := http.NewRequestWithContext(ctx, "GET", "http://"+address, nil)
	client := &http.Client{Timeout: time.Second, Transport: &http.Transport{Proxy: nil}}
	resp, err := client.Do(req)
	if err == nil {
		resp.Body.Close()
		t.Fatal("expected closed-port failure")
	}
	var log strings.Builder
	p.Log(func(format string, args ...any) { fmt.Fprintf(&log, format, args...) })
	if !strings.Contains(log.String(), "destination 1 IPv4 same_subnet=yes") || strings.Contains(log.String(), "127.0.0.1") {
		t.Fatalf("unsafe/missing diagnostic: %s", log.String())
	}
	_, unknown := Observe(context.Background(), "https://unresolved.example")
	log.Reset()
	unknown.Log(func(format string, args ...any) { fmt.Fprintf(&log, format, args...) })
	if !strings.Contains(log.String(), "destination unknown") || strings.Contains(log.String(), "example") {
		t.Fatal(log.String())
	}
}
