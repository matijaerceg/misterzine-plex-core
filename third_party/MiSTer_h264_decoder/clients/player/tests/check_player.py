#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""check_player.py OUT LOG MEDIA -- score one run of the file player's host test.

What the fake core consumed (OUT/sNN.stream, test_player.c) is walked by tools/ring_model.py's
consumer -- written from docs/architecture.md, sharing nothing with the player or the library --
and compared with references ffmpeg made from the fixtures (MEDIA, run_test.sh). The settings
requests and the script's times come from test_player.c's files; what the player refused and the
subtitle cues it put on screen from its log (the test build logs each cue). Each check prints one
PASS / FAIL line, its letter as in tests/README.md; "check_player: ALL GREEN" only when every one
passed.
"""
import hashlib
import json
import os
import re
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "..", "tools"))
import ring_model as M  # noqa: E402
import ts_skew  # noqa: E402

RING = 1 << 20                     # test_player.c's RING
M32 = 0xFFFFFFFF
fails = 0


def check(label, ok, why=""):
    global fails
    print("  %s %s%s" % ("PASS" if ok else "FAIL", label, "  [%s]" % why if why else ""))
    if not ok:
        fails += 1


class View(object):
    def __init__(self, start, body):
        self.start, self.body = start, body

    def __getitem__(self, i):
        return self.body[(i - self.start) & M32]


def records(c):
    """the session's records: video {data, pts, eos}, audio {data, pts}"""
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
        ss.append({"k": k, "t_start": float(f[2]), "records": int(f[6]), "c": c, "rec": records(c)})
    return ss


def framemd5(path):
    tb, pk = (1, 1000), []
    for ln in open(path):
        if ln.startswith("#tb 0:"):
            a, b = ln.split(":")[1].strip().split("/")
            tb = (int(a), int(b))
        elif not ln.startswith("#") and ln.strip():
            f = [x.strip() for x in ln.split(",")]
            pk.append({"pts": int(f[2]), "size": int(f[4]), "md5": f[5]})
    for p in pk:
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


def entropy_flags(au):
    """each PPS's entropy_coding_mode_flag in an Annex-B access unit (H.264 7.3.2.2: ue(pps_id),
    ue(sps_id), u(1)), emulation prevention removed"""
    out, i = [], 0
    while True:
        i = au.find(b"\x00\x00\x01", i)
        if i < 0 or i + 3 >= len(au):
            return out
        if au[i + 3] & 0x1F == 8:
            j = au.find(b"\x00\x00\x01", i + 3)
            raw = au[i + 4:j if j > 0 else len(au)]
            rb, zeros = bytearray(), 0
            for b in raw:
                if zeros >= 2 and b == 3:
                    zeros = 0
                    continue
                zeros = zeros + 1 if b == 0 else 0
                rb.append(b)
            bits = "".join(format(b, "08b") for b in rb)
            pos = 0
            for _ in range(2):                      # pps_id, sps_id: ue(v)
                lz = 0
                while pos < len(bits) and bits[pos] == "0":
                    lz += 1
                    pos += 1
                pos += 1 + lz
            out.append(int(bits[pos]) if pos < len(bits) else -1)
        i += 3


def load_pics(outdir):
    """(0.15) test_player.c's pics.bin: every PICTURE the fake core consumed, with its store's image"""
    path = os.path.join(outdir, "pics.bin")
    raw = open(path, "rb").read() if os.path.exists(path) else b""
    out, off = [], 0
    while off + 52 <= len(raw):
        sn, fl, pts = struct.unpack_from("<IIQ", raw, off)
        d = struct.unpack_from("<4Q", raw, off + 16)
        nb, = struct.unpack_from("<I", raw, off + 48)
        off += 52
        out.append({"sess": sn, "flags": fl & 0xFFFF, "colour": (fl >> 16) & 7, "pts": pts, "d": M.pic_unpack(b"".join(x.to_bytes(8, "little") for x in d)),
                    "img": raw[off:off + nb]})
        off += nb
    return out


