#!/usr/bin/env python3
"""Slice fixtures for bench/h264/mb_syntax_tb.sv: real slices, decoded by
tools/h264_fe_ref.py, as the byte stream mb_syntax + cabac_engine consume and the SE
stream they must emit (docs/h264_frontend.md S4).

Files (one word per line, $readmemh):
  <stem>.bytes.hex  the slice data from the CABAC start (byte aligned, EPB removed)
  <stem>.se.hex     32-bit words {kind[7:0], aux[7:0], val[15:0]}: the SE stream in the
                    RTL's emission order (table below); val is two's complement
  <stem>.meta.hex   [0] n_bytes [1] n_se [2] slice_type (0 P 1 B 2 I) [3] first_mb
                    [4] num_ref_idx_l0_active [5] num_ref_idx_l1_active [6] field_pic_flag
                    [7] PicWidthInMbs [8] PicHeightInMbs (of this picture/field)
                    [9] SliceQPY [10] init set (0..2 cabac_init_idc, 3 I) [11] slice id
                    [12] n_mbs (decoded by the slice) [13] bins (the model's count)
                    [14] transform_8x8_mode_flag (PPS) [15] direct_8x8_inference_flag (SPS)

SE kinds (shared with h264/dec/mb_syntax.sv, keep in step):
   1 MB_START      val = mb address
   2 SKIP_FLAG     val 0/1
   3 MB_TYPE       spec value
   4 SUB_MB_TYPE
   5 PREV_INTRA    prev_intra4x4_pred_mode_flag
   6 REM_INTRA     rem_intra4x4_pred_mode
   7 CHROMA_PRED   intra_chroma_pred_mode
   8 REF_L0        ref_idx_l0
   9 REF_L1
  10 MVD_L0        one component (x, then y)
  11 MVD_L1
  12 CBP           coded_block_pattern
  13 QP_DELTA      mb_qp_delta
  14 BLK_START     aux = block kind (0 LDC, 1 L4, 2 CDC, 3 CAC, 4 PCM) | idx << 4; val = n
  15 COEF          one coefficient in scan order (n per block), or a PCM sample
  16 END_OF_SLICE  val 0/1
  20 T8            transform_size_8x8_flag (High; 17..19 are h264_top's NAL / HDR / EOS)
  (PREV_INTRA / REM_INTRA carry the Intra_8x8 modes too; BLK_START kind 5 = L8, 64 levels)

    mb_syntax_golden.py stream.264 --slice 0 --out bench/h264/fixtures/gen/mbs_x
    mb_syntax_golden.py stream.264 --list          # the slices and what they hold
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import h264_fe_ref as FE  # noqa: E402
import h264_trace_ref as TR  # noqa: E402

K = {"MB_START": 1, "SKIP_FLAG": 2, "MB_TYPE": 3, "SUB_MB_TYPE": 4, "PREV_INTRA": 5, "REM_INTRA": 6,
     "CHROMA_PRED": 7, "REF_L0": 8, "REF_L1": 9, "MVD_L0": 10, "MVD_L1": 11, "CBP": 12, "QP_DELTA": 13,
     "BLK_START": 14, "COEF": 15, "END_OF_SLICE": 16, "T8": 20}
E_KIND = {"mb_skip_flag": K["SKIP_FLAG"], "mb_type": K["MB_TYPE"], "sub_mb_type": K["SUB_MB_TYPE"],
          "prev_intra4x4_pred_mode_flag": K["PREV_INTRA"], "rem_intra4x4_pred_mode": K["REM_INTRA"],
          "intra_chroma_pred_mode": K["CHROMA_PRED"], "ref_idx_l0": K["REF_L0"], "ref_idx_l1": K["REF_L1"],
          "mvd_l0": K["MVD_L0"], "mvd_l1": K["MVD_L1"], "coded_block_pattern": K["CBP"],
          "mb_qp_delta": K["QP_DELTA"], "end_of_slice_flag": K["END_OF_SLICE"],
          "transform_size_8x8_flag": K["T8"], "prev_intra8x8_pred_mode_flag": K["PREV_INTRA"],
          "rem_intra8x8_pred_mode": K["REM_INTRA"]}
BLK_KIND = {"LDC": 0, "L4": 1, "CDC": 2, "CAC": 3, "PCM": 4, "L8": 5}


def se_words(records):
    """canonical M/E/B records of one slice -> [(kind, aux, val)]"""
    out = []
    for r in records:
        f = r.split(" ")
        if f[0] == "M":
            out.append((K["MB_START"], 0, int(f[1])))
        elif f[0] == "E":
            out.append((E_KIND[f[1]], 0, int(f[2])))
        elif f[0] == "B":
            kind, idx, n = BLK_KIND[f[1]], int(f[2]), int(f[3])
            out.append((K["BLK_START"], kind | (idx << 4), n))
            for c in f[4:4 + n]:
                out.append((K["COEF"], 0, int(c)))
        elif f[0] in ("N", "S"):
            continue
        else:
            raise ValueError("unknown record " + r)
    return out


def write(stem, sl):
    os.makedirs(os.path.dirname(stem) or ".", exist_ok=True)
    words = se_words(sl["records"])
    with open(stem + ".bytes.hex", "w") as f:
        f.write("".join("%02x\n" % b for b in sl["data"]))
    with open(stem + ".se.hex", "w") as f:
        for kind, aux, val in words:
            f.write("%02x%02x%04x\n" % (kind, aux, val & 0xFFFF))
    init_set = 3 if sl["slice_type"] == FE.I else sl["cabac_init_idc"]
    meta = [len(sl["data"]), len(words), sl["slice_type"], sl["first_mb"], sl["num_ref_idx"][0],
            sl["num_ref_idx"][1], sl["field_pic"], sl["width_mbs"], sl["height_mbs"], sl["qp"], init_set,
            sl["slice_id"], sl["n_mbs"], sl["bins"], sl["t8_mode"], sl["d8inf"]]
    with open(stem + ".meta.hex", "w") as f:
        f.write("".join("%08x\n" % v for v in meta))
    return len(words)


def describe(i, sl):
    kinds = {}
    for r in sl["records"]:
        if r.startswith("E mb_type "):
            kinds["mb_type"] = kinds.get("mb_type", 0) + 1
        elif r.startswith("E mb_skip_flag 1"):
            kinds["skip"] = kinds.get("skip", 0) + 1
        elif r.startswith("B PCM"):
            kinds["pcm"] = kinds.get("pcm", 0) + 1
    return "slice %3d: %s first_mb %4d n_mbs %4d field %d refs %s qp %2d set %s bytes %6d bins %7d %s" % (
        i, "PBI"[sl["slice_type"]], sl["first_mb"], sl["n_mbs"], sl["field_pic"], sl["num_ref_idx"], sl["qp"],
        3 if sl["slice_type"] == FE.I else sl["cabac_init_idc"], len(sl["data"]), sl["bins"], kinds)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("stream", nargs="?")
    ap.add_argument("--slice", type=int, nargs="*", help="slice indices to write")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--out", help="stem; with several slices, <stem>_<i>")
    a = ap.parse_args(argv)
    if a.stream:
        data = open(a.stream, "rb").read()
    else:
        ap.error("a stream")
    slices = []
    FE.decode_stream(data, None, slices)
    if a.list or not a.slice:
        for i, sl in enumerate(slices):
            print(describe(i, sl))
        return 0
    for i in a.slice:
        stem = a.out if len(a.slice) == 1 else "%s_%d" % (a.out, i)
        n = write(stem, slices[i])
        print("%s: %s -> %d SE words" % (stem, describe(i, slices[i]), n))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (FE.Refused, FE.FeError, TR.TraceError) as e:
        sys.exit("mb_syntax_golden: %s" % e)
