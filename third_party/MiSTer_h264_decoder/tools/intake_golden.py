#!/usr/bin/env python3
"""Fixtures for bench/h264/mb_intake_tb.sv: a stream's macroblock-layer SE words (the
front end's kinds 1..16 and 20, transform_size_8x8_flag, as the RTL emits them) and, per macroblock, the descriptor
h264/dec/mb_intake.sv must hold -- from tools/h264_recon_ref.py's own intake (its
SliceDecoder.se / block collect the same words into an Mb) and expand_mb(), the layout
the reconstruction consumes (docs/h264_recon.md S2.3).

Files (one hex word per line, $readmemh):
  <stem>.mbw.hex   48-bit words {kind[7:0], aux[7:0], val[31:0]}: the macroblock words
  <stem>.dsc.hex   32-bit words, per macroblock:
     [0]  0xD5C00000 | slice_type << 12 | num_ref_l0 << 6 | num_ref_l1     (the inputs)
     [1]  addr
     [2]  t8 << 29 | skip << 28 | is_intra << 27 | pcm << 26 | end_of_slice << 25 | itype << 20 | mb_type << 14 | cbp << 8 | chroma
     [3]  {sub_types[15:0], qp_delta[7:0] (two's complement)}
     [4]  prev_flag[15:0]
     [5]  rem_mode[31:0]   [6] rem_mode[47:32]
     [7]  refs[31:0]       [8] refs[39:32]
     [9..40]  mvd[lx][blk] {x[15:0], y[15:0]}, list 0 blocks 0..15 then list 1
     [41] pred[31:0]       [42] direct8
     [43] coded[26:0]      [44] nz[15:0]
     [45] n_coef_words, then per coded slot: {slot << 16 | n} and n levels (16-bit, two's
          complement in 32 bits); an 8x8 block (High) as its four slots 1 + 4 b8 + k / 16,
          16 levels each (nz: all four when any level is nonzero -- 8.7.2.1's 8x8 rule);
          I_PCM: {31 << 16 | 384} and the 384 samples
  <stem>.meta.hex  [0] n_words (mbw) [1] n_dsc words [2] macroblocks

    intake_golden.py stream.264 --out bench/h264/fixtures/gen/intake_x [--max-mbs N]
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import h264_fe_ref as FE  # noqa: E402
import h264_recon_ref as RR  # noqa: E402
import h264_top_golden as TG  # noqa: E402

SLOT = {"LDC": lambda i: 0, "L4": lambda i: 1 + i, "CDC": lambda i: 17 + i, "CAC": lambda i: 19 + i}


def build(data, max_mbs=None):
    rec = FE.decode_stream(data)
    words = [w for w in TG.words(rec) if 1 <= w[0] <= 16 or w[0] == 20]
    dsc = []
    n_mbs = [0]
    orig_se = RR.SliceDecoder.se

    def se_hook(self, name, v):
        if name == "end_of_slice_flag":
            m = self.cur
            h = self.h
            st = h.slice_type
            base = {RR.P: 5, RR.B: 23, RR.I: 0}[st]
            e = RR.expand_mb(m, st, h.num_ref_idx)       # None for an intra macroblock
            mbt = 0 if m.skip or m.mb_type is None else m.mb_type
            intra = (not m.skip) and m.mb_type is not None and m.mb_type >= base
            itype = 0 if m.skip else (mbt - base) & 31    # the RTL's mb_type - base, 5 bits (no MB_TYPE word: 0)
            cbp = m.cbp
            if intra and itype not in (0, 25):
                t = itype - 1
                cbp = (15 if t >= 12 else 0) | (((t % 12) // 4) << 4)
            pcm = m.pcm is not None
            w = [0xD5C00000 | (st << 12) | (h.num_ref_idx[0] << 6) | h.num_ref_idx[1], m.addr]
            w.append((int(bool(m.t8)) << 29) | (int(m.skip) << 28) | (int(intra) << 27) | (int(pcm) << 26) | (v << 25) | ((itype & 31) << 20)
                     | ((mbt & 63) << 14) | ((cbp & 63) << 8) | (m.chroma_mode & 3))
            subs = 0
            for i, t in enumerate(m.sub_types):
                subs |= (t & 15) << (4 * i)
            w.append((subs << 8) | (m.qp_delta & 0xFF))
            pf = 0
            rem = 0
            for i, f in enumerate(m.prev_flags):
                pf |= f << i
            for i, r in enumerate(m.rem_modes):
                if r is not None:
                    rem |= (r & 7) << (3 * i)
            w += [pf, rem & 0xFFFFFFFF, rem >> 32]
            if e is None:
                refs, mvd, pred, direct = [[0] * 4, [0] * 4], [[(0, 0)] * 16, [(0, 0)] * 16], [[0] * 16, [0] * 16], [0] * 4
            else:
                refs, mvd, pred, direct = e
            if m.skip:
                pred = [[0] * 16, [0] * 16]           # P_Skip / B_Skip: mv_pred's
            rr = 0
            for lx in range(2):
                for sl in range(4):
                    rr |= (refs[lx][sl] & 31) << (5 * (4 * lx + sl))
            w += [rr & 0xFFFFFFFF, rr >> 32]
            for lx in range(2):
                for b in range(16):
                    x, y = mvd[lx][b]
                    w.append(((x & 0xFFFF) << 16) | (y & 0xFFFF))
            pp = 0
            for lx in range(2):
                for b in range(16):
                    pp |= pred[lx][b] << (16 * lx + b)
            dd = 0
            for i, d in enumerate(direct):
                dd |= d << i
            w += [pp, dd]
            coded = 0
            nz = 0
            coefs = []
            for kind, idx, lv in m.blocks:
                if kind == "L8":
                    for j in range(4):
                        coded |= 1 << (1 + 4 * idx + j)
                        if any(lv):
                            nz |= 1 << (4 * idx + j)
                        coefs.append(((1 + 4 * idx + j) << 16) | 16)
                        coefs += [c & 0xFFFFFFFF for c in lv[16 * j:16 * j + 16]]
                    continue
                sl = SLOT[kind](idx)
                coded |= 1 << sl
                if kind == "L4" and any(lv):
                    nz |= 1 << idx
                coefs.append((sl << 16) | len(lv))
                coefs += [c & 0xFFFFFFFF for c in lv]
            if pcm:
                coefs.append((31 << 16) | len(m.pcm))
                coefs += [c & 0xFFFFFFFF for c in m.pcm]
            w += [coded, nz, len(coefs)] + coefs
            if max_mbs is None or n_mbs[0] < max_mbs:
                dsc.extend(w)
            n_mbs[0] += 1
        return orig_se(self, name, v)

    RR.SliceDecoder.se = se_hook
    try:
        dec = RR.Decoder()
        dec.feed(rec)
    finally:
        RR.SliceDecoder.se = orig_se
    if max_mbs is not None and n_mbs[0] > max_mbs:
        # cut the words at the start of macroblock max_mbs
        k = 0
        for i, wd in enumerate(words):
            if wd[0] == 1:
                if k == max_mbs:
                    words = words[:i]
                    break
                k += 1
        n_mbs[0] = max_mbs
    return words, dsc, n_mbs[0]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("stream")
    ap.add_argument("--out", required=True)
    ap.add_argument("--max-mbs", type=int)
    a = ap.parse_args(argv)
    words, dsc, n = build(open(a.stream, "rb").read(), a.max_mbs)
    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    with open(a.out + ".mbw.hex", "w") as f:
        for kind, aux, val in words:
            f.write("%02x%02x%08x\n" % (kind, aux, val & 0xFFFFFFFF))
    with open(a.out + ".dsc.hex", "w") as f:
        f.write("".join("%08x\n" % (v & 0xFFFFFFFF) for v in dsc))
    with open(a.out + ".meta.hex", "w") as f:
        f.write("%08x\n%08x\n%08x\n" % (len(words), len(dsc), n))
    print("%s: %d macroblocks, %d words, %d descriptor words" % (a.out, n, len(words), len(dsc)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
