# Independent distribution

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

## Prepare a release

1. Build the core and presenter from the matching source using `docs/BUILD.md`.
   Build the presenter with `build_presenter.py`: `build_package.py` refuses one
   that was not built from the current `arm/plexfb.c`.
2. Build the app with `beta_release.py build`, explicitly selecting public or beta,
   version and release ID. For beta, select an existing private batch or manually
   create a new one as described in [beta release preparation](../docs/BETA_RELEASES.md). No automatic rotation occurs.
3. Run `build_package.py` with the same ID and version. Its build stamp must match
   the binary hash. The package allowlist excludes keys, raw codes and receipts.
4. Write user-facing release notes, then prepare distribution assets:

```sh
python3 release/publish.py --package "$PACKAGE" --tag "$TAG" --notes "$NOTES"
```

This is local preparation only. `release/dist/distribution` contains a standalone
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
only when the release is approved. The automation verifies the ZIP, fetches the
current distribution branch, preserves the other channel, uploads a draft release,
publishes its assets, then pushes the new catalogue/database. It uses no force push.

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
restart, failed-start recovery, rollback and both uninstall choices on an isolated
card tree. Inspect CRT/HDMI output on the connected displays. Repeat on DE10 hardware;
an ARM cross-build alone does not verify that target.
