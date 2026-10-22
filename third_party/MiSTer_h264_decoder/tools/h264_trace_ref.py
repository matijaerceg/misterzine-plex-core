#!/usr/bin/env python3
"""H.264 syntax-element golden for the Phase 3 front end: JM `ldecod` traces (and the
H.264.1 conformance packages' donated `-trace.txt` files) normalised to one canonical
SE stream, so that the RTL's typed SE FIFO can be scored against it bit-exact and the
normaliser itself can be proven by diffing the two independent trace sources.

Two input formats, one output (docs/h264_frontend.md "The SE golden"):

  JM 18.4 `trace_dec.txt` (tools/jm_build.sh builds ldecod with TRACE 1):
    @<bit>  SPS: name   <bits> (value)      header fields, spec names with a prefix
    @<sym>  mb_type                (value)  CABAC SEs, JM's OWN value conventions:
                                            mb_skip_flag is INVERTED (1 = not skipped),
                                            P-slice mb_type is spec + 1,
                                            intra4x4_pred_mode is -1 (use predicted) or rem
    @<sym>  Luma sng    level  run          residual (level, run) pairs, a `0 0` line
                                            ends each block (also a cbf=0 block)
    JM traces every slice header of a picture (and the next picture's first) BEFORE
    the macroblocks of that picture: headers and MB groups are paired by order.

  The 2004-era JVT trace the conformance zips carry (Sony's donation tooling):
    @<hex> : name : value : (bits) : [bitstring]     spec values; per-bin CABAC
    flags for the residual (significant_coeff_flag / last / abs_level / sign) under a
    `luma.dc_ac : BK n` label that names the block's SPEC index; mb_skip_flag is
    printed BEFORE the `+++ MB n` line it belongs to.

Canonical stream, one record per line, spec names and spec values throughout:
    N <nal_unit_type> <nal_ref_idc>
    S <field> <value>                 SPS / PPS / slice-header field, syntax order
    M <mb_addr>                       macroblock start (absolute address)
    E <se> <value>                    an SE of the macroblock, syntax order
                                      (prev_intra4x4_pred_mode_flag / rem_..., not JM's -1)
    B <kind> <idx> <n> <c0> ... <cn>  a residual block, coefficients in scan order:
                                      LDC (Intra16x16 DC, 16), L4 (4x4 luma, idx = the
                                      spec 4x4 block index, 16 or 15 for Intra16x16 AC),
                                      CDC (chroma DC, idx 0 Cb / 1 Cr, 4), CAC (chroma AC,
                                      idx 0-3 Cb, 4-7 Cr, 15), L8 (8x8 luma, High:
                                      idx = luma8x8BlkIdx, 64). A block with
                                      coded_block_flag 0 is all zeros.
    B PCM 0 384 <s0> ... <s383>       an I_PCM macroblock's samples (256 luma, 64 Cb, 64 Cr)
Dropped from both: rbsp trailing/alignment bits, reserved bits, JM's bit positions,
the donated `initialize` line and its first-bin `intra_16x16_decision` (part of mb_type).

    h264_trace_ref.py --jm stream.264 -o golden.txt      run ldecod, normalise its trace
    h264_trace_ref.py --jm-trace trace_dec.txt -o ...    normalise an existing JM trace
    h264_trace_ref.py --jvt X-trace.txt -o ...           normalise a donated trace
    h264_trace_ref.py --diff a.txt b.txt                 first difference, exit 1 if any

The pixel check that makes a trace trustworthy (JM decoded what ffmpeg decodes):
    ffmpeg -i x.264 -fps_mode passthrough -f rawvideo -pix_fmt yuv420p x_ff.yuv && cmp x.yuv x_ff.yuv
(`passthrough`: on a 3:2 `pic_struct` stream ffmpeg otherwise repeats frames to 29.97).
UMD's `--disc` input (a disc image's video ES) is not carried in this fork.

ldecod is found at $H264_REFS_DIR/JM/build_trace/bin/ldecod.exe ($H264_JM_DIR/build_trace
overrides). Refused loudly (never guessed): MBAFF (`mb_field_decoding_flag`), CAVLC
slices, anything else this decoder does not decode. H264 Phase 5: High profile's
transform_size_8x8_flag, the Intra_8x8 modes (JM traces them as intra4x4_pred_mode:
named by the macroblock's transform_size_8x8_flag here) and the 8x8 blocks (JM:
`Luma8x8 DC sng` for the first (level, run) pair, `Luma8x8 sng` after it) are
normalised; the donated 2004 traces are not read for High streams (JM + pixels).
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))

SLICE_P, SLICE_B, SLICE_I = 0, 1, 2    # spec slice_type % 5 and JM's enum agree (P0 B1 I2)


class TraceError(Exception):
    pass


# ---------------------------------------------------------------- spec helpers

def is_i16(slice_type, mb_type):
    """Is this (spec) mb_type an Intra_16x16 one in a slice of this type?"""
    base = {SLICE_I: 0, SLICE_P: 5, SLICE_B: 23}[slice_type]
    return base + 1 <= mb_type <= base + 24


def is_intra(slice_type, mb_type):
    base = {SLICE_I: 0, SLICE_P: 5, SLICE_B: 23}[slice_type]
    return mb_type >= base


def i16_cbp(slice_type, mb_type):
    """CodedBlockPattern implied by an Intra_16x16 mb_type (Table 7-11)."""
    base = {SLICE_I: 0, SLICE_P: 5, SLICE_B: 23}[slice_type]
    t = mb_type - base - 1
    luma = 15 if t >= 12 else 0
    chroma = (t % 12) // 4
    return luma | (chroma << 4)


def expected_blocks(slice_type, mb_type, cbp, t8=0):
    """The residual blocks a macroblock carries, in syntax order (7.3.5.3, 7.3.5.3.1),
    as (kind, idx, n_coeff); t8 = transform_size_8x8_flag (CABAC: one 64-coefficient
    block per coded 8x8)."""
    out = []
    i16 = is_i16(slice_type, mb_type)
    if i16:
        out.append(("LDC", 0, 16))
        if cbp & 15:
            for b in range(16):
                out.append(("L4", b, 15))
    else:
        for b8 in range(4):
            if cbp & (1 << b8):
                if t8:
                    out.append(("L8", b8, 64))
                    continue
                for b in range(4):
                    out.append(("L4", 4 * b8 + b, 16))
    chroma = cbp >> 4
    if chroma:
        out.append(("CDC", 0, 4))
        out.append(("CDC", 1, 4))
    if chroma == 2:
        for b in range(8):
            out.append(("CAC", b, 15))
    return out


# ---------------------------------------------------------------- header field names

# JM's names -> the spec's (the donated trace mostly uses the spec's 2003 names; the
# few that changed are aliased too). Keyed by (context, jm_name).
ALIAS = {
    "constrained_set0_flag": "constraint_set0_flag",
    "constrained_set1_flag": "constraint_set1_flag",
    "constrained_set2_flag": "constraint_set2_flag",
    "num_ref_idx_override_flag": "num_ref_idx_active_override_flag",
    "adaptive_ref_pic_buffering_flag": "adaptive_ref_pic_marking_mode_flag",
    "pic_order_present_flag": "bottom_field_pic_order_in_frame_present_flag",
    "ref_pic_list_reordering_flag_l0": "ref_pic_list_modification_flag_l0",
    "ref_pic_list_reordering_flag_l1": "ref_pic_list_modification_flag_l1",
    "reordering_of_pic_nums_idc": "modification_of_pic_nums_idc",
    "reordering_of_pic_nums_idc_l0": "modification_of_pic_nums_idc_l0",
    "reordering_of_pic_nums_idc_l1": "modification_of_pic_nums_idc_l1",
    "long_term_pic_idx_l0": "long_term_pic_num_l0",
    "long_term_pic_idx_l1": "long_term_pic_num_l1",
    "max_long_term_pic_idx_plus1": "max_long_term_frame_idx_plus1",
    "seq_scaling_list_present_flag": "seq_scaling_list_present_flag[i]",
    "pic_scaling_list_present_flag": "pic_scaling_list_present_flag[i]",
    "delta_sl": "delta_scale",
}
# JM's VUI names that are not the spec's (ldecod parset.c), and the HRD loop's fields,
# which the canonical stream names with [i] like offset_for_ref_frame[i]
VUI_ALIAS = {
    "color_description_present_flag": "colour_description_present_flag",
    "num_reorder_frames": "max_num_reorder_frames",
    "bit_rate_value_minus1": "bit_rate_value_minus1[i]",
    "cpb_size_value_minus1": "cpb_size_value_minus1[i]",
    "cbr_flag": "cbr_flag[i]",
}
# JM holds these unsigned 32-bit VUI fields in an int and prints 2^32 - 1 as -1
VUI_U32 = {"num_units_in_tick", "time_scale", "bit_rate_value_minus1[i]", "cpb_size_value_minus1[i]"}
# JM traces the PPS default counts under the SH name
PPS_ALIAS = {
    "num_ref_idx_l0_active_minus1": "num_ref_idx_l0_default_active_minus1",
    "num_ref_idx_l1_active_minus1": "num_ref_idx_l1_default_active_minus1",
}
DROP = re.compile(r"^(rbsp_|reserved_zero|constrained_set[345]|constraint_set[345]|"
                  r"cabac_alignment|pcm_alignment|forbidden_zero_bit$|nal_ref_idc$|nal_unit_type$|"
                  r"initialize$|intra_16x16_decision$)")
REFUSE = {"mb_field_decoding_flag",
          "mb_field_decoding_flag (of following bottom MB)",
          "mb_skip_flag (of following bottom MB)"}


def canon_field(ctx, name):
    name = name.strip()
    if ctx == "PPS":
        name = PPS_ALIAS.get(name, name)
    if ctx == "VUI":
        name = VUI_ALIAS.get(name, name)
    return ALIAS.get(name, name)


# ---------------------------------------------------------------- macroblock builder

class Mb(object):
    """One macroblock being assembled: SEs in order, then finalised into records."""

    def __init__(self, addr, slice_type):
        self.addr = addr
        self.slice_type = slice_type
        self.items = []       # ("E", name, value) | ("B", kind, idx, coeffs)
        self.mb_type = None
        self.cbp = None
        self.skipped = False
        self.wild = False     # mb_type not traced (Sony's tracer, intra MBs in P/B): blocks come from labels
        self.pcm = False
        self.pcm_samples = []
        self.t8 = 0

    def se(self, name, value):
        if name in REFUSE:
            raise TraceError("MB %d: %s -- MBAFF is refused" % (self.addr, name))
        if name == "transform_size_8x8_flag":
            self.t8 = value
        if name == "mb_type":
            self.mb_type = value
            if is_i16(self.slice_type, value):
                self.cbp = i16_cbp(self.slice_type, value)
            elif value - {SLICE_I: 0, SLICE_P: 5, SLICE_B: 23}[self.slice_type] == 25:
                self.pcm = True
        elif name == "coded_block_pattern":
            self.cbp = value
        elif name == "mb_skip_flag" and value == 1:
            self.skipped = True
        self.items.append(("E", name, value))

    def block(self, kind, idx, coeffs):
        self.items.append(("B", kind, idx, coeffs))

    def pcm_sample(self, v):
        """one of an I_PCM macroblock's 384 samples, in stream order"""
        if not self.pcm:
            raise TraceError("MB %d: PCM sample in a macroblock that is not I_PCM" % self.addr)
        self.pcm_samples.append(v)
        if len(self.pcm_samples) == 384:
            self.block("PCM", 0, self.pcm_samples)

    def infer_intra(self, first_se):
        """The donated tracer prints no mb_type for an intra MB in a P/B slice. I_NxN is
        exact (its first SE is prev_intra4x4_pred_mode_flag); Intra_16x16 carries the
        prediction mode inside mb_type, which is lost: the record becomes `E mb_type *`
        and the residual blocks are taken from the trace's own labels."""
        base = {SLICE_I: 0, SLICE_P: 5, SLICE_B: 23}[self.slice_type]
        if first_se == "prev_intra4x4_pred_mode_flag":
            self.se("mb_type", base)
        else:
            self.wild = True
            self.items.append(("E", "mb_type", "*"))

    def records(self):
        out = ["M %d" % self.addr]
        for it in self.items:
            if it[0] == "E":
                out.append("E %s %s" % (it[1], it[2]))
            else:
                out.append("B %s %d %d %s" % (it[1], it[2], len(it[3]),
                                              " ".join(str(c) for c in it[3])))
        return out

    def expected(self):
        if self.wild:
            return None
        if self.skipped or self.mb_type is None:
            return []
        if self.pcm:
            if len(self.pcm_samples) != 384:
                raise TraceError("MB %d: I_PCM with %d samples" % (self.addr, len(self.pcm_samples)))
            return []
        if self.cbp is None:
            raise TraceError("MB %d: mb_type %d without a coded_block_pattern" % (self.addr, self.mb_type))
        return expected_blocks(self.slice_type, self.mb_type, self.cbp, self.t8)


