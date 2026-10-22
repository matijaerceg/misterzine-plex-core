#!/usr/bin/env python3
"""ring_model.py -- the HPS interface's producer and consumer, modelled from
docs/architecture.md "The HPS interface" (NOT from the RTL: an oracle written from the
design it checks shares its bugs, CLAUDE.md "Independent oracle"). Layout constants come
from tools/ring_layout.py.

  Producer     writes records the way hps/lib/h264ring.c does (16-byte alignment, a PAD at
               the ring's end, flow control against the core's read index), recording
               each step for a bench to replay: pokes into DDR3, write-index and nonce
               stores, waits on the core's published read index / ack.
  consume()    the reference consumer: walks the records of a session in index order and
               yields what the core must deliver -- payload bytes with their PTS mark and
               access-unit end, stream resets, the end-of-stream flush -- and the error the
               core must stop on (code, position, offending word), with the counters.

    ring_model.py --scenario NAME --out STEM [--ring-words N]
        write STEM.steps.hex (the producer's script), STEM.expect.hex (the delivered
        stream), STEM.final.hex (status fields to check), STEM.audio.hex (the AUDIO
        payloads, 0.5) and STEM.pics.hex (0.15: the pictures the display must be given) for
        bench/h264/ring_rd_tb.sv
    ring_model.py --list      the scenario names (one per bench arm)

Bench file formats (64-bit hex words, one per line, for $readmemh):
  steps   op word [63:56] op  [55:32] n  [31:0] arg, then n data words for POKE
          OP_POKE arg=word address, n words      OP_WIDX arg=write index
          OP_NONCE arg=nonce                     OP_WAIT_READ arg=index: wait until the
          published read index has reached it    OP_WAIT_ACK arg=nonce
          OP_DELAY arg=clk_sys cycles            OP_OSD_RESET (a reset_n pulse)
          OP_WAIT_STATE arg=state                OP_END
          OP_RELEASE: release the core's resets (the bench holds them until then, so a
          step before it is DDR3 left by an earlier load)
          OP_STILL arg=clk_sys cycles: nothing may be delivered and the published read
          index may not move for that long (0.5: the pause)
          OP_WAIT_FIELD n=1: wait until a status field holds a value; the data word is
          {[55:48] word, [47:40] lsb, [39:32] width, [31:0] value}
  expect  [63:56] kind: K_BYTE ([7:0] byte [8] mark [9] au_end [42:10] PTS), K_RESET,
          K_EOS, K_PREFIX / K_PREFIX_END (the bytes between may be delivered only in
          part: a session replaced mid-stream; K_PREFIX bit 0: they MUST stop early),
          K_AUDIO (0.5: a descriptor queued, [55:33] length [32:0] PTS) always followed by
          K_AUDIO2 ([32] PTS_VALID [31:0] the record's index), K_END
  audio   (0.5) every AUDIO record's payload in order, as the core must fetch it: its
          ceil(length / 8) words (the producer pads with zero bytes)
  final   pairs: {[23:16] word [15:8] lsb [7:0] width}, the expected value
  pics    (0.15) what recon_out must present, in order (bench/h264/ring_rd_tb.sv's stand-in
          display takes each record and releases the store it took before): per picture
          K_PIC1 {[4:0] store [5] frame [6] first_bot [14:7] w [22:15] hf [23] timing_v
          [27:24] ps [28] ps_v [29] pts_v}, K_PIC2 {[40:0] crop with cuy4}, K_PIC3 {[39:0]
          aspect}, K_PIC4 {[63:32] ts [31:0] nuit} (no kind byte: the whole word), K_PIC5
          {[32:0] PTS}; K_PEND the END record (END_OF_STREAM); K_END the list's end
"""
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ring_layout as L  # noqa: E402

T = {n: v for n, v in L.TYPES}
F = {n: 1 << b for n, b, _ in L.FLAGS}
S = {n: v for n, v in L.STATES}
E = {n: v for n, v, _ in L.ERRORS}
FLAG_TYPES = {n: t for n, _, t in L.FLAGS}
M32 = 0xFFFFFFFF

OP_POKE, OP_WIDX, OP_NONCE, OP_WAIT_READ, OP_WAIT_ACK, OP_DELAY, OP_OSD_RESET, OP_WAIT_STATE, OP_END, OP_RELEASE, \
    OP_STILL, OP_WAIT_FIELD = range(1, 13)
K_BYTE, K_RESET, K_EOS, K_PREFIX, K_PREFIX_END, K_AUDIO, K_AUDIO2, K_END = 1, 2, 3, 4, 5, 6, 7, 0xFF
K_PIC1, K_PIC2, K_PIC3, K_PIC5, K_PEND = 0x11, 0x12, 0x13, 0x15, 0x16      # 0.15 (pics.hex)

# 0.15: a PICTURE's descriptor (docs/architecture.md "Pictures from the program"), its fields as
# the table there lists them: (name, payload word, lsb, width). Everything else is reserved.
PIC_FIELDS = [("store", 0, 0, 5), ("w", 0, 8, 8), ("hf", 0, 16, 8), ("st", 0, 24, 2), ("ps", 0, 32, 4),
              ("psv", 0, 36, 1), ("idc", 0, 40, 8), ("sarw", 1, 0, 16), ("sarh", 1, 16, 16), ("tv", 1, 32, 1),
              ("nuit", 2, 0, 32), ("ts", 2, 32, 32), ("cl", 3, 0, 10), ("cr", 3, 10, 10), ("ct", 3, 20, 10),
              ("cb", 3, 30, 10)]
PIC_USED = [0, 0, 0, 0]
for _n, _w, _l, _b in PIC_FIELDS:
    PIC_USED[_w] |= ((1 << _b) - 1) << _l


def pic_desc(**kw):
    d = dict(store=0, w=45, hf=30, st=0, ps=0, psv=0, idc=0, sarw=0, sarh=0, tv=1, nuit=1001, ts=60000,
             cl=0, cr=0, ct=0, cb=0, rsv=(0, 0, 0, 0))
    d.update(kw)
    return d


def pic_payload(d):
    words = list(d.get("rsv", (0, 0, 0, 0)))
    for n, w, l, b in PIC_FIELDS:
        words[w] |= (d[n] & ((1 << b) - 1)) << l
    return b"".join(x.to_bytes(8, "little") for x in words)


def pic_unpack(payload):
    words = [int.from_bytes(payload[8 * i:8 * i + 8], "little") for i in range(4)]
    d = {n: (words[w] >> l) & ((1 << b) - 1) for n, w, l, b in PIC_FIELDS}
    d["rsv_bad"] = any(words[i] & ~PIC_USED[i] & ((1 << 64) - 1) for i in range(4))
    return d


def pic_check(d):
    """the descriptor's checks, in the interface's order (FIELD, STORE, SIZE, CROP): an error name or None"""
    pair = d["st"] != 0
    if d["rsv_bad"] or d["st"] == 3 or (d["psv"] and (pair or d["ps"] not in (0, 3, 4, 5, 6, 7, 8))) or \
            17 <= d["idc"] <= 254 or (d["idc"] == 255 and (d["sarw"] == 0 or d["sarh"] == 0)) or \
            (d["tv"] and (d["nuit"] == 0 or d["ts"] == 0)):
        return "PIC_FIELD"
    if d["store"] >= L.DPB_STORES:
        return "PIC_STORE"
    if d["w"] == 0 or d["hf"] == 0 or d["w"] > L.PIC_MAX_SIDE or d["hf"] > L.PIC_MAX_SIDE or \
            (pair and d["hf"] % 2) or d["w"] * d["hf"] > L.CAP_MAX_MBS:
        return "PIC_SIZE"
    if d["cl"] + d["cr"] >= 8 * d["w"] or d["ct"] + d["cb"] >= 8 * d["hf"]:
        return "PIC_CROP"
    return None


