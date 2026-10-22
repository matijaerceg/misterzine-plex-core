#!/usr/bin/env python3
"""
mister.py -- drive a MiSTer running the H264 core, over ssh.

The hardware-in-the-loop harness: deploy a build, launch an image, press buttons,
and pull back a screenshot -- so a session can SEE the core instead of asking
someone to test and report. Inherited from MiSTer_UMD_Video (itself from MiSTer_DVD),
cut down to the parts that need NOTHING but a stock MiSTer Main: UMD's HIL Main fork
(telemetry over EXT_BUS, the live OSD channel) is not carried -- the HPS interface's status
block is the telemetry (`stat`; decided 2026-09-27, docs/hil_harness.md). Design notes and the
facts it relies on are in docs/hil_harness.md.

Four stock mechanisms:

  load_core   /dev/MiSTer_cmd accepts an .mgl, which loads a core (and can mount
              media in the same command; this core has no file slot yet).
  screenshot  the same FIFO writes a PNG of the CORE's raw raster (read from
              ascal's INPUT buffer), so it carries no MiSTer OSD, no popups and
              no scaling. You cannot see the OSD in a shot -- which is why options
              are set by writing the settings file, not by navigating menus.
  H264_vN.CFG the core's saved settings are a raw dump of Main's 128-bit status
              word, read at core init before reset is released -- so writing 16
              bytes sets any OSD option for the next launch.
  uinput      a virtual keyboard on the target (tools/mister_keyd.py) reaches the
              core's PS/2 path once h264/kbd_map.sv exists (it may never: an
              HPS program drives this core). Until then `key` knows only the OSD
              toggle.

Configuration, in precedence order -- NEVER hardcode a host; this repository will
be public:
    $MISTER_HOST                 e.g. root@<mister-ip>
    tools/.mister_host           one line, gitignored
    $MISTER_CORE_DIR             default /media/fat/_Other
    $MISTER_CFG_DIR              default /media/fat/config

⚠ The rig is the maintainer's. Run `state` first, and `restore` when done.

Usage:
    mister.py state
    mister.py deploy [--rbf PATH] [--agent]
    mister.py launch [<image-on-the-mister>] [--opt "Name=Value"] ... [--delay N]
    mister.py wait
    mister.py key <name> [<name> ...]
    mister.py shot [-o FILE]
    mister.py options
    mister.py restore
    mister.py shell -- <command>
    mister.py deploy --bin                    hps/build/arm/{h264play,h264stat} -> $MISTER_BIN_DIR
    mister.py feed <clip-on-the-mister> [--bg] [-- <h264play options>]
    mister.py stat [--watch N]

Feeding (roadmap Phase 3): the reference feeder hps/h264play runs ON the rig (build it with
USE_DOCKER=1 hps/build_arm.sh, copy it with `deploy --bin`), loads the core through an MGL
naming the harness's rbf, and plays a clip from the rig's own storage (test on LOCAL media:
docs/hw_budget_and_lessons.md S6). `stat` reads the status block (h264stat --json): the
telemetry is the interface's own status block, no HIL Main.
"""

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import docs_check                                    # noqa: E402  (CONF_STR parser)

CORE_NAME = 'H264'                                    # CONF_STR[0]; /tmp/CORENAME reads this
CORE_DIR = os.environ.get('MISTER_CORE_DIR', '/media/fat/_Other')
CFG_DIR = os.environ.get('MISTER_CFG_DIR', '/media/fat/config')
SHOT_DIR = '/media/fat/screenshots'
# A FIXED name, deliberately. MGL <rbf> resolution takes the lexicographically
# GREATEST match (mra_loader.cpp), not the newest file, so a bare "H264" would pick
# whichever H264_* build sorts last. The core name comes from CONF_STR, not the
# filename, so renaming costs nothing.
HIL_RBF = 'H264_hil.rbf'
HIL_MGL = 'H264_hil.mgl'
EMU = os.path.join(ROOT, 'h264', 'emu.sv')
BIN_DIR = os.environ.get('MISTER_BIN_DIR', '/media/fat/h264hil')     # the hps/ binaries (restore removes it)
BIN_SRC = os.path.join(ROOT, 'hps', 'build', 'arm')
KBD_MAP = os.path.join(ROOT, 'h264', 'kbd_map.sv')


