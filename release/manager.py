#!/usr/bin/env python3
"""Install and launch a self-contained MisterZine Plex Core release.

Only named files are replaced. Old releases, account settings and caches are
preserved. This module also runs against a temporary card root in its tests.
"""
import argparse
import contextlib
import hashlib
import json
import mmap
import os
from pathlib import Path
import re
import shutil
import shlex
import signal
import struct
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request
from xml.sax.saxutils import escape

FF_URL = 'https://johnvansickle.com/ffmpeg/releases/ffmpeg-7.0.2-armhf-static.tar.xz'
FF_SHA = '7d41f558cb1f3395b313f8ceabed78b3731c79a0962abf405ebb5cd393e93991'
PAYLOAD = {'plexcrt', 'plexplay.py', 'plexfb', 'MisterZine Plex Core.rbf'}
LEGACY_PAYLOAD = (PAYLOAD - {'MisterZine Plex Core.rbf'}) | {'MisterZine Plex.rbf'}
SCRIPTS = {'Rollback': 'rollback', 'Diagnostics': 'diagnostics', 'Uninstall': 'uninstall'}
HELPERS = ('manager.py', 'update_service.py', 'catalogue.py', 'menu_launcher.py')
BOOT_START = '# BEGIN MISTERZINE PLEX LAUNCHER'
BOOT_END = '# END MISTERZINE PLEX LAUNCHER'
# Reports go to the same service the MisterZine Frontend uses: a plain-text
# upload answered with a short code, kept 30 days, nothing stored about the
# sender. '' switches sending off.
REPORT_SERVICE = 'https://api.misterzine.fyi'
REPORT_MAGIC = 'MisterZine report v1'
REPORT_MAX_BYTES = 256 * 1024
REPORT_LOGS = ('misterzine-plex-menu-run.log', 'misterzine-plex-menu-run.log.1', 'misterzine-plex.log',
               'misterzine-plex.log.1', 'misterzine-plex-menu.log', 'plexplay.log')


LEGACY_ENTRY = b'<mistergamedescription>\n  <rbf>menu</rbf>\n  <setname>misterzine-plex</setname>\n</mistergamedescription>\n'


def legacy_watcher(root):
    """True when the installed watcher only understands the pre-beta.4 menu bounce."""
    try:
        return b'SELECTIONS' not in (root / 'menu_launcher.py').read_bytes()
    except OSError:
        return False


def repair_menu_entry(card):
    """Point the main-menu entry at the selected release, in the form the
    installed watcher understands. Called after any change of selection.
    With no release selected (a failed first install), both the menu entry
    and the Zaparoo entry go."""
    root = card / 'misterzine-plex'
    entry = card / 'MisterZine Plex Core.mgl'
    if not (root / 'active.json').is_file():
        entry.unlink(missing_ok=True)
        zaparoo_entry(card, enable=False)
        return
    if not entry.exists() or not (root / 'menu_launcher.py').is_file():
        return
    menu_entries(card)


ZAPAROO_ENTRY = 'misterzine-plex.toml'


def reload_zaparoo(card):
    """Ask a running Zaparoo service to re-read its launchers, so the entry
    appears without a reboot. Best effort: no Zaparoo, no wait beyond 15 s."""
    script = card / 'Scripts/zaparoo.sh'
    if not script.is_file():
        return
    try:
        subprocess.run([str(script), '-reload'], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=15)
    except (OSError, subprocess.SubprocessError):
        pass


def maintains_zaparoo(root):
    """True when the installed manager keeps the Zaparoo entry up to date and
    removes it on uninstall. After a rollback to a release from before that,
    the restored manager would leave a stale entry behind."""
    try:
        return b'def zaparoo_entry(' in (root / 'manager.py').read_bytes()
    except OSError:
        return False


def zaparoo_entry(card, enable=True, folder=None, reload=None):
    """List Plex under Other in Zaparoo, pointing at the selected release.

    Zaparoo does not scan _Other; its Other list is its built-ins plus custom
    launchers, which it also reads from files in zaparoo/launchers. This file
    is ours alone, rewritten whenever the selected release changes and removed
    on uninstall. Nothing is written when Zaparoo is not installed. A pre-beta.4
    watcher cannot start the app from a direct core load, so none is listed
    for one. A launcher with the same id in Zaparoo's own config.toml wins.
    The frontend's system list reads this after a reload; no media database
    update is needed (that only indexes games)."""
    reload = reload or reload_zaparoo
    root = card / 'misterzine-plex'
    zaparoo = card / 'zaparoo'
    launchers = zaparoo / 'launchers'
    path = launchers / ZAPAROO_ENTRY
    for place in (zaparoo, launchers, path):
        if place.is_symlink():
            return
    if (not enable or legacy_watcher(root) or not maintains_zaparoo(root)
            or not (root / 'active.json').is_file() and folder is None):
        if path.is_file():
            path.unlink()
            reload(card)
        return
    if not zaparoo.is_dir():
        return
    load = core_file(root, folder).relative_to(card).with_suffix('').as_posix()
    body = ('# MisterZine Plex Core in Zaparoo\'s Other list. Written by the Plex installer and\n'
            '# rewritten on every update; do not edit. Uninstalling Plex removes it.\n'
            '[[launchers.custom]]\n'
            'id = "misterzine-plex"\n'
            'kind = "virtual_system"\n'
            'backend = "mister_core"\n'
            'name = "MisterZine Plex Core"\n'
            'category = "Other"\n'
            'load_path = ' + json.dumps(load) + '\n').encode()
    try:
        if path.read_bytes() == body:
            return
    except OSError:
        pass
    launchers.mkdir(exist_ok=True)
    atomic(path, body)
    reload(card)


