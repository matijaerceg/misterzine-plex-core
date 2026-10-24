#!/usr/bin/env python3
"""Publish the catalogue's memos without a release; publish only with --publish.

A memo is a short note from the developers that the app shows once over Home,
dismissed by holding OK. The catalogue's "memos" list lets one be added,
reworded or withdrawn between releases:

    [{"id": "2026-11-outage", "title": "Heads up", "text": "..."}]

The app shows each id once, so rewording keeps the id (cards that already
dismissed it will not see the new text) and a note meant for everyone again
takes a new id. A published memo with the id of one compiled into the app
replaces its text. Removing a memo from the list withdraws it. Every other key
of the catalogue is left exactly as it is; the release entries are not touched.

Without --publish the resulting catalogue is written to --out for inspection.
--show prints the memos the catalogue holds now. GitHub CLI authentication and
Git are required for publishing.
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

import build_distribution
import catalogue


def run(*args, cwd=None):
    return subprocess.run(args, cwd=cwd, check=True, text=True, stdout=subprocess.PIPE).stdout


def replace(cat, memos):
    """The catalogue with its memos replaced, validated, unchanged otherwise."""
    cat = dict(catalogue.catalogue(cat))
    if memos:
        cat['memos'] = memos
    else:
        cat.pop('memos', None)
    catalogue.memos(cat)
    return cat


def publish(memos, out, perform=False, previous=None):
    if previous is None:
        previous = catalogue.fetch()
    cat = replace(previous, memos)
    out.mkdir(parents=True, exist_ok=True)
    (out / 'catalogue.json').write_text(json.dumps(cat, indent=2) + '\n')
    if not perform:
        print('Prepared catalogue.json with %d memo(s). Nothing was published.' % len(memos))
        return
    repo = build_distribution.REPO
    with tempfile.TemporaryDirectory(prefix='plex-memos-') as tmp:
        checkout = Path(tmp)
        remote = 'https://github.com/' + repo + '.git'
        run('git', 'init', '-b', 'distribution', str(checkout))
        run('git', 'remote', 'add', 'origin', remote, cwd=checkout)
        run('git', 'fetch', '--depth=1', 'origin', 'distribution', cwd=checkout)
        run('git', 'reset', '--hard', 'FETCH_HEAD', cwd=checkout)
        # The branch as it is now, not the fetched copy: a release published
        # meanwhile keeps its entries.
        cat = replace(json.loads((checkout / 'catalogue.json').read_text()), memos)
        (checkout / 'catalogue.json').write_text(json.dumps(cat, indent=2) + '\n')
        (out / 'catalogue.json').write_text(json.dumps(cat, indent=2) + '\n')
        run('git', 'add', 'catalogue.json', cwd=checkout)
        run('git', '-c', 'user.name=MisterZine release', '-c', 'user.email=release@users.noreply.github.com',
            'commit', '-m', 'Update memos', cwd=checkout)
        # No force push: a concurrent publish is not overwritten.
        run('git', 'push', 'origin', 'HEAD:distribution', cwd=checkout)
    print('Published %d memo(s).' % len(memos))


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--memos', type=Path, help='JSON file holding the list of memos (an empty list withdraws all)')
    p.add_argument('--out', type=Path, default=Path(__file__).parent / 'dist/distribution')
    p.add_argument('--previous', type=Path, help='a catalogue file to start from instead of the published one')
    p.add_argument('--publish', action='store_true')
    p.add_argument('--show', action='store_true', help='print the memos the catalogue holds now')
    a = p.parse_args()
    current = json.loads(a.previous.read_text()) if a.previous else None
    if a.show:
        print(json.dumps(catalogue.memos(current if current is not None else catalogue.fetch()), indent=2))
    elif a.memos is None:
        p.error('--memos is required unless --show is given')
    else:
        publish(json.loads(a.memos.read_text()), a.out, a.publish, current)
