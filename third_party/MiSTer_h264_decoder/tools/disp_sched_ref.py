#!/usr/bin/env python3
"""disp_sched_ref.py -- the display scheduler's reference (roadmap P5e, docs/display.md
S7): which store the 480p raster shows at every refresh, and with which field parity,
given the output queue's records (h264/recon_out.sv) -- exact to the 90 kHz tick -- and
the stimulus scenarios bench/h264/disp_sched_tb.sv plays (tools-side generator).

THE RULES (written from the spec and MiSTer_DVD's scheduler notes, not from the RTL):

  duration   a store lasts n_ticks clock ticks (Table E-6 DeltaTfiDivisor): a frame 2,
             or its pic_struct's 0/3/4 -> 2, 5/6 -> 3, 7 -> 4, 8 -> 6; a field 1 (a pair
             1 + 1). A tick is num_units_in_tick / time_scale s (C-1): field_q3 =
             720000 * nuit // ts eighth-ticks of 90 kHz (Q3; 4004 / 240000 -> 12012,
             5005 / 240000 -> 15015). No VUI timing (or ts 0): 12012 (59.94) and a flag.
             A quotient >= 2^24 is clamped (a tick over 23 s) and flagged. A pic_struct
             that does not fit the store (1/2 on a frame, 0/3-8 on a field, 9-15) takes
             the default and is flagged.
  time       STC counts 90 kHz ticks, one per 300 clk_sys cycles, phased to the raster:
             P = 0 at the first (h 0, v 0) after reset, ticks at P = 300 m (m >= 1).
             A refresh is 858 x 525 = 450,450 cycles (1501.5 ticks). Refresh k's
             decision is evaluated with the STC of cycle P_eval(k) = 450450 k + 499 x 858
             and taken at P_pick(k) = 450450 k + 500 x 858 (vertical blanking: after the
             last line's fetch, before line 0's). An anchor at P_pick sets STC there; it
             then counts the ticks at P_pick+1 .. Q-1 as seen in cycle Q.
  due        the head record (if present at P_eval) is due when STC >= want - 750
             (half a refresh), want = its PTS when tagged (a pair's second-field PTS
             minus one tick when only that one is), else the timeline's next PTS.
  anchor     the first head ever, or a TAGGED head that has jumped: more than one frame
             (2 ticks) BEHIND the timeline, more than 0.5 s (45000) AHEAD of it, or
             more than 2.7 s (243000) late -- re-anchors STC to it (an untagged first
             head anchors at 0). Lateness below that is NOT a jump: a late picture is
             simply shown at once (MiSTer_DVD's HW round B). (Interface 1.1, docs/architecture.md
             "Queued audio: a late picture never runs the clock back over it") while the audio
             LEADS (aud_lead: the queued audio was written ahead of the clock and has neither run
             dry nor come late since) lateness never anchors: the 2.7 s leg is gone, the other two
             (and the first head's) stay. A scenario's records carry it as `lead`.
  lone PTS   (UMD fix/film-timing PR fj#25 + fix/lone-early PR fj#26, ported 2026-09-30; UMD
             docs/display.md S10, this tree's display.md S10) a TAGGED head more than half a
             refresh and at most 0.5 s AHEAD of the timeline or BEHIND it (HALF < |PTS - next|
             <= 45000), not late past LATE_MAX, is DISBELIEVED -- taken as untagged, on the
             timeline -- unless the previous tag taken was disbelieved too: the next tag is
             always believed (a real gap is waited out one tag later). UMD's discs carry lone
             PES PTS 1-8 ticks off on one GOP-opening PES, the next tag back on the old
             timeline: believing one held a picture ~3x and then re-anchored the STC back. The
             edge is half a refresh, not a frame. A real backward edit under 0.5 s is corrected
             one tag late; a larger jump either way re-anchors at once, as before. The flag is
             set by a pickup of a disbelieved head, cleared by a pickup of a believed tagged one
             (and by the stream's reset); `lone` counts the disbelieved pickups.
  pickup     at P_pick, a due head is taken: the store shown until then is released,
             the timeline's next PTS = want (or the anchor) + the duration. The END
             record is taken at the first pickup it heads; the last store stays.
  low        (LOW_LATENCY, roadmap P3f) every head is due at the pickup (the STC still anchors
  latency    and runs); `late` is not counted (no pacing, nothing is late); and at line 490,
             when a picture is shown and another PICTURE waits behind the head with no END
             queued yet (recon_out's rec_more), the head is taken and released unseen:
             `skip`, one a refresh at most.
  parity     a field store shows parity first_bot ^ (refreshes since its pickup) & 1;
             a single field its own parity; a frame 0.
  the field  (P7, --il: 480i / 576i; UMD's V6, its PR fj#37) a refresh is a raster FIELD, and the
             raster shows each field's own lines of a field store: a pair must start on the raster
             field of its first field, or it plays later-field-first (measured on the RetroTINK at
             576i, docs/history.md §35). Refresh 0 is the TOP field (the raster's alignment point is
             the top field's first dot), refresh k's field is k & 1, and the store taken at refresh
             k's pickup is first shown in refresh k + 1. So a due PAIR whose first_bot != (k + 1) & 1
             is not taken -- unless it is LATE (below: due at the previous refresh already) -- it
             waits one refresh (`fhold`), the shown store stays one refresh more. The refresh after
             a hold does not count its pickup late, nor judges the held store's cadence. Frames and
             single fields are never held; nothing is held on a progressive raster.
  counters   dc: the decided (store, parity) changes (a pickup, a field store's parity
             step); reanchors; late: pickups of a head that was ALREADY due at the
             previous refresh's eval (STC then >= want - 750, the same timeline: no
             anchor between) -- a missed opportunity, starved or backlogged. (A first
             draft counted STC - want > 750 at the pickup: 23.976 frames last 2.5
             refreshes, so every other one is taken ~750 ticks after its PTS -- the best
             a 59.94 raster can do -- and phase noise pushed some over; X-Men 2 read
             LT 21 a minute on the rig with the decoder ahead, 2026-09-26);
             cadence: a store held for a refresh count outside {floor, ceil} of its
             duration / 12012, judged at the next pickup when that one is contiguous
             (not an anchor, |its PTS - the timeline| < 750, no starved refresh between).

  standards  (P6 steps 5 / 6, docs/analog.md §10) the raster's refresh RF and its events:
             59.94 Hz RF 450,450, eval / pickup at 499 / 500 x 858, half 750, a refresh 12,012
             eighth-ticks; 60.00 Hz RF 450,000, the same event offsets, half 750, 12,000;
             50 Hz RF 540,000, eval / pickup at 599 / 600 x 864, half 900, 14,400. The
             no-VUI default tick stays 12,012 (the content's, not the raster's).
  rate       (Refresh Rate's Auto) the first picture's VUI tick classified: field_q3 3,000 /
             6,000 / 12,000 / 15,000 -> 1 (60.00 Hz), 3,600 / 7,200 / 14,400 -> 2 (50 Hz),
             else or no timing -> 0.

    disp_sched_ref.py --scenario NAME[@STD] --out STEM     the stimulus + the expected refreshes
    disp_sched_ref.py --list
"""
import argparse
import sys

