#!/usr/bin/env python3
"""cavlc_synth.py -- CAVLC streams for the paths of the CAVLC -> CABAC rewriter (fj#20,
hps/lib/h264ring_cavlc.c, docs/cavlc.md) that no encoder and no conformance stream reaches.

Synthesised streams are written bit by bit from the syntax tables (7.3, the CAVLC codes of
tools/cavlc_tables.py): a High-profile 32x32 picture (2x2 macroblocks, 4:2:0, 8 bits, the
8x8 transform enabled, poc type 2, no deblocking parameters), an IDR of four I_16x16 DC
macroblocks without residual, then P pictures whose macroblocks carry the case. Each is a
valid stream (bench/h264/run_cavlc.sh decodes it with ffmpeg first); what it tests is
named beside it:

  z8_inter        P_L0_16x16, transform_size_8x8_flag 1, cbp 1, the 8x8 block's four 4x4
                  coeff_tokens all TotalCoeff 0 -- CAVLC codes it, CABAC cannot (no
                  coded_block_flag for ctxBlockCat 5 in 4:2:0): the rewriter codes the
                  macroblock with the 4x4 transform and coded_block_flag 0
  z8_inter_qpd    the same with mb_qp_delta +3 (kept: the cbp stays)
  z8_mixed        cbp 3: 8x8 block 0 all zero, block 1 one level -- block 0's cbp bit cleared
  z8_chroma       cbp 1 + chroma DC, the luma 8x8 all zero, mb_qp_delta -2
  z8_p8x8         P_8x8 with four DIFFERENT motion vectors over a textured reference (an IDR of
                  I_PCM macroblocks), cbp 15 all zero, mb_qp_delta +2: the 4x4 transform makes
                  the internal 4x4 edges deblockable, and their bS must stay 0 (the motion is
                  uniform inside each 8x8 partition) for the pictures to match
  z8_intra        I_NxN (Intra_8x8) in a P slice, cbp 1 all zero, mb_qp_delta 0: the bit cleared
  z8_intra_mixed  I_NxN Intra_8x8, cbp 3, block 0 zero, block 1 one level, mb_qp_delta +1
  z8_intra_qpd    I_NxN Intra_8x8, cbp 1 all zero, mb_qp_delta +2: not expressible in CABAC
                  (cbp 0 drops the mb_qp_delta) -- REFUSED
  redundant       redundant_pic_cnt_present_flag 1 (every redundant_pic_cnt 0) -- REFUSED
  dp              a slice data partition A NAL unit (type 2) -- REFUSED
  badcode         a coeff_token of sixteen zero bits (no such code) -- ERROR
  zw              an IDR (QP 0) of Intra_4x4 macroblocks whose every level is +15: ~4,600 bins a
                  macroblock that cost a few bits each, so the picture needs cabac_zero_words
                  (9.3.4.6, 7.4.2.10) -- no encoder setting reaches it
  pcm             I_PCM macroblocks in an I and a P picture beside Intra_4x4 ones with levels
                  (nC of 16 next to an I_PCM, the CABAC engine restarted after the samples)

JM 18.4's lencod (tools/jm_build.sh --lencod) for High CAVLC syntax x264 never writes:

  jm field        field pictures (PicInterlace 1): the field significance contexts
  jm i8           High, the 8x8 transform only (Transform8x8Mode 2): Intra_8x8 in CAVLC
  jm b            B pictures, two references

and two mutations of an existing CAVLC stream:

  aso IN          in each picture of two or more slices, the first two slices swapped -- REFUSED
  cut IN          the last third of every slice NAL unit cut off -- ERROR

    cavlc_synth.py CASE OUT.264 | cavlc_synth.py aso|cut IN.264 OUT.264 |
    cavlc_synth.py jm field|i8|b OUT.264 [LENCOD] | --list
    cavlc_synth.py --c-header OUT.h [--check]   the C arrays hps/tests/test_ring.c uses
                                                (C_HEADER below: a few hundred bytes)
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import cavlc_tables as V  # noqa: E402
from h264_synth import BitWriter, nal  # noqa: E402
from h264_fe_ref import nal_units_pos  # noqa: E402


class W(BitWriter):
    def se(self, v):
        self.ue(2 * v - 1 if v > 0 else -2 * v)

    def code(self, s):
        self.bits += [int(c) for c in s]


def sps():
    w = W()
    w.u(8, 100)                     # High
    w.u(8, 0)                       # constraint flags, reserved
    w.u(8, 30)                      # level 3.0
    w.ue(0)                         # seq_parameter_set_id
    w.ue(1)                         # chroma_format_idc 4:2:0
    w.ue(0)                         # bit_depth_luma_minus8
    w.ue(0)                         # bit_depth_chroma_minus8
    w.u(1, 0)                       # qpprime_y_zero_transform_bypass_flag
    w.u(1, 0)                       # seq_scaling_matrix_present_flag
    w.ue(0)                         # log2_max_frame_num_minus4
    w.ue(2)                         # pic_order_cnt_type 2
    w.ue(1)                         # max_num_ref_frames
    w.u(1, 0)                       # gaps_in_frame_num_value_allowed_flag
    w.ue(1)                         # pic_width_in_mbs_minus1: 2
    w.ue(1)                         # pic_height_in_map_units_minus1: 2
    w.u(1, 1)                       # frame_mbs_only_flag
    w.u(1, 1)                       # direct_8x8_inference_flag
    w.u(1, 0)                       # frame_cropping_flag
    w.u(1, 0)                       # vui_parameters_present_flag
    w.trailing()
    return nal(0x67, w.bytes())


def pps(redundant=0):
    w = W()
    w.ue(0)                         # pic_parameter_set_id
    w.ue(0)                         # seq_parameter_set_id
    w.u(1, 0)                       # entropy_coding_mode_flag: CAVLC
    w.u(1, 0)                       # bottom_field_pic_order_in_frame_present_flag
    w.ue(0)                         # num_slice_groups_minus1
    w.ue(0)                         # num_ref_idx_l0_default_active_minus1
    w.ue(0)                         # num_ref_idx_l1_default_active_minus1
    w.u(1, 0)                       # weighted_pred_flag
    w.u(2, 0)                       # weighted_bipred_idc
    w.se(0)                         # pic_init_qp_minus26
    w.se(0)                         # pic_init_qs_minus26
    w.se(0)                         # chroma_qp_index_offset
    w.u(1, 0)                       # deblocking_filter_control_present_flag
    w.u(1, 0)                       # constrained_intra_pred_flag
    w.u(1, redundant)               # redundant_pic_cnt_present_flag
    w.u(1, 1)                       # transform_8x8_mode_flag
    w.u(1, 0)                       # pic_scaling_matrix_present_flag
    w.se(0)                         # second_chroma_qp_index_offset
    w.trailing()
    return nal(0x68, w.bytes())


def ct(w, t1, tc, col=0):
    w.code(V.COEFF_TOKEN[col][(t1, tc)])


def one_level(w):
    """a 4x4 block (nC 0..1) with one level +1 at scan position 0"""
    ct(w, 1, 1)
    w.u(1, 0)                       # trailing_ones_sign_flag: +1
    w.code(V.TOTAL_ZEROS[1][0])     # total_zeros 0


def idr(redundant=0):
    w = W()
    w.ue(0)                         # first_mb_in_slice
    w.ue(7)                         # slice_type I (all)
    w.ue(0)                         # pic_parameter_set_id
    w.u(4, 0)                       # frame_num
    w.ue(0)                         # idr_pic_id
    if redundant:
        w.ue(0)                     # redundant_pic_cnt
    w.u(1, 0)                       # no_output_of_prior_pics_flag
    w.u(1, 0)                       # long_term_reference_flag
    w.se(0)                         # slice_qp_delta
    for _ in range(4):
        w.ue(3)                     # I_16x16_2_0_0: DC prediction, no AC, no chroma
        w.ue(0)                     # intra_chroma_pred_mode DC
        w.se(0)                     # mb_qp_delta
        ct(w, 0, 0)                 # Intra16x16DCLevel: TotalCoeff 0 (nC 0)
    w.trailing()
    return nal(0x65, w.bytes())


def p_slice(frame_num, body, redundant=0):
    w = W()
    w.ue(0)                         # first_mb_in_slice
    w.ue(5)                         # slice_type P (all)
    w.ue(0)                         # pic_parameter_set_id
    w.u(4, frame_num)
    if redundant:
        w.ue(0)                     # redundant_pic_cnt
    w.u(1, 0)                       # num_ref_idx_active_override_flag
    w.u(1, 0)                       # ref_pic_list_modification_flag_l0
    w.u(1, 0)                       # adaptive_ref_pic_marking_mode_flag
    w.se(0)                         # slice_qp_delta
    body(w)
    w.trailing()
    return nal(0x41, w.bytes())


def inter_mb(w, cbp, qpd, blocks, chroma_dc=False):
    """P_L0_16x16, mvd (0, 0), transform_size_8x8_flag 1; blocks: per coded 8x8, 'z' all zero
    or 'l' one level in its first 4x4"""
    w.ue(0)                         # mb_type P_L0_16x16
    w.se(0)                         # mvd_l0 x
    w.se(0)                         # mvd_l0 y
    w.ue(V.CBP_INTER.index(cbp))    # coded_block_pattern me(v)
    w.u(1, 1)                       # transform_size_8x8_flag
    w.se(qpd)                       # mb_qp_delta
    luma(w, blocks)
    if chroma_dc:
        ct(w, 1, 1, 4)              # Cb DC: one level +1 (nC -1)
        w.u(1, 0)
        w.code(V.TOTAL_ZEROS_CDC[1][0])
        ct(w, 0, 0, 4)              # Cr DC: none


def p8x8_mb(w, cbp, qpd, mvds):
    """P_8x8, four sub_mb_type 0 (one 8x8 partition each), each its own mvd, the 8x8 transform,
    every coded 8x8 block all zero"""
    w.ue(3)                         # mb_type P_8x8
    for _ in range(4):
        w.ue(0)                     # sub_mb_type P_L0_8x8
    for x, y in mvds:
        w.se(x)
        w.se(y)
    w.ue(V.CBP_INTER.index(cbp))
    w.u(1, 1)                       # transform_size_8x8_flag
    w.se(qpd)
    luma(w, "z" * bin(cbp & 15).count("1"))


def intra8_mb(w, cbp, qpd, blocks):
    """I_NxN in a P slice (mb_type 5) with transform_size_8x8_flag 1: Intra_8x8, every mode
    the predicted one, chroma DC prediction"""
    w.ue(5)                         # mb_type I_NxN
    w.u(1, 1)                       # transform_size_8x8_flag
    for _ in range(4):
        w.u(1, 1)                   # prev_intra8x8_pred_mode_flag
    w.ue(0)                         # intra_chroma_pred_mode
    w.ue(V.CBP_INTRA.index(cbp))
    w.se(qpd)
    luma(w, blocks)


def luma(w, blocks):
    # every neighbouring TotalCoeff in these pictures is 0 or 1: nC < 2, the first column
    for b in blocks:
        for k in range(4):
            if b == "l" and k == 0:
                one_level(w)
            else:
                ct(w, 0, 0)


# ---- a CAVLC residual encoder (the inverse of 9.2) and nC (9.2.1) for the synthetic pictures

def blk_xy(i):
    return (i >> 2 & 1) * 8 + (i & 1) * 4, (i >> 3) * 8 + (i >> 1 & 1) * 4


def xy_blk(x, y):
    return 8 * (y >> 3) + 4 * (x >> 3) + 2 * ((y & 7) >> 2) + ((x & 7) >> 2)


class Pic(object):
    """TotalCoeff per macroblock (luma 0-15, Cb 16-19, Cr 20-23) of a 2x2-macroblock picture,
    one slice: what nC reads"""
    def __init__(self):
        self.tc = {}

    def nc_luma(self, mb, i):
        x, y = blk_xy(i)
        vals = []
        for dx, dy in ((-1, 0), (0, -1)):
            nx, ny, m = x + dx, y + dy, mb
            if nx < 0:
                if mb % 2 == 0:
                    continue
                m, nx = mb - 1, nx + 16
            if ny < 0:
                if mb < 2:
                    continue
                m, ny = mb - 2, ny + 16
            if m not in self.tc:
                continue
            vals.append(self.tc[m][xy_blk(nx, ny)])
        if len(vals) == 2:
            return (vals[0] + vals[1] + 1) >> 1
        return vals[0] if vals else 0


def nc_col(nc):
    return 0 if nc < 2 else 1 if nc < 4 else 2 if nc < 8 else 3


def cavlc_block(w, coeffs, maxn, nc):
    """coeffs in scan order (maxn of them) -> residual_block_cavlc; returns TotalCoeff"""
    nz = [(k, v) for k, v in enumerate(coeffs) if v]
    tc = len(nz)
    rev = [v for _k, v in reversed(nz)]
    t1 = 0
    while t1 < min(3, tc) and abs(rev[t1]) == 1:
        t1 += 1
    w.code(V.COEFF_TOKEN[4 if nc < 0 else nc_col(nc)][(t1, tc)])
    if not tc:
        return 0
    for v in rev[:t1]:
        w.u(1, 1 if v < 0 else 0)
    sl = 1 if tc > 10 and t1 < 3 else 0
    for i in range(t1, tc):
        v = rev[i]
        code = 2 * v - 2 if v > 0 else -2 * v - 1
        if i == t1 and t1 < 3:
            code -= 2
        if sl == 0:
            if code < 14:
                w.code("0" * code + "1")
            elif code < 30:
                w.code("0" * 14 + "1")
                w.u(4, code - 14)
            else:
                w.code("0" * 15 + "1")
                w.u(12, code - 30)
        elif code < (15 << sl):
            w.code("0" * (code >> sl) + "1")
            w.u(sl, code & ((1 << sl) - 1))
        else:
            w.code("0" * 15 + "1")
            w.u(12, code - (15 << sl))
        if sl == 0:
            sl = 1
        if abs(v) > (3 << (sl - 1)) and sl < 6:
            sl += 1
    positions = [k for k, _v in nz]
    tz = positions[-1] + 1 - tc
    if tc < maxn:
        w.code((V.TOTAL_ZEROS_CDC if maxn == 4 else V.TOTAL_ZEROS)[tc][tz])
    zl = tz
    hi = list(reversed(positions))
    for k in range(tc - 1):
        if zl <= 0:
            break
        run = hi[k] - hi[k + 1] - 1
        w.code(V.RUN_BEFORE[min(zl, 7)][run])
        zl -= run
    return tc


def intra4_mb(w, pic, mb, levels, mb_type=0):
    """I_NxN Intra_4x4 (every mode the predicted one), cbp 15 (luma only), mb_qp_delta 0, each
    4x4 block's 16 levels from levels(i)"""
    w.ue(mb_type)
    w.u(1, 0)                       # transform_size_8x8_flag 0: Intra_4x4
    for _ in range(16):
        w.u(1, 1)                   # prev_intra4x4_pred_mode_flag
    w.ue(0)                         # intra_chroma_pred_mode
    w.ue(V.CBP_INTRA.index(15))
    w.se(0)
    pic.tc[mb] = [0] * 24
    for i in range(16):
        pic.tc[mb][i] = cavlc_block(w, levels(i), 16, pic.nc_luma(mb, i))


