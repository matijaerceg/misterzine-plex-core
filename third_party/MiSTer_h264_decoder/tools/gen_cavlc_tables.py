#!/usr/bin/env python3
"""Transcribe the CAVLC tables of ITU-T H.264 from the spec PDF into tools/cavlc_tables.py:
coeff_token (Table 9-5), total_zeros (Tables 9-7, 9-8, 9-9), run_before (Table 9-10) and
the me(v) mapping of coded_block_pattern (Table 9-4). The CAVLC -> CABAC rewriter of fj#20
(hps/lib/h264ring_cavlc.c, docs/cavlc.md) parses with them; its C header is generated
from this module by tools/gen_hps_tables.py.

CLAUDE.md: these numbers come from the spec, never from memory. `pdftotext -layout`
renders each row as cells separated by two or more spaces (a codeword's own groups of four
are separated by one); a row of Table 9-10 may omit a leading "-" cell, so its cells are
aligned to the right (only "-" cells can be missing, and they are on the left). Every
table must yield exactly its rows or the run fails. The result is cross-checked against
an independent transcription (ffmpeg's libavcodec/h264_cavlc.c and h264data.c) when one
is at $H264_REFS_DIR/ffmpeg-9.0.1/libavcodec/.

    gen_cavlc_tables.py [--pdf T-REC-H.264-202606.pdf] [-o tools/cavlc_tables.py] [--check]
"""
import argparse
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REFS = os.environ.get("H264_REFS_DIR", os.path.expanduser("~/h264-refs"))
PDF = os.path.join(REFS, "T-REC-H.264-202606.pdf")
FFMPEG_DIR = os.path.join(REFS, "ffmpeg-9.0.1", "libavcodec")


class GenError(Exception):
    pass


def cells(line):
    return [c.replace(" ", "") for c in re.split(r"\s{2,}", line.strip()) if c]


def is_code(c):
    return c == "-" or re.fullmatch(r"[01]+", c) is not None


def section(text, start_pat, end_pat):
    """The lines from the LAST match of start_pat (the table of contents lists each caption
    first) to the next match of end_pat, page footers dropped."""
    starts = [m.start() for m in re.finditer(start_pat, text, re.M)]
    if not starts:
        raise GenError("caption not found: %s" % start_pat)
    s = starts[-1]
    m = re.compile(end_pat, re.M).search(text, s + 1)
    if not m:
        raise GenError("no end after: %s" % start_pat)
    return [ln for ln in text[s:m.start()].split("\n") if "Rec. ITU-T H.264" not in ln]


def code_rows(lines, n_label, n_cols, right_align=False):
    """Rows whose first n_label cells are integers and whose remaining cells are codewords
    or "-"; returns [(labels, codes)]."""
    out = []
    for ln in lines:
        c = cells(ln)
        if len(c) < n_label + 1 or not all(re.fullmatch(r"\d+", x) for x in c[:n_label]):
            continue
        rest = c[n_label:]
        if not all(is_code(x) for x in rest):
            continue
        if len(rest) != n_cols:
            if right_align and len(rest) < n_cols:
                rest = ["-"] * (n_cols - len(rest)) + rest
            else:
                raise GenError("row %r: %d code cells, expected %d" % (ln.strip(), len(rest), n_cols))
        out.append(([int(x) for x in c[:n_label]], [None if x == "-" else x for x in rest]))
    return out


