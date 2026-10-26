#!/usr/bin/env python3
"""Fixtures for bench/h264/disp_reader_tb.sv: random 4:2:0 pictures as DPB store words
(docs/h264_recon.md S2.2: luma rows of 2W words, then Cb, Cr rows of W) and the expected
720x480 raster of every variant the reader shows, one line per active dot, {de, R, G, B}
as 7 hex digits (de 0 and black beyond the picture). The RGB is the BT.601 limited-range
integer conversion h264/disp_reader.sv states, of each dot's Y / Cb / Cr:

  frame   the store as a FRAME at the identity fit (progressive, 1:1): chroma INTERPOLATED at
          H.264's default siting (chroma_sample_loc_type 0; docs/display.md "Chroma at the
          identity"): horizontally co-sited with even luma columns -- odd column x = (c[x >> 1] +
          c[(x + 1) >> 1] + 1) >> 1, the right edge replicated -- then vertically between luma
          rows 2m and 2m + 1 -- row 2m = (3 h[m] + h[m - 1] + 2) >> 2, 2m + 1 = (3 h[m] + h[m + 1]
          + 2) >> 2, the edges replicated; checked here against ffmpeg's own upsampling
          (scale=in_chroma_loc=left, bilinear, full_chroma_int) within one code
  frame_il  the same store at 480i (not the identity): chroma NEAREST, luma line y takes chroma row y >> 1
  field   the store as a FIELD PAIR (line-interleaved), woven: luma line y takes its own
          field's chroma. That siting is NOT computed here from the RTL's formula
          (2 (y >> 2) + (y & 1)): ffmpeg's `separatefields` splits the woven picture into
          its two fields (every plane, chroma included, line-interleaved -- the layout the
          reconstruction writes and ffmpeg decodes to), each field's chroma is expanded with
          its own planes -- horizontally interpolated as the frame's, vertically nearest (the
          rows above and below are the other field's) -- and the two are woven back; field_il
          is the same with chroma nearest (480i).
  blend   the field pair's 4:4:4 lines through ffmpeg's `interlace` lowpass (vf_tinterlace:
          (1 + a + 2b + d) >> 2 on every line, per plane), the Blend kernel's definition. The
          filter clamps each FIELD's first and last lines to themselves; the reader mirrors
          the PICTURE's edges (line -1 := line 1, line H := line H - 2), so the planes go in
          padded by two mirrored lines each side and come out cropped: ffmpeg's edge rule never
          touches a scored line, and the golden checks the reader's edge rule too.
  bob0/1  the Bob kernel, keeping the top (0) / bottom (1) field: its lines as woven, the
          other field's (a + d + 1) >> 1, edges mirrored. No ffmpeg filter computes this (its
          bobs are temporal or edge-directed): the formula is the definition, and the kept
          lines are the ffmpeg-split weave's.

Three pictures: L, 720x480 (the raster's size); S, 480x272 (the PSP's own; its last line
is inside the raster, so the bottom mirror is seen, and the dots beyond it are black); T,
720x576 (the Level 3.0 maximum, 1,620 macroblocks, clipped to the raster's 480 lines: the
last shown line's d is the picture's real line 480, not a mirror).
Without ffmpeg the field split falls back to numpy and blend to the formula (no oracle) and
the script says so.

    disp_golden.py   -> bench/h264/fixtures/gen/disp_store{,_s,_t}.hex, disp_want_*.hex
"""
import os
import shutil
import subprocess
import tempfile
import sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import colour_ref                                 # noqa: E402  (0.16: the colour codes' integers)

RW, RH = 720, 480                                 # the raster
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bench", "h264", "fixtures", "gen")
os.makedirs(out, exist_ok=True)
HAVE_FFMPEG = shutil.which("ffmpeg") is not None


