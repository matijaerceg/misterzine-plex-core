#!/usr/bin/env python3
"""The Verilator cosim's golden (bench/h264/run_cosim.sh): a window of an Annex-B stream
as the elementary stream the decoder is fed, and the model's decode-order pictures
(tools/h264_recon_ref.py) before and after deblocking -- the cosim scores the RTL against
them per macroblock and per picture. The model's display-order output of the same window
is compared with ffmpeg's decode first (the independent oracle: a window where the model
and ffmpeg disagree is reported and not scored).

    cosim_golden.py --es STREAM.264 --out STEM [--frames 300] [--fps 59.94] [--timing-only]

The window: the stream's first IDR picture (with the parameter sets before it), whole
access units, cut after `frames` frames (a field pair is one frame) -- the header parsers
count them, no CABAC. Its display time comes from the pic_timing SEI's pic_struct when the
stream carries it, else from --fps (a Moonlight stream carries no timing: 59.94).

Forked from UMD cc595c6 (docs/harvest.md), where the window was cut from a disc image's
main title; H264 Phase 1's tools/p1/es_golden.py was this Annex-B entry, folded in here at
the Phase 2 harvest.

Files:
  STEM.es     the Annex-B bytes
  STEM.pics   a header line "pictures macroblocks frames field_pictures play_us" (the
              window's display time from its pic_struct SEI, 0 if unknown), then per
              picture (decode order) "struct width_mbs height_mbs word_offset" (struct 0 F,
              1 T, 2 B; a field's own height)
  STEM.pre / STEM.post   the samples, per picture luma rows then Cb then Cr, raw bytes
              (8 samples = one little-endian DPB word, docs/h264_recon.md S2.2)
  STEM.out    P5d, the output process: per store emitted, in order, "picture step frame
              unpaired" -- the decode index of the store's first picture, the pictures
              opened when it is emitted, coded as a frame, a single field (the window's
              end included: the end-of-stream flush)
Exit: 0 written; 3 SKIP (no IDR, or no pictures); 4 REFUSED (the model refuses the
stream: a scoping decision, e.g. CAVLC or MBAFF); 5 the model disagrees with ffmpeg.
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile
from collections import Counter

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import h264_fe_ref as FE  # noqa: E402
import h264_recon_ref as RR  # noqa: E402
import h264_top_golden as TG  # noqa: E402
import recon_top_golden as RG  # noqa: E402


def nal_spans(data):
    """(start, end, nal_unit_type) per NAL unit, start at its start code (a 4-byte one's
    leading zero included), end at the next unit's start."""
    out = []
    i = data.find(b"\x00\x00\x01")
    while i >= 0 and i + 3 < len(data):
        s = i - 1 if i > 0 and data[i - 1] == 0 else i
        j = data.find(b"\x00\x00\x01", i + 3)
        e = len(data) if j < 0 else (j - 1 if data[j - 1] == 0 else j)
        out.append((s, e, data[i + 3] & 0x1F))
        i = j
    return out


def param_sets(data):
    """The SPS and PPS NAL units of `data`, in order, with their start codes."""
    return b"".join(data[s:e] for s, e, t in nal_spans(data) if t in (7, 8))


def from_idr(data, prefix=b""):
    """The data from the access unit of the first IDR picture, or None. A video EP entry
    is an I picture but not always an IDR (Family Guy's are recovery points): decoding
    from one starts with no reference state (the model refuses the frame_num gap), so the
    window starts at the next IDR. Its access unit need not repeat the parameter sets
    (Astro Boy's IDRs do not: they are sent once, at the start), so the SPS / PPS a player
    would already hold go right after its delimiter: `prefix` (the title start's) and then
    every one the data sent before the IDR -- later ones override, as in a decoder."""
    aud = None
    for s, e, t in nal_spans(data):
        if t == 9:
            aud = (s, e)
        elif t == 5:
            if aud is None:
                return prefix + param_sets(data[:s]) + data[s:]
            return data[aud[0]:aud[1]] + prefix + param_sets(data[:aud[0]]) + data[aud[1]:]
    return None


