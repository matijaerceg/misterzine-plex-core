#!/usr/bin/env python3
"""The colour codes of interface 0.16 (docs/colour.md §3, docs/architecture.md "The colour"):
each code's Y'CbCr -> R'G'B' integers, DERIVED here from the matrices' Kr / Kb by H.264 E.2.1's
equations -- not copied from h264/disp_reader.sv -- so the bench's golden is independent of the
RTL's table.

  code  1 BT.601 limited   2 BT.601 full   3 BT.709 limited   4 BT.709 full
        5 BT.2020 (ncl) limited             6 BT.2020 (ncl) full      (0 auto, 7 reserved)

The conversion (Q8, one rounding, the clamp: the integer form disp_reader states):
  C = Y - yoff, D = Cb - 128, E = Cr - 128
  R = (kc C + krv E + 128) >> 8,  G = (kc C - kbg D - krg E + 128) >> 8,  B = (kc C + kbb D + 128) >> 8

    colour_ref.py          prints the table and checks it (the integers within 1 of E.2.1 in floats,
                           code 1 = the 0.15 integers 298 / 409 / 100 / 208 / 516); exit 1 on a failure
    colour_ref.py --sv     the table as SystemVerilog case arms (for reading against the RTL)
"""
import sys
import numpy as np

KRKB = {"601": (0.299, 0.114), "709": (0.2126, 0.0722), "2020": (0.2627, 0.0593)}   # Table E-5
CODES = {1: ("601", 0), 2: ("601", 1), 3: ("709", 0), 4: ("709", 1), 5: ("2020", 0), 6: ("2020", 1)}


def factors(code):
    """E.2.1, inverted: the float factors (yoff, kc, krv, kbg, krg, kbb) of a code."""
    m, full = CODES[code]
    kr, kb = KRKB[m]
    kg = 1.0 - kr - kb
    ys = 1.0 if full else 255.0 / 219.0            # Y' = (Y - 16) / 219, or Y / 255 (x 255 out)
    cs = 1.0 if full else 255.0 / 224.0            # Pb = (Cb - 128) / 224, or / 255
    return (0 if full else 16, ys, 2 * (1 - kr) * cs, 2 * kb * (1 - kb) / kg * cs,
            2 * kr * (1 - kr) / kg * cs, 2 * (1 - kb) * cs)


def coeffs(code):
    """The Q8 integers (yoff, kc, krv, kbg, krg, kbb), rounded to nearest."""
    f = factors(code)
    return (f[0],) + tuple(int(round(x * 256)) for x in f[1:])


def rgb(Y, U, V, code=1):
    """The integer conversion of numpy arrays (or ints), as the display does it."""
    yoff, kc, krv, kbg, krg, kbb = coeffs(code)
    C, D, E = np.asarray(Y) - yoff, np.asarray(U) - 128, np.asarray(V) - 128
    R = np.clip((kc * C + krv * E + 128) >> 8, 0, 255)
    G = np.clip((kc * C - kbg * D - krg * E + 128) >> 8, 0, 255)
    B = np.clip((kc * C + kbb * D + 128) >> 8, 0, 255)
    return np.stack([R, G, B], -1)


def rgb_float(Y, U, V, code=1):
    yoff, kc, krv, kbg, krg, kbb = factors(code)
    C, D, E = np.asarray(Y, float) - yoff, np.asarray(U, float) - 128, np.asarray(V, float) - 128
    R, G, B = kc * C + krv * E, kc * C - kbg * D - krg * E, kc * C + kbb * D
    return np.clip(np.round(np.stack([R, G, B], -1)), 0, 255)


def check():
    ok = True
    if coeffs(1) != (16, 298, 409, 100, 208, 516):
        print("FAIL: code 1 is not the 0.15 integers:", coeffs(1)); ok = False
    g = np.arange(256)
    Y, U, V = np.meshgrid(g, g[::3], g[::3], indexing="ij")
    for c in CODES:
        d = np.abs(rgb(Y, U, V, c).astype(int) - rgb_float(Y, U, V, c).astype(int)).max()
        print("code %d %-4s %-7s %s  max |integer - float| %d" % (c, CODES[c][0], "full" if CODES[c][1] else "limited",
                                                              coeffs(c), d))
        if d > 1:
            print("FAIL: code %d off by %d" % (c, d)); ok = False
    print("PASS: colour_ref" if ok else "FAIL: colour_ref")
    return ok


if __name__ == "__main__":
    if "--sv" in sys.argv:
        for c in CODES:
            y, kc, a, b, cc, d = coeffs(c)
            print("3'd%d: begin cf_yoff <= 5'd%d; cf_c <= 10'd%d; cf_rv <= 10'd%d; cf_bg <= 10'd%d; cf_rg <= 10'd%d; cf_bb <= 10'd%d; end"
                  % (c, y, kc, a, b, cc, d))
    else:
        sys.exit(0 if check() else 1)
