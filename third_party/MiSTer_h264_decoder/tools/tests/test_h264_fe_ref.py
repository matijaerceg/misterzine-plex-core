#!/usr/bin/env python3
"""cabac_ref / h264_fe_ref -- the Python front end -- gated three ways:

  units      the bit reader, NAL splitting with emulation-prevention bytes, the context
             initialisation arithmetic (9.3.1.1 by hand), the bypass engine on a hand
             vector -- no tools needed.
  x264       (SKIP without ffmpeg's libx264) a synthetic Main/CABAC clip encoded at test
             time: 12 frames, 4 slices per picture, B-frames, 3 references, weighted P.
             The model must decode every slice to exactly the picture's last macroblock,
             every SE within its spec range, and its SPS/PPS/slice-header records must
             equal ffmpeg's own `trace_headers` parse (an independent header oracle). A
             wrong context, table entry or neighbour rule desynchronises the arithmetic
             decoder within a macroblock, so this arm catches the RED mutations without
             the reference set.
  high       (H264 Phase 5; SKIP without libx264) an x264 High clip: the 8x8 transform,
             Intra_8x8, B, and custom scaling matrices in the PPS (every list coded,
             delta_scale runs) -- headers == ffmpeg trace_headers, and with the traced
             ldecod the canonical stream == JM's; with the spec PDF, tools/high_tables.py
             re-derived and cross-checked against ffmpeg (gen_high_tables.py --check).
  refs       (SKIP without $H264_REFS_DIR + the traced ldecod) CABACI3_Sony_B: the model's
             canonical stream identical to JM's -- 534,852 records -- and the context
             tables regenerated from the spec PDF equal to the committed module; CAPM3_Sony_D
             (I_PCM under CABAC) identical to JM and to its donated trace.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import score as S  # noqa: E402
import cabac_ref as C  # noqa: E402
import h264_fe_ref as FE  # noqa: E402
import h264_trace_ref as TR  # noqa: E402

Sc = S.Score("test_h264_fe_ref")

print("[units]")
br = C.BitReader(bytes([0b10100110, 0b01000000]))          # ue: 1 -> 0, 010 -> 1, 011 -> 2, 00100 -> 3
Sc.check("ue(v)", [br.ue() for _ in range(4)], [0, 1, 2, 3])
br = C.BitReader(bytes([0b01001100, 0b10000000]))          # se: 010 -> 1, 011 -> -1, 00100 -> 2
Sc.check("se(v)", [br.se() for _ in range(3)], [1, -1, 2])
nal = b"\x00\x00\x00\x01\x67\x00\x00\x03\x01\xaa\x00\x00\x01\x68\x00\x00\x03\x00\x00\x00\x01\x65\xff"
Sc.check("Annex-B split + EPB removal",
         list(FE.nal_units(nal)), [(3, 7, b"\x00\x00\x01\xaa"), (3, 8, b"\x00\x00"), (3, 5, b"\xff")])
# (a NAL never ends in 0x00 (7.4.1): "00 00 03" at its end is the RBSP "00 00" plus its EPB)
cab = C.Cabac(C.BitReader(b"\x00" * 4))
cab.init_contexts(26, "I")
# ctxIdx 0: (m, n) = (20, -15): pre = ((20 * 26) >> 4) - 15 = 17 -> pStateIdx 46, valMPS 0
Sc.check("context init (20, -15) at QP 26", (cab.p_state[0], cab.val_mps[0]), (46, 0))
# ctxIdx 6: (-28, 127): pre = ((-28 * 26) >> 4) + 127 = -46 + 127 = 81 -> pStateIdx 17, valMPS 1
Sc.check("context init (-28, 127) at QP 26", (cab.p_state[6], cab.val_mps[6]), (17, 1))
cab.init_contexts(51, 0)
Sc.check("QP clip and set 0 (ctxIdx 11 = (23, 33)): pre = clip(1, 126, 73 + 33)", (cab.p_state[11], cab.val_mps[11]), (42, 1))
# bypass by hand: offset = 9 bits 011111111 = 255; bin 1: 511 >= 510 -> 1, offset 1; bin 2: 3 < 510 -> 0
cab = C.Cabac(C.BitReader(bytes([0b01111111, 0b11100000])))
cab.init_engine()
Sc.check("engine init", (cab.rng, cab.off), (510, 255))
Sc.check("bypass bins", [cab.bypass(), cab.bypass()], [1, 0])
Sc.check("bin counter", cab.bins, 2)
cab = C.Cabac(C.BitReader(bytes([0xff, 0xff])))
Sc.raises("codIOffset 511 at init is a bitstream violation", cab.init_engine, C.CabacError, "511")

print("[the fabric's tables]")
r = subprocess.run([sys.executable, os.path.join(os.path.dirname(HERE), "cabac_mem.py"), "--check"],
                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
Sc.check("h264/dec/*.mem == cabac_tables.py", r.returncode == 0 and "DIFFERS" not in r.stdout, True)

print("[refusals]")


class Bits(object):
    """a tiny MSB-first writer for hand-made RBSPs"""

    def __init__(self):
        self.s = ""

    def u(self, n, v):
        self.s += format(v, "0%db" % n) if n else ""
        return self

    def ue(self, v):
        b = format(v + 1, "b")
        self.s += "0" * (len(b) - 1) + b
        return self

    def bytes(self):
        s = self.s + "1"
        s += "0" * (-len(s) % 8)
        return bytes(int(s[i:i + 8], 2) for i in range(0, len(s), 8))


# a Main-profile SPS whose only sin is mb_adaptive_frame_field_flag
sps = (Bits().u(8, 77).u(8, 0x40).u(8, 30).ue(0).ue(0).ue(0).ue(0).ue(2).u(1, 0)
       .ue(44).ue(14).u(1, 0).u(1, 1).u(1, 1).u(1, 0).u(1, 0))
Sc.raises("MBAFF SPS refused", lambda: FE.parse_sps(sps.bytes(), []), FE.Refused, "mb_adaptive_frame_field_flag")
rec = []
ok = FE.parse_sps(Bits().u(8, 77).u(8, 0x40).u(8, 30).ue(0).ue(0).ue(0).ue(0).ue(2).u(1, 0)
                  .ue(44).ue(14).u(1, 0).u(1, 0).u(1, 1).u(1, 0).u(1, 0).bytes(), rec)
Sc.check("PAFF SPS parses (720x480, frame_mbs_only 0)", (ok.width_mbs, ok.frame_height_mbs, ok.mbaff), (45, 30, 0))
Sc.check("its records", rec[-5:], ["S frame_mbs_only_flag 0", "S mb_adaptive_frame_field_flag 0",
                                   "S direct_8x8_inference_flag 1", "S frame_cropping_flag 0",
                                   "S vui_parameters_present_flag 0"])
Sc.check("frame_mbs_only 0 -> mb_adaptive_frame_field_flag traced", "S mb_adaptive_frame_field_flag 0" in rec, True)
Sc.raises("CAVLC PPS refused", lambda: FE.parse_pps(Bits().ue(0).ue(0).u(1, 0).bytes(), {}, []), FE.Refused, "CAVLC")
Sc.raises("FMO PPS refused", lambda: FE.parse_pps(Bits().ue(0).ue(0).u(1, 1).u(1, 0).ue(1).bytes(), {}, []), FE.Refused, "FMO")


def ranges_ok(recs, num_ref):
    """every SE within the spec's range for Main 4:2:0 at Level 3.0"""
    lim = {"mb_type": 48, "sub_mb_type": 12, "coded_block_pattern": 47, "intra_chroma_pred_mode": 3,
           "rem_intra4x4_pred_mode": 7, "prev_intra4x4_pred_mode_flag": 1, "mb_skip_flag": 1,
           "end_of_slice_flag": 1}
    for r in recs:
        if r.startswith("E "):
            _, k, v = r.split(" ")
            v = int(v)
            if k in lim and not 0 <= v <= lim[k]:
                return "%s = %d" % (k, v)
            if k.startswith("ref_idx") and not 0 <= v < num_ref:      # x264 weightp=2 duplicates refs: up to 32
                return r
            if k.startswith("mvd") and not -8192 <= v <= 8191:
                return r
            if k == "mb_qp_delta" and not -26 <= v <= 25:
                return r
        elif r.startswith("B "):
            for c in r.split(" ")[4:]:
                if not -65536 < int(c) < 65536:
                    return r
    return None


