#!/usr/bin/env python3
"""Fixtures for bench/h264/mv_pred_tb.sv: every inter macroblock of a stream decoded by
tools/h264_recon_ref.py (the model proven pixel-exact vs ffmpeg and the H.264.1 CABAC
set), captured exactly as h264/dec/mv_pred.sv sees it -- the slice parameters, the
descriptor (expand_mb), the A / B / C / D neighbour blocks, the sixteen co-located
entries, the MapColToList0 and DistScaleFactor tables the caller builds per slice --
and the sixteen blocks' (pred, ref, mv) per list the model derived (docs/h264_recon.md
S2). The gate of bench/h264/run_mv_pred.sh.

Capture: SliceDecoder.decode_mb is wrapped; for an inter macroblock the neighbours
(pic.mbs of the four neighbouring addresses through nb_mb: exists, same slice, decoded)
and, in a B slice, colocated(blk) for blk 0..15 with direct_8x8_inference forced 0 (the
per-block truth; the unit applies the corner selection 5 * (blk >> 2) itself) are read
before the model decodes the macroblock, the expectation from its MbInfo after. Fields
the unit must not read (an unavailable neighbour, an intra one, a list with predFlag 0,
an intra co-located block, the co-located data of a macroblock without direct
prediction) are filled with random values.

Synthetic classes, derived through the model's own methods on captured macroblocks
(never from the RTL): ERR_REF (a P 16x16 with ref_idx_l0 >= num_ref_idx_l0_active: err,
index 0, the predictor of index 0 + mvd, via SliceDecoder.mvp), ERR_MAP (a temporal
direct macroblock whose co-located reference has no MapColToList0 entry: err, index 0,
via temporal_direct with the mapping patched to 0), TD_FRM2FLD / TD_FLD2FRM (the same
macroblocks with vertMvScale forced and every mvCol[1] made negative and odd, so 8-193's
truncation toward zero differs from a floor, via temporal_direct with colocated
patched), SP_EDGE (a spatial direct macroblock with the co-located vectors forced onto
the colZeroFlag boundary -1 / 1 / -2 / 2, via spatial_direct with colocated patched),
TD_RAW (a temporal direct macroblock with every list-0 picture treated as long-term:
mvL0 = mvCol, mvL1 = 0 (8.4.1.2.3), via temporal_direct with RefPic.marking patched --
no available CABAC stream reaches that path: the scan found no temporal direct block
whose list-0 target is long-term or has pic1's POC).

Files (bench/h264/README.md conventions, one 32-bit word per line, $readmemh):
  <stem>.case.hex   164 words per case:
      w0   [15:0] slice record index  [16] skip  [22:17] mb_type  [23] err expected
           [31:24] class id (CLASSES below)
      w1   [15:0] sub_mb_type (4 bits each, sub-macroblock 0 in [3:0])  [31:16] mb addr
      w2   ref_idx_l0 per slot (5 bits each, slot 0 in [4:0])   w3  ref_idx_l1
      w4+lx*16+blk   mvd: {mvd_y[15:0], mvd_x[15:0]} per 4x4 block, lx 0 then 1
      w36+3k, k = 0..9 (A rows 0..3, B columns 0..3, C, D):
           {L0 mvy, L0 mvx}, {L1 mvy, L1 mvx},
           {[0] avail [1] intra [2] pred0 [8:3] ref0 (signed 6) [9] pred1 [15:10] ref1}
      w66+2b, b = 0..15 co-located: {mvy, mvx}, {[4:0] refIdxCol [12:5] identity code
           [13] intra}
      w98+4*blk+2*lx: expected {mvy, mvx}, {[4:0] ref (0 when pred 0) [5] pred}
      w162, w163 reserved (0)
  <stem>.slice.hex  100 words per slice record:
      s0   [1:0] slice_type (0 P 1 B) [2] direct_spatial [3] direct_8x8_inference
           [4] field_pic [6:5] cur_struct (0 F 1 T 2 B) [12:7] num_ref_l0 [18:13] num_ref_l1
           [19] RefPicList1[0] is short-term [20] colPic is a field [22:21] vert_scale
           (0 One_To_One 1 Frm_To_Fld 2 Fld_To_Frm)
      s1   list0_long: bit i = RefPicList0[i] is long-term
      s2+c, c = 0..63   map_col: {[4:0] MapColToList0, [5] valid} for identity code c
      s66+i, i = 0..31  {[10:0] DistScaleFactor (two's complement), [11] raw} for list-0
           index i (raw: long-term, or DiffPicOrderCnt(pic1, pic0) == 0 -> mvL0 = mvCol)
      s98, s99 reserved
  <stem>.meta.hex   [0] n_cases [1] n_slices [2] words per case [3] words per slice
                    [4 + i] the count of class i (CLASSES order)

    mv_pred_golden.py --x264 clip.264 --out bench/h264/fixtures/gen/mvp_p --require P_SKIP,P16x16,...
"""
import argparse
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import h264_fe_ref as FE  # noqa: E402
import h264_recon_ref as R  # noqa: E402

