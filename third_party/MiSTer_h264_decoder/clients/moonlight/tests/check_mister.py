#!/usr/bin/env python3
"""check_mister.py STEM STREAM CAVLC_REWRITTEN -- score what test_mister's fake core consumed, through
tools/ring_model.py's consumer (written from docs/architecture.md, not from the library or
the backend): the records must be what the design says a Moonlight session writes.

  STEM.s1.stream   session 1's consumed bytes (u32 start index, then the bytes)
  STEM.s1.dus      the decode units submitted in S1: offset and length in STREAM
  STEM.s1.pcm      the reference decode of the audio packets the backend wrote
  STEM.s2.stream   session 2's (after the OSD Reset); STEM.s2.first its expected first AU; then
                   S7's CAVLC stream, which must arrive as CAVLC_REWRITTEN (hps' cavlc2cabac on it)
  STEM.counters    the backend's own counts
Prints one PASS / FAIL line per check and "check_mister: ALL GREEN".
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "..", "tools"))
import ring_model as M  # noqa: E402

RING = 1 << 20                     # test_mister.c's RING
M32 = 0xFFFFFFFF
fails = 0


def check(label, ok):
    global fails
    print("  %s %s" % ("PASS" if ok else "FAIL", label))
    if not ok:
        fails += 1


def load(stem, k):
    raw = open("%s.s%d.stream" % (stem, k), "rb").read()
    start = struct.unpack("<I", raw[:4])[0]
    body = raw[4:]
    stream = {(start + i) & M32: b for i, b in enumerate(body)}
    return M.consume(stream, start, (start + len(body)) & M32, RING)


def records(c):
    """the access units' bytes, the PTS marks, and the record order ('v' / 'a')"""
    aus, order, cur, marks = [], [], None, 0
    for it in c.items:
        if it[0] == "byte":
            if cur is None:
                cur = bytearray()
                order.append("v")
            cur.append(it[1])
            marks += it[2]
            if it[4]:
                aus.append(bytes(cur))
                cur = None
        elif it[0] == "audio":
            order.append("a")
    return aus, order, marks


def main():
    stem, streamf, cavlcf = sys.argv[1], sys.argv[2], sys.argv[3]
    data = open(streamf, "rb").read()
    counters = dict((ln.split()[0], int(ln.split()[1])) for ln in open(stem + ".counters"))

    c1 = load(stem, 1)
    dus = [tuple(int(x) for x in ln.split()) for ln in open(stem + ".s1.dus")]
    aus, order, marks = records(c1)
    check("S1: the consumer finds no error in what the backend wrote", (c1.err, c1.err_pos) == (0, 0))
    check("S1: one VIDEO_AU per decode unit", c1.n_au == len(dus) == counters["au"])
    check("S1: every access unit's bytes, in order", aus == [data[o:o + n] for o, n in dus])
    check("S1: LOW_LATENCY and GRAPHICS on every access unit",
          (c1.ll, c1.gfx, c1.ll_mismatch, c1.gfx_mismatch) == (1, 1, 0, 0))
    check("S1: no PTS on any record", marks == 0 and all(it[3] == 0 for it in c1.items if it[0] == "audio"))
    check("S1: no audio before the session's first access unit", bool(order) and order[0] == "v")
    check("S1: every audio record 5 ms of whole frames (960 bytes)",
          c1.n_audio > 0 and all(len(a) == 960 for a in c1.audio))
    check("S1: the audio is the reference decode of the packets written, in order",
          b"".join(c1.audio) == open(stem + ".s1.pcm", "rb").read())
    check("S1: the consumer's audio records are the backend's count", c1.n_audio == counters["aud"])

    c2 = load(stem, 2)
    aus2, order2, _ = records(c2)
    check("S3: the new session's records are clean", (c2.err, c2.err_pos) == (0, 0))
    check("S3: the new session starts with the IDR", bool(order2) and order2[0] == "v" and
          bool(aus2) and aus2[0] == open(stem + ".s2.first", "rb").read())
    want = open(cavlcf, "rb").read()
    check("S7: the CAVLC stream's units written as their CABAC rewrite, in order",
          len(aus2) > 1 and b"".join(aus2[1:]) == want)

    print("check_mister: %s" % ("FAILURES" if fails else "ALL GREEN"))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