def menu_entries(card, enable=True, folder=None):
    root = card / 'misterzine-plex'
    startup = card / 'linux/user-startup.sh'
    if startup.is_symlink() or not startup.resolve().is_relative_to(card.resolve()):
        raise ValueError('Startup file must stay on the selected card')
    text = startup.read_text() if startup.exists() else '#!/bin/bash\n'
    text = re.sub(re.escape(BOOT_START) + r'\n.*?' + re.escape(BOOT_END) + r'\n?', '', text, flags=re.S)
    # Migrate the exact earlier development hook without touching other apps.
    legacy = '[ -f /media/fat/misterzine-plex/menu_launcher.py ] && setsid python3 /media/fat/misterzine-plex/menu_launcher.py > /tmp/misterzine-plex-menu.log 2>&1 < /dev/null &'
    text = '\n'.join(line for line in text.split('\n') if line not in (legacy, '# MisterZine Plex main-menu launcher'))
    entry = card / 'MisterZine Plex Core.mgl'
    if enable:
        # Load the core directly. Bouncing through the menu core with a
        # setname never reaches the watcher under forked main binaries
        # (Zaparoo Frontend), which keep reporting the menu as the core.
        # A pre-beta.4 watcher only knows the bounce, so keep it for one.
        atomic(entry, LEGACY_ENTRY if legacy_watcher(root) else launch_body(root, folder).encode())
        command = 'setsid python3 ' + shlex.quote(str(root / 'menu_launcher.py')) + ' --card ' + shlex.quote(str(card))
        block = BOOT_START + '\n' + command + ' >/tmp/misterzine-plex-menu.log 2>&1 </dev/null &\n' + BOOT_END + '\n'
        # Put the hook ahead of any existing early exit in user-startup.sh.
        first, sep, rest = text.partition('\n')
        text = first + '\n' + block + rest if first.startswith('#!') else '#!/bin/bash\n' + block + text
    else:
        entry.unlink(missing_ok=True)
    if enable or startup.exists():
        atomic(startup, text.encode())
        startup.chmod(0o755)
    zaparoo_entry(card, enable, folder)


def start_menu_launcher(card):
    if card.resolve() == Path('/media/fat') and Path('/dev/MiSTer_cmd').exists():
        stop_menu_launcher(card)
        with open('/tmp/misterzine-plex-menu.log', 'ab') as log:
            subprocess.Popen([sys.executable, str(card / 'misterzine-plex/menu_launcher.py'), '--card', str(card)],
                stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)


def stop_menu_launcher(card):
    for proc in Path('/proc').glob('[0-9]*'):
        try:
            args = (proc / 'cmdline').read_bytes().split(b'\0')
            if len(args) > 1 and args[1] == str(card / 'misterzine-plex/menu_launcher.py').encode():
                os.kill(int(proc.name), signal.SIGTERM)
        except (FileNotFoundError, ProcessLookupError):
            pass


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as src:
        for block in iter(lambda: src.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.' + path.name + '-', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'wb') as out:
            out.write(data)
            out.flush()
            os.fsync(out.fileno())
        os.replace(name, str(path))
    finally:
        if os.path.exists(name):
            os.unlink(name)


def write_json(path, data):
    atomic(path, (json.dumps(data, indent=2) + '\n').encode())


def read_state(root):
    state = json.loads((root / 'active.json').read_text())
    for key in ('current', 'previous'):
        value = state.get(key)
        if value is not None and not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,95}', value):
            raise ValueError('Invalid release selection; run the installer again')
    return state


@contextlib.contextmanager
def locked(root):
    import fcntl
    root.mkdir(parents=True, exist_ok=True)
    with (root / 'manager.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('MisterZine Plex Core is running. Return to the MiSTer menu first.')
        yield


def decoder(root, archive=None):
    ff = root / 'ffmpeg'
    stamp = root / 'decoder.json'
    if ff.is_file() and stamp.is_file():
        known = json.loads(stamp.read_text())
        if known.get('archive_sha256') == FF_SHA and digest(ff) == known.get('binary_sha256'):
            return
    if archive is None:
        archive = root / 'ffmpeg-7.0.2-armhf-static.tar.xz'
        if not archive.exists() or digest(archive) != FF_SHA:
            print('Downloading the pinned FFmpeg decoder (about 20 MB)...', flush=True)
            with urllib.request.urlopen(FF_URL, timeout=60) as response:
                atomic(archive, response.read(64 * 1024 * 1024 + 1))
    if digest(archive) != FF_SHA:
        raise ValueError('Decoder checksum failed. No release was activated.')
    with tarfile.open(str(archive), 'r:xz') as tar:
        base = 'ffmpeg-7.0.2-armhf-static/'
        for name in ('ffmpeg', 'GPLv3.txt', 'readme.txt'):
            member = tar.getmember(base + name)
            if not member.isfile() or member.size > 100 * 1024 * 1024:
                raise ValueError('Unexpected decoder archive contents')
            with tar.extractfile(member) as src:
                dest = ff if name == 'ffmpeg' else root / 'decoder-notices' / name
                atomic(dest, src.read())
    ff.chmod(0o755)
    write_json(stamp, {'archive_sha256': FF_SHA, 'binary_sha256': digest(ff), 'url': FF_URL})


def wrappers(card):
    for label, action in SCRIPTS.items():
        path = card / 'Scripts' / ('MisterZine-Plex-' + label + '.sh')
        helper = 'update_service.py' if label in ('Install', 'Uninstall') else 'manager.py'
        body = '#!/bin/bash\npython3 ' + shlex.quote(str(card / 'misterzine-plex' / helper)) + ' ' + action + ' --card ' + shlex.quote(str(card)) + '\n'
        # Diagnostics always waits: the code it prints is what the player posts.
        pause = 'true' if label == 'Diagnostics' else '[ "$result" -ne 0 ]'
        body += 'result=$?\nif ' + pause + '; then read -r -p "Press Enter to return to MiSTer..."; fi\nexit "$result"\n'
        atomic(path, body.encode())
        path.chmod(0o755)
    for label in ('Run', 'Rollback', 'Remove', 'Diagnostics', 'Install'):
        (card / 'Scripts' / ('MisterZine-Plex-Core-' + label + '.sh')).unlink(missing_ok=True)
    for label in ('Run', 'Install'):
        (card / 'Scripts' / ('MisterZine-Plex-' + label + '.sh')).unlink(missing_ok=True)


def stage(card, package, archive=None):
    root = card / 'misterzine-plex'
    manifest = json.loads((package / 'manifest.json').read_text())
    files = manifest['files']
    if set(files) != PAYLOAD:
        raise ValueError('Unexpected package file list')
    ident = manifest['id']
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,95}', ident):
        raise ValueError('Invalid release identifier')
    for name, expected in files.items():
        if digest(package / 'payload' / name) != expected:
            raise ValueError('Package checksum failed: ' + name)
    root.mkdir(parents=True, exist_ok=True)
    decoder(root, archive)
    dest = root / 'releases' / ident
    dest.mkdir(parents=True, exist_ok=True)
    if dest.is_symlink():
        raise ValueError('Unsafe release directory')
    if (dest / 'manifest.json').exists() and json.loads((dest / 'manifest.json').read_text()) != manifest:
        raise ValueError('Release identifier already contains different files')
    for name, expected in files.items():
        target = dest / name
        if target.is_symlink():
            raise ValueError('Unsafe release payload')
        if not target.exists() or digest(target) != expected:
            atomic(target, (package / 'payload' / name).read_bytes())
        target.chmod(0o755 if name != 'MisterZine Plex Core.rbf' else 0o644)
    write_json(dest / 'manifest.json', manifest)
    for name in HELPERS:
        if (package / name).is_file():
            atomic(dest / 'maintenance' / name, (package / name).read_bytes())
    return manifest


