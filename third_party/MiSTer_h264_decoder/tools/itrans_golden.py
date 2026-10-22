#!/usr/bin/env python3
"""Fixtures for bench/h264/dequant_itrans_tb.sv: blocks of coefficient levels in scan
order and the residual samples / scaled DC values h264/dec/dequant_itrans.sv must
produce, from the model functions of tools/h264_recon_ref.py (dequant4x4, itrans4x4,
luma_dc, chroma_dc -- proven pixel-exact against ffmpeg and the H.264.1 YUVs).
docs/h264_recon.md S2.4.

Files per case class (one hex word per line, $readmemh):
  <stem>.meta.hex   [0] n_blocks [1] n_coef words [2] n_out words [3] max |d| seen
  <stem>.blk.hex    one 32-bit word per block: {kind[31:29], field[28], qp[27:22], weighted[21],
                    list[20:18], 0[17:16], dc_in[15:0] (two's complement)}: weighted 0 = every
                    weight 16 (wflat), else the block's scaling list `list` of the .w.hex matrix
                    (0..5 the 4x4 lists, 6 / 7 the 8x8 ones)
  <stem>.w.hex      the fixture's scaling matrix, 56 words as the front end emits them
                    (tools/h264_fe_ref.py scaling_words): lists 0..5 four words each, 6 and 7
                    sixteen, coded order, four weights a word (H264 Phase 5)
  <stem>.coef.hex   the levels in scan order, 16-bit two's complement, block after block
                    (16 per L4/LDC block, 15 per LAC/CAC block, 4 per CDC block)
  <stem>.exp.hex    the expected outputs, 16-bit two's complement (16 per block, 4 per CDC)

Case classes (the RED arms of run_dequant_itrans.sh are named by these stems):
  it_rand_<KIND>_<frame|field>  every qp 0..51 x random blocks, levels kept inside the
                    spec's ranges (8.5.12: d, f, h in 16 bits; 8.5.10 / 8.5.11.2: dcY, dcC
                    in 16 bits) by a sufficient condition that is ASSERTED on the golden
                    (sum |d| <= 32767 bounds every f and h; sum |c| times the DC gain
                    bounds every dcY / dcC); a block outside the range is regenerated with
                    smaller levels, never written, and the retries are counted
  it_sparse_<frame|field>  one coefficient at every scan position of every kind, at the
                    largest magnitude the range admits, both signs, 7 qps
  it_zero           all-zero blocks of every kind, and AC blocks whose only content is dc_in
  it_real[_field]   the blocks a real stream's decode transforms (the fixture-range check):
                    the x264 clip the runner encodes (--stream), captured by wrapping the
                    model's own transform functions while h264_recon_ref decodes it, with
                    the QP the decoder used for that macroblock; with --field-stream,
                    field-coded blocks from a stream with field pictures (the model
                    decodes them; the runner's is H.264.1's camp_mot_fld0_full)
  (H264 Phase 5, High profile: docs/high_profile.md S5)
  it_w_<KIND>_<frame|field>  the random classes again with WEIGHTED lists (random weights
                    1..255 per list, a random list per block): LevelScale4x4 = w x normAdjust,
                    the rounding term of eq. 8-337 now real (a weight need not be a multiple of
                    16), the DC kinds scaled by weightScale(0, 0)
  it_rand_L8_<frame|field>  8x8 blocks (kind 5), every qp, flat and weighted mixed; every
                    intermediate of 8.5.13 (d, e, f, g, h, k, m) checked in range EXACTLY on
                    the model's arithmetic (not a sufficient condition)
  it_sparse8_<frame|field>  one coefficient at every one of the 64 scan positions, both signs
  it_real8          the 8x8 blocks an x264 High clip's decode transforms (--high-stream)
    itrans_golden.py --out bench/h264/fixtures/gen [--stream clip.264] [--field-stream f.264]
"""
import argparse
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import h264_recon_ref as R  # noqa: E402

import high_tables as HT  # noqa: E402

K_L4, K_LAC, K_CAC, K_LDC, K_CDC, K_L8 = range(6)
KIND_NAME = ["L4", "LAC", "CAC", "LDC", "CDC", "L8"]
NCOEF = [16, 15, 15, 16, 4, 64]
NOUT = [16, 16, 16, 16, 4, 64]
LIM = 32767                                 # 2^(7 + bitDepth) - 1 at 8 bits

