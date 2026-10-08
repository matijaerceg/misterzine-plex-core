package ui

import (
	"sync"
	"time"

	"plexcrt/internal/gfx"
	"plexcrt/internal/input"
	"plexcrt/internal/plex"
)

// Login is the first-run screen: a plex.tv/link code, then the account's
// servers. Network work runs in goroutines; the screen redraws on Wake.
type Login struct {
	app    *App
	mu     sync.Mutex
	pin    *plex.Pin
	stat   string // what is going on, for the status line
	err    string
	tok    string // the account token once the code has been entered
	srvs   []plex.Server
	cur    int
	busy   bool
	picker bool // an existing account can cancel server selection with Back
	gen    int  // bumped on every restart so stale goroutines stand down
	at     time.Time
}

// NewLogin starts the code flow.
func NewLogin(app *App) *Login {
	l := &Login{app: app, at: time.Now()}
	l.newCode()
	return l
}

func (l *Login) wake() {
	select {
	case l.app.Wake <- struct{}{}:
	default:
	}
}

// newCode asks for a link code and polls it until it is claimed.
func (l *Login) newCode() {
	l.mu.Lock()
	l.gen++
	gen := l.gen
	l.pin, l.err, l.tok, l.srvs = nil, "", "", nil
	l.stat = "Getting a code..."
	l.mu.Unlock()
	id := l.app.Cfg.ClientID
	grace := l.at.Add(ConnectGrace)
	go func() {
		pin, err := plex.NewPin(id)
		// no answer soon after start is retried quietly (see ConnectGrace)
		for err != nil && unreachable(err) && time.Now().Before(grace) {
			l.mu.Lock()
			if l.gen != gen {
				l.mu.Unlock()
				return
			}
			l.stat = classify(err, time.Now()).waiting()
			l.mu.Unlock()
			l.wake()
			time.Sleep(ConnectRetry)
			pin, err = plex.NewPin(id)
		}
		l.mu.Lock()
		if l.gen != gen {
			l.mu.Unlock()
			return
		}
		if err != nil {
			l.err = "Cannot reach plex.tv: " + err.Error()
			if p := classify(err, time.Now()); p != problemServer && unreachable(err) {
				headline, _ := p.failure()
				l.err = headline + " " + l.err
			}
			l.stat = ""
			l.mu.Unlock()
			l.wake()
			return
		}
		l.pin = pin
		l.stat = "Waiting for the code..."
		l.mu.Unlock()
		l.wake()
		for {
			time.Sleep(2 * time.Second)
			l.mu.Lock()
			if l.gen != gen {
				l.mu.Unlock()
				return
			}
			expired := time.Now().After(pin.Expires)
			l.mu.Unlock()
			if expired {
				l.mu.Lock()
				l.err = "The code expired. Press OK for a new one."
				l.stat = ""
				l.mu.Unlock()
				l.wake()
				return
			}
			tok, err := plex.CheckPin(id, pin.ID)
			if err != nil || tok == "" {
				continue
			}
			l.mu.Lock()
			if l.gen != gen {
				l.mu.Unlock()
				return
			}
			l.tok = tok
			l.stat = "Signed in. Finding your servers..."
			l.mu.Unlock()
			l.wake()
			l.findServers(gen, tok)
			return
		}
	}()
}

func (l *Login) findServers(gen int, tok string) {
	srvs, err := plex.Servers(l.app.Cfg.ClientID, tok)
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.gen != gen {
		return
	}
	if err != nil {
		l.err = "Cannot list your servers: " + err.Error()
		l.stat = ""
		l.wake()
		return
	}
	if len(srvs) == 0 {
		l.err = "This account has no media servers."
		l.stat = ""
		l.wake()
		return
	}
	l.srvs = srvs
	l.stat = ""
	l.wake()
	if len(srvs) == 1 {
		go l.connect(gen, srvs[0])
	}
}

// connect finds a way to reach the server, saves it and opens the app.
func (l *Login) connect(gen int, s plex.Server) {
	l.mu.Lock()
	l.busy = true
	l.stat = "Connecting to " + s.Name + "..."
	l.mu.Unlock()
	l.wake()
	uri, err := plex.Reach(s)
	l.mu.Lock()
	if l.gen != gen {
		l.mu.Unlock()
		return
	}
	if err != nil {
		l.busy = false
		l.err = "Cannot reach " + s.Name + ": " + err.Error()
		l.stat = ""
		l.mu.Unlock()
		l.wake()
		return
	}
	l.stat = "Saving sign-in..."
	l.mu.Unlock()
	l.app.Later(func() { l.finishConnect(gen, s, uri) })
}