def install(card, package, archive=None):
    root = card / 'misterzine-plex'
    manifest = stage(card, package, archive)
    ident = manifest['id']
    # Activate only after every executable and dependency has been verified.
    state = read_state(root) if (root / 'active.json').exists() else {}
    previous = state.get('previous') if state.get('current') == ident else state.get('current')
    atomic(root / 'manager.py', (package / 'manager.py').read_bytes() if (package / 'manager.py').exists() else Path(__file__).read_bytes())
    for name in HELPERS[1:]:
        if (package / name).is_file():
            atomic(root / name, (package / name).read_bytes())
    for name in ('README.md', 'TERMS.md', 'THIRD_PARTY_NOTICES.md', 'BETA_ACCESS.md', 'corresponding-source.zip'):
        if (package / name).is_file():
            atomic(root / name, (package / name).read_bytes())
    for name in ('Apache-2.0.txt', 'Go.txt', 'GPL-2.0.txt', 'GPL-3.0.txt', 'LGPL-2.1.txt'):
        if (package / 'licenses' / name).is_file():
            atomic(root / 'licenses' / name, (package / 'licenses' / name).read_bytes())
    wrappers(card)
    if (root / 'menu_launcher.py').is_file():
        updates = root / 'updates'
        if updates.is_symlink():
            raise ValueError('Update support directory cannot be a symbolic link')
        updates.mkdir(exist_ok=True)
        menu_entries(card, folder=root / 'releases' / ident)
    write_json(root / 'active.json', {'current': ident, 'previous': previous})
    configure_channel(root, manifest)
    start_menu_launcher(card)
    print('Installed ' + ident + '. Launch MisterZine Plex Core from the main menu.')


def prune_releases(root):
    """Delete release folders other than the current and previous selection.

    Every update added a folder of about 14 MB and none was ever removed. The
    previous release stays for Rollback. Call only once a new release is known
    to start, never while a failed update may still restore an older one."""
    if (root / 'updates/activation.json').exists():
        # An interrupted update is still to be recovered, and recovery may
        # select a release that is neither current nor previous now.
        return []
    state = read_state(root)
    keep = {state.get('current'), state.get('previous')} - {None}
    folder = root / 'releases'
    if folder.is_symlink() or not folder.is_dir():
        return []
    removed = []
    for path in sorted(folder.iterdir()):
        if path.name in keep:
            continue
        if path.is_symlink() or not path.is_dir():
            path.unlink()
        else:
            shutil.rmtree(path)
        removed.append(path.name)
    return removed


def configure_channel(root, manifest):
    channel = manifest.get('channel')
    if channel in ('public', 'beta'):
        from catalogue import CATALOGUE_URL
        url = CATALOGUE_URL.rsplit('/', 1)[0] + '/' + channel + '.json.zip'
        atomic(root.parent / 'downloader_misterzine_plex.ini',
               ('[misterzine_plex]\ndb_url = ' + url + '\nfilter =\n').encode())


def rollback(root):
    state = read_state(root)
    if not state.get('previous'):
        raise ValueError('No previous release is installed yet')
    previous = root / 'releases' / state['previous']
    manifest = json.loads((previous / 'manifest.json').read_text())
    if set(manifest['files']) not in (PAYLOAD, LEGACY_PAYLOAD):
        raise ValueError('Previous release is incomplete')
    for name, expected in manifest['files'].items():
        if digest(previous / name) != expected:
            raise ValueError('Previous release checksum failed')
    for name in HELPERS:
        if (previous / 'maintenance' / name).is_file():
            atomic(root / name, (previous / 'maintenance' / name).read_bytes())
    write_json(root / 'active.json', {'current': state['previous'], 'previous': state['current']})
    configure_channel(root, manifest)
    repair_menu_entry(root.parent)
    print('Previous release selected. Account and settings preserved.')


