#!/usr/bin/env python3
"""Install and launch a self-contained MisterZine Plex Core release.

Only named files are replaced. Old releases, account settings and caches are
preserved. This module also runs against a temporary card root in its tests.
"""
import argparse
import base64
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
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from xml.sax.saxutils import escape

PAYLOAD = {'plexcrt', 'jfplay', 'ffmpeg', 'PlexH264.rbf'}
# The payload of the releases before the H.264 core (beta.27 and earlier),
# which a rollback right after the update to this one must still accept.
LEGACY_PAYLOAD = {'plexcrt', 'plexplay.py', 'plexfb', 'MisterZine Plex Core.rbf'}
# What those releases kept beside the release folders: the FFmpeg they
# downloaded (run passed it to the app), its archive, stamp and notices, and
# their source bundle. Removed once no such release is installed.
LEGACY_FILES = ('ffmpeg', 'decoder.json', 'decoder-notices', 'ffmpeg-7.0.2-armhf-static.tar.xz',
                'corresponding-source.zip')
SCRIPTS = {'Rollback': 'rollback', 'Diagnostics': 'diagnostics', 'Uninstall': 'uninstall'}
HELPERS = ('manager.py', 'update_service.py', 'catalogue.py', 'menu_launcher.py')


def installer_script(channel):
    """The installer a user puts in Scripts for a channel (build_distribution.py
    names them). Install does not add one, so messages name the downloaded one."""
    return 'MisterZine-Plex-Install-' + ('Public' if channel == 'public' else 'Beta')
BOOT_START = '# BEGIN MISTERZINE PLEX LAUNCHER'
BOOT_END = '# END MISTERZINE PLEX LAUNCHER'
# Reports go to the same service the MisterZine Frontend uses: a plain-text
# upload answered with a short code, kept 30 days, nothing stored about the
# sender. '' switches sending off.
REPORT_SERVICE = 'https://api.misterzine.fyi'
REPORT_MAGIC = 'MisterZine report v1'
REPORT_MAX_BYTES = 256 * 1024
REPORT_LOGS = ('misterzine-plex-menu-run.log', 'misterzine-plex-menu-run.log.1', 'misterzine-plex-update-run.log',
               'misterzine-plex-update-run.log.1', 'misterzine-plex.log', 'misterzine-plex.log.1',
               'misterzine-plex-menu.log', 'misterzine-plex-maintain.log', 'jfplay.log')

# The code running now. Entry checks stand down once the installed manager
# differs from it (a recovery or rollback put another release's in place).
try:
    SELF_DIGEST = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
except OSError:                 # imported from the installer's archive
    SELF_DIGEST = None


LEGACY_ENTRY = b'<mistergamedescription>\n  <rbf>menu</rbf>\n  <setname>misterzine-plex</setname>\n</mistergamedescription>\n'


def legacy_watcher(root):
    """True when the installed watcher only understands the pre-beta.4 menu bounce."""
    try:
        return b'SELECTIONS' not in (root / 'menu_launcher.py').read_bytes()
    except OSError:
        return False


# The main-menu entry. MiSTer lists it by its file name; releases before the
# H.264 core named it after the core, MisterZine Plex Core.
MENU_ENTRY = 'MisterZine Plex.mgl'
OLD_MENU_ENTRY = 'MisterZine Plex Core.mgl'


def menu_entry_names(root):
    """(the entry to write, the one to remove). A rollback to a release from
    before the new name restores a manager that writes the old name at every
    boot and knows nothing of the new one; that release keeps its old name,
    so the app is never listed twice."""
    try:
        manager = (root / 'manager.py').read_bytes()
    except OSError:
        manager = b''
    if OLD_MENU_ENTRY.encode() in manager and MENU_ENTRY.encode() not in manager:
        return OLD_MENU_ENTRY, MENU_ENTRY
    return MENU_ENTRY, OLD_MENU_ENTRY


def repair_menu_entry(card):
    """Point the main-menu entry at the selected release, in the form the
    installed watcher understands. Called after any change of selection.
    With no release selected (a failed first install), both the menu entry
    and the Zaparoo entry go."""
    root = card / 'misterzine-plex'
    entries = [card / name for name in (MENU_ENTRY, OLD_MENU_ENTRY)]
    if not (root / 'active.json').is_file():
        for entry in entries:
            entry.unlink(missing_ok=True)
        zaparoo_entry(card, enable=False)
        return
    if not any(entry.exists() for entry in entries) or not (root / 'menu_launcher.py').is_file():
        return
    menu_entries(card)


ZAPAROO_ENTRY = 'misterzine-plex.toml'

# Zaparoo's UUIDv5 namespace + "mister_core:misterzine-plex", encoded as
# lowercase base32. This is the same on every device; do not rename the launcher.
ZAPAROO_SYSTEM = '54pxmxbaxzkp3jpkpj3r7gw76m'
ZAPAROO_ICON = 'misterzine-plex'
ZAPAROO_ART_STATE = 'zaparoo-art.json'
# The packager embeds the existing PNG here, keeping the four-helper package
# format compatible with older updaters. Source checkouts read the source asset.
ZAPAROO_LOGO = ''


def zaparoo_logo():
    if ZAPAROO_LOGO:
        return base64.b64decode(ZAPAROO_LOGO, validate=True)
    return (Path(__file__).resolve().parent.parent /
            'app/internal/ui/assets/misterzine-stacked-v1.png').read_bytes()


def frontend_tables(text):
    """Conservative, lossless editor for Frontend's generated TOML subset.

    Python 3.9 on MiSTer has no TOML parser. Never guess around multiline
    strings, dotted keys or unfamiliar headers: leave such configs untouched.
    Values we do not use (arrays, booleans, etc.) remain byte-for-byte intact.
    """
    if '\"\"\"' in text or "'''" in text:
        raise ValueError('Multiline Frontend config left unchanged')
    tables = []
    current = {'header': '', 'start': 0, 'values': {}}
    lines = text.splitlines(keepends=True)
    for index, line in enumerate(lines):
        stripped = line.strip()
        if not stripped or stripped.startswith('#'):
            continue
        if stripped.startswith('['):
            match = re.fullmatch(r'(\[\[?[A-Za-z0-9_.-]+\]\]?)\s*(?:#.*)?', stripped)
            if not match or match[1].count('[') != match[1].count(']'):
                raise ValueError('Unfamiliar Frontend table left unchanged')
            current['end'] = index
            tables.append(current)
            current = {'header': match[1], 'start': index + 1, 'values': {}}
            continue
        match = re.fullmatch(r'([A-Za-z0-9_-]+|"[^"\\]+"|\'[^\']+\')\s*=\s*(.*)', stripped)
        if not match:
            raise ValueError('Unfamiliar Frontend key left unchanged')
        key, raw = match[1].strip('\"\''), match[2]
        if key in current['values']:
            raise ValueError('Duplicate Frontend key left unchanged')
        value = None
        string = re.fullmatch(r'("(?:[^"\\]|\\.)*"|\'[^\']*\')\s*(?:#.*)?', raw)
        if string:
            value = json.loads(string[1]) if string[1].startswith('"') else string[1][1:-1]
        current['values'][key] = (index, value)
    current['end'] = len(lines)
    tables.append(current)
    for header in ('[custom]', '[custom.system_names]'):
        if sum(t['header'] == header for t in tables) > 1:
            raise ValueError('Duplicate Frontend table left unchanged')
    return lines, tables


