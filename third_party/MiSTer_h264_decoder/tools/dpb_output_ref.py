#!/usr/bin/env python3
"""dpb_output_ref.py -- the output order DPB of Annex C.4, per PICTURE, from the spec text
(roadmap P5d, docs/display.md), and the order checks of the P5d output process.

tools/h264_recon_ref.py outputs STORES (the display's unit: a field pair is one store,
emitted when the bumping first selects it, whole, once, never before it is complete).
The spec outputs PICTURES: fields are pictures, and C.4.5.3 may output a pair's two
fields apart when another picture's POC falls between theirs. This module runs the
spec process literally -- C.4.4 (an IDR's emptying with or without output, MMCO 5,
emptying "not needed for output" + "unused for reference" buffers), C.4.5.1 / C.4.5.2
(storage, a non-reference picture output directly), C.4.5.3 (bumping: the smallest
PicOrderCnt; a complementary reference field pair with equal POCs output together; a
non-reference pair with equal POCs, its first field in decoding order) -- over the
model's per-picture events (the picture, its flags, the DPB size and every store's
reference marking after it: the marking itself, 8.2.5, is the model's, verified
pixel-exact against ffmpeg and JM elsewhere).

It shares the model's two documented choices: no_output_of_prior_pics_flag as coded
(C.4.4's inference on a size change is not made) and the DPB size of
h264_recon_ref.dpb_size(). Its store order (each store's first picture in the spec's
output) must equal the model's emitted order; `split` counts the stores whose two
fields the spec outputs apart (the case the store-unit rule changes).

    dpb_output_ref.py STREAM...       the three checks per stream: model == spec order,
                                      the split count, model == ffmpeg's display order
                                      (framemd5 with -fps_mode passthrough)
"""
import hashlib
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


class Buf(object):
    """A frame buffer: per field (0 top, 1 bottom) present / needed for output / POC."""

    def __init__(self, frame):
        self.frame = frame
        self.present = [False, False]
        self.needed = [False, False]
        self.poc = [None, None]
        self.is_ref = [False, False]         # the model's marking, refreshed per event
        self.first = None                    # the field decoded first (a pair's)

    def ref_any(self):
        return self.is_ref[0] or self.is_ref[1]

    def needed_any(self):
        return self.needed[0] or self.needed[1]


def spec_output(events):
    """The pictures output, in order: [(frame id, fields tuple)]."""
    dpb = {}                                 # frame id -> Buf (non-empty frame buffers)
    out = []

    def empty_unneeded():
        for k in [k for k, b in dpb.items() if not b.needed_any() and not b.ref_any()]:
            del dpb[k]

    def bump():
        cands = [(b.poc[p], b, p) for b in dpb.values() for p in (0, 1) if b.needed[p]]
        if not cands:
            return False
        poc, b, p = min(cands, key=lambda c: (c[0], c[1].frame, c[2]))
        both_equal = b.needed[0] and b.needed[1] and b.poc[0] == b.poc[1]
        if both_equal and b.ref_any():
            fields = (0, 1)                  # a reference pair with equal POCs: together
        elif both_equal:
            fields = (b.first,)              # a non-reference pair: its first field first
        else:
            fields = (p,)
        for q in fields:
            b.needed[q] = False
        out.append((b.frame, fields))
        # step 4: a buffer emptied once nothing in it is needed or referenced
        if not b.needed_any() and not b.ref_any():
            del dpb[b.frame]
        return True

    for e in events:
        fid, struct = e["frame"], e["struct"]
        fields = (0, 1) if struct == "F" else ((0,) if struct == "T" else (1,))
        cur_poc = min(e["poc"][q] for q in fields)
        # the marking after this picture, for every buffer (8.2.5, the model's)
        for k, b in dpb.items():
            r = e["refs"].get(k, [False, False])
            b.is_ref = [r[0] and b.present[0], r[1] and b.present[1]]
        # C.4.4
        if e["idr"]:
            if e["no_output"]:
                dpb = {k: b for k, b in dpb.items() if k == fid}   # emptied without output
            else:
                empty_unneeded()
                while bump():
                    pass
                dpb = {k: b for k, b in dpb.items() if k == fid}
        else:
            empty_unneeded()
            if e["mmco5"]:
                while any(b.needed_any() for k, b in dpb.items() if k != fid):
                    # (the current picture is not in the DPB yet; its first field could be)
                    held = dpb.pop(fid, None)
                    bump()
                    if held is not None:
                        dpb[fid] = held
        size = e["size"]
        r = e["refs"].get(fid, [False, False])
        # C.4.5
        second = struct != "F" and fid in dpb and dpb[fid].present[1 - fields[0]]
        if second:
            b = dpb[fid]
            q = fields[0]
            b.present[q] = True
            b.needed[q] = True
            b.poc[q] = e["poc"][q]
            b.is_ref = [r[0] and b.present[0], r[1] and b.present[1]]
            continue

        def fullness():
            return len(dpb)

        if e["is_ref"]:
            while fullness() >= size and bump():
                pass
            b = Buf(fid)
            dpb[fid] = b
        else:
            stored = False
            while True:
                if fullness() >= size:
                    needed = [b.poc[p] for b in dpb.values() for p in (0, 1) if b.needed[p]]
                    if needed and not all(cur_poc < v for v in needed):
                        if bump():
                            continue
                    out.append((fid, fields))            # output directly, not stored
                    break
                stored = True
                break
            if not stored:
                continue
            b = Buf(fid)
            dpb[fid] = b
        b.first = fields[0]
        for q in fields:
            b.present[q] = True
            b.needed[q] = True
            b.poc[q] = e["poc"][q]
        b.is_ref = [r[0] and b.present[0], r[1] and b.present[1]]
    while True:
        cands = [b for b in dpb.values() if b.needed_any()]
        if not cands or not bump():
            break
    return out


