#!/usr/bin/env python3
"""The HPS interface's layout and its model (tools/ring_layout.py, tools/ring_model.py):
the generated files match the tables, the published offsets are pinned (a moved field is
an interface change: it must fail here and be decided, not slip through), and the
reference consumer delivers what the producer wrote and stops on each fault with the
code the scenario was written for.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.dirname(HERE)
sys.path.insert(0, TOOLS)
sys.path.insert(0, HERE)
import ring_layout as L  # noqa: E402
import ring_model as M   # noqa: E402
from score import Score  # noqa: E402

s = Score("test_ring_model")

# ---- the generated files and the pinned layout
r = subprocess.run([sys.executable, os.path.join(TOOLS, "ring_layout.py"), "--check"],
                   capture_output=True, text=True)
s.check("generated files match the tables", r.returncode, 0)
s.check("magic", L.MAGIC.to_bytes(8, "little"), b"MiSTH264")
s.check("region", (L.CTRL_BYTE, L.RING_BYTE, L.RING_SIZE), (0x31400000, 0x31800000, 0x800000))
s.check("program words", (L.PROG_WORD, L.const("W_WRITE_INDEX"), L.const("W_NONCE")), (32, 32, 33))
for name, want in [("seq_head", (3, 0, 32)), ("state", (4, 0, 8)), ("err", (4, 8, 8)), ("live", (4, 16, 8)),
                   ("err_pos", (4, 32, 32)), ("read_index", (5, 0, 32)), ("ack_nonce", (5, 32, 32)),
                   ("stc", (7, 0, 33)), ("seq_tail", (31, 0, 32)),
                   # 0.5: the core's second region and the pause word
                   ("core2_word", (1, 48, 16)), ("aud_state", (40, 0, 2)), ("aud_q_samples", (40, 32, 32)),
                   ("aud_played", (41, 0, 32)), ("aud_offset", (44, 0, 32)), ("paused", (45, 0, 1)),
                   ("ctl_err", (45, 1, 1)), ("atten", (45, 8, 8))]:
    s.check("field " + name, L.field(name), want)
# 0.6: the input region (published: a moved field must fail here and be decided)
for name, want in [("in_head", (48, 0, 32)), ("ev_count", (48, 32, 32)), ("pad0_joy", (49, 0, 32)),
                   ("pad0_lstick", (49, 32, 16)), ("pad0_rstick", (49, 48, 16)), ("pad5_joy", (54, 0, 32)),
                   ("dx_sum", (55, 0, 32)), ("dy_sum", (55, 32, 32)), ("ev_q0", (56, 0, 16)), ("ev_q31", (63, 48, 16)),
                   ("wheel_sum", (64, 0, 32)), ("mouse_btn", (64, 32, 8)), ("osd_open", (64, 40, 1)),
                   ("ev_lost", (64, 48, 16)), ("in_tail", (71, 0, 32))]:
    s.check("field " + name, L.field(name), want)
s.check("field disp_lone (0.7)", L.field("disp_lone"), (27, 27, 4))
# 0.9: the overlay plane (the descriptor the program writes, the status the core writes)
s.check("0.9: the descriptor's words",
        [L.const(n) for n in ("W_OVL_GEN_LO", "W_OVL_CTL", "W_OVL_BASE", "W_OVL_SIZE", "W_OVL_STRIDE",
                              "W_OVL_BAND", "W_OVL_RSVD", "W_OVL_GEN_HI")], list(range(72, 80)))
s.check("0.9: the framebuffer's region", (L.FB_BYTE, L.FB_SIZE), (0x22000000, 0x800000))
s.check("0.9: the formats", [(n, v, b) for n, v, b in L.OVL_FORMATS], [("1555", 0, 2), ("4444", 1, 2), ("8888", 2, 4)])
s.check("0.9: the error codes", [(n, v) for n, v, _ in L.OVL_ERRORS],
        [("NONE", 0), ("CTL", 1), ("SIZE", 2), ("STRIDE", 3), ("ALIGN", 4), ("BAND", 5), ("RANGE", 6)])
for name, want in [("ovl_gen", (46, 0, 32)), ("ovl_state", (46, 32, 2)), ("ovl_at", (46, 34, 1)),
                   ("ovl_clip", (46, 35, 1)), ("ovl_err", (46, 36, 4)), ("ovl_torn", (46, 40, 8)),
                   ("ovl_late", (46, 48, 16)), ("ar_x", (47, 0, 12)), ("ar_y", (47, 12, 12)),
                   ("ovl_lines", (47, 32, 32))]:
    s.check("field " + name, L.field(name), want)
s.check("0.6: the region and its queue", (L.IN_WORD, L.IN_WORDS, L.IN_Q_WORD, L.IN_Q_LEN), (48, 24, 56, 32))
s.check("0.6 / 0.8: the event types", [(n, v) for n, v, _ in L.EVENTS], [("KEY", 0), ("MOUSE_BTN", 1), ("OSD", 2), ("ACTION", 3)])
s.check("0.8: the OSD's actions", L.const("IN_ACTIONS"), 2)
s.check("CPB fits (Level 3.1 High NAL MaxCPB 14000 x 1500 bits)", L.RING_SIZE * 8 >= 14000 * 1500, True)
s.check("0.5: the pause word and the second region", (L.const("W_PAUSE"), L.CORE2_WORD, L.CORE2_WORDS), (34, 40, 8))
s.check("1.2: rumble layout and eight-word poll including geometry",
        (L.const("W_RUMBLE"), L.const("RUMBLE_PADS"), L.const("RUMBLE_LARGE_LSB"), L.const("POLL_WORDS")), (36, 6, 8, 8))
s.check("0.13: the rumble applied (words 82-83)",
        (L.field("rum_p0"), L.field("rum_p3"), L.field("rum_p4"), L.field("rum_p5"), L.field("rum_changes")),
        ((82, 0, 16), (82, 48, 16), (83, 0, 16), (83, 16, 16), (83, 32, 32)))
s.check("0.5: seq_head first, words 40-47 before seq_tail, seq_tail last",
        (L.WRITE_ORDER[3], L.WRITE_ORDER.index(40) < L.WRITE_ORDER.index(31), L.WRITE_ORDER[-1]), (3, True, 31))

# ---- the consumer delivers exactly what was written
p = M.Producer(ring=4096)
p.set_widx((1 << 32) - 2048)            # the u32 wrap inside the run
start = p.w
p.start_session(7)
payloads = [bytes([i % 251 + 1] * n) for i, n in enumerate([1, 15, 16, 17, 1000, 2000, 3000, 5, 4000 - 16])]
for i, pl in enumerate(payloads):
    p.write_au(pl, pts=i * 1500 if i % 2 else None)
c = M.consume(p.stream, start, p.w, 4096)
got = bytes(it[1] for it in c.items if it[0] == "byte")
s.check("bytes round trip", got, b"".join(payloads))
s.check("no error", c.err, 0)
s.check("AUs", c.n_au, len(payloads))
s.check("PADs at the ring's end", c.n_pad > 0, True)
s.check("marks only on PTS_VALID first bytes",
        [it[3] for it in c.items if it[0] == "byte" and it[2]], [i * 1500 for i in range(len(payloads)) if i % 2])
s.check("au_end once per AU", sum(it[4] for it in c.items if it[0] == "byte"), len(payloads))
s.check("the read index reaches the write index", c.read, p.w)

# ---- each scenario ends where it was written to end
want_err = {"R3": "WIDX_RANGE", "R4": "WIDX_ALIGN", "R5": "HDR_SYNC", "R6": "HDR_TYPE", "R7": "HDR_FLAGS",
            "R8": "HDR_LENGTH", "R9": "HDR_SEQ", "R10": "CONTROL_UNSUPPORTED", "R11": "HDR_WRAP",
            "R16": "NEED_DISCONT", "R20": "HDR_WRAP", "R23": "HDR_LENGTH",
            "R29": "STREAM_KIND",       # 0.15: R29 a session per error, its last STREAM_KIND
            "R36": "HDR_SYNC"}          # 0.16: R36 a session per error, its last HDR_SYNC (bit 47)
for name in M.SCENARIOS:
    p, sections, final = M.scenario(name)
    fin = dict((k if isinstance(k, str) else str(k), v) for k, v in final)
    err = fin.get("err", 0)
    s.check("%s ends with %s" % (name, want_err.get(name, "NONE")), err, M.E[want_err.get(name, "NONE")])
    n_bytes = sum(1 for sec, _ in sections for it in sec if it[0] == "byte")
    if name in ("R28", "R29", "R32", "R33", "R35"):   # 0.15: picture streams deliver pictures, no bytes
        n_pics = sum(1 for it in getattr(p, "_pics", []) if it[0] == "pic")
        s.check("%s delivers pictures (0.15)" % name, n_pics > 0, True)
    else:
        s.check("%s delivers bytes" % name, n_bytes > 0, name != "R12")
# 0.16: R34's stream colour and its disagreements; R35's codes, the size rule at its bounds
_f34 = dict((k if isinstance(k, str) else str(k), v) for k, v in M.scenario("R34")[2])
s.check("R34: the second stream's colour (6) from its first AU, one disagreement (0.16)",
        (_f34["colour_override"], _f34["colour_mismatch"]), (1, 1))
s.check("R35: every code resolved, the size rule at 1,280 / 576 and across a crop (0.16)",
        [it[1]["colour"] for it in M.scenario("R35")[0]._pics if it[0] == "pic"], [1, 3, 1, 3, 3, 1, 1, 2, 4, 5, 6, 1, 3])
# 0.15: R28's pictures carry frames and both pair orders; R29 reaches every PICTURE error
r28 = [it[1] for it in M.scenario("R28")[0]._pics if it[0] == "pic"]
s.check("R28: frames and pairs of both orders (0.15)", sorted(set(d["st"] for d in r28)), [0, 1, 2])
s.check("R28: ends with END_OF_STREAM's END record", M.scenario("R28")[0]._pics[-1], ("pend",))
s.check("R16 resets on each DISCONTINUITY", sum(1 for it in M.scenario("R16")[1][0][0] if it[0] == "reset"), 3)
s.check("R16 flushes on each EOS", sum(1 for it in M.scenario("R16")[1][0][0] if it[0] == "eos"), 2)
s.check("R17 counts the LOW_LATENCY disagreements", dict(M.scenario("R17")[2])["ll_mismatch"], 6)
# 0.5: AUDIO records are queued (descriptors) in ring order between the video bytes
for name in ("R15", "R24"):
    items = M.scenario(name)[1][0][0]
    auds = [it for it in items if it[0] == "audio"]
    s.check("%s queues its AUDIO records" % name, len(auds) > 5, True)
    s.check("%s: whole frames only" % name, all(it[2] % 4 == 0 and it[2] > 0 for it in auds), True)
    s.check("%s: some untagged" % name, any(it[3] == 0 for it in auds) and any(it[3] for it in auds), True)
p24 = M.Producer(ring=4096)
p24.set_widx(0); p24.start_session(3)
p24.write_audio(bytes(range(1, 13)), pts=1234)
c24 = M.consume(p24.stream, 0, p24.w, 4096)
s.check("an AUDIO record's descriptor", c24.items[1], ("audio", 0, 12, 1, 1234))
s.check("... and its payload", c24.audio, [bytes(range(1, 13))])
s.finish()