def picture(seed, W, H):
    rng = np.random.default_rng(seed)
    Y = rng.integers(0, 256, (H, W))
    # a ramp band: every level of the clip -- each row shifted 7 levels, so no two adjacent rows are equal (the
    # Blend kernel's first-row mirror is visible in luma: with identical rows K5 was seen only through the
    # chroma kernel, retired by docs/chroma.md)
    Y[:40] = (np.arange(W)[None, :] + 7 * np.arange(40)[:, None]) % 256
    Cb = rng.integers(0, 256, (H // 2, W // 2))
    Cr = rng.integers(0, 256, (H // 2, W // 2))
    return Y, Cb, Cr


def words(p):
    h, w = p.shape
    b = p.astype(np.uint64).reshape(h, w // 8, 8)
    return (sum(b[:, :, i] << np.uint64(8 * i) for i in range(8))).reshape(-1)


def up(c):
    """4:2:0 chroma -> one sample per luma dot, NEAREST (rows sited on luma row pairs): every
    output that is not the identity fit (480i, a scaled picture)."""
    return np.repeat(np.repeat(c, 2, 0), 2, 1)


def hup(c, cols=None, last=None):
    """(docs/display.md "Chroma at the identity") horizontal interpolation at H.264's default siting:
    luma column x takes c[x >> 1] (x even) or (c[x >> 1] + c[min((x + 1) >> 1, last)] + 1) >> 1 (x odd);
    `last` the crop's last chroma sample (kmax_x >> 1), `cols` the luma columns wanted (all by default)."""
    c = np.asarray(c, np.int64)
    if cols is None:
        cols = np.arange(2 * c.shape[1])
    if last is None:
        last = c.shape[1] - 1
    n, nx = cols >> 1, np.minimum((cols + 1) >> 1, last)
    return np.where(cols & 1, (c[:, n] + c[:, nx] + 1) >> 1, c[:, n])


def vrow(h, k, kmin, kmax):
    """the vertical interpolation of luma row k of a FRAME (h: the horizontally interpolated chroma
    rows), with the reader's rows a / d at the identity: a = k - 1 (k + 1 at the first row), d = k + 1
    (k - 1 at the last) -- their chroma rows >> 1; row 2m weighs a's, 2m + 1 d's"""
    ra = (k if k == kmax else k + 1) if k == kmin else k - 1
    rd = (k if k == kmin else k - 1) if k == kmax else k + 1
    o = ra if (k & 1) == 0 else rd
    return (3 * h[k >> 1] + h[o >> 1] + 2) >> 2


def up_ident(c):
    """a whole frame's chroma at the identity (no crop): horizontal, then vertical"""
    h = hup(c)
    H = 2 * c.shape[0]
    return np.stack([vrow(h, k, 0, H - 1) for k in range(H)])


def up_field(c):
    """(the identity step's form, superseded: horizontal only, vertically nearest within the field)"""
    return np.repeat(hup(c), 2, 0)


# ---- CHROMA (docs/chroma.md): siting-aware bilinear on every output --------------------------------
# Written from the design (chroma.md §2), Q.16 integers as the reader keeps them:
#   the luma source position X = (lx << 16) + j sx + (sx >> 1) - 2^15 (the UNSHIFTED one: the Area
#   pre-filter and anti-twitter shift luma only), Y likewise with ty / sy;
#   a frame (or a field store at dv > 1, woven): cx = (X - ((dh - 1) << 16) - HOFF) >> (log2 dh + 1),
#   cy = (Y - ((dv - 1) << 16) - VOFF) >> (log2 dv + 1) -- decimated chroma samples / rows;
#   a store of fields at dv = 1: the field p of the row nearest Y (Bob's rebuilt line: the kept field),
#   its own coordinates Yf = (Y - (p << 16)) >> 1, cy = (Yf - (VOFF_p + (p << 16)) / 2) >> 1, the store's
#   rows 2 k + p -- Figure E-1's field siting: field p's chroma row m sits at frame line 4m + 2p + VOFF_p,
#   i.e. (VOFF_p + p) / 2 down its own field's line pair (type 0: a quarter in the top field, three
#   quarters in the bottom; MPEG-2's interlaced 4:2:0), not VOFF_p (the field-centred rule before
#   2026-10-12, found by MiSTer_UMD_Video: docs/chroma.md §2);
#   taps k = floor, k + 1, the weight the next 8 bits; below the crop both the first and weight 0,
#   above it the last; h = (a (256 - w) + b w + 128) >> 8 on both rows, then the same vertically.
# The siting (chroma_sample_loc_type, E.2.1): horizontally 1 / 3 / 5 centred (+1/2 luma sample), 0 / 2 / 4
# co-sited; vertically 0 / 1 between the rows (+1/2), 2 / 3 the top row (0), 4 / 5 the bottom (+1).
HOFF = {0: 0, 1: 1 << 15, 2: 0, 3: 1 << 15, 4: 0, 5: 1 << 15}
VOFF = {0: 1 << 15, 1: 1 << 15, 2: 0, 3: 0, 4: 1 << 16, 5: 1 << 16}
_FIELD_CENTRED = False        # (check_field_oracle only) the old field rule, to prove the oracle tells them apart


def clerp(a, b, w):
    return (a * (256 - w) + b * w + 128) >> 8


def ctaps(q, cmin, cmax):
    q = np.asarray(q, np.int64)
    k, w = q >> 16, (q >> 8) & 0xFF
    below = k < cmin
    return (np.where(below, cmin, np.minimum(k, cmax)), np.where(below, cmin, np.minimum(k + 1, cmax)),
            np.where(below, 0, w))


def chroma_line(Ud, Vd, f, L, xs, sit=(0, 0), field=False, bobkeep=None, want_pos=False):
    """raster line L's chroma at raster columns xs (an array) under the fit f; Ud / Vd the decimated
    chroma planes, their rows the store's decimated chroma rows; sit = (top / frame, bottom) types"""
    t, b = sit
    dh, dv = f['dh'], f['dv']
    dhl, dvl = dh.bit_length() - 1, dv.bit_length() - 1
    Yq = (f['ty'] << 16) + (L - f['oy0']) * f['sy'] + (f['sy'] >> 1) - (1 << 15)
    if field and dv == 1:
        p = ((Yq + (1 << 15)) >> 16) & 1
        if bobkeep is not None:
            p = bobkeep
        typ = t if p == 0 else b
        foff = VOFF[typ] if _FIELD_CENTRED else (VOFF[typ] + (p << 16)) >> 1   # (Figure E-1's field siting)
        cq = (((Yq - (p << 16)) >> 1) - foff) >> 1
        k0, k1, wy = ctaps(cq, f['ty'] >> 2, ((f['ty'] + f['hc']) >> 2) - 1)
        r0, r1 = 2 * int(k0) + p, 2 * int(k1) + p
    else:
        typ = t
        cq = (Yq - ((dv - 1) << 16) - VOFF[t]) >> (dvl + 1)
        k0, k1, wy = ctaps(cq, f['ty'] >> (dvl + 1), (((f['ty'] + f['hc']) >> 1) - 1) >> dvl)
        r0, r1 = int(k0), int(k1)
    wy = int(wy)
    Xq = (f['lx'] << 16) + (np.asarray(xs) - f['ox0']) * f['sx'] + (f['sx'] >> 1) - (1 << 15)
    cx = (Xq - ((dh - 1) << 16) - HOFF[typ]) >> (dhl + 1)
    c0, c1, wx = ctaps(cx, f['lx'] >> (dhl + 1), (((f['lx'] + f['wc']) >> 1) - 1) >> dhl)
    out = []
    for C in (Ud, Vd):
        out.append(clerp(clerp(C[r0, c0], C[r0, c1], wx), clerp(C[r1, c0], C[r1, c1], wx), wy))
    if want_pos:
        out.append((r0, r1, wy, c0, c1, wx))
    return out


def ident_fit(W, H):
    import disp_fit_ref as _frr
    f = _frr.fit(W // 16, H // 16, mode='fill')     # the raster filled (no display): any picture at 720x480 is the identity
    assert f['sx'] == f['sy'] == 1 << 16 and f['dh'] == f['dv'] == 1 and f['ox0'] == f['oy0'] == 0, "not the identity"
    return f


def chroma_planes(Cb, Cr, f, sit=(0, 0), field=False, bobkeep=None, H=None, W=None):
    """every raster line's chroma over the whole picture (the identity fixtures: raster = picture)"""
    H = 2 * Cb.shape[0] if H is None else H
    W = 2 * Cb.shape[1] if W is None else W
    U = np.zeros((H, W), np.int64)
    V = np.zeros((H, W), np.int64)
    xs = np.arange(W)
    for y in range(H):
        U[y], V[y] = chroma_line(np.asarray(Cb, np.int64), np.asarray(Cr, np.int64), f, y, xs, sit, field, bobkeep)[:2]
    return U, V


def check_positions():
    """docs/chroma.md §2's worked positions -- an off-by-half hides here"""
    f = dict(lx=0, ty=0, wc=64, hc=64, ox0=0, oy0=0, sx=1 << 16, sy=1 << 16, dh=1, dv=1)
    C = np.arange(32 * 32).reshape(32, 32)
    def pos(L, x, sit, field=False, keep=None):
        return chroma_line(C, C, f, L, np.array([x]), sit, field, keep, want_pos=True)[2]
    # horizontally: type 0 X = 2n -> n, w 0; X = 2n + 1 -> n, n + 1, w 128; type 1 X = 2n -> n - 1, n, w 192
    def hx(x, t):
        r = pos(9, x, (t, t)); return int(r[3][0]), int(r[4][0]), int(r[5][0])
    def vy(L, t, field=False, keep=None):
        r = pos(L, 4, (t, t), field, keep); return r[0], r[1], r[2]
    assert hx(10, 0) == (5, 6, 0) and hx(11, 0) == (5, 6, 128), "type 0 horizontally"
    assert hx(10, 1) == (4, 5, 192) and hx(11, 1) == (5, 6, 64), "type 1 horizontally"
    assert vy(10, 0) == (4, 5, 192) and vy(11, 0) == (5, 6, 64), "voff 1/2 vertically"
    assert vy(10, 2) == (5, 6, 0) and vy(11, 2) == (5, 6, 128), "voff 0 (types 2, 3)"
    assert vy(10, 4) == (4, 5, 128) and vy(11, 4) == (5, 6, 0), "voff 1 (types 4, 5)"
    # a field store (dv 1), Figure E-1's field siting: field p's chroma row m at its own field line 2m + (VOFF + p) / 2.
    # Type 0: frame line 10 is field 0's line 5 -> (5 - 1/4) / 2 = 2.375 -> its rows 2 / 3 = store rows 4 / 6, w 96;
    # line 11 is field 1's line 5 -> (5 - 3/4) / 2 = 2.125 -> store rows 5 / 7, w 32 (the field-centred rule
    # gave 64 / 64 before 2026-10-12)
    assert vy(10, 0, True) == (4, 6, 96) and vy(11, 0, True) == (5, 7, 32), "a field's own rows, type 0"
    # type 2 (top: 0, bottom: 1/2): (5 - 0) / 2 = 2.5 -> w 128; (5 - 1/2) / 2 = 2.25 -> w 64
    assert vy(10, 2, True) == (4, 6, 128) and vy(11, 2, True) == (5, 7, 64), "a field's own rows, type 2"
    # type 4 (top: 1/2, bottom: 1): (5 - 1/2) / 2 = 2.25 -> w 64; (5 - 1) / 2 = 2 -> w 0
    assert vy(10, 4, True) == (4, 6, 64) and vy(11, 4, True) == (5, 7, 0), "a field's own rows, type 4"
    # Bob keeping field 0: line 11 rebuilt from field 0 at its line 5.5 -> (5.5 - 1/4) / 2 = 2.625 -> store 4 / 6, w 160
    assert vy(11, 0, True, 0) == (4, 6, 160), "Bob's rebuilt line from the kept field"
    # dh 2, type 0: decimated chroma sample m centred at luma x = 4m + 1
    f2 = dict(f, dh=2, sx=2 << 16)
    r = chroma_line(C, C, f2, 9, np.array([2]), (0, 0), want_pos=True)[2]   # output 2: X = 4.5 + ... -> centre
    Xq = (2 << 16) * 2 + ((2 << 16) >> 1) - (1 << 15)
    assert Xq == (4 << 16) + (1 << 15) and (int(r[3][0]), int(r[5][0])) == (0, 224), "dh 2 (4.5 - 1) / 4 = 0.875"
    print("disp_golden: chroma positions as docs/chroma.md §2's table")


check_positions()


def rgb(Y, U, V, code=1):
    """The display's conversion under a colour code (0.16; default 1, BT.601 limited: the 0.15
    integers). The integers are tools/colour_ref.py's, derived from Kr / Kb -- not the RTL's table."""
    return colour_ref.rgb(Y, U, V, code)


def ffmpeg(args, planes, W, H, fmt):
    with tempfile.TemporaryDirectory() as d:
        src, dst = os.path.join(d, "in.yuv"), os.path.join(d, "out.yuv")
        with open(src, "wb") as f:
            f.write(b"".join(p.astype(np.uint8).tobytes() for p in planes))
        subprocess.run(["ffmpeg", "-v", "error", "-f", "rawvideo", "-pix_fmt", fmt, "-s", "%dx%d" % (W, H),
                        "-i", src] + args + ["-f", "rawvideo", "-pix_fmt", fmt, dst], check=True)
        return np.frombuffer(open(dst, "rb").read(), np.uint8).astype(np.int64)


def fields(Y, Cb, Cr):
    """The two fields' 4:2:0 planes, split by ffmpeg `separatefields` (numpy without it)."""
    H, W = Y.shape
    if not HAVE_FFMPEG:
        return [(Y[p::2], Cb[p::2], Cr[p::2]) for p in (0, 1)]
    raw = ffmpeg(["-vf", "setfield=tff,separatefields"], (Y, Cb, Cr), W, H, "yuv420p")
    fh = H // 2
    fsz = W * fh + 2 * (W // 2) * (fh // 2)
    assert raw.size == 2 * fsz, "separatefields: %d bytes" % raw.size
    res = []
    for k in range(2):                            # output order = top field, then bottom (tff)
        a = raw[k * fsz:(k + 1) * fsz]
        yp = a[:W * fh].reshape(fh, W)
        cb = a[W * fh:W * fh + (W // 2) * (fh // 2)].reshape(fh // 2, W // 2)
        cr = a[W * fh + (W // 2) * (fh // 2):].reshape(fh // 2, W // 2)
        res.append((yp, cb, cr))
    # the split must be the luma lines as stored (a sanity check on the oracle's field order)
    assert all((res[p][0] == Y[p::2]).all() for p in (0, 1)), "field order"
    return res


def woven444(Y, Cb, Cr, cup=None):
    """Every luma line with its own field's chroma, woven (H x W, three planes); `cup` the chroma
    expansion of each field (up_field at the identity, up -- nearest -- at 480i)."""
    cup = up_field if cup is None else cup
    H, W = Y.shape
    planes = [np.zeros((H, W), np.int64) for _ in range(3)]
    for p, (yp, cb, cr) in enumerate(fields(Y, Cb, Cr)):
        planes[0][p::2], planes[1][p::2], planes[2][p::2] = yp, cup(cb), cup(cr)
    return planes


def mirror_pad(p, n=2):
    """Rows -n..-1 and H..H+n-1 mirrored about the picture's first / last line."""
    top = p[1:n + 1][::-1]
    bot = p[-n - 1:-1][::-1]
    return np.concatenate([top, p, bot])


def blend(planes):
    H, W = planes[0].shape
    padded = [mirror_pad(p) for p in planes]
    if HAVE_FFMPEG:
        # two identical frames in, one out: each output line is the lowpass of its own frame
        raw = ffmpeg(["-vf", "interlace=scan=tff:lowpass=linear"], padded * 2, W, H + 4, "yuv444p")
        n = W * (H + 4)
        assert raw.size == 3 * n, "interlace: %d bytes" % raw.size
        return [raw[k * n:(k + 1) * n].reshape(H + 4, W)[2:-2] for k in range(3)]
    return [(pp[1:-3] + 2 * pp[2:-2] + pp[3:-1] + 1) >> 2 for pp in padded]


def bob(planes, keep):
    res = []
    for p in planes:
        pp = mirror_pad(p, 1)                     # pp[y + 1] = line y
        o = p.copy()
        for y in range(p.shape[0]):
            if (y & 1) != keep:
                o[y] = (pp[y] + pp[y + 2] + 1) >> 1
        res.append(o)
    return res


def write_want(name, img):
    """img: the picture's RGB (h x w x 3), placed at the raster's top left."""
    h, w, _ = img.shape
    with open(os.path.join(out, name), "w") as f:
        for y in range(RH):
            for x in range(RW):
                if y < h and x < w:
                    f.write("1%02x%02x%02x\n" % tuple(img[y, x]))
                else:
                    f.write("0000000\n")


def write_store(name, Y, Cb, Cr):
    with open(os.path.join(out, name), "w") as f:
        for p in (Y, Cb, Cr):
            f.write("".join("%016x\n" % int(v) for v in words(p)))


# L: 720x480 (seed 7: the picture the frame / field fixtures have always used)
L = picture(7, 720, 480)
write_store("disp_store.hex", *L)
# (docs/chroma.md) the identity fixtures through the general chroma model -- chroma_line on the identity fit
F_ID = ident_fit(720, 480)
Uf_, Vf_ = chroma_planes(L[1], L[2], F_ID)
# the regression anchor: at the identity, type 0, the general model IS the identity step's integers
assert (Uf_ == up_ident(L[1])).all() and (Vf_ == up_ident(L[2])).all(), "the general model is not the identity step's"
write_want("disp_want_frame.hex", rgb(L[0], Uf_, Vf_))
for _c in range(2, 7):                            # (0.16) the frame under every other colour code
    write_want("disp_want_frame_c%d.hex" % _c, rgb(L[0], Uf_, Vf_, _c))
for _t in range(1, 6):                            # (chroma.md) the frame at every other siting
    _u, _v = chroma_planes(L[1], L[2], F_ID, (_t, _t))
    write_want("disp_want_frame_s%d.hex" % _t, rgb(L[0], _u, _v))
# a store of fields at the identity: each field's chroma within the field (store rows 2 k + p)
Uw_, Vw_ = chroma_planes(L[1], L[2], F_ID, field=True)
# ... independently: ffmpeg's separatefields split, each field upsampled at Figure E-1's FIELD siting (up_fv:
# MiSTer_UMD_Video's, written from the weights, not from chroma_line's positions), woven back


def up_fv(c, p):
    """one field's chroma (field p: 0 top, 1 bottom; type 0) at H.264's field siting: horizontal as hup, then
    field line k takes row m = k >> 1 and its far-side neighbour (k even: m - 1, odd: m + 1; the field's first /
    last row itself); the line nearer its row (k & 1 == p) (7 h[m] + h[n] + 4) >> 3, the other
    (5 h[m] + 3 h[n] + 4) >> 3 -- row m a quarter (top) / three quarters (bottom) down its line pair"""
    h = hup(c)
    R = c.shape[0]
    rows = []
    for k in range(2 * R):
        m = k >> 1
        n = max(m - 1, 0) if (k & 1) == 0 else min(m + 1, R - 1)
        rows.append(((7 * h[m] + h[n] + 4) >> 3) if (k & 1) == p else ((5 * h[m] + 3 * h[n] + 4) >> 3))
    return np.stack(rows)


_fl = fields(*L)
_ou, _ov = np.zeros_like(Uw_), np.zeros_like(Vw_)
for _p in (0, 1):
    _ou[_p::2], _ov[_p::2] = up_fv(_fl[_p][1], _p), up_fv(_fl[_p][2], _p)
assert (_ou == Uw_).all() and (_ov == Vw_).all(), "a field store's chroma is not each field's own upsampling at E-1's siting"
Lf = [L[0].astype(np.int64), Uw_, Vw_]
write_want("disp_want_field.hex", rgb(*Lf))
# ... the two fields at different sitings (top type 0, bottom type 2: {bottom, top} = 16): each line its own field's
_u, _v = chroma_planes(L[1], L[2], F_ID, (0, 2), field=True)
write_want("disp_want_field_s16.hex", rgb(L[0], _u, _v))
# 480i shows the same positions (a 1:1 picture: every pixel two dots, each frame line its own row)
write_want("disp_want_frame_il.hex", rgb(L[0], Uf_, Vf_))
write_want("disp_want_field_il.hex", rgb(*Lf))


def check_chroma_oracle(c):
    """the independent check of the model at the identity: ffmpeg's own 4:2:0 -> 4:4:4 upsampling at each
    siting (scale=in_chroma_loc), against chroma_line within one code (ffmpeg rounds once, the reader twice).
    Validated first on an impulse per siting: the weights where the siting puts them (2026-10-09: without
    in_chroma_loc ffmpeg assumes centre siting)"""
    if not HAVE_FFMPEG:
        print("disp_golden: identity chroma NOT checked (no ffmpeg)")
        return
    names = ["left", "center", "topleft", "top", "bottomleft", "bottom"]
    def up_ff(cp, loc):
        h, w = cp.shape
        with tempfile.TemporaryDirectory() as d:
            src, dst = os.path.join(d, "in.yuv"), os.path.join(d, "out.yuv")
            with open(src, "wb") as fh:
                fh.write(b"".join(q.astype(np.uint8).tobytes() for q in (np.full((2 * h, 2 * w), 128), cp, cp)))
            subprocess.run(["ffmpeg", "-v", "error", "-f", "rawvideo", "-pix_fmt", "yuv420p", "-s", "%dx%d" % (2 * w, 2 * h),
                            "-i", src, "-vf", "scale=in_chroma_loc=%s:flags=bilinear+full_chroma_int+accurate_rnd" % loc,
                            "-f", "rawvideo", "-pix_fmt", "yuv444p", dst], check=True)
            raw = np.frombuffer(open(dst, "rb").read(), np.uint8).astype(np.int64)
        n = 4 * h * w
        return raw[n:2 * n].reshape(2 * h, 2 * w)
    imp = np.full((8, 16), 128); imp[4, 8] = 228
    fi = dict(lx=0, ty=0, wc=32, hc=16, ox0=0, oy0=0, sx=1 << 16, sy=1 << 16, dh=1, dv=1)   # 1:1 (no raster)
    for t, loc in enumerate(names):
        ref = up_ff(imp, loc) - 128
        ours = chroma_planes(imp, imp, fi, (t, t))[0] - 128
        assert np.abs(ref - ours).max() <= 1, "the %s impulse: ffmpeg and the model disagree" % loc
        u, _ = chroma_planes(c, c, F_ID, (t, t))
        d = np.abs(u - up_ff(c, loc))[2:-2, 2:-2]     # (the borders: ffmpeg's own edge rule)
        assert d.max() <= 1, "siting %d (%s): %d codes from ffmpeg's upsampling" % (t, loc, d.max())
    print("disp_golden: identity chroma within one code of ffmpeg's upsampling at all six sitings")


check_chroma_oracle(L[1])


def check_field_oracle(c):
    """(docs/chroma.md §2) the independent check of the FIELD rule: ffmpeg's interlaced 4:2:0 -> 4:4:4
    (scale=interl=1 with in_chroma_loc: libswscale 9.0.1's format.c halves the vertical position for a field
    and moves the bottom field's by a luma row -- Figure E-1's field positions, MPEG-2's interlaced siting)
    against the model's field store at the identity, within one code (ffmpeg rounds once, the reader twice),
    at all six sitings. And the old field-centred rule must be MORE than a code from it at every siting: an
    oracle that cannot tell the two apart checks nothing (MiSTer_UMD_Video's check, ported 2026-10-12)"""
    global _FIELD_CENTRED
    if not HAVE_FFMPEG:
        print("disp_golden: field chroma NOT checked (no ffmpeg)")
        return
    names = ["left", "center", "topleft", "top", "bottomleft", "bottom"]
    def up_ff(cp, loc):
        h, w = cp.shape
        with tempfile.TemporaryDirectory() as d:
            src, dst = os.path.join(d, "in.yuv"), os.path.join(d, "out.yuv")
            with open(src, "wb") as fh:
                fh.write(b"".join(q.astype(np.uint8).tobytes() for q in (np.full((2 * h, 2 * w), 128), cp, cp)))
            subprocess.run(["ffmpeg", "-v", "error", "-f", "rawvideo", "-pix_fmt", "yuv420p", "-s", "%dx%d" % (2 * w, 2 * h),
                            "-i", src, "-vf", "scale=interl=1:in_chroma_loc=%s:flags=bilinear+full_chroma_int+accurate_rnd" % loc,
                            "-f", "rawvideo", "-pix_fmt", "yuv444p", dst], check=True)
            raw = np.frombuffer(open(dst, "rb").read(), np.uint8).astype(np.int64)
        n = 4 * h * w
        assert raw.size == 3 * n, "ffmpeg's interlaced upsampling: %d bytes" % raw.size
        return raw[n:2 * n].reshape(2 * h, 2 * w)
    s_ = np.s_[4:-4, 2:-2]                          # (the borders: ffmpeg's own edge rule)
    worst = 0
    for t, loc in enumerate(names):
        ref = up_ff(c, loc)
        try:
            for centred in (False, True):
                _FIELD_CENTRED = centred
                u, _ = chroma_planes(c, c, F_ID, (t, t), field=True)
                d = int(np.abs(u - ref)[s_].max())
                if centred:
                    assert d > 1, "siting %d (%s): the field-centred rule is within one code of ffmpeg's interlaced upsampling: no oracle" % (t, loc)
                else:
                    assert d <= 1, "siting %d (%s): field chroma %d codes from ffmpeg's interlaced upsampling" % (t, loc, d)
                    worst = max(worst, d)
        finally:
            _FIELD_CENTRED = False
    print("disp_golden: field chroma within %d code of ffmpeg's interlaced upsampling (interl=1) at all six sitings; "
          "the field-centred rule is not" % worst)


check_field_oracle(L[1])
# Blend and Bob keep their LUMA kernels (ffmpeg's interlace lowpass for Blend); chroma is the field model's
# -- Blend the line's own field (docs/chroma.md §2, decided), Bob's rebuilt line the kept field's
write_want("disp_want_blend.hex", rgb(blend(Lf)[0], Uw_, Vw_))
for _k in (0, 1):
    _u, _v = chroma_planes(L[1], L[2], F_ID, field=True, bobkeep=_k)
    write_want("disp_want_bob%d.hex" % _k, rgb(bob(Lf, _k)[0], _u, _v))
# (P6: the 480x272 and 720x576 kernel fixtures retired -- the kernels apply at the identity
# fit only, where L's first and last lines are the mirrors; those pictures are FIT's s / t)


# ---- P6 step 3: the FITTED raster (docs/analog.md §5) -------------------------------------
# Written from the design's formulas (tools/disp_fit_ref.py holds the fit's integers): the
# box decimation, the 2-tap blends (horizontal on rows k and k + 1, then vertical), chroma
# NEAREST at the luma tap >> 1, black outside the rectangle. Not from the RTL.
import sys as _sys
_sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import disp_fit_ref as _fr


def box(p, dh, dv):
    """(sum + 2^(s-1)) >> s over each dh x dv block, s = log2(dh dv)"""
    H, W = p.shape
    s = (dh * dv).bit_length() - 1
    t = p.reshape(H // dv, dv, W // dh, dh).sum(axis=(1, 3))
    return (t + (1 << (s - 1))) >> s if s else t


def prefiltered(p, dh, dv, hpf, vpf):
    """(docs/analog.md §11b) the stored luma: over the box sums B (dh x dv, unrounded), the
    vertical pre-filter's weights (eighths) on boxes k, k + 1, k + 2 and the horizontal's on
    samples m, m + 1, m + 2, ONE rounding: (sum + 2^(s+5)) >> (s + 6), s = log2(dh dv). Anti-
    twitter's sliding rows (§9) are vpf 4: (B_k + B_k+1 + 2^s) >> (s + 1), and (8, 0, 0) both ways
    the plain box -- the old integers exactly. Samples past the picture (only a clamped tap's
    neighbours, never read) replicate the last."""
    H, W = p.shape
    s = (dh * dv).bit_length() - 1
    B = p.reshape(H // dv, dv, W // dh, dh).sum(axis=(1, 3)).astype(np.int64)
    wv, wh = _fr.pf_weights(vpf), _fr.pf_weights(hpf)
    Bp = np.pad(B, ((0, 2), (0, 2)), mode='edge')
    V = sum(wv[i] * Bp[i:i + B.shape[0], :] for i in range(3))
    T = sum(wh[j] * V[:, j:j + B.shape[1]] for j in range(3))
    return (T + (1 << (s + 5))) >> (s + 6)


def taps(f, j, axis):
    """src_pos over an array of output indices (numpy: // and >> floor like Python's); the
    pre-filtered sample k is centred at k + S / 8 (docs/analog.md §11b; anti-twitter's sliding
    rows are S = 4, §9), so the position is S / 8 of a decimated sample up, and the last sample
    whose boxes lie inside the crop is kmax - (nb - 1)"""
    step, d, org, size = (f['sx'], f['dh'], f['lx'], f['wc']) if axis == 'x' else \
                         (f['sy'], f['dv'], f['ty'], f['hc'])
    c = f['hpf'] if axis == 'x' else f['vpf']
    Q = _fr.Q
    pos = (org << Q) + j * step + (step >> 1) - (1 << (Q - 1))
    u = (pos - ((d - 1) << (Q - 1)) - ((d * _fr.pf_shift(c)) << (Q - 3))) // d
    kmin, kmax = org // d, (org + size - 1) // d - _fr.pf_extra(c)
    k = u >> Q
    w = (u >> (Q - 8)) & 0xFF
    w = np.where(k < kmin, 0, w)
    return np.clip(k, kmin, kmax), np.clip(k + 1, kmin, kmax), w


def lerp(a, b, w):
    return (a * (256 - w) + b * w + 128) >> 8


def render(Y, Cb, Cr, f, luma=None, sit=(0, 0), code=1):
    """the raster (RH x RW x 3) and its de mask for a picture fitted by f (luma: a dict that
    receives each shown line's luma -- and 'U' / 'V', the chroma -- for the independent checks below).
    The pre-filters (§11b; anti-twitter's sliding rows among them): luma only. Chroma (docs/chroma.md):
    bilinear at the picture's siting, at the UNSHIFTED position (chroma_line), the frame's decimated rows"""
    Yd = prefiltered(Y, f['dh'], f['dv'], f['hpf'], f['vpf'])
    Ud, Vd = box(Cb, f['dh'], f['dv']), box(Cr, f['dh'], f['dv'])
    rh, rw = f['rh'], f['rw']                     # the raster (576 lines at 50 Hz; stage 2: a native raster)
    img = np.zeros((rh, rw, 3), np.int64)
    de = np.zeros((rh, rw), bool)
    x0, x1 = max(0, f['ox0']), min(rw, f['ox0'] + f['ow'])
    if x1 <= x0:
        return img, de
    xs = np.arange(x0, x1)
    kx0, kx1, wx = taps(f, xs - f['ox0'], 'x')
    for L in range(max(0, f['oy0']), min(rh, f['oy0'] + f['oh'])):
        ky0, ky1, wy = taps(f, np.array([L - f['oy0']]), 'y')
        ky0, ky1, wy = int(ky0[0]), int(ky1[0]), int(wy[0])
        y = lerp(lerp(Yd[ky0, kx0], Yd[ky0, kx1], wx), lerp(Yd[ky1, kx0], Yd[ky1, kx1], wx), wy)
        u, v = chroma_line(Ud, Vd, f, L, xs, sit)[:2]
        img[L, x0:x1] = rgb(y, u, v, code)
        if luma is not None:
            luma[L] = y
            luma.setdefault('U', {})[L] = u
            luma.setdefault('V', {})[L] = v
        de[L, x0:x1] = True
    return img, de


def check_filter(name, wm, hm, cr, sar, mode, il, at, pal, flt):
    """(docs/analog.md §11b) independent of the arithmetic above:
    - a RAMP: every filter here sums to 1 and is symmetric about the centre it claims, so on a
      linear ramp the output equals the ramp at the output pixel's own source position (within
      the quantisation): a centre offset wrong by any fraction of a sample shows
    - (chroma: check_chroma_ramp, every fitted case, docs/chroma.md)
    - an upscale (r <= 1 both ways) renders exactly Sharp's raster"""
    f = _fr.fit(wm, hm, cr, sar[0], sar[1], mode, il, at, pal, flt=flt)
    if f['hpf'] == 0 and f['vpf'] == 0:
        g = _fr.fit(wm, hm, cr, sar[0], sar[1], mode, il, at, pal)
        P = picture(1, 16 * wm, 16 * hm)
        assert (render(*P, f)[0] == render(*P, g)[0]).all() and f['dh'] == g['dh'], name + ": not Sharp's"
        print("disp_golden: %s: no pre-filter, Sharp's raster exactly" % name)
        return
    W, H = 16 * wm, 16 * hm
    xx, yy = np.meshgrid(np.arange(W), np.arange(H))
    for axis in ('x', 'y'):
        ramp = (xx if axis == 'x' else yy) * (180.0 / (W if axis == 'x' else H)) + 30
        Y = np.round(ramp).astype(np.int64)
        lum = {}
        render(Y, np.full((H // 2, W // 2), 128), np.full((H // 2, W // 2), 128), f, lum)
        lum.pop('U'); lum.pop('V')
        step, org, size, o0, n = (f['sx'], f['lx'], f['wc'], f['ox0'], f['ow']) if axis == 'x' else \
                                 (f['sy'], f['ty'], f['hc'], f['oy0'], f['oh'])
        span = W if axis == 'x' else H
        worst = 0.0
        for L, y in lum.items():
            j = np.arange(len(y)) if axis == 'x' else np.full(len(y), L - f['oy0'])
            if axis == 'x':
                j = np.arange(max(0, f['ox0']), max(0, f['ox0']) + len(y)) - f['ox0']
            src = org + (j + 0.5) * step / 65536.0 - 0.5
            inner = (src > org + 12 * (f['dh'] if axis == 'x' else f['dv'])) & \
                    (src < org + size - 1 - 12 * (f['dh'] if axis == 'x' else f['dv']))
            if inner.any():
                worst = max(worst, float(np.abs(y[inner] - (src[inner] * 180.0 / span + 30)).max()))
        assert worst <= 1.5, "%s: the %s ramp off by %.2f codes (a centre offset)" % (name, axis, worst)
        print("disp_golden: %s: the %s ramp within %.2f codes" % (name, axis, worst))
    # IMPULSES: isolated one-sample lines at spread output phases; each one's centroid on the output, mapped back
    # through the fit, against where it is -- the mean signed error is the centre offset (rounding
    # noise averages out; a 3/8-sample offset at r 1.8 is 0.2 output pixels)
    for axis in ('x', 'y'):
        pos_of = np.arange(W) if axis == 'x' else np.arange(H)
        # each line placed (within 8 of every 37th) so its output phase is the next of a uniform
        # set: the sampling's own bias, odd about each phase, then averages to zero
        st_, org_ = (f['sx'], f['lx']) if axis == 'x' else (f['sy'], f['ty'])
        base = np.arange(20, (W if axis == 'x' else H) - 28, 37)
        ph = lambda x: (((x - org_ + 0.5) * 65536.0 / st_ - 0.5) % 1.0)
        lines = np.array([min(range(b - 8, b + 9), key=lambda x: abs(ph(x) - (i + 0.5) / len(base)))
                          for i, b in enumerate(base)])
        Y = np.full((H, W), 16, np.int64)
        if axis == 'x':
            Y[:, lines] = 235
        else:
            Y[lines, :] = 235
        lum = {}
        render(Y, np.full((H // 2, W // 2), 128), np.full((H // 2, W // 2), 128), f, lum)
        lum.pop('U'); lum.pop('V')
        step, org, size, o0 = (f['sx'], f['lx'], f['wc'], f['ox0']) if axis == 'x' else \
                              (f['sy'], f['ty'], f['hc'], f['oy0'])
        if axis == 'x':
            L0 = sorted(lum)[len(lum) // 2]
            prof = lum[L0].astype(float) - 16
            j = np.arange(max(0, o0), max(0, o0) + len(prof)) - o0
        else:
            Ls = sorted(lum)
            x0 = len(lum[Ls[0]]) // 2
            prof = np.array([lum[L][x0] for L in Ls], float) - 16
            j = np.array(Ls) - o0
        s_out = step / 65536.0
        errs = []
        for x in lines:
            if x < org + 8 * s_out or x > org + size - 1 - 8 * s_out:
                continue
            want = (x - org + 0.5) / s_out - 0.5          # the output coordinate of the source line
            m = np.abs(j - want) <= 3 + 3 / s_out
            if prof[m].sum() <= 0:
                continue
            errs.append(float((j[m] * prof[m]).sum() / prof[m].sum() - want))
        if errs:
            me = float(np.mean(errs))
            assert abs(me) <= 0.08, "%s: the %s impulses' centroids off by %.3f output pixels (a centre offset)" % (name, axis, me)
            print("disp_golden: %s: %d %s impulses centred within %.3f" % (name, len(errs), axis, me))


def check_chroma_ramp(name, W, H, f, sit):
    """(docs/chroma.md §5) the chroma positions, independent of chroma_line's integers: a triangle wave in
    chroma (period 48 chroma samples, 30..222: exactly 8 codes a sample, so every sample, every box
    average of 2, 4 or 8, and every quarter / half position is an integer -- no rounding in the source) is linear between its peaks, and box
    decimation and bilinear reproduce a linear piece exactly -- so each output pixel's Cb must be the wave
    AT ITS OWN CHROMA POSITION, (source position - siting offset) / 2 in floating point. A siting or
    centre error of a quarter chroma sample biases the mean by 2 codes; the blends' rounding stays near 0."""
    def tri(u):
        ph = np.mod(u, 48.0)
        return 30 + 8 * np.minimum(ph, 48 - ph), np.minimum(np.abs(ph - 24), np.minimum(ph, 48 - ph))
    # E.2.1 / Figure E-1, written out here -- NOT the model's HOFF / VOFF tables (a wrong entry there must show)
    hoff = 0.5 if sit[0] in (1, 3, 5) else 0.0
    voff = {0: 0.5, 1: 0.5, 2: 0.0, 3: 0.0, 4: 1.0, 5: 1.0}[sit[0]]
    for axis in ('x', 'y'):
        cc = np.arange(W // 2) if axis == 'x' else np.arange(H // 2)
        wave = np.round(tri(cc.astype(float))[0]).astype(np.int64)
        Cb = np.tile(wave, (H // 2, 1)) if axis == 'x' else np.tile(wave[:, None], (1, W // 2))
        lum = {}
        render(np.full((H, W), 128), Cb, np.full((H // 2, W // 2), 128), f, lum, sit)
        Us = lum['U']
        d = f['dh'] if axis == 'x' else f['dv']
        errs = []
        for L, u in Us.items():
            if axis == 'x':
                j = np.arange(max(0, f['ox0']), max(0, f['ox0']) + len(u)) - f['ox0']
                src = f['lx'] + (j + 0.5) * f['sx'] / 65536.0 - 0.5
                cpos, org, size = (src - hoff) / 2.0, f['lx'] / 2.0, f['wc'] / 2.0
                got = u
            else:
                src = np.array([f['ty'] + (L - f['oy0'] + 0.5) * f['sy'] / 65536.0 - 0.5])
                cpos, org, size = (src - voff) / 2.0, f['ty'] / 2.0, f['hc'] / 2.0
                got = u[len(u) // 2:len(u) // 2 + 1]
            want, edge = tri(cpos)
            inner = (cpos > org + 2 * d + 1) & (cpos < org + size - 2 * d - 2) & (edge > 2 * d + 2)
            errs.extend((got[inner] - want[inner]).tolist())
        if not errs:
            continue
        me, mx = float(np.mean(errs)), float(np.max(np.abs(errs)))
        assert abs(me) <= 0.3 and mx <= 3.0, "%s siting %d: the %s chroma ramp off by mean %.2f, max %.2f (a position error)" % (
            name, sit[0], axis, me, mx)


def write_want_de(name, img, de):
    with open(os.path.join(out, name), "w") as fh:
        for y in range(img.shape[0]):
            for x in range(img.shape[1]):
                fh.write(("1%02x%02x%02x\n" % tuple(img[y, x])) if de[y, x] else "0000000\n")


# the identity: 720x480 filled (mode 3 with no display) on the progressive raster is the frame golden,
# bit for bit -- render's crop-aware identity chroma (hup over the crop's columns, vrow) against
# up_ident's whole frame. (Before issue #11 Fit filled the raster; Fit is now the anamorphic 16:9 fit,
# which pillarboxes 720x480, so the "fill the raster" cases below are 'fill'.)
_f = _fr.fit(45, 30, mode='fill')
_img, _de = render(*L, _f)
assert _de.all() and (_img == rgb(L[0], up_ident(L[1]), up_ident(L[2]))).all(), "the identity fit is not the frame golden"
# the fitted cases: (name, seed, W, H in MBs, crop (cuy4, l, r, t, b), sar, mode, il, at[, pal])
FIT = [("s",    11, 30, 17,  (0, 0, 0, 0, 0), (1, 1),   'fill',      False, False),   # 480x272 up, progressive
       ("t",    13, 45, 36,  (0, 0, 0, 0, 0), (1, 1),   'letterbox', True,  False),   # 720x576 pillarbox, 480i
       ("w",    17, 54, 30,  (0, 2, 3, 0, 0), (1, 1),   'letterbox', True,  False),   # 854x480 (cropped 4 + 6) letterbox
       ("wc",   17, 54, 30,  (0, 0, 5, 0, 0), (1, 1),   'crop',      True,  False),   # 854x480 Crop: the sides cut
       ("v",    19, 30, 54,  (0, 0, 0, 2, 3), (1, 1),   'letterbox', True,  False),   # 480x854 portrait (cropped 4 + 6)
       ("snap", 23, 44, 30,  (0, 0, 0, 0, 0), (10, 11), 'letterbox', True,  False),   # 704x480 10:11: 1:1, offset 8
       ("tall", 29, 12, 128, (0, 0, 0, 0, 0), (1, 1),   'letterbox', True,  False),   # 192x2048: dv 8, dh 2
       ("wide", 31, 128, 12, (0, 0, 0, 0, 0), (1, 1),   'fill',      False, False),   # 2048x192: dh 2 (the buffer)
       ("p640", 37, 40, 30,  (0, 0, 0, 0, 0), (1, 1),   'fill',      False, False),   # 640x480 stretched
       # anti-twitter (P6 step 4, docs/analog.md §9): 480i, sliding boxes
       ("at_id",   41, 45, 30,  (0, 0, 0, 0, 0), (1, 1), 'fill',      True, True),     # 720x480: the (1, 2, 1)
       ("at_w",    43, 54, 30,  (0, 2, 3, 0, 0), (1, 1), 'letterbox', True, True),     # 854x480 letterbox
       ("at_v",    47, 30, 54,  (0, 0, 0, 2, 3), (1, 1), 'letterbox', True, True),     # 480x854: the crop's top
       ("at_tall", 53, 12, 128, (0, 0, 0, 0, 0), (1, 1), 'letterbox', True, True),     # 192x2048: dv 4, 8-row boxes
       ("at_wide", 59, 128, 12, (0, 0, 0, 0, 0), (1, 1), 'letterbox', True, True),     # 2048x192: dv 2 (the W > 40 cap), dh 2
       ("at_up",   61, 22, 15,  (0, 0, 0, 0, 0), (1, 1), 'letterbox', True, True),     # 352x240 scaled up
       # Non-integer downsizing: de-flicker must follow output line spacing.
       ("scaled_720_off", 211, 60, 45, (0, 0, 0, 0, 0), (1, 1), 'fill', True, False, False, 'area'),
       ("scaled_720_on",  211, 60, 45, (0, 0, 0, 0, 0), (1, 1), 'fill', True, True,  False, 'area'),
       ("scaled_722_on",  223, 61, 46, (0, 0, 4, 0, 7), (1, 1), 'fill', True, True, False, 'area'),
       # the 576-line raster (P6 step 6, docs/analog.md §10)
       ("pal_w",   67, 54, 30,  (0, 0, 5, 0, 0), (1, 1),   'letterbox', False, False, True),  # 854x480 on 576p: 720x432
       ("pal_n",   71, 45, 36,  (0, 0, 0, 0, 0), (12, 11), 'letterbox', True,  False, True),  # 720x576 12:11: the snap, 576i
       ("pal_at",  73, 64, 23,  (0, 0, 0, 0, 8), (1, 1),   'letterbox', True,  True,  True),  # 1024x352 (cropped) 576i anti-twitter
       # The reported PAL scope geometry (1280x534 coded after crop) under the core's always-on
       # Area pre-filter: Off uses its computed vertical coefficient; On must override it with
       # the stronger sliding-row coefficient 4. Keep the source/seed identical for a differential.
       ("pal_1280x534_area",    191, 80, 34, (0, 0, 0, 0, 5), (1, 1), 'letterbox', True, False, True, 'area'),
       ("pal_1280x534_area_at", 191, 80, 34, (0, 0, 0, 0, 5), (1, 1), 'letterbox', True, True,  True, 'area'),
       # (0.11) 1280x720, 3,600 macroblocks: the 2 MiB store (Cb at word 115,200, past 2^17), dh 2
       ("hd",      97, 80, 45,  (0, 0, 0, 0, 0), (1, 1),   'fill',      False, False),        # 1280x720 filled, 480p: 640 stored
       ("hd_il",  101, 80, 45,  (0, 0, 0, 0, 0), (1, 1),   'letterbox', True,  False),        # letterboxed at 480i
       ("hd_at",  103, 80, 45,  (0, 0, 0, 0, 0), (1, 1),   'letterbox', True,  True),         # ... with anti-twitter
       ("hd_pal", 107, 80, 45,  (0, 0, 0, 0, 0), (1, 1),   'letterbox', True,  False, True),  # letterboxed at 576i
       # (docs/analog.md §11b) the Area pre-filter: (..., pal, flt) -- 'area' the core's, the cases above
       # without it the Sharp control (bit-identical to main)
       ("hd_area",    109, 80, 45,  (0, 0, 0, 0, 0), (1, 1), 'fill',      False, False, False, 'area'),    # 1,280 kept: A 3 / 2
       ("hd_il_area", 127, 80, 45,  (0, 0, 0, 0, 0), (1, 1), 'letterbox', True,  False, False, 'area'),    # 480i
       ("hd_at_area", 131, 80, 45,  (0, 0, 0, 0, 0), (1, 1), 'letterbox', True,  True,  False, 'area'),    # ... with anti-twitter
       ("w_area",     137, 54, 30,  (0, 2, 3, 0, 0), (1, 1), 'letterbox', True,  False, False, 'area'),    # 854x480 at 480i: A 1 / 1
       ("w_at_area",  139, 54, 30,  (0, 2, 3, 0, 0), (1, 1), 'letterbox', True,  True,  False, 'area'),    # ... anti-twitter the stronger
       ("p_area",     149, 54, 30,  (0, 0, 5, 0, 0), (1, 1), 'fill',      False, False, False, 'area'),    # horizontal only (rows 1:1)
       ("port_area",  151, 45, 80,  (0, 0, 0, 0, 0), (1, 1), 'letterbox', False, False, False, 'area'),    # 720x1280: dh 2 dv 2, W odd
       ("wide_area",  163, 128, 28, (0, 0, 0, 0, 0), (1, 1), 'letterbox', False, False, False, 'area'),    # 2048x448: past the budget
       ("tall_area",  167, 12, 128, (0, 0, 0, 0, 0), (1, 1), 'letterbox', True,  False, False, 'area'),    # 192x2048 dv 4
       ("pal_area",   173, 64, 36,  (0, 0, 0, 0, 0), (1, 1), 'letterbox', True,  False, True,  'area'),    # 1024x576 at 576i
       ("s_area",     11, 30, 17,   (0, 0, 0, 0, 0), (1, 1), 'fill',      False, False, False, 'area'),    # an upscale: Sharp's raster
       # (issue #11) Fit, the anamorphic 16:9 fit: the issue's 720x304 scope clip letterboxed to 720x360 at
       # 480i, and 640x480 pillarboxed to 540 at 480p
       ("fit_scope",  179, 45, 19,  (0, 0, 0, 0, 0), (1, 1), 'fit',       True,  False),
       ("fit_43",     181, 40, 30,  (0, 0, 0, 0, 0), (1, 1), 'fit',       False, False)]
# (hdmi_raster stage 2) the native raster: raster_geom's geometry for the picture on a 1920x1080
# display, the fit's identity on it -- (name, seed, W, H in MBs, crop, sar, std)
import raster_geom_ref as _rg
NAT = [("nat_scope", 79, 54, 23, (0, 0, 6, 0, 6), (640, 639), 0),   # 852x356 letterboxed in 852x480
       ("nat_43",    83, 40, 30, (0, 0, 0, 0, 0), (1, 1),     0),   # 640x480 pillarboxed in 853x480
       ("nat_pal",   89, 45, 36, (0, 0, 0, 0, 0), (16, 15),   2),   # 720x576 4:3 PAL: display-shaped 960x576 (hd_raster), 50 Hz
       ("nat_hd",    91, 80, 45, (0, 0, 0, 0, 0), (1, 1),     0),   # (hd_raster stage B) 1280x720 at its own pixels
       ("nat_w2k",   93, 128, 28, (0, 0, 0, 0, 0), (1, 1),    0)]   # ... the widest legal picture, 2048x448
# (docs/chroma.md) siting variants: the same picture and fit at another chroma_sample_loc_type
NAT_SIT = {"nat_hd_s1": ("nat_hd", 1), "nat_scope_s4": ("nat_scope", 4), "nat_pal_s2": ("nat_pal", 2)}
NAT += [(n,) + next(c for c in NAT if c[0] == b)[1:] for n, (b, _) in NAT_SIT.items()]
with open(os.path.join(out, "disp_nat_cases.txt"), "w") as nf:
    for name, seed, wm, hm, cr, sar, std in NAT:
        sit_t = NAT_SIT.get(name, (None, 0))[1]
        P = picture(seed, 16 * wm, 16 * hm)
        f0 = _fr.fit(wm, hm, cr, sar[0], sar[1], 'fit')
        g = _rg.geom(f0['wc'], f0['hc'], sar[0], sar[1], wm, 1920, 1080, std, 1)
        assert g['mode'] == _rg.MODE_NATIVE, (name, g)
        f = _fr.fit(wm, hm, cr, sar[0], sar[1], 'fit', False, False, std == 2, 0, 0, True, g['rw'], g['rh'])
        img, de = render(*P, f, sit=(sit_t, sit_t))
        write_store("disp_store_nat_%s.hex" % name, *P)
        write_want_de("disp_want_nat_%s.hex" % name, img, de)
        nf.write("%s %d %d %d %d %d %d %d %d %d %d  %d %d %d %d %d %d  %dx%d at (%d, %d)\n" % (
            name, wm, hm, cr[0], cr[1], cr[2], cr[3], cr[4], sar[0], sar[1], std,
            g['rw'], g['rh'], g['l'], g['nt'], g['last'], 9 * sit_t, f['ow'], f['oh'], f['ox0'], f['oy0']))
# (docs/chroma.md) siting variants of fitted cases: an upscale, a 1280x720 downscale, 480i, the Area filter
FIT_SIT = {"s_s1": ("s", 1), "hd_s5": ("hd", 5), "hd_il_s2": ("hd_il", 2), "w_area_s3": ("w_area", 3)}
FIT += [(n,) + next(c for c in FIT if c[0] == b)[1:] for n, (b, _) in FIT_SIT.items()]
fit_rasters = {}
with open(os.path.join(out, "disp_fit_cases.txt"), "w") as cf:
    for name, seed, wm, hm, cr, sar, mode, il, at, *rest in FIT:
        pal = bool(rest and rest[0])
        flt = rest[1] if len(rest) > 1 else 'sharp'
        sit_t = FIT_SIT.get(name, (None, 0))[1]
        P = picture(seed, 16 * wm, 16 * hm)
        f = _fr.fit(wm, hm, cr, sar[0], sar[1], mode, il, at, pal, flt=flt)
        lum = {}
        img, de = render(*P, f, lum, sit=(sit_t, sit_t))
        fit_rasters[name] = (img.copy(), de.copy(), f)
        write_store("disp_store_fit_%s.hex" % name, *P)
        write_want_de("disp_want_fit_%s.hex" % name, img, de)
        cf.write("%s %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d  %dx%d at (%d, %d) dh %d dv %d snap %d pf %d/%d\n" % (
            name, wm, hm, cr[0], cr[1], cr[2], cr[3], cr[4], sar[0], sar[1],
            ('letterbox', 'crop', 'fit', 'fill').index(mode), int(il), int(at), int(pal), _fr.FLT.index(flt), 9 * sit_t,
            f['ow'], f['oh'], f['ox0'], f['oy0'], f['dh'], f['dv'], int(f['snap']), f['hpf'], f['vpf']))
        if flt != 'sharp':
            check_filter(name, wm, hm, cr, sar, mode, il, at, pal, flt)
        for _t in (0, 5, 2):                      # hoff 0 / 1/2 / 0, voff 1/2 / 1 / 0: every offset each way
            check_chroma_ramp(name, 16 * wm, 16 * hm, f, (_t, _t))
        if name == "at_id":
            # the independent check: at the identity the sliding boxes ARE the (1, 2, 1) --
            # ffmpeg's `interlace` lowpass ((1 + a + 2b + d) >> 2) within one code (the design
            # rounds twice), on every line but the edges (the design clamps, ffmpeg mirrors)
            ref = blend([P[0]] * 3)[0]
            ours = np.array([lum[L] for L in range(1, 479)])
            dmax = int(np.abs(ours - ref[1:479]).max())
            assert dmax <= 1, "anti-twitter at the identity is %d codes from the (1, 2, 1)" % dmax
            print("disp_golden: anti-twitter at the identity within %d code of %s" % (
                dmax, "ffmpeg's interlace lowpass" if HAVE_FFMPEG else "the (1, 2, 1) formula (NO ffmpeg)"))
pal_off, pal_de, pal_off_fit = fit_rasters["pal_1280x534_area"]
pal_on, pal_on_de, pal_on_fit = fit_rasters["pal_1280x534_area_at"]
assert (pal_de == pal_on_de).all() and (pal_off_fit["vpf"] < 4) and (pal_on_fit["vpf"] == 4), \
    "PAL anti-twitter did not strengthen the Area pre-filter for 1280x534"
assert np.any(pal_off[pal_de] != pal_on[pal_on_de]), \
    "PAL anti-twitter and the Area-only control produced identical video pixels for 1280x534"
print("disp_golden: %d fitted rasters (the identity fit = the frame golden)" % len(FIT))

oracle = "ffmpeg separatefields + interlace lowpass" if HAVE_FFMPEG else \
    "numpy (NO ffmpeg: not an independent oracle)"
print("disp_golden: the 720x480 store; frame, field, blend, bob0/1 rasters (%s)" % oracle)
