"""Upgrade defaults must not take over a user's Zaparoo customization."""
import base64
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import build_package
import manager


class ZaparooArtTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.card = Path(tmp.name).resolve()
        self.root = self.card / 'misterzine-plex'
        self.zaparoo = self.card / 'zaparoo'
        self.root.mkdir()
        self.zaparoo.mkdir()
        self.config = self.zaparoo / 'frontend.toml'
        self.art = self.zaparoo / 'custom'
        self.system = self.art / 'systems' / (manager.ZAPAROO_SYSTEM + '.png')
        self.hub = self.art / 'hub' / (manager.ZAPAROO_ICON + '.png')
        self.logo = b'synthetic-logo'
        p = patch.object(manager, 'zaparoo_logo', return_value=self.logo)
        p.start()
        self.addCleanup(p.stop)

    def pin(self, extra=''):
        return ('[[hub.items]]\ntype = "system"\nid = "' + manager.ZAPAROO_SYSTEM + '"\n' + extra)

    def test_existing_pin_gets_logo_without_reordering_or_changing_launcher(self):
        before = ('# keep my comment\n[settings]\ncolor_scheme = "nord"\n'
                  '[[hub.items]]\ntype = "action"\nid = "settings"\n' + self.pin() +
                  '[[hub.items]]\ntype = "category"\nid = "Console"\n')
        self.config.write_text(before)
        launcher = self.zaparoo / 'launchers/misterzine-plex.toml'
        launcher.parent.mkdir()
        launcher.write_text('unchanged launcher identity and launch path')
        self.assertIn('updated', manager.zaparoo_art(self.card))
        after = self.config.read_text()
        self.assertIn('icon = "misterzine-plex"', after)
        self.assertIn(' = "MisterZine Plex"', after)
        self.assertLess(after.index('id = "settings"'), after.index(manager.ZAPAROO_SYSTEM))
        self.assertLess(after.index(manager.ZAPAROO_SYSTEM), after.index('id = "Console"'))
        self.assertEqual(launcher.read_text(), 'unchanged launcher identity and launch path')
        self.assertEqual(self.system.read_bytes(), self.logo)
        self.assertEqual(self.hub.read_bytes(), self.logo)
        stamps = {p: p.stat().st_mtime_ns for p in (self.config, self.system, self.hub,
                                                  self.root / manager.ZAPAROO_ART_STATE)}
        self.assertEqual(manager.zaparoo_art(self.card), 'current')
        self.assertEqual(stamps, {p: p.stat().st_mtime_ns for p in stamps})

    def test_no_pin_is_added_and_a_later_pin_is_decorated(self):
        self.config.write_text('[settings]\nmouse_enabled = true\n')
        manager.zaparoo_art(self.card)
        self.assertNotIn('[[hub.items]]', self.config.read_text())
        self.assertFalse(self.hub.exists())
        self.config.write_text(self.config.read_text() + '\n' + self.pin())
        manager.zaparoo_art(self.card)
        self.assertIn('icon = "misterzine-plex"', self.config.read_text())

    def test_new_art_version_updates_both_owned_images(self):
        self.config.write_text(self.pin())
        manager.zaparoo_art(self.card)
        with patch.object(manager, 'zaparoo_logo', return_value=b'updated artwork'):
            manager.zaparoo_art(self.card)
        self.assertEqual(self.system.read_bytes(), b'updated artwork')
        self.assertEqual(self.hub.read_bytes(), b'updated artwork')

    def test_custom_name_and_pin_icon_survive_install_and_uninstall(self):
        before = self.pin('icon = "my-logo"\nname = "Movie time"\n') + (
            '[custom.system_names]\n"' + manager.ZAPAROO_SYSTEM.upper() + '" = "My movies"\n')
        self.config.write_text(before)
        manager.zaparoo_art(self.card)
        self.assertEqual(self.config.read_text(), before)
        manager.zaparoo_art(self.card, False)
        self.assertEqual(self.config.read_text(), before)

    def test_existing_system_image_in_any_supported_format_wins(self):
        for ext in ('PNG', 'svg', 'webp', 'jpg'):
            with self.subTest(ext=ext):
                custom = self.system.with_name(manager.ZAPAROO_SYSTEM.upper() + '.' + ext)
                custom.parent.mkdir(parents=True, exist_ok=True)
                custom.write_bytes(b'personal image')
                self.config.write_text(self.pin())
                manager.zaparoo_art(self.card)
                self.assertEqual(custom.read_bytes(), b'personal image')
                self.assertNotIn('icon =', self.config.read_text())
                manager.zaparoo_art(self.card, False)
                self.assertTrue(custom.exists())
                custom.unlink()

    def test_personal_hub_image_collision_is_preserved(self):
        self.config.write_text(self.pin())
        self.hub.parent.mkdir(parents=True)
        self.hub.write_bytes(b'personal logo')
        manager.zaparoo_art(self.card)
        self.assertNotIn('icon =', self.config.read_text())
        manager.zaparoo_art(self.card, False)
        self.assertEqual(self.hub.read_bytes(), b'personal logo')

    def test_uninstall_removes_only_unchanged_owned_art_and_fields(self):
        before = self.pin() + '[[hub.items]]\ntype = "action"\nid = "settings"\n'
        self.config.write_text(before)
        manager.zaparoo_art(self.card)
        self.config.write_text(self.config.read_text().replace('id = "settings"', 'id = "favorites"'))
        self.system.write_bytes(b'edited by user')
        manager.zaparoo_art(self.card, False)
        self.assertEqual(self.system.read_bytes(), b'edited by user')
        self.assertFalse(self.hub.exists())
        self.assertNotIn('icon =', self.config.read_text())
        self.assertNotIn('MisterZine Plex', self.config.read_text())
        self.assertIn('id = "favorites"', self.config.read_text())

    def test_user_edit_of_our_hub_image_keeps_its_pin_reference(self):
        self.config.write_text(self.pin())
        manager.zaparoo_art(self.card)
        self.hub.write_bytes(b'personal replacement')
        manager.zaparoo_art(self.card)
        manager.zaparoo_art(self.card, False)
        self.assertEqual(self.hub.read_bytes(), b'personal replacement')
        self.assertIn('icon = "misterzine-plex"', self.config.read_text())

    def test_rollback_to_old_manager_removes_our_defaults(self):
        self.config.write_text(self.pin())
        manager.zaparoo_art(self.card)
        (self.root / 'manager.py').write_text('def zaparoo_entry(): pass\n')
        manager.maintain_zaparoo_art(self.card)
        self.assertFalse(self.system.exists())
        self.assertFalse(self.hub.exists())
        self.assertNotIn('icon =', self.config.read_text())

    def test_custom_directory_on_card_is_respected(self):
        folder = self.card / 'my-art'
        self.config.write_text(self.pin() + '[custom]\ndir = ' + json.dumps(str(folder)) + '\n')
        manager.zaparoo_art(self.card)
        self.assertTrue((folder / 'systems' / self.system.name).is_file())
        self.assertFalse(self.art.exists())

    def test_complex_config_is_left_intact(self):
        for text in (self.pin() + "[custom]\ndir = '''custom'''\n",
                     self.pin() + '[custom]\n"dir".nested = "custom"\n',
                     self.pin() + '[custom.system_names]\nx = "a"\nx = "b"\n'):
            self.config.write_text(text)
            self.assertIn('preserved', manager.zaparoo_art(self.card))
            self.assertEqual(self.config.read_text(), text)
            self.assertFalse(self.system.exists())

    def test_symlink_art_directory_is_not_followed(self):
        outside = self.card / 'personal'
        outside.mkdir()
        try:
            self.art.symlink_to(outside, target_is_directory=True)
        except OSError:
            self.skipTest('symlinks unavailable')
        self.config.write_text(self.pin())
        manager.zaparoo_art(self.card)
        self.assertEqual(list(outside.iterdir()), [])

    def test_config_changed_during_update_is_not_overwritten(self):
        self.config.write_text(self.pin())
        real = manager.write_if_changed
        def concurrent(path, data, *args, **kwargs):
            result = real(path, data, *args, **kwargs)
            if path == self.hub:
                self.config.write_text('# newer layout\n' + self.pin('icon = "personal"\n'))
            return result
        with patch.object(manager, 'write_if_changed', side_effect=concurrent):
            self.assertIn('retry', manager.zaparoo_art(self.card))
        self.assertIn('# newer layout', self.config.read_text())
        self.assertNotIn('MisterZine Plex', self.config.read_text())
        manager.zaparoo_art(self.card)
        self.assertIn('icon = "personal"', self.config.read_text())

    def test_packaged_manager_embeds_exact_source_logo(self):
        source = build_package.manager_source()
        encoded = source.split(b"ZAPAROO_LOGO = '", 1)[1].split(b"'", 1)[0]
        self.assertEqual(base64.b64decode(encoded),
                         (build_package.ROOT / 'app/internal/ui/assets/misterzine-stacked-v1.png').read_bytes())
        compile(source, 'packaged-manager.py', 'exec')


if __name__ == '__main__':
    unittest.main()
