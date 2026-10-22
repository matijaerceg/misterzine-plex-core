#!/usr/bin/env python3
"""Name the cosim's +prof histograms (bench/h264/cosim_main.cpp): cycles a macroblock per
state of recon_mb's front (ms), recon_inter's fetch (st) and interpolation (k) sides, the back engine (es) and the residual
engine (rs), the 8x8 residual unit (dq8), the state names read from the RTL's enums.

    cosim_prof.py COSIM.log [--min N] [--by-type]
        (states under N cycles a macroblock are folded; --by-type: the same tables per picture
        type -- I, P, B by the slice types a picture's macroblocks were decoded in -- each in
        cycles a macroblock of that type, docs/mb_pipeline.md S4i)

The "dq8" unit is dequant_itrans8's INTAKE (S_IN / S_DRAIN while a block comes in): since S4j
its passes and its output stream are stages of their own and do not show -- S_IDLE there does
not mean the unit is idle.

The "mc0" unit is lane 0's mc_interp: no reads left (idle, or draining), a read issued, starved
of window rows (the fetch), held by its output credit (the consumer); "pre:" while the item the
interpolation side owns has not issued its first read (its setup, its first rows awaited).

The "kitem" / "kitemn" units are recon_inter's interpolation items (a group, a plane, a list):
the cycles the interpolation side owns an item of each kind, and the items taken, keyed by
{owned, chroma, size, fraction class (full / one axis / both), bi, list} -- printed as a table.
"Owned" is recon_inter's main machine away from K_IDLE: since S4k step B an item's setup (the
weight reads) runs before it is taken, so its cycles count from its start, not its setup.

The "hand" unit (only in the parked feature/ab-queue's cosim, S4i) is its A -> B hand-off, a
bit set per cycle: {A in A_HAND, B idle, the request queue's second entry, the slot's take
pending, the slot full}.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def enum(path, pattern):
    src = open(os.path.join(ROOT, path)).read()
    m = re.search(pattern, src, re.S)
    body = re.sub(r"//[^\n]*", "", m.group(1))
    return [n.strip() for n in body.replace("\n", " ").split(",") if n.strip()]


def localparams(path, typ):
    # plain-constant states (mb_syntax.sv: "localparam state_t S_X = 7'dN;")
    src = open(os.path.join(ROOT, path)).read()
    names = {}
    for n, v in re.findall(r"localparam\s+%s\s+(\w+)\s*=\s*\d+'d(\d+)" % typ, src):
        names[int(v)] = n
    return [names.get(i, "S_%d" % i) for i in range(max(names) + 1)] if names else []


HAND_BITS = ("slot", "take", "rq2", "Bidle", "Ahand")


def hand_name(i):
    on = [n for b, n in enumerate(HAND_BITS) if i >> b & 1]
    return "+".join(on) if on else "(none)"


def item_name(i):
    """kitem: {owned, chroma, size, fraction class, bi, list} (bench/h264/cosim_top.sv)"""
    c = i >> 6 & 1
    sz = ("2", "4", "8")[i >> 4 & 3] if c else ("4", "8", "16")[i >> 4 & 3]
    fr = ("full", "1-axis", "2-axis")[min(i >> 2 & 3, 2)]
    bi, lx = i >> 1 & 1, i & 1
    role = ("bi L0" if not lx else "bi L1") if bi else ("L0 only" if not lx else "L1 only")
    return "%s%sx%s %-6s %s" % ("C" if c else "Y", sz, sz, fr, role)


def items(rows_of, nmb, lim):
    """the interpolation side's items: cycles a macroblock owned, items a macroblock, cycles an item"""
    cyc = dict(rows_of("kitem"))
    cnt = dict(rows_of("kitemn"))
    rows = [(i, c, cnt.get(i, 0)) for i, c in cyc.items() if i & 0x80]
    if not rows:
        return
    rows.sort(key=lambda r: -r[1])
    print("  interpolation items (cycles a macroblock / items a macroblock / cycles an item):")
    rest = 0.0
    for i, c, n in rows:
        if c / nmb < lim / 4:
            rest += c / nmb
            continue
        print("    %-22s %7.0f %7.2f %7.0f" % (item_name(i & 0x7F), c / nmb, n / nmb, c / n if n else 0))
    if rest:
        print("    %-22s %7.0f" % ("(the rest)", rest))
    print("    %-22s %7.0f %7.2f" % ("(all items)", sum(r[1] for r in rows) / nmb, sum(r[2] for r in rows) / nmb))


