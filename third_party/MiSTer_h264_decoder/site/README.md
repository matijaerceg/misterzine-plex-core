# The user manual

This directory is the **source of the user manual**. It is not build output: `site/` is
tracked in git and the build writes to `.site-build/`, which is gitignored.

`site/content/` is the manual. `mkdocs.yml` at the repo root configures it, and
`.github/workflows/docs.yml` owns it (the two checks below are also run by hand before
committing). That workflow does two
separate things:

- **Builds it as a CI check** on every PR and every push to `main` that touches the manual,
  `mkdocs.yml`, `tools/docs_check.py` or `h264/emu.sv`. This is the parity gate: a broken
  cross-link or an undocumented OSD option fails next to the change that caused it.
- **Deploys it only when a release is published**, from that release's own tagged commit,
  so the published manual always matches the `.rbf` a reader can download.

## Preview it locally

```bash
python3 -m venv .venv
source .venv/bin/activate          # fish: source .venv/bin/activate.fish
pip install -r site/requirements.txt

mkdocs serve                       # http://127.0.0.1:8000, live reload
mkdocs build --strict              # exactly what CI runs
python3 tools/docs_check.py        # CONF_STR <-> manual parity
```

Run both checks before committing anything under `site/content/`.

## What belongs here, and what does not

| | |
|---|---|
| `README.md` | The landing page. What the core is, honest status, quick start, licensing. Deliberately short, **not** the manual. |
| `site/content/` | **The user manual.** Every user-visible detail: controls, settings, messages, output modes, formats, troubleshooting. |
| `docs/` | Engineering design notes: *why* the RTL is the way it is. **Not published, not user documentation.** |

If a `docs/` note contains genuinely user-facing material, **harvest those sentences into
the manual**. Do not link a reader into `docs/` as though it were a manual page.

## Authoring rules

**Keep `.md` extensions on cross-links.** `[Settings](../playback/settings.md)`, not an
extensionless or directory-style link: MkDocs rewrites it, and GitHub resolves the
same link natively.

**Links to repo files must be absolute.** `strict: true` fails the build on any link that
escapes `docs_dir`. Use the full repository URL for `LICENSE`, `NOTICE` and anything in
`docs/`.

**Write in the present tense as a feature lands.** The site deploys only on a release, so
a page never describes a build nobody can download. A page for a feature that does not
exist yet carries a short "not yet implemented" admonition instead; remove it when the
feature ships.

**Prose must never depend on an image.** No "as shown below". Placeholders are marked with
`<!-- SCREENSHOT ... -->` comments carrying the caption and capture recipe; add real
screenshots with the figure form (`attr_list` and `md_in_html` are enabled for it):

```html
<figure markdown="span">
  ![The Main settings page](../assets/img/osd-main.png){ width="640" }
  <figcaption>The Main settings page, showing default values.</figcaption>
</figure>
```

## Why MkDocs

It is the MiSTer ecosystem's own convention (mister-devel's documentation is MkDocs on
`github.io`), and the content is plain markdown.