CLASSES = ["P_SKIP", "P16x16", "P16x8", "P8x16", "P8x8", "B16x16", "B16x8", "B8x16", "B8x8", "B8x8DS", "B8x8DT",
           "BDIR16S", "BDIR16T", "ERR_REF", "ERR_MAP", "TD_FRM2FLD", "TD_FLD2FRM", "SP_EDGE", "TD_RAW"]
CID = {n: i for i, n in enumerate(CLASSES)}
# coverage keys beyond the classes (printed and --require-able)
COV_KEYS = ["skip", "16x16", "16x8", "8x16", "8x8", "direct16", "direct8x8", "spatial", "temporal", "field",
            "intra_nb", "c_to_d", "psub0", "psub1", "psub2", "psub3"] + ["bsub%d" % i for i in range(13)] + \
           ["inference", "td_one_to_one", "td_frm_to_fld", "td_fld_to_frm", "sp_one_to_one", "sp_frm_to_fld",
            "sp_fld_to_frm", "td_f2f_neg_odd", "td_f2f_neg_even", "td_intra_col", "td_raw", "sp_col_zero"]
SCALE_KEY = ("one_to_one", "frm_to_fld", "fld_to_frm")
WORDS_CASE, WORDS_SLICE = 164, 100
SCALE = {"One_To_One": 0, "Frm_To_Fld": 1, "Fld_To_Frm": 2}
STRUCT = {"F": 0, "T": 1, "B": 2}


def u16(v):
    return v & 0xFFFF


