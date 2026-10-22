#!/usr/bin/env python3
"""Fixtures for bench/h264/deblock_filter_tb.sv and deblock_bs_tb.sv from the
reconstruction model tools/h264_recon_ref.py (docs/h264_recon.md S2.4): the edge filter
kernel (filter_line, 8.7.2.2-8.7.2.4) and the boundary strength (boundary_strength,
8.7.2.1). Every expected value comes from the model; the generator only CHOOSES the
inputs (directed classes at the thresholds, random ones, and lines recorded while the
model decodes a real x264 clip) and counts what they cover.

Files (one hex word per line, $readmemh):
  <out>/deblock_filter.in.hex   128-bit {cls[97:90], beta_off[89:85], alpha_off[84:80],
                                qp_q[79:74], qp_p[73:68], chroma[67], bs[66:64],
                                p3,p2,p1,p0,q0,q1,q2,q3 [63:0]} (offsets two's complement)
  <out>/deblock_filter.exp.hex  64-bit {changed[48], p2o,p1o,p0o,q0o,q1o,q2o [47:0]}
  <out>/deblock_filter.meta.hex [0] n cases
  <out>/deblock_bs.in.hex       192-bit {cls[178:171], field[170], vertical[169],
                                mb_edge[168], q block [167:84], p block [83:0]}, a block
                                = {intra, nz, pred0, pred1, refpic0[7:0], refpic1[7:0],
                                mv0x, mv0y, mv1x, mv1y (16-bit two's complement)}
  <out>/deblock_bs.exp.hex      4-bit bS
  <out>/deblock_bs.meta.hex     [0] n cases

Case classes (the bench names the class of every failing case; run_deblock.sh --red
requires each mutation to be caught in the class written for it):
  filter: alpha (|p0-q0| at alpha-1 / alpha for every indexA), beta (|p1-p0|, |q1-q0| at
          beta-1 / beta for every indexB), tc0 (luma bS 1..3, the delta clip binding, every
          indexA), tcc (chroma bS 1..3, the clip binding), p1 (luma weak with ap < beta and
          the p1 / q1 term beyond tC0), strong (luma bS 4 with |p0-q0| at (alpha>>2)+1 and
          +2), c4 (chroma bS 4), dclip (the delta at and beyond +-tC), idxclip (qPav +
          offset beyond 51 / below 0), pcm (an I_PCM side), rand, real (the clip)
  bs:     intra_mb (a macroblock edge with intra: frame / field x vertical / horizontal),
          intra_in (an internal edge with intra), flags (all 252 reachable combinations of
          intra / nz / pred0 / pred1 on both sides), nz (p only / q only / both), nvec (one
          vector against two), refset (the picture sets), mv1h / mv1v (one vector each,
          differences around the limits: 3, 4, 5 horizontally; 1, 2, 3, 4 vertically, frame
          and field), mv2d (two different pictures, paired by picture), mv2s (the same
          picture twice: straight / crossed), rand, real (the clip; frame-coded only --
          x264 has no PAFF, so every field case is directed)
The class index is the order above (F_CLS / B_CLS); the benches name the class of a
failing case and take +only=<class> to score one class alone (run_deblock.sh --red).

    deblock_golden.py --out bench/h264/fixtures/gen [--clip .sim/deblock_x264.264] [--seed N]
"""
import argparse
import os
import random
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import h264_recon_ref as RR  # noqa: E402

F_CLS = ["alpha", "beta", "tc0", "tcc", "p1", "strong", "c4", "dclip", "idxclip", "pcm", "rand", "real"]
B_CLS = ["intra_mb", "intra_in", "flags", "nz", "nvec", "refset", "mv1h", "mv1v", "mv2d", "mv2s", "rand", "real"]
OFFSETS = list(range(-12, 13, 2))


# ---------------------------------------------------------------- the filter

def mb(qp, pcm=0):
    m = RR.MbInfo()
    m.qp = qp
    m.qpc = (qp, qp)
    m.pcm = pcm
    return m


def resolve_qp(m, chroma):
    """what the caller hands the RTL (the model's own rule in filter_line)"""
    if chroma:
        return RR.QPC_TABLE[0] if m.pcm else m.qpc[chroma - 1]
    return 0 if m.pcm else m.qp


def thresholds(qp_p, qp_q, aoff, boff):
    qpav = (qp_p + qp_q + 1) >> 1
    ia = RR.clip3(0, 51, qpav + aoff)
    ib = RR.clip3(0, 51, qpav + boff)
    return ia, ib, RR.ALPHA[ia], RR.BETA[ib]


def flag_on(s, alpha, beta):
    p3, p2, p1, p0, q0, q1, q2, q3 = s
    return abs(p0 - q0) < alpha and abs(p1 - p0) < beta and abs(q1 - q0) < beta


