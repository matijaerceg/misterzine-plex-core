#!/usr/bin/env python3
"""disp_fit_ref.py -- the display fit's arithmetic, written from docs/analog.md §5 (P6 step 3).

The reference the RTL (h264/disp_fit.sv) and its bench are scored against: every integer
the fit produces, computed the way the design text states it -- NOT from the RTL. The
geometry (the output rectangle) is also checked against ffmpeg's `scale` / `pad`, an
independent oracle (--check-ffmpeg).

    fit(w_mbs, hf_mbs, crop, sar_w, sar_h, mode, il) -> dict
      crop  = (cuy4, left, right, top, bottom)  frame_crop_*_offset + the vertical unit bit
      mode  = 'letterbox' | 'crop' | 'fit' | 'fill'
              (Analog Aspect; HDMI in Progressive with Analog Aspect Auto = 'fill': the raster
              filled (720 x RH), but A' when the picture is wider than the HDMI display --
              docs/hdmi_raster.md §3a. 'fit' (issue #11, docs/analog.md §5): the anamorphic 16:9
              fit -- Letterbox computed for a 16:9 display (a TV in its wide mode stretches the
              raster to 16:9), so a wider picture is letterboxed (oh = round(RH x 16 B / 9 A),
              normalised as A' is), a narrower one pillarboxed (ow = round(405 A / B)), 16:9 fills)
      dw, dh = (A') the HDMI display's shape, HDMI_WIDTH x HDMI_HEIGHT (0 = none: no A');
              used by 'fill' only
      nat, nw, nh = (stage 2, docs/hdmi_raster.md §3b) the native raster, nw x nh
              (h264/raster_geom.sv): the picture shown 1:1 -- ow, oh = Wc, Hc, steps 1.0, no
              snap -- centred on it: ox0 = (nw - Wc) >> 1, oy0 = (nh - Hc) >> 1. The mode is ignored
      il    = the 480i raster (no effect on the fit: the raster is 480 lines over its two
              fields, so the decimation follows sy as in Progressive -- a field takes
              alternate rows; softening for twitter is step 4's option, not a default)
      at    = anti-twitter applies to this picture (P6 step 4, docs/analog.md §9: the
              option, 480i, a frame store): the luma rows are SLIDING boxes of 2 dv source
              rows, the vertical position half a decimated row up (`slide`), and dv capped
              at 4, at 2 when W > 40 (the 480i line's fetch budget)
      pal   = the 576-line raster (P6 step 6, docs/analog.md §10): 720 dots = 4:3 at 576
              lines (a pixel 16:15), so the picture is Wc sar (15/16) raster pixels wide --
              576 for 480, oh = round(768 B / A) for round(640 B / A); 540 on both

    python3 tools/disp_fit_ref.py W H [--sar a:b] [--mode m] [--il] [--at] [--crop l,r,t,b[,cuy4]]
    python3 tools/disp_fit_ref.py --selftest
    python3 tools/disp_fit_ref.py --check-ffmpeg     # the rectangle vs ffmpeg scale/pad
    python3 tools/disp_fit_ref.py --vectors N FILE   # random cases for the RTL bench
"""
import argparse, os, random, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import raster_geom_ref  # noqa: E402

RW, RH = 720, 480            # the raster: 720 dots = 4:3 (a pixel 8:9)
Q = 16                       # steps and positions in Q.16


def pow2floor(v_q, cap):
    """the largest power of two <= v (Q.16), at least 1, at most cap"""
    d = 1
    while d * 2 <= cap and (d * 2) << Q <= v_q:
        d *= 2
    return d


def rdiv(n, d):
    """round(n / d) for n >= 0, d > 0: floor((2n + d) / 2d)"""
    return (2 * n + d) // (2 * d)


# (docs/analog.md §11b; decided 2026-10-05: Area always) the fit's pre-filter: 'area' is the core's
# (emu ties disp_fit's `area` high); 'sharp' (no pre-filter, the dh >= 2 floor past 1,024 columns) is
# the fit before it, kept as the benches' control -- bit-identical to main's
FLT = ('sharp', 'area')


def pf_weights(c):
    """a pre-filter code A (0..4) -> (w0, w1, w2) in eighths: (8 - A, A, 0) (docs/analog.md §11b)"""
    return (8 - c, c, 0)


def pf_shift(c):
    """the code's centre offset S (eighths of a decimated sample): w1 + 2 w2"""
    w0, w1, w2 = pf_weights(c)
    return w1 + 2 * w2


def pf_extra(c):
    """the boxes past the first: the taps clamp that many short of the crop's last (nb - 1)"""
    w0, w1, w2 = pf_weights(c)
    return (w1 > 0) + (w2 > 0)


