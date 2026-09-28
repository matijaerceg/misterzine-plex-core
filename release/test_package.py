import io
import subprocess
import tempfile
import unittest
import zipfile
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

import build_package
import build_presenter

FILES = ['app/dist/plexcrt', 'arm/plexplay.py', 'arm/plexfb.c', 'core/PlexCRT.rbf', 'core/PlexCRT.qsf',
         'core/PlexCRT.qpf', 'core/PlexCRT.sdc', 'core/build_id.v',
         'core/LICENSE', 'core/PlexCRT.sv', 'core/files.qip',
         'core/LICENSING.md', 'core/rtl/fixture.v', 'core/sys/fixture.v',
         'release/manager.py', 'release/update_service.py', 'release/catalogue.py', 'release/menu_launcher.py', 'release/README.md', 'release/TERMS.md',
         'release/THIRD_PARTY_NOTICES.md', 'release/BETA_ACCESS.md',
         'release/licenses/fixture.txt']


def fake_gcc(args, cwd, check, capture_output=False, text=False):
    """The cross compiler: the binary depends on the source it was given."""
    if '--version' in args:
        return subprocess.CompletedProcess(args, 0, stdout='arm-linux-gnueabihf-gcc (fixture) 13.2.0\nCopyright\n')
    out = Path(cwd) / args[args.index('-o') + 1]
    out.write_bytes(b'presenter built from ' + (Path(cwd) / args[args.index('-o') + 2]).read_bytes())
    return subprocess.CompletedProcess(args, 0)


def fixture_tree(root):
    for name in FILES:
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b'synthetic public fixture')
    with patch.object(build_presenter.subprocess, 'run', side_effect=fake_gcc) as gcc:
        build_presenter.build(root=root)
    return gcc


def package(root):
    with patch.object(build_package, 'ROOT', root), redirect_stdout(io.StringIO()):
        return build_package.build(root / 'out', root / 'core', 'fixture', '0.2.0-beta.1')


class PackagePrivacyTests(unittest.TestCase):
    def test_private_access_files_never_enter_package(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fixture_tree(root)
            for folder in ('release/private-beta', 'app/dist', 'core/sys'):
                for suffix in ('.key', '.code', '.receipt'):
                    path = root / folder / ('private-fixture' + suffix)
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(b'SYNTHETIC-PRIVATE-MATERIAL')
            package(root)
            with zipfile.ZipFile(next((root / 'out').glob('*.zip'))) as archive:
                for name in archive.namelist():
                    self.assertFalse(name.endswith(('.key', '.code', '.receipt')))
                    data = archive.read(name)
                    self.assertNotIn(b'SYNTHETIC-PRIVATE-MATERIAL', data)
                    if name.endswith('corresponding-source.zip'):
                        with zipfile.ZipFile(io.BytesIO(data)) as source:
                            for member in source.namelist():
                                self.assertFalse(member.endswith(('.key', '.code', '.receipt')))
                                self.assertNotIn(b'SYNTHETIC-PRIVATE-MATERIAL', source.read(member))


class PresenterBuildTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.gcc = fixture_tree(self.root)

    def test_build_compiles_by_repository_path_and_records_both_hashes(self):
        args, kwargs = self.gcc.call_args_list[0]
        self.assertEqual(args[0][-4:], ['-o', 'arm/plexfb', 'arm/plexfb.c', '-lm'])
        self.assertEqual(kwargs['cwd'], self.root)
        record = build_presenter.check(self.root)
        self.assertEqual(record['source_sha256'], build_presenter.sha(self.root / 'arm/plexfb.c'))
        self.assertEqual(record['binary_sha256'], build_presenter.sha(self.root / 'arm/plexfb'))
        self.assertEqual(record['compiler'], 'arm-linux-gnueabihf-gcc (fixture) 13.2.0')
        package(self.root)
        with zipfile.ZipFile(next((self.root / 'out').glob('*.zip'))) as archive:
            self.assertEqual(archive.read('misterzine-plex-beta/payload/plexfb'), (self.root / 'arm/plexfb').read_bytes())

    def refused(self, message):
        with self.assertRaisesRegex(ValueError, message):
            package(self.root)
        self.assertFalse((self.root / 'out').exists(), 'a refused package must write nothing')

    def test_package_refuses_a_presenter_from_older_source(self):
        (self.root / 'arm/plexfb.c').write_bytes(b'newer presenter source')
        self.refused('built from a different arm/plexfb.c')

    def test_package_refuses_a_replaced_presenter(self):
        (self.root / 'arm/plexfb').write_bytes(b'a binary copied from elsewhere')
        self.refused('not the binary its build record describes')

    def test_package_refuses_a_presenter_without_a_record(self):
        (self.root / 'arm/plexfb.build.json').unlink()
        self.refused('no build record')

    def test_rebuilding_after_a_source_change_is_accepted(self):
        (self.root / 'arm/plexfb.c').write_bytes(b'newer presenter source')
        with patch.object(build_presenter.subprocess, 'run', side_effect=fake_gcc):
            build_presenter.build(root=self.root)
        package(self.root)