def remove(card):
    # Disable the launch entries; retain everything needed to recover an install.
    stop_menu_launcher(card)
    menu_entries(card, enable=False)
    for label in SCRIPTS:
        path = card / 'Scripts' / ('MisterZine-Plex-' + label + '.sh')
        if path.exists():
            os.replace(str(path), str(path) + '.disabled')
    print('Launch entries disabled. Settings, cache and releases remain in /media/fat/misterzine-plex.')
    print('Run the installer to restore the entries.')


def safe_log(text, secrets):
    import urllib.parse
    for secret in secrets:
        if secret:
            for value in (secret, urllib.parse.quote(secret, safe=''), urllib.parse.quote_plus(secret)):
                text = text.replace(value, '[redacted]')
    text = re.sub(r'(?i)((?:x-plex-token|authtoken|accesstoken|token)[= :"%]+)[^&\s"<>]+', r'\1[redacted]', text)
    text = re.sub(r'(?i)(authorization:\s*bearer\s+)\S+', r'\1[redacted]', text)
    text = re.sub(r'https?://[^\s"<>]+', '[server address removed]', text)
    return text


VIDEO_KEYS = ('main', 'direct_video', 'vga_scaler', 'forced_scandoubler', 'ypbpr', 'composite_sync', 'vga_sog',
              'vsync_adjust', 'vscale_mode', 'vscale_border', 'video_mode', 'video_mode_ntsc', 'video_mode_pal',
              'menu_pal', 'hdmi_limited', 'vrr_mode', 'fb_terminal')


def ini_video_settings(text):
    """Video-related keys of MiSTer.ini by section: the global ones and any
    section that names this core. Values only; no paths or names beyond that."""
    found, section = {}, 'MiSTer'
    for line in text.splitlines():
        line = line.split(';', 1)[0].strip()
        if not line:
            continue
        if line.startswith('[') and line.endswith(']'):
            section = line[1:-1].strip()
            continue
        key, sep, value = line.partition('=')
        key = key.strip().lower()
        if sep and key in VIDEO_KEYS and (section.lower() in ('mister', 'menu') or 'plex' in section.lower()):
            found.setdefault(section, {})[key] = value.strip()[:40]
    return found


def system_facts(root, secrets, proc_root=Path('/proc')):
    """Facts about the board that decide whether a launch or a picture can
    work, gathered read-only. Each is best-effort and absent when unreadable."""
    facts = {}
    card = root.parent
    try:
        facts['video_settings'] = ini_video_settings((card / 'MiSTer.ini').read_text(errors='replace'))
    except OSError:
        pass
    try:
        names, binaries = set(), set()
        for proc in proc_root.iterdir():
            try:
                name = (proc / 'comm').read_bytes().decode('utf-8', errors='replace').strip() if proc.name.isdigit() else ''
            except OSError:
                continue
            if name.startswith('MiSTer'):
                names.add(name)
                # Which main this is: the path it runs from and the hash of that
                # file, since a fork shares its name with stock main.
                try:
                    exe = Path(os.readlink(proc / 'exe'))
                    binaries.add('%s %s %d %s' % (name, exe, exe.stat().st_size, digest(exe)[:16]))
                except OSError:
                    pass
        facts['main_processes'] = sorted(names)
        facts['main_binaries'] = sorted(binaries)
    except OSError:
        pass
    try:
        facts['fb0_holders'] = sorted('%s %d' % (name, pid) for pid, name in fb_holders(proc_root))
    except OSError:
        pass
    try:
        startup = (card / 'linux/user-startup.sh').read_text(errors='replace')
        facts['startup_hooks'] = sorted({word for word in ('misterzine-plex', 'zaparoo', 'tapto', 'remote.sh')
                                         if word in startup})
        facts['startup_sha256'] = hashlib.sha256(startup.encode()).hexdigest()[:16]
    except OSError:
        pass
    try:
        facts['framebuffer_mode'] = Path('/sys/module/MiSTer_fb/parameters/mode').read_text().strip()
    except OSError:
        pass
    try:
        cfg = json.loads((root / 'plexcrt.json').read_text())
        url = cfg.get('server_url', '')
        import urllib.parse
        u = urllib.parse.urlsplit(url)
        host = u.hostname or ''
        facts['server'] = {'scheme': u.scheme, 'port': u.port,
                           'kind': 'relay' if u.port == 8443 else 'plex.direct' if host.endswith('.plex.direct') else 'address',
                           'private_lan': bool(re.match(r'(10-|192-168-|172-(1[6-9]|2\d|3[01])-)', host)) if host.endswith('.plex.direct') else None,
                           'bitrate': cfg.get('bitrate'), 'progressive': cfg.get('progressive')}
    except (OSError, ValueError):
        pass
    facts['decoder_present'] = (root / 'ffmpeg').is_file() and os.access(root / 'ffmpeg', os.X_OK)
    try:
        state = read_state(root)
        folder = root / 'releases' / state['current']
        manifest = json.loads((folder / 'manifest.json').read_text())
        facts['payload_intact'] = all((folder / name).is_file() and digest(folder / name) == sha
                                      for name, sha in manifest['files'].items())
    except (OSError, ValueError, KeyError, TypeError):
        pass
    for name in ('plexfb.stat', 'plexplay.stat.err'):
        try:
            facts[name] = safe_log(Path('/tmp', name).read_text(errors='replace').strip()[:300], secrets)
        except OSError:
            pass
    return facts


