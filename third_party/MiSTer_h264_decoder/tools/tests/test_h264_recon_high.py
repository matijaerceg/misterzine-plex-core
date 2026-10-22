#!/usr/bin/env python3
"""h264_recon_ref on High profile (H264 Phase 5): x264 High clips encoded at test time,
decoded by the front-end and reconstruction models, bit-exact against ffmpeg.

  intra    Intra_8x8 (all nine modes' reference filtering), I_NxN 4x4 beside 8x8
           neighbours, keyframes only
  inter    P and B with the 8x8 transform (inter transform_size_8x8_flag 1), spatial
           direct with direct_8x8_inference, weighted prediction, deblocking on
  jvt      the JVT default matrices: a PPS with pic_scaling_matrix_present_flag 1 and
           every list absent -- fall-back rule A to Default_* (7.4.2.2 / Table 7-2)
  custom   every 4x4 and 8x8 list coded, non-flat: LevelScale4x4 / 8x8 with weights,
           the Intra16x16 / chroma DC paths through weightScale(0, 0)
  crqp     chroma_qp_index_offset -9 (Cb and Cr QPs through Table 8-15; Cb != Cr is the
           FRExt package's, h264_conformance.py --pkg FRExt --recon)

Each clip's range is asserted, not assumed (the counts of 8x8 blocks, Intra_8x8
macroblocks, non-flat lists, fall-backs): a clip that stops exercising its feature fails
here rather than passing vacuously. SKIP (exit 0) without ffmpeg's libx264.
"""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import h264_fe_ref as FE  # noqa: E402
import h264_recon_ref as RR  # noqa: E402
from score import Score  # noqa: E402

Sc = Score("test_h264_recon_high")

# every list distinct (intra / inter, luma / chroma, 4x4 / 8x8): a wrong list chosen for a
# block cannot hide behind an equal one


def lst(n, a, b, c):
    return ",".join(str(a + (i * b) % c) for i in range(n))


I4Y, I4C, P4Y, P4C = lst(16, 6, 13, 50), lst(16, 9, 7, 40), lst(16, 12, 5, 36), lst(16, 20, 3, 30)
I8, P8 = lst(64, 4, 11, 60), lst(64, 10, 9, 45)
CLIPS = [
    ("intra", "testsrc2=size=352x288:rate=30", "keyint=1:8x8dct=1:crf=16"),
    ("inter", "mandelbrot=size=352x288:rate=30", "8x8dct=1:bframes=2:ref=2:direct=spatial:weightp=2:crf=22"),
    ("jvt", "mandelbrot=size=352x288:rate=30", "8x8dct=1:cqm=jvt:bframes=1:crf=20"),
    ("custom", "mandelbrot=size=352x288:rate=30",
     "8x8dct=1:bframes=1:crf=20:cqm4iy=%s:cqm4ic=%s:cqm4py=%s:cqm4pc=%s:cqm8i=%s:cqm8p=%s" % (I4Y, I4C, P4Y, P4C, I8, P8)),
    ("crqp", "mandelbrot=size=352x288:rate=30", "8x8dct=1:chroma-qp-offset=-7:bframes=1:crf=22"),
]

have_x264 = shutil.which("ffmpeg") and "libx264" in subprocess.run(
    ["ffmpeg", "-hide_banner", "-encoders"], stdout=subprocess.PIPE, universal_newlines=True).stdout
if not have_x264:
    print("  SKIP: ffmpeg with libx264 not found")
    Sc.finish()
    sys.exit(0)

with tempfile.TemporaryDirectory(prefix="h264_rh_") as d:
    for name, src, params in CLIPS:
        print("[%s]" % name)
        clip = os.path.join(d, name + ".264")
        r = subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", src, "-frames:v", "8", "-c:v", "libx264",
                            "-profile:v", "high", "-pix_fmt", "yuv420p", "-x264-params", "cabac=1:" + params,
                            "-bsf:v", "h264_mp4toannexb", "-f", "h264", "-y", clip],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
        Sc.check("encode", r.returncode, 0)
        recs = FE.decode_stream(open(clip, "rb").read())
        n_l8 = sum(1 for x in recs if x.startswith("B L8 "))
        n_i8 = sum(1 for x in recs if x.startswith("E prev_intra8x8_pred_mode_flag"))
        n_t8 = sum(1 for x in recs if x == "E transform_size_8x8_flag 1")
        dec = RR.Decoder()
        dec.feed(recs)
        dec.flush_output()
        out = os.path.join(d, name + ".yuv")
        RR.write_yuv(dec.output_frames(), out)
        ref = os.path.join(d, name + ".ff.yuv")
        RR.ffmpeg_yuv(clip, ref)
        s = dec.output_frames()[0].sps
        mism, na, nb = RR.compare_yuv(out, ref, s.width, s.height)
        Sc.check("bit-exact vs ffmpeg (first mismatch, frames)", (mism, na), (None, nb))
        cov = dec.cov
        if name == "intra":
            Sc.check("range: Intra_8x8 macroblocks (x4 modes)", n_i8 >= 400, True)
            Sc.check("range: Intra_4x4 macroblocks beside them",
                     any(x.startswith("E prev_intra4x4_pred_mode_flag") for x in recs), True)
        if name == "inter":
            Sc.check("range: inter 8x8 transform", n_t8 - n_i8 // 4 > 50, True)
            Sc.check("range: 8x8 blocks", n_l8 > 100, True)
        if name == "jvt":
            Sc.check("range: non-flat lists, all by fall-back rule A",
                     (cov.get("scaling_nonflat", 0) > 0, cov.get("scaling_fallback", 0) > 0), (True, True))
        if name == "custom":
            Sc.check("range: coded lists (delta_scale)", sum(1 for x in recs if x.startswith("S delta_scale ")) > 40, True)
            Sc.check("range: non-flat", cov.get("scaling_nonflat", 0) > 0, True)
        if name == "crqp":
            # x264 adds its psy offset (-2) to the one asked for: -9 is written
            offs = [int(x.split()[2]) for x in recs if x.startswith("S chroma_qp_index_offset ")]
            Sc.check("range: chroma_qp_index_offset far from 0", bool(offs) and min(offs) <= -7, True)

Sc.finish()
