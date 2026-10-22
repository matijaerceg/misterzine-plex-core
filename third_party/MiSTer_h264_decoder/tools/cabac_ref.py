#!/usr/bin/env python3
"""The CABAC arithmetic decoding engine of ITU-T H.264 clause 9.3, as a bit-exact
Python model: the reference `cabac_engine.sv` is scored against (docs/h264_frontend.md
S2), and the engine `tools/h264_fe_ref.py` drives to decode whole slices.

Written from the spec's own text (9.3.1.1 context initialisation, 9.3.1.2 engine
initialisation, 9.3.3.2.1 DecodeDecision, 9.3.3.2.2 RenormD, 9.3.3.2.3 DecodeBypass,
9.3.3.2.4 DecodeTerminate) with the tables of tools/cabac_tables.py (transcribed from the
PDF, cross-checked against ffmpeg and JM). Nothing here is written from memory of an
implementation: where the spec and a decoder's shortcut differ, the spec wins and the
golden diff (h264_fe_ref.py vs JM's trace) is the arbiter.

Register widths are the spec's: codIRange 9 bits after renormalisation, codIOffset 9
bits (10 during a bypass). The RTL is required to hold exactly these.
"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cabac_tables import CTX_INIT, RANGE_LPS, TRANS_IDX_LPS, TRANS_IDX_MPS, NUM_CTX  # noqa: E402

CTX_TERMINATE = 276


class CabacError(Exception):
    pass


class BitReader(object):
    """MSB-first reader over an RBSP (emulation-prevention bytes already removed)."""

    def __init__(self, data, pos=0):
        self.data = data
        self.pos = pos            # in bits
        self.nbits = len(data) * 8

    def read_bit(self):
        if self.pos >= self.nbits:
            raise CabacError("read past the end of the RBSP (bit %d of %d)" % (self.pos, self.nbits))
        b = (self.data[self.pos >> 3] >> (7 - (self.pos & 7))) & 1
        self.pos += 1
        return b

    def read_bits(self, n):
        v = 0
        for _ in range(n):
            v = (v << 1) | self.read_bit()
        return v

    def peek_bits(self, n):
        p = self.pos
        try:
            return self.read_bits(n)
        finally:
            self.pos = p

    def ue(self):
        """Exp-Golomb ue(v), 9.1."""
        zeros = 0
        while self.read_bit() == 0:
            zeros += 1
            if zeros > 32:
                raise CabacError("ue(v) with more than 32 leading zeros")
        return (1 << zeros) - 1 + (self.read_bits(zeros) if zeros else 0)

    def se(self):
        k = self.ue()
        return (k + 1) >> 1 if k & 1 else -(k >> 1)

    def byte_aligned(self):
        return (self.pos & 7) == 0

    def byte_align(self):
        while not self.byte_aligned():
            self.read_bit()

    def bits_left(self):
        return self.nbits - self.pos

    def more_rbsp_data(self):
        """7.2: data remains before the rbsp_stop_one_bit and trailing zeros."""
        if self.pos >= self.nbits:
            return False
        # find the last set bit of the RBSP
        i = len(self.data) - 1
        while i >= 0 and self.data[i] == 0:
            i -= 1
        if i < 0:
            return False
        last = self.data[i]
        tz = 0
        while not (last >> tz) & 1:
            tz += 1
        stop_pos = i * 8 + (7 - tz)
        return self.pos < stop_pos


def clip3(lo, hi, v):
    return lo if v < lo else hi if v > hi else v


class Cabac(object):
    """One slice's decoding engine and its 460 context variables."""

    def __init__(self, reader):
        self.br = reader
        self.p_state = [0] * NUM_CTX
        self.val_mps = [0] * NUM_CTX
        self.rng = 0
        self.off = 0
        self.bins = 0              # decoded bins, for the throughput measure
        self.bins_bypass = 0
        self.trace = None          # a list: (ctxIdx | 'B' | 'T', bin) per bin, for bench debugging

    # 9.3.1.1
    def init_contexts(self, slice_qp, init_set):
        tab = CTX_INIT[init_set]
        qp = clip3(0, 51, slice_qp)
        for i in range(NUM_CTX):
            # a context the spec marks "na" for this set is never used by a conformant
            # stream; it is initialised as (m, n) = (0, 0) would be (pStateIdx 62, valMPS 0),
            # the one definition the RTL's zero ROM word and this model share
            m, n = tab[i] if tab[i] is not None else (0, 0)
            pre = clip3(1, 126, ((m * qp) >> 4) + n)
            if pre <= 63:
                self.p_state[i] = 63 - pre
                self.val_mps[i] = 0
            else:
                self.p_state[i] = pre - 64
                self.val_mps[i] = 1

    # 9.3.1.2
    def init_engine(self):
        self.rng = 510
        self.off = self.br.read_bits(9)
        if self.off >= 510:
            raise CabacError("codIOffset %d at initialisation (bitstream violation)" % self.off)

    # 9.3.3.2.1 + 9.3.3.2.2
    def decode(self, ctx):
        if ctx == CTX_TERMINATE:
            return self.terminate()
        p = self.p_state[ctx]
        q = (self.rng >> 6) & 3
        r_lps = RANGE_LPS[p][q]
        self.rng -= r_lps
        if self.off >= self.rng:
            b = 1 - self.val_mps[ctx]
            self.off -= self.rng
            self.rng = r_lps
            if p == 0:
                self.val_mps[ctx] = 1 - self.val_mps[ctx]
            self.p_state[ctx] = TRANS_IDX_LPS[p]
        else:
            b = self.val_mps[ctx]
            self.p_state[ctx] = TRANS_IDX_MPS[p]
        while self.rng < 256:
            self.rng <<= 1
            self.off = (self.off << 1) | self.br.read_bit()
        self.bins += 1
        if self.trace is not None:
            self.trace.append((ctx, b))
        return b

    # 9.3.3.2.3
    def bypass(self):
        self.off = (self.off << 1) | self.br.read_bit()
        self.bins += 1
        self.bins_bypass += 1
        b = 1 if self.off >= self.rng else 0
        if b:
            self.off -= self.rng
        if self.trace is not None:
            self.trace.append(("B", b))
        return b

    # 9.3.3.2.4
    def terminate(self):
        self.rng -= 2
        self.bins += 1
        if self.trace is not None:
            self.trace.append(("T", 1 if self.off >= self.rng else 0))
        if self.off >= self.rng:
            # binVal 1: no renormalisation; the last bit read is the flushed 1 (the
            # rbsp_stop_one_bit at a slice end, or the bit before pcm_alignment_zero_bits)
            return 1
        while self.rng < 256:
            self.rng <<= 1
            self.off = (self.off << 1) | self.br.read_bit()
        return 0

    # ---- binarisation helpers (9.3.2), each taking a ctxIdx function of binIdx

    def decode_unary(self, ctx_of_bin, c_max=None):
        """U (c_max None) or TU: count 1 bins until a 0 (or c_max)."""
        v = 0
        while c_max is None or v < c_max:
            if not self.decode(ctx_of_bin(v)):
                break
            v += 1
        return v

    def decode_ueg(self, ctx_of_bin, u_coff, k, signed):
        """UEGk (9.3.2.3): TU prefix with cMax = uCoff under contexts, then an
        Exp-Golomb suffix and the sign in bypass."""
        v = self.decode_unary(ctx_of_bin, u_coff)
        if v >= u_coff:
            while self.bypass():
                v += 1 << k
                k += 1
            while k > 0:
                k -= 1
                v += self.bypass() << k
        if signed and v != 0:
            if self.bypass():
                v = -v
        return v

    def decode_fixed(self, ctx, n):
        """FL with a single context, LSB first (rem_intra4x4_pred_mode)."""
        v = 0
        for i in range(n):
            v |= self.decode(ctx) << i
        return v