def report_secrets(root):
    """Values that must never leave the card, read only to redact them."""
    secrets = []
    for path in (root / 'plexcrt.json', root / 'plexcrt.json.bak'):
        try:
            cfg = json.loads(path.read_text())
            secrets += [cfg.get(k, '') for k in ('token', 'server_token', 'server_url', 'server_name', 'client_id', 'account_name')]
        except (OSError, ValueError):
            pass
    return secrets


def report_version(root):
    try:
        state = read_state(root)
        manifest = json.loads((root / 'releases' / state['current'] / 'manifest.json').read_text())
        return str(manifest.get('version') or state['current'])[:40]
    except (OSError, ValueError, KeyError, TypeError):
        return 'unknown'


def log_tail(path, limit):
    """The last `limit` bytes of a log, minus a possibly cut first line."""
    with path.open('rb') as src:
        src.seek(max(0, path.stat().st_size - limit))
        data = src.read().decode('utf-8', errors='replace')
        if src.tell() > limit:
            data = data.partition('\n')[2]
    return data


def build_report(root, proc_root=Path('/proc'), tmp=Path('/tmp'), now=None):
    """The plain-text report the service takes: what the app, the launcher and
    the board say, redacted, within REPORT_MAX_BYTES. Longer logs lose their
    oldest lines first."""
    secrets = report_secrets(root)
    try:
        state = read_state(root)
    except (OSError, ValueError):
        # An installation that never completed still deserves a report.
        state = None
    facts = system_facts(root, secrets, proc_root)
    logs = [(name, tmp / name) for name in REPORT_LOGS]
    logs += [(name, root / 'updates' / name) for name in ('last-error.log', 'download-output.log', 'downloader.log')]
    logs = [(name, path) for name, path in logs if path.is_file()]
    created = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(now))
    limit = 64 * 1024
    while True:
        lines = [REPORT_MAGIC, 'App: MisterZine Plex Core ' + report_version(root), 'Created: ' + created, '', '== SYSTEM',
                 'kernel: ' + os.uname().release, 'release: ' + json.dumps(state)]
        for key, value in facts.items():
            lines.append(safe_log(key + ': ' + json.dumps(value, sort_keys=True), secrets))
        for name, path in logs:
            lines += ['', '== LOG ' + name + ' (' + time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(path.stat().st_mtime)) + ')']
            lines.append(safe_log(log_tail(path, limit), secrets).rstrip('\n'))
        text = '\n'.join(lines) + '\n'
        if len(text.encode()) <= REPORT_MAX_BYTES or limit <= 1024:
            return text
        limit //= 2


class ReportError(RuntimeError):
    """A failed upload, worded for the screen."""


def send_report(text, version='unknown', opener=None):
    """POST the report; the code the service filed it under."""
    if not REPORT_SERVICE:
        raise ReportError('Sending reports is switched off in this build.')
    import urllib.error
    req = urllib.request.Request(REPORT_SERVICE + '/reports', data=text.encode(), method='POST',
                                 headers={'Content-Type': 'text/plain; charset=utf-8',
                                          'User-Agent': 'MisterZine-Plex-Core/' + version})
    try:
        with (opener or urllib.request.urlopen)(req, timeout=20) as response:
            answer = response.read(4096)
    except urllib.error.HTTPError as exc:
        raise ReportError({413: 'The report is too large to send.', 429: 'Too many reports at once; try again in a minute.',
                           503: 'The report service is switched off.'}.get(exc.code, 'The report service answered HTTP %d.' % exc.code))
    except (urllib.error.URLError, OSError, ValueError):
        raise ReportError('The MiSTer seems to be offline, or the report service did not answer.')
    try:
        code = str(json.loads(answer.decode('utf-8', errors='replace')).get('code', ''))
    except (ValueError, AttributeError):
        code = ''
    if not re.fullmatch(r'[0-9A-HJKMNP-TV-Z]{4,8}', code):
        raise ReportError('The report service gave no code.')
    return code


def diagnostics(root, upload=False):
    """Write the report beside the app and, when asked, send it. Returns (path, code, problem):
    code is '' when the upload did not happen and problem then says why."""
    text = build_report(root)
    out = root / 'report.txt'
    atomic(out, text.encode())
    if not upload:
        return out, '', ''
    try:
        return out, send_report(text, report_version(root)), ''
    except ReportError as exc:
        return out, '', str(exc)


def stop_child(child):
    if child.poll() is None:
        child.terminate()
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()


def cleanup_player(folder):
    marker = ('MISTERZINE_PLEX_OWNER=' + str(folder / 'plexplay.py')).encode()
    owned = []
    for proc in Path('/proc').iterdir():
        if not proc.name.isdigit() or int(proc.name) == os.getpid():
            continue
        try:
            if marker in (proc / 'environ').read_bytes().split(b'\0'):
                os.kill(int(proc.name), signal.SIGTERM)
                owned.append(proc)
        except OSError:
            pass
    if owned:
        time.sleep(0.5)
    for proc in owned:
        try:
            if marker in (proc / 'environ').read_bytes().split(b'\0'):
                os.kill(int(proc.name), signal.SIGKILL)
        except OSError:
            pass


def core_file(root, folder=None):
    if folder is None:
        folder = root / 'releases' / read_state(root)['current']
    core = folder / 'MisterZine Plex Core.rbf'
    if not core.exists():
        core = folder / 'MisterZine Plex.rbf'
    return core


def launch_body(root, folder=None):
    core = core_file(root, folder)
    # MGL core paths are relative to MiSTer's storage root, not the MGL file.
    # Also support an isolated installation nested under that mount for testing.
    storage = Path('/media') / root.parts[2] if len(root.parts) > 3 and root.parts[1] == 'media' else root.parent
    relative = core.relative_to(storage).with_suffix('').as_posix()
    return '<mistergamedescription>\n  <rbf>' + escape(relative) + '</rbf>\n</mistergamedescription>\n'


