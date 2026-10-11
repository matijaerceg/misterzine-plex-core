package plex

import (
	"io"
	"net/http"
	"net/url"
	"strings"
	"testing"
)

type homeTransport func(*http.Request) (*http.Response, error)

func (f homeTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func homeResponse(status int, body string) *http.Response {
	return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader(body))}
}

func TestAccountHomeIdentity(t *testing.T) {
	old := tvClient
	t.Cleanup(func() { tvClient = old })
	for _, tc := range []struct {
		body     string
		want     HomeUser
		isHome   bool
		wantFail bool
	}{
		{`{"id":123,"title":"Alice","home":false,"protected":false,"restricted":false}`, HomeUser{ID: "123", Title: "Alice"}, false, false},
		{`{"id":123,"title":"Ordinary account","home":false}`, HomeUser{ID: "123", Title: "Ordinary account"}, false, false},
		{`{"id":"u-456","title":"Household Admin","home":true,"protected":true,"restricted":false}`, HomeUser{ID: "u-456", Title: "Household Admin", Protected: true}, true, false},
		{`{"id":123,"friendlyName":"Fallback","home":true}`, HomeUser{ID: "123", Title: "Fallback", Protected: true, Restricted: true}, true, false},
		{`{"id":123,"title":"No Home Flag"}`, HomeUser{}, false, true},
		{`{"title":"No ID","home":false}`, HomeUser{}, false, true},
		{`{broken`, HomeUser{}, false, true},
	} {
		tvClient = &http.Client{Transport: homeTransport(func(r *http.Request) (*http.Response, error) {
			if r.Method != "GET" || r.URL.Path != "/api/v2/user" || r.Header.Get("Accept") != "application/json" {
				t.Fatalf("unexpected request: %s %s Accept=%q", r.Method, r.URL, r.Header.Get("Accept"))
			}
			if r.Header.Get("X-Plex-Token") != "account-token" || r.Header.Get("X-Plex-Client-Identifier") != "client" {
				t.Fatal("missing Plex credentials")
			}
			return homeResponse(200, tc.body), nil
		})}
		got, home, err := AccountHomeIdentity("client", "account-token")
		if (err != nil) != tc.wantFail || got != tc.want || home != tc.isHome {
			t.Fatalf("body %q: identity=%#v home=%v err=%v", tc.body, got, home, err)
		}
	}
}

func TestHomeUsers(t *testing.T) {
	old := tvClient
	t.Cleanup(func() { tvClient = old })
	tvClient = &http.Client{Transport: homeTransport(func(r *http.Request) (*http.Response, error) {
		if r.Method != "GET" || r.URL.Path != "/api/home/users" || r.URL.RawQuery != "" || r.Header.Get("Accept") != "application/xml" {
			t.Fatalf("unexpected request: %s %s", r.Method, r.URL)
		}
		if r.Header.Get("X-Plex-Token") != "account-token" || r.Header.Get("X-Plex-Client-Identifier") != "client" {
			t.Fatal("missing Plex credentials")
		}
		return homeResponse(200, `<MediaContainer size="2"><User id="1" title="Primary" protected="1" restricted="0"/><User id="2" title="Kids" protected="false" restricted="true"/></MediaContainer>`), nil
	})}
	users, err := HomeUsers("client", "account-token")
	if err != nil {
		t.Fatal(err)
	}
	want := []HomeUser{{ID: "1", Title: "Primary", Protected: true}, {ID: "2", Title: "Kids", Restricted: true}}
	if len(users) != len(want) {
		t.Fatalf("got %#v", users)
	}
	for i := range users {
		if users[i] != want[i] {
			t.Fatalf("user %d: got %#v want %#v", i, users[i], want[i])
		}
	}
}

