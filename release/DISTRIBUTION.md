# Independent distribution

Plex owns `misterzine-plex` on the SD card, its own Scripts entries, main-menu
launcher and download staging directory. Application settings, calibration,
cached artwork and saved beta access live outside the versioned application
payload, so updates and rollback preserve them.

The database owns only `misterzine-plex-downloads/package.zip`. The package worker
verifies the selected catalogue hash before extracting an immutable release.
Only controlled restart changes `active.json`; the running manager holds its
own lock until the app exits. Maintenance helpers are snapshotted for recovery.
An interrupted activation restores its saved selection on the next ordinary run.

The official Downloader bootstrap is pinned by both source revision and SHA-256
in `update_service.py`. HTTPS certificate validation remains enabled. Existing
Downloader launchers and binaries are preferred. A private invocation config
limits the operation to `misterzine_plex`, disables Linux updates/reboots and
overrides global filters without rewriting the user's configuration.

## Package inputs

The runtime payload is `plexcrt` (the Go application), `jfplay` (the ARM
playback worker), a static ARM `ffmpeg` and `PlexH264.rbf` (the H.264 decoder
core). FFmpeg is bundled; the installer downloads nothing else. Fonts and UI
assets are embedded in the application. HPS tools and static libraries are
build inputs rather than runtime dependencies.

The core in `third_party/MiSTer_h264_decoder` is this project's own fork and
follows only this project's rules. Upstream changes are never merged
automatically; a wanted fix is cherry-picked and reviewed like any other change.
Before the build that will ship, set `CORE_VERSION` in its `h264/emu.sv` to
`plex-` plus the app version it first ships in, and commit it. Then build with
`USE_DOCKER=1 ./build_release.sh --compile --release` from that clean commit,
which writes `releases/PlexH264_plex-<version>_<date>_<time>.rbf` and its `.json`
manifest. The packager refuses a core that is marginal, failed timing, was
built from a dirty tree, or carries a version without the `plex-` prefix. Keep
the generated manifest unchanged; an upstream checked-in RBF is not a
substitute for the qualified image. An app-only release reuses the last
packaged core and its manifest.

Each package is published with its corresponding source,
`MisterZine-Plex-Core-Source-<id>.zip`, made by `release/build_source.py` from a
clean commit: the tracked source, the qualified core snapshot with its fitter
seed and `build_id.v`, and `dependency-sources.zip` (the FFmpeg, OpenSSL, C
library and compiler runtime source and relink materials). The package manifest
records the source archive's name, size and hash, and the catalogue entry links
it. Exclude account files, caches, logs, raw codes, receipts, local paths and
Git history from distributable archives.

## Prepare a release

1. Build `jfplay` and the static `ffmpeg` with `toolchain/build_hps.sh`,
   `toolchain/build_ffmpeg.sh` and `make -C arm jfplay`, and the core as above,
   following `docs/BUILD.md`.
2. Build the app with `beta_release.py build`, explicitly selecting public or beta,
   version and release ID. For beta, select an existing private batch or manually
   create a new one as described in [beta release preparation](../docs/BETA_RELEASES.md). No automatic rotation occurs.
3. Build the corresponding source with `build_source.py --out --core-tree
   --dependencies --rbf-manifest`.
4. Run `build_package.py` with the same ID and version, the worker, FFmpeg, core,
   core manifest and source archive. Its build stamp must match the binary hash.
   The package allowlist excludes keys, raw codes and receipts. It writes
   `MisterZine-Plex-Core-<id>.zip`, its `.sha256` and a copy of the source
   archive under its published name.
5. Write user-facing release notes, then prepare distribution assets:

```sh
python3 release/publish.py --package "$PACKAGE" --tag "$TAG" --notes "$NOTES"
```

This is local preparation only. The source archive is taken from beside the
package unless `--source-archive` names it. `release/dist/distribution` contains standalone
installers, uninstall entry, catalogue and selected-channel database. Latest
scripts are named `MisterZine-Plex-Install-Public.sh` and
`MisterZine-Plex-Install-Beta.sh`, for published channels only. The
`MisterZine-Plex-Install-<version>.sh` asset embeds the exact release metadata and
uses the release's immutable `release-db.json.zip`; it never silently follows
the latest catalogue. All three proceed without interactive confirmation.
For previewing
both channels, pass `--previous` with an existing catalogue. Beta catalogue entries
contain only batch and verifier. Never put a real code in release notes or arguments.

## Publish separately

Publishing requires Git, authenticated GitHub CLI, and an existing reviewed source
tag in `matijaerceg/misterzine-plex-core`. Add `--publish` to the preparation command
only when the release is approved. The automation verifies the ZIP and its source
archive, fetches the current distribution branch, preserves the other channel,
uploads a draft release with the package and source archive, publishes its
assets, then pushes the new catalogue/database. It uses no force push.

The `distribution` branch serves `catalogue.json`, `public.json.zip`,
`beta.json.zip` and latest-channel installer scripts. Attach the versioned script
to a version-specific post; link general installation instructions to the latest
channel script or GitHub release assets. Missing channels have no catalogue entry. Do not create placeholder
public releases. Use unique release IDs and immutable package/tag assets. A changed
package at a published URL is rejected by clients; publish a new release instead.

If publication stops after uploading, inspect the existing draft/published release
and branch before retrying. Do not overwrite an existing release to bypass a hash
failure. If the final push loses a race, regenerate against the latest catalogue
and publish the prepared distribution commit after review.

Each version's Patreon post repeats the code for its selected batch. The publisher
does not generate private codes, choose versions, or post to Patreon.

## Validation

Run Go tests and ARM vet/build from `CONTRIBUTING.md`, release Python tests and the
public-content scan. For real Downloader integration, supply the official archive:

```sh
python3 tools/check_downloader_integration.py "$DOWNLOADER_ARCHIVE"
```

This test needs permission to create a temporary directory under `/media`, because
Downloader rejects other card roots. Only HTTP transport is replaced with synthetic
bytes. Database parsing, filtering, file verification, local store and repair are
real. Nothing touches the actual card or publishes a release.

Before advertising hardware support, test installation, repair, preparation,
restart, failed-start recovery, rollback (including back to a release before the
H.264 core) and both uninstall choices on an isolated card tree. Play direct
streams and transcodes, and inspect the core's Output Modes on the connected CRT
and HDMI displays. Repeat on DE10 hardware; an ARM cross-build alone does not
verify that target.
