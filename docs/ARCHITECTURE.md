# Architecture and current limitations

The Go application runs on MiSTer's ARM processor. It authenticates with Plex,
browses libraries and draws into a shared DDR frame ring. The FPGA scans out the
image and provides controller status, a playback overlay, moving scrub/focus
sprites and an output brightness the app lowers when idle. The Python launcher manages transcoding and playback; FFmpeg decodes
into the C presenter, which synchronizes video and PCM audio with display timing.

Write-combined framebuffer memory is expensive to read. Rendering composes in
ordinary memory where necessary and writes frames sequentially. Artwork loads
asynchronously; text and images are cached. Playback controls use a FIFO and
status files. Account settings use atomic saves and a last-good backup.

The installer selects versioned releases, verifies payload hashes and keeps
settings/cache separate. Rollback selects the previous release; after a successful
update only the current and previous release folders are kept. Existing data
paths and legacy launcher migration are retained across the product rename.

Official beta apps check offline batch access before playback. Numeric-code builds
save unlock receipts separately from account settings; legacy file-key batches
remain supported. Explicit release-channel metadata controls beta branding.
Development/public builds are unlocked. This convenience check is separate from
the FPGA core and presenter and can be removed in modified application builds;
it is not a guarantee of exclusive access.

Primary output is NTSC 15 kHz 480i. Component/Y-C profiles enforce 480i; RGB-only
CRTs require Safe 480i in the OSD. HDMI 480p requires confirmation. PAL and HDMI
full-height scaling refinements remain incomplete. Sources of 45 fps and up
(50 and 60 fps video) are requested at half their frame rate, every other
frame, because the board cannot decode the full rate. Output always refreshes
at 59.94 Hz and never follows the video's frame rate, so 24 and 25 fps video is
shown with an uneven frame cadence and HDMI variable refresh rate adds nothing;
see [HDMI setup](HDMI.md#variable-refresh-rate-vrr-freesync). The artwork/theme cache
has no disk quota. Show transitions can miss
their target cadence; no universal 60 fps guarantee is made.
