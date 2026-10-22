#!/usr/bin/env python3
"""timing_chain.py -- condense full-detail timing paths to their cell chains.

Reads a report_timing -detail full_path file (output_files/clk_dec_detail.txt from
TIMING_PAIRS=... tools/timing_paths.sh, or clk_dec_paths.txt's three detailed paths) and
prints, per path, the data path's cells: arrival time (ns), fanout, element. The clock
tree is dropped. Read it for WHAT the cells are (LessThan / Add / Mux / Selector / a
RAM's PORT_B / a DSP's resulta) and WHERE the fanout jumps: those name the retime
(docs/hw_budget_and_lessons.md S5 "Retiming for a faster clock").
"""
import re
import sys


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else 'output_files/clk_dec_detail.txt'
    inside = False
    in_data = False
    for line in open(path):
        if 'Data Arrival Path' in line:
            inside, in_data = True, False
            print('----')
            continue
        if 'Data Required Path' in line:
            inside = False
            continue
        if not inside:
            continue
        f = [x.strip() for x in line.split(';')]
        if len(f) < 8:
            continue
        if f[7] == 'data path':
            in_data = True
            continue
        if in_data and f[4] == 'CELL':
            el = re.sub(r'emu(:emu)?\|(recon_top(:recon_top_inst)?\||h264_top(:h264_top_inst)?\||recon_top_inst\||h264_top_inst\|)?', '', f[7])
            print(f"{f[1]:>8} {f[5]:>6}  {el}")


if __name__ == '__main__':
    main()