def parse_coeff_token(text):
    """Table 9-5 (three pages): COEFF_TOKEN[col] = {(TrailingOnes, TotalCoeff): code}, col 0..5
    = 0<=nC<2, 2<=nC<4, 4<=nC<8, 8<=nC, nC==-1, nC==-2."""
    lines = []
    for m in re.finditer(r"^\s*Table 9-5 – coeff_token mapping", text, re.M):
        if m.start() < len(text) // 20:              # the table of contents
            continue
        end = re.compile(r"^(\s*Table 9-5 – |9\.2\.2 )", re.M).search(text, m.end())
        lines += text[m.end():end.start()].split("\n")
    rows = code_rows(lines, 2, 6)
    tab = [dict() for _ in range(6)]
    for (t1, tc), codes in rows:
        for col, code in enumerate(codes):
            if code is not None:
                if (t1, tc) in tab[col]:
                    raise GenError("Table 9-5: (%d, %d) twice" % (t1, tc))
                tab[col][(t1, tc)] = code
    # every (TrailingOnes, TotalCoeff) with TrailingOnes <= min(3, TotalCoeff), TotalCoeff <= 16
    want = [(t1, tc) for tc in range(17) for t1 in range(min(3, tc) + 1)]
    if len(rows) != len(want):
        raise GenError("Table 9-5: %d rows, expected %d" % (len(rows), len(want)))
    for col, maxtc in enumerate((16, 16, 16, 16, 4, 8)):
        exp = {k for k in want if k[1] <= maxtc}
        if set(tab[col]) != exp:
            raise GenError("Table 9-5 column %d: %d entries, expected %d" % (col, len(tab[col]), len(exp)))
    return tab


def parse_total_zeros(text):
    """Tables 9-7 / 9-8: TOTAL_ZEROS[tzVlcIndex][total_zeros] = code (None when n/a),
    tzVlcIndex 1..15; Table 9-9 (a): TOTAL_ZEROS_CDC[tzVlcIndex 1..3][total_zeros]."""
    tz = {}
    a = code_rows(section(text, r"^\s*Table 9-7 – total_zeros tables", r"^\s*Table 9-8 – "), 1, 7)
    b = code_rows(section(text, r"^\s*Table 9-8 – total_zeros tables", r"^\s*Table 9-9 – "), 1, 8)
    if [r[0][0] for r in a] != list(range(16)) or [r[0][0] for r in b] != list(range(9)):
        raise GenError("Tables 9-7 / 9-8: rows %s / %s" % ([r[0][0] for r in a], [r[0][0] for r in b]))
    for k in range(1, 16):
        rows, col = (a, k - 1) if k <= 7 else (b, k - 8)
        tz[k] = [r[1][col] for r in rows]
        # total_zeros 0 .. 16 - tzVlcIndex are coded, nothing past
        tz[k] = (tz[k] + [None] * 16)[:17 - k]
        if any(c is None for c in tz[k]):
            raise GenError("total_zeros tzVlcIndex %d: a hole" % k)
    lines = section(text, r"^\s*Table 9-9 – total_zeros tables for chroma DC", r"^\s*\(b\) Chroma DC 2x4")
    c = code_rows(lines, 1, 3)
    if [r[0][0] for r in c] != [0, 1, 2, 3]:
        raise GenError("Table 9-9 (a): rows %s" % [r[0][0] for r in c])
    cdc = {k: [r[1][k - 1] for r in c][:5 - k] for k in range(1, 4)}
    return tz, cdc


def parse_run_before(text):
    """Table 9-10: RUN_BEFORE[zerosLeft 1..7 (7 = '>6')][run_before] = code."""
    rows = code_rows(section(text, r"^\s*Table 9-10 – Tables for run_before", r"^\s*9\.2\.4 "), 1, 7,
                     right_align=True)
    if [r[0][0] for r in rows] != list(range(15)):
        raise GenError("Table 9-10: rows %s" % [r[0][0] for r in rows])
    rb = {}
    for zl in range(1, 8):
        col = [r[1][zl - 1] for r in rows]
        n = zl + 1 if zl < 7 else 15
        if any(c is None for c in col[:n]) or any(c is not None for c in col[n:]):
            raise GenError("Table 9-10 zerosLeft %d: %s" % (zl, col))
        rb[zl] = col[:n]
    return rb


def parse_cbp(text):
    """Table 9-4 (a) (ChromaArrayType 1 or 2): CBP_INTRA[codeNum], CBP_INTER[codeNum]."""
    lines = section(text, r"^[\f ]*Table 9-4 – Assignment of codeNum", r"^\s*\(b\) ChromaArrayType is equal to 0 or 3")
    intra, inter = {}, {}
    for ln in lines:
        c = cells(ln)
        if len(c) == 3 and all(re.fullmatch(r"\d+", x) for x in c):
            k, a, b = (int(x) for x in c)
            if k in intra:
                raise GenError("Table 9-4: codeNum %d twice" % k)
            intra[k], inter[k] = a, b
    if sorted(intra) != list(range(48)):
        raise GenError("Table 9-4 (a): codeNums %s" % sorted(intra))
    ci = [intra[k] for k in range(48)]
    cp = [inter[k] for k in range(48)]
    if sorted(ci) != list(range(48)) or sorted(cp) != list(range(48)):
        raise GenError("Table 9-4 (a): not a permutation of 0..47")
    return ci, cp