def pf_code(r_q, flt):
    """the pre-filter for one axis from its residual step r (Q.16): none at r <= 1 (an upscale, the
    identity) or under the Sharp control; else A = clamp(floor(4 r - 4 + 1/2), 0, 4)"""
    if r_q <= (1 << Q) or flt == 'sharp':
        return 0
    return min(4, max(0, (4 * r_q - (4 << Q) + (1 << (Q - 1))) >> Q))


def fit(w_mbs, hf_mbs, crop=(0, 0, 0, 0, 0), sar_w=1, sar_h=1, mode='letterbox', il=False, at=False, pal=False,
        dw=0, dh=0, nat=False, nw=720, nh=480, flt='sharp'):
    RH = 576 if pal else 480                          # the raster's lines
    KH = 768 if pal else 640                          # 720 x 3/4 x (the raster pixel's height : width)
    cuy4, left, right, top, bottom = crop
    cw, ch = 16 * w_mbs, 16 * hf_mbs                  # coded size
    uy = 4 if cuy4 else 2
    wc, hc = cw - 2 * (left + right), ch - uy * (top + bottom)
    crop_bad = wc <= 0 or hc <= 0
    if crop_bad:                                      # ignored and flagged: the coded picture whole
        left = right = top = bottom = 0
        wc, hc = cw, ch
    lx, ty = 2 * left, uy * top                       # the crop's origin, in samples / rows
    if sar_w == 0 or sar_h == 0:
        sar_w = sar_h = 1
    wide = 3 * wc * sar_w >= 4 * hc * sar_h           # at least as wide as 4:3 in display
    lb = False
    if nat:
        ow, oh = wc, hc
    elif mode == 'fill' and dw and dh and wc * sar_w * dh > hc * sar_h * dw:
        # A' (docs/hdmi_raster.md §3a): wider than the display -- the picture fills the raster's
        # width, letterboxed so the whole raster shows at the display's shape:
        # oh = round(RH B dw / (A dh)), B dw and A dh shifted down together until A dh fits 28
        # bits (the divider's divisor is 2 A dh: 29 bits), the ratio kept to 1 part in 2^27
        lb = True
        p, q = hc * sar_h * dw, wc * sar_w * dh
        sh = max(0, q.bit_length() - 28)
        p, q = p >> sh, q >> sh
        ow, oh = RW, rdiv(RH * p, q)
    elif mode == 'fit' and 9 * wc * sar_w > 16 * hc * sar_h:
        # (issue #11) Fit, wider than 16:9: the width filled, letterboxed for the 16:9 the TV shows
        # the raster at -- A''s quotient with a 16 x 9 display: oh = round(RH P / Q), P = 16 B and
        # Q = 9 A shifted down together until Q fits 28 bits (P < Q: it fits too)
        p, q = 16 * hc * sar_h, 9 * wc * sar_w
        sh = max(0, q.bit_length() - 28)
        p, q = p >> sh, q >> sh
        ow, oh = RW, rdiv(RH * p, q)
    elif mode == 'fit':
        # (issue #11) Fit, 16:9 or narrower: the height filled, pillarboxed -- 720 x 9/16 = 405 for
        # the Letterbox rule's 540 (720 x 3/4); 16:9 itself fills the raster (both branches agree)
        ow, oh = rdiv(405 * wc * sar_w, hc * sar_h), RH
    elif mode == 'fill':
        ow, oh = RW, RH
    elif (mode == 'letterbox') == wide:               # letterbox & wide, or crop & narrow
        ow, oh = RW, rdiv(KH * hc * sar_h, wc * sar_w)
    else:
        ow, oh = rdiv(540 * wc * sar_w, hc * sar_h), RH
    # Crop under an absurd SAR can ask for a rectangle of millions of pixels: clamped at
    # 8,191 (13 bits) and flagged -- the picture then shows less zoomed, visibly
    clamp = ow > 8191 or oh > 8191
    ow, oh = min(max(ow, 2), 8191), min(max(oh, 2), 8191)
    # the native snap: within 3.5 % of the picture's own size on both axes (BT.601's 10:11
    # against the raster's 8:9 is 2 %), shown 1:1 -- a 480 -> 469 rescale softens every
    # line to correct a geometry error overscan hides
    snap = not nat and mode in ('letterbox', 'crop', 'fit') and 1000 * abs(ow - wc) <= 35 * wc and 1000 * abs(oh - hc) <= 35 * hc
    if snap:
        ow, oh = wc, hc
    # A': the vertical alone snaps (the width is the raster's, resampled anyway): a letterbox
    # height within 3.5 % of the picture's own is shown 1:1 -- no vertical resample -- if the
    # picture fits the raster's lines
    if lb and hc <= RH and 1000 * abs(oh - hc) <= 35 * hc:
        oh, snap = hc, True
    ox0, oy0 = ((nw if nat else RW) - ow) >> 1, ((nh if nat else RH) - oh) >> 1   # arithmetic: negative under Crop
    sx = (wc << Q) // ow
    sy = (hc << Q) // oh
    dh = pow2floor(sx, 8)
    if cw > 1024 and not nat and flt == 'sharp':
        dh = max(dh, 2)                               # the stored line <= 1,024 samples (fitted; the native
                                                      # line holds 2,048 since hd_raster stage B; §11b: the
                                                      # Area / Smooth filters keep every column)
    if at:
        # a line fetches two sliding boxes: 2 dv luma rows + dv of each chroma plane, each
        # ~ dv (12 W + 320) clk_mem cycles of the 480i line's 5,720 (docs/analog.md §9)
        # Nearest supported source-line spacing; ties choose the wider filter.
        choices = (1, 2) if w_mbs > 40 else (1, 2, 4)
        dv = min(choices, key=lambda d: (abs((d << Q) - sy), -d))
    else:
        dv = pow2floor(sy, 4 if w_mbs > 80 else 8)
    # (§11b) the pre-filters on the decimated grid: from the residual steps; vertically anti-twitter's
    # (4, 4, 0) where it applies (the stronger: A <= 4); then the fetch budget -- a stored row of two
    # boxes costs ~ dv (6 W + 180) clk_mem cycles (luma 2 dv rows of 2W words, chroma 2 dv rows of W,
    # ~45 a row's latency) and a 480p line (2,860) fetches up to two: 2 dv <= 8 and that <= 1,300,
    # else one box (A = 0); anti-twitter keeps its two (its own dv caps, on the 480i line's double time)
    hpf = pf_code(sx // dh, flt)
    vpf = pf_code(sy // dv, flt)
    if at:
        vpf = 4
    fits2 = 2 * dv <= 8 and dv * (w_mbs * 6 + 180) <= 1300
    if vpf and not fits2 and not at:
        vpf = 0
    return dict(wc=wc, hc=hc, lx=lx, ty=ty, crop_bad=crop_bad, wide=wide, snap=snap, clamp=clamp, lb=lb,
                ow=ow, oh=oh, ox0=ox0, oy0=oy0, sx=sx, sy=sy, dh=dh, dv=dv,
                wd=cw // dh, slide=bool(at), rh=nh if nat else RH, rw=nw if nat else RW,
                flt=flt, hpf=hpf, vpf=vpf, il=bool(il))


def src_pos(f, j, axis):
    """output pixel / frame line j of the rectangle -> the decimated source position (Q.16)
    and the two taps (clamped to the cropped region) and the blend weight (8 bits).
    Vertically under anti-twitter (f['slide']): decimated row k is the box of source rows
    [k d, k d + 2 d), centred at k + 1/2, so the position is half a row up -- the offset
    (2 d - 1) / 2 instead of (d - 1) / 2 -- and the last box inside the crop is kmax - 1"""
    step, d, org, size = (f['sx'], f['dh'], f['lx'], f['wc']) if axis == 'x' else \
                         (f['sy'], f['dv'], f['ty'], f['hc'])
    # (§11b) the pre-filtered sample k is centred at k + S / 8: the position S / 8 of a decimated
    # sample up (anti-twitter's sliding rows are S = 4: the old (2 d - 1) / 2); the last sample
    # whose boxes lie inside the crop is kmax - (nb - 1)
    c = f.get('hpf' if axis == 'x' else 'vpf', 0)
    pos = (org << Q) + j * step + (step >> 1) - (1 << (Q - 1))
    u = (pos - ((d - 1) << (Q - 1)) - ((d * pf_shift(c)) << (Q - 3))) // d   # floor: // floors negatives
    kmin, kmax = org // d, (org + size - 1) // d - pf_extra(c)
    k = u >> Q
    w8 = (u >> (Q - 8)) & 0xFF
    k0 = min(max(k, kmin), kmax)
    k1 = min(max(k + 1, kmin), kmax)
    if k < kmin:
        w8 = 0
    return k0, k1, w8


def selftest():
    # 720x480 square pixels, Letterbox: 720x480 is 3:2, wider than 4:3 -> 720 wide, 427 tall
    f = fit(45, 30)
    assert (f['ow'], f['oh']) == (720, 427), f
    # BT.601 720x480 at 10:11: within 3.5 % -> shown 1:1 (the snap), not 480 -> 469
    f = fit(45, 30, sar_w=10, sar_h=11)
    assert f['snap'] and (f['ow'], f['oh'], f['sx'], f['sy']) == (720, 480, 1 << Q, 1 << Q), f
    # the same picture with SAR 8:9 fills the raster exactly (720 dots = 4:3 by definition)
    f = fit(45, 30, sar_w=8, sar_h=9)
    assert (f['ow'], f['oh'], f['sx'], f['sy'], f['dh'], f['dv']) == (720, 480, 1 << Q, 1 << Q, 1, 1), f
    # 854x480 (coded 864, right 5 crop units): 16:9 on 4:3 -> 720 x 360, centred
    f = fit(54, 30, crop=(0, 0, 5, 0, 0))
    assert f['wc'] == 854 and (f['ow'], f['oh'], f['oy0']) == (720, 360, 60), f
    # portrait 480x854 (coded 480x864): pillarbox, 480 tall
    f = fit(30, 54, crop=(0, 0, 0, 0, 5))
    assert f['hc'] == 854 and f['oh'] == 480 and f['ow'] == rdiv(540 * 480, 854), f
    assert f['dv'] == 1 and fit(30, 54, crop=(0, 0, 0, 0, 5), il=True)['dv'] == 1
    # the spec's extreme side: 12 x 128 macroblocks (192 x 2048: 1,536 <= 1,620), 480i
    f = fit(12, 128, il=True)
    assert f['oh'] == 480 and f['dv'] == 4 and f['dh'] == 2, f
    # (0.11) 1280x720, 3,600 macroblocks: filled at 480p stores 640 (dh 2: the line <= 1,024) and
    # steps 1.5 rows (dv 1); letterboxed at 480i 720x405 -> the vertical step 1.78 (dv 1)
    f = fit(80, 45, mode='fill')
    assert (f['ow'], f['oh'], f['dh'], f['dv']) == (720, 480, 2, 1), f
    f = fit(80, 45, il=True)
    assert f['ow'] == 720 and f['dh'] == 2, f
    # 704x480 at 10:11 on 480i: the snap, and NO vertical decimation (every line of each field)
    f = fit(44, 30, sar_w=10, sar_h=11, il=True)
    assert f['snap'] and f['dv'] == 1 and f['ox0'] == 8, f
    # 2048 wide: the stored line within 1,024 samples
    f = fit(128, 12)
    assert f['dh'] == 2 and f['wd'] == 1024, f
    # a crop leaving nothing: ignored, flagged
    f = fit(45, 30, crop=(0, 400, 400, 0, 0))
    assert f['crop_bad'] and f['wc'] == 720, f
    # Crop mode: 16:9 fills the height, the width cut
    f = fit(54, 30, crop=(0, 0, 5, 0, 0), mode='crop')
    assert f['oh'] == 480 and f['ow'] > 720 and f['ox0'] < 0, f
    # identity positions: 720x480 at 8:9 -> source x = j exactly, weight 0
    f = fit(45, 30, sar_w=8, sar_h=9)
    assert all(src_pos(f, j, 'x') == (j, min(j + 1, 719), 0) for j in range(720))
    # anti-twitter at the identity (720x480 filled): line L's taps are rows L - 1 and L of the
    # sliding boxes, weight 1/2 -- the (1, 2, 1); the first line clamps to box 0
    f = fit(45, 30, mode='fill', il=True, at=True)
    assert f['slide'] and f['dv'] == 1
    assert src_pos(f, 0, 'y') == (0, 0, 0) and src_pos(f, 1, 'y') == (0, 1, 128), src_pos(f, 1, 'y')
    assert all(src_pos(f, L, 'y') == (L - 1, L, 128) for L in range(1, 479))
    assert src_pos(f, 479, 'y') == (478, 478, 128)      # box 478 = rows 478, 479: the last inside
    # the fetch cap: 192x2048 keeps dv 4 (W 12); 2048x192 at an absurd SAR stays within dv 2
    assert fit(12, 128, il=True, at=True)['dv'] == 4
    assert fit(128, 12, sar_w=40, sar_h=1, il=True, at=True)["dv"] == 2
    assert fit(128, 12, sar_w=40, sar_h=1, il=True)["dv"] == 4
    # the 576-line raster: 720x576 at 12:11 (BT.601 PAL, 704 = 4:3) snaps 1:1; 16:9 1024x576
    # letterboxes to 720 x 432 (768 x 576 / 1024 ... = 3/4 of the height), centred at 72
    f = fit(45, 36, sar_w=12, sar_h=11, pal=True)
    assert f['snap'] and (f['ow'], f['oh'], f['oy0']) == (720, 576, 0), f
    f = fit(64, 36, pal=True)
    assert (f['ow'], f['oh'], f['oy0']) == (720, 432, 72), f
    assert fit(64, 36, mode='fit', pal=True)['oh'] == 576
    # a 720x480 picture (3:2) on it: 720 x 512 (the 480-line raster's 427 x 6/5)
    assert fit(45, 30, pal=True)['oh'] == 512
    # A' (docs/hdmi_raster.md §3a): a 2.39:1 852x356 transcode (SAR 640:639) on 1920x1080 --
    # letterboxed at 356 lines exactly, centred (62 above)
    f = fit(54, 23, crop=(0, 0, 6, 0, 6), sar_w=640, sar_h=639, mode='fill', dw=1920, dh=1080)
    assert (f['wc'], f['hc']) == (852, 356) and f['lb'] and (f['ow'], f['oh'], f['oy0']) == (720, 356, 62), f
    # ... on 1280x1024 (5:4): 250 lines, no snap
    f = fit(54, 23, crop=(0, 0, 6, 0, 6), sar_w=640, sar_h=639, mode='fill', dw=1280, dh=1024)
    assert f['lb'] and not f['snap'] and f['oh'] == 250, f
    # exactly the display's shape (1024x576 on 1920x1080) is not wider: filled, no A'
    f = fit(64, 36, mode='fill', dw=1920, dh=1080)
    assert not f['lb'] and (f['ow'], f['oh']) == (720, 480), f
    # 854x480 square is a hair wider than 16:9: A', 479.6 -> 480, snapped (the vertical 1:1)
    f = fit(54, 30, crop=(0, 0, 5, 0, 0), mode='fill', dw=1920, dh=1080)
    assert f['lb'] and f['snap'] and f['oh'] == 480, f
    # 16:9 on a 4:3 display: a real letterbox, 360 lines (no snap)
    f = fit(54, 30, crop=(0, 0, 5, 0, 0), mode='fill', dw=1024, dh=768)
    assert f['lb'] and not f['snap'] and (f['oh'], f['oy0']) == (360, 60), f
    # no display (direct_video): Fit; 4:3 on 16:9: Fit
    assert not fit(54, 30, mode='fill')['lb'] and fit(54, 30, mode='fill')['oh'] == 480
    assert not fit(40, 30, mode='fill', dw=1920, dh=1080)['lb']
    # the 576-line raster: 2.39:1 on 16:9 -> 576 x 356 / 480 = 427
    f = fit(54, 23, crop=(0, 0, 6, 0, 6), sar_w=640, sar_h=639, mode='fill', pal=True, dw=1920, dh=1080)
    assert f['lb'] and f['oh'] == 427 and f['oy0'] == 74, f
    # the native raster (stage 2): 852x356 on raster_geom's 852x480 -- 1:1, 62 lines down
    f = fit(54, 23, crop=(0, 0, 6, 0, 6), sar_w=640, sar_h=639, mode='fit', nat=True, nw=852, nh=480)
    assert (f['ow'], f['oh'], f['ox0'], f['oy0'], f['sx'], f['sy'], f['dh'], f['dv'], f['snap']) == \
        (852, 356, 0, 62, 1 << Q, 1 << Q, 1, 1, False), f
    f = fit(40, 30, mode='letterbox', nat=True, nw=853, nh=480)                   # 640x480 pillarboxed
    assert (f['ow'], f['ox0'], f['oy0'], f['snap']) == (640, 106, 0, False), f
    # (hd_raster stage B) 1280x720 native: 1:1, NOT decimated (the native line holds 2,048 samples)
    f = fit(80, 45, mode='fit', nat=True, nw=1280, nh=720)
    assert (f['ow'], f['oh'], f['ox0'], f['oy0'], f['dh'], f['dv'], f['wd']) == (1280, 720, 0, 0, 1, 1, 1280), f
    f = fit(128, 28, mode='fit', nat=True, nw=2048, nh=448)                   # the widest legal picture
    assert (f['ow'], f['dh'], f['wd']) == (2048, 1, 2048), f
    # (§11b) the Area pre-filter. 1280x720 filled at 480p: the Sharp control keeps the floor (dh 2, 640
    # stored); Area keeps 1,280 columns: r 1.78 -> A 3, rows r 1.5 -> A 2
    f = fit(80, 45, mode='fill')
    assert (f['dh'], f['hpf'], f['vpf']) == (2, 0, 0), f
    f = fit(80, 45, mode='fill', flt='area')
    assert (f['dh'], f['dv'], f['hpf'], f['vpf'], f['wd']) == (1, 1, 3, 2, 1280), f
    # an upscale (480x272 filled) and the identity: no pre-filter; native never
    for flt in FLT:
        assert (fit(30, 17, mode='fill', flt=flt)['hpf'], fit(30, 17, mode='fill', flt=flt)['vpf']) == (0, 0)
        assert fit(45, 30, sar_w=8, sar_h=9, flt=flt)['hpf'] == 0
        g = fit(80, 45, mode='fit', nat=True, nw=1280, nh=720, flt=flt)
        assert (g['hpf'], g['vpf'], g['dh']) == (0, 0, 1), g
    # 720x1280 portrait letterboxed: dh 2 (r 1.18 -> A 1), dv 2 (r 1.33 -> A 1)
    f = fit(45, 80, flt='area')
    assert (f['ow'], f['dh'], f['dv'], f['hpf'], f['vpf']) == (304, 2, 2, 1, 1), f
    # 2048x448 letterboxed (W 128, dv 2): past the budget for two boxes (2 x 948 cycles) -> none, so
    # the rows stay one box (found by run_disp_reader's wide_sm: rows late at 480p); horizontal kept
    f = fit(128, 28, flt='area')
    assert (f['dv'], f['vpf'], f['hpf']) == (2, 0, 2), f
    # ... at 480i with anti-twitter its own (4, 4, 0) stays (the field line's double time)
    assert fit(128, 28, il=True, at=True, flt='area')['vpf'] == 4
    # anti-twitter is (4, 4, 0) under Area too (A <= 4)
    assert fit(54, 30, crop=(0, 0, 5, 0, 0), il=True, at=True, flt='area')['vpf'] == 4
    # the positions: the last tap one short of the crop (A > 0)
    f = fit(80, 45, mode='fill', flt='area')
    k0, k1, w = src_pos(f, 719, 'x')
    assert k1 <= 1279 - 1 and src_pos(f, 0, 'x')[0] == 0, (k0, k1, w)
    # (issue #11) Fit, the anamorphic 16:9 fit. The issue's 720x304 scope clip (2.37:1): letterboxed
    # to 720 x 360 (480 x 16/9 / 2.37), 60 lines down; on the 576-line raster 432
    f = fit(45, 19, mode='fit')
    assert (f['ow'], f['oh'], f['ox0'], f['oy0'], f['lb'], f['snap']) == (720, 360, 0, 60, False, False), f
    assert fit(45, 19, mode='fit', pal=True)['oh'] == 432
    # 640x480 (4:3) pillarboxed to 540 (720 x 3/4), 90 columns in; 848x480 (a hair narrower than
    # 16:9) 716; 1024x576 and 1280x720 (exactly 16:9) fill the raster, as before
    f = fit(40, 30, mode='fit')
    assert (f['ow'], f['oh'], f['ox0'], f['oy0']) == (540, 480, 90, 0), f
    assert (fit(53, 30, mode='fit')['ow'], fit(53, 30, mode='fit')['oh']) == (716, 480)
    for wm, hm in ((64, 36), (80, 45)):
        for pal in (False, True):
            g = fit(wm, hm, mode='fit', pal=pal)
            assert (g['ow'], g['oh'], g['ox0'], g['oy0']) == (720, 576 if pal else 480, 0, 0), g
    # an anamorphic 16:9 DVD-class picture (704x480 at 40:33) lands within 3.5 %: shown 1:1
    f = fit(44, 30, sar_w=40, sar_h=33, mode='fit')
    assert f['snap'] and (f['ow'], f['oh'], f['ox0']) == (704, 480, 8), f
    # portrait (480x854) pillarboxed to 405 x 480 / 854 x 480 / 480 -> 128 columns
    f = fit(30, 54, crop=(0, 0, 0, 0, 5), mode='fit')
    assert (f['ow'], f['oh']) == (rdiv(405 * 480, 854), 480), f
    # 'fill' with no display is the raster filled whatever the shape (the benches' identity)
    assert (fit(40, 30, mode='fill')['ow'], fit(45, 19, mode='fill')['oh']) == (720, 480)
    print("disp_fit_ref selftest: PASS")


def check_ffmpeg():
    """the rectangle against ffmpeg's scale (force_original_aspect_ratio) + pad, on the
    raster's own pixel aspect: ffmpeg works in square pixels, so the raster is 640x480
    square (720 dots = 4:3) and the widths are compared after x 8/9 -- and (P6 step 6) the
    576-line raster as 768x576 square, the widths compared after x 16/15. Fit (issue #11) on the 16:9
    the wide-mode TV shows the raster at: 854x480 / 1024x576 square, the widths after x 854/720 /
    1024/720 (854 is 16:9 to 0.06 %: under half a pixel at 720)"""
    cases = [(640, 480), (720, 480), (854, 480), (720, 404), (352, 240), (480, 854),
             (192, 2048), (2048, 192), (1024, 576), (480, 480), (320, 1600), (720, 304)]
    bad = 0
    for (w, h), pal in [(c, False) for c in cases] + [(c, True) for c in cases + [(720, 576), (1024, 576)]]:
        for mode, far in (('letterbox', 'decrease'), ('crop', 'increase'), ('fit', 'decrease')):
            wm, hm = (w + 15) // 16, (h + 15) // 16
            f = fit(wm, hm, crop=(0, 0, (16 * wm - w) // 2, 0, (16 * hm - h) // 2), mode=mode, pal=pal)
            sq_w, sq_h = ((1024, 576) if pal else (854, 480)) if mode == 'fit' else ((768, 576) if pal else (640, 480))
            r = subprocess.run(
                ['ffprobe', '-v', 'error', '-f', 'lavfi', '-i',
                 'color=black:size=%dx%d,scale=%d:%d:force_original_aspect_ratio=%s' % (w, h, sq_w, sq_h, far),
                 '-show_entries', 'stream=width,height', '-of', 'csv=p=0'], capture_output=True, text=True)
            try:
                fw, fh = (int(v) for v in r.stdout.strip().split(','))
            except ValueError:
                print("  ffprobe gave no size for %dx%d %s: %s" % (w, h, mode, r.stderr.strip())); bad += 1; continue
            ow_sq = f['ow'] * sq_w / 720 if mode == 'fit' else \
                f['ow'] * (16 / 15 if pal else 8 / 9)        # the fit's width in square pixels
            ok = abs(ow_sq - fw) <= 1.5 and abs(f['oh'] - fh) <= 1
            print("  %-4s %4dx%-4d %-9s %s fit %4d(%6.1f sq) x %-4d  ffmpeg %4d x %-4d" %
                  ('ok' if ok else 'BAD', w, h, mode, '576' if pal else '480', f['ow'], ow_sq, f['oh'], fw, fh))
            bad += not ok
    print("disp_fit_ref ffmpeg check: %s" % ("PASS" if bad == 0 else "FAIL (%d)" % bad))
    return bad == 0


def vectors(n, path, seed=1):
    """random + edge cases for the RTL bench: one line a case, hex fields"""
    rnd = random.Random(seed)
    cases = [(45, 30, (0, 0, 0, 0, 0), 1, 1), (45, 30, (0, 0, 0, 0, 0), 8, 9),
             (54, 30, (0, 0, 5, 0, 0), 1, 1), (30, 54, (0, 0, 0, 0, 5), 1, 1),
             (12, 128, (0, 0, 0, 0, 0), 1, 1), (128, 12, (0, 0, 0, 0, 0), 1, 1),
             (45, 30, (0, 400, 400, 0, 0), 1, 1), (45, 30, (0, 0, 0, 0, 0), 255, 1),
             (45, 30, (0, 0, 0, 0, 0), 1, 255), (45, 30, (1, 0, 0, 2, 2), 10, 11),
             (45, 30, (0, 0, 0, 0, 0), 65535, 1), (45, 30, (0, 0, 0, 0, 0), 1, 65535),
             (1, 1, (0, 0, 0, 0, 0), 1, 1), (128, 128, (0, 0, 0, 0, 0), 1, 1),
             # anti-twitter's caps (P6 step 4): W <= 40 with a step of 8+ (dv 8 -> 4), W > 40 (-> 2)
             (20, 30, (0, 0, 0, 0, 0), 255, 1), (8, 8, (0, 0, 0, 0, 0), 65535, 1),
             (40, 40, (0, 0, 0, 0, 0), 300, 1), (41, 30, (0, 0, 0, 0, 0), 255, 1),
             # A' (docs/hdmi_raster.md): scope 852x356 at 640:639, exactly 16:9 (not wider),
             # 854x480 (a hair wider: the snap), 2:1
             (54, 23, (0, 0, 6, 0, 6), 640, 639), (64, 36, (0, 0, 0, 0, 0), 1, 1),
             (54, 30, (0, 0, 5, 0, 0), 1, 1), (60, 30, (0, 0, 0, 0, 0), 1, 1),
             # (§11b) the filter: 1280x720 (the floor), 720x1280, 2048x448 and 192x2048 (the budget)
             (80, 45, (0, 0, 0, 0, 0), 1, 1), (45, 80, (0, 0, 0, 0, 0), 1, 1),
             (128, 28, (0, 0, 0, 0, 0), 1, 1), (12, 128, (0, 0, 0, 0, 0), 1, 1),
             # (issue #11) Fit: the 720x304 scope clip, 640x480, 848x480 (a hair narrower than 16:9),
             # 704x480 at 40:33 (exactly 16:9: the snap), 1024x576 at 1:1 (exactly 16:9: filled)
             (45, 19, (0, 0, 0, 0, 0), 1, 1), (40, 30, (0, 0, 0, 0, 0), 1, 1),
             (53, 30, (0, 0, 0, 0, 0), 1, 1), (44, 30, (0, 0, 0, 0, 0), 40, 33)]
    displays = [(1920, 1080), (1280, 720), (1024, 768), (0, 0), (1280, 1024), (720, 480),
                (3840, 2160), (1366, 768), (2560, 1080), (640, 480), (0, 1080), (4095, 1)]
    while len(cases) < n:
        w = rnd.randint(1, 128)
        h = rnd.randint(1, max(1, min(128, 3600 // w)))   # 0.11: pictures to 3,600 macroblocks
        cuy4 = rnd.randint(0, 1)
        cr = (cuy4, rnd.randint(0, 8 * w), rnd.randint(0, 8 * w), rnd.randint(0, 4 * h), rnd.randint(0, 4 * h)) \
            if rnd.random() < 0.5 else (0, 0, 0, 0, 0)
        sar = rnd.choice([(1, 1), (10, 11), (40, 33), (16, 11), (4, 3), (8, 9)]) if rnd.random() < 0.8 else \
            (rnd.randint(1, 65535), rnd.randint(1, 65535))
        cases.append((w, h, cr, sar[0], sar[1]))
    nnat = [0]
    with open(path, 'w') as fh:
        for ci, (w, h, cr, sw, sh) in enumerate(cases):
            # (stage 2) the native raster for this picture, when raster_geom gives one
            rf = fit(w, h, cr, sw, sh, 'fit')
            g = raster_geom_ref.geom(rf['wc'], rf['hc'], sw, sh, w, 1920, 1080, ci % 3, 1)
            if g['mode'] == raster_geom_ref.MODE_NATIVE:
                f = fit(w, h, cr, sw, sh, 'fit', False, False, ci % 3 == 2, 0, 0, True, g['rw'], g['rh'], FLT[ci % 2])
                fh.write('%02x %02x %x %03x %03x %03x %03x %04x %04x %x %x %x %x %03x %03x %x %03x %03x  %03x %03x %04x %04x %08x %08x %x %x %02x %03x %03x %03x %03x  %x %x %x\n' % (
                    w, h, cr[0], cr[1], cr[2], cr[3], cr[4], sw, sh, 2, 0, 0, int(ci % 3 == 2), 0, 0, 1, g['rw'], g['rh'],
                    f['ow'], f['oh'], f['ox0'] & 0xFFFF, f['oy0'] & 0xFFFF, f['sx'], f['sy'],
                    f['dh'], f['dv'], int(f['crop_bad']) | (int(f['snap']) << 1) | (int(f['clamp']) << 2)
                    | (int(f['slide']) << 3) | (int(f['lb']) << 4),
                    f['wc'], f['hc'], f['lx'], f['ty'], ci % 2, f['hpf'], f['vpf']))
                nnat[0] += 1
            for mi, mode in enumerate(('letterbox', 'crop', 'fit', 'fill')):
                for ri, (il, at, pal) in enumerate(((0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 0, 1), (1, 1, 1))):
                    # the display: drives every mode (only 'fill' may use it); random past the list
                    # (every case meets a 1920x1080 display once in Fill: the exact-16:9 edge)
                    dw, dhh = (1920, 1080) if (mode == 'fill' and ri == 0) else \
                        displays[(ci * 5 + ri) % len(displays)] if rnd.random() < 0.7 else \
                        (rnd.randint(0, 4095), rnd.randint(0, 4095))
                    for fi, flt in enumerate(FLT):    # (§11b) every case under Area and the Sharp control
                        f = fit(w, h, cr, sw, sh, mode, bool(il), bool(at), bool(pal), dw, dhh, flt=flt)
                        fh.write('%02x %02x %x %03x %03x %03x %03x %04x %04x %x %x %x %x %03x %03x %x %03x %03x  %03x %03x %04x %04x %08x %08x %x %x %02x %03x %03x %03x %03x  %x %x %x\n' % (
                            w, h, cr[0], cr[1], cr[2], cr[3], cr[4], sw, sh, mi, il, at, pal, dw, dhh, 0, 0, 0,
                            f['ow'], f['oh'], f['ox0'] & 0xFFFF, f['oy0'] & 0xFFFF, f['sx'], f['sy'],
                            f['dh'], f['dv'], int(f['crop_bad']) | (int(f['snap']) << 1) | (int(f['clamp']) << 2)
                            | (int(f['slide']) << 3) | (int(f['lb']) << 4),
                            f['wc'], f['hc'], f['lx'], f['ty'], fi, f['hpf'], f['vpf']))
    print("wrote %d vectors to %s (%d on a native raster)" % (len(cases) * 40 + nnat[0], path, nnat[0]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('w', nargs='?', type=int); ap.add_argument('h', nargs='?', type=int)
    ap.add_argument('--sar', default='1:1'); ap.add_argument('--mode', default='letterbox')
    ap.add_argument('--il', action='store_true'); ap.add_argument('--at', action='store_true')
    ap.add_argument('--pal', action='store_true')
    ap.add_argument('--display', default='0x0', help="A': the HDMI display, WxH (mode fill)")
    ap.add_argument('--crop', default='0,0,0,0')
    ap.add_argument('--selftest', action='store_true'); ap.add_argument('--check-ffmpeg', action='store_true')
    ap.add_argument('--vectors', nargs=2)
    a = ap.parse_args()
    if a.selftest:
        selftest(); return 0
    if a.check_ffmpeg:
        return 0 if check_ffmpeg() else 1
    if a.vectors:
        vectors(int(a.vectors[0]), a.vectors[1]); return 0
    c = [int(v) for v in a.crop.split(',')]
    crop = (c[4] if len(c) > 4 else 0, c[0], c[1], c[2], c[3])
    sw, sh = (int(v) for v in a.sar.split(':'))
    wm, hm = (a.w + 15) // 16, (a.h + 15) // 16
    dw, dhh = (int(v) for v in a.display.split('x'))
    print(fit(wm, hm, crop, sw, sh, a.mode, a.il, a.at, a.pal, dw, dhh))
    return 0


if __name__ == '__main__':
    sys.exit(main())