def _cfg_name():
    """The saved-settings filename, READ FROM emu.sv's CONF_STR "v,N" line.

    A hardcoded name goes stale the day the config version is bumped, and a stale
    one fails SILENTLY: every --opt writes a file the core never reads and the
    harness measures defaults while reporting the options it thought it set.
    """
    try:
        m = re.search(r'"v,(\d+);"', open(EMU).read())
        if m:
            return '%s_v%s.CFG' % (CORE_NAME, m.group(1))
    except Exception:
        pass
    return CORE_NAME + '.CFG'


CFG_NAME = _cfg_name()
AGENT_SRC = os.path.join(HERE, 'mister_keyd.py')
AGENT_DST = '/tmp/mister_keyd.py'
AGENT_FIFO = '/tmp/mister_hil'

SSH_OPTS = [
    '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8',
    '-o', 'StrictHostKeyChecking=accept-new',
    '-o', 'ControlMaster=auto', '-o', 'ControlPath=~/.ssh/cm-mister-%C',
    '-o', 'ControlPersist=120',
]


def kill_exact(cmdline):
    """Shell snippet: kill every process whose argv is EXACTLY `cmdline`.

    The MiSTer has NO pkill and no killall: `pkill -f ...` fails silently, and
    MiSTer_DVD found 18 leaked key daemons that way. Walk /proc instead; an EXACT
    argv match so it cannot hit the shell running this very script.
    """
    return ("for pid in $(ls /proc | grep -E '^[0-9]+$'); do\n"
            "  c=$( { tr '\\000' ' ' < /proc/$pid/cmdline; } 2>/dev/null )\n"
            f"  [ \"$c\" = \"{cmdline} \" ] && kill $pid 2>/dev/null\n"
            "done\n")


RESTORE_SCRIPT = """
@KILL_AGENT@
for p in /proc/[0-9]*; do                    # a feeder still running (no pkill on the MiSTer)
  [ "$(readlink $p/exe 2>/dev/null)" = "@BINDIR@/h264play" ] && kill ${p#/proc/} 2>/dev/null
done
rm -f @FIFO@ @AGENT@ @COREDIR@/@RBF@ @COREDIR@/@MGL@ /tmp/h264ring.mgl /tmp/h264play.log
rm -rf @BINDIR@
echo "  harness files removed (core, mgl, agent, the hps binaries)"
if [ -f @CFGDIR@/@CFG@.hilbak ]; then
  mv -f @CFGDIR@/@CFG@.hilbak @CFGDIR@/@CFG@
  echo "  restored the saved settings the harness had overwritten"
elif [ -f @CFGDIR@/@CFG@.hilnew ]; then
  rm -f @CFGDIR@/@CFG@ @CFGDIR@/@CFG@.hilnew
  echo "  removed the settings file the harness had created"
fi
# Removing the .rbf does not unload it: a harness-launched H264 core keeps running. Back
# to the menu -- but only if it is OUR core; any other core is the maintainer's.
if [ "$(cat /tmp/CORENAME 2>/dev/null)" = "@CORE@" ] && [ -f /media/fat/menu.rbf ]; then
  echo "load_core /media/fat/menu.rbf" > /dev/MiSTer_cmd
  echo "  @CORE@ core unloaded: back to the menu"
  sleep 4                                    # let the menu load land before `state` reads it
fi
true
"""


