package ui

import (
	"strings"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/plex"
)

// HomeUsers is the gate between a linked account and its libraries. All
// network results return to the UI thread and are ignored after replacement.
type HomeUsers struct {
	app             *App
	rootToken       string
	users           []plex.HomeUser
	servers         []plex.Server
	user            plex.HomeUser
	userToken       string
	home            bool
	pickerNeeded    bool
	cur             int
	phase           string // users, pin, servers, working
	status, problem string
	busy            bool
	pin             string
	digit           int
	gen             int
}

func NewHomeUsers(app *App, token string) *HomeUsers {
	h := &HomeUsers{app: app, rootToken: token, phase: "users"}
	h.refresh()
	return h
}

func (h *HomeUsers) live(gen int) bool {
	return h.gen == gen && len(h.app.stack) > 0 && h.app.top() == h
}

func (h *HomeUsers) refresh() {
	h.gen++
	gen := h.gen
	h.phase, h.status, h.problem, h.busy = "working", "Connecting to Plex...", "", true
	id, token := h.app.Cfg.ClientID, h.rootToken
	go func() {
		deadline := time.Now().Add(ConnectGrace)
		var identity plex.HomeUser
		var home bool
		var err error
		for {
			identity, home, err = plex.AccountHomeIdentity(id, token)
			if err == nil || !unreachable(err) || time.Now().After(deadline) {
				break
			}
			time.Sleep(ConnectRetry)
		}
		var users []plex.HomeUser
		if err == nil && home {
			for {
				users, err = plex.HomeUsers(id, token)
				if err == nil || !unreachable(err) || time.Now().After(deadline) {
					break
				}
				time.Sleep(ConnectRetry)
			}
		}
		h.app.Later(func() {
			if !h.live(gen) {
				return
			}
			h.busy = false
			if err != nil || (home && len(users) == 0) || (!home && identity.Protected) {
				h.phase, h.status, h.problem = "users", "", "Could not load Plex users. Press OK to retry."
				return
			}
			h.home = home
			if !home {
				h.user, h.userToken = identity, token
				h.findServers()
				return
			}
			h.pickerNeeded = len(users) > 1 || users[0].Protected
			h.users, h.phase, h.status = users, "users", ""
			if len(users) == 1 && !users[0].Protected {
				h.selectUser(users[0])
			}
		})
	}()
}

func (h *HomeUsers) selectUser(u plex.HomeUser) {
	h.user = u
	h.pin, h.digit, h.problem = "", 0, ""
	if u.Protected {
		h.phase = "pin"
		return
	}
	h.switchUser("")
}

func (h *HomeUsers) switchUser(pin string) {
	h.gen++
	gen := h.gen
	h.phase, h.status, h.busy, h.problem = "working", "Signing in as "+h.user.Title+"...", true, ""
	id, token, user := h.app.Cfg.ClientID, h.rootToken, h.user
	// The PIN remains only in this request. It is never saved or logged.
	go func() {
		selected, err := plex.SwitchHomeUser(id, token, user.ID, pin)
		h.app.Later(func() {
			if !h.live(gen) {
				return
			}
			if err != nil || selected == "" {
				h.busy, h.status = false, ""
				if user.Protected {
					h.phase, h.problem, h.pin = "pin", "Could not sign in. Check PIN and connection.", ""
				} else {
					h.phase, h.problem = "users", "Could not switch Plex user. Press OK to retry."
				}
				return
			}
			h.userToken = selected
			h.findServers()
		})
	}()
}

func (h *HomeUsers) findServers() {
	h.gen++
	gen := h.gen
	h.phase, h.status, h.busy = "working", "Finding your servers...", true
	id, token := h.app.Cfg.ClientID, h.userToken
	go func() {
		servers, err := plex.Servers(id, token)
		h.app.Later(func() {
			if !h.live(gen) {
				return
			}
			h.busy = false
			if err != nil || len(servers) == 0 {
				h.phase, h.status, h.problem = "users", "", "Could not find a server for this user. Press OK to retry."
				h.cur = 0
				return
			}
			h.servers, h.phase, h.status, h.problem = servers, "servers", "", ""
			h.cur = 0
			for i, server := range servers {
				if h.app.Cfg.ServerID != "" && server.ID == h.app.Cfg.ServerID {
					h.cur = i
					break
				}
			}
			if len(servers) == 1 || (h.app.Cfg.ServerID != "" && servers[h.cur].ID == h.app.Cfg.ServerID) {
				h.connectServer(servers[h.cur])
			}
		})
	}()
}

