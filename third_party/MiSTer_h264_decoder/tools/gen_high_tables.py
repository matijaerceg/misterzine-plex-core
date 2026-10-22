#!/usr/bin/env python3
"""Transcribe the High-profile tables of ITU-T H.264 from the spec PDF into
tools/high_tables.py: the default scaling lists (Tables 7-3, 7-4), the 8x8 zig-zag and
field scans (Table 8-14; Table 8-13's 4x4 scans are re-derived as a check of the method),
normAdjust8x8's matrix v (equation 8-318) and the 8x8 significance / last context maps
(Table 9-43).

CLAUDE.md: these numbers come from the spec, never from memory. The PDF is rendered with
`pdftotext -layout` (as tools/gen_cabac_tables.py does); every table must yield exactly
its element count or the run fails. The result is cross-checked against an independent
transcription, ffmpeg's libavcodec (h264_ps.c default_scaling4 / 8 in raster order,
h264_slice.c field_scan8x8, mathtables.c ff_zigzag_direct, h264data.c
ff_h264_dequant8_coeff_init, h264_cabac.c significant_coeff_flag_offset_8x8, cabac.c
last_coeff_flag_offset_8x8), when a source tree is at $H264_REFS_DIR/ffmpeg-*/.
tools/tests/test_h264_fe_ref.py repeats the check.

Conventions: a scan maps the scan index to the RASTER index 8 * i + j of c_ij, i the row
and j the column (8.5.14: u_ij = pred[ xO + j, yO + i ] + r_ij). Scaling lists are kept in
the order the bitstream codes them (zig-zag scan order, 8.5.6 / 8.5.7 "for a scaling
list the inverse zig-zag scan is used").

    gen_high_tables.py [--pdf T-REC-H.264-202606.pdf] [-o tools/high_tables.py] [--check]
"""
import argparse
import glob
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REFS = os.environ.get("H264_REFS_DIR", os.path.expanduser("~/h264-refs"))
PDF = os.path.join(REFS, "T-REC-H.264-202606.pdf")


class GenError(Exception):
    pass


def ints(line):
    return [int(t) for t in re.findall(r"(?<![\w.])-?\d+(?![\w.])", line)]


def region(text, start_pat, end_pat, nth=-1):
    """The text from the nth match of start_pat (a caption; the table of contents lists
    it first, hence the last by default) to the next end_pat."""
    starts = [m.start() for m in re.finditer(start_pat, text, re.M)]
    if not starts:
        raise GenError("not found: %r" % start_pat)
    s = starts[nth]
    m = re.compile(end_pat, re.M).search(text, s + 1)
    if not m:
        raise GenError("no end after %r" % start_pat)
    return text[s:m.start()]


def parse_default_lists(text):
    """Tables 7-3 / 7-4: rows 'Default_NxN_Kind[ idx ]  v v v ...', 16 values a row, the
    8x8 table in four chunks (idx 0-15, 16-31, 32-47, 48-63)."""
    body = region(text, r"^\s*Table 7-3 – Specification of default scaling lists", r"^log2_max_frame_num_minus4")
    out = {}
    for name in ("Default_4x4_Intra", "Default_4x4_Inter", "Default_8x8_Intra", "Default_8x8_Inter"):
        vals = []
        for ln in body.split("\n"):
            if ln.strip().startswith(name + "[ idx ]"):
                vals += ints(ln.split("]", 1)[1])
        want = 16 if "4x4" in name else 64
        if len(vals) != want:
            raise GenError("%s: %d values, want %d" % (name, len(vals), want))
        out[name] = vals
    return out


