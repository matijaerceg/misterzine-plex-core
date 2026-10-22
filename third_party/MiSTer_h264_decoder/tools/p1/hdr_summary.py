#!/usr/bin/env python3
"""Summarise an Annex-B stream's H.264 features from ffmpeg's trace_headers (Phase 1).

    hdr_summary.py FILE.264

Counts every value each listed SPS / PPS / slice-header field takes, and the slices per
picture -- what a decoder must support to play the stream (docs/p1_measurements.md).
"""
import collections, re, subprocess, sys
KEYS = ["profile_idc", "constraint_set", "level_idc", "entropy_coding_mode_flag", "transform_8x8_mode_flag",
        "max_num_ref_frames", "num_ref_idx_l0_default_active_minus1", "frame_mbs_only_flag", "direct_8x8_inference_flag",
        "weighted_pred_flag", "weighted_bipred_idc", "pic_order_cnt_type", "pic_struct_present_flag",
        "seq_scaling_matrix_present_flag", "pic_scaling_matrix_present_flag", "slice_type", "nal_unit_type",
        "num_ref_idx_active_override_flag", "deblocking_filter_control_present_flag", "disable_deblocking_filter_idc",
        "cabac_init_idc", "constrained_intra_pred_flag", "timing_info_present_flag", "max_dec_frame_buffering"]
out = subprocess.run(["ffmpeg", "-v", "verbose", "-i", sys.argv[1], "-c", "copy", "-bsf:v", "trace_headers",
                      "-f", "null", "-"], capture_output=True, text=True).stderr
c = {k: collections.Counter() for k in KEYS}
slices_per_pic = collections.Counter(); cur = 0
for line in out.splitlines():
    m = re.match(r"\[trace_headers @ [^\]]*\] \d+\s+(\S+)\s+\S+ = (-?\d+)", line)
    if not m:
        continue
    k, v = m.group(1), int(m.group(2))
    base = re.sub(r"\[.*", "", k)
    if base.startswith("constraint_set"):
        c["constraint_set"][f"{base}={v}"] += 1
    elif base in c:
        c[base][v] += 1
    if base == "first_mb_in_slice":
        if v == 0 and cur:
            slices_per_pic[cur] += 1; cur = 0
        cur += 1
if cur: slices_per_pic[cur] += 1
print(f"== {sys.argv[1]}")
for k in KEYS:
    if c[k]:
        print(f"  {k:42s} " + ", ".join(f"{v}:{n}" for v, n in sorted(c[k].items(), key=lambda x: str(x[0]))))
print(f"  {'slices per picture':42s} " + ", ".join(f"{v}:{n}" for v, n in sorted(slices_per_pic.items())))
