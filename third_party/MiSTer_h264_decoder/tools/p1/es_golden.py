#!/usr/bin/env python3
"""H264 Phase 1 (MiSTer_h264_decoder): cosim_golden.py for an Annex-B FILE instead of a disc
window. Same outputs (STEM.es/.pics/.pre/.post/.out), same oracle (the model vs ffmpeg);
the window is the file's first `frames` frames from its first IDR. It imports UMD's
tools, so it runs from inside a UMD snapshot: tools/p1/run_p1_cosim.sh copies it there.
Real time comes from the stream's pic_timing SEI when present, else from --fps.

    es_golden.py --es FILE.264 --out STEM [--frames 300] [--fps 59.94]
"""
import argparse, os, sys, tempfile
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import cosim_golden as CG  # noqa: E402
import h264_fe_ref as FE  # noqa: E402
import h264_recon_ref as RR  # noqa: E402
import h264_top_golden as TG  # noqa: E402
import recon_top_golden as RG  # noqa: E402


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--es", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--frames", type=int, default=300)
    ap.add_argument("--fps", type=float, default=60000 / 1001.0)
    a = ap.parse_args(argv)
    try:
        data = CG.from_idr(open(a.es, "rb").read())
        if data is None:
            print("SKIP: no IDR"); return 3
        n_pic, n_fields = CG.count_pictures(data, a.frames)
        data = CG.trim_tail(RG.truncate_es(data, n_pic - 1))
        secs, _n_sei, _p = CG.display_seconds(data)
        n_frames_w = n_pic - n_fields // 2
        if not secs:
            secs = n_frames_w / a.fps
        print("window: %d pictures, plays %.3f s (%.2f frames/s needed)" % (n_pic, secs, n_frames_w / secs))
        rec = FE.decode_stream(data)
    except (FE.Refused, RR.ReconError) as e:
        print("REFUSED: %s" % e); return 4
    except Exception as e:
        if type(e).__name__ in ("Refused", "Unsupported"):
            print("REFUSED: %s" % e); return 4
        raise

    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    with open(a.out + ".es", "wb") as f:
        f.write(data)
    pics = []
    fpre = open(a.out + ".pre", "wb")
    fpost = open(a.out + ".post", "wb")
    off = [0]

    frame_of = []

    def hook(pic, pre):
        frame_of.append(pic.frame.id)
        pics.append(({"F": 0, "T": 1, "B": 2}[pic.struct], pic.w, pic.hgt, off[0]))
        for planes, f in ((pre, fpre), ([pic.Y, pic.Cb, pic.Cr], fpost)):
            for pl in planes:
                f.write(np.ascontiguousarray(pl.astype(np.uint8)).tobytes())
        off[0] += (16 * pic.hgt * 2 * pic.w) + 2 * (8 * pic.hgt * pic.w)
    dec = RR.Decoder(on_picture=hook)
    try:
        dec.feed(rec)
    except RR.ReconError as e:
        print("REFUSED: %s" % e)
        return 4
    dec.flush_output()                    # the end of stream: the last picture, then every one waiting
    fpre.close()
    fpost.close()
    n_mbs = sum(1 for w in TG.words(rec) if w[0] == 1)
    frames = dec.output_frames()

    # the independent oracle: the model's display-order window against ffmpeg's decode
    with tempfile.TemporaryDirectory() as td:
        es = os.path.join(td, "w.264")
        open(es, "wb").write(data)
        ours, ref = os.path.join(td, "m.yuv"), os.path.join(td, "f.yuv")
        RR.write_yuv(frames, ours)
        RR.ffmpeg_yuv(es, ref)
        s = frames[0].sps
        l, r, t, b = s.crop
        cu_y = 2 * (2 - s.frame_mbs_only)
        w, h = s.width - 2 * (l + r), s.height - cu_y * (t + b)
        mism, na, nb = RR.compare_yuv(ours, ref, w, h)
    if mism is not None or na != nb:
        print("MODEL-MISMATCH vs ffmpeg: %s (model %d frames, ffmpeg %d)" % (mism, na, nb))
        return 5

    with open(a.out + ".pics", "w") as f:
        f.write("%d %d %d %d %d\n" % (len(pics), n_mbs, len(frames), n_fields,
                                     int(round((secs or 0) * 1e6))))
        for p in pics:
            f.write("%d %d %d %d\n" % p)
    with open(a.out + ".out", "w") as f:
        f.write("%d\n" % len(dec.emitted))
        for fr, n, _how in dec.emitted:
            unpaired = int(not fr.coded_as_frame and fr.decoded != [1, 1])
            f.write("%d %d %d %d\n" % (frame_of.index(fr.id), n, fr.coded_as_frame, unpaired))
    print("%s: %s from its first IDR, %d bytes, %d pictures (%d fields), %d frames, %d macroblocks, "
          "plays %.3f s; the model BIT-EXACT vs ffmpeg" % (a.out, a.es, len(data), len(pics), n_fields, len(frames),
                                                        n_mbs, secs or 0))
    return 0



if __name__ == "__main__":
    sys.exit(main())
