package updates

import "plexcrt/internal/beta"

// Channel is the build's release channel, set at link time
// (-X plexcrt/internal/updates.Channel=public|beta); "" is a development build.
// A build whose builder set only the beta gate's channel (beta.Channel) takes
// that one, so the two never disagree.
var Channel string

func init() {
	if Channel == "" {
		Channel = beta.Channel
	}
}

// Installer is the Scripts entry that installs or repairs this build's channel:
// the one-file installer a user downloads and copies into Scripts
// (release/build_distribution.py names them). Installing adds no installer of
// its own, so a message that sends the user to one names this file.
func Installer() string {
	if Channel == "public" {
		return "MisterZine-Plex-Install-Public"
	}
	return "MisterZine-Plex-Install-Beta"
}