def trim_tail(data):
    """Drop the non-VCL NAL units after the last slice (the next access unit's delimiter
    and SEI, which the cut leaves behind: an access unit with no picture)."""
    last_slice = -1
    i = data.find(b"\x00\x00\x01")
    while i >= 0 and i + 3 < len(data):
        if data[i + 3] & 0x1F in (1, 5):
            last_slice = i
        i = data.find(b"\x00\x00\x01", i + 3)
    if last_slice < 0:
        return data
    j = data.find(b"\x00\x00\x01", last_slice + 3)
    if j < 0:
        return data
    while j > last_slice + 3 and data[j - 1] == 0:
        j -= 1
    return data[:j]


def count_pictures(data, frames):
    """How many pictures (decode order) make up the first `frames` frames, and how many
    of them are fields. Header parsing only."""
    sps_map, pps_map = {}, {}
    n_pic, n_fields, n_frames2 = 0, 0, 0       # n_frames2 in half frames
    for ref_idc, ntype, rbsp in FE.nal_units(data):
        rec = []
        if ntype == 7:
            s = FE.parse_sps(rbsp, rec)
            sps_map[s.id] = s
        elif ntype == 8:
            p = FE.parse_pps(rbsp, sps_map, rec)
            pps_map[p.id] = p
        elif ntype in (1, 5):
            h = FE.parse_slice_header(FE.BitReader(rbsp), ntype, ref_idc, sps_map, pps_map, rec)
            if h.first_mb != 0:
                continue
            if n_frames2 >= 2 * frames:
                break
            n_pic += 1
            if h.field_pic:
                n_fields += 1
                n_frames2 += 1
            else:
                n_frames2 += 2
    return n_pic, n_fields


# Table E-6: clock ticks a picture is displayed for, by pic_struct (a tick is
# num_units_in_tick / time_scale: 1/59.94 s on the 4004 / 240000 streams, one field)
TICKS = {0: 2, 1: 1, 2: 1, 3: 2, 4: 2, 5: 3, 6: 3, 7: 4, 8: 6}


TRACE_RE = re.compile(r"\]\s+\d+\s+([A-Za-z0-9_]+)(?:\[[^\]]*\])*\s+[01]+ = (-?\d+)\s*$")
TIMING = ("num_units_in_tick", "time_scale", "pic_struct")


def trace_timing(es):
    """ffmpeg trace_headers over an Annex-B ES -> ({field: Counter} for the timing fields,
    pictures). UMD's census trace, cut to what the window's display time needs."""
    with tempfile.NamedTemporaryFile(suffix=".h264") as t:
        t.write(es)
        t.flush()
        r = subprocess.run(["ffmpeg", "-v", "trace", "-nostdin", "-f", "h264", "-i", t.name,
                            "-c", "copy", "-bsf:v", "trace_headers", "-f", "null", "-"],
                           capture_output=True, text=True, errors="replace")
    h = {k: Counter() for k in TIMING}
    pics = 0
    for line in r.stderr.splitlines():
        if "trace_headers" not in line:
            continue
        m = TRACE_RE.search(line)
        if not m:
            continue
        k, v = m.group(1), int(m.group(2))
        if k in h:
            h[k][v] += 1
        if k == "first_mb_in_slice":
            pics += v == 0
    return h, pics


