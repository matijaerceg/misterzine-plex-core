# Reference

Detailed behavior and display settings. For everyday help, see the
[help page](../release/README.md).

## Using Plex


### Controls

- D-pad moves the selection; OK opens it; Back goes back or opens the drawer.
- In the library wall, L/R jumps by sort letter or page. Back selects the view
  tabs, then returns to the previous screen.
- During playback, OK opens the controls. Left/right selects an action; OK
  activates it. Up opens the scrubber. Back or Down closes the controls; Back
  with the controls hidden stops playback. Audio/subtitle menus use the same
  controls. In the scrubber, taps step the dot ten seconds and a hold runs it,
  speeding up once after half a second; the seek goes on its own 400 ms after
  the last release (OK sends it at once). Down from the scrubber returns to the
  buttons and keeps the new position; Back returns without it.
  With the controls hidden, left/right shows a strip with the title, the
  progress bar and the times, and works the same way: taps and holds add
  up into one seek. The last frame stays on screen until the new position
  starts playing. **More** holds the crop for the playback under way (see
  Display setup); it is dimmed when no crop would change the picture.
- A movie or episode in Continue Watching has **Remove from Continue Watching**
  as the last action on its page. Plex keeps the resume point, and playing it
  again puts it back in the row. Servers without a Continue Watching list
  don't show the action.
- The menu lists Home, Search, the movie and TV libraries, Options, Exit to
  MiSTer menu and Patreon. A long list of libraries scrolls, and the menu opens
  on the library visited last. Patreon says what membership gets you and holds
  **Beta access**; on an unlocked beta it thanks you instead.
- Options contains video mode, video geometry and crop, theme music, navigation
  taps, autoplay, bitrate, downmix boost, the 4:3 filter, server selection and
  sign-out. A scrollbar on the right shows where the list is. The 4:3 filter
  applies to the
  home rows, search and every library view. Movies and episodes are judged by
  their own picture; a show by its first episode. Each TV library is read once
  for that, the first time the filter needs it, and the answers are kept in the
  cache folder. An update waiting under Options is marked with a purple UPDATE
  mark at the top of Home and an amber dot in the menu.
- After three minutes without a press in the menus or on a paused video, the
  screen dims to a quarter of its brightness. The next press only brings it
  back; it does not also act. The sign-in code never dims.
- To leave the app, choose Exit to MiSTer menu in the menu (before sign-in, at
  the foot of Options). Returning to the MiSTer Menu core from MiSTer's OSD
  works too.

### Connecting after power-on

Opened right after the MiSTer is switched on, Plex can start before the
network is up. On a MiSTer without a clock chip it can also start before the
clock has been set from the internet, and secure connections to the server
fail until then. For its first minute Plex keeps trying every two seconds and
shows **Connecting** with what it is waiting for. After that it shows the error
and tries again every 30 seconds; OK tries at once.

### Sound and playback quality

Theme music and navigation taps can be disabled in Options. **Video bitrate**
defaults to Max: at 480 lines a Plex server sends at most about 2 Mbps of
video, whatever higher ceiling is requested. The lower steps (1.2 Mbps, 1 Mbps,
and 0.4 Mbps at a lower resolution) are for slow connections to the server;
the labels are the video rates measured with Plex Media Server 1.43. Settings
of 4.5 or 6 Mbps saved by older versions read as Max, which is the stream they
already received.

Frames are decoded with H.264's loop filter on, which keeps block edges from
building up between keyframes in dark scenes. The presenter fits each frame
to the 4:3 screen, or to the area set under **Video geometry** (letterbox or
pillarbox, honouring non-square pixels, less what **Video crop** cuts) as it
copies it into the frame ring. 50 and 60 fps video is requested from the
server at half its frame rate (25 or 29.97 fps), which the board can keep up
with.

Surround soundtracks are folded to stereo by the Plex server. A plain fold
comes out noticeably quieter than a stereo track, so **Surround downmix boost**
in Options raises the level when the server downmixes: Off, Small or Large
(the default). Stereo tracks are passed through unchanged. The setting applies
from the next playback.

