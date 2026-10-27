package plex

import (
	"fmt"
	"io"
	"net/http"
	"reflect"
	"strings"
	"testing"
)

type accountTransport func(*http.Request) (*http.Response, error)

func (f accountTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestAccountName(t *testing.T) {
	old := tvClient
	t.Cleanup(func() { tvClient = old })
	for _, tc := range []struct {
		body   string
		status int
		want   string
		bad    bool
	}{
		{`{"username":" alice ","title":"Alice"}`, 200, "alice", false},
		{`{"username":"","title":" Alice "}`, 200, "Alice", false},
		{`{"email":"private@example.com"}`, 200, "", false},
		{`{broken`, 200, "", true},
		{`{}`, 401, "", true},
		{`{}`, 503, "", true},
	} {
		tvClient = &http.Client{Transport: accountTransport(func(r *http.Request) (*http.Response, error) {
			if r.URL.Path != "/api/v2/user" || r.Header.Get("X-Plex-Token") != "account-token" || r.Header.Get("X-Plex-Client-Identifier") != "client" {
				t.Fatal("incorrect account request")
			}
			return &http.Response{StatusCode: tc.status, Body: io.NopCloser(strings.NewReader(tc.body))}, nil
		})}
		name, err := AccountName("client", "account-token")
		if name != tc.want || (err != nil) != tc.bad {
			t.Fatalf("status %d body %s: name=%q err=%v", tc.status, tc.body, name, err)
		}
	}
}

func TestServersOfferThePlainAddressOnlyOnTheHomeNetwork(t *testing.T) {
	old := tvClient
	t.Cleanup(func() { tvClient = old })
	const lan, wan = "10.0.0.2", "203.0.113.9"
	body := fmt.Sprintf(`[
		{"name":"Player","provides":"player","connections":[]},
		{"name":"Home","clientIdentifier":"id","provides":"server","owned":true,"connections":[
			{"protocol":"https","address":"%[1]s","port":32400,"uri":"https://10-0-0-2.hash.plex.direct:32400","local":true},
			{"protocol":"http","address":"%[1]s","port":32400,"uri":"http://%[1]s:32400","local":true},
			{"protocol":"https","address":"%[2]s","port":32400,"uri":"https://203-0-113-9.hash.plex.direct:32400"},
			{"protocol":"https","address":"%[2]s","port":8443,"uri":"https://203-0-113-9.hash.plex.direct:8443","relay":true}]}]`, lan, wan)
	tvClient = &http.Client{Transport: accountTransport(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/api/v2/resources" || r.URL.Query().Get("includeHttps") != "1" {
			t.Fatal("incorrect resources request")
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body))}, nil
	})}
	servers, err := Servers("client", "account-token")
	if err != nil || len(servers) != 1 {
		t.Fatalf("servers=%v err=%v", servers, err)
	}
	want := []Connection{
		{URI: "https://10-0-0-2.hash.plex.direct:32400", Local: true},
		{URI: "http://" + lan + ":32400", Local: true},
		{URI: "https://203-0-113-9.hash.plex.direct:32400"}, // no plain form: the token must never cross the internet in clear
		{URI: "https://203-0-113-9.hash.plex.direct:8443", Relay: true},
	}
	if !reflect.DeepEqual(servers[0].Connections, want) {
		t.Fatalf("connections:\n got %v\nwant %v", servers[0].Connections, want)
	}
	if servers[0].AccessToken != "account-token" {
		t.Errorf("an owned server without its own token uses the account's")
	}
}