# ---------------------------------------------------------------- ffmpeg cross-check

def c_array(src, name):
    m = re.search(r"\b%s\s*(\[[^=]*)=\s*\{(.*?)\};" % re.escape(name), src, re.S)
    if not m:
        raise GenError("ffmpeg: %s not found" % name)
    body = re.sub(r"//[^\n]*|/\*.*?\*/", "", m.group(2), flags=re.S)
    return [int(x) for x in re.findall(r"-?\d+", body)]


def c_rows(src, name):
    """A two-dimensional array as its rows (ffmpeg's rows may be ragged)."""
    m = re.search(r"\b%s\s*\[[^=]*=\s*\{(.*?)\}\s*;" % re.escape(name), src, re.S)
    if not m:
        raise GenError("ffmpeg: %s not found" % name)
    body = re.sub(r"//[^\n]*|/\*.*?\*/", "", m.group(1), flags=re.S)
    return [[int(x) for x in re.findall(r"-?\d+", r)] for r in re.findall(r"\{([^{}]*)\}", body)]


def bits(code):
    return len(code), int(code, 2)


def cross_check(ct, tz, cdc, rb, ci, cp, ffdir):
    src = open(os.path.join(ffdir, "h264_cavlc.c")).read()
    data = open(os.path.join(ffdir, "h264data.c")).read()
    bad = []

    def eq(what, mine, theirs):
        if mine != theirs:
            bad.append((what, mine, theirs))
    ln, bt = c_rows(src, "coeff_token_len"), c_rows(src, "coeff_token_bits")
    for col in range(4):
        for (t1, tc), code in ct[col].items():
            i = tc * 4 + t1
            eq("coeff_token col %d (%d,%d)" % (col, t1, tc), bits(code), (ln[col][i], bt[col][i]))
    ln, bt = c_array(src, "chroma_dc_coeff_token_len"), c_array(src, "chroma_dc_coeff_token_bits")
    for (t1, tc), code in ct[4].items():
        eq("chroma dc coeff_token (%d,%d)" % (t1, tc), bits(code), (ln[tc * 4 + t1], bt[tc * 4 + t1]))
    ln, bt = c_array(src, "chroma422_dc_coeff_token_len"), c_array(src, "chroma422_dc_coeff_token_bits")
    for (t1, tc), code in ct[5].items():
        eq("chroma422 dc coeff_token (%d,%d)" % (t1, tc), bits(code), (ln[tc * 4 + t1], bt[tc * 4 + t1]))
    def rows_eq(what, table, lname, bname):
        ln, bt = c_rows(src, lname), c_rows(src, bname)
        for k, codes in table.items():
            theirs = list(zip(ln[k - 1], bt[k - 1]))[:len(codes)]
            eq("%s %d" % (what, k), [bits(c) for c in codes], theirs)
    rows_eq("total_zeros", tz, "total_zeros_len", "total_zeros_bits")
    rows_eq("chroma dc total_zeros", cdc, "chroma_dc_total_zeros_len", "chroma_dc_total_zeros_bits")
    rows_eq("run_before", rb, "run_len", "run_bits")
    eq("cbp intra", ci, c_array(data, "ff_h264_golomb_to_intra4x4_cbp"))
    eq("cbp inter", cp, c_array(data, "ff_h264_golomb_to_inter_cbp"))
    return bad