class Capture(object):
    def __init__(self, rnd, synth=True, synth_cap=6):
        self.rnd = rnd
        self.cases = []
        self.slices = []           # dicts: params + codes + sd
        self.slice_of = {}         # id(SliceDecoder) -> index
        self.cov = {k: 0 for k in CLASSES + COV_KEYS}
        self.synth = synth
        self.synth_cap = synth_cap
        self.synth_n = {k: 0 for k in CLASSES}

    # ---- slice records --------------------------------------------------------------------
    def slice_index(self, sd):
        key = id(sd)
        if key in self.slice_of:
            return self.slice_of[key]
        h, pic = sd.h, sd.pic
        rec = {"sd": sd, "codes": {}, "slice_type": h.slice_type, "direct_spatial": h.direct_spatial,
               "inference": sd.sps.direct_8x8_inference, "field_pic": int(pic.field), "cur_struct": STRUCT[pic.struct],
               "num_ref": list(h.num_ref_idx), "l1_short": 0, "col_is_field": 0, "vert_scale": 0, "list0_long": 0,
               "tdir": [(0, 0)] * 32, "map_probe": {}}
        lists = sd.lists
        for i, e in enumerate(lists[0][:32]):
            if e is not None and e.marking() == R.LONG:
                rec["list0_long"] |= 1 << i
        if h.slice_type == R.B:
            l1_0 = lists[1][0]
            rec["l1_short"] = int(l1_0 is not None and l1_0.marking() == R.SHORT)
            # 8.4.1.2.3 (8-195 .. 8-198) per list-0 index, exactly as temporal_direct evaluates them
            for i, pic0 in enumerate(lists[0][:32]):
                if pic0 is None or l1_0 is None:
                    continue
                if pic0.marking() == R.LONG or l1_0.poc() - pic0.poc() == 0:
                    rec["tdir"][i] = (0, 1)
                else:
                    tb = R.clip3(-128, 127, pic.poc - pic0.poc())
                    td = R.clip3(-128, 127, l1_0.poc() - pic0.poc())
                    tx = R.c_div(16384 + abs(R.c_div(td, 2)), td)
                    dsf = R.clip3(-1024, 1023, (tb * tx + 32) >> 6)
                    rec["tdir"][i] = (dsf, 0)
        self.slices.append(rec)
        self.slice_of[key] = len(self.slices) - 1
        return self.slice_of[key]

    def slice_variant(self, si, **changes):
        rec = dict(self.slices[si])
        rec["codes"] = dict(rec["codes"])
        rec["map_probe"] = dict(rec["map_probe"])
        rec.update(changes)
        self.slices.append(rec)
        return len(self.slices) - 1

    def finish_slices(self):
        """MapColToList0 for every identity code that occurred in the slice. A code with no
        list-0 entry stays unmapped (valid 0): legal in a spatial slice, and in a temporal
        one for a non-corner block under direct_8x8_inference (8.4.1.2.3's "shall" covers
        only the co-located blocks actually used; the model raised during the decode if
        one of those was missing)."""
        for rec in self.slices:
            m = {}
            for code, (ident, scale, cs) in rec["codes"].items():
                try:
                    m[code] = rec["sd"].map_col_to_list0(ident, scale, cs)
                except R.ReconError:
                    pass
            rec["map"] = m

    # ---- the neighbours as the unit's line memories hold them ------------------------------
    def nb_entries(self, sd, addr):
        rnd = self.rnd
        out = []
        c_avail = None
        for (xN, yN), blks in (((-1, 0), (5, 7, 13, 15)), ((0, -1), (10, 11, 14, 15)), ((16, -1), (10,)), ((-1, -1), (15,))):
            mb, _xw, _yw = sd.nb_mb(addr, xN, yN)
            if (xN, yN) == (16, -1):
                c_avail = mb is not None
            for b in blks:
                e = {"avail": int(mb is not None), "intra": rnd.randrange(2) if mb is None else int(mb.intra), "L": []}
                if e["avail"] and e["intra"]:
                    self.cov["intra_nb"] += 1
                for lx in range(2):
                    real = mb is not None and not mb.intra
                    pred = int(mb.pred[lx][b]) if real else rnd.randrange(2)
                    if real and pred:
                        e["L"].append((1, mb.ref[lx][b], mb.mv[lx][b][0], mb.mv[lx][b][1]))
                    else:
                        e["L"].append((pred, rnd.randrange(-32, 32), rnd.randrange(-2048, 2048), rnd.randrange(-512, 512)))
                out.append(e)
        if not c_avail:
            self.cov["c_to_d"] += 1
        return out

    def random_col(self):
        rnd = self.rnd
        return [{"intra": rnd.randrange(2), "mvx": rnd.randrange(-2048, 2048), "mvy": rnd.randrange(-512, 512),
                 "ref": rnd.randrange(32), "code": rnd.randrange(256)} for _ in range(16)]

    def col_entries(self, sd, si):
        """colocated(blk) for every block with direct_8x8_inference forced 0."""
        rnd = self.rnd
        rec = self.slices[si]
        sps = sd.sps
        saved = sps.direct_8x8_inference
        sps.direct_8x8_inference = 0
        try:
            raw = [sd.colocated(b) for b in range(16)]
        finally:
            sps.direct_8x8_inference = saved
        out = []
        for mv, ident, cf, scale, cs, ref_col in raw:
            rec["col_is_field"] = int(cf)
            rec["vert_scale"] = SCALE[scale]
            if ident is None:
                out.append({"intra": 1, "mvx": rnd.randrange(-2048, 2048), "mvy": rnd.randrange(-512, 512),
                            "ref": rnd.randrange(32), "code": rnd.randrange(256), "raw": (mv, ident, cf, scale, cs, ref_col)})
                continue
            code = R.ref_code(ident)
            low = code & 63
            if low in rec["codes"] and rec["codes"][low][0] != ident:
                raise SystemExit("two co-located reference identities share code %d in one slice" % low)
            rec["codes"][low] = (ident, scale, cs)
            if low not in rec["map_probe"]:
                try:
                    sd.map_col_to_list0(ident, scale, cs)
                    rec["map_probe"][low] = 1
                except R.ReconError:
                    pass
            out.append({"intra": 0, "mvx": mv[0], "mvy": mv[1], "ref": ref_col, "code": code,
                        "raw": (mv, ident, cf, scale, cs, ref_col)})
        return out

    # ---- the case ---------------------------------------------------------------------
    @staticmethod
    def expected_of(info):
        exp = []
        for b in range(16):
            for lx in range(2):
                p = int(info.pred[lx][b])
                exp.append((p, info.ref[lx][b] if p else 0, info.mv[lx][b][0], info.mv[lx][b][1]))
        return exp

    def add(self, cls, si, m, ex, nb, col, exp, err=0):
        refs, mvd, _pred, _direct = ex
        subs = list(m.sub_types) + [0] * (4 - len(m.sub_types))
        self.cases.append({"cls": cls, "si": si, "skip": int(m.skip), "mb_type": m.mb_type or 0, "addr": m.addr,
                           "subs": subs[:4], "refs": refs, "mvd": mvd, "nb": nb, "col": col, "exp": exp, "err": err})
        self.cov[cls] += 1

    def classify(self, sd, m, ex):
        st = sd.h.slice_type
        direct = ex[3]
        if st == R.P:
            if m.skip:
                self.cov["skip"] += 1
                return "P_SKIP"
            self.cov[("16x16", "16x8", "8x16", "8x8")[m.mb_type]] += 1
            if m.mb_type == R.P_8X8:
                for t in m.sub_types:
                    self.cov["psub%d" % t] += 1
            return ("P16x16", "P16x8", "P8x16", "P8x8")[m.mb_type]
        sp = sd.h.direct_spatial
        if m.skip or m.mb_type == R.B_DIRECT_16X16:
            if m.skip:
                self.cov["skip"] += 1
            self.cov["direct16"] += 1
            self.cov["spatial" if sp else "temporal"] += 1
            return "BDIR16S" if sp else "BDIR16T"
        if m.mb_type == R.B_8X8:
            self.cov["8x8"] += 1
            for t in m.sub_types:
                self.cov["bsub%d" % t] += 1
            if any(direct):
                self.cov["direct8x8"] += 1
                self.cov["spatial" if sp else "temporal"] += 1
                return "B8x8DS" if sp else "B8x8DT"
            return "B8x8"
        if m.mb_type <= 3:
            self.cov["16x16"] += 1
            return "B16x16"
        if (m.mb_type - 4) % 2 == 0:
            self.cov["16x8"] += 1
            return "B16x8"
        self.cov["8x16"] += 1
        return "B8x16"

    def direct_coverage(self, sd, si, ex, col):
        """What a real direct macroblock exercised: vertMvScale (Table 8-8) per mode, and per
        direct 4x4 block the co-located entry the unit reads (the corner under
        direct_8x8_inference): an intra one, a negative odd / even mvCol[1] under Frm_To_Fld
        (8-193's truncation differs from a floor only on the odd ones), a raw (long-term or
        equal-POC) list-0 target, colZeroFlag."""
        rec = self.slices[si]
        spatial = rec["direct_spatial"]
        self.cov[("sp_" if spatial else "td_") + SCALE_KEY[rec["vert_scale"]]] += 1
        if rec["inference"]:
            self.cov["inference"] += 1
        for b in range(16):
            if not ex[3][b >> 2]:
                continue
            e = col[5 * (b >> 2) if rec["inference"] else b]
            if e["intra"]:
                if not spatial:
                    self.cov["td_intra_col"] += 1
                continue
            if spatial:
                if rec["l1_short"] and e["ref"] == 0 and -1 <= e["mvx"] <= 1 and -1 <= e["mvy"] <= 1:
                    self.cov["sp_col_zero"] += 1
                continue
            if rec["vert_scale"] == 1 and e["mvy"] < 0:
                self.cov["td_f2f_neg_odd" if e["mvy"] & 1 else "td_f2f_neg_even"] += 1
            code = e["code"] & 63
            try:
                idx = sd.map_col_to_list0(*rec["codes"][code])
            except (R.ReconError, KeyError):
                continue
            if rec["tdir"][idx][1]:
                self.cov["td_raw"] += 1

    # ---- synthetic variants through the model's own methods --------------------------------
    def synth_err_ref(self, sd, m, ex, nb, col, si):
        h = sd.h
        n0 = h.num_ref_idx[0]
        if n0 < 2 or n0 > 31 or self.synth_n["ERR_REF"] >= self.synth_cap:
            return
        refs = [list(ex[0][0]), list(ex[0][1])]
        refs[0][0] = n0                                   # names no list entry
        p = sd.mvp(0, 0, 16, 16, 16, 0, 0)                # the unit derives with index 0
        d = ex[1][0][0]
        exp = []
        for _b in range(16):
            exp.append((1, 0, p[0] + d[0], p[1] + d[1]))
            exp.append((0, 0, 0, 0))
        self.add("ERR_REF", si, m, (refs, ex[1], ex[2], ex[3]), nb, col, exp, err=1)
        self.synth_n["ERR_REF"] += 1

    def synth_temporal(self, sd, m, ex, nb, col, si):
        """ERR_MAP, TD_RAW and the two vertMvScale variants of a temporal direct 16x16
        macroblock."""
        rnd = self.rnd
        rec = self.slices[si]
        used = (0, 5, 10, 15) if rec["inference"] else range(16)   # the blocks the unit reads
        # a variant says something only where a co-located vector moves (x264's still
        # background gives many all-zero macroblocks, on which a dropped rule is invisible)
        moving = any(not col[i]["intra"] and (col[i]["mvx"], col[i]["mvy"]) != (0, 0) for i in used)
        if moving and self.synth_n["TD_RAW"] < self.synth_cap:
            ids = set(e.ident() for e in sd.lists[0] if e is not None)
            orig_mark = R.RefPic.marking

            def long_mark(rp):
                return R.LONG if rp.ident() in ids else orig_mark(rp)
            R.RefPic.marking = long_mark
            try:
                info2 = R.MbInfo()
                sd.temporal_direct(info2, [0, 1, 2, 3])
            finally:
                R.RefPic.marking = orig_mark
            vsi = self.slice_variant(si, tdir=[(d, 1) for d, _raw in rec["tdir"]])
            self.add("TD_RAW", vsi, m, ex, nb, col, self.expected_of(info2))
            self.synth_n["TD_RAW"] += 1
        codes = [col[i]["code"] & 63 for i in used if not col[i]["intra"] and (col[i]["code"] & 63) in rec["map_probe"]]
        if moving and codes and self.synth_n["ERR_MAP"] < self.synth_cap:
            bad = codes[0]
            orig_map = sd.map_col_to_list0

            def patched(ident, scale, cs):
                return 0 if (R.ref_code(ident) & 63) == bad else orig_map(ident, scale, cs)
            sd.map_col_to_list0 = patched
            try:
                info2 = R.MbInfo()
                sd.temporal_direct(info2, [0, 1, 2, 3])
            finally:
                del sd.map_col_to_list0
            vsi = self.slice_variant(si, drop_code=bad)
            self.add("ERR_MAP", vsi, m, ex, nb, col, self.expected_of(info2), err=1)
            self.synth_n["ERR_MAP"] += 1
        if rec["vert_scale"] != 0 or rec["field_pic"]:
            return          # a frame One_To_One slice: MapColToList0 is the same under every scale
        for cls, scale, vs in (("TD_FRM2FLD", "Frm_To_Fld", 1), ("TD_FLD2FRM", "Fld_To_Frm", 2)):
            if self.synth_n[cls] >= self.synth_cap:
                continue
            col2 = []
            for e in col:
                e2 = dict(e)
                if not e["intra"]:
                    y = e["mvy"]
                    if vs == 1:
                        y = -((abs(y) | 1) + (rnd.randrange(4) * 2))   # negative and odd
                    else:
                        y = max(-511, min(511, y))                        # the doubling must stay in range
                    e2["mvy"] = y
                    mv, ident, cf, _s, cs, ref_col = e["raw"]
                    e2["raw"] = ((mv[0], y), ident, cf, scale, cs, ref_col)
                col2.append(e2)
            inference = sd.sps.direct_8x8_inference

            def patched_col(blk, col2=col2):
                return col2[5 * (blk >> 2) if inference else blk]["raw"]
            sd.colocated = patched_col
            try:
                info2 = R.MbInfo()
                sd.temporal_direct(info2, [0, 1, 2, 3])
            finally:
                del sd.colocated
            vsi = self.slice_variant(si, vert_scale=vs)
            self.add(cls, vsi, m, ex, nb, col2, self.expected_of(info2))
            self.synth_n[cls] += 1

    def synth_spatial_edge(self, sd, m, ex, nb, col, si):
        """Only a macroblock whose colZeroFlag can matter: RefPicList1[0] short-term and a
        list with refIdx 0 and a non-zero predictor. Every co-located entry becomes an
        inter one (spatial direct reads only mvCol and refIdxCol, never the identity)
        with refIdxCol 0 (one in four keeps its own) and each component on -2..2, one
        component forced to +-1 or +-2 so both sides of the boundary are present."""
        rnd = self.rnd
        rec = self.slices[si]
        info = sd.pic.mbs[m.addr]
        live = any(info.pred[lx][b] and info.ref[lx][b] == 0 and info.mv[lx][b] != (0, 0)
                   for lx in range(2) for b in range(16))
        if self.synth_n["SP_EDGE"] >= self.synth_cap or not rec["l1_short"] or not live:
            return
        col2 = []
        for e in col:
            e2 = dict(e)
            mv, ident, cf, s, cs, ref_col = e["raw"]
            x, y = rnd.choice((-2, -1, 0, 1, 2)), rnd.choice((-2, -1, 0, 1, 2))
            if rnd.randrange(2):
                x = rnd.choice((-2, -1, 1, 2))
            else:
                y = rnd.choice((-2, -1, 1, 2))
            ref = rnd.choice((0, 0, 0, max(ref_col, 0)))
            e2["intra"], e2["mvx"], e2["mvy"], e2["ref"] = 0, x, y, ref
            e2["raw"] = ((x, y), ident if ident is not None else (-1, "F"), cf, s, cs, ref)
            col2.append(e2)
        inference = sd.sps.direct_8x8_inference

        def patched_col(blk, col2=col2):
            return col2[5 * (blk >> 2) if inference else blk]["raw"]
        sd.colocated = patched_col
        try:
            info2 = R.MbInfo()
            sd.spatial_direct(info2, [0, 1, 2, 3])
        finally:
            del sd.colocated
        self.add("SP_EDGE", si, m, ex, nb, col2, self.expected_of(info2))
        self.synth_n["SP_EDGE"] += 1


