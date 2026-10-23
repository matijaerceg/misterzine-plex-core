# Reference

Detailed behavior and display settings. For everyday help, see the
[help page](../release/README.md).

## Using Plex

### Household profiles

Accounts without Plex Home open their libraries without a user-selection screen.
A Plex Home with one unprotected profile also continues automatically. Homes
with multiple profiles show **Who's watching?**; selecting a protected profile
requires its Plex PIN, including the primary account. Use Up/Down to choose a
digit and OK to enter it, or type the digits on a keyboard. Back erases a digit
or returns to the profile list when the entry is empty. PINs are not saved.

**Options > Switch user** changes the active household profile without linking
the device again. Libraries, playback and watch progress use that profile's
Plex access. Switching clears local recent searches and hidden-library choices
when the profile changes.

**Options > Sign in automatically** remembers the last selected profile on this
installation, skipping the picker and its PIN on startup. It is off by default;
only a signed-in full account can change it. Managed profiles see its current
On/Off value greyed out; selecting the row explains how to change it.
A managed profile can be remembered after a full account enables the setting.
Explicitly switching to a protected profile still requires its PIN. Household
options are hidden for ordinary accounts without Plex Home.

Checking profiles and switching users requires a connection to Plex. A failed
lookup or rejected PIN leaves the libraries locked rather than opening the
primary account. Automatic sign-in uses the saved server connection at startup.

### Controls

- D-pad moves the selection; OK opens it; Back goes back. On Home, Back or Left
  at the start of a row opens the menu. L/R move a screen of posters along a
  Home row.
- Home shows **Continue Watching** and a **Recently Added** row for each
  library, ending in a **See all** tile that opens the library newest first. A
  library hidden in Options has no row.
- The menu lists Home, Search, the movie and TV libraries, Options, Exit to
  MiSTer menu and Patreon. A long list of libraries scrolls, and the menu opens
  on the library visited last. Patreon says what a MisterZine code unlocks for
  good and holds **Beta access**; once a code has been entered, or on an
  unlocked beta, it thanks you instead. Its supporters row lists the Patreon
  supporters, current then past. The list is the one the MisterZine app shows:
  it is fetched from `misterzine.fyi` with each release check and kept in the
  cache folder for when the MiSTer is offline.
- A library opens as a wall of posters, four across (six with the 16:9
  Display Shape), with tabs above: **A to Z**, **Added**, **Released**,
  **Continue** (the library's Continue Watching), **Folders** and, once the
  server has listed at least one, **Collections**. Up from the first row, or
  Back from anywhere in the grid, selects the tabs; Left and Right switch them;
  Back again leaves the library. Down past the last row rounds to the first,
  and Up on the tabs to the last (a held run stops at the end instead). A
  collection has no tabs, so Up from its first row rounds too. L/R jump a letter in A to Z and a screen in
  the other views. The scrollbar on the right shows the letter, or the
  position and the total.
- **Folders** lists the library's folders on disk as the server lists them. OK
  on a folder shows its subfolders and files under the folder's name; a file
  opens as from any other view; Back comes out one folder at a time. It is
  meant for libraries of unmatched files (Plex's "Other Videos", such as music
  videos kept in artist folders), where the other views show one flat list.
- **Collections** lists the library's collections. OK on a collection shows its
  items, in the collection's order and through the 4:3 filter like any view;
  one Back returns to it on the Collections tab.
- With a MisterZine code that covers it and **Show beta features** on,
  Options has **Random library order**, marked BETA, on by default. Movie
  and TV libraries then have a **Random** tab after Released: the whole
  library in a random order, shown once all of it has been listed. The order
  and the selected poster stay through an item's page and back and through the
  other tabs; a title added on the server meanwhile slots in without changing
  the order of the rest. Leaving the library (back to Home or the menu)
  shuffles it again and forgets the place: a library left on Random opens on
  it again, in a new order from the first poster. On the tabs, OK on Random
  shuffles again and starts at the first poster; Down goes to the posters.
  With the setting off, without the code or with beta features hidden there
  is no Random tab, and the library opens on A to Z.
- **Search** has an on-screen keyboard, and a USB keyboard types into it. It
  lists the movies and shows that match, through the 4:3 filter and without
  hidden libraries. Right from the keyboard's last column, or **Results**,
  moves to the list; Left returns. With nothing typed the list holds the
  recent searches. Back clears the query, then leaves.
- A movie's page holds **Play** (or **Resume from** and **Play from the
  start**), **Mark watched** or **Mark unwatched**, **Audio** when there is
  more than one track, and **Subtitles** when there are any. When the summary
  is cut short, Up from the first action selects it and OK shows it in full.
