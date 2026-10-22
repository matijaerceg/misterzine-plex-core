#!/usr/bin/env python3
"""ovl_ref.py -- the overlay plane's model (Phase 6b, interface 0.9), written from
docs/architecture.md "The overlay plane (Phase 6b, interface 0.9)" -- the descriptor, its
checks, the pixel formats and the composite -- NOT from h264/ovl_plane.sv. The rounded
division is plain round(x / 255) here, not the RTL's shift-and-add, so a wrong trick shows.

For one scenario it writes, to bench/h264/fixtures/gen/ (gitignored):
  ovl_<arm>.mem.hex   the DDR3 window the bench's ddr_model holds, sparse ($readmemh @):
                      the framebuffer's region at the window's base (word FB_BYTE / 8), the
                      control block's words 72-79 after it (the bench translates the address)
  ovl_<arm>.stim.hex  a header (refreshes, il, pal, flags, and (0.10) the raster: nat, w, h, l,
                      nt, last -- nat 0 the fitted 720 raster) then, per refresh k, the words the
                      bench applies at its start: the eight descriptor words, sess, at_en
  ovl_<arm>.exp.hex   per refresh, every frame line of the raster (480 / 576, or the native raster's
                      h) x its width (720, or the native w) pixels:
                      the overlay's premultiplied {r, g, b, a} (after the anti-twitter) --
                      at 480i the bench scores the lines its field shows
  ovl_<arm>.stat.hex  per refresh, the status the bench checks in its vertical blank: gen,
                      {clip, at, err, state}, torn, and the canvas lines fetched so far
                      (cumulative) twice: refresh 0's first line even, then odd (480i)

Timing (the architecture's rule): what the bench writes at refresh k's start is read at
refresh k's vertical blank and shown from refresh k + 1; sess and at_en set at k's start are
taken at k + 1's first line. Refresh 0 shows nothing.

    ovl_ref.py <arm> [--seed N]     one scenario
    ovl_ref.py --list               the arms
"""
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import ring_layout as L  # noqa: E402  (the published constants: the region, the words)
import raster_geom_ref as G  # noqa: E402  (0.10: a native raster's geometry, for the n* arms)

GEN = os.path.join(ROOT, "bench", "h264", "fixtures", "gen")
FB = L.FB_BYTE
FB_END = L.FB_BYTE + L.FB_SIZE
FMT = {n: v for n, v, _ in L.OVL_FORMATS}
BPP = {v: b for _, v, b in L.OVL_FORMATS}
ERR = {n: v for n, v, _ in L.OVL_ERRORS}
STATE = {n: v for n, v in L.OVL_STATES}


def rdiv255(x):
    """x / 255 rounded (no ties: 2x / 255 is never odd)."""
    return (2 * x + 255) // 510


def widen5(c):
    return (c << 3) | (c >> 2)


def unpack(fmt, v):
    """-> (r, g, b, a), 8 bits each, straight alpha (the architecture's table)."""
    if fmt == FMT["1555"]:
        return widen5((v >> 10) & 31), widen5((v >> 5) & 31), widen5(v & 31), 255 if v & 0x8000 else 0
    if fmt == FMT["4444"]:
        return 17 * ((v >> 8) & 15), 17 * ((v >> 4) & 15), 17 * (v & 15), 17 * ((v >> 12) & 15)
    return (v >> 16) & 255, (v >> 8) & 255, v & 255, (v >> 24) & 255


def premul(p):
    r, g, b, a = p
    return (rdiv255(r * a), rdiv255(g * a), rdiv255(b * a), a)


class Mem:
    """The bytes the program wrote (sparse)."""

    def __init__(self):
        self.b = {}

    def put(self, addr, value, n):
        for i in range(n):
            self.b[addr + i] = (value >> (8 * i)) & 255

    def get(self, addr, n):
        return sum(self.b.get(addr + i, 0) << (8 * i) for i in range(n))


def desc_words(gen, enable=1, fmt="1555", base=FB, w=720, h=480, stride=None, band=None,
               ctl_extra=0, rsvd=0, gen_hi=None, fmt_code=None):
    f = FMT[fmt] if fmt_code is None else fmt_code
    if stride is None:
        stride = w * (4 if f == FMT["8888"] else 2)
        stride = (stride + 7) & ~7
    if band is None:
        band = (0, h - 1)
    ctl = (enable & 1) | (f << 1) | ctl_extra
    return [gen & 0xFFFFFFFF, ctl & 0xFFFFFFFF, base & 0xFFFFFFFF, ((h & 0xFFFF) << 16) | (w & 0xFFFF),
            stride & 0xFFFFFFFF, ((band[1] & 0xFFFF) << 16) | (band[0] & 0xFFFF), rsvd & 0xFFFFFFFF,
            (gen if gen_hi is None else gen_hi) & 0xFFFFFFFF]


