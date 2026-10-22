#!/usr/bin/env python3
"""Score bench/h264/recon_ctl_tb.sv's log against tools/h264_recon_ref.py --dump.

The bench prints, per slice, the fabric's picture (store, structure, POC), the
reference lists (store/structure/POC/marking per entry) and, for a new picture, the
DPB after the previous picture's marking. The model's dump carries the same per
picture (pic_NNNN.ctl.txt) with the model's frame ids. Store numbers and frame ids
are matched by a mapping built as pictures open (frame id -> store) and required to
stay consistent: a store holds one frame id from its allocation until it is reused.

    recon_ctl_check.py <model dump dir> <bench log>        -> exit 0 / 1, first mismatch printed
"""
import os
import re
import sys

STRUCT = {"F": "F", "T": "T", "B": "B"}


def load_model(d):
    """[(slice records)] in decode order: each {'new', 'frame', 'struct', 'poc', 'isref',
    'lists': [[(frame, struct, poc, mark) | None]], 'dpb_prev': {frame: (mt, mb, pt, pb)}}"""
    pics = sorted(f for f in os.listdir(d) if f.endswith(".ctl.txt"))
    out = []
    prev_dpb = {}
    for f in pics:
        lines = open(os.path.join(d, f)).read().split("\n")
        m = re.match(r"store (\d+) struct (\w) poc_top (\S+) poc_bot (\S+) frame_num (\d+) is_ref (\d) idr (\d) mmco5 (\d)", lines[0])
        frame, struct = int(m.group(1)), m.group(2)
        pt = None if m.group(3) == "None" else int(m.group(3))
        pb = None if m.group(4) == "None" else int(m.group(4))
        poc = pt if struct == "T" else pb if struct == "B" else min(pt, pb)
        isref = int(m.group(6))
        slices = []
        cur = None
        for ln in lines[1:]:
            if ln.startswith("slice "):
                cur = {"type": ln.split()[3], "lists": []}
                slices.append(cur)
            elif ln.startswith("  list"):
                ents = []
                for tok in ln.split()[1:]:
                    if tok == "-":
                        ents.append(None)
                    else:
                        mm = re.match(r"(\d+)([FTB])/(-?\d+)/(\d)", tok)
                        ents.append((int(mm.group(1)), mm.group(2), int(mm.group(3)), int(mm.group(4))))
                cur["lists"].append(ents)
            elif ln.startswith("dpb"):
                dpb = {}
                for tok in ln.split()[1:]:
                    mm = re.match(r"(\d+):(\d)(\d)/(\S+)/(\S+)/fn\d+/lt\S+", tok)
                    fid = int(mm.group(1))
                    mt, mb = int(mm.group(2)), int(mm.group(3))
                    vt = int(mm.group(4)) if mt and mm.group(4) != "None" else 0
                    vb = int(mm.group(5)) if mb and mm.group(5) != "None" else 0
                    if mt or mb:                      # the model prunes unmarked frames after the dump
                        dpb[fid] = (mt, mb, vt, vb)
        for i, sl in enumerate(slices):
            # an I slice has no list, a P slice only list 0 (the bench prints the same)
            n_l = {"I": 0, "P": 1, "B": 2}[sl["type"]]
            out.append({"new": i == 0, "frame": frame, "struct": struct, "poc": poc, "isref": isref,
                        "type": sl["type"], "lists": sl["lists"][:n_l], "dpb_prev": prev_dpb if i == 0 else None})
        prev_dpb = dpb
    return out


