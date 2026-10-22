"""Bundle tracked source and a qualified FPGA snapshot without local build state."""
import argparse
import hashlib
import json
import re
from pathlib import Path, PurePosixPath
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CORE = 'third_party/MiSTer_h264_decoder/'
EXCLUDED = ('.git', '.claude', 'private-beta', 'beta-unlocks', 'beta-keys', '__pycache__')


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def build(out, core_tree, dependencies, rbf_manifest):
    if (ROOT / 'PRIVATE_ASSEMBLY.json').exists():
        raise ValueError('Build distributable source from the public checkout, not a private assembly')
    provenance = json.loads(rbf_manifest.read_text())
    seed = provenance["fit"]["seed"]
    if not isinstance(seed, int) or seed < 1:
        raise ValueError("Qualified fitter seed is required")
    if subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=no'], cwd=ROOT).strip():
        raise ValueError('Commit tracked changes before bundling release source')
    names = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0')
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT).decode().strip()
    out = Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as archive:
        for name in sorted(filter(None, names)):
            p = PurePosixPath(name)
            if (p.name.startswith(('.env', 'plexcrt.json', '.plextoken')) or any(part in EXCLUDED for part in p.parts)) or p.suffix in ('.rbf', '.zip', '.key', '.code', '.receipt'):
                continue
            path = ROOT / name
            # Keep current test benches and documentation; they do not enter synthesis.
            # Hardware and build inputs come from the qualified snapshot.
            if name.startswith(CORE) and not name.startswith((CORE + 'bench/', CORE + 'docs/', CORE + 'site/')):
                snapshot = core_tree / name[len(CORE):]
                if snapshot.is_file():
                    path = snapshot
            if path.is_symlink():
                raise ValueError('Source symlinks require explicit review: ' + name)
            if not path.is_file():
                raise ValueError('Tracked source is missing: ' + name)
            if p.name == 'access-codes.json' or (p.suffix == '.go' and re.search(rb'^//go:build premium(?:\s|$)', path.read_bytes(), re.M)):
                raise ValueError('Private supporter source cannot be distributed: ' + name)
            if name == CORE + 'H264.qsf':
                text, count = re.subn(r'(?m)^set_global_assignment -name SEED [0-9]+$',
                                      'set_global_assignment -name SEED ' + str(seed), path.read_text())
                if count != 1:
                    raise ValueError('Expected one fitter seed assignment')
                archive.writestr('source/' + name, text)
            else:
                archive.write(path, 'source/' + name)
        build_id = core_tree / 'build_id.v'
        if not build_id.is_file():
            raise ValueError('Qualified core build_id.v is required')
        target = 'source/' + CORE + 'build_id.v'
        if target not in archive.namelist():
            archive.write(build_id, target)
        with zipfile.ZipFile(dependencies) as deps:
            if deps.testzip() is not None:
                raise ValueError('Dependency source archive is corrupt')
        archive.write(dependencies, 'dependency-sources.zip', compress_type=zipfile.ZIP_STORED)
        archive.writestr('SOURCE.json', json.dumps({
            'application_revision': revision,
            'qualified_fitter_seed': seed,
            'quartus_manifest_sha256': digest(rbf_manifest),
            'dependency_sources_sha256': digest(dependencies),
            'core_source': 'Qualified build snapshot; see the binary package original Quartus manifest.'
        }, indent=2) + '\n')
        archive.writestr('BUILD.txt', '''Application and worker: source/docs/BUILD.md and source/toolchain/README.md.
FPGA: source/third_party/MiSTer_h264_decoder/site/content/about/building.md and its build scripts.
The supplied core directory uses the qualified snapshot's source and build_id.v.
Dependency source archives and toolchain/relink notes are in dependency-sources.zip.

An ordinary source application build is ungated. Optional supporter components
are maintained separately and are not part of this public source archive.
Install modified binaries in a separate development directory as described in
BUILD.md; the official updater verifies official payload hashes.
''')
    out.with_suffix(out.suffix + '.sha256').write_text(digest(out) + '  ' + out.name + '\n')
    return out


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--core-tree', type=Path, required=True)
    p.add_argument('--dependencies', type=Path, required=True)
    p.add_argument('--rbf-manifest', type=Path, required=True)
    a = p.parse_args()
    print(build(a.out, a.core_tree, a.dependencies, a.rbf_manifest))