def core_launch_entry(root, folder):
    # MiSTer anchors its core browser to the MGL's directory, even when the
    # bitstream lives elsewhere. Keep this internal entry at the card root.
    entry = root.parent / '.misterzine-plex-core.mgl'
    atomic(entry, launch_body(root, folder).encode())
    return entry


def prepare_framebuffer(parameters=Path('/sys/module/MiSTer_fb/parameters')):
    # MiSTer sizes fbdev for the selected HDMI/menu profile. The Plex core
    # instead uses a fixed frame ring in this reserved memory. Enlarge only
    # the Linux mapping; this does not change the core or HDMI scan timing.
    # MiSTer reapplies its own framebuffer mode when another core is loaded,
    # and can still do so just after this write, so the app and the presenter
    # check it again before they map the ring.
    mode = parameters / 'mode'
    values = [int(value) for value in mode.read_text().split()]
    if len(values) != 5:
        raise RuntimeError('Cannot read MiSTer framebuffer geometry')
    fmt, rb, width, height, stride = values
    if fmt != 8888 or stride * height < 0x7e0000:
        mode.write_text('8888 1 1920 1080 7680\n')
        return True
    return False


def mister_processes(proc_root=Path('/proc')):
    """PID and first argument (the loaded core) of each MiSTer main process."""
    found = {}
    for proc in proc_root.iterdir():
        if not proc.name.isdigit():
            continue
        try:
            # Forks such as Zaparoo Frontend's MiSTer_Zaparoo load cores too.
            if not (proc / 'comm').read_text().strip().startswith('MiSTer'):
                continue
            args = (proc / 'cmdline').read_bytes().split(b'\0')
        except OSError:
            continue
        found[int(proc.name)] = args[1] if len(args) > 1 else b''
    return found


def selected_core(core, proc_root=Path('/proc'), before=()):
    """True once a MiSTer process not listed in `before` runs the selected core.

    Loading a core restarts MiSTer main, so a new PID proves the switch
    happened even when the same core was already loaded."""
    return any(pid not in before and arg == str(core).encode()
               for pid, arg in mister_processes(proc_root).items())


def core_loaded(core, proc_root=Path('/proc'), corename=Path('/tmp/CORENAME'), wait=3):
    """True when the main-menu entry already loaded this core, so no reload is needed.

    The core name appears a moment before the restarted main process does,
    so give the process a little time rather than reloading over it."""
    deadline = time.monotonic() + wait
    while True:
        try:
            if corename.read_text().strip() != core.stem:
                return False
        except OSError:
            return False
        if selected_core(core, proc_root):
            return True
        if time.monotonic() > deadline:
            return False
        time.sleep(.05)


def recover_activation(root):
    journal = root / 'updates/activation.json'
    if not journal.exists() or os.environ.get('MISTERZINE_PLEX_READY_FILE'):
        return False
    recovery = root / 'updates/recovery'
    record = json.loads(journal.read_text())
    if not set(record['helpers']) <= set(HELPERS):
        raise ValueError('Invalid recovery information; use the external rollback entry')
    previous = json.loads((recovery / 'selection.json').read_text())
    for name in record['helpers']:
        atomic(root / name, (recovery / name).read_bytes())
    if previous is None:
        (root / 'active.json').unlink(missing_ok=True)
    else:
        write_json(root / 'active.json', previous)
    repair_menu_entry(root.parent)
    registration = (recovery / 'registration').read_bytes()
    dropin = root.parent / 'downloader_misterzine_plex.ini'
    if registration:
        atomic(dropin, registration)
    else:
        dropin.unlink(missing_ok=True)
    # Tell the Updates screen what happened before the evidence goes: a user who
    # rebooted mid-update otherwise finds the old version back with no reason.
    target = record.get('target')
    message = ('The update to ' + target if target else 'An update') + ' was interrupted'
    if previous:
        message += ' and ' + str(previous.get('current', 'the previous release')) + ' was restored.'
    else:
        message += '. No earlier release is installed; run MisterZine-Plex-Install to retry.'
    try:
        earlier = json.loads((root / 'updates/status.json').read_text())
        cause = earlier.get('message', '') if earlier.get('stage') in ('activating', 'failed') else ''
        if cause.startswith('Could not restart Plex:'):
            message = cause.split(' Restoring', 1)[0] + ' ' + message
    except (OSError, ValueError, AttributeError):
        pass
    write_json(root / 'updates/status.json', {'stage': 'failed', 'message': message, 'pid': os.getpid(), 'updated': time.time()})
    journal.unlink()
    print('Interrupted activation recovered. Previous selection restored.')
    return True


def rotate_log(path):
    """Keep the previous run's log as `.1`: a launch that bounces and starts
    again must not erase the evidence of its first attempt."""
    try:
        os.replace(path, str(path) + '.1')
    except OSError:
        pass


def trace(message):
    """One timestamped line of the launch story, into the menu-run log."""
    print(time.strftime('%H:%M:%S') + ' launch: ' + message, flush=True)


def fb_holders(proc_root=Path('/proc'), exclude=()):
    """Other processes with /dev/fb0 open: (pid, name). The frame ring lives in
    that memory, so anything else drawing there lands on the picture. MiSTer
    main itself is left out; it owns the device."""
    found = []
    for proc in proc_root.iterdir():
        if not proc.name.isdigit() or int(proc.name) in exclude or int(proc.name) == os.getpid():
            continue
        try:
            name = (proc / 'comm').read_bytes().decode('utf-8', errors='replace').strip()
            if name.startswith('MiSTer'):
                continue
            for fd in (proc / 'fd').iterdir():
                try:
                    if os.readlink(fd) == '/dev/fb0':
                        found.append((int(proc.name), name))
                        break
                except OSError:
                    continue
        except OSError:
            continue
    return found