def zaparoo_art(card, enable=True):
    """Supply defaults, never replace personal art or rearrange Hub tiles.

    Record ownership before writes, so retries and removal only touch our
    unchanged files/fields. No Frontend restart and no MiSTer.ini changes.
    """
    root, zaparoo = card / 'misterzine-plex', card / 'zaparoo'
    state_path = root / ZAPAROO_ART_STATE
    config = zaparoo / 'frontend.toml'
    def safe(path):
        return path.resolve().is_relative_to(card.resolve()) and not any(
            p.is_symlink() for p in (path, *path.parents) if p != card.parent)
    if not all(safe(p) for p in (state_path, zaparoo, config)):
        return 'unsafe path'
    state = json.loads(state_path.read_text()) if state_path.exists() else {'files': {}}
    before = config.read_bytes() if config.exists() else b''
    try:
        lines, tables = frontend_tables(before.decode('utf-8'))
    except (ValueError, UnicodeError):
        return 'custom config preserved'
    custom = next((t['values'] for t in tables if t['header'] == '[custom]'), {})
    art = zaparoo / 'custom'
    if 'dir' in custom:
        directory = custom['dir'][1]
        if not directory:
            return 'custom directory preserved'
        art = Path(directory)
        if not art.is_absolute():
            return 'custom directory preserved'
    if not safe(art):
        return 'custom directory preserved'
    edits, additions, changed = {}, {}, False
    newline = '\r\n' if b'\r\n' in before else '\n'
    def append_at(index, value):
        additions[index] = additions.get(index, '') + value + newline
    def value(table, key):
        return table['values'].get(key, (None, None))[1]
    names = next((t for t in tables if t['header'] == '[custom.system_names]'), None)
    pins = [t for t in tables if t['header'] == '[[hub.items]]'
            and value(t, 'type') == 'system' and value(t, 'id') == ZAPAROO_SYSTEM]
    def save_state():
        write_if_changed(state_path, (json.dumps(state, sort_keys=True) + '\n').encode())
    def image_default(namespace, ident, data):
        folder = art / namespace
        if not safe(folder):
            return None
        candidates = [p for p in folder.iterdir() if p.stem.lower() == ident.lower()
                      and p.suffix.lower() in ('.png', '.jpg', '.jpeg', '.webp', '.bmp', '.svg')] if folder.is_dir() else []
        target = folder / (ident + '.png')
        relative = target.relative_to(card).as_posix()
        owned = state['files'].get(relative)
        if candidates and (candidates != [target] or not safe(target)
                           or not owned or digest(target) != owned):
            return None
        state['files'][relative] = hashlib.sha256(data).hexdigest()
        save_state()
        return write_if_changed(target, data)
    if enable:
        data = zaparoo_logo()
        system = image_default('systems', ZAPAROO_SYSTEM, data)
        changed |= bool(system)
        # A personal system image is also a deliberate choice: do not add a
        # different default logo to that person's pinned tile.
        if system is not None and any('icon' not in pin['values'] or
                                     state.get('hub') and value(pin, 'icon') == ZAPAROO_ICON
                                     for pin in pins):
            hub = image_default('hub', ZAPAROO_ICON, data)
            changed |= bool(hub)
            if hub is not None:
                for pin in pins:
                    if 'icon' not in pin['values']:
                        state['hub'] = True
                        append_at(pin['start'], 'icon = ' + json.dumps(ZAPAROO_ICON))
        existing_names = names['values'] if names else {}
        if not any(re.sub('[^a-z0-9]', '', key.lower()) == ZAPAROO_SYSTEM for key in existing_names):
            state['name'] = True
            if names:
                append_at(names['start'], ZAPAROO_SYSTEM + ' = "MisterZine Plex"')
            else:
                append_at(len(lines), '\n[custom.system_names]\n' + ZAPAROO_SYSTEM + ' = "MisterZine Plex"')
        save_state()
    else:
        hub_owned = False
        for relative, sha in state['files'].items():
            target = card / relative
            if (target.parent.name, target.name) not in (
                    ('systems', ZAPAROO_SYSTEM + '.png'), ('hub', ZAPAROO_ICON + '.png')):
                continue
            if safe(target) and target.is_file() and digest(target) == sha:
                target.unlink()
                changed = True
                if target.name == ZAPAROO_ICON + '.png':
                    hub_owned = True
            elif safe(target) and not target.exists() and target.name == ZAPAROO_ICON + '.png':
                hub_owned = True
        if state.get('hub') and hub_owned:
            for pin in pins:
                if value(pin, 'icon') == ZAPAROO_ICON:
                    edits[pin['values']['icon'][0]] = ''
        if state.get('name') and names and value(names, ZAPAROO_SYSTEM) == 'MisterZine Plex':
            edits[names['values'][ZAPAROO_SYSTEM][0]] = ''
    after = ''.join(additions.get(i, '') + edits.get(i, line) for i, line in enumerate(lines))
    if len(lines) in additions:
        after += ('\n' if after and not after.endswith('\n') else '') + additions[len(lines)]
    if after.encode() != before:
        # Frontend also saves this file. Do not knowingly replace a newer layout.
        if (config.read_bytes() if config.exists() else b'') != before:
            return 'config changed; retry next boot'
        atomic(config, after.encode())
        changed = True
    if not enable:
        state_path.unlink(missing_ok=True)
    return 'updated; restart Frontend' if changed else 'current'


def maintain_zaparoo_art(card, enable=True):
    """Artwork is optional: a customized or unwritable config cannot fail an update."""
    root = card / 'misterzine-plex'
    try:
        # Rollback has already restored the selected manager before this call.
        supported = b'def zaparoo_art(' in (root / 'manager.py').read_bytes()
        outcome = zaparoo_art(card, enable and supported)
    except (OSError, ValueError, TypeError, KeyError) as exc:
        outcome = type(exc).__name__
    note(root, zaparoo_art=outcome)


ZAPAROO_API = 'http://localhost:7497/api/v0.1'


def zaparoo_version(timeout=1):
    """Version and platform of the running Zaparoo Core, asked through its
    local API, or None when nothing answers there."""
    import uuid
    body = json.dumps({'jsonrpc': '2.0', 'id': str(uuid.uuid4()), 'method': 'version'}).encode()
    req = urllib.request.Request(ZAPAROO_API, data=body, method='POST', headers={'Content-Type': 'application/json'})
    try:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(req, timeout=timeout) as response:
            result = json.loads(response.read(4096).decode('utf-8', errors='replace'))['result']
            return {'version': str(result.get('version', ''))[:40], 'platform': str(result.get('platform', ''))[:40]}
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return None


def reload_zaparoo(card):
    """Ask a running Zaparoo service to re-read its launchers, so the entry
    appears without a reboot. No wait beyond 15 s. A reload that did not
    happen stays pending for the next check to retry: a service that is
    stopped refuses at once (a fraction of a second), and one that is starting
    or busy may already have read the old launchers."""
    script = card / 'Scripts/zaparoo.sh'
    if not script.is_file():
        outcome = 'no script'
    else:
        # Recorded first: a check stopped mid-reload leaves the retry due.
        note(card / 'misterzine-plex', zaparoo_pending=True)
        try:
            done = subprocess.run([str(script), '-reload'], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL, timeout=15)
            outcome = 'ok' if done.returncode == 0 else 'exit %d' % done.returncode
        except subprocess.TimeoutExpired:
            outcome = 'timeout'
        except (OSError, subprocess.SubprocessError) as exc:
            outcome = type(exc).__name__
    note(card / 'misterzine-plex', zaparoo_reload=outcome, zaparoo_pending=outcome not in ('ok', 'no script'))
    return outcome


def refresh_zaparoo(card, wait=0):
    """Reload Zaparoo's launchers. At boot its service starts alongside this
    check and may have read them just before the entry was written, so for up
    to `wait` seconds keep trying once its API answers."""
    outcome = reload_zaparoo(card)
    deadline = time.monotonic() + wait
    while outcome not in ('ok', 'no script') and time.monotonic() < deadline:
        time.sleep(2)
        if zaparoo_version() is not None:
            outcome = reload_zaparoo(card)
    return outcome


def maintains_zaparoo(root):
    """True when the installed manager keeps the Zaparoo entry up to date and
    removes it on uninstall. After a rollback to a release from before that,
    the restored manager would leave a stale entry behind."""
    try:
        return b'def zaparoo_entry(' in (root / 'manager.py').read_bytes()
    except OSError:
        return False


def zaparoo_body(root, folder=None):
    load = core_file(root, folder).relative_to(root.parent).with_suffix('').as_posix()
    return ('# MisterZine Plex in Zaparoo\'s Other list. Written by the Plex installer and\n'
            '# rewritten on every update; do not edit. Uninstalling Plex removes it.\n'
            '[[launchers.custom]]\n'
            'id = "misterzine-plex"\n'
            'kind = "virtual_system"\n'
            'backend = "mister_core"\n'
            'name = "MisterZine Plex"\n'
            'category = "Other"\n'
            'load_path = ' + json.dumps(load) + '\n').encode()


def zaparoo_entry(card, enable=True, folder=None, reload=None):
    """List Plex under Other in Zaparoo, pointing at the selected release.

    Zaparoo does not scan _Other; its Other list is its built-ins plus custom
    launchers, which it also reads from files in zaparoo/launchers. This file
    is ours alone, rewritten whenever the selected release changes and removed
    on uninstall. Nothing is written when Zaparoo is not installed. A pre-beta.4
    watcher cannot start the app from a direct core load, so none is listed
    for one. A launcher with the same id in Zaparoo's own config.toml wins.
    The frontend's system list reads this after a reload; no media database
    update is needed (that only indexes games).

    Returns what happened: 'written', 'current', 'removed', 'none',
    'no zaparoo' or 'symlink'."""
    reload = reload or reload_zaparoo
    root = card / 'misterzine-plex'
    zaparoo = card / 'zaparoo'
    launchers = zaparoo / 'launchers'
    path = launchers / ZAPAROO_ENTRY
    for place in (zaparoo, launchers, path):
        if place.is_symlink():
            return 'symlink'
    if (not enable or legacy_watcher(root) or not maintains_zaparoo(root)
            or not (root / 'active.json').is_file() and folder is None):
        if (root / ZAPAROO_ART_STATE).exists():
            maintain_zaparoo_art(card, enable=False)
        if path.is_file():
            path.unlink()
            reload(card)
            return 'removed'
        return 'none'
    if not zaparoo.is_dir():
        return 'no zaparoo'
    maintain_zaparoo_art(card)
    body = zaparoo_body(root, folder)
    try:
        if path.read_bytes() == body:
            return 'current'
    except OSError:
        pass
    launchers.mkdir(exist_ok=True)
    atomic(path, body)
    reload(card)
    return 'written'


def startup_file(card):
    startup = card / 'linux/user-startup.sh'
    if startup.is_symlink() or not startup.resolve().is_relative_to(card.resolve()):
        raise ValueError('Startup file must stay on the selected card')
    return startup