def load_bench(path):
    out = []
    cur = None
    for ln in open(path):
        ln = ln.rstrip("\n")
        if ln.startswith("S "):
            f = ln.split()
            cur = {"new": int(f[3]), "store": int(f[5]), "struct": f[7], "poc": int(f[9]), "isref": int(f[11]),
                   "lists": [], "dpb": None}
            out.append(cur)
        elif ln.startswith("D") and cur is not None and (ln == "D" or ln.startswith("D ")):
            dpb = {}
            for tok in ln.split()[1:]:
                mm = re.match(r"(\d+):(\d)(\d)/(-?\d+)/(-?\d+)", tok)
                dpb[int(mm.group(1))] = (int(mm.group(2)), int(mm.group(3)), int(mm.group(4)), int(mm.group(5)))
            cur["dpb"] = dpb
        elif re.match(r"L[01] ", ln) and cur is not None:
            ents = []
            for tok in ln.split()[2:]:
                if tok == "-":
                    ents.append(None)
                else:
                    mm = re.match(r"(\d+)([FTB])/(-?\d+)/(\d)", tok)
                    ents.append((int(mm.group(1)), mm.group(2), int(mm.group(3)), int(mm.group(4))))
            cur["lists"].append(ents)
    return out


def main(argv):
    model = load_model(argv[0])
    bench = load_bench(argv[1])
    if len(model) != len(bench):
        print("FAIL [ctl] %d slices in the bench log, %d in the model" % (len(bench), len(model)))
        return 1
    f2s = {}      # model frame id -> store
    s2f = {}      # store -> model frame id

    def bind(fid, store, where):
        if fid in f2s and f2s[fid] != store:
            raise AssertionError("%s: model frame %d was store %d, now %d" % (where, fid, f2s[fid], store))
        if store in s2f and s2f[store] != fid and fid not in f2s:
            pass
        f2s[fid] = store
        s2f[store] = fid

    n_ent = 0
    for i, (m, b) in enumerate(zip(model, bench)):
        where = "slice %d" % i
        try:
            if m["new"] != bool(b["new"]):
                raise AssertionError("%s: new picture %s (model) vs %s" % (where, m["new"], b["new"]))
            # the DPB after the previous picture's marking, under the mapping as it stood
            # before this picture took its store
            if m["dpb_prev"] is not None:
                want = {}
                for fid, v in m["dpb_prev"].items():
                    if fid not in f2s:
                        raise AssertionError("%s: model DPB frame %d never seen" % (where, fid))
                    want[f2s[fid]] = v
                have = dict(b["dpb"] or {})
                if want != have:
                    raise AssertionError("%s: DPB after marking\n  model  %s\n  fabric %s" % (
                        where, sorted(want.items()), sorted(have.items())))
            if m["new"]:
                # a new picture: the store was free (or pairs with the first field's)
                if b["store"] in s2f and s2f[b["store"]] != m["frame"]:
                    old = s2f.pop(b["store"])
                    f2s.pop(old, None)
            bind(m["frame"], b["store"], where)
            if m["struct"] != b["struct"] or m["poc"] != b["poc"] or m["isref"] != b["isref"]:
                raise AssertionError("%s: picture %s poc %d ref %d (model) vs %s poc %d ref %d" % (
                    where, m["struct"], m["poc"], m["isref"], b["struct"], b["poc"], b["isref"]))
            if len(m["lists"]) != len(b["lists"]):
                raise AssertionError("%s: %d lists (model) vs %d" % (where, len(m["lists"]), len(b["lists"])))
            for lx, (ml, bl) in enumerate(zip(m["lists"], b["lists"])):
                if len(ml) != len(bl):
                    raise AssertionError("%s list%d: %d entries (model) vs %d" % (where, lx, len(ml), len(bl)))
                for e, (me, be) in enumerate(zip(ml, bl)):
                    n_ent += 1
                    if me is None or be is None:
                        if me is not be and not (me is None and be is None):
                            raise AssertionError("%s list%d[%d]: %s (model) vs %s" % (where, lx, e, me, be))
                        continue
                    fid, st, poc, mk = me
                    if fid not in f2s or f2s[fid] != be[0] or st != be[1] or poc != be[2] or mk != be[3]:
                        raise AssertionError("%s list%d[%d]: frame %d%s/%d/%d -> store %s (model) vs %s" % (
                            where, lx, e, fid, st, poc, mk, f2s.get(fid), be))
        except AssertionError as ex:
            print("FAIL [ctl] %s" % ex)
            return 1
    print("recon_ctl_check: %d slices, %d list entries, %d pictures identical" % (
        len(model), n_ent, sum(1 for m in model if m["new"])))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