def check(d):
    """A consistent descriptor with ENABLE set -> (err, params). The architecture's order."""
    ctl, base, size, stride, band, rsvd = d[1], d[2], d[3], d[4], d[5], d[6]
    fmt = (ctl >> 1) & 3
    w, h = size & 0xFFFF, size >> 16
    s = stride & 0xFFFF
    bf, bl = band & 0xFFFF, band >> 16
    if (ctl & ~7) or rsvd or fmt == 3:
        return ERR["CTL"], None
    if not (1 <= w <= L.OVL_MAX_W and 1 <= h <= L.OVL_MAX_H):
        return ERR["SIZE"], None
    bpp = BPP[fmt]
    if s % 8 or s < w * bpp or (stride >> 16):
        return ERR["STRIDE"], None
    if base % 8:
        return ERR["ALIGN"], None
    if bf > bl or bl >= h:
        return ERR["BAND"], None
    if base < FB or base + (h - 1) * s + w * bpp > FB_END:
        return ERR["RANGE"], None
    return ERR["NONE"], dict(fmt=fmt, base=base, w=w, h=h, s=s, bf=bf, bl=bl)


# ------------------------------------------------------------------------ the scenarios
def page(mem, rng, fmt, base, w, h, stride, style="random"):
    """Draw a page: random pixels, alpha weighted to the edges (0 and full) and between."""
    bpp = BPP[FMT[fmt]]
    for y in range(h):
        for x in range(w):
            if style == "random":
                v = rng.getrandbits(8 * bpp)
                k = rng.random()
                if fmt == "1555":
                    pass                                  # the top bit random: half transparent
                elif fmt == "4444":
                    a = 0 if k < 0.3 else 15 if k < 0.6 else rng.randrange(16)
                    v = (v & 0x0FFF) | (a << 12)
                else:
                    a = 0 if k < 0.3 else 255 if k < 0.6 else rng.randrange(256)
                    v = (v & 0x00FFFFFF) | (a << 24)
                if x == 0:                               # column 0 opaque: a line's first dot is always seen
                    v |= {"1555": 0x8000, "4444": 0xF000, "8888": 0xFF000000}[fmt]
            else:                                        # "boxes": an opaque frame, a hole
                edge = x < 4 or y < 4 or x >= w - 4 or y >= h - 4
                v = {"1555": 0xFFFF if edge else 0, "4444": 0xF8C4 if edge else 0x0000,
                     "8888": 0xFF20C0F0 if edge else 0}[fmt]
            mem.put(base + y * stride + x * bpp, v, bpp)