def emit(ct, tz, cdc, rb, ci, cp, out):
    w = ['"""GENERATED by tools/gen_cavlc_tables.py from T-REC-H.264-202606.pdf and cross-checked',
         "against ffmpeg's libavcodec (h264_cavlc.c, h264data.c) -- never edit by hand. The CAVLC",
         'tables the CAVLC -> CABAC rewriter parses with (fj#20, docs/cavlc.md). Codewords as bit strings."""',
         "",
         "# Table 9-5: COEFF_TOKEN[col][(TrailingOnes, TotalCoeff)] = codeword; col 0..5 =",
         "# 0 <= nC < 2, 2 <= nC < 4, 4 <= nC < 8, 8 <= nC, nC == -1, nC == -2",
         "COEFF_TOKEN = ["]
    for col in range(6):
        w.append("    {")
        for k in sorted(ct[col], key=lambda k: (k[1], k[0])):
            w.append("        %r: %r," % (k, ct[col][k]))
        w.append("    },")
    w.append("]")
    w.append("")
    w.append("# Tables 9-7 / 9-8: TOTAL_ZEROS[tzVlcIndex][total_zeros], tzVlcIndex 1..15 (4x4 blocks)")
    w.append("TOTAL_ZEROS = {")
    for k in range(1, 16):
        w.append("    %d: %r," % (k, tz[k]))
    w.append("}")
    w.append("")
    w.append("# Table 9-9 (a): chroma DC 2x2 (4:2:0), tzVlcIndex 1..3")
    w.append("TOTAL_ZEROS_CDC = {")
    for k in range(1, 4):
        w.append("    %d: %r," % (k, cdc[k]))
    w.append("}")
    w.append("")
    w.append("# Table 9-10: RUN_BEFORE[zerosLeft][run_before], zerosLeft 1..6 and 7 for '> 6'")
    w.append("RUN_BEFORE = {")
    for zl in range(1, 8):
        w.append("    %d: %r," % (zl, rb[zl]))
    w.append("}")
    w.append("")
    w.append("# Table 9-4 (a), ChromaArrayType 1 or 2: coded_block_pattern by codeNum")
    w.append("CBP_INTRA = %r" % ci)
    w.append("CBP_INTER = %r" % cp)
    w.append("")
    open(out, "w").write("\n".join(w))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--pdf", default=PDF)
    ap.add_argument("--ffmpeg", default=FFMPEG_DIR, help="an ffmpeg libavcodec directory")
    ap.add_argument("-o", "--out", default=os.path.join(HERE, "cavlc_tables.py"))
    ap.add_argument("--check", action="store_true", help="compare with the existing module, write nothing")
    a = ap.parse_args(argv)
    if not os.path.exists(a.pdf):
        sys.exit("gen_cavlc_tables: no spec PDF at %s (H264_REFS_DIR)" % a.pdf)
    text = subprocess.run(["pdftotext", "-layout", a.pdf, "-"], check=True,
                          stdout=subprocess.PIPE, universal_newlines=True).stdout
    ct = parse_coeff_token(text)
    tz, cdc = parse_total_zeros(text)
    rb = parse_run_before(text)
    ci, cp = parse_cbp(text)
    print("spec: coeff_token %s, total_zeros 15 + 3, run_before 7, cbp 48 x 2"
          % "/".join(str(len(c)) for c in ct))
    if os.path.exists(os.path.join(a.ffmpeg, "h264_cavlc.c")):
        bad = cross_check(ct, tz, cdc, rb, ci, cp, a.ffmpeg)
        for b in bad[:10]:
            print("  MISMATCH %s: spec %s ffmpeg %s" % b)
        if bad:
            sys.exit("gen_cavlc_tables: %d mismatches against ffmpeg" % len(bad))
        print("ffmpeg cross-check: every value agrees")
    else:
        print("ffmpeg cross-check SKIPPED (no %s)" % a.ffmpeg)
    if a.check:
        sys.path.insert(0, HERE)
        import cavlc_tables as T
        same = (T.COEFF_TOKEN == ct and T.TOTAL_ZEROS == tz and T.TOTAL_ZEROS_CDC == cdc
                and T.RUN_BEFORE == rb and T.CBP_INTRA == ci and T.CBP_INTER == cp)
        print("cavlc_tables.py %s the PDF" % ("matches" if same else "DIFFERS FROM"))
        return 0 if same else 1
    emit(ct, tz, cdc, rb, ci, cp, a.out)
    print("wrote %s" % a.out)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except GenError as e:
        sys.exit("gen_cavlc_tables: %s" % e)
