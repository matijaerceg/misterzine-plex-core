#!/usr/bin/env python3
"""raster_geom_ref.py -- the native raster's geometry, written from docs/hdmi_raster.md §3b / §4
(stage 2) and docs/hd_raster.md §4 / §5 (hd_raster stage B: the native raster on the 81 MHz dot, up
to 2,048 x 2,048), NOT from the RTL. h264/raster_geom.sv and its bench are scored against it.

    geom(wc, hc, sar_w, sar_h, w_mbs, dw, dh, std, req) -> dict

  wc, hc      the shown picture's cropped size (disp_fit's wc / hc)
  sar_w/h     its resolved SAR (aspect_vui: 1:1 when unspecified)
  w_mbs       its CODED width in macroblocks (the reader's line: 16 W <= 2,048 for native)
  dw, dh      the HDMI display's shape (HDMI_WIDTH x HDMI_HEIGHT; 0 = no scaler)
  std         0 59.94 Hz, 1 60.00 Hz (525-line standards), 2 50 Hz, 3 reserved (aliases 0)
  req         Video Output is Native (HDMI) and the raster is progressive

THE RULE (§3b, decided 2026-10-01: display-shaped whenever it fits):
  A = wc sar_w, B = hc sar_h (the picture's display aspect A : B). With a display:
    wider  (A dh > B dw):  Rw = wc, Rh = round(A dh / (sar_h dw))    letterboxed inside
    narrower (A dh < B dw): Rh = hc, Rw = round(B dw / (sar_w dh))   pillarboxed inside
    equal:                 Rw = wc, Rh = hc
  shown at the display's shape (disp = 1: HDMI is given dw : dh). If that raster does not FIT,
  the picture-sized raster Rw x Rh = wc x hc (disp = 0: HDMI is given A : B); if that does not fit
  either, the fitted 720 raster (mode 2, "native, fell back") -- visible in word 80.
  round(n / d) = floor((2n + d) / 2d).

FITS (§4): the frame keeps the standard's time -- F 27 MHz dots (450,450 / 450,000 / 540,000) -- and
disp_ctl's events (skip at Ae = 420,420 / 509,760) stay where they are. hd_raster: the native raster
counts 81 MHz dots, THREE a 27 MHz dot, so a frame is 3F (1,351,350 / 1,350,000 / 1,620,000) and the
active lines end by 3 Ae (1,261,260 / 1,529,280):
  L = min(floor(Ae / Rh), LMAX)     each active line's dots (LMAX 4,000: h_pos is 12 bits, and
                                    the last line may carry up to 31 more)
  fits iff 1 <= Rw <= 2,048 (the reader's line slots, its 11-bit column; hd_raster), 1 <= Rh <= 2,048
           (a 128-macroblock-tall picture; then L >= 615 and NT <= 2,635: v_pos's 12 bits hold it),
           L - Rw >= HBL (20: ascal's 17 dots of DE low + margin), 16 W <= 2,048 (coded: the decoder's
           own 128-macroblock side bound). Every picture the decoder accepts (<= 3,600 macroblocks)
           then fits picture-sized: Rh (Rw + 20) <= 962,560 <= 3 Ae.
THE FRAME: N = floor(F / L) lines of L dots, R = F - N L; R >= 32: one more (short) line of R dots;
  else one line is L + R long. That odd line is the FIRST BLANK LINE (line Rh): the reader fetches
  nothing there (the frame's last line commands the next frame's first rows: a short one there left
  it ~150 dots -- found by run_disp_reader.sh's 720x576 native case, fetch_late). So the frame is EXACTLY F dots (disp_ctl's refresh counter
  free-runs at F after alignment: a frame of F +- 1 would drift the events into the picture).
  total lines NT = N + (R >= 32), the odd line's length LAST.
  VS on lines [Rh + 2, Rh + 5); HS on the dots [len - 14, len - 6) of every line (inside the blank:
  L - Rw >= 20).

    python3 tools/raster_geom_ref.py --selftest
    python3 tools/raster_geom_ref.py --vectors N FILE
"""
import argparse, random, sys