def startup_text(card, text, enable):
    """user-startup.sh without our block, and with it first when enabled."""
    root = card / 'misterzine-plex'
    text = re.sub(re.escape(BOOT_START) + r'\n.*?' + re.escape(BOOT_END) + r'\n?', '', text, flags=re.S)
    # Migrate the exact earlier development hook without touching other apps.
    legacy = '[ -f /media/fat/misterzine-plex/menu_launcher.py ] && setsid python3 /media/fat/misterzine-plex/menu_launcher.py > /tmp/misterzine-plex-menu.log 2>&1 < /dev/null &'
    text = '\n'.join(line for line in text.split('\n') if line not in (legacy, '# MisterZine Plex main-menu launcher'))
    if enable:
        command = 'setsid python3 ' + shlex.quote(str(root / 'menu_launcher.py')) + ' --card ' + shlex.quote(str(card))
        block = BOOT_START + '\n' + command + ' >/tmp/misterzine-plex-menu.log 2>&1 </dev/null &\n' + BOOT_END + '\n'
        # Put the hook ahead of any existing early exit in user-startup.sh.
        first, _, rest = text.partition('\n')
        text = first + '\n' + block + rest if first.startswith('#!') else '#!/bin/bash\n' + block + text
    return text


def startup_hook(card, enable=True):
    """Add or remove the boot hook that starts the watcher. Other tools edit
    this file too: nothing is written when it is already right, and a change
    made while the new text was worked out is read again, not overwritten."""
    startup = startup_file(card)
    for _ in range(3):
        before = startup.read_bytes() if startup.exists() else None
        if before is None and not enable:
            return False
        text = before.decode('utf-8', 'surrogateescape') if before is not None else '#!/bin/bash\n'
        data = startup_text(card, text, enable).encode('utf-8', 'surrogateescape')
        if data == before:
            return False
        if (startup.read_bytes() if startup.exists() else None) == before:
            atomic(startup, data)
            startup.chmod(0o755)
            return True
    raise RuntimeError('user-startup.sh kept changing')


def menu_entry_file(card, enable=True, folder=None):
    """Write the main-menu entry, or remove it. The entry under its other
    name (menu_entry_names) goes either way. True when a file changed."""
    root = card / 'misterzine-plex'
    name, other = menu_entry_names(root)
    entry = card / name
    removed = (card / other).exists()
    (card / other).unlink(missing_ok=True)
    if not enable:
        entry.unlink(missing_ok=True)
        return False
    # Load the core directly. Bouncing through the menu core with a
    # setname never reaches the watcher under forked main binaries
    # (Zaparoo Frontend), which keep reporting the menu as the core.
    # A pre-beta.4 watcher only knows the bounce, so keep it for one.
    body = LEGACY_ENTRY if legacy_watcher(root) else launch_body(root, folder).encode()
    return write_if_changed(entry, body) or removed


def menu_entries(card, enable=True, folder=None):
    startup_file(card)          # refuse a startup file off the card before anything changes
    menu_entry_file(card, enable, folder)
    startup_hook(card, enable)
    zaparoo_entry(card, enable, folder)


def upkeep_blocked(root):
    """Why the entries must be left alone now, or None."""
    if not (root / 'active.json').is_file() or not (root / 'menu_launcher.py').is_file():
        return 'not installed'
    if (root / 'updates/activation.json').exists():
        return 'update in progress'
    if any((root.parent / 'Scripts').glob('MisterZine-Plex-*.sh.disabled')):
        return 'entries switched off'           # manager.py remove
    try:
        read_state(root)
        if SELF_DIGEST is None or digest(root / 'manager.py') != SELF_DIGEST:
            # A recovery or rollback put another release's manager in place.
            return 'another manager installed'
    except (OSError, ValueError):
        return 'installation unreadable'
    return None


def reconcile(card):
    """Put this release's own entries on the card right: the main-menu entry,
    the Scripts entries and the Zaparoo entry.

    An in-app update is installed by the previous release's code, which writes
    its own idea of these, and nothing else checks them later (Zaparoo can
    arrive after Plex). So each release checks them itself at boot and once an
    update to it has committed. The boot hook is left to install and
    uninstall: other tools edit user-startup.sh too, and without the hook
    nothing would run this check anyway. Each piece is optional: a failure is
    recorded and the rest goes on. The caller holds the manager lock. Returns
    whether Zaparoo needs to reload its launchers."""
    root = card / 'misterzine-plex'
    reason = upkeep_blocked(root)
    if reason:
        note(root, skipped=reason)
        return False
    wrote, errors, zaparoo = [], {}, 'unknown'
    for name, piece in (('menu entry', menu_entry_file), ('scripts', wrappers)):
        try:
            if piece(card):
                wrote.append(name)
        except Exception as exc:
            errors[name] = type(exc).__name__
    try:
        zaparoo = zaparoo_entry(card, reload=lambda card: None)
    except Exception as exc:
        errors['zaparoo'] = type(exc).__name__
    changed = zaparoo in ('written', 'removed')
    if changed:
        wrote.append('zaparoo entry')
    fields = {'release': read_state(root).get('current'), 'skipped': None, 'errors': errors,
              'zaparoo_entry': {'written': 'current', 'removed': 'none'}.get(zaparoo, zaparoo)}
    if changed:
        fields['zaparoo_pending'] = True        # until a reload succeeds, whatever stops this process
    if wrote:
        fields.update(repaired=wrote, repaired_at=int(time.time()))
        print(time.strftime('%H:%M:%S') + ' upkeep: put right: ' + ', '.join(wrote), flush=True)
    if errors:
        print(time.strftime('%H:%M:%S') + ' upkeep: failed: ' + ', '.join(k + ' (' + v + ')' for k, v in errors.items()), flush=True)
    note(root, **fields)
    return changed


@contextlib.contextmanager
def no_update_running(root):
    """True for the block while no update is under way, holding the update
    worker's lock shared so none starts meanwhile; False while one runs or an
    interrupted one awaits recovery. Never waits."""
    import fcntl
    try:
        lock = (root / 'updates/worker.lock').open('a')
    except FileNotFoundError:           # no updates folder: no update ever ran
        yield not (root / 'updates/activation.json').exists()
        return
    with lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
        except BlockingIOError:
            yield False
            return
        yield not (root / 'updates/activation.json').exists()


def reconcile_when_settled(card, release=None):
    """(settled, reload): reconcile unless an update is under way. With a
    release, only while that release is still the selected one."""
    root = card / 'misterzine-plex'
    with no_update_running(root) as clear:
        if not clear:
            return False, False
        if release is not None and read_state(root).get('current') != release:
            return True, False
        return True, reconcile(card)


def upkeep_after_start(root, release, timeout=600, pause=.5):
    """Reconcile from a launched release once no update is under way.

    When an update starts this release to check it, the previous release's
    updater holds its lock until it has committed. A start that fails is
    stopped before that and the previous release put back, so a release that
    is being undone never writes its entries. An ordinary launch goes ahead
    at once. Runs beside the launch and never holds it up."""
    card = root.parent
    try:
        deadline = time.monotonic() + timeout
        while True:
            settled, reload = reconcile_when_settled(card, release)
            if settled:
                break
            if time.monotonic() > deadline:
                return
            time.sleep(pause)
        if reload or noted(root).get('zaparoo_pending'):
            refresh_zaparoo(card)
    except Exception as exc:
        note(root, errors={'upkeep': type(exc).__name__})


def maintain(card, wait=60, released=lambda: None):
    """The boot check (manager.py maintain, started by the watcher).

    The update lock is checked first: an update holds it from before it
    installs until its start check is done, and the manager lock must stay
    free for the release that start check launches. With no update running,
    the manager lock keeps an install, rollback or the app out while the
    entries are checked. `released` is called once both are let go, before
    any Zaparoo reload; the watcher waits for that before it watches, so this
    never holds the lock a launch needs."""
    root = card / 'misterzine-plex'
    reload = False
    try:
        if not root.is_dir():
            return 0
        with no_update_running(root) as clear:
            if not clear:
                print('upkeep: skipped, an update is under way', flush=True)
                return 0
            with locked(root):
                reload = reconcile(card)
    except RuntimeError:
        print('upkeep: skipped, Plex or its installer is running', flush=True)
        return 0
    finally:
        released()
    if reload or noted(root).get('zaparoo_pending'):
        print('upkeep: Zaparoo reload ' + refresh_zaparoo(card, wait), flush=True)
    return 0


def let_the_watcher_go():
    """End the watcher's wait for `maintain`: it waits for this process's
    stdout to close. Everything printed after goes to the log on stderr."""
    sys.stdout.flush()
    sys.stdout = sys.stderr
    devnull = os.open(os.devnull, os.O_WRONLY)
    os.dup2(devnull, 1)
    os.close(devnull)


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


def write_if_changed(path, data, mode=None):
    """Write only when the content differs, so checks that run at every boot
    cost no card writes. True when the file was written."""
    try:
        same = path.read_bytes() == data
    except OSError:
        same = False
    if not same:
        atomic(path, data)
    if mode is not None and (not same or path.stat().st_mode & mode != mode):
        path.chmod(mode)
    return not same


def write_json(path, data):
    atomic(path, (json.dumps(data, indent=2) + '\n').encode())


MAINTENANCE = 'maintenance.json'


def note(root, **fields):
    """Merge fields into maintenance.json, the record of the last entry check
    and Zaparoo reload that Send a report shows. Written only when a value
    changed. Best effort: it never stops what it records."""
    path = root / MAINTENANCE
    if not root.is_dir():
        return
    try:
        old = json.loads(path.read_text())
        old = old if isinstance(old, dict) else {}
    except (OSError, ValueError):
        old = {}
    new = dict(old, **fields)
    if new != old:
        try:
            write_json(path, new)
        except OSError:
            pass