# ---------------------------------------------------------------- JM trace

JM_NALU = re.compile(r"^Annex B NALU w/ (?:long|short) startcode, len (\d+), forbidden_bit (\d+), "
                     r"nal_reference_idc (\d+), nal_unit_type (\d+)")
JM_MB = re.compile(r"^\*+ POC: (-?\d+) \(I/P\) MB: (\d+) Slice: (\d+) Type (\d+) \*+")
JM_SE = re.compile(r"^@(\d+)\s+(.*?)\s+(?:([01]+)\s+)?\(\s*(-?\d+)\)\s*$")
JM_RL = re.compile(r"^@(\d+)\s+(.*?)\s+(-?\d+)\s+(\d+)\s*$")
JM_BLOCK = {"DC luma 16x16": "LDC", "Luma sng": "L4", "2x2 DC Chroma": "CDC", "AC Chroma": "CAC",
            "Luma8x8 DC sng": "L8", "Luma8x8 sng": "L8"}
JM_MB_SE = {"mb_skip_flag", "mb_type", "sub_mb_type", "intra4x4_pred_mode", "intra_chroma_pred_mode",
            "coded_block_pattern", "mb_qp_delta", "end_of_slice_flag", "transform_size_8x8_flag"}
JM_MV_SE = re.compile(r"^(mvd|ref_idx|mvd0|mvd1)_l([01])$")