func (h *HomeUsers) connectServer(server plex.Server) {
	h.gen++
	gen := h.gen
	h.phase, h.status, h.busy, h.problem = "working", "Connecting to "+server.Name+"...", true, ""
	go func() {
		uri, err := plex.Reach(server, h.app.Log.Printf)
		h.app.Later(func() {
			if !h.live(gen) {
				return
			}
			h.busy = false
			if err != nil {
				h.phase, h.status, h.problem = "servers", "", reachFailure("server", err)
				return
			}
			h.finish(server, uri)
		})
	}()
}

func (h *HomeUsers) finish(s plex.Server, uri string) {
	cfg := h.app.Cfg
	next := cfg.snapshot()
	changedUser := next.HomeUserID != h.user.ID || next.HomeToken == ""
	if !h.home && next.Token == h.rootToken && next.HomeUserID == "" {
		// Existing ordinary accounts were saved before Home identities existed.
		// Their server-specific preferences still belong to this same account.
		changedUser = false
	}
	changedServer := next.ServerName != s.Name
	if next.ServerID != "" && s.ID != "" {
		changedServer = next.ServerID != s.ID
	}
	if changedUser {
		next.RecentSearches = nil
	}
	if changedUser || changedServer {
		next.HiddenLibraries = nil
	}
	// A new account link must not inherit an earlier household's auto sign-in.
	if next.Token != h.rootToken {
		next.AutoSignIn = false
		next.AccountName = ""
	}
	next.Token = h.rootToken
	next.HomeUserID, next.HomeUserTitle = h.user.ID, h.user.Title
	next.HomeToken, next.HomeRestricted = h.userToken, h.user.Restricted
	next.HomeEnabled, next.HomePickerNeeded = h.home, h.pickerNeeded
	next.ServerURL, next.ServerToken, next.ServerName, next.ServerID = uri, s.AccessToken, s.Name, s.ID
	if err := next.Save(); err != nil {
		h.app.Log.Printf("config: %v", err)
		h.phase, h.status, h.problem, h.busy = "servers", "", "Could not save sign-in. Check free space and retry.", false
		return
	}
	*cfg = next
	h.gen++
	h.app.Connect()
}

func (h *HomeUsers) Key(ev input.Event, now time.Time) {
	if ev.Release || h.busy {
		return
	}
	if h.phase == "pin" {
		if ev.Keyboard && ev.Text >= '0' && ev.Text <= '9' {
			h.pin += string(ev.Text)
			if len(h.pin) == 4 {
				h.switchUser(h.pin)
				h.pin = ""
			}
			return
		}
		switch ev.Key {
		case input.Up:
			h.digit = (h.digit + 1) % 10
		case input.Down:
			h.digit = (h.digit + 9) % 10
		case input.Enter, input.Right:
			h.pin += string(rune('0' + h.digit))
			if len(h.pin) == 4 {
				h.switchUser(h.pin)
				h.pin = ""
			}
		case input.Left, input.Back:
			if len(h.pin) > 0 {
				h.pin = h.pin[:len(h.pin)-1]
			} else {
				h.phase, h.problem = "users", ""
			}
		}
		return
	}
	if h.phase == "users" {
		if len(h.users) > 0 {
			h.cur = max(0, min(h.cur, len(h.users)-1))
		}
		if h.problem != "" && len(h.users) == 0 && ev.Key == input.Enter {
			h.refresh()
			return
		}
		if ev.Key == input.Up && h.cur > 0 {
			h.cur--
		}
		if ev.Key == input.Down && h.cur+1 < len(h.users) {
			h.cur++
		}
		if ev.Key == input.Enter && len(h.users) > 0 {
			h.selectUser(h.users[h.cur])
		}
		return
	}
	if h.phase == "servers" {
		if len(h.servers) > 0 {
			h.cur = max(0, min(h.cur, len(h.servers)-1))
		}
		if ev.Key == input.Up && h.cur > 0 {
			h.cur--
		}
		if ev.Key == input.Down && h.cur+1 < len(h.servers) {
			h.cur++
		}
		if ev.Key == input.Enter && len(h.servers) > 0 {
			h.connectServer(h.servers[h.cur])
		}
	}
}