def noted(root):
    try:
        value = json.loads((root / MAINTENANCE).read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def read_state(root):
    state = json.loads((root / 'active.json').read_text())
    for key in ('current', 'previous'):
        value = state.get(key)
        if value is not None and not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,95}', value):
            raise ValueError('Invalid release selection; run the installer again')
    return state


@contextlib.contextmanager
def locked(root, patience=0):
    """Hold the manager lock. With `patience`, a lock held for a moment is
    waited for: an install restarts the watcher, whose entry check takes the
    lock just as the install script's next line launches the app."""
    import fcntl
    root.mkdir(parents=True, exist_ok=True)
    deadline = time.monotonic() + patience
    with (root / 'manager.lock').open('a') as lock:
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise RuntimeError('MisterZine Plex Core is running. Return to the MiSTer menu first.')
                time.sleep(.2)
        yield


def decoder(root):
    """Check the release's bundled ARM FFmpeg; updates never fetch a second binary."""
    ff = Path(root) / 'ffmpeg'
    if not ff.is_file() or not os.access(ff, os.X_OK):
        raise ValueError('The release is missing its bundled FFmpeg decoder')


def wrappers(card):
    """The Scripts entries, and the removal of retired ones. True when any changed."""
    changed = False
    for label, action in SCRIPTS.items():
        path = card / 'Scripts' / ('MisterZine-Plex-' + label + '.sh')
        helper = 'update_service.py' if label in ('Install', 'Uninstall') else 'manager.py'
        body = '#!/bin/bash\npython3 ' + shlex.quote(str(card / 'misterzine-plex' / helper)) + ' ' + action + ' --card ' + shlex.quote(str(card)) + '\n'
        # Diagnostics always waits: the code it prints is what the player posts.
        pause = 'true' if label == 'Diagnostics' else '[ "$result" -ne 0 ]'
        body += 'result=$?\nif ' + pause + '; then read -r -p "Press Enter to return to MiSTer..."; fi\nexit "$result"\n'
        changed |= write_if_changed(path, body.encode(), 0o755)
        # The copy `remove` set aside: left behind, it keeps upkeep switched off.
        with contextlib.suppress(FileNotFoundError):
            Path(str(path) + '.disabled').unlink()
            changed = True
    retired =['MisterZine-Plex-Core-' + label + '.sh' for label in ('Run', 'Rollback', 'Remove', 'Diagnostics', 'Install')]
    retired += ['MisterZine-Plex-' + label + '.sh' for label in ('Run', 'Install')]
    for name in retired:
        with contextlib.suppress(FileNotFoundError):
            (card / 'Scripts' / name).unlink()
            changed = True
    return changed


def stage(card, package):
    root = card / 'misterzine-plex'
    manifest = json.loads((package / 'manifest.json').read_text())
    files = manifest['files']
    # A release of the shape before the H.264 core (LEGACY_PAYLOAD) is the
    # bridge release, beta.27's app and core with these helpers; it stages
    # like any other and uses the FFmpeg kept beside the release folders.
    if set(files) not in (PAYLOAD, LEGACY_PAYLOAD):
        raise ValueError('Unexpected package file list')
    ident = manifest['id']
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,95}', ident):
        raise ValueError('Invalid release identifier')
    for name, expected in files.items():
        if digest(package / 'payload' / name) != expected:
            raise ValueError('Package checksum failed: ' + name)
    root.mkdir(parents=True, exist_ok=True)
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
        target.chmod(0o644 if name.endswith('.rbf') else 0o755)
    if set(files) == PAYLOAD:
        decoder(dest)
    write_json(dest / 'manifest.json', manifest)
    if (package / 'BETA_ACCESS.md').is_file():
        atomic(dest / 'BETA_ACCESS.md', (package / 'BETA_ACCESS.md').read_bytes())
    if (package / 'provenance').is_dir():
        provenance = dest / 'provenance'
        if provenance.exists():
            shutil.rmtree(provenance)
        shutil.copytree(package / 'provenance', provenance)
    for name in HELPERS:
        if (package / name).is_file():
            atomic(dest / 'maintenance' / name, (package / name).read_bytes())
    return manifest


def install(card, package):
    root = card / 'misterzine-plex'
    manifest = stage(card, package)
    ident = manifest['id']
    # Activate only after every executable and dependency has been verified.
    state = read_state(root) if (root / 'active.json').exists() else {}
    previous = state.get('previous') if state.get('current') == ident else state.get('current')
    atomic(root / 'manager.py', (package / 'manager.py').read_bytes() if (package / 'manager.py').exists() else Path(__file__).read_bytes())
    for name in HELPERS[1:]:
        if (package / name).is_file():
            atomic(root / name, (package / name).read_bytes())
    for name in ('README.md', 'TERMS.md', 'THIRD_PARTY_NOTICES.md', 'BETA_ACCESS.md'):
        if (package / name).is_file():
            atomic(root / name, (package / name).read_bytes())
    for name in ('Apache-2.0.txt', 'Go.txt', 'GPL-2.0.txt', 'GPL-3.0.txt', 'LGPL-2.1.txt', 'Lucide-ISC.txt'):
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
    print('Installed ' + ident + '. Launch MisterZine Plex from the main menu.')


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
    if all(core_file(root, folder / name).name == 'PlexH264.rbf' for name in keep):
        # No release from before the H.264 core is left to roll back to, so
        # the FFmpeg those releases downloaded beside the release folders goes.
        for name in LEGACY_FILES:
            path = root / name
            if path.is_symlink() or path.is_file():
                path.unlink()
            elif path.is_dir():
                shutil.rmtree(path)
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


# A name shorter than this is not redacted: "tv" or "Bo" would shred the
# report wherever those letters stand, and says little about anyone.
NAME_MIN = 4


def safe_log(text, secrets):
    """text with every secret replaced by [redacted]. A secret is a string
    (a token, key or id: replaced wherever it stands, URL-quoted too) or a
    (value, whole_word) pair; whole_word marks a name, replaced only as a whole
    word and only when at least NAME_MIN characters long."""
    import urllib.parse
    for secret in secrets:
        value, whole_word = secret if isinstance(secret, tuple) else (secret, False)
        if not value:
            continue
        if whole_word:
            if len(value) >= NAME_MIN:
                text = re.sub(r'(?<!\w)' + re.escape(value) + r'(?!\w)', '[redacted]', text)
            continue
        for quoted in (value, urllib.parse.quote(value, safe=''), urllib.parse.quote_plus(value)):
            text = text.replace(quoted, '[redacted]')
    text = re.sub(r'(?i)((?:x-plex-token|x-emby-token|x-mediabrowser-token|authtoken|accesstoken|access_token|api_key|token)[= :"%]+)[^&\s"<>]+', r'\1[redacted]', text)
    text = re.sub(r'(?i)(authorization:\s*bearer\s+)\S+', r'\1[redacted]', text)
    text = re.sub(r'(?i)((?:beta|supporter)[_-]?code|receipt)[= :"%]+[^&\s"<>]+', r'\1[redacted]', text)
    text = re.sub(r'(?i)beta-unlocks[/\\][^\s"<>]+', 'beta-unlocks/[redacted]', text)
    text = re.sub(r'https?://[^\s"<>]+', '[server address removed]', text)
    return text


VIDEO_KEYS = ('main', 'direct_video', 'vga_scaler', 'forced_scandoubler', 'ypbpr', 'composite_sync', 'vga_sog',
              'vsync_adjust', 'vscale_mode', 'vscale_border', 'video_mode', 'video_mode_ntsc', 'video_mode_pal',
              'menu_pal', 'hdmi_limited', 'vrr_mode', 'fb_terminal', 'dvi_mode')


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


# The name MiSTer main knows the core by: the setname in the launch entry
# (launch_body), which it matches INI sections against and publishes in
# /tmp/CORENAME. The same name the PlexCRT core had, so INI sections written
# for earlier releases still apply.
CORE_NAME = 'MisterZine Plex Core'
# MiSTer main keeps the INI chosen in its menu in reserved memory (altcfg() in
# its user_io.cpp): a signature, then 0 for MiSTer.ini or 1-3 for the
# alternatives.
ALTCFG_ADDRESS, ALTCFG_OFFSET, ALTCFG_SIGNATURE = 0x1FFFF000, 0xF04, b'\x34\x99\xba'
# What main keeps of an INI line besides blanks (CHAR_IS_VALID in its cfg.cpp).
INI_CHARS = frozenset('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789[]()-+/=#$@_,.!*:~')


def alt_ini_names(card):
    """The alternative INIs MiSTer's menu offers, in its order: the first three
    MiSTer_*.ini files the directory lists, sorted ignoring case (cfg_get_name)."""
    names = [name for name in os.listdir(card) if name.lower().startswith('mister_') and name.lower().endswith('.ini')]
    return sorted(names[:3], key=str.lower)


def read_altcfg(mem='/dev/mem', address=ALTCFG_ADDRESS):
    """The INI number MiSTer main last chose; 0 without its signature, as main
    reads it, and None when the memory cannot be read."""
    try:
        fd = os.open(mem, os.O_RDONLY | getattr(os, 'O_SYNC', 0))
    except OSError:
        return None
    try:
        with mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ, offset=address) as page:
            data = page[ALTCFG_OFFSET:ALTCFG_OFFSET + 4]
    except (OSError, ValueError):
        return None
    finally:
        os.close(fd)
    return data[3] if data[:3] == ALTCFG_SIGNATURE else 0