class JmMbGroup(object):
    """The macroblocks of one slice, as JM emitted them. JM does not decode the
    end_of_slice_flag of a picture's LAST macroblock (it stops on the MB count), so a
    group also ends when the next MB line carries another (POC, slice) key or a lower
    address, or when NAL headers follow; that MB then gets the `1` the bitstream holds."""

    def __init__(self, slice_type, key):
        self.slice_type = slice_type
        self.key = key
        self.mbs = []
        self.first_addr = None
        self.last_addr = None

    def finish(self):
        if self.mbs:
            last = self.mbs[-1]
            if not any(i[0] == "E" and i[1] == "end_of_slice_flag" for i in last.items):
                last.items.append(("E", "end_of_slice_flag", 1))


def parse_jm(lines):
    """JM trace_dec.txt -> canonical records."""
    nals = []          # [ (type, ref_idc, [ "S ..." ]) ]
    groups = []        # [JmMbGroup]
    cur_nal = None
    cur_group = None
    mb = None
    blocks = None      # expected blocks remaining for `mb`
    coeffs = None      # the block being filled: [kind, idx, n, pos, values]
    ctx = None

    def close_mb():
        nonlocal mb, blocks, coeffs
        if mb is None:
            return
        if coeffs is not None:
            raise TraceError("MB %d: block %s %d unterminated" % (mb.addr, coeffs[0], coeffs[1]))
        if blocks:
            raise TraceError("MB %d: %d residual blocks expected but not traced" % (mb.addr, len(blocks)))
        cur_group.mbs.append(mb)
        mb = None
        blocks = None

    try:
        for lineno, ln in enumerate(lines, 1):
            ln = ln.rstrip("\n")
            if not ln.strip():
                continue
            m = JM_NALU.match(ln)
            if m:
                close_mb()
                if cur_group is not None:
                    cur_group.finish()
                    cur_group = None
                cur_nal = (int(m.group(4)), int(m.group(3)), [])
                nals.append(cur_nal)
                ctx = {7: "SPS", 8: "PPS", 1: "SH", 5: "SH"}.get(cur_nal[0])
                continue
            if ln.startswith("Last NALU in File"):
                continue
            m = JM_MB.match(ln)
            if m:
                close_mb()
                poc, addr, slice_nr, jtype = int(m.group(1)), int(m.group(2)), int(m.group(3)), int(m.group(4))
                if jtype not in (SLICE_P, SLICE_B, SLICE_I):
                    raise TraceError("JM slice type %d (SP/SI) is refused" % jtype)
                key = (poc, slice_nr)
                if cur_group is not None and (cur_group.key != key or addr <= cur_group.last_addr):
                    cur_group.finish()
                    cur_group = None
                if cur_group is None:
                    cur_group = JmMbGroup(jtype, key)
                    cur_group.first_addr = addr
                    groups.append(cur_group)
                elif cur_group.slice_type != jtype:
                    raise TraceError("MB %d: slice type changed inside a slice" % addr)
                cur_group.last_addr = addr
                mb = Mb(addr, jtype)
                continue
            m = JM_RL.match(ln)
            if m and m.group(2).strip() in JM_BLOCK:
                if mb is None:
                    raise TraceError("residual outside a macroblock: %s" % ln)
                name, level, run = m.group(2).strip(), int(m.group(3)), int(m.group(4))
                if blocks is None:
                    blocks = mb.expected()
                if coeffs is None:
                    if not blocks:
                        raise TraceError("MB %d: unexpected residual block (%s)" % (mb.addr, name))
                    kind, idx, n = blocks.pop(0)
                    if JM_BLOCK[name] != kind:
                        raise TraceError("MB %d: block order: JM %s, expected %s %d" % (mb.addr, name, kind, idx))
                    coeffs = [kind, idx, n, 0, [0] * n]
                if level == 0:
                    mb.block(coeffs[0], coeffs[1], coeffs[4])
                    coeffs = None
                else:
                    pos = coeffs[3] + run
                    if pos >= coeffs[2]:
                        raise TraceError("MB %d: coefficient %d past the end of a %d-coefficient block" % (mb.addr, pos, coeffs[2]))
                    coeffs[4][pos] = level
                    coeffs[3] = pos + 1
                continue
            m = JM_SE.match(ln)
            if m:
                name, value = m.group(2).strip(), int(m.group(4))
                if name in REFUSE:
                    raise TraceError("%s -- MBAFF is refused" % name)
                mv = JM_MV_SE.match(name)
                if name.startswith("pcm_byte "):
                    if mb is None:
                        raise TraceError("pcm_byte outside a macroblock: %s" % ln)
                    mb.pcm_sample(value)
                    continue
                if name in JM_MB_SE or mv:
                    if mb is None:
                        raise TraceError("MB syntax outside a macroblock: %s" % ln)
                    if coeffs is not None:
                        raise TraceError("MB %d: %s inside a residual block" % (mb.addr, name))
                    if name == "mb_skip_flag":
                        mb.se(name, 1 - value)               # JM: 1 = NOT skipped
                    elif name == "mb_type":
                        mb.se(name, value - 1 if mb.slice_type == SLICE_P else value)
                    elif name == "intra4x4_pred_mode":
                        sz = "8x8" if mb.t8 else "4x4"          # JM's one name for both
                        if value < 0:
                            mb.se("prev_intra%s_pred_mode_flag" % sz, 1)
                        else:
                            mb.se("prev_intra%s_pred_mode_flag" % sz, 0)
                            mb.se("rem_intra%s_pred_mode" % sz, value)
                    elif mv:
                        base = mv.group(1)
                        if base in ("mvd0", "mvd1"):
                            base = "mvd"
                        mb.se("%s_l%s" % (base, mv.group(2)), value)
                    elif name == "end_of_slice_flag":
                        if blocks is None:
                            blocks = mb.expected()
                        mb.se(name, value)
                        close_mb()
                        if value == 1:
                            cur_group = None
                    else:
                        mb.se(name, value)
                    continue
                # a header field
                if ":" in name:
                    pfx, _, fname = name.partition(":")
                    pfx = pfx.strip()
                    if pfx == "" and fname.strip() == "delta_sl" and ctx in ("SPS", "PPS"):
                        pfx = ctx               # JM's scaling_list(): "   : delta_sl"
                    if pfx in ("SPS", "PPS", "SH", "VUI", "SEI"):
                        if cur_nal is None:
                            raise TraceError("header field before any NAL: %s" % ln)
                        if pfx == "SEI":
                            continue      # SEI payloads: pic_timing is checked against ffmpeg's trace (P5c)
                        fname = canon_field(pfx, fname)
                        if pfx == "VUI" and fname in VUI_U32:
                            value &= 0xFFFFFFFF
                        if not DROP.match(fname):
                            cur_nal[2].append("S %s %d" % (fname, value))
                        continue
                raise TraceError("unrecognised JM trace line: %s" % ln)
            raise TraceError("unrecognised JM trace line: %s" % ln)
    except TraceError as e:
        raise TraceError("line %d: %s" % (lineno, e))
    close_mb()
    if cur_group is not None:
        cur_group.finish()

    # pair slice NALs with MB groups, in order
    out = []
    gi = 0
    for ntype, ref_idc, fields in nals:
        out.append("N %d %d" % (ntype, ref_idc))
        out.extend(fields)
        if ntype in (1, 5):
            if gi >= len(groups):
                raise TraceError("slice NAL #%d has no macroblocks in the trace" % gi)
            g = groups[gi]
            gi += 1
            first = _field(fields, "first_mb_in_slice")
            if first is not None and g.first_addr != first:
                raise TraceError("slice %d: header first_mb_in_slice %d, macroblocks start at %d"
                                 % (gi - 1, first, g.first_addr))
            for m in g.mbs:
                out.extend(m.records())
    if gi != len(groups):
        raise TraceError("%d macroblock groups for %d slice NALs" % (len(groups), gi))
    return out


