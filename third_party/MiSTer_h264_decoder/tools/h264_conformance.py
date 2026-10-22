#!/usr/bin/env python3
"""The H.264.1 conformance sweep for the Phase 3 front end (docs/roadmap.md P3,
docs/conformance.md): every package under $H264_REFS_DIR/H.264.1_bitstreams/AVCv1 (or
FRExt with `--pkg FRExt`: the High-profile package, H264 Phase 5) goes through
tools/h264_fe_ref.py; what it decodes is scored three ways, what it refuses is
listed with the reason -- the graded / refused split is MEASURED here, not asserted.

Per stream:
  model     h264_fe_ref.py: `ok` (records, bins) or `REFUSED <field>` (CAVLC, MBAFF, ...)
  vs JM     canonical stream of the traced ldecod (tools/jm_build.sh) identical?
  vs donated the package's own -trace.txt, when it has one, identical?
  pixels    ldecod's YUV == the package's reference YUV?
  sps       profile / level / size / frame_mbs_only, from the model's SPS parse

    h264_conformance.py [--pkg AVCv1|FRExt] [--only CABACI3 CAFI1 ...] [--no-jm] [--recon] [-o report.tsv]

Exit 1 when any decoded stream disagrees with an oracle or a decode fails for a reason
other than a refusal; refusals are expected and exit 0. SKIP (exit 0) without the refs.
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile
import time
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import h264_fe_ref as FE  # noqa: E402
import h264_trace_ref as TR  # noqa: E402

REFS = os.environ.get("H264_REFS_DIR", os.path.expanduser("~/h264-refs"))
PKG_ROOT = os.path.join(REFS, "H.264.1_bitstreams")
STREAM_EXT = (".jsv", ".264", ".26l", ".avc", ".h264", ".jvt", ".bit")


def find(d, pred):
    out = []
    for root, _dirs, files in os.walk(d):
        for f in files:
            if pred(f):
                out.append(os.path.join(root, f))
    return sorted(out)


def sps_summary(records):
    """profile/level/size/frame_mbs_only from the first SPS's S records."""
    v = {}
    for r in records:
        if r.startswith("N ") and v.get("_in") and "profile_idc" in v:
            break
        if r.startswith("S "):
            _, k, x = r.split(" ", 2)
            if k in ("profile_idc", "level_idc", "pic_width_in_mbs_minus1", "pic_height_in_map_units_minus1",
                     "frame_mbs_only_flag") and k not in v:
                v[k] = int(x)
            v["_in"] = True
    if "profile_idc" not in v:
        return "?"
    w = (v["pic_width_in_mbs_minus1"] + 1) * 16
    h = (v["pic_height_in_map_units_minus1"] + 1) * 16 * (2 - v["frame_mbs_only_flag"])
    return "p%d L%d.%d %dx%d %s" % (v["profile_idc"], v["level_idc"] // 10, v["level_idc"] % 10, w, h,
                                    "frm" if v["frame_mbs_only_flag"] else "fld")