- A show with one season opens straight on its episodes. Otherwise its page
  lists the seasons; Down or OK opens one. An episode's actions are those of a
  movie page, then **Go to show** when the page was opened without the row of
  seasons (Home, search, Continue Watching, a show with one season), and
  **Shuffle show**.
- A movie or episode in Continue Watching has **Remove from Continue Watching**
  as the last action on its page. Plex keeps the resume point, and playing it
  again puts it back in the row. Servers without a Continue Watching list
  don't show the action.
- A show's row of seasons ends with a **Shuffle** tile; **Shuffle show** does
  the same. Both play every episode of the show, watched or not and specials
  included, in a random order and each from its start. While the episodes are
  listed the start bar runs, and Back gives up. A shuffle runs on into the next
  episode even with autoplay off; Prev and Next move along the shuffled order.
- Back on a season page after playback selects the episode after the last one
  finished (played to the end or stopped in its last 30 seconds). An episode
  stopped earlier stays selected. Nothing starts playing.
- After three minutes without a press in the menus or on a paused video, the
  screen dims to a quarter of its brightness. The next press only brings it
  back; it does not also act. The sign-in code never dims.
- To leave the app, choose Exit to MiSTer menu in the menu (before sign-in, at
  the foot of Options). Loading another core from MiSTer's OSD works too.

### Playback controls

- During playback, OK opens the controls: **-10**, **Pause**, **+10**,
  **Prev**, **Next**, **Audio**, **Subs** and **More**. Left and Right select
  a button and skip the ones with nothing to do (Prev on the first episode,
  Audio with one track); OK presses it. The controls hide after four seconds
  unless paused. Down closes them.
- On a USB keyboard, Space or P pauses and resumes playback in one press; a
  pause brings up the controls showing **Play**. A USB remote whose play key
  MiSTer does not pass through can be remapped to Space in MiSTer's keyboard
  mapping.
- Back steps out one level at a time. The first Back clears what is on screen:
  a list, the scrubber, the seek strip, a skip button or the controls. With
  nothing on screen, the next Back stops playback. A second Back within half
  a second of the one that cleared the screen is ignored, so a double press
  does not stop the video by surprise; what leaves the screen by itself, such
  as the controls hiding, leaves the next Back free to stop.
- Up opens the scrubber. A tap of Left or Right moves the dot ten seconds; a
  hold runs it, speeding up after half a second. The seek goes on its own
  400 ms after the last release; OK sends it at once. Down returns to the
  buttons and keeps the new position; Back returns without it.
- With the controls hidden, Left and Right show a strip with the title, the
  progress bar and the times, and work the same way: taps and holds add up into
  one seek. The last picture stays on screen until the new position plays.
