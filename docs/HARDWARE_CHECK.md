# Release hardware check

On each unit: install from Scripts and launch from the main menu; link the
device and select a server; browse; play, pause, seek and stop one item; leave
a menu and a paused item alone for three minutes and check the screen dims and
the next press only restores it; check theme music; leave to MiSTer Menu and
relaunch. Check normal startup has no test card.

Play one file the core can take as stored (H.264 up to 720p) and one that needs
a transcode (HEVC, or a 1080p file), and check the playback log names the
direct stream and the transcode. Check the lowest bitrate steps on Wi-Fi.

Check each Output Mode the unit's display accepts, from the core OSD: 480i60 and
576i50 on a CRT, 480p60, 576p50 and Native HDMI on HDMI. With 240p Playback on,
check that menus stay interlaced and video switches. With Refresh Rate Match on,
play a 25 fps and a 24 or 30 fps item and check the output switches family and
returns when playback stops. On a 576-line mode with matching off, check Play
24fps at 25fps speeds up a 24 fps film.

For subtitles, use a file with an SRT track, an ASS/SSA track and a PGS or VobSub
track. With the SRT track, compare Normal, Large and Extra large on CRT and HDMI,
check the cues come and go with the speech, and check a long line wraps inside
the safe area with cropping on. Changing size, turning subtitles off and on, and
switching between text tracks should never reload the video, playing or paused.
Check Options and playback More show the same saved choice after relaunch, and
More is available for a 4:3 video too. The PGS or VobSub track should restart
the stream once and appear burned in; a Cyrillic or other non-Latin text track
should do the same after a moment. Record any server or format limitations.

For household profiles, test an ordinary account with no Plex Home (no picker),
a Home with one unprotected profile, and a Home with multiple profiles including
a protected primary account and a managed profile. Check wrong and correct PINs
using the controller and keyboard, and scroll a long profile list. After switching,
confirm the available libraries, Continue Watching and playback progress belong
to the selected profile. Relaunch with automatic sign-in off and on; verify a
managed profile cannot change that option and explicit switching still asks for
a protected profile's PIN. Check network failure during selection never opens
the primary account, and check startup while the network/clock is still settling.

Record the hardware and output combinations tested in the release notes.
Keep raw device logs and internal test journals outside this public repository.
