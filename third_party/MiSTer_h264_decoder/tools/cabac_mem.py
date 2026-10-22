#!/usr/bin/env python3
"""Render tools/cabac_tables.py (the spec's CABAC tables, transcribed from the PDF and
cross-checked) into the $readmemh files the fabric loads:

  h264/dec/cabac_init.mem   1840 x 16 bits: {m[7:0], n[7:0]} two's complement, address
                            set * 460 + ctxIdx with set 0..2 = cabac_init_idc, 3 = I slices;
                            0000 where the spec says "na" (both the model and the RTL then
                            initialise them as (0, 0) does: pStateIdx 62, valMPS 0)
  h264/dec/cabac_rlpsrow.mem   64 x 32 bits: pStateIdx's row of rangeTabLPS, bits 8q+7..8q
                               = rangeTabLPS[pStateIdx][q] (q = qCodIRangeIdx); cabac_ctx
                               stores it beside each context's state at initialisation
  h264/dec/cabac_rlpsnext.mem  64 x 64 bits: {row(transIdxLPS[p]), row(transIdxMPS[p])}, the
                               rows the engine writes back with the next state
  h264/dec/cabac_trans.mem     64 x 12 bits: {transIdxLPS[5:0], transIdxMPS[5:0]}

Generated, never edited: `cabac_mem.py --check` (the tests) proves the files equal the
tables. Set order matches cabac_engine.sv's req_ctx encoding for an init request.
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import cabac_tables as T  # noqa: E402

OUT_DIR = os.path.join(os.path.dirname(HERE), "h264", "dec")
SETS = (0, 1, 2, "I")


def render():
    init = []
    for s in SETS:
        for i in range(T.NUM_CTX):
            mn = T.CTX_INIT[s][i]
            if mn is None:
                init.append("0000")
            else:
                m, n = mn
                init.append("%02x%02x" % (m & 0xFF, n & 0xFF))
    def row(p):
        return sum(v << (8 * q) for q, v in enumerate(T.RANGE_LPS[p]))
    rlpsrow = ["%08x" % row(p) for p in range(64)]
    rlpsnext = ["%08x%08x" % (row(T.TRANS_IDX_LPS[p]), row(T.TRANS_IDX_MPS[p])) for p in range(64)]
    trans = ["%03x" % ((T.TRANS_IDX_LPS[i] << 6) | T.TRANS_IDX_MPS[i]) for i in range(64)]
    return {"cabac_init.mem": init, "cabac_rlpsrow.mem": rlpsrow, "cabac_rlpsnext.mem": rlpsnext,
            "cabac_trans.mem": trans}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out-dir", default=OUT_DIR)
    ap.add_argument("--check", action="store_true", help="compare with the files on disk, write nothing")
    a = ap.parse_args(argv)
    files = render()
    bad = 0
    for name, lines in files.items():
        path = os.path.join(a.out_dir, name)
        text = "\n".join(lines) + "\n"
        if a.check:
            same = os.path.exists(path) and open(path).read() == text
            print("%s: %s" % (path, "matches cabac_tables.py" if same else "DIFFERS / missing"))
            bad += 0 if same else 1
        else:
            os.makedirs(a.out_dir, exist_ok=True)
            open(path, "w").write(text)
            print("wrote %s (%d words)" % (path, len(lines)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
