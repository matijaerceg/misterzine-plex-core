import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import build_source


class SourceBundleTests(unittest.TestCase):
    def test_private_assembly_is_rejected_before_export(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'PRIVATE_ASSEMBLY.json').write_text('{}')
            with patch.object(build_source, 'ROOT', root):
                with self.assertRaisesRegex(ValueError, 'public checkout'):
                    build_source.build(root / 'out.zip', root, root / 'deps.zip', root / 'rbf.json')

    def test_dirty_worktree_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            manifest = root / 'rbf.json'
            manifest.write_text(json.dumps({'fit': {'seed': 7}}))
            with patch.object(build_source.subprocess, 'check_output', return_value=b' M app/main.go\n'):
                with self.assertRaisesRegex(ValueError, 'Commit tracked changes'):
                    build_source.build(root / 'out.zip', root, root / 'deps.zip', manifest)

    def test_snapshot_seed_and_private_state_exclusion(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            core = root / 'snapshot'
            core.mkdir()
            (core / 'H264.qsf').write_text('set_global_assignment -name SEED 9\n')
            (core / 'build_id.v').write_text('`define BUILD_DATE "260101"\n')
            (core / 'bench').mkdir()
            (core / 'bench/check.sv').write_text('old test')
            current_bench = root / build_source.CORE / 'bench'
            current_bench.mkdir(parents=True)
            (current_bench / 'check.sv').write_text('current test')
            (root / 'app').mkdir()
            (root / 'app/main.go').write_text('package main\n')
            (root / 'private.code').write_text('PRIVATE-FIXTURE')
            deps = root / 'deps.zip'
            with zipfile.ZipFile(deps, 'w') as z:
                z.writestr('README.txt', 'Synthetic source fixture')
            manifest = root / 'rbf.json'
            manifest.write_text(json.dumps({'fit': {'seed': 7}}))
            names = b'third_party/MiSTer_h264_decoder/bench/check.sv\0app/main.go\0third_party/MiSTer_h264_decoder/H264.qsf\0private.code\0.env\0plexcrt.json\0'
            with patch.object(build_source, 'ROOT', root), patch.object(build_source.subprocess, 'check_output', side_effect=[b'', names, b'fixture-revision\n']):
                out = build_source.build(root / 'out.zip', core, deps, manifest)
            with zipfile.ZipFile(out) as z:
                self.assertEqual(z.read('source/' + build_source.CORE + 'bench/check.sv'), b'current test')
                self.assertNotIn('source/private.code', z.namelist())
                self.assertEqual(z.read('source/' + build_source.CORE + 'H264.qsf'), b'set_global_assignment -name SEED 7\n')
                self.assertIn('source/' + build_source.CORE + 'build_id.v', z.namelist())
                self.assertNotIn(b'PRIVATE-FIXTURE', b''.join(z.read(n) for n in z.namelist()))
                self.assertEqual(json.loads(z.read('SOURCE.json'))['qualified_fitter_seed'], 7)
                with zipfile.ZipFile(io.BytesIO(z.read('dependency-sources.zip'))) as d:
                    self.assertEqual(d.read('README.txt'), b'Synthetic source fixture')


if __name__ == '__main__':
    unittest.main()
