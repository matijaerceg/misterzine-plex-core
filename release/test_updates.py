import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch
import zipfile

import build_distribution
import catalogue
import manager

# Tests never talk to the live report service.
manager.REPORT_SERVICE = ''
import update_service as service
import publish

stop_real_manager = service.stop_manager


class ProcessTests(unittest.TestCase):
    def test_startup_requires_the_selected_bitstream(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc=Path(tmp)/'12';proc.mkdir()
            (proc/'comm').write_text('MiSTer\n')
            (proc/'cmdline').write_bytes(b'MiSTer\0/media/fat/old.rbf\0')
            self.assertFalse(manager.selected_core(Path('/media/fat/new.rbf'),Path(tmp)))
            self.assertTrue(manager.selected_core(Path('/media/fat/old.rbf'),Path(tmp)))
            # The same core in a MiSTer process that predates load_core is not a switch.
            self.assertFalse(manager.selected_core(Path('/media/fat/old.rbf'),Path(tmp),before={12}))
            self.assertEqual(manager.mister_processes(Path(tmp)),{12:b'/media/fat/old.rbf'})

    def test_exited_child_does_not_block_restart(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            (root/'manager.py').write_text('import time\ntime.sleep(30)\n')
            child=subprocess.Popen([service.sys.executable,str(root/'manager.py'),'run'])
            try:
                time.sleep(.05)
                stop_real_manager(root)
                child.wait(timeout=1)
            finally:
                if child.poll() is None:child.kill();child.wait()

    def test_start_check_counts_exit_to_the_menu_as_a_start(self):
        real_sleep = time.sleep
        for status, runs, started in ((manager.EXIT_TO_MENU, .3, True), (None, 1.5, True), (0, .3, False), (1, .3, False)):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                (root / 'updates').mkdir()
                # up (the readiness marker), then gone with this status after `runs` s
                (root / 'manager.py').write_text(
                    'import os, sys, time\n'
                    'open(os.environ["MISTERZINE_PLEX_READY_FILE"], "w").write("ready")\n'
                    'time.sleep(%s)\nsys.exit(%d)\n' % (runs, status or 0))
                with patch.object(service.time, 'sleep', lambda s: real_sleep(min(s, .6))):
                    self.assertEqual(service.start_and_check(root, timeout=10), started)

    def test_an_update_launch_writes_the_menu_run_log(self):
        real_sleep = time.sleep
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'misterzine-plex'
            (root / 'updates').mkdir(parents=True)
            (root / 'manager.py').write_text(
                'import os, sys\n'
                'print("launch: app started", flush=True)\n'
                'print("MisterZine Plex Core: failed", file=sys.stderr, flush=True)\n'
                'open(os.environ["MISTERZINE_PLEX_READY_FILE"], "w").write("ready")\n'
                'sys.exit(%d)\n' % manager.EXIT_TO_MENU)
            log = Path(tmp) / 'menu-run.log'
            log.write_text('the launch before the update\n')
            for path, written in ((log, True), (Path(tmp) / 'missing/menu-run.log', False)):
                with self.subTest(written=written), patch.object(service, 'LAUNCH_LOG', str(path)), \
                        patch.object(service.time, 'sleep', lambda s: real_sleep(min(s, .6))):
                    # A log that cannot be opened is no reason to leave Plex stopped.
                    self.assertTrue(service.start_and_check(root, timeout=10))
            self.assertEqual(log.read_text(), 'launch: app started\nMisterZine Plex Core: failed\n')
            self.assertEqual(Path(str(log) + '.1').read_text(), 'the launch before the update\n')

    def test_an_older_updaters_start_check_survives_an_exit(self):
        def legacy_start_check(root, timeout=10):
            # start_and_check as releases up to 73924e1 have it: the update
            # worker is the installed release's, the manager the new one's
            ready = root / 'updates/started'
            env = dict(os.environ, MISTERZINE_PLEX_READY_FILE=str(ready))
            child = subprocess.Popen([service.sys.executable, str(root / 'manager.py')], env=env)
            try:
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    if child.poll() is not None:
                        return False
                    if ready.is_file():
                        time.sleep(2)
                        return child.poll() is None
                    time.sleep(.2)
                return False
            finally:
                child.wait()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'updates').mkdir()
            (root / 'manager.py').write_text(
                'import os, sys, time\nsys.path.insert(0, %r)\nimport manager\n'
                'open(os.environ["MISTERZINE_PLEX_READY_FILE"], "w").write("ready")\n'
                'time.sleep(.3)  # the app is up, and the user chooses Exit\n'
                'manager.linger_for_start_check()\nsys.exit(manager.EXIT_TO_MENU)\n'
                % str(Path(manager.__file__).resolve().parent))
            self.assertTrue(legacy_start_check(root))


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.card = Path(self.temp.name) / 'card'
        self.card.mkdir()
        self.root = self.card / 'misterzine-plex'
        self.root.mkdir()
        self.fixture = Path(self.temp.name) / 'package'
        self.fixture.mkdir()
        for target in ('decoder',):
            p = patch.object(manager, target)
            p.start(); self.addCleanup(p.stop)
        p = patch.object(service, 'stop_manager')
        p.start(); self.addCleanup(p.stop)
        p = patch.object(service, 'other_downloader', return_value=False)
        p.start(); self.addCleanup(p.stop)

    def release(self, ident='fixture-1', channel='public', helpers=None):
        version = '1.0.0' if channel == 'public' else '1.1.0-beta.1'
        access = None if channel == 'public' else {'batch': 'fixture', 'sha256': hashlib.sha256(b'012345').hexdigest()}
        files = {}
        package = self.fixture / ident / 'misterzine-plex-beta'
        (package / 'payload').mkdir(parents=True)
        for name in manager.PAYLOAD:
            data = (ident + name).encode()
            (package / 'payload' / name).write_bytes(data)
            files[name] = hashlib.sha256(data).hexdigest()
        manifest = {'id': ident, 'version': version, 'channel': channel, 'access': access, 'files': files}
        (package / 'manifest.json').write_text(json.dumps(manifest))
        for name in service.HELPERS:
            (package / name).write_text((helpers or {}).get(name, '# synthetic helper ' + ident))
        archive = self.fixture / (ident + '.zip')
        with zipfile.ZipFile(archive, 'w') as z:
            for path in package.rglob('*'):
                if path.is_file():
                    z.write(path, path.relative_to(package.parent).as_posix())
        release = dict(id=ident, version=version, channel=channel, access=access, notes='Synthetic test release',
                       url='https://example.org/' + archive.name, db_url='https://example.org/' + channel + '.json.zip',
                       size=archive.stat().st_size, sha256=manager.digest(archive))
        return release, archive, package

    def deliver(self, archive):
        def download(card, root, release):
            path = card / catalogue.STAGING / 'package.zip'
            path.parent.mkdir(exist_ok=True)
            path.write_bytes(archive.read_bytes())
        return download

    def test_prepare_does_not_activate_and_restart_retains_old(self):
        old, _, package = self.release('old')
        manager.install(self.card, package)
        (self.root / 'plexcrt.json').write_text('account fixture')
        release, archive, _ = self.release('new', 'beta')
        service.prepare(self.card, release, self.deliver(archive))
        self.assertEqual(manager.read_state(self.root)['current'], 'old')
        self.assertEqual(json.loads((self.root / 'updates/status.json').read_text())['stage'], 'ready')
        service.activate(self.card, lambda root: True)
        self.assertEqual(manager.read_state(self.root), {'current': 'new', 'previous': 'old'})
        self.assertEqual((self.root / 'plexcrt.json').read_text(), 'account fixture')
        self.assertIn(release['db_url'], (self.card / 'downloader_misterzine_plex.ini').read_text())
        manager.rollback(self.root)
        self.assertEqual(manager.read_state(self.root)['current'], 'old')
        self.assertEqual((self.root / 'manager.py').read_text(), '# synthetic helper old')

    def test_ready_download_of_the_running_release_is_not_activated(self):
        # A script installed the prepared release after it was downloaded.
        _, _, old = self.release('old')
        manager.install(self.card, old)
        release, archive, package = self.release('new', 'beta')
        service.prepare(self.card, release, self.deliver(archive))
        manager.install(self.card, package)
        launched = []
        with self.assertRaises(ValueError):
            service.activate(self.card, lambda root: launched.append(root) or True)
        self.assertEqual(launched, [])
        self.assertEqual(manager.read_state(self.root), {'current': 'new', 'previous': 'old'})
        status = json.loads((self.root / 'updates/status.json').read_text())
        self.assertEqual(status['stage'], 'failed')
        self.assertIn('already installed', status['message'])

    def test_failed_launch_restores_runtime_registration_and_selection(self):
        _, _, package = self.release('old')
        manager.install(self.card, package)
        original = manager.read_state(self.root)
        drop = self.card / 'downloader_misterzine_plex.ini'; drop.write_text('original registration')
        r, z, _ = self.release('new')
        service.prepare(self.card, r, self.deliver(z))
        calls = []
        def launch(root):
            calls.append(manager.read_state(root)['current'])
            return len(calls) > 1
        with self.assertRaises(RuntimeError):
            service.activate(self.card, launch)
        self.assertEqual(calls, ['new', 'old'])
        self.assertEqual(manager.read_state(self.root), original)
        self.assertEqual(drop.read_text(), 'original registration')
        self.assertEqual((self.root / 'manager.py').read_text(), '# synthetic helper old')
        # The restored helpers predate the direct-launch entry, so the entry follows them.
        self.assertEqual((self.card / 'MisterZine Plex Core.mgl').read_bytes(), manager.LEGACY_ENTRY)

    def test_corrupt_download_and_interruption_preserve_current(self):
        _, _, old = self.release('old')
        manager.install(self.card, old)
        r, z, _ = self.release('new')
        z.write_bytes(b'corrupted')
        with self.assertRaises(ValueError):
            service.prepare(self.card, r, self.deliver(z))
        def fail(*args):
            raise OSError('synthetic failure')
        with self.assertRaises(OSError):
            service.prepare(self.card, r, fail)
        self.assertEqual(manager.read_state(self.root)['current'], 'old')
        # The reason reaches the status the app shows and the error log, but an
        # unexpected error is named only, never echoed.
        status = json.loads((self.root / 'updates/status.json').read_text())
        self.assertIn('Update could not be prepared: OSError.', status['message'])
        log = (self.root / service.ERROR_LOG).read_text().splitlines()
        self.assertEqual(len(log), 2)
        self.assertIn('failed verification', log[0])
        self.assertTrue(log[1].endswith('Update could not be prepared: OSError'))
        self.assertNotIn('synthetic failure', log[1])

    def test_external_staging_is_reused_without_running_downloader(self):
        r, z, _ = self.release()
        self.deliver(z)(self.card, self.root, r)
        service.prepare(self.card, r, lambda *args: self.fail('Downloader should not run'))
        self.assertFalse((self.root / 'active.json').exists())

    def test_unsafe_archives_and_identity_mismatch(self):
        for name in ('../escape', '/absolute', 'misterzine-plex-beta/../../escape', 'C:/escape'):
            with self.subTest(name=name):
                r, z, _ = self.release('unsafe-' + str(abs(hash(name))))
                with zipfile.ZipFile(z, 'a') as archive:
                    archive.writestr(name, 'bad')
                r.update(size=z.stat().st_size, sha256=manager.digest(z))
                with tempfile.TemporaryDirectory() as target, self.assertRaises(ValueError):
                    service.unpack(z, Path(target), r)
        r, z, _ = self.release('mismatch')
        r['id'] = 'different'
        with tempfile.TemporaryDirectory() as target, self.assertRaises(ValueError):
            service.unpack(z, Path(target), r)

    def test_uninstall_keeps_data_and_does_not_touch_other_apps(self):
        _, _, package = self.release()
        manager.install(self.card, package)
        (self.card / 'downloader_misterzine_plex.ini').write_text('fixture')
        unrelated = self.card / 'downloader.ini'; unrelated.write_text('[other]\n')
        other_app = self.card / 'misterzine'; other_app.mkdir(); (other_app / 'keep').touch()
        for name in ('plexcrt.json', 'cache/art', 'beta-unlocks/fixture.receipt', 'beta-keys/fixture.key'):
            path = self.root / name; path.parent.mkdir(exist_ok=True); path.write_text('keep')
        service.uninstall(self.card)
        self.assertFalse((self.root / 'releases').exists())
        self.assertFalse((self.root / 'active.json').exists())
        self.assertFalse((self.card / 'downloader_misterzine_plex.ini').exists())
        self.assertEqual((self.root / 'beta-unlocks/fixture.receipt').read_text(), 'keep')
        self.assertEqual(unrelated.read_text(), '[other]\n')
        self.assertTrue((other_app / 'keep').exists())
        service.uninstall(self.card, keep=False)
        self.assertFalse(self.root.exists())

    def test_downloader_engines_and_isolated_environment(self):
        scripts = self.card / 'Scripts'; scripts.mkdir()
        base = scripts / '.config/downloader'; base.mkdir(parents=True)
        with self.assertRaises(RuntimeError):
            service.engine(self.card, bootstrap=False)
        archive = base / 'downloader_latest.zip'; archive.touch()
        self.assertEqual(service.engine(self.card)[-1], str(archive))
        if os.name != 'nt':
            binary = base / 'downloader_bin'; binary.write_text(''); binary.chmod(0o755)
            self.assertEqual(service.engine(self.card), [str(binary)])
        launcher = scripts / 'downloader.sh'; launcher.touch()
        self.assertEqual(service.engine(self.card), ['/bin/bash', str(launcher)])
        r, z, _ = self.release()
        (self.root / 'updates').mkdir()
        def run(command, **kw):
            self.assertEqual(command[-2:], ['--run-only', 'misterzine_plex'])
            staging = self.card / catalogue.STAGING
            staging.mkdir(exist_ok=True)
            (staging / 'package.zip').write_bytes(z.read_bytes())
            env = kw['env']
            self.assertEqual(env['UPDATE_LINUX'], 'false')
            self.assertEqual(env['ALLOW_REBOOT'], '0')
            self.assertEqual(env['EXTRA_DROP_IN_DATABASE_FILES'], '')
            ini = Path(env['DOWNLOADER_INI_PATH']).read_text()
            self.assertIn('filter =', ini)
            self.assertNotIn('[distribution_mister]', ini)
            return subprocess.CompletedProcess(command, 0)
        service.download(self.card, self.root, r, run)

    def test_certificate_option_fits_downloader_limit(self):
        # Downloader refuses CURL_SSL over 50 characters, so the long bundle path
        # under Scripts must never be passed as an option.
        scripts = self.card / 'Scripts/.config/downloader'; scripts.mkdir(parents=True)
        own = scripts / 'cacert.pem'; own.write_text('')
        missing = self.card / 'no-system-bundle.pem'
        env = service.certificate_env(self.card, system=missing)
        self.assertEqual(env['SSL_CERT_FILE'], str(own))
        self.assertNotIn('CURL_SSL', env)
        system = self.card / 'cacert.pem'; system.write_text('')
        env = service.certificate_env(self.card, system=system)
        self.assertEqual(env['SSL_CERT_FILE'], str(system))
        option = '--cacert ' + str(system)
        self.assertEqual(env.get('CURL_SSL'), option if len(option) <= service.CURL_SSL_MAX else None)

        self.assertLessEqual(len('--cacert /etc/ssl/certs/cacert.pem'), service.CURL_SSL_MAX)

    def opener(self, data):
        class Response(io.BytesIO):
            def geturl(self):
                return 'https://objects.example.org/redirected/package.zip'
        return lambda url, timeout: Response(data)

    def failing_runner(self, output):
        def run(command, **kw):
            kw['stdout'].write(output)
            return subprocess.CompletedProcess(command, 1)
        return run

    def test_downloader_success_without_a_staged_file_falls_back_to_a_direct_fetch(self):
        # Seen after an uninstall: Downloader exits 0 but leaves nothing on this card.
        r, z, _ = self.release()
        (self.card / 'Scripts').mkdir(); (self.card / 'Scripts/downloader.sh').touch()
        (self.root / 'updates').mkdir()
        def idle_runner(command, **kw):
            kw['stdout'].write(b'Installed:\nnone.\n')
            return subprocess.CompletedProcess(command, 0)
        downloader = lambda card, root, release: service.download(
            card, root, release, idle_runner, lambda *a: service.fetch_release(*a, opener=self.opener(z.read_bytes())))
        service.prepare(self.card, r, downloader)
        self.assertEqual(manager.digest(self.card / catalogue.STAGING / 'package.zip'), r['sha256'])
        self.assertEqual(json.loads((self.root / 'updates/status.json').read_text())['stage'], 'ready')
        log = (self.root / 'updates/download-output.log').read_text()
        self.assertIn('Downloader finished without staging the release on this card. The release was then fetched directly.', log)

    def test_failed_downloader_run_falls_back_to_a_direct_fetch(self):
        r, z, _ = self.release()
        (self.card / 'Scripts').mkdir(); (self.card / 'Scripts/downloader.sh').touch()
        (self.root / 'updates').mkdir()
        output = b'curl: (60) SSL certificate problem: certificate is not yet valid\nhttps://secret.example.org/x\n'
        downloader = lambda card, root, release: service.download(
            card, root, release, self.failing_runner(output), lambda *a: service.fetch_release(*a, opener=self.opener(z.read_bytes())))
        service.prepare(self.card, r, downloader)
        staged = self.card / catalogue.STAGING / 'package.zip'
        self.assertEqual(manager.digest(staged), r['sha256'])
        self.assertFalse((self.root / 'updates/package.part').exists())
        status = json.loads((self.root / 'updates/status.json').read_text())
        self.assertEqual(status['stage'], 'ready')
        log = (self.root / 'updates/download-output.log').read_text()
        self.assertIn('Downloader could not verify the server certificate (exit 1). The release was then fetched directly.', log)

    def test_both_download_paths_failing_name_fixed_reasons_only(self):
        r, _, _ = self.release()
        (self.card / 'Scripts').mkdir(); (self.card / 'Scripts/downloader.sh').touch()
        (self.root / 'updates').mkdir()
        output = b'downloader.ini: CURL_SSL value too long https://secret.example.org/cert\n'
        def refused(url, timeout):
            raise service.urllib.error.HTTPError(url, 404, 'Not Found', {}, None)
        # GitHub answers, so the screen blames the release; the log keeps both reasons.
        with self.assertRaises(RuntimeError):
            service.prepare(self.card, r, lambda card, root, release: service.download(
                card, root, release, self.failing_runner(output), lambda *a: service.fetch_release(*a, opener=refused), lambda: None))
        status = json.loads((self.root / 'updates/status.json').read_text())
        self.assertIn('Download failed: GitHub is reachable, but the release could not be fetched. Try again later or report this.', status['message'])
        self.assertNotIn('Downloader', status['message'])
        log = (self.root / service.ERROR_LOG).read_text()
        self.assertIn('[Downloader rejected its certificate option (exit 1); '
                      'direct download was refused the release file (HTTP 404)]', log)
        self.assertNotIn('example.org', status['message'] + log)
        # A missing Downloader that cannot be bootstrapped is reported the same
        # way, and with no DNS the screen blames the connection.
        (self.card / 'Scripts/downloader.sh').unlink()
        def offline(url, timeout):
            raise service.urllib.error.URLError(service.socket.gaierror(-2, 'Name or service not known'))
        with patch.object(service.urllib.request, 'urlopen', offline), self.assertRaises(RuntimeError) as caught:
            service.download(self.card, self.root, r, self.failing_runner(b''), lambda *a: service.fetch_release(*a, opener=offline))
        self.assertEqual(str(caught.exception), 'Download failed: your MiSTer cannot look up GitHub. Check its network connection and DNS.')
        self.assertEqual(caught.exception.detail, 'Downloader setup could not resolve the download host; '
                         'direct download could not resolve the download host')

    def test_decoder_site_failure_names_whose_problem_it_is(self):
        # The FFmpeg decoder comes from its own site once the release is
        # staged. A failure there used to reach the screen as the bare library
        # error ("Update could not be prepared: URLError").
        _, _, old = self.release('old')
        manager.install(self.card, old)
        r, z, _ = self.release('new')
        e = service.urllib.error
        def fails_with(cause):
            def decoder(*a):
                try:
                    raise cause
                except (OSError, service.http.client.HTTPException) as exc:
                    raise manager.DecoderFetchError('Could not fetch the FFmpeg decoder') from exc
            return decoder
        manager.decoder.side_effect = fails_with(e.URLError(service.socket.gaierror(-2, 'no https://secret.example.org/')))
        board = 'your MiSTer cannot look up GitHub. Check its network connection and DNS'
        with patch.object(service, 'verdict', lambda: board), self.assertRaises(RuntimeError) as caught:
            service.prepare(self.card, r, self.deliver(z))
        self.assertEqual(str(caught.exception), 'Download failed: ' + board + '.')
        status = json.loads((self.root / 'updates/status.json').read_text())
        self.assertEqual(status['message'], 'Update could not be prepared: Download failed: ' + board + '. Your current version will keep working.')
        self.assertEqual(status['detail'], 'decoder download could not resolve the download host')
        self.assertNotIn('example.org', status['message'] + (self.root / service.ERROR_LOG).read_text())
        self.assertEqual(manager.read_state(self.root)['current'], 'old')
        self.assertFalse((self.root / 'updates/ready.json').exists())
        # With GitHub answering, the decoder's own site is blamed.
        manager.decoder.side_effect = fails_with(e.URLError(service.socket.timeout('timed out')))
        with patch.object(service, 'verdict', lambda: None), self.assertRaises(RuntimeError) as caught:
            service.prepare(self.card, r, self.deliver(z))
        self.assertEqual(str(caught.exception), 'Download failed: GitHub is reachable, but the FFmpeg decoder '
                         'could not be fetched from its own site. Try again later or report this.')
        self.assertEqual(caught.exception.detail, 'decoder download timed out')
        # A full card is the card's problem, found without a probe.
        error = service.decoder_error(OSError(service.errno.ENOSPC, 'No space left on device'), probe=self.fail)
        self.assertEqual(str(error), 'Download failed: your SD card has no free space.')

    def test_library_errors_and_broken_responses_stay_in_fixed_words(self):
        r, z, _ = self.release()
        (self.card / 'Scripts').mkdir(); (self.card / 'Scripts/downloader.sh').touch()
        (self.root / 'updates').mkdir()
        e = service.urllib.error
        # A library error message, such as a malformed redirect that urlsplit
        # rejects, may carry an address or credentials: it is named only.
        self.assertEqual(service.network_reason(ValueError('Invalid IPv6 URL https://user:hunter2@evil.example/')), 'failed with ValueError')
        self.assertEqual(service.network_reason(RuntimeError('https://user:hunter2@evil.example/')), 'failed with RuntimeError')
        self.assertEqual(service.network_reason(service.http.client.IncompleteRead(b'partial')), 'got a broken response')
        self.assertEqual(service.network_reason(service.Reason('was redirected to an insecure address')), 'was redirected to an insecure address')
        # A redirect to a credential-bearing or insecure address is refused in fixed words.
        class Redirected(io.BytesIO):
            def geturl(self):
                return 'https://user:hunter2@evil.example/package.zip'
        with self.assertRaises(service.Reason) as caught:
            service.fetch_release(self.card, self.root, r, lambda url, timeout: Redirected(z.read_bytes()))
        self.assertEqual(str(caught.exception), 'was redirected to an insecure address')
        # A truncated HTTP response during the direct fetch, or while
        # bootstrapping Downloader, is handled and reported like any other failure.
        class Truncated(io.BytesIO):
            def geturl(self):
                return 'https://objects.example.org/package.zip'
            def read(self, n=-1):
                raise service.http.client.IncompleteRead(b'partial')
        with self.assertRaises(RuntimeError) as caught:
            service.download(self.card, self.root, r, self.failing_runner(b'Bad status code 500'),
                             lambda *a: service.fetch_release(*a, opener=lambda url, timeout: Truncated()), lambda: None)
        self.assertEqual(caught.exception.detail, 'Downloader got a server error (exit 1); direct download got a broken response')
        self.assertNotIn('partial', str(caught.exception) + caught.exception.detail)
        (self.card / 'Scripts/downloader.sh').unlink()
        with patch.object(service.urllib.request, 'urlopen', lambda url, timeout: Truncated()):
            service.download(self.card, self.root, r, self.failing_runner(b''), lambda *a: service.fetch_release(*a, opener=self.opener(z.read_bytes())))
        self.assertIn('Downloader setup got a broken response. The release was then fetched directly.',
                      (self.root / 'updates/download-output.log').read_text())

    def test_full_or_read_only_card_is_not_blamed_on_the_release(self):
        r, _, _ = self.release()
        (self.card / 'Scripts').mkdir(); (self.card / 'Scripts/downloader.sh').touch()
        (self.root / 'updates').mkdir()
        for code, output, expected in ((service.errno.ENOSPC, b'OSError: [Errno 28] No space left on device', 'your SD card has no free space'),
                                       (service.errno.EROFS, b'OSError: [Errno 30] Read-only file system', 'your SD card is read-only. Check it in MiSTer')):
            def fetch(*a, code=code):
                raise OSError(code, service.os.strerror(code))
            with self.assertRaises(RuntimeError) as caught:
                service.download(self.card, self.root, r, self.failing_runner(output), fetch, lambda: self.fail('no probe needed'))
            self.assertEqual(str(caught.exception), 'Download failed: ' + expected + '.')

    def test_verdict_separates_the_board_from_the_release(self):
        e = service.urllib.error
        def probe(exc):
            def opener(request, timeout):
                self.assertEqual(request.get_method(), 'HEAD')
                raise exc
            return opener
        self.assertIn('cannot look up GitHub', service.verdict(probe(e.URLError(service.socket.gaierror(-2, 'x')))))
        self.assertIn('cannot verify GitHub certificates', service.verdict(probe(e.URLError('[SSL: CERTIFICATE_VERIFY_FAILED]'))))
        self.assertIn('cannot reach GitHub', service.verdict(probe(e.URLError(service.socket.timeout()))))
        self.assertIn('cannot reach GitHub', service.verdict(probe(ConnectionResetError())))
        self.assertIsNone(service.verdict(probe(e.HTTPError('https://github.com/', 403, 'Forbidden', {}, None))))
        self.assertIsNone(service.verdict(self.opener(b'')))
        # A clock from before this code existed explains certificate failures without a probe.
        self.assertIn('clock reads 2016', service.verdict(lambda *a: self.fail('no probe'), now=lambda: 1461000000))

    def test_direct_fetch_verifies_size_and_digest_and_leaves_no_partial_file(self):
        r, z, _ = self.release()
        (self.root / 'updates').mkdir()
        for data in (z.read_bytes() + b'x', z.read_bytes()[:-1], b'y' * r['size']):
            with self.assertRaises(ValueError) as caught:
                service.fetch_release(self.card, self.root, r, self.opener(data))
            self.assertIn('release file', str(caught.exception))
        self.assertFalse((self.card / catalogue.STAGING / 'package.zip').exists())
        self.assertFalse((self.root / 'updates/package.part').exists())
        def plain_http(url, timeout):
            class Response(io.BytesIO):
                def geturl(self):
                    return 'http://example.org/package.zip'
            return Response(z.read_bytes())
        with self.assertRaises(ValueError):
            service.fetch_release(self.card, self.root, r, plain_http)
        service.fetch_release(self.card, self.root, r, self.opener(z.read_bytes()))
        self.assertEqual(manager.digest(self.card / catalogue.STAGING / 'package.zip'), r['sha256'])

    def test_failure_reasons_are_fixed_words(self):
        log = self.root / 'output.log'
        for text, expected in ((b'Could not resolve host: raw.githubusercontent.com', 'could not resolve the download host (exit 1)'),
                               (b'OSError: [Errno 28] No space left on device', 'found no free space (exit 1)'),
                               (b'Traceback (most recent call last):', 'crashed (exit 1)'),
                               (b'Bad status code 503', 'got a server error (exit 1)'),
                               (b'something else entirely', 'exit 1, see updates/download-output.log')):
            log.write_bytes(text)
            self.assertEqual(service.downloader_reason(log, 1), expected)
        self.assertEqual(service.downloader_reason(self.root / 'missing.log', 2), 'exit 2')
        e = service.urllib.error
        self.assertEqual(service.network_reason(e.URLError(service.socket.timeout('timed out'))), 'timed out')
        self.assertEqual(service.network_reason(e.URLError(ConnectionRefusedError())), 'could not connect')
        self.assertEqual(service.network_reason(e.URLError(OSError(101, 'Network is unreachable'))), 'failed with network is unreachable')
        self.assertEqual(service.network_reason(e.URLError('[SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed')), 'could not verify the server certificate')
        self.assertEqual(service.network_reason(service.Reason('Downloader archive verification failed')), 'Downloader archive verification failed')
        self.assertEqual(service.network_reason(ValueError('Downloader archive verification failed')), 'failed with ValueError')

    def test_diagnostics_include_download_logs_without_addresses(self):
        (self.root / 'updates').mkdir()
        (self.root / 'updates/download-output.log').write_text('first\ncurl: (6) Could not resolve host https://raw.example.org/db.json.zip\n')
        (self.root / 'updates/downloader.log').write_text('first\nDownloader 2.0 https://example.org/x\n')
        out, code, problem = manager.diagnostics(self.root, upload=False)
        report = out.read_text()
        self.assertEqual(out, self.root / 'report.txt')
        self.assertTrue(report.startswith(manager.REPORT_MAGIC + '\n'))
        self.assertIn('== LOG download-output.log', report)
        self.assertIn('Could not resolve host [server address removed]', report)
        self.assertIn('Downloader 2.0 [server address removed]', report)
        self.assertIn('== SYSTEM', report)
        self.assertNotIn('example.org', report)

    def test_console_leaves_the_framebuffer_while_the_app_runs(self):
        first, second = self.card / 'tty2', self.card / 'tty7'
        first.write_text(''); second.write_text('')
        modes = {str(first): manager.KD_TEXT, str(second): manager.KD_GRAPHICS}
        opened, calls = {}, []
        real_open = os.open
        def fake_open(path, flags, *a):
            fd = real_open(path, flags, *a)
            opened[fd] = str(path)
            return fd
        def ioctl(fd, request, arg):
            path = opened[fd]
            if request == manager.KDGETMODE:
                arg[0] = modes[path]
            else:
                calls.append((os.path.basename(path), arg))
                modes[path] = arg
        active = [str(first)]
        with patch.object(manager.os, 'open', fake_open), \
                contextlib.redirect_stdout(io.StringIO()) as out:
            console = manager.GraphicsConsole(lambda: active[0], ioctl)
            console.check(first=True)
            # Mid-run the foreground moves to another console, which is then put in text mode.
            active[0] = str(second)
            modes[str(second)] = manager.KD_TEXT
            console.check()
            console.check()
            console.release()
            console.release()
        self.assertEqual(calls, [('tty2', manager.KD_GRAPHICS), ('tty7', manager.KD_GRAPHICS),
                                 ('tty2', manager.KD_TEXT), ('tty7', manager.KD_TEXT)])
        self.assertIn('tty2 was in text mode', out.getvalue())
        calls.clear()
        modes[str(second)] = manager.KD_GRAPHICS   # a console already in graphics mode is left alone
        with patch.object(manager.os, 'open', fake_open), contextlib.redirect_stdout(io.StringIO()):
            quiet = manager.GraphicsConsole(lambda: str(second), ioctl)
            quiet.check(first=True)
            quiet.release()
        self.assertEqual(calls, [])
        # A console that cannot be named is never touched.
        with patch.object(manager.os, 'open', fake_open), contextlib.redirect_stdout(io.StringIO()) as out:
            unnamed = manager.GraphicsConsole(lambda: None, ioctl)
            unnamed.check(first=True)
            unnamed.release()
        self.assertEqual(calls, [])
        self.assertIn('console unknown', out.getvalue())
        self.assertIsNone(manager.active_console(self.card / 'missing'))
        # A stop right after the switch still leaves the change on record.
        modes[str(first)] = manager.KD_TEXT
        def interrupted_ioctl(fd, request, arg):
            ioctl(fd, request, arg)
            if request == manager.KDSETMODE:
                raise KeyboardInterrupt()
        calls.clear()
        with patch.object(manager.os, 'open', fake_open), contextlib.redirect_stdout(io.StringIO()):
            stopped = manager.GraphicsConsole(lambda: str(first), interrupted_ioctl)
            with self.assertRaises(KeyboardInterrupt):
                stopped.check(first=True)
            stopped.ioctl = ioctl
            stopped.release()
        self.assertEqual(calls, [('tty2', manager.KD_GRAPHICS), ('tty2', manager.KD_TEXT)])

    def test_a_failed_launch_still_resumes_holders_and_the_console(self):
        sleeper = subprocess.Popen(['sleep', '30'])
        self.addCleanup(sleeper.kill)
        released = []
        class Console:
            def check(self, first=False):
                pass
            def release(self):
                released.append(True)
        def state(want=None):
            # Signals land asynchronously; give the state a moment to settle.
            for _ in range(100):
                s = (Path('/proc') / str(sleeper.pid) / 'stat').read_text().split(') ')[1][0]
                if want is None or (s == 'T') == (want == 'T'):
                    return s
                time.sleep(0.01)
            return s
        with contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(OSError):
                with manager.screen_to_ourselves(lambda: [(sleeper.pid, 'sleep')], Console):
                    self.assertEqual(state('T'), 'T')
                    raise OSError('could not start the app')
        self.assertEqual(released, [True])
        self.assertNotEqual(state('S'), 'T')
        self.assertIs(signal.getsignal(signal.SIGTERM), signal.SIG_DFL)
        # A console that cannot even be set up still leaves nothing paused.
        def broken():
            raise KeyboardInterrupt()
        with contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(KeyboardInterrupt):
                with manager.screen_to_ourselves(lambda: [(sleeper.pid, 'sleep')], broken):
                    pass
        self.assertNotEqual(state('S'), 'T')

    def test_framebuffer_holders_exclude_main_and_ourselves(self):
        proc = self.card / 'proc'
        for pid, name, target in ((40, 'frontend', '/dev/fb0'), (41, 'MiSTer_Zaparoo', '/dev/fb0'),
                                  (42, 'python3', '/dev/null'), (os.getpid(), 'python3', '/dev/fb0')):
            (proc / str(pid) / 'fd').mkdir(parents=True)
            (proc / str(pid) / 'comm').write_text(name + '\n')
            os.symlink(target, proc / str(pid) / 'fd' / '5')
        self.assertEqual(manager.fb_holders(proc), [(40, 'frontend')])
        self.assertEqual(manager.fb_holders(proc, exclude={40}), [])

    def test_diagnostics_system_facts_stay_free_of_addresses(self):
        (self.card / 'MiSTer.ini').write_text('[MiSTer]\nvga_scaler=0 ; comment\nypbpr=1\nkey_menu_as_rgui=0\n'
                                              '[Menu]\ndirect_video=1\n[ao486]\nvga_scaler=1\n[MisterZine Plex Core]\nvsync_adjust=2\n')
        (self.card / 'linux').mkdir()
        (self.card / 'linux/user-startup.sh').write_text('#!/bin/bash\n/media/fat/Scripts/zaparoo.sh -service $1\n')
        self.root.mkdir(parents=True, exist_ok=True)
        (self.root / 'plexcrt.json').write_text(json.dumps({'server_url': 'https://192-168-1-9.abcdef.plex.direct:32400',
                                                            'token': 'TEST-ONLY-token', 'bitrate': 3000}))
        facts = manager.system_facts(self.root, ['TEST-ONLY-token'], proc_root=self.card / 'no-proc')
        self.assertEqual(facts['video_settings'], {'MiSTer': {'vga_scaler': '0', 'ypbpr': '1'}, 'Menu': {'direct_video': '1'},
                                                   'MisterZine Plex Core': {'vsync_adjust': '2'}})
        self.assertEqual(facts['startup_hooks'], ['zaparoo'])
        self.assertEqual(facts['server'], {'scheme': 'https', 'port': 32400, 'kind': 'plex.direct', 'private_lan': True,
                                           'bitrate': 3000, 'progressive': None})
        self.assertNotIn('192-168', json.dumps(facts))
        self.assertNotIn('TEST-ONLY', json.dumps(facts))

    def test_publishing_database_owns_only_staging_and_installer_is_standalone(self):
        r, z, _ = self.release()
        out = self.fixture / 'dist'
        published = build_distribution.build(z, 'v1.0.0', 'Release notes', out)
        catalogue.entry(published)
        with zipfile.ZipFile(out / 'public.json.zip') as db:
            data = json.loads(db.read('misterzine_plex.json'))
            self.assertEqual(set(data['files']), {'misterzine-plex-downloads/package.zip'})
        script = (out / 'MisterZine-Plex-Install-Public.sh').read_text()
        self.assertIn('service.pyz', script)
        self.assertNotIn('update_all', script)
        self.assertNotIn('012345', script)
        self.assertIn('--channel public', script)
        self.assertIn('--yes', script)
        self.assertFalse((out / 'MisterZine-Plex-Install-Beta.sh').exists())
        pinned = (out / 'MisterZine-Plex-Install-1.0.0.sh').read_text()
        self.assertIn(published['sha256'], pinned)
        self.assertIn('--request', pinned)
        self.assertIn('/v1.0.0/release-db.json.zip', pinned)
        self.assertEqual((out/'release-db.json.zip').read_bytes(), (out/'public.json.zip').read_bytes())

    def test_menu_entry_repair_and_uninstall_preserve_other_startup_commands(self):
        startup = self.card / 'linux/user-startup.sh'
        startup.parent.mkdir()
        startup.write_text('#!/bin/bash\necho other-app\nexit 0\n')
        _, _, package = self.release()
        manager.install(self.card, package)
        manager.install(self.card, package)
        self.assertTrue((self.root/'updates').is_dir())
        text = startup.read_text()
        self.assertEqual(text.count(manager.BOOT_START), 1)
        self.assertLess(text.index(manager.BOOT_START), text.index('exit 0'))
        self.assertTrue((self.card/'MisterZine Plex Core.mgl').exists())
        self.assertFalse((self.card/'Scripts/MisterZine-Plex-Run.sh').exists())
        service.uninstall(self.card)
        self.assertEqual(startup.read_text(), '#!/bin/bash\necho other-app\nexit 0\n')
        self.assertFalse((self.card/'MisterZine Plex Core.mgl').exists())

    def test_update_keeps_only_current_and_previous_release(self):
        for ident in ('one', 'two', 'three'):
            _, _, package = self.release(ident)
            manager.install(self.card, package)
        self.assertEqual(sorted(p.name for p in (self.root / 'releases').iterdir()), ['one', 'three', 'two'])
        release, archive, _ = self.release('four', 'beta')
        service.prepare(self.card, release, self.deliver(archive))
        service.activate(self.card, lambda root: True)
        self.assertEqual(sorted(p.name for p in (self.root / 'releases').iterdir()), ['four', 'three'])
        manager.rollback(self.root)
        self.assertEqual(manager.read_state(self.root)['current'], 'three')

    def test_failed_update_removes_no_release(self):
        for ident in ('one', 'two'):
            _, _, package = self.release(ident)
            manager.install(self.card, package)
        release, archive, _ = self.release('three', 'beta')
        service.prepare(self.card, release, self.deliver(archive))
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(RuntimeError):
            service.activate(self.card, lambda root: False)
        self.assertEqual(manager.read_state(self.root), {'current': 'two', 'previous': 'one'})
        self.assertEqual(sorted(p.name for p in (self.root / 'releases').iterdir()), ['one', 'three', 'two'])

    def test_zaparoo_lists_plex_under_other_and_follows_the_selection(self):
        reloads = []
        def fresh(ident):
            _, _, package = self.release(ident)
            (package / 'menu_launcher.py').write_text("SELECTIONS = ('MisterZine Plex Core',)\n")
            (package / 'manager.py').write_text('def zaparoo_entry(): pass\n')
            return package
        entry = self.card / 'zaparoo/launchers' / manager.ZAPAROO_ENTRY
        with patch.object(manager, 'reload_zaparoo', lambda card: reloads.append(card)):
            manager.install(self.card, fresh('one'))
            self.assertFalse(entry.exists())               # no Zaparoo, no entry
            (self.card / 'zaparoo').mkdir()
            manager.install(self.card, fresh('two'))
            self.assertIn('load_path = "misterzine-plex/releases/two/MisterZine Plex Core"', entry.read_text())
            self.assertIn('category = "Other"', entry.read_text())
            count = len(reloads)
            manager.repair_menu_entry(self.card)            # unchanged: no rewrite, no reload
            self.assertEqual(len(reloads), count)
            manager.rollback(self.root)
            self.assertIn('releases/one/MisterZine Plex Core"', entry.read_text())
            self.assertEqual(len(reloads), count + 1)
            with contextlib.redirect_stdout(io.StringIO()):
                service.uninstall(self.card)
            self.assertFalse(entry.exists())
            self.assertEqual(len(reloads), count + 2)
            self.assertTrue((self.card / 'zaparoo').is_dir())   # Zaparoo's own folders stay

    def test_rollback_to_a_manager_without_zaparoo_support_removes_the_entry(self):
        (self.card / 'zaparoo').mkdir()
        entry = self.card / 'zaparoo/launchers' / manager.ZAPAROO_ENTRY
        watcher = "SELECTIONS = ('MisterZine Plex Core',)\n"
        _, _, old = self.release('old', helpers={'menu_launcher.py': watcher})
        _, _, new = self.release('new', helpers={'menu_launcher.py': watcher, 'manager.py': 'def zaparoo_entry(): pass\n'})
        with patch.object(manager, 'reload_zaparoo', lambda card: None):
            manager.install(self.card, old)
            self.assertFalse(entry.exists())
            manager.install(self.card, new)
            self.assertTrue(entry.exists())
            manager.rollback(self.root)
        # The restored manager would not remove it on uninstall, so it goes now.
        self.assertFalse(entry.exists())
        self.assertTrue((self.card / 'MisterZine Plex Core.mgl').exists())

    def test_pending_recovery_keeps_every_release(self):
        for ident in ('one', 'two', 'three'):
            _, _, package = self.release(ident)
            manager.install(self.card, package)
        manager.write_json(self.root / 'updates/activation.json', {'helpers': []})
        self.assertEqual(manager.prune_releases(self.root), [])
        self.assertEqual(sorted(p.name for p in (self.root / 'releases').iterdir()), ['one', 'three', 'two'])
        (self.root / 'updates/activation.json').unlink()
        self.assertEqual(manager.prune_releases(self.root), ['one'])

    def test_failed_first_install_leaves_no_zaparoo_entry(self):
        (self.card / 'zaparoo').mkdir()
        entry = self.card / 'zaparoo/launchers' / manager.ZAPAROO_ENTRY
        release, archive, _ = self.release('first', 'beta', {'menu_launcher.py': "SELECTIONS = ()\n",
                                                              'manager.py': 'def zaparoo_entry(): pass\n'})
        service.prepare(self.card, release, self.deliver(archive))
        seen = []
        def launch(root):
            seen.append(entry.exists())
            return False
        with patch.object(manager, 'reload_zaparoo', lambda card: None), \
                contextlib.redirect_stdout(io.StringIO()), self.assertRaises(RuntimeError):
            service.activate(self.card, launch)
        self.assertEqual(seen, [True])              # listed while the new release was tried
        self.assertFalse((self.root / 'active.json').exists())
        self.assertFalse(entry.exists())
        self.assertFalse((self.card / 'MisterZine Plex Core.mgl').exists())

    def test_zaparoo_reload_runs_the_service_script(self):
        script = self.card / 'Scripts/zaparoo.sh'
        script.parent.mkdir()
        marker = self.card / 'reloaded'
        script.write_text('#!/bin/sh\necho "$1" > ' + str(marker) + '\n')
        script.chmod(0o755)
        manager.reload_zaparoo(self.card)
        self.assertEqual(marker.read_text().strip(), '-reload')

    CURRENT = {'menu_launcher.py': "SELECTIONS = ('MisterZine Plex Core',)\n", 'manager.py': 'def zaparoo_entry(): pass\n'}

    def installed(self, ident='one', zaparoo=True):
        """A release whose watcher and manager know the direct entry and
        Zaparoo, installed, with this code counting as its manager."""
        if zaparoo:
            (self.card / 'zaparoo').mkdir(exist_ok=True)
        _, _, package = self.release(ident, helpers=self.CURRENT)
        with patch.object(manager, 'reload_zaparoo', lambda card: 'ok'):
            manager.install(self.card, package)
        p = patch.object(manager, 'SELF_DIGEST', manager.digest(self.root / 'manager.py'))
        p.start(); self.addCleanup(p.stop)
        p = patch.object(manager, 'zaparoo_version', return_value=None)
        p.start(); self.addCleanup(p.stop)
        return self.card / 'zaparoo/launchers' / manager.ZAPAROO_ENTRY

    def test_upkeep_puts_this_releases_entries_right_and_then_writes_nothing(self):
        startup = self.card / 'linux/user-startup.sh'
        startup.parent.mkdir()
        startup.write_text('#!/bin/bash\necho other-app\n')
        entry = self.installed()
        mgl = self.card / 'MisterZine Plex Core.mgl'
        script = self.card / 'Scripts/MisterZine-Plex-Rollback.sh'
        right = {path: path.read_bytes() for path in (entry, mgl, startup, script)}
        # What an older release's updater can leave behind.
        entry.unlink()
        mgl.write_bytes(manager.LEGACY_ENTRY)
        script.write_text('#!/bin/bash\necho retired\n')
        # The boot hook belongs to install and uninstall: other tools edit that file too.
        edited = '#!/bin/bash\necho other-app\n'
        startup.write_text(edited)
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertTrue(manager.reconcile(self.card))
        self.assertEqual(startup.read_text(), edited)
        startup.write_bytes(right[startup])
        self.assertEqual({path: path.read_bytes() for path in right}, right)
        record = json.loads((self.root / manager.MAINTENANCE).read_text())
        self.assertEqual(record['repaired'], ['menu entry', 'scripts', 'zaparoo entry'])
        self.assertEqual((record['release'], record['zaparoo_entry'], record['errors'], record['skipped']),
                         ('one', 'current', {}, None))
        # Once right, a check writes nothing at all.
        for path in list(right) + [self.root / manager.MAINTENANCE]:
            os.utime(path, (1_000_000_000, 1_000_000_000))
        self.assertFalse(manager.reconcile(self.card))
        for path in list(right) + [self.root / manager.MAINTENANCE]:
            self.assertEqual(path.stat().st_mtime, 1_000_000_000, path.name)

    def test_upkeep_failure_in_one_entry_leaves_the_others_to_be_put_right(self):
        entry = self.installed()
        entry.unlink()
        with patch.object(manager, 'wrappers', side_effect=PermissionError), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertTrue(manager.reconcile(self.card))
        self.assertTrue(entry.exists())
        self.assertEqual(json.loads((self.root / manager.MAINTENANCE).read_text())['errors'],
                         {'scripts': 'PermissionError'})

    def test_upkeep_leaves_the_entries_alone_when_it_should(self):
        entry = self.installed()
        entry.unlink()
        def skipped():
            self.assertFalse(manager.reconcile(self.card))
            self.assertFalse(entry.exists())
            return json.loads((self.root / manager.MAINTENANCE).read_text())['skipped']
        with patch.object(manager, 'SELF_DIGEST', 'another release'):
            self.assertEqual(skipped(), 'another manager installed')
        journal = self.root / 'updates/activation.json'
        journal.write_text('{}')
        self.assertEqual(skipped(), 'update in progress')
        journal.unlink()
        disabled = self.card / 'Scripts/MisterZine-Plex-Rollback.sh.disabled'
        disabled.write_text('')
        self.assertEqual(skipped(), 'entries switched off')
        disabled.unlink()
        (self.root / 'active.json').unlink()
        self.assertEqual(skipped(), 'not installed')

    def test_upkeep_waits_for_the_updater_to_commit_and_never_runs_for_a_failed_start(self):
        (self.card / 'zaparoo').mkdir()
        _, _, package = self.release('old', helpers=self.CURRENT)
        with patch.object(manager, 'reload_zaparoo', lambda card: 'ok'):
            manager.install(self.card, package)
        helpers = dict(self.CURRENT, **{'manager.py': 'def zaparoo_entry(): pass\n# new\n'})
        release, archive, new = self.release('new', 'beta', helpers)
        service.prepare(self.card, release, self.deliver(archive))
        seen = []
        def launch(result):
            def check(root):
                seen.append(manager.reconcile_when_settled(self.card, 'new'))
                return result
            return check
        with patch.object(manager, 'SELF_DIGEST', manager.digest(new / 'manager.py')), \
                patch.object(manager, 'reload_zaparoo', lambda card: 'ok'), \
                patch.object(manager, 'zaparoo_version', return_value=None), \
                contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(RuntimeError):
                service.activate(self.card, launch(False))
            # Undone: the old release is selected again, so the new one writes nothing.
            self.assertEqual(manager.reconcile_when_settled(self.card, 'new'), (True, False))
            self.assertNotIn('repaired', manager.noted(self.root))
            service.prepare(self.card, release, self.deliver(archive))
            service.activate(self.card, launch(True))
            self.assertGreaterEqual(len(seen), 2)
            self.assertEqual(set(seen), {(False, False)})       # held off during every start check
            entry = self.card / 'zaparoo/launchers' / manager.ZAPAROO_ENTRY
            entry.unlink()
            self.assertEqual(manager.reconcile_when_settled(self.card, 'new'), (True, True))
        self.assertIn('releases/new/', entry.read_text())

    def test_upkeep_after_start_waits_beside_the_launch_until_no_update_runs(self):
        import fcntl
        import threading
        entry = self.installed()
        entry.unlink()
        reloads = []
        with (self.root / 'updates/worker.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            with patch.object(manager, 'refresh_zaparoo', lambda card: reloads.append(card)), \
                    contextlib.redirect_stdout(io.StringIO()):
                worker = threading.Thread(target=manager.upkeep_after_start, args=(self.root, 'one', 30, .01))
                worker.start()
                time.sleep(.2)
                self.assertFalse(entry.exists())
                fcntl.flock(lock, fcntl.LOCK_UN)
                worker.join(10)
        self.assertFalse(worker.is_alive())
        self.assertTrue(entry.exists())
        self.assertEqual(reloads, [self.card])

    def test_boot_upkeep_stands_aside_for_the_app_an_install_or_an_update(self):
        import fcntl
        entry = self.installed()
        entry.unlink()
        out, freed = io.StringIO(), []
        def released():
            # Both locks are free by the time the watcher is let go.
            with manager.no_update_running(self.root) as clear, manager.locked(self.root):
                freed.append(clear)
        with contextlib.redirect_stdout(out):
            with manager.locked(self.root):
                self.assertEqual(manager.maintain(self.card, wait=0, released=lambda: freed.append('app')), 0)
            self.assertFalse(entry.exists())
            # During an update the manager lock is left alone: the release its
            # start check launches must be able to take it.
            with (self.root / 'updates/worker.lock').open('a') as lock, \
                    patch.object(manager, 'locked', side_effect=AssertionError('manager lock taken')):
                fcntl.flock(lock, fcntl.LOCK_EX)
                manager.maintain(self.card, wait=0, released=lambda: freed.append('update'))
            self.assertFalse(entry.exists())
            with patch.object(manager, 'reload_zaparoo', lambda card: 'ok'):
                manager.maintain(self.card, wait=0, released=released)
        self.assertTrue(entry.exists())
        self.assertEqual(freed, ['app', 'update', True])
        self.assertIn('Plex or its installer is running', out.getvalue())
        self.assertIn('an update is under way', out.getvalue())
        self.assertIn('Zaparoo reload ok', out.getvalue())

    def test_a_missed_zaparoo_reload_stays_pending_until_one_succeeds(self):
        entry = self.installed()
        script = self.card / 'Scripts/zaparoo.sh'
        answer = self.card / 'answer'
        script.write_text('#!/bin/sh\nexit $(cat ' + str(answer) + ')\n')
        script.chmod(0o755)
        answer.write_text('1')
        # Not answering may mean starting, with the old launchers already read.
        self.assertEqual(manager.reload_zaparoo(self.card), 'exit 1')
        self.assertTrue(manager.noted(self.root)['zaparoo_pending'])
        manager.upkeep_after_start(self.root, 'one')                  # still refused: still pending
        self.assertTrue(manager.noted(self.root)['zaparoo_pending'])
        answer.write_text('0')
        manager.upkeep_after_start(self.root, 'one')                  # entry unchanged, reload still due
        self.assertTrue(entry.exists())
        self.assertEqual((manager.noted(self.root)['zaparoo_reload'], manager.noted(self.root)['zaparoo_pending']),
                         ('ok', False))
        os.utime(self.root / manager.MAINTENANCE, (1_000_000_000, 1_000_000_000))
        answer.write_text('1')
        manager.upkeep_after_start(self.root, 'one')                  # nothing due: no reload, no write
        self.assertEqual(manager.noted(self.root)['zaparoo_reload'], 'ok')
        self.assertEqual((self.root / manager.MAINTENANCE).stat().st_mtime, 1_000_000_000)

    def test_report_says_why_plex_is_or_is_not_in_zaparoo(self):
        entry = self.installed()
        running = lambda: {'version': '2.17.2', 'platform': 'mister'}
        facts = manager.zaparoo_facts(self.root, running)
        self.assertEqual(facts, {'installed': True, 'script': False, 'entry': 'current', 'config_override': False,
                                 'other_files_with_id': 0, 'core': {'version': '2.17.2', 'platform': 'mister'}})
        config = self.card / 'zaparoo/config.toml'
        config.write_text('# [[launchers.custom]]\n# id = "misterzine-plex"\n[[launchers.custom]]\nid = "other"\n')
        self.assertFalse(manager.zaparoo_facts(self.root, running)['config_override'])
        config.write_text('[[ launchers.custom ]]  # mine\nid = \'misterzine-plex\'\n')
        self.assertTrue(manager.zaparoo_facts(self.root, running)['config_override'])
        (entry.parent / 'copy.toml').write_bytes(entry.read_bytes())
        self.assertEqual(manager.zaparoo_facts(self.root, running)['other_files_with_id'], 1)
        entry.write_text(entry.read_text().replace('/one/', '/zero/'))
        self.assertEqual(manager.zaparoo_facts(self.root, running)['entry'], 'stale')
        entry.unlink()
        facts = manager.zaparoo_facts(self.root, lambda: None)
        self.assertEqual((facts['entry'], facts['core']), ('absent', 'not answering'))
        (self.root / 'updates/worker.log').write_text('Complete: Update installed\n')
        with patch.object(manager, 'zaparoo_version', return_value=None):
            text = manager.build_report(self.root, proc_root=self.card / 'no-proc', tmp=self.card / 'no-tmp')
        self.assertIn('zaparoo: {"config_override": true, "core": "not answering", "entry": "absent"', text)
        self.assertIn('== LOG worker.log', text)
        self.assertNotIn(str(self.card), text.split('== LOG')[0])

    def test_watcher_waits_for_the_boot_check_to_let_go_of_the_locks_but_not_for_a_reload(self):
        import menu_launcher
        # A stand-in manager: records its arguments, holds "the locks" for a
        # moment, lets the watcher go as the real one does, then "reloads".
        (self.root / 'manager.py').write_text(
            'import sys, time\n'
            'sys.path.insert(0, ' + repr(str(Path(manager.__file__).parent)) + ')\n'
            'import manager\n'
            'open(' + repr(str(self.card / 'args')) + ', "w").write(" ".join(sys.argv[1:]))\n'
            'time.sleep(.3)\n'
            'manager.let_the_watcher_go()\n'
            'print("after the watcher went")\n'
            'time.sleep(2)\n')
        log = self.card / 'maintain.log'
        with patch.object(menu_launcher, 'MAINTAIN_LOG', str(log)):
            started = time.monotonic()
            child = menu_launcher.start_upkeep(self.card, self.root)
            waited = time.monotonic() - started
        self.assertTrue(.3 <= waited < 1.8, waited)
        self.assertIsNone(child.poll())                                 # its reload goes on
        self.assertEqual((self.card / 'args').read_text(), 'maintain --card ' + str(self.card))
        child.wait(10)
        self.assertIn('after the watcher went', log.read_text())

    def test_watcher_stops_a_boot_check_that_holds_the_locks_too_long(self):
        import menu_launcher
        (self.root / 'manager.py').write_text(
            'import fcntl, os, sys, time\n'
            'lock = open(' + repr(str(self.root / 'manager.lock')) + ', "a")\n'
            'fcntl.flock(lock, fcntl.LOCK_EX)\n'
            'open(' + repr(str(self.card / 'held')) + ', "w").write(str(os.getpid()))\n'
            'time.sleep(30)\n')
        with patch.object(menu_launcher, 'MAINTAIN_LOG', str(self.card / 'maintain.log')):
            started = time.monotonic()
            self.assertIsNone(menu_launcher.start_upkeep(self.card, self.root, patience=1))
        self.assertLess(time.monotonic() - started, 5)
        self.assertTrue((self.card / 'held').exists())
        with manager.locked(self.root):                 # stopped, so the lock is free for a launch
            pass

    def test_a_zaparoo_reload_is_pending_from_before_it_runs(self):
        self.installed()
        script = self.card / 'Scripts/zaparoo.sh'
        seen = self.card / 'seen'
        script.write_text('#!/bin/sh\ncat ' + str(self.root / manager.MAINTENANCE) + ' > ' + str(seen) + '\n')
        script.chmod(0o755)
        self.assertEqual(manager.reload_zaparoo(self.card), 'ok')
        self.assertTrue(json.loads(seen.read_text())['zaparoo_pending'])
        self.assertFalse(manager.noted(self.root)['zaparoo_pending'])
        # A changed entry is pending as soon as it is written, before any reload.
        (self.card / 'zaparoo/launchers' / manager.ZAPAROO_ENTRY).unlink()
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertTrue(manager.reconcile(self.card))
        self.assertTrue(manager.noted(self.root)['zaparoo_pending'])

    def test_unattended_pinned_install_does_not_fetch_latest_or_prompt(self):
        release, _, _ = self.release()
        request = self.fixture/'request.json'
        request.write_text(json.dumps(release))
        with patch('sys.argv', ['worker','install','--card',str(self.card),'--request',str(request),'--yes',
                                '--download-db-url','https://example.org/immutable.json.zip']), \
             patch.object(service.platform,'system',return_value='Linux'), \
             patch.object(service.platform,'machine',return_value='armv7l'), \
             patch.object(Path,'exists',return_value=True), \
             patch('builtins.input',side_effect=AssertionError('unexpected prompt')), \
             patch.object(catalogue,'fetch',side_effect=AssertionError('unexpected latest lookup')), \
             patch.object(service,'prepare') as prepare, patch.object(service,'activate'), \
             patch.object(service,'download') as download:
            service.main()
            self.assertEqual(prepare.call_args.args[1], release)
            prepare.call_args.args[2](self.card,self.root,release)
            self.assertEqual(download.call_args.args[2]['db_url'],'https://example.org/immutable.json.zip')
            self.assertEqual(release['db_url'],'https://example.org/public.json.zip')

    def test_metadata_rejects_unknown_channels_and_secrets(self):
        r, _, _ = self.release()
        catalogue.catalogue({'schema': 1, 'releases': {'public': r}})
        for field, value in [('url', 'http://example.org/file'), ('id', '../escape'), ('size', -1), ('sha256', 'bad'), ('channel', 'other')]:
            with self.subTest(field=field), self.assertRaises(ValueError):
                catalogue.entry(dict(r, **{field: value}))
        with self.assertRaises(ValueError):
            catalogue.entry(dict(r, access={'code': '012345'}))

    def test_tampered_helpers_and_worker_exclusion(self):
        r, archive, _ = self.release()
        service.prepare(self.card, r, self.deliver(archive))
        (self.root / 'updates/ready/manager.py').write_text('altered')
        with self.assertRaises(ValueError):
            service.activate(self.card, launch=lambda root: True)
        with service.worker_lock(self.root), self.assertRaises(RuntimeError):
            service.prepare(self.card, r, self.deliver(archive))

    def test_bootstrap_rejects_unverified_download(self):
        class Response(io.BytesIO):
            def geturl(self): return service.BOOTSTRAP_URL
        with patch.object(service.urllib.request, 'urlopen', return_value=Response(b'corrupt')), self.assertRaises(ValueError):
            service.engine(self.card)
        self.assertFalse((self.card / 'Scripts/.config/downloader/downloader_latest.zip').exists())

    def test_interrupted_activation_restores_selection_and_helpers(self):
        _, _, old = self.release('old')
        manager.install(self.card, old)
        recovery = self.root / 'updates/recovery'; recovery.mkdir(parents=True)
        manager.write_json(recovery/'selection.json', manager.read_state(self.root))
        (recovery/'registration').write_bytes(b'[misterzine_plex]\n')
        (recovery/'manager.py').write_bytes((self.root/'manager.py').read_bytes())
        manager.write_json(self.root/'updates/activation.json', {'helpers':['manager.py']})
        manager.write_json(self.root/'active.json', {'current':'failed','previous':'old'})
        (self.root/'manager.py').write_text('new helper')
        with patch.dict(os.environ, {}, clear=True):
            self.assertTrue(manager.recover_activation(self.root))
        self.assertEqual(manager.read_state(self.root)['current'],'old')
        self.assertEqual((self.root/'manager.py').read_bytes(),(old/'manager.py').read_bytes())
        self.assertFalse((self.root/'updates/activation.json').exists())

    def test_publishing_defaults_to_local_preparation(self):
        _, archive, _ = self.release()
        with patch.object(publish, 'run', side_effect=AssertionError('unexpected remote action')):
            publish.publish(archive,'v1.0.0','Synthetic notes',self.fixture/'publish')


class FailureReasonTests(UpdateTests):
    """Every way activation can go wrong leaves its reason in the status the
    Updates screen shows, so a user does not have to ask what happened."""

    def prepared(self):
        _, _, old = self.release('old')
        manager.install(self.card, old)
        r, z, _ = self.release('new')
        service.prepare(self.card, r, self.deliver(z))
        return r

    def status(self):
        return json.loads((self.root / 'updates/status.json').read_text())

    def test_busy_manager_lock_fails_before_anything_changes(self):
        import fcntl
        self.prepared()
        holder = (self.root / 'manager.lock').open('a')
        self.addCleanup(holder.close)
        fcntl.flock(holder, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with self.assertRaises(RuntimeError):
            service.activate(self.card, lambda root: self.fail('installed under a busy lock'))
        s = self.status()
        self.assertEqual(s['stage'], 'failed')
        self.assertIn('Could not restart Plex: MisterZine Plex Core is running', s['message'])
        self.assertIn('Your current version will keep working', s['message'])
        self.assertEqual(manager.read_state(self.root)['current'], 'old')
        self.assertFalse((self.root / 'updates/activation.json').exists())
        self.assertTrue((self.root / 'updates/ready.json').exists())

    def test_preflight_failure_reaches_the_screen(self):
        self.prepared()
        (self.root / 'updates/ready/manager.py').write_text('tampered')
        with self.assertRaises(ValueError):
            service.activate(self.card, lambda root: True)
        s = self.status()
        self.assertEqual(s['stage'], 'failed')
        self.assertIn('Prepared installation support changed', s['message'])
        (self.root / 'updates/ready.json').unlink()
        with self.assertRaises(OSError):
            service.activate(self.card, lambda root: True)
        self.assertIn('Could not restart Plex: FileNotFoundError', self.status()['message'])

    def test_failed_start_keeps_the_cause_and_reports_the_restore(self):
        self.prepared()
        stages = []
        real = service.status
        def spy(root, stage, release=None, message='', detail=''):
            stages.append((stage, message)); real(root, stage, release, message, detail)
        with patch.object(service, 'status', spy), self.assertRaises(RuntimeError):
            service.activate(self.card, lambda root: manager.read_state(root)['current'] == 'old')
        self.assertEqual([s for s, _ in stages], ['activating', 'activating', 'failed'])
        self.assertIn('Restoring the previous release...', stages[1][1])
        s = self.status()
        self.assertEqual(s['message'], 'Could not restart Plex: The new release did not start. The previous release was restored.')
        self.assertEqual(manager.read_state(self.root)['current'], 'old')
        self.assertFalse((self.root / 'updates/activation.json').exists())

    def test_the_restored_release_starts_with_a_launch_log_too(self):
        self.prepared()
        starts = []
        class Exited:
            def poll(self):
                return 1
        def start(root, env=None):
            starts.append((manager.read_state(root)['current'], env is not None))
            return Exited()
        with patch.object(service, 'start_manager', start), self.assertRaises(RuntimeError):
            service.activate(self.card)
        # The new release with its readiness marker, then the previous one without.
        self.assertEqual(starts, [('new', True), ('old', False)])

    def test_failed_restore_keeps_the_journal_and_says_so(self):
        self.prepared()
        def broken(card):
            raise RuntimeError('menu entry synthetic failure')
        with patch.object(manager, 'repair_menu_entry', broken), self.assertRaises(RuntimeError):
            service.activate(self.card, lambda root: False)
        s = self.status()
        self.assertEqual(s['stage'], 'failed')
        self.assertIn('Could not restart Plex: The new release did not start.', s['message'])
        self.assertIn('Restoring the previous release also failed: menu entry synthetic failure', s['message'])
        self.assertIn('open Plex again', s['message'])
        self.assertTrue((self.root / 'updates/activation.json').exists())
        journal = json.loads((self.root / 'updates/activation.json').read_text())
        self.assertEqual((journal['target'], journal['previous']), ('1.0.0', 'old'))
        # The next launch finishes the restore and keeps the original cause on screen.
        with patch.dict(os.environ, {}, clear=True):
            self.assertTrue(manager.recover_activation(self.root))
        s = self.status()
        self.assertEqual(s['stage'], 'failed')
        self.assertTrue(s['message'].startswith('Could not restart Plex: The new release did not start.'))
        self.assertIn('The update to 1.0.0 was interrupted and old was restored.', s['message'])
        self.assertEqual(manager.read_state(self.root)['current'], 'old')
        self.assertFalse((self.root / 'updates/activation.json').exists())

    def test_recovery_after_reboot_explains_the_old_version(self):
        _, _, old = self.release('old')
        manager.install(self.card, old)
        recovery = self.root / 'updates/recovery'; recovery.mkdir(parents=True)
        manager.write_json(recovery / 'selection.json', manager.read_state(self.root))
        (recovery / 'registration').write_bytes(b'')
        manager.write_json(self.root / 'updates/activation.json', {'helpers': [], 'target': '2.0.0', 'previous': 'old'})
        manager.write_json(self.root / 'updates/status.json', {'stage': 'activating', 'message': 'Restarting Plex...', 'pid': 0})
        with patch.dict(os.environ, {}, clear=True):
            self.assertTrue(manager.recover_activation(self.root))
        self.assertEqual(self.status()['message'], 'The update to 2.0.0 was interrupted and old was restored.')