def parse_scan(text, table, n):
    """Tables 8-13 (4x4) / 8-14 (8x8): chunks of an 'idx' row, a 'zig-zag' row of cij
    and a 'field' row. Returns (zigzag, field) as scan index -> raster index."""
    if table == 13:
        body = region(text, r"^\s*Table 8-13 – Specification of mapping of idx to cij", r"^8\.5\.7")
    else:
        body = region(text, r"^\s*Table 8-14 – Specification of mapping of idx to cij", r"^8\.5\.8")
    side = 4 if n == 16 else 8
    idx, zz, fs = [], [], []
    for ln in body.split("\n"):
        t = ln.split()
        if not t:
            continue
        if t[0] == "idx":
            idx += [int(v) for v in t[1:]]
        elif t[0] in ("zig-zag", "field"):
            cells = t[1:]
            for c in cells:
                if not re.fullmatch(r"c\d\d", c):
                    raise GenError("Table 8-%d: cell %r" % (table, c))
            r = [int(c[1]) * side + int(c[2]) for c in cells]
            (zz if t[0] == "zig-zag" else fs).extend(r)
    if idx != list(range(n)) or len(zz) != n or len(fs) != n:
        raise GenError("Table 8-%d: %d idx, %d zig-zag, %d field" % (table, len(idx), len(zz), len(fs)))
    for s in (zz, fs):
        if sorted(s) != list(range(n)):
            raise GenError("Table 8-%d: a scan is not a permutation" % table)
    return zz, fs


def parse_norm_adjust8(text):
    """Equation 8-318: the matrix v of normAdjust8x8, six rows of six (the layout puts
    'v=' on a line of its own; the rows are the lines of exactly six integers between
    (8-317) and clause 8.5.10)."""
    body = region(text, r"normAdjust8x8 \(m, i, j\) =", r"^8\.5\.10 ", nth=0)
    rows = [ints(ln) for ln in body.split("\n") if "(8-3" not in ln]
    rows = [r for r in rows if len(r) == 6]
    if len(rows) != 6:
        raise GenError("8-318: %d rows of six" % len(rows))
    return rows


def parse_ctx8(text):
    """Table 9-43: per row levelListIdx, sig (frame), sig (field), last; the left half
    of a page 0..31, the right half 32..62; the table spans two pages."""
    sig_fr, sig_fl, last = {}, {}, {}
    starts = [m.start() for m in re.finditer(r"^\s*Table 9-43 – Mapping of scanning position", text, re.M)]
    if len(starts) < 3:
        raise GenError("Table 9-43: %d captions" % len(starts))
    for s in starts[1:]:                      # [0] is the table of contents
        s = text.index("\n", s)                # past the caption line itself
        e = text.find("Let numDecodAbsLevelEq1", s)
        e2 = text.find("Table 9-43", s)
        end = min(x for x in (e, e2) if x > 0)
        for ln in text[s:end].split("\n"):
            v = ints(ln)
            if len(v) not in (4, 8) or "Rec. ITU-T" in ln:
                continue
            for k in range(0, len(v), 4):
                i, a, b, c = v[k:k + 4]
                if i in sig_fr:
                    raise GenError("Table 9-43: levelListIdx %d twice" % i)
                sig_fr[i], sig_fl[i], last[i] = a, b, c
    if sorted(sig_fr) != list(range(63)):
        raise GenError("Table 9-43: levelListIdx %s" % sorted(sig_fr))
    return [sig_fr[i] for i in range(63)], [sig_fl[i] for i in range(63)], [last[i] for i in range(63)]


# ---------------------------------------------------------------- ffmpeg (independent)

def ffmpeg_dir():
    for d in sorted(glob.glob(os.path.join(REFS, "ffmpeg-*", "libavcodec")), reverse=True):
        if os.path.exists(os.path.join(d, "h264_ps.c")):
            return d
    return None


def c_array(src, name, n):
    """The first n values of the C array `name` (an initialiser of integers, or of
    'a + b * 8' sums)."""
    m = re.search(re.escape(name) + r"\s*(\[[^\]]*\])+\s*=\s*\{", src)
    if not m:
        raise GenError("ffmpeg: %s not found" % name)
    body = src[m.end():]
    body = re.sub(r"//[^\n]*", "", body)
    vals = []
    for tok in re.split(r"[,{}\n]", body):
        tok = tok.strip()
        if not tok:
            continue
        if not re.fullmatch(r"[\d\s+*]+", tok):
            break
        vals.append(eval(tok))              # digits, + and * only (checked above)
        if len(vals) == n:
            return vals
    raise GenError("ffmpeg: %s has %d values, want %d" % (name, len(vals), n))