func TestHomeUsersErrors(t *testing.T) {
	old := tvClient
	t.Cleanup(func() { tvClient = old })
	for _, tc := range []struct {
		status int
		body   string
		bad    bool
	}{{200, `<MediaContainer><User`, true}, {401, ``, true}, {200, `<WrongRoot/>`, true}, {200, `<MediaContainer><User title="No ID"/></MediaContainer>`, true}, {200, `<MediaContainer/>`, false}} {
		tvClient = &http.Client{Transport: homeTransport(func(*http.Request) (*http.Response, error) {
			return homeResponse(tc.status, tc.body), nil
		})}
		users, err := HomeUsers("client", "token")
		if (err != nil) != tc.bad || (!tc.bad && len(users) != 0) {
			t.Fatalf("status %d body %q: users=%#v err=%v", tc.status, tc.body, users, err)
		}
	}
}

func TestHomeUsersUnknownProtectionDefaultsProtected(t *testing.T) {
	old := tvClient
	t.Cleanup(func() { tvClient = old })
	tvClient = &http.Client{Transport: homeTransport(func(*http.Request) (*http.Response, error) {
		return homeResponse(200, `<MediaContainer><User id="1" title="Unknown" protected="maybe" restricted="maybe"/></MediaContainer>`), nil
	})}
	users, err := HomeUsers("client", "token")
	if err != nil || len(users) != 1 || !users[0].Protected || !users[0].Restricted {
		t.Fatalf("users=%#v err=%v", users, err)
	}
}

func TestSwitchHomeUser(t *testing.T) {
	old := tvClient
	t.Cleanup(func() { tvClient = old })
	for _, pin := range []string{"", "12&34"} {
		tvClient = &http.Client{Transport: homeTransport(func(r *http.Request) (*http.Response, error) {
			if r.Method != "POST" || r.URL.Path != "/api/home/users/user-7/switch" || r.URL.RawQuery != "" || r.Header.Get("Accept") != "application/xml" {
				t.Fatalf("unexpected request: %s %s", r.Method, r.URL)
			}
			if strings.Contains(r.URL.String(), pin) && pin != "" {
				t.Fatal("PIN appeared in request URL")
			}
			body, err := io.ReadAll(r.Body)
			if err != nil {
				t.Fatal(err)
			}
			values, err := url.ParseQuery(string(body))
			if err != nil || values.Get("pin") != pin || r.Header.Get("Content-Type") != "application/x-www-form-urlencoded" {
				t.Fatalf("unexpected form %q, err %v", body, err)
			}
			if r.Header.Get("X-Plex-Token") != "account-token" {
				t.Fatal("missing account token")
			}
			return homeResponse(200, `<user authenticationToken="member-token"/>`), nil
		})}
		token, err := SwitchHomeUser("client", "account-token", "user-7", pin)
		if err != nil || token != "member-token" {
			t.Fatalf("token=%q err=%v", token, err)
		}
	}
}

func TestSwitchHomeUserNeverLeaksPIN(t *testing.T) {
	old := tvClient
	t.Cleanup(func() { tvClient = old })
	const pin = "secret-pin"
	tvClient = &http.Client{Transport: homeTransport(func(*http.Request) (*http.Response, error) {
		return homeResponse(401, `PIN rejected`), nil
	})}
	_, err := SwitchHomeUser("client", "account-token", "user-7", pin)
	if err == nil || strings.Contains(err.Error(), pin) {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestSwitchHomeUserRejectsBadResponses(t *testing.T) {
	old := tvClient
	t.Cleanup(func() { tvClient = old })
	for _, body := range []string{`<not-user/>`, `<user/>`, `<user authenticationToken=""/>`, `<user`} {
		tvClient = &http.Client{Transport: homeTransport(func(*http.Request) (*http.Response, error) {
			return homeResponse(200, body), nil
		})}
		token, err := SwitchHomeUser("client", "token", "id", "")
		if err == nil || token != "" {
			t.Fatalf("body %q: token=%q err=%v", body, token, err)
		}
	}
	if _, err := SwitchHomeUser("client", "token", "", ""); err == nil {
		t.Fatal("expected empty user ID to fail")
	}
}
