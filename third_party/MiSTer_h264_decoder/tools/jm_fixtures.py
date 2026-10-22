#!/usr/bin/env python3
"""JM lencod fixtures for the P4 control paths no x264 setting and no disc reaches
(docs/h264_recon.md S5): field MMCOs, long-term references used in frame streams, the
B-list swap of 8.2.4.2.3/4, and list modification with its duplicate removal.

Per case: a source made with ffmpeg, encoded by JM 18.4's lencod (tools/jm_build.sh
--lencod; Main profile, CABAC, no 8x8 transform), then three checks before the fixture is
written -- a fixture that fails any of them is not written, and the case FAILs:
  1. the model (tools/h264_recon_ref.py) decodes the stream bit-exact against ffmpeg;
  2. COVERAGE: the model's counters (Decoder.cov) show the stream reaches the case's own
     path (a fixture whose stream never swaps a list cannot vouch for the swap);
  3. the fixture itself: tools/recon_top_golden.py (the recon_top_tb hex files).

    jm_fixtures.py CASE --out STEM          (CASE: jfmmco jlt jswap jmod jdefer; --list)
"""
import argparse
import os
import subprocess
import sys
import tempfile

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import h264_fe_ref as FE  # noqa: E402
import h264_recon_ref as RR  # noqa: E402
import recon_top_golden as RG  # noqa: E402

W, H = 96, 64

# the encoder settings every case shares: Main profile, CABAC, 4x4 transform only, no
# weighted prediction, fixed QPs, P pictures unless a case says otherwise
BASE = {
    "ProfileIDC": 77, "LevelIDC": 30, "SymbolMode": 1, "Transform8x8Mode": 0,
    "SourceWidth": W, "SourceHeight": H, "OutputWidth": W, "OutputHeight": H, "FrameRate": 30.0,
    "IntraPeriod": 0, "IDRPeriod": 0, "NumberBFrames": 0, "QPISlice": 28, "QPPSlice": 28, "QPBSlice": 30,
    "SearchRange": 16, "WeightedPrediction": 0, "WeightedBiprediction": 0, "RDOptimization": 1,
    "Log2MaxFNumMinus4": 0, "DisableSubpelME": 0, "YUVFormat": 1, "LoopFilterDisable": 0,
}

# case: (what it covers, frames, source kind, encoder settings, {counter: minimum})
CASES = {
    "jfmmco": ("field pictures with MMCOs (PocMemoryManagement)", 12, "scroll",
               {"PicInterlace": 1, "PocMemoryManagement": 1, "NumberReferenceFrames": 3},
               {"mmco_field": 1}),
    "jlt": ("a long-term reference used in a frame stream (SetFirstAsLongTerm)", 12, "revisit",
            {"SetFirstAsLongTerm": 1, "NumberReferenceFrames": 2},
            {"lt_used": 1}),
    # BReferencePictures 2 with no B frames codes every anchor as a B slice over past
    # references only (low-delay B): list 1 = list 0, so the swap (PReplaceBSlice is the
    # opposite: B positions as P slices)
    "jswap": ("low-delay B slices, past references only: the list-1 swap (BReferencePictures 2)", 10, "scroll",
              {"BReferencePictures": 2, "NumberBFrames": 0, "NumberReferenceFrames": 3},
              {"b_swap": 1}),
    # the encoder reorders list 0 by POC distance, which differs from the FrameNumWrap
    # order only when the references are not in display order: reference B pictures
    # mod_dup_used, not mod_dup_removed: a removal only shows where a partition predicts from
    # an index it changed. lencod never writes such a stream -- its ReferenceReorder 1 names
    # every entry (the removal changes nothing), 2 crashes this tree -- so the P slices of a
    # plain 3-reference stream get ONE operation spliced into their headers
    # (rewrite_modification): [B, A, B, C] -> removal -> [B, A, C], index 2 in use.
    "jmod": ("list modification whose duplicate removal is observable (headers rewritten)", 16, "revisit",
             {"NumberReferenceFrames": 3},
             {"mod": 1, "mod_dup_used": 1}),
    # P5d: non-reference B FIELD pairs in a DPB the VUI keeps small (max_dec_frame_buffering
    # 2), so a B pair's first field is output directly (C.4.5.2) before its partner exists:
    # the store waits for its second field and is emitted whole (docs/display.md). The
    # order is checked against the spec's per-picture process and JM's output as well
    "jdefer": ("non-reference field pairs output directly: a store emitted with its second field", 12, "scroll",
               {"PicInterlace": 1, "NumberBFrames": 1, "NumberReferenceFrames": 2, "EnableVUISupport": 1,
                "VUI_bitstream_restriction_flag": 1, "VUI_max_dec_frame_buffering": 2, "VUI_num_reorder_frames": 1},
               {"out_deferred": 1}),
}


