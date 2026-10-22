#!/usr/bin/env python3
"""h264_trace_ref on synthetic traces (no JM, no media): the same three-picture stream
(I with I_NxN + Intra16x16, P with P_8x8 + an intra MB, B with B_8x8 + a skip) written
in BOTH trace formats from a common description by two emitters that follow each
format's conventions as documented in the tool -- JM's inverted mb_skip_flag, its P
mb_type + 1, its -1 intra4x4 mode, its undecoded picture-final end_of_slice_flag, its
(level, run) residual; the donated tracer's significance-map residual, its mb_skip_flag
before `+++ MB n`, and the mb_type it never prints for an intra MB in a P/B slice.
The two normalise to the same canonical stream (one wildcard), the diff catches
mutations, and MBAFF / 8x8-transform lines are refused.

With $H264_REFS_DIR (H.264.1 CABACI3_Sony_B.zip + the traced ldecod of tools/jm_build.sh)
the real proof runs too: ldecod's trace vs the zip's own 2004 trace over 300 I/P/B
frames -- SKIP without them, never a silent pass.
"""
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import score as S  # noqa: E402
import h264_trace_ref as T  # noqa: E402

Sc = S.Score("test_h264_trace_ref")

# ------------------------------------------------------------------ the stream
# Each NAL: (nal_unit_type, nal_ref_idc, ctx, [(field, value)], [macroblocks]).
# A macroblock: dict(addr, skip, mb_type (spec), ses=[(name, value)] in syntax order after
# mb_type, blocks=[(kind, idx, coeffs)], eos). `i4` lists 16 (flag, rem) pairs.

SPS = [("profile_idc", 77), ("constraint_set0_flag", 0), ("constraint_set1_flag", 1),
       ("constraint_set2_flag", 0), ("level_idc", 30), ("seq_parameter_set_id", 0),
       ("log2_max_frame_num_minus4", 0), ("pic_order_cnt_type", 0),
       ("log2_max_pic_order_cnt_lsb_minus4", 2), ("num_ref_frames", 2),
       ("gaps_in_frame_num_value_allowed_flag", 0), ("pic_width_in_mbs_minus1", 1),
       ("pic_height_in_map_units_minus1", 0), ("frame_mbs_only_flag", 1),
       ("direct_8x8_inference_flag", 1), ("frame_cropping_flag", 0),
       ("vui_parameters_present_flag", 0)]
PPS = [("pic_parameter_set_id", 0), ("seq_parameter_set_id", 0), ("entropy_coding_mode_flag", 1),
       ("bottom_field_pic_order_in_frame_present_flag", 0), ("num_slice_groups_minus1", 0),
       ("num_ref_idx_l0_default_active_minus1", 0), ("num_ref_idx_l1_default_active_minus1", 0),
       ("weighted_pred_flag", 0), ("weighted_bipred_idc", 0), ("pic_init_qp_minus26", 0),
       ("pic_init_qs_minus26", 0), ("chroma_qp_index_offset", 0),
       ("deblocking_filter_control_present_flag", 1), ("constrained_intra_pred_flag", 0),
       ("redundant_pic_cnt_present_flag", 0)]
SH_I = [("first_mb_in_slice", 0), ("slice_type", 7), ("pic_parameter_set_id", 0), ("frame_num", 0),
        ("idr_pic_id", 0), ("pic_order_cnt_lsb", 0), ("no_output_of_prior_pics_flag", 0),
        ("long_term_reference_flag", 0), ("slice_qp_delta", 0), ("disable_deblocking_filter_idc", 0),
        ("slice_alpha_c0_offset_div2", 0), ("slice_beta_offset_div2", 0)]
SH_P = [("first_mb_in_slice", 0), ("slice_type", 5), ("pic_parameter_set_id", 0), ("frame_num", 1),
        ("pic_order_cnt_lsb", 4), ("num_ref_idx_active_override_flag", 0),
        ("ref_pic_list_modification_flag_l0", 0), ("adaptive_ref_pic_marking_mode_flag", 0),
        ("cabac_init_idc", 1), ("slice_qp_delta", 0), ("disable_deblocking_filter_idc", 0),
        ("slice_alpha_c0_offset_div2", 0), ("slice_beta_offset_div2", 0)]