# ---------------------------------------------------------------------------
# transport
# ---------------------------------------------------------------------------
def host():
    h = os.environ.get('MISTER_HOST')
    if h:
        return h.strip()
    path = os.path.join(HERE, '.mister_host')
    if os.path.exists(path):
        h = open(path).read().strip()
        if h:
            return h
    sys.exit('mister: no host. Set $MISTER_HOST or write tools/.mister_host '
             '(one line, e.g. root@<mister-ip>). It is gitignored.')


def ssh(script, check=True, timeout=120):
    """Run a shell script on the target. Returns (rc, stdout)."""
    p = subprocess.run(['ssh', *SSH_OPTS, host(), 'bash -s'],
                       input=script, capture_output=True, text=True,
                       timeout=timeout)
    if check and p.returncode != 0:
        sys.stderr.write(p.stderr)
        sys.exit(f'mister: remote command failed (rc={p.returncode})')
    return p.returncode, p.stdout


def scp(src, dst, to_target=True, timeout=180):
    a, b = (src, f'{host()}:{dst}') if to_target else (f'{host()}:{src}', dst)
    p = subprocess.run(['scp', *SSH_OPTS, '-q', a, b],
                       capture_output=True, text=True, timeout=timeout)
    if p.returncode != 0:
        sys.stderr.write(p.stderr)
        sys.exit(f'mister: scp failed ({a} -> {b})')


def fifo(cmd):
    """Write ONE command to /dev/MiSTer_cmd. One per write, always: Main does a single
    read() then one if/else chain, so a second command in the same write is dropped."""
    ssh(f'echo {shlex.quote(cmd)} > /dev/MiSTer_cmd\n')


# ---------------------------------------------------------------------------
# key names, derived from the RTL rather than hand-listed
# ---------------------------------------------------------------------------
# PS/2 set-2 -> Linux keycode, inverted from Main's own ev2ps2[] (input.cpp).
PS2_TO_LINUX = {
    (0x04, False): 61, (0x05, False): 59, (0x06, False): 60, (0x0C, False): 62,
    (0x0D, False): 15, (0x1B, False): 31, (0x1C, False): 30, (0x22, False): 45,
    (0x23, False): 32, (0x29, False): 57, (0x2B, False): 33, (0x2C, False): 20,
    (0x2D, False): 19, (0x31, False): 49, (0x32, False): 48, (0x34, False): 34,
    (0x3A, False): 50, (0x4D, False): 25, (0x5A, False): 28, (0x66, False): 14,
    (0x76, False): 1,
    (0x15, False): 16, (0x1A, False): 44, (0x03, False): 63,
    (0x4B, False): 38, (0x49, False): 52,
    (0x24, False): 18, (0x79, False): 78, (0x7B, False): 74,
    (0x5A, True): 96, (0x6B, True): 105, (0x72, True): 108, (0x74, True): 106,
    (0x75, True): 103, (0x7A, True): 109, (0x7D, True): 104,
}
DPAD = {0: 'right', 1: 'left', 2: 'down', 3: 'up'}
KEY_F12 = 88


def kbd_map_table():
    """Parse h264/kbd_map.sv -> {joy bit: [(ps2 code, extended), ...]}.

    Derived, not transcribed, so a new binding in the RTL is usable the same day.
    Returns {} while the module does not exist.
    """
    if not os.path.exists(KBD_MAP):
        return {}
    src = open(KBD_MAP).read()
    m = re.search(r'if \(ps2_key\[8\]\) begin(.*?)\n\s*end else begin(.*?)\n\s*end\b',
                  src, re.S)
    if not m:
        sys.exit('mister: could not find the kbd_map.sv decode table')
    out = {}
    for extended, body in ((True, m.group(1)), (False, m.group(2))):
        body = re.sub(r'//[^\n]*', '', body)
        for code, bit in re.findall(r"8'h([0-9A-Fa-f]{2}):\s*hit\[(\d+)\]", body):
            out.setdefault(int(bit), []).append((int(code, 16), extended))
    return out


