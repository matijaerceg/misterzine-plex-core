import hashlib
import io
import json
import tempfile
import unittest
import zipfile
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

import build_package


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.dist = self.root / 'app/dist'
        self.dist.mkdir(parents=True)
        self.core = self.root / 'private/PlexH264_qualified.rbf'
        self.core.parent.mkdir(parents=True)
        self.core.write_bytes(b'qualified rbf fixture')
        self.rbf_manifest = self.root / 'private/quartus-rbf-manifest.json'
        self.rbf_manifest.write_text(json.dumps({
            'schema': 1, 'core_version': 'plex-1.0.0-beta.1', 'build_date': '261018',
            'rbf': {'name': self.core.name, 'bytes': self.core.stat().st_size,
                    'sha256': build_package.sha(self.core), 'marginal': False},
            'git': {'branch': 'fixture', 'sha': 'abc123', 'dirty': False},
            'fit': {'seed': 7}, 'timing': {'pass': True, 'clk_dec_100c_mhz': 103.67},
            'toolchain': {'quartus': '17.0.2'}}))
        self.worker = self.root / 'jfplay'
        self.worker.write_bytes(b'ARM worker')
        self.ffmpeg = self.root / 'ffmpeg'
        self.ffmpeg.write_bytes(b'ARM static ffmpeg')
        self.app = self.dist / 'plexcrt'
        self.app.write_bytes(b'ARM app')
        self.verifier = hashlib.sha256(b'synthetic verifier').hexdigest()
        # The stamp as beta_release.py writes it: the code's hash travels
        # with the batch into the manifest and the catalogue.
        (self.dist / 'plexcrt.build.json').write_text(json.dumps({
            'id': 'fixture', 'version': '1.0.0-beta.1', 'channel': 'beta',
            'access': {'batch': 'fixture-batch', 'sha256': self.verifier},
            'binary_sha256': build_package.sha(self.app)}))
        self.source = self.root / 'corresponding-source.zip'
        with zipfile.ZipFile(self.source, 'w') as z:
            z.writestr('BUILD.md', 'fixture source and exact build recipe')
            z.writestr('H264/rtl/fixture.sv', 'source')
        release = self.root / 'release'
        release.mkdir()
        for name in ('manager.py', 'update_service.py', 'catalogue.py', 'menu_launcher.py', 'README.md', 'TERMS.md', 'THIRD_PARTY_NOTICES.md', 'BETA_ACCESS.md'):
            (release / name).write_text('# fixture')
        # The packager embeds the Zaparoo artwork in manager.py.
        (release / 'manager.py').write_text("ZAPAROO_LOGO = ''\n")
        logo = self.root / 'app/internal/ui/assets/misterzine-stacked-v1.png'
        logo.parent.mkdir(parents=True)
        logo.write_bytes(b'synthetic-logo')
        (release / 'licenses').mkdir()
        (release / 'licenses/NOTICE.txt').write_text('notice')
        self.release_dir = release

    def build(self):
        with patch.object(build_package, 'ROOT', self.root), redirect_stdout(io.StringIO()):
            return build_package.build(self.root / 'out', 'fixture', '1.0.0-beta.1',
                                       self.worker, self.ffmpeg, self.core,
                                       self.rbf_manifest, self.source)

    def test_beta_package_is_allowlisted_keeps_core_provenance_and_carries_access(self):
        path = self.build()
        with zipfile.ZipFile(path) as archive:
            files = set(archive.namelist())
            payload = {name.removeprefix('misterzine-plex-beta/payload/')
                       for name in files if name.startswith('misterzine-plex-beta/payload/')}
            self.assertEqual(payload, {'plexcrt', 'jfplay', 'ffmpeg', 'PlexH264.rbf'})
            self.assertIn('misterzine-plex-beta/TERMS.md', files)
            manifest = json.loads(archive.read('misterzine-plex-beta/manifest.json'))
            self.assertEqual(manifest['access'], {'batch': 'fixture-batch', 'sha256': self.verifier})
            self.assertEqual(manifest['core']['sha256'], build_package.sha(self.core))
            self.assertEqual(manifest['core']['quartus_manifest_sha256'], build_package.sha(self.rbf_manifest))
            self.assertEqual(manifest['source']['sha256'], build_package.sha(self.source))
            self.assertEqual(manifest['source']['size'], self.source.stat().st_size)
            self.assertEqual(archive.read('misterzine-plex-beta/provenance/quartus-rbf-manifest.json'),
                             self.rbf_manifest.read_bytes())
            self.assertIn(b"ZAPAROO_LOGO = '", archive.read('misterzine-plex-beta/manager.py'))
            installer = archive.read('Scripts/MisterZine-Plex-Install.sh').decode()
            self.assertIn('/media/fat/misterzine-plex-beta/manager.py install', installer)
            self.assertIn('/media/fat/misterzine-plex/manager.py run', installer)
        self.assertEqual(path.name, 'MisterZine-Plex-Core-fixture.zip')
        self.assertEqual((self.root / 'out' / manifest['source']['filename']).read_bytes(), self.source.read_bytes())

    def test_beta_build_fails_closed_on_missing_or_malformed_gate_metadata(self):
        metadata = self.dist / 'plexcrt.build.json'
        original = json.loads(metadata.read_text())
        for changes in ({'access': {'batch': '', 'sha256': self.verifier}},
                        {'access': {'batch': 'fixture-batch', 'sha256': 'bad'}},
                        {'access': None}, {'binary_sha256': '0' * 64},
                        {'channel': 'public', 'access': None},
                        {'channel': 'public', 'version': '1.0.0', 'access': {'batch': 'fixture-batch', 'sha256': self.verifier}}):
            with self.subTest(changes=changes):
                bad = dict(original, **changes)
                metadata.write_text(json.dumps(bad))
                with patch.object(build_package, 'ROOT', self.root), self.assertRaises(ValueError):
                    build_package.build(self.root / 'out', 'fixture', '1.0.0-beta.1',
                                        self.worker, self.ffmpeg, self.core,
                                        self.rbf_manifest, self.source)
        metadata.write_text(json.dumps(original))

    def test_rejects_unqualified_or_mismatched_core(self):
        provenance = json.loads(self.rbf_manifest.read_text())
        provenance['rbf']['marginal'] = True
        self.rbf_manifest.write_text(json.dumps(provenance))
        with patch.object(build_package, 'ROOT', self.root), self.assertRaises(ValueError):
            build_package.build(self.root / 'out', 'fixture', '1.0.0-beta.1',
                                self.worker, self.ffmpeg, self.core,
                                self.rbf_manifest, self.source)

    def test_rejects_dirty_or_test_labelled_core(self):
        good = json.loads(self.rbf_manifest.read_text())
        for field, value in (('git', {'branch': 'fixture', 'sha': 'abc123', 'dirty': True}),
                             ('git', {'branch': 'fixture', 'sha': 'abc123'}),
                             ('core_version', 'dev-test')):
            self.rbf_manifest.write_text(json.dumps(dict(good, **{field: value})))
            with self.subTest(field=field, value=value), \
                    patch.object(build_package, 'ROOT', self.root), self.assertRaises(ValueError):
                build_package.build(self.root / 'out', 'fixture', '1.0.0-beta.1',
                                    self.worker, self.ffmpeg, self.core,
                                    self.rbf_manifest, self.source)


if __name__ == '__main__':
    unittest.main()
