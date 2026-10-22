#!/usr/bin/env python3
"""cavlc_check.py -- what the pixels of a rewritten stream cannot show (fj#20, docs/cavlc.md):
the CAVLC -> CABAC rewriter's output decoded by the project's own CABAC model
(tools/h264_fe_ref.py: every syntax element where the spec puts it, no CabacError, every
slice ending where its data ends) and checked for

  bins       the model's bin count equals the rewriter's (--bins N): the two count the same
             thing independently, the encoder its EncodeDecision / Bypass / Terminate calls,
             the model its DecodeBin calls
  limit      7.4.2.10 / 9.3.4.6 per picture: BinCountsInNALunits <= (32 / 3) *
             NumBytesInVclNALunits + (RawMbBits * PicSizeInMbs) / 32, RawMbBits 3072 (8-bit
             4:2:0) -- the cabac_zero_words the rewriter appends must be enough
  headers    every SPS: profile_idc neither 66 nor 88, constraint_set0 and constraint_set2 0
             (CABAC is neither Baseline nor Extended); a former 66 / 88 is 77 with
             constraint_set1 1, any other profile unchanged; every PPS entropy_coding_mode_flag 1

    cavlc_check.py ORIGINAL.264 REWRITTEN.264 [--bins N]     exit 0 and "cavlc_check: OK ..."
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import h264_fe_ref as FE  # noqa: E402

RAW_MB_BITS = 3072


def sps_heads(data):
    out = []
    for _pos, _ref, t, rbsp in FE.nal_units_pos(data):
        if t == 7:
            out.append((rbsp[0], rbsp[1]))
    return out


def vcl_sizes(data):
    """NumBytesInNALunit of each VCL NAL unit, in order (header byte and emulation prevention
    bytes included, the start code and trailing zero bytes not)"""
    starts = [p for p, _r, t, _b in FE.nal_units_pos(data)]
    types = [t for _p, _r, t, _b in FE.nal_units_pos(data)]
    sizes = []
    for k, (p, t) in enumerate(zip(starts, types)):
        e = starts[k + 1] - 3 if k + 1 < len(starts) else len(data)
        while e > p and data[e - 1] == 0:
            e -= 1
        if t in (1, 5):
            sizes.append(e - p)
    return sizes


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("original")
    ap.add_argument("rewritten")
    ap.add_argument("--bins", type=int, help="the rewriter's bin count (cavlc2cabac's report)")
    a = ap.parse_args(argv)
    orig = open(a.original, "rb").read()
    data = open(a.rewritten, "rb").read()
    bad = []
    stats, slices = {}, []
    try:
        FE.decode_stream(data, stats, slices)
    except (FE.Refused, FE.FeError, FE.CabacError) as e:
        print("cavlc_check: FAIL [model] %s: %s" % (type(e).__name__, e))
        return 1
    if a.bins is not None and stats["bins"] != a.bins:
        bad.append("[bins] the model decoded %d bins, the rewriter wrote %d" % (stats["bins"], a.bins))
    sizes = vcl_sizes(data)
    if len(sizes) != len(slices):
        bad.append("[limit] %d VCL NAL units, %d slices" % (len(sizes), len(slices)))
    pics, worst = 0, 0.0
    cur = None

    def close(p):
        nonlocal worst
        if p is None:
            return
        bins, nbytes, mbs = p
        limit = 32.0 / 3.0 * nbytes + RAW_MB_BITS * mbs / 32.0
        worst = max(worst, bins / limit)
        if bins > limit:
            bad.append("[limit] a picture of %d bins in %d bytes, %d macroblocks: above %.1f" % (bins, nbytes, mbs, limit))
    for s, n in zip(slices, sizes):
        if s["first_mb"] == 0:
            close(cur)
            cur = [0, 0, s["width_mbs"] * s["height_mbs"]]
            pics += 1
        if cur is None:
            bad.append("[limit] a slice before any picture's first")
            continue
        cur[0] += s["bins"]
        cur[1] += n
    close(cur)
    before, after = sps_heads(orig), sps_heads(data)
    if len(before) != len(after):
        bad.append("[headers] %d SPS in, %d out" % (len(before), len(after)))
    for (p0, c0), (p1, c1) in zip(before, after):
        if p1 in (66, 88) or c1 & 0xA0:
            bad.append("[headers] SPS profile_idc %d constraint flags 0x%02x after the rewrite" % (p1, c1))
        if p0 in (66, 88) and (p1 != 77 or not c1 & 0x40):
            bad.append("[headers] SPS profile_idc %d -> %d (constraint 0x%02x): not Main" % (p0, p1, c1))
        if p0 not in (66, 88) and p1 != p0:
            bad.append("[headers] SPS profile_idc %d changed to %d" % (p0, p1))
    for _pos, _ref, t, rbsp in FE.nal_units_pos(data):
        if t == 8:
            br = FE.BitReader(rbsp)
            br.ue()
            br.ue()
            if not br.read_bit():
                bad.append("[headers] a PPS still CAVLC")
    for b in bad[:10]:
        print("cavlc_check: FAIL %s" % b)
    if bad:
        return 1
    print("cavlc_check: OK %d pictures, %d slices, %d bins, the 7.4.2.10 limit at most %.0f %%"
          % (pics, len(slices), stats["bins"], 100 * worst))
    return 0


if __name__ == "__main__":
    sys.exit(main())