def active_ini(card, altcfg=read_altcfg):
    """The INI MiSTer main read for the running core, and its number (0 for
    MiSTer.ini). (None, None) when that cannot be told: an alternative exists
    but main's choice is unreadable, or the choice names no file."""
    try:
        alts = alt_ini_names(card)
    except OSError:
        return None, None
    number = altcfg() if alts else 0
    if number is None:
        return None, None
    if not 1 <= number <= 3:        # main uses MiSTer.ini for anything else
        return card / 'MiSTer.ini', 0
    return (card / alts[number - 1], number) if number <= len(alts) else (None, None)


def ini_line(raw):
    """A line as MiSTer main keeps it (ini_getline): leading blanks, a comment
    and characters it does not accept dropped, trailing blanks trimmed."""
    kept, leading = [], True
    for c in raw:
        if c == ';' or len(kept) >= 1023:   # INI_LINE_SIZE: the rest of a long line is dropped
            break
        if c not in ' \t':
            leading = False
        if not leading and (c in ' \t' or c in INI_CHARS):
            kept.append(c)
    return ''.join(kept).rstrip(' \t')


def section_scope(header, core=CORE_NAME):
    """Whether main applies a section to this core (ini_get_section): 'MiSTer'
    for [MiSTer], 'core' for the core's name or a prefix of it ending in '*',
    'video' for a video mode section ([video=720x480@59.9]), else None. Main
    applies a video section when it names the core's current mode, which it
    measures once the core's video runs, so which ones apply is not known
    here. Arcade sections never apply to this core."""
    name = header.split(']', 1)[0]
    if name.lower() == 'mister':
        return 'MiSTer'
    star = name.rfind('*')
    own = core.lower().startswith(name[:star].lower()) if star >= 0 else name.lower() == core.lower()
    if own:
        return 'core'
    equals = name.rfind('=')
    # strncasecmp(name, "video", equals): any start of "video" before the '='
    return 'video' if 0 <= equals <= 5 and 'video'.startswith(name[:equals].lower()) else None


def parse_core_ini(text, core=CORE_NAME):
    """What main applies to the core from an INI: (scope, key, value) for each
    line under [MiSTer], the core's own sections (or a '+name' line that
    includes it) and video mode sections, in file order, keys in lower case;
    and whether the file has a section of the core's own."""
    entries, scope, own = [], None, False
    for raw in text.split('\n'):
        line = ini_line(raw)
        if line.startswith('[') or (line.startswith('+') and scope is None):
            scope = section_scope(line[1:], core)
            own = own or scope == 'core'
        elif scope:
            match = re.match(r'([^=\s]+)[=\s]', line)
            if match:
                entries.append((scope, match.group(1).lower(), line[match.end():].lstrip('= \t')))
    return entries, own


def ini_number(text, low, high):
    """An unsigned value as main reads it: strtoul with base 0, clamped."""
    match = re.match(r'\s*([+-]?)(0[xX][0-9a-fA-F]+|0[0-7]*|[1-9][0-9]*)', text)
    if not match:
        return low
    digits = match.group(2)
    value = int(digits, 16) if digits[:2].lower() == '0x' else int(digits, 8) if digits[0] == '0' else int(digits)
    if match.group(1) == '-' and value:
        value = high                # a negative number wraps to a huge one
    return max(low, min(high, value))


DECIMAL = re.compile(r'\s*[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?')


def ini_float(text, low, high):
    """A decimal value as main reads it: strtof, clamped."""
    match = DECIMAL.match(text)
    return max(low, min(high, float(match.group(0)) if match else 0.0))


# The settings these checks compare, with main's ranges (ini_vars in its
# cfg.cpp); video modes are kept as text. Anything else a section sets is
# not looked at.
NUMBER_KEYS = {'vrr_mode': (0, 4), 'vsync_adjust': (0, 2), 'direct_video': (0, 2), 'dvi_mode': (0, 1),
               'vscale_mode': (0, 5), 'vscale_border': (0, 399), 'vga_scaler': (0, 1), 'forced_scandoubler': (0, 1),
               'ypbpr': (0, 1), 'composite_sync': (0, 1), 'hdmi_limited': (0, 2), 'menu_pal': (0, 1)}
FLOAT_KEYS = {'refresh_min': (0, 150), 'refresh_max': (0, 150)}
TEXT_KEYS = frozenset({'video_mode', 'video_mode_ntsc', 'video_mode_pal'})
VRR_KEYS = ('vrr_mode', 'vsync_adjust', 'direct_video')
REFRESH_KEYS = VRR_KEYS + ('video_mode', 'video_mode_ntsc', 'video_mode_pal', 'refresh_min', 'refresh_max')


KNOWN_KEYS = frozenset(NUMBER_KEYS) | frozenset(FLOAT_KEYS) | TEXT_KEYS


def setting(key, value):
    """A known setting's value as main ends up with it, so two spellings of
    the same value compare equal."""
    if key in NUMBER_KEYS:
        return ini_number(value, *NUMBER_KEYS[key])
    if key in FLOAT_KEYS:
        return ini_float(value, *FLOAT_KEYS[key])
    if not value:
        return ''
    parts = video_mode_parts(value)
    if parts is None:
        return 'rejected'           # any rejected value gets the same fallback mode
    numbers, rate, flags = parts
    # The flags as main leaves them: the last of each pair wins.
    hpol, vpol, rb, pr = 0, 0, 1, 0
    for flag in flags:
        if flag in ('+hsync', '-hsync'):
            hpol = int(flag[0] == '+')
        elif flag in ('+vsync', '-vsync'):
            vpol = int(flag[0] == '+')
        elif flag in ('cvt', 'cvtrb'):
            rb = int(flag == 'cvtrb')
        else:
            pr = 1
    if len(numbers) == 1:           # main's table sets blanking and repetition; past it is mode 0
        return ('mode', numbers[0] if numbers[0] < 15 else 0, hpol, vpol)
    if rate is not None or len(numbers) == 3:   # width,height,rate: 60 and 60.0 alike
        return ('rate', numbers[0], numbers[1], rate if rate is not None else float(numbers[2]), hpol, vpol, rb, pr)
    # A timing keeps its blanking flag: vscale_mode 4 and 5 recalculate it.
    if len(numbers) == 11:          # the last two numbers set the polarities
        return ('timing', tuple(numbers), rb, pr)
    return ('timing', tuple(numbers), hpol, vpol, rb, pr)


def last_scopes(entries):
    """The scope of the line that last set each key. A key last set in a video
    mode section is not known: that section may not apply."""
    return {key: scope for scope, key, _ in entries}


def overridden_keys(entries):
    """Known settings the core's own section sets that a later [MiSTer] line
    changes, so main never uses the core's value. A setting last set in a
    video mode section is left out: whether that section applies is not
    known."""
    own, final = {}, {}
    for scope, key, value in entries:
        if key in KNOWN_KEYS and scope != 'video':
            final[key] = setting(key, value)
            if scope == 'core':
                own[key] = final[key]
    last = last_scopes(entries)
    return sorted(key for key, value in own.items() if final[key] != value and last[key] != 'video')


def vrr_state(values):
    """'forced' when main turns variable refresh rate on for the core whatever
    the display reports, 'auto' when only a display that reports support gets
    it, 'off' otherwise (set_vrr_mode and video_set_mode in its video.cpp):
    main drops VRR with vsync_adjust or direct video. 'unknown' with
    direct_video=2, which main resolves at start-up: direct video for a VGA
    converter it recognises, the scaler for anything else."""
    mode = ini_number(values.get('vrr_mode', ''), 0, 4)
    video = ini_number(values.get('direct_video', ''), 0, 2)
    if not mode or ini_number(values.get('vsync_adjust', ''), 0, 2) or video == 1:
        return 'off'
    if video == 2:
        return 'unknown'
    return 'auto' if mode == 1 else 'forced'


# video_mode numbers that run at 50 Hz (vmodes[] in main's video.cpp); every
# other number, including ones past the table, which main reads as 0, is 60 Hz.
FIFTY_HZ_MODES = frozenset({3, 7, 9})
VIDEO_MODE_FLAGS = frozenset({'+vsync', '-vsync', '+hsync', '-hsync', 'cvt', 'cvtrb', 'pr'})
# The core's rate in its 480-line Output Modes. Its 576-line modes, and
# playback Refresh Rate Match moves to that family, run at 50 Hz, which the
# vsync_adjust checks below do not model; the app compares a fixed HDMI rate
# with the Output Mode the core reports (Warnings in app/internal/ui/display.go).
CORE_HZ = 59.94


def whole_number(token):
    """A token strtoul reads to its end with base 0, else None."""
    match = re.fullmatch(r'\s*\+?(0[xX][0-9a-fA-F]+|0[0-7]*|[1-9][0-9]*)', token)
    if not match:
        return None
    digits = match.group(1)
    return int(digits, 16) if digits[:2].lower() == '0x' else int(digits, 8) if digits[0] == '0' else int(digits)


def video_mode_parts(value):
    """A video mode value as main parses it (parse_custom_video_mode): its
    leading numbers, the rate of the width,height,rate form when that is a
    decimal, and its flags in lower case; None when it is empty or main
    rejects it. The numbers are a mode number, width,height,rate, the full
    timing with the pixel clock in kHz (9 or 11), or raw registers (21+)."""
    if not value:
        return None
    tokens = value.split(',')
    numbers = []
    for token in tokens:
        number = whole_number(token)
        if number is None:
            break
        numbers.append(number)
    rate = None
    if len(numbers) == 2 and len(tokens) > 2 and DECIMAL.fullmatch(tokens[2]):
        rate = float(tokens[2])     # strtod: 59.94, say
    flags = [flag.lower() for flag in tokens[len(numbers) + (rate is not None):]]
    if any(flag not in VIDEO_MODE_FLAGS for flag in flags):
        return None
    if not (len(numbers) in (1, 3, 9, 11) or rate is not None or len(numbers) >= 21):
        return None
    return numbers, rate, flags