def key_names():
    """{name: linux keycode} for every transport action the core exposes."""
    lits = docs_check.extract_conf_str(open(EMU).read())
    _, buttons, _ = docs_check.parse(lits)
    names = {}
    for bit, codes in sorted(kbd_map_table().items()):
        linux = None
        for code, ext in codes:
            linux = PS2_TO_LINUX.get((code, ext))
            if linux is not None:
                break
        if linux is None:
            continue
        if bit in DPAD:
            label = DPAD[bit]
        elif bit - 4 < len(buttons):
            label = buttons[bit - 4]
        else:
            continue
        names[label.lower().replace(' ', '-')] = linux
    names['osd'] = KEY_F12          # Main's OSD toggle, not a core action
    return names


# ---------------------------------------------------------------------------
# OSD options -> the 16-byte saved-settings blob
# ---------------------------------------------------------------------------
def options():
    return docs_check.parse_bits(docs_check.extract_conf_str(open(EMU).read()))


def build_status(opts):
    """[('Aspect Ratio', '16:9'), ...] -> 16 bytes of cur_status. ALL 16 bytes are
    written from the full option set: the blob has no version or checksum."""
    table = options()
    by_label = {label.lower(): (label, s, e, vals) for label, s, e, vals in table}
    word = 0
    for name, value in opts:
        entry = by_label.get(name.strip().lower())
        if entry is None:
            sys.exit(f'mister: unknown option {name!r}. Try: mister.py options')
        label, start, end, vals = entry
        value = value.strip()
        idx = None
        for i, v in enumerate(vals):
            if v.strip().lower() == value.lower():
                idx = i
                break
        if idx is None:
            if re.fullmatch(r'\d+', value):
                idx = int(value)
            else:
                sys.exit(f'mister: {label!r} has no value {value!r}. '
                         f'Choices: {", ".join(vals)}')
        width = end - start + 1
        if idx >= (1 << width):
            sys.exit(f'mister: value {idx} does not fit {label!r} ({width} bits)')
        word |= idx << start
    return word.to_bytes(16, 'little')


# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------
def newest_rbf():
    rel = os.path.join(ROOT, 'releases')
    cands = [os.path.join(rel, f) for f in os.listdir(rel)] if os.path.isdir(rel) else []
    cands = [c for c in cands if c.endswith('.rbf')]
    if not cands:
        sys.exit('mister: no .rbf in releases/ -- build one, or pass --rbf')
    return max(cands, key=os.path.getmtime)


def cmd_restore(args):
    """Put the rig back: harness files removed, the user's saved settings restored."""
    script = RESTORE_SCRIPT.replace('@KILL_AGENT@', kill_exact(f'python3 {AGENT_DST}')) \
                           .replace('@CORE@', CORE_NAME).replace('@AGENT@', AGENT_DST).replace('@FIFO@', AGENT_FIFO) \
                           .replace('@COREDIR@', CORE_DIR).replace('@CFGDIR@', CFG_DIR) \
                           .replace('@RBF@', HIL_RBF).replace('@MGL@', HIL_MGL) \
                           .replace('@CFG@', CFG_NAME).replace('@BINDIR@', BIN_DIR)
    _, out = ssh(script)
    print('restore:')
    print(out.rstrip())
    st = os.path.join(HERE, '.mister_state.json')
    if os.path.exists(st):
        os.remove(st)
    return 0


# the ARM tools `deploy --bin` copies (hps/build/arm): the feeder, the status reader, and the
# CAVLC -> CABAC rewriter's file tool (its --bench measures the rewrite on the rig's A9, fj#20)
HIL_BINS = ('h264play', 'h264stat', 'cavlc2cabac')