def ffmpeg_tables(d):
    rd = lambda f: open(os.path.join(d, f)).read()
    ps, sl, cab, cabc, dat = rd("h264_ps.c"), rd("h264_slice.c"), rd("h264_cabac.c"), rd("cabac.c"), rd("h264data.c")
    mt = rd("mathtables.c")
    ds4 = c_array(ps, "default_scaling4", 32)
    ds8 = c_array(ps, "default_scaling8", 128)
    fl = cabc[cabc.index("// last_coeff_flag_offset_8x8"):]
    last8 = [int(v) for v in re.findall(r"\d+", fl.split("};")[0])][2:]      # "8x8" in the comment
    return {
        "zz8": c_array(mt, "ff_zigzag_direct", 64),
        "fs8": c_array(sl, "field_scan8x8", 64),
        "ds4": (ds4[:16], ds4[16:]), "ds8": (ds8[:64], ds8[64:]),
        "v8": [c_array(dat, "ff_h264_dequant8_coeff_init", 36)[6 * r:6 * r + 6] for r in range(6)],
        "sig8": c_array(cab, "significant_coeff_flag_offset_8x8", 126),
        "last8": last8[:63],
    }


def cross_check(t, ff):
    bad = []
    if t["ZIGZAG8"] != ff["zz8"]:
        bad.append("8x8 zig-zag")
    if t["FIELD_SCAN8"] != ff["fs8"]:
        bad.append("8x8 field scan")
    for k, (name4, name8) in enumerate((("DEFAULT_4X4_INTRA", "DEFAULT_8X8_INTRA"),
                                         ("DEFAULT_4X4_INTER", "DEFAULT_8X8_INTER"))):
        r4 = [0] * 16
        for s, v in enumerate(t[name4]):
            r4[t["ZIGZAG4"][s]] = v
        if r4 != ff["ds4"][k]:
            bad.append(name4)
        r8 = [0] * 64
        for s, v in enumerate(t[name8]):
            r8[t["ZIGZAG8"][s]] = v
        if r8 != ff["ds8"][k]:
            bad.append(name8)
    if t["NORM_ADJUST8"] != ff["v8"]:
        bad.append("normAdjust8x8 v")
    if t["SIG8_FRAME"] != ff["sig8"][:63] or t["SIG8_FIELD"] != ff["sig8"][63:]:
        bad.append("Table 9-43 significance")
    if t["LAST8"] != ff["last8"]:
        bad.append("Table 9-43 last")
    return bad


# ---------------------------------------------------------------- output

def build(text):
    d = parse_default_lists(text)
    zz4, fs4 = parse_scan(text, 13, 16)
    zz8, fs8 = parse_scan(text, 14, 64)
    sfr, sfl, last = parse_ctx8(text)
    return {
        "ZIGZAG4": zz4, "FIELD_SCAN4": fs4, "ZIGZAG8": zz8, "FIELD_SCAN8": fs8,
        "DEFAULT_4X4_INTRA": d["Default_4x4_Intra"], "DEFAULT_4X4_INTER": d["Default_4x4_Inter"],
        "DEFAULT_8X8_INTRA": d["Default_8x8_Intra"], "DEFAULT_8X8_INTER": d["Default_8x8_Inter"],
        "NORM_ADJUST8": parse_norm_adjust8(text),
        "SIG8_FRAME": sfr, "SIG8_FIELD": sfl, "LAST8": last,
    }


ORDER = ["ZIGZAG4", "FIELD_SCAN4", "ZIGZAG8", "FIELD_SCAN8", "DEFAULT_4X4_INTRA", "DEFAULT_4X4_INTER",
         "DEFAULT_8X8_INTRA", "DEFAULT_8X8_INTER", "NORM_ADJUST8", "SIG8_FRAME", "SIG8_FIELD", "LAST8"]