def _field(fields, name):
    for f in fields:
        _, n, v = f.split(" ", 2)
        if n == name:
            return int(v)
    return None


# ---------------------------------------------------------------- donated (JVT) trace

JVT_SE = re.compile(r"^@([0-9A-Fa-f]+)\s*:\s*(.*?)\s*:\s*(-?\d*)\s*:\s*\((\d+)\)\s*:\s*\[([01]*)\]\s*$")
JVT_NAL = re.compile(r"^<<< Begin Nal Unit \[(\d+)\]")
JVT_MB = re.compile(r"^\+\+\+ MB (\d+)$")
JVT_BLK = re.compile(r"^(luma\.intra_dc|luma\.dc_ac|chroma\.dc|chroma\.ac) : BK (\d+)$")
JVT_LIST = re.compile(r"^l([01]) \( [FB]W \) (?:mvd|ref_idx) : BK \d+$")
JVT_LABEL = re.compile(r"^(mvd : BK \d+|intra4x4 : BK \d+|"
                       r"@@@ DCT block bits : \d+|\*+ Start Pic \d+ \*+|>>> .*|<<< Begin .*)$")
JVT_EOS = re.compile(r"^\+\+\+ end_of_slice_flag of MB (\d+)$")
JVT_KIND = {"luma.intra_dc": "LDC", "luma.dc_ac": "L4", "chroma.dc": "CDC", "chroma.ac": "CAC"}
JVT_HDR_SE = {"forbidden_zero_bit", "nal_ref_idc", "nal_unit_type"}


