#!/usr/bin/env python3
"""Fixtures for bench/h264/mc_interp_tb.sv and bench/h264/wpred_tb.sv (the gate of
bench/h264/run_mc.sh; docs/h264_recon.md S2.4).

mc_interp (--out-mc): windows in, prediction samples out, the golden from
tools/h264_recon_ref.py's mc_luma / mc_chroma (imported; the model proven pixel-exact vs
ffmpeg). Random reference planes (numpy), every partition size (luma {4,8,16}^2, chroma
the same halved), every fractional position (16 luma, 64 chroma), random integer
positions INCLUDING ones off the picture edges (the window is ref_window's clamped gather,
exactly as mc_luma / mc_chroma build theirs: luma rows yi-2.., cols xi-2.., (w+5) x
(h+5) -- the model over-fetches w+6 x h+6 and its extra row / column are never read;
chroma (w+1) x (h+1) from (xi, yi)), --seeds planes per (size, position); per position
the extreme fills (all 0, all 255, binary noise, a checkerboard) at one size; and for the
positions that use the centre j (f, i, j, k, q) a few 16x16 windows chosen so that some
j1 is exactly 512 mod 1024 (the (j1 + 512) >> 10 rounding's edge, which random data hits
once in a thousand samples). Cases are sorted (plane, fy, fx, w, h) so a mutation's first
failure names the earliest position class that can see it.

wpred (--out-wp): a / b streams in, weighted samples out, the golden from wp_formula()
below -- 8.4.2.3.1 / 8.4.2.3.2 / 8.4.3 transcribed from the spec text, NOT from the
model. Random legal parameters per class: default single / bi; explicit single logWD 0..7
(w, o in -128..127); explicit bi logWD 0..7 with -128 <= w0 + w1 <= (logWD == 7 ? 127 :
128), first with both offsets zero ("oz") then with random offsets (so a rounding defect
in the offsets is caught by the class that has offsets); implicit ("I": logWD 5, offsets
0, w1 in -64..128 and w0 = 64 - w1, including both corners). Extreme fills per class.
With --clip, an Annex-B stream is decoded through the model with SliceDecoder.weighted
monkeypatched to record every (inputs, output) triple; every recorded output must equal
wp_formula's (the cross-check of the transcription against the model), the triples are
then kept as cases (capped per class) and the coverage table printed.

Files (bench/h264/README.md conventions, one hex word per line, $readmemh):
  <mc>.case.hex  32-bit per case: {h[7:0], is_chroma[7:0], frac_x[3:0], frac_y[3:0], w[7:0]}
  <mc>.win.hex   the window bytes, row-major, (w+5)(h+5) luma / (w+1)(h+1) chroma per case
  <mc>.exp.hex   w*h samples in raster order per case
  <mc>.meta.hex  [0] n_cases [1] n_win [2] n_exp [3] seed
  <wp>.case.hex  3 words per case: {mode[3:0], bi[3:0], logwd[3:0], src[3:0] (0 D 1 E 2 I),
                 clip[3:0], n[11:0]}, {w0[15:0], w1[15:0]}, {o0[15:0], o1[15:0]} (two's
                 complement)
  <wp>.a.hex / <wp>.b.hex   n bytes per case (b is random poison for a single-list case)
  <wp>.exp.hex   n samples per case
  <wp>.meta.hex  [0] n_cases [1] n_samples [2] seed [3] n_clip_cases

    mc_golden.py --out-mc bench/h264/fixtures/gen/mc_interp --out-wp bench/h264/fixtures/gen/wpred \\
                 --seeds 6 --clip .sim/mc_x264.264
"""
import argparse
import os
import random
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import h264_recon_ref as R  # noqa: E402