def pcm_mb(w, pic, mb, mb_type, seed):
    w.ue(mb_type)
    while len(w.bits) % 8:
        w.u(1, 0)                   # pcm_alignment_zero_bit
    for k in range(384):
        w.u(8, (seed * 37 + k * 11) % 255 + 1)
    pic.tc[mb] = [16] * 24


def islice(body, frame=0, qp_delta=0):
    w = W()
    w.ue(0)
    w.ue(7)
    w.ue(0)
    w.u(4, frame)
    w.ue(frame)                     # idr_pic_id
    w.u(1, 0)
    w.u(1, 0)
    w.se(qp_delta)                  # slice_qp_delta
    body(w)
    w.trailing()
    return nal(0x65, w.bytes())


def zw():
    def body(w):
        pic = Pic()
        for mb in range(4):
            intra4_mb(w, pic, mb, lambda i: [15] * 16)
    # QP 0: levels of 15 everywhere stay inside the inverse transform's 16-bit intermediate range
    # (8.5.12.1 -- at QP 26 they overflow it: a non-conforming stream whose pixels decoders may
    # legitimately disagree on); the bins, which this case is about, do not depend on QP
    return islice(body, qp_delta=-26)


def pcm():
    """every Intra_4x4 macroblock has an I_PCM to its left or above: its edge blocks' nC is
    read from an I_PCM's TotalCoeff, 16 (9.2.1)"""
    def ibody(w):
        pic = Pic()
        pcm_mb(w, pic, 0, 25, 1)
        intra4_mb(w, pic, 1, lambda i: [3, -1, 0, 1] + [0] * 12)
        intra4_mb(w, pic, 2, lambda i: [0, 2, 0, 0, -1] + [0] * 11)
        pcm_mb(w, pic, 3, 25, 2)

    def pbody(w):
        pic = Pic()
        w.ue(0)
        pcm_mb(w, pic, 0, 30, 3)    # I_PCM in a P slice: 5 + 25
        w.ue(0)
        intra4_mb(w, pic, 1, lambda i: [1, 1, -1] + [0] * 13, mb_type=5)
        w.ue(2)                     # mbs 2, 3 skipped: the end
    return islice(ibody) + p_slice(1, pbody)


