#!/usr/bin/env python3
"""Fixtures for bench/h264/aspect_vui_tb.sv (h264/aspect_vui.sv, roadmap P5b).

Table E-1 is read out of the spec PDF itself ($H264_REFS_DIR/T-REC-H.264-202606.pdf via
pdftotext), not typed: the RTL's case table is a transcription, this is the source. The
rounding rule (the nearer of 4:3 and 16:9) is checked against the table's own informative
"Examples of use" column, each of which names its display aspect: every example whose
coded size fits the module's 8-bit macroblock counts must round to its own label.

Cases, one per line of bench/h264/fixtures/gen/aspect_vui.hex:
    {sar_w_o[15:0], sar_h_o[15:0], cat[1:0], valid, idc[7:0], ext_w[15:0], ext_h[15:0], w_mbs[7:0],
     hf_mbs[7:0], known, wide}   (96 bits; sar_*_o the resolved SAR, 1:1 when not known -- P6)
  cat (the bench's arm): 0 [table] the idc sweep, 1 [round] the spec examples, 2 [ext]
  Extended_SAR, 3 [valid] nothing shown
  * every Table E-1 example that fits, at its coded size (1080 lines -> 68 MBs)
  * Extended_SAR: zero terms (unspecified), extremes (65535:1, 1:65535), random pairs
  * every idc 0..254 at 45x30 MBs (720x480), and each Table E-1 entry at the two sizes
    straddling its decision boundary
  * valid = 0 (nothing shown -> unknown)
Without the spec PDF the table falls back to the transcription below and says so.

    aspect_vui_golden.py     -> bench/h264/fixtures/gen/aspect_vui.hex
"""
import os
import random
import re
import shutil
import subprocess
from fractions import Fraction

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "bench", "h264", "fixtures", "gen")
REFS = os.environ.get("H264_REFS_DIR", os.path.expanduser("~/h264-refs"))
PDF = os.path.join(REFS, "T-REC-H.264-202606.pdf")


def table_from_spec():
    """{idc: (sar_w, sar_h)} and [(idc, W, H, 'a:b')] examples, from the PDF's Table E-1."""
    if not (os.path.exists(PDF) and shutil.which("pdftotext")):
        return None, None
    txt = subprocess.run(["pdftotext", "-layout", PDF, "-"], stdout=subprocess.PIPE,
                         universal_newlines=True, check=True).stdout.split("\n")
    starts = [i for i, l in enumerate(txt) if "Table E-1 – Meaning of sample aspect ratio indicator" in l]
    i = starts[-1]                     # the table itself (the first hit is the contents list)
    table, examples, cur = {}, [], None
    for l in txt[i + 1:i + 60]:
        if "Extended_SAR" in l:
            break
        m = re.match(r"^\s+(\d+)\s+(\d+):(\d+)\s*(.*)$", l)
        if m:
            cur = int(m.group(1))
            table[cur] = (int(m.group(2)), int(m.group(3)))
            rest = m.group(4)
        else:
            rest = l
        e = re.search(r"(\d+)x(\d+) (\d+):(\d+) frame", rest)
        if e and cur is not None:
            examples.append((cur, int(e.group(1)), int(e.group(2)), "%s:%s" % (e.group(3), e.group(4))))
    return table, examples


TRANSCRIBED = {1: (1, 1), 2: (12, 11), 3: (10, 11), 4: (16, 11), 5: (40, 33), 6: (24, 11), 7: (20, 11),
               8: (32, 11), 9: (80, 33), 10: (18, 11), 11: (15, 11), 12: (64, 33), 13: (160, 99),
               14: (4, 3), 15: (3, 2), 16: (2, 1)}


def sar(idc, ew, eh, table):
    if idc == 255:
        return (ew, eh) if ew and eh else (0, 0)
    return table.get(idc, (0, 0))


def expect(valid, idc, ew, eh, w, h, table):
    sw, sh = sar(idc, ew, eh, table)
    known = int(valid and sw != 0 and sh != 0)
    wide = int(9 * sw * w > 14 * sh * h)
    return known, wide