- When the server has made preview thumbnails for the video (Plex's "Generate
  video preview thumbnails" library setting), a hold of Left or Right shows a
  small frame of the film at the dot's place above the scrubber or the strip.
  The thumbnails download in the background once playback starts, so a hold
  right after the start may show none for a moment. While the hold runs,
  playback pauses; it resumes when the seek is sent, or when Back drops the
  scrub. A tap never pauses, and a video paused beforehand stays paused.
- The progress bar shows how far is downloaded in pale lilac (cyan in the VCR
  controls). A seek inside that range can reuse what is already downloaded.
- **Audio** and **Subs** open a list of tracks. A change is kept for the movie
  or show. Another audio track, or a subtitle track the server burns in,
  restarts the stream at the same position; a subtitle track the app draws
  changes without a restart (see Subtitles).
- **More** is one list with no pages behind it: Left and Right change the
  value of the row under the cursor in place, shown by the small arrows
  either side of it, and stop at the first and last choice. It holds
  **Crop**, for any picture, **Downmix boost** and **Subtitle size** (see
  Display setup, Sound and Subtitles), each applied as soon as it changes,
  and after them:
  - **Autoplay next** (episodes): On or Off by Left, Right or OK; the Options
    setting, saved at once, and the end of this playback follows it.
  - **Video bitrate**: Left and Right choose a step of the Options ladder and
    OK saves it. A transcode starts over at the same position with the new
    cap; a direct play (so marked) plays on and uses it next time.
  - **Playback info**: read only and updated every second: direct play or
    transcode, picture size and frame rate, bitrate, sound and downmix,
    subtitle track, position, and the decoder's late frames and errors. OK
    or Back goes back to More.
- Over an intro or credits the server has found, **Skip intro** or **Skip
  credits** shows at the lower right for 20 seconds once playback reaches them, also after a
  resume or a seek into them. OK skips to their end; Back dismisses the
  button. Options can turn the buttons off.
- When an episode plays to its end, the next one in the season is shown for
  ten seconds and then plays. OK plays it at once; Back stops. Options can
  turn this off.

### Options

Options lists, in groups:

- **Only show 4:3 media**: hides anything wider than 4:3 from the Home rows,
  search and every library view. Movies and episodes are judged by their own
  picture; a show by its first episode. Each TV library is read once for that,
  the first time the filter needs it, and the answers are kept in the cache
  folder.
- **Autoplay next episode**: the countdown into the next episode.
- **Skip intro and credits buttons**.
- **Playback UI theme**: the look of the playback controls. **Standard**;
  **Icons**, Standard with the buttons drawn as small icons instead of
  words (back and forward 10 seconds as double arrows over a 10, pause bars
  or a play triangle, previous and next as arrows against a bar, a speaker
  for Audio, a caption box for Subs, three dots for More), in the same
  places, colours and order; or **VCR**, an old deck's on-screen display:
  bright green and white block capitals in an on-screen display chip's
  eight pure colours on a blue band, the progress as a row of blocks with an
  upright line for the scrubber's playhead, and the lines of the controls
  wavering sideways by a pixel, as a tape's picture did. **VCR, no band**
  leaves the band out, the text straight over the picture as on a deck. In
  both VCR looks the three dots that show while the picture is held up are a
  tape whose reels turn. The controls work the same in every look; the
  picture and the subtitles do not waver. The looks other than Standard are
  a supporter extra: the row carries the purple star, and without a code
  covering it the row shows **Unlock forever** and OK opens the code entry.
  A look chosen earlier plays as Standard until a code covers it, and comes
  back once one does.
- **Video bitrate** (see Sound and playback quality).
- **Show** and a library's name, one row per library: off leaves it out of
  Home, the menu and search. Shown once the libraries have loaded.
- **Video calibration** and **Video crop** (see Display setup).
- Rows about your MiSTer INI, when it has a setting known to cause trouble:
  **HDMI refresh** (HDMI held at a fixed rate the core's output does not
  match), **HDMI sound** (DVI mode, no sound over HDMI) and **INI section** (a
  later `[MiSTer]` section overriding the app's `[MisterZine Plex Core]`
  section). Select one for the file to change and what to add. See
  [HDMI setup](HDMI.md#settings-options-warn-about).
- **Surround downmix boost**, **Subtitle size** and **Subtitle background**
  (see Subtitles), **Theme
  music** (a show's theme song on its pages) and **Navigation sounds** (no
  sound plays with the H.264 core).
- **Show beta features**, and the beta features a MisterZine code covers.
- **Switch user** and **Sign in automatically** for a Plex Home (see
  Household profiles), **Choose server again**, and **Sign out**, with the
  account's name.
- **Updates**, which says when an update is downloading, ready or available,
  or when one failed.
- **Send a report**.
- **Exit to MiSTer menu** and **Patreon**, before sign-in only.
- **Version**. The foot of the screen shows the build.

Up and Down wrap between the first and last rows, skipping group gaps. OK,
Left or Right turns a setting on or off; a setting with more choices (playback
controls, bitrate, crop, downmix boost, subtitle size) changes with Left and
Right only, shown by the arrows either side of its value when it is selected.
A scrollbar on the right shows where the list is.

An update waiting under Options is marked with a purple UPDATE mark at the top
of Home and a dot in the menu.

### Connecting after power-on

Opened right after the MiSTer is switched on, Plex can start before the
network is up. On a MiSTer without a clock chip it can also start before the
clock has been set from the internet, and secure connections to the server
fail until then. For its first minute Plex keeps trying every two seconds and
shows **Connecting** with what it is waiting for. After that it shows the error
and tries again every 30 seconds; OK tries at once.

### Server connection

On sign-in and when choosing a server, Plex tries every connection plex.tv
lists for the server at once and keeps the best that answers: the home
network first, then the internet, then Plex's relay. At each it uses a secure
(HTTPS) connection when one works, and otherwise a plain HTTP connection where
the server allows it. The relay is secure only. The server's **Secure
connections** setting (Settings > Network) decides: **Required** refuses plain
connections, **Preferred** accepts them.

### Release notes on start

A release can carry a short note. It appears once, over Home, the first time
Home has connected after the app starts, and stays until OK is held for one
second (a bar under the hint fills while it is held). Once dismissed, that
note is remembered in the settings file and does not show again.

### Subtitles and audio tracks

The audio and subtitle tracks chosen on a page or during playback are kept for
that movie, or for the whole show, and used for every play. Until you choose,
the server's selection is used.

Text subtitle tracks (SRT, ASS/SSA, WebVTT and the other text formats the
server can hand over as a file) are drawn by the app over the picture, as
white type with a thin dark outline
(or on a translucent box, see below), centred along the bottom of the screen. The
video is sent without them, so a film with text subtitles can still play as
stored, and turning text subtitles on or off, choosing another text track or
changing their size does not restart the video. Only the words are shown:
styling, positioning and effects in ASS/SSA tracks are left out, and accented
letters lose their accents. Long lines wrap; up to six lines show at a time.
Subtitles step aside while the controls, a list, the seek strip or a skip
button are on screen.

A track embedded in the file can take the server a while to hand over the
first time. The video plays meanwhile, without subtitles until they arrive.
The app waits up to 30 seconds for an answer, then gives up and shows none;
turning subtitles off and on again asks once more.

**Options > Subtitle size** chooses Normal, Large (150%) or Extra large (200%)
and is saved for future playback. During playback, Left and Right on
**More > Subtitle size** change the same setting at once.

**Options > Subtitle background**, off by default, puts a translucent box
behind each line in place of the outline. A change shows on the next cue drawn,
including one already on screen.

Picture subtitles (PGS, VobSub, DVB) are burned into the picture by the Plex
server, which therefore transcodes the video. A text track in a script the
app's fonts lack (Cyrillic, Greek, Arabic, Chinese, Japanese, Korean and
others) is handed to the server the same way. Choosing one, or changing from
one, restarts the stream at the same position; the server can take a while to
start the new transcode. The server scales the subtitles it burns in to the
Subtitle size; the result depends on the server and the subtitle format, and
a crop can cut the ends of their long lines. Subtitles the app draws are never
cut by a crop. Lettering already embedded in the original video cannot be
resized.

### Sound and playback quality

Files the decoder can certainly play are streamed as stored: H.264 High or
Main, 8-bit, level 4.1 or lower, at most 1280x720, at most 30 frames per
second above 854 pixels wide (60 at or below), and at most 6 Mbit/s above 854
pixels wide (8 Mbit/s at or below), and no more than the **Video bitrate**
setting. Everything else, and anything with subtitles the server burns in (see
Subtitles), is transcoded by the Plex server to H.264 within the same limits.
At the 3 Mbps step and above, 50 and 60 fps video is transcoded at half its
frame rate; at the lower steps it keeps its rate. If a direct stream
turns out to be unplayable or falls behind, playback switches once to a
transcode at the same position. See [playback details](PLAYBACK.md).

**Video bitrate** caps the video Plex sends: 0.4, 1, 2, 3, 4, 6 or 8 Mbps
(the default and the most the decoder handles). The steps below 3 Mbps are for
a slow or unreliable link to the server, such as weak Wi-Fi. At those steps a
transcode is also made smaller, so the bits go further: 854x480 at 1 and
2 Mbps, 640x360 at 0.4 Mbps. That costs little on a 480i or 576i screen. A file
whose video is above the chosen bitrate is never streamed as stored; it is
transcoded to that bitrate. Start low on Wi-Fi and raise it while playback
stays smooth. The first run of a release with the decoder core sets it to the top value;
change it afterwards and it stays.

Sound is folded to stereo: on the MiSTer for a file streamed as stored, by the
server in a transcode. A plain fold of a surround track comes out noticeably
quieter than a stereo track, so **Surround downmix boost** raises the level of
surround sources: Off, Small or Large (the default). Stereo tracks are passed
through unchanged. The MiSTer applies the boost in both cases, so Left and
Right on **More > Downmix boost** in the playback controls change it at once, without
restarting the video.

Theme music and navigation sounds can be turned off in Options.

### Update, rollback and remove

Open **Options > Updates** to see whether a newer version is available, and its
download size. The screen checks when it opens. Checks also run in the
background at startup and every six hours while browsing; failed background
checks stay quiet and are tried again after five minutes. An update found by
an earlier check is still offered while the network is down.

Updates offers only versions newer than the one running. It never reinstalls
the current version or goes back to an older one; **MisterZine-Plex-Rollback**
does that. Public builds notify about newer public releases. Beta
notifications are off by default but can be switched on in Updates; a newer
beta is listed either way. Beta builds notify about newer betas and public
releases that catch up. Nothing installs or switches channels automatically.

Choose **Update now**. Downloading continues if you leave the screen or Plex
closes; installing waits for **Restart now**. **Later** leaves the current
version active. If an update fails, the reason is shown under **Try again**,
and the current version keeps working. If the new version does not start, the
previous one is put back. Sign-in, settings, calibration, beta codes and older
receipts are kept through updates and rollback.

Downloads go through MiSTer Downloader into `misterzine-plex-downloads` on the
SD card, and fall back to fetching the release file directly when that fails.
An ordinary Downloader or Update All run can refresh that download; it cannot
install it. Rebooting the MiSTer does not install a downloaded update either;
only **Restart now** does. The selected channel is registered with Downloader
in `downloader_misterzine_plex.ini`. The app's own files live in
`/media/fat/misterzine-plex`.

Each installed release keeps its own folder, with its own copy of the H.264
core. Once an update has started, Plex keeps the new release and the previous
one and removes older release folders.

These entries are in the MiSTer **Scripts** menu once Plex is installed.
Return to MiSTer Menu before running them.

- **MisterZine-Plex-Rollback** selects the previous installed release without
  opening Plex.
- **MisterZine-Plex-Uninstall** works offline. Its default removes the Plex
  programs, its menu, Scripts and Zaparoo entries, its boot entry, downloads
  and Downloader registration, and keeps sign-in, preferences, artwork and
  acquired codes. Removing all Plex data requires typing **REMOVE**.
  Downloader and unrelated files are kept. A manually extracted
  `misterzine-plex-beta` ZIP folder can be removed separately after
  installation.
- **MisterZine-Plex-Diagnostics** writes the same report as **Send a report**
  (below), for when the app does not start.

The installer adds **MisterZine Plex** to the MiSTer main menu and a line
to `linux/user-startup.sh` that starts the small helper behind that entry at
boot. Releases before the H.264 core listed the entry as **MisterZine Plex
Core**; installing or updating replaces that entry with the new one. The core
itself is still called MisterZine Plex Core, so its `MiSTer.ini` section keeps
that name. If Zaparoo is installed, Plex also appears under **Other** in
Zaparoo, through its own file `zaparoo/launchers/misterzine-plex.toml`, pointed
at the selected release and removed on uninstall. Nothing needs adding to Zaparoo's
`config.toml`.

Plex also supplies its **MisterZine Plex Core** logotype and a shorter
**MisterZine Plex** display name for Zaparoo Frontend. Existing pinned Plex
tiles receive the artwork in place; the installer does not pin Plex, rearrange
the Hub, enable Frontend, or change `MiSTer.ini`. Restart Frontend to see new
artwork. Personal display names, tile icons and existing system artwork take
priority. The same check runs at boot, including when Zaparoo was installed
after Plex or Plex was pinned later.

Artwork ownership is tracked in `misterzine-plex/zaparoo-art.json`. Uninstall
and rollback to a release without this support remove only unchanged defaults
installed by Plex, preserving later user edits. Custom artwork directories on
the same card are supported. Directories outside the card, symbolic links, and
Frontend configurations using syntax beyond its usual generated format are
left alone; the reason is recorded as `zaparoo_art` in `maintenance.json`.

Each release also checks its own entries at boot and once an update to it has
finished: the main-menu entry, the Scripts entries and the Zaparoo entry. An
in-app update is installed by the previous release's code, so this is what
brings them up to date, and it adds the Zaparoo entry at the next boot when
Zaparoo is installed after Plex. Nothing is written when they are already
right, and a Zaparoo reload that did not happen is retried at the next check.
The boot hook in `linux/user-startup.sh` is changed only by the installer and
uninstaller. The last check and Zaparoo reload are recorded in
`maintenance.json` and appear in diagnostics reports, with the Zaparoo version
and whether its `config.toml` overrides the entry.

### Send a report

**Options > Send a report** gathers what helps diagnose a problem: the app,
launcher and player logs, the reasons for connection and update failures, the
video settings read from the MiSTer INI, which MiSTer main is running and the
framebuffer state. It can name media titles and playback details. Sign-in
tokens, the server address and account files are never included, and beta
access codes are redacted. OK sends it and shows a code to post where you
asked for help; the report is deleted after 30 days. If it cannot be sent, a
copy saved on the card is named instead, which you can send.
**MisterZine-Plex-Diagnostics** writes the same report.

### Showcase captures

Options ends with the app version and build information. Select **Version**
and press OK three times in quick succession (less than two seconds between
presses) to toggle Showcase Mode. A brief message confirms whether it is on or
off. Showcase Mode uses generic library names and hides library totals and
position counts. Titles, artwork, episode details and watched and progress
marks remain visible. The account name is also left off Sign out. The mode
lasts until the app exits; repeat the shortcut to turn it off sooner. After
switching, Back returns to Home so cached menu images cannot show old labels.
This is capture styling, not full account anonymization: server selection and
sign-in screens can still show identifying information.

## Display setup

Video is decoded by the H.264 core, which also draws the app's screens. The
output is chosen in the core's OSD (the MiSTer menu button while the app
runs), not in the app's Options. The core's own manual describes every option:
[core settings](../third_party/MiSTer_h264_decoder/site/content/using/settings.md).
In short:

