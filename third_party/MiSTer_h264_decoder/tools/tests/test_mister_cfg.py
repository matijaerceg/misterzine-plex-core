#!/usr/bin/env python3
"""mister.py's settings backup: `launch` overwrites the core's saved settings
(config/H264_vN.CFG) and `restore` must leave config/ as the maintainer had it.

The shell mister.py generates is run by local bash against a temporary config/ (its
ssh and FIFO stubbed), two launches then the restore's settings block, from both
starting states:
  none -- no settings file before the harness: restore leaves NO file. Without the
          .hilnew marker the second launch backed up the first launch's all-zero file
          as the user's and restore put it back (found by the H264 fork's P0 HW gate,
          2026-09-27; the rig had exactly such a file).
  user -- the maintainer's own file: restore puts it back byte for byte.
"""
import os
import re
import contextlib
import io
import subprocess
import sys
import tempfile
import types

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.dirname(HERE)
USER = b'USERSETTINGS0123'
fails = 0


def bash(script, check=True, timeout=120):
    p = subprocess.run(['bash', '-s'], input=script, capture_output=True, text=True)
    if check and p.returncode != 0:
        raise RuntimeError(p.stderr)
    return p.returncode, p.stdout


def scenario(mode):
    t = tempfile.mkdtemp()
    cfg, core = os.path.join(t, 'config'), os.path.join(t, 'core')
    os.makedirs(cfg)
    os.makedirs(core)
    os.environ['MISTER_CFG_DIR'] = cfg
    os.environ['MISTER_CORE_DIR'] = core
    sys.modules.pop('mister', None)            # re-read the directories from the environment
    import mister as m
    m.ssh, m.fifo = bash, (lambda c: None)
    f = os.path.join(cfg, m.CFG_NAME)
    if mode == 'user':
        open(f, 'wb').write(USER)
    a = types.SimpleNamespace(image=None, opt=[], delay=1, no_wait=True, timeout=1)   # no file slot here
    m.cmd_launch(a)
    m.cmd_launch(a)                            # the second launch is the one that went wrong
    script = m.RESTORE_SCRIPT.replace('@CFGDIR@', cfg).replace('@CFG@', m.CFG_NAME)
    blk = re.search(r'^if \[ -f ' + re.escape(cfg) + r'/.*?^fi$', script, re.S | re.M)
    if not blk:
        return m.CFG_NAME, None, 'the restore script has no settings block'
    bash(blk.group(0))
    left = sorted(os.listdir(cfg))
    body = open(f, 'rb').read() if os.path.exists(f) else None
    return m.CFG_NAME, left, body


sys.path.insert(0, TOOLS)
for mode in ('none', 'user'):
    with contextlib.redirect_stdout(io.StringIO()):     # launch prints the options it set
        name, left, body = scenario(mode)
    want = ([], None) if mode == 'none' else ([name], USER)
    ok = (left, body) == want
    print(f"  {'PASS' if ok else 'FAIL'} {mode}: config/ after restore = {left}, file = {body!r}"
          + ('' if ok else f'; want {want}'))
    fails += not ok

print('test_mister_cfg: ' + ('ALL GREEN' if fails == 0 else '%d FAILED' % fails))
sys.exit(1 if fails else 0)
