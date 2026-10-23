#!/usr/bin/env python3
"""Generate a release catalogue, staging-only Downloader DB, and one-file installer."""
import argparse
import base64
import hashlib
import io
import json
from pathlib import Path
import shutil
import time
import zipfile

import catalogue
import build_package

ROOT = Path(__file__).resolve().parent
REPO = 'matijaerceg/misterzine-plex-core'
DISTRIBUTION = 'https://raw.githubusercontent.com/' + REPO + '/distribution/'


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def installer(out, name, channel=None, pinned=None, database=None):
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, 'w', zipfile.ZIP_DEFLATED) as z:
        for helper in ('manager.py', 'update_service.py', 'catalogue.py', 'menu_launcher.py'):
            z.writestr(helper, build_package.manager_source(ROOT.parent) if helper == 'manager.py'
                       else (ROOT / helper).read_bytes())
        z.writestr('__main__.py', 'from update_service import cli\ncli()\n')
    payload = base64.b64encode(stream.getvalue()).decode()
    script = '#!/bin/bash\nset -eu\n'
    script += 'command -v python3 >/dev/null || { echo "Current MiSTer Linux with Python 3 is required."; exit 1; }\n'
    script += 'python3 -c "import sys; assert sys.version_info >= (3, 9), \'Python 3.9 or newer is required\'"\n'
    script += 'work=$(mktemp -d /tmp/misterzine-plex-install.XXXXXX)\ntrap \'rm -rf -- "$work"\' EXIT\n'
    script += 'base64 -d > "$work/service.pyz" <<\'MISTERZINE_INSTALLER\'\n' + payload + '\nMISTERZINE_INSTALLER\n'
    options = ' --yes'
    if channel:
        options += ' --channel ' + channel
    if pinned:
        script += 'cat > "$work/release.json" <<\'MISTERZINE_RELEASE\'\n' + json.dumps(pinned) + '\nMISTERZINE_RELEASE\n'
        options += ' --request "$work/release.json" --download-db-url ' + database
    script += 'python3 "$work/service.pyz" install "$@"' + options + '\n'
    (out / name).write_text(script, newline='\n')
    (out / 'MisterZine-Plex-Uninstall.sh').write_text(
        '#!/bin/bash\npython3 /media/fat/misterzine-plex/update_service.py uninstall "$@"\n', newline='\n')


def build(package, tag, notes, out, previous=None, source_archive=None):
    out.mkdir(parents=True, exist_ok=True)
    if not catalogue.IDENT.fullmatch(tag):
        raise ValueError('Invalid release tag')
    with zipfile.ZipFile(package) as z:
        manifest = json.loads(z.read('misterzine-plex-beta/manifest.json'))
    source = manifest.get('source')
    if not isinstance(source, dict) or set(source) != {'filename', 'size', 'sha256'}:
        raise ValueError('Release package has no corresponding-source asset metadata')
    source_archive = Path(source_archive) if source_archive else package.parent / source['filename']
    if (not source_archive.is_file() or source_archive.name != source['filename']
            or source_archive.stat().st_size != source['size'] or sha(source_archive) != source['sha256']):
        raise ValueError('Corresponding-source asset does not match package metadata')
    base = 'https://github.com/' + REPO + '/releases/download/' + tag + '/'
    channel = manifest.get('channel')
    release = {'id': manifest['id'], 'version': manifest['version'], 'channel': channel,
               'notes': notes, 'url': base + package.name, 'db_url': DISTRIBUTION + str(channel) + '.json.zip',
               'size': package.stat().st_size, 'sha256': hashlib.sha256(package.read_bytes()).hexdigest(),
               'access': manifest.get('access'),
               'source': {'filename': source['filename'], 'size': source['size'], 'sha256': source['sha256'],
                          'url': base + source['filename']}}
    catalogue.entry(release)
    # The channel being published is replaced whole, so its old entry is not
    # validated: a catalogue written before the corresponding-source metadata
    # existed (beta.27 and earlier) is still a valid starting point.
    if previous is not None:
        previous = dict(previous, releases={c: r for c, r in previous.get('releases', {}).items() if c != channel})
    cat = catalogue.catalogue(previous) if previous is not None else {'schema': 1, 'releases': {}}
    cat['releases'][channel] = release
    for missing in {'public', 'beta'} - set(cat['releases']):
        (out / ('MisterZine-Plex-Install-' + missing.title() + '.sh')).unlink(missing_ok=True)
    (out / 'catalogue.json').write_text(json.dumps(cat, indent=2) + '\n')
    db = {'v': 1, 'db_id': catalogue.DB_ID, 'timestamp': int(time.time()),
          'folders': {catalogue.STAGING: {}}, 'default_options': {'filter': ''},
          'files': {catalogue.STAGING + '/package.zip': {'url': release['url'], 'size': release['size'],
                    'hash': hashlib.md5(package.read_bytes()).hexdigest()}}}
    with zipfile.ZipFile(out / (channel + '.json.zip'), 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr('misterzine_plex.json', json.dumps(db))
    shutil.copyfile(out / (channel + '.json.zip'), out / 'release-db.json.zip')
    (out / 'downloader_misterzine_plex.ini').write_text('[misterzine_plex]\ndb_url = ' + release['db_url'] + '\nfilter =\n')
    for available in cat['releases']:
        installer(out, 'MisterZine-Plex-Install-' + available.title() + '.sh', channel=available)
    installer(out, 'MisterZine-Plex-Install-' + release['version'] + '.sh',
              pinned=release, database=base + 'release-db.json.zip')
    return release


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--package', type=Path, required=True)
    p.add_argument('--tag', required=True)
    p.add_argument('--notes', type=Path, required=True)
    p.add_argument('--out', type=Path, default=ROOT / 'dist/distribution')
    p.add_argument('--previous', type=Path)
    p.add_argument('--source-archive', type=Path)
    args = p.parse_args()
    build(args.package, args.tag, args.notes.read_text(), args.out,
          json.loads(args.previous.read_text()) if args.previous else None, args.source_archive)