# the fixture's scaling matrix: eight lists (coded order), set per written fixture; a case's
# `wsel` is None (flat) or a list index into it
MATRIX = [[16] * 16] * 6 + [[16] * 64] * 2


def ls4_for(wsel):
    return R.LEVEL_SCALE if wsel is None else R.level_scale4_table(MATRIX[wsel])


def ls8_for(wsel):
    return R.level_scale8_table([16] * 64 if wsel is None else MATRIX[wsel])


def itrans8_checked(d):
    """8.5.13.2 on the model's own arithmetic with every intermediate checked against the
    spec's bounds (e, f, g, h, k in 16 bits; m to 2^15 - 33): raises RangeError. The result
    is compared with R.itrans8x8 so this copy cannot drift from the model."""
    def one(v):
        d0, d1, d2, d3, d4, d5, d6, d7 = v
        e = [d0 + d4, -d3 + d5 - d7 - (d7 >> 1), d0 - d4, d1 + d7 - d3 - (d3 >> 1),
             (d2 >> 1) - d6, -d1 + d7 + d5 + (d5 >> 1), d2 + (d6 >> 1), d3 + d5 + d1 + (d1 >> 1)]
        f = [e[0] + e[6], e[1] + (e[7] >> 2), e[2] + e[4], e[3] + (e[5] >> 2),
             e[2] - e[4], (e[3] >> 2) - e[5], e[0] - e[6], e[7] - (e[1] >> 2)]
        g = [f[0] + f[7], f[2] + f[5], f[4] + f[3], f[6] + f[1], f[6] - f[1], f[4] - f[3], f[2] - f[5], f[0] - f[7]]
        for x in e + f:
            if not -LIM - 1 <= x <= LIM:
                raise RangeError("8x8 e/f out of range")
        return g
    rows = []
    for i in range(8):
        g = one(d[8 * i:8 * i + 8])
        if min(g) < -LIM - 1 or max(g) > LIM:
            raise RangeError("8x8 g out of range")
        rows.append(g)
    r = [0] * 64
    for j in range(8):
        m = one([rows[i][j] for i in range(8)])
        if min(m) < -LIM - 1 or max(m) > LIM - 32:
            raise RangeError("8x8 m out of range")
        for i in range(8):
            r[8 * i + j] = (m[i] + 32) >> 6
    assert r == R.itrans8x8(d)
    return r


class RangeError(Exception):
    pass


def golden(kind, qp, field, dc, levels, strict=True, wsel=None):
    """The model's outputs for one block, and the range facts the spec states about it.
    Returns (outputs, max_abs_d, tight). Raises RangeError when the block is outside what
    a conforming stream may carry (the bench must never see one of those). `strict` also
    demands the sufficient condition below, which the random generator keeps to; a real
    stream's block may legally exceed it (`tight` says so) while its f and h stay in range."""
    scan = R.FIELD_SCAN if field else R.ZIGZAG
    if kind == K_L8:
        d = R.dequant8x8(levels, HT.FIELD_SCAN8 if field else HT.ZIGZAG8, qp, ls8_for(wsel))
        if min(d) < -LIM - 1 or max(d) > LIM:
            raise RangeError("d out of range")
        return itrans8_checked(d), max(abs(v) for v in d), False
    if kind in (K_L4, K_LAC, K_CAC):
        d = R.dequant4x4(levels, scan, qp, dc=(dc if kind != K_L4 else None), ls4=ls4_for(wsel))
        # 8.5.12.1: every d_ij within 16 bits; 8.5.12.2: every f_ij and h_ij too. Sufficient
        # for the latter: each row's f is a signed combination of that row's d with
        # |weights| <= 1, so |f_ij| <= sum_j |d_ij|, and |h_ij| <= sum_i |f_ij| <= the sum
        # over the block of |d|.
        if min(d) < -LIM - 1 or max(d) > LIM:
            raise RangeError("d out of range")
        tight = sum(abs(v) for v in d) > LIM
        if strict and tight:
            raise RangeError("d sum out of range")
        return R.itrans4x4(d), max(abs(v) for v in d), tight
    if kind == K_LDC:
        out = R.luma_dc(levels, scan, qp, ls4_for(wsel))
    else:
        out = R.chroma_dc(levels, qp, ls4_for(wsel))
    if min(out) < -LIM - 1 or max(out) > LIM:      # 8.5.10 / 8.5.11.2: dcY, dcC within 16 bits
        raise RangeError("dc out of range")
    return out, max(abs(v) for v in out), False