def pictures(recs):
    """[(set of mb addresses, slice count)] per picture (a slice at MB 0 starts one)"""
    pics = []
    for r in recs:
        if r.startswith("S first_mb_in_slice "):
            first = int(r.split()[2])
            if first == 0:
                pics.append([set(), 0])
            pics[-1][1] += 1
        elif r.startswith("M "):
            pics[-1][0].add(int(r[2:]))
    return pics


FF_ALIAS = {"max_num_ref_frames": "num_ref_frames", "gaps_in_frame_num_allowed_flag": "gaps_in_frame_num_value_allowed_flag",
            "luma_weight_l0_flag": "luma_weight_flag_l0", "chroma_weight_l0_flag": "chroma_weight_flag_l0",
            "luma_weight_l1_flag": "luma_weight_flag_l1", "chroma_weight_l1_flag": "chroma_weight_flag_l1",
            # the canonical stream keeps JM's (2003) name for this High SPS field
            "qpprime_y_zero_transform_bypass_flag": "lossless_qpprime_y_zero_flag"}
FF_DROP = re.compile(r"^(forbidden_zero_bit|nal_ref_idc|nal_unit_type|cabac_alignment_one_bit|rbsp_|reserved_|"
                     r"constraint_set[345]_flag)")


def ffmpeg_headers(stream):
    """ffmpeg -bsf:v trace_headers -> [[(field, value)] per SPS/PPS/slice header], in-band only."""
    r = subprocess.run(["ffmpeg", "-v", "trace", "-i", stream, "-c", "copy", "-bsf:v", "trace_headers", "-f", "null", "-"],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
    sections = []
    cur = None
    in_extradata = False
    skip = 0
    for ln in r.stdout.split("\n"):
        m = re.match(r"^\[trace_headers @ 0x[0-9a-f]+\] (.*)$", ln)
        if not m:
            continue
        t = m.group(1)
        if t == "Extradata":
            in_extradata = True
            continue
        if t in ("Sequence Parameter Set", "Picture Parameter Set", "Slice Header"):
            if in_extradata and t != "Slice Header":
                skip += 1
                cur = None
                if skip == 2:
                    in_extradata = False
                continue
            cur = []
            sections.append(cur)
            continue
        if t.startswith(("Supplemental", "Access Unit", "nal_unit_type", "Filler", "End of")):
            cur = None
            continue
        mm = re.match(r"^\d+\s+(\S+?)(?:\[\d+\])*\s+[01]+\s+=\s+(-?\d+)$", t)
        if mm and cur is not None:
            name = FF_ALIAS.get(mm.group(1), mm.group(1))
            if name in ("bit_rate_value_minus1", "cpb_size_value_minus1", "cbr_flag"):
                name += "[i]"                                 # the HRD loop: the model's [i] names
            if not FF_DROP.match(name):
                cur.append((name, int(mm.group(2))))
    return sections


MODEL_ALIAS = re.compile(r"^(modification_of_pic_nums_idc|abs_diff_pic_num_minus1|long_term_pic_num)_l[01]$")


def model_headers(recs):
    """the model's S records per NAL; the list-modification names lose their _lX
    suffix, which ffmpeg does not print (its sections are in syntax order anyway)"""
    out = []
    cur = None
    for r in recs:
        if r.startswith("N "):
            cur = []
            out.append(cur)
        elif r.startswith("S "):
            _, k, v = r.split(" ", 2)
            m = MODEL_ALIAS.match(k)
            if k.endswith("_scaling_list_present_flag[i]"):
                k = k[:-3]                                    # ffmpeg drops the index
            cur.append((m.group(1) if m else k, int(v)))
    return [s for s in out if s]


print("[x264: a synthetic Main/CABAC clip, 4 slices, B, 3 refs, weighted P]")
have_x264 = shutil.which("ffmpeg") and "libx264" in subprocess.run(
    ["ffmpeg", "-hide_banner", "-encoders"], stdout=subprocess.PIPE, universal_newlines=True).stdout
if not have_x264:
    print("  SKIP: ffmpeg with libx264 not found")
else:
    with tempfile.TemporaryDirectory(prefix="h264_fe_") as d:
        clip = os.path.join(d, "x264.264")
        r = subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=720x480:rate=24", "-frames:v", "12",
                            "-c:v", "libx264", "-profile:v", "main", "-pix_fmt", "yuv420p", "-x264-params",
                            "cabac=1:8x8dct=0:bframes=2:b-pyramid=0:ref=3:weightp=2:slices=4:keyint=6:min-keyint=6:"
                            "scenecut=0:direct=spatial:aq-mode=1:qp=26", "-bsf:v", "h264_mp4toannexb", "-f", "h264", "-y", clip],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
        Sc.check("encode", r.returncode, 0)
        data = open(clip, "rb").read()
        stats = {}
        try:
            recs = FE.decode_stream(data, stats)
        except (FE.Refused, FE.FeError, C.CabacError) as e:
            recs = []
            Sc.check("decode raised %s: %s" % (type(e).__name__, e), False, True)
        if recs:
            pics = pictures(recs)
            Sc.check("12 pictures", len(pics), 12)
            Sc.check("every picture: 1350 macroblocks, each once, 4 slices",
                     [(len(s), n) for s, n in pics], [(1350, 4)] * 12)
            Sc.check("every slice ends on a terminate bin", recs.count("E end_of_slice_flag 1"), 48)
            Sc.check("SE ranges", ranges_ok(recs, 32), None)
            types = [int(r.split()[2]) for r in recs if r.startswith("S slice_type ")]
            Sc.check("I, P and B slices present", sorted(set(t % 5 for t in types)), [0, 1, 2])
            Sc.check("weighted P present", any(r.startswith("S luma_weight_l0 ") for r in recs), True)
            Sc.check("B_8x8 / direct present", any(r == "E mb_type 22" for r in recs), True)
            Sc.check("ref_idx > 0 present", any(r.startswith("E ref_idx_l0 ") and r != "E ref_idx_l0 0" for r in recs), True)
            ff = ffmpeg_headers(clip)
            mine = model_headers(recs)
            Sc.check("header count vs ffmpeg trace_headers", len(mine), len(ff))
            first_bad = next((i for i, (x, y) in enumerate(zip(mine, ff)) if x != y), None)
            if first_bad is not None:
                print("   model :", mine[first_bad][:12])
                print("   ffmpeg:", ff[first_bad][:12])
            Sc.check("SPS / PPS / slice headers == ffmpeg", first_bad, None)
            Sc.check("bins decoded", stats["bins"] > 100000, True)