def main():
    table, examples = table_from_spec()
    src = "the spec PDF"
    if table is None:
        table, examples, src = TRANSCRIBED, [], "the TRANSCRIPTION (no spec PDF: not an oracle)"
    assert sorted(table) == list(range(1, 17)), "Table E-1 parse: %s" % sorted(table)
    assert table == TRANSCRIBED or src.startswith("the TRANS"), "the PDF disagrees with the transcription"
    cases = []
    n_ex = 0
    for idc, W, H, label in examples:
        wm, hm = -(-W // 16), -(-H // 16)          # coded size: 1080 lines are 68 MBs
        if wm > 255 or hm > 255:
            continue
        sw, sh = table[idc]
        dar = Fraction(sw * W, sh * H)
        want_wide = int(label == "16:9")
        # the rule's own check against the spec's label (on the visible size W x H)
        assert int(abs(dar - Fraction(16, 9)) < abs(dar - Fraction(4, 3))) == want_wide, (idc, W, H, label, float(dar))
        cases.append((1, 1, idc, 0, 0, wm, hm))
        n_ex += 1
    # [round] the rule's own threshold, square pixels: exactly 14:9 is the midpoint and
    # rounds to 4:3 (strict >), one macroblock wider is 16:9; 3:2 (720x480 square) is 4:3
    for w, h in ((14, 9), (15, 9), (28, 18), (29, 18), (126, 81), (127, 81), (45, 30), (3, 2)):
        cases.append((1, 1, 1, 0, 0, w, h))
    for ew, eh in ((0, 0), (0, 5), (5, 0), (65535, 1), (1, 65535), (65535, 65535), (4, 3), (16, 9)):
        cases.append((2, 1, 255, ew, eh, 45, 30))
        cases.append((2, 1, 255, ew, eh, 255, 255))
        cases.append((2, 1, 255, ew, eh, 1, 1))
    rng = random.Random(5)
    for _ in range(400):
        cases.append((2, 1, 255, rng.randint(0, 65535), rng.randint(0, 65535), rng.randint(1, 255), rng.randint(1, 255)))
    # [table] last (a threshold or Extended_SAR defect is the other arms'): every idc but
    # 255 at 720x480, and for each Table E-1 entry the two sizes that straddle its
    # decision boundary most tightly (9 sw W - 14 sh H: the smallest > 0 and the
    # largest <= 0), so that any change of either term flips one of them
    for idc in range(255):
        cases.append((0, 1, idc, 40, 33, 45, 30))
    for idc, (sw, sh) in sorted(table.items()):
        best_pos = best_neg = None
        for w in range(1, 256):
            for h in range(1, 256):
                d = 9 * sw * w - 14 * sh * h
                if d > 0 and (best_pos is None or d < best_pos[0]):
                    best_pos = (d, w, h)
                if d <= 0 and (best_neg is None or d > best_neg[0]):
                    best_neg = (d, w, h)
        for _d, w, h in (best_pos, best_neg):
            cases.append((0, 1, idc, 0, 0, w, h))
    for idc in (0, 5, 255):
        cases.append((3, 0, idc, 40, 33, 45, 30))
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "aspect_vui.hex"), "w") as f:
        for cat, v, idc, ew, eh, w, h in cases:
            k, wd = expect(v, idc, ew, eh, w, h, table)
            word = (cat << 59) | (v << 58) | (idc << 50) | (ew << 34) | (eh << 18) | (w << 10) | (h << 2) | (k << 1) | wd
            rw, rh = sar(idc, ew, eh, table) if k else (1, 1)
            word |= (rw << 80) | (rh << 64)
            f.write("%024x\n" % word)
    print("aspect_vui_golden: %d cases (Table E-1 from %s; %d spec examples round to their own label)"
          % (len(cases), src, n_ex))
    return len(cases)


if __name__ == "__main__":
    main()