def parse_video_mode(value):
    """(accepted, refresh) for a video mode value: accepted is False for an
    empty value or one main rejects; refresh is None when it cannot be told
    (the raw register form)."""
    parts = video_mode_parts(value)
    if parts is None:
        return False, None
    numbers, rate, _ = parts
    if len(numbers) == 1:
        return True, 50.0 if numbers[0] in FIFTY_HZ_MODES else 60.0
    if rate is not None:
        return True, rate
    if len(numbers) == 3:
        return True, float(numbers[2])
    if len(numbers) in (9, 11):
        total = sum(numbers[0:4]) * sum(numbers[4:8])
        return True, round(numbers[8] * 1000.0 / total, 2) if total else None
    return True, None


def clock_out_of_range(value):
    """Whether main must give up following the core in this mode because the pixel
    clock it needs at 59.94 Hz is outside 2-300 MHz (video_mode_adjust). Only
    the full timing form gives the totals; every numbered mode stays inside,
    and the width,height,rate form counts as inside, which leaves its rate
    unknown rather than wrongly fixed."""
    parts = video_mode_parts(value)
    if parts is None or len(parts[0]) not in (9, 11):
        return False
    numbers = parts[0]
    clock = sum(numbers[0:4]) * sum(numbers[4:8]) * CORE_HZ / 1e6
    return not 2 <= clock <= 300


def video_mode_refresh(value):
    """The refresh rate of the default mode for a video_mode value: a value
    main rejects, or none at all when it cannot use the display's own mode,
    gives its 60 Hz fallback (store_custom_video_mode)."""
    accepted, refresh = parse_video_mode(value)
    return refresh if accepted else 60.0


def fixed_hdmi_refresh(values):
    """The rate HDMI keeps whatever the core does and the setting that picks
    that mode ('video_mode', say), or (None, '') when HDMI follows the core or
    it cannot be told (video_mode_load, video_mode_select and video_mode_adjust
    in main's video.cpp). HDMI follows the core with forced VRR, and with
    vsync_adjust, unless refresh_min or refresh_max leaves out the core's 59.94 Hz
    or only a PAL mode is given. Direct video sends the core's own timing;
    direct_video=2 is resolved at start-up. With no video mode at all, main
    takes the display's own."""
    if ini_number(values.get('direct_video', ''), 0, 2) or vrr_state(values) == 'forced':
        return None, ''
    video, pal, ntsc = (values.get(key, '') for key in ('video_mode', 'video_mode_pal', 'video_mode_ntsc'))
    if not (video or pal or ntsc):
        return None, ''
    if not ini_number(values.get('vsync_adjust', ''), 0, 2):
        return video_mode_refresh(video), 'video_mode'
    (pal_set, pal_hz), (ntsc_set, ntsc_hz) = parse_video_mode(pal), parse_video_mode(ntsc)
    if pal_set and not ntsc_set:
        return pal_hz, 'video_mode_pal'     # "NTSC mode cannot be used": the PAL mode, never adjusted
    base, key = (ntsc, 'video_mode_ntsc') if ntsc_set else (video, 'video_mode')
    low, high = (ini_float(values.get(name, ''), *FLOAT_KEYS[name]) for name in ('refresh_min', 'refresh_max'))
    if (low and CORE_HZ < low) or (high and CORE_HZ > high) or clock_out_of_range(base):
        return (ntsc_hz if ntsc_set else video_mode_refresh(video)), key     # main cancels the adjustment
    return None, ''


def ini_findings(entries):
    """What Options and reports say about the INI main read for the core:
    VRR, the fixed HDMI rate, DVI mode (no HDMI sound) and core settings a
    later [MiSTer] section undoes. A finding that depends on a setting last
    set in a video mode section is left unknown ('unknown', None), since that
    section may or may not apply; a later line anywhere else settles it."""
    values = {key: value for scope, key, value in entries if scope != 'video'}
    conditional = sorted(key for key, scope in last_scopes(entries).items() if scope == 'video' and key in KNOWN_KEYS)
    def known(keys):
        return not set(conditional).intersection(keys)
    hz, mode = fixed_hdmi_refresh(values) if known(REFRESH_KEYS) else (None, '')
    return {'vrr': vrr_state(values) if known(VRR_KEYS) else 'unknown',
            'vrr_mode': ini_number(values.get('vrr_mode', ''), 0, 4),
            'vsync_adjust': ini_number(values.get('vsync_adjust', ''), 0, 2),
            'hdmi_hz': hz, 'hdmi_mode': (mode + '=' + values.get(mode, ''))[:60] if mode and values.get(mode) else '',
            'dvi': ini_number(values.get('dvi_mode', ''), 0, 1) == 1 if known(('dvi_mode',)) else None,
            'overridden': overridden_keys(entries), 'conditional': conditional}


def section_elsewhere(card, active):
    """Another INI main could read that has the core's own section, for when
    the active one has none: MiSTer.ini first, then the alternatives. Reports
    only: separate INIs for a CRT and for HDMI are often set up that way on
    purpose, so Options do not flag it."""
    try:
        names = ['MiSTer.ini'] + alt_ini_names(card)
    except OSError:
        return ''
    for name in names:
        if name.lower() == active.name.lower():
            continue
        try:
            if parse_core_ini((card / name).read_text(errors='replace'))[1]:
                return name
        except OSError:
            continue
    return ''


def display_check(card, altcfg=read_altcfg):
    """What the app's Options show about the MiSTer INI: which file main read
    for the core and ini_findings for it. vrr is 'unknown' when the file main read
    cannot be told or read."""
    path, _ = active_ini(card, altcfg)
    if path is None:
        return {'ini': '', 'vrr': 'unknown'}
    try:
        entries = parse_core_ini(path.read_text(errors='replace'))[0]
    except FileNotFoundError:
        entries = []                # main runs on its defaults
    except OSError:
        return {'ini': path.name, 'vrr': 'unknown'}
    return dict(ini_findings(entries), ini=path.name)


DISPLAY_ENV_MAX = 4096


def display_env(card):
    """display_check for the app's environment (MISTERZINE_PLEX_DISPLAY),
    taken once the core is loaded, when main has read the INI for it. A check
    that fails is logged and leaves the variable empty: the app then shows
    nothing about the INI. Older apps ignore the variable."""
    try:
        check = display_check(card)
    except Exception as exc:        # never in the way of starting the app
        trace('display check failed: %s' % type(exc).__name__)
        return ''
    trace('display check: vrr %s, hdmi %s Hz, dvi %s, overridden %s' % (
        check['vrr'], check.get('hdmi_hz'), check.get('dvi'), ','.join(check.get('overridden', [])) or 'none'))
    text = json.dumps(check)
    # Only known keys and file names go in, but an environment string that
    # is too long would stop the app starting at all.
    if len(text) > DISPLAY_ENV_MAX:
        trace('display check left out: %d bytes' % len(text))
        return ''
    return text


def ini_label(card, name):
    """An INI as a report names it: MiSTer.ini, or an alternative by its
    number in MiSTer's menu, since its file name is the player's own."""
    if not name or name.lower() == 'mister.ini':
        return name
    try:
        alts = [alt.lower() for alt in alt_ini_names(card)]
    except OSError:
        alts = []
    return 'alternative %d' % (alts.index(name.lower()) + 1) if name.lower() in alts else 'another INI'


def defines_launcher(path, ident='misterzine-plex'):
    """Whether a Zaparoo TOML file has a [[launchers.custom]] table with this
    id. Tables and keys only; comments do not count."""
    table = None
    for line in path.read_text(errors='replace').splitlines():
        line = line.strip()
        if line.startswith('['):
            table = re.sub(r'\s+', '', line.split('#', 1)[0])
        elif table == '[[launchers.custom]]' and re.fullmatch(r'id\s*=\s*(["\'])' + re.escape(ident) + r'\1\s*(#.*)?', line):
            return True
    return False


def zaparoo_facts(root, version=None):
    """Why Plex does or does not show in Zaparoo, without paths or contents."""
    version = version or zaparoo_version
    card = root.parent
    folder = card / 'zaparoo'
    facts = {'installed': folder.is_dir(), 'script': (card / 'Scripts/zaparoo.sh').is_file()}
    if not (facts['installed'] or facts['script']):
        return facts
    try:
        data = (folder / 'launchers' / ZAPAROO_ENTRY).read_bytes()
    except FileNotFoundError:
        facts['entry'] = 'absent'
    except OSError:
        facts['entry'] = 'unreadable'
    else:
        try:
            facts['entry'] = 'current' if data == zaparoo_body(root) else 'stale'
        except (OSError, ValueError, KeyError, TypeError):
            facts['entry'] = 'present'
    # Zaparoo's own config wins over our file; another file with our id is a
    # duplicate, which Zaparoo refuses.
    try:
        facts['config_override'] = (folder / 'config.toml').is_file() and defines_launcher(folder / 'config.toml')
    except OSError:
        facts['config_override'] = 'unreadable'
    try:
        facts['other_files_with_id'] = sum(1 for path in (folder / 'launchers').glob('*.toml')
                                           if path.name != ZAPAROO_ENTRY and defines_launcher(path))
    except OSError:
        pass
    facts['core'] = version() or 'not answering'
    return facts