class _JvtBlock(object):
    def __init__(self, kind, idx, n):
        self.kind, self.idx, self.n = kind, idx, n
        self.cbf = None
        self.sig = []        # significant positions in scan order
        self.pos = 0         # next scan position awaiting a significant_coeff_flag
        self.levels = []     # (abs_minus1, sign) in decode (reverse) order
        self.pending = None

    def feed(self, name, value):
        if name == "coded_block_flag":
            self.cbf = value
        elif name == "significant_coeff_flag":
            if value:
                self.sig.append(self.pos)
            self.pos += 1
        elif name == "last_significant_coeff_flag":
            if value:
                self.pos = self.n      # map complete
        elif name == "coeff_abs_level_minus1":
            self.pending = value
        elif name == "coeff_sign_flag":
            self.levels.append((self.pending, value))
            self.pending = None
        else:
            return False
        return True

    def coeffs(self):
        c = [0] * self.n
        if not self.cbf:
            return c
        sig = list(self.sig)
        if self.pos < self.n:
            # the map ran to the last position without a last flag: it is significant
            if self.pos != self.n - 1:
                raise TraceError("significance map stopped at %d of %d" % (self.pos, self.n))
            sig.append(self.n - 1)
        if len(self.levels) != len(sig):
            raise TraceError("%d significant coefficients, %d levels" % (len(sig), len(self.levels)))
        for p, (a, s) in zip(reversed(sig), self.levels):
            c[p] = -(a + 1) if s else a + 1
        return c