def cmd_deploy(args):
    ssh(f'mkdir -p {SHOT_DIR}\n')
    if args.bin:
        for b in HIL_BINS:
            src = os.path.join(BIN_SRC, b)
            if not os.path.exists(src):
                sys.exit(f'mister: {src} missing -- build it: USE_DOCKER=1 hps/build_arm.sh')
        ssh(f'mkdir -p {BIN_DIR}\n')
        for b in HIL_BINS:
            scp(os.path.join(BIN_SRC, b), f'{BIN_DIR}/{b}')
        ssh(f'chmod +x ' + ' '.join(f'{BIN_DIR}/{b}' for b in HIL_BINS) + '\n')
        print(f'deploy: {", ".join(HIL_BINS)} -> {BIN_DIR}')
        for c in args.clip or []:
            scp(c, f'{BIN_DIR}/{os.path.basename(c)}')
            print(f'deploy: {os.path.basename(c)} -> {BIN_DIR} (local storage: removed by restore)')
        if not args.rbf and not args.agent:
            return
    if args.agent:
        scp(AGENT_SRC, AGENT_DST)
        _, out = ssh(kill_exact(f'python3 {AGENT_DST}') + f'''
rm -f {AGENT_FIFO}
setsid python3 {AGENT_DST} </dev/null >>/tmp/mister_keyd.log 2>&1 &
sleep 2
[ -p {AGENT_FIFO} ] && echo "agent: listening" || echo "agent: FIFO MISSING"
''')
        print(out.strip())
    # `--agent` alone means "agent only"; an explicit --rbf is an instruction and wins.
    if args.rbf or not args.agent:
        rbf = args.rbf or newest_rbf()
        print(f'deploy: {os.path.basename(rbf)} -> {CORE_DIR}/{HIL_RBF}')
        scp(rbf, f'{CORE_DIR}/{HIL_RBF}')
        meta = rbf + '.json'
        state = {'rbf': os.path.basename(rbf), 'deployed': time.strftime('%F %T')}
        if os.path.exists(meta):
            try:
                j = json.load(open(meta))
                state['core_version'] = j.get('core_version')
                state['git_sha'] = (j.get('git') or {}).get('sha')
                state['seed'] = (j.get('fit') or {}).get('seed')
                state['marginal'] = (j.get('rbf') or {}).get('marginal')
            except Exception:
                pass
        with open(os.path.join(HERE, '.mister_state.json'), 'w') as f:
            json.dump(state, f, indent=2)
        for k, v in state.items():
            print(f'  {k}: {v}')
        # A core already running keeps its OLD bitstream: scp only replaced the file, and
        # h264play loads the core only when /tmp/CORENAME is not H264 (found 2026-09-29, Phase
        # 4: a "retest" of a fix ran on the previous build). Reload it from the new file --
        # the MGL alone, the saved settings untouched -- and wait for it.
        _, cur = ssh('cat /tmp/CORENAME 2>/dev/null\n', check=False, timeout=30)
        if cur.strip() == CORE_NAME:
            mgl = (f'<mistergamedescription>\n'
                   f'  <rbf>{os.path.basename(CORE_DIR)}/{HIL_RBF[:-4]}</rbf>\n'
                   f'</mistergamedescription>\n')
            ssh(f"cat > {CORE_DIR}/{HIL_MGL} <<'MGLEOF'\n{mgl}MGLEOF\n")
            fifo(f'load_core {CORE_DIR}/{HIL_MGL}')
            time.sleep(3)                              # CORENAME stays H264 across the reload
            cmd_wait(argparse.Namespace(timeout=60, delay=0))
            print('deploy: the running core was reloaded from the new file')