def source(kind, n, path):
    """scroll: testsrc2 moving by sub-pixel steps with a little noise. revisit: the same,
    but every fourth frame repeats frame 0 -- a picture a long-term (or a reordered, older)
    reference predicts best."""
    f = "testsrc2=size=%dx%d:rate=30,scroll=h=0.013:v=0.021,noise=alls=6:allf=t:all_seed=5" % (W, H)
    raw = subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", f, "-frames:v", str(n),
                          "-pix_fmt", "yuv420p", "-f", "rawvideo", "-"], capture_output=True, check=True).stdout
    fs = W * H * 3 // 2
    frames = [raw[i * fs:(i + 1) * fs] for i in range(n)]
    if kind == "revisit":
        frames = [frames[0] if i % 4 == 3 else fr for i, fr in enumerate(frames)]
    with open(path, "wb") as fo:
        fo.write(b"".join(frames))


def _ue(v):
    """ue(v) as a bit string"""
    v += 1
    return "0" * (v.bit_length() - 1) + format(v, "b")


def _escape(rbsp):
    """emulation prevention (7.4.1): 0x03 after two zeros before a byte <= 3"""
    out = bytearray()
    zeros = 0
    for b in rbsp:
        if zeros >= 2 and b <= 3:
            out.append(3)
            zeros = 0
        out.append(b)
        zeros = zeros + 1 if b == 0 else 0
    if out and out[-1] == 0:
        out.append(3)
    return bytes(out)