class PausedHolders:
    """Stop other framebuffer users for the app's lifetime and let them go
    after. A Zaparoo Frontend left running beside the core kept painting its
    screen over the ring, which showed as a picture flashing to black."""
    def __init__(self, holders=()):
        self.paused = []
        self.pause(holders)

    def pause(self, holders):
        for pid, name in holders:
            # Listed before the signal, so an interrupt here cannot leave a
            # stopped process that nothing resumes.
            self.paused.append((pid, name))
            try:
                os.kill(pid, signal.SIGSTOP)
                trace('paused %s (pid %d): it holds /dev/fb0 and would draw over the picture' % (name, pid))
            except OSError:
                self.paused.pop()

    def resume(self):
        for pid, name in self.paused:
            try:
                os.kill(pid, signal.SIGCONT)
                trace('resumed %s (pid %d)' % (name, pid))
            except OSError:
                pass
        self.paused = []


KDSETMODE, KDGETMODE, KD_TEXT, KD_GRAPHICS = 0x4B3A, 0x4B3B, 0, 1


def active_console(sysfs=Path('/sys/class/tty/tty0/active')):
    """The foreground virtual console as a stable path such as /dev/tty2, or
    None when it cannot be named: /dev/tty0 follows the foreground, so it
    could not be restored reliably."""
    try:
        name = sysfs.read_text().strip()
    except OSError:
        return None
    return '/dev/' + name if re.fullmatch(r'tty[1-9][0-9]*', name) else None


class GraphicsConsole:
    """Keep the Linux console out of the framebuffer while the app runs.

    The ring lives in the framebuffer the console draws into. Zaparoo's MiSTer
    main forces fb_terminal on and, when its frontend exits, leaves the console
    in text mode with the cursor shown; the kernel then blinks that cursor over
    the ring's header at the top-left, several times a second, and every blink
    blanks the picture. Graphics mode, which MiSTer main normally keeps, stops
    the console drawing. This is the only place that changes a console's mode:
    it checks at launch and while the app runs, remembers each console it
    changed by its own device path, and puts each one back afterwards."""
    def __init__(self, console=active_console, ioctl=None):
        import fcntl
        self.ioctl = ioctl or fcntl.ioctl
        self.console = console
        self.changed = {}      # console device -> mode to put back
        self.told = 0

    def check(self, first=False):
        path = self.console()
        if path is None:
            if first:
                trace('console unknown; left as it is')
            return
        name = os.path.basename(path)
        try:
            fd = os.open(path, os.O_RDWR | os.O_NOCTTY)
        except OSError as exc:
            if first:
                trace('console %s mode unknown (%s)' % (name, exc.__class__.__name__))
            return
        try:
            mode = bytearray(4)
            self.ioctl(fd, KDGETMODE, mode)
            if mode[0] == KD_TEXT:
                # Recorded before the switch, so a stop between the two still
                # puts it back (restoring a mode it already has is harmless).
                self.changed.setdefault(path, KD_TEXT)
                self.ioctl(fd, KDSETMODE, KD_GRAPHICS)
                if self.told < 5:
                    self.told += 1
                    trace('console %s was in text mode and would draw over the picture; graphics mode while Plex runs' % name)
            elif first:
                trace('console %s in graphics mode' % name)
        except OSError as exc:
            if first:
                trace('console %s mode unknown (%s)' % (name, exc.__class__.__name__))
        finally:
            os.close(fd)

    def release(self):
        for path, mode in self.changed.items():
            try:
                fd = os.open(path, os.O_RDWR | os.O_NOCTTY)
                try:
                    self.ioctl(fd, KDSETMODE, mode)
                finally:
                    os.close(fd)
                trace('console %s returned to text mode' % os.path.basename(path))
            except OSError:
                pass
        self.changed = {}


@contextlib.contextmanager
def screen_to_ourselves(holders=fb_holders, console=GraphicsConsole):
    """Pause other framebuffer users and keep the console out of the
    framebuffer for the block, and undo both however the block ends, even
    when the app never started. A SIGTERM during the undo is held off so the
    undo always completes."""
    previous = signal.getsignal(signal.SIGTERM)
    paused, guard = PausedHolders(), None
    try:
        paused.pause(holders())
        guard = console()          # no side effects until check()
        guard.check(first=True)
        yield guard
    finally:
        with contextlib.suppress(ValueError):   # only the main thread may
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
        try:
            if guard is not None:
                guard.release()
        finally:
            paused.resume()
            with contextlib.suppress(ValueError, TypeError):
                signal.signal(signal.SIGTERM, previous)


def lost_core_status(mem, recheck=0.1, sleep=time.sleep):
    """The ring's status word when it no longer carries the Plex core's
    signature, else None. A framebuffer mode write zeroes it until the core's
    next vsync, so a bad reading counts only if it is still bad a few fields
    later."""
    for attempt in range(2):
        status = struct.unpack_from('<I', mem, 0x6c)[0]
        if status & 0xfffffff0 == 0x56500000:
            return None
        if attempt == 0:
            sleep(recheck)
    return status


def fb_mode(parameters=Path('/sys/module/MiSTer_fb/parameters')):
    try:
        return (parameters / 'mode').read_text().strip()
    except OSError:
        return '?'