def cmd_launch(args):
    img = args.image
    if img and not re.search(r'"S\d,', open(EMU).read()):
        sys.exit('mister: this core has no file slot (no "S0," in CONF_STR) -- launch it without an image')
    opts = [tuple(o.split('=', 1)) for o in (args.opt or [])]
    for o in opts:
        if len(o) != 2:
            sys.exit('mister: --opt takes "Name=Value"')
    blob = build_status(opts)
    print(f'launch: {img or "(no image)"}')
    if opts:
        print('  options: ' + ', '.join(f'{k}={v}' for k, v in opts))
    print(f'  status word: {blob.hex()}')
    mount = f'  <file delay="{args.delay}" type="s" index="0" path="{img}"/>\n' if img else ''
    mgl = (f'<mistergamedescription>\n'
           f'  <rbf>{os.path.basename(CORE_DIR)}/{HIL_RBF[:-4]}</rbf>\n'
           f'{mount}'
           f'</mistergamedescription>\n')
    # This OVERWRITES the user's saved OSD settings for the core. Back them up once.
    ssh(f'''
# Back up the user's file ONCE; if there was none, mark that the harness created it, so a
# second launch does not back up the harness's own file as the user's (found at the P0
# HW gate: restore put the first launch's all-zero file back as "the user's settings").
if [ ! -f {CFG_DIR}/{CFG_NAME}.hilbak ] && [ ! -f {CFG_DIR}/{CFG_NAME}.hilnew ]; then
  if [ -f {CFG_DIR}/{CFG_NAME} ]; then cp {CFG_DIR}/{CFG_NAME} {CFG_DIR}/{CFG_NAME}.hilbak
  else touch {CFG_DIR}/{CFG_NAME}.hilnew; fi
fi
python3 -c "import sys;open('{CFG_DIR}/{CFG_NAME}','wb').write(bytes.fromhex('{blob.hex()}'))"
cat > {CORE_DIR}/{HIL_MGL} <<'MGLEOF'
{mgl}MGLEOF
''')
    fifo(f'load_core {CORE_DIR}/{HIL_MGL}')
    if not args.no_wait:
        cmd_wait(args)


def cmd_wait(args):
    """Wait for the core to be loaded, then for the MGL delay to have elapsed."""
    deadline = time.time() + args.timeout
    while time.time() < deadline:
        _, out = ssh('cat /tmp/CORENAME 2>/dev/null\n', check=False, timeout=30)
        if out.strip() == CORE_NAME:
            break
        time.sleep(0.5)
    else:
        sys.exit(f'mister: timed out waiting for the {CORE_NAME} core')
    # No custom Main here, so there is no "MGL finished" log line to wait on; the
    # mount lands `delay` seconds after the load. Wait that out plus a margin.
    time.sleep(getattr(args, 'delay', 2) + 1.5)
    print(f'  {CORE_NAME} core loaded')


def cmd_key(args):
    names = key_names()
    codes = []
    for n in args.names:
        n = n.lower()
        if n not in names:
            sys.exit(f'mister: unknown key {n!r}. Known: {", ".join(sorted(names))}')
        codes.append(names[n])
    _, out = ssh(f'''
[ -p {AGENT_FIFO} ] || {{ echo "NOAGENT"; exit 0; }}
echo "keys {' '.join(str(c) for c in codes)}" > {AGENT_FIFO}
echo sent
''')
    if 'NOAGENT' in out:
        sys.exit('mister: key daemon is not running -- `mister.py deploy --agent`')
    print(f'key: {" ".join(args.names)}  ({", ".join(str(c) for c in codes)})')


def cmd_shot(args):
    name = 'hil.png'
    # --scaled: Main's `screenshot scaled` captures the SCALER's output (the HDMI frame,
    # cropped to the active picture), so the image's width shows the aspect the core
    # reports (VIDEO_ARX/ARY): 1440x1080 for 4:3, 1920x1080 for 16:9 on a 1080p output.
    # The plain shot is the core's raw raster, where aspect is invisible.
    what = 'screenshot scaled' if args.scaled else 'screenshot'
    # The PNG is written asynchronously with no temp-and-rename: poll for existence
    # AND a stable size.
    ssh(f'''
rm -f {SHOT_DIR}/{name}
echo '{what} {name}' > /dev/MiSTer_cmd
for i in $(seq 1 20); do
  sleep 0.25
  if [ -f {SHOT_DIR}/{name} ]; then
    a=$(stat -c %s {SHOT_DIR}/{name}); sleep 0.25
    b=$(stat -c %s {SHOT_DIR}/{name})
    [ "$a" = "$b" ] && [ "$a" != 0 ] && exit 0
  fi
done
echo "NOSHOT"; exit 1
''', check=False)
    out = args.out or os.path.join(
        os.environ.get('TMPDIR', '/tmp'), f'mister_{time.strftime("%H%M%S")}.png')
    scp(f'{SHOT_DIR}/{name}', out, to_target=False)
    print(f'shot: {out}')