def two_p(mb):
    """two P pictures: the case's macroblock at address 0 then the rest skipped; then three
    skipped and the case's macroblock at address 3 (neighbours: skipped)"""
    def first(w):
        w.ue(0)                     # mb_skip_run
        mb(w)
        w.ue(3)                     # mb_skip_run to the end
    def second(w):
        w.ue(3)
        mb(w)
    return p_slice(1, first) + p_slice(2, second)


SYNTH = {
    "z8_inter": lambda: two_p(lambda w: inter_mb(w, 1, 0, "z")),
    "z8_inter_qpd": lambda: two_p(lambda w: inter_mb(w, 1, 3, "z")),
    "z8_mixed": lambda: two_p(lambda w: inter_mb(w, 3, 0, "zl")),
    "z8_chroma": lambda: two_p(lambda w: inter_mb(w, 17, -2, "z", chroma_dc=True)),
    "z8_intra": lambda: two_p(lambda w: intra8_mb(w, 1, 0, "z")),
    "z8_intra_mixed": lambda: two_p(lambda w: intra8_mb(w, 3, 1, "zl")),
    "z8_intra_qpd": lambda: two_p(lambda w: intra8_mb(w, 1, 2, "z")),
}
EXPECT = {k: "exact" for k in SYNTH}
EXPECT.update({"z8_p8x8": "exact", "zw": "exact", "pcm": "exact", "z8_intra_qpd": "refused", "redundant": "refused", "dp": "refused", "badcode": "error",
               "aso": "refused", "cut": "error"})