SH_B = [("first_mb_in_slice", 0), ("slice_type", 6), ("pic_parameter_set_id", 0), ("frame_num", 2),
        ("pic_order_cnt_lsb", 2), ("direct_spatial_mv_pred_flag", 1),
        ("num_ref_idx_active_override_flag", 1), ("num_ref_idx_l0_active_minus1", 1),
        ("num_ref_idx_l1_active_minus1", 0), ("ref_pic_list_modification_flag_l0", 0),
        ("ref_pic_list_modification_flag_l1", 0), ("cabac_init_idc", 2), ("slice_qp_delta", 0),
        ("disable_deblocking_filter_idc", 0), ("slice_alpha_c0_offset_div2", 0),
        ("slice_beta_offset_div2", 0)]


def coeffs(n, **at):
    c = [0] * n
    for k, v in at.items():
        c[int(k[1:])] = v
    return c


I4 = [(1, None), (0, 3), (1, None), (1, None), (0, 0), (1, None), (1, None), (0, 7),
      (1, None), (1, None), (1, None), (0, 2), (1, None), (1, None), (1, None), (1, None)]

MB_I0 = dict(addr=0, skip=None, mb_type=0, i4=I4,
             ses=[("intra_chroma_pred_mode", 1), ("coded_block_pattern", 0x11), ("mb_qp_delta", 0)],
             blocks=[("L4", 0, coeffs(16, p0=3, p2=-1, p15=2)),      # last position significant: inferred
                     ("L4", 1, coeffs(16)),                           # coded_block_flag 0
                     ("L4", 2, coeffs(16, p5=1)),
                     ("L4", 3, [1, -1, 2, -2, 1, 1, -1, 1, 1, -3, 1, 1, -1, 1, 1, 4]),   # every coefficient
                     ("CDC", 0, coeffs(4, p0=-2)),
                     ("CDC", 1, coeffs(4))],
             eos=0)
MB_I1 = dict(addr=1, skip=None, mb_type=19, i4=None,                   # Intra16x16 pred 2, chroma 1, AC
             ses=[("intra_chroma_pred_mode", 0), ("mb_qp_delta", 2)],
             blocks=[("LDC", 0, coeffs(16, p0=5, p3=-1))]
             + [("L4", b, coeffs(15, p0=1, p14=-1) if b == 5 else coeffs(15)) for b in range(16)]
             + [("CDC", 0, coeffs(4, p1=1)), ("CDC", 1, coeffs(4))],
             eos=1)
MB_P0 = dict(addr=0, skip=0, mb_type=3, i4=None,                       # P_8x8: 8x8, 8x4, 4x8, 4x4
             ses=[("sub_mb_type", 0), ("sub_mb_type", 1), ("sub_mb_type", 2), ("sub_mb_type", 3)]
             + [("mvd_l0", v) for v in (1, -2, 0, 3, 4, 0, -1, -1, 2, 2, 0, 0, 5, -5, 1, 0, 0, 9)]
             + [("coded_block_pattern", 0)],
             blocks=[], eos=0)
MB_P1 = dict(addr=1, skip=0, mb_type=7, i4=None, intra_in_p=True,     # Intra16x16 pred 1 in a P slice
             ses=[("intra_chroma_pred_mode", 2), ("mb_qp_delta", 0)],
             blocks=[("LDC", 0, coeffs(16))], eos=1)
MB_B0 = dict(addr=0, skip=0, mb_type=22, i4=None,                      # B_8x8: direct, L0, L1, Bi
             ses=[("sub_mb_type", 0), ("sub_mb_type", 1), ("sub_mb_type", 2), ("sub_mb_type", 3),
                  ("ref_idx_l0", 1), ("ref_idx_l0", 0),
                  ("mvd_l0", 3), ("mvd_l0", -4), ("mvd_l0", 0), ("mvd_l0", 1),
                  ("mvd_l1", -7), ("mvd_l1", 2), ("mvd_l1", 1), ("mvd_l1", 0),
                  ("coded_block_pattern", 0x20), ("mb_qp_delta", -1)],
             blocks=[("CDC", 0, coeffs(4, p0=1, p3=-1)), ("CDC", 1, coeffs(4, p2=2))]
             + [("CAC", b, coeffs(15, p0=-1) if b in (0, 7) else coeffs(15)) for b in range(8)],
             eos=0)
MB_B1 = dict(addr=1, skip=1, mb_type=None, i4=None, ses=[], blocks=[], eos=1)

