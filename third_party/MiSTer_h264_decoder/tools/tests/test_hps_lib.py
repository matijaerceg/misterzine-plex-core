#!/usr/bin/env python3
"""The client library (hps/): its host build, its unit tests against a fake core
(hps/tests/test_ring.c), the bytes it wrote parsed by tools/ring_model.py's consumer (an
oracle written from docs/architecture.md, sharing nothing with the C), and the reference
feeder's access-unit splitter against ffprobe's H.264 parser on generated streams.
"""
import os
import shutil
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.dirname(HERE)
ROOT = os.path.dirname(TOOLS)
sys.path.insert(0, TOOLS)
sys.path.insert(0, HERE)
import ring_model as M  # noqa: E402
from score import Score  # noqa: E402

s = Score("test_hps_lib")
HPS = os.path.join(ROOT, "hps")
r = subprocess.run(["make", "-s", "-C", HPS, "all", "build/host/test_ring"], capture_output=True, text=True)
s.check("hps host build", r.returncode, 0)
if r.returncode:
    print(r.stdout + r.stderr)
    s.finish()

tmp = tempfile.mkdtemp()
stem = os.path.join(tmp, "t")
# run from hps/, as `make test` does: test_ring reads ../h264/dec/h264_pkg.sv (the refusal names' arm)
r = subprocess.run([os.path.join(HPS, "build/host/test_ring"), stem], capture_output=True, text=True, cwd=HPS)
print("\n".join("  [test_ring] " + ln.strip() for ln in r.stdout.splitlines() if "FAIL" in ln))
s.check("test_ring (the fake core's checks)", "test_ring: ALL GREEN" in r.stdout and r.returncode == 0, True)

# ---- the bytes the fake core consumed, through the independent consumer ----
raw = open(stem + ".stream", "rb").read()
start = struct.unpack("<I", raw[:4])[0]
data = raw[4:]
stream = {(start + i) & 0xFFFFFFFF: b for i, b in enumerate(data)}
buf = open(stem + ".buf", "rb").read()
aus = [tuple(int(x) for x in ln.split()) for ln in open(stem + ".aus")]
c = M.consume(stream, start, (start + len(data)) & 0xFFFFFFFF, 64 * 1024)
s.check("the consumer finds no error in what the library wrote", (c.err, M.E and c.err_pos), (0, 0))
s.check("every access unit", c.n_au, len(aus))
s.check("PADs at the ring's ends", c.n_pad > 5, True)
got, cur = [], None
resets = eos = 0
for it in c.items:
    if it[0] == "byte":
        if cur is None:
            cur = [bytearray(), it[2], it[3]]
        cur[0].append(it[1])
        if it[4]:
            got.append(cur)
            cur = None
    elif it[0] == "reset":
        resets += 1
    elif it[0] == "eos":
        eos += 1
want = [buf[off:off + ln] for ln, off, _, _, _ in aus]
s.check("payloads byte-exact", [bytes(g[0]) for g in got] == want, True)
s.check("PTS marks where PTS_VALID", [(g[1], g[2]) for g in got],
        [((1, pts) if pts >= 0 else (0, 0)) for _, _, _, pts, _ in aus])
s.check("a reset at the session and at the DISCONTINUITY after END_OF_STREAM", resets, 2)
s.check("one END_OF_STREAM", eos, 1)
mism, first = 0, None
for ln, off, flags, pts, _ in aus:                    # each stream's first AU sets the mode
    ll = 1 if flags & M.F["LOW_LATENCY"] else 0
    if first is None or flags & M.F["DISCONTINUITY"]:
        first = ll
    elif ll != first:
        mism += 1
s.check("LOW_LATENCY disagreements counted from each stream's first AU", c.ll_mismatch, mism)
s.check("... and there are some (the arm can see a miscount)", mism > 0, True)
# (0.16) the colour code in each AU's header word 1 [35:33], as h264ring_set_colour() set it: the consumer
# takes each stream's first and counts the later disagreements
cm, cfirst = 0, None
for ln, off, flags, pts, col in aus:
    if cfirst is None or flags & M.F["DISCONTINUITY"]:
        cfirst, cm = col, 0
    elif col != cfirst:
        cm += 1
s.check("(0.16) the colour from each stream's first AU (h264ring_set_colour)", c.colour, cfirst)
s.check("(0.16) ... later disagreements counted", c.colour_mismatch, cm)
s.check("(0.16) ... and there are some, and the stream's colour is not 0 (the arms can see a miscount)", (cm > 0, cfirst != 0), (True, True))


# ---- (0.15) the PICTURE records and the store copies, against docs/architecture.md "Pictures from
# the program" (the descriptor's fields, the coded size, the crop, the SAR and timing, the store's
# layout, the range and 4:2:2 conversions, the edges): written here from the text, not the C ----
def gcd(a, b):
    while b:
        a, b = b, a % b
    return a