def table(names, rows_of, nmb, lim):
    """rows_of(unit) -> [(state, cycles)]; prints each unit in cycles a macroblock"""
    items(rows_of, nmb, lim)
    for unit in ("as", "ms", "inter", "interp", "mc0", "es", "rs", "dq8", "fe", "hand"):
        rows = rows_of(unit)
        if not rows:
            continue
        rows.sort(key=lambda r: -r[1])
        print("  %s:" % unit)
        rest = 0.0
        for i, c in rows:
            per = c / nmb
            if per < lim:
                rest += per
                continue
            if unit == "hand":
                nm = hand_name(i)
            else:
                nm = names[unit][i] if i < len(names[unit]) else str(i)
            print("    %-16s %7.0f" % (nm, per))
        if rest:
            print("    %-16s %7.0f" % ("(the rest)", rest))


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    log = argv[0]
    lim = float(argv[argv.index("--min") + 1]) if "--min" in argv else 10.0
    names = {
        "ms": enum("h264/dec/recon_mb.sv", r"typedef enum logic \[6:0\] \{(.*?)\} mstate_t;"),
        "inter": enum("h264/dec/recon_inter.sv", r"typedef enum logic \[4:0\] \{(.*?)\} istate_t;"),
        "interp": enum("h264/dec/recon_inter.sv", r"typedef enum logic \[3:0\] \{(.*?)\} kstate_t;"),
        "es": enum("h264/dec/recon_mb_fsm.svh", r"typedef enum logic \[3:0\] \{(.*?)\} estate_t;"),
        "rs": enum("h264/dec/recon_mb_fsm.svh", r"typedef enum logic \[2:0\] \{(.*?)\} rstate_t;"),
        "as": enum("h264/dec/recon_mb_fsm.svh", r"typedef enum logic \[4:0\] \{(.*?)\} astate_t;"),
        "fe": localparams("h264/dec/mb_syntax.sv", "state_t"),
        "mc0": ["no reads left", "a read issued", "starved: rows", "held: credit",
                "pre: no reads yet", "pre: (issued)", "pre: starved rows", "pre: held"],
        "dq8": enum("h264/dec/dequant_itrans8.sv", r"typedef enum logic \[2:0\] \{(.*?)\} state_t;"),
    }
    txt = open(log).read()
    m = re.search(r"PROF macroblocks (\d+) span (\d+)", txt)
    if not m:
        sys.exit("cosim_prof: no PROF lines in %s (run the cosim with +prof)" % log)
    nmb, span = int(m.group(1)), int(m.group(2))
    print("%d macroblocks, %.0f cycles a macroblock" % (nmb, span / nmb))
    b = re.search(r"PROF bins (\d+)", txt)
    if b:
        nb = int(b.group(1))
        print("  front end: %.1f bins a macroblock, %.3f bins a cycle over the span" % (nb / nmb, nb / span))
    table(names, lambda u: [(int(i), int(c)) for i, c in re.findall(r"^PROF %s (\d+) (\d+)$" % u, txt, re.M)], nmb, lim)
    if "--by-type" in argv:
        pics = re.findall(r"^PROF pic (\d+) (\d+) (\d+) (\d+)$", txt, re.M)
        if not pics:
            sys.exit("cosim_prof: no per-picture lines (a cosim built before S4i)")
        mbs_per_pic = nmb / len(pics)        # (frames of one size: the profile's streams)
        kind = {}
        for i, mask, _, _ in pics:
            m = int(mask)
            kind[i] = "B" if m & 2 else "P" if m & 1 else "I"
        pu = re.findall(r"^PROF pu (\d+) (\w+) (\d+) (\d+)$", txt, re.M)
        for t in "IPB":
            sel = [p for p in pics if kind[p[0]] == t]
            if not sel:
                continue
            n = len(sel) * mbs_per_pic
            cyc = sum(int(p[2]) for p in sel)
            bins = sum(int(p[3]) for p in sel)
            print("%s pictures: %d, %.0f cycles a macroblock (%.0f %% of the time), %.0f bins a macroblock"
                  % (t, len(sel), cyc / n, 100.0 * cyc / span, bins / n))
            ids = set(p[0] for p in sel)

            def rows_of(u, ids=ids):
                acc = {}
                for i, uu, st, c in pu:
                    if uu == u and i in ids:
                        acc[int(st)] = acc.get(int(st), 0) + int(c)
                return list(acc.items())
            table(names, rows_of, n, lim)
    return 0


if __name__ == "__main__":
    sys.exit(main())
