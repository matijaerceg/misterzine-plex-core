# Preparing beta releases

Maintainer instructions. For entering a member code, see
[beta access](../release/BETA_ACCESS.md).

## Creating releases

Generate a code once for a new access batch (the label below is an example):

```sh
python release/beta_release.py create-code --batch example-beta
```

The six-digit code is saved in ignored `release/private-beta/<batch>.code`.
The command prints its path, not its contents. Back up this private file securely;
never commit it or include it in the app ZIP. Read it privately when preparing the
members-only post. Generation refuses to overwrite an existing batch.

Build a beta application with an explicitly selected batch:

```sh
python release/beta_release.py build --channel beta --batch example-beta --version 0.2.0-beta.1 --id beta-example-1
```

Then, on Linux or inside WSL on Windows, build the playback worker and its
static FFmpeg ([build from source](BUILD.md)), the corresponding source, and
the package with the same version and ID:

```sh
bash toolchain/build_hps.sh && bash toolchain/build_ffmpeg.sh && make -C arm jfplay
python3 release/build_source.py --out "$SOURCE" --core-tree "$CORE_SNAPSHOT" \
    --dependencies "$DEPENDENCY_SOURCES" --rbf-manifest "$RBF.json"
python3 release/build_package.py --version 0.2.0-beta.1 --id beta-example-1 \
    --worker arm/jfplay --ffmpeg build/arm/ffmpeg --rbf "$RBF" --source-archive "$SOURCE"
```

`$RBF` is the qualified core, `PlexH264_plex-<version>_<date>_<time>.rbf` with
its `.json` manifest beside it, built with `USE_DOCKER=1 ./build_release.sh
--compile --release` from a clean commit of `third_party/MiSTer_h264_decoder`
after setting its `CORE_VERSION` to `plex-` plus the version; `$CORE_SNAPSHOT`
is the core directory that build ran in. An app-only release reuses the last
packaged core and its manifest ([distribution](../release/DISTRIBUTION.md)).

Use the same version and unique release ID in the app and package commands. The
package is refused unless the app's build stamp matches its binary, and the core
unless its manifest records a clean build that passed timing with a `plex-`
version. Match the version in the Patreon post title. Reuse the batch for as many releases as desired and repeat
its code in each post. To require a new code, generate and select a new batch.
Version changes alone do not rotate access. The binary embeds the code's SHA-256
verifier, batch and release channel; it does not embed the code itself.

Public builds explicitly omit the access requirement:

```sh
python release/beta_release.py build --channel public --version 0.2.0 --id public-0.2.0
```

Rebuild rather than renaming a beta ZIP. Check the app's `-version` output for its
release channel and batch before distributing. Invalid beta metadata blocks
playback while still allowing browsing.

## Legacy file-key releases

Existing file-key batches remain supported. Extract their patron key ZIP onto
the SD card root, preserving `misterzine-plex/beta-keys/<batch>.key`. Return to the
app and press Play. Keep older keys for rollbacks. The release tool retains
`create-key` and can build an existing file-key batch; a batch cannot contain both
a file key and a numeric code. Numeric builds do not convert or delete old keys.

## Verification and limitations

Test incorrect codes, leading zeros, saved access, failed storage writes, Play,
Resume, episode queues, updates, rollback and public builds. Verify CRT and HDMI
output in the core's Output Modes on MiSTer before release. Packaging uses an explicit file list that
excludes private codes, keys and saved unlock receipts.

This is an offline convenience gate. Shared codes can be passed on, a short code
can be recovered from its verifier, and modified applications can bypass the
check. There is no membership API, expiry or device binding. Cancellation does
not disable an acquired build. Existing component licenses and modification
rights remain unchanged.