- **Output Mode**: **480i60** (the default) and **576i50** are interlaced
  15 kHz signals for standard-definition CRTs; **480p60** and **576p50** are
  progressive, for 31 kHz displays, scalers and HDMI; **Native HDMI** plays
  video at its own size and leaves scaling to MiSTer's HDMI scaler. Use the
  576-line modes only with a display that accepts PAL.
- **Refresh Rate Match**: **50/60** lets playback switch between the 50 Hz and
  60 Hz families to suit the video, and returns to the chosen Output Mode when
  playback ends. Enable it only if your display accepts both.
- **240p Playback**: on the interlaced modes, shows video as 240p (288p in the
  PAL family) while menus stay interlaced.
- **Play 24fps at 25fps**: on the fixed 576-line modes with Refresh Rate Match
  Off, plays 23.976 and 24 fps films at 25 fps, the traditional PAL speed-up.
  Films run about 4% faster and the sound is pitched up.
- **Display Shape**: 4:3 or 16:9, shared by the menus, fitted video and the
  overlay. The app's screens widen for 16:9. In Native HDMI a playing video
  takes the HDMI mode's own shape.
- **De-flicker**: on interlaced output, softens thin horizontal lines in
  video and in the app's screens so they flicker less.

The core saves these settings like any MiSTer core. Restart playback after
changing a setting that affects playback speed. There is no 48 Hz mode.