def synth(case):
    if case in SYNTH:
        return sps() + pps() + idr() + SYNTH[case]()
    if case == "z8_p8x8":
        def ibody(w):
            pic = Pic()
            for mb in range(4):
                pcm_mb(w, pic, mb, 25, mb + 7)
        return sps() + pps() + islice(ibody) + two_p(
            lambda w: p8x8_mb(w, 15, 2, [(9, -3), (-14, 6), (5, 17), (-22, -11)]))
    if case == "zw":
        return sps() + pps() + zw()
    if case == "pcm":
        return sps() + pps() + pcm()
    if case == "redundant":
        def body(w):
            w.ue(4)                 # all skipped
        return sps() + pps(1) + idr(1) + p_slice(1, body, 1)
    if case == "dp":
        return sps() + pps() + idr() + nal(0x42, bytes([0x80, 0x80, 0x80]))
    if case == "badcode":
        def body(w):
            w.ue(0)
            w.ue(0)                 # P_L0_16x16
            w.se(0)
            w.se(0)
            w.ue(V.CBP_INTER.index(1))
            w.u(1, 0)               # transform_size_8x8_flag 0
            w.se(0)
            w.code("0" * 16)        # a coeff_token no table has
            w.ue(3)
        return sps() + pps() + idr() + p_slice(1, body)
    raise SystemExit("cavlc_synth: no case %s (--list)" % case)