def run(root):
    recover_activation(root)
    state = read_state(root)
    folder = root / 'releases' / state['current']
    args = [str(folder / 'plexcrt'), '-config', str(root / 'plexcrt.json'),
            '-cache', str(root / 'cache'), '-ffmpeg', str(root / 'ffmpeg')]
    subprocess.run(args + ['-check'], check=True)
    core = core_file(root, folder)
    try:
        corename = Path('/tmp/CORENAME').read_text().strip()
    except OSError:
        corename = '?'
    mains = mister_processes()
    trace('release %s, CORENAME %r, main %s' % (state['current'], corename,
          ', '.join(sorted('%d:%s' % (pid, arg.decode(errors='replace')) for pid, arg in mains.items())) or 'none'))
    started = time.monotonic()
    if core_loaded(core):
        trace('core already loaded by the menu entry (%.1f s)' % (time.monotonic() - started))
    else:
        trace('core not detected after %.1f s; loading it' % (time.monotonic() - started))
        entry = core_launch_entry(root, folder)
        before = mister_processes()
        with open('/dev/MiSTer_cmd', 'w') as cmd:
            cmd.write('load_core ' + str(entry) + '\n')
        # No fixed delay: MiSTer restarts its main process to load a core, so a
        # fresh PID running this core is the signal, however quick or slow it is.
        deadline = time.monotonic() + 10
        while not selected_core(core, before=before):
            if time.monotonic() > deadline:
                trace('no new main process running the core within 10 s')
                raise RuntimeError('MiSTer did not load the selected RBF. Reinstall the matching package.')
            time.sleep(.05)
        trace('core loaded by a new main process (%.1f s)' % (time.monotonic() - started))
    # Keep a read-only watch on the core. Returning to Menu stops this app too.
    with open('/dev/fb0', 'rb') as fb, mmap.mmap(fb.fileno(), 4096, access=mmap.ACCESS_READ) as mem:
        last = struct.unpack_from('<I', mem, 0x40)[0]
        waited = time.monotonic()
        deadline = waited + 8
        while time.monotonic() < deadline:
            time.sleep(0.1)
            field = struct.unpack_from('<I', mem, 0x40)[0]
            status = struct.unpack_from('<I', mem, 0x6c)[0]
            if status & 0xfffffff0 == 0x56500000 and field != last:
                break
            last = field
        else:
            trace('core status %08x, field %d: no live Plex core within 8 s' % (status, field))
            raise RuntimeError('Plex core did not start. Reinstall the matching package and try again.')
        trace('core running (%.1f s), framebuffer mode %s' % (time.monotonic() - waited, fb_mode()))
        if prepare_framebuffer():
            trace('framebuffer mode written, now %s' % fb_mode())
        changed = time.monotonic()
        rotate_log('/tmp/misterzine-plex.log')
        def interrupted(signum, frame):
            raise KeyboardInterrupt()
        # Before anything is paused or switched, so a stop at any point unwinds.
        signal.signal(signal.SIGTERM, interrupted)
        with screen_to_ourselves() as screen, open('/tmp/misterzine-plex.log', 'wb') as log:
            child = None
            try:
                child = subprocess.Popen(args, stdout=log, stderr=log)
                trace('app started, pid %d' % child.pid)
                ticks = 0
                while child.poll() is None:
                    time.sleep(0.5)
                    ticks += 1
                    if ticks % 2 == 0:
                        screen.check()
                    lost = lost_core_status(mem)
                    if lost is not None:
                        trace('core status changed to %08x; stopping the app' % lost)
                        break
                    field = struct.unpack_from('<I', mem, 0x40)[0]
                    if field != last:
                        last, changed = field, time.monotonic()
                    elif time.monotonic() - changed > 2:
                        trace('field counter stalled at %d for 2 s; stopping the app' % field)
                        break
                if child.poll() is not None:
                    trace('app exited with status %d after %.0f s' % (child.returncode, time.monotonic() - changed))
                if child.poll() not in (None, 0):
                    raise RuntimeError('App could not start. Run MisterZine-Plex-Diagnostics and check the report.')
            finally:
                with contextlib.suppress(ValueError):
                    signal.signal(signal.SIGTERM, signal.SIG_IGN)   # finish stopping the app
                if child is not None:
                    stop_child(child)
                cleanup_player(folder)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['install', 'run', 'rollback', 'remove', 'diagnostics', 'report'])
    parser.add_argument('--card', type=Path, default=Path('/media/fat'))
    parser.add_argument('--package', type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument('--decoder-archive', type=Path)
    parser.add_argument('--no-upload', action='store_true', help='write the report without sending it')
    args = parser.parse_args()
    root = args.card / 'misterzine-plex'
    try:
        if args.action in ('diagnostics', 'report'):
            # Reading logs needs no lock, so a report can be sent from the running app.
            out, code, problem = diagnostics(root, upload=not args.no_upload)
            if args.action == 'report':
                # Lines the app parses.
                print('saved: ' + str(out))
                print('code: ' + code if code else 'error: ' + problem, flush=True)
                return 0
            print('Report saved as ' + str(out))
            if code:
                print('Report sent. Post this code where you asked for help: ' + code)
            elif problem:
                print('Not sent: ' + problem + ' You can send the saved file instead.')
            print('It can name media titles and playback details. Account files and tokens are never included.')
            return 0 if code or args.no_upload else 1
        with locked(root):
            if args.action == 'install':
                install(args.card, args.package, args.decoder_archive)
                prune_releases(root)
            elif args.action == 'run':
                run(root)
            elif args.action == 'rollback':
                rollback(root)
            elif args.action == 'remove':
                remove(args.card)
    except KeyboardInterrupt:
        return 0
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError, tarfile.TarError) as exc:
        # Network exceptions can contain URLs. Never echo arbitrary exception text.
        if isinstance(exc, (ValueError, RuntimeError)):
            print('MisterZine Plex Core: ' + str(exc), file=sys.stderr)
        else:
            print('MisterZine Plex Core: operation failed (' + type(exc).__name__ + '). Check card space, network and package files.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