def parse_jvt(lines):
    """A conformance package's donated -trace.txt -> canonical records."""
    out = []
    ctx = None
    slice_type = None
    mb = None
    blocks = None
    blk = None
    pending_skip = None
    chroma_seen = 0
    cur_list = None      # from the `l0 ( FW ) mvd : BK n` labels: which list the bare mvd/ref_idx SEs are

    def close_block():
        nonlocal blk
        if blk is not None:
            mb.block(blk.kind, blk.idx, blk.coeffs())
            blk = None

    def close_mb():
        nonlocal mb, blocks, chroma_seen
        close_block()
        if mb is not None:
            if blocks:
                raise TraceError("MB %d: %d residual blocks expected but not traced" % (mb.addr, len(blocks)))
            out.extend(mb.records())
            mb = None
            blocks = None
            chroma_seen = 0

    try:
        for lineno, ln in enumerate(lines, 1):
            ln = ln.rstrip("\n")
            if not ln.strip():
                continue
            m = JVT_NAL.match(ln)
            if m:
                close_mb()
                ctx = "NAL"
                continue
            if ln.startswith("<<< Begin Sequence Parameter Set"):
                ctx = "SPS"
                continue
            if ln.startswith("<<< Begin Picture Parameter Set"):
                ctx = "PPS"
                continue
            if ln.startswith("<<< Begin Slice"):
                ctx = "SH"
                slice_type = None
                continue
            m = JVT_MB.match(ln)
            if m:
                close_mb()
                if slice_type is None:
                    raise TraceError("macroblock before a slice header")
                mb = Mb(int(m.group(1)), slice_type)
                if pending_skip is not None:
                    mb.se("mb_skip_flag", pending_skip)
                    pending_skip = None
                continue
            m = JVT_BLK.match(ln)
            if m:
                close_block()
                if blocks is None:
                    blocks = mb.expected()
                lab, bk = JVT_KIND[m.group(1)], int(m.group(2))
                if blocks is None:
                    # wild MB: the labels are the only description of its residual
                    if lab == "LDC":
                        kind, idx, n = "LDC", 0, 16
                    elif lab == "L4":
                        kind, idx, n = "L4", bk, 15
                    elif lab == "CDC":
                        kind, idx, n = "CDC", chroma_seen, 4
                        chroma_seen += 1
                    else:
                        kind, idx, n = "CAC", chroma_seen - 2, 15
                        chroma_seen += 1
                    blk = _JvtBlock(kind, idx, n)
                    continue
                if not blocks:
                    raise TraceError("MB %d: unexpected residual block %s" % (mb.addr, ln))
                kind, idx, n = blocks.pop(0)
                if lab != kind:
                    raise TraceError("MB %d: block order: trace %s, expected %s %d" % (mb.addr, m.group(1), kind, idx))
                # the trace numbers chroma blocks per plane; the spec index is checked for luma
                if kind == "L4" and bk != idx:
                    raise TraceError("MB %d: luma block %d traced where %d was expected" % (mb.addr, bk, idx))
                if kind == "CAC" and bk != idx % 4:
                    raise TraceError("MB %d: chroma AC block %d traced where %d was expected" % (mb.addr, bk, idx % 4))
                blk = _JvtBlock(kind, idx, n)
                continue
            m = JVT_EOS.match(ln)
            if m:
                close_block()
                if mb is None or mb.addr != int(m.group(1)):
                    raise TraceError("end_of_slice_flag of MB %s outside that macroblock" % m.group(1))
                continue
            m = JVT_LIST.match(ln)
            if m:
                cur_list = m.group(1)
                continue
            if JVT_LABEL.match(ln):
                continue
            m = JVT_SE.match(ln)
            if not m:
                raise TraceError("unrecognised JVT trace line: %s" % ln)
            name, vtxt = m.group(2).strip(), m.group(3)
            value = int(vtxt) if vtxt not in ("", "-") else None
            if name.startswith("+++ end_of_slice_flag of MB "):
                close_block()
                addr = int(name.rsplit(" ", 1)[1])
                if mb is None or mb.addr != addr:
                    raise TraceError("end_of_slice_flag of MB %d outside that macroblock" % addr)
                if blocks is None:
                    blocks = mb.expected()
                mb.se("end_of_slice_flag", value)
                close_mb()
                continue
            if DROP.match(name):
                continue
            if ctx == "NAL" and name in JVT_HDR_SE:
                continue
            if ctx in ("SPS", "PPS", "SH") and mb is None and name != "mb_skip_flag":
                fname = canon_field(ctx, name)
                if ctx == "SH" and fname == "slice_type":
                    slice_type = value % 5
                    if slice_type not in (SLICE_P, SLICE_B, SLICE_I):
                        raise TraceError("slice_type %d (SP/SI) is refused" % value)
                out.append("S %s %d" % (fname, value))
                continue
            if name == "mb_skip_flag":
                # printed before the `+++ MB n` line it belongs to; MB n-1 was closed by
                # its end_of_slice_flag already
                close_mb()
                pending_skip = value
                continue
            if mb is None:
                raise TraceError("MB syntax outside a macroblock: %s" % ln)
            if blk is not None and blk.feed(name, value):
                continue
            if name in REFUSE or name == "transform_size_8x8_flag":
                # the 2004 tracer's 8x8 residual labels are unread: High streams are
                # scored against JM's trace and the package's pixels instead
                raise TraceError("MB %d: %s -- MBAFF / the 8x8 transform are not read from a donated trace"
                                 % (mb.addr, name))
            if name == "pcm_coding_pixel":
                if mb.mb_type is None and mb.slice_type != SLICE_I:
                    # the tracer's untraced intra mb_type in P/B: I_PCM is exact
                    mb.se("mb_type", {SLICE_P: 5, SLICE_B: 23}[mb.slice_type] + 25)
                mb.pcm_sample(value)
                continue
            if name in ("mvd", "ref_idx"):
                if cur_list is None:
                    raise TraceError("MB %d: %s without a list label" % (mb.addr, name))
                name = "%s_l%s" % (name, cur_list)
            if (mb.mb_type is None and not mb.wild and mb.slice_type != SLICE_I
                    and name in ("prev_intra4x4_pred_mode_flag", "intra_chroma_pred_mode")):
                mb.infer_intra(name)
            mb.se(name, value)
    except TraceError as e:
        raise TraceError("line %d: %s" % (lineno, e))
    close_mb()
    return out