NOTES = {
    "ZIGZAG4": "Table 8-13 zig-zag: scan index -> raster 4 * i + j (i row, j column)",
    "FIELD_SCAN4": "Table 8-13 field scan",
    "ZIGZAG8": "Table 8-14 8x8 zig-zag: scan index -> raster 8 * i + j",
    "FIELD_SCAN8": "Table 8-14 8x8 field scan",
    "DEFAULT_4X4_INTRA": "Table 7-3, in scan (zig-zag) order",
    "DEFAULT_4X4_INTER": "Table 7-3",
    "DEFAULT_8X8_INTRA": "Table 7-4, in scan (zig-zag) order",
    "DEFAULT_8X8_INTER": "Table 7-4",
    "NORM_ADJUST8": "equation 8-318: v[m][0..5] of normAdjust8x8 (8-317)",
    "SIG8_FRAME": "Table 9-43: ctxIdxInc of significant_coeff_flag, frame coded, levelListIdx 0..62",
    "SIG8_FIELD": "Table 9-43: significant_coeff_flag, field coded",
    "LAST8": "Table 9-43: last_significant_coeff_flag (frame and field)",
}


def emit(t, out):
    w = ['"""GENERATED by tools/gen_high_tables.py from T-REC-H.264-202606.pdf and cross-checked',
         "against ffmpeg's libavcodec -- never edit by hand. The High-profile tables: default",
         'scaling lists, the 8x8 scans, normAdjust8x8, the 8x8 context maps."""', ""]
    for k in ORDER:
        w.append("# " + NOTES[k])
        v = t[k]
        if k == "NORM_ADJUST8":
            w.append("%s = [" % k)
            for row in v:
                w.append("    %s," % row)
            w.append("]")
        else:
            w.append("%s = %s" % (k, v))
        w.append("")
    txt = "\n".join(w)
    if out is None:
        return txt
    with open(out, "w") as f:
        f.write(txt)
    return txt


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--pdf", default=PDF)
    ap.add_argument("-o", "--out", default=os.path.join(HERE, "high_tables.py"))
    ap.add_argument("--check", action="store_true", help="compare with the existing module, write nothing")
    a = ap.parse_args(argv)
    if not os.path.exists(a.pdf):
        sys.exit("gen_high_tables: no spec PDF at %s (set H264_REFS_DIR)" % a.pdf)
    text = subprocess.run(["pdftotext", "-layout", a.pdf, "-"], check=True, capture_output=True,
                          text=True).stdout
    t = build(text)
    # the method, checked on the tables the Main decoder already proved
    sys.path.insert(0, HERE)
    import h264_recon_ref as rr
    if t["ZIGZAG4"] != rr.ZIGZAG or t["FIELD_SCAN4"] != rr.FIELD_SCAN:
        sys.exit("gen_high_tables: Table 8-13 disagrees with h264_recon_ref's proven 4x4 scans")
    d = ffmpeg_dir()
    if d:
        bad = cross_check(t, ffmpeg_tables(d))
        if bad:
            sys.exit("gen_high_tables: mismatches against ffmpeg: %s" % ", ".join(bad))
        print("ffmpeg cross-check (%s): every value agrees" % os.path.dirname(d))
    else:
        print("ffmpeg cross-check SKIPPED (no $H264_REFS_DIR/ffmpeg-*/libavcodec)")
    txt = emit(t, None)
    if a.check:
        cur = open(a.out).read() if os.path.exists(a.out) else ""
        if cur != txt:
            sys.exit("gen_high_tables: %s differs from the spec's tables" % a.out)
        print("%s: identical" % a.out)
        return 0
    emit(t, a.out)
    print("wrote %s" % a.out)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except GenError as e:
        sys.exit("gen_high_tables: %s" % e)
