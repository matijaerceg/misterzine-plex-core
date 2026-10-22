#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""check_client.py OUT SERVER_LOG MEDIA -- score one run of the Jellyfin client's host test.

What the fake core consumed (OUT/sNN.stream, test_client.c) is walked by tools/ring_model.py's
consumer -- written from docs/architecture.md, sharing nothing with the client or the library --
and compared with references ffmpeg made from the fixtures (MEDIA, run_test.sh); what the client
said to the server comes from fake_server.py's log. Each check prints one PASS / FAIL line, the
letter as in tests/README.md; "check_client: ALL GREEN" only when every one passed.

  MEDIA/A.h264 + A.framemd5      item A's video as Annex B (h264_mp4toannexb) and its packets
                                 (size, PTS, MD5): the raw split by the sizes is the reference
  MEDIA/A.pcm                    item A's audio, decoded: s16le, 48 kHz, stereo
  MEDIA/B.framemd5               the CAVLC file's packets (no AU of it may ever reach the core)
  MEDIA/C.framemd5               the pad's item (one colour, 300 s): its packets
  MEDIA/hls.h264 + hls.framemd5  the transcode's video packets (TS: Annex B already)
  MEDIA/fixtures.json            start times (the origin of each stream's timestamps)
"""
import bisect
import hashlib
import json
import os
import re
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "..", "tools"))
import ring_model as M  # noqa: E402
import ts_skew  # noqa: E402

RING = 1 << 20                     # test_client.c's RING
M32 = 0xFFFFFFFF
TICKS = 10_000_000
POS_TOL = 0.6                      # seconds: a report against the fake core's STC
fails = 0


def check(label, ok, why=""):
    global fails
    print("  %s %s%s" % ("PASS" if ok else "FAIL", label, "  [%s]" % why if why else ""))
    if not ok:
        fails += 1


# ---- what the fake core consumed ----
class View(object):
    """the consumer indexes the stream by the producer's free-running byte index"""

    def __init__(self, start, body):
        self.start, self.body = start, body

    def __getitem__(self, i):
        return self.body[(i - self.start) & M32]


def records(c):
    """the session's records in order: video {data, pts (None: no PTS_VALID), eos}, audio
    {data, pts}, and 'reset' (a DISCONTINUITY inside the session)"""
    out, cur, curpts, ai = [], None, None, 0
    for it in c.items:
        k = it[0]
        if k == "byte":
            if cur is None:
                cur, curpts = bytearray(), (it[3] if it[2] else None)
            cur.append(it[1])
            if it[4]:
                out.append({"t": "v", "data": bytes(cur), "pts": curpts, "eos": False})
                cur = None
        elif k == "eos":
            if out and out[-1]["t"] == "v":
                out[-1]["eos"] = True
        elif k == "audio":
            out.append({"t": "a", "data": c.audio[ai], "pts": it[4] if it[3] else None})
            ai += 1
        elif k == "reset" and out:
            out.append({"t": "reset"})
    return out


def load_sessions(outdir):
    ss = []
    for ln in open(os.path.join(outdir, "sessions.txt")):
        f = ln.split()
        k = int(f[0])
        raw = open(os.path.join(outdir, "s%02d.stream" % k), "rb").read()
        start = struct.unpack("<I", raw[:4])[0]
        body = raw[4:]
        c = M.consume(View(start, body), start, (start + len(body)) & M32, RING)
        ss.append({"k": k, "t_start": float(f[2]), "t_anchor": float(f[3]), "c": c, "rec": records(c),
                   "t_first": float(f[7]), "t_last": float(f[8]), "first_type": int(f[9]), "dropped": int(f[10])})
    return ss


# ---- references ----
def framemd5(path):
    tb, pk = (1, 1000), []
    for ln in open(path):
        if ln.startswith("#tb 0:"):
            a, b = ln.split(":")[1].strip().split("/")
            tb = (int(a), int(b))
        elif not ln.startswith("#") and ln.strip():
            f = [x.strip() for x in ln.split(",")]
            pk.append({"pts": int(f[2]), "size": int(f[4]), "md5": f[5]})
    for p in pk:                                        # to 90 kHz (exact for 1/1000 and 1/90000)
        p["pts90"] = p["pts"] * 90000 * tb[0] // tb[1]
    return pk


def split_ref(raw_path, fm):
    raw = open(raw_path, "rb").read()
    aus, off = [], 0
    for p in fm:
        aus.append(raw[off:off + p["size"]])
        off += p["size"]
    ok = off == len(raw) and all(hashlib.md5(a).hexdigest() == p["md5"] for a, p in zip(aus, fm))
    return aus, ok


def nal_types(au):
    t, i = set(), 0
    while True:
        i = au.find(b"\x00\x00\x01", i)
        if i < 0 or i + 3 >= len(au):
            return t
        t.add(au[i + 3] & 0x1F)
        i += 3


def vids(rec):
    return [r for r in rec if r["t"] == "v"]


def main():
    outdir, logf, media = sys.argv[1], sys.argv[2], sys.argv[3]
    L = json.load(open(logf))
    T = L["times"]
    fx = json.load(open(os.path.join(media, "fixtures.json")))
    token, A, B = L["token"], L["items"]["A"], L["items"]["B"]
    reqs = L["requests"]

    fmA = framemd5(os.path.join(media, "A.framemd5"))
    refA, refA_ok = split_ref(os.path.join(media, "A.h264"), fmA)
    fmH = framemd5(os.path.join(media, "hls.framemd5"))
    refH, refH_ok = split_ref(os.path.join(media, "hls.h264"), fmH)
    md5_B = set(p["md5"] for p in framemd5(os.path.join(media, "B.framemd5")))
    md5_A = set(p["md5"] for p in fmA)
    md5_H = set(p["md5"] for p in fmH)
    md5_C = set(p["md5"] for p in framemd5(os.path.join(media, "C.framemd5")))
    fmD = framemd5(os.path.join(media, "D.framemd5"))
    refD, refD_ok = split_ref(os.path.join(media, "D.h264"), fmD)
    md5_D = set(p["md5"] for p in fmD)
    origin = {"A": fx["A_start"], "H": fx["hls_start"], "B": fx["B_start"], "C": fx["C_start"], "D": fx["D_start"],
              None: 0.0}

    S = load_sessions(outdir)
    for s in S:                                          # which stream a session carried
        v = vids(s["rec"])
        h = hashlib.md5(v[0]["data"]).hexdigest() if v else None
        s["what"] = ("A" if h in md5_A else "H" if h in md5_H else "B" if h in md5_B else
                     "C" if h in md5_C else "D" if h in md5_D else None)

    check("(0) the scenario ran to its end (no wait timed out)", T.get("completed") is True and not L["timeouts"],
          T.get("aborted", "") or "; ".join(x["what"] for x in L["timeouts"]))
    check("(0) the consumer finds no error in any session the client wrote",
          all(s["c"].err == 0 for s in S), "; ".join("s%d err %d at %d" % (s["k"], s["c"].err, s["c"].err_pos)
                                                    for s in S if s["c"].err))

    # ---- (a) Quick Connect, and the header ----
    t_auth = min([r["t"] for r in reqs if r["path"] == "/Users/AuthenticateWithQuickConnect" and r.get("status") == 200]
                 or [None], key=lambda x: x if x is not None else 0)
    bad, devids = [], set()
    for r in reqs:
        path = r["path"]
        media_req = "/stream?" in path or ".m3u8" in path or ".ts?" in path
        fa = M_auth(r["auth"])
        if fa is not None:
            devids.add(fa.get("DeviceId"))
        if media_req:                                    # FFmpeg's: the token on the URL, as the server's URLs carry it
            if "ApiKey=" + token not in path and not (fa and fa.get("Token") == token):
                bad.append(path)
            continue
        if fa is None or not all(fa.get(k) for k in ("Client", "Device", "DeviceId", "Version")):
            bad.append(path)
            continue
        if t_auth is not None and r["t"] > t_auth and fa.get("Token") != token:
            bad.append(path)
    polls = [r for r in reqs if r["path"].startswith("/QuickConnect/Connect?secret=" + L["qc_secret"])]
    ok_a = (L["qc_initiate_post"] >= 1 and L["qc_initiate_get"] == 0 and len(polls) >= 3 and t_auth is not None
            and not bad and len(devids) == 1 and ("ApiKey=" + token) in (L.get("ws_query") or ""))
    check("(a) Quick Connect: Initiate by POST, polled, then the token in every request's MediaBrowser header",
          ok_a, "POST %d GET %d polls %d signed in %s bad %s devices %d" % (
              L["qc_initiate_post"], L["qc_initiate_get"], len(polls), t_auth is not None, bad[:3], len(devids)))

    # ---- (b) the capabilities ----
    cap = L.get("capabilities") or {}
    prof = cap.get("DeviceProfile") or {}
    cps = prof.get("CodecProfiles") or []
    bands = [c.get("ApplyConditions") or [] for c in cps[1:]]
    check("(b) capabilities: Video, SupportsMediaControl, every band keyed on Width (never Height)",
          "Video" in (cap.get("PlayableMediaTypes") or []) and cap.get("SupportsMediaControl") is True and
          bool(bands) and all(any(c.get("Property") == "Width" for c in ac) and
                              not any(c.get("Property") == "Height" for c in ac) for ac in bands),
          "ApplyConditions %s" % bands)

    # ---- (b') interface 0.11: 720p direct play at <= 30 frames/s, the transcode's box ----
    def conds(lst):
        return {(c.get("Condition"), c.get("Property")): c.get("Value") for c in lst or []}
    base = conds(cps[0].get("Conditions")) if cps else {}
    fast = [conds(c.get("Conditions")) for c in cps[1:]
            if any(a.get("Property") == "VideoFramerate" for a in c.get("ApplyConditions") or [])]
    tps = prof.get("TranscodingProfiles") or []
    box = conds(tps[0].get("Conditions")) if tps else {}
    check("(b') the profile: direct play to 1280x720, a band above 30 frames/s inside 864x480, the box 854x480",
          base.get(("LessThanEqual", "Width")) == "1280" and base.get(("LessThanEqual", "Height")) == "720" and
          len(fast) == 1 and fast[0].get(("LessThanEqual", "Width")) == "864" and
          fast[0].get(("LessThanEqual", "Height")) == "480" and
          box.get(("LessThanEqual", "Width")) == "854" and box.get(("LessThanEqual", "Height")) == "480",
          "base %s fast %s box %s" % (base, fast, box))
    # ---- (b'') interface 0.12: the HD raster -- the profile a Native (HDMI) output asks with on a core
    # whose cap_native_h reaches 720 (the fake core reports 720 but NOT Native: the box above stays 854x480)
    try:
        hp = json.load(open(os.path.join(outdir, "profile_hd.json")))
    except Exception as e:
        hp = {}
    htp = hp.get("TranscodingProfiles") or []
    hbox = conds(htp[0].get("Conditions")) if htp else {}
    hcp = hp.get("CodecProfiles") or []
    hbase = conds(hcp[0].get("Conditions")) if hcp else {}
    check("(b'') the HD profile (Native, cap_native_h >= 720): the box 1280x720, direct play to 1280x720",
          hbox.get(("LessThanEqual", "Width")) == "1280" and hbox.get(("LessThanEqual", "Height")) == "720" and
          hbase.get(("LessThanEqual", "Width")) == "1280" and hbase.get(("LessThanEqual", "Height")) == "720",
          "box %s base %s" % (hbox, hbase))

    # ---- (c) the keep-alive ----
    t_fk = T.get("force_keepalive")
    ka = [w for w in L["ws"] if w["dir"] == "rx" and w["msg"].get("MessageType") == "KeepAlive"
          and t_fk is not None and t_fk < w["t"] <= t_fk + 2.0]
    unmasked = max([w.get("unmasked_frames", 0) for w in L["ws"] if w["dir"] == "rx"] or [0])
    check("(c) ForceKeepAlive answered by a KeepAlive within 2 s (masked frames)", bool(ka) and unmasked == 0,
          "keepalives %d unmasked %d" % (len(ka), unmasked))

    # ---- (d) item A's first session ----
    sa = next((s for s in S if s["what"] == "A"), None)
    va = vids(sa["rec"]) if sa else []
    pts_ok = len(va) == len(fmA) and all(v["pts"] is not None and v["pts"] == p["pts90"] for v, p in zip(va, fmA))
    first_ok = bool(va) and {5, 7, 8} <= nal_types(va[0]["data"]) and sa["rec"][0]["t"] == "v"
    check("(d) item A's first session: every access unit byte-identical to the file's, PTS = the packet's at 90 kHz, "
          "an IDR with SPS / PPS first",
          refA_ok and sa is not None and [v["data"] for v in va] == refA and pts_ok and first_ok,
          "reference %s, session %s, AUs %d of %d, PTS %s, first %s" % (
              refA_ok, sa and sa["k"], len(va), len(refA), pts_ok, first_ok))

    # ---- (e) the audio ----
    ok_e, why = audio_check(sa, os.path.join(media, "A.pcm"), fx["A_audio_t0"], "item A")
    check("(e) item A's audio: AUDIO records with PTS, the PCM equal to a reference decode", ok_e, why)

    # ---- (f) the pause ----
    ctl = [tuple(float(x) if i == 0 else int(x) for i, x in enumerate(ln.split()))
           for ln in open(os.path.join(outdir, "ctl.txt"))]

    def pause_at(t):
        w = 0
        for tt, ww in ctl:
            if tt <= t:
                w = ww
        return w & 1

    tp, tu, ts = T.get("pause"), T.get("unpause"), T.get("seek")
    ok_f = None not in (tp, tu, ts) and pause_at(tp) == 0 and \
        any(tp < tt < tu and ww & 1 for tt, ww in ctl) and pause_at(tu) == 1 and \
        any(tu < tt < ts and not ww & 1 for tt, ww in ctl) and pause_at(ts) == 0
    check("(f) the pause: word 34's PAUSE set after Pause, cleared after Unpause", ok_f,
          "events %s" % [(round(t - T["t0"], 2), w) for t, w in ctl])

    # ---- (g) the seek ----
    seek_s = [s for s in S if ts is not None and ts < s["t_start"] < T.get("stop_a", 1e18)]
    sk = next((s for s in seek_s if vids(s["rec"])), None)
    ok_g, why = False, "no session started between the Seek and the Stop" if not seek_s else "no access unit in it"
    if sk is not None:
        v0 = sk["rec"][0]
        vv = vids(sk["rec"])
        h0 = hashlib.md5(vv[0]["data"]).hexdigest()
        k0 = next((i for i, p in enumerate(fmA) if p["md5"] == h0), None)
        pos0 = (v0["pts"] / 90000.0 - origin["A"]) if v0["t"] == "v" and v0["pts"] is not None else None
        ok_g = (v0["t"] == "v" and {5, 7, 8} <= nal_types(v0["data"]) and pos0 is not None and
                6.0 - 1.0 - 1e-6 <= pos0 <= 6.0 + 1e-6 and k0 is not None and
                [v["data"] for v in vv] == refA[k0:len(refA)][:len(vv)])
        why = "first record %s, NAL %s, at %s s, ref index %s" % (v0["t"], v0["t"] == "v" and sorted(nal_types(v0["data"])),
                                                                pos0, k0)
    check("(g) the seek: a new session, its first record an IDR with SPS / PPS at or before 6 s (within a GOP)",
          ok_g, why)

    # ---- (h) the reports' positions come from the STC ----
    REPORT_LAG_S = 0.5                               # a report's way from the client's thread to the server
    samp = []
    for ln in open(os.path.join(outdir, "stc.txt")):
        f = ln.split()
        samp.append((float(f[0]), int(f[1]), int(f[2]), int(f[3]), int(f[4]), int(f[5])))
    st_t = [x[0] for x in samp]
    scored, badrep = 0, []
    for r in L["reports"]:
        b = r["body"] if isinstance(r["body"], dict) else {}
        if b.get("ItemId") not in (A, B) or "PositionTicks" not in b:
            continue
        pos = b["PositionTicks"] / TICKS
        i = bisect.bisect_right(st_t, r["t"]) - 1
        if i < 0:
            continue
        t, k, run = samp[i][0], samp[i][1], samp[i][2]
        if run:
            exp = samp[i][5] / 90000.0 - origin[S[k]["what"]] if 0 <= k < len(S) else None
            scored += 1
        else:
            # the clock not running: either not yet (the position it anchors at, the next running
            # sample), or no longer -- the client posts its reports from their own thread, so a
            # report made just before a stop (the end's Stopped) can arrive just after it: the last
            # running sample within REPORT_LAG_S before the arrival
            j = next((j for j in range(i + 1, len(samp)) if samp[j][2]), None)
            nxt = samp[j][5] / 90000.0 - origin[S[samp[j][1]]["what"]] if j is not None else None
            p_ = next((p_ for p_ in range(i, -1, -1) if samp[p_][2]), None)
            prv = (samp[p_][5] / 90000.0 - origin[S[samp[p_][1]]["what"]]
                   if p_ is not None and r["t"] - samp[p_][0] <= REPORT_LAG_S else None)
            cands = [x for x in (nxt, prv) if x is not None]
            exp = min(cands, key=lambda x: abs(pos - x)) if cands else None
        if exp is not None and abs(pos - exp) > POS_TOL:
            badrep.append("%s %.2f vs %.2f%s" % (r["kind"], pos, exp, "" if run else " (not running)"))
    check("(h) every report's position is the fake core's STC (within 0.6 s), at least 4 while it ran",
          scored >= 4 and not badrep, "scored %d, off: %s" % (scored, badrep[:4]))

    # ---- (i) the volume ----
    tv = T.get("volume")
    ok_i = tv is not None and all((w >> 8) & 0xFF == 0 for t, w in ctl if t < tv) and \
        any(t > tv and (w >> 8) & 0xFF == 12 for t, w in ctl)
    check("(i) the volume: SetVolume 50 -> ATTEN 12 (word 34)", ok_i,
          "atten %s" % [(round(t - T["t0"], 2), (w >> 8) & 0xFF) for t, w in ctl])

    # ---- (j) the CAVLC file asked again as a transcode, never written ----
    pb = [p for p in L["pbinfo"] if p["item"] == B]
    consumed = set(hashlib.md5(v["data"]).hexdigest() for s in S for v in vids(s["rec"]))
    leaked = len(consumed & md5_B)
    ok_j = len(pb) >= 2 and pb[0]["body"].get("EnableDirectPlay") is True and \
        pb[1]["body"].get("EnableDirectPlay") is False and pb[1]["body"].get("AllowVideoStreamCopy") is False and \
        leaked == 0
    check("(j) the CAVLC file: PlaybackInfo again with direct play and stream copy off; none of its AUs consumed",
          ok_j, "requests %d, second %s, CAVLC AUs consumed %d" % (
              len(pb), {k: pb[1]["body"].get(k) for k in ("EnableDirectPlay", "EnableDirectStream", "AllowVideoStreamCopy")}
              if len(pb) > 1 else None, leaked))

    # ---- (k) the transcode played to its end ----
    sh = next((s for s in S if s["what"] == "H"), None)
    vh = vids(sh["rec"]) if sh else []
    stops = [r for r in L["reports"] if r["kind"] == "Stopped" and isinstance(r["body"], dict) and
             r["body"].get("ItemId") == B and r["body"].get("PlayMethod") == "Transcode"]
    end_pos = stops[-1]["body"]["PositionTicks"] / TICKS if stops else None
    ok_k = (refH_ok and sh is not None and [v["data"] for v in vh] == refH and
            all(v["pts"] == p["pts90"] for v, p in zip(vh, fmH)) and bool(vh) and vh[-1]["eos"] and
            not any(v["eos"] for v in vh[:-1]) and end_pos is not None and
            abs(end_pos - L["runtime"]["B"]) <= 1.0)
    check("(k) the transcode: every AU as the playlist's, the last with END_OF_STREAM, Stopped near the runtime",
          ok_k, "reference %s, AUs %d of %d, last EOS %s, Stopped at %s" % (
              refH_ok, len(vh), len(refH), bool(vh) and vh[-1]["eos"], end_pos))

    # ---- (k2) (0.16, docs/colour.md R4) the colour: a transcode carries its SOURCE's (B: tagged bt709 -> 3,
    # where the server would say 709 for any source and the size rule 1); direct play 0 (auto: the file's tags) ----
    sa2 = next((s for s in S if s["what"] == "A"), None)
    ok_k2 = (sh is not None and sh["c"].colour == 3 and sh["c"].colour_mismatch == 0 and
             sa2 is not None and sa2["c"].colour == 0)
    check("(k2) the colour: the transcode's access units carry its source's BT.709 (3), direct play auto (0)",
          ok_k2, "transcode %s (mismatches %s), direct play %s" % (
              sh["c"].colour if sh else None, sh["c"].colour_mismatch if sh else None, sa2["c"].colour if sa2 else None))

    # ---- (l) the overlay flips after the seek's session start ----
    ovl = [ln.split() for ln in open(os.path.join(outdir, "ovl.txt"))]
    t_from = sk["t_start"] if sk is not None else (ts or 1e18)
    flips = [o for o in ovl if float(o[0]) > t_from and o[4] == "1"]
    check("(l) the overlay: page flips after the seek's session started (the generation rule \"at least\")",
          len(flips) >= 1, "no seek" if ts is None else "flips after %.2f s: %d (all %d)" % (
              t_from - T["t0"], len(flips), sum(1 for o in ovl if o[4] == "1")))

    # ---- (m) the subtitles ----
    pa = [p for p in L["pbinfo"] if p["item"] == A]
    srt = [r for r in reqs if "/Subtitles/2/0/Stream.srt" in r["path"] and r.get("status") == 200]
    check("(m) the subtitles: asked for (index 2) and the .srt fetched",
          bool(pa) and pa[0]["body"].get("SubtitleStreamIndex") == 2 and len(srt) >= 1,
          "fetched %d" % len(srt))

    # ---- (n) a text subtitle track switched off and on: the stream untouched ----
    t_off, t_on, t_end = T.get("sub_off"), T.get("sub_on"), T.get("volume")
    if None in (t_off, t_on, t_end):
        check("(n) subtitles off and on again: no new session, the .srt fetched again, no Stopped", False,
              "the phase did not run")
    else:
        new_s = [s["k"] for s in S if t_off < s["t_start"] < t_end]
        refetch = [r for r in reqs if "/Subtitles/2/0/Stream.srt" in r["path"] and r.get("status") == 200
                   and t_on < r["t"] < t_end]
        stopped = [r for r in L["reports"] if r["kind"] == "Stopped" and t_off < r["t"] < t_end and
                   isinstance(r["body"], dict) and r["body"].get("ItemId") == A]
        check("(n) subtitles off and on again: no new session, the .srt fetched again, no Stopped",
              not new_s and len(refetch) >= 1 and not stopped,
              "sessions started %s, .srt fetched %d, Stopped %d" % (new_s, len(refetch), len(stopped)))

    # ---- (r) the loop runs while the server is slow: the switch's .srt (answered SLOW_SRT_S late) ----
    slow_srt = [r for r in L.get("srt", []) if r.get("slow")]
    gaps = []
    gp = os.path.join(outdir, "loopgap.txt")
    if os.path.exists(gp):
        gaps = [tuple(float(x) for x in ln.split()) for ln in open(gp) if ln.strip()]
    hit = [(round(a - T["t0"], 2), round(b - a, 2)) for a, b in gaps for r in slow_srt
           if a < r["t_answer"] and b > r["t_request"]]
    check("(r) a slow subtitle answer: the client's loop never stalls over 0.25 s while it waits",
          bool(slow_srt) and not hit,
          "slow .srt requests %d, loop stalls during them %s (all stalls %d)" % (len(slow_srt), hit, len(gaps)))

    # ---- (u) the subtitle asked for whole: the URL's start 0, whatever the PlaybackInfo's start ----
    srt_reqs = L.get("srt", [])
    late_pb = [p for p in L["pbinfo"] if p["item"] == A and (p["body"].get("StartTimeTicks") or 0) > 0 and
               p["body"].get("SubtitleStreamIndex") == 2]
    check("(u) every .srt asked for from 0 (the whole track, its own times), also after a switch at 6 s+",
          bool(srt_reqs) and all(r["ticks"] == 0 for r in srt_reqs) and bool(late_pb),
          "start ticks asked %s; PlaybackInfo with a start and the track %d" % (
              [r["ticks"] for r in srt_reqs], len(late_pb)))

    # ---- (o) the pad: taps add up to one seek; a held RIGHT repeats, and still one seek ----
    ok_o, why = pad_check(outdir, S, samp, origin, T)
    check("(o) the pad: three RIGHT taps -> ONE seek of +90 s; RIGHT held 1.2 s -> ONE seek of >= 3 steps", ok_o, why)

    # ---- (p) the held seek: the old picture paused through a slow open, then the flush and the IDR ----
    ok_p, why = held_check(outdir, S, L, T, ctl)
    check("(p) the held seek: PAUSE at once and held through the slow open, then the flush and the IDR within 300 ms",
          ok_p, why)

    # ---- (q) a seek in the transcode opens the playlist trimmed to the target's segment ----
    ok_q, why = trim_check(media, S, reqs, T, fmH, refH, origin)
    check("(q) the transcode's seek: the trimmed playlist -- the target's segment first, its IDR first", ok_q, why)

    # ---- (v) / (w) item D: the transcode of 2026-10-09 (docs/jellyfin.md S12) ----
    sd = next((s for s in S if s["what"] == "D"), None)
    ok_v, why = interleave_check(sd, os.path.join(media, "D.packets"), refD, refD_ok, fmD, L)
    check("(v) item D (audio 6 s ahead in the stream): no AUDIO record over 1.3 s ahead of the video before it, "
          "played to its end", ok_v, why)
    ok_w, why = audio_check(sd, os.path.join(media, "D.pcm"), fx["D_audio_t0"], "item D")
    check("(w) item D (its audio past the probe): AUDIO records with PTS, the PCM equal to a reference decode",
          ok_w, why)

    print("check_client: %s" % ("FAILURES" if fails else "ALL GREEN"))
    return 1 if fails else 0


def trim_check(media, S, reqs, T, fmH, refH, origin, target=4.0):
    """B's Seek to 4 s: the segment holding it (the last whose start -- its runtimeTicks, the
    playlist's EXTINF durations summed -- is at or before 4 s) is the FIRST segment asked for after
    the Seek, and no earlier one is asked for after it (an untrimmed open probes segment 0, then
    seeks); the first session started after the Seek begins with that segment's first access unit,
    an IDR with SPS / PPS, byte-identical with its PTS, and continues as the playlist's"""
    t_seek = T.get("seek_b")
    if t_seek is None:
        return False, "no Seek in item B"
    starts, t = [], 0.0
    for ln in open(os.path.join(media, "hls", "main.m3u8")):
        if ln.startswith("#EXTINF:"):
            starts.append(t)
            t += float(ln[8:].split(",")[0])
    seg = max(i for i, s0 in enumerate(starts) if s0 <= target + 1e-6)
    asked = []
    for r in reqs:
        m = re.search(r"/seg(\d+)\.ts", r["path"])
        if m and r["t"] > t_seek:
            asked.append(int(m.group(1)))
    why = "segment %d holds %.1f s (starts at %.2f); asked after the Seek: %s" % (seg, target, starts[seg], asked[:6])
    if not asked or asked[0] != seg or min(asked) < seg:
        return False, why
    sn = next((s for s in S if s["t_start"] > t_seek), None)
    v = vids(sn["rec"]) if sn else []
    if not v or sn["rec"][0]["t"] != "v":
        return False, why + "; no session after the Seek starting with an access unit"
    h0 = hashlib.md5(v[0]["data"]).hexdigest()
    k0 = next((i for i, p in enumerate(fmH) if p["md5"] == h0), None)
    pos = v[0]["pts"] / 90000.0 - origin["H"] if v[0]["pts"] is not None else None
    good = (k0 is not None and {5, 7, 8} <= nal_types(v[0]["data"]) and pos is not None and
            starts[seg] - 0.05 <= pos <= starts[seg] + 0.2 and v[0]["pts"] == fmH[k0]["pts90"] and
            [x["data"] for x in v] == refH[k0:k0 + len(v)])
    return good, why + "; the session's first AU: reference %s, at %s s, NAL %s" % (
        k0, None if pos is None else round(pos, 3), sorted(nal_types(v[0]["data"])))


def held_check(outdir, S, L, T, ctl):
    """each seek whose open the server made slow (A's Seek, the taps', the hold's): word 34's PAUSE
    set within 200 ms of the seek (the command; the pad's: 600 ms after the last step, the settle),
    the slow request made while it was set, PAUSE never cleared before the new session started (the
    flush) and that after the slow answer; the new session's first record a VIDEO_AU consumed within
    300 ms of its start; the old session consumed nothing after the PAUSE and had nothing written to
    it that it never consumed (the held stream writes nothing until its release)"""
    slow = {x["what"]: x for x in L.get("slow", [])}
    ev = [ln.split() for ln in open(os.path.join(outdir, "pad.txt"))]
    taps = [float(t) for t, k, p in ev if k == "taps" and p == "1"]
    hold_rel = [float(t) for t, k, p in ev if k == "hold" and p == "0"]
    cmd = {}
    if T.get("seek") is not None:
        cmd["seek"] = T["seek"]
    if len(taps) == 3:
        cmd["taps"] = taps[-1] + 0.6                    # SEEK_SETTLE_MS after the last step
    if hold_rel:
        cmd["hold"] = hold_rel[-1] + 0.6                # the last repeat is at most the release
    out, ok = [], True
    for what in ("seek", "taps", "hold"):
        if what not in slow or what not in cmd:
            ok = False
            out.append("%s: %s" % (what, "no slow open" if what not in slow else "no seek command"))
            continue
        t_cmd, sl = cmd[what], slow[what]
        lo, hi = t_cmd - (0.2 if what == "hold" else 0.05), t_cmd + 0.2
        sets = [t for t, w in ctl if w & 1 and lo <= t <= hi]
        if not sets:
            ok = False
            out.append("%s: PAUSE not set within 200 ms of the seek" % what)
            continue
        t_p = sets[0]
        nxt = [s for s in S if s["t_start"] > t_p]
        old = [s for s in S if s["t_start"] < t_p]
        if not nxt or not old:
            ok = False
            out.append("%s: no session after the PAUSE" % what)
            continue
        new, old = nxt[0], old[-1]
        cleared = [t for t, w in ctl if t_p < t < new["t_start"] and not w & 1]
        good = (not cleared and t_p <= sl["t_request"] and sl["t_answer"] <= new["t_start"] and
                new["first_type"] == 2 and new["t_first"] - new["t_start"] <= 0.3 and
                old["t_last"] < t_p and old["dropped"] == 0)
        ok = ok and good
        out.append("%s: PAUSE +%.0f ms, flush %.2f s later (slow answer %.2f s before it), PAUSE cleared before %s, "
                   "first record %s, old session last read %s, dropped %d" % (
                       what, 1000 * (t_p - t_cmd), new["t_start"] - t_p, new["t_start"] - sl["t_answer"],
                       bool(cleared),
                       "type %d +%.0f ms" % (new["first_type"], 1000 * (new["t_first"] - new["t_start"]))
                       if new["t_first"] else "none",
                       "%.2f s before" % (t_p - old["t_last"]) if old["t_last"] else "never", old["dropped"]))
    return ok, "; ".join(out)


def pad_check(outdir, S, samp, origin, T):
    """the sessions started in each cue's window (the taps: from their first press to the hold's;
    the hold: from its press to the Stop of C) -- exactly one each, its first record an IDR at
    or before the position at the cue plus n x 30 s, within a GOP (1 s): n = 3 for the taps, n >= 3
    for the hold (1 + the repeats a 1.2 s hold gives at 450 ms then every 180 ms: up to 6)"""
    ev = [ln.split() for ln in open(os.path.join(outdir, "pad.txt"))]
    starts = {}
    for t, kind, _ in ev:
        starts.setdefault(kind, float(t))
    if "taps" not in starts or "hold" not in starts or T.get("stop_c") is None:
        return False, "the pad phase did not run (cues %s)" % sorted(starts)
    st_t = [x[0] for x in samp]
    out, ok = [], True
    for kind, a, b in (("taps", starts["taps"], starts["hold"]), ("hold", starts["hold"], T["stop_c"])):
        i = bisect.bisect_right(st_t, a) - 1
        if i < 0 or not samp[i][2] or S[samp[i][1]]["what"] != "C":
            return False, "%s: the clock of item C was not running at the cue" % kind
        before = samp[i][5] / 90000.0 - origin["C"]
        ss = [s for s in S if a < s["t_start"] < b]
        if len(ss) != 1:
            ok = False
            out.append("%s: %d sessions" % (kind, len(ss)))
            continue
        r0 = ss[0]["rec"][0] if ss[0]["rec"] else None
        if not r0 or r0["t"] != "v" or r0["pts"] is None or not {5, 7, 8} <= nal_types(r0["data"]):
            ok = False
            out.append("%s: the session does not start with an IDR with its PTS" % kind)
            continue
        pos = r0["pts"] / 90000.0 - origin["C"]
        n = int(round((pos - before + 0.5) / 30.0))     # the IDR is up to a GOP before the target
        target = before + 30.0 * n
        fit = target - 1.0 - 0.1 <= pos <= target + 0.1
        good = fit and (n == 3 if kind == "taps" else n >= 3)
        ok = ok and good
        out.append("%s: from %.2f to the IDR at %.2f = %d steps" % (kind, before, pos, n) + ("" if fit else " (not a GOP)"))
    return ok, "; ".join(out)


def M_auth(h):
    import re
    import urllib.parse
    if not h or not h.startswith("MediaBrowser "):
        return None
    return {k: urllib.parse.unquote(v) for k, v in re.findall(r'(\w+)="([^"]*)"', h)}


LEAD_TOL_S = 1.3       # the client's 1 s (AUD_LEAD), the two access units it holds back, a record's gathering
                       # (1.16 s measured); the fixture's skew is 6.4 s


def interleave_check(sd, packets, refD, refD_ok, fmD, L):
    """item D: the fixture holds the skew (audio first after >= 2.5 s of video -- past both probes --
    and >= 5 s ahead of its video, more than the core's 256 records); in the session the client
    wrote, every AUDIO record with a PTS within LEAD_TOL_S of the newest video PTS written before it;
    every access unit the playlist's, the last with END_OF_STREAM, and the Stopped report near the
    runtime (it did not stall)"""
    lead_f, first_a = ts_skew.skew(packets)
    why = "fixture: audio %.2f s ahead, the first after %.2f s of video" % (lead_f, first_a or -1)
    if lead_f < 5.0 or first_a is None or first_a < 2.5:
        return False, why + " (the fixture lost its skew)"
    if sd is None:
        return False, why + "; no session of item D"
    vmax, worst, n_a = None, None, 0
    for r in sd["rec"]:
        if r["t"] == "v" and r["pts"] is not None:
            vmax = r["pts"] if vmax is None else max(vmax, r["pts"])
        elif r["t"] == "a" and r["pts"] is not None and vmax is not None:
            n_a += 1
            d = (r["pts"] - vmax) / 90000.0
            worst = d if worst is None else max(worst, d)
    vd = vids(sd["rec"])
    stops = [x for x in L["reports"] if x["kind"] == "Stopped" and isinstance(x["body"], dict) and
             x["body"].get("ItemId") == L["items"]["D"]]
    end_pos = stops[-1]["body"]["PositionTicks"] / TICKS if stops else None
    why += "; %d timed records, the most ahead %s s; AUs %d of %d, last EOS %s, Stopped at %s" % (
        n_a, None if worst is None else round(worst, 3), len(vd), len(refD), bool(vd) and vd[-1]["eos"], end_pos)
    ok = (n_a > 0 and worst <= LEAD_TOL_S and refD_ok and [v["data"] for v in vd] == refD and
          all(v["pts"] == p["pts90"] for v, p in zip(vd, fmD)) and bool(vd) and vd[-1]["eos"] and
          end_pos is not None and abs(end_pos - L["runtime"]["D"]) <= 1.0)
    return ok, why


def audio_check(sa, pcm, t0, what):
    """the client's PCM against the reference decode, EXACT. The offset comes from the first
    record's PTS; MKV's millisecond timestamps put a PTS-derived sample offset up to 24 samples off,
    so the exact match is searched within +-96 frames of it and required within 48 (1 ms). When the
    client's first record is the reference's first frame (offset 0: no packet dropped -- this
    fixture's interleave puts the first video packet first), every frame must be equal. Only when
    the client started mid-stream (it drops audio until its first picture, and starts a FRESH
    decoder there, whose first AAC frame overlap-adds with zeros) are its first 2,048 frames
    excused. Every record's PTS must sit at its own place in the stream within 1 ms."""
    if sa is None:
        return False, "no session of " + what
    au = [r for r in sa["rec"] if r["t"] == "a"]
    if not au:
        return False, "no AUDIO record"
    if any(r["pts"] is None for r in au):
        return False, "%d of %d AUDIO records without PTS" % (sum(r["pts"] is None for r in au), len(au))
    C = b"".join(r["data"] for r in au)
    R = open(pcm, "rb").read()
    e = round((au[0]["pts"] / 90000.0 - t0) * 48000)
    skip = 2048
    if len(C) // 4 < skip + 48000 * 5:
        return False, "only %d frames of audio" % (len(C) // 4)
    match = None
    for d in sorted(range(-96, 97), key=abs):
        o = e + d
        if o < 0:
            continue
        a = C[skip * 4:]
        b = R[(o + skip) * 4:(o + skip) * 4 + len(a)]
        n = min(len(a), len(b))
        if n >= 48000 * 4 * 5 and a[:n] == b[:n]:
            match = (o, n // 4)
            break
    if match is None:
        return False, "no exact match within 96 frames of the PTS-derived offset %d" % e
    o, n = match
    if o == 0 and C[:skip * 4] != R[:skip * 4]:
        return False, "the first %d frames differ although the client started at the reference's first" % skip
    if abs(o - e) > 48:
        return False, "the match at %d, %d frames from the PTS's %d" % (o, o - e, e)
    f, worst = 0, 0
    for r in au:                                         # each record's PTS at its place
        exp = round((r["pts"] / 90000.0 - t0) * 48000)
        worst = max(worst, abs(o + f - exp))
        f += len(r["data"]) // 4
    if worst > 48:
        return False, "a record's PTS %d frames from its place" % worst
    return True, "%d records, %d frames equal from offset %d (%s)" % (
        len(au), n + (skip if o == 0 else 0), o, "all of them" if o == 0 else "the first %d excused" % skip)


if __name__ == "__main__":
    sys.exit(main())
