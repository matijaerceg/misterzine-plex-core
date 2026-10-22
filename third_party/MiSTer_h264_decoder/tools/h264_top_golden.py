#!/usr/bin/env python3
"""Fixtures for bench/h264/h264_top_tb.sv: an Annex-B stream as the bytes h264/dec/h264_top
consumes and the syntax-element stream it must emit -- tools/h264_fe_ref.py's whole
record list (N, S, M, E, B) as the RTL's words (docs/h264_frontend.md S5).

Files (one word per line, $readmemh):
  <stem>.es.hex    42-bit words {pts[32:0], mark, byte}: the Annex-B bytes (start codes,
                   EPBs and all), each with the PES sideband -- mark on a PES's first
                   payload byte when that PES carried a PTS, and the PTS (P5c)
  <stem>.se.hex    48-bit words {kind[7:0], aux[7:0], val[31:0]}: kinds 1..16 are
                   tools/mb_syntax_golden.py's (val sign-extended), 17 K_NAL (aux type,
                   val nal_ref_idc), 18 K_HDR (aux = tools/h264_fields.py id)
  <stem>.meta.hex  [0] n_bytes [1] n_words [2] NAL units [3] slices decoded [4] pictures
                   (slices with first_mb 0) [5] SPS stored [6] PPS stored [7] refusals (0/1)
                   [8] the refusal code (h264_pkg.sv) [9] errors expected (0) [10] bins
                   [11] partial (score only n_words) [12] pictures with a picture timing
                   SEI [13] ... missing one [14] short / Table D-1 / forbidden [15]
                   malformed SEI units [16] pictures tagged with a PTS [17] stamps dropped
                   ([12..17] = 0xFFFFFFFF, not scored, on a refused or partial fixture)
A full fixture's words end with one K_EOS_WORD (the tb flushes once at the end).

--nals N cuts the stream after N NAL units. A stream the model REFUSES is still a
fixture: the records up to the refused field are the expected words, the stream is cut
at the end of the refused NAL unit, meta[7:8] name the refusal -- the RED arm for the
refusal path. --fabric applies the RTL's own limit (128 macroblocks a side) on top.
--truncate K cuts the bytes at K (inside a NAL unit): the model fails there, the words
up to its failure are expected, meta[9] = 1 error and meta[11] = 1 tells the bench to
score only those words -- the no-hang arm (the RTL must count one error and return to
idle; what it emits past the model's failure is not scored).
--expect-error: the same scoring for a stream the model rejects with a range error (a
VUI value outside its E.2 range, tools/h264_synth.py); cut it after that NAL (--nals).

    h264_top_golden.py stream.264 --out bench/h264/fixtures/gen/h264top_x [--nals 12]
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import h264_fe_ref as FE  # noqa: E402
import h264_trace_ref as TR  # noqa: E402
import mb_syntax_golden as MG  # noqa: E402
from h264_fields import FIELD_ID, K_NAL, K_HDR, K_EOS  # noqa: E402

FABRIC_MAX_MBS = 128

# the model's Refused messages -> h264_pkg.sv's REF_* codes, by the field they name
REFUSAL_CODES = [
    ("chroma_format_idc", 1), ("bit depth", 2), ("qpprime_y_zero_transform_bypass", 2), ("scaling_matrix", 3), ("mb_adaptive", 4),
    ("entropy_coding_mode_flag 0", 5), ("num_slice_groups", 6), ("transform_8x8", 7),
    ("redundant_pic_cnt", 8), ("slice_type", 9), ("data partitioning", 10), ("SVC/MVC", 11),
    ("beyond the fabric", 12),
]


def refusal_code(msg):
    for key, code in REFUSAL_CODES:
        if key in msg:
            return code
    raise ValueError("no code for refusal %r" % msg)


def start_codes(data):
    out = []
    i = data.find(b"\x00\x00\x01")
    while i >= 0:
        out.append(i)
        i = data.find(b"\x00\x00\x01", i + 3)
    return out


def cut_nals(data, n):
    """The bytes of the first n NAL units (cut at the start code of unit n)."""
    sc = start_codes(data)
    if n < len(sc):
        return data[:sc[n]]
    return data


def words(rec, eos=False):
    out = []
    mb = []

    def flush_mb():
        for kind, aux, val in MG.se_words(mb):
            out.append((kind, aux, val))
        del mb[:]
    for r in rec:
        if r[0] == "N":
            flush_mb()
            _n, t, ref = r.split(" ")
            out.append((K_NAL, int(t), int(ref)))
        elif r[0] == "S":
            flush_mb()
            _s, name, v = r.split(" ")
            out.append((K_HDR, FIELD_ID[name], int(v)))
        else:
            mb.append(r)
    flush_mb()
    if eos:
        out.append((K_EOS, 0, 0))
    return out


def build(data, nals=None, fabric=False, truncate=None, expect_error=False, marks=None):
    if nals:
        data = cut_nals(data, nals)
    if truncate:
        data = data[:truncate]
    marks = [(o, p) for o, p in (marks or []) if o < len(data)]
    rec = []
    stats = {}
    refused = 0
    code = 0
    errors = 0
    partial = 0
    # decode_stream appends to `rec` as it goes, so the records before an exception survive
    try:
        FE.decode_stream(data, stats, None, FABRIC_MAX_MBS if fabric else None, marks=marks, rec=rec,
                         resolved_scaling=True)
    except FE.Refused as e:
        refused = 1
        code = refusal_code(str(e))
        n_before = sum(1 for r in rec if r[0] == "N")
        data = cut_nals(data, n_before)
        marks = [(o, p) for o, p in marks if o < len(data)]
        stats = {"bins": 0}
    except (FE.FeError, FE.CabacError):
        if not (truncate or expect_error):
            raise
        errors = 1
        partial = 1
        stats = {"bins": 0}
    n_nals = sum(1 for r in rec if r[0] == "N")
    n_slices = sum(1 for r in rec if r.startswith("N 1 ") or r.startswith("N 5 "))
    n_pics = sum(1 for r in rec if r == "S first_mb_in_slice 0")
    n_sps = sum(1 for r in rec if r.startswith("N 7 "))
    n_pps = sum(1 for r in rec if r.startswith("N 8 "))
    if refused or partial:
        # the refused / truncated unit was not stored / not decoded
        last_i = max(i for i, r in enumerate(rec) if r[0] == "N")
        last = rec[last_i]
        if last.startswith("N 7 "):
            n_sps -= 1
        elif last.startswith("N 8 "):
            n_pps -= 1
        elif last.startswith("N 1 ") or last.startswith("N 5 "):
            n_slices -= 1
            if "S first_mb_in_slice 0" in rec[last_i:]:
                n_pics -= 1
    w = words(rec, eos=not partial)
    if partial:
        # the model's last records may be a half-decoded macroblock; score whole NAL
        # units only, up to the failing one's NAL word
        keep = max(i for i, x in enumerate(w) if x[0] == K_NAL) + 1
        w = w[:keep]
    unscored = 0xFFFFFFFF
    p5c = [stats.get(k, unscored) if not (refused or partial) else unscored
           for k in ("pt_seen", "pt_missing", "pt_bad", "sei_malformed", "pts_tagged", "pts_drops")]
    if not (refused or partial):
        p5c[2] = stats["pt_short"] + stats["pt_struct"]
    meta = [len(data), len(w), n_nals, n_slices, n_pics, n_sps, n_pps, refused, code, errors,
            stats.get("bins", 0), partial] + p5c
    return data, w, meta, marks


def epb_count(data):
    """Emulation-prevention bytes in the stream (a fixture-range figure for the runner)."""
    n = z = 0
    for b in data:
        if z >= 2 and b == 3:
            n += 1
            z = 0
            continue
        z = z + 1 if b == 0 else 0
    return n


def write(stem, data, w, meta, marks=()):
    os.makedirs(os.path.dirname(stem) or ".", exist_ok=True)
    at = dict(marks)
    with open(stem + ".es.hex", "w") as f:
        f.write("".join("%011x\n" % (((at[i] << 9) | (1 << 8) | b) if i in at else b)
                        for i, b in enumerate(data)))
    with open(stem + ".se.hex", "w") as f:
        for kind, aux, val in w:
            f.write("%02x%02x%08x\n" % (kind, aux, val & 0xFFFFFFFF))
    with open(stem + ".meta.hex", "w") as f:
        f.write("".join("%08x\n" % v for v in meta))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("stream", nargs="?")
    ap.add_argument("--nals", type=int, help="keep only the first N NAL units")
    ap.add_argument("--fabric", action="store_true", help="apply the RTL's 128-MB size limit")
    ap.add_argument("--truncate", type=int, help="cut the bytes at this offset (inside a NAL unit)")
    ap.add_argument("--expect-error", action="store_true",
                    help="the model raises a stream error (a range violation): score like --truncate")
    ap.add_argument("--synth-marks", action="store_true",
                    help="P5c: PES marks around every NAL unit's start code (offsets -1, 0, +1, +2 "
                         "rotating per pair of units; PTSs with bit 32 set on every fifth): the "
                         "association's edges")
    ap.add_argument("--out", required=True)
    a = ap.parse_args(argv)
    marks = None
    if a.synth_marks and a.stream:
        d0 = open(a.stream, "rb").read()
        marks = []
        for k, (pos, _r, _t, _rb) in enumerate(FE.nal_units_pos(d0)):
            # the start code at pos - 3: -1, 0, +1, +2, rotating per PAIR of NAL units so the
            # access-unit openers (every other unit in an x264 stream) get all four offsets
            off = pos - 3 + ((k // 2) % 4) - 1
            if off >= 0:
                marks.append((off, 1000 * (k + 1) + ((1 << 32) if k % 5 == 0 else 0)))
    if a.stream:
        data = open(a.stream, "rb").read()
    else:
        ap.error("a stream")
    data, w, meta, marks = build(data, a.nals, a.fabric, a.truncate, a.expect_error, marks)
    write(a.out, data, w, meta, marks)
    print("%s: %d bytes, %d words, %d NAL units, %d slices, %d pictures, %d SPS, %d PPS, refused %d (code %d), errors %d, %d bins, %d EPBs%s"
          % ((a.out, meta[0], meta[1]) + tuple(meta[2:10]) + (meta[10], epb_count(data), " (partial)" if meta[11] else "")) +
          ("" if meta[12] == 0xFFFFFFFF else
           "; pic_timing %d, missing %d, bad %d, malformed SEI %d; PTS tagged %d, dropped %d" % tuple(meta[12:18])))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (FE.FeError, TR.TraceError) as e:
        sys.exit("h264_top_golden: %s" % e)
