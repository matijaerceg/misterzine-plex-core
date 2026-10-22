# Project instructions

This is the public source repository for MisterZine Plex Core. Keep session
handoffs, raw research, business strategy, approval history, device deployment
logs and personal preferences outside this repository. Use the local directory
specified by MISTERZINE_PRIVATE_NOTES for such notes; do not commit its location.
If unset, request a private location before writing internal notes.

Public docs describe current behavior and reproducible instructions. Retain
licenses and attribution. Do not put keys, account files, real media identifiers,
private machine paths or device addresses into source, tests or documentation.
Use parameters and synthetic fixtures. Run tools/check_public_content.py before
committing; its scan is a guardrail, not a complete secret detector.

See docs/BUILD.md for builds and CONTRIBUTING.md for validation. Do not publish
old development history by merging historical branches into this repository.

Supporter implementations and code registries belong in the private companion
repository. Keep public extension points code-free. See docs/SUPPORTER_BUILDS.md.