F = {0: 3 * 450450, 1: 3 * 450000, 2: 3 * 540000, 3: 3 * 450450}  # hd_raster: 81 MHz dots; 3 aliases reserved 0
AE = {0: 3 * 420420, 1: 3 * 420420, 2: 3 * 509760, 3: 3 * 420420}
HBL, LMAX, RW_MAX, RH_MAX = 20, 4000, 2048, 2048
MODE_FITTED, MODE_NATIVE, MODE_FELL = 0, 1, 2


def rdiv(n, d):
    return (2 * n + d) // (2 * d)


def lines_for(rw, rh, std):
    """L for a raster, or None if it does not fit"""
    if rw < 1 or rh < 1 or rw > RW_MAX or rh > RH_MAX:
        return None
    l = min(AE[std] // rh, LMAX)
    return l if l - rw >= HBL else None


def geom(wc, hc, sar_w, sar_h, w_mbs, dw, dh, std, req):
    if sar_w == 0 or sar_h == 0:
        sar_w = sar_h = 1
    out = dict(mode=MODE_FITTED, rw=720, rh=576 if std == 2 else 480, disp=0, l=0, nt=0, last=0)
    if not req:
        return out
    ok = dw and dh and 16 * w_mbs <= RW_MAX and wc >= 1 and hc >= 1
    cand = []
    if ok:
        a, b = wc * sar_w, hc * sar_h
        if a * dh > b * dw:
            cand.append((wc, rdiv(a * dh, sar_h * dw), 1))
        elif a * dh < b * dw:
            cand.append((rdiv(b * dw, sar_w * dh), hc, 1))
        else:
            cand.append((wc, hc, 1))
        cand.append((wc, hc, 0))
    for rw, rh, disp in cand:
        l = lines_for(rw, rh, std)
        if l is None:
            continue
        n = F[std] // l
        r = F[std] - n * l
        nt, last = (n + 1, r) if r >= 32 else (n, l + r)
        return dict(mode=MODE_NATIVE, rw=rw, rh=rh, disp=disp, l=l, nt=nt, last=last)
    out['mode'] = MODE_FELL
    return out


def frame_dots(g):
    return (g['nt'] - 1) * g['l'] + g['last']


def selftest():
    # docs/hd_raster.md §4's table, 1920x1080 display. 59.94:
    g = geom(852, 356, 640, 639, 54, 1920, 1080, 0, 1)     # a scope transcode: letterboxed inside
    assert g['mode'] == 1 and g['disp'] == 1 and (g['rw'], g['rh']) == (852, 480), g
    assert g['l'] == 2627 and frame_dots(g) == 1351350, g
    g = geom(854, 480, 1, 1, 54, 1920, 1080, 0, 1)         # Sunshine's 854 (a hair wider than 16:9)
    assert g['mode'] == 1 and (g['rw'], g['rh'], g['l']) == (854, 480, 2627), g
    g = geom(852, 480, 640, 639, 54, 1920, 1080, 0, 1)     # Jellyfin's 852 at SAR 640:639 is EXACTLY 16:9
    assert g['mode'] == 1 and g['disp'] == 1 and (g['rw'], g['rh']) == (852, 480), g   # (the equal branch)
    g = geom(640, 480, 1, 1, 40, 1920, 1080, 0, 1)         # a square 4:3 transcode: pillarboxed, 853
    assert g['mode'] == 1 and g['disp'] == 1 and (g['rw'], g['rh']) == (853, 480), g
    g = geom(720, 480, 8, 9, 45, 1920, 1080, 0, 1)         # 4:3 SD at 8:9: 960 wide -- fits now (picture-sized at 27 MHz)
    assert g['mode'] == 1 and g['disp'] == 1 and (g['rw'], g['rh']) == (960, 480), g
    g = geom(720, 480, 10, 11, 45, 1920, 1080, 0, 1)       # ... at 10:11: 939
    assert g['mode'] == 1 and g['disp'] == 1 and g['rw'] == 939, g
    g = geom(864, 480, 1, 1, 54, 1920, 1080, 0, 1)         # 864x480 uncropped: fits now (fell back at 27 MHz),
    assert g['mode'] == 1 and (g['rw'], g['rh'], g['l']) == (864, 486, 2595), g   # a hair wider than 16:9
    g = geom(1280, 720, 1, 1, 80, 1920, 1080, 0, 1)        # 720p: exactly 16:9, native at last
    assert g['mode'] == 1 and g['disp'] == 1 and (g['rw'], g['rh'], g['l']) == (1280, 720, 1751), g
    assert frame_dots(g) == 1351350, g
    g = geom(1280, 720, 1, 1, 80, 1920, 1080, 2, 1)        # ... at 50 Hz
    assert g['mode'] == 1 and g['l'] == 2124 and frame_dots(g) == 1620000, g
    g = geom(480, 854, 1, 1, 30, 1920, 1080, 0, 1)         # portrait: display-shaped 1,518 does not fit
    assert g['mode'] == 1 and g['disp'] == 0 and g['l'] == 1476, g   # (L 1,476) -- picture-sized does
    g = geom(480, 854, 1, 1, 30, 1920, 1080, 2, 1)         # at 50 Hz the display-shaped one fits (L 1,790)
    assert g['mode'] == 1 and g['disp'] == 1 and g['rw'] == 1518, g
    g = geom(720, 576, 16, 15, 45, 1920, 1080, 2, 1)       # PAL 4:3: 960 at 576 lines, display-shaped
    assert g['mode'] == 1 and g['disp'] == 1 and (g['rw'], g['rh']) == (960, 576), g
    g = geom(720, 576, 16, 15, 45, 1920, 1080, 3, 1)       # reserved standard safely aliases 59.94
    assert g['mode'] == 1 and g['disp'] == 1 and (g['rw'], g['rh']) == (960, 576), g
    assert frame_dots(g) == F[0] and g['rh'] * g['l'] <= AE[0], g
    g = geom(2048, 448, 1, 1, 128, 1920, 1080, 0, 1)       # the widest legal picture: picture-sized
    assert g['mode'] == 1 and g['disp'] == 0 and (g['rw'], g['rh'], g['l']) == (2048, 448, 2815), g
    g = geom(448, 2048, 1, 1, 28, 1920, 1080, 0, 1)        # the tallest
    assert g['mode'] == 1 and g['disp'] == 0 and (g['rh'], g['l']) == (2048, 615), g
    assert geom(2064, 300, 1, 1, 129, 1920, 1080, 0, 1)['mode'] == 2        # coded wider than 2,048
    assert geom(2000, 300, 1, 1, 129, 1920, 1080, 0, 1)['mode'] == 2        # ... even cropped to 2,000
    assert geom(852, 356, 640, 639, 54, 0, 0, 0, 1)['mode'] == 2            # no scaler (direct_video)
    assert geom(852, 356, 640, 639, 54, 1920, 1080, 0, 0)['mode'] == 0      # not asked
    # tiny pictures: L capped at 4,000, the frame still exact
    g = geom(16, 16, 1, 1, 1, 1920, 1080, 0, 1)
    assert g['mode'] == 1 and g['l'] == 4000 and frame_dots(g) == 1351350 and g['nt'] <= 4095, g
    for std in (0, 1, 2, 3):
        for _ in range(2000):
            w = random.randint(1, 128); h = random.randint(1, max(1, min(128, 3600 // w)))   # 0.11: 3,600
            g = geom(16 * w - random.randint(0, 15), 16 * h - random.randint(0, 15), random.randint(1, 300),
                     random.randint(1, 300), w, random.choice([1920, 1280, 1024, 640, 3840]),
                     random.choice([1080, 720, 768, 480, 2160]), std, 1)
            # every picture the decoder accepts is native (picture-sized at worst)
            assert g['mode'] == 1, g
            assert frame_dots(g) == F[std] and g['l'] - g['rw'] >= HBL and g['rh'] * g['l'] <= AE[std], g
            assert g['nt'] >= g['rh'] + 6 and g['last'] <= 4095 and g['nt'] <= 4095, g
    print("raster_geom_ref selftest: PASS")


def vectors(n, path, seed=1):
    rnd = random.Random(seed)
    cases = [(852, 356, 640, 639, 54), (854, 480, 1, 1, 54), (852, 480, 640, 639, 54), (640, 480, 1, 1, 40),
             (720, 480, 8, 9, 45), (720, 480, 10, 11, 45), (864, 480, 1, 1, 54), (480, 854, 1, 1, 30),
             (720, 576, 16, 15, 45), (1280, 300, 1, 1, 80), (1024, 576, 1, 1, 64), (16, 16, 1, 1, 1),
             (1, 1, 1, 1, 1), (720, 404, 1, 1, 45), (352, 240, 10, 11, 22), (1024, 256, 1, 1, 64),
             (224, 1808, 1, 1, 14), (720, 480, 65535, 1, 45), (720, 480, 1, 65535, 45), (0, 480, 1, 1, 45),
             # coded wider than 2,048 but cropped narrower: the coded-width bound alone refuses it
             (2000, 300, 1, 1, 129), (1000, 200, 1, 1, 130), (900, 300, 1, 1, 66),
             (1280, 720, 1, 1, 80), (2048, 448, 1, 1, 128), (448, 2048, 1, 1, 28), (1920, 480, 1, 1, 120)]
    while len(cases) < n:
        w = rnd.randint(1, 130); h = rnd.randint(1, max(1, min(128, 3600 // w)))   # 0.11: 3,600
        sar = rnd.choice([(1, 1), (10, 11), (40, 33), (16, 11), (4, 3), (8, 9), (640, 639), (8100, 8113)]) \
            if rnd.random() < 0.8 else (rnd.randint(1, 65535), rnd.randint(1, 65535))
        cases.append((16 * w - rnd.randint(0, 15), 16 * h - rnd.randint(0, 15), sar[0], sar[1], w))
    displays = [(1920, 1080), (1280, 720), (1024, 768), (0, 0), (1280, 1024), (720, 480), (3840, 2160),
                (1366, 768), (2560, 1080), (640, 480), (0, 1080), (4095, 1), (1, 4095)]
    with open(path, 'w') as fh:
        for ci, (wc, hc, sw, sh, wm) in enumerate(cases):
            for k, (std, req) in enumerate(((0, 1), (1, 1), (2, 1), (3, 1), (0, 0))):
                dw, dhh = (1920, 1080) if k == 0 else displays[(ci * 4 + k) % len(displays)] \
                    if rnd.random() < 0.7 else (rnd.randint(0, 4095), rnd.randint(0, 4095))
                g = geom(wc, hc, sw, sh, wm, dw, dhh, std, req)
                fh.write('%03x %03x %04x %04x %02x %03x %03x %x %x  %x %03x %03x %x %03x %03x %03x\n' % (
                    wc, hc, sw, sh, wm, dw, dhh, std, req,
                    g['mode'], g['rw'], g['rh'], g['disp'], g['l'], g['nt'], g['last']))
    print("wrote %d vectors to %s" % (len(cases) * 4, path))


def sync_geo(std, path):
    """segments for bench/h264/sync_gen_nat_tb.sv at this standard: "nat w h l nt last" (hex), a
    fitted segment after every third native one"""
    pics = [(852, 356, 640, 639, 54), (854, 480, 1, 1, 54), (640, 480, 1, 1, 40), (720, 480, 8, 9, 45),
            (16, 16, 1, 1, 1), (480, 854, 1, 1, 30), (1000, 300, 1, 1, 62), (352, 240, 10, 11, 22),
            (224, 1808, 1, 1, 14), (720, 576, 16, 15, 45), (1024, 256, 1, 1, 64), (720, 404, 1, 1, 45),
            (1280, 720, 1, 1, 80), (2048, 448, 1, 1, 128), (448, 2048, 1, 1, 28)]
    n = 0
    with open(path, 'w') as fh:
        for i, p in enumerate(pics):
            g = geom(*p, 1920, 1080, std, 1)
            if g['mode'] != MODE_NATIVE:
                continue
            fh.write('1 %03x %03x %03x %03x %03x\n' % (g['rw'], g['rh'], g['l'], g['nt'], g['last']))
            n += 1
            if n % 3 == 0:
                fh.write('0 000 000 000 000 000\n')
    print("wrote %d native segments (std %d) to %s" % (n, std, path))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--selftest', action='store_true')
    ap.add_argument('--vectors', nargs=2)
    ap.add_argument('--sync-geo', nargs=2, metavar=('STD', 'FILE'))
    a = ap.parse_args()
    if a.selftest:
        selftest(); return 0
    if a.vectors:
        vectors(int(a.vectors[0]), a.vectors[1]); return 0
    if a.sync_geo:
        sync_geo(int(a.sync_geo[0]), a.sync_geo[1]); return 0
    ap.print_help(); return 1


if __name__ == '__main__':
    sys.exit(main())
