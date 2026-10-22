#!/usr/bin/env python3
"""Random request streams for cabac_engine.sv, answered by tools/cabac_ref.py: the
golden of bench/h264/run_h264_cabac.sh (docs/h264_frontend.md S3).

A vector set is a random byte stream and a random sequence of the engine's request
kinds (decision on a random ctxIdx, bypass, terminate, context+engine init, byte
alignment, raw byte, engine re-init) driven through the Python model step by step, so
the sequence stays inside defined behaviour: a terminate bin of 1 is always followed by
the I_PCM shape (align, 0..3 raw bytes, re-init) or a new slice (align, init), and the
stream runs until the model would read past its end (that request is dropped: every set
ends with the engine draining its last bits -- the end-of-stream path).

Files (bench/h264/README.md conventions, one word per line):
  <stem>.bytes.hex   the byte stream
  <stem>.req.hex     16-bit words: [15:12] kind, [8:0] ctxIdx (or {set[1:0], qp[5:0]} for init)
  <stem>.exp.hex     16-bit words, one per request: the response (bin, or the raw byte)
  <stem>.ctx.hex     460 x 7-bit {valMPS, pStateIdx} after every init request, in order
  <stem>.meta.hex    [0] n_bytes [1] n_req [2] n_init [3] seed [4] n_bins (decision+bypass+terminate)

    cabac_vectors.py --seed 1 --bytes 3000 --out bench/h264/fixtures/gen/cabac_s1
"""
import argparse
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import cabac_ref as C  # noqa: E402

K_DECISION, K_BYPASS, K_TERMINATE, K_INIT, K_ALIGN, K_RAWBYTE, K_REINIT = range(7)
SET_OF = {0: 0, 1: 1, 2: 2, 3: "I"}


def generate(seed, n_bytes, p_dec=0.70, p_byp=0.24):
    rnd = random.Random(seed)
    data = bytes(rnd.getrandbits(8) for _ in range(n_bytes))
    br = C.BitReader(data)
    cab = C.Cabac(br)
    reqs, exps, ctxs = [], [], []
    pending = []                     # requests queued by a terminate 1 / a new slice

    def init_word():
        return (rnd.randrange(4) << 6) | rnd.randrange(52)

    pending = [(K_INIT, init_word())]
    while True:
        if pending:
            kind, arg = pending.pop(0)
        else:
            r = rnd.random()
            if r < 0.004:
                pending = [(K_INIT, init_word())]
                kind, arg = K_ALIGN, 0
            elif r < p_dec:
                arg = rnd.randrange(460)
                while arg == 276:                    # the terminate context is kind 2's
                    arg = rnd.randrange(460)
                kind = K_DECISION
            elif r < p_dec + p_byp:
                kind, arg = K_BYPASS, 0
            else:
                kind, arg = K_TERMINATE, 0
        pos = br.pos
        try:
            if kind == K_DECISION:
                v = cab.decode(arg)
            elif kind == K_BYPASS:
                v = cab.bypass()
            elif kind == K_TERMINATE:
                v = cab.terminate()
                if v:
                    pending = [(K_ALIGN, 0)] + [(K_RAWBYTE, 0)] * rnd.randrange(4) + \
                              [(K_REINIT, 0) if rnd.random() < 0.5 else (K_INIT, init_word())]
            elif kind == K_INIT:
                cab.init_contexts(arg & 63, SET_OF[arg >> 6])
                cab.init_engine()
                v = 0
            elif kind == K_ALIGN:
                br.byte_align()
                v = 0
            elif kind == K_RAWBYTE:
                v = br.read_bits(8)
            else:
                cab.init_engine()
                v = 0
        except C.CabacError:
            br.pos = pos
            break
        reqs.append((kind << 12) | arg)
        exps.append(v)
        if kind == K_INIT:
            ctxs.extend((cab.val_mps[i] << 6) | cab.p_state[i] for i in range(C.NUM_CTX))
        if len(reqs) > 200000:
            break
    n_bins = sum(1 for r in reqs if (r >> 12) in (K_DECISION, K_BYPASS, K_TERMINATE))
    n_init = sum(1 for r in reqs if (r >> 12) == K_INIT)
    return data, reqs, exps, ctxs, n_bins, n_init


def write(stem, seed, data, reqs, exps, ctxs, n_bins, n_init):
    os.makedirs(os.path.dirname(stem) or ".", exist_ok=True)
    with open(stem + ".bytes.hex", "w") as f:
        f.write("".join("%02x\n" % b for b in data))
    with open(stem + ".req.hex", "w") as f:
        f.write("".join("%04x\n" % r for r in reqs))
    with open(stem + ".exp.hex", "w") as f:
        f.write("".join("%04x\n" % e for e in exps))
    with open(stem + ".ctx.hex", "w") as f:
        f.write("".join("%02x\n" % c for c in ctxs))
    with open(stem + ".meta.hex", "w") as f:
        for v in (len(data), len(reqs), n_init, seed, n_bins):
            f.write("%08x\n" % v)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--bytes", type=int, default=3000)
    ap.add_argument("--p-dec", type=float, default=0.70)
    ap.add_argument("--p-byp", type=float, default=0.24)
    ap.add_argument("--out", required=True)
    a = ap.parse_args(argv)
    data, reqs, exps, ctxs, n_bins, n_init = generate(a.seed, a.bytes, a.p_dec, a.p_byp)
    write(a.out, a.seed, data, reqs, exps, ctxs, n_bins, n_init)
    print("%s: %d bytes, %d requests (%d bins, %d inits)" % (a.out, len(data), len(reqs), n_bins, n_init))
    return 0


if __name__ == "__main__":
    sys.exit(main())