### Update, rollback and remove

Open **Options > Updates** to see whether a newer version is available, and its
download size. The screen checks when it opens. Checks also run in the background
at startup and every six hours while browsing; failed background checks stay quiet
and are tried again after five minutes. An update found by an earlier check is
still offered while the network is down.

Updates offers only versions newer than the one running. It never reinstalls the
current version or goes back to an older one; **MisterZine-Plex-Rollback** does
that. Public builds notify about newer public releases. Beta notifications are off
by default but can be switched on in Updates; a newer beta is listed either way.
Beta builds notify about newer betas and public releases that catch up. Nothing
installs or switches channels automatically.

Choose **Update now**. If a beta needs a code you have not saved, choose **Enter
code and update**, or **Install for browsing**. Your current version will keep
working. Codes and older receipts survive updates and rollback. Downloading
continues if you leave the screen or Plex closes; activation waits for **Restart
now**. **Later** leaves the current version active. If an update fails, the reason
is shown under **Try again**. If startup fails, the previous selection is restored.

An ordinary Downloader run can refresh `misterzine-plex-downloads/package.zip`;
it cannot activate that package. Rebooting the MiSTer does not install a downloaded
update either; only **Restart now** does. The selected channel is registered in
`downloader_misterzine_plex.ini`. Installation data stays in
`/media/fat/misterzine-plex`.

Each installed release keeps its own folder. Once an update has started, Plex keeps
the new release and the previous one and removes older release folders.

**MisterZine-Plex-Rollback** selects the previous installed release without opening
Plex. Return to MiSTer Menu before using it. **MisterZine-Plex-Uninstall** works
offline and removes Plex binaries, entries, staging files and its database
registration. The default keeps sign-in, preferences, artwork and acquired codes.
Removing all Plex data requires typing **REMOVE**. Downloader and unrelated files
are preserved. A manually extracted `misterzine-plex-beta` ZIP folder can be
removed separately after installation.

If Zaparoo is installed, Plex also appears under **Other** in Zaparoo. The installer
keeps its own entry, `zaparoo/launchers/misterzine-plex.toml`, pointed at the
selected release and removes it on uninstall. Nothing needs adding to Zaparoo's
`config.toml`.

Each release also checks its own entries at boot and once an update to it has
finished: the main-menu entry, the Scripts entries and the Zaparoo entry. An in-app
update is installed by the previous release's code, so this is what brings them up
to date, and it adds the Zaparoo entry at the next boot when Zaparoo is installed
after Plex. Nothing is written when they are already right, and a Zaparoo reload
that did not happen is retried at the next check. The boot hook in
`linux/user-startup.sh` is changed only by the installer and uninstaller. The last
check and Zaparoo reload are recorded in `maintenance.json` and appear in
diagnostics reports, with the Zaparoo version and whether its `config.toml`
overrides the entry.

### Showcase captures

Options ends with the app version and build information. Select Version and
press OK three times in quick succession (less than two seconds between presses)
to toggle Showcase Mode. A brief message confirms whether it is on or off.
Showcase Mode uses generic library names and hides library totals and numeric
library position counts. Titles, artwork, episode details and watched/progress
indicators remain visible. The account name is also omitted from Sign out.
The mode lasts until the app exits; repeat the shortcut to turn it off sooner.
After switching, Back returns to Home so cached menu images cannot expose old
labels. This is capture styling, not full account anonymization; server selection
and sign-in screens can still contain identifying information.

## Display setup


CRT output is intended primarily for NTSC 15 kHz CRT output at 480i. Component
and Y/C profiles enforce 480i. This is profile detection, not cable or display
detection: RGB-only CRT profiles need **Safe 480i** in the core OSD.

The core OSD has **Video output: App settings / Safe 480i**. Normally leave it
on App settings. HDMI 480p is selected in the app's Options and requires a fresh
two-second OK hold to keep the change. It reverts if you do not confirm.

