#!/usr/bin/env python3
"""Fixtures for bench/h264/recon_top_tb.sv: a stream's syntax-element words (what
h264/dec/h264_top emits: tools/h264_top_golden.py) and, per picture in decode order, the
model's pre-deblock and post-deblock samples (tools/h264_recon_ref.py, pixel-exact vs
ffmpeg and the H.264.1 YUVs) as the 64-bit words the DPB holds (docs/h264_recon.md S2.2:
8 samples a word, byte 0 the leftmost).

Files (one hex word per line, $readmemh):
  <stem>.se.hex    48-bit SE words {kind, aux, val}
  <stem>.pic.hex   per picture 4 words: [0] struct (0 F, 1 T, 2 B) [1] PicWidthInMbs
                   [2] the picture's height in macroblocks (a field's own) [3] word offset
                   of the picture in .pre.hex / .post.hex
  <stem>.pre.hex / .post.hex   64-bit words: per picture luma rows (16 H rows of 2 W
                   words), then Cb rows (8 H of W), then Cr
  <stem>.meta.hex  [0] SE words [1] pictures [2] pre/post words [3] macroblocks
                   [4] stores emitted to the display (P5d)
  <stem>.out.hex   P5d, the output process: per store emitted, in order,
                   {step[31:20], frame[19], dec_b[18], dec_t[17], unpaired[16], picture[15:0]} --
                   step = the pictures opened when it is emitted (mod 4096: WHEN, which the
                   order alone cannot show -- a DPB-size error changes the timing, not the order);
                   picture = the decode index of the store's FIRST picture (the RTL's store
                   numbers are its own; the bench maps them through pic_start)
The SE words end with K_EOS_WORD: the flush emits everything still waiting.

    recon_top_golden.py stream.264 --out bench/h264/fixtures/gen/rtop_x [--max-pics N]
"""
import argparse
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import h264_fe_ref as FE  # noqa: E402
import h264_recon_ref as RR  # noqa: E402
import h264_top_golden as TG  # noqa: E402


def words64(plane):
    """a 2-D uint8 plane -> 64-bit words, row-major, 8 samples a word (byte 0 = leftmost)"""
    h, w = plane.shape
    b = np.ascontiguousarray(plane.astype(np.uint8)).reshape(h, w // 8, 8)
    out = np.zeros((h, w // 8), dtype=np.uint64)
    for i in range(8):
        out |= b[:, :, i].astype(np.uint64) << np.uint64(8 * i)
    return out.reshape(-1)


def truncate_es(data, max_pics):
    """The Annex-B bytes up to (not including) the slice NAL that opens picture
    max_pics + 1 -- one picture beyond what build() keeps, so its cut still finds the
    boundary. A picture opens at a slice (nal_unit_type 1 or 5) whose first_mb_in_slice
    is 0: ue(v) 0 is a single '1' bit, so the first payload byte's top bit. Decoding the
    whole of a conformance stream to keep four pictures took the model ~40 minutes."""
    n_pic = 0
    i = 0
    while True:
        j = data.find(b"\x00\x00\x01", i)
        if j < 0 or j + 4 >= len(data):
            return data
        t = data[j + 3] & 0x1F
        if t in (1, 5) and (data[j + 4] & 0x80):
            n_pic += 1
            if n_pic == max_pics + 2:
                k = j - 1 if j > 0 and data[j - 1] == 0 else j     # a 4-byte start code
                return data[:k]
        i = j + 3


def build(data, max_pics=None):
    pics = []
    frame_of = []                                 # per picture: its frame (store) id

    def hook(pic, pre):
        pics.append((pic.struct, pic.w, pic.hgt, [p.copy() for p in pre], [pic.Y.copy(), pic.Cb.copy(), pic.Cr.copy()]))
        frame_of.append(pic.frame.id)
    rec = FE.decode_stream(data, resolved_scaling=True)
    # the records of the first max_pics pictures (cut at the NAL record that opens the next)
    cut_rec = len(rec)
    if max_pics is not None:
        n_pic, last_n = 0, 0
        for i, r in enumerate(rec):
            if r[0] == "N":
                last_n = i
            if r == "S first_mb_in_slice 0":
                if n_pic == max_pics:
                    cut_rec = last_n
                    break
                n_pic += 1
    dec = RR.Decoder(on_picture=hook)
    dec.feed(rec[:cut_rec])
    dec.flush_output()                            # the end of stream (the EOS word below)
    COV.clear(); COV.update(dec.cov)             # the model's path counters (printed by main)
    out = []
    for fr, n, _how in dec.emitted:
        idx = frame_of.index(fr.id)
        unpaired = int(not fr.coded_as_frame and fr.decoded != [1, 1])
        out.append(((n & 0xFFF) << 20) | (fr.coded_as_frame << 19) | (fr.decoded[1] << 18) | (fr.decoded[0] << 17) |
                   (unpaired << 16) | idx)
    words = TG.words(rec)
    n_mbs = 0
    if max_pics is not None and len(pics) >= max_pics:
        # cut the SE words at the NAL word that opens picture max_pics (the first slice
        # with first_mb_in_slice 0 after max_pics pictures)
        n_pic = 0
        cut = len(words)
        last_nal = 0
        for i, (k, aux, val) in enumerate(words):
            if k == 17:
                last_nal = i
            if k == 18 and aux == TG.FIELD_ID["first_mb_in_slice"] and val == 0:
                if n_pic == max_pics:
                    cut = last_nal
                    break
                n_pic += 1
        words = words[:cut]
        pics = pics[:max_pics]
    words = words + [(TG.K_EOS, 0, 0)]
    n_mbs = sum(1 for w in words if w[0] == 1)
    return words, pics, n_mbs, out


COV = {}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("stream", nargs="?")
    ap.add_argument("--out", required=True)
    ap.add_argument("--max-pics", type=int)
    a = ap.parse_args(argv)
    if not a.stream:
        ap.error("a stream")
    data = open(a.stream, "rb").read()
    if a.max_pics is not None:
        data = truncate_es(data, a.max_pics)
    words, pics, n_mbs, out = build(data, a.max_pics)
    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    with open(a.out + ".se.hex", "w") as f:
        for kind, aux, val in words:
            f.write("%02x%02x%08x\n" % (kind, aux, val & 0xFFFFFFFF))
    off = 0
    with open(a.out + ".pic.hex", "w") as fp, open(a.out + ".pre.hex", "w") as fpre, open(a.out + ".post.hex", "w") as fpost:
        for struct, w, h, pre, post in pics:
            fp.write("%08x\n%08x\n%08x\n%08x\n" % ({"F": 0, "T": 1, "B": 2}[struct], w, h, off))
            for planes, f in ((pre, fpre), (post, fpost)):
                for pl in planes:
                    f.write("".join("%016x\n" % int(v) for v in words64(pl)))
            off += (16 * h * 2 * w) + 2 * (8 * h * w)
    with open(a.out + ".out.hex", "w") as f:
        f.write("".join("%08x\n" % v for v in out) or "00000000\n")
    with open(a.out + ".meta.hex", "w") as f:
        f.write("%08x\n%08x\n%08x\n%08x\n%08x\n" % (len(words), len(pics), off, n_mbs, len(out)))
    print("%s: %d SE words, %d pictures, %d macroblocks, %d sample words, %d stores emitted" % (
        a.out, len(words), len(pics), n_mbs, off, len(out)))
    # the model's path counters: the runner requires a fixture to reach the paths it is for
    print("coverage: " + " ".join("%s=%d" % (k, v) for k, v in sorted(COV.items()) if v))
    return 0


if __name__ == "__main__":
    sys.exit(main())