**Options > Video calibration** shows adjustable screen edges and a square
with a circle in it. OK selects the next edge or the square's corner, the
D-pad moves it, and Back saves and leaves. The saved edges and width
correction also move video playback on a core that supports it (interface 1.2
or later, which the core shipped with the app does); menus are unaffected. On
an older H.264 core the screen is labelled **Video calibration (preview
only)**, and the saved values do not affect playback. Geometry applies to
fitted 480- and 576-line output, not to Native HDMI.

**Options > Video crop** sets how much of a picture that does not match the
screen is cut away. **Off** shows all of it, with black bars. **14:9** cuts the
sides of anything wider than 14:9, the compromise broadcasters used for
widescreen on 4:3 sets: thin bars remain and little is lost. **Fill** cuts
whatever overhangs the screen, so there are no bars: a 16:9 picture on a 4:3
screen loses a quarter of its width. A crop can cut the ends of long subtitle
lines burned in by the server, but not subtitles the app draws. Each playback
starts with this setting; Left and Right on **More > Crop** in the playback
controls change it for that playback, including the episodes that follow it, and the change shows
at once.

For HDMI scaling, MiSTer INI sections and refresh rates, see
[HDMI setup](HDMI.md).

## MisterZine Plex Core - Patreon beta access

Official beta builds let anyone link Plex, browse libraries, search, change
settings and use watched-state controls. Starting or resuming a movie or episode
requires the member code for that release. Browsing theme music remains available.
Public and normal development builds play without a code. The FPGA core and
separate playback tools do not check Patreon access. See
[beta access](../release/BETA_ACCESS.md).