def scenario(arm, seed):
    """-> dict(il, pal, refreshes: [(desc words, sess, at)], mem, flags)."""
    rng = random.Random(seed * 1000 + sum(map(ord, arm)))
    mem = Mem()
    R = []
    il = pal = 0
    flags = 0                                          # bit 0: the late arm (score lines whole-or-zero)
    geo = None                                         # (0.10) a native raster: (w, h, l, nt, last)
    P0, P1, P2 = FB, FB + 0x200000, FB + 0x400000        # three page addresses inside the region
    if arm == "p1555":                                   # full canvas, 480p; a page flip
        page(mem, rng, "1555", P0, 720, 480, 1440)
        page(mem, rng, "1555", P1, 720, 480, 1440)
        R = [(desc_words(1, base=P0), 1, 0), (desc_words(2, base=P1), 1, 0), (desc_words(2, base=P1), 1, 0)]
    elif arm == "p4444":                                 # 640x400 centred, padded stride, a band
        page(mem, rng, "4444", P0, 640, 400, 1296)
        R = [(desc_words(5, fmt="4444", base=P0, w=640, h=400, stride=1296, band=(100, 299)), 1, 1),
             (desc_words(5, fmt="4444", base=P0, w=640, h=400, stride=1296, band=(100, 299)), 1, 1)]
    elif arm == "p8888clip":                             # 720x576 on the 480-line raster (clipped)
        page(mem, rng, "8888", P0, 720, 576, 2880)
        R = [(desc_words(9, fmt="8888", base=P0, w=720, h=576), 1, 0),
             (desc_words(9, fmt="8888", base=P0, w=720, h=576), 1, 0)]
    elif arm == "i1555at":                               # 480i, anti-twitter on, the whole canvas: the
        il = 1                                           # odd field's first line needs canvas line 0 (its
        page(mem, rng, "1555", P0, 720, 480, 1440)       # c - 1), the even field's last line 479 (c + 1)
        d = desc_words(3, base=P0)
        R = [(d, 1, 1)] + [(d, 1, 1)] * 4
    elif arm == "i4444odd":                              # 480i unfiltered, odd width / height / offset
        il = 1
        page(mem, rng, "4444", P1, 333, 211, 672)
        d = desc_words(4, fmt="4444", base=P1, w=333, h=211, stride=672)
        R = [(d, 1, 0)] + [(d, 1, 0)] * 3
    elif arm == "i8888pal":                              # 576i with the filter, 8888, a small band
        il = pal = 1
        page(mem, rng, "8888", P2, 720, 576, 2880)
        d = desc_words(6, fmt="8888", base=P2, w=720, h=576, band=(200, 263))
        R = [(d, 1, 1)] + [(d, 1, 1)] * 3
    elif arm == "inarrow":                               # 480i filtered, canvases 1 and 3 pixels wide: the
        il = 1                                           # ops' accumulator words a clock or two apart
        page(mem, rng, "4444", P0, 1, 24, 8)
        page(mem, rng, "4444", P1, 3, 20, 8)
        a = desc_words(40, fmt="4444", base=P0, w=1, h=24, stride=8)
        b = desc_words(41, fmt="4444", base=P1, w=3, h=20, stride=8)
        R = [(a, 1, 1), (a, 1, 1), (b, 1, 1), (b, 1, 1), (b, 1, 1)]
    elif arm == "desc":                                  # the checks, torn, off, the session
        page(mem, rng, "1555", P0, 64, 32, 128, style="boxes")
        ok = dict(base=P0, w=64, h=32, stride=128)
        top = FB_END - 31 * 128 - 64 * 2                 # the last page that fits exactly
        page(mem, rng, "1555", top, 64, 32, 128)
        R = [(desc_words(10, **ok), 1, 0),                               # accepted
             (desc_words(11, ctl_extra=8, **ok), 1, 0),                  # CTL: a reserved bit
             (desc_words(12, fmt_code=3, **ok), 1, 0),                   # CTL: FORMAT 3
             (desc_words(13, **dict(ok, w=L.OVL_MAX_W + 1)), 1, 0),      # SIZE (0.10: 1,025; 0.9's 721)
             (desc_words(14, **dict(ok, stride=120)), 1, 0),             # STRIDE: below w x 2
             (desc_words(15, **dict(ok, base=P0 + 4)), 1, 0),            # ALIGN
             (desc_words(16, band=(10, 32), **ok), 1, 0),                # BAND: last = height
             (desc_words(17, **dict(ok, base=top + 8)), 1, 0),           # RANGE: 8 bytes past the end
             (desc_words(18, **dict(ok, base=top)), 1, 0),               # accepted: ends exactly at the end
             (desc_words(19, gen_hi=20, **ok), 1, 0),                    # torn: the last one kept
             (desc_words(21, enable=0, **ok), 1, 0),                     # off
             (desc_words(22, **ok), 0, 0),                               # accepted, no session
             (desc_words(23, **ok), 1, 0)]
    elif arm == "late":                                  # the DDR3 port starved: lines late
        flags = 1
        page(mem, rng, "8888", P0, 720, 480, 2880)
        d = desc_words(30, fmt="8888", base=P0)
        R = [(d, 1, 0), (d, 1, 0), (d, 1, 0)]
    elif arm == "n8888wide":                             # (0.10) a native 852x480 raster (a scope picture at
        g = G.geom(852, 356, 640, 639, 54, 1920, 1080, 0, 1)   # 59.94: display-shaped); a 1,024-wide 8888 canvas
        geo = (g["rw"], g["rh"], g["l"], g["nt"], g["last"])   # clipped 86 columns each side, then a 640x300
        page(mem, rng, "8888", P0, 1024, 480, 4096)            # 4444 one centred
        page(mem, rng, "4444", P1, 640, 300, 1280)
        a = desc_words(50, fmt="8888", base=P0, w=1024, h=480)
        b = desc_words(51, fmt="4444", base=P1, w=640, h=300)
        R = [(a, 1, 0), (a, 1, 0), (b, 1, 0), (b, 1, 0)]
    elif arm == "n1555tall":                             # (0.10) a native portrait raster at 50 Hz (480x854,
        pal = 1                                          # picture-sized); a 400x1000 canvas: clipped top and
        g = G.geom(480, 854, 1, 1, 30, 1920, 1080, 2, 1) # bottom (73 lines each), centred across
        geo = (g["rw"], g["rh"], g["l"], g["nt"], g["last"])
        page(mem, rng, "1555", P0, 400, 1000, 800)
        d = desc_words(52, base=P0, w=400, h=1000, band=(20, 979))
        R = [(d, 1, 0), (d, 1, 0), (d, 1, 0)]
    elif arm == "n8888hd":                               # (0.12, hd_raster stage B) a native 1280x720 raster
        g = G.geom(1280, 720, 1, 1, 80, 1920, 1080, 0, 1) # (81 MHz dots): a 1280x700 8888 canvas (10 lines
        geo = (g["rw"], g["rh"], g["l"], g["nt"], g["last"])   # transparent above and below), then a 1280x720
        P5 = FB + 0x500000                                     # 4444 one exactly the raster. (A canvas WIDER
        page(mem, rng, "8888", P0, 1280, 700, 5120)            # than a native raster is clipped, but the engine
        page(mem, rng, "4444", P5, 1280, 720, 2560)            # still composes every canvas column: on 1280x720
        a = desc_words(53, fmt="8888", base=P0, w=1280, h=700) # at 81 MHz a 2,048-wide line outruns the line --
        b = desc_words(54, fmt="4444", base=P5, w=1280, h=720) # late, counted: hd_raster.md S11)
        R = [(a, 1, 0), (a, 1, 0), (b, 1, 0)]
    elif arm == "n4444w2k":                              # (0.12) the widest native raster, 2048x448 (128 x 28
        g = G.geom(2048, 448, 1, 1, 128, 1920, 1080, 0, 1)   # macroblocks, picture-sized): a 2,048-wide canvas,
        geo = (g["rw"], g["rh"], g["l"], g["nt"], g["last"])   # the widest the slots hold
        page(mem, rng, "4444", P0, 2048, 448, 4096)
        d = desc_words(55, fmt="4444", base=P0, w=2048, h=448)
        R = [(d, 1, 0), (d, 1, 0)]
    elif arm == "n8888w2k":                              # (0.12) the same raster, a 2,048-wide 8888 canvas:
        g = G.geom(2048, 448, 1, 1, 128, 1920, 1080, 0, 1)   # 1,024 64-bit words a line -- the top bit of the
        geo = (g["rw"], g["rh"], g["l"], g["nt"], g["last"])   # line's word count (r_words), which no narrower
        page(mem, rng, "8888", P0, 2048, 448, 8192)            # canvas sets (3.5 MB from the region's start)
        d = desc_words(56, fmt="8888", base=P0, w=2048, h=448)
        R = [(d, 1, 0), (d, 1, 0)]
    else:
        raise SystemExit("ovl_ref: unknown arm %s" % arm)
    return dict(il=il, pal=pal, refreshes=R, mem=mem, flags=flags, geo=geo)