def slices_of(data):
    """(start, end, nal_type, first_mb) of each NAL unit; start at its 3-byte start code"""
    out = []
    pos = [(p - 3, t) for p, _r, t, _b in nal_units_pos(data)]
    for k, (s, t) in enumerate(pos):
        e = pos[k + 1][0] if k + 1 < len(pos) else len(data)
        while e > s and data[e - 1] == 0 and k + 1 < len(pos):
            e -= 1
        fm = None
        if t in (1, 5):
            b = data[s + 4]
            fm = 0 if b & 0x80 else 1           # first_mb_in_slice == 0 or not: enough here
        out.append((s, e, t, fm))
    return out


def mutate(kind, data):
    units = slices_of(data)
    out = bytearray()
    if kind == "cut":
        for s, e, t, _fm in units:
            if t in (1, 5):
                e = s + 4 + max(4, (e - s - 4) * 2 // 3)
            out += data[s:e]
        return bytes(out)
    # aso: swap the first two slices of each picture of two or more
    k = 0
    swapped = 0
    while k < len(units):
        s, e, t, fm = units[k]
        if t in (1, 5) and fm == 0 and k + 1 < len(units) and units[k + 1][2] in (1, 5) and units[k + 1][3] == 1:
            out += data[units[k + 1][0]:units[k + 1][1]] + data[s:e]
            k += 2
            swapped += 1
            continue
        out += data[s:e]
        k += 1
    if not swapped:
        raise SystemExit("cavlc_synth: aso: no picture of two or more slices")
    return bytes(out)


JM_BASE = {"ProfileIDC": 100, "LevelIDC": 30, "SymbolMode": 0, "Transform8x8Mode": 1,
           "SourceWidth": 176, "SourceHeight": 144, "OutputWidth": 176, "OutputHeight": 144,
           "FrameRate": 30.0, "IntraPeriod": 0, "IDRPeriod": 0, "NumberBFrames": 0, "QPISlice": 28,
           "QPPSlice": 28, "QPBSlice": 30, "SearchRange": 16, "WeightedPrediction": 0,
           "WeightedBiprediction": 0, "RDOptimization": 1, "Log2MaxFNumMinus4": 0, "YUVFormat": 1}
JM_CASES = {"field": {"PicInterlace": 1, "NumberReferenceFrames": 2},
            "i8": {"Transform8x8Mode": 2},
            "b": {"NumberBFrames": 2, "NumberReferenceFrames": 2, "QPBSlice": 32}}


def jm(case, out, lencod):
    import subprocess
    import tempfile
    work = tempfile.mkdtemp(prefix="cavlc_jm_")
    yuv = os.path.join(work, "src.yuv")
    n = 12
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i",
                    "testsrc2=size=176x144:rate=30,noise=alls=12:allf=t", "-frames:v", str(n),
                    "-pix_fmt", "yuv420p", "-f", "rawvideo", yuv], check=True)
    cfg = dict(JM_BASE)
    # the JM tree in $H264_REFS_DIR carries a vector-quantisation extension that loads codebooks
    # unless these are 0 (tools/jm_fixtures.py); a pristine JM rejects the keys
    if os.path.exists(os.path.join(os.path.dirname(os.path.dirname(lencod)), "lencod", "src", "vq.c")):
        cfg.update({"VQdim": 0, "VQcblen": 0})
    cfg.update(JM_CASES[case])
    cfg.update({"InputFile": yuv, "FramesToBeEncoded": n, "OutputFile": os.path.abspath(out),
                "ReconFile": os.path.join(work, "rec.yuv"), "StatsFile": os.path.join(work, "stats.dat"),
                "TraceFile": os.path.join(work, "trace.txt"),
                "LeakyBucketParamFile": os.path.join(work, "lbp.cfg"),
                "LeakyBucketRateFile": os.path.join(work, "lbr.cfg")})
    cfgp = os.path.join(work, "enc.cfg")
    with open(cfgp, "w") as fo:
        for k, v in cfg.items():
            fo.write('%s = %s\n' % (k, '"%s"' % v if isinstance(v, str) else v))
    r = subprocess.run([lencod, "-d", cfgp], cwd=work, capture_output=True, text=True, errors="replace")
    if r.returncode or not os.path.exists(out) or not os.path.getsize(out):
        raise SystemExit("cavlc_synth: lencod failed: %s" % (r.stdout + r.stderr)[-400:])