def run(data, cap):
    records = FE.decode_stream(data)
    orig = R.SliceDecoder.decode_mb

    def wrapped(self, m):
        st = self.h.slice_type
        base = {R.I: 0, R.P: 5, R.B: 23}[st]
        inter = st != R.I and (m.skip or m.mb_type - base < 0)
        if not inter:
            return orig(self, m)
        ex = R.expand_mb(m, st, self.h.num_ref_idx)
        self.addr = m.addr                       # colocated() addresses the current macroblock
        si = cap.slice_index(self)
        nb = cap.nb_entries(self, m.addr)
        direct = m.skip or (st == R.B and (m.mb_type == R.B_DIRECT_16X16 or any(ex[3])))
        col = cap.col_entries(self, si) if (st == R.B and direct) else cap.random_col()
        orig(self, m)
        info = self.pic.mbs[m.addr]
        cls = cap.classify(self, m, ex)
        if self.pic.field:
            cap.cov["field"] += 1
        cap.add(cls, si, m, ex, nb, col, cap.expected_of(info))
        if st == R.B and direct:
            cap.direct_coverage(self, si, ex, col)
        if cap.synth:
            if cls == "P16x16":
                cap.synth_err_ref(self, m, ex, nb, col, si)
            elif cls == "BDIR16T":
                cap.synth_temporal(self, m, ex, nb, col, si)
            elif cls == "BDIR16S":
                cap.synth_spatial_edge(self, m, ex, nb, col, si)

    R.SliceDecoder.decode_mb = wrapped
    try:
        dec = R.Decoder()
        dec.feed(records)
    finally:
        R.SliceDecoder.decode_mb = orig
    cap.finish_slices()