def cmd_state(args):
    _, out = ssh('''
echo "corename=$(cat /tmp/CORENAME 2>/dev/null)"
for p in $(ls /proc | grep -E '^[0-9]+$'); do
  e=$(readlink /proc/$p/exe 2>/dev/null)
  case "$e" in *MiSTer*) echo "main=$e";; esac
done
[ -p ''' + AGENT_FIFO + ''' ] && echo "agent=listening" || echo "agent=down"
true
''')
    print(out.rstrip())
    st = os.path.join(HERE, '.mister_state.json')
    if os.path.exists(st):
        print('--- deployed ---')
        for k, v in json.load(open(st)).items():
            print(f'{k}={v}')


def cmd_options(args):
    print('OSD options (from h264/emu.sv CONF_STR):')
    for label, s, e, vals in options():
        print(f'  {label:<20} bits[{e}:{s}]  {", ".join(vals)}')
    print('\nKeys (from h264/kbd_map.sv, plus osd):')
    print('  ' + ', '.join(sorted(key_names())))


def cmd_feed(args):
    rest = [a for a in (args.rest or []) if a != '--']
    rbf = '_Other/' + HIL_RBF[:-4]                  # the harness's rbf, named exactly
    cmd = f'{BIN_DIR}/h264play --rbf {rbf} ' + ' '.join(shlex.quote(a) for a in rest) + ' ' + shlex.quote(args.clip)
    if args.bg:
        ssh(f'setsid {cmd} </dev/null >/tmp/h264play.log 2>&1 &\necho started\n')
        print(f'feed: {cmd} (detached; log /tmp/h264play.log)')
        return 0
    rc, out = ssh(cmd + ' 2>&1\n', check=False, timeout=args.timeout)
    print(out.rstrip())
    return rc


def cmd_hdmi(args):
    """The HDMI output as the ADV7513 transmitter sees it (docs/history.md S47): the TMDS clock it
    measures for HDMI audio (CTS = f_pix x N / (128 fs): with Main's N, 6144 at 48 kHz or 12288 at
    96 kHz, the CTS in kHz IS the pixel clock) and the VIC it detects. The detected VIC comes from the line / pixel counts alone: it
    read 480p60 while the clock was 135 MHz (a 300 Hz signal) -- trust the clock, not the VIC."""
    rc, out = ssh('''
r() { i2cget -y 1 0x39 $1; }
n=$(( ($(r 0x01) & 0xf) << 16 | $(r 0x02) << 8 | $(r 0x03) ))
c=$(( ($(r 0x04) & 0xf) << 16 | $(r 0x05) << 8 | $(r 0x06) ))
v=$(r 0x3e); s=$(r 0x3d)
echo "$n $c $((v >> 2)) $((s & 0x3f)) $(cat /tmp/CORENAME 2>/dev/null)"
''', check=False)
    try:
        n, cts, vic, sent, core = out.split()[:5]
        n, cts = int(n), int(cts)
    except ValueError:
        print(out.rstrip())
        return 1
    fs = 96 if n == 12288 else 48                       # kHz: hdmi_audio_96k=1 sends N 12288
    mhz = cts * 128 * fs / n / 1000 if n else 0.0
    print(f'hdmi: {mhz:.3f} MHz pixel clock (N {n}, CTS {cts}); VIC detected {vic}, sent {sent}; core {core}')
    return rc


