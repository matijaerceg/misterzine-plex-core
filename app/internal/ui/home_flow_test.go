package ui

import (
	"io"
	"log"
	"net/http"
	"net/url"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"plexcrt/internal/input"
	"plexcrt/internal/plex"
)

type homeFlowRoundTrip func(*http.Request) (*http.Response, error)

func (f homeFlowRoundTrip) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func flowResponse(status int, body string) *http.Response {
	return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader(body))}
}

type flowFixture struct {
	t               *testing.T
	mu              sync.Mutex
	account         string
	users           string
	selectedToken   string
	validPIN        string
	requests        []string
	identityStart   chan struct{}
	identityRelease <-chan struct{}
}

func (f *flowFixture) RoundTrip(r *http.Request) (*http.Response, error) {
	key := r.Method + " " + r.URL.Host + r.URL.Path
	var requestBody string
	if r.Body != nil {
		b, _ := io.ReadAll(r.Body)
		requestBody = string(b)
	}
	f.mu.Lock()
	f.requests = append(f.requests, key+" token="+r.Header.Get("X-Plex-Token"))
	f.mu.Unlock()
	if r.URL.Host == "plex.tv" {
		switch r.URL.Path {
		case "/api/v2/user":
			if f.identityStart != nil {
				select {
				case f.identityStart <- struct{}{}:
				default:
				}
			}
			if f.identityRelease != nil {
				<-f.identityRelease
			}
			return flowResponse(200, f.account), nil
		case "/api/home/users":
			return flowResponse(200, f.users), nil
		case "/api/v2/resources":
			return flowResponse(200, `[{"name":"Test Server","clientIdentifier":"server-id","provides":"server","accessToken":"server-token","owned":true,"connections":[{"uri":"http://server.test","local":true}]}]`), nil
		default:
			if strings.HasSuffix(r.URL.Path, "/switch") {
				values, _ := url.ParseQuery(requestBody)
				if f.validPIN != "" && values.Get("pin") != f.validPIN {
					return flowResponse(401, `PIN rejected`), nil
				}
				return flowResponse(200, `<user authenticationToken="`+f.selectedToken+`"/>`), nil
			}
			return flowResponse(404, ``), nil
		}
	}
	if r.URL.Host == "server.test" && r.URL.Path == "/identity" {
		return flowResponse(200, `<MediaContainer machineIdentifier="server-id"/>`), nil
	}
	// Empty but valid server responses let App.Connect build its home page.
	return flowResponse(200, `<MediaContainer/>`), nil
}

func (f *flowFixture) count(path string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, req := range f.requests {
		if strings.Contains(req, path) {
			n++
		}
	}
	return n
}

func newHomeFlowApp(t *testing.T, cfg *Config) *App {
	t.Helper()
	a := New(nil, nil, &Player{}, log.New(io.Discard, "", 0))
	a.Cfg = cfg
	a.SetCacheDir(t.TempDir())
	return a
}

func installHomeGate(a *App, token string) *HomeUsers {
	h := NewHomeUsers(a, token)
	a.stack = []Screen{h}
	return h
}

func pumpHomeUntil(t *testing.T, a *App, ready func() bool) {
	t.Helper()
	deadline := time.Now().Add(4 * time.Second)
	for time.Now().Before(deadline) {
		a.runLater()
		if ready() {
			return
		}
		select {
		case <-a.Wake:
		case <-time.After(5 * time.Millisecond):
		}
	}
	a.runLater()
	if !ready() {
		t.Fatal("timed out waiting for home flow")
	}
}

func waitHomeCallback(t *testing.T, a *App) {
	t.Helper()
	select {
	case <-a.Wake:
		a.runLater()
	case <-time.After(2 * time.Second):
		t.Fatal("home completion was not queued")
	}
}

func useFlowFixture(t *testing.T, f *flowFixture) {
	t.Helper()
	old := http.DefaultTransport
	http.DefaultTransport = homeFlowRoundTrip(f.RoundTrip)
	t.Cleanup(func() { http.DefaultTransport = old })
}