def run_one(zpath, use_jm, use_recon=False):
    name = os.path.basename(zpath)[:-4]
    row = {"name": name, "model": "?", "jm": "-", "donated": "-", "pixels": "-", "sps": "?", "t": 0.0,
           "recon": "-", "t_recon": 0.0}
    with tempfile.TemporaryDirectory(prefix="h264_conf_") as d:
        try:
            with zipfile.ZipFile(zpath) as z:
                z.extractall(d)
        except zipfile.BadZipFile as e:
            row["model"] = "BADZIP %s" % e
            return row
        streams = find(d, lambda f: f.lower().endswith(STREAM_EXT))
        if not streams:
            row["model"] = "NOSTREAM"
            return row
        stream = streams[0]
        yuvs = find(d, lambda f: f.lower().endswith(".yuv"))
        traces = find(d, lambda f: f.lower().endswith("-trace.txt") or f.lower().endswith("_trace.txt"))
        t0 = time.time()
        stats = {}
        try:
            recs = FE.decode_stream(open(stream, "rb").read(), stats)
        except FE.Refused as e:
            row["model"] = "REFUSED %s" % e
            row["sps"] = "-"
            return row
        except (FE.FeError, FE.CabacError, Exception) as e:      # noqa: BLE001 -- a report row, not a crash
            row["model"] = "ERROR %s: %s" % (type(e).__name__, str(e)[:60])
            return row
        row["t"] = time.time() - t0
        row["sps"] = sps_summary(recs)
        row["model"] = "ok %d rec %d bins" % (len(recs), stats["bins"])
        if traces:
            # three donation-time tracers exist in the package: Sony's (parse_jvt), an
            # old JM's (SVA: parse_jm reads it), and Toshiba's CSV (not parsed)
            lines = open(traces[0], errors="replace").readlines()
            head = "".join(lines[:40])
            try:
                if "<<< Begin Nal Unit" in head:
                    don = TR.parse_jvt_file(lines)
                    tag = "sony"
                elif re.search(r"^@\d+\s+SPS:", head, re.M):
                    don = TR.parse_jm(lines)
                    tag = "oldjm"
                else:
                    don = None
                    row["donated"] = "n/a(csv)"
                if don is not None:
                    dd, wild = TR.diff(recs, don, "model", "donated")
                    row["donated"] = ("SAME(%d*,%s)" % (wild, tag)) if dd is None else "DIFF " + dd.split("\n")[0]
            except TR.TraceError as e:
                row["donated"] = "TRACE? %s" % str(e)[:50]
        if use_recon:
            # Phase 4: the reconstruction model's pixels against the package's reference YUV
            import h264_recon_ref as RR
            t1 = time.time()
            try:
                dec = RR.Decoder()
                dec.feed(recs)
                out = os.path.join(d, "recon_out.yuv")
                RR.write_yuv(dec.output_frames(), out)
                if yuvs:
                    ours = open(out, "rb").read()
                    ref = open(yuvs[0], "rb").read()
                    if ours == ref:
                        row["recon"] = "SAME %d fr" % len(dec.output_frames())
                    else:
                        row["recon"] = "DIFF %d vs %d bytes" % (len(ours), len(ref))
                        if len(ours) == len(ref):
                            import numpy as np
                            a = np.frombuffer(ours, dtype=np.uint8)
                            b = np.frombuffer(ref, dtype=np.uint8)
                            i = int(np.nonzero(a != b)[0][0])
                            row["recon"] += " first byte %d (%d vs %d)" % (i, a[i], b[i])
                else:
                    row["recon"] = "NOYUV"
            except (RR.ReconError, Exception) as e:      # noqa: BLE001 -- a report row
                row["recon"] = "ERROR %s: %s" % (type(e).__name__, str(e)[:70])
            row["t_recon"] = time.time() - t1
        if use_jm:
            yuv = os.path.join(d, "jm_out.yuv")
            try:
                lines, _frames = TR.run_jm(stream, yuv=yuv)
                jm = TR.parse_jm(lines)
                dd, _w = TR.diff(recs, jm, "model", "jm")
                row["jm"] = "SAME" if dd is None else "DIFF " + dd.split("\n")[0]
                if yuvs and os.path.exists(yuv):
                    same = open(yuv, "rb").read() == open(yuvs[0], "rb").read()
                    row["pixels"] = "SAME" if same else "DIFF"
            except TR.TraceError as e:
                row["jm"] = "JM? %s" % str(e)[:60]
    return row


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--pkg", default="AVCv1", help="the package directory: AVCv1 (Main) or FRExt (High)")
    ap.add_argument("--only", nargs="*", help="substrings of package names to run")
    ap.add_argument("--no-jm", action="store_true")
    ap.add_argument("--recon", action="store_true", help="Phase 4: the reconstruction model vs the reference YUV")
    ap.add_argument("-o", "--out")
    a = ap.parse_args(argv)
    PKG = os.path.join(PKG_ROOT, a.pkg)
    if not os.path.isdir(PKG):
        print("h264_conformance: SKIP (no %s)" % PKG)
        return 0
    zips = sorted(f for f in os.listdir(PKG) if f.endswith(".zip"))
    if a.only:
        zips = [z for z in zips if any(s.lower() in z.lower() for s in a.only)]
    rows = []
    bad = 0
    for z in zips:
        row = run_one(os.path.join(PKG, z), not a.no_jm, a.recon)
        rows.append(row)
        flag = ""
        if row["model"].startswith(("ERROR", "BADZIP", "NOSTREAM")) or "DIFF" in row["jm"] \
                or "DIFF" in row["donated"] or row["pixels"] == "DIFF" or row["jm"].startswith("JM?") \
                or row["recon"].startswith(("DIFF", "ERROR", "NOYUV")):
            bad += 1
            flag = "  <<<"
        print("%-26s %-28s %-8s %-14s %-6s %s%s%s" % (row["name"], row["sps"], row["jm"], row["donated"],
                                                       row["pixels"], row["model"],
                                                       ("  recon %s (%.0fs)" % (row["recon"], row["t_recon"])) if a.recon else "", flag))
        sys.stdout.flush()
    n_ok = sum(1 for r in rows if r["model"].startswith("ok"))
    n_ref = sum(1 for r in rows if r["model"].startswith("REFUSED"))
    print("h264_conformance: %d streams, %d decoded, %d refused, %d problems -> %s"
          % (len(rows), n_ok, n_ref, bad, "ALL GREEN" if not bad else "FAILURES"))
    if a.out:
        with open(a.out, "w") as f:
            f.write("name\tsps\tmodel\tjm\tdonated\tpixels\tseconds\trecon\trecon_seconds\n")
            for r in rows:
                f.write("%s\t%s\t%s\t%s\t%s\t%s\t%.1f\t%s\t%.1f\n" % (r["name"], r["sps"], r["model"], r["jm"],
                                                                  r["donated"], r["pixels"], r["t"], r["recon"], r["t_recon"]))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