// Commit on the UI thread so cancellation/sign-out cannot race a late result.
func (l *Login) finishConnect(gen int, s plex.Server, uri string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.gen != gen {
		return
	}
	l.busy = false
	cfg := l.app.Cfg
	next := *cfg
	if next.Token != l.tok {
		next.AccountName = ""
	}
	// library keys are the server's own: another server's "1" is another
	// library. Names need not be unique, so the identifier decides (by the
	// name for settings saved before it was kept).
	same := next.ServerName == s.Name
	if next.ServerID != "" && s.ID != "" {
		same = next.ServerID == s.ID
	}
	if !same {
		next.HiddenLibraries = nil
	}
	next.Token, next.ServerURL, next.ServerToken, next.ServerName, next.ServerID = l.tok, uri, s.AccessToken, s.Name, s.ID
	if err := next.Save(); err != nil {
		l.app.Log.Printf("config: %v", err)
		l.err = "Could not save sign-in. Check free space and retry."
		l.stat = ""
		return
	}
	*cfg = next
	l.app.loadAccountName()
	l.stat = "Connected."
	l.app.Log.Printf("signed in: server %q at %s", s.Name, uri)
	l.app.Connected <- struct{}{}
}

// Key: OK retries after an error, or picks a server from the list.
func (l *Login) Key(ev input.Event, now time.Time) {
	if ev.Release {
		return
	}
	l.mu.Lock()
	busy, nsrv, hasErr := l.busy, len(l.srvs), l.err != ""
	l.mu.Unlock()
	if busy {
		return
	}
	switch ev.Key {
	case input.Up:
		if l.cur > 0 {
			l.cur--
		}
	case input.Down:
		if l.cur < nsrv-1 {
			l.cur++
		}
	case input.Enter:
		if nsrv > 0 {
			l.mu.Lock()
			s := l.srvs[l.cur]
			gen := l.gen
			l.err = ""
			l.mu.Unlock()
			go l.connect(gen, s)
		} else if hasErr {
			if l.picker {
				l.refreshServers()
			} else {
				l.newCode()
			}
		}
	}
}

// Draw paints the code page or the server list.
func (l *Login) Draw(c *gfx.Canvas, now time.Time) bool {
	c.Fill(0, 0, c.W, c.H, gfx.Bg)
	f := l.app.F
	l.mu.Lock()
	pin, stat, errS, srvs, busy := l.pin, l.stat, l.err, l.srvs, l.busy
	l.mu.Unlock()
	l.app.Mark.PlaceFlat(c, SafeX+16, SafeY-8)
	y := SafeY + 60
	if len(srvs) > 1 || (len(srvs) == 1 && errS != "") {
		l.app.text(c, SafeX, y, f.Big, gfx.Grey, "Choose a server")
		y += f.Big.Height() + 24
		for i, s := range srvs {
			col := gfx.GreyHi
			if i == l.cur {
				col = gfx.White
				focusBar(c, SafeX, y, f.Body.Height())
			}
			l.app.text(c, SafeX, y, f.Body, col, f.Body.Fit(s.Name, SafeW-120))
			if !s.Owned {
				l.app.textRight(c, SafeX+SafeW, y+2, f.SmallBold, gfx.GreyLo, "shared")
			}
			y += ListRowH
		}
	} else {
		l.app.text(c, SafeX, y, f.Big, gfx.Grey, "Sign in to Plex")
		y += f.Big.Height() + 20
		l.app.text(c, SafeX, y, f.Body, gfx.GreyHi, "On your phone or computer, go to")
		y += f.Body.Height() + 10
		l.app.text(c, SafeX, y, f.Big, gfx.Amber, "plex.tv/link")
		y += f.Big.Height() + 10
		l.app.text(c, SafeX, y, f.Body, gfx.GreyHi, "and enter this code:")
		y += f.Body.Height() + 24
		if pin != nil {
			// the code, letter-spaced
			x := SafeX
			for i := 0; i < len(pin.Code); i++ {
				l.app.text(c, x, y, f.Big, gfx.White, pin.Code[i:i+1])
				x += f.Big.Width(pin.Code[i:i+1]) + 18
			}
			y += f.Big.Height() + 24
		}
	}
	y = SafeBottom - 2*f.Body.Height() - 10
	if !l.picker {
		l.app.text(c, SafeX, SafeBottom-18, f.SmallBold, gfx.GreyLo, "Back: Options")
	}
	if errS != "" {
		l.app.text(c, SafeX, y, f.Body, gfx.GreyHi, f.Body.Fit(errS, SafeW))
		return false
	}
	if stat != "" {
		l.app.text(c, SafeX, y, f.Body, gfx.GreyLo, stat)
		if busy || pin != nil {
			sweep(c, SafeX, y+f.Body.Height()+3, f.Body.Width(stat), BarW, now.Sub(l.at))
			return true
		}
	}
	return false
}

// NewServerPicker refreshes connections without discarding a working account.
func NewServerPicker(app *App) *Login {
	l := &Login{app: app, picker: true, tok: app.Cfg.Token, at: time.Now()}
	l.refreshServers()
	return l
}

func (l *Login) refreshServers() {
	l.mu.Lock()
	l.gen++
	gen, tok := l.gen, l.tok
	l.srvs, l.err, l.stat = nil, "", "Finding your servers..."
	l.mu.Unlock()
	go l.findServers(gen, tok)
}

func (l *Login) Back() bool {
	if l.picker {
		l.mu.Lock()
		l.gen++
		l.mu.Unlock()
		l.app.Pop()
	} else {
		l.app.Push(NewOptions(l.app))
	}
	return true
}
