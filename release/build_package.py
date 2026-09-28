"""Build an allowlisted release ZIP; never copy developer state or history."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import zipfile

import build_presenter

ROOT = Path(__file__).resolve().parent.parent
SOURCE_EXTENSIONS = {'.v', '.sv', '.vh', '.vhd', '.qip', '.sdc', '.tcl', '.mif', '.hex'}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build(out, core_tree, ident, version='0.1.0-beta.12'):
    # Before anything is written: nothing else would notice a presenter
    # binary left over from older source.
    build_presenter.check(ROOT)
    out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='misterzine-package-') as tmp:
        stage = Path(tmp)
        package = stage / 'misterzine-plex-beta'
        payload = package / 'payload'
        payload.mkdir(parents=True)
        inputs = {'plexcrt': ROOT / 'app/dist/plexcrt', 'plexplay.py': ROOT / 'arm/plexplay.py',
                  'plexfb': ROOT / 'arm/plexfb', 'MisterZine Plex Core.rbf': ROOT / 'core/PlexCRT.rbf'}
        hashes = {}
        for name, src in inputs.items():
            shutil.copyfile(src, payload / name)
            hashes[name] = sha(src)
        manifest = {'id': ident, 'version': version, 'channel': 'development', 'access': None, 'files': hashes}
        metadata = ROOT / 'app/dist/plexcrt.build.json'
        if metadata.exists():
            info = json.loads(metadata.read_text())
            if info['id'] != ident or info['version'] != version or info['binary_sha256'] != hashes['plexcrt']:
                raise ValueError('Application metadata does not match this package; rebuild with the selected ID and version')
            manifest.update(channel=info['channel'], access=info['access'])
        (package / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        for name in ('manager.py', 'update_service.py', 'catalogue.py', 'menu_launcher.py', 'README.md', 'TERMS.md', 'THIRD_PARTY_NOTICES.md', 'BETA_ACCESS.md'):
            shutil.copyfile(ROOT / 'release' / name, package / name)
        shutil.copytree(ROOT / 'release/licenses', package / 'licenses')
        script = stage / 'Scripts/MisterZine-Plex-Install.sh'
        script.parent.mkdir()
        script.write_text('#!/bin/bash\nset -e\npython3 /media/fat/misterzine-plex-beta/manager.py install\npython3 /media/fat/misterzine-plex/manager.py run\n', newline='\n')
        source = package / 'corresponding-source.zip'
        with zipfile.ZipFile(source, 'w', zipfile.ZIP_DEFLATED) as archive:
            # Complete source directories, without Quartus build products/history.
            for sub in ('sys', 'rtl'):
                for path in sorted((core_tree / sub).rglob('*')):
                    if path.is_file() and path.suffix in SOURCE_EXTENSIONS and '.git' not in path.parts:
                        archive.write(path, 'core/' + path.relative_to(core_tree).as_posix())
            for name in ('PlexCRT.qsf', 'PlexCRT.qpf', 'PlexCRT.sdc', 'build_id.v', 'LICENSE'):
                archive.write(core_tree / name, 'core/' + name)
            for name in ('PlexCRT.sv', 'files.qip', 'LICENSING.md'):
                archive.write(ROOT / 'core' / name, 'core/' + name)
            archive.write(ROOT / 'arm/plexfb.c', 'arm/plexfb.c')
            for path in sorted((ROOT / 'release/licenses').iterdir()):
                archive.write(path, 'licenses/' + path.name)
            archive.writestr('BUILD.md', '# Build the supplied sources\n\nCore: Quartus Prime Lite 17.0, Cyclone V support. In core/: `quartus_sh --flow compile PlexCRT`. Output: output_files/PlexCRT.rbf.\n\nPresenter: Ubuntu ARM hard-float cross GCC 13, glibc 2.39 (libc6-armhf-cross 2.39-0ubuntu8cross1). In arm/: `arm-linux-gnueabihf-gcc -O2 -static -march=armv7-a -mfpu=neon -mfloat-abi=hard -pthread -o plexfb plexfb.c -lm`. No signing or activation key is required to run a rebuilt core or presenter. Replace the matching installed file for your own build; the official installer verifies official payload hashes.\n')
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
    p = argparse.ArgumentParser()
    p.add_argument('--out', type=Path, default=ROOT / 'release/dist')
    p.add_argument('--core-tree', type=Path, default=ROOT / 'core')
    p.add_argument('--id', default='source-build')
    p.add_argument('--version', default='0.1.0-beta.12')
    args = p.parse_args()
    build(args.out, args.core_tree, args.id, args.version)
