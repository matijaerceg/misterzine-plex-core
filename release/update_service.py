#!/usr/bin/env python3
"""Independent Plex installation/update worker. Downloader owns staging only.

Downloader discovery follows the approach documented in MisterZine on-device:
https://github.com/matijaerceg/misterzine-on-device/tree/main/internal/updater
No Update All execution is needed. Downloader itself retains its GPL-3.0 license.
"""
import argparse
import contextlib
import errno
import hashlib
import http.client
import io
import json
import lzma
import os
import platform
from pathlib import Path, PurePosixPath
import re
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import zipfile

import catalogue as releases
import manager

BOOTSTRAP_URL = 'https://raw.githubusercontent.com/MiSTer-devel/Downloader_MiSTer/5d0771359ae396aaea64453e6791ac87781d78f4/dont_download.sh'
BOOTSTRAP_SHA = 'e19ed080deb4ac67f646e4318438427243e2f65fb95c0a1b6e738be4d8ad4903'
BOOTSTRAP_ZIP_SHA = '93c247f04c0082ba724abbd6e041a166351c7c758fe114e52447575aae9a65ed'
HELPERS = manager.HELPERS
SCRIPT_NAMES = ('Run', 'Rollback', 'Diagnostics', 'Uninstall')


class Reason(ValueError):
    """A download problem this service names itself. Only its text may be
    echoed; any other error is described in fixed words, since library
    errors can carry addresses or credentials in their messages."""


class DownloadError(RuntimeError):
    """A download failure whose message is for the person at the screen and
    whose detail, in the same fixed vocabulary, is for the error log."""
    def __init__(self, message, detail):
        super().__init__(message)
        self.detail = detail


def root_for(card):
    card = Path(card).resolve()
    if not card.is_dir() or card == Path('/'):
        raise ValueError('Choose a mounted MiSTer card directory')
    root = card / 'misterzine-plex'
    for path in (root, card / releases.STAGING, card / 'Scripts', root / 'releases', root / 'updates'):
        if path.is_symlink():
            raise ValueError('Plex installation paths cannot be symbolic links')
    return root


def guarded(root, relative):
    path = root / relative
    if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()):
        raise ValueError('Unsafe installation path')
    return path


