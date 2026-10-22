#!/usr/bin/env python3
"""Transcribe the CABAC tables of ITU-T H.264 from the spec PDF into tools/cabac_tables.py:
the context initialisation (m, n) of Tables 9-12 to 9-24 (ctxIdx 0..459: everything a
Main-profile decoder uses, incl. the field-coded significance ranges), rangeTabLPS
(Table 9-44) and the state transitions (Table 9-45).

CLAUDE.md: these numbers come from the spec, never from memory. `pdftotext -layout`
renders the tables faithfully except that a two-digit negative in a narrow column wraps
onto two lines ("−4" over "6" for −46, Table 9-14): the horizontal tables are read by
COLUMN POSITION and the pieces of a cell are joined top to bottom. Every table must
yield exactly its ctxIdx range or the run fails. The result is cross-checked against an
independent transcription (ffmpeg's libavcodec/h264_cabac.c, by ctxIdx) when one is at
$H264_REFS_DIR/ffmpeg/libavcodec/h264_cabac.c; tools/tests/test_cabac_ref.py repeats
both checks.

    gen_cabac_tables.py [--pdf T-REC-H.264-202606.pdf] [-o tools/cabac_tables.py] [--check]
"""
import argparse
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REFS = os.environ.get("H264_REFS_DIR", os.path.expanduser("~/h264-refs"))
PDF = os.path.join(REFS, "T-REC-H.264-202606.pdf")
FFMPEG_C = os.path.join(REFS, "ffmpeg", "libavcodec", "h264_cabac.c")
SETS = ("I", 0, 1, 2)
NUM_CTX = 460

# (table, first ctxIdx, last ctxIdx, layout, extra ctxIdx list for 9-16)
TABLES = [(12, 0, 10, "h"), (13, 11, 23, "h"), (14, 24, 39, "h"), (15, 40, 53, "h"),
          (16, 54, 59, "h"), (17, 60, 69, "h"), (18, 70, 104, "v"), (19, 105, 165, "v"),
          (20, 166, 226, "v"), (21, 227, 275, "v"), (22, 277, 337, "v"), (23, 338, 398, "v"),
          (24, 402, 459, "v")]
EXTRA_16 = [399, 400, 401]


class GenError(Exception):
    pass


def num(tok):
    tok = tok.replace("−", "-").replace("–", "-")
    if tok == "na":
        return None
    if not re.fullmatch(r"-?\d+", tok):
        raise GenError("not a number: %r" % tok)
    return int(tok)


def tokens(line):
    """(start column, token) for every whitespace-separated token."""
    return [(m.start(), m.group()) for m in re.finditer(r"\S+", line)]


def table_text(text, n):
    """The lines of Table 9-n's body (from its caption to the next caption)."""
    # a caption may start a page (form feed); the table of contents lists them first
    caps = [(m.start(), int(m.group(1))) for m in
            re.finditer(r"^[ \f]*Table 9-(\d+) – Values of variables m and n for ctxIdx", text, re.M)]
    mine = [pos for pos, k in caps if k == n]
    if not mine:
        raise GenError("Table 9-%d not found in the PDF text" % n)
    start = mine[-1]
    after = [pos for pos, _k in caps if pos > start]
    if not after:
        raise GenError("Table 9-%d: no following caption" % n)
    body = text[start:after[0]]
    # drop page footers
    return [ln for ln in body.split("\n") if "Rec. ITU-T H.264" not in ln]


def parse_horizontal(lines, ids):
    """Tables 9-12..9-17: a header line with the ctxIdx values, then rows labelled
    'm' / 'n', optionally preceded by 'I slices' / a cabac_init_idc value. Returns
    {set: {ctxIdx: (m, n)}} for the sets the table names ('all' when unlabelled)."""
    hdr = None
    rows = []          # (set_label, 'm'|'n', [(col, tok)...])
    for ln in lines:
        toks = tokens(ln)
        if not toks:
            continue
        vals = [t for _, t in toks]
        if hdr is None:
            if all(re.fullmatch(r"\d+", t) for t in vals) and [int(t) for t in vals] == ids:
                hdr = [c + len(t) / 2.0 for c, t in toks]      # column centres
            continue
        if "Table" in vals or "ctxIdx" in vals:
            break
        label = None
        body = toks
        if vals[0] == "I" and vals[1:2] == ["slices"]:
            label, body = "I", toks[2:]
        elif vals[0] in ("0", "1", "2") and vals[1:2] == ["m"]:
            label, body = int(vals[0]), toks[1:]      # only the leading label, never a data 0
        if body and body[0][1] in ("m", "n"):
            rows.append([label, body[0][1], body[1:]])
        elif rows:
            rows[-1][2].extend(body)         # a wrapped continuation of the previous row
        else:
            raise GenError("stray line before the first row: %r" % ln)
    if hdr is None:
        raise GenError("header with ctxIdx %s..%s not found" % (ids[0], ids[-1]))
    out = {}
    cur_set = "all"
    for label, which, toks in rows:
        if which == "m":
            cur_set = label if label is not None else "all"
        cells = [[] for _ in ids]
        for c, t in toks:
            centre = c + len(t) / 2.0
            k = min(range(len(ids)), key=lambda i: abs(hdr[i] - centre))
            cells[k].append(t)
        vals = [num("".join(cell)) if cell else None for cell in cells]
        if any(v is None and "".join(cell) != "na" and cell for v, cell in zip(vals, cells)):
            raise GenError("empty cell in %s row" % which)
        d = out.setdefault(cur_set, {})
        for i, v in zip(ids, vals):
            mn = list(d.get(i, (None, None)))
            mn[0 if which == "m" else 1] = v
            d[i] = tuple(mn)
    return out