def unit_scale(kind, qp, field, pos, wsel=None):
    """|d| (or the DC output gain) of a level of 1 at scan position `pos`, from the model."""
    scan = R.FIELD_SCAN if field else R.ZIGZAG
    n = NCOEF[kind]
    lv = [0] * n
    lv[pos] = 1
    if kind == K_L8:
        d = R.dequant8x8(lv, HT.FIELD_SCAN8 if field else HT.ZIGZAG8, qp, ls8_for(wsel))
        # the 8-point transform's gain on one d: up to ~1.5 x per pass on the odd terms
        return max(abs(v) for v in d) * 2.5
    if kind in (K_L4, K_LAC, K_CAC):
        d = R.dequant4x4(lv, scan, qp, dc=(0 if kind != K_L4 else None), ls4=ls4_for(wsel))
        return max(abs(v) for v in d)
    ls00 = ls4_for(wsel)[qp % 6][0][0]
    if kind == K_LDC:
        # the Hadamard spreads a single level to every f_ij with |f| = 1: the gain is
        # LevelScale * 2^(qp/6) / 64 (the rounding hides it at low qp, so use the formula)
        return ls00 * (2 ** (qp // 6)) / 64.0
    return ls00 * (2 ** (qp // 6)) / 32.0


def max_level(kind, qp, field, pos, budget, wsel=None):
    """The largest level magnitude at `pos` whose scaled value stays within `budget`
    (the estimate from the unit gain, then backed off until the model agrees -- the DC
    rounding can add one)."""
    g = unit_scale(kind, qp, field, pos, wsel)
    if g == 0:
        return 0
    m = max(0, min(int(budget // g), LIM))
    n = NCOEF[kind]
    while m > 0:
        lv = [0] * n
        lv[pos] = m
        try:
            out, maxv, _ = golden(kind, qp, field, 0, lv, wsel=wsel)
            if maxv <= budget:
                break
        except RangeError:
            pass
        m = m - 1 if m < 64 else m - max(1, m // 16)
    return m


class Case(object):
    __slots__ = ("kind", "qp", "field", "dc", "levels", "out", "maxd", "tight", "wsel")

    def __init__(self, kind, qp, field, dc, levels, strict=True, wsel=None):
        self.kind, self.qp, self.field, self.dc, self.levels, self.wsel = kind, qp, field, dc, levels, wsel
        self.out, self.maxd, self.tight = golden(kind, qp, field, dc, levels, strict, wsel)


def rand_block(rng, kind, qp, field, retries, wsel=None):
    """A random block inside the spec ranges: n_nz positions, the range budget shared."""
    n = NCOEF[kind]
    for attempt in range(40):
        n_nz = rng.randint(1, n)
        positions = rng.sample(range(n), n_nz)
        # the budget shared by the non-zero coefficients (and dc_in for the AC kinds); a
        # deliberately uneven split so a few coefficients can be large
        shares = [rng.random() ** 2 + 0.02 for _ in range(n_nz + (1 if kind in (K_LAC, K_CAC) else 0))]
        tot = sum(shares)
        scale = LIM / float(2 ** attempt)
        levels = [0] * n
        for p, s in zip(positions, shares):
            m = max_level(kind, qp, field, p, s / tot * scale, wsel)
            if m == 0:
                continue
            v = rng.randint(1, m)
            levels[p] = -v if rng.random() < 0.5 else v
        dc = 0
        if kind in (K_LAC, K_CAC):
            m = int(shares[-1] / tot * scale)
            m = max(0, min(m, LIM))
            if m:
                dc = rng.randint(-m, m)
        try:
            return Case(kind, qp, field, dc, levels, wsel=wsel)
        except RangeError:
            retries[0] += 1
    raise SystemExit("itrans_golden: could not place a block in range (kind %d qp %d)" % (kind, qp))


def rand_block8(rng, qp, field, retries, wsel):
    """A random 8x8 block: a few to many coefficients, levels bounded by the model's own
    range checks (itrans8_checked), halved until the block is legal."""
    for attempt in range(40):
        n_nz = rng.choice((1, 2, 4, 8, 16, 32, 64))
        positions = rng.sample(range(64), n_nz)
        levels = [0] * 64
        for p in positions:
            m = max(1, max_level(K_L8, qp, field, p, LIM / float(2 ** attempt) / max(1, n_nz // 2), wsel))
            v = rng.randint(1, m)
            levels[p] = -v if rng.random() < 0.5 else v
        try:
            return Case(K_L8, qp, field, 0, levels, wsel=wsel)
        except RangeError:
            retries[0] += 1
    raise SystemExit("itrans_golden: could not place an 8x8 block in range (qp %d)" % qp)


def sparse_cases(field, rng):
    cases = []
    qps = [0, 7, 13, 26, 35, 36, 51]
    for kind in (K_L4, K_LAC, K_CAC, K_LDC):
        n = NCOEF[kind]
        for qp in qps:
            for pos in range(n):
                m = max_level(kind, qp, field, pos, LIM)
                for sign in (1, -1):
                    lv = [0] * n
                    lv[pos] = sign * m
                    cases.append(Case(kind, qp, field, 0, lv))
                # an AC block's DC and one AC coefficient share the range
                if kind in (K_LAC, K_CAC):
                    lv = [0] * n
                    lv[pos] = -(m // 2) if pos % 2 else (m // 2)
                    dc = rng.randint(-(LIM // 2), LIM // 2)
                    cases.append(Case(kind, qp, field, dc, lv))
    if not field:
        for qp in qps:
            for pos in range(4):
                m = max_level(K_CDC, qp, field, pos, LIM)
                for sign in (1, -1):
                    lv = [0] * 4
                    lv[pos] = sign * m
                    cases.append(Case(K_CDC, qp, field, 0, lv))
    return cases


def zero_cases(rng):
    cases = []
    for qp in (0, 5, 11, 23, 24, 40, 51):
        for kind in range(5):
            for field in ((0, 1) if kind != K_CDC else (0,)):
                cases.append(Case(kind, qp, field, 0, [0] * NCOEF[kind]))
        for field in (0, 1):
            # a DC-only block: every h_ij is d00 itself, so the whole 16-bit range is legal
            # (the random classes' sum|d| condition is only sufficient -- not demanded here)
            for dc in (1, -1, 63, -64, LIM, -LIM - 1, rng.randint(-LIM, LIM)):
                cases.append(Case(K_LAC, qp, field, dc, [0] * 15, strict=False))
                cases.append(Case(K_CAC, qp, field, dc, [0] * 15, strict=False))
    return cases


# ---- real blocks: what the model transforms while decoding a stream --------------------

class Harvest(Exception):
    pass


def real_cases(stream_path, want_field, limit, seed):
    """Wrap the model's transform functions, decode the stream, keep what they were called
    with. Every call is one case; nothing is reconstructed here."""
    import h264_fe_ref as FE
    got = []
    state = {"chroma": False, "field": 0}
    o_dq, o_ldc, o_cdc, o_rc = R.dequant4x4, R.luma_dc, R.chroma_dc, R.SliceDecoder.residual_chroma
    o_dq8 = R.dequant8x8

    def dq(levels, scan, qp, dc=None, ls4=R.LEVEL_SCALE):
        field = 1 if scan is R.FIELD_SCAN else 0
        if len(levels) == 16:
            got.append((K_L4, qp, field, 0, list(levels)))
        else:
            got.append((K_CAC if state["chroma"] else K_LAC, qp, field, dc, list(levels)))
        return o_dq(levels, scan, qp, dc=dc, ls4=ls4)

    def dq8(levels, scan8, qp, ls8):
        got.append((K_L8, qp, 1 if scan8 is HT.FIELD_SCAN8 else 0, 0, list(levels)))
        return o_dq8(levels, scan8, qp, ls8)

    def ldc(levels, scan, qp, ls4=R.LEVEL_SCALE):
        got.append((K_LDC, qp, 1 if scan is R.FIELD_SCAN else 0, 0, list(levels)))
        return o_ldc(levels, scan, qp, ls4)

    def cdc(levels, qp, ls4=R.LEVEL_SCALE):
        got.append((K_CDC, qp, state["field"], 0, list(levels)))
        return o_cdc(levels, qp, ls4)

    def rc(self, m, info):
        state["chroma"] = True
        state["field"] = 1 if self.field else 0
        try:
            return o_rc(self, m, info)
        finally:
            state["chroma"] = False
            if self.field and want_field and len(got) >= limit:
                raise Harvest()

    R.dequant4x4, R.luma_dc, R.chroma_dc, R.SliceDecoder.residual_chroma = dq, ldc, cdc, rc
    R.dequant8x8 = dq8
    try:
        data = open(stream_path, "rb").read()
        try:
            R.decode_file(None, records=FE.decode_stream(data))
        except Harvest:
            pass
    finally:
        R.dequant4x4, R.luma_dc, R.chroma_dc, R.SliceDecoder.residual_chroma = o_dq, o_ldc, o_cdc, o_rc
        R.dequant8x8 = o_dq8
    if want_field == "l8":
        got = [g for g in got if g[0] == K_L8]
    elif want_field:
        got = [g for g in got if g[2] == 1]
    n_all = len(got)
    rng = random.Random(seed)
    if len(got) > limit:
        got = rng.sample(got, limit)
    cases = []
    for kind, qp, field, dc, levels in got:
        cases.append(Case(kind, qp, field, dc if dc is not None else 0, levels, strict=False))
    print("  real: %d blocks transformed by the model, %d kept, %d beyond the random classes'"
          " sum|d| condition (legal: f/h still in range)" % (n_all, len(cases), sum(1 for c in cases if c.tight)))
    return cases


# ---- writing ----------------------------------------------------------------------

def h16(v):
    assert -32768 <= v <= 32767, v
    return "%04x" % (v & 0xFFFF)


def write(stem, cases):
    n_coef = sum(len(c.levels) for c in cases)
    n_out = sum(len(c.out) for c in cases)
    maxd = max([c.maxd for c in cases] + [0])
    with open(stem + ".blk.hex", "w") as f:
        for c in cases:
            wbits = 0 if c.wsel is None else ((1 << 21) | (c.wsel << 18))
            f.write("%08x\n" % ((c.kind << 29) | (c.field << 28) | (c.qp << 22) | wbits | (c.dc & 0xFFFF)))
    with open(stem + ".w.hex", "w") as f:
        for lst in MATRIX:
            for k in range(0, len(lst), 4):
                f.write("%08x\n" % (lst[k] | (lst[k + 1] << 8) | (lst[k + 2] << 16) | (lst[k + 3] << 24)))
    with open(stem + ".coef.hex", "w") as f:
        for c in cases:
            assert len(c.levels) == NCOEF[c.kind]
            f.write("".join(h16(v) + "\n" for v in c.levels))
    with open(stem + ".exp.hex", "w") as f:
        for c in cases:
            assert len(c.out) == NOUT[c.kind]
            f.write("".join(h16(v) + "\n" for v in c.out))
    with open(stem + ".meta.hex", "w") as f:
        f.write("".join("%08x\n" % v for v in (len(cases), n_coef, n_out, maxd)))
    kinds = [sum(1 for c in cases if c.kind == k) for k in range(6)]
    qps = sorted(set(c.qp for c in cases))
    print("  %-22s %6d blocks (%s) qp %d..%d (%d distinct) max|d| %d, %d weighted" % (
        os.path.basename(stem), len(cases), " ".join("%s %d" % (KIND_NAME[k], n) for k, n in enumerate(kinds) if n),
        qps[0], qps[-1], len(qps), maxd, sum(1 for c in cases if c.wsel is not None)))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", required=True, help="the fixture directory")
    ap.add_argument("--stream", help="an Annex-B clip for it_real (the x264 clip the runner makes)")
    ap.add_argument("--field-stream", help="an Annex-B stream with field pictures for it_real_field "
                    "(the runner's: camp_mot_fld0_full from H.264.1; UMD cut a disc here)")
    ap.add_argument("--high-stream", help="an x264 High clip for it_real8 (its 8x8 blocks)")
    ap.add_argument("--per-qp", type=int, default=6, help="random blocks per qp per class")
    ap.add_argument("--real-limit", type=int, default=6000)
    ap.add_argument("--seed", type=int, default=20260923)
    a = ap.parse_args(argv)
    os.makedirs(a.out, exist_ok=True)
    rng = random.Random(a.seed)
    retries = [0]
    global MATRIX
    # a sanity check of the sufficient condition against the model on a few hot blocks
    for kind in range(5):
        for field in (0, 1):
            for qp in (0, 51):
                for pos in range(NCOEF[kind]):
                    lv = [0] * NCOEF[kind]
                    lv[pos] = max_level(kind, qp, field, pos, LIM)
                    Case(kind, qp, field, 0, lv)     # raises RangeError if the bound lies
    for kind in range(5):
        for field in ((0, 1) if kind != K_CDC else (0,)):
            cases = []
            for qp in range(52):
                for _ in range(a.per_qp):
                    cases.append(rand_block(rng, kind, qp, field, retries))
            stem = "it_rand_%s" % KIND_NAME[kind] + ("" if kind == K_CDC else ("_field" if field else "_frame"))
            write(os.path.join(a.out, stem), cases)
    write(os.path.join(a.out, "it_sparse_frame"), sparse_cases(0, rng))
    write(os.path.join(a.out, "it_sparse_field"), sparse_cases(1, rng))
    write(os.path.join(a.out, "it_zero"), zero_cases(rng))
    # H264 Phase 5: weighted lists (random weights 1..255, a random list per block)
    MATRIX = [[rng.randint(1, 255) for _ in range(16)] for _ in range(6)] + \
             [[rng.randint(1, 255) for _ in range(64)] for _ in range(2)]
    for kind in range(5):
        for field in ((0, 1) if kind != K_CDC else (0,)):
            cases = []
            for qp in range(52):
                for _ in range(a.per_qp):
                    cases.append(rand_block(rng, kind, qp, field, retries, wsel=rng.randint(0, 5)))
            stem = "it_w_%s" % KIND_NAME[kind] + ("" if kind == K_CDC else ("_field" if field else "_frame"))
            write(os.path.join(a.out, stem), cases)
    for field in (0, 1):
        cases = []
        for qp in range(52):
            for k in range(a.per_qp):
                cases.append(rand_block8(rng, qp, field, retries, None if k % 2 == 0 else rng.randint(6, 7)))
        write(os.path.join(a.out, "it_rand_L8_" + ("field" if field else "frame")), cases)
        cases = []
        for qp in (0, 7, 13, 26, 35, 36, 51):
            for pos in range(64):
                for sign in (1, -1):
                    wsel = None if sign > 0 else 6 + (pos & 1)
                    m = max_level(K_L8, qp, field, pos, LIM, wsel)
                    if m == 0:
                        continue              # even a level of 1 is out of 8.5.13's range here
                    lv = [0] * 64
                    lv[pos] = sign * m
                    cases.append(Case(K_L8, qp, field, 0, lv, wsel=wsel))
        write(os.path.join(a.out, "it_sparse8_" + ("field" if field else "frame")), cases)
    MATRIX = [[16] * 16] * 6 + [[16] * 64] * 2
    print("  random blocks regenerated for range: %d" % retries[0])
    if a.stream:
        cases = real_cases(a.stream, False, a.real_limit, a.seed)
        if not cases:
            raise SystemExit("itrans_golden: the stream produced no blocks")
        write(os.path.join(a.out, "it_real"), cases)
    if a.field_stream:
        cases = real_cases(a.field_stream, True, a.real_limit, a.seed)
        if not cases:
            raise SystemExit("itrans_golden: the field stream produced no field blocks")
        write(os.path.join(a.out, "it_real_field"), cases)
    if a.high_stream:
        cases = real_cases(a.high_stream, "l8", a.real_limit, a.seed)
        if not cases:
            raise SystemExit("itrans_golden: the High stream produced no 8x8 blocks")
        write(os.path.join(a.out, "it_real8"), cases)
    return 0


if __name__ == "__main__":
    sys.exit(main())
