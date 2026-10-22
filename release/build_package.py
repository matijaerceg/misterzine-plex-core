"""Build an allowlisted release ZIP from verified build outputs; never copy
developer state or history."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import shutil
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
HASH = re.compile(r'[0-9a-f]{64}')
IDENT = re.compile(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,95}')
VERSION = re.compile(r'v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?')
PAYLOAD_NAMES = ('plexcrt', 'jfplay', 'ffmpeg', 'PlexH264.rbf')
BATCH = re.compile(r'[a-z0-9][a-z0-9-]{0,47}')


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def manager_source(root=None):
    """Embed artwork without changing the package schema older updaters accept."""
    root = root or ROOT
    source = (root / 'release/manager.py').read_bytes()
    marker = b"ZAPAROO_LOGO = ''"
    if source.count(marker) != 1:
        raise ValueError('Expected one Zaparoo artwork placeholder')
    logo = (root / 'app/internal/ui/assets/misterzine-stacked-v1.png').read_bytes()
    return source.replace(marker, b"ZAPAROO_LOGO = '" + base64.b64encode(logo) + b"'")


def read_build_metadata(path, ident, version, binary_hash):
    """The channel and access requirement of the app build, from the stamp
    beta_release.py writes beside the binary. A beta carries its batch and
    the hash of its code, which the app checks offline before offering the
    update (updates.Release.Requirement)."""
    if not path.is_file():
        raise ValueError('Application build metadata is required; build the app with release/beta_release.py')
    info = json.loads(path.read_text(encoding='utf-8'))
    if info.get('id') != ident or info.get('version') != version or info.get('binary_sha256') != binary_hash:
        raise ValueError('Application metadata does not match this package; rebuild with the selected ID and version')
    channel, access = info.get('channel'), info.get('access')
    if channel not in ('development', 'public', 'beta'):
        raise ValueError('Invalid application release channel')
    if channel == 'beta':
        if '-' not in version:
            raise ValueError('Beta builds must use a prerelease version')
        if not isinstance(access, dict) or not BATCH.fullmatch(str(access.get('batch', ''))):
            raise ValueError('Beta build is missing valid batch metadata')
        if not HASH.fullmatch(str(access.get('sha256', ''))):
            raise ValueError('Beta build is missing a valid code verifier')
        return {'channel': channel, 'access': dict(access)}
    if access not in (None, {}):
        raise ValueError('Non-beta build contains beta gate metadata')
    if channel == 'public' and '-' in version:
        raise ValueError('Public builds must use a stable version')
    return {'channel': channel, 'access': None}


def build(out, ident, version, worker=None, ffmpeg=None, rbf=None, rbf_manifest=None, source_archive=None):
    if not isinstance(ident, str) or not IDENT.fullmatch(ident):
        raise ValueError('Invalid release identifier')
    if not isinstance(version, str) or not VERSION.fullmatch(version):
        raise ValueError('Invalid release version')
    out.mkdir(parents=True, exist_ok=True)
    worker = Path(worker or ROOT / 'arm/jfplay')
    ffmpeg = Path(ffmpeg or ROOT / 'build/arm/ffmpeg')
    rbf = Path(rbf or ROOT / 'app/dist/PlexH264.rbf')
    rbf_manifest = Path(rbf_manifest or rbf.with_name(rbf.name + '.json'))
    inputs = {'plexcrt': ROOT / 'app/dist/plexcrt', 'jfplay': worker,
              'ffmpeg': ffmpeg, 'PlexH264.rbf': rbf}
    for name, path in inputs.items():
        if not path.is_file():
            raise FileNotFoundError('Required release input is missing: ' + name)
    if not rbf_manifest.is_file():
        raise FileNotFoundError('Qualified Quartus RBF manifest is required')
    provenance = json.loads(rbf_manifest.read_text(encoding='utf-8'))
    rbf_info = provenance.get('rbf', {})
    if rbf_info.get('name') != rbf.name or rbf_info.get('sha256') != sha(rbf) or rbf_info.get('marginal') is not False:
        raise ValueError('RBF does not match a non-marginal qualified build manifest')
    if provenance.get('timing', {}).get('pass') is not True:
        raise ValueError('RBF build manifest does not record a timing pass')
    if provenance.get('git', {}).get('dirty') is not False:
        raise ValueError('RBF was not built from a clean, committed tree')
    if not str(provenance.get('core_version', '')).startswith('plex-'):
        raise ValueError('RBF core version must be a plex- release version, not a test label')
    metadata = read_build_metadata(ROOT / 'app/dist/plexcrt.build.json', ident, version, sha(inputs['plexcrt']))
    core_provenance = {'rbf': rbf.name, 'sha256': sha(rbf),
                       'quartus_manifest_sha256': sha(rbf_manifest),
                       'core_version': provenance.get('core_version'),
                       'build_date': provenance.get('build_date'),
                       'git': provenance.get('git'), 'fit': provenance.get('fit'),
                       'timing': provenance.get('timing'), 'toolchain': provenance.get('toolchain')}

    if source_archive is None:
        raise ValueError('A matching corresponding-source archive is required')
    source_archive = Path(source_archive)
    if not source_archive.is_file():
        raise FileNotFoundError('Corresponding-source archive is required')

    with tempfile.TemporaryDirectory(prefix='misterzine-package-') as tmp:
        stage = Path(tmp)
        package = stage / 'misterzine-plex-beta'
        payload = package / 'payload'
        payload.mkdir(parents=True)
        hashes = {}
        for name, src in inputs.items():
            shutil.copyfile(src, payload / name)
            hashes[name] = sha(src)
        source_name = 'MisterZine-Plex-Core-Source-' + ident + '.zip'
        source_meta = {'filename': source_name, 'size': source_archive.stat().st_size,
                       'sha256': sha(source_archive)}
        manifest = {'id': ident, 'version': version, **metadata, 'core': core_provenance,
                    'source': source_meta, 'files': hashes}
        (package / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
        prov = package / 'provenance'
        prov.mkdir()
        shutil.copyfile(rbf_manifest, prov / 'quartus-rbf-manifest.json')
        for name in ('manager.py', 'update_service.py', 'catalogue.py', 'menu_launcher.py', 'README.md', 'TERMS.md', 'THIRD_PARTY_NOTICES.md', 'BETA_ACCESS.md'):
            if name == 'manager.py':
                (package / name).write_bytes(manager_source())
            else:
                shutil.copyfile(ROOT / 'release' / name, package / name)
        shutil.copytree(ROOT / 'release/licenses', package / 'licenses')
        with zipfile.ZipFile(source_archive) as archive:
            if archive.testzip() is not None:
                raise ValueError('Corresponding-source archive is corrupt')
        if source_archive.resolve() != (out / source_name).resolve():
            # build_source.py may already have written it under this name
            shutil.copyfile(source_archive, out / source_name)
        script = stage / 'Scripts/MisterZine-Plex-Install.sh'
        script.parent.mkdir()
        script.write_text('#!/bin/bash\nset -e\npython3 /media/fat/misterzine-plex-beta/manager.py install\npython3 /media/fat/misterzine-plex/manager.py run\n', newline='\n')
        zip_path = out / ('MisterZine-Plex-Core-' + ident + '.zip')
        with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as archive:
            for path in sorted(stage.rglob('*')):
                if path.is_file():
                    archive.write(path, path.relative_to(stage).as_posix())
        (out / (zip_path.name + '.sha256')).write_text(sha(zip_path) + '  ' + zip_path.name + '\n')
        print(str(zip_path))
        print('SHA-256: ' + sha(zip_path))
        print('Payloads: ' + ', '.join(sorted(hashes)))
        return zip_path


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=ROOT / 'release/dist')
    parser.add_argument('--id', required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--worker', type=Path, help='jfplay from make -C arm (default arm/jfplay)')
    parser.add_argument('--ffmpeg', type=Path, help='static ARM ffmpeg from toolchain/build_ffmpeg.sh (default build/arm/ffmpeg)')
    parser.add_argument('--rbf', type=Path, required=True, help='the qualified core as build_release.sh named it (releases/PlexH264_plex-<version>_...rbf)')
    parser.add_argument('--rbf-manifest', type=Path, help='its Quartus manifest (default: the .rbf.json beside it)')
    parser.add_argument('--source-archive', type=Path, required=True, help='the matching bundle from release/build_source.py')
    args = parser.parse_args()
    build(args.out, args.id, args.version, args.worker, args.ffmpeg, args.rbf, args.rbf_manifest, args.source_archive)
