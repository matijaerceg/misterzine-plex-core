#!/usr/bin/env python3
"""comb_metric.py -- how combed a screenshot is: the rig gate of the deinterlacer (P5f,
docs/display.md S8).

A woven field pair on motion alternates line by line between two instants, so the
1-line vertical second difference |2 b - a - d| is large while the 2-line one (within a
field, |2 b - y[-2] - y[+2]|) is not. Per image, on luma (BT.601 from the RGB), over the
rows and columns that are not black borders:

  comb   mean |2 y[r] - y[r-1] - y[r+1]|
  ratio  comb / mean |2 y[r] - y[r-2] - y[r+2]|   (texture-normalised: below 1 on a clean
         picture, above it on a combed one -- the self-test's synthetic pan: 0.25
         progressive, 0.10 blended, 0.25 bobbed, 1,600 woven. Compare MODES on one title;
         real pictures' absolute values are the rig's to measure, docs/display.md S8)

    comb_metric.py shot1.png [shot2.png ...]    one line per image
    comb_metric.py --selftest                    prove the metric separates comb from none

Take the shots with Diagnostics Off (the HUD's text is itself high-frequency).
"""
import sys
import numpy as np


def luma(img):
    a = np.asarray(img.convert("RGB"), np.float64)
    return 0.299 * a[:, :, 0] + 0.587 * a[:, :, 1] + 0.114 * a[:, :, 2]


def metric(y):
    rows = np.where(y.max(1) > 20)[0]
    cols = np.where(y.max(0) > 20)[0]
    if rows.size < 8 or cols.size < 8:
        return None
    y = y[rows[0]:rows[-1] + 1, cols[0]:cols[-1] + 1]
    d1 = np.abs(2 * y[2:-2] - y[1:-3] - y[3:-1]).mean()
    d2 = np.abs(2 * y[2:-2] - y[:-4] - y[4:]).mean()
    return d1, d1 / max(d2, 1e-9), y.shape


def selftest():
    H, W = 480, 720
    yy, xx = np.mgrid[0:H, 0:W + 64].astype(np.float64)
    # a picture smooth in both directions, with hard vertical edges (bars) -- where a pan combs
    base = 110 + 40 * np.sin(xx / 17) * np.cos(yy / 37) + 50 * ((xx // 40) % 2)
    t0, t1 = base[:, :W], base[:, 24:W + 24]                     # a 24-dot pan between fields
    woven = t0.copy()
    woven[1::2] = t1[1::2]
    blend = woven.copy()
    blend[1:-1] = (woven[:-2] + 2 * woven[1:-1] + woven[2:]) / 4
    bob = t0.copy()
    bob[1:-1:2] = (t0[0:-2:2] + t0[2::2]) / 2
    r = {k: metric(v)[1] for k, v in (("progressive", t0), ("woven", woven), ("blend", blend), ("bob", bob))}
    for k, v in r.items():
        print("  %-12s ratio %.3f" % (k, v))
    ok = r["woven"] > 1.0 and max(r["progressive"], r["blend"], r["bob"]) < 0.9 and r["woven"] > 2 * r["blend"]
    print("PASS: comb_metric selftest" if ok else "FAIL: comb_metric selftest")
    return 0 if ok else 1


def main():
    if sys.argv[1:] == ["--selftest"]:
        return selftest()
    from PIL import Image
    for f in sys.argv[1:]:
        m = metric(luma(Image.open(f)))
        if m is None:
            print("%s: no picture (black)" % f)
        else:
            print("%s: comb %.2f ratio %.3f (%dx%d)" % (f, m[0], m[1], m[2][1], m[2][0]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