KERNEL_WORDS = re.compile(r'exfat|fat-fs|ext4-fs|mmc|i/o error|remount|read-only|sd[a-z]\b|blk_update', re.I)


def kernel_lines(dmesg=None, limit=40):
    """The kernel's recent lines about storage: a card mounted dirty, an I/O
    error, a remount read-only. Each cut to 200 characters, newest kept."""
    if dmesg is None:
        def dmesg():
            return subprocess.run(['dmesg'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                  timeout=10, check=False).stdout.decode('utf-8', errors='replace')
    lines = [line.strip()[:200] for line in dmesg().splitlines() if KERNEL_WORDS.search(line)]
    return lines[-limit:]


def mount_facts(mountpoint, mounts=Path('/proc/mounts')):
    """How the card is mounted: its filesystem and options. 'ro' among the
    options means the kernel has turned the card read-only after an error."""
    for line in mounts.read_text(errors='replace').splitlines():
        parts = line.split()
        if len(parts) >= 4 and parts[1] == str(mountpoint):
            return {'type': parts[2], 'options': parts[3][:200]}
    return None


def system_facts(root, secrets, proc_root=Path('/proc'), altcfg=read_altcfg, dmesg=None):
    """Facts about the board that decide whether a launch or a picture can
    work, gathered read-only. Each is best-effort and absent when unreadable."""
    facts = {}
    card = root.parent
    # The INI main read, by number only: an alternative's file name is the
    # player's own. MiSTer.ini stands in when main's choice is unreadable.
    ini, number = active_ini(card, altcfg)
    facts['ini'] = 'unknown' if ini is None else 'MiSTer.ini' if not number else 'alternative %d' % number
    try:
        text = (ini or card / 'MiSTer.ini').read_text(errors='replace')
        facts['video_settings'] = ini_video_settings(text)
        entries, own = parse_core_ini(text)
        values = {key: value for _, key, value in entries}
        findings = ini_findings(entries)
        for key in ('vrr_mode', 'vsync_adjust'):   # the raw values below say it
            del findings[key]
        facts['ini_video'] = {key: values[key][:40] for key in VIDEO_KEYS if key in values}
        elsewhere = '' if own else section_elsewhere(card, ini or card / 'MiSTer.ini')
        facts['ini_video'].update(findings, own_section=own, section_in=ini_label(card, elsewhere))
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
        facts['zaparoo'] = zaparoo_facts(root)
    except OSError:
        pass
    upkeep = noted(root)
    if upkeep:
        facts['upkeep'] = upkeep
    try:
        facts['framebuffer_mode'] = Path('/sys/module/MiSTer_fb/parameters/mode').read_text().strip()
    except OSError:
        pass
    try:
        cfg = json.loads((root / 'plexcrt.json').read_text())
        url = cfg.get('server_url', '')
        import ipaddress, urllib.parse
        u = urllib.parse.urlsplit(url)
        host = u.hostname or ''
        if host.endswith('.plex.direct'):
            private = bool(re.match(r'(10-|192-168-|172-(1[6-9]|2\d|3[01])-)', host))
        else:
            # the plain HTTP connection is the address itself
            try:
                private = ipaddress.ip_address(host).is_private
            except ValueError:
                private = None
        facts['server'] = {'scheme': u.scheme, 'port': u.port,
                           'kind': 'relay' if u.port == 8443 else 'plex.direct' if host.endswith('.plex.direct') else 'address',
                           'private_lan': private,
                           'bitrate': cfg.get('bitrate'), 'progressive': cfg.get('progressive')}
    except (OSError, ValueError):
        pass
    # The card's mount and the kernel's word on it: a card remounted read-only
    # after an error fails every write and drags the board until a reboot.
    try:
        facts['card_mount'] = mount_facts(card, proc_root / 'mounts')
    except OSError:
        pass
    try:
        facts['kernel_storage_lines'] = [safe_log(line, secrets) for line in kernel_lines(dmesg)]
    except (OSError, subprocess.SubprocessError):
        pass
    # Free space on the card and in /tmp (a RAM disk here): a full one slows the
    # board and fails writes, and a reboot hides it again.
    for label, place in (('card', card), ('tmp', Path('/tmp'))):
        try:
            usage = shutil.disk_usage(place)
            facts[label + '_space_mb'] = {'free': usage.free // (1024 * 1024), 'total': usage.total // (1024 * 1024)}
        except OSError:
            pass
    try:
        state = read_state(root)
        folder = root / 'releases' / state['current']
        manifest = json.loads((folder / 'manifest.json').read_text())
        facts['payload_intact'] = all((folder / name).is_file() and digest(folder / name) == sha
                                      for name, sha in manifest['files'].items())
    except (OSError, ValueError, KeyError, TypeError):
        pass
    for name in ('ffmpeg.stat', 'jfplay.stat.err'):
        try:
            facts[name] = safe_log(Path('/tmp', name).read_text(errors='replace').strip()[:300], secrets)
        except OSError:
            pass
    return facts


def report_secrets(root):
    """Values that must never leave the card, read only to redact them (for
    safe_log): tokens, ids and addresses as they are, names as whole words."""
    import urllib.parse
    secrets = []
    for path in (root / 'plexcrt.json', root / 'plexcrt.json.bak'):
        try:
            cfg = json.loads(path.read_text())
            secrets += [str(cfg.get(k) or '') for k in ('token', 'home_token', 'server_token', 'server_url', 'server_id',
                                                        'client_id')]
            secrets += [(str(cfg.get(k) or ''), True) for k in ('account_name', 'home_user_title', 'server_name')]
            # a plain HTTP server URL is a bare address, which network errors quote without the URL
            secrets.append(urllib.parse.urlsplit(str(cfg.get('server_url') or '')).hostname or '')
        except (OSError, ValueError):
            pass
    # Receipt names bind an access batch to a verifier. Omit names without
    # opening the files or exposing their contents.
    try:
        secrets.extend(path.name for path in (root / 'beta-unlocks').glob('*.receipt'))
    except OSError:
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
    logs += [(name, root / 'updates' / name) for name in ('last-error.log', 'worker.log', 'download-output.log', 'downloader.log')]
    logs = [(name, path) for name, path in logs if path.is_file()]
    created = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(now))
    limit = 64 * 1024
    while True:
        lines = [REPORT_MAGIC, 'App: MisterZine Plex Core ' + report_version(root), 'Created: ' + created, '', '== SYSTEM',
                 'kernel: ' + os.uname().release, 'release: ' + json.dumps(state)]
        for key, value in facts.items():
            lines.append(safe_log(key + ': ' + json.dumps(value, sort_keys=True), secrets))
        for name, path in logs:
            try:
                stamp = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(path.stat().st_mtime))
                tail = safe_log(log_tail(path, limit), secrets).rstrip('\n')
            except OSError as exc:
                # A log that cannot be read is a finding, not a reason to lose the report.
                stamp, tail = 'unreadable', write_problem(exc)
            lines += ['', '== LOG ' + name + ' (' + stamp + ')', tail]
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


def write_problem(exc):
    """A local file failure, worded for the screen. Never echoes paths or
    the exception text."""
    import errno
    words = {errno.ENOSPC: 'The card is full.', errno.EROFS: 'The card is read-only.',
             errno.EACCES: 'The card refused the write.', errno.EPERM: 'The card refused the write.',
             errno.ENOENT: 'The Plex folder is missing.', errno.EIO: 'The card gave a read/write error.'}
    name = errno.errorcode.get(exc.errno or 0, type(exc).__name__)
    return words.get(exc.errno, 'The card could not be written (' + name + ').')


def diagnostics(root, upload=False, tmp=Path('/tmp')):
    """Write the report beside the app and, when asked, send it. Returns (path, code, problem):
    code is '' when the upload did not happen and problem then says why.

    A card that cannot take the file is itself what the report is for, so the
    report then goes to /tmp, and the upload is tried either way; path is None
    only when neither place took it."""
    text = build_report(root)
    out, saving = None, ''
    for place in (root / 'report.txt', tmp / 'misterzine-plex-report.txt'):
        try:
            atomic(place, text.encode())
            out = place
            break
        except OSError as exc:
            saving = saving or write_problem(exc)
    if saving:
        saving = 'The report could not be saved on the card: ' + saving
    if not upload:
        return out, '', saving
    try:
        return out, send_report(text, report_version(root)), ''
    except ReportError as exc:
        return out, '', (str(exc) + ' ' + saving).strip()


def stop_child(child):
    if child.poll() is None:
        child.terminate()
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()


def core_file(root, folder=None):
    if folder is None:
        folder = root / 'releases' / read_state(root)['current']
    core = folder / 'PlexH264.rbf'
    if not core.exists():
        # a release from before the H.264 core, selected by a rollback
        core = folder / 'MisterZine Plex Core.rbf'
    return core


def launch_body(root, folder=None):
    core = core_file(root, folder)
    # MGL core paths are relative to MiSTer's storage root, not the MGL file.
    # Also support an isolated installation nested under that mount for testing.
    storage = Path('/media') / root.parts[2] if len(root.parts) > 3 and root.parts[1] == 'media' else root.parent
    relative = core.relative_to(storage).with_suffix('').as_posix()
    return ('<mistergamedescription>\n  <rbf>' + escape(relative) + '</rbf>\n'
            '  <setname>' + CORE_NAME + '</setname>\n</mistergamedescription>\n')


