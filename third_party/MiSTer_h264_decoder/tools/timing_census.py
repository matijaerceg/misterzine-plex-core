#!/usr/bin/env python3
"""timing_census.py -- per-module census of the clk_dec endpoints under a slack.

Reads output_files/clk_dec_paths.txt as written by
    TIMING_TEMP=-40 TIMING_BELOW=<slack> USE_DOCKER=1 tools/timing_paths.sh 100000
(one path per ENDPOINT, the worst, every endpoint below the slack) and prints, per
destination module: how many endpoints fail, the worst slack, and that worst path's
from -> to (data delay). The count is what a clock target needs retimed; the top-N
path list a plain report gives is filled by one or two clusters and hides the rest.

The slack for a gate G MHz at a constraint of P ns is P - 1000 / G (at 96.43 MHz and a
101.4 gate: 10.370 - 9.862 = 0.508; at 103.85 and 108.8: 0.439). Run it at BOTH slow
corners (TIMING_TEMP=100 and -40): after the P5b clock move the hot corner bound where the cold one had.
docs/hw_budget_and_lessons.md S5 "Retiming for a faster clock".
"""
import re
import sys
from collections import defaultdict


def module(node):
    inst = [p for p in node.split('|')[:-1] if ':' in p]
    return inst[-1].split(':')[0] if inst else node.split('|')[0]


def short(node):
    return re.sub(r'emu:emu\|(recon_top:recon_top_inst\||h264_top:h264_top_inst\|)?', '', node)


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else 'output_files/clk_dec_paths.txt'
    rows = []
    for line in open(path):
        f = [x.strip() for x in line.split(';')]
        # the summary table: slack; from; to; launch; latch; relationship; skew; data delay
        if len(f) > 8 and re.fullmatch(r'-?\d+\.\d+', f[1] or '') and f[2] and f[3] \
                and f[3] not in ('RR', 'FF', 'RF', 'FR'):
            rows.append((float(f[1]), f[2], f[3], f[8]))
    cnt = defaultdict(int)
    worst = {}
    for s, fr, to, d in rows:
        k = module(to)
        cnt[k] += 1
        if k not in worst or s < worst[k][0]:
            worst[k] = (s, fr, to, d)
    print(f"{len(rows)} endpoints")
    for k in sorted(cnt, key=lambda k: -cnt[k]):
        s, fr, to, d = worst[k]
        print(f"{cnt[k]:5d} {s:6.3f} {k:18s} {short(fr)[-60:]} -> {short(to)[-50:]} ({d})")


if __name__ == '__main__':
    main()