LUMA_SIZES = [(w, h) for h in (4, 8, 16) for w in (4, 8, 16)]
CHROMA_SIZES = [(w // 2, h // 2) for (w, h) in LUMA_SIZES]
J_POSITIONS = ((2, 1), (1, 2), (2, 2), (3, 2), (2, 3))      # f i j k q: the ones through j


# ---------------------------------------------------------------- mc_interp

def mc_class(is_chroma, fx, fy, w, h):
    return "%s%dx%d fx%dfy%d" % ("C" if is_chroma else "L", w, h, fx, fy)


def luma_case(plane, x, y, w, h, mvx, mvy):
    """The window as mc_luma builds it (cropped to what the unit reads) and its output."""
    xi, yi = x + (mvx >> 2), y + (mvy >> 2)
    win = R.ref_window(plane, xi - 2, yi - 2, w + 5, h + 5)
    out = R.mc_luma(plane, x, y, w, h, mvx, mvy)
    return (0, mvx & 3, mvy & 3, w, h, [int(v) for v in win.reshape(-1)], [int(v) for v in out.reshape(-1)])


def chroma_case(plane, x, y, w, h, mvx, mvy):
    xi, yi = x + (mvx >> 3), y + (mvy >> 3)
    win = R.ref_window(plane, xi, yi, w + 1, h + 1)
    out = R.mc_chroma(plane, x, y, w, h, mvx, mvy)
    return (1, mvx & 7, mvy & 7, w, h, [int(v) for v in win.reshape(-1)], [int(v) for v in out.reshape(-1)])


def random_plane(rnd, chroma):
    W = rnd.randrange(20, 64) if not chroma else rnd.randrange(10, 32)
    H = rnd.randrange(16, 48) if not chroma else rnd.randrange(8, 24)
    g = np.random.RandomState(rnd.randrange(1 << 30))
    return g.randint(0, 256, size=(H, W)).astype(np.int32)


def random_pos(rnd, plane, w, h, chroma):
    """An integer position anywhere from well outside the left/top edge to well past the
    right/bottom one: whole windows off the picture, straddling an edge, or inside."""
    H, W = plane.shape
    x = rnd.randrange(-(w + 8), W + 8)
    y = rnd.randrange(-(h + 8), H + 8)
    # the vector carries a random integer part so the (mv >> 2) path is the model's own
    d = 3 if chroma else 2
    dx, dy = rnd.randrange(-6, 7), rnd.randrange(-6, 7)
    return x - dx, y - dy, dx << d, dy << d


def fill_window(name, cols, rows, rnd):
    if name == "zero":
        return np.zeros((rows, cols), dtype=np.int32)
    if name == "full":
        return np.full((rows, cols), 255, dtype=np.int32)
    if name == "checker":
        return np.fromfunction(lambda y, x: 255 * ((x + y) % 2), (rows, cols), dtype=np.int64).astype(np.int32)
    g = np.random.RandomState(rnd.randrange(1 << 30))
    return (255 * g.randint(0, 2, size=(rows, cols))).astype(np.int32)


def j1_of(win, w, h):
    """The centre intermediate j1 of every output sample of a (w+5) x (h+5) luma window
    (8-245: the horizontal 6-tap b1 of each row, then the vertical 6-tap of those); used
    only to SELECT sentinel windows, the golden still comes from mc_luma."""
    win = win.astype(np.int64)
    b1 = R.tap6(win[:, 0:w], win[:, 1:w + 1], win[:, 2:w + 2], win[:, 3:w + 3], win[:, 4:w + 4], win[:, 5:w + 5])
    return R.tap6(b1[0:h], b1[1:h + 1], b1[2:h + 2], b1[3:h + 3], b1[4:h + 4], b1[5:h + 5])


def mc_cases(rnd, seeds):
    cases = []
    for chroma, sizes, nf in ((0, LUMA_SIZES, 4), (1, CHROMA_SIZES, 8)):
        for fy in range(nf):
            for fx in range(nf):
                for (w, h) in sizes:
                    for _ in range(seeds):
                        plane = random_plane(rnd, chroma)
                        x, y, mvx, mvy = random_pos(rnd, plane, w, h, chroma)
                        cases.append((chroma_case if chroma else luma_case)(plane, x, y, w, h, mvx | fx, mvy | fy))
                # the extreme fills, as a plane exactly the window's size
                fw, fh = (8, 8) if not chroma else (4, 4)
                for name in ("zero", "full", "binary", "checker"):
                    plane = fill_window(name, fw + (5 if not chroma else 1), fh + (5 if not chroma else 1), rnd)
                    if chroma:
                        cases.append(chroma_case(plane, 0, 0, fw, fh, fx, fy))
                    else:
                        cases.append(luma_case(plane, 2, 2, fw, fh, fx, fy))
    # sentinel windows for the centre rounding
    n_sent = 0
    for (fx, fy) in J_POSITIONS:
        found = 0
        tries = 0
        while found < 2 and tries < 400:
            tries += 1
            plane = np.random.RandomState(rnd.randrange(1 << 30)).randint(0, 256, size=(40, 40)).astype(np.int32)
            x, y = rnd.randrange(0, 40 - 21), rnd.randrange(0, 40 - 21)
            win = R.ref_window(plane, x, y, 21, 21)
            if np.any((j1_of(win, 16, 16) % 1024) == 512):
                cases.append(luma_case(plane, x + 2, y + 2, 16, 16, fx, fy))
                found += 1
        n_sent += found
    if n_sent < 2 * len(J_POSITIONS):
        raise SystemExit("mc: only %d j-rounding sentinel windows found" % n_sent)
    cases.sort(key=lambda c: (c[0], c[2], c[1], c[3], c[4]))
    # (hd_raster, 2026-10-04) set-reuse triples, appended after the sort: a luma item, a 4-read
    # chroma item (2x2, integer) and a luma item of another position class. With items overlapped
    # (+ovl) the third item's parameters go into the first item's set while the first item's last
    # reads are still in the stages: only the unit's guard (set_used) keeps them apart. Since S7
    # takes its parameters registered from t6, the window is a stage shorter and the sorted list
    # never hit it (M15 survived)
    for fy in range(4):
        for fx in range(4):
            for (wa, ha, chroma_b) in ((8, 8, 0), (4, 4, 0)):
                plane = random_plane(rnd, 0)
                x, y, mvx, mvy = random_pos(rnd, plane, wa, ha, 0)
                cases.append(luma_case(plane, x, y, wa, ha, mvx | fx, mvy | fy))
                plane = random_plane(rnd, 1)
                x, y, mvx, mvy = random_pos(rnd, plane, 2, 2, 1)
                cases.append(chroma_case(plane, x, y, 2, 2, mvx & ~7, mvy & ~7))
                plane = random_plane(rnd, 0)
                x, y, mvx, mvy = random_pos(rnd, plane, 4, 4, 0)
                cases.append(luma_case(plane, x, y, 4, 4, mvx | ((fx + 1) % 4), mvy | ((fy + 2) % 4)))
    return cases


def write_mc(stem, cases, seed):
    n_win = n_exp = 0
    with open(stem + ".case.hex", "w") as fc, open(stem + ".win.hex", "w") as fw, open(stem + ".exp.hex", "w") as fe:
        for chroma, fx, fy, w, h, win, out in cases:
            cols, rows = (w + 1, h + 1) if chroma else (w + 5, h + 5)
            assert len(win) == cols * rows and len(out) == w * h
            fc.write("%02x%02x%01x%01x%02x\n" % (h, chroma, fx, fy, w))
            fw.write("".join("%02x\n" % v for v in win))
            fe.write("".join("%02x\n" % v for v in out))
            n_win += len(win)
            n_exp += len(out)
    with open(stem + ".meta.hex", "w") as f:
        for v in (len(cases), n_win, n_exp, seed):
            f.write("%08x\n" % v)
    return n_win, n_exp


# ---------------------------------------------------------------- wpred

def clip1(v):
    return 0 if v < 0 else 255 if v > 255 else v


def clip3(lo, hi, v):
    return lo if v < lo else hi if v > hi else v


def cdiv(a, b):
    """The spec's "/": integer division with truncation toward zero."""
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b >= 0) else -q


def wp_formula(mode, bi, logwd, w0, w1, o0, o1, a, b):
    """8.4.2.3 transcribed from the spec text. ">>" is the arithmetic shift (Python's on
    ints), Clip1 the 8-bit clip."""
    if mode == 0:                                                   # 8.4.2.3.1 default
        if bi:
            return [(x + y + 1) >> 1 for x, y in zip(a, b)]
        return list(a)
    if bi:                                                          # 8.4.2.3.2 bi
        return [clip1(((x * w0 + y * w1 + (1 << logwd)) >> (logwd + 1)) + ((o0 + o1 + 1) >> 1))
                for x, y in zip(a, b)]
    if logwd >= 1:                                                  # 8.4.2.3.2 single
        return [clip1(((x * w0 + (1 << (logwd - 1))) >> logwd) + o0) for x in a]
    return [clip1(x * w0 + o0) for x in a]


def implicit_weights(cur_poc, pic0, pic1):
    """8.4.3: the implicit weights from the POC distances (currPicOrField, pic0, pic1)."""
    poc0, poc1 = pic0.poc(), pic1.poc()
    if poc1 - poc0 == 0 or pic0.marking() == R.LONG or pic1.marking() == R.LONG:
        return 32, 32
    tb = clip3(-128, 127, cur_poc - poc0)
    td = clip3(-128, 127, poc1 - poc0)
    tx = cdiv(16384 + abs(cdiv(td, 2)), td)
    dsf = clip3(-1024, 1023, (tb * tx + 32) >> 6)
    if (dsf >> 2) < -64 or (dsf >> 2) > 128:
        return 32, 32
    return 64 - (dsf >> 2), dsf >> 2


def wp_class(src, bi, logwd, o0, o1, clip):
    s = "%s/%s" % (src, "bi" if bi else "single")
    if src != "D":
        s += " lw%d" % logwd
        if bi and o0 == 0 and o1 == 0:
            s += " oz"
    if clip:
        s += " clip"
    return s


SIZES_N = (4, 8, 16, 32, 64, 128, 256)
SRC_ORDER = {"D": 0, "E": 1, "I": 2}


def wp_case(rnd, src, mode, bi, logwd, w0, w1, o0, o1, n, a=None, b=None, clip=False):
    if a is None:
        a = [rnd.randrange(256) for _ in range(n)]
    if b is None:
        b = [rnd.randrange(256) for _ in range(n)]
    out = wp_formula(mode, bi, logwd, w0, w1, o0, o1, a, b)
    return (src, mode, bi, logwd, w0, w1, o0, o1, n, a, b, out, clip)


def bi_weights(rnd, logwd):
    """w0, w1 in -128..127 with -128 <= w0 + w1 <= (logWD == 7 ? 127 : 128) (7.4.3.2)."""
    hi = 127 if logwd == 7 else 128
    while True:
        w0, w1 = rnd.randrange(-128, 128), rnd.randrange(-128, 128)
        if -128 <= w0 + w1 <= hi:
            return w0, w1


def wp_cases(rnd, seeds):
    cases = []
    fills = ((0, 0), (255, 255), (0, 255), (255, 0))
    ext_w = (127, -128, 1, 0)
    ext_o = (127, -128, 0)
    for _ in range(seeds):
        n = rnd.choice(SIZES_N)
        cases.append(wp_case(rnd, "D", 0, 0, 0, 0, 0, 0, 0, n))
        cases.append(wp_case(rnd, "D", 0, 1, 0, 0, 0, 0, 0, n))
    for lw in range(8):
        for _ in range(seeds):
            n = rnd.choice(SIZES_N)
            cases.append(wp_case(rnd, "E", 1, 0, lw, rnd.randrange(-128, 128), 0, rnd.randrange(-128, 128), 0, n))
            w0, w1 = bi_weights(rnd, lw)
            cases.append(wp_case(rnd, "E", 1, 1, lw, w0, w1, 0, 0, n))
            w0, w1 = bi_weights(rnd, lw)
            cases.append(wp_case(rnd, "E", 1, 1, lw, w0, w1, rnd.randrange(-128, 128), rnd.randrange(-128, 128), n))
        # the extremes: constant streams against the extreme weights and offsets (the bi
        # pairs at the edges of 7.4.3.2's sum constraint)
        bi_pairs = ((127, -128), (-128, 127), (127, 0 if lw == 7 else 1), (-128, 0), (0, 0), (64, 63 if lw == 7 else 64))
        for (fa, fb) in fills:
            for w in ext_w:
                for o in ext_o:
                    cases.append(wp_case(rnd, "E", 1, 0, lw, w, 0, o, 0, 4, [fa] * 4, [fb] * 4))
            for (w0, w1) in bi_pairs:
                for (o0, o1) in ((0, 0), (127, 127), (-128, -128), (127, -128), (-128, 127)):
                    cases.append(wp_case(rnd, "E", 1, 1, lw, w0, w1, o0, o1, 4, [fa] * 4, [fb] * 4))
    # implicit: logWD 5, offsets 0, w1 in -64..128 with w0 = 64 - w1
    for w1 in (128, -64, 32, 64, 0):
        cases.append(wp_case(rnd, "I", 1, 1, 5, 64 - w1, w1, 0, 0, 16))
        for (fa, fb) in fills:
            cases.append(wp_case(rnd, "I", 1, 1, 5, 64 - w1, w1, 0, 0, 4, [fa] * 4, [fb] * 4))
    for _ in range(seeds):
        w1 = rnd.randrange(-64, 129)
        cases.append(wp_case(rnd, "I", 1, 1, 5, 64 - w1, w1, 0, 0, rnd.choice(SIZES_N)))
    return cases


def wp_clip_cases(rnd, path, cap):
    """Decode a stream through the model with SliceDecoder.weighted recording every call:
    (mode, bi, logWD, weights, offsets, a, b) per plane and the model's output. Every
    output must reproduce from wp_formula -- the transcription checked against the model
    (itself proven against ffmpeg)."""
    recorded = []
    orig = R.SliceDecoder.weighted

    def wrapped(self, preds, info, blk):
        out = orig(self, preds, info, blk)
        h, pps, pic = self.h, self.pps, self.pic
        p0, p1 = preds
        both = p0 is not None and p1 is not None
        implicit = pps.weighted_bipred_idc == 2 and h.slice_type == R.B and both
        explicit = ((pps.weighted_bipred_idc == 1 and h.slice_type == R.B)
                    or (pps.weighted_pred and h.slice_type == R.P and p0 is not None))
        for k in range(3):
            a = [int(v) for v in (p0 if p0 is not None else p1)[k].reshape(-1)]
            b = [int(v) for v in p1[k].reshape(-1)] if both else None
            o = [int(v) for v in out[k].reshape(-1)]
            if implicit:
                w0, w1 = implicit_weights(pic.poc, p0[4], p1[4])
                recorded.append(("I", 1, 1, 5, w0, w1, 0, 0, a, b, o))
            elif explicit:
                logwd = h.luma_log2_wd if k == 0 else h.chroma_log2_wd
                wts = []
                for lx, p in ((0, p0), (1, p1)):
                    if p is None:
                        wts.append((0, 0))
                        continue
                    wt = h.weights[lx][p[3]]
                    wts.append((wt[0], wt[1]) if k == 0 else tuple(wt[2][k - 1]))
                if p0 is None:
                    wts = [wts[1], (0, 0)]
                recorded.append(("E", 1, int(both), logwd, wts[0][0], wts[1][0], wts[0][1], wts[1][1], a, b, o))
            else:
                recorded.append(("D", 0, int(both), 0, 0, 0, 0, 0, a, b, o))
        return out

    R.SliceDecoder.weighted = wrapped
    try:
        R.decode_file(path)
    finally:
        R.SliceDecoder.weighted = orig

    by_class = {}
    n_chk = 0
    for src, mode, bi, logwd, w0, w1, o0, o1, a, b, o in recorded:
        if len(a) > 256 or (bi and len(b) != len(a)):
            raise SystemExit("clip: a recorded call of %d samples" % len(a))
        if not (-128 <= w0 <= 128 and -128 <= w1 <= 128 and -128 <= o0 <= 127 and -128 <= o1 <= 127):
            raise SystemExit("clip: weights out of range: %d %d %d %d" % (w0, w1, o0, o1))
        chk = wp_formula(mode, bi, logwd, w0, w1, o0, o1, a, b if bi else [0] * len(a))
        if chk != o:
            raise SystemExit("clip: a recorded %s call (bi %d logWD %d w %d %d o %d %d) does not reproduce from the "
                             "spec transcription" % (src, bi, logwd, w0, w1, o0, o1))
        n_chk += 1
        bb = b if bi else [rnd.randrange(256) for _ in range(len(a))]
        by_class.setdefault(wp_class(src, bi, logwd, o0, o1, True), []).append(
            (src, mode, bi, logwd, w0, w1, o0, o1, len(a), a, bb, o, True))
    print("clip %s: %d weighted calls recorded, every one reproduced by the spec transcription" % (
        os.path.basename(path), n_chk))
    print("  %-22s %8s %6s" % ("class", "recorded", "kept"))
    cases = []
    for key in sorted(by_class, key=lambda k: (SRC_ORDER[k[0]], k)):
        lst = by_class[key]
        keep = lst if len(lst) <= cap else rnd.sample(lst, cap)
        cases.extend(keep)
        print("  %-22s %8d %6d" % (key, len(lst), len(keep)))
    return cases


def write_wp(stem, cases, seed, n_clip):
    n_s = 0
    with open(stem + ".case.hex", "w") as fc, open(stem + ".a.hex", "w") as fa, \
            open(stem + ".b.hex", "w") as fb, open(stem + ".exp.hex", "w") as fe:
        for src, mode, bi, logwd, w0, w1, o0, o1, n, a, b, out, clip in cases:
            assert 1 <= n <= 256 and len(a) == n and len(b) == n and len(out) == n
            fc.write("%01x%01x%01x%01x%01x%03x\n" % (mode, bi, logwd, SRC_ORDER[src], int(clip), n))
            fc.write("%04x%04x\n" % (w0 & 0xffff, w1 & 0xffff))
            fc.write("%04x%04x\n" % (o0 & 0xffff, o1 & 0xffff))
            fa.write("".join("%02x\n" % v for v in a))
            fb.write("".join("%02x\n" % v for v in b))
            fe.write("".join("%02x\n" % v for v in out))
            n_s += n
    with open(stem + ".meta.hex", "w") as f:
        for v in (len(cases), n_s, seed, n_clip):
            f.write("%08x\n" % v)
    return n_s


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out-mc", help="fixture stem for mc_interp")
    ap.add_argument("--out-wp", help="fixture stem for wpred")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--seeds", type=int, default=6, help="random cases per class")
    ap.add_argument("--clip", help="an Annex-B stream decoded through the model, its weighted calls recorded")
    ap.add_argument("--clip-cap", type=int, default=40, help="recorded wpred cases kept per class")
    a = ap.parse_args(argv)
    rnd = random.Random(a.seed)
    if a.out_mc:
        cases = mc_cases(rnd, a.seeds)
        os.makedirs(os.path.dirname(a.out_mc) or ".", exist_ok=True)
        n_win, n_exp = write_mc(a.out_mc, cases, a.seed)
        n_l = sum(1 for c in cases if c[0] == 0)
        print("%s: %d cases (%d luma, %d chroma), %d window bytes, %d samples" % (
            a.out_mc, len(cases), n_l, len(cases) - n_l, n_win, n_exp))
    if a.out_wp:
        cases = wp_cases(rnd, a.seeds)
        n_clip = 0
        if a.clip:
            cc = wp_clip_cases(rnd, a.clip, a.clip_cap)
            n_clip = len(cc)
            cases.extend(cc)
        cases.sort(key=lambda c: (SRC_ORDER[c[0]], c[2], c[3], not (c[6] == 0 and c[7] == 0), c[12]))
        os.makedirs(os.path.dirname(a.out_wp) or ".", exist_ok=True)
        n_s = write_wp(a.out_wp, cases, a.seed, n_clip)
        per = {}
        for c in cases:
            k = wp_class(c[0], c[2], c[3], c[6], c[7], c[12])
            per[k] = per.get(k, 0) + 1
        print("%s: %d cases (%d from the clip), %d samples; per class: %s" % (
            a.out_wp, len(cases), n_clip, n_s, " ".join("%s=%d" % (k.replace(" ", "_"), n) for k, n in sorted(per.items()))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
