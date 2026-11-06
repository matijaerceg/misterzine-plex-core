#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 - "$@" <<'PY'
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import subprocess
import sys

if sys.argv[1:] not in ([], ['--red']):
    raise SystemExit('usage: run_video_calc_dv.sh [--red]')
root = Path.cwd()
scratch = root / '.sim' / 'video_calc_dv'
scratch.mkdir(parents=True, exist_ok=True)
source = (root / 'sys/hps_io.sv').read_text()

def compile_run(name, rtl, modes, failure=None):
    path = scratch / name
    path.mkdir(exist_ok=True)
    (path / 'hps_io.sv').write_text(rtl)
    binary = path / 'sim'
    binary.unlink(missing_ok=True)
    compile_result = subprocess.run(['iverilog', '-g2012', '-I' + str(root), '-s', 'video_calc_dv_tb',
                    '-o', str(binary), str(path / 'hps_io.sv'),
                    str(root / 'h264/sync_gen.sv'),
                    str(root / 'bench/h264/video_calc_dv_tb.sv')], cwd=path, text=True, capture_output=True)
    (path / 'compile.log').write_text(compile_result.stdout + compile_result.stderr)
    if compile_result.returncode:
        raise SystemExit(compile_result.stdout + compile_result.stderr)
    def run_mode(mode):
        run = subprocess.run(['vvp', '-n', str(binary), f'+mode={mode}'],
                             cwd=path, text=True, capture_output=True)
        (path / f'mode{mode}.log').write_text(run.stdout + run.stderr)
        if failure:
            if run.returncode == 0 or failure not in run.stdout:
                raise SystemExit(f'FAIL: {name} mode={mode} did not fail at {failure}\n{run.stdout}{run.stderr}')
            print(f'RED: {name} mode={mode} caught at {failure}', flush=True)
        elif run.returncode or 'PASS: video_calc_dv_tb' not in run.stdout:
            raise SystemExit(f'FAIL: {name} mode={mode}\n{run.stdout}{run.stderr}')
        else:
            print(run.stdout.strip(), flush=True)
    with ThreadPoolExecutor(max_workers=3) as pool:
        list(pool.map(run_mode, modes))

compile_run('green', source, range(6))
if '--red' in sys.argv:
    mutations = [
        ('old_crop', "17: dout <= direct_video ? (vid_de_h_sys / 16'd3) : vid_de_h;",
         '17: dout <= vid_de_h;', '[dv-crop]'),
        ('all_crop', "direct_video ? (vid_de_h_sys / 16'd3) : vid_de_h",
         "(vid_de_h_sys / 16'd3)", '[ordinary-crop]'),
        ('old_repetition', "direct_video ? (vid_pixrep_sys / 8'd3) : vid_pixrep",
         'vid_pixrep', '[dv-repetition]'),
    ]
    for name, before, after, failure in mutations:
        if source.count(before) != 1:
            raise SystemExit(f'FAIL: {name} mutation anchor is not unique')
        compile_run(name, source.replace(before, after), [0], failure)
print('== ALL GREEN ==')
PY