func TestHomeFlowOrdinaryAccountUsesRootTokenWithoutHomeEndpoints(t *testing.T) {
	f := &flowFixture{t: t, account: `{"id":7,"title":"Alice","home":false}`}
	useFlowFixture(t, f)
	cfg := LoadConfig(filepath.Join(t.TempDir(), "settings.json"))
	cfg.ClientID, cfg.Token = "client", "account-token"
	a := newHomeFlowApp(t, cfg)
	h := installHomeGate(a, cfg.Token)
	pumpHomeUntil(t, a, func() bool { return a.Plex != nil })
	if f.count("/api/home/users") != 0 || f.count("/switch") != 0 {
		t.Fatal("ordinary account called Plex Home endpoints")
	}
	if f.count("/api/v2/resources token=account-token") != 1 {
		t.Fatal("ordinary account did not list resources with the account token")
	}
	if cfg.HomeEnabled || cfg.HomePickerNeeded || cfg.HomeUserID != "7" || cfg.HomeToken != "account-token" || cfg.ServerToken != "server-token" {
		t.Fatalf("unexpected saved identity: %#v", cfg)
	}
	if h.home || h.userToken != "account-token" {
		t.Fatal("ordinary identity did not retain the root token")
	}
}

func TestHomeFlowWrongProtectedPINStopsBeforeServerLookup(t *testing.T) {
	f := &flowFixture{t: t,
		account:       `{"id":1,"title":"Owner","home":true,"protected":false,"restricted":false}`,
		users:         `<MediaContainer><User id="1" title="Owner" protected="0" restricted="0"/><User id="2" title="Child" protected="1" restricted="1"/></MediaContainer>`,
		validPIN:      "2468",
		selectedToken: "child-token",
	}
	useFlowFixture(t, f)
	cfg := LoadConfig(filepath.Join(t.TempDir(), "settings.json"))
	cfg.ClientID, cfg.Token = "client", "account-token"
	a := newHomeFlowApp(t, cfg)
	h := installHomeGate(a, cfg.Token)
	pumpHomeUntil(t, a, func() bool { return !h.busy && h.phase == "users" && len(h.users) == 2 })
	h.Key(input.Event{Key: input.Down}, time.Now())
	h.Key(input.Event{Key: input.Enter}, time.Now())
	if h.phase != "pin" {
		t.Fatal("protected child did not require a PIN")
	}
	for _, digit := range "1357" {
		h.Key(input.Event{Keyboard: true, Text: digit}, time.Now())
	}
	pumpHomeUntil(t, a, func() bool { return !h.busy && h.phase == "pin" && h.problem != "" })
	if f.count("/api/v2/resources") != 0 || f.count("/identity") != 0 {
		t.Fatal("server lookup occurred after an incorrect PIN")
	}
	if cfg.ServerURL != "" || cfg.HomeToken != "" || a.Plex != nil {
		t.Fatal("failed PIN granted a signed-in session")
	}
}

func TestHomeFlowSelectedChildUsesItsTokenAndSetsPlaybackEnvironment(t *testing.T) {
	f := &flowFixture{t: t,
		account:       `{"id":1,"title":"Owner","home":true,"protected":false,"restricted":false}`,
		users:         `<MediaContainer><User id="1" title="Owner" protected="0" restricted="0"/><User id="2" title="Child" protected="0" restricted="1"/></MediaContainer>`,
		selectedToken: "child-token",
	}
	useFlowFixture(t, f)
	cfg := LoadConfig(filepath.Join(t.TempDir(), "settings.json"))
	cfg.ClientID, cfg.Token = "client", "account-token"
	a := newHomeFlowApp(t, cfg)
	h := installHomeGate(a, cfg.Token)
	pumpHomeUntil(t, a, func() bool { return !h.busy && h.phase == "users" && len(h.users) == 2 })
	h.Key(input.Event{Key: input.Down}, time.Now())
	h.Key(input.Event{Key: input.Enter}, time.Now())
	pumpHomeUntil(t, a, func() bool { return a.Plex != nil })
	if f.count("/api/v2/resources token=child-token") != 1 {
		t.Fatal("server resources were not requested with the selected child's token")
	}
	if f.count("/identity token=server-token") != 1 {
		t.Fatal("server was not probed with its server-specific token")
	}
	if cfg.HomeUserID != "2" || cfg.HomeUserTitle != "Child" || cfg.HomeToken != "child-token" || !cfg.HomeRestricted || cfg.AutoSignIn {
		t.Fatalf("selected child identity not saved safely: %#v", cfg)
	}
	if a.Player.Client != a.Plex || a.Plex.Host != "http://server.test" || a.Plex.Token != "server-token" {
		t.Fatalf("playback client: %#v", a.Player.Client)
	}
}