print("[high: an x264 High clip -- 8x8 transform, Intra_8x8, B, custom scaling matrices]")
if not have_x264:
    print("  SKIP: ffmpeg with libx264 not found")
else:
    L8 = ",".join(str(4 + (i * 11) % 60) for i in range(64))
    L4 = ",".join(str(6 + (i * 13) % 50) for i in range(16))
    with tempfile.TemporaryDirectory(prefix="h264_fe_") as d:
        clip = os.path.join(d, "high.264")
        r = subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "mandelbrot=size=352x288:rate=30", "-frames:v", "8",
                            "-c:v", "libx264", "-profile:v", "high", "-pix_fmt", "yuv420p", "-x264-params",
                            "cabac=1:8x8dct=1:bframes=2:ref=2:keyint=4:scenecut=0:crf=20:cqm4iy=%s:cqm4ic=%s:cqm4py=%s:"
                            "cqm4pc=%s:cqm8i=%s:cqm8p=%s" % (L4, L4, L4, L4, L8, L8),
                            "-bsf:v", "h264_mp4toannexb", "-f", "h264", "-y", clip],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
        Sc.check("encode", r.returncode, 0)
        stats = {}
        try:
            recs = FE.decode_stream(open(clip, "rb").read(), stats)
        except (FE.Refused, FE.FeError, C.CabacError) as e:
            recs = []
            Sc.check("decode raised %s: %s" % (type(e).__name__, e), False, True)
        if recs:
            Sc.check("8x8 blocks present", sum(1 for x in recs if x.startswith("B L8 ")) > 50, True)
            Sc.check("Intra_8x8 modes present", any(x.startswith("E prev_intra8x8_pred_mode_flag") for x in recs), True)
            Sc.check("inter transform_size_8x8_flag 1 present",
                     any(x == "E transform_size_8x8_flag 1" for x in recs), True)
            Sc.check("scaling lists coded (delta_scale)", sum(1 for x in recs if x.startswith("S delta_scale ")) > 16, True)
            ff = ffmpeg_headers(clip)
            mine = model_headers(recs)
            first_bad = next((i for i, (x, y) in enumerate(zip(mine, ff)) if x != y), None)
            if first_bad is not None:
                print("   model :", mine[first_bad][:14])
                print("   ffmpeg:", ff[first_bad][:14])
            Sc.check("High SPS / PPS (scaling lists) / slice headers == ffmpeg", (len(mine) == len(ff), first_bad), (True, None))
            if os.access(TR.jm_binary(), os.X_OK):
                lines, _frames = TR.run_jm(clip)
                dd, _w = TR.diff(recs, TR.parse_jm(lines), "model", "jm")
                Sc.check("High clip: model == JM (first difference)", dd, None)
            else:
                print("  SKIP: model vs JM needs the traced ldecod (tools/jm_build.sh)")
    refs = os.environ.get("H264_REFS_DIR", os.path.expanduser("~/h264-refs"))
    if os.path.exists(os.path.join(refs, "T-REC-H.264-202606.pdf")) and shutil.which("pdftotext"):
        r = subprocess.run([sys.executable, os.path.join(os.path.dirname(HERE), "gen_high_tables.py"), "--check"],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
        Sc.check("high_tables.py == the spec PDF (+ ffmpeg cross-check)",
                 (r.returncode, "identical" in r.stdout, "every value agrees" in r.stdout), (0, True, True))
    else:
        print("  SKIP: the High table regeneration needs the spec PDF and pdftotext")

print("[refs: CABACI3_Sony_B vs the traced ldecod; the tables vs the spec PDF]")
refs = os.environ.get("H264_REFS_DIR", os.path.expanduser("~/h264-refs"))
zpath = os.path.join(refs, "H.264.1_bitstreams", "AVCv1", "CABACI3_Sony_B.zip")
exe = TR.jm_binary()
if not os.path.exists(zpath) or not os.access(exe, os.X_OK):
    print("  SKIP: needs %s and %s (tools/jm_build.sh)" % (zpath, exe))
else:
    with tempfile.TemporaryDirectory(prefix="h264_fe_") as d:
        with zipfile.ZipFile(zpath) as z:
            z.extractall(d)
        jsv = os.path.join(d, "CABACI3_Sony_B.jsv")
        recs = FE.decode_stream(open(jsv, "rb").read())
        lines, _frames = TR.run_jm(jsv)
        jm = TR.parse_jm(lines)
        dd, _w = TR.diff(recs, jm, "model", "jm")
        Sc.check("model == JM (first difference)", dd, None)
        Sc.check("534,852 records", len(recs), 534852)
    zpcm = os.path.join(refs, "H.264.1_bitstreams", "AVCv1", "CAPM3_Sony_D.zip")
    if os.path.exists(zpcm):
        # I_PCM under CABAC: byte alignment after the terminate bin, 384 raw samples, the
        # engine re-initialised (9.3.1.2) -- on no disc, so the conformance stream is the gate
        with tempfile.TemporaryDirectory(prefix="h264_fe_") as d:
            with zipfile.ZipFile(zpcm) as z:
                z.extractall(d)
            jsv = os.path.join(d, "CAPM3_Sony_D.jsv")
            recs = FE.decode_stream(open(jsv, "rb").read())
            lines, _frames = TR.run_jm(jsv)
            dd, _w = TR.diff(recs, TR.parse_jm(lines), "model", "jm")
            Sc.check("I_PCM stream: model == JM", dd, None)
            Sc.check("I_PCM macroblocks decoded", sum(1 for r in recs if r.startswith("B PCM ")) > 100, True)
            don = TR.parse_jvt_file(open(os.path.join(d, "CAPM3_Sony_D-trace.txt"), errors="replace").readlines())
            dd, _w = TR.diff(recs, don, "model", "donated")
            Sc.check("I_PCM stream: model == the donated trace", dd, None)
    pdf = os.path.join(refs, "T-REC-H.264-202606.pdf")
    if os.path.exists(pdf) and shutil.which("pdftotext"):
        r = subprocess.run([sys.executable, os.path.join(os.path.dirname(HERE), "gen_cabac_tables.py"), "--check"],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
        Sc.check("cabac_tables.py == the spec PDF (+ ffmpeg cross-check)", r.returncode == 0 and "matches" in r.stdout, True)
    else:
        print("  SKIP: table regeneration needs the spec PDF and pdftotext")

print("[P5c: the picture timing SEI vs ffmpeg trace_headers; the PTS vs ffprobe]")
if not have_x264:
    print("  SKIP: needs ffmpeg with libx264")
else:
    import h264_synth
    with tempfile.TemporaryDirectory(prefix="h264_pt_") as d:
        base = os.path.join(d, "base.264")
        subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=64x64:rate=24", "-frames:v", "12",
                        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-x264-params",
                        "cabac=1:8x8dct=0:nal-hrd=vbr:vbv-maxrate=2000:vbv-bufsize=2000:pic-struct=1:bframes=2",
                        "-f", "h264", "-y", base], check=True)
        data, _n = h264_synth.rewrite_sei(open(base, "rb").read(), "ps_all")
        f = os.path.join(d, "ps_all.264")
        open(f, "wb").write(data)
        names = ("cpb_removal_delay", "dpb_output_delay", "pic_struct")
        tr = subprocess.run(["ffmpeg", "-v", "trace", "-i", f, "-c", "copy", "-bsf:v", "trace_headers", "-f", "null", "-"],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True).stdout
        ff = [(m.group(1), int(m.group(2))) for m in re.finditer(r"\b(%s) +[01]+ = (\d+)" % "|".join(names), tr)]
        st = {}
        mine = [(r.split()[1], int(r.split()[2])) for r in FE.decode_stream(data, st) if r.split()[1] in names]
        Sc.check("every pic_struct value on frames: the model's SEI fields == ffmpeg's", mine, ff)
        Sc.check("the fixture spans pic_struct 0, 3..8, reserved and field-only (12 values)",
                 sorted(set(v for n, v in mine if n == "pic_struct")), [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 15])
        Sc.check("Table D-1 mismatches counted (1, 2, 9, 15 on frames)", st["pt_struct"], 4)
    iso_dir = os.environ.get("UMD_ISO_DIR", os.path.expanduser("~/umd-isos"))
    discs = [os.path.join(iso_dir, x) for x in sorted(os.listdir(iso_dir))
             if x.lower().endswith(".iso") and ("akira" in x.lower() or "family guy" in x.lower())] \
        if os.path.isdir(iso_dir) else []
    if not discs:
        print("  SKIP: the PTS arm needs the Akira / Family Guy images in $UMD_ISO_DIR")
    for iso in discs:
        with tempfile.TemporaryDirectory(prefix="h264_pts_") as d:
            import psmf_ref
            src = psmf_ref.Source(iso, 1)
            src.limit(150)
            r = psmf_ref.parse(src.mm, src.start, src.end, keep=True)
            es, marks = psmf_ref.es(src.mm, r, "video")
            cut = os.path.join(d, "cut.mps")
            open(cut, "wb").write(src.mm[src.start:src.end])
            src.close()
            rec = []
            try:
                FE.decode_stream(es, None, marks=[(o, p) for (o, p, _dt, _f) in marks if p is not None], rec=rec)
            except (FE.FeError, C.CabacError):
                pass                                    # the window ends inside an access unit
            pics, tags = 0, []
            for i, x in enumerate(rec):
                if x == "S first_mb_in_slice 0":
                    pics += 1
                elif x.startswith("S au_pts_lo "):
                    tags.append((pics - 1, int(x.split()[2]) | (int(rec[i + 1].split()[2]) << 32)))
            ffp = [int(x) for x in subprocess.run(
                ["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries", "packet=pts", "-of", "csv=p=0", cut],
                stdout=subprocess.PIPE, universal_newlines=True).stdout.split() if x != "N/A"]
            name = os.path.basename(iso)[:24]
            Sc.check("%s: tagged pictures, the PTS == ffprobe's for the same packet" % name,
                     [(i, t) for i, t in tags], [(i, ffp[i]) for i, _t in tags])
            Sc.check("%s: at least 4 pictures tagged" % name, len(tags) >= 4, True)

Sc.finish()
