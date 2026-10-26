#!/usr/bin/env python3
"""Install, run or remove the optional PAL timing diagnostic. Normal releases are unchanged."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import urllib.request

TAG = 'diagnostic-pal-timing-1'
URL = 'https://github.com/matijaerceg/misterzine-plex-core/releases/download/' + TAG + '/jfplay-pal-diagnostic'
SHA256 = '67e37ed87724beb30d3c502ae3889502a783a2c27da5e13236af50fe0de552f3'
CARD = Path('/media/fat')
ROOT = CARD / 'misterzine-plex'
DEST = ROOT / 'diagnostics' / 'pal-timing-1'
ENTRY = CARD / 'Scripts' / 'MisterZine-Plex-PAL-Diagnostic.sh'

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def manager():
    spec = importlib.util.spec_from_file_location('plex_manager', ROOT / 'manager.py')
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m

def installed():
    state = json.loads((ROOT / 'active.json').read_text())
    if state['current'] != 'beta-0.1.0-beta.31':
        raise RuntimeError('This diagnostic requires installed Plex beta31. It does not change your selected release.')
    folder = ROOT / 'releases' / state['current']
    manifest = json.loads((folder / 'manifest.json').read_text())
    for name, expected in manifest['files'].items():
        if digest(folder / name) != expected:
            raise RuntimeError('Installed payload check failed: ' + name)
    return folder

def install(local_worker=None):
    installed()
    DEST.mkdir(parents=True, exist_ok=True)
    tmp = DEST / 'jfplay.download'
    try:
        if local_worker:
            shutil.copyfile(local_worker, tmp)
        else:
            with urllib.request.urlopen(URL, timeout=60) as response, tmp.open('wb') as f:
                shutil.copyfileobj(response, f)
        if digest(tmp) != SHA256:
            raise RuntimeError('Diagnostic download checksum failed; nothing was installed.')
        tmp.chmod(0o755)
        os.replace(tmp, DEST / 'jfplay')
        # The launcher uses this exact checked installer, not a second network fetch.
        if Path(__file__).resolve() != (DEST / 'install.py').resolve():
            shutil.copyfile(__file__, DEST / 'install.py')
        ENTRY.write_text('#!/bin/bash\nexec python3 /media/fat/misterzine-plex/diagnostics/pal-timing-1/install.py run\n')
        ENTRY.chmod(0o755)
    finally:
        if tmp.exists(): tmp.unlink()
    print('Installed optional diagnostic. Exit Plex, then run Scripts > MisterZine-Plex-PAL-Diagnostic.')
    print('The normal Plex launcher, release files and saved access are unchanged.')

def run():
    m = manager()
    with m.locked(ROOT, patience=3):
        folder = installed()
        if digest(DEST / 'jfplay') != SHA256:
            raise RuntimeError('Diagnostic checksum failed; reinstall it.')
        args = [str(folder / 'plexcrt'), '-config', str(ROOT / 'plexcrt.json'),
                '-cache', str(ROOT / 'cache'), '-player', str(DEST / 'jfplay'),
                '-ffmpeg', str(folder / 'ffmpeg')]
        subprocess.run(args + ['-check'], check=True)
        if not m.ensure_selected_core(CARD, ROOT, folder):
            raise RuntimeError('Installed core did not load.')
        rbf = m.core_file(ROOT, folder).relative_to(CARD).with_suffix('').as_posix()
        env = dict(os.environ, MISTERZINE_H264_RBF=rbf,
                   MISTERZINE_PLEX_DISPLAY=m.display_env(CARD))
        # Never enable URL logging, even if a caller previously set this variable.
        env.pop('JFPLAY_LOG_URLS', None)
        child = None
        old = signal.getsignal(signal.SIGTERM)
        signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
        try:
            with open('/tmp/misterzine-plex.log', 'wb') as log:
                child = subprocess.Popen(args, env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
                code = child.wait()
        except KeyboardInterrupt:
            if child: m.stop_child(child)
            code = 0
        finally:
            signal.signal(signal.SIGTERM, old)
        if code == 3: m.load_menu(CARD)
        elif code != 0: raise RuntimeError('Diagnostic app exited with code ' + str(code))

def remove():
    m = manager()
    with m.locked(ROOT, patience=3):
        if DEST.resolve() != ROOT.resolve() / 'diagnostics' / 'pal-timing-1':
            raise RuntimeError('Unexpected diagnostic directory.')
        if ENTRY.exists():
            if 'diagnostics/pal-timing-1/install.py run' not in ENTRY.read_text():
                raise RuntimeError('Launcher changed; refusing to remove it.')
            ENTRY.unlink()
        if DEST.exists(): shutil.rmtree(DEST)
    print('Diagnostic removed. Launch MisterZine Plex normally.')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['install', 'run', 'remove'], nargs='?', default='install')
    parser.add_argument('--worker', type=Path, help=argparse.SUPPRESS)
    a = parser.parse_args()
    try:
        if a.action == 'install': install(a.worker)
        elif a.action == 'run': run()
        else: remove()
    except KeyboardInterrupt:
        sys.exit(0)
    except Exception as e:
        # HTTP exception URLs and arbitrary environment values are not report data.
        print('Diagnostic failed: ' + (str(e) if isinstance(e, RuntimeError) else type(e).__name__), file=sys.stderr)
        sys.exit(1)