ARMS = ["p1555", "p4444", "p8888clip", "i1555at", "i4444odd", "i8888pal", "inarrow", "desc", "late",
        "n8888wide", "n1555tall", "n8888hd", "n4444w2k", "n8888w2k"]


def raster(sc):
    """the raster the canvas is centred on: (width, lines)"""
    if sc.get("geo"):
        return sc["geo"][0], sc["geo"][1]
    return 720, (576 if sc["pal"] else 480)


# ------------------------------------------------------------------------ the expected output
def run(sc):
    rw, lines = raster(sc)
    il = sc["il"]
    mem = sc["mem"]
    nd = None                                          # the accepted descriptor (the next one)
    gen = state = err = torn = 0
    lines_cum = [0, 0]                                 # canvas lines fetched, if refresh 0's first line is even / odd
    shown = dict(on=False)                             # refresh 0: nothing
    exp, stat = [], []
    for k, (d, sess, at) in enumerate(sc["refreshes"]):
        # ---- refresh k shows what refresh k - 1's blank read, with k - 1's sess / at ----
        img = [[(0, 0, 0, 0)] * rw for _ in range(lines)]
        r_at = shown.get("at", False)
        if shown["on"]:
            p = shown["p"]
            ox, oy = (rw - p["w"]) >> 1, (lines - p["h"]) >> 1   # (0.10) negative: clipped both sides
            bpp = BPP[p["fmt"]]
            cache = {}

            def pline(c):
                if not (p["bf"] <= c <= p["bl"]):
                    return None
                if c not in cache:
                    a = p["base"] + c * p["s"]
                    cache[c] = [premul(unpack(p["fmt"], mem.get(a + x * bpp, bpp))) for x in range(p["w"])]
                return cache[c]

            field_lines = [L_ for L_ in range(lines)]
            for Lf in field_lines:
                c = Lf - oy
                if r_at:
                    taps = [(pline(c - 1), 1), (pline(c), 2), (pline(c + 1), 1)]
                    row = []
                    for xc in range(p["w"]):
                        acc = [0, 0, 0, 0]
                        for t, wgt in taps:
                            if t is not None:
                                for i in range(4):
                                    acc[i] += wgt * t[xc][i]
                        row.append(tuple((v + 2) >> 2 for v in acc))
                else:
                    t = pline(c)
                    row = t if t is not None else [(0, 0, 0, 0)] * p["w"]
                for xc in range(p["w"]):
                    if 0 <= ox + xc < rw:
                        img[Lf][ox + xc] = row[xc]
            # the canvas lines fetched this refresh, in the order the raster commands them
            # (each field's lines; a filtered field line fetches c and c + 1, its first also c - 1).
            # Fields alternate, so refresh k's first line is even iff (k + p0) is even.
            vb = lambda c: 1 if p["bf"] <= c <= p["bl"] else 0
            for p0 in (0, 1):
                order = list(range((k + p0) & 1, lines, 2)) if il else list(range(lines))
                for i, Lf in enumerate(order):
                    c = Lf - oy
                    if r_at:
                        lines_cum[p0] += (vb(c - 1) if i == 0 else 0) + vb(c) + vb(c + 1)
                    else:
                        lines_cum[p0] += vb(c)
        exp.append(img)
        # ---- refresh k's blank: the descriptor written at its start is read ----
        if d[0] != d[7]:
            torn = min(torn + 1, 255)
        else:
            gen = d[0]
            if not (d[1] & 1):
                nd, state, err = None, STATE["OFF"], ERR["NONE"]
            else:
                e, prm = check(d)
                if e:
                    nd, state, err = None, STATE["REFUSED"], e
                else:
                    nd, state, err = prm, STATE["ACCEPTED"], ERR["NONE"]
        clip = 1 if (nd is not None and (nd["h"] > lines or nd["w"] > rw)) else 0
        stat.append((gen, (clip << 7) | ((1 if r_at else 0) << 6) | (err << 2) | state, torn,
                     lines_cum[0], lines_cum[1]))
        # ---- what refresh k + 1 takes at its first line ----
        shown = dict(on=(nd is not None and sess == 1), p=nd, at=bool(il and at))
    return exp, stat