func TestHomeFlowStaleIdentityAfterSignOutCannotReconnect(t *testing.T) {
	release := make(chan struct{})
	f := &flowFixture{t: t,
		account:         `{"id":7,"title":"Alice","home":false,"protected":false,"restricted":false}`,
		identityStart:   make(chan struct{}, 1),
		identityRelease: release,
	}
	useFlowFixture(t, f)
	cfg := LoadConfig(filepath.Join(t.TempDir(), "settings.json"))
	cfg.ClientID, cfg.Token = "client", "account-token"
	a := newHomeFlowApp(t, cfg)
	h := installHomeGate(a, cfg.Token)
	select {
	case <-f.identityStart:
	case <-time.After(2 * time.Second):
		t.Fatal("identity request did not start")
	}
	if err := cfg.SignOut(); err != nil {
		t.Fatal(err)
	}
	a.stack = nil // the sign-out screen replaces the pending Home gate
	close(release)
	waitHomeCallback(t, a)
	if cfg.Token != "" || cfg.ServerURL != "" || cfg.HomeToken != "" || a.Plex != nil || len(a.stack) != 0 {
		t.Fatal("stale identity response reconnected after sign-out")
	}
	if len(a.later) != 0 {
		t.Fatal("stale completion remained queued")
	}
	_ = h
}

func TestHomeFlowSaveFailureDoesNotGrantAccessOrMutateConfig(t *testing.T) {
	f := &flowFixture{t: t, account: `{"id":7,"title":"Alice","home":false,"protected":false,"restricted":false}`}
	useFlowFixture(t, f)
	dir := t.TempDir()
	cfg := &Config{path: dir, ClientID: "client", Token: "old-account", HomeUserID: "old-user", HomeToken: "old-home-token",
		ServerURL: "http://old-server", ServerToken: "old-server-token", ServerName: "Old", ServerID: "old-id"}
	a := newHomeFlowApp(t, cfg)
	h := installHomeGate(a, "new-account")
	pumpHomeUntil(t, a, func() bool { return !h.busy && h.phase == "servers" && h.problem != "" })
	if cfg.Token != "old-account" || cfg.HomeUserID != "old-user" || cfg.HomeToken != "old-home-token" || cfg.ServerURL != "http://old-server" || cfg.ServerToken != "old-server-token" {
		t.Fatalf("failed save mutated existing credentials: %#v", cfg)
	}
	if a.Plex != nil || a.Player.Client != nil {
		t.Fatal("failed save activated Plex or playback")
	}
}

func TestHomeStartupGateAutoSignInAndLegacyConfig(t *testing.T) {
	for _, tc := range []struct {
		name      string
		auto      bool
		homeID    string
		homeToken string
		wantGate  bool
	}{
		{"auto sign-in off", false, "child", "child-token", true},
		{"auto sign-in on", true, "child", "child-token", false},
		{"legacy config missing home identity", true, "", "", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := &flowFixture{t: t, account: `{"id":7,"title":"Alice","home":false,"protected":false,"restricted":false}`}
			useFlowFixture(t, f)
			cfg := LoadConfig(filepath.Join(t.TempDir(), "settings.json"))
			cfg.ClientID, cfg.Token, cfg.ServerURL, cfg.ServerToken = "client", "account-token", "http://server.test", "server-token"
			cfg.AutoSignIn, cfg.HomeUserID, cfg.HomeToken = tc.auto, tc.homeID, tc.homeToken
			var client *plex.Client
			if cfg.ResumeWithoutPicker() {
				client = plex.New(cfg.ServerURL, cfg.ServerToken, t.TempDir(), cfg.ClientID)
			}
			a := newHomeFlowApp(t, cfg)
			a.Plex = client
			var release chan struct{}
			if client == nil {
				release = make(chan struct{})
				f.identityStart, f.identityRelease = make(chan struct{}, 1), release
			}
			a.Start()
			if tc.wantGate {
				if _, ok := a.top().(*HomeUsers); !ok {
					t.Fatal("startup bypassed user gate")
				}
			} else if _, ok := a.top().(*Home); !ok {
				t.Fatal("remembered sign-in did not open saved server")
			}
			if client == nil {
				select {
				case <-f.identityStart:
				case <-time.After(2 * time.Second):
					t.Fatal("startup gate did not check account identity")
				}
				if f.count("/api/v2/resources") != 0 {
					t.Fatal("startup gate reached a server before checking identity")
				}
				a.stack = nil
				close(release)
				waitHomeCallback(t, a)
			}
		})
	}
}