def core_launch_entry(root, folder):
    # MiSTer anchors its core browser to the MGL's directory, even when the
    # bitstream lives elsewhere. Keep this internal entry at the card root.
    entry = root.parent / '.misterzine-plex-core.mgl'
    atomic(entry, launch_body(root, folder).encode())
    return entry


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


def ensure_selected_core(card, root, folder, wait=20, proc_root=Path('/proc'),
                         corename=Path('/tmp/CORENAME'), cmd=Path('/dev/MiSTer_cmd')):
    """Select this release's RBF if the running MiSTer process owns another one.

    CORENAME alone is not enough: an update can leave the previous release's
    H264 image loaded under the same name, and the Go app skips loading when
    CORENAME already says it is up. MiSTer restarts its main process for a core
    switch, so both the name and the process argument are checked after
    requesting the MGL.
    """
    target = core_file(root, folder)
    target_key = target.resolve(strict=False).with_suffix('').as_posix()

    def matching_processes():
        try:
            if corename.read_text().strip() not in (target.stem, CORE_NAME):
                return set()
        except OSError:
            return set()
        matches = set()
        for pid, argument in mister_processes(proc_root).items():
            try:
                value = Path(argument.decode(errors='replace')).resolve(strict=False).with_suffix('').as_posix()
            except (OSError, ValueError):
                continue
            if value == target_key:
                matches.add(pid)
        return matches

    before = set(mister_processes(proc_root))
    if matching_processes():
        return True
    entry = core_launch_entry(root, folder)
    with open(cmd, 'w') as out:
        out.write('load_core ' + str(entry) + '\n')
    deadline = time.monotonic() + wait
    while time.monotonic() < deadline:
        if matching_processes() - before:
            return True
        time.sleep(.05)
    return False


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
        # A stable release has no prerelease part in its version (build_package.py).
        channel = 'public' if target and '-' not in str(target) else 'beta'
        message += '. No earlier release is installed; run ' + installer_script(channel) + ' from Scripts to retry.'
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
    """One timestamped line of the launch story, into the menu-run log (the
    update-run log for a launch the updater started)."""
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


# The app's exit status after the menu's Exit (exitToMenu in app/cmd/plexcrt/main.go).
EXIT_TO_MENU = 3


def app_finished(returncode):
    """Whether the app asked for the MiSTer menu as it ended. One still running
    (stopped here: None) or one that exited cleanly did not; any other
    status is a failure."""
    if returncode == EXIT_TO_MENU:
        return True
    if returncode not in (None, 0):
        raise RuntimeError('The Plex application exited with status %s; check its launch log.' % returncode)
    return False


def menu_core(arg):
    """Whether a MiSTer main process's core argument is a menu: menu.rbf, or a
    forked main's own (Zaparoo Frontend loads zaparoo/menu_zaparoo.rbf)."""
    name = Path(arg.decode(errors='replace')).name.lower()
    return name.startswith('menu') and name.endswith('.rbf')


def load_menu(card, cmd=Path('/dev/MiSTer_cmd'), wait=10):
    """Return to the MiSTer menu, as a short OSD Reboot does. Only once the app
    has stopped: the menu draws its background into the framebuffer, and a
    mode write of ours after that would clear its top.
    MiSTer restarts its main process to load a core, so a new one running a
    menu shows it came up. False when it did not."""
    rbf = card / 'menu.rbf'
    if not rbf.is_file():
        trace('no %s; the H264 core stays loaded' % rbf)
        return False
    before = mister_processes()
    with open(cmd, 'w') as out:
        out.write('load_core ' + str(rbf) + '\n')
    trace('app chose Exit; loading the MiSTer menu')
    deadline = time.monotonic() + wait
    while not any(pid not in before and menu_core(arg) for pid, arg in mister_processes().items()):
        if time.monotonic() > deadline:
            trace('no MiSTer menu within %d s; the H264 core may still be loaded' % wait)
            return False
        time.sleep(.05)
    trace('MiSTer menu loaded')
    return True


def linger_for_start_check(ready=None, now=time.time, sleep=time.sleep):
    """After an Exit, stay until 3 s after the app came up when an updater's
    start check launched us (its readiness marker is set). That check, in
    older releases too, counts a launcher still running 2 s after the app is
    up as a good start; ending sooner would roll the update back."""
    ready = ready if ready is not None else os.environ.get('MISTERZINE_PLEX_READY_FILE')
    try:
        up = Path(ready).stat().st_mtime if ready else None
    except OSError:
        up = None
    wait = max(0.0, min(3.0, up + 3 - now())) if up else 0.0
    if wait:
        sleep(wait)
    return wait


def run(root):
    recovered = recover_activation(root)
    state = read_state(root)
    if not recovered:
        threading.Thread(target=upkeep_after_start, args=(root, state['current']), daemon=True).start()
    folder = root / 'releases' / state['current']
    card = root.parent
    rbf = core_file(root, folder).relative_to(card).with_suffix('').as_posix()
    args = [str(folder / 'plexcrt'), '-config', str(root / 'plexcrt.json'),
            '-cache', str(root / 'cache'), '-player', str(folder / 'jfplay'),
            '-ffmpeg', str(folder / 'ffmpeg')]
    # Validate runtime dependencies before switching cores: once MiSTer loads
    # the H264 image, it displays color bars until the app can start.
    subprocess.run(args + ['-check'], check=True)
    if not ensure_selected_core(card, root, folder):
        raise RuntimeError('The selected Plex H264 core did not load; return to the MiSTer menu and retry.')
    # The INI check for Options, now that main has read the INI for the core.
    env = dict(os.environ, MISTERZINE_H264_RBF=rbf, MISTERZINE_PLEX_DISPLAY=display_env(card))
    rotate_log('/tmp/misterzine-plex.log')
    child = None
    original_term = signal.getsignal(signal.SIGTERM)
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    try:
        with open('/tmp/misterzine-plex.log', 'wb') as log:
            child = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=log, stderr=log, env=env)
            trace('application started, pid %d; Go app owns core and playback lifecycle' % child.pid)
            code = child.wait()
    except KeyboardInterrupt:
        if child is not None:
            stop_child(child)
        return False
    finally:
        signal.signal(signal.SIGTERM, original_term)
    # The app only says it wants the menu (exit status 3); loading it is ours.
    to_menu = app_finished(code)
    if to_menu:
        try:
            loaded = load_menu(card)
        except OSError as exc:
            import errno
            trace('could not ask MiSTer for its menu (%s)' % errno.errorcode.get(exc.errno or 0, type(exc).__name__))
            loaded = False
        if not loaded:
            # Still the Exit, not a failure: an updater's start check reads an
            # exit status of 1 within its first seconds as a failed start and
            # can roll the update back.
            trace('Could not return to the MiSTer menu. Use the OSD to leave MisterZine Plex.')
    return to_menu


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['install', 'run', 'rollback', 'remove', 'diagnostics', 'report', 'maintain'])
    parser.add_argument('--card', type=Path, default=Path('/media/fat'))
    parser.add_argument('--package', type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument('--decoder-archive', type=Path, help='accepted for older menu scripts; the release bundles its decoder')
    parser.add_argument('--no-upload', action='store_true', help='write the report without sending it')
    args = parser.parse_args()
    root = args.card / 'misterzine-plex'
    try:
        if args.action in ('diagnostics', 'report'):
            # Reading logs needs no lock, so a report can be sent from the running app.
            try:
                out, code, problem = diagnostics(root, upload=not args.no_upload)
            except OSError as exc:
                # Gathering failed before anything could be sent: say why, in
                # words the app shows, instead of the generic failure below.
                out, code, problem = None, '', 'The report could not be made. ' + write_problem(exc)
            if args.action == 'report':
                # Lines the app parses.
                if out is not None:
                    print('saved: ' + str(out))
                print('code: ' + code if code else 'error: ' + problem, flush=True)
                return 0
            print('Report saved as ' + str(out) if out is not None else 'Report not saved')
            if code:
                print('Report sent. Post this code where you asked for help: ' + code)
            elif problem:
                print('Not sent: ' + problem + (' You can send the saved file instead.' if out is not None else ''))
            print('It can name media titles and playback details. Account files and tokens are never included.')
            return 0 if code or args.no_upload else 1
        if args.action == 'maintain':
            sys.stdout = sys.stderr         # the log; stdout only tells the watcher when to go on
            return maintain(args.card, released=let_the_watcher_go)
        to_menu = False
        # Longer than the watcher lets its entry check run (20 s), so a check
        # never turns a fresh install's launch into a "running" error.
        with locked(root, patience=30):
            if args.action == 'install':
                install(args.card, args.package)
                prune_releases(root)
            elif args.action == 'run':
                to_menu = run(root)
            elif args.action == 'rollback':
                rollback(root)
            elif args.action == 'remove':
                remove(args.card)
        if to_menu:
            # With the lock let go, so Plex picked again meanwhile still launches.
            linger_for_start_check()
            return EXIT_TO_MENU     # the updater's start check reads it
    except KeyboardInterrupt:
        return 0
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as exc:
        # Network exceptions can contain URLs. Never echo arbitrary exception text.
        if isinstance(exc, (ValueError, RuntimeError)):
            print('MisterZine Plex Core: ' + str(exc), file=sys.stderr)
        else:
            print('MisterZine Plex Core: operation failed (' + type(exc).__name__ + '). Check card space, network and package files.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