def write(arm, seed):
    sc = scenario(arm, seed)
    exp, stat = run(sc)
    rw, lines = raster(sc)
    os.makedirs(GEN, exist_ok=True)
    stem = os.path.join(GEN, "ovl_" + arm)
    # the window: words from FB / 8; the control block's 72-79 at window word 0x100000 + 72
    words = {}
    for a, v in sc["mem"].b.items():
        wa = (a - FB) >> 3
        words[wa] = words.get(wa, 0) | (v << (8 * (a & 7)))
    with open(stem + ".mem.hex", "w") as f:
        last = None
        for wa in sorted(words):
            if last is None or wa != last + 1:
                f.write("@%x\n" % wa)
            f.write("%016x\n" % words[wa])
            last = wa
    with open(stem + ".stim.hex", "w") as f:
        f.write("%08x\n%08x\n%08x\n%08x\n" % (len(sc["refreshes"]), sc["il"], sc["pal"], sc["flags"]))
        geo = sc.get("geo")
        f.write("%08x\n%08x\n%08x\n%08x\n%08x\n%08x\n" % ((1,) + tuple(geo) if geo else (0, 0, 0, 0, 0, 0)))
        for d, sess, at in sc["refreshes"]:
            for v in d:
                f.write("%08x\n" % v)
            f.write("%08x\n%08x\n" % (sess, at))
    with open(stem + ".exp.hex", "w") as f:
        for img in exp:
            for Lf in range(lines):
                f.write("".join("%02x%02x%02x%02x\n" % px for px in img[Lf]))
    with open(stem + ".stat.hex", "w") as f:
        for s in stat:
            f.write("%08x\n%08x\n%08x\n%08x\n%08x\n" % s)
    nz = sum(1 for img in exp for row in img for px in row if px[3])
    print("ovl_ref: %s -- %d refreshes, %dx%d%s%s, %d opaque-or-partial pixels, %d canvas lines fetched" % (
        arm, len(exp), rw, lines, "i" if sc["il"] else "p", " native" if sc.get("geo") else "", nz, stat[-1][3]))


if __name__ == "__main__":
    a = sys.argv[1:]
    if not a or a[0] == "--list":
        print(" ".join(ARMS))
        sys.exit(0)
    seed = int(a[a.index("--seed") + 1]) if "--seed" in a else 1
    write(a[0], seed)