def store_order(out):
    """Each store's first appearance in the spec's picture output; the split count."""
    order, seen, last_pos = [], set(), {}
    split = 0
    for i, (fid, fields) in enumerate(out):
        if fid not in seen:
            seen.add(fid)
            order.append(fid)
        elif last_pos.get(fid, -1) != i - 1:
            split += 1                       # another picture came between a pair's fields
        last_pos[fid] = i
    return order, split


def frame_md5(fr):
    import numpy as np
    return hashlib.md5(np.concatenate([fr.Y.ravel(), fr.Cb.ravel(), fr.Cr.ravel()])
                       .astype(np.uint8).tobytes()).hexdigest()


def jm_order(stream, frame_bytes):
    """JM ldecod's output frames (its YUV, in output order) as md5s, or None without JM.
    JM implements C.4.4 literally -- ffmpeg does not honour no_output_of_prior_pics_flag
    (it outputs every frame), so JM is the independent oracle for that path."""
    import tempfile
    import h264_trace_ref as TR
    if not os.access(TR.jm_binary(), os.X_OK):
        return None
    with tempfile.TemporaryDirectory(prefix="dpb_jm_") as d:
        yuv = os.path.join(d, "out.yuv")
        TR.run_jm(os.path.abspath(stream), workdir=d, yuv=yuv)
        raw = open(yuv, "rb").read()
    return [hashlib.md5(raw[i:i + frame_bytes]).hexdigest() for i in range(0, len(raw), frame_bytes)]


def check(stream):
    """{model_eq_spec, split, model_eq_ffmpeg, n}: the three P5d order checks."""
    import h264_recon_ref as R
    d = R.decode_file(stream)
    model = [fr.id for fr, _n, _h in d.emitted]
    spec, split = store_order(spec_output(d.pic_events))
    ff = [ln.split(",")[-1].strip() for ln in subprocess.run(
        ["ffmpeg", "-v", "error", "-i", stream, "-fps_mode", "passthrough", "-f", "framemd5", "-"],
        stdout=subprocess.PIPE, universal_newlines=True).stdout.splitlines() if ln and not ln.startswith("#")]
    em = list(d.emitted)
    # ffmpeg does not output a non-paired field left at the end of the stream (a cut
    # window's last first field); the spec does (C.4.5.3): those TRAILING unpaired fields
    # are set aside and counted, never skipped anywhere else
    tail = 0
    while em and not em[-1][0].coded_as_frame and em[-1][0].decoded != [1, 1]:
        em.pop()
        tail += 1
    mine = [frame_md5(fr) for fr, _n, _h in em]
    jm = None
    if em:
        fr0 = em[0][0]
        jm = jm_order(stream, fr0.Y.size * 3 // 2)
    return {"n": len(model), "model_eq_spec": model == spec, "split": split,
            "model_eq_ffmpeg": mine == ff, "n_ffmpeg": len(ff), "tail_unpaired": tail,
            "model_eq_jm": None if jm is None else ([frame_md5(fr) for fr, _n, _h in d.emitted] == jm),
            "n_jm": None if jm is None else len(jm), "counts": dict(d.out_cnt)}


def main(argv):
    bad = 0
    for s in argv:
        r = check(s)
        # the oracle: JM when it is there (it honours no_output_of_prior_pics_flag, ffmpeg
        # does not -- where they disagree, JM's C.4.4 is the spec's); else ffmpeg
        oracle = r["model_eq_jm"] if r["model_eq_jm"] is not None else r["model_eq_ffmpeg"]
        ok = r["model_eq_spec"] and r["split"] == 0 and oracle
        bad += not ok
        print("%s %-36s %d stores: model==spec %s, splits %d, model==JM %s (%s), model==ffmpeg %s (%d; %d "
              "trailing unpaired dropped by ffmpeg), %s" % (
                  "PASS" if ok else "FAIL", os.path.basename(s)[:36], r["n"], r["model_eq_spec"], r["split"],
                  r["model_eq_jm"], r["n_jm"], r["model_eq_ffmpeg"], r["n_ffmpeg"], r["tail_unpaired"],
                  r["counts"]))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
