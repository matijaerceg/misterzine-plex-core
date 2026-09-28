import hashlib
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest import mock

import manager

# Tests never talk to the live report service.
manager.REPORT_SERVICE = ''


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.card = self.base / 'card'
        self.package = self.base / 'package'
        (self.package / 'payload').mkdir(parents=True)
        self.root = self.card / 'misterzine-plex'

    def package_version(self, ident):
        files = {}
        for name in manager.PAYLOAD:
            data = (ident + name).encode()
            (self.package / 'payload' / name).write_bytes(data)
            files[name] = hashlib.sha256(data).hexdigest()
        manager.write_json(self.package / 'manifest.json', {'id': ident, 'files': files})

    @mock.patch.object(manager, 'decoder')
    def test_install_update_rollback_preserve_settings(self, decoder):
        self.package_version('alpha-1')
        manager.install(self.card, self.package)
        account = self.root / 'plexcrt.json'
        account.write_text('{"token":"TEST-ONLY-secret"}')
        key = self.root / 'beta-keys/2026-09.key'
        key.parent.mkdir()
        key.write_bytes(b'patron-test-key')
        receipt = self.root / 'beta-unlocks/fixture.receipt'
        receipt.parent.mkdir()
        receipt.write_text('unlocked\n')
        self.package_version('alpha-2')
        manager.install(self.card, self.package)
        self.assertEqual(manager.read_state(self.root), {'current': 'alpha-2', 'previous': 'alpha-1'})
        manager.rollback(self.root)
        self.assertEqual(manager.read_state(self.root)['current'], 'alpha-1')
        manager.remove(self.card)
        self.assertTrue((self.card / 'Scripts/MisterZine-Plex-Rollback.sh.disabled').is_file())
        self.assertFalse((self.card / 'Scripts/MisterZine-Plex-Run.sh').exists())
        self.assertEqual(account.read_text(), '{"token":"TEST-ONLY-secret"}')
        self.assertEqual(key.read_bytes(), b'patron-test-key')
        self.assertEqual(receipt.read_text(), 'unlocked\n')

    @mock.patch.object(manager, 'decoder')
    def test_rollback_to_local_pre_rename_release(self, decoder):
        self.package_version('before-rename')
        manager.install(self.card, self.package)
        previous = self.root / 'releases/before-rename'
        (previous / 'MisterZine Plex Core.rbf').rename(previous / 'MisterZine Plex.rbf')
        manifest = json.loads((previous / 'manifest.json').read_text())
        manifest['files']['MisterZine Plex.rbf'] = manifest['files'].pop('MisterZine Plex Core.rbf')
        manager.write_json(previous / 'manifest.json', manifest)
        self.package_version('after-rename')
        manager.install(self.card, self.package)
        manager.rollback(self.root)
        self.assertEqual(manager.read_state(self.root)['current'], 'before-rename')

    @mock.patch.object(manager, 'decoder')
    def test_bad_package_never_changes_active_release(self, decoder):
        self.package_version('alpha-1')
        manager.install(self.card, self.package)
        self.package_version('alpha-2')
        (self.package / 'payload/plexcrt').write_bytes(b'broken')
        with self.assertRaises(ValueError):
            manager.install(self.card, self.package)
        self.assertEqual(manager.read_state(self.root)['current'], 'alpha-1')

    @mock.patch.object(manager, 'decoder')
    def test_interrupted_activation_keeps_previous_release(self, decoder):
        self.package_version('alpha-1')
        manager.install(self.card, self.package)
        self.package_version('alpha-2')
        real_atomic = manager.atomic
        def fail_active(path, data):
            if path.name == 'active.json':
                raise OSError('simulated full card')
            real_atomic(path, data)
        with mock.patch.object(manager, 'atomic', side_effect=fail_active):
            with self.assertRaises(OSError):
                manager.install(self.card, self.package)
        self.assertEqual(manager.read_state(self.root)['current'], 'alpha-1')

    @mock.patch.object(manager, 'decoder')
    def test_menu_entry_follows_the_selected_release_and_the_installed_watcher(self, decoder):
        import xml.etree.ElementTree as ET
        entry = self.card / 'MisterZine Plex Core.mgl'
        self.root.mkdir(parents=True)
        (self.root / 'menu_launcher.py').write_text("SELECTIONS = ('MisterZine Plex Core',)\n")
        self.package_version('alpha-1')
        manager.install(self.card, self.package)
        self.assertEqual(ET.parse(entry).findtext('rbf'), 'misterzine-plex/releases/alpha-1/MisterZine Plex Core')
        self.package_version('alpha-2')
        manager.install(self.card, self.package)
        self.assertEqual(ET.parse(entry).findtext('rbf'), 'misterzine-plex/releases/alpha-2/MisterZine Plex Core')
        manager.rollback(self.root)
        self.assertEqual(ET.parse(entry).findtext('rbf'), 'misterzine-plex/releases/alpha-1/MisterZine Plex Core')
        # A watcher from before beta.4 only reacts to the menu bounce.
        (self.root / 'menu_launcher.py').write_text("SELECTION = 'misterzine-plex'\n")
        manager.rollback(self.root)
        self.assertEqual(entry.read_bytes(), manager.LEGACY_ENTRY)
        (self.root / 'active.json').unlink()
        manager.repair_menu_entry(self.card)
        self.assertFalse(entry.exists())

    def test_core_already_loaded_by_the_menu_entry_needs_no_reload(self):
        proc = self.base / 'proc/40'
        proc.mkdir(parents=True)
        (proc / 'comm').write_text('MiSTer_Zaparoo\n')
        (proc / 'cmdline').write_bytes(b'/media/fat/zaparoo/MiSTer_Zaparoo\0/media/fat/x/MisterZine Plex Core.rbf\0')
        corename = self.base / 'CORENAME'
        core = Path('/media/fat/x/MisterZine Plex Core.rbf')
        self.assertFalse(manager.core_loaded(core, proc.parent, corename, wait=0))
        corename.write_text('MENU\n')
        self.assertFalse(manager.core_loaded(core, proc.parent, corename, wait=0))
        corename.write_text('MisterZine Plex Core\n')
        self.assertTrue(manager.core_loaded(core, proc.parent, corename, wait=0))
        (proc / 'comm').write_text('python3\n')
        self.assertFalse(manager.core_loaded(core, proc.parent, corename, wait=0))

    def test_core_launch_keeps_browser_at_card_root(self):
        import xml.etree.ElementTree as ET
        folder = self.root / 'releases/alpha-1'
        folder.mkdir(parents=True)
        core = folder / 'MisterZine Plex Core.rbf'
        core.write_bytes(b'core')
        entry = manager.core_launch_entry(self.root, folder)
        self.assertEqual(entry.parent, self.card)
        self.assertEqual(ET.parse(entry).findtext('rbf'),
                         'misterzine-plex/releases/alpha-1/MisterZine Plex Core')
        core.rename(folder / 'MisterZine Plex.rbf')
        manager.core_launch_entry(self.root, folder)
        self.assertEqual(ET.parse(entry).findtext('rbf'),
                         'misterzine-plex/releases/alpha-1/MisterZine Plex')

    def test_small_hdmi_framebuffer_is_enlarged_for_ring(self):
        params = self.base / 'framebuffer'
        params.mkdir()
        mode = params / 'mode'
        mode.write_text('8888 1 640 480 2560')
        manager.prepare_framebuffer(params)
        self.assertEqual(mode.read_text(), '8888 1 1920 1080 7680\n')

    def test_large_framebuffer_is_left_alone(self):
        params = self.base / 'framebuffer'
        params.mkdir()
        mode = params / 'mode'
        original = '8888 1 1920 1080 7680'
        mode.write_text(original)
        manager.prepare_framebuffer(params)
        self.assertEqual(mode.read_text(), original)

    def test_core_status_wiped_for_a_field_is_not_a_lost_core(self):
        mem = bytearray(4096)
        struct.pack_into('<I', mem, 0x6c, 0x56500001)
        self.assertIsNone(manager.lost_core_status(mem, sleep=self.fail))
        # A framebuffer mode write clears the word until the core's next vsync.
        struct.pack_into('<I', mem, 0x6c, 0)
        rewritten = lambda _: struct.pack_into('<I', mem, 0x6c, 0x56500002)
        self.assertIsNone(manager.lost_core_status(mem, sleep=rewritten))
        # Another core never writes it back.
        struct.pack_into('<I', mem, 0x6c, 0)
        self.assertEqual(manager.lost_core_status(mem, sleep=lambda _: None), 0)

    def test_reject_path_escape(self):
        self.root.mkdir(parents=True)
        manager.write_json(self.root / 'active.json', {'current': '../elsewhere'})
        with self.assertRaises(ValueError):
            manager.read_state(self.root)

    def test_redaction(self):
        value = manager.safe_log('token=TESTsecret&v=1\nAuthorization: Bearer OTHERsecret\nhttps://private.local/path\nTESTsecret', ['TESTsecret'])
        self.assertNotIn('TESTsecret', value)
        self.assertNotIn('OTHERsecret', value)
        self.assertNotIn('private.local', value)
        self.assertIn('&v=1', value)


class ReportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.card = self.base / 'card'
        self.root = self.card / 'misterzine-plex'
        (self.root / 'releases/beta-9').mkdir(parents=True)
        manager.write_json(self.root / 'active.json', {'current': 'beta-9', 'previous': None})
        manager.write_json(self.root / 'releases/beta-9/manifest.json', {'id': 'beta-9', 'version': '0.1.0-beta.9', 'files': {}})
        (self.root / 'plexcrt.json').write_text('{"token":"TESTtoken","server_url":"https://10-0-0-2.abc.plex.direct:32400"}')
        (self.card / 'MiSTer.ini').write_text('[MiSTer]\nvideo_mode=8\nfb_terminal=1\n[Menu]\nmain=zaparoo/MiSTer_Zaparoo\n')
        (self.card / 'linux').mkdir()
        (self.card / 'linux/user-startup.sh').write_text('#!/bin/bash\nzaparoo.sh\n')
        self.proc = self.base / 'proc/40'
        self.proc.mkdir(parents=True)
        (self.proc / 'comm').write_text('MiSTer_Zaparoo\n')
        (self.proc / 'cmdline').write_bytes(b'/media/fat/zaparoo/MiSTer_Zaparoo\0')
        exe = self.base / 'MiSTer_Zaparoo'
        exe.write_bytes(b'not really main')
        (self.proc / 'exe').symlink_to(exe)
        self.tmp = self.base / 'tmp'
        self.tmp.mkdir()
        (self.tmp / 'misterzine-plex.log').write_text('watch: header wiped 3 times\nGET https://10-0-0-2.abc.plex.direct:32400/x?X-Plex-Token=TESTtoken\n')
        (self.tmp / 'misterzine-plex.log.1').write_text('ring: no core\n')
        (self.tmp / 'misterzine-plex-menu-run.log').write_text('12:00:00 launch: CORENAME MENU\n')

    def report(self):
        return manager.build_report(self.root, self.proc.parent, self.tmp, now=0)

    def test_report_names_the_main_binary_and_keeps_secrets_out(self):
        text = self.report()
        self.assertTrue(text.startswith(manager.REPORT_MAGIC + '\nApp: MisterZine Plex Core 0.1.0-beta.9\nCreated: 1970-01-01T00:00:00Z\n'))
        self.assertIn('main_binaries: ["MiSTer_Zaparoo ', text)
        self.assertIn(hashlib.sha256(b'not really main').hexdigest()[:16], text)
        self.assertIn('"fb_terminal": "1"', text)
        self.assertIn('"main": "zaparoo/MiSTer_Zaparoo"', text)
        self.assertIn('startup_hooks: ["zaparoo"]', text)
        self.assertIn('== LOG misterzine-plex.log.1', text)
        self.assertIn('== LOG misterzine-plex-menu-run.log', text)
        self.assertIn('watch: header wiped 3 times', text)
        self.assertNotIn('TESTtoken', text)
        self.assertNotIn('10-0-0-2', text)
        self.assertLessEqual(len(text.encode()), manager.REPORT_MAX_BYTES)

    def test_report_trims_long_logs_to_the_limit(self):
        (self.tmp / 'plexplay.log').write_text('x' * 200 + '\n' + 'a line of playback\n' * 20000)
        text = self.report()
        self.assertLessEqual(len(text.encode()), manager.REPORT_MAX_BYTES)
        self.assertIn('a line of playback', text)
        self.assertIn('watch: header wiped', text)

    @mock.patch.object(manager, 'REPORT_SERVICE', 'https://reports.invalid')
    def test_send_report_reads_the_code_and_words_failures(self):
        import io
        import urllib.error

        class Answer(io.BytesIO):
            def __enter__(self):
                return self

            def __exit__(self, *a):
                pass
        seen = {}

        def ok(req, timeout):
            seen['body'] = req.data
            seen['type'] = req.get_header('Content-type')
            return Answer(b'{"code":"K7M4"}')
        self.assertEqual(manager.send_report('MisterZine report v1\n', '0.1.0-beta.9', ok), 'K7M4')
        self.assertEqual(seen['body'], b'MisterZine report v1\n')
        self.assertEqual(seen['type'], 'text/plain; charset=utf-8')

        def busy(req, timeout):
            raise urllib.error.HTTPError(req.full_url, 429, 'busy', {}, None)
        with self.assertRaisesRegex(manager.ReportError, 'Too many reports'):
            manager.send_report('x', opener=busy)

        def offline(req, timeout):
            raise urllib.error.URLError('no route')
        with self.assertRaisesRegex(manager.ReportError, 'offline'):
            manager.send_report('x', opener=offline)
        with self.assertRaisesRegex(manager.ReportError, 'no code'):
            manager.send_report('x', opener=lambda req, timeout: Answer(b'{"code":"0O"}'))

    def test_diagnostics_saves_the_report_without_uploading(self):
        with mock.patch.object(manager, 'build_report', return_value='MisterZine report v1\nApp: x\n'), \
                mock.patch.object(manager, 'send_report', side_effect=AssertionError('uploaded')):
            out, code, problem = manager.diagnostics(self.root)
        self.assertEqual(out, self.root / 'report.txt')
        self.assertEqual(out.read_text(), 'MisterZine report v1\nApp: x\n')
        self.assertEqual((code, problem), ('', ''))

    def test_report_service_off_is_worded(self):
        with self.assertRaisesRegex(manager.ReportError, 'switched off'):
            manager.send_report('x')

    def test_account_name_never_reaches_the_report(self):
        (self.root / 'plexcrt.json').write_text('{"token":"TESTtoken","account_name":"TESTaccount"}')
        (self.tmp / 'misterzine-plex.log').write_text('signed in as TESTaccount\n')
        self.assertNotIn('TESTaccount', self.report())

    def test_diagnostics_entry_always_waits_for_a_key(self):
        manager.wrappers(self.card)
        diag = (self.card / 'Scripts/MisterZine-Plex-Diagnostics.sh').read_text()
        self.assertIn('if true; then read -r -p', diag)
        rollback = (self.card / 'Scripts/MisterZine-Plex-Rollback.sh').read_text()
        self.assertIn('if [ "$result" -ne 0 ]; then read -r -p', rollback)

    def test_framebuffer_preparation_reports_a_write(self):
        params = self.base / 'params'
        params.mkdir()
        (params / 'mode').write_text('8888 1 640 480 2560\n')
        self.assertTrue(manager.prepare_framebuffer(params))
        self.assertFalse(manager.prepare_framebuffer(params))


if __name__ == '__main__':
    unittest.main()