**Options > Video geometry** fits video to a set that hides the picture's
edges (overscan) or draws it too wide or too narrow. It affects video only;
menus stay where they are. OK steps through the top, right, bottom and left
edges and then the aspect ratio. The d-pad moves the selected edge in or out:
line each edge up with the edge of the screen, leaving a tiny bit of
overscan. For the aspect ratio an arrow marks the square's top-right corner,
and the d-pad moves that corner: measure the square with a ruler and make it
as wide as it is tall. Back saves and leaves. Video keeps its shape inside
the edges, with black bars where its shape differs from the area's. Edges
move in by up to a sixth of the screen, and the width by up to 15% either
way. Bringing the top or bottom edge in scales 480 lines into fewer, which
softens the picture slightly. One calibration serves every video output.

**Options > Video crop** sets how much of a picture that does not match the
screen is cut away. **Off** shows all of it, with black bars. **14:9** cuts the
sides of anything wider than 14:9, the compromise broadcasters used for
widescreen on 4:3 sets: thin bars remain and little is lost. **Fill** cuts
whatever overhangs the screen (or the area set under Video geometry), so there
are no bars: a 16:9 picture loses a quarter of its width, which also removes
the side bars of 4:3 shows stored in 16:9 files. A picture narrower than the
screen loses its top and bottom instead. Pictures within 1% of the target
shape are left whole. The crop is enlarged from the frame Plex sends, so it
is slightly softer, and a crop can cut the ends of long subtitle lines, which
Plex draws across the full width. Each playback starts with this setting;
**More > Crop** in the playback controls changes it for that playback,
including the episodes that follow it, and the change shows at once.

For HDMI scaling, aspect and variable refresh rate settings, see [HDMI setup](HDMI.md).
PAL is not yet supported. RGB-only CRTs are not detected automatically.

## MisterZine Plex Core - Patreon beta access

Official beta builds let anyone link Plex, browse libraries, search, change
settings and use watched-state controls. Starting or resuming a movie or episode
requires the member code for that release. Browsing theme music remains available.
Public and normal development builds play without a code. The FPGA core and
separate playback tools do not check Patreon access.

### Unlocking a beta

Find the exact version shown in the app's drawer or Options, then find its
members-only Patreon release post. The post supplies a six-digit code.

Press Play or Resume to open the early-access code screen, or select **Beta access** on
the menu's Patreon page. Left/right selects a digit; up/down changes it. Hold up/down to repeat.
Digit changes take effect immediately, with a short rolling animation. A keyboard can type the
six digits directly, including leading zeros. Press OK to unlock or Back to cancel.
Keyboard Backspace edits and Escape cancels. The Patreon address is displayed
on the code screen, the Patreon page and in Options. An incorrect code stays visible for
correction. Successful entry continues the selected playback automatically;
unlocking from the Patreon page simply returns to it.

Access is saved with the installation, separately from the Plex account. Restarts,
sign-out, reinstallations that preserve settings and updates using the same access
batch keep working. A release using a new batch requires its new code. Previously
unlocked releases still work after rollback. Keep the installation's settings and
`beta-unlocks` directory when moving or backing up your installation.

The BETA badge stays visible after unlocking. Video playback has no beta watermark.

To clear saved access, select **Patreon → Beta access → Forget beta access** in the menu and
confirm. This removes all saved beta unlocks and legacy keys on the installation,
including access to older releases. Plex sign-in and settings are kept. Beta
playback requires unlocking again; legacy builds need their key restored.

### Older file-key builds

If your older release post supplies a patron key ZIP, extract it onto the SD
card root, preserving `misterzine-plex/beta-keys/<batch>.key`, then press Play.
Keep older keys for rollback. Numeric-code builds do not convert or delete them.

### Does access expire?

There is no automatic membership check, expiry or device binding. Cancellation
does not disable an acquired build. A later release may require a new code.
Existing component licenses and modification rights remain unchanged.
