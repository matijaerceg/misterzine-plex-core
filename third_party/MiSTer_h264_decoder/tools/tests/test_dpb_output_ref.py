#!/usr/bin/env python3
"""The output order (P5d, docs/display.md S6): h264_recon_ref's output process and
dpb_output_ref's per-picture spec process, gated two ways:

  units   the DPB size (Table A-1 by level / the VUI's max_dec_frame_buffering, A.3.1 /
          E.2.1) on hand-made SPSs; the spec process on a hand-built three-picture stream
          (an IDR, a P, a non-reference B output directly past a full DPB); the store
          order and its split count on a hand-built picture list -- no tools needed.
  x264    (SKIP without ffmpeg's libx264) B pictures with two IDRs and a VUI DPB of 2
          (non-reference pictures output directly, C.4.5.2), its second IDR's
          no_output_of_prior_pics_flag set (C.4.4: the waiting stores dropped -- 7 stores
          out of 14, where ffmpeg, which ignores the flag, outputs 14), and a P stream with
          an MMCO 5 spliced in (tools/h264_synth.py). Each: the model's store order equal to
          the spec process's, no pair split, and equal to ffmpeg's display order (the
          no_output stream: equal to ffmpeg's with the dropped stores removed).
"""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import score as S  # noqa: E402
import dpb_output_ref as DO  # noqa: E402
import h264_recon_ref as R  # noqa: E402

Sc = S.Score("test_dpb_output_ref")

print("[units]")


class Sps(object):
    def __init__(self, level, w, h, mdfb=None):
        self.level_idc, self.width_mbs, self.frame_height_mbs = level, w, h
        self.vui = {} if mdfb is None else {"bitstream_restriction_flag": 1, "max_dec_frame_buffering": mdfb}


# MaxDpbFrames = Min(MaxDpbMbs / (PicWidthInMbs * FrameHeightInMbs), 16): Table A-1 by hand
Sc.check("DPB size: Level 3.0, 720x480 (8100 / 1350)", R.dpb_size(Sps(30, 45, 30)), 6)
Sc.check("DPB size: Level 3.0, 480x272 (8100 / 510)", R.dpb_size(Sps(30, 30, 17)), 15)
Sc.check("DPB size: Level 1.1, QCIF (900 / 99)", R.dpb_size(Sps(11, 11, 9)), 9)
Sc.check("DPB size: capped at 16 (Level 3.0, 64x48)", R.dpb_size(Sps(30, 4, 3)), 16)
Sc.check("DPB size: the VUI's max_dec_frame_buffering (3, the discs')", R.dpb_size(Sps(30, 45, 30, 3)), 3)
Sc.check("DPB size: max_dec_frame_buffering 0 -> 1", R.dpb_size(Sps(30, 45, 30, 0)), 1)


def ev(frame, poc, is_ref, idr, size, refs):
    return {"frame": frame, "struct": "F", "is_ref": is_ref, "idr": idr, "no_output": 0, "mmco5": 0,
            "size": size, "poc": [poc, poc], "refs": {k: [True, True] for k in refs}}


# IDR (POC 0), P (POC 4), B non-reference (POC 2), DPB size 1: the P bumps nothing it can
# free (the IDR is still a reference), the B is below everything waiting: output directly
evs = [ev(0, 0, True, True, 1, [0]), ev(1, 4, True, False, 1, [0, 1]), ev(2, 2, False, False, 1, [0, 1])]
Sc.check("spec process: I P b, size 1 -> I b P", DO.spec_output(evs), [(0, (0, 1)), (2, (0, 1)), (1, (0, 1))])
Sc.check("store order + splits: a pair's fields apart",
         DO.store_order([(0, (0,)), (1, (0, 1)), (0, (1,))]), ([0, 1], 1))

print("[x264]")
if not (shutil.which("ffmpeg") and b"libx264" in subprocess.run(
        ["ffmpeg", "-hide_banner", "-encoders"], capture_output=True).stdout):
    print("SKIP: [x264] needs ffmpeg with libx264")
else:
    with tempfile.TemporaryDirectory(prefix="dpbout_") as d:
        def enc(name, params):
            p = os.path.join(d, name + ".264")
            subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=64x64:rate=24",
                            "-frames:v", "14", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-x264-params",
                            "cabac=1:8x8dct=0:keyint=7:min-keyint=7:scenecut=0:weightp=0:" + params,
                            "-f", "h264", "-y", p], check=True)
            return p

        def synth(src, kind):
            out = src[:-4] + "_" + kind + ".264"
            subprocess.run([sys.executable, os.path.join(os.path.dirname(HERE), "h264_synth.py"), src, kind, out],
                           check=True, capture_output=True)
            return out
        b = enc("b", "bframes=2:b-pyramid=0:ref=2")
        p = enc("p", "bframes=0:ref=1")
        for name, path, n, direct in (("B pictures, VUI DPB 2", b, 14, 6),
                                      ("MMCO 5 (VUI dropped: Table A-1)", synth(p, "mmco5"), 14, None)):
            r = DO.check(path)
            Sc.check(name + ": model == spec order, no split, == ffmpeg, stores",
                     (r["model_eq_spec"], r["split"], r["model_eq_ffmpeg"], r["n"]), (True, 0, True, n))
            if direct is not None:
                Sc.check(name + ": non-reference pictures output directly", r["counts"]["direct"], direct)
        no = synth(b, "no_output")
        r = DO.check(no)
        Sc.check("no_output_of_prior_pics_flag: model == spec, 7 stores (7 dropped), ffmpeg 14",
                 (r["model_eq_spec"], r["split"], r["n"], r["counts"]["dropped"], r["n_ffmpeg"]), (True, 0, 7, 7, 14))

Sc.finish()