@contextlib.contextmanager
def worker_lock(root):
    import fcntl
    folder = guarded(root, 'updates')
    folder.mkdir(parents=True, exist_ok=True)
    with (folder / 'worker.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('A Plex update is already running')
        yield


def status(root, stage, release=None, message='', detail=''):
    if not message:
        message = {'download': 'Downloading release...', 'verify': 'Verifying download...',
                   'install': 'Installing release files...'}.get(stage, '')
    value = {'stage': stage, 'message': message, 'pid': os.getpid(), 'updated': time.time()}
    if detail:
        value['detail'] = detail
    if release is not None:
        value['release'] = release
    manager.write_json(root / 'updates/status.json', value)
    print(stage.capitalize() + (': ' + message if message else ''), flush=True)


def other_downloader(proc_root=Path('/proc')):
    names = {'update_all.sh', 'update_all.pyz', 'ua_downloader_bin', 'ua_downloader_dd.pyz',
             'ua_downloader_latest.zip', 'downloader_bin', 'downloader.sh', 'update.sh', 'downloader_latest.zip'}
    for proc in proc_root.iterdir():
        if not proc.name.isdigit() or int(proc.name) == os.getpid():
            continue
        try:
            args = (proc / 'cmdline').read_bytes().decode(errors='replace').split('\0')
        except OSError:
            continue
        if any(Path(a).name in names for a in args):
            return True
    return False


def engine(card, bootstrap=True):
    script = card / 'Scripts/downloader.sh'
    base = card / 'Scripts/.config/downloader'
    if script.is_file():
        return ['/bin/bash', str(script)]
    binary = base / 'downloader_bin'
    if binary.is_file() and os.access(binary, os.X_OK):
        return [str(binary)]
    archive = base / 'downloader_latest.zip'
    if archive.is_file():
        return [sys.executable, str(archive)]
    if not bootstrap:
        raise RuntimeError('Downloader is not installed')
    print('Installing MiSTer Downloader...', flush=True)
    with urllib.request.urlopen(BOOTSTRAP_URL, timeout=30) as response:
        releases.https(response.geturl())
        raw = response.read(2 * 1024 * 1024)
    if hashlib.sha256(raw).hexdigest() != BOOTSTRAP_SHA:
        raise Reason('Downloader bootstrap verification failed')
    data = lzma.decompress(raw.split(b'\n', 7)[7])
    if hashlib.sha256(data).hexdigest() != BOOTSTRAP_ZIP_SHA or not zipfile.is_zipfile(io.BytesIO(data)):
        raise Reason('Downloader archive verification failed')
    manager.atomic(archive, data)
    return [sys.executable, str(archive)]


def database_text(release):
    return '[misterzine_plex]\ndb_url = ' + release['db_url'] + '\nfilter =\n'


def register(card, release):
    # Only this owned drop-in is modified. Existing global configuration survives.
    manager.atomic(card / 'downloader_misterzine_plex.ini', database_text(release).encode())


# Downloader rejects a CURL_SSL value longer than this with a configuration
# error, so a long certificate path must not be passed through it.
CURL_SSL_MAX = 50


def certificate_env(card, system=Path('/etc/ssl/certs/cacert.pem')):
    """Certificate settings for Downloader: the system bundle first, since its
    short path fits Downloader's CURL_SSL limit; the bundle Downloader keeps
    for itself only as a fallback, and then only through SSL_CERT_FILE."""
    for cert in (system, card / 'Scripts/.config/downloader/cacert.pem'):
        if cert.is_file():
            env = {'SSL_CERT_FILE': str(cert)}
            option = '--cacert ' + str(cert)
            if len(option) <= CURL_SSL_MAX:
                env['CURL_SSL'] = option
            return env
    return {}


# Fixed descriptions of failures recognised in Downloader's output. Only these
# words reach the screen and the status file; Downloader's own output does not.
DOWNLOADER_CAUSES = (
    (r'CURL_SSL', 'rejected its certificate option'),
    (r'could not resolve host|name or service not known|temporary failure in name resolution|gaierror', 'could not resolve the download host'),
    (r'certificate|ssl|tls', 'could not verify the server certificate'),
    (r'no space left', 'found no free space'),
    (r'read-only file system', 'found the card read-only'),
    (r'timed out|timeout', 'timed out'),
    (r'connection refused|network is unreachable|no route to host', 'could not connect'),
    (r'\b40[34]\b', 'was refused the release file'),
    (r'\b5\d\d\b|bad gateway|service unavailable', 'got a server error'),
    (r'hash|mismatch', 'saw the release file change'),
    (r'traceback', 'crashed'),
)


def downloader_reason(log, returncode):
    """A short, fixed description of a failed Downloader run: its exit code and
    the first recognised problem in its output log."""
    detail = 'exit ' + str(returncode)
    try:
        text = log.read_text(errors='replace')[-64 * 1024:]
    except OSError:
        return detail
    for pattern, cause in DOWNLOADER_CAUSES:
        if re.search(pattern, text, re.IGNORECASE):
            return cause + ' (' + detail + ')'
    return detail + ', see updates/download-output.log'


def network_reason(exc):
    """A short, fixed description of a failed direct fetch. Server addresses,
    headers and bodies stay out of it."""
    if isinstance(exc, urllib.error.HTTPError):
        return 'was refused the release file (HTTP ' + str(exc.code) + ')'
    if isinstance(exc, Reason):
        return str(exc)
    if isinstance(exc, http.client.HTTPException):
        return 'got a broken response'
    cause = getattr(exc, 'reason', exc)
    if isinstance(cause, socket.gaierror):
        return 'could not resolve the download host'
    if 'CERTIFICATE' in str(cause).upper() or type(cause).__name__.startswith('SSL'):
        return 'could not verify the server certificate'
    if isinstance(cause, (socket.timeout, TimeoutError)) or 'timed out' in str(cause):
        return 'timed out'
    if isinstance(cause, (ConnectionRefusedError, ConnectionResetError)):
        return 'could not connect'
    if isinstance(cause, OSError) and cause.errno == errno.ENOSPC:
        return 'found no free space'
    if isinstance(cause, OSError) and cause.errno == errno.EROFS:
        return 'found the card read-only'
    if isinstance(cause, OSError) and cause.errno is not None:
        return 'failed with ' + os.strerror(cause.errno).lower()
    if isinstance(cause, str):
        return 'could not connect'
    return 'failed with ' + type(cause).__name__


def local_fault(detail):
    """The board's own storage problem, when that is what both paths hit."""
    if 'no free space' in detail:
        return 'your SD card has no free space'
    if 'card read-only' in detail:
        return 'your SD card is read-only. Check it in MiSTer'
    return None


PROBE_URL = 'https://github.com/'
# This code did not exist before 2026, so an earlier clock is wrong, and a
# wrong clock makes every certificate check fail.
CLOCK_FLOOR = 1767225600


def verdict(opener=None, now=time.time):
    """Why every download path failed, for the person at the screen: their
    board's clock or connection, or, when GitHub itself answers, the release.
    None means GitHub was reached, so the release side is at fault."""
    opener = opener or urllib.request.urlopen
    if now() < CLOCK_FLOOR:
        year = time.strftime('%Y', time.gmtime(now()))
        return 'your MiSTer clock reads ' + year + ', so it cannot verify secure sites. Set the time in MiSTer Menu'
    try:
        with opener(urllib.request.Request(PROBE_URL, method='HEAD'), timeout=20) as response:
            response.read(1)
    except (urllib.error.HTTPError, http.client.HTTPException):
        # An answer, even a refusal or a broken one, means GitHub was reached.
        return None
    except (OSError, urllib.error.URLError) as exc:
        cause = network_reason(exc)
        if 'resolve' in cause:
            return 'your MiSTer cannot look up GitHub. Check its network connection and DNS'
        if 'certificate' in cause:
            return 'your MiSTer cannot verify GitHub certificates. Check its clock and network'
        return 'your MiSTer cannot reach GitHub. Check its network connection'
    return None


def fetch_release(card, root, release, opener=None):
    """Stage the release archive directly from its published URL, with the
    same size and digest checks the package gets before installation. The
    file lands in Downloader's staging folder with the content Downloader
    would have written, so a later Downloader run leaves it alone."""
    opener = opener or urllib.request.urlopen
    releases.https(release['url'])
    staging = guarded(card, releases.STAGING)
    staging.mkdir(exist_ok=True)
    part = guarded(root, 'updates/package.part')
    digest, size = hashlib.sha256(), 0
    try:
        with opener(release['url'], timeout=60) as response, part.open('wb') as out:
            try:
                releases.https(response.geturl())
            except ValueError:
                raise Reason('was redirected to an insecure address')
            while True:
                chunk = response.read(256 * 1024)
                if not chunk:
                    break
                size += len(chunk)
                if size > release['size']:
                    raise Reason('found the release file larger than published')
                digest.update(chunk)
                out.write(chunk)
            out.flush()
            os.fsync(out.fileno())
        if size != release['size'] or digest.hexdigest() != release['sha256']:
            raise Reason('found the release file changed or incomplete')
        os.replace(part, staging / 'package.zip')
    finally:
        part.unlink(missing_ok=True)


def staged(card, release):
    archive = guarded(card, releases.STAGING + '/package.zip')
    return archive.is_file() and archive.stat().st_size == release['size'] and manager.digest(archive) == release['sha256']


def download(card, root, release, runner=subprocess.run, fetch=fetch_release, probe=verdict):
    if other_downloader():
        raise RuntimeError('Another Downloader or Update All run is active. Try again when it finishes.')
    problems = []
    log = root / 'updates/download-output.log'
    try:
        command = engine(card)
        ini = root / 'updates/downloader.ini'
        manager.atomic(ini, ('[MiSTer]\nupdate_linux=false\nallow_reboot=0\nstorage_priority=off\n' + database_text(release)).encode())
        env = dict(os.environ, DOWNLOADER_INI_PATH=str(ini), DOWNLOADER_LAUNCHER_PATH=str(card / 'Scripts/downloader.sh'),
                   FORCED_BASE_PATH=str(card), DEFAULT_BASE_PATH=str(card), UPDATE_LINUX='false', ALLOW_REBOOT='0',
                   EXTRA_DROP_IN_DATABASE_FILES='', FAIL_ON_FILE_ERROR='true', PYTHONUTF8='1',
                   LOGFILE=str(root / 'updates/downloader.log'))
        env.update(certificate_env(card))
        # Output belongs in an explicit device diagnostic log, never in the UI or request file.
        with log.open('wb') as out:
            result = runner(command + ['--run-only', releases.DB_ID], env=env, stdout=out, stderr=out, timeout=1800)
        if not result.returncode:
            if staged(card, release):
                return
            # Downloader can report success while its store says the file
            # already lives elsewhere (another drive, an earlier Update All
            # run) or after the staged copy was removed. Fetch it here.
            problems.append('Downloader finished without staging the release on this card')
        else:
            problems.append('Downloader ' + downloader_reason(log, result.returncode))
    except subprocess.TimeoutExpired:
        problems.append('Downloader timed out')
    except (OSError, ValueError, RuntimeError, urllib.error.URLError, http.client.HTTPException) as exc:
        problems.append('Downloader setup ' + network_reason(exc))
    # Downloader could not stage the release. Fetch it directly so one broken
    # Downloader setup does not block every update, and record both outcomes.
    status(root, 'download', release, 'Downloading release directly...')
    try:
        fetch(card, root, release)
    except (OSError, ValueError, RuntimeError, urllib.error.URLError, http.client.HTTPException) as exc:
        problems.append('direct download ' + network_reason(exc))
        # Both paths failed. Say whose problem it is: the board's card, clock
        # or connection, or the release when GitHub itself answers.
        detail = '; '.join(problems)
        why = local_fault(detail) or probe() or 'GitHub is reachable, but the release could not be fetched. Try again later or report this'
        raise DownloadError('Download failed: ' + why + '.', detail)
    with log.open('ab') as out:
        out.write(('\n' + '; '.join(problems) + '. The release was then fetched directly.\n').encode())


def unpack(archive, destination, release):
    if archive.stat().st_size != release['size'] or manager.digest(archive) != release['sha256']:
        raise ValueError('Downloaded release changed or failed verification. Check for updates again.')
    with zipfile.ZipFile(archive) as z:
        seen, total = set(), 0
        for info in z.infolist():
            path = PurePosixPath(info.filename)
            if (path.is_absolute() or '..' in path.parts or '\\' in info.filename or ':' in info.filename
                    or info.filename in seen or stat.S_ISLNK(info.external_attr >> 16)):
                raise ValueError('Unsafe release archive')
            seen.add(info.filename)
            total += info.file_size
            if total > 512 * 1024 * 1024 or len(seen) > 4096:
                raise ValueError('Release archive is too large')
        z.extractall(destination)
    package = destination / 'misterzine-plex-beta'
    manifest = json.loads((package / 'manifest.json').read_text())
    if not releases.manifest_matches(manifest, release):
        raise ValueError('Package does not match the selected release. Check for updates again.')
    if set(manifest.get('files', {})) != manager.PAYLOAD:
        raise ValueError('Unexpected package payload')
    for name, sha in manifest['files'].items():
        if not releases.HASH.fullmatch(str(sha)) or manager.digest(package / 'payload' / name) != sha:
            raise ValueError('Package payload failed verification')
    for name in HELPERS:
        if not (package / name).is_file():
            raise ValueError('Package is missing installation support')
    return package


ERROR_LOG = 'updates/last-error.log'


def reason(exc):
    """The message of an error this service or the manager raised on purpose;
    other errors are named only, so URLs, credentials or child output never
    reach the screen or the status file."""
    return str(exc).rstrip('.') if isinstance(exc, (ValueError, RuntimeError)) else type(exc).__name__


def record(root, summary, exc):
    """Append one failure to the error log and return its screen-safe reason
    and detail. Logging never masks the failure being recorded."""
    why = reason(exc)
    detail = getattr(exc, 'detail', '')
    log = root / ERROR_LOG
    try:
        lines = log.read_text(errors='replace').splitlines()[-19:] if log.is_file() else []
        lines.append(time.strftime('%Y-%m-%d %H:%M:%S ') + summary + ': ' + why + (' [' + detail + ']' if detail else ''))
        manager.atomic(log, ('\n'.join(lines) + '\n').encode())
    except OSError:
        pass
    return why, detail


def failed(root, release, summary, exc):
    """Record why an update step failed: the status the app shows carries a
    short reason, and the error log keeps the last few for diagnostics."""
    why, detail = record(root, summary, exc)
    status(root, 'failed', release, summary + ': ' + why + '. Your current version will keep working.', detail)


def prepare(card, release, downloader=download):
    root = root_for(card)
    releases.entry(release)
    with worker_lock(root):
        try:
            status(root, 'download', release)
            archive = guarded(card, releases.STAGING + '/package.zip')
            # A matching package from an ordinary Downloader run can be reused.
            if not staged(card, release):
                downloader(card, root, release)
            status(root, 'verify', release)
            with tempfile.TemporaryDirectory(prefix='package-', dir=str(root / 'updates')) as tmp:
                # External Downloader runs may replace staging at any time. Verify
                # and extract one private snapshot, never reopen the shared file.
                snapshot = Path(tmp) / 'selected.zip'
                shutil.copyfile(archive, snapshot)
                package = unpack(snapshot, Path(tmp), release)
                status(root, 'install', release)
                manager.stage(card, package)
                # Ready package survives the worker and contains verified maintenance files.
                ready = guarded(root, 'updates/ready')
                if ready.exists():
                    shutil.rmtree(ready)
                shutil.copytree(package, ready)
                manager.write_json(root / 'updates/ready-hashes.json', {
                    name: manager.digest(ready / name) for name in HELPERS + ('manifest.json',)})
            manager.write_json(root / 'updates/ready.json', release)
            status(root, 'ready', release, 'Downloaded. Choose Restart now to install')
        except Exception as exc:
            failed(root, release, 'Update could not be prepared', exc)
            raise


def manager_processes(root, proc_root=Path('/proc')):
    found = []
    for proc in proc_root.iterdir():
        if not proc.name.isdigit() or int(proc.name) == os.getpid():
            continue
        try:
            args = (proc / 'cmdline').read_bytes().split(b'\0')
        except OSError:
            continue
        if len(args) >= 3 and args[1:3] == [str(root / 'manager.py').encode(), b'run']:
            found.append(int(proc.name))
    return found


def stop_manager(root):
    pids = manager_processes(root)
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 12
    def running(pid):
        try:
            # An exited child can remain in /proc until its parent reaps it.
            # It no longer owns the manager lock or app process at this point.
            state = Path('/proc', str(pid), 'stat').read_text().rsplit(')', 1)[1].split()[0]
            if state == 'Z':
                try:
                    os.waitpid(pid, os.WNOHANG)
                except ChildProcessError:
                    pass
                return False
            return True
        except FileNotFoundError:
            return False
    while any(running(pid) for pid in pids):
        if time.monotonic() > deadline:
            raise RuntimeError('Plex has not stopped yet. Return to the MiSTer menu and retry.')
        time.sleep(.1)


def start_and_check(root, timeout=25):
    ready = root / 'updates/started'
    ready.unlink(missing_ok=True)
    env = dict(os.environ, MISTERZINE_PLEX_READY_FILE=str(ready))
    child = subprocess.Popen([sys.executable, str(root / 'manager.py'), 'run', '--card', str(root.parent)],
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True, env=env)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        started = ready.is_file()
        code = child.poll()
        if started:
            if code is None:
                time.sleep(2)
                code = child.poll()
            # Exit to MiSTer menu, chosen once the app was up, is no failed start.
            return code in (None, manager.EXIT_TO_MENU)
        if code is not None:
            return False
        time.sleep(.2)
    stop_manager(root)
    return False


def activate(card, launch=start_and_check):
    root = root_for(card)
    with worker_lock(root):
        release = None
        try:
            release = releases.entry(json.loads((root / 'updates/ready.json').read_text()))
            package = root / 'updates/ready'
            verified = json.loads((root / 'updates/ready-hashes.json').read_text())
            if set(verified) != set(HELPERS + ('manifest.json',)) or any(
                    manager.digest(package / name) != digest for name, digest in verified.items()):
                raise ValueError('Prepared installation support changed. Check for updates again.')
            manifest = json.loads((package / 'manifest.json').read_text())
            if not releases.manifest_matches(manifest, release):
                raise ValueError('Prepared release metadata changed')
            old = manager.read_state(root) if (root / 'active.json').exists() else None
            # Copy runtime before activation so recovery does not depend on the new helper.
            backups = {name: (root / name).read_bytes() for name in HELPERS if (root / name).exists()}
            dropin = card / 'downloader_misterzine_plex.ini'
            old_registration = dropin.read_bytes() if dropin.exists() else None
            for name, sha in manifest.get('files', {}).items():
                if name not in manager.PAYLOAD or manager.digest(package / 'payload' / name) != sha:
                    raise ValueError('Prepared payload changed. Check for updates again.')
        except Exception as exc:
            # Nothing has changed yet; the reason still belongs on the screen,
            # not only on the worker's stderr.
            failed(root, release, 'Could not restart Plex', exc)
            raise
        installed = False
        status(root, 'activating', release, 'Restarting Plex...')
        try:
            recovery = root / 'updates/recovery'
            recovery.mkdir(exist_ok=True)
            for name, data in backups.items():
                manager.atomic(recovery / name, data)
            manager.write_json(recovery / 'selection.json', old)
            manager.atomic(recovery / 'registration', old_registration or b'')
            manager.write_json(root / 'updates/activation.json', {
                'helpers': list(backups), 'target': release['version'],
                'previous': old['current'] if old else None})
            stop_manager(root)
            # Take the manager lock before touching the installation. A holder
            # this worker did not recognise is reported, never killed.
            with manager.locked(root):
                installed = True
                manager.install(card, package)
                register(card, release)
            if not launch(root):
                raise RuntimeError('The new release did not start')
        except Exception as exc:
            if not installed:
                (root / 'updates/activation.json').unlink(missing_ok=True)
                failed(root, release, 'Could not restart Plex', exc)
                raise
            # The installation changed. Keep the cause, and keep the screen
            # busy while the previous release is put back.
            why, detail = record(root, 'Could not restart Plex', exc)
            cause = 'Could not restart Plex: ' + why + '.'
            status(root, 'activating', release, cause + ' Restoring the previous release...', detail)
            try:
                stop_manager(root)
                with manager.locked(root):
                    for name, data in backups.items():
                        manager.atomic(root / name, data)
                    if old is not None:
                        manager.write_json(root / 'active.json', old)
                    else:
                        (root / 'active.json').unlink(missing_ok=True)
                    if old_registration is None:
                        dropin.unlink(missing_ok=True)
                    else:
                        manager.atomic(dropin, old_registration)
                    manager.repair_menu_entry(card)
                    (root / 'updates/activation.json').unlink(missing_ok=True)
            except Exception as restore_exc:
                # The journal stays: the next launch of Plex finishes the restore.
                restore_why, _ = record(root, 'Could not restore the previous release', restore_exc)
                status(root, 'failed', release, cause + ' Restoring the previous release also failed: ' + restore_why
                       + '. Return to the MiSTer menu and open Plex again to finish restoring it.', detail)
                raise
            status(root, 'failed', release, cause + (' The previous release was restored.' if old
                   else ' No earlier release is installed. Run MisterZine-Plex-Install to retry.'), detail)
            if old:
                if launch is start_and_check:
                    # Older releases do not emit a readiness marker. Restore them
                    # without terminating a healthy app for lacking that marker.
                    subprocess.Popen([sys.executable, str(root / 'manager.py'), 'run', '--card', str(card)],
                                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL, start_new_session=True)
                else:
                    launch(root)
            raise
        (root / 'updates/ready.json').unlink(missing_ok=True)
        (root / 'updates/activation.json').unlink(missing_ok=True)
        try:
            # The new release started, so nothing can restore an older one:
            # keep it and the previous release for Rollback, remove the rest.
            manager.prune_releases(root)
        except (OSError, ValueError) as exc:
            record(root, 'Could not remove old releases', exc)
        status(root, 'complete', release, 'Update installed')


def uninstall(card, keep=True):
    root = root_for(card)
    if other_downloader():
        raise RuntimeError('Wait for Downloader or Update All to finish before uninstalling.')
    with worker_lock(root):
        stop_manager(root)
        manager.stop_menu_launcher(card)
        with manager.locked(root):
            manager.menu_entries(card, enable=False)
            (card / 'downloader_misterzine_plex.ini').unlink(missing_ok=True)
            # These are exact, application-owned names, never a wildcard over Scripts.
            for prefix in ('MisterZine-Plex-', 'MisterZine-Plex-Core-'):
                for label in ('Run', 'Install', 'Install-Public', 'Install-Beta', 'Uninstall', 'Rollback', 'Diagnostics', 'Remove'):
                    for suffix in ('.sh', '.sh.disabled'):
                        path = card / 'Scripts' / (prefix + label + suffix)
                        path.unlink(missing_ok=True)
            (card / '.misterzine-plex-core.mgl').unlink(missing_ok=True)
            staged = guarded(card, releases.STAGING)
            if staged.exists():
                shutil.rmtree(staged)
            (root / 'active.json').unlink(missing_ok=True)
            if keep:
                for name in ('releases', 'updates', 'ffmpeg', 'decoder.json', 'decoder-notices', 'ffmpeg-7.0.2-armhf-static.tar.xz',
                             manager.MAINTENANCE):
                    path = guarded(root, name)
                    if path.is_dir():
                        shutil.rmtree(path)
                    else:
                        path.unlink(missing_ok=True)
                for name in HELPERS:
                    (root / name).unlink(missing_ok=True)
            else:
                shutil.rmtree(root)
    print('Plex removed. Settings and acquired codes kept.' if keep else 'Plex and its saved data removed.')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=('install', 'prepare', 'activate', 'uninstall'))
    p.add_argument('--card', type=Path, default=Path('/media/fat'))
    p.add_argument('--request', type=Path)
    p.add_argument('--catalogue', default=releases.CATALOGUE_URL)
    p.add_argument('--channel', choices=('public', 'beta'))
    p.add_argument('--yes', action='store_true', help='Install the selected release without prompting')
    p.add_argument('--download-db-url', help='Immutable database for a pinned installer')
    args = p.parse_args()
    if args.action == 'install' and (platform.system() != 'Linux' or platform.machine() != 'armv7l' or not Path('/dev/MiSTer_cmd').exists()):
        raise RuntimeError('Installation requires MiSTer Linux on supported ARM hardware.')
    root = root_for(args.card)
    if args.action == 'uninstall':
        print('1. Remove Plex, keep settings and codes (default)\n2. Remove Plex and all its saved data\n3. Cancel')
        choice = input('Choice [1]: ').strip()
        if choice in ('', '1'):
            uninstall(args.card)
        elif choice == '2' and input('Type REMOVE to delete all Plex data: ').strip() == 'REMOVE':
            uninstall(args.card, keep=False)
        return
    if args.action == 'activate':
        activate(args.card)
        return
    if args.request:
        release = releases.entry(json.loads(args.request.read_text()))
    else:
        available = releases.fetch(args.catalogue)['releases']
        channel = args.channel or ('public' if 'public' in available else 'beta')
        if channel not in available:
            raise ValueError('No release is available for that channel')
        release = available[channel]
        print('MisterZine Plex - ' + release['version'])
        if channel == 'beta':
            print('Playback in this early-access release requires a paid Patreon code.')
        if not args.yes and input('Install this release? [Y/n] ').strip().lower() not in ('', 'y', 'yes'):
            return
    if args.download_db_url:
        releases.https(args.download_db_url)
        def pinned_download(card, root, selected):
            download(card, root, dict(selected, db_url=args.download_db_url))
        prepare(args.card, release, pinned_download)
    else:
        prepare(args.card, release)
    if args.action == 'install':
        activate(args.card)


def cli():
    try:
        main()
    except (OSError, ValueError, RuntimeError, KeyError, subprocess.SubprocessError, zipfile.BadZipFile,
            http.client.HTTPException) as exc:
        # Do not echo URLs, credentials, or arbitrary child output.
        print(str(exc) if isinstance(exc, (ValueError, RuntimeError)) else 'Operation failed. Check network, free space and the installed package.', file=sys.stderr)
        if getattr(exc, 'detail', ''):
            print('Details: ' + exc.detail, file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    cli()
