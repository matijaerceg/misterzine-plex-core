#!/usr/bin/env python3
"""Prepare distribution files; publish only with an explicit --publish.

Consumes an already verified release ZIP. Does not generate codes or choose a
release version. GitHub CLI authentication and Git are required for publishing.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

import build_distribution
import catalogue
import update_service


def run(*args, cwd=None):
    return subprocess.run(args, cwd=cwd, check=True, text=True, stdout=subprocess.PIPE).stdout


def publish(package, tag, notes, out, perform=False, previous=None, source_archive=None, pin_legacy=False,
            memos=None):
    package = package.resolve()
    release = build_distribution.build(package, tag, notes, out, previous, source_archive, pin_legacy, memos)
    source_asset = Path(source_archive).resolve() if source_archive else package.parent / release['source']['filename']
    with tempfile.TemporaryDirectory(prefix='plex-verify-') as tmp:
        update_service.unpack(package, Path(tmp), release)
    if not perform:
        print('Prepared distribution files. Nothing was published.')
        return
    repo = build_distribution.REPO
    with tempfile.TemporaryDirectory(prefix='plex-publish-') as tmp:
        checkout = Path(tmp)
        remote = 'https://github.com/' + repo + '.git'
        exists = run('git', 'ls-remote', '--heads', remote, 'distribution').strip()
        run('git', 'init', '-b', 'distribution', str(checkout))
        run('git', 'remote', 'add', 'origin', remote, cwd=checkout)
        if exists:
            run('git', 'fetch', '--depth=1', 'origin', 'distribution', cwd=checkout)
            run('git', 'reset', '--hard', 'FETCH_HEAD', cwd=checkout)
        old = checkout / 'catalogue.json'
        previous = catalogue.catalogue(json.loads(old.read_text())) if old.exists() else None
        if previous and any(r['id'] == release['id'] for slot in ('releases', 'current')
                            for r in previous.get(slot, {}).values()):
            raise ValueError('This release ID is already published')
        build_distribution.build(package, tag, notes, out, previous, source_asset, pin_legacy, memos)
        note_file = checkout / 'release-notes.txt'
        note_file.write_text(notes)
        checksum = out / (package.name + '.sha256')
        checksum.write_text(release['sha256'] + '  ' + package.name + '\n')
        # Upload everything before making either the release or catalogue visible.
        run('gh', 'release', 'create', tag, str(package), str(source_asset), str(checksum),
            str(out/'release-db.json.zip'), str(out/'MisterZine-Plex-Uninstall.sh'),
            *[str(out / ('MisterZine-Plex-Install-' + c.title() + '.sh'))
              for c in catalogue.offered_channels(json.loads((out/'catalogue.json').read_text()))],
            str(out / ('MisterZine-Plex-Install-' + release['version'] + '.sh')),
            '--repo', repo, '--draft', '--verify-tag', '--title', release['version'], '--notes-file', str(note_file),
            *(['--prerelease'] if release['channel']=='beta' else []))
        published_channels = catalogue.offered_channels(json.loads((out/'catalogue.json').read_text()))
        for name in ('catalogue.json', release['channel']+'.json.zip',
                     *('MisterZine-Plex-Install-' + c.title() + '.sh' for c in published_channels)):
            shutil.copyfile(out/name, checkout/name)
            run('git', 'add', name, cwd=checkout)
        run('git', '-c', 'user.name=MisterZine release', '-c', 'user.email=release@users.noreply.github.com',
            'commit', '-m', 'Publish '+release['id'], cwd=checkout)
        run('gh', 'release', 'edit', tag, '--repo', repo, '--draft=false')
        # No force push: concurrent publishers cannot overwrite another channel.
        run('git', 'push', 'origin', 'HEAD:distribution', cwd=checkout)
    print('Published package, installers, catalogue and selected channel database.')


if __name__ == '__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--package',type=Path,required=True)
    p.add_argument('--tag',required=True)
    p.add_argument('--notes',type=Path,required=True)
    p.add_argument('--out',type=Path,default=Path(__file__).parent/'dist/distribution')
    p.add_argument('--previous',type=Path)
    p.add_argument('--source-archive',type=Path)
    p.add_argument('--publish',action='store_true')
    p.add_argument('--pin-legacy',action='store_true')
    p.add_argument('--memos',type=Path,help='JSON list of notes replacing the catalogue\'s (see publish_memos.py)')
    a=p.parse_args()
    publish(a.package,a.tag,a.notes.read_text(),a.out,a.publish,
            json.loads(a.previous.read_text()) if a.previous else None, a.source_archive, a.pin_legacy,
            json.loads(a.memos.read_text()) if a.memos else None)