def cmd_stat(args):
    for i in range(max(1, args.count)):
        rc, out = ssh(f'{BIN_DIR}/h264stat --json\n', check=False)
        print(out.rstrip())
        if rc:
            return rc
        if i + 1 < args.count:
            time.sleep(args.watch or 1)
    return 0


def cmd_shell(args):
    # argparse.REMAINDER keeps the `--` separator; strip it or bash reports "command
    # not found" on stderr and silently eats the first command.
    rest = args.rest
    if rest and rest[0] == '--':
        rest = rest[1:]
    rc, out = ssh(' '.join(rest) + '\n', check=False)
    print(out.rstrip())
    return rc


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)

    p = sub.add_parser('deploy', help='copy a build (and/or the key daemon) to the rig')
    p.add_argument('--rbf', help='default: newest releases/*.rbf')
    p.add_argument('--agent', action='store_true',
                   help='(re)start the key daemon; alone = that and nothing else, '
                        'but an explicit --rbf is still flashed')
    p.add_argument('--bin', action='store_true',
                   help='copy the hps/ binaries (h264play, h264stat); alone = that and nothing else')
    p.add_argument('--clip', action='append', metavar='FILE', help='with --bin: a clip to copy beside them')
    p.set_defaults(fn=cmd_deploy)

    p = sub.add_parser('feed', help='play a clip on the rig through the HPS interface (h264play)')
    p.add_argument('clip', help='absolute path ON THE MISTER (local storage)')
    p.add_argument('--bg', action='store_true', help='detach (log in /tmp/h264play.log); take shots meanwhile')
    p.add_argument('--timeout', type=int, default=300)
    p.set_defaults(fn=cmd_feed, rest=[])   # h264play's options: everything after `--` (split in main)

    p = sub.add_parser('stat', help="the core's status block (h264stat --json)")
    p.add_argument('--watch', type=float, default=0)
    p.add_argument('--count', type=int, default=1)
    p.set_defaults(fn=cmd_stat)

    sub.add_parser('restore', help='remove harness files and restore saved settings') \
       .set_defaults(fn=cmd_restore)

    p = sub.add_parser('launch', help='set options, (mount an image,) load the core')
    p.add_argument('image', nargs='?', help='absolute path ON THE MISTER; only for a core with a file slot')
    p.add_argument('--opt', action='append', metavar='"Name=Value"')
    p.add_argument('--delay', type=int, default=2)
    p.add_argument('--timeout', type=int, default=60)
    p.add_argument('--no-wait', action='store_true')
    p.set_defaults(fn=cmd_launch)

    p = sub.add_parser('wait')
    p.add_argument('--timeout', type=int, default=60)
    p.add_argument('--delay', type=int, default=2)
    p.set_defaults(fn=cmd_wait)

    p = sub.add_parser('key', help='press one or more keys')
    p.add_argument('names', nargs='+')
    p.set_defaults(fn=cmd_key)

    p = sub.add_parser('shot', help='screenshot and pull it back')
    p.add_argument('-o', '--out')
    p.add_argument('--scaled', action='store_true',
                   help="the scaler's output (shows the aspect), not the raw raster")
    p.set_defaults(fn=cmd_shot)

    sub.add_parser('hdmi', help="the HDMI pixel clock the ADV7513 measures, and its detected VIC") \
       .set_defaults(fn=cmd_hdmi)

    for name, fn in (('state', cmd_state), ('options', cmd_options)):
        sub.add_parser(name).set_defaults(fn=fn)

    p = sub.add_parser('shell')
    p.add_argument('rest', nargs=argparse.REMAINDER)
    p.set_defaults(fn=cmd_shell)

    argv = sys.argv[1:]
    extra = []
    if argv and argv[0] == 'feed' and '--' in argv:       # feed: h264play's options after --
        i = argv.index('--')
        argv, extra = argv[:i], argv[i + 1:]
    args = ap.parse_args(argv)
    if extra:
        args.rest = extra
    return args.fn(args) or 0


if __name__ == '__main__':
    sys.exit(main())