def want_desc(width, height, st, ps, sw, sh, num, den, store):
    w = -(-width // 16)
    hf = 2 * -(-height // 32) if st else -(-height // 16)
    d = dict(store=store, w=w, hf=hf, st=st, ps=ps if ps >= 0 else 0, psv=1 if ps >= 0 else 0, idc=0, sarw=0, sarh=0,
             tv=0, nuit=0, ts=0, cl=0, cr=(16 * w - width) // 2, ct=0, cb=(16 * hf - height) // 2, rsv_bad=False)
    if sw and sh:
        g = gcd(sw, sh)
        d.update(idc=255, sarw=sw // g, sarh=sh // g)
    if num and den:
        g = gcd(2 * num, den)
        d.update(tv=1, nuit=den // g, ts=2 * num // g)
    return d


lines = [ln.split() for ln in open(stem + ".pics")]
bad, stores = [], []
for k, f in enumerate(lines):
    width, height, st, ps, sw, sh, num, den, flags, pts, rtype = [int(x) for x in f[:11]]
    payload = b"".join(int(x).to_bytes(8, "little") for x in f[11:15])
    got = M.pic_unpack(payload)
    want = want_desc(width, height, st, ps, sw, sh, num, den, got["store"])
    if got != want or rtype != M.T["PICTURE"] or M.pic_check(got) is not None:
        bad.append((k, got, want))
    stores.append(got["store"])
s.check("(0.15) twenty PICTURE records written", len(lines), 20)
s.check("(0.15) each descriptor as the interface defines it (size, crop, structure, pic_struct, SAR, timing)",
        bad[:1], [])
s.check("(0.15) the stores taken in turn, 0-19", stores, list(range(20)))
s.check("(0.16) each PICTURE's colour code in header word 1 [35:33], every code", [int(f[15]) for f in lines],
        [k % 7 for k in range(20)])
s.check("(0.15) PTS_VALID where a PTS was given, GRAPHICS where asked",
        [(int(f[8]) & M.F["PTS_VALID"] != 0, int(f[8]) & M.F["GRAPHICS"] != 0) for f in lines],
        [(k != 7, k == 2) for k in range(20)])


def want_store(width, height, st, fmt, strides, planes):
    """the store image (Y, Cb, Cr) the text says a source picture becomes; (0.16) fmt's [15:8] the colour code:
    a full-range code (2, 4, 6) keeps a full-range source as it is"""
    pair = st != 0
    colour, fmt = fmt >> 8, fmt & 0xFF
    full = fmt in (1, 3) and colour not in (2, 4, 6)
    c422 = fmt in (2, 3)
    w = -(-width // 16)
    hf = 2 * -(-height // 32) if pair else -(-height // 16)
    ly = [16 + (219 * v + 127) // 255 for v in range(256)]
    lc = [16 + (224 * v + 127) // 255 for v in range(256)]

    def last(y, n):                      # a row past the picture: the last of its own field (a pair) or the last
        if y < n:
            return y
        if not pair or n < 2:
            return n - 1
        return n - 1 if (n - 1) % 2 == y % 2 else n - 2

    def plane(i, ow, oh, sw_, rows, lut):
        out = bytearray()
        for y in range(oh):
            rs = rows(y)
            for x in range(ow):
                sx = min(x, sw_ - 1)
                vals = [planes[i][r * strides[i] + sx] for r in rs]
                v = vals[0] if len(vals) == 1 else (vals[0] + vals[1] + 1) >> 1
                out.append(lut[v] if full else v)
        return out
    out = plane(0, 16 * w, 16 * hf, width, lambda y: [last(y, height)], ly)
    cw = -(-width // 2)
    for i in (1, 2):
        if c422:
            def rows(y):
                r0 = 4 * (y >> 1) + (y & 1) if pair else 2 * y
                r1 = r0 + 2 if pair else r0 + 1
                return [last(r0, height), last(r1, height)]
        else:
            ch = -(-height // 2)

            def rows(y, ch=ch):
                return [last(y, ch)]
        out += plane(i, 8 * w, 8 * hf, cw, rows, lc)
    return bytes(out)


cbad = []
for n in range(10):
    raw = open("%s.copy%d" % (stem, n), "rb").read()
    hdr = struct.unpack("<8I", raw[:32])
    width, height, st, fmt, s0, s1, s2, nbytes = hdr
    planes = [raw[32 + 4096 * i:32 + 4096 * (i + 1)] for i in range(3)]
    got = raw[32 + 3 * 4096:32 + 3 * 4096 + nbytes]
    want = want_store(width, height, st, fmt, (s0, s1, s2), planes)
    if got != want:
        first = next(i for i in range(min(len(got), len(want))) if got[i] != want[i]) if len(got) == len(want) else -1
        cbad.append((n, width, height, st, fmt, first))
s.check("(0.15) the store copies: 4:2:0 / 4:2:2, limited / full range, frames / pairs, the edges; (0.16) full kept", cbad, [])
shutil.rmtree(tmp)

# ---- the feeder's access-unit splitter vs ffprobe ----
if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
    print("SKIP: ffmpeg / ffprobe not installed: the splitter arm is not run")
else:
    tmp = tempfile.mkdtemp()
    cases = [
        ("B frames, 3 slices", "bframes=2:slices=3:keyint=30"),
        ("access unit delimiters, SEI", "bframes=3:aud=1:keyint=20"),
        ("P only, one slice (Sunshine-shaped)", "bframes=0:keyint=600:ref=1"),
    ]
    for label, params in cases:
        f = os.path.join(tmp, "s.264")
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=352x240:rate=30",
                        "-frames:v", "60", "-c:v", "libx264", "-profile:v", "main", "-x264-params", params, f],
                       check=True)
        mine = subprocess.run([os.path.join(HPS, "build/host/h264play"), "--list", f],
                              capture_output=True, text=True).stdout.split("\n")
        mine = [tuple(int(x) for x in ln.split()) for ln in mine if ln.strip()]
        ref = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "packet=pos,size", "-of", "csv=p=0", f],
                             capture_output=True, text=True).stdout.split("\n")
        ref = [tuple(int(x) for x in ln.split(",")[::-1]) for ln in ref if ln.strip()]
        s.check("splitter == ffprobe: " + label, mine, ref)
    shutil.rmtree(tmp)
s.finish()