FRAME = 450450
P_EVAL = 499 * 858
P_PICK = 500 * 858
HALF = 750
REF_Q3 = 12012                 # one refresh, eighth-ticks
DEFAULT_FQ = 12012             # no VUI timing: a 59.94 field (the content's default, any raster)
STD = 0
FWD_MAX = 45000
LATE_MAX = 243000
DIV = {0: 2, 3: 2, 4: 2, 5: 3, 6: 3, 7: 4, 8: 6}
Q3_MAX = (1 << 24) - 1


def set_std(std):
    """the raster standard's refresh and events (docs/analog.md §10)"""
    global FRAME, P_EVAL, P_PICK, HALF, REF_Q3, STD
    STD = std
    if std == 2:
        FRAME, P_EVAL, P_PICK, HALF, REF_Q3 = 540000, 599 * 864, 600 * 864, 900, 14400
    elif std == 1:
        FRAME, P_EVAL, P_PICK, HALF, REF_Q3 = 450000, 499 * 858, 500 * 858, 750, 12000
    else:
        FRAME, P_EVAL, P_PICK, HALF, REF_Q3 = 450450, 499 * 858, 500 * 858, 750, 12012


def rate_cls(r):
    """Refresh Rate's Auto: the class of a picture's VUI tick"""
    fq, ff = field_q3(r)
    if ff:
        return 0
    return 1 if fq in (3000, 6000, 12000, 15000) else 2 if fq in (3600, 7200, 14400) else 0