def display_seconds(data, n_frames=0):
    """How long the window plays: the pic_timing SEI's pic_struct of every access unit
    (ffmpeg's trace_headers), in the VUI's ticks. The decoder is in real time on the
    window when it decodes it in less. (seconds, SEI count, pictures). With VUI timing but
    no pic_timing SEI (x264's default) a frame is two ticks (Table E-6's frame, E.2.1's
    DeltaTfiDivisor): 2 nuit / ts a frame -- n_frames of them (2026-10-02: the 720p24 / 30
    proxies were scored against 59.94 before)."""
    h, pics = trace_timing(data)
    ps = h["pic_struct"]
    if not h["num_units_in_tick"] or not h["time_scale"]:
        return None, 0, pics
    nuit = h["num_units_in_tick"].most_common(1)[0][0]
    ts = h["time_scale"].most_common(1)[0][0]
    ticks = sum(TICKS.get(k, 2) * c for k, c in ps.items())
    if not ps and n_frames:
        ticks = 2 * n_frames
    return ticks * nuit / float(ts), sum(ps.values()), pics


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--es", required=True, help="an Annex-B stream")
    ap.add_argument("--out", required=True)
    ap.add_argument("--frames", type=int, default=300)
    ap.add_argument("--fps", type=float, default=60000 / 1001.0,
                    help="frames/s when the stream carries no pic_timing SEI (default 59.94)")
    ap.add_argument("--timing-only", action="store_true",
                    help="cut the window and print its display time; no model, no files")
    a = ap.parse_args(argv)

    try:
        data = from_idr(open(a.es, "rb").read())
        if data is None:
            print("SKIP: no IDR picture in the stream")
            return 3
        n_pic, n_fields = count_pictures(data, a.frames)
        if n_pic == 0:
            print("SKIP: no pictures in the window")
            return 3
        data = trim_tail(RG.truncate_es(data, n_pic - 1))   # exactly n_pic pictures
        secs, n_sei, _p = display_seconds(data, n_pic - n_fields // 2)
        if not secs:                  # no VUI timing / pic_timing SEI: the stated rate
            secs = (n_pic - n_fields // 2) / a.fps
        if a.timing_only:
            print("TIMING: %d pictures (%d fields), %d frames, %d pic_timing SEI, plays %.3f s: "
                  "%.3f frames/s needed" % (n_pic, n_fields, a.frames, n_sei, secs, a.frames / secs))
            return 0
        rec = FE.decode_stream(data)
    except (FE.Refused, RR.ReconError) as e:
        print("REFUSED: %s" % e)
        return 4
    except Exception as e:  # a front-end refusal raised under another name
        if type(e).__name__ in ("Refused", "Unsupported"):
            print("REFUSED: %s" % e)
            return 4
        raise

    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    with open(a.out + ".es", "wb") as f:
        f.write(data)
    pics = []
    fpre = open(a.out + ".pre", "wb")
    fpost = open(a.out + ".post", "wb")
    off = [0]

    frame_of = []

    def hook(pic, pre):
        frame_of.append(pic.frame.id)
        pics.append(({"F": 0, "T": 1, "B": 2}[pic.struct], pic.w, pic.hgt, off[0]))
        for planes, f in ((pre, fpre), ([pic.Y, pic.Cb, pic.Cr], fpost)):
            for pl in planes:
                f.write(np.ascontiguousarray(pl.astype(np.uint8)).tobytes())
        off[0] += (16 * pic.hgt * 2 * pic.w) + 2 * (8 * pic.hgt * pic.w)
    dec = RR.Decoder(on_picture=hook)
    try:
        dec.feed(rec)
    except RR.ReconError as e:
        print("REFUSED: %s" % e)
        return 4
    dec.flush_output()                    # the end of stream: the last picture, then every one waiting
    fpre.close()
    fpost.close()
    n_mbs = sum(1 for w in TG.words(rec) if w[0] == 1)
    frames = dec.output_frames()

    # the independent oracle: the model's display-order window against ffmpeg's decode
    with tempfile.TemporaryDirectory() as td:
        es = os.path.join(td, "w.264")
        open(es, "wb").write(data)
        ours, ref = os.path.join(td, "m.yuv"), os.path.join(td, "f.yuv")
        RR.write_yuv(frames, ours)
        RR.ffmpeg_yuv(es, ref)
        s = frames[0].sps
        l, r, t, b = s.crop
        cu_y = 2 * (2 - s.frame_mbs_only)
        w, h = s.width - 2 * (l + r), s.height - cu_y * (t + b)
        mism, na, nb = RR.compare_yuv(ours, ref, w, h)
    if mism is not None or na != nb:
        print("MODEL-MISMATCH vs ffmpeg: %s (model %d frames, ffmpeg %d)" % (mism, na, nb))
        return 5

    with open(a.out + ".pics", "w") as f:
        f.write("%d %d %d %d %d\n" % (len(pics), n_mbs, len(frames), n_fields,
                                     int(round((secs or 0) * 1e6))))
        for p in pics:
            f.write("%d %d %d %d\n" % p)
    with open(a.out + ".out", "w") as f:
        f.write("%d\n" % len(dec.emitted))
        for fr, n, _how in dec.emitted:
            unpaired = int(not fr.coded_as_frame and fr.decoded != [1, 1])
            f.write("%d %d %d %d\n" % (frame_of.index(fr.id), n, fr.coded_as_frame, unpaired))
    print("%s: %s from its first IDR, %d bytes, %d pictures (%d fields), %d frames, %d macroblocks, "
          "plays %.3f s; the model BIT-EXACT vs ffmpeg" % (a.out, os.path.basename(a.es), len(data), len(pics),
                                                        n_fields, len(frames), n_mbs, secs or 0))
    return 0


if __name__ == "__main__":
    sys.exit(main())