def cap_cases(cap, limit):
    """Keep at most `limit` cases, class-balanced: the rarer classes whole, the bulk
    (P_Skip, B_Skip on a disc) sampled; decode order preserved. The class counts in the
    meta and the coverage report stay those of the whole window."""
    if len(cap.cases) <= limit:
        return
    by_cls = {}
    for i, c in enumerate(cap.cases):
        by_cls.setdefault(c["cls"], []).append(i)
    keep = []
    budget = limit
    order = sorted(by_cls, key=lambda k: len(by_cls[k]))
    for n, k in enumerate(order):
        share = budget // (len(order) - n)
        idx = by_cls[k]
        if len(idx) > share:
            idx = cap.rnd.sample(idx, share)
        keep.extend(idx)
        budget -= len(idx)
    keep.sort()
    cap.cases = [cap.cases[i] for i in keep]


def write(stem, cap):
    os.makedirs(os.path.dirname(stem) or ".", exist_ok=True)
    with open(stem + ".case.hex", "w") as f:
        for c in cap.cases:
            w = [0] * WORDS_CASE
            w[0] = (c["si"] & 0xFFFF) | (c["skip"] << 16) | ((c["mb_type"] & 63) << 17) | (c["err"] << 23) | (CID[c["cls"]] << 24)
            w[1] = sum((t & 15) << (4 * i) for i, t in enumerate(c["subs"])) | ((c["addr"] & 0xFFFF) << 16)
            for lx in range(2):
                w[2 + lx] = sum((r & 31) << (5 * i) for i, r in enumerate(c["refs"][lx]))
                for b in range(16):
                    dx, dy = c["mvd"][lx][b]
                    w[4 + 16 * lx + b] = (u16(dy) << 16) | u16(dx)
            for k, e in enumerate(c["nb"]):
                (p0, r0, x0, y0), (p1, r1, x1, y1) = e["L"]
                w[36 + 3 * k] = (u16(y0) << 16) | u16(x0)
                w[37 + 3 * k] = (u16(y1) << 16) | u16(x1)
                w[38 + 3 * k] = e["avail"] | (e["intra"] << 1) | (p0 << 2) | ((r0 & 63) << 3) | (p1 << 9) | ((r1 & 63) << 10)
            for b, e in enumerate(c["col"]):
                w[66 + 2 * b] = (u16(e["mvy"]) << 16) | u16(e["mvx"])
                w[67 + 2 * b] = (e["ref"] & 31) | ((e["code"] & 255) << 5) | (e["intra"] << 13)
            for i, (p, r, x, y) in enumerate(c["exp"]):
                w[98 + 2 * i] = (u16(y) << 16) | u16(x)
                w[99 + 2 * i] = (r & 31) | (p << 5)
            f.write("".join("%08x\n" % v for v in w))
    with open(stem + ".slice.hex", "w") as f:
        for rec in cap.slices:
            s = [0] * WORDS_SLICE
            s[0] = (rec["slice_type"] & 3) | (rec["direct_spatial"] << 2) | (rec["inference"] << 3) | (rec["field_pic"] << 4) \
                | (rec["cur_struct"] << 5) | (rec["num_ref"][0] << 7) | (rec["num_ref"][1] << 13) | (rec["l1_short"] << 19) \
                | (rec["col_is_field"] << 20) | (rec["vert_scale"] << 21)
            s[1] = rec["list0_long"] & 0xFFFFFFFF
            for code, idx in rec["map"].items():
                if code == rec.get("drop_code"):
                    continue
                s[2 + code] = (idx & 31) | (1 << 5)
            for i, (dsf, raw) in enumerate(rec["tdir"]):
                s[66 + i] = (dsf & 0x7FF) | (raw << 11)
            f.write("".join("%08x\n" % v for v in s))
    with open(stem + ".meta.hex", "w") as f:
        meta = [len(cap.cases), len(cap.slices), WORDS_CASE, WORDS_SLICE] + [cap.cov[k] for k in CLASSES]
        f.write("".join("%08x\n" % v for v in meta))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--x264", help="an Annex-B stream")
    ap.add_argument("--out", required=True, help="fixture stem")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--require", default="", help="comma-separated coverage keys that must be > 0")
    ap.add_argument("--no-synth", action="store_true", help="no synthetic classes")
    ap.add_argument("--synth-cap", type=int, default=6, help="synthetic cases per class")
    ap.add_argument("--cap", type=int, default=12000, help="cases kept (class-balanced sample; 0 = all)")
    a = ap.parse_args(argv)
    if a.x264:
        data = open(a.x264, "rb").read()
    else:
        ap.error("--x264 (any Annex-B stream)")
    cap = Capture(random.Random(a.seed), synth=not a.no_synth, synth_cap=a.synth_cap)
    run(data, cap)
    n_all = len(cap.cases)
    if a.cap:
        cap_cases(cap, a.cap)
    write(a.out, cap)
    print("%s: %d cases%s, %d slice records" % (a.out, len(cap.cases), "" if len(cap.cases) == n_all else " of %d" % n_all,
                                                len(cap.slices)))
    print("  classes: " + " ".join("%s=%d" % (k, cap.cov[k]) for k in CLASSES if cap.cov[k]))
    print("  coverage: " + " ".join("%s=%d" % (k, cap.cov[k]) for k in COV_KEYS if cap.cov[k]))
    missing = [k for k in a.require.split(",") if k and cap.cov.get(k, 0) == 0]
    if missing:
        raise SystemExit("coverage missing: %s" % ", ".join(missing))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (R.ReconError, FE.Refused, FE.FeError) as e:
        sys.exit("mv_pred_golden: %s" % e)