def ticks_between(a, b):
    """ticks at P = 300 m, m >= 1, with a <= P <= b"""
    if b < a:
        return 0
    lo = max(1, -(-a // 300))
    hi = b // 300
    return max(0, hi - lo + 1)


class Rec(object):
    FIELDS = ("avail", "store", "frame", "unpaired", "first_bot", "dec_t", "dec_b", "ps_a", "ps_a_v",
              "ps_b", "ps_b_v", "pts", "pts_v", "pts_b", "pts_b_v", "timing_v", "nuit", "ts", "w", "hf")

    def __init__(self, **kw):
        self.end = kw.pop("end", False)
        for f in self.FIELDS:
            setattr(self, f, kw.get(f, 0))

    def line(self):
        if self.end:
            return "E %d" % self.avail
        return "R " + " ".join(str(getattr(self, f)) for f in self.FIELDS)


def field_q3(r):
    """(Q3 ticks of one clock tick, flag bits: 1 no timing, 2 clamped / ts 0)"""
    if not r.timing_v or r.ts == 0:
        return DEFAULT_FQ, (1 if not r.timing_v else 2)
    q = (720000 * r.nuit) // r.ts
    if q > Q3_MAX:
        return Q3_MAX, 2
    if q == 0:
        return DEFAULT_FQ, 2
    return q, 0


def n_ticks(r):
    """(DeltaTfiDivisor total, pic_struct error)"""
    if r.frame:
        if r.ps_a_v:
            if r.ps_a in DIV:
                return DIV[r.ps_a], 0
            return 2, 1
        return 2, 0
    err = 0
    a = 1
    if r.ps_a_v and r.ps_a not in (1, 2):
        err = 1
    if r.unpaired:
        return 1, err
    if r.ps_b_v and r.ps_b not in (1, 2):
        err = 1
    return 2, err


def simulate(recs, n_refresh, n_store=20, ll=False, il=False, lead=False):
    """recs: Rec list (store fields ignored: assigned here, lowest free at emission).
    Returns (per refresh [(valid, store, parity, field, single, late_pair)], counters, recs with stores).
    late_pair: the shown store is a field pair taken LATE (P7: at 480i it may be off its field --
    the bench's [field] arm skips those refreshes, and only those).
    single: the shown store is one field (the reader bobs it in every deinterlace mode)."""
    held = set()                       # emitted, not released
    q = []                             # the queue (emitted, not taken)
    todo = list(recs)
    anchored = False
    stc = 0
    stc_anchor = None                  # (value, P_pick) of the last anchor
    next_q3 = 0
    next_valid = False
    cur = None                         # the shown record
    idx = 0
    ended = False
    starved = False
    cnt = {"dc": 0, "reanchors": 0, "late": 0, "cadence": 0, "flags": 0, "pickups": 0, "starve": 0, "skip": 0, "lone": 0,
           "fhold": 0,
           "rate": next((rate_cls(r) for r in recs if not r.end), 0)}
    anchored_prev_eval = False             # the STC ran at the previous refresh's eval
    anchored_at_prev_pick = False          # the previous pickup re-anchored it
    s_prev = 0                             # the previous refresh's eval STC
    susp = False                           # the previous tag taken was disbelieved (a lone PTS)
    held_prev = False                      # the previous refresh held a due pair for the field
    out = []

    def stc_at(Q):
        if not anchored:
            return 0
        v, pp = stc_anchor
        return (v + ticks_between(pp + 1, Q - 1)) & ((1 << 33) - 1)

    for k in range(n_refresh):
        # emissions for this refresh (frame k, line 10): the lowest free store
        while todo and todo[0].avail <= k:
            r = todo.pop(0)
            if not r.end:
                free = [s for s in range(n_store) if s not in held]
                if not free:
                    raise RuntimeError("scenario needs more than %d stores at refresh %d" % (n_store, k))
                r.store = free[0]
                held.add(r.store)
            q.append(r)
        # low latency: line 490, a head a newer picture waits behind goes unseen
        if ll and cur is not None and not ended and len(q) >= 2 and not q[0].end and not q[1].end \
                and not any(x.end for x in q):
            held.discard(q.pop(0).store)
            cnt["skip"] += 1
        pe = FRAME * k + P_EVAL
        pp = FRAME * k + P_PICK
        s_e = stc_at(pe)
        prev_ok = anchored_prev_eval and not anchored_at_prev_pick
        anchored_prev_eval = anchored
        anchored_at_prev_pick = False
        took = False
        h = q[0] if q else None
        if h is not None and h.end:
            q.pop(0)
            ended = True
            h = None
        if h is not None and not ended:
            fq, ff = field_q3(h)
            nt, pe_err = n_ticks(h)
            dur = nt * fq
            tick_t = fq >> 3
            frame_t = fq >> 2
            if h.pts_v:
                tag, pts_eff = True, h.pts
            elif h.pts_b_v and not h.frame and not h.unpaired:
                tag, pts_eff = True, (h.pts_b - tick_t) & ((1 << 33) - 1)
            else:
                tag, pts_eff = False, 0
            next_pts = (next_q3 >> 3) & ((1 << 33) - 1)
            # a lone PTS ahead of or behind the timeline: disbelieved (taken as untagged)
            lone = (tag and anchored and next_valid and not susp and
                    HALF < abs(pts_eff - next_pts) <= FWD_MAX and s_e - pts_eff <= LATE_MAX)
            if lone:
                tag = False
            want = pts_eff if tag else (next_pts if next_valid else s_e)
            d_pic_next = pts_eff - next_pts
            d_stc_pic = s_e - pts_eff
            disc = tag and anchored and next_valid and (d_pic_next < -frame_t or d_pic_next > FWD_MAX
                                                         or (d_stc_pic > LATE_MAX and not lead))
            anchor_now = (not anchored) or (tag and (not next_valid or disc))
            due = anchor_now or ll or (s_e - want >= -HALF)
            late_raw = not anchor_now and not ll and prev_ok and (s_prev - want >= -HALF)
            fhold = il and not late_raw and not h.frame and not h.unpaired and h.first_bot != ((k + 1) & 1)
            if due and fhold:
                cnt["fhold"] += 1
            if due and not fhold:
                took = True
                q.pop(0)
                cnt["pickups"] += 1
                cnt["flags"] |= ff | (4 if pe_err else 0)
                # the previous store's cadence, judged when this one is contiguous
                if cur is not None and not anchor_now and not starved and not held_prev and \
                        (not tag or abs(d_pic_next) < HALF):
                    lo, hi = cur_dur // REF_Q3, -(-cur_dur // REF_Q3)
                    if not (lo <= idx + 1 <= hi):
                        cnt["cadence"] += 1
                if not anchor_now and not ll and prev_ok and not held_prev and (s_prev - want >= -HALF):
                    cnt["late"] += 1
                if anchor_now:
                    anchored_at_prev_pick = True
                    av = pts_eff if tag else 0
                    cnt["reanchors"] += 1
                    anchored = True
                    stc_anchor = (av, pp)
                    next_q3 = (av << 3) + dur
                else:
                    next_q3 = (want << 3) + dur
                next_valid = True
                if lone:
                    susp = True
                    cnt["lone"] += 1
                elif tag:
                    susp = False
                if cur is not None:
                    held.discard(cur.store)
                cur = h
                # a pair taken late, not just after its hold (that one is on its field): maybe off it
                cur_late = bool(late_raw and not held_prev and not h.frame and not h.unpaired)
                cur_dur = dur
                idx = 0
                starved = False
                cnt["dc"] += 1
        if not took:
            if cur is not None:
                idx += 1
                if not cur.frame and not cur.unpaired:
                    cnt["dc"] += 1               # the pair's other field
            if (not q or q[0].end) and anchored and next_valid and not ended:
                if s_e - ((next_q3 >> 3) & ((1 << 33) - 1)) >= -HALF:
                    starved = True
                    cnt["starve"] += 1
        s_prev = s_e
        held_prev = bool(h is not None and not ended and due and fhold)
        if cur is None:
            out.append((0, 0, 0, 0, 0, 0))
        else:
            field = 0 if cur.frame else 1
            if cur.frame:
                par = 0
            elif cur.unpaired:
                par = 1 if (cur.dec_b and not cur.dec_t) else 0
            else:
                par = (cur.first_bot ^ (idx & 1)) & 1
            out.append((1, cur.store, par, field, 1 if (not cur.frame and cur.unpaired) else 0, 1 if cur_late else 0))
    return out, cnt, recs


# ---- scenarios ---------------------------------------------------------------------------

def frames(n, ps_cycle, pts0, tag_every, nuit=4004, ts=240000, avail0=0, lead=3, ps_v=1, start=0, t0=0.0,
           ceil_pts=False):
    """n frame records; PTS on every tag_every-th (exact 90 kHz of the running Q3 sum);
    record i available `lead` refreshes before its nominal display refresh (t0 + the
    durations before it)"""
    recs = []
    q3 = pts0 << 3
    fq = (720000 * nuit) // ts
    t_ref = float(t0)
    for i in range(start, start + n):
        ps = ps_cycle[i % len(ps_cycle)] if ps_cycle else 0
        nt = DIV.get(ps, 2) if ps_v else 2
        disp_ref = int(t_ref)
        recs.append(Rec(avail=max(avail0, disp_ref - lead), frame=1, dec_t=1, dec_b=1, ps_a=ps, ps_a_v=ps_v,
                        pts=(-(-q3 // 8) if ceil_pts else q3 >> 3), pts_v=int(i % tag_every == 0), timing_v=1,
                        nuit=nuit, ts=ts, w=45, hf=30))
        q3 += nt * fq
        t_ref += nt * fq / REF_Q3
    return recs


def pairs(n, first_bot, pts0, tag_every, avail0=0, lead=3, nuit=4004, ts=240000):
    recs = []
    q3 = pts0 << 3
    fq = (720000 * nuit) // ts
    for i in range(n):
        ps_a, ps_b = (2, 1) if first_bot else (1, 2)
        recs.append(Rec(avail=max(avail0, 2 * i - lead), frame=0, first_bot=first_bot, dec_t=1, dec_b=1,
                        ps_a=ps_a, ps_a_v=1, ps_b=ps_b, ps_b_v=1, pts=q3 >> 3, pts_v=int(i % tag_every == 0),
                        timing_v=1, nuit=nuit, ts=ts, w=45, hf=30))
        q3 += 2 * fq
    return recs


def fields(n, pts0, tag_every, lead=3, t0=0):
    """n single top fields (1 tick each: one refresh -- the display's maximum rate)"""
    recs = []
    for i in range(n):
        recs.append(Rec(avail=max(0, t0 + i - lead), frame=0, unpaired=1, dec_t=1, dec_b=0, ps_a=1, ps_a_v=1,
                        pts=((pts0 << 3) + i * 12012) >> 3, pts_v=int(i % tag_every == 0), timing_v=1, nuit=4004,
                        ts=240000, w=45, hf=30))
    return recs


def end_at(recs, extra=4):
    last = max(r.avail for r in recs)
    return recs + [Rec(end=True, avail=last + extra)]


def scenario(name):
    """(records, refreshes to simulate); NAME@STD runs it on that raster standard"""
    if "@" in name:
        base, std = name.split("@")
        set_std(int(std))
        return scenario(base)
    P0 = 1000000
    # the standards' own content (P6 steps 5 / 6): 60.000 / 24.000 on the 60.00 Hz raster,
    # 25 / 50 on the 50 Hz one (and every scenario below may run on any raster: NAME@STD)
    if name == "p60":                             # 60.000 progressive, tagged: one a refresh at 60.00 Hz
        return end_at(frames(120, None, P0, 1, nuit=1000, ts=120000, ps_v=0)), 140
    if name == "p60ll":                           # a Moonlight session: 60.000, LOW_LATENCY
        return _ll(end_at(frames(60, None, P0, 1, nuit=1000, ts=120000, ps_v=0, lead=0))), 80
    if name == "p24":                             # 24.000 progressive: exactly 2.5 refreshes at 60.00 Hz
        return end_at(frames(80, None, P0, 8, nuit=1000, ts=48000, ps_v=0)), 220
    if name == "p25":                             # 25p: two refreshes a frame at 50 Hz
        return end_at(frames(80, None, P0, 8, nuit=1000, ts=50000, ps_v=0)), 180
    if name == "p50":                             # 50p, tagged: one a refresh
        return end_at(frames(120, None, P0, 1, nuit=1000, ts=100000, ps_v=0)), 140
    if name == "i25":                             # 25i field pairs, top first: a field a refresh
        return end_at(pairs(80, 0, P0, 10, nuit=1, ts=50)), 180
    if name == "film32":                          # C1 3:2 film on frames
        r = frames(120, [5, 4, 6, 3], P0, 12)
        return end_at(r), 320
    if name == "prog24":                          # C2 23.976 progressive: 2.5 refreshes a frame
        r = frames(120, None, P0, 12, nuit=5005, ps_v=0)
        return end_at(r), 320
    if name == "prog24r":                         # C2' the disc's phase: time stamps rounded UP --
        # every other frame lands 750.75 ticks past a refresh and is taken at the next one:
        # the best a 59.94 raster can do, NOT late (X-Men 2 on the rig, 2026-09-26)
        r = frames(120, None, P0, 1, nuit=5005, ps_v=0, ceil_pts=True)
        return end_at(r), 320
    if name == "tff":                             # C3 field pairs, top first / bottom first
        return end_at(pairs(120, 0, P0, 15)), 260
    if name == "bff":
        return end_at(pairs(120, 1, P0, 15)), 260
    if name == "fldmix":                          # (P7) frames, a 3-field frame (the phase flips), top-first
        # pairs, then bottom-first pairs: at 480i one of the two pair runs starts off the raster's
        # field and is held EVERY pair (a hold mid-stream: the late / cadence exemptions), the
        # other at most once
        r = frames(20, [0] * 19 + [5], P0, 4)
        t = 19 * 2 + 3
        tp = pairs(30, 0, P0, 5) + pairs(30, 1, P0, 5)
        q3 = (P0 << 3) + t * 12012
        for i, x in enumerate(tp):
            x.avail += t + (60 if i >= 30 else 0)
            x.pts = q3 >> 3
            q3 += 2 * 12012
        return end_at(r + tp), 200
    if name == "ps78":                            # C4 frame doubling / tripling
        r = frames(60, [7, 8, 0], P0, 6)
        return end_at(r), 260
    if name == "unpaired":                        # C5 single fields (1 tick) among pairs
        r = pairs(40, 0, P0, 10)
        for i in (7, 19, 30):
            r[i].unpaired, r[i].dec_b, r[i].ps_b_v = 1, 0, 0
        # the timeline after a single field is one tick shorter: re-stamp the tags
        q3 = P0 << 3
        for x in r:
            if x.pts_v:
                x.pts = q3 >> 3
            q3 += (1 if x.unpaired else 2) * 12012
        return end_at(r), 120
    if name == "geom":                            # C6 sizes and no VUI timing (the default, flagged)
        r = frames(40, None, P0, 8)
        for i, x in enumerate(r):
            x.w, x.hf = (30, 17) if i % 3 == 0 else (45, 30)
            if i >= 20:
                x.timing_v = 0
        return end_at(r), 120
    if name == "late":                            # [5] a late decoder: pictures 30-59 grow late
        r = frames(90, [5, 4, 6, 3], P0, 12, lead=3)
        for i in range(30, 60):
            r[i].avail += (i - 29) // 2
        for i in range(60, 90):
            r[i].avail = max(r[i].avail, r[59].avail)
        return end_at(r), 300
    if name == "fldlate":                         # (P7) [5] on field pairs: pairs 30-59 grow late, by
        # odd refresh counts too -- at 480i a LATE pair is taken at once, even off its field (the
        # backlog catches up), and the pairs after it are held back into phase
        r = pairs(90, 0, P0, 6)
        for i in range(30, 60):
            r[i].avail += (i - 29) // 2 + (i - 29) // 3
        for i in range(60, 90):
            r[i].avail = max(r[i].avail, r[59].avail)
        return end_at(r), 300
    # the second segment is displayed right after the first (60 film frames = 150
    # refreshes); only its PTS jumps. First picture of each segment tagged.
    if name == "back":                            # [7a] PTS restarts 5 s back
        r = frames(60, [5, 4, 6, 3], P0, 12) + frames(60, [5, 4, 6, 3], P0 - 450000, 12, start=60, t0=150)
        return end_at(r), 320
    if name == "back200":                         # [7d] 200 ms back: under LATE_MAX, only the backward leg
        r = frames(60, [5, 4, 6, 3], P0, 12) + frames(60, [5, 4, 6, 3], 0, 12, start=60, t0=150)
        _shift_pts(r, 60, r[59].pts - 18000)
        return end_at(r), 320
    if name == "backfld":                         # [7e] 200 ms back on single fields: the picture after
        # the anchor is taken at the very next refresh, so "already due at the previous one"
        # must not be judged with the OLD timeline's STC (D13)
        r = fields(60, P0, 10) + fields(60, P0 + 60 * 1501 - 18000, 10, t0=60)
        return end_at(r), 140
    if name == "gap03":                           # [7b] a 0.3 s forward gap is waited out
        r = frames(60, [5, 4, 6, 3], P0, 12) + frames(60, [5, 4, 6, 3], 0, 12, start=60, t0=150)
        _shift_pts(r, 60, r[59].pts + 60060 // 8 + 27000)
        return end_at(r), 340
    if name == "gap2s":                           # [7c] a 2 s forward gap re-anchors
        r = frames(60, [5, 4, 6, 3], P0, 12) + frames(60, [5, 4, 6, 3], 0, 12, start=60, t0=150)
        _shift_pts(r, 60, r[59].pts + 180000)
        return end_at(r), 320
    if name == "held":                            # [8] a 4 s held still: past LATE_MAX
        r = frames(80, [5, 4, 6, 3], P0, 12)
        for i in range(40, 80):
            r[i].avail = r[i].avail + 240
        return end_at(r), 520
    if name == "heldlead":                        # (1.1) [8] with the audio leading: no re-anchor
        r, n = scenario("held")
        for x in r:
            x.lead = 1
        return r, n
    if name == "starve400":                       # [8b] a 400 ms starvation is NOT a re-anchor
        r = frames(100, [5, 4, 6, 3], P0, 12)
        for i in range(40, 100):
            r[i].avail = r[i].avail + 24
        return end_at(r), 340
    # ---- lone PTS (UMD PR fj#25 + fj#26; display.md S10): UMD's discs' shapes ----
    if name == "lone7":                           # [L1] 3:2 film; lone tags +7 ticks (record 48, the next
        # tag on the old timeline) and +8 (record 84: the flag was cleared by the believed tag
        # between: record 72, +600 ticks -- under the edge, believed, carried on); record 108
        # +1 tick (over the edge, disbelieved)
        r = frames(120, [5, 4, 6, 3], P0, 12)
        r[48].pts += 10511
        r[72].pts += 600
        r[84].pts += 12012
        r[108].pts += 1501
        return end_at(r), 320
    if name == "lonefld":                         # [L2] field pairs, a lone tag +5 ticks
        r = pairs(120, 0, P0, 15)
        r[45].pts += 7508
        return end_at(r), 260
    if name == "lone2":                           # [L3] a real +7-tick gap from record 48: its tag is
        # disbelieved, the next (60) believed -- the gap waited out one tag later
        r = frames(120, [5, 4, 6, 3], P0, 12)
        for x in r[48:]:
            x.pts += 10511
        return end_at(r), 330
    if name == "loneearly":                       # [L4] rule B: 23.976 progressive, a lone tag one frame
        # and half a tick EARLY (-3,754.5 ticks; the timeline's whole ticks read -3,746)
        r = frames(120, None, P0, 12, nuit=5005, ps_v=0)
        r[48].pts -= 3755
        return end_at(r), 320
    if name == "loneearlyfld":                    # [L5] rule B: field pairs, a lone tag 3 ticks early
        r = pairs(120, 0, P0, 15)
        r[45].pts -= 4504
        return end_at(r), 260
    if name == "back1s":                          # [7f] 1 s back: past FWD_MAX, under LATE_MAX -- not a
        # lone PTS, re-anchors at once (the band's lower bound)
        r = frames(60, [5, 4, 6, 3], P0, 12) + frames(60, [5, 4, 6, 3], 0, 12, start=60, t0=150)
        _shift_pts(r, 60, r[59].pts - 90000)
        return end_at(r), 320
    # low latency (P3f): one 59.94 picture a refresh, shown the refresh after it arrives
    if name == "llsteady":
        return _ll(end_at(frames(60, None, P0, 1, nuit=1001, ts=120000, ps_v=0, lead=0))), 80
    if name == "llearly":                         # arriving 3 refreshes ahead of their PTS: shown at once
        return _ll(end_at(frames(60, None, P0, 1, nuit=1001, ts=120000, ps_v=0, lead=3))), 80
    if name == "llburst":                         # three at once (a network burst): two skipped
        r = frames(60, None, P0, 1, nuit=1001, ts=120000, ps_v=0, lead=0)
        for i in (21, 22, 40, 41, 42):
            r[i].avail = r[20 if i < 40 else 39].avail
        return _ll(end_at(r)), 80
    if name == "llend":                           # a burst at the stream's END: the last picture shows
        r = frames(30, None, P0, 1, nuit=1001, ts=120000, ps_v=0, lead=0)
        for i in (27, 28, 29):
            r[i].avail = r[26].avail
        return _ll(end_at(r, extra=0)), 40
    raise KeyError(name)


def _ll(recs):
    for r in recs:
        r.ll = 1
    return recs


def _shift_pts(r, i0, new0):
    base = r[i0].pts
    for x in r[i0:]:
        x.pts = x.pts - base + new0


SCENARIOS = ("film32", "prog24", "prog24r", "tff", "bff", "fldmix", "ps78", "unpaired", "geom", "late", "back", "back200", "backfld", "gap03", "gap2s",
             "fldlate", "held", "heldlead", "starve400", "llsteady", "llearly", "llburst", "llend",
             # UMD's lone-PTS rules A and B (PR fj#25 + fj#26), and the band's edge at 50 Hz's half (900)
             "lone7", "lonefld", "lone2", "loneearly", "loneearlyfld", "back1s", "lone7@2",
             # P6 steps 5 / 6: the 60.00 Hz and 50 Hz rasters (their own content, and 59.94 content on them)
             "p60@1", "p60ll@1", "p24@1", "film32@1", "llburst@1",
             "p25@2", "p50@2", "i25@2", "film32@2", "llsteady@2")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--scenario")
    ap.add_argument("--out")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--il", action="store_true", help="the interlaced raster (480i / 576i): pairs held for the field")
    a = ap.parse_args(argv)
    if a.list:
        print(" ".join(SCENARIOS))
        return 0
    recs, n = scenario(a.scenario)
    for i in range(1, len(recs)):
        recs[i].avail = max(recs[i].avail, recs[i - 1].avail)     # FIFO: availability is monotonic
    ll = any(getattr(r, "ll", 0) for r in recs)
    lead = any(getattr(r, "lead", 0) for r in recs)
    out, cnt, recs = simulate(recs, n, ll=ll, il=a.il, lead=lead)
    with open(a.out + ".stim", "w") as f:
        f.write("%d %d %d %d %d %d\n" % (len(recs), n, 1 if ll else 0, STD, 1 if a.il else 0, 1 if lead else 0))
        for r in recs:
            f.write(r.line() + "\n")
    with open(a.out + ".exp", "w") as f:
        for v, s, p, fl, sg, lt in out:
            f.write("%d %d %d %d %d %d\n" % (v, s, p, fl, sg, lt))
    with open(a.out + ".cnt", "w") as f:
        f.write(" ".join("%s=%d" % kv for kv in sorted(cnt.items())) + "\n")
    print("%s: %d records, %d refreshes; %s" % (a.scenario, len(recs), n,
                                                " ".join("%s %d" % kv for kv in sorted(cnt.items()))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