# hps/tests/cavlc_fixtures.h: the library's own test (test_ring.c: the rewrite in the write call)
C_HEADER = (("cv_mixed", "z8_mixed"), ("cv_refused", "redundant"), ("cv_bad", "badcode"))


def c_header():
    w = ["/* GENERATED by tools/cavlc_synth.py --c-header -- never edit by hand. Synthetic CAVLC",
         " * streams (no media) for hps/tests/test_ring.c: the rewrite inside the write call. */",
         "#ifndef CAVLC_FIXTURES_H", "#define CAVLC_FIXTURES_H", ""]
    for name, case in C_HEADER:
        data = synth(case)
        w.append("/* %s: %s */" % (case, EXPECT[case]))
        w.append("static const unsigned char %s[%d] = {" % (name, len(data)))
        for i in range(0, len(data), 16):
            w.append("    " + ", ".join("0x%02x" % b for b in data[i:i + 16]) + ",")
        w.append("};")
        w.append("")
    w.append("#endif")
    w.append("")
    return "\n".join(w)


def main(argv):
    if argv[:1] == ["--list"]:
        for k in list(SYNTH) + ["z8_p8x8", "zw", "pcm", "redundant", "dp", "badcode", "aso", "cut"]:
            print(k, EXPECT[k])
        return 0
    if len(argv) == 2 and argv[0] != "--c-header":
        open(argv[1], "wb").write(synth(argv[0]))
        return 0
    if argv[:1] == ["--c-header"] and len(argv) in (2, 3):
        text = c_header()
        if argv[2:] == ["--check"]:
            same = os.path.exists(argv[1]) and open(argv[1]).read() == text
            print("%s %s the generator" % (argv[1], "matches" if same else "DIFFERS FROM"))
            return 0 if same else 1
        open(argv[1], "w").write(text)
        return 0
    if argv[:1] == ["jm"] and len(argv) in (3, 4):
        refs = os.environ.get("H264_REFS_DIR", os.path.expanduser("~/h264-refs"))
        jm(argv[1], argv[2], argv[3] if len(argv) == 4 else
           os.path.join(refs, "JM", "build_enc", "bin", "lencod.exe"))
        return 0
    if len(argv) == 3 and argv[0] in ("aso", "cut"):
        open(argv[2], "wb").write(mutate(argv[0], open(argv[1], "rb").read()))
        return 0
    sys.exit(__doc__)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
