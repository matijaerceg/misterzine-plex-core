#!/usr/bin/env python3
"""Build the presenter (arm/plexfb) from arm/plexfb.c and record what it was built from.

build_package.py refuses a presenter whose record does not match the current
arm/plexfb.c, so a release can never ship a binary left over from older source.
Run on Linux with the ARM hard-float cross GCC (on Windows, inside WSL)."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent
SOURCE = 'arm/plexfb.c'
BINARY = 'arm/plexfb'
RECORD = 'arm/plexfb.build.json'
FLAGS = ['-O2', '-static', '-march=armv7-a', '-mfpu=neon', '-mfloat-abi=hard', '-pthread']


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build(cc='arm-linux-gnueabihf-gcc', root=None):
    root = root or ROOT
    source = (root / SOURCE).read_bytes()
    # Compiled by its repository path from the root: the path is embedded in
    # the binary, so another spelling changes the hash.
    subprocess.run([cc] + FLAGS + ['-o', BINARY, SOURCE, '-lm'], cwd=root, check=True)
    if (root / SOURCE).read_bytes() != source:
        raise RuntimeError(SOURCE + ' changed during the build; build again')
    compiler = subprocess.run([cc, '--version'], cwd=root, check=True, capture_output=True, text=True).stdout
    record = {'source_sha256': hashlib.sha256(source).hexdigest(), 'binary_sha256': sha(root / BINARY),
              'compiler': compiler.splitlines()[0] if compiler else cc}
    (root / RECORD).write_text(json.dumps(record, indent=2) + '\n')
    return record


def check(root=None):
    """Raise unless arm/plexfb is the recorded build of the current arm/plexfb.c."""
    root = root or ROOT
    try:
        record = json.loads((root / RECORD).read_text())
    except (OSError, ValueError):
        raise ValueError('The presenter has no build record; build it with release/build_presenter.py') from None
    if record.get('source_sha256') != sha(root / SOURCE):
        raise ValueError('arm/plexfb was built from a different arm/plexfb.c; rebuild it with release/build_presenter.py')
    if record.get('binary_sha256') != sha(root / BINARY):
        raise ValueError('arm/plexfb is not the binary its build record describes; rebuild it with release/build_presenter.py')
    return record


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--cc', default='arm-linux-gnueabihf-gcc', help='ARM hard-float cross compiler')
    record = build(p.parse_args().cc)
    print('Built ' + BINARY + ' ' + record['binary_sha256'])
    print('From ' + SOURCE + ' ' + record['source_sha256'] + ' with ' + record['compiler'])