def parse_jvt_file(lines):
    """Per-NAL driver: the donated trace is self-contained per NAL except for the
    slice type (needed for mb_type interpretation), which slice headers carry."""
    chunks = []
    chunk = None
    for ln in lines:
        if ln.startswith("<<< Begin Nal Unit"):
            if chunk is not None:
                chunks.append(chunk)
            chunk = []
        if chunk is not None:
            chunk.append(ln)
    if chunk is not None:
        chunks.append(chunk)
    out = []
    for ch in chunks:
        ntype = nref = None
        for ln in ch:
            m = JVT_SE.match(ln.rstrip("\n"))
            if m:
                n = m.group(2).strip()
                if n == "nal_ref_idc" and nref is None:
                    nref = int(m.group(3))
                elif n == "nal_unit_type" and ntype is None:
                    ntype = int(m.group(3))
                    break
        if ntype is None:
            raise TraceError("NAL without a nal_unit_type")
        out.append("N %d %d" % (ntype, nref))
        out.extend(_parse_jvt_chunk(ch))
    return out


def _parse_jvt_chunk(ch):
    return parse_jvt(ch)


# ---------------------------------------------------------------- access units

AUD = b"\x00\x00\x00\x01\x09"


def trim_to_last_au(es):
    """Cut an Annex-B ES at its last access-unit delimiter: a cut ends mid-NAL, and
    ldecod stops (or worse) on a truncated slice."""
    i = es.rfind(AUD)
    if i <= 0:
        raise TraceError("no access-unit delimiter in the ES (%d bytes)" % len(es))
    return es[:i]