STREAM = [(7, 3, "SPS", SPS, []), (8, 3, "PPS", PPS, []), (5, 3, "SH", SH_I, [MB_I0, MB_I1]),
          (1, 2, "SH", SH_P, [MB_P0, MB_P1]), (1, 0, "SH", SH_B, [MB_B0, MB_B1])]
SLICE_TYPE = {SH_I[1][1]: 2, SH_P[1][1]: 0, SH_B[1][1]: 1}   # spec value % 5

# ------------------------------------------------------------------ the JM emitter

JM_KIND = {"LDC": "DC luma 16x16", "L4": "Luma sng", "CDC": "2x2 DC Chroma", "AC": "AC Chroma", "CAC": "AC Chroma"}
JM_PPS_NAME = {"num_ref_idx_l0_default_active_minus1": "num_ref_idx_l0_active_minus1",
               "num_ref_idx_l1_default_active_minus1": "num_ref_idx_l1_active_minus1"}
JM_SH_NAME = {"num_ref_idx_active_override_flag": "num_ref_idx_override_flag",
              "ref_pic_list_modification_flag_l0": "ref_pic_list_reordering_flag_l0",
              "ref_pic_list_modification_flag_l1": "ref_pic_list_reordering_flag_l1",
              "adaptive_ref_pic_marking_mode_flag": "adaptive_ref_pic_buffering_flag"}
JM_SPS_NAME = {"constraint_set0_flag": "constrained_set0_flag", "constraint_set1_flag": "constrained_set1_flag",
               "constraint_set2_flag": "constrained_set2_flag"}


def emit_jm(stream):
    """JM 18.4 trace_dec.txt: headers first (a whole picture ahead), MB lines after."""
    hdr, mbs = [], []
    poc = 0
    sym = 0
    for ntype, ref, ctx, fields, macroblocks in stream:
        hdr.append("Annex B NALU w/ long startcode, len 99, forbidden_bit 0, nal_reference_idc %d, nal_unit_type %d" % (ref, ntype))
        hdr.append("")
        names = {"SPS": JM_SPS_NAME, "PPS": JM_PPS_NAME, "SH": JM_SH_NAME}[ctx]
        for f, v in fields:
            hdr.append("@%-5d %s: %-45s %s (%3d) " % (sym, ctx, names.get(f, f), "1", v))
            sym += 1
            if ctx == "SPS" and f == "constraint_set2_flag":
                for extra in ("constrained_set3_flag", "constrained_set4_flag", "constrained_set5_flag", "reserved_zero_2bits"):
                    hdr.append("@%-5d SPS: %-45s 0 (  0) " % (sym, extra))
        if ctx == "SH":
            hdr.append("@%-5d SEI: %-45s 1 (  0) " % (sym, "some_payload_field"))
        if not macroblocks:
            continue
        stype = SLICE_TYPE[dict(fields)["slice_type"]]
        last = len(macroblocks) - 1
        for k, mb in enumerate(macroblocks):
            mbs.append("")
            mbs.append("*********** POC: %d (I/P) MB: %d Slice: 0 Type %d **********" % (poc, mb["addr"], stype))
            def se(name, v):
                mbs.append("@%-6d %-63s (%3d)" % (len(mbs), name, v))
            if mb["skip"] is not None:
                se("mb_skip_flag", 1 - mb["skip"])
            if not mb["skip"]:
                se("mb_type", mb["mb_type"] + 1 if stype == 0 else mb["mb_type"])
                if mb["i4"]:
                    for flag, rem in mb["i4"]:
                        se("intra4x4_pred_mode", -1 if flag else rem)
                for name, v in mb["ses"]:
                    if name.startswith("mvd_"):
                        # JM's 16x16-partition mvds are "mvd0_lX"/"mvd1_lX"; sub-partition ones "mvd_lX"
                        se(name, v)
                    else:
                        se(name, v)
                for kind, idx, c in mb["blocks"]:
                    pos = 0
                    for i, v in enumerate(c):
                        if v:
                            mbs.append("@%-6d %-53s %3d  %3d" % (len(mbs), JM_KIND[kind], v, i - pos))
                            pos = i + 1
                    mbs.append("@%-6d %-53s %3d  %3d" % (len(mbs), JM_KIND[kind], 0, 0))
            if k != last:                 # JM never decodes the picture-final terminator
                se("end_of_slice_flag", mb["eos"])
        poc += 2
    return [x + "\n" for x in hdr + mbs]


# ------------------------------------------------------------------ the donated emitter