### Unlocking a beta

Find the exact version shown in the app's menu or Options, then find its
members-only Patreon release post. The post supplies a six-digit code.

Press Play or Resume to open the early-access code screen, or select **Beta
access** on the menu's Patreon page. Left/right selects a digit; up/down
changes it. Hold up/down to repeat. Digit changes take effect immediately, with
a short rolling animation. A keyboard can type the six digits directly,
including leading zeros. Press OK to unlock or Back to cancel. Keyboard
Backspace edits and Escape cancels. The Patreon address is displayed on the
code screen, the Patreon page and in Options. An incorrect code stays visible
for correction. Successful entry continues the selected playback
automatically; unlocking from the Patreon page simply returns to it.

Access is saved with the installation, separately from the Plex account.
Restarts, sign-out, reinstallations that preserve settings and updates using
the same access batch keep working. A release using a new batch requires its
new code. Previously unlocked releases still work after rollback. Keep the
installation's settings and `beta-unlocks` directory when moving or backing up
your installation.

The BETA badge stays visible after unlocking. Video playback has no beta watermark.

To clear saved access, select **Patreon > Beta access > Forget beta access** in
the menu and confirm. This removes all saved beta unlocks and legacy keys on
the installation, including access to older releases. Plex sign-in and
settings are kept. Beta playback requires unlocking again; legacy builds need
their key restored.

### Older file-key builds

If your older release post supplies a patron key ZIP, extract it onto the SD
card root, preserving `misterzine-plex/beta-keys/<batch>.key`, then press Play.
Keep older keys for rollback. Numeric-code builds do not convert or delete them.

### Does access expire?

There is no automatic membership check, expiry or device binding. Cancellation
does not disable an acquired build. A later release may require a new code.
Existing component licenses and modification rights remain unchanged.

The registry of issued MisterZine codes and the features they unlock (such as
Random library order and the screensavers) come from a separate private
repository; see [public
source and supporter builds](SUPPORTER_BUILDS.md).

Supporter builds add a **Home logo** row to Options, with the star. **Default**
draws the app's wordmark at the top left of Home, **MisterKun** draws
MiSTer-kun peeking from behind the Plex chevron in its place, and **Off** draws no
logo; the BETA and UPDATE marks then start where the wordmark did. The drawer
and the sign-in screen keep the wordmark. It needs a code covering September 2026;
without one, Home shows the wordmark whatever the row was set to. A logo hidden
with the earlier **Hide home logo** row reads as Off.
