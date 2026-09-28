package updates

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
)

type Status struct {
	Updated float64  `json:"updated"`
	Stage   string   `json:"stage"`
	Message string   `json:"message"`
	Detail  string   `json:"detail"`
	PID     int      `json:"pid"`
	Release *Release `json:"release"`
}

func (s Status) Busy() bool {
	return s.Stage == "download" || s.Stage == "verify" || s.Stage == "install" || s.Stage == "activating"
}
func ReadStatus(root string) Status {
	var s Status
	data, err := os.ReadFile(filepath.Join(root, "updates/status.json"))
	if err != nil {
		return s
	}
	if len(data) > 128<<10 || json.Unmarshal(data, &s) != nil {
		return Status{Stage: "failed", Message: "Could not read update status."}
	}
	if s.Busy() && (s.PID <= 0 || syscall.Kill(s.PID, 0) != nil) {
		s.Stage = "failed"
		s.Message = "The updater stopped without reporting a result. Your current version will keep working. Return to the MiSTer menu and open Plex again before retrying."
	}
	return s
}

// Holder is who holds the worker lock. An updater started meanwhile would
// exit at once without a word, so this is asked before starting one.
type Holder int

const (
	Nobody      Holder = iota
	Maintenance        // the launcher's and manager's checks, shared and for moments
	Updater            // an update at work, exclusive
)

func LockHolder(root string) Holder {
	f, err := os.Open(filepath.Join(root, "updates/worker.lock"))
	if err != nil {
		return Nobody
	}
	defer f.Close()
	fd := int(f.Fd())
	if syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB) == nil {
		syscall.Flock(fd, syscall.LOCK_UN)
		return Nobody
	}
	if syscall.Flock(fd, syscall.LOCK_SH|syscall.LOCK_NB) == nil {
		syscall.Flock(fd, syscall.LOCK_UN)
		return Maintenance
	}
	return Updater
}

// Copy the worker before starting it: installing a new runtime must not change
// the code supervising the current update or its recovery path. The channel
// closes when the worker exits.
func Start(root, action string, release *Release) (<-chan struct{}, error) {
	if action != "prepare" && action != "activate" {
		return nil, fmt.Errorf("invalid update action")
	}
	folder := filepath.Join(root, "updates")
	if err := os.MkdirAll(folder, 0700); err != nil {
		return nil, err
	}
	worker, err := os.MkdirTemp(folder, "worker-")
	if err != nil {
		return nil, err
	}
	for _, name := range []string{"manager.py", "update_service.py", "catalogue.py", "menu_launcher.py"} {
		data, e := os.ReadFile(filepath.Join(root, name))
		if e != nil {
			return nil, fmt.Errorf("run MisterZine-Plex-Install to add update support")
		}
		if e = os.WriteFile(filepath.Join(worker, name), data, 0600); e != nil {
			return nil, e
		}
	}
	args := []string{filepath.Join(worker, "update_service.py"), action, "--card", filepath.Dir(root)}
	if release != nil {
		if err = release.Validate(); err != nil {
			return nil, err
		}
		data, _ := json.Marshal(release)
		request := filepath.Join(worker, "request.json")
		if err = os.WriteFile(request, data, 0600); err != nil {
			return nil, err
		}
		args = append(args, "--request", request)
	}
	log, err := os.OpenFile(filepath.Join(folder, "worker.log"), os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
	if err != nil {
		return nil, err
	}
	cmd := exec.Command("python3", args...)
	// The app marks its descendants as playback-owned for cleanup. An updater
	// must survive that cleanup when it stops the app for activation.
	for _, item := range os.Environ() {
		if !strings.HasPrefix(item, "MISTERZINE_PLEX_OWNER=") && !strings.HasPrefix(item, "MISTERZINE_PLEX_READY_FILE=") {
			cmd.Env = append(cmd.Env, item)
		}
	}
	cmd.Stdout = log
	cmd.Stderr = log
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err = cmd.Start(); err != nil {
		log.Close()
		return nil, err
	}
	exited := make(chan struct{})
	go func() { cmd.Wait(); log.Close(); close(exited) }()
	return exited, nil
}