def parse_vertical(lines, lo, hi):
    """Tables 9-18..9-24: two side-by-side halves, each line
    ctxIdx mI nI m0 n0 m1 n1 m2 n2 [ctxIdx mI nI m0 n0 m1 n1 m2 n2]."""
    out = {s: {} for s in SETS}
    for ln in lines:
        vals = [t for _, t in tokens(ln)]
        if not vals or not re.fullmatch(r"\d+", vals[0]) or len(vals) not in (9, 18):
            continue
        for half in range(len(vals) // 9):
            v = vals[half * 9:half * 9 + 9]
            idx = int(v[0])
            if not lo <= idx <= hi:
                raise GenError("ctxIdx %d outside %d..%d" % (idx, lo, hi))
            nums = [num(t) for t in v[1:]]
            for si, s in enumerate(SETS):
                out[s][idx] = (nums[2 * si], nums[2 * si + 1])
    return out


def parse_init(text):
    ctx = {s: [None] * NUM_CTX for s in SETS}

    def put(s, i, mn):
        if ctx[s][i] is not None and ctx[s][i] != mn:
            raise GenError("ctxIdx %d set %s given twice: %s vs %s" % (i, s, ctx[s][i], mn))
        ctx[s][i] = mn

    for tab, lo, hi, layout in TABLES:
        lines = table_text(text, tab)
        ids = list(range(lo, hi + 1)) + (EXTRA_16 if tab == 16 else [])
        if layout == "h":
            got = parse_horizontal(lines, ids)
            for s, d in got.items():
                for i, mn in d.items():
                    if mn == (None, None):
                        continue
                    if None in mn:
                        raise GenError("Table 9-%d ctxIdx %d set %s half-filled: %s" % (tab, i, s, mn))
                    for target in (SETS if s == "all" else (s,)):
                        put(target, i, mn)
        else:
            got = parse_vertical(lines, lo, hi)
            for s in SETS:
                for i, mn in got[s].items():
                    put(s, i, mn)
        for i in ids:
            if not any(ctx[s][i] is not None for s in SETS):
                raise GenError("Table 9-%d: ctxIdx %d not read" % (tab, i))
    return ctx


def parse_range_lps(text):
    i = text.index("Table 9-44 – Specification of rangeTabLPS depending on pStateIdx and qCodIRangeIdx")
    i = text.index("Table 9-44 – Specification of rangeTabLPS depending on pStateIdx and qCodIRangeIdx", i + 1) if text.count("Table 9-44 – Specification") > 1 else i
    body = text[i:text.index("Table 9-45", i)]
    tab = [None] * 64
    for ln in body.split("\n"):
        vals = [t for _, t in tokens(ln)]
        if len(vals) == 10 and all(re.fullmatch(r"\d+", t) for t in vals):
            for half in range(2):
                v = [int(t) for t in vals[half * 5:half * 5 + 5]]
                tab[v[0]] = v[1:]
    if any(r is None for r in tab):
        raise GenError("rangeTabLPS incomplete")
    return tab


def parse_trans(text):
    i = text.rindex("Table 9-45 – State transition table")
    body = text[i:i + 6000]
    lps, mps = [None] * 64, [None] * 64
    cur = None
    for ln in body.split("\n"):
        vals = [t for _, t in tokens(ln)]
        if not vals:
            continue
        if vals[0] == "pStateIdx" and len(vals) == 17:
            cur = [int(t) for t in vals[1:]]
        elif vals[0] in ("transIdxLPS", "transIdxMPS") and cur:
            dst = lps if vals[0] == "transIdxLPS" else mps
            for k, t in zip(cur, vals[1:]):
                dst[k] = int(t)
    if None in lps or None in mps:
        raise GenError("state transition table incomplete")
    return lps, mps


def ffmpeg_tables(path):
    src = open(path).read()

    def grab(name):
        i = src.index(name)
        return [(int(a), int(b)) for a, b in re.findall(r"\{\s*(-?\d+)\s*,\s*(-?\d+)\s*\}", src[i:src.index("};", i)])]
    I = grab("cabac_context_init_I[1024][2]")
    PB = grab("cabac_context_init_PB[3][1024][2]")
    if len(I) != 1024 or len(PB) != 3072:
        raise GenError("ffmpeg tables: %d / %d entries" % (len(I), len(PB)))
    return {"I": I[:NUM_CTX], 0: PB[:NUM_CTX], 1: PB[1024:1024 + NUM_CTX], 2: PB[2048:2048 + NUM_CTX]}


def cross_check(ctx, ff):
    """Every (set, ctxIdx) the spec defines must equal ffmpeg's; ffmpeg's zero entries
    are its 'unused' marker (the spec's 'na')."""
    bad = []
    for s in SETS:
        for i in range(NUM_CTX):
            mine = ctx[s][i]
            theirs = ff[s][i]
            if mine is None:
                continue
            if tuple(mine) != tuple(theirs):
                bad.append((s, i, mine, theirs))
    return bad


def emit(ctx, rlps, lps, mps, out):
    w = []
    w.append('"""CABAC tables of ITU-T H.264 (06/2026), transcribed from the spec PDF by')
    w.append("tools/gen_cabac_tables.py and cross-checked against ffmpeg's h264_cabac.c -- never")
    w.append("edited by hand. CTX_INIT[set][ctxIdx] = (m, n) with set in ('I', 0, 1, 2); None where")
    w.append("the spec says 'na' (initialised as (0, 0) by the model and the fabric alike).")
    w.append("ctxIdx 0..459 = the Main-profile contexts (Table 9-11), the field")
    w.append("significance ranges 277..398 included; 399..401 are the 8x8-transform flag (refused).")
    w.append('"""')
    w.append("")
    w.append("NUM_CTX = %d" % NUM_CTX)
    w.append("")
    w.append("CTX_INIT = {")
    for s in SETS:
        w.append("    %r: [" % s)
        row = []
        for i in range(NUM_CTX):
            v = ctx[s][i]
            row.append("None" if v is None else "(%d, %d)" % v)
            if len(row) == 8:
                w.append("        " + ", ".join(row) + ",")
                row = []
        if row:
            w.append("        " + ", ".join(row) + ",")
        w.append("    ],")
    w.append("}")
    w.append("")
    w.append("# Table 9-44: rangeTabLPS[pStateIdx][qCodIRangeIdx]")
    w.append("RANGE_LPS = [")
    for r in rlps:
        w.append("    %s," % list(r))
    w.append("]")
    w.append("")
    w.append("# Table 9-45")
    w.append("TRANS_IDX_LPS = %r" % lps)
    w.append("TRANS_IDX_MPS = %r" % mps)
    w.append("")
    open(out, "w").write("\n".join(w))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--pdf", default=PDF)
    ap.add_argument("--ffmpeg", default=FFMPEG_C)
    ap.add_argument("-o", "--out", default=os.path.join(HERE, "cabac_tables.py"))
    ap.add_argument("--check", action="store_true", help="compare with the existing module, write nothing")
    a = ap.parse_args(argv)
    if not os.path.exists(a.pdf):
        sys.exit("gen_cabac_tables: no spec PDF at %s (H264_REFS_DIR)" % a.pdf)
    text = subprocess.run(["pdftotext", "-layout", a.pdf, "-"], check=True,
                          stdout=subprocess.PIPE, universal_newlines=True).stdout
    ctx = parse_init(text)
    rlps = parse_range_lps(text)
    lps, mps = parse_trans(text)
    n = sum(1 for s in SETS for v in ctx[s] if v is not None)
    print("spec: %d (set, ctxIdx) pairs, rangeTabLPS 64x4, transitions 64" % n)
    if os.path.exists(a.ffmpeg):
        bad = cross_check(ctx, ffmpeg_tables(a.ffmpeg))
        for b in bad[:10]:
            print("  MISMATCH set %s ctxIdx %d: spec %s ffmpeg %s" % b)
        if bad:
            sys.exit("gen_cabac_tables: %d mismatches against ffmpeg" % len(bad))
        print("ffmpeg cross-check: every value agrees")
    else:
        print("ffmpeg cross-check SKIPPED (no %s)" % a.ffmpeg)
    if a.check:
        sys.path.insert(0, HERE)
        import cabac_tables as T
        same = (all(T.CTX_INIT[s] == ctx[s] for s in SETS) and T.RANGE_LPS == [list(r) for r in rlps]
                and T.TRANS_IDX_LPS == lps and T.TRANS_IDX_MPS == mps)
        print("cabac_tables.py %s the PDF" % ("matches" if same else "DIFFERS FROM"))
        return 0 if same else 1
    emit(ctx, rlps, lps, mps, a.out)
    print("wrote %s" % a.out)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except GenError as e:
        sys.exit("gen_cabac_tables: %s" % e)