def pic_colour(d, colour):
    """0.16 (docs/architecture.md "The colour"): a PICTURE's code -- its own 1-6, else the size rule
    on the shown size (the crop in pairs of columns / frame lines): >= 1,280 wide or > 576 high BT.709"""
    if 1 <= colour <= 6:
        return colour
    w = 16 * d["w"] - 2 * (d["cl"] + d["cr"])
    h = 16 * d["hf"] - 2 * (d["ct"] + d["cb"])
    return L.const("COLOUR_709") if (w >= 1280 or h > 576) else L.const("COLOUR_601")


def pad16(n):
    return (n + 15) & ~15


def header(rtype, flags, seq, length, pts, sync=L.SYNC, colour=0):
    w0 = (rtype & 0xFF) | ((flags & 0xFF) << 8) | ((seq & 0xFFFF) << 16) | ((length & M32) << 32)
    w1 = (pts & ((1 << 48) - 1)) | ((colour & 7) << 33) | (sync << 48)   # 0.16: [35:33] the colour
    return w0, w1


def record_bytes(w0, w1, payload):
    b = w0.to_bytes(8, "little") + w1.to_bytes(8, "little") + bytes(payload)
    return b + bytes(pad16(len(payload)) - len(payload))


class Producer(object):
    """The client library's writer, step by step. `ring` is the ring's size in bytes;
    `ctrl_word` / `ring_word` the DDR3 word addresses (the bench uses a small ring)."""

    def __init__(self, ring=L.RING_SIZE, ctrl_word=L.CTRL_BYTE >> 3, ring_word=L.RING_BYTE >> 3):
        self.ring, self.ctrl_word, self.ring_word = ring, ctrl_word, ring_word
        self.steps = []
        self.w = 0          # the write index (free-running)
        self.seq = 0
        self.stream = {}    # index -> byte, what was written (the logical stream)
        self.nonce = 0
        self.stale = False

    # ---- low level
    def _poke_bytes(self, index, data):
        assert index % 8 == 0 and len(data) % 8 == 0
        words = [int.from_bytes(data[i:i + 8], "little") for i in range(0, len(data), 8)]
        i = 0
        while i < len(words):      # never across the ring's end in one poke
            off = ((index + 8 * i) % self.ring) // 8
            n = min(len(words) - i, self.ring // 8 - off)
            self.steps.append((OP_POKE, n, self.ring_word + off, words[i:i + n]))
            i += n
        for k, b in enumerate(data):
            self.stream[(index + k) & M32] = b

    def op(self, code, arg=0):
        self.steps.append((code, 0, arg & M32, []))

    def poke_ctrl(self, word, value):
        self.steps.append((OP_POKE, 1, self.ctrl_word + word, [value]))

    def set_widx(self, w):
        self.w = w & M32
        self.op(OP_WIDX, self.w)

    # ---- the session
    def start_session(self, nonce, wait=True):
        """write a new nonce (the write index untouched) and wait for the core's ack. The
        core starts the session at the write index it read in the same poll."""
        self.nonce = nonce & M32
        self.seq = 0
        self.op(OP_NONCE, self.nonce)
        if wait:
            self.op(OP_WAIT_ACK, self.nonce)

    # ---- records
    def _room(self, need):
        """flow control: wait until the core's read index lets `need` more bytes in"""
        self.op(OP_WAIT_READ, (self.w + need - self.ring) & M32)

    def write_record(self, rtype, flags=0, payload=b"", pts=0, corrupt=None, publish=True, flow=True, colour=0):
        n = 16 + pad16(len(payload))
        to_end = self.ring - (self.w % self.ring)
        if n > to_end and rtype != T["PAD"] and not (corrupt or {}).get("no_pad"):
            self.write_pad(to_end)
        at = self.w
        w0, w1 = header(rtype, flags, self.seq, len(payload), pts, colour=colour)
        c = corrupt or {}
        if "w0" in c:
            w0 = c["w0"](w0)
        if "w1" in c:
            w1 = c["w1"](w1)
        if flow:
            self._room(n)
        self._poke_bytes(self.w, record_bytes(w0, w1, payload))
        self.seq = (self.seq + 1) & 0xFFFF
        self.w = (self.w + n) & M32
        if publish:
            self.op(OP_WIDX, self.w)
        return at

    def write_pad(self, to_end=None):
        if to_end is None:
            to_end = self.ring - (self.w % self.ring)
        assert to_end >= 16 and to_end % 16 == 0
        return self.write_record(T["PAD"], 0, bytes(to_end - 16), 0)

    def write_au(self, payload, pts=None, flags=0, **kw):
        if pts is not None:
            flags |= F["PTS_VALID"]
        return self.write_record(T["VIDEO_AU"], flags, payload, pts or 0, **kw)

    def write_picture(self, desc, pts=None, flags=0, **kw):
        """0.15: a PICTURE record: the descriptor (pic_desc()) of a picture already in its store"""
        if pts is not None:
            flags |= F["PTS_VALID"]
        return self.write_record(T["PICTURE"], flags, pic_payload(desc), pts or 0, **kw)

    def write_audio(self, payload, pts=None, **kw):
        """0.5: an AUDIO record: 48 kHz s16 stereo frames (4 bytes each)"""
        return self.write_record(T["AUDIO"], F["PTS_VALID"] if pts is not None else 0, payload, pts or 0, **kw)

    def wait_field(self, name, value):
        w, lsb, width = name if isinstance(name, tuple) else L.field(name)
        self.steps.append((OP_WAIT_FIELD, 1, 0, [(w << 48) | (lsb << 40) | (width << 32) | (value & M32)]))

    def wait_consumed(self):
        self.op(OP_WAIT_READ, self.w)

    # ---- bench files
    def steps_hex(self):
        out = []
        for code, n, arg, data in self.steps:
            out.append((code << 56) | (n << 32) | arg)
            out.extend(data)
        out.append(OP_END << 56)
        return ["%016x" % v for v in out]


# ------------------------------------------------------------------ reference consumer
class Consumed(object):
    def __init__(self):
        self.items = []         # ("byte", b, mark, pts, au_end) | ("reset",) | ("eos",) | ("audio", pos, len, ptsv, pts)
        self.audio = []         # 0.5: each AUDIO record's payload, in order
        self.err, self.err_pos, self.err_word = 0, 0, 0
        self.n_au = self.n_pad = self.n_audio = self.es_bytes = self.ll_mismatch = 0
        self.gfx, self.gfx_mismatch = 0, 0          # 0.4: the stream's GRAPHICS, later disagreements
        self.colour, self.colour_mismatch = 0, 0    # 0.16: the stream's colour (its first VIDEO_AU's), later disagreements
        self.n_streams = 0
        self.ll = 0
        self.eos = False
        self.read = 0
        # 0.15: the pictures given to the display, the stream's kind, the stand-in display's hold
        self.pics = []          # ("pic", d, ptsv, pts) | ("pend",)
        self.kind = None        # the current stream's: None (no video record yet), "coded", "pic"
        self.held = None        # the store the stand-in display holds (the last one emitted)
        self.pic_emitted = 0


def consume(stream, start, end, ring, cons=None, max_payload=L.MAX_PAYLOAD):
    """Walk the records in stream[start:end) (the byte indices the producer wrote, a
    dict) as the core must. Returns a Consumed (appends to `cons` when given: a later
    session continues the counters). A new session starts with a stream reset."""
    c = cons or Consumed()
    c.items.append(("reset",))
    c.n_streams += 1
    c.eos = False
    c.kind, c.held = None, None
    first_au = True
    pos, seq = start, 0

    def word(i):
        return int.from_bytes(bytes(stream[(i + k) & M32] for k in range(8)), "little")

    while ((end - pos) & M32) != 0 and not c.err:
        avail = (end - pos) & M32
        if avail < 16:
            break
        w0, w1 = word(pos), word(pos + 8)
        rtype, flags, hseq, length = w0 & 0xFF, (w0 >> 8) & 0xFF, (w0 >> 16) & 0xFFFF, w0 >> 32
        pts, colour, zero, sync = w1 & ((1 << 33) - 1), (w1 >> 33) & 7, (w1 >> 36) & 0xFFF, w1 >> 48

        def fail(code):
            c.err, c.err_pos, c.err_word = code, pos, w0

        # the checks in the order the core makes them (word 0's fields, then word 1's,
        # then the stream's state): the first failing one is the code
        names = {v: n for n, v in T.items()}
        tname = names.get(rtype)
        if tname in (None, "INVALID"):
            fail(E["HDR_TYPE"]); break
        if tname == "CONTROL":
            fail(E["CONTROL_UNSUPPORTED"]); break
        bad_flag = flags & ~sum(F.values())
        for fn, fbit in F.items():
            if flags & fbit and tname not in FLAG_TYPES[fn]:
                bad_flag = 1
        if bad_flag:
            fail(E["HDR_FLAGS"]); break
        if length > max_payload or (tname == "VIDEO_AU" and length == 0) or \
                (tname == "AUDIO" and (length == 0 or length % 4)) or \
                (tname == "PICTURE" and length != L.PIC_PAYLOAD):        # 0.5: whole 4-byte frames; 0.15: 32
            fail(E["HDR_LENGTH"]); break
        n = 16 + pad16(length)
        off = pos % ring
        if tname == "PAD" and off + n != ring:
            fail(E["HDR_WRAP"]); break
        if off + n > ring:
            fail(E["HDR_WRAP"]); break
        if hseq != seq:
            fail(E["HDR_SEQ"]); break
        if sync != L.SYNC or zero:
            fail(E["HDR_SYNC"]); break
        if colour == 7 or (colour and tname not in ("VIDEO_AU", "PICTURE")):   # 0.16
            fail(E["HDR_COLOUR"]); break
        if avail < n:
            break                         # not all written yet: the core waits
        if tname in ("VIDEO_AU", "PICTURE"):
            if c.eos and not flags & F["DISCONTINUITY"]:
                fail(E["NEED_DISCONT"]); break
            if flags & F["DISCONTINUITY"]:
                c.items.append(("reset",))
                c.n_streams += 1
                c.eos = False
                c.kind, c.held = None, None
                first_au = True
            kind = "pic" if tname == "PICTURE" else "coded"
            if c.kind is not None and c.kind != kind:     # 0.15: a stream is one kind or the other
                fail(E["STREAM_KIND"]); break
        if tname == "PICTURE":
            ll = 1 if flags & F["LOW_LATENCY"] else 0
            gfx = 1 if flags & F["GRAPHICS"] else 0
            if first_au:
                c.ll, c.gfx, c.kind = ll, gfx, "pic"
                c.colour, c.colour_mismatch = 0, 0        # 0.16: a picture stream's colour is per picture
                first_au = False
            else:
                if ll != c.ll:
                    c.ll_mismatch += 1
                if gfx != c.gfx:
                    c.gfx_mismatch = min(c.gfx_mismatch + 1, 0xFFFF)
            d = pic_unpack(bytes(stream[(pos + 16 + k) & M32] for k in range(length)))
            bad = pic_check(d)
            if bad:
                fail(E[bad]); break
            if d["store"] == c.held:                      # the stand-in still holds it
                fail(E["PIC_BUSY"]); break
            ptsv = 1 if flags & F["PTS_VALID"] else 0
            d = dict(d, colour=pic_colour(d, colour))     # 0.16: the code pic_in resolves
            c.pics.append(("pic", d, ptsv, pts if ptsv else 0))
            c.held = d["store"]
            c.pic_emitted += 1
            if flags & F["END_OF_STREAM"]:
                c.pics.append(("pend",))
                c.eos = True
        elif tname == "VIDEO_AU":
            if first_au:
                c.kind = "coded"
            ll = 1 if flags & F["LOW_LATENCY"] else 0
            gfx = 1 if flags & F["GRAPHICS"] else 0      # 0.4: taken from the stream's first, like LOW_LATENCY
            if first_au:
                c.ll, c.gfx = ll, gfx
                c.colour, c.colour_mismatch = colour, 0   # 0.16: the stream's colour, from its first VIDEO_AU
                first_au = False
            else:
                if ll != c.ll:
                    c.ll_mismatch += 1
                if gfx != c.gfx:
                    c.gfx_mismatch = min(c.gfx_mismatch + 1, 0xFFFF)
                if colour != c.colour:
                    c.colour_mismatch = min(c.colour_mismatch + 1, 0xFFFF)
            mark = bool(flags & F["PTS_VALID"])
            for k in range(length):
                b = stream[(pos + 16 + k) & M32]
                c.items.append(("byte", b, 1 if (mark and k == 0) else 0, pts if (mark and k == 0) else 0,
                                1 if k == length - 1 else 0))
            c.es_bytes += length
            c.n_au += 1
            if flags & F["END_OF_STREAM"]:
                c.items.append(("eos",))
                c.eos = True
        elif tname == "PAD":
            c.n_pad += 1
        elif tname == "AUDIO":
            # 0.5: queued for playing -- the record's index, its length and PTS; the core
            # fetches the payload from the ring later (the ring is the buffer)
            ptsv = 1 if flags & F["PTS_VALID"] else 0
            c.items.append(("audio", pos, length, ptsv, pts if ptsv else 0))
            c.audio.append(bytes(stream[(pos + 16 + k) & M32] for k in range(length)))
            c.n_audio += 1
        pos = (pos + n) & M32
        seq = (seq + 1) & 0xFFFF
    c.read = pos
    return c


def expect_hex(sections):
    """sections: list of (items, prefix): prefix False (exact), True (may stop early), or
    "cut" (MUST stop early: the session is replaced while the reader is still behind, so
    only a prompt switch -- the slow poll -- cuts it)"""
    out = []
    for items, prefix in sections:
        if prefix:
            out.append((K_PREFIX << 56) | (1 if prefix == "cut" else 0))
        for it in items:
            if it[0] == "byte":
                _, b, mark, pts, au_end = it
                out.append((K_BYTE << 56) | (pts << 10) | (au_end << 9) | (mark << 8) | b)
            elif it[0] == "reset":
                out.append(K_RESET << 56)
            elif it[0] == "eos":
                out.append(K_EOS << 56)
            elif it[0] == "audio":
                _, pos, length, ptsv, pts = it
                out.append((K_AUDIO << 56) | (length << 33) | pts)
                out.append((K_AUDIO2 << 56) | (ptsv << 32) | (pos & M32))
        if prefix:
            out.append(K_PREFIX_END << 56)
    out.append(K_END << 56)
    return ["%016x" % v for v in out]


def pics_hex(pics):
    """0.15: what recon_out must present, in order (see the docstring's "pics")"""
    out = []
    for it in pics:
        if it[0] == "pend":
            out.append(K_PEND << 56)
            continue
        _, d, ptsv, pts = it
        frame = 1 if d["st"] == 0 else 0
        out.append((K_PIC1 << 56) | (ptsv << 29) | (d["psv"] << 28) | (d["ps"] << 24) | (d["tv"] << 23) |
                   (d["hf"] << 15) | (d["w"] << 7) | ((1 if d["st"] == 2 else 0) << 6) | (frame << 5) | d["store"])
        crop = (d["cl"] << 30) | (d["cr"] << 20) | (d["ct"] << 10) | d["cb"]          # {cuy4 0, l, r, t, b}
        out.append((K_PIC2 << 56) | (d["colour"] << 41) | crop)   # 0.16: [43:41] the colour code
        out.append((K_PIC3 << 56) | (d["idc"] << 32) | (d["sarw"] << 16) | d["sarh"])
        out.append((d["ts"] << 32) | d["nuit"])
        out.append((K_PIC5 << 56) | pts)
    out.append(K_END << 56)
    return ["%016x" % v for v in out]


def audio_hex(payloads):
    out = []
    for pl in payloads:
        b = pl + bytes(-len(pl) % 8)
        out.extend(int.from_bytes(b[i:i + 8], "little") for i in range(0, len(b), 8))
    return ["%016x" % v for v in out] or ["0" * 16]


def final_hex(fields):
    out = []
    for name, value in fields:
        w, lsb, width = name if isinstance(name, tuple) else L.field(name)
        out.append((w << 16) | (lsb << 8) | width)
        out.append(value & ((1 << width) - 1) if width < 64 else value)
    return ["%016x" % v for v in out]


# ------------------------------------------------------------------ scenarios (bench arms)
def _au(rng, n, first=0):
    """a fake access unit: bytes that never contain a start code (the bench scores
    bytes, not H.264), n long"""
    return bytes([first & 0xFF] + [rng.randrange(1, 256) for _ in range(n - 1)])


def _std_final(c, nonce, state, extra=()):
    f = [("state", state), ("err", c.err), ("n_au", c.n_au), ("n_pad", c.n_pad), ("n_audio", c.n_audio),
         ("es_bytes", c.es_bytes & M32), ("n_streams", c.n_streams), ("ack_nonce", nonce),
         ("read_index", c.read), ("ll_mismatch", c.ll_mismatch), ("gfx_mismatch", c.gfx_mismatch),
         ("colour_override", 1 if c.colour else 0), ("colour_mismatch", c.colour_mismatch)]   # 0.16: word 86
    if c.err:
        f += [("err_pos", c.err_pos), ("err_word", c.err_word)]
    # 0.15: word 84 -- the stand-in display holds the last store emitted in the current stream
    f += [("pic_emitted", c.pic_emitted), ("pic_held", 0 if c.held is None else 1 << c.held),
          ("pic_mode", 1 if c.kind == "pic" else 0), ("cap_pic_stores", L.DPB_STORES)]
    return f + list(extra)


def scenario(name, ring_words=512, seed=1):
    rng = random.Random(seed)
    ring = ring_words * 8
    p = Producer(ring=ring, ctrl_word=L.CTRL_BYTE >> 3, ring_word=(L.CTRL_BYTE >> 3) + ring_words)
    sections = []
    final = []
    start = rng.randrange(0, 1 << 20) * 16
    if name == "R2":          # the u32 wrap: start just below 2^32
        start = ((1 << 32) - 3 * ring // 2 - 48) & ~15    # 6 words off a burst boundary: bursts cross the end
    nonce = rng.randrange(1, 1 << 32)

    if name == "R12":         # stale boot: a ring, a write index and a nonce left by an earlier load
        p.poke_ctrl(L.PROG_WORD + 1, 0x1234ABCD)
        p.set_widx(start)
        p.nonce = 0x1234ABCD
        p.write_record(T["VIDEO_AU"], F["PTS_VALID"], _au(rng, 40), 1000, flow=False)
        p.op(OP_RELEASE)
        p.op(OP_DELAY, 30000)
        sections.append(([], False))
        final = [("state", S["NO_SESSION"]), ("n_au", 0), ("es_bytes", 0), ("n_streams", 0)]
        return p, sections, final

    p.op(OP_RELEASE)
    p.op(OP_DELAY, 3000)      # the boot poll has seen the (unwritten, zero) nonce
    p.set_widx(start)

    if name == "R27":         # 0.13: the rumble (program words 36-38) -- passed to Main only during a session
        return _rumble(p, rng, start, nonce, ring)
    if name in ("R28", "R29", "R30", "R32", "R33", "R34", "R35", "R36"):   # 0.15 pictures; 0.16 the colour
        return _pictures(name, p, rng, nonce, ring)

    def session_consume():
        return consume(p.stream, s_start, p.w, ring)

    s_start = p.w
    p.start_session(nonce)

    if name in ("R1", "R2", "R3", "R14", "R17", "R18", "R21"):
        n_aus = {"R1": 40, "R2": 60, "R3": 30, "R14": 6, "R17": 12, "R18": 10, "R21": 12}[name]
        for i in range(n_aus):
            size = rng.choice([1, 15, 16, 17, 100, rng.randrange(1, ring // 3)]) if name != "R3" else ring - 16 - 16 * rng.randrange(0, 3)
            flags = F["LOW_LATENCY"] if (name == "R17" and i < 6) else 0
            if name == "R17" and i == 0:
                flags = F["LOW_LATENCY"]
            if name == "R21":                  # 0.4: GRAPHICS on the first 5, then off (7 disagree)
                flags = F["GRAPHICS"] if i < 5 else 0
            p.write_au(_au(rng, size, i), pts=rng.randrange(0, 1 << 33) if i % 3 else None, flags=flags)
            if name == "R14" and i % 2:
                p.op(OP_DELAY, 40000)      # idle: the fast poll must stay bounded
            if name == "R2" and i == 10:
                p.write_pad()              # a PAD written though a record would have fit
        p.wait_consumed()
        c = session_consume()
        sections.append((c.items, False))
        final = _std_final(c, nonce, S["PLAYING"])
        if name == "R3":          # a whole ring was legal; a write index beyond it is not
            bad_w = (p.w + ring + 16) & M32
            p.op(OP_WIDX, bad_w)
            p.op(OP_WAIT_STATE, S["ERROR"])
            final = [f for f in final if f[0] not in ("state", "err")]
            final += [("state", S["ERROR"]), ("err", E["WIDX_RANGE"]), ("err_pos", bad_w)]
        if name == "R17":
            final.append(((4, 16, 1), 1))    # live LOW_LATENCY: the stream's first AU asked for it
        if name == "R21":
            final.append(((4, 23, 1), 1))    # live GRAPHICS (0.4): the stream's first AU declared it
            final.append(((4, 16, 1), 0))    # ... and not LOW_LATENCY (the bits kept apart)
    elif name == "R22":       # 0.4: the settings request (program word 35), end to end
        # The bench stands in for Main: it adopts status_in when status_set rises, and word
        # 27's mirror reads that emulated menu. Its menu starts at R18's constants.
        opts = ["aspect", "deint", "video_out", "hdmi_deint", "analog_aspect", "refresh", "anti_twitter"]
        width = {"hdmi_deint": 1}
        lsb, b = {}, 0
        for o in opts:
            lsb[o] = b
            b += width.get(o, 2)
        menu = {"aspect": 2, "deint": 1, "video_out": 2, "hdmi_deint": 1, "analog_aspect": 3,
                "refresh": 1, "anti_twitter": 2}

        def req(seq, vals, reserved=0):
            v = sum(val << lsb[o] for o, val in vals.items())
            m = sum(1 << opts.index(o) for o in vals)
            return (seq << L.const("REQ_SEQ_LSB")) | (reserved << 20) | (m << L.const("REQ_MASK_LSB")) | v

        # the program's requests, each left for several polls: (word, applied?)
        reqs = [(req(1, {"aspect": 1}), True),                          # applied
                (req(1, {"deint": 2}), False),                          # the same sequence number: not a new request
                (req(2, {"video_out": 1, "refresh": 3}), True),         # two options at once
                (req(3, {"anti_twitter": 3}), False)]                   # refused: 3 is past Anti-Twitter's last (On)
        for i in range(3):
            p.write_au(_au(rng, rng.randrange(1, 300), i), pts=i)
        for w, applied in reqs:
            p.poke_ctrl(L.const("W_SETTINGS"), w)
            p.op(OP_DELAY, 4000)                # several polls (the slow poll is 3,000 clk_mem cycles)
            if applied:
                for o in opts:
                    if (w >> (L.const("REQ_MASK_LSB") + opts.index(o))) & 1:
                        menu[o] = (w >> lsb[o]) & ((1 << width.get(o, 2)) - 1)
        p.wait_consumed()
        c = session_consume()
        sections.append((c.items, False))
        final = _std_final(c, nonce, S["PLAYING"]) + [("osd_" + o, menu[o]) for o in opts] + \
            [("set_seq", 3), ("set_err", 1)]
    elif name == "R20":       # a PAD that stops short of the ring's end
        for i in range(3):
            p.write_au(_au(rng, rng.randrange(1, 200), i), pts=i)
        to_end = ring - (p.w % ring)
        if to_end < 64:
            p.write_pad()
            to_end = ring
        p.write_record(T["PAD"], 0, bytes(to_end - 48), 0)      # 32 bytes short
        p.write_au(_au(rng, 30, 8))
        p.op(OP_WAIT_STATE, S["ERROR"])
        p.op(OP_DELAY, 4000)
        c = session_consume()
        assert c.err == E["HDR_WRAP"]
        sections.append((c.items, False))
        final = [f for f in _std_final(c, nonce, S["ERROR"]) if f[0] != "read_index"]
    elif name in ("R5", "R6", "R7", "R8", "R9", "R10", "R11"):
        for i in range(5):
            p.write_au(_au(rng, rng.randrange(1, 300), i), pts=100 * i)
        bad = {
            "R5": dict(w1=lambda w: w ^ (1 << 50)),                       # sync
            "R6": dict(w0=lambda w: w & ~0xFF),                           # type 0 (a zero header)
            "R7": dict(w0=lambda w: w | (0x20 << 8)),                     # an undefined flag
            "R8": dict(w0=lambda w: (w & M32) | ((L.MAX_PAYLOAD + 1) << 32)),  # length
            "R9": dict(w0=lambda w: w ^ (7 << 16)),                       # seq (a stale lap's header)
            "R10": dict(w0=lambda w: (w & ~0xFF) | T["CONTROL"]),         # CONTROL
            "R11": dict(no_pad=True),                                     # crossing the ring's end
        }[name]
        if name == "R11":
            to_end = ring - (p.w % ring)
            p.write_au(_au(rng, max(1, to_end - 32), 9))                  # leave 16 bytes: then cross
            p.write_record(T["VIDEO_AU"], 0, _au(rng, 40, 7), 0, corrupt=bad)
        else:
            p.write_record(T["VIDEO_AU"], 0, _au(rng, 50, 7), 0, corrupt=bad)
        p.write_au(_au(rng, 30, 8))
        p.op(OP_WAIT_STATE, S["ERROR"])
        p.op(OP_DELAY, 4000)
        c = session_consume()
        assert c.err, name
        sections.append((c.items, False))
        final = _std_final(c, nonce, S["ERROR"])
        final = [f for f in final if f[0] != "read_index"]
    elif name == "R4":        # the write index misaligned / out of range (engine errors)
        for i in range(4):
            p.write_au(_au(rng, 64, i), pts=10 * i)
        p.wait_consumed()
        c = session_consume()
        bad_w = (p.w + 8) & M32
        p.op(OP_WIDX, bad_w)
        p.op(OP_WAIT_STATE, S["ERROR"])
        sections.append((c.items, False))
        final = [("state", S["ERROR"]), ("err", E["WIDX_ALIGN"]), ("err_pos", bad_w), ("n_au", 4)]
    elif name == "R13":       # a nonce change mid-stream: the old session may stop anywhere
        for i in range(20):
            p.write_au(_au(rng, rng.randrange(100, 900), i), pts=i)
        c1 = consume(p.stream, s_start, p.w, ring)
        s2 = p.w
        nonce2 = (nonce + 77) & M32 or 1
        p.start_session(nonce2)
        for i in range(8):
            p.write_au(_au(rng, rng.randrange(1, 400), 50 + i), pts=500 + i)
        p.wait_consumed()
        c2 = consume(p.stream, s2, p.w, ring)
        sections.append((c1.items, "cut"))      # the bench runs it with the decoder mostly stalled
        sections.append((c2.items, False))
        final = [("state", S["PLAYING"]), ("err", 0), ("ack_nonce", nonce2), ("read_index", c2.read),
                 ("n_streams", 2)]
    elif name in ("R15", "R24"):
        # 0.5: AUDIO records queued, their payloads fetched from the ring by the audio path
        # (the bench's consumer), the read index held behind the oldest unplayed one. R24
        # writes mostly audio against a slow consumer, so the producer waits on the hold.
        n_rec = {"R15": 24, "R24": 60}[name]
        for i in range(n_rec):
            if (name == "R15" and i % 3 == 1) or (name == "R24" and i % 5):
                n = 4 * rng.choice([1, 2, 3, 4, 31, 32, 33, rng.randrange(1, ring // 12)])
                p.write_audio(_au(rng, n, 0xA0 + i), pts=None if i % 4 == 3 else 90 * i)
            else:
                p.write_au(_au(rng, rng.randrange(1, 300), i), pts=90 * i)
        p.wait_consumed()
        c = session_consume()
        sections.append((c.items, False))
        final = _std_final(c, nonce, S["PLAYING"]) + [("aud_hold_bytes", 0)]
    elif name == "R23":       # 0.5: an AUDIO record whose length is not whole frames
        for i in range(3):
            p.write_au(_au(rng, rng.randrange(1, 200), i), pts=i)
        p.write_audio(_au(rng, 16, 0xA0), pts=5)
        p.write_record(T["AUDIO"], 0, _au(rng, 18, 0xA1), 0)            # 18: not a multiple of 4
        p.write_au(_au(rng, 30, 8))
        p.op(OP_WAIT_STATE, S["ERROR"])
        p.op(OP_DELAY, 4000)
        c = session_consume()
        assert c.err == E["HDR_LENGTH"]
        sections.append((c.items, False))
        final = [f for f in _std_final(c, nonce, S["ERROR"]) if f[0] != "read_index"]
    elif name == "R26":       # 0.5: after END_OF_STREAM the reset waits for the queued audio too
        for i in range(3):
            p.write_au(_au(rng, rng.randrange(1, 200), i), pts=i)
        for i in range(3):
            p.write_audio(_au(rng, 4 * rng.randrange(40, 200), 0xB0 + i), pts=1000 + 90 * i)
        p.write_au(_au(rng, 60, 5), pts=5, flags=F["END_OF_STREAM"])
        p.write_au(_au(rng, 60, 6), pts=6, flags=F["DISCONTINUITY"])
        for i in range(3):
            p.write_au(_au(rng, rng.randrange(1, 200), 7 + i), pts=7 + i)
        p.wait_consumed()
        c = session_consume()
        sections.append((c.items, False))
        final = _std_final(c, nonce, S["PLAYING"])
    elif name == "R25":       # 0.5: the pause word -- the ring not consumed; a refused word; resume
        W34 = L.const("W_PAUSE")
        for i in range(4):
            p.write_au(_au(rng, rng.randrange(1, 200), i), pts=i)
        p.wait_consumed()
        p.poke_ctrl(W34, 1 | (40 << L.const("CTL_ATTEN_LSB")))        # PAUSE, -20 dB
        p.wait_field("paused", 1)
        for i in range(4, 12):
            p.write_au(_au(rng, rng.randrange(1, 200), i), pts=i, flow=False)
        p.op(OP_STILL, 20000)                                      # nothing consumed while paused
        p.poke_ctrl(W34, 1 | (7 << 20))                             # a reserved bit: refused whole
        p.wait_field("ctl_err", 1)
        p.op(OP_STILL, 8000)                                       # still paused (the old word kept)
        p.poke_ctrl(W34, 3 << L.const("CTL_ATTEN_LSB"))                # resume, -1.5 dB
        p.wait_field("paused", 0)
        p.wait_consumed()
        c = session_consume()
        sections.append((c.items, False))
        final = _std_final(c, nonce, S["PLAYING"]) + [("paused", 0), ("ctl_err", 0), ("atten", 3)]
    elif name == "R16":       # DISCONTINUITY, EOS, NEED_DISCONT
        for i in range(5):
            p.write_au(_au(rng, rng.randrange(1, 200), i), pts=i)
        p.write_au(_au(rng, 60, 5), pts=5, flags=F["DISCONTINUITY"])
        p.write_au(_au(rng, 60, 6), pts=6, flags=F["END_OF_STREAM"])
        p.write_au(_au(rng, 60, 7), pts=7, flags=F["DISCONTINUITY"])
        p.write_au(_au(rng, 60, 8), pts=8, flags=F["END_OF_STREAM"])
        p.write_au(_au(rng, 60, 9), pts=9)                  # no DISCONTINUITY after EOS
        p.op(OP_WAIT_STATE, S["ERROR"])
        c = session_consume()
        assert c.err == E["NEED_DISCONT"]
        sections.append((c.items, False))
        final = _std_final(c, nonce, S["ERROR"])
        final = [f for f in final if f[0] != "read_index"]
    elif name == "R19":       # an OSD reset mid-stream: the session drops; a new one works
        for i in range(30):
            p.write_au(_au(rng, rng.randrange(200, 1500), i), pts=i)
        c1 = consume(p.stream, s_start, p.w, ring)
        p.op(OP_DELAY, 1500)
        p.op(OP_OSD_RESET)
        p.op(OP_WAIT_STATE, S["NO_SESSION"])
        p.op(OP_WAIT_ACK, 0)                    # the drop clears the published ack
        s2 = p.w
        nonce2 = (nonce ^ 0x5A5A5A5A) or 1
        p.start_session(nonce2)
        for i in range(5):
            p.write_au(_au(rng, rng.randrange(1, 400), 60 + i), pts=600 + i)
        p.wait_consumed()
        c2 = consume(p.stream, s2, p.w, ring)
        sections.append((c1.items, "cut"))
        sections.append((c2.items, False))
        final = [("state", S["PLAYING"]), ("err", 0), ("ack_nonce", nonce2), ("read_index", c2.read),
                 ("n_streams", 1)]
    else:
        raise KeyError(name)
    return p, sections, final


def _good_pic(rng, store):
    """0.15: a valid descriptor with its fields spread: frames and pairs, pic_struct, crops, the
    aspect, the timing -- every value one the core must pass through unchanged"""
    st = rng.choice([0, 0, 1, 2])
    w = rng.choice([1, 2, 20, 45, 80, 128])
    hf_max = min(128, L.CAP_MAX_MBS // w)
    hf = rng.randrange(1, hf_max + 1)
    if st and hf % 2:
        hf = hf - 1 if hf > 1 else 2
    idc = rng.choice([0, 1, 2, 16, 255])
    sarw, sarh = (rng.randrange(1, 1 << 16), rng.randrange(1, 1 << 16)) if idc == 255 else \
        rng.choice([(0, 0), (rng.randrange(0, 1 << 16), rng.randrange(0, 1 << 16))])
    psv = rng.choice([0, 1]) if st == 0 else 0
    ps = rng.choice([0, 3, 4, 5, 6, 7, 8]) if psv else rng.randrange(0, 16)
    tv = rng.choice([0, 1, 1])
    nuit, ts = (rng.choice([1001, 1, 1000, 7]), rng.choice([60000, 50, 48000, 0x8000_0001])) if tv else \
        (rng.randrange(0, 1 << 32), rng.randrange(0, 1 << 32))
    cl = rng.randrange(0, min(1024, 4 * w))
    cr = rng.randrange(0, min(1024, 8 * w - cl))
    ct = rng.randrange(0, min(1024, 4 * hf))
    cb = rng.randrange(0, min(1024, 8 * hf - ct))
    return pic_desc(store=store, w=w, hf=hf, st=st, ps=ps, psv=psv, idc=idc, sarw=sarw, sarh=sarh, tv=tv,
                    nuit=nuit, ts=ts, cl=cl, cr=cr, ct=ct, cb=cb)


def _pictures(name, p, rng, nonce, ring):
    """0.15 (docs/architecture.md "Pictures from the program"): PICTURE records. The bench's stand-in
    display takes each record recon_out presents, checks it against pics.hex and releases the store
    it took before (it holds one, as the display shows one): a PICTURE naming the store it holds is
    PIC_BUSY. The scenarios reuse a store only after three others (or at once, on purpose)."""
    sections, pics = [], []
    c = Consumed()

    def session(nc):
        s0 = p.w
        p.start_session(nc)
        return s0

    def take(s0):                      # this session's records, consumed (the counters carry on)
        c.err = 0
        consume(p.stream, s0, p.w, ring, cons=c)
        return c

    if name == "R28":                  # a picture stream: every field through, audio beside it, EOS
        s0 = session(nonce)
        n = 26
        for i in range(n):
            if i % 7 == 3:
                p.write_audio(_au(rng, 4 * rng.randrange(1, 60), 0xC0 + i), pts=3000 * i)
            p.write_picture(_good_pic(rng, i % L.DPB_STORES), pts=None if i % 5 == 4 else 3003 * i,
                            flags=F["END_OF_STREAM"] if i == n - 1 else 0)
        p.op(OP_WAIT_STATE, S["ENDED"])
        p.wait_consumed()                  # the audio released too (the read index held behind it)
        take(s0)
        sections.append((list(c.items), False))
        final = _std_final(c, nonce, S["ENDED"])
    elif name == "R29":                # every error, one session each; the counters carry on
        cases = [
            ("PIC_FIELD", dict(rsv=(1 << 5, 0, 0, 0))), ("PIC_FIELD", dict(rsv=(1 << 63, 0, 0, 0))),
            ("PIC_FIELD", dict(rsv=(0, 1 << 40, 0, 0))), ("PIC_FIELD", dict(rsv=(0, 0, 0, 1 << 50))),
            ("PIC_FIELD", dict(st=3, hf=30)), ("PIC_FIELD", dict(st=1, psv=1, ps=0)),
            ("PIC_FIELD", dict(psv=1, ps=1)), ("PIC_FIELD", dict(psv=1, ps=9)),
            ("PIC_FIELD", dict(idc=17)), ("PIC_FIELD", dict(idc=254)), ("PIC_FIELD", dict(idc=255, sarw=4, sarh=0)),
            ("PIC_FIELD", dict(tv=1, nuit=0)), ("PIC_FIELD", dict(tv=1, ts=0)),
            ("PIC_STORE", dict(store=20)), ("PIC_STORE", dict(store=31)),
            ("PIC_SIZE", dict(w=0)), ("PIC_SIZE", dict(hf=0)), ("PIC_SIZE", dict(w=129, hf=2)),
            ("PIC_SIZE", dict(w=2, hf=129)), ("PIC_SIZE", dict(st=2, hf=29)), ("PIC_SIZE", dict(w=80, hf=46)),
            ("PIC_SIZE", dict(w=255, hf=255)),
            ("PIC_CROP", dict(w=10, cl=40, cr=40)), ("PIC_CROP", dict(hf=10, ct=79, cb=1)),
            ("PIC_BUSY", None), ("HDR_LENGTH", 31), ("HDR_LENGTH", 33), ("NEED_DISCONT", None),
            ("STREAM_KIND", "pic_after_au"), ("STREAM_KIND", "au_after_pic"),
        ]
        for k, (err, arg) in enumerate(cases):
            nc = (nonce + 101 * (k + 1)) & M32 or 1
            s0 = session(nc)
            if err == "STREAM_KIND" and arg == "pic_after_au":
                p.write_au(_au(rng, 40, 1), pts=1)
                p.write_picture(pic_desc(store=2), pts=2)
            else:
                p.write_picture(_good_pic(rng, 0), pts=10)
                p.write_picture(_good_pic(rng, 1), pts=20)
                if err == "PIC_BUSY":
                    p.write_picture(pic_desc(store=1), pts=30)
                elif err == "HDR_LENGTH":
                    p.write_record(T["PICTURE"], 0, pic_payload(pic_desc(store=2))[:arg] + bytes(max(0, arg - 32)), 0)
                elif err == "NEED_DISCONT":
                    p.write_picture(pic_desc(store=2), pts=30, flags=F["END_OF_STREAM"])
                    p.write_picture(pic_desc(store=3), pts=40)
                elif err == "STREAM_KIND":
                    p.write_au(_au(rng, 40, 3), pts=30)
                else:
                    d = pic_desc(store=2)
                    d.update(arg)
                    p.write_picture(d, pts=30)
            p.write_picture(pic_desc(store=4), pts=50)       # never reached
            p.wait_field("err", E[err])
            take(s0)
            assert c.err == E[err], (k, err, c.err)
            sections.append((list(c.items), False))
            c.items = []
        final = _std_final(c, nc, S["ERROR"])
        final = [f for f in final if f[0] != "read_index"]
    elif name == "R30":                # the kinds: coded -> pictures -> pictures -> coded, legally
        s0 = session(nonce)
        for i in range(3):
            p.write_au(_au(rng, rng.randrange(1, 200), i), pts=i)
        for i in range(4):             # DISCONTINUITY without END_OF_STREAM: a reset in order
            p.write_picture(_good_pic(rng, 7 + i), pts=100 + i,
                            flags=(F["DISCONTINUITY"] if i == 0 else 0) | (F["END_OF_STREAM"] if i == 3 else 0))
        for i in range(3):             # after END_OF_STREAM: the reset waits for the END (and the holds clear)
            p.write_picture(_good_pic(rng, 10 + i), pts=200 + i,
                            flags=(F["DISCONTINUITY"] if i == 0 else 0) | (F["END_OF_STREAM"] if i == 2 else 0))
        for i in range(3):
            p.write_au(_au(rng, rng.randrange(1, 200), 20 + i), pts=300 + i,
                       flags=F["DISCONTINUITY"] if i == 0 else 0)
        p.wait_consumed()
        take(s0)
        sections.append((list(c.items), False))
        final = _std_final(c, nonce, S["PLAYING"])
    elif name == "R32":                # a flush while a hand-over is in flight (the bench stretches pd_ack)
        s0 = session(nonce)
        p.write_picture(_good_pic(rng, 0), pts=10)
        p.write_picture(_good_pic(rng, 1), pts=20)          # fetched, not reached: the flush drops it
        p.op(OP_DELAY, 1500)                                # picture 0's hand-over is in flight
        n2 = (nonce ^ 0x3C3C3C3C) or 1
        s1 = p.w
        p.start_session(n2)
        # the model: session 1 delivers exactly picture 0 (taken before the clear, finished after it)
        c1 = Consumed()
        consume(p.stream, s0, (s0 + 16 + 32) & M32, ring, cons=c1)
        c.items, c.pics, c.pic_emitted, c.n_streams = list(c1.items), list(c1.pics), 1, 1
        for i in range(3):
            p.write_picture(_good_pic(rng, i), pts=100 + i)  # store 0 again: free after the reset
        p.wait_consumed()
        c.items = []
        take(s1)
        sections.append((list(c1.items), False))
        sections.append((list(c.items), False))
        final = _std_final(c, n2, S["PLAYING"])
    elif name == "R33":                # LOW_LATENCY and GRAPHICS from the stream's first PICTURE
        s0 = session(nonce)
        for i in range(6):
            f = (F["LOW_LATENCY"] | F["GRAPHICS"]) if i in (0, 1, 2) else (F["GRAPHICS"] if i == 4 else 0)
            p.write_picture(_good_pic(rng, i), pts=i, flags=f)
        p.wait_consumed()
        take(s0)
        sections.append((list(c.items), False))
        final = _std_final(c, nonce, S["PLAYING"]) + [((4, 16, 1), 1), ((4, 23, 1), 1)]
    elif name == "R34":                # 0.16: a coded stream's colour -- its first VIDEO_AU's, disagreements counted
        s0 = session(nonce)
        for i, col in enumerate([3, 3, 4, 3, 0, 3, 3]):          # two disagree
            p.write_au(_au(rng, rng.randrange(1, 300), i), pts=i, colour=col)
        for i, col in enumerate([6, 6, 1, 6]):                   # a new stream: its own first, one disagrees
            p.write_au(_au(rng, rng.randrange(1, 300), 10 + i), pts=10 + i, colour=col,
                       flags=F["DISCONTINUITY"] if i == 0 else 0)
        p.wait_consumed()
        take(s0)
        assert c.colour == 6 and c.colour_mismatch == 1, (c.colour, c.colour_mismatch)
        sections.append((list(c.items), False))
        # word 80's colour and word 86's display fields are the bench's constants: each lands where the layout says
        final = _std_final(c, nonce, S["PLAYING"]) + [
            ("colour", 5), ("vui_matrix", 0xD1), ("vui_primaries", 0xD2), ("vui_transfer", 0xD3),
            ("vui_full_range", 1), ("vui_colour_present", 0), ("colour_unsup", 0xD004)]
    elif name == "R35":                # 0.16: a PICTURE's colour -- its own, else the size rule on the shown size
        s0 = session(nonce)
        cases = [(0, dict(w=45, hf=30)),                          # 720x480: BT.601
                 (0, dict(w=80, hf=45)),                          # 1280x720: BT.709
                 (0, dict(w=80, hf=2, cr=1)),                     # 1280 wide cropped by a pair: 1278, BT.601
                 (0, dict(w=80, hf=2)),                           # exactly 1,280 wide: BT.709
                 (0, dict(w=2, hf=37)),                           # 592 high: BT.709
                 (0, dict(w=2, hf=36)),                           # exactly 576 high: BT.601
                 (0, dict(w=2, hf=37, cb=8)),                     # 592 cropped to 576: BT.601
                 (2, dict(w=80, hf=45)), (4, dict()), (5, dict()), (6, dict(w=80, hf=45)),
                 (1, dict(w=80, hf=45)), (3, dict())]
        for i, (col, kw) in enumerate(cases):
            p.write_picture(pic_desc(store=i % L.DPB_STORES, **kw), pts=i, colour=col)
        p.wait_consumed()
        take(s0)
        assert [x[1]["colour"] for x in c.pics] == [1, 3, 1, 3, 3, 1, 1, 2, 4, 5, 6, 1, 3], [x[1]["colour"] for x in c.pics]
        sections.append((list(c.items), False))
        final = _std_final(c, nonce, S["PLAYING"])
    elif name == "R36":                # 0.16: the colour's errors, one session each; the counters carry on
        cases = [("HDR_COLOUR", "au7"), ("HDR_COLOUR", "pic7"), ("HDR_COLOUR", "audio"), ("HDR_SYNC", "bit36"),
                 ("HDR_SYNC", "bit47")]
        for k, (err, how) in enumerate(cases):
            nc = (nonce + 77 * (k + 1)) & M32 or 1
            s0 = session(nc)
            if how == "pic7":
                p.write_picture(pic_desc(store=0), pts=1, colour=3)
                p.write_picture(pic_desc(store=1), pts=2, colour=7)
                p.write_picture(pic_desc(store=2), pts=3)            # never reached
            else:
                p.write_au(_au(rng, 40, 1), pts=1, colour=3)
                if how == "au7":
                    p.write_au(_au(rng, 40, 2), pts=2, colour=7)
                elif how == "audio":
                    p.write_audio(_au(rng, 64, 0xC0), pts=2, colour=1)
                else:
                    bit = 36 if how == "bit36" else 47
                    p.write_au(_au(rng, 40, 2), pts=2, corrupt={"w1": lambda w, b=bit: w | (1 << b)})
                p.write_au(_au(rng, 40, 3), pts=3)                   # never reached
            p.wait_field("err", E[err])
            take(s0)
            assert c.err == E[err], (k, err, c.err)
            sections.append((list(c.items), False))
            c.items = []
        final = _std_final(c, nc, S["ERROR"])
        final = [f for f in final if f[0] != "read_index"]
    else:
        raise KeyError(name)
    p._pics = list(c.pics)             # (R32: session 1's picture, then session 2's)
    return p, sections, final


def _rumble(p, rng, start, nonce, ring):
    """0.13 (docs/architecture.md "Rumble (interface 0.13)"): words 36-38, two pads a u32 in the low
    half ([15:0] pad 2k, [31:16] pad 2k + 1), the high half ignored; read with every poll; passed to
    Main (status words 82-83) only while a session is open, 0 otherwise; rum_changes counts each
    change of what is passed (any pad)."""
    W = L.const("W_RUMBLE")

    def rum(vals, junk):
        for k in range(3):        # the high halves hold junk: they must be ignored
            p.poke_ctrl(W + k, ((junk + k) << 32) | (vals[2 * k + 1] << 16) | vals[2 * k])

    v1 = [0x1111 * (n + 1) for n in range(6)]
    v2 = [0x8040, 0xFF00, 0x00FF, 0x0102, 0x7F7F, 0xFFFF]
    v3 = [0x2030, 0x0000] + v2[2:]            # pads 0-1 change: one word, one change
    changes = 0
    rum(v1, 0xDEAD0000)                       # before any session: never passed on
    p.op(OP_DELAY, 8000)                      # several polls (the slow poll is 3,000 clk_mem cycles)
    rum(v2, 0xBEEF0000)
    s1 = p.w
    p.start_session(nonce)                    # 0 -> v2
    changes += 1
    p.wait_field("rum_p5", v2[5])
    for i in range(3):
        p.write_au(_au(rng, rng.randrange(1, 200), i), pts=i)
    p.wait_consumed()
    c1 = consume(p.stream, s1, p.w, ring)
    rum(v3, 0xC0DE0000)                       # v2 -> v3
    changes += 1
    p.wait_field("rum_p0", v3[0])
    rum(v3, 0xF00D0000)                       # the same values, other junk: no change
    p.op(OP_DELAY, 8000)
    p.op(OP_OSD_RESET)                        # the session drops: v3 -> 0
    changes += 1
    p.op(OP_WAIT_STATE, S["NO_SESSION"])
    p.wait_field("rum_p2", 0)
    p.op(OP_DELAY, 8000)                      # still 0 without a session
    s2 = p.w
    nonce2 = (nonce ^ 0x0F0F0F0F) or 1
    p.start_session(nonce2)                   # 0 -> v3: the words were never cleared
    changes += 1
    p.wait_field("rum_p3", v3[3])
    for i in range(3):
        p.write_au(_au(rng, rng.randrange(1, 200), 10 + i), pts=10 + i)
    p.wait_consumed()
    c2 = consume(p.stream, s2, p.w, ring)
    sections = [(c1.items, False), (c2.items, False)]
    final = [("state", S["PLAYING"]), ("err", 0), ("ack_nonce", nonce2), ("read_index", c2.read),
             ("n_streams", 1)] + [("rum_p%d" % n, v3[n]) for n in range(6)] + [("rum_changes", changes)]
    return p, sections, final


SCENARIOS = ["R1", "R2", "R3", "R4", "R5", "R6", "R7", "R8", "R9", "R10", "R11", "R12", "R13",
             "R14", "R15", "R16", "R17", "R18", "R19", "R20", "R21", "R22", "R23", "R24", "R25", "R26", "R27",
             "R28", "R29", "R30", "R32", "R33", "R34", "R35", "R36"]


def main(argv):
    import argparse
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--scenario")
    ap.add_argument("--out")
    ap.add_argument("--ring-words", type=int, default=512)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args(argv)
    if a.list:
        print(" ".join(SCENARIOS))
        return 0
    p, sections, final = scenario(a.scenario, a.ring_words, a.seed)
    payloads = []
    for items, _ in sections:        # the audio payloads, in the order their descriptors were queued
        payloads += [bytes(p.stream[(it[1] + 16 + k) & M32] for k in range(it[2])) for it in items if it[0] == "audio"]
    for ext, lines in (("steps", p.steps_hex()), ("expect", expect_hex(sections)), ("final", final_hex(final)),
                       ("audio", audio_hex(payloads)), ("pics", pics_hex(getattr(p, "_pics", [])))):
        with open("%s.%s.hex" % (a.out, ext), "w") as f:
            f.write("\n".join(lines) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
