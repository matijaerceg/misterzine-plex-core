# Release hardware check

On each unit: install from Scripts and launch from the main menu; link and select a server; browse;
play, pause, seek and stop one item; leave a menu and a paused item alone for three
minutes and check the screen dims and the next press only restores it; check
theme/taps; leave to MiSTer Menu and
relaunch. Confirm the active CRT profile stays at 480i. On HDMI, test the 480p
hold-to-confirm and timeout-to-revert once. Check normal startup has no test card.

For subtitle size, use a text subtitle track and compare Normal, Large and Extra
large on CRT and HDMI. Check Options and playback More show the same saved choice
after relaunch. Change size while playing and paused: the position should be kept,
and paused playback should stay paused. Choosing the current size or changing it
with subtitles off should not reload the video; enabling subtitles afterwards
should use the saved size. Check More is available for a 4:3 video too. Compare
styled ASS/SSA and image-based PGS/VobSub separately and record any server or
format limitations. Include long lines with cropping enabled.

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