def visible(p):
    """a picture's shown planes, as yuv420p is laid out (Y, then Cb, then Cr, rows packed): read from
    the store image by docs/architecture.md's layout (Y 16 W bytes a row, Cb at 256 W HF, Cr at 320 W
    HF, 8 W bytes a row) and the crop (pairs of columns / lines off the right and bottom)"""
    d, img = p["d"], p["img"]
    W, HF = d["w"], d["hf"]
    w, h = 16 * W - 2 * d["cr"], 16 * HF - 2 * d["cb"]
    cw, ch = (w + 1) // 2, (h + 1) // 2
    y = b"".join(img[r * 16 * W:r * 16 * W + w] for r in range(h))
    u = b"".join(img[256 * W * HF + r * 8 * W:256 * W * HF + r * 8 * W + cw] for r in range(ch))
    v = b"".join(img[320 * W * HF + r * 8 * W:320 * W * HF + r * 8 * W + cw] for r in range(ch))
    return w, h, y + u + v


def mjpeg_expected(raw, w, h):
    """yuvj422p frames -> what the store must show: 4:2:0 (each pair of chroma rows averaged, rounding
    up); (0.16, docs/colour.md D-C8) the full range kept as it is -- the record says BT.601 full (colour
    2) and the core converts it -- where 0.15 converted it to limited on the ARM"""
    cw = (w + 1) // 2
    fsz = w * h + 2 * cw * h
    ly = list(range(256))
    lc = list(range(256))
    out = []
    for f in range(len(raw) // fsz):
        b = raw[f * fsz:(f + 1) * fsz]
        y = bytes(ly[v] for v in b[:w * h])
        planes = [y]
        for c in range(2):
            pl = b[w * h + c * cw * h:w * h + (c + 1) * cw * h]
            rows = []
            for r in range((h + 1) // 2):
                a = pl[min(2 * r, h - 1) * cw:min(2 * r, h - 1) * cw + cw]
                bb = pl[min(2 * r + 1, h - 1) * cw:min(2 * r + 1, h - 1) * cw + cw]
                rows.append(bytes(lc[(x + z + 1) >> 1] for x, z in zip(a, bb)))
            planes.append(b"".join(rows))
        out.append(b"".join(planes))
    return out


def vids(rec):
    return [r for r in rec if r["t"] == "v"]


def md5(b):
    return hashlib.md5(b).hexdigest()


def main():
    outdir, logf, media = sys.argv[1], sys.argv[2], sys.argv[3]
    log = open(logf, errors="replace").read().splitlines()
    fx = json.load(open(os.path.join(media, "fixtures.json")))
    ref = {}
    for n in ("inner", "b_pal", "c_ok", "l_ahead", "m_late"):
        fm = framemd5(os.path.join(media, n + ".framemd5"))
        aus, ok = split_ref(os.path.join(media, n + ".h264"), fm)
        ref[n] = {"fm": fm, "aus": aus, "ok": ok, "md5": set(p["md5"] for p in fm)}
    refused_md5 = {n: set(p["md5"] for p in framemd5(os.path.join(media, n + ".framemd5")))
                   for n in ("d_big", "g_fast", "j_ffv1", "k_hd")}
    ss = load_sessions(outdir)
    played = [s for s in ss if s["records"] > 0]
    settings = [tuple(float(x) if i == 0 else int(x) for i, x in enumerate(ln.split()))
                for ln in open(os.path.join(outdir, "settings.txt")) if ln.strip()]
    script = []
    for ln in open(os.path.join(outdir, "script.txt")):
        f = ln.split(None, 3)
        script.append({"t0": float(f[0]), "t1": float(f[1]), "to": int(f[2]), "cmd": f[3].strip() if len(f) > 3 else ""})
    stc = [tuple(float(x) if i == 0 else int(x) for i, x in enumerate(ln.split()))
           for ln in open(os.path.join(outdir, "stc.txt")) if ln.strip()]
    final = int(open(os.path.join(outdir, "final.txt")).read().strip() or "-1")

    def which(s):
        """the fixture a session's video came from (by MD5), or None"""
        v = vids(s["rec"])
        if not v:
            return None
        h = md5(v[0]["data"])
        for n, r in ref.items():
            if h in r["md5"]:
                return n
        return "?"

    names = [which(s) for s in played]
    print("check_player: played sessions: %s" % names)
    check("(0) the references split exactly; the consumer finds no error in any session",
          all(r["ok"] for r in ref.values()) and all(s["c"].err == 0 for s in ss),
          "refs %s; %s" % ({n: r["ok"] for n, r in ref.items()},
                           "; ".join("s%d err %d at %d" % (s["k"], s["c"].err, s["c"].err_pos) for s in ss if s["c"].err)))

    def exact(s, n, from_idx=0):
        """every AU the session's: the reference's from from_idx, byte-identical, PTS equal"""
        v = vids(s["rec"])
        r = ref[n]
        if not v or from_idx + len(v) > len(r["aus"]):
            return False, "AUs %d" % len(v)
        origin = 0
        for i, a in enumerate(v):
            p = r["fm"][from_idx + i]
            if a["data"] != r["aus"][from_idx + i] or a["pts"] is None or a["pts"] != p["pts90"] + origin:
                return False, "AU %d differs (pts %s, ref %d)" % (i, a["pts"], p["pts90"])
        return True, "%d AUs" % len(v)

    # (b) the list: the first file played is b_pal (DOWN from the folder: folders first, then the
    # files in order -- a hidden file or a non-video listed would have been selected instead)
    # (the first file OPENED, from the log: a hidden or non-video entry would be opened -- and
    # refused or failed, never reaching the ring -- before b_pal)
    opened = [ln.split("h264player: play ", 1)[1] for ln in log if ln.startswith("h264player: play ")]
    check("(b) the list: the first file played is the folder's first video (b_pal)",
          bool(opened) and opened[0].endswith("/b_pal.mp4") and len(played) >= 1 and names[0] == "b_pal",
          "opened first %s, played %s" % (opened[:1], names[:1]))

    # (d) the files byte-identical: b_pal (MP4: avcC -> Annex B) and c_ok, each AU with its PTS
    okb, whyb = exact(played[0], "b_pal") if len(played) >= 1 and names[0] == "b_pal" else (False, "not played")
    okc, whyc = exact(played[1], "c_ok") if len(played) >= 2 and names[1] == "c_ok" else (False, "not played")
    lastc = vids(played[1]["rec"])[-1] if len(played) >= 2 and vids(played[1]["rec"]) else None
    audioc = [r for r in played[1]["rec"] if r["t"] == "a"] if len(played) >= 2 else []
    check("(d) b_pal and c_ok: every AU byte-identical with its PTS, c_ok's last with END_OF_STREAM, audio with PTS",
          okb and okc and lastc is not None and lastc["eos"] and len(audioc) > 10 and all(a["pts"] is not None for a in audioc),
          "b_pal %s; c_ok %s; audio records %d" % (whyb, whyc, len(audioc)))

    # (c) the folder plays on: b_pal's end starts c_ok, no press between
    # by itself: c_ok's session starts before any press made after b_pal's started
    t_b0 = played[0]["t_start"] if played else 0
    later = [c["t0"] for c in script if c["cmd"].startswith("press") and c["t0"] > t_b0]
    c_by_itself = len(played) >= 2 and (not later or played[1]["t_start"] < later[0])
    check("(c) the folder plays on: c_ok follows b_pal by itself",
          len(played) >= 2 and names[0] == "b_pal" and names[1] == "c_ok" and c_by_itself,
          "played %s, c_ok before the next press %s" % (names[:2], c_by_itself))

    # (e) the refusals: none of d / f / g's AUs consumed; the log names each reason
    consumed = set()
    for s in ss:
        for v in vids(s["rec"]):
            consumed.add(md5(v["data"]))
    leaked = {n: len(consumed & m) for n, m in refused_md5.items() if consumed & m}
    cant = [ln for ln in log if "h264player: cannot play" in ln]
    reasons = {"d_big": "1344x720 is larger", "g_fast": "too fast", "j_ffv1": "cannot decode", "k_hd": "larger than SD"}
    named = {n: any(n in ln and w in ln for ln in cant) for n, w in reasons.items()}
    pics = load_pics(outdir)
    pic_sess = sorted(set(p["sess"] for p in pics))
    check("(e) refused: a CAVLC 1344x720 (its size, CAVLC checked last), 720p60 (too fast), FFV1 (not decoded), MPEG-4 1280x720 (over SD) -- none reached the core, each reason named",
          not leaked and all(named.values()) and len(pic_sess) == 3,
          "leaked %s, named %s, sessions of pictures %d (f_mpeg4, h_mpeg2i, i_mjpeg)" % (leaked, named, len(pic_sess)))

    # (v) the CAVLC file plays (P6): the third session -- every PPS the core read is CABAC
    # (entropy_coding_mode_flag 1), and ffmpeg decodes the AUs the core read to exactly the
    # pictures it decodes the file to (the rewrite is lossless; ffmpeg shares nothing with it)
    okv, whyv = False, "no third session"
    if len(played) >= 3:
        v = vids(played[2]["rec"])
        cabac = [entropy_flags(a["data"]) for a in v]
        flags = [f for fs in cabac for f in fs]
        vref = [ln.split(",")[5].strip() for ln in open(os.path.join(media, "e_cavlc.decoded.framemd5"))
               if ln.strip() and not ln.startswith("#")]
        with tempfile.NamedTemporaryFile(suffix=".h264") as tf:
            tf.write(b"".join(a["data"] for a in v))
            tf.flush()
            out = subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-f", "h264", "-i", tf.name,
                                  "-f", "framemd5", "-"], capture_output=True, text=True).stdout
        got = [ln.split(",")[5].strip() for ln in out.splitlines() if ln.strip() and not ln.startswith("#")]
        okv = bool(flags) and all(flags) and bool(vref) and got == vref
        whyv = "PPS entropy flags %s, pictures %d decoded vs %d of the file, equal %s" % (
            sorted(set(flags)), len(got), len(vref), got == vref)
    check("(v) the CAVLC file plays: the core read CABAC (every PPS), decoding to the file's own pictures", okv, whyv)

    # (f) folders: inner.mkv (in a_dir) is the third file played
    # (0.15) pictures decoded on the ARM: f_mpeg4 (frames), h_mpeg2i (woven field pairs, top first), i_mjpeg
    # (4:2:2 full range) -- each session's pictures, in order, against ffmpeg's decode of the file
    by = {k: [p for p in pics if p["sess"] == k] for k in pic_sess}

    def pics_vs(k, n, want_st, want_rate):
        fm = framemd5(os.path.join(media, n + ".decoded.framemd5"))
        tl = [ln.strip().rstrip(",") for ln in open(os.path.join(media, n + ".times")) if ln.strip()]
        tn, td = (int(x) for x in tl[0].split("/"))
        for i, ln in enumerate(tl[1:]):        # av_rescale_q's rounding: to the nearest, halves away from 0
            if i < len(fm):
                fm[i]["pts90"] = (int(ln) * 90000 * tn * 2 + td) // (2 * td)
        ps = by.get(k, [])
        if not ps:
            return False, "no pictures"
        bad = []
        for i, p in enumerate(ps):
            w, h, planes = visible(p)
            d = p["d"]
            if i >= len(fm) or md5(planes) != fm[i]["md5"]:
                bad.append("picture %d's pixels" % i)
            elif p["pts"] != fm[i]["pts90"] or not (p["flags"] & M.F["PTS_VALID"]):
                bad.append("picture %d's PTS %d, the file's %d" % (i, p["pts"], fm[i]["pts90"]))
            elif d["st"] != want_st or M.pic_check(d) is not None or d["cl"] or d["ct"]:
                bad.append("picture %d's descriptor %s" % (i, d))
            elif not d["tv"] or abs(d["ts"] / (2.0 * d["nuit"]) - want_rate) > 0.01:
                bad.append("picture %d's rate %d / 2 x %d" % (i, d["ts"], d["nuit"]))
            elif bool(p["flags"] & M.F["END_OF_STREAM"]) != (i == len(ps) - 1):
                bad.append("END_OF_STREAM on picture %d of %d" % (i, len(ps)))
        if len(ps) != len(fm):
            bad.append("%d pictures, the file decodes to %d" % (len(ps), len(fm)))
        return not bad, "; ".join(bad[:3]) or "%d pictures" % len(ps)

    ok1, why1 = pics_vs(pic_sess[0], "f_mpeg4", 0, 30.0) if len(pic_sess) >= 1 else (False, "no pictures")
    check("(p1) f_mpeg4 decoded on the ARM: every picture as ffmpeg decodes it, with its PTS, frames, the last with END_OF_STREAM",
          ok1, why1)
    # (p4) f_mpeg4's DTS 5.1 (a tone in the center only) downmixed with its center: both sides carry it, at
    # ffmpeg's level (the session's audio starts with its first picture, so levels, not samples, compare)
    ok4, why4 = False, "no audio"
    s4 = [s for s in ss if pic_sess and s["k"] == pic_sess[0]]
    if s4:
        pcm = b"".join(r["data"] for r in s4[0]["rec"] if r["t"] == "a")
        ref4 = open(os.path.join(media, "f_mpeg4.pcm"), "rb").read()

        def lr(b):
            n = len(b) // 4
            v = struct.unpack("<%dh" % (2 * n), b[:4 * n])
            rms = lambda x: (sum(a * a for a in x) / max(1, len(x))) ** 0.5
            return rms(v[0::2]), rms(v[1::2])
        (gl, gr), (rl, rr) = lr(pcm), lr(ref4)
        ok4 = len(pcm) > 4 * 9600 and rl > 100 and all(abs(g - q) <= 0.1 * q for g, q in ((gl, rl), (gr, rr)))
        why4 = "L / R rms %.0f / %.0f, ffmpeg's %.0f / %.0f (%d frames)" % (gl, gr, rl, rr, len(pcm) // 4)
    check("(p4) f_mpeg4's DTS 5.1 downmixed with its center (a center-only tone in both sides, at ffmpeg's level)",
          ok4, why4)
    ok2, why2 = pics_vs(pic_sess[1], "h_mpeg2i", 1, 30000 / 1001.0) if len(pic_sess) >= 2 else (False, "no pictures")
    check("(p2) h_mpeg2i (interlaced MPEG-2): every picture a woven field pair, top first, as ffmpeg decodes it",
          ok2, why2)
    ok3, why3 = False, "no pictures"
    if len(pic_sess) >= 3:
        ps = by[pic_sess[2]]
        want = mjpeg_expected(open(os.path.join(media, "i_mjpeg.yuvj422p"), "rb").read(), 320, 240)
        got = [visible(p)[2] for p in ps]
        cols = sorted(set(p["colour"] for p in ps))
        ok3 = len(got) == len(want) and got == want and cols == [2]
        why3 = "%d pictures vs %d frames; first difference at picture %s; colour codes %s (want [2])" % (
            len(got), len(want), next((i for i, (a, b) in enumerate(zip(got, want)) if a != b), None), cols)
    check("(p3) i_mjpeg (4:2:2 full range): every picture 4:2:0, its full range kept and tagged BT.601 full (0.16)",
          ok3, why3)

    check("(f) a folder entered: the ninth file played is a_dir/inner.mkv",
          len(played) >= 9 and names[8] == "inner", "played %s" % names)

    # (g) the seek: RIGHT once -> one new session of inner, its first AU an IDR (SPS / PPS) at the
    # position then + 30 s (at or before it, within a GOP: 1 s)
    right = [c for c in script if c["cmd"].startswith("press RIGHT")]
    okg, whyg = False, "no RIGHT press / no fourth session"
    if right and len(played) >= 10 and names[9] == "inner":
        k3 = played[8]["k"]
        t = right[0]["t0"]
        before = [x for x in stc if x[0] <= t and x[1] == k3 and x[2]]
        if before:
            pos = before[-1][5] / 90000.0 - fx["inner_start"]
            v = vids(played[9]["rec"])
            first = v[0]["pts"] / 90000.0 - fx["inner_start"] if v and v[0]["pts"] is not None else -1
            target = pos + 30
            idr = v and {5, 7, 8} <= nal_types(v[0]["data"])
            # by MD5 AND PTS: one colour's IDRs are byte-identical
            idx = next((i for i, p in enumerate(ref["inner"]["fm"])
                        if md5(v[0]["data"]) == p["md5"] and v[0]["pts"] == p["pts90"]), None)
            ok_from = idx is not None and exact(played[9], "inner", idx)[0]
            okg = bool(idr) and target - 1.05 <= first <= target + 0.05 and ok_from and len(played) == 10
            whyg = "position %.2f -> first AU at %.2f (target %.2f), IDR %s, AUs as the file's %s, played %d" % (
                pos, first, target, bool(idr), ok_from, len(played))
    check("(g) the seek: RIGHT -> one new session, an IDR at the position + 30 s (within a GOP)", okg, whyg)

    # (r1) 50 Hz asked for before each 25 frames/s file's first session (b_pal, inner)
    def req_between(a, b, val):
        return [x for x in settings if a <= x[0] <= b and x[3] == val]
    t_b = played[0]["t_start"] if played else 0
    t_c = played[1]["t_start"] if len(played) >= 2 else 0
    t_i = played[8]["t_start"] if len(played) >= 9 else 0
    t_c_end = played[1]["t_start"] if len(played) >= 2 else 0
    r1 = bool(played) and len(played) >= 9 and req_between(0, t_b, 3) and req_between(t_c_end, t_i, 3)
    check("(r1) Refresh Rate 50 Hz asked for before each 25 frames/s file starts (b_pal, inner)", bool(r1),
          "requests %s" % [(round(x[0] - (ss[0]["t_start"] if ss else 0), 2), x[3]) for x in settings])

    # (r2) Auto given back: before c_ok (30 frames/s) starts, and when the player ends; the mirror Auto
    last_press = [c for c in script if c["cmd"].startswith("press BACK+START")]
    t_quit = last_press[-1]["t0"] if last_press else 1e18
    r2 = len(played) >= 2 and req_between(t_b, t_c, 0) and req_between(t_quit, 1e18, 0) and final == 0
    check("(r2) Refresh Rate Auto given back: before c_ok, and at the end (the mirror Auto)", bool(r2),
          "requests %s, final %d" % ([(round(x[0] - (ss[0]["t_start"] if ss else 0), 2), x[3]) for x in settings], final))

    # (s1) the SRT track (default) shown in its time: "The first cue" between 0.5 and 2.5 s
    subs = []
    for ln in log:
        m = re.match(r"h264player: subtitle at (-?[0-9.]+): (.*)$", ln)
        if m:
            subs.append((float(m.group(1)), m.group(2)))
    s1 = [p for p, t in subs if t == "The first cue"]
    check("(s1) the file's default SRT track on screen in its time (The first cue, 0.5 - 2.5 s)",
          bool(s1) and all(0.4 <= p <= 2.6 for p in s1), "cues %s" % subs[:6])

    # (s2) X: the ASS track, its Text as plain lines (tags gone, \N a line break, the drawing dropped)
    s2 = [p for p, t in subs if t == "An ASS line|on two"]
    raw = [t for p, t in subs if "Default" in t or "m 0 0" in t or "\\N" in t or "{" in t]
    check("(s2) X: the ASS track's cue as plain text in its time (3.0 - 5.5 s), no event fields or drawing",
          bool(s2) and all(2.9 <= p <= 5.6 for p in s2) and not raw, "cues %s" % subs[:8])

    # (z1) the screensaver (P5): left alone in the list after B, the overlay's corner pixel (outside
    # every list and panel) turns the veil's -- alpha 11 from 3.6 s, 15 from 7.2 s (the ini's times);
    # never before that phase (playing is never idle, and the list's other pauses are ~2 s)
    ovl = [tuple(float(x) if i == 0 else int(x) for i, x in enumerate(ln.split()))
           for ln in open(os.path.join(outdir, "ovl.txt")) if ln.strip()]
    pb = [c for c in script if c["cmd"].split("#")[0].strip() == "press B"]
    wake = None
    if pb:
        idle = pb[-1]["t1"]
        downs = [c for c in script if c["cmd"].startswith("press DOWN") and c["t0"] > idle]
        wake = downs[0]["t0"] if downs else None
        early = [round(o[0] - idle, 2) for o in ovl if o[0] < idle and o[3] > 0]
        # the veil at both edges of the canvas (the right one on the 852-wide native raster: T7)
        dim = [o[0] - idle for o in ovl if idle < o[0] < (wake or 1e18) and o[3] == 11 and o[4] == 11]
        black = [o[0] - idle for o in ovl if idle < o[0] < (wake or 1e18) and o[3] == 15 and o[4] == 15]
        ok1 = not early and bool(dim) and bool(black) and 3.4 <= min(dim) < 7.2 and min(black) >= 7.0
        why1 = "veil before the idle phase at %s; dimmed (both edges) from %s s, black from %s s" % (
            early[:3], round(min(dim), 2) if dim else None, round(min(black), 2) if black else None)
    else:
        ok1, why1 = False, "no B press"
    check("(z1) the screensaver: the list left alone dims at 3.6 s and goes black at 7.2 s, never before", ok1, why1)

    # (z2) the press that wakes it does only that: the veil goes, and the A after it opens a_dir (a
    # DOWN that moved the selection would make it play b_pal: a fifth session)
    if wake is not None:
        after = [o for o in ovl if wake < o[0] < wake + 1.5]
        gone = bool(after) and after[-1][3] <= 0
        later = [s for s in played if s["t_start"] > wake]
        woke = any("woke the screensaver" in ln for ln in log)
        check("(z2) a press only wakes the screensaver: the veil goes, the selection stays (no file played)",
              gone and not later and woke, "veil after the wake %s, sessions after %d, logged %s" % (
                  [o[3] for o in after][-3:], len(later), woke))
    else:
        check("(z2) a press only wakes the screensaver: the veil goes, the selection stays (no file played)",
              False, "no wake press")

    # (w) the loop stays responsive while writes are slow (each 15 ms in this build: the A9's CAVLC
    # rewrite): from the first press to the quit, the player's loop never stalls over 0.25 s
    gp = os.path.join(outdir, "loopgap.txt")
    gaps = [tuple(float(x) for x in ln.split()) for ln in open(gp) if ln.strip()] if os.path.exists(gp) else None
    t_first = script[0]["t0"] if script else 0
    t_last = script[-1]["t0"] if script else 0
    stalls = [(round(a - t_first, 2), round(b - a, 2)) for a, b in (gaps or []) if t_first < a < t_last]
    check("(w) slow writes (the A9's CAVLC rewrite): the player's loop never stalls over 0.25 s (the pad read)",
          gaps is not None and not stalls, "stalls (at, s) %s" % stalls[:6])

    # (x) / (y) the interleaves of 2026-10-09's transcode (docs/jellyfin.md S12), in files: the seventh and
    # eighth sessions
    sl = played[6] if len(played) >= 7 and names[6] == "l_ahead" else None
    lead_f, _ = ts_skew.skew(os.path.join(media, "l_ahead.packets"))
    okx, whyx = False, "fixture: audio %.2f s ahead; l_ahead not the seventh played (%s)" % (lead_f, names[6:7])
    if sl is not None:
        vmax, worst, n_a = None, None, 0
        for r in sl["rec"]:
            if r["t"] == "v" and r["pts"] is not None:
                vmax = r["pts"] if vmax is None else max(vmax, r["pts"])
            elif r["t"] == "a" and r["pts"] is not None and vmax is not None:
                n_a += 1
                worst = max(worst if worst is not None else -1e9, (r["pts"] - vmax) / 90000.0)
        oke, whye = exact(sl, "l_ahead")
        lastl = vids(sl["rec"])[-1] if vids(sl["rec"]) else None
        oka, whya = pcm_check(sl, os.path.join(media, "l_ahead.pcm"), fx["l_ahead_audio_t0"])
        okx = (lead_f >= 5.0 and n_a > 0 and worst <= LEAD_TOL_S and oke and lastl is not None and lastl["eos"]
               and oka)
        whyx = "fixture: audio %.2f s ahead; %d timed records, the most ahead %s s; %s; audio %s" % (
            lead_f, n_a, None if worst is None else round(worst, 3), whye, whya)
    check("(x) l_ahead (audio 6.5 s ahead in the file): no AUDIO record over 1.3 s ahead of the video before it, "
          "every AU, the audio whole", okx, whyx)
    sm = played[7] if len(played) >= 8 and names[7] == "m_late" else None
    _, first_a = ts_skew.skew(os.path.join(media, "m_late.packets"))
    oky, whyy = False, "fixture: the first audio after %s s of video; m_late not the eighth played (%s)" % (
        first_a, names[7:8])
    if sm is not None:
        oka, whya = pcm_check(sm, os.path.join(media, "m_late.pcm"), fx["m_late_audio_t0"])
        oky = first_a is not None and first_a >= 2.5 and oka
        whyy = "fixture: the first audio after %.2f s of video; audio %s" % (first_a or -1, whya)
    check("(y) m_late (its audio past the probe): AUDIO records with PTS, the PCM equal to a reference decode",
          oky, whyy)

    print("check_player: %s" % ("FAILURES" if fails else "ALL GREEN"))
    return 1 if fails else 0


LEAD_TOL_S = 1.3       # the player's 1 s (AUD_LEAD), the two access units it holds back, a record's gathering


def pcm_check(s, pcm, t0, min_s=3):
    """the session's PCM against ffmpeg's decode of the file, EXACT (the Jellyfin test's audio_check):
    every record with a PTS, at its own place within 1 ms; the frames equal from the first record's
    place on, the first 2,048 excused when the player started past the reference's first frame (its
    decoder's first AAC frame overlap-adds with zeros)"""
    au = [r for r in s["rec"] if r["t"] == "a"]
    if not au:
        return False, "no AUDIO record"
    if any(r["pts"] is None for r in au):
        return False, "%d of %d records without PTS" % (sum(r["pts"] is None for r in au), len(au))
    C = b"".join(r["data"] for r in au)
    R = open(pcm, "rb").read()
    e = round((au[0]["pts"] / 90000.0 - t0) * 48000)
    skip = 0 if e == 0 else 2048
    if len(C) // 4 < skip + 48000 * min_s:
        return False, "only %d frames" % (len(C) // 4)
    match = next((o for o in sorted(range(e - 48, e + 49), key=lambda o: abs(o - e)) if o >= 0 and
                  C[skip * 4:] == R[(o + skip) * 4:(o + skip) * 4 + len(C) - skip * 4]), None)
    if match is None:
        return False, "no exact match within 1 ms of the PTS-derived offset %d" % e
    f, worst = 0, 0
    for r in au:
        worst = max(worst, abs(match + f - round((r["pts"] / 90000.0 - t0) * 48000)))
        f += len(r["data"]) // 4
    if worst > 48:
        return False, "a record's PTS %d frames from its place" % worst
    return True, "%d records, %d frames equal from offset %d" % (len(au), len(C) // 4, match)


if __name__ == "__main__":
    sys.exit(main())
