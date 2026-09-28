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

    def test_only_the_exit_status_asks_for_the_menu(self):
        self.assertTrue(manager.app_finished(manager.EXIT_TO_MENU))
        self.assertFalse(manager.app_finished(0))
        self.assertFalse(manager.app_finished(None))    # stopped here: the core went
        for status in (1, 2, -15):
            with self.assertRaises(RuntimeError):
                manager.app_finished(status)

    def test_exit_loads_the_menu_core(self):
        cmd = self.base / 'MiSTer_cmd'
        self.card.mkdir()
        plex, menu = {10: b'/media/fat/plex.rbf'}, {11: b'/media/fat/menu.rbf'}
        with mock.patch.object(manager, 'trace'):
            self.assertFalse(manager.load_menu(self.card, cmd))
            self.assertFalse(cmd.exists())
            (self.card / 'menu.rbf').write_bytes(b'rbf')
            # MiSTer restarts its main process to load the menu
            with mock.patch.object(manager, 'mister_processes', side_effect=[plex, plex, menu]):
                self.assertTrue(manager.load_menu(self.card, cmd))
            self.assertEqual(cmd.read_text(), 'load_core ' + str(self.card / 'menu.rbf') + '\n')
            # Zaparoo Frontend's main comes back on its own menu core
            with mock.patch.object(manager, 'mister_processes', side_effect=[plex, {12: b'zaparoo/menu_zaparoo.rbf'}]):
                self.assertTrue(manager.load_menu(self.card, cmd))
            # the same main process all along, or a new one on another core
            for after in (plex, {13: b'/media/fat/_Console/NES.rbf'}):
                with mock.patch.object(manager, 'mister_processes', side_effect=[plex] + [after] * 100):
                    self.assertFalse(manager.load_menu(self.card, cmd, wait=.1))

    def test_exit_lingers_with_the_lock_let_go(self):
        import fcntl
        self.root.mkdir(parents=True)
        free = []

        def linger():
            # a new pick of Plex meanwhile must be able to launch
            with (self.root / 'manager.lock').open('a') as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    free.append(True)
                except BlockingIOError:
                    free.append(False)
        with mock.patch.object(manager, 'run', return_value=True), \
                mock.patch.object(manager, 'linger_for_start_check', side_effect=linger), \
                mock.patch.object(manager.sys, 'argv', ['manager.py', 'run', '--card', str(self.card)]):
            self.assertEqual(manager.main(), manager.EXIT_TO_MENU)
        self.assertEqual(free, [True])
        with mock.patch.object(manager, 'run', return_value=False), \
                mock.patch.object(manager, 'linger_for_start_check', side_effect=self.fail), \
                mock.patch.object(manager.sys, 'argv', ['manager.py', 'run', '--card', str(self.card)]):
            self.assertEqual(manager.main(), 0)

    def test_exit_after_an_update_start_outlasts_its_check(self):
        ready = self.base / 'started'
        ready.write_text('ready')
        up = ready.stat().st_mtime
        slept = []
        # the app came up half a second ago: stay until 3 s after it
        self.assertAlmostEqual(manager.linger_for_start_check(str(ready), now=lambda: up + .5, sleep=slept.append), 2.5)
        self.assertAlmostEqual(slept[0], 2.5)
        # long up, no updater, or no marker: no wait
        self.assertEqual(manager.linger_for_start_check(str(ready), now=lambda: up + 10, sleep=self.fail), 0)
        self.assertEqual(manager.linger_for_start_check('', sleep=self.fail), 0)
        self.assertEqual(manager.linger_for_start_check(str(self.base / 'missing'), sleep=self.fail), 0)

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

    def test_report_reads_the_active_alternative_ini_by_number(self):
        (self.card / 'MiSTer_Bench.ini').write_text('[MiSTer]\nvrr_mode=2\n[MisterZine Plex Core]\nvideo_mode=8\n')
        facts = manager.system_facts(self.root, [], self.proc.parent, altcfg=lambda: 1)
        self.assertEqual(facts['ini'], 'alternative 1')
        self.assertEqual(facts['video_settings'], {'MiSTer': {'vrr_mode': '2'}, 'MisterZine Plex Core': {'video_mode': '8'}})
        self.assertEqual(facts['plex_video'], {'vrr_mode': '2', 'video_mode': '8', 'vrr': 'forced', 'hdmi_hz': None,
                                               'hdmi_mode': '', 'dvi': False, 'overridden': [], 'conditional': [],
                                               'own_section': True, 'section_in': ''})
        self.assertNotIn('Bench', json.dumps(facts))
        facts = manager.system_facts(self.root, [], self.proc.parent, altcfg=lambda: None)
        self.assertEqual(facts['ini'], 'unknown')
        self.assertEqual(facts['plex_video']['hdmi_hz'], 60.0)          # MiSTer.ini stands in
        self.assertEqual(facts['plex_video']['section_in'], 'alternative 1')
        self.assertNotIn('Bench', json.dumps(facts))


class DisplayCheckTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.card = Path(self.temp.name)

    def check(self, text, altcfg=lambda: 0):
        (self.card / 'MiSTer.ini').write_text(text)
        return manager.display_check(self.card, altcfg)

    def assertFound(self, check, **expected):
        self.assertEqual({key: check.get(key) for key in expected}, expected)

    def test_the_plex_section_overrides_the_global_setting(self):
        self.assertFound(self.check('[MiSTer]\nvrr_mode=2\n'), ini='MiSTer.ini', vrr='forced', vrr_mode=2)
        self.assertEqual(self.check('[MiSTer]\nvrr_mode=2\n[MisterZine Plex Core]\nvrr_mode=0\n')['vrr'], 'off')
        # main reads top to bottom: a [MiSTer] section after the core's wins
        self.assertEqual(self.check('[misterzine plex core]\nvrr_mode=0\n[MiSTer]\nvrr_mode=3\n')['vrr'], 'forced')
        self.assertEqual(self.check('[SNES]\nvrr_mode=2\n[MiSTer]\nvideo_mode=8\n')['vrr'], 'off')
        # what the app's notes suggest: a second Plex section at the end
        self.assertEqual(self.check('[MisterZine Plex Core]\nvideo_mode=8\n[MiSTer]\nvrr_mode=2\n'
                                    '[MisterZine Plex Core]\nvrr_mode=0\n')['vrr'], 'off')

    def test_main_drops_vrr_with_vsync_adjust_or_direct_video(self):
        self.assertEqual(self.check('[MiSTer]\nvrr_mode=2\nvsync_adjust=1\n')['vrr'], 'off')
        self.assertEqual(self.check('[MiSTer]\nvrr_mode=4\ndirect_video=1\n')['vrr'], 'off')
        # direct_video=2 is direct video only for a VGA converter main recognises at start-up
        self.assertEqual(self.check('[MiSTer]\nvrr_mode=2\ndirect_video=2\n')['vrr'], 'unknown')
        self.assertEqual(self.check('[MiSTer]\nvrr_mode=2\ndirect_video=2\nvsync_adjust=1\n')['vrr'], 'off')
        self.assertEqual(self.check('[MiSTer]\nvrr_mode=1\n')['vrr'], 'auto')
        self.assertEqual(self.check('[MiSTer]\nvideo_mode=8\n')['vrr'], 'off')

    def test_lines_are_read_as_main_reads_them(self):
        self.assertEqual(self.check('﻿[MiSTer]\r\n  vrr_mode = 2 ; forced\r\n')['vrr_mode'], 2)
        self.assertEqual(self.check('vrr_mode=2\n[MiSTer]\n')['vrr'], 'off')           # before any section
        self.assertEqual(self.check('[MiSTer]\n;vrr_mode=2\n')['vrr'], 'off')
        self.assertEqual(self.check('[MisterZine*]\nvrr_mode=2\n')['vrr'], 'forced')
        self.assertEqual(self.check('[Genesis]\n+MisterZine Plex Core\nvrr_mode=2\n')['vrr'], 'forced')
        self.assertEqual(self.check('[MiSTer]\nvrr_mode=9\n')['vrr_mode'], 4)            # clamped
        self.assertEqual(self.check('[MiSTer]\nvrr_mode=0x2\n')['vrr_mode'], 2)
        self.assertEqual(self.check('[MiSTer]\nvrr_mode=on\n')['vrr'], 'off')

    def test_the_ini_main_chose_is_the_one_read(self):
        for name in ('MiSTer_zeta.ini', 'MiSTer_Alpha.ini', 'notes.ini'):
            (self.card / name).write_text('[MiSTer]\nvrr_mode=2\n')
        self.assertFound(self.check('[MiSTer]\n', altcfg=lambda: 2), ini='MiSTer_zeta.ini', vrr='forced', vrr_mode=2)
        self.assertEqual(self.check('[MiSTer]\n', altcfg=lambda: 0)['vrr'], 'off')
        self.assertEqual(self.check('[MiSTer]\n', altcfg=lambda: 7)['ini'], 'MiSTer.ini')
        self.assertEqual(self.check('[MiSTer]\n', altcfg=lambda: 3), {'ini': '', 'vrr': 'unknown'})
        self.assertEqual(self.check('[MiSTer]\n', altcfg=lambda: None), {'ini': '', 'vrr': 'unknown'})

    def test_without_alternatives_main_memory_is_not_read(self):
        self.assertEqual(self.check('[MiSTer]\nvrr_mode=2\n', altcfg=mock.Mock(side_effect=AssertionError))['vrr'], 'forced')
        (self.card / 'MiSTer.ini').unlink()
        self.assertEqual(manager.display_check(self.card, lambda: 0),
                         {'ini': 'MiSTer.ini', 'vrr': 'off', 'vrr_mode': 0, 'vsync_adjust': 0, 'hdmi_hz': None,
                          'hdmi_mode': '', 'dvi': False, 'overridden': [], 'conditional': [], 'section_in': ''})

    def test_video_mode_refresh_follows_main_parsing(self):
        refresh = manager.video_mode_refresh
        self.assertEqual([refresh(v) for v in ('8', '9', '3', '7', '12', '99', '0x9', '9,pr')],
                         [60.0, 50.0, 50.0, 50.0, 60.0, 60.0, 50.0, 50.0])
        self.assertEqual(refresh('1920,1080,50'), 50.0)
        self.assertEqual(refresh('1920,1080,59.94,cvt'), 59.94)
        self.assertEqual(refresh('1280,110,40,220,720,5,5,20,74250,+hsync,-vsync'), 60.0)
        self.assertEqual(refresh('1920,528,44,148,1080,4,5,36,148500'), 50.0)
        self.assertEqual(refresh('9,oops'), 60.0)           # main rejects it and falls back to 60 Hz
        self.assertEqual(refresh('1920,1080'), 60.0)
        self.assertIsNone(refresh(','.join(['1'] * 21)))
        self.assertEqual(manager.parse_video_mode(''), (False, None))
        self.assertEqual(manager.parse_video_mode('9,oops'), (False, None))

    def test_fixed_hdmi_refresh(self):
        hz = lambda text: self.check('[MiSTer]\n' + text)['hdmi_hz']
        self.assertFound(self.check('[MiSTer]\nvideo_mode=9\n'), hdmi_hz=50.0, hdmi_mode='video_mode=9', vsync_adjust=0)
        self.assertFound(self.check('[MiSTer]\nvideo_mode=8\nvsync_adjust=1\nvideo_mode_pal=9\n'),
                         hdmi_hz=50.0, hdmi_mode='video_mode_pal=9', vsync_adjust=1)
        self.assertEqual(self.check('[MiSTer]\nvideo_mode=9\n[MisterZine Plex Core]\nvideo_mode=8\n')['hdmi_hz'], 60.0)
        # HDMI follows the core with vsync_adjust or forced VRR; direct video is the core's own timing
        for extra in ('vsync_adjust=1', 'direct_video=1', 'vrr_mode=2'):
            self.assertIsNone(hz('video_mode=9\n' + extra + '\n'), extra)
        self.assertIsNone(hz('video_mode=9\ndirect_video=2\n'))            # decided at start-up
        self.assertEqual(hz('video_mode=9\nvrr_mode=1\n'), 50.0)             # the note hedges this one
        self.assertIsNone(hz('vscale_mode=0\n'))                             # the display's own mode
        self.assertEqual(hz('video_mode_ntsc=8\n'), 60.0)                    # main's default mode
        # vsync_adjust gives up when the refresh bounds leave out 59.94 Hz
        self.assertEqual(hz('video_mode=9\nvsync_adjust=1\nrefresh_max=55\n'), 50.0)
        self.assertEqual(hz('video_mode=9\nvsync_adjust=1\nrefresh_min=60.5\n'), 50.0)
        self.assertIsNone(hz('video_mode=9\nvsync_adjust=1\nrefresh_min=50\nrefresh_max=61\n'))
        # a PAL mode without an NTSC one is used for a 60 Hz core as it is
        self.assertEqual(hz('video_mode=8\nvsync_adjust=1\nvideo_mode_pal=9\n'), 50.0)
        self.assertIsNone(hz('video_mode=8\nvsync_adjust=1\nvideo_mode_pal=9\nvideo_mode_ntsc=8\n'))
        self.assertEqual(hz('video_mode=8\nvsync_adjust=2\nvideo_mode_ntsc=7\nrefresh_max=55\n'), 50.0)
        # or when the pixel clock 59.94 Hz would take leaves 2-300 MHz: 2560 x 2031 lines needs 311.7 MHz
        found = self.check('[MiSTer]\nvsync_adjust=1\nvideo_mode=1920,100,100,440,1800,50,50,131,259968\n')
        self.assertFound(found, hdmi_hz=50.0, hdmi_mode='video_mode=1920,100,100,440,1800,50,50,131,259968')
        self.assertIsNone(hz('vsync_adjust=1\nvideo_mode=1920,528,44,148,1080,4,5,36,148500\n'))
        self.assertIsNone(hz('vsync_adjust=1\nvideo_mode=3840,2160,50\n'))   # CVT timing: not worked out here

    def test_video_mode_sections_make_findings_unknown(self):
        # main applies [video=...] by the core's measured mode, not known before its video runs
        found = self.check('[MiSTer]\nvrr_mode=2\nvideo_mode=9\ndvi_mode=1\n[video=720x480@59.9]\nvrr_mode=0\n')
        self.assertFound(found, vrr='unknown', hdmi_hz=None, dvi=True, conditional=['vrr_mode'])
        found = self.check('[MiSTer]\ndvi_mode=1\nvideo_mode=9\n[Video=720x480]\ndvi_mode=0\n')
        self.assertFound(found, dvi=None, hdmi_hz=50.0, conditional=['dvi_mode'])
        # a later line outside video sections settles the value whether or not the section applies
        found = self.check('[video=720x480]\nvrr_mode=0\ndvi_mode=0\n[MiSTer]\nvrr_mode=2\ndvi_mode=1\n')
        self.assertFound(found, vrr='forced', dvi=True, conditional=[])
        # only the settings the checks use count, so junk cannot swell what the app is handed
        found = self.check('[MiSTer]\nvrr_mode=2\n[video=720x480]\n' + 'k' * 5000 + '=1\nbootscreen=0\n')
        self.assertFound(found, vrr='forced', conditional=[])
        self.assertEqual(len(manager.ini_line('k' * 5000 + '=1')), 1023)          # main's line limit
        self.assertEqual(manager.section_scope('vid=640x480]'), 'video')     # strncasecmp up to the '='
        self.assertIsNone(manager.section_scope('videos=640x480]'))
        self.assertIsNone(manager.section_scope('SNES]'))

    def test_dvi_mode(self):
        self.assertTrue(self.check('[MiSTer]\ndvi_mode=1\n')['dvi'])
        self.assertFalse(self.check('[MiSTer]\ndvi_mode=1\n[MisterZine Plex Core]\ndvi_mode=0\n')['dvi'])
        self.assertFalse(self.check('[MiSTer]\n;dvi_mode=1\n')['dvi'])

    def test_plex_settings_a_later_mister_section_undoes(self):
        text = ('[MisterZine Plex Core]\nvideo_mode=8\nvrr_mode=0\nvscale_mode=0\n'
                '[MiSTer]\nvideo_mode=9\nvrr_mode=0\nvrr_mode=2\n')
        self.assertFound(self.check(text), overridden=['video_mode', 'vrr_mode'], hdmi_hz=None, vrr='forced')
        self.assertEqual(self.check('[MiSTer]\nvideo_mode=9\n[MisterZine Plex Core]\nvideo_mode=8\n')['overridden'], [])
        # the same value again is no override, however it is spelled
        self.assertEqual(self.check('[MisterZine Plex Core]\nvideo_mode=8\n[MiSTer]\nvideo_mode=8\n')['overridden'], [])
        self.assertEqual(self.check('[MisterZine Plex Core]\nvrr_mode=0x2\nrefresh_max=61\n'
                                    '[MiSTer]\nvrr_mode=2\nrefresh_max=61.0\n')['overridden'], [])
        self.assertEqual(self.check('[MisterZine Plex Core]\nvrr_mode=9\n[MiSTer]\nvrr_mode=4\n')['overridden'], [])
        self.assertEqual(self.check('[MisterZine Plex Core]\nvideo_mode=0x9\nvideo_mode_ntsc=1920,1080,60,CVT\n'
                                    '[MiSTer]\nvideo_mode=9\nvideo_mode_ntsc=1920,1080,60.0,cvt\n')['overridden'], [])
        self.assertEqual(self.check('[MisterZine Plex Core]\nvideo_mode=99\n[MiSTer]\nvideo_mode=0\n')['overridden'], [])
        # flags as main leaves them: the last of a pair wins; a numbered mode ignores blanking flags
        for own, later in (('9,+hsync,+vsync', '9,+vsync,+hsync'), ('9,-hsync,+hsync', '9,+hsync'), ('9,cvt,pr', '9'),
                           ('1280,110,40,220,720,5,5,20,74250,1,1,-vsync', '1280,110,40,220,720,5,5,20,74250,1,1')):
            self.assertEqual(self.check('[MisterZine Plex Core]\nvideo_mode=%s\n[MiSTer]\nvideo_mode=%s\n' % (own, later))
                             ['overridden'], [], (own, later))
        self.assertEqual(self.check('[MisterZine Plex Core]\nvideo_mode=9,+hsync\n[MiSTer]\nvideo_mode=9\n')['overridden'],
                         ['video_mode'])
        # a timing keeps its blanking flag, which vscale_mode 4 and 5 use
        timing = '1280,110,40,220,720,5,5,20,74250'
        self.assertEqual(self.check('[MisterZine Plex Core]\nvscale_mode=4\nvideo_mode=%s,cvt\n[MiSTer]\nvideo_mode=%s,cvtrb\n'
                                    % (timing, timing))['overridden'], ['video_mode'])
        self.assertEqual(self.check('[MisterZine Plex Core]\nvideo_mode=1920,1080,60\n'
                                    '[MiSTer]\nvideo_mode=1920,1080,50\n')['overridden'], ['video_mode'])
        # settings main does not know, or these checks do not use, are not flagged
        self.assertEqual(self.check('[MisterZine Plex Core]\nvideo_mdoe=8\nbootscreen=0\n'
                                    '[MiSTer]\nvideo_mdoe=9\nbootscreen=1\n')['overridden'], [])
        # nor ones a video mode section may change again
        self.assertEqual(self.check('[MisterZine Plex Core]\nvideo_mode=8\n[MiSTer]\nvideo_mode=9\n'
                                    '[video=720x480]\nvideo_mode=8\n')['overridden'], [])
        # but a video section in between changes nothing about a later [MiSTer] line
        self.assertEqual(self.check('[MisterZine Plex Core]\nvideo_mode=8\n[video=720x480]\nvideo_mode=7\n'
                                    '[MiSTer]\nvideo_mode=9\n')['overridden'], ['video_mode'])

    def test_plex_section_in_another_ini(self):
        (self.card / 'MiSTer_crt.ini').write_text('[MiSTer]\nvideo_mode=9\n')
        self.assertEqual(self.check('[MiSTer]\n[MisterZine Plex Core]\nvideo_mode=8\n', altcfg=lambda: 1)['section_in'], 'MiSTer.ini')
        self.assertEqual(self.check('[MiSTer]\nvideo_mode=8\n', altcfg=lambda: 1)['section_in'], '')
        (self.card / 'MiSTer_crt.ini').write_text('[MiSTer]\n[MisterZine Plex Core]\nvideo_mode=8\n')
        self.assertEqual(self.check('[MiSTer]\n', altcfg=lambda: 0)['section_in'], 'MiSTer_crt.ini')
        self.assertEqual(self.check('[MiSTer]\n[MisterZine Plex Core]\n', altcfg=lambda: 0)['section_in'], '')
        self.assertEqual(manager.ini_label(self.card, 'MiSTer_crt.ini'), 'alternative 1')

    def test_altcfg_reads_main_signature(self):
        mem = self.card / 'mem'
        page = bytearray(4096)
        mem.write_bytes(bytes(page))
        self.assertEqual(manager.read_altcfg(str(mem), address=0), 0)
        page[0xF04:0xF08] = b'\x34\x99\xba\x02'
        mem.write_bytes(bytes(page))
        self.assertEqual(manager.read_altcfg(str(mem), address=0), 2)
        self.assertIsNone(manager.read_altcfg(str(self.card / 'missing')))

    def test_display_env_never_fails(self):
        with mock.patch.object(manager, 'display_check', side_effect=RuntimeError('boom')), \
                mock.patch.object(manager, 'trace') as trace:
            self.assertEqual(manager.display_env(self.card), '')
        trace.assert_called_once_with('display check failed: RuntimeError')
        (self.card / 'MiSTer.ini').write_text('[MiSTer]\nvrr_mode=2\n')
        with mock.patch.object(manager, 'trace') as trace:
            self.assertFound(json.loads(manager.display_env(self.card)), ini='MiSTer.ini', vrr='forced', vrr_mode=2)
        trace.assert_called_once_with('display check: vrr forced, hdmi None Hz, dvi False, overridden none, section elsewhere False')
        with mock.patch.object(manager, 'trace') as trace, mock.patch.object(manager, 'DISPLAY_ENV_MAX', 20):
            self.assertEqual(manager.display_env(self.card), '')
        self.assertTrue(trace.call_args[0][0].startswith('display check left out: '))


if __name__ == '__main__':
    unittest.main()
