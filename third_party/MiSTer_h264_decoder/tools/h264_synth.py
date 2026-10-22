#!/usr/bin/env python3
"""h264_synth.py -- rewrite an Annex-B stream's SPS with a synthetic VUI (roadmap P5b).

Encoders write the VUI fields they need, never the spec's maxima (x264: timing, a SAR,
at most one HRD structure with one CPB). This tool keeps an x264 stream's pictures and
replaces every SPS's VUI (E.1.1) with one built here, bit by bit from the syntax table,
so the front end's VUI states and the model's parse_vui() see what no encoder emits:

  max      every optional part present at its spec maximum: Extended_SAR 65535:65534,
           overscan, video signal + colour description (255s), chroma location 5 / 5,
           timing num_units_in_tick = time_scale = 2^32 - 1, NAL AND VCL hrd_parameters()
           each with cpb_cnt_minus1 31, scales 15, every bit_rate / cpb_size value
           2^32 - 2 (ue(v) with 31 leading zeros), every length 31, pic_struct_present,
           bitstream_restriction with denominators 16, mv lengths 15, 16 / 16 frames.
  err_cpb  cpb_cnt_minus1 32                                    (E.2.2: 0..31)
  err_mdfb max_dec_frame_buffering 17                           (A.3.1: at most 16)
  err_nrf  max_num_reorder_frames 5 above max_dec_frame_buffering 4 (E.2.1)
  err_tick num_units_in_tick 0                                  (E.2.1: greater than 0)
  err_len  the VCL structure's dpb_output_delay_length differs from the NAL one (E.2.2)
  dpbN     legal: max_num_reorder_frames = max_dec_frame_buffering = N (1..16) -- the
           reorder limit never binds before the DPB fills, so the VUI's DPB size alone
           decides when pictures leave (roadmap P3d: the early output would hide a wrong size)

Every variant writes a COMPLETE VUI: a parser without the check under test must parse
it to the end and store the SPS (a stream cut at the violation would fail anyway, by
reading past its end -- a mutation dropping the check would survive).

The fields BEFORE vui_parameters_present_flag are copied bit for bit (their position is
found by running the model's own SPS parser); emulation prevention is re-applied, so the
maximal VUI's 0x00 / 0xFF runs also put EPBs inside the VUI.

    h264_synth.py in.264 max out.264

P5c -- the picture timing SEI (D.1.3), on an x264 stream written with pic-struct=1 and a
NAL HRD (each access unit = one pic_timing SEI + one slice; the SPS's delay lengths are
read from the stream itself). Each mode rewrites the pic_timing payloads bit by bit from
the syntax table (the values are the stream's own unless the mode changes them):

  ps_all        pic_struct of access unit k from PS_SEQ: every Table D-1 value on a frame
                picture -- 0, 3..8 legal; 1 / 2 (field-only) and 9 / 15 (reserved)
                counted pt_struct
  sei_edge      every pic_timing SEI unit rebuilt as three messages: user data (type 5)
                of 300 bytes of zero runs (EPBs inside the payload), a payloadType >= 255
                (0xFF 0x06 = 261), then the pic_timing padded to 20 bytes (its tail after
                pic_struct is skipped): the same fields must come out
  sei_short     access unit 3's pic_timing payloadSize 1: pt_short
  sei_malformed access unit 4's SEI unit: a pic_timing whose payloadSize runs past the
                unit's end: sei_malformed, and no timing for that picture (pt_missing)
  sei_missing   access unit 5's SEI unit removed: pt_missing
  sps_after_sei from access unit 6 on, a new SPS (same id) with cpb_removal_delay /
                dpb_output_delay lengths +8 / +3 is inserted AFTER the SEI and before the
                slice, and the payloads are coded with the NEW lengths -- the SEI must be
                interpreted with the SPS the slice activates (D.2.3 NOTE 1)

P5d -- the output process (C.4.4), on an x264 stream with two IDRs; the SPS's VUI is
dropped first, so the DPB size is MaxDpbFrames (16 at this size) and pictures WAIT for
output until an IDR or an MMCO 5 empties the DPB:

  no_output     the second IDR's no_output_of_prior_pics_flag set (a 1-bit field,
                rewritten in place): the pictures waiting at it are dropped, not output
  (H264 Phase 5) --
  unlossless    an x264 LOSSLESS stream (qp 0: High 4:4:4 Predictive, every macroblock
                I_PCM) rewritten as plain High: profile_idc 244 -> 100 and
                qpprime_y_zero_transform_bypass_flag 1 -> 0 in every SPS (two fixed-width
                fields, rewritten in place). With every macroblock I_PCM no transform runs,
                so the pictures are unchanged -- the refs-free way to put emulation-
                prevention bytes inside DECODED data (the lossless stream itself is
                refused: the transform bypass is not built).
  mmco5         the reference picture before the second IDR gets MMCO 5 (its slice
                header re-encoded from the model's records with the operation added,
                the CABAC data re-appended byte-aligned): the waiting pictures must be
                output BEFORE its POC becomes relative to itself (8.2.1), or it jumps
                ahead of them. Nothing references across the IDR, so the pixels stay exact.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import h264_fe_ref as FE  # noqa: E402
import cabac_ref  # noqa: E402


class BitWriter(object):
    def __init__(self):
        self.bits = []

    def u(self, n, v):
        assert 0 <= v < (1 << n), (n, v)
        self.bits += [(v >> (n - 1 - i)) & 1 for i in range(n)]

    def ue(self, v):
        x = v + 1
        n = x.bit_length()
        self.bits += [0] * (n - 1)
        self.u(n, x)

    def trailing(self):
        self.bits.append(1)
        while len(self.bits) % 8:
            self.bits.append(0)

    def bytes(self):
        return bytes(int("".join(map(str, self.bits[i:i + 8])), 2) for i in range(0, len(self.bits), 8))


def vui(w, kind):
    """E.1.1 at its maxima, with the one violation `kind` names (if any)."""
    w.u(1, 1)                                   # aspect_ratio_info_present_flag
    w.u(8, 255)                                 #   Extended_SAR
    w.u(16, 65535)
    w.u(16, 65534)
    w.u(1, 1); w.u(1, 1)                        # overscan_info_present / appropriate
    w.u(1, 1); w.u(3, 7); w.u(1, 1)             # video_signal_type_present, format, full range
    w.u(1, 1); w.u(8, 255); w.u(8, 255); w.u(8, 255)   # colour description
    w.u(1, 1); w.ue(5); w.ue(5)                 # chroma location
    w.u(1, 1)                                   # timing_info_present_flag
    w.u(32, 0 if kind == "err_tick" else 0xFFFFFFFF)
    w.u(32, 0xFFFFFFFF)
    w.u(1, 1)                                   # fixed_frame_rate_flag
    for k in ("nal", "vcl"):
        w.u(1, 1)                               # *_hrd_parameters_present_flag
        cnt = 32 if kind == "err_cpb" else 31
        w.ue(cnt)
        w.u(4, 15); w.u(4, 15)
        for _ in range(cnt + 1):
            w.ue(0xFFFFFFFE); w.ue(0xFFFFFFFE); w.u(1, 1)
        w.u(5, 31); w.u(5, 31)
        w.u(5, 30 if (kind == "err_len" and k == "vcl") else 31)
        w.u(5, 31)
    w.u(1, 0)                                   # low_delay_hrd_flag (1 needs cpb_cnt_minus1 0)
    w.u(1, 1)                                   # pic_struct_present_flag
    w.u(1, 1)                                   # bitstream_restriction_flag
    w.u(1, 1); w.ue(16); w.ue(16); w.ue(15); w.ue(15)
    nrf, mdfb = {"err_mdfb": (16, 17), "err_nrf": (5, 4)}.get(kind, (16, 16))
    if kind.startswith("dpb"):
        nrf = mdfb = int(kind[3:])
    w.ue(nrf); w.ue(mdfb)


def vui_flag_bitpos(rbsp):
    """The bit position of vui_parameters_present_flag in an SPS RBSP (the model's parse)."""
    seen = {}

    class Rec(list):
        def append(self, r):
            if r.startswith("S vui_parameters_present_flag "):
                seen["pos"] = Probe.last.pos - 1
            list.append(self, r)

    class Probe(cabac_ref.BitReader):
        last = None

        def __init__(self, *a, **k):
            cabac_ref.BitReader.__init__(self, *a, **k)
            Probe.last = self
    orig = FE.BitReader
    FE.BitReader = Probe
    try:
        FE.parse_sps(rbsp, Rec())
    except FE.FeError:
        pass                                    # a VUI the model rejects: the position is known
    finally:
        FE.BitReader = orig
    return seen["pos"]


def lossless_flag_bitpos(rbsp):
    """The bit position of qpprime_y_zero_transform_bypass_flag in an SPS RBSP: the model
    refuses right after reading it, so the reader stands just past it."""
    class Probe(cabac_ref.BitReader):
        last = None

        def __init__(self, *a, **k):
            cabac_ref.BitReader.__init__(self, *a, **k)
            Probe.last = self
    orig = FE.BitReader
    FE.BitReader = Probe
    try:
        FE.parse_sps(rbsp, [])
        raise SystemExit("h264_synth: the SPS carries no transform bypass flag of 1")
    except FE.Refused as e:
        if "qpprime_y_zero_transform_bypass_flag" not in str(e):
            raise
        return Probe.last.pos - 1
    finally:
        FE.BitReader = orig


def unlossless(data):
    # the bytes before the first 00 00 01 (the SPS's zero_byte) and each rewritten unit's
    # trailing zeros (the next unit's zero_byte) are kept: B.1.2 requires the zero_byte
    # before an SPS / PPS / an access unit's first NAL unit, and a 3-byte start code at
    # byte 0 once lost run_cosim.sh's pcm window its parameter sets (ERR_NO_SPS)
    out = bytearray(data[:data.find(b"\x00\x00\x01")])
    n = 0
    for hdr, rbsp, raw in units(data):
        if hdr & 0x1F == 7:
            b = bytearray(rbsp)
            if b[0] != 244:
                raise SystemExit("h264_synth: profile_idc %d, not 244 (High 4:4:4 Predictive)" % b[0])
            pos = lossless_flag_bitpos(bytes(b))
            b[0] = 100
            b[pos // 8] &= ~(0x80 >> (pos % 8))
            tail = len(raw) - len(raw.rstrip(b"\x00"))
            out += b"\x00\x00\x01" + bytes([hdr]) + escape(bytes(b)) + b"\x00" * tail
            n += 1
        else:
            out += raw
    assert n, "no SPS in the stream"
    return bytes(out), n


def rbsp_bits(rbsp, n):
    return [(rbsp[i // 8] >> (7 - i % 8)) & 1 for i in range(n)]


def escape(rbsp):
    out = bytearray()
    zeros = 0
    for b in rbsp:
        if zeros >= 2 and b <= 3:
            out.append(3)
            zeros = 0
        out.append(b)
        zeros = zeros + 1 if b == 0 else 0
    return bytes(out)


def rewrite(data, kind):
    out = bytearray()
    starts = []
    i = data.find(b"\x00\x00\x01")
    while i >= 0:
        starts.append(i)
        i = data.find(b"\x00\x00\x01", i + 3)
    starts.append(len(data))
    out += data[:starts[0]]
    n_sps = 0
    for a, b in zip(starts, starts[1:]):
        unit = data[a:b]
        hdr = unit[3]
        if hdr & 0x1F == 7:
            body = unit[4:]
            tail = len(body) - len(body.rstrip(b"\x00"))
            nal = body[:len(body) - tail] if tail else body
            rbsp = next(FE.nal_units(b"\x00\x00\x01" + bytes([hdr]) + nal))[2]
            pos = vui_flag_bitpos(rbsp)
            w = BitWriter()
            w.bits = rbsp_bits(rbsp, pos)
            w.u(1, 1)                           # vui_parameters_present_flag
            vui(w, kind)
            w.trailing()
            unit = b"\x00\x00\x01" + bytes([hdr]) + escape(w.bytes()) + (b"\x00" * tail)
            n_sps += 1
        out += unit
    assert n_sps, "no SPS in the stream"
    return bytes(out), n_sps


# ---------------------------------------------------------------- P5c: picture timing SEIs

PS_SEQ = [0, 3, 4, 5, 6, 7, 8, 9, 15, 1, 2, 0]
NUM_CLOCK_TS = {0: 1, 1: 1, 2: 1, 3: 2, 4: 2, 5: 3, 6: 3, 7: 2, 8: 3}


def units(data):
    """[(header byte, rbsp, raw unit bytes incl. its start code)] in stream order."""
    out = []
    starts = []
    i = data.find(b"\x00\x00\x01")
    while i >= 0:
        starts.append(i)
        i = data.find(b"\x00\x00\x01", i + 3)
    starts.append(len(data))
    for a, b in zip(starts, starts[1:]):
        raw = data[a:b]
        body = raw[3:]
        stripped = body.rstrip(b"\x00")
        rbsp = next(FE.nal_units(b"\x00\x00\x01" + stripped))[2]
        out.append((raw[3], rbsp, raw))
    return out


def nal(hdr, rbsp):
    return b"\x00\x00\x01" + bytes([hdr]) + escape(rbsp)


def sei_messages(rbsp):
    """[(type, payload)] of an SEI RBSP (well-formed input)."""
    i, out = 0, []
    while i < len(rbsp) - 1:
        t = 0
        while rbsp[i] == 0xFF:
            t += 255
            i += 1
        t += rbsp[i]
        i += 1
        n = 0
        while rbsp[i] == 0xFF:
            n += 255
            i += 1
        n += rbsp[i]
        i += 1
        out.append((t, rbsp[i:i + n]))
        i += n
    return out


def sei_rbsp(msgs, cut_last_by=0):
    """An SEI RBSP from [(type, payload)]; with cut_last_by, the last message's
    payloadSize claims that many bytes more than it carries (malformed)."""
    out = bytearray()
    for k, (t, pl) in enumerate(msgs):
        for v in (t, len(pl) + (cut_last_by if k == len(msgs) - 1 else 0)):
            while v >= 255:
                out.append(0xFF)
                v -= 255
            out.append(v)
        out += pl
    out.append(0x80)
    return bytes(out)


def pt_payload(cpb, dpb, ps, lc, ld, pad_to=0):
    """pic_timing(): the delays, pic_struct, NumClockTS clock_timestamp_flags of 0
    (none for a reserved pic_struct), byte alignment (1 then 0s), padded to pad_to."""
    w = BitWriter()
    w.u(lc, cpb)
    w.u(ld, dpb)
    w.u(4, ps)
    for _ in range(NUM_CLOCK_TS.get(ps, 0)):
        w.u(1, 0)
    if len(w.bits) % 8:
        w.bits.append(1)
        while len(w.bits) % 8:
            w.bits.append(0)
    b = w.bytes()
    return b + bytes(range(0xA0, 0xA0 + max(0, pad_to - len(b))))


def sps_fields(rbsp):
    """{record name: (value, bit position after it)} of an SPS RBSP (the model's parse)."""
    got = {}

    class Rec(list):
        def append(self, r):
            _s, name, v = r.split(" ")
            got.setdefault(name, (int(v), Probe.last.pos))
            list.append(self, r)

    class Probe(cabac_ref.BitReader):
        last = None

        def __init__(self, *a, **k):
            cabac_ref.BitReader.__init__(self, *a, **k)
            Probe.last = self
    orig = FE.BitReader
    FE.BitReader = Probe
    try:
        FE.parse_sps(rbsp, Rec())
    finally:
        FE.BitReader = orig
    return got


def set_bits(rbsp, end_pos, n, v):
    """Overwrite the n-bit field that ENDS at bit end_pos."""
    bits = rbsp_bits(rbsp, len(rbsp) * 8)
    bits[end_pos - n:end_pos] = [(v >> (n - 1 - i)) & 1 for i in range(n)]
    return bytes(int("".join(map(str, bits[i:i + 8])), 2) for i in range(0, len(bits), 8))


def rewrite_sei(data, kind):
    us = units(data)
    sps = [u for u in us if u[0] & 0x1F == 7][0]
    f = sps_fields(sps[1])
    lc = f["cpb_removal_delay_length_minus1"][0] + 1
    ld = f["dpb_output_delay_length_minus1"][0] + 1
    assert f["pic_struct_present_flag"][0] == 1 and f["nal_hrd_parameters_present_flag"][0] == 1, \
        "the base stream needs pic-struct=1 and a NAL HRD"
    # the new SPS for sps_after_sei: the two length fields rewritten in place (u(5) each)
    lc2, ld2 = lc + 8, ld + 3
    sps2 = set_bits(sps[1], f["cpb_removal_delay_length_minus1"][1], 5, lc2 - 1)
    sps2 = set_bits(sps2, f["dpb_output_delay_length_minus1"][1], 5, ld2 - 1)
    out = bytearray()
    au = -1
    for hdr, rbsp, raw in us:
        t = hdr & 0x1F
        if t != 6:
            out += raw
            continue
        msgs = sei_messages(rbsp)
        pts = [m for m in msgs if m[0] == 1]
        if not pts:
            out += raw                      # x264's version / buffering SEIs
            continue
        au += 1
        br = cabac_ref.BitReader(bytes(pts[0][1]) + b"\x00")
        cpb, dpb, ps = br.read_bits(lc), br.read_bits(ld), br.read_bits(4)
        if kind == "ps_all":
            ps = PS_SEQ[au % len(PS_SEQ)]
            out += nal(hdr, sei_rbsp([(1, pt_payload(cpb, dpb, ps, lc, ld))]))
        elif kind == "sei_edge":
            zeros = bytes([0, 0, 0, 3, 0, 0, 1, 0, 0, 2] * 30)          # 300 bytes: EPBs inside
            out += nal(hdr, sei_rbsp([(5, zeros), (261, b"\xab\xcd"),
                                       (1, pt_payload(cpb, dpb, ps, lc, ld, pad_to=20))]))
        elif kind == "sei_short" and au == 3:
            out += nal(hdr, sei_rbsp([(1, pt_payload(cpb, dpb, ps, lc, ld)[:1])]))
        elif kind == "sei_malformed" and au == 4:
            out += nal(hdr, sei_rbsp([(1, pt_payload(cpb, dpb, ps, lc, ld))], cut_last_by=40))
        elif kind == "sei_missing" and au == 5:
            pass
        elif kind == "sps_after_sei" and au >= 6:
            # the SEI first (coded for the NEW lengths), then the new SPS, then the slice
            out += nal(hdr, sei_rbsp([(1, pt_payload(cpb, dpb, ps, lc2, ld2))]))
            out += nal(sps[0], sps2)
        else:
            out += raw
    return bytes(out), au + 1


SEI_KINDS = ("ps_all", "sei_edge", "sei_short", "sei_malformed", "sei_missing", "sps_after_sei")


# ---------------------------------------------------------------- P5d: C.4.4 fixtures

def no_vui_sps(rbsp):
    """The SPS with vui_parameters_present_flag 0 (the fields before it copied)."""
    pos = vui_flag_bitpos(rbsp)
    w = BitWriter()
    w.bits = rbsp_bits(rbsp, pos)
    w.u(1, 0)
    w.trailing()
    return w.bytes()


def slice_records(data):
    """[(unit index, header records, header bit length)] of every slice, by the model."""
    out = []
    sps_map, pps_map = {}, {}
    for k, (hdr, rbsp, _raw) in enumerate(units(data)):
        t = hdr & 0x1F
        rec = []
        if t == 7:
            s = FE.parse_sps(rbsp, rec)
            sps_map[s.id] = s
        elif t == 8:
            p = FE.parse_pps(rbsp, sps_map, rec)
            pps_map[p.id] = p
        elif t in (1, 5):
            br = cabac_ref.BitReader(rbsp)
            h = FE.parse_slice_header(br, t, (hdr >> 5) & 3, sps_map, pps_map, rec)
            h.nal_ref_idc = (hdr >> 5) & 3
            out.append((k, rec, br.pos, h))
    return out


def field_code(name):
    """A slice-header field's descriptor, by name (7.3.3): 'u1', 'uv', 'ue' or 'se'."""
    base = name.split("[")[0]
    if base in ("frame_num", "pic_order_cnt_lsb"):
        return "uv"
    if base.endswith("_flag") or base.endswith("_flag_l0") or base.endswith("_flag_l1"):
        return "u1"
    if base.startswith("delta_pic_order_cnt") or base in ("slice_qp_delta", "slice_alpha_c0_offset_div2",
                                                          "slice_beta_offset_div2"):
        return "se"
    if (base.startswith("luma_weight_l") or base.startswith("luma_offset_l") or
            base.startswith("chroma_weight_l") or base.startswith("chroma_offset_l")):
        return "se"
    return "ue"


def write_se(w, v):
    w.ue(2 * v - 1 if v > 0 else -2 * v)


def reencode_header(rec, h, marking):
    """A slice header's bits from its records, with the dec_ref_pic_marking() replaced by
    `marking` (a list of (name, value)); byte-aligned with cabac_alignment_one_bits."""
    sps = h.sps
    w = BitWriter()
    skip = False
    for r in rec:
        _s, name, v = r.split(" ")
        v = int(v)
        if name in ("adaptive_ref_pic_marking_mode_flag", "memory_management_control_operation",
                    "difference_of_pic_nums_minus1", "long_term_pic_num", "long_term_frame_idx",
                    "max_long_term_frame_idx_plus1"):
            if not skip:
                for n2, v2 in marking:
                    (w.u(1, v2) if field_code(n2) == "u1" else w.ue(v2))
                skip = True
            continue
        c = field_code(name)
        if c == "u1":
            w.u(1, v)
        elif c == "uv":
            w.u(sps.log2_max_frame_num if name == "frame_num" else sps.log2_max_poc_lsb, v)
        elif c == "se":
            write_se(w, v)
        else:
            w.ue(v)
    while len(w.bits) % 8:
        w.bits.append(1)                          # cabac_alignment_one_bit
    return w.bytes()


def rewrite_c44(data, kind):
    us = units(data)
    slices = slice_records(data)
    idrs = [k for k, _r, _p, h in slices if h.idr]
    assert len(idrs) >= 2, "the base stream needs two IDRs"
    out = bytearray()
    target = None
    if kind == "mmco5":
        refs_before = [k for k, _r, _p, h in slices if k < idrs[1] and h.nal_ref_idc and not h.idr]
        assert refs_before, "no reference picture before the second IDR"
        target = refs_before[-1]
    for k, (hdr, rbsp, raw) in enumerate(us):
        t = hdr & 0x1F
        if t == 7:
            out += nal(hdr, no_vui_sps(rbsp))
        elif kind == "no_output" and k == idrs[1]:
            f = sps_fields_slice(rbsp, slices, k)
            out += nal(hdr, set_bits(rbsp, f, 1, 1))
        elif kind == "mmco5" and k == target:
            _k, rec, pos, h = [x for x in slices if x[0] == k][0]
            hb = reencode_header(rec, h, [("adaptive_ref_pic_marking_mode_flag", 1),
                                          ("memory_management_control_operation", 5),
                                          ("memory_management_control_operation", 0)])
            out += nal(hdr, hb + rbsp[(pos + 7) // 8:])
        else:
            out += raw
    return bytes(out)


def sps_fields_slice(rbsp, slices, k):
    """The bit position just after no_output_of_prior_pics_flag in slice unit k."""
    _k, rec, _pos, h = [x for x in slices if x[0] == k][0]
    names = [r.split(" ")[1] for r in rec]
    assert "no_output_of_prior_pics_flag" in names
    # re-parse with a probe, stopping at the field
    got = {}

    class Rec(list):
        def append(self, r):
            if r.startswith("S no_output_of_prior_pics_flag "):
                got["pos"] = Probe.last.pos
            list.append(self, r)

    class Probe(cabac_ref.BitReader):
        last = None

        def __init__(self, *a, **kw):
            cabac_ref.BitReader.__init__(self, *a, **kw)
            Probe.last = self
    br = Probe(rbsp)
    sps_map = {h.sps.id: h.sps}
    pps_map = {h.pps.id: h.pps} if hasattr(h, "pps") else {}
    FE.parse_slice_header(br, 5, 3, sps_map, pps_map, Rec())
    return got["pos"]


C44_KINDS = ("no_output", "mmco5")
KINDS = ("max", "err_cpb", "err_mdfb", "err_nrf", "err_tick", "err_len") + tuple("dpb%d" % n for n in range(1, 17)) \
    + SEI_KINDS + C44_KINDS + ("unlossless",)


def main(argv):
    if len(argv) != 3 or argv[1] not in KINDS:
        sys.exit(__doc__)
    src = open(argv[0], "rb").read()
    if argv[1] in C44_KINDS:
        data, what = rewrite_c44(src, argv[1]), "C.4.4 (%s)" % argv[1]
        open(argv[2], "wb").write(data)
        print("h264_synth: %s -> %s (%s)" % (argv[0], argv[2], what))
        return
    if argv[1] == "unlossless":
        data, n = unlossless(src)
        what = "%d SPS" % n
    elif argv[1] in SEI_KINDS:
        data, n = rewrite_sei(src, argv[1])
        what = "%d access units' picture timing" % n
    else:
        data, n = rewrite(src, argv[1])
        what = "%d SPS" % n
    open(argv[2], "wb").write(data)
    print("h264_synth: %s -> %s (%s, %s rewritten)" % (argv[0], argv[2], argv[1], what))


if __name__ == "__main__":
    main(sys.argv[1:])