JVT_KIND = {"LDC": "luma.intra_dc", "L4": "luma.dc_ac", "CDC": "chroma.dc", "CAC": "chroma.ac"}
JVT_NAME = {"bottom_field_pic_order_in_frame_present_flag": "pic_order_present_flag",
            "ref_pic_list_modification_flag_l0": "ref_pic_list_reordering_flag_l0",
            "ref_pic_list_modification_flag_l1": "ref_pic_list_reordering_flag_l1",
            "num_ref_idx_l0_default_active_minus1": "num_ref_idx_l0_active_minus1",
            "num_ref_idx_l1_default_active_minus1": "num_ref_idx_l1_active_minus1"}


def emit_jvt(stream):
    out = []
    n = 0

    def se(name, v, bits="1"):
        out.append("@%-4X: %-42s: %3s : (%d)  : [%s]" % (len(out), name, "" if v is None else v, len(bits), bits))

    for ntype, ref, ctx, fields, macroblocks in stream:
        out.append("<<< Begin Nal Unit [%d]" % n)
        n += 1
        se("forbidden_zero_bit", 0)
        se("nal_ref_idc", ref)
        se("nal_unit_type", ntype)
        out.append({"SPS": "<<< Begin Sequence Parameter Set RBSP", "PPS": "<<< Begin Picture Parameter Set RBSP",
                    "SH": "<<< Begin Slice "}[ctx])
        for f, v in fields:
            se(JVT_NAME.get(f, f), v)
            if ctx == "SPS" and f == "constraint_set2_flag":
                se("reserved_zero_5bits", 0)
        if ctx != "SH":
            se("rbsp_stop_one_bit", 1)
            se("rbsp_alignment_zero_bit", 0)
            out.append(">>> End %s RBSP" % ("Sequence Parameter Set" if ctx == "SPS" else "Picture Parameter Set"))
            out.append(">>> End Nal Unit [%d] (5d bytes)" % (n - 1))
            continue
        se("cabac_alignment_one_bit", 1)
        out.append("")
        out.append("******** Start Pic %d ********" % (n - 3))
        se("initialize", None, "101101000")
        stype = SLICE_TYPE[dict(fields)["slice_type"]]
        for mb in macroblocks:
            if mb["skip"] is not None:
                se("mb_skip_flag", mb["skip"])
            out.append("")
            out.append("+++ MB %d" % mb["addr"])
            if not mb["skip"]:
                if stype == 2:
                    se("intra_16x16_decision", 0 if mb["mb_type"] == 0 else 1)
                if not mb.get("intra_in_p"):          # the tracer's gap: no mb_type for intra in P/B
                    se("mb_type", mb["mb_type"])
                if mb["i4"]:
                    for b, (flag, rem) in enumerate(mb["i4"]):
                        out.append("intra4x4 : BK %d" % b)
                        se("prev_intra4x4_pred_mode_flag", flag)
                        if not flag:
                            se("rem_intra4x4_pred_mode", rem)
                blk = 0
                for name, v in mb["ses"]:
                    if name in ("ref_idx_l0", "ref_idx_l1"):
                        out.append("l%s ( %s ) ref_idx : BK %d" % (name[-1], "FW" if name[-1] == "0" else "BW", blk))
                        se("ref_idx", v)
                    elif name in ("mvd_l0", "mvd_l1"):
                        if blk % 2 == 0:
                            out.append("l%s ( %s ) mvd : BK %d" % (name[-1], "FW" if name[-1] == "0" else "BW", blk // 2))
                        else:
                            out.append("mvd : BK %d" % (blk // 2))
                        se("mvd", v)
                        blk += 1
                    else:
                        se(name, v)
                for kind, idx, c in mb["blocks"]:
                    bk = idx if kind == "L4" else idx % 4 if kind == "CAC" else 0
                    out.append("%s : BK %d" % (JVT_KIND[kind], bk))
                    sig = [i for i, v in enumerate(c) if v]
                    se("coded_block_flag", 1 if sig else 0)
                    if sig:
                        for i in range(len(c) - 1):
                            se("significant_coeff_flag", 1 if c[i] else 0)
                            if c[i]:
                                se("last_significant_coeff_flag", 1 if i == sig[-1] else 0)
                                if i == sig[-1]:
                                    break
                        for i in reversed(sig):
                            se("coeff_abs_level_minus1", abs(c[i]) - 1)
                            se("coeff_sign_flag", 1 if c[i] < 0 else 0)
                    out.append("@@@ DCT block bits : 7")
            se("+++ end_of_slice_flag of MB %d" % mb["addr"], mb["eos"], "")
        se("rbsp_stop_one_bit", 1)
        out.append(">>> End Slice")
        out.append(">>> End Nal Unit [%d] (99d bytes)" % (n - 1))
        out.append("")
        out.append(">>> End Access Unit (100 bytes)")
    return [x + "\n" for x in out]


# ------------------------------------------------------------------ tests

print("[both formats -> one canonical stream]")
jm = T.parse_jm(emit_jm(STREAM))
jvt = T.parse_jvt_file(emit_jvt(STREAM))
d, wild = T.diff(jm, jvt, "jm", "jvt")
Sc.check("identical (first difference)", d, None)
Sc.check("exactly the untraced intra-in-P mb_type is a wildcard", wild, 1)
Sc.check("record count", len(jm), len(jvt))

print("[JM conventions]")
Sc.check("mb_skip_flag un-inverted (B skip MB)", jm[jm.index("M 1", jm.index("N 1 0")) + 1], "E mb_skip_flag 1")
p0 = jm.index("M 0", jm.index("N 1 2"))
Sc.check("P mb_type is spec (P_8x8 = 3)", jm[p0 + 2], "E mb_type 3")
Sc.check("P intra mb_type from JM", jm[jm.index("M 1", p0) + 2], "E mb_type 7")
Sc.check("P intra mb_type from the donated tracer", jvt[jm.index("M 1", p0) + 2], "E mb_type *")
Sc.check("intra4x4 -1 -> flag 1", jm[3 + len(SPS) + len(PPS) + len(SH_I) + 2], "E prev_intra4x4_pred_mode_flag 1")
Sc.check("intra4x4 rem -> flag 0 + rem", jm[3 + len(SPS) + len(PPS) + len(SH_I) + 3:][:2],
         ["E prev_intra4x4_pred_mode_flag 0", "E rem_intra4x4_pred_mode 3"])
Sc.check("picture-final end_of_slice_flag synthesised (3 pictures)", jm.count("E end_of_slice_flag 1"), 3)
Sc.check("slice_type kept as coded (7 = I)", "S slice_type 7" in jm, True)
Sc.check("PPS default counts named as in the spec", "S num_ref_idx_l0_default_active_minus1 0" in jm, True)
Sc.check("SEI / reserved / rbsp lines dropped", any("some_payload" in r or "reserved" in r or "rbsp" in r for r in jm), False)

print("[residual reconstruction]")
b = [r for r in jm if r.startswith("B ")]
Sc.check("L4 with the last position significant", b[0], "B L4 0 16 3 0 -1 0 0 0 0 0 0 0 0 0 0 0 0 2")
Sc.check("coded_block_flag 0 block", b[1], "B L4 1 16 " + " ".join(["0"] * 16))
Sc.check("all 16 coefficients", b[3], "B L4 3 16 1 -1 2 -2 1 1 -1 1 1 -3 1 1 -1 1 1 4")
Sc.check("chroma DC Cb / Cr", b[4:6], ["B CDC 0 4 -2 0 0 0", "B CDC 1 4 0 0 0 0"])
Sc.check("Intra16x16 AC block 5 (15 coefficients, last inferred)", b[6 + 1 + 5], "B L4 5 15 1 0 0 0 0 0 0 0 0 0 0 0 0 0 -1")
Sc.check("B slice chroma AC 0..7", [x.split()[:4] for x in b[-8:]], [["B", "CAC", str(i), "15"] for i in range(8)])

print("[the diff can fail]")
mut = list(jm)
i = next(k for k, r in enumerate(mut) if r.startswith("B L4 2 "))
mut[i] = mut[i].replace(" 1 ", " -1 ", 1)
Sc.check("one coefficient sign", T.diff(mut, jvt)[0] is not None, True)
mut = list(jm)
i = next(k for k, r in enumerate(mut) if r.startswith("E mvd_l1 "))
mut[i] = "E mvd_l1 99"
Sc.check("one mvd", T.diff(mut, jvt)[0] is not None, True)
mut = list(jm)
del mut[jm.index("E mb_skip_flag 0")]
Sc.check("a dropped record", T.diff(mut, jvt)[0] is not None, True)
mut = list(jm)
mut[jm.index("E end_of_slice_flag 1")] = "E end_of_slice_flag 0"
Sc.check("the synthesised terminator", T.diff(mut, jvt)[0] is not None, True)

print("[refusals]")
lines = emit_jm(STREAM)
k = next(i for i, x in enumerate(lines) if "mb_type" in x)
Sc.raises("MBAFF in a JM trace", lambda: T.parse_jm(lines[:k] + ["@9      mb_field_decoding_flag      (  1)\n"] + lines[k:]),
          T.TraceError, "refused")
lines = emit_jvt(STREAM)
k = next(i for i, x in enumerate(lines) if "coded_block_pattern" in x)
Sc.raises("8x8 transform in a donated trace (High is scored against JM, not the 2004 tracer)",
          lambda: T.parse_jvt_file(lines[:k + 1] + ["@40  : transform_size_8x8_flag     :   1 : (1)  : [1]\n"] + lines[k + 1:]),
          T.TraceError, "not read from a donated trace")
Sc.raises("an ES without access-unit delimiters", lambda: T.trim_to_last_au(b"\x00\x00\x01\x67" * 4),
          T.TraceError, "delimiter")

print("[the real proof: ldecod vs the H.264.1 donated trace, CABACI3_Sony_B]")
refs = os.environ.get("H264_REFS_DIR", os.path.expanduser("~/h264-refs"))
zpath = os.path.join(refs, "H.264.1_bitstreams", "AVCv1", "CABACI3_Sony_B.zip")
exe = T.jm_binary()
if not os.path.exists(zpath) or not os.access(exe, os.X_OK):
    print("  SKIP: needs %s and %s (tools/jm_build.sh)" % (zpath, exe))
else:
    with tempfile.TemporaryDirectory(prefix="h264_conf_") as d:
        with zipfile.ZipFile(zpath) as z:
            z.extractall(d)
        jsv = os.path.join(d, "CABACI3_Sony_B.jsv")
        trace = os.path.join(d, "CABACI3_Sony_B-trace.txt")
        yuv = os.path.join(d, "jm.yuv")
        lines, frames = T.run_jm(jsv, yuv=yuv)
        Sc.check("ldecod decoded 300 frames", frames, 300)
        Sc.check("ldecod pixels == the package's reference YUV",
                 open(yuv, "rb").read() == open(os.path.join(d, "CABACI3_Sony_B.yuv"), "rb").read(), True)
        a = T.parse_jm(lines)
        b = T.parse_jvt_file(open(trace, errors="replace").readlines())
        dd, wild = T.diff(a, b, "ldecod", "donated")
        Sc.check("canonical streams identical (first difference)", dd, None)
        Sc.check("records", len(a) > 500000, True)
        Sc.check("wildcards = the intra-16x16 MBs in P/B slices", wild, 296)

print("[the VUI (P5b): ldecod vs the model on a synthetic spec-maximum VUI]")
have_x264 = shutil.which("ffmpeg") and "libx264" in subprocess.run(
    ["ffmpeg", "-hide_banner", "-encoders"], stdout=subprocess.PIPE, universal_newlines=True).stdout
if not os.access(exe, os.X_OK) or not have_x264:
    print("  SKIP: needs %s and ffmpeg with libx264" % exe)
else:
    import h264_fe_ref as FE
    import h264_synth
    with tempfile.TemporaryDirectory(prefix="h264_vui_") as d:
        base = os.path.join(d, "base.264")
        subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=64x64:rate=24", "-frames:v", "3",
                        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-x264-params", "cabac=1:8x8dct=0:bframes=0",
                        "-f", "h264", "-y", base], check=True)
        data, _n = h264_synth.rewrite(open(base, "rb").read(), "max")
        vmax = os.path.join(d, "vmax.264")
        open(vmax, "wb").write(data)
        model = FE.decode_stream(data, {})
        lines, _frames = T.run_jm(vmax)
        jm = T.parse_jm(lines)
        dd, _w = T.diff(model, jm, "model", "ldecod")
        Sc.check("model == ldecod on every VUI field at its maximum (first difference)", dd, None)
        Sc.check("the VUI is there: two HRD structures of 32 CPBs",
                 sum(1 for r in jm if r == "S cpb_cnt_minus1 31"), 2)
        Sc.check("u(32) 2^32 - 1 read unsigned from JM's int",
                 "S num_units_in_tick 4294967295" in jm, True)
Sc.finish()