class FilterCases(object):
    def __init__(self, rng):
        self.rng = rng
        self.rows = []      # (cls, samples, bs, chroma, qp_p, qp_q, aoff, boff, out, changed)
        self.cov = {"on": 0, "off": 0, "ap_lt": 0, "ap_ge": 0, "aq_lt": 0, "aq_ge": 0,
                    "strong_close": 0, "strong_far": 0, "pcm": 0}
        self.cov_bs = {}
        self.idx_a_on = set()
        self.idx_b_on = set()
        self.aoffs = set()
        self.boffs = set()
        self.qp_p = set()
        self.qp_q = set()

    def add(self, cls, s, bs, chroma, pm, qm, aoff, boff):
        s = [int(v) for v in s]
        plane = np.zeros((1, 8), dtype=np.int32)
        plane[0, :] = s
        RR.filter_line(plane, 0, 4, True, bs, pm, qm, chroma, aoff, boff)
        out = [int(v) for v in plane[0, 1:7]]
        qp_p, qp_q = resolve_qp(pm, chroma), resolve_qp(qm, chroma)
        self.record(cls, s, bs, 1 if chroma else 0, qp_p, qp_q, aoff, boff, out, pm.pcm or qm.pcm)

    def record(self, cls, s, bs, chroma, qp_p, qp_q, aoff, boff, out, pcm):
        ia, ib, alpha, beta = thresholds(qp_p, qp_q, aoff, boff)
        on = bs != 0 and flag_on(s, alpha, beta)
        if not on:
            assert out == s[1:7], "the model changed a line whose filterSamplesFlag is 0"
        p3, p2, p1, p0, q0, q1, q2, q3 = s
        c = self.cov
        c["on" if on else "off"] += 1
        if on:
            self.idx_a_on.add(ia)
            self.idx_b_on.add(ib)
            if not chroma:
                c["ap_lt" if abs(p2 - p0) < beta else "ap_ge"] += 1
                c["aq_lt" if abs(q2 - q0) < beta else "aq_ge"] += 1
                if bs == 4:
                    c["strong_close" if abs(p0 - q0) < (alpha >> 2) + 2 else "strong_far"] += 1
        if pcm:
            c["pcm"] += 1
        k = (bs, chroma, on)
        self.cov_bs[k] = self.cov_bs.get(k, 0) + 1
        self.aoffs.add(aoff)
        self.boffs.add(boff)
        self.qp_p.add(qp_p)
        self.qp_q.add(qp_q)
        self.rows.append((cls, s, bs, chroma, qp_p, qp_q, aoff, boff, out, 1 if on else 0))

    # -- helpers to pick a qp pair / offsets giving a wanted index ------------------------
    def qp_for(self, qpav):
        k = self.rng.randint(0, min(qpav, 51 - qpav))
        qp_p = qpav - k
        qp_q = qpav + k - (1 if (k > 0 and self.rng.random() < 0.5) else 0)
        if self.rng.random() < 0.5:
            qp_p, qp_q = qp_q, qp_p
        assert (qp_p + qp_q + 1) >> 1 == qpav
        return qp_p, qp_q

    def index_a(self, ia, want_beta=True):
        """qp pair and offsets with indexA == ia (and indexB >= 16 when want_beta)"""
        while True:
            aoff = self.rng.choice(OFFSETS)
            qpav = ia - aoff
            if not 0 <= qpav <= 51:
                continue
            boff = self.rng.choice(OFFSETS)
            if want_beta and RR.clip3(0, 51, qpav + boff) < 16:
                continue
            qp_p, qp_q = self.qp_for(qpav)
            return qp_p, qp_q, aoff, boff

    def index_b(self, ib):
        while True:
            boff = self.rng.choice(OFFSETS)
            qpav = ib - boff
            if not 0 <= qpav <= 51:
                continue
            aoff = self.rng.choice(OFFSETS)
            if RR.clip3(0, 51, qpav + aoff) < 16:
                continue
            qp_p, qp_q = self.qp_for(qpav)
            return qp_p, qp_q, aoff, boff

    def smooth(self, base, spread):
        r = self.rng
        return [RR.clip3(0, 255, base + r.randint(-spread, spread)) for _ in range(8)]

    def gen_directed(self):
        r = self.rng
        # alpha: |p0-q0| = alpha-1 (on) and alpha (off) for every indexA, bS 1..4, luma/chroma
        for ia in range(52):
            for bs in (1, 2, 3, 4):
                for chroma in (0, 1):
                    qp_p, qp_q, aoff, boff = self.index_a(ia)
                    _, _, alpha, beta = thresholds(qp_p, qp_q, aoff, boff)
                    for d in (alpha - 1, alpha):
                        if d < 0:
                            continue
                        p0 = r.randint(0, 255 - d)
                        q0 = p0 + d
                        if r.random() < 0.5:            # either sign of p0 - q0
                            p0, q0 = q0, p0
                        s = [RR.clip3(0, 255, p0 + r.randint(-(beta - 1 if beta else 0), (beta - 1 if beta else 0))) for _ in range(3)] \
                            + [p0, q0] + [RR.clip3(0, 255, q0 + r.randint(-(beta - 1 if beta else 0), (beta - 1 if beta else 0))) for _ in range(3)]
                        self.add("alpha", s, bs, chroma, mb(qp_p), mb(qp_q), aoff, boff)
        # beta: |p1-p0| and |q1-q0| at beta-1 / beta for every indexB
        for ib in range(52):
            for bs in (1, 2, 3, 4):
                for chroma in (0, 1):
                    qp_p, qp_q, aoff, boff = self.index_b(ib)
                    _, _, alpha, beta = thresholds(qp_p, qp_q, aoff, boff)
                    for side in ("p", "q"):
                        for d in (beta - 1, beta):
                            if d < 0:
                                continue
                            base = r.randint(0, 255)
                            s = self.smooth(base, max(0, min(beta - 1, alpha // 2 - 1)) // 2)
                            p0, q0 = s[3], s[4]
                            if abs(p0 - q0) >= alpha:
                                s[4] = q0 = RR.clip3(0, 255, p0 + r.randint(-(alpha - 1), alpha - 1))
                            sign = 1 if r.random() < 0.5 else -1
                            if side == "p":
                                s[2] = RR.clip3(0, 255, p0 + sign * d)
                                if abs(s[2] - p0) != d:
                                    s[2] = RR.clip3(0, 255, p0 - sign * d)
                                s[5] = RR.clip3(0, 255, q0 + r.randint(-(beta - 1 if beta else 0), (beta - 1 if beta else 0)))
                            else:
                                s[5] = RR.clip3(0, 255, q0 + sign * d)
                                if abs(s[5] - q0) != d:
                                    s[5] = RR.clip3(0, 255, q0 - sign * d)
                                s[2] = RR.clip3(0, 255, p0 + r.randint(-(beta - 1 if beta else 0), (beta - 1 if beta else 0)))
                            self.add("beta", s, bs, chroma, mb(qp_p), mb(qp_q), aoff, boff)
        # tc0: luma bS 1..3, every indexA >= 16, the clip binding (|delta| > tC), both signs,
        # ap / aq on both sides of beta
        for ia in range(16, 52):
            for bs in (1, 2, 3):
                for sign in (1, -1):
                    for ap_side in (0, 1):
                        qp_p, qp_q, aoff, boff = self.index_a(ia)
                        _, _, alpha, beta = thresholds(qp_p, qp_q, aoff, boff)
                        tc0 = RR.TC0[bs - 1][ia]
                        s = self.pick_weak(alpha, beta, tc0 + (2 if ap_side else 0), sign, ap_side)
                        if s is not None:
                            self.add("tc0", s, bs, 0, mb(qp_p), mb(qp_q), aoff, boff)
        # tcc: chroma bS 1..3, the clip binding at tC = tC0 + 1
        for ia in range(16, 52):
            for bs in (1, 2, 3):
                for sign in (1, -1):
                    qp_p, qp_q, aoff, boff = self.index_a(ia)
                    _, _, alpha, beta = thresholds(qp_p, qp_q, aoff, boff)
                    tc0 = RR.TC0[bs - 1][ia]
                    s = self.pick_weak(alpha, beta, tc0 + 1, sign, 0)
                    if s is not None:
                        self.add("tcc", s, bs, 1, mb(qp_p), mb(qp_q), aoff, boff)
        # p1: luma weak, ap < beta (tC > tC0) and the p1 term beyond tC0 (so it clips at tC0)
        n = 0
        tries = 0
        while n < 400 and tries < 200000:
            tries += 1
            ia = r.randint(20, 51)
            bs = r.randint(1, 3)
            qp_p, qp_q, aoff, boff = self.index_a(ia)
            _, _, alpha, beta = thresholds(qp_p, qp_q, aoff, boff)
            tc0 = RR.TC0[bs - 1][ia]
            p0 = r.randint(0, 255)
            d = r.randint(-(alpha - 1), alpha - 1)
            q0 = RR.clip3(0, 255, p0 + d)
            b = beta - 1
            p1 = RR.clip3(0, 255, p0 + r.randint(-b, b))
            q1 = RR.clip3(0, 255, q0 + r.randint(-b, b))
            p2 = RR.clip3(0, 255, p0 + r.randint(-b, b))
            q2 = RR.clip3(0, 255, q0 + r.randint(-b, b))
            s = [r.randint(0, 255), p2, p1, p0, q0, q1, q2, r.randint(0, 255)]
            if not flag_on(s, alpha, beta):
                continue
            t1p = (p2 + ((p0 + q0 + 1) >> 1) - (p1 << 1)) >> 1
            t1q = (q2 + ((p0 + q0 + 1) >> 1) - (q1 << 1)) >> 1
            ap_lt, aq_lt = abs(p2 - p0) < beta, abs(q2 - q0) < beta
            if (ap_lt and abs(t1p) > tc0) or (aq_lt and abs(t1q) > tc0):
                self.add("p1", s, bs, 0, mb(qp_p), mb(qp_q), aoff, boff)
                n += 1
        assert n == 400, "p1 class: could not find enough cases"
        # strong: luma bS 4, |p0-q0| == (alpha>>2)+1 (strong) and +2 (weak), ap < beta
        for ia in range(16, 52):
            for d_extra in (1, 2):
                for sign in (1, -1):
                    qp_p, qp_q, aoff, boff = self.index_a(ia)
                    _, _, alpha, beta = thresholds(qp_p, qp_q, aoff, boff)
                    d = (alpha >> 2) + d_extra
                    if d >= alpha:
                        continue
                    p0 = r.randint(d, 255 - d)
                    q0 = p0 + sign * d
                    b = beta - 1
                    s = [RR.clip3(0, 255, p0 + r.randint(-b, b)) for _ in range(3)] + [p0, q0] + \
                        [RR.clip3(0, 255, q0 + r.randint(-b, b)) for _ in range(3)]
                    self.add("strong", s, 4, 0, mb(qp_p), mb(qp_q), aoff, boff)
        # c4: chroma bS 4, on, with q1 != q0 and p1 != p0
        for ia in range(16, 52):
            for _ in range(4):
                qp_p, qp_q, aoff, boff = self.index_a(ia)
                _, _, alpha, beta = thresholds(qp_p, qp_q, aoff, boff)
                for _try in range(1000):
                    s = self.smooth(r.randint(0, 255), max(1, min(alpha, beta) - 1))
                    if flag_on(s, alpha, beta) and s[5] != s[4] and s[2] != s[3]:
                        break
                else:
                    continue
                self.add("c4", s, 4, 1, mb(qp_p), mb(qp_q), aoff, boff)
        # dclip: the raw delta at -tC-1, -tC, +tC, +tC+1 (and further), luma and chroma
        n = 0
        tries = 0
        want = {(-1, 0): 0, (-1, 1): 0, (1, 0): 0, (1, 1): 0}    # (sign, beyond?)
        while n < 600 and tries < 400000:
            tries += 1
            ia = r.randint(16, 51)
            bs = r.randint(1, 3)
            chroma = r.randint(0, 1)
            qp_p, qp_q, aoff, boff = self.index_a(ia)
            _, _, alpha, beta = thresholds(qp_p, qp_q, aoff, boff)
            s = self.smooth(r.randint(0, 255), max(1, min(alpha, beta) - 1))
            if not flag_on(s, alpha, beta):
                continue
            p3, p2, p1, p0, q0, q1, q2, q3 = s
            tc0 = RR.TC0[bs - 1][ia]
            tc = tc0 + 1 if chroma else tc0 + (abs(p2 - p0) < beta) + (abs(q2 - q0) < beta)
            d = (((q0 - p0) << 2) + (p1 - q1) + 4) >> 3
            if abs(d) < tc or tc == 0:
                continue
            key = (1 if d > 0 else -1, 1 if abs(d) > tc else 0)
            if d == 0 or want[key] >= 150:
                continue
            want[key] += 1
            self.add("dclip", s, bs, chroma, mb(qp_p), mb(qp_q), aoff, boff)
            n += 1
        assert n == 600, "dclip class: could not find enough cases %r" % want
        # idxclip: qPav + offset beyond 51 (both indices) and below 0
        for qpav in range(40, 52):
            for aoff in (2, 4, 6, 8, 10, 12):
                if qpav + aoff <= 51:
                    continue
                for bs in (1, 2, 3, 4):
                    for chroma in (0, 1):
                        qp_p, qp_q = self.qp_for(qpav)
                        boff = r.choice(OFFSETS)
                        s = self.smooth(r.randint(0, 255), 60)
                        self.add("idxclip", s, bs, chroma, mb(qp_p), mb(qp_q), aoff, boff)
                        boff = r.choice([b for b in OFFSETS if qpav + b > 51] or OFFSETS)
                        s = self.smooth(r.randint(0, 255), 6)
                        self.add("idxclip", s, bs, chroma, mb(qp_p), mb(qp_q), aoff, boff)
        for qpav in range(0, 12):
            for aoff in (-12, -10, -8, -6, -4, -2):
                if qpav + aoff >= 0:
                    continue
                qp_p, qp_q = self.qp_for(qpav)
                s = self.smooth(r.randint(0, 255), 2)
                self.add("idxclip", s, r.randint(1, 4), r.randint(0, 1), mb(qp_p), mb(qp_q), aoff, r.choice(OFFSETS))
        # pcm: an I_PCM side (the caller resolves its qp to 0), both ways and both sides
        for _ in range(300):
            which = r.randint(1, 3)
            pm = mb(r.randint(0, 51), pcm=which & 1)
            qm = mb(r.randint(0, 51), pcm=(which >> 1) & 1)
            aoff, boff = r.choice(OFFSETS), r.choice(OFFSETS)
            s = self.smooth(r.randint(0, 255), r.choice([1, 2, 4, 8]))
            self.add("pcm", s, r.randint(1, 4), r.randint(0, 1), pm, qm, aoff, boff)

    def pick_weak(self, alpha, beta, tc, sign, ap_lt_wanted):
        """samples with the flag on, ap / aq on the wanted side of beta, and a raw delta of
        the wanted sign beyond tc; None when alpha / beta allow none"""
        r = self.rng
        if alpha == 0 or beta == 0:
            return None
        for _ in range(4000):
            p0 = r.randint(0, 255)
            d = r.randint(1, alpha - 1) * sign
            q0 = p0 + d
            if not 0 <= q0 <= 255:
                continue
            b = beta - 1
            p1 = RR.clip3(0, 255, p0 + r.randint(-b, b))
            q1 = RR.clip3(0, 255, q0 + r.randint(-b, b))
            if ap_lt_wanted:
                p2 = RR.clip3(0, 255, p0 + r.randint(-b, b))
                q2 = RR.clip3(0, 255, q0 + r.randint(-b, b))
                if not (abs(p2 - p0) < beta and abs(q2 - q0) < beta):
                    continue
            else:
                p2 = RR.clip3(0, 255, p0 + r.choice([-1, 1]) * r.randint(beta, beta + 40))
                q2 = RR.clip3(0, 255, q0 + r.choice([-1, 1]) * r.randint(beta, beta + 40))
                if abs(p2 - p0) < beta or abs(q2 - q0) < beta:
                    continue
            s = [r.randint(0, 255), p2, p1, p0, q0, q1, q2, r.randint(0, 255)]
            if not flag_on(s, alpha, beta):
                continue
            delta = (((q0 - p0) << 2) + (p1 - q1) + 4) >> 3
            if delta * sign > tc:
                return s
        return None

    def gen_random(self, n):
        r = self.rng
        for i in range(n):
            kind = r.random()
            if kind < 0.3:
                s = [r.randint(0, 255) for _ in range(8)]
            elif kind < 0.7:
                s = self.smooth(r.randint(0, 255), r.choice([1, 2, 3, 4, 6, 8, 12]))
            else:
                base = r.randint(0, 255)
                step = r.randint(-40, 40)
                s = [RR.clip3(0, 255, base + r.randint(-3, 3)) for _ in range(4)] + \
                    [RR.clip3(0, 255, base + step + r.randint(-3, 3)) for _ in range(4)]
            qp_p, qp_q = r.randint(0, 51), r.randint(0, 51)
            self.add("rand", s, r.randint(1, 4), r.randint(0, 1), mb(qp_p), mb(qp_q), r.choice(OFFSETS), r.choice(OFFSETS))

    def check_coverage(self):
        c = self.cov
        for k in ("on", "off", "ap_lt", "ap_ge", "aq_lt", "aq_ge", "strong_close", "strong_far", "pcm"):
            assert c[k] > 0, "filter coverage: %s never happened" % k
        for bs in (1, 2, 3, 4):
            for chroma in (0, 1):
                assert self.cov_bs.get((bs, chroma, True), 0) > 0, "no ON case for bS %d chroma %d" % (bs, chroma)
                assert self.cov_bs.get((bs, chroma, False), 0) > 0, "no OFF case for bS %d chroma %d" % (bs, chroma)
        assert self.idx_a_on == set(range(16, 52)), "indexA with the filter on: %r" % sorted(self.idx_a_on)
        assert self.idx_b_on == set(range(16, 52)), "indexB with the filter on: %r" % sorted(self.idx_b_on)
        assert self.aoffs == set(OFFSETS) and self.boffs == set(OFFSETS), "offsets not all exercised"
        assert self.qp_p == set(range(52)) and self.qp_q == set(range(52)), "qp values not all exercised"

    def report(self, out):
        c = self.cov
        print("filter cases: %d" % len(self.rows), file=out)
        print("  filterSamplesFlag on %d / off %d; ap<beta %d / >= %d; aq<beta %d / >= %d; "
              "bS4 luma |p0-q0| < (alpha>>2)+2: %d / not %d; I_PCM sides %d"
              % (c["on"], c["off"], c["ap_lt"], c["ap_ge"], c["aq_lt"], c["aq_ge"],
                 c["strong_close"], c["strong_far"], c["pcm"]), file=out)
        for bs in (1, 2, 3, 4):
            print("  bS %d: luma on %d off %d, chroma on %d off %d" % (
                bs, self.cov_bs.get((bs, 0, True), 0), self.cov_bs.get((bs, 0, False), 0),
                self.cov_bs.get((bs, 1, True), 0), self.cov_bs.get((bs, 1, False), 0)), file=out)
        print("  indexA on: %d values, indexB on: %d values; alpha offsets %d, beta offsets %d; qp_p %d values, qp_q %d values"
              % (len(self.idx_a_on), len(self.idx_b_on), len(self.aoffs), len(self.boffs), len(self.qp_p), len(self.qp_q)), file=out)
        by = {}
        for row in self.rows:
            by[row[0]] = by.get(row[0], 0) + 1
        print("  by class: " + ", ".join("%s %d" % (k, by[k]) for k in F_CLS if k in by), file=out)

    def write(self, stem):
        with open(stem + ".in.hex", "w") as fi, open(stem + ".exp.hex", "w") as fe:
            for cls, s, bs, chroma, qp_p, qp_q, aoff, boff, out, changed in self.rows:
                w = 0
                for v in s:
                    w = (w << 8) | v
                w |= bs << 64
                w |= chroma << 67
                w |= qp_p << 68
                w |= qp_q << 74
                w |= (aoff & 0x1F) << 80
                w |= (boff & 0x1F) << 85
                w |= F_CLS.index(cls) << 90
                fi.write("%032x\n" % w)
                e = 0
                for v in out:
                    e = (e << 8) | v
                e |= changed << 48
                fe.write("%016x\n" % e)
        with open(stem + ".meta.hex", "w") as fm:
            fm.write("%08x\n" % len(self.rows))


# ---------------------------------------------------------------- the boundary strength

def blk(intra=0, nz=0, pred=(0, 0), ref=(0, 0), mv=((0, 0), (0, 0))):
    m = RR.MbInfo()
    m.intra = intra
    m.nz = [nz] * 16
    m.pred = [[pred[0]] * 16, [pred[1]] * 16]
    m.refpic = [[ref[0]] * 16, [ref[1]] * 16]
    m.mv = [[tuple(mv[0])] * 16, [tuple(mv[1])] * 16]
    return m


class BsCases(object):
    def __init__(self, rng):
        self.rng = rng
        self.rows = []
        self.cov = {}
        self.combo = set()

    def add(self, cls, p, q, mb_edge, vertical, field):
        bs = RR.boundary_strength(p, q, mb_edge, vertical, 0, 0, field)
        self.record(cls, self.pack(p, 0), self.pack(q, 0), mb_edge, vertical, field, bs)

    @staticmethod
    def pack(m, b):
        """an MbInfo's block b as the RTL's fields (refpic codes assigned by the caller)"""
        return (m.intra, m.nz[b], m.pred[0][b], m.pred[1][b], m.refpic[0][b], m.refpic[1][b],
                m.mv[0][b], m.mv[1][b])

    def record(self, cls, p, q, mb_edge, vertical, field, bs):
        self.cov[bs] = self.cov.get(bs, 0) + 1
        self.combo.add((p[0], q[0], p[1], q[1], p[2], p[3], q[2], q[3]))
        self.rows.append((cls, p, q, mb_edge, vertical, field, bs))

    def rmv(self, lim=2047):
        r = self.rng
        return (r.randint(-lim, lim), r.randint(-lim, lim))

    def gen_directed(self):
        r = self.rng
        # intra on a macroblock edge: frame / field x vertical / horizontal, p or q intra
        for field in (0, 1):
            for vertical in (0, 1):
                for who in (1, 2, 3):
                    for _ in range(4):
                        p = blk(intra=who & 1, nz=r.randint(0, 1), pred=(1, 0), ref=(r.randint(0, 255), 0), mv=(self.rmv(), (0, 0)))
                        q = blk(intra=(who >> 1) & 1, nz=r.randint(0, 1), pred=(1, 0), ref=(r.randint(0, 255), 0), mv=(self.rmv(), (0, 0)))
                        self.add("intra_mb", p, q, 1, vertical, field)
        # intra on an internal edge -> 3 whatever the picture structure
        for field in (0, 1):
            for vertical in (0, 1):
                for who in (1, 2, 3):
                    for _ in range(4):
                        p = blk(intra=who & 1, nz=r.randint(0, 1), pred=(1, 0), ref=(3, 0), mv=(self.rmv(), (0, 0)))
                        q = blk(intra=(who >> 1) & 1, nz=r.randint(0, 1), pred=(1, 0), ref=(3, 0), mv=(self.rmv(), (0, 0)))
                        self.add("intra_in", p, q, 0, vertical, field)
        # flags: every combination of intra / nz / pred0 / pred1 on both sides that the model
        # can evaluate (an inter block with no vector on BOTH sides is the one it cannot:
        # 2 x 2 nz combos of the 256 are left out -> 252), each with three random
        # motions / edge kinds; the coverage check requires all 252
        for combo in range(256):
            ip, iq = combo & 1, (combo >> 1) & 1
            nzp, nzq = (combo >> 2) & 1, (combo >> 3) & 1
            pp, pq = ((combo >> 4) & 1, (combo >> 5) & 1), ((combo >> 6) & 1, (combo >> 7) & 1)
            if not ip and not iq and pp == (0, 0) and pq == (0, 0):
                continue
            for _ in range(3):
                pics = [r.randint(0, 255) for _ in range(2)]
                mv = self.rmv()
                near = (mv[0] + r.randint(-3, 3), mv[1] + r.randint(-1, 1))
                p = blk(intra=ip, nz=nzp, pred=pp, ref=(r.choice(pics), r.choice(pics)), mv=(mv, near if r.random() < 0.5 else self.rmv()))
                q = blk(intra=iq, nz=nzq, pred=pq, ref=(r.choice(pics), r.choice(pics)), mv=(near if r.random() < 0.5 else mv, mv))
                self.add("flags", p, q, r.randint(0, 1), r.randint(0, 1), r.randint(0, 1))
        # nz on p only / q only / both, inter blocks with identical motion (so bS would be 0)
        for who in (1, 2, 3):
            for mb_edge in (0, 1):
                for vertical in (0, 1):
                    for field in (0, 1):
                        for _ in range(3):
                            ref, mv = r.randint(0, 255), self.rmv()
                            p = blk(nz=who & 1, pred=(1, 0), ref=(ref, 0), mv=(mv, (0, 0)))
                            q = blk(nz=(who >> 1) & 1, pred=(1, 0), ref=(ref, 0), mv=(mv, (0, 0)))
                            self.add("nz", p, q, mb_edge, vertical, field)
        # nvec: one vector against two of the same picture with identical vectors (only the
        # count differs), both orders, the unused list mirroring the used one or random
        for order in (0, 1):
            for lists in ((1, 0), (0, 1)):
                for mirror in (0, 1):
                    for _ in range(6):
                        ref, mv = r.randint(0, 255), self.rmv()
                        one = blk(pred=lists, ref=(ref, ref) if mirror else (ref if lists[0] else r.randint(0, 255), ref if lists[1] else r.randint(0, 255)),
                                  mv=(mv, mv) if mirror else (mv if lists[0] else self.rmv(), mv if lists[1] else self.rmv()))
                        two = blk(pred=(1, 1), ref=(ref, ref), mv=(mv, mv))
                        p, q = (one, two) if order == 0 else (two, one)
                        self.add("nvec", p, q, r.randint(0, 1), r.randint(0, 1), r.randint(0, 1))
        # refset: same count, different pictures -> 1; same set in swapped lists with equal
        # vectors -> 0; {A,A} vs {A,B} -> 1
        for _ in range(40):
            a, b = r.sample(range(256), 2)
            mv = self.rmv()
            # one vector each, different pictures (any lists)
            lp, lq = r.choice([(1, 0), (0, 1)]), r.choice([(1, 0), (0, 1)])
            p = blk(pred=lp, ref=(a, a), mv=(mv, mv))
            q = blk(pred=lq, ref=(b, b), mv=(mv, mv))
            self.add("refset", p, q, r.randint(0, 1), r.randint(0, 1), r.randint(0, 1))
            # one vector each, the same picture through different lists, same vector -> 0
            p = blk(pred=(1, 0), ref=(a, r.randint(0, 255)), mv=(mv, self.rmv()))
            q = blk(pred=(0, 1), ref=(r.randint(0, 255), a), mv=(self.rmv(), mv))
            self.add("refset", p, q, r.randint(0, 1), r.randint(0, 1), r.randint(0, 1))
            # two each: {a,b} vs {b,a} equal vectors per picture -> 0
            mv2 = self.rmv()
            p = blk(pred=(1, 1), ref=(a, b), mv=(mv, mv2))
            q = blk(pred=(1, 1), ref=(b, a), mv=(mv2, mv))
            self.add("refset", p, q, r.randint(0, 1), r.randint(0, 1), r.randint(0, 1))
            # {a,a} vs {a,b} -> 1
            p = blk(pred=(1, 1), ref=(a, a), mv=(mv, mv))
            q = blk(pred=(1, 1), ref=(a, b) if r.random() < 0.5 else (b, a), mv=(mv, mv))
            self.add("refset", p, q, r.randint(0, 1), r.randint(0, 1), r.randint(0, 1))
            # {a,b} vs {a,c} -> 1
            c = r.choice([v for v in range(256) if v not in (a, b)])
            p = blk(pred=(1, 1), ref=(a, b), mv=(mv, mv2))
            q = blk(pred=(1, 1), ref=(a, c), mv=(mv, mv2))
            self.add("refset", p, q, r.randint(0, 1), r.randint(0, 1), r.randint(0, 1))
        # mv1h / mv1v: one vector each, same picture, component differences around the limits
        for field in (0, 1):
            for d in (0, 1, 2, 3, 4, 5, 6, 8):
                for sign in (1, -1):
                    for lists in ((1, 0), (0, 1)):
                        for _ in range(4):
                            ref = r.randint(0, 255)
                            base = self.rmv()
                            # horizontal
                            mvq = (base[0] + sign * d, base[1] + r.randint(-1, 1))
                            p = blk(pred=lists, ref=(ref, ref), mv=(base, base))
                            q = blk(pred=lists, ref=(ref, ref), mv=(mvq, mvq))
                            self.add("mv1h", p, q, r.randint(0, 1), r.randint(0, 1), field)
                            # vertical
                            mvq = (base[0] + r.randint(-1, 1), base[1] + sign * d)
                            p = blk(pred=lists, ref=(ref, ref), mv=(base, base))
                            q = blk(pred=lists, ref=(ref, ref), mv=(mvq, mvq))
                            self.add("mv1v", p, q, r.randint(0, 1), r.randint(0, 1), field)
        # extremes of the 16-bit range (the 17-bit difference)
        for _ in range(20):
            ref = r.randint(0, 255)
            p = blk(pred=(1, 0), ref=(ref, ref), mv=((32767, -32768), (0, 0)))
            q = blk(pred=(1, 0), ref=(ref, ref), mv=((-32768, 32767), (0, 0)))
            self.add("mv1h", p, q, r.randint(0, 1), r.randint(0, 1), r.randint(0, 1))
            p = blk(pred=(1, 0), ref=(ref, ref), mv=((32767, 32767), (0, 0)))
            q = blk(pred=(1, 0), ref=(ref, ref), mv=((32767 - r.randint(0, 5), 32767 - r.randint(0, 5)), (0, 0)))
            self.add("mv1v", p, q, r.randint(0, 1), r.randint(0, 1), r.randint(0, 1))
        # mv2d: two vectors, two different pictures: pairing by picture, straight and swapped
        for field in (0, 1):
            for swap in (0, 1):
                for far_which in (0, 1, 2, 3):      # neither / the a pair / the b pair / both
                    for _ in range(8):
                        a, b = r.sample(range(256), 2)
                        mva, mvb = self.rmv(), self.rmv()
                        lim = 2 if field else 4
                        def near(v):
                            return (v[0] + r.randint(-3, 3), v[1] + r.randint(-(lim - 1), lim - 1))
                        def far(v):
                            if r.random() < 0.5:
                                return (v[0] + r.choice([-1, 1]) * r.randint(4, 20), v[1] + r.randint(-(lim - 1), lim - 1))
                            return (v[0] + r.randint(-3, 3), v[1] + r.choice([-1, 1]) * r.randint(lim, 20))
                        qa = far(mva) if far_which & 1 else near(mva)
                        qb = far(mvb) if far_which & 2 else near(mvb)
                        p = blk(pred=(1, 1), ref=(a, b), mv=(mva, mvb))
                        q = blk(pred=(1, 1), ref=(b, a), mv=(qb, qa)) if swap else blk(pred=(1, 1), ref=(a, b), mv=(qa, qb))
                        self.add("mv2d", p, q, r.randint(0, 1), r.randint(0, 1), field)
        # mv2s: the same picture twice on both sides: straight / crossed pairings near or far
        for field in (0, 1):
            for straight_far in (0, 1):
                for crossed_far in (0, 1):
                    for _ in range(10):
                        a = r.randint(0, 255)
                        lim = 2 if field else 4
                        mv0, mv1 = self.rmv(), self.rmv()
                        def near(v):
                            return (v[0] + r.randint(-3, 3), v[1] + r.randint(-(lim - 1), lim - 1))
                        def far(v):
                            if r.random() < 0.5:
                                return (v[0] + r.choice([-1, 1]) * r.randint(4, 20), v[1] + r.randint(-(lim - 1), lim - 1))
                            return (v[0] + r.randint(-3, 3), v[1] + r.choice([-1, 1]) * r.randint(lim, 20))
                        # q's list 0 vector is near/far p's list 0 (straight) and near/far p's
                        # list 1 (crossed): choose q0 from mv0 or mv1, q1 from the other
                        if not straight_far and not crossed_far:
                            q0, q1 = near(mv0), near(mv0)
                            # both pairings near needs q0 near mv0 and mv1, so make mv1 near mv0
                            mv1 = near(mv0)
                            q1 = near(mv0)
                        elif straight_far and not crossed_far:
                            q0, q1 = near(mv1), near(mv0)
                            mv1 = far(mv0) if r.random() < 0.5 else (mv0[0] + r.choice([-1, 1]) * r.randint(4, 30), mv0[1])
                            q0, q1 = near(mv1), near(mv0)
                        elif not straight_far and crossed_far:
                            mv1 = (mv0[0] + r.choice([-1, 1]) * r.randint(4, 30), mv0[1] + r.choice([-1, 1]) * r.randint(lim, 30))
                            q0, q1 = near(mv0), near(mv1)
                        else:
                            mv1 = (mv0[0] + r.choice([-1, 1]) * r.randint(8, 30), mv0[1])
                            q0 = far(mv0)
                            q1 = far(mv1)
                        p = blk(pred=(1, 1), ref=(a, a), mv=(mv0, mv1))
                        q = blk(pred=(1, 1), ref=(a, a), mv=(q0, q1))
                        self.add("mv2s", p, q, r.randint(0, 1), r.randint(0, 1), field)

    def gen_random(self, n):
        r = self.rng
        pics = [r.randint(0, 255) for _ in range(4)]
        for i in range(n):
            if i % 200 == 0:
                pics = [r.randint(0, 255) for _ in range(r.randint(1, 4))]
            def rb():
                intra = 1 if r.random() < 0.15 else 0
                nz = 1 if r.random() < 0.3 else 0
                pred = (r.randint(0, 1), r.randint(0, 1))
                if pred == (0, 0) and not intra:
                    pred = (1, 0) if r.random() < 0.7 else (0, 1)
                spread = r.choice([1, 2, 3, 4, 5, 6, 40, 2000])
                base = self.rmv()
                mv = ((base[0] + r.randint(-spread, spread), base[1] + r.randint(-spread, spread)),
                      (base[0] + r.randint(-spread, spread), base[1] + r.randint(-spread, spread)))
                return blk(intra=intra, nz=nz, pred=pred, ref=(r.choice(pics), r.choice(pics)), mv=mv)
            p, q = rb(), rb()
            if not p.intra and not q.intra and p.pred[0][0] + p.pred[1][0] == 0 and q.pred[0][0] + q.pred[1][0] == 0:
                continue
            self.add("rand", p, q, r.randint(0, 1), r.randint(0, 1), r.randint(0, 1))

    def check_coverage(self):
        for bs in range(5):
            assert self.cov.get(bs, 0) > 0, "no bS %d case" % bs
        # every combination of the flags (intra p/q, nz p/q, pred p0 p1 q0 q1) that is
        # legal for an inter block (at least one vector) or an intra one
        n_combo = len(self.combo)
        assert n_combo == 252, "flag combinations covered: %d (252 are reachable)" % n_combo

    def report(self, out):
        print("bS cases: %d; by bS: %s; flag combinations (intra/nz/pred p and q): %d"
              % (len(self.rows), ", ".join("%d -> %d" % (k, self.cov[k]) for k in sorted(self.cov)), len(self.combo)), file=out)
        by = {}
        for row in self.rows:
            by[row[0]] = by.get(row[0], 0) + 1
        print("  by class: " + ", ".join("%s %d" % (k, by[k]) for k in B_CLS if k in by), file=out)

    def write(self, stem):
        def pack(b):
            intra, nz, pred0, pred1, ref0, ref1, mv0, mv1 = b
            w = (intra << 83) | (nz << 82) | (pred0 << 81) | (pred1 << 80) | ((ref0 or 0) << 72) | ((ref1 or 0) << 64)
            w |= (mv0[0] & 0xFFFF) << 48
            w |= (mv0[1] & 0xFFFF) << 32
            w |= (mv1[0] & 0xFFFF) << 16
            w |= (mv1[1] & 0xFFFF)
            return w
        with open(stem + ".in.hex", "w") as fi, open(stem + ".exp.hex", "w") as fe:
            for cls, p, q, mb_edge, vertical, field, bs in self.rows:
                w = pack(p) | (pack(q) << 84) | (mb_edge << 168) | (vertical << 169) | (field << 170) | (B_CLS.index(cls) << 171)
                fi.write("%048x\n" % w)
                fe.write("%x\n" % bs)
        with open(stem + ".meta.hex", "w") as fm:
            fm.write("%08x\n" % len(self.rows))


# ---------------------------------------------------------------- the real clip

def make_clip(path, size="320x240", frames=12):
    """an x264 Main-profile clip with B frames, several references, adaptive quantisation
    (so qp varies across macroblocks) and the deblocking filter with non-zero offsets"""
    cmd = ["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=%s:rate=24" % size, "-frames:v", str(frames),
           "-c:v", "libx264", "-profile:v", "main", "-pix_fmt", "yuv420p",
           "-x264-params", "cabac=1:8x8dct=0:bframes=2:b-pyramid=0:ref=3:weightp=0:keyint=12:min-keyint=12:scenecut=0:"
                           "direct=spatial:aq-mode=1:aq-strength=1.5:crf=26:deblock=2,-1:psy=0",
           "-bsf:v", "h264_mp4toannexb", "-f", "h264", "-y", path]
    subprocess.check_call(cmd)


def record_real(clip, fcases, bcases, cap, check=True):
    """decode the clip with the model, recording every filter_line / boundary_strength call
    (the model's own calls, through its globals), and keep a deterministic subsample"""
    frec = []
    brec = []
    orig_f, orig_b = RR.filter_line, RR.boundary_strength
    codes = {}

    def code(ident):
        if ident is None:
            return 0
        if ident not in codes:
            codes[ident] = len(codes) + 1
            assert len(codes) < 256, "more than 255 reference pictures in the clip"
        return codes[ident]

    def rec_filter(plane, y, x, vertical, bs, pm, qm, chroma, aoff, boff):
        s = [int(v) for v in (plane[y, x - 4:x + 4] if vertical else plane[y - 4:y + 4, x])]
        orig_f(plane, y, x, vertical, bs, pm, qm, chroma, aoff, boff)
        out = [int(v) for v in (plane[y, x - 3:x + 3] if vertical else plane[y - 3:y + 3, x])]
        frec.append((s, bs, 1 if chroma else 0, resolve_qp(pm, chroma), resolve_qp(qm, chroma), aoff, boff, out, pm.pcm or qm.pcm))

    def rec_bs(p, q, mb_edge, vertical, pblk, qblk, field):
        bs = orig_b(p, q, mb_edge, vertical, pblk, qblk, field)
        def pk(m, b):
            return (m.intra, m.nz[b], m.pred[0][b], m.pred[1][b],
                    code(m.refpic[0][b]) if m.pred[0][b] else 0, code(m.refpic[1][b]) if m.pred[1][b] else 0,
                    tuple(m.mv[0][b]), tuple(m.mv[1][b]))
        brec.append((pk(p, pblk), pk(q, qblk), 1 if mb_edge else 0, 1 if vertical else 0, 1 if field else 0, bs))
        return bs

    RR.filter_line = rec_filter
    RR.boundary_strength = rec_bs
    try:
        dec = RR.decode_file(clip)
    finally:
        RR.filter_line, RR.boundary_strength = orig_f, orig_b
    frames = dec.output_frames()
    if check:
        yuv = clip + ".recon.yuv"
        ref = clip + ".ffmpeg.yuv"
        RR.write_yuv(frames, yuv)
        RR.ffmpeg_yuv(clip, ref)
        s = frames[0].sps
        l, r, t, b = s.crop
        cu_y = 2 * (2 - s.frame_mbs_only)
        w, h = s.width - 2 * (l + r), s.height - cu_y * (t + b)
        mism, na, nb = RR.compare_yuv(yuv, ref, w, h)
        assert mism is None and na == nb, "the recorded decode is not bit-exact vs ffmpeg: %r %d %d" % (mism, na, nb)
    fstride = max(1, len(frec) // cap)
    bstride = max(1, len(brec) // cap)
    for i in range(0, len(frec), fstride):
        s, bs, chroma, qp_p, qp_q, aoff, boff, out, pcm = frec[i]
        fcases.record("real", s, bs, chroma, qp_p, qp_q, aoff, boff, out, pcm)
    for i in range(0, len(brec), bstride):
        p, q, mb_edge, vertical, field, bs = brec[i]
        bcases.record("real", p, q, mb_edge, vertical, field, bs)
    bs_hist = {}
    for rec in brec:
        bs_hist[rec[5]] = bs_hist.get(rec[5], 0) + 1
    print("real clip: %d pictures, %d frames bit-exact vs ffmpeg; %d filter lines (kept every %d), %d bS pairs (kept every %d), bS histogram %s, %d reference pictures"
          % (dec.n_pictures, len(frames), len(frec), fstride, len(brec), bstride,
             ", ".join("%d -> %d" % (k, bs_hist[k]) for k in sorted(bs_hist)), len(codes)))
    return len(frec), len(brec)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", required=True, help="fixture directory")
    ap.add_argument("--clip", help="the x264 clip to decode (made here with ffmpeg when missing); none: skip the real arm")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--random", type=int, default=6000, help="random cases per unit")
    ap.add_argument("--cap", type=int, default=30000, help="recorded real cases kept per unit (a stride)")
    ap.add_argument("--no-check", action="store_true", help="skip the ffmpeg pixel check of the recorded decode")
    a = ap.parse_args(argv)
    os.makedirs(a.out, exist_ok=True)
    rng = random.Random(a.seed)
    f = FilterCases(rng)
    f.gen_directed()
    f.gen_random(a.random)
    b = BsCases(rng)
    b.gen_directed()
    b.gen_random(a.random)
    if a.clip:
        if not os.path.exists(a.clip):
            make_clip(a.clip)
        record_real(a.clip, f, b, a.cap, check=not a.no_check)
    f.check_coverage()
    b.check_coverage()
    f.report(sys.stdout)
    b.report(sys.stdout)
    f.write(os.path.join(a.out, "deblock_filter"))
    b.write(os.path.join(a.out, "deblock_bs"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