def rewrite_modification(data):
    """Every P slice with three references active and three available (frame_num >= 3)
    gets ref_pic_list_modification_flag_l0 = 1 and ONE operation, idc 0 with
    abs_diff_pic_num_minus1 1 (picNum = CurrPicNum - 2: the default list's second entry to
    the front), in place of its flag 0. A CABAC slice's data starts byte-aligned after the
    header (cabac_alignment_one_bit), so the header is re-emitted bit for bit around the
    splice, padded with ones, and the slice data follows unchanged. The stream stays
    standard: the model and ffmpeg decode it (check())."""
    out = bytearray()
    sps_map, pps_map = {}, {}
    for s0, e0, t in _nal_spans(data):
        nal = data[s0:e0]
        sc = nal.index(b"\x00\x00\x01") + 3
        rbsp = next(FE.nal_units(nal))[2] if t in (1, 5, 7, 8) else None
        if t == 7:
            sp = FE.parse_sps(rbsp, [])
            sps_map[sp.id] = sp
        elif t == 8:
            pp = FE.parse_pps(rbsp, sps_map, [])
            pps_map[pp.id] = pp
        elif t == 1:
            br = FE.BitReader(rbsp)
            pos = {}

            class Rec(list):
                def append(self, item):
                    pos[item.split()[1]] = br.pos
                    list.append(self, item)
            h = FE.parse_slice_header(br, t, (nal[sc] >> 5) & 3, sps_map, pps_map, Rec())
            end = pos.get("ref_pic_list_modification_flag_l0")
            if h.slice_type == FE.P and h.num_ref_idx[0] >= 3 and h.frame_num >= 3 and end is not None \
                    and not h.field_pic and (rbsp[(end - 1) >> 3] >> (7 - ((end - 1) & 7))) & 1 == 0:
                bits = "".join(format(b, "08b") for b in rbsp)
                # the header's last syntax element: parse_slice_header also consumes the
                # cabac_alignment_one_bits, which the splice re-pads itself
                hdr_end = max(pos.values())
                nb = bits[:end - 1] + "1" + _ue(0) + _ue(1) + _ue(3) + bits[end:hdr_end]
                nb += "1" * (-len(nb) % 8)                  # cabac_alignment_one_bit
                new = bytes(int(nb[i:i + 8], 2) for i in range(0, len(nb), 8)) + rbsp[(br.pos + 7) // 8:]
                out += nal[:sc + 1] + _escape(new)
                continue
        out += nal
    return bytes(out)


def _nal_spans(data):
    """(start, end, nal_unit_type): start at the start code (a 4-byte one's zero included)"""
    spans = []
    i = data.find(b"\x00\x00\x01")
    while i >= 0 and i + 3 < len(data):
        s = i - 1 if i > 0 and data[i - 1] == 0 else i
        j = data.find(b"\x00\x00\x01", i + 3)
        e = len(data) if j < 0 else (j - 1 if data[j - 1] == 0 else j)
        spans.append((s, e, data[i + 3] & 0x1F))
        i = j
    return spans


def encode(lencod, case, work):
    desc, n, kind, params, _cov = CASES[case]
    yuv = os.path.join(work, "src.yuv")
    source(kind, n, yuv)
    cfg = dict(BASE)
    # the JM tree in $H264_REFS_DIR carries a vector-quantisation research extension
    # (lencod/src/vq.c) that loads codebook files unless VQdim / VQcblen are 0; a pristine
    # JM rejects those keys, so they are set only when the extension is there
    if os.path.exists(os.path.join(os.path.dirname(os.path.dirname(lencod)), "lencod", "src", "vq.c")):
        cfg.update({"VQdim": 0, "VQcblen": 0})
    cfg.update(params)
    cfg.update({"InputFile": yuv, "FramesToBeEncoded": n, "OutputFile": os.path.join(work, "out.264"),
                "ReconFile": os.path.join(work, "rec.yuv"), "StatsFile": os.path.join(work, "stats.dat"),
                "TraceFile": os.path.join(work, "trace.txt"),
                "LeakyBucketParamFile": os.path.join(work, "leakybucketparam.cfg"),
                "LeakyBucketRateFile": os.path.join(work, "leakybucketrate.cfg")})
    cfgp = os.path.join(work, "enc.cfg")
    with open(cfgp, "w") as fo:
        for k, v in cfg.items():
            fo.write('%s = %s\n' % (k, '"%s"' % v if isinstance(v, str) else v))
    r = subprocess.run([lencod, "-d", cfgp], cwd=work, capture_output=True, text=True, errors="replace")
    out = os.path.join(work, "out.264")
    if r.returncode != 0 or not os.path.exists(out) or os.path.getsize(out) == 0:
        raise RuntimeError("lencod failed (%d): %s" % (r.returncode, (r.stdout + r.stderr)[-600:]))
    data = open(out, "rb").read()
    if case == "jmod":
        data = rewrite_modification(data)
    return data


def check(data, case, work):
    """the model vs ffmpeg, and the case's coverage; returns the counters"""
    dec = RR.Decoder()
    dec.feed(FE.decode_stream(data))
    frames = dec.output_frames()
    es = os.path.join(work, "chk.264")
    open(es, "wb").write(data)
    ours, ref = os.path.join(work, "m.yuv"), os.path.join(work, "f.yuv")
    RR.write_yuv(frames, ours)
    RR.ffmpeg_yuv(es, ref)
    mism, na, nb = RR.compare_yuv(ours, ref, W, H)
    if mism is not None or na != nb:
        raise RuntimeError("the model disagrees with ffmpeg: %s (model %d frames, ffmpeg %d)" % (mism, na, nb))
    need = CASES[case][4]
    cov = dict(dec.cov)
    cov.update({"out_" + k: v for k, v in dec.out_cnt.items()})       # the output process (P5d)
    short = {k: cov.get(k, 0) for k in need if cov.get(k, 0) < need[k]}
    if short:
        raise RuntimeError("the stream does not reach the case's path: %s (all counters: %s)" % (short, cov))
    if any(k.startswith("out_") for k in need):
        # the output ORDER: the spec's per-picture process and JM's (a stream reaching the
        # output paths must be ordered right, not only decoded right)
        import dpb_output_ref as DO
        r = DO.check(es)
        if not r["model_eq_spec"] or r["model_eq_jm"] is False:
            raise RuntimeError("the output order disagrees: %s" % r)
        cov["out_split"] = r["split"]
    return cov


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("case", nargs="?")
    ap.add_argument("--out")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--lencod", default=os.path.join(os.environ.get("H264_REFS_DIR", os.path.expanduser("~/h264-refs")),
                                                    "JM", "build_enc", "bin", "lencod.exe"))
    a = ap.parse_args(argv)
    if a.list or not a.case:
        for k, v in CASES.items():
            print("%-7s %s" % (k, v[0]))
        return 0
    if not os.path.exists(a.lencod):
        print("SKIP: no lencod at %s (tools/jm_build.sh --lencod)" % a.lencod)
        return 2
    with tempfile.TemporaryDirectory() as work:
        try:
            data = encode(a.lencod, a.case, work)
            cov = check(data, a.case, work)
        except RuntimeError as e:
            print("FAIL %s: %s" % (a.case, e))
            return 1
        stream = os.path.join(work, "fix.264")
        open(stream, "wb").write(data)
        if a.out:
            RG.main([stream, "--out", a.out])
            open(a.out + ".264", "wb").write(data)
    print("%s: %s -- %d bytes, the model BIT-EXACT vs ffmpeg; coverage %s" %
          (a.case, CASES[a.case][0], len(data), {k: cov.get(k, 0) for k in CASES[a.case][4]}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