func (h *HomeUsers) Back() bool {
	if h.busy {
		h.gen++ // any in-flight response may no longer open a library
		h.busy, h.phase, h.status = false, "users", ""
		h.problem = "Press OK to retry."
		h.app.Push(NewOptions(h.app))
		return true
	}
	if h.phase == "pin" {
		if len(h.pin) > 0 {
			h.pin = h.pin[:len(h.pin)-1]
		} else {
			h.phase, h.problem = "users", ""
		}
		return true
	}
	if h.phase == "servers" {
		h.phase, h.cur = "users", 0
		if len(h.users) == 0 {
			h.problem = "Press OK to retry."
		}
		return true
	}
	// The account is linked; use Options to sign out if needed. The previous
	// user's library is deliberately unavailable until a user signs in.
	h.app.Push(NewOptions(h.app))
	return true
}

func (h *HomeUsers) Draw(c *gfx.Canvas, now time.Time) bool {
	c.Fill(0, 0, c.W, c.H, gfx.Bg)
	f := h.app.F
	h.app.Mark.PlaceFlat(c, SafeX+16, SafeY-8)
	y := SafeY + 60
	title := "Who's watching?"
	if h.phase == "working" {
		title = "Connecting to Plex"
	}
	if h.phase == "pin" {
		title = "Enter PIN for " + h.user.Title
	}
	if h.phase == "servers" {
		title = "Choose a server"
	}
	h.app.text(c, SafeX, y, f.Big, gfx.Grey, f.Big.Fit(title, SafeW))
	y += f.Big.Height() + 24
	switch h.phase {
	case "pin":
		h.app.text(c, SafeX, y, f.Big, gfx.White, strings.Repeat("*  ", len(h.pin))+strings.Repeat("_  ", 4-len(h.pin)))
		h.app.text(c, SafeX, y+65, f.Body, gfx.GreyHi, "Up/Down: digit "+itoa(h.digit)+"    OK: add digit")
		h.app.text(c, SafeX, y+98, f.SmallBold, gfx.GreyLo, "Back: erase or choose another user")
	case "users":
		first := max(0, min(h.cur-2, len(h.users)-5))
		for i := first; i < min(first+5, len(h.users)); i++ {
			u := h.users[i]
			col := gfx.GreyHi
			if i == h.cur {
				col = gfx.White
				focusBar(c, SafeX, y, f.Body.Height())
			}
			name := u.Title
			if u.Protected {
				name += "  (PIN)"
			}
			h.app.text(c, SafeX, y, f.Body, col, f.Body.Fit(name, SafeW))
			y += ListRowH
		}
	case "servers":
		first := max(0, min(h.cur-2, len(h.servers)-5))
		for i := first; i < min(first+5, len(h.servers)); i++ {
			s := h.servers[i]
			col := gfx.GreyHi
			if i == h.cur {
				col = gfx.White
				focusBar(c, SafeX, y, f.Body.Height())
			}
			h.app.text(c, SafeX, y, f.Body, col, f.Body.Fit(s.Name, SafeW))
			y += ListRowH
		}
	}
	if h.status != "" {
		h.app.text(c, SafeX, SafeBottom-55, f.Body, gfx.GreyLo, f.Body.Fit(h.status, SafeW))
		return true
	}
	if h.problem != "" {
		// two lines: the router remedy does not fit one
		lines := wrap(f.Body, h.problem, SafeW, 2)
		y := SafeBottom - 55 - (len(lines)-1)*(f.Body.Height()+4)
		for _, line := range lines {
			h.app.text(c, SafeX, y, f.Body, gfx.GreyHi, line)
			y += f.Body.Height() + 4
		}
	}
	return false
}