# ---------------------------------------------------------------- running JM

def jm_binary():
    refs = os.environ.get("H264_REFS_DIR", os.path.expanduser("~/h264-refs"))
    jm = os.environ.get("H264_JM_DIR", os.path.join(refs, "JM"))
    return os.path.join(jm, "build_trace", "bin", "ldecod.exe")


def run_jm(stream, workdir=None, yuv=None):
    """Decode an Annex-B stream with the traced ldecod; return the trace lines
    (and leave the YUV at `yuv` if asked)."""
    exe = jm_binary()
    if not os.access(exe, os.X_OK):
        raise TraceError("no traced ldecod at %s (tools/jm_build.sh)" % exe)
    stream = os.path.abspath(stream)
    tmp = None
    if workdir is None:
        tmp = tempfile.TemporaryDirectory(prefix="h264_trace_")
        workdir = tmp.name
    yuv_path = os.path.abspath(yuv) if yuv else os.path.join(workdir, "out.yuv")
    cmd = [exe, "-p", "InputFile=" + stream, "-p", "OutputFile=" + yuv_path,
           "-p", "Silent=1", "-p", "VQdim=0", "-p", "ResidualsOutput=0"]
    r = subprocess.run(cmd, cwd=workdir, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       universal_newlines=True)
    trace = os.path.join(workdir, "trace_dec.txt")
    if r.returncode != 0 or not os.path.exists(trace):
        raise TraceError("ldecod failed (%d):\n%s" % (r.returncode, r.stdout[-2000:]))
    m = re.search(r"(\d+) frames are decoded", r.stdout)
    frames = int(m.group(1)) if m else None
    with open(trace) as f:
        lines = f.readlines()
    if tmp is not None:
        tmp.cleanup()
    return lines, frames


# ---------------------------------------------------------------- diff / main

def diff(a, b, na="a", nb="b"):
    """First differing record, with the MB/NAL context, or None."""
    ctx = None
    wild = 0
    for i, (x, y) in enumerate(zip(a, b)):
        if x.startswith("M ") or x.startswith("N "):
            ctx = x
        if x != y:
            if x.startswith("E mb_type ") and y.startswith("E mb_type ") and "*" in (x[10:], y[10:]):
                wild += 1
                continue
            return "record %d (after %s):\n  %s: %s\n  %s: %s" % (i, ctx, na, x, nb, y), wild
    if len(a) != len(b):
        return "%s has %d records, %s has %d (common prefix identical)" % (na, len(a), nb, len(b)), wild
    return None, wild


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--jm", help="Annex-B stream: run the traced ldecod and normalise")
    ap.add_argument("--jm-trace", help="an existing JM trace_dec.txt")
    ap.add_argument("--jvt", help="a conformance package's donated -trace.txt")
    ap.add_argument("--yuv", help="with --jm: keep the decoded YUV here")
    ap.add_argument("--diff", nargs=2, metavar=("A", "B"), help="compare two canonical files")
    ap.add_argument("-o", "--out")
    a = ap.parse_args(argv)
    if a.diff:
        x = open(a.diff[0]).read().splitlines()
        y = open(a.diff[1]).read().splitlines()
        d, wild = diff(x, y, a.diff[0], a.diff[1])
        if d:
            print("DIFF " + d)
            return 1
        print("SAME %d records (%d mb_type wildcards: the donated tracer's untraced intra MBs in P/B)"
              % (len(x), wild))
        return 0
    if a.jm:
        lines, frames = run_jm(a.jm, yuv=a.yuv)
        recs = parse_jm(lines)
        print("%s: %d frames, %d records" % (a.jm, frames or -1, len(recs)), file=sys.stderr)
    elif a.jm_trace:
        recs = parse_jm(open(a.jm_trace).readlines())
    elif a.jvt:
        recs = parse_jvt_file(open(a.jvt, errors="replace").readlines())
    else:
        ap.error("one of --jm, --jm-trace, --jvt, --diff")
    if a.out:
        with open(a.out, "w") as f:
            f.write("\n".join(recs) + "\n")
    else:
        sys.stdout.write("\n".join(recs) + "\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except TraceError as e:
        sys.exit("h264_trace_ref: %s" % e)
