#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""ts_skew.py -- re-interleave an MPEG-TS so its audio sits AHEAD of (or after) its video in the
file, the timestamps untouched: the host tests' fixture for a transcode whose audio the server's
muxer put seconds ahead of its video (docs/jellyfin.md S12, 2026-10-09).

  ts_skew.py IN.ts OUT.ts --lead S [--audio-from S]

FFmpeg's muxers interleave by DTS and cannot be told otherwise, so this moves whole PES units of
the 188-byte packets: a video unit stays at its DTS; an audio unit whose PTS is T moves to the
video's position T - lead (audio `lead` seconds ahead), but never before the video's position
first video DTS + audio_from (no audio at all in the stream's first seconds: past a probe's
reach). Each PID keeps its own order (the continuity counters stay right), the PSI (PAT / PMT /
SDT) its place behind the packet before it; ties go to the video. Prints what it made: the
largest lead of an audio packet over the newest video before it, and the video's position at the
first audio packet."""
import argparse
import sys

TS = 188


def pes_times(pkt):
    """(pts, dts) in 90 kHz of a PES that starts in this packet, or None"""
    afc = (pkt[3] >> 4) & 3
    off = 4
    if afc & 2:
        off += 1 + pkt[4]
    if not afc & 1 or off + 14 > TS:
        return None
    p = pkt[off:]
    if p[0:3] != b"\x00\x00\x01":
        return None
    flags = p[7]

    def ts(b):
        return ((b[0] >> 1) & 7) << 30 | b[1] << 22 | (b[2] >> 1) << 15 | b[3] << 7 | b[4] >> 1
    pts = ts(p[9:14]) if flags & 0x80 else None
    dts = ts(p[14:19]) if flags & 0x40 else pts
    return pts, dts


def skew(packets):
    """a file's own interleave, from `ffprobe -show_entries packet=stream_index,pts,pos -of csv=p=0`
    (stream 0 the video, 90 kHz): the most an audio packet is ahead of the newest video packet
    before it in the file, and the video's time (from its first) at the first audio packet, in
    seconds -- the host tests check a fixture still holds what it was made for"""
    rows = []
    for ln in open(packets):
        f = ln.strip().split(",")
        if len(f) >= 3 and f[1] not in ("", "N/A") and f[2] not in ("", "N/A"):
            rows.append((int(f[2]), int(f[0]), int(f[1])))
    rows.sort()
    vmax, v0, lead, first_a = None, None, 0.0, None
    for _, si, pts in rows:
        if si == 0:
            v0 = pts if v0 is None else v0
            vmax = pts if vmax is None else max(vmax, pts)
        elif vmax is not None:
            lead = max(lead, (pts - vmax) / 90000.0)
            if first_a is None:
                first_a = (vmax - v0) / 90000.0
    return lead, first_a


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("inp")
    ap.add_argument("out")
    ap.add_argument("--lead", type=float, required=True, help="seconds the audio comes ahead of its video")
    ap.add_argument("--audio-from", type=float, default=0.0, help="no audio before this much video")
    a = ap.parse_args()
    data = open(a.inp, "rb").read()
    if len(data) % TS or data[0] != 0x47:
        sys.exit("ts_skew: not a 188-byte TS")
    pkts = [data[i:i + TS] for i in range(0, len(data), TS)]
    # the elementary streams: PIDs whose units start with a PES start code; audio by its stream id
    kind = {}
    for p in pkts:
        pid = (p[1] & 0x1F) << 8 | p[2]
        if p[1] & 0x40 and pid not in kind:
            t = pes_times(p)
            afc = (p[3] >> 4) & 3
            off = 4 + (1 + p[4] if afc & 2 else 0)
            if t is not None:
                sid = p[off + 3]
                kind[pid] = "v" if 0xE0 <= sid <= 0xEF else "a" if (0xC0 <= sid <= 0xDF or sid == 0xBD) else "o"
    vids = [p for p in pkts if kind.get((p[1] & 0x1F) << 8 | p[2]) == "v" and p[1] & 0x40]
    if not vids or "a" not in kind.values():
        sys.exit("ts_skew: needs a video and an audio stream")
    v0 = pes_times(vids[0])[1]
    lead, start = int(a.lead * 90000), v0 + int(a.audio_from * 90000)
    keys = []
    cur = {}                                   # a PID's current unit's key
    last = (-1, 0, -1)
    for i, p in enumerate(pkts):
        pid = (p[1] & 0x1F) << 8 | p[2]
        k = kind.get(pid)
        if k in ("v", "a"):
            if p[1] & 0x40:
                pts, dts = pes_times(p)
                cur[pid] = (dts, 0) if k == "v" else (max(pts - lead, start), 1)
            if pid not in cur:                 # a unit's tail before its start: keep it first
                cur[pid] = (-1, 0)
            key = cur[pid] + (i,)
            last = key
        else:
            key = last[:2] + (last[2] + 0.5,)  # PSI: right behind the packet before it
        keys.append(key)
    order = sorted(range(len(pkts)), key=lambda i: keys[i])
    with open(a.out, "wb") as f:
        for i in order:
            f.write(pkts[i])
    # what it made
    vmax, worst, first_a = None, 0.0, None
    for i in order:
        p = pkts[i]
        pid = (p[1] & 0x1F) << 8 | p[2]
        if not p[1] & 0x40 or kind.get(pid) not in ("v", "a"):
            continue
        pts, _ = pes_times(p)
        if kind[pid] == "v":
            vmax = pts if vmax is None else max(vmax, pts)
        else:
            if first_a is None:
                first_a = (vmax - v0) / 90000 if vmax is not None else 0.0
            if vmax is not None:
                worst = max(worst, (pts - vmax) / 90000)
    print("ts_skew: %s -> %s: audio up to %.2f s ahead of the video before it; the first audio after %.2f s of video"
          % (a.inp, a.out, worst, first_a))


if __name__ == "__main__":
    main()
