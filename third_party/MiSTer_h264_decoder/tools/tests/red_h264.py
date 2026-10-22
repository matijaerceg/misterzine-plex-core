#!/usr/bin/env python3
"""RED arm for the host-side python tests (harvested from UMD's tools/tests/red_umd.py at
cc595c6 with the tests this core carries: the HIL settings backup, the output-order and
trace models, the Python front end) (bench/h264/README.md "--red proves the bench can
fail"): each mutation is applied to a COPY of tools/ (never the tree) and must make ITS
OWN test fail. Anchors are asserted unique, so a moved line is a harness failure, not a
silent no-op. Run by tools/tests/run_tests.sh --red.
"""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.dirname(HERE)

# (tool file, anchor, replacement, the test that must catch it, what the defect is)
MUTATIONS = [    # the HIL settings backup (test_mister_cfg.py; the .hilnew marker, ported from the H264 fork)
    ("mister.py", "  else touch {CFG_DIR}/{CFG_NAME}.hilnew; fi", "  fi",
     "test_mister_cfg.py", "launch does not mark a settings file the harness created"),
    ("mister.py", "  rm -f @CFGDIR@/@CFG@ @CFGDIR@/@CFG@.hilnew", "  rm -f @CFGDIR@/@CFG@.hilnew",
     "test_mister_cfg.py", "restore leaves the harness's own settings file behind"),
    ("mister.py", "if [ ! -f {CFG_DIR}/{CFG_NAME}.hilbak ] && [ ! -f {CFG_DIR}/{CFG_NAME}.hilnew ]; then",
     "if [ ! -f {CFG_DIR}/{CFG_NAME}.hilnew ]; then",
     "test_mister_cfg.py", "a second launch overwrites the user's backup"),
    # P5d, the output order (test_dpb_output_ref.py)
    ("h264_recon_ref.py", "        fr = min(self.waitq, key=self.store_poc)",
     "        fr = max(self.waitq, key=self.store_poc)",
     "test_dpb_output_ref.py", "the bumping takes the largest POC (C.4.5.3)"),
    ("h264_recon_ref.py", "return max(1, min(16, mbs // (sps.width_mbs * sps.frame_height_mbs)))",
     "return max(1, min(16, (mbs - 1) // (sps.width_mbs * sps.frame_height_mbs)))",
     "test_dpb_output_ref.py", "MaxDpbFrames one short on an exact division (A.3.1)"),
    ("h264_recon_ref.py", "        if h.idr and h.no_output_of_prior_pics:", "        if False:",
     "test_dpb_output_ref.py", "no_output_of_prior_pics_flag ignored (C.4.4)"),
    ("dpb_output_ref.py", "        poc, b, p = min(cands, key=lambda c: (c[0], c[1].frame, c[2]))",
     "        poc, b, p = max(cands, key=lambda c: (c[0], c[1].frame, c[2]))",
     "test_dpb_output_ref.py", "the spec process bumping the largest POC"),
    ("h264_trace_ref.py", "mb.se(name, value - 1 if mb.slice_type == SLICE_P else value)",
     "mb.se(name, value)", "test_h264_trace_ref.py", "JM's P-slice mb_type is spec + 1"),
    ("h264_trace_ref.py", "mb.se(name, 1 - value)               # JM: 1 = NOT skipped",
     "mb.se(name, value)               # JM: 1 = NOT skipped",
     "test_h264_trace_ref.py", "JM's mb_skip_flag is inverted"),
    ("h264_trace_ref.py", "last.items.append((\"E\", \"end_of_slice_flag\", 1))",
     "last.items.append((\"E\", \"end_of_slice_flag\", 0))",
     "test_h264_trace_ref.py", "the picture-final end_of_slice_flag JM never decodes"),
    # the Python front end: caught by the x264 arm (a wrong context desynchronises CABAC)
    ("cabac_ref.py", "q = (self.rng >> 6) & 3", "q = (self.rng >> 5) & 3",
     "test_h264_fe_ref.py", "qCodIRangeIdx bits"),
    ("cabac_tables.py", "    [128, 176, 208, 240],", "    [128, 176, 208, 241],",
     "test_h264_fe_ref.py", "one rangeTabLPS entry"),
    ("h264_fe_ref.py", "inc = 2 if s > 32 else 1 if s > 2 else 0", "inc = 2 if s > 32 else 1 if s > 3 else 0",
     "test_h264_fe_ref.py", "mvd ctxIdxInc threshold (9.3.3.1.1.7)"),
    ("h264_fe_ref.py", "            return 1 if self.cur.intra else 0", "            return 0",
     "test_h264_fe_ref.py", "coded_block_flag condTerm for an unavailable neighbour of an intra MB"),
    ("h264_fe_ref.py", "return 1 + cab.decode(27 + 5)                       # 1 0 x",
     "return 1 + cab.decode(27 + 4)                       # 1 0 x",
     "test_h264_fe_ref.py", "B mb_type bin 2 context after b1 == 0 (Table 9-41)"),
    # H264 Phase 5, High profile in the front end (test_h264_fe_ref.py's high arm)
    ("h264_fe_ref.py", "        return self.cab.decode(399 + inc)", "        return self.cab.decode(399)",
     "test_h264_fe_ref.py", "transform_size_8x8_flag ctxIdxInc ignored (9.3.3.1.1.10)"),
    ("h264_fe_ref.py", "abs_off = 426 if cat == 5 else", "abs_off = 427 if cat == 5 else",
     "test_h264_fe_ref.py", "the 8x8 coeff_abs_level_minus1 ctxIdxOffset (Table 9-34)"),
    ("h264_fe_ref.py", "                inc_s, inc_l = sig_map[i], HT.LAST8[i]",
     "                inc_s, inc_l = sig_map[i], HT.LAST8[min(i + 1, 62)]",
     "test_h264_fe_ref.py", "the 8x8 last_significant_coeff_flag map (Table 9-43)"),
    ("h264_fe_ref.py", "                        cur.cbf_luma[4 * b8 + b] = 1", "                        cur.cbf_luma[4 * b8 + b] = 0",
     "test_h264_fe_ref.py", "a 4x4 cbf context not seeing a neighbour's 8x8 block (9.3.3.1.1.9)"),
    ("h264_fe_ref.py", "            nxt = (last + d + 256) % 256", "            nxt = (last + d + 255) % 256",
     "test_h264_fe_ref.py", "scaling_list() nextScale arithmetic (7.3.2.1.1.1): the lists desynchronise the parse"),
    # High profile in the reconstruction (test_h264_recon_high.py)
    ("h264_recon_ref.py", "    if i % 4 == 2 and j % 4 == 2:\n        return v[2]", "    if i % 4 == 2 and j % 4 == 2:\n        return v[1]",
     "test_h264_recon_high.py", "normAdjust8x8's (2, 2) class (8-317)"),
    ("h264_recon_ref.py", "    e3 = d1 + d7 - d3 - (d3 >> 1)", "    e3 = d1 + d7 - d3",
     "test_h264_recon_high.py", "the 8x8 inverse transform's e3 (8-361)"),
    ("h264_recon_ref.py", "        t[15] = (top[14] + 3 * top[15] + 2) >> 2", "        t[15] = top[15]",
     "test_h264_recon_high.py", "Intra_8x8 reference filter p'[15, -1] (8-81)"),
    ("h264_recon_ref.py", "                ma = (modes if nba is info else nba.modes)[4 * b8a + 1] if nba.i4 else 2",
     "                ma = (modes if nba is info else nba.modes)[4 * b8a + 3] if nba.i4 else 2",
     "test_h264_recon_high.py", "Intra8x8PredMode from a 4x4 neighbour A: n = 1 (8-72)"),
    # (the vertical loop's skip, the one carrying the t8_edge_skipped coverage count)
    ("h264_recon_ref.py", "            if e in (1, 3) and q.t8:\n                # coverage: an edge the 4x4",
     "            if False:\n                # coverage: an edge the 4x4",
     "test_h264_recon_high.py", "the 4-sample vertical luma edges filtered inside an 8x8-transform macroblock (8.7)"),
    ("h264_recon_ref.py", "            ls4 = self.ls4[1 + icc + (0 if info.intra else 3)]",
     "            ls4 = self.ls4[0 if info.intra else 3]",
     "test_h264_recon_high.py", "the chroma blocks scaled with the luma list (8.5.9 iYCbCr)"),
    ("h264_fe_ref.py", '            return DEFAULT_LISTS[i], "fallback-default"', '            return (FLAT4 if i < 6 else FLAT8), "fallback-default"',
     "test_h264_recon_high.py", "fall-back rule A to Flat instead of Default (Table 7-2)"),
    ("h264_recon_ref.py", "    ls = ls4[qp % 6][0][0]\n    out = [0] * 16", "    ls = LEVEL_SCALE[qp % 6][0][0]\n    out = [0] * 16",
     "test_h264_recon_high.py", "the Intra16x16 DC scaled without its weight (8-321: LevelScale4x4(qP % 6, 0, 0))"),
    # P3, the HPS interface's layout and model (test_ring_model.py)
    ("ring_layout.py", '(5, "mem", [("read_index", 0, 32,', '(5, "mem", [("read_index", 1, 31,',
     "test_ring_model.py", "a published field moved without deciding it (and the headers not regenerated)"),
    ("ring_model.py", "        if hseq != seq:", "        if False:",
     "test_ring_model.py", "the consumer ignores the record sequence (R9: a stale lap's header)"),
    ("ring_model.py", "1 if (mark and k == 0) else 0, pts", "1 if (mark and k == 1) else 0, pts",
     "test_ring_model.py", "the PTS mark on the second payload byte"),
    ("ring_model.py", 'if n > to_end and rtype != T["PAD"]', 'if False and n > to_end and rtype != T["PAD"]',
     "test_ring_model.py", "the producer writes a record across the ring's end instead of a PAD"),
    ("ring_model.py", 'if c.eos and not flags & F["DISCONTINUITY"]:', "if False:",
     "test_ring_model.py", "a VIDEO_AU after END_OF_STREAM accepted without DISCONTINUITY"),
    # 1.0, the version rule (test_hps_lib.py: test_ring's attach / version arms)
    ("hps/include/h264ring.h", "    return ((core >> 8) & 0xFFu) == ((lib >> 8) & 0xFFu) && (core & 0xFFu) >= (lib & 0xFFu);",
     "    return (core & 0xFFu) >= (lib & 0xFFu);",
     "test_hps_lib.py", "the version rule ignores the major (a 0.17 or 2.0 core attached)"),
    ("hps/include/h264ring.h", "    return ((core >> 8) & 0xFFu) == ((lib >> 8) & 0xFFu) && (core & 0xFFu) >= (lib & 0xFFu);",
     "    return ((core >> 8) & 0xFFu) == ((lib >> 8) & 0xFFu);",
     "test_hps_lib.py", "the version rule ignores the minor (an older core serves a newer program)"),
    ("hps/lib/h264ring.c", "    if (!h264ring_version_ok((uint32_t)(w1 & 0xFFFFu), H264RING_VERSION) ||",
     "    if ((w1 & 0xFFFFu) != H264RING_VERSION ||",
     "test_hps_lib.py", "attach checks the version exactly (a 1.2 core refuses a 1.1 program)"),
    # P3, the client library (test_hps_lib.py: hps/ built in the copy)
    ("hps/lib/h264ring.c", "    ctrl_lo_store(r, H264RING_W_NONCE, nonce);        /* the nonce ALONE starts the session */",
     "    ctrl_lo_store(r, H264RING_W_WRITE_INDEX, 0);\n    ctrl_lo_store(r, H264RING_W_NONCE, nonce);",
     "test_hps_lib.py", "the session start also zeroes the write index (the race the interface avoids)"),
    ("hps/lib/h264ring.c", "            r->need_disc = 1;", "            r->need_disc = 0;",
     "test_hps_lib.py", "no DISCONTINUITY after END_OF_STREAM"),
    ("hps/lib/h264ring.c", "            for (int i = 7; i >= 0; i--)", "            for (int i = 0; i < 8; i++)",
     "test_hps_lib.py", "payload bytes packed in the wrong order"),
    ("hps/lib/h264ring.c", "        if (ctrl_lo(r, 3) == tail && (uint32_t)st->w[3] == tail && (uint32_t)st->w[31] == tail)",
     "        if (1)", "test_hps_lib.py", "the status read accepts a torn frame"),
    ("hps/lib/h264ring.c", "    rs->pic_x0 = (x0 & 0x1000u) ? (int)x0 - 0x2000 : (int)x0;", "    rs->pic_x0 = (int)x0;",
     "test_hps_lib.py", "(0.10) the picture's left read unsigned: a negative origin (Crop) misplaced"),
    ("hps/lib/h264ring.c", "            st->w[i] = (i < H264RING_CORE2_WORD + H264RING_CORE2_WORDS || i >= H264RING_CORE3_WORD) ? r->be.ctrl[i] : 0;",
     "            st->w[i] = (i < H264RING_CORE2_WORD + H264RING_CORE2_WORDS) ? r->be.ctrl[i] : 0;",
     "test_hps_lib.py", "(0.10) the third region (words 80-87) not copied"),
    ("hps/lib/h264ring.c", "    if (!c->max_mbs || !c->mb_rate || !c->native_h) {   /* no status frame yet: 0.10's limits */",
     "    if (0) {", "test_hps_lib.py", "(0.11) a word 81 of 0 read as a 0-macroblock limit (every stream refused)"),
    ("hps/lib/h264ring.c", "    c->max_mbs = (unsigned)H264RING_ST(st, CAP_MAX_MBS);", "    c->max_mbs = 1620;",
     "test_hps_lib.py", "(0.11) the largest picture not read from word 81 (720p refused by a program)"),
    # (0.14) Video Output as resolved (test_ring.c's "video_out" checks)
    ("hps/lib/h264ring.c", "    unsigned v = (unsigned)H264RING_ST(st, VIDEO_OUT);           /* (0.14) as resolved */",
     "    unsigned v = 0;", "test_hps_lib.py", "(0.14) word 80's video_out ignored: Auto's Native read as Progressive"),
    ("hps/lib/h264ring.c", "    return H264RING_ST(st, RASTER_IL) ? H264RING_VOUT_INTERLACED : H264RING_VOUT_PROGRESSIVE;   /* ... Auto */",
     "    return H264RING_VOUT_PROGRESSIVE;", "test_hps_lib.py", "(0.14) a 0.13 core's Auto at 480i read as Progressive"),
    # (0.13) the rumble (test_ring.c's "rumble" checks)
    ("hps/lib/h264ring.c", "            ctrl_lo_store(r, H264RING_W_RUMBLE + k, r->rum[k]);", "            ;",
     "test_hps_lib.py", "(0.13) the first session leaves an earlier program's rumble in words 36-38"),
    ("hps/lib/h264ring.c", "    if (!r->rum_taken) {", "    if (1) {",
     "test_hps_lib.py", "(0.13) every session (a flush) rewrites the rumble words (races the input thread)"),
    ("hps/lib/h264ring.c", "    unsigned k = pad / 2u, sh = 16u * (pad & 1u);", "    unsigned k = pad / 2u, sh = 16u * (1u - (pad & 1u));",
     "test_hps_lib.py", "(0.13) the two pads of a word swapped"),
    ("hps/lib/h264ring.c", "    return (x ^ 1u) ? (x ^ 1u) : 2u;", "    return x ^ 1u;",
     "test_hps_lib.py", "(0.13) the keepalive steps a motor of 1 to 0 (the pad stops)"),
    ("hps/lib/h264ring.c", "now - r->rum_at[pad] < (uint64_t)H264RING_RUMBLE_KEEPALIVE_MS * 1000u", "now - r->rum_at[pad] < 1000u",
     "test_hps_lib.py", "(0.13) the keepalive steps every millisecond, not every 10 s"),
    ("hps/lib/h264ring.c", "    if (r->rum_taken)                                 /* (0.13)", "    if (0)                                 /* (0.13)",
     "test_hps_lib.py", "(0.13) close leaves the program's rumble on"),
    ("hps/lib/h264ring.c", "    ctrl_lo_store(r, H264RING_W_SETTINGS, r->set_word);", "",
     "test_hps_lib.py", "a new session leaves the previous program's settings request in word 35 (re-applied)"),
    ("hps/lib/h264ring.c", "        r->set_seq = (uint8_t)H264RING_ST(&st, SET_SEQ);", "        ;",
     "test_hps_lib.py", "a program's first settings request numbered from 1 (repeats the last program's: ignored)"),
    ("hps/lib/h264ring.c", "    pad = n > to_end ? to_end : 0u;", "    pad = 0u;",
     "test_hps_lib.py", "a record written across the ring's end (no PAD)"),
    ("hps/lib/h264ring.c", "    return used > r->be.ring_size ? 0 : r->be.ring_size - used;",
     "    return used > r->be.ring_size ? 0 : r->be.ring_size - used + 1024u;",
     "test_hps_lib.py", "the free space overstated: the writer overruns the core's read index"),
    ("hps/lib/h264ring.c", "    if (ctrl_hi(r, 5) != r->nonce) {", "    if (0) {",
     "test_hps_lib.py", "a dropped session goes unnoticed"),
    ("hps/lib/h264ring.c", "    return new_session(r, timeout_ms);\n}\n\nint h264ring_session_ok",
     "    return 0;\n}\n\nint h264ring_session_ok",
     "test_hps_lib.py", "flush returns without starting a new session (the queue is not dropped)"),
    ("hps/lib/h264ring_au.c", "(b[i + 4] & 0x80))", "(b[i + 4] & 0x40))",
     "test_hps_lib.py", "the splitter misreads first_mb_in_slice"),
    # (fj#20) the CAVLC -> CABAC rewrite inside the write call (test_ring.c's "rewrite:" checks)
    ("hps/lib/h264ring.c", "if (r->rc_valid && r->rc_in_n == len && memcmp(r->rc_in, in, len) == 0) {",
     "if (r->rc_valid && r->rc_in_n == len) {", "test_hps_lib.py",
     "the retry cache trusts the length alone: a reused buffer's other unit served the old rewrite"),
    ("hps/lib/h264ring.c", "    r->rc_valid = 0;                                  /* and nothing rewritten before it is reused */",
     "", "test_hps_lib.py", "a flush leaves the unit rewritten before it in the cache"),
    ("hps/lib/h264ring.c", "    if (disc)\n        h264ring_cavlc_reset(r->cv);\n", "", "test_hps_lib.py",
     "a DISCONTINUITY keeps the old stream's parameter sets"),
    ("hps/lib/h264ring.c", "        payload = o;\n        len = on;\n", "", "test_hps_lib.py",
     "the rewrite done but the input written"),
    ("hps/lib/h264ring.c", "        return -EOPNOTSUPP;", "        return 0;", "test_hps_lib.py",
     "a stream the rewrite refuses written as it is"),
    # 0.9, the overlay's descriptor (test_ring.c's overlay checks through test_hps_lib.py)
    ("hps/lib/h264ring.c", "    ctrl_lo_store(r, H264RING_W_OVL_GEN_HI, g);\n    r->be.barrier(r->be.user);\n",
     "    r->be.barrier(r->be.user);\n", "test_hps_lib.py",
     "gen_hi not written first (the core would take a half-written descriptor as consistent)"),
    ("hps/lib/h264ring.c", "    ovl_write(r, r->ovl_on);                          /* (0.9) this program's overlay, or none: never a",
     "    (void)0;                          /* (0.9) this program's overlay, or none: never a",
     "test_hps_lib.py", "a new session leaves a previous program's overlay descriptor shown"),
    ("hps/lib/h264ring.c", "        end > H264RING_FB_BYTE + H264RING_FB_SIZE - o->base)",
     "        end > H264RING_FB_BYTE + H264RING_FB_SIZE - o->base + 8u)",
     "test_hps_lib.py", "the library's RANGE check lets a page run 8 bytes past the framebuffer's region"),
    ("hps/lib/h264ring.c", "            return H264RING_ST(&st, OVL_STATE) == H264RING_OVL_S_REFUSED ? -EPROTO : 0;",
     "            return 0;", "test_hps_lib.py", "overlay_wait reports a refused descriptor as read"),
    # 0.15, pictures from the program (test_ring.c's pictures / layout / copy checks, and
    # test_hps_lib.py's model of the descriptors and the store copies)
    # (2026-10-06, the rig after a cold boot) the stale misaligned write index left for the core's poll
    ("hps/lib/h264ring.c", "        if (wi & 15u)\n            ctrl_lo_store(r, H264RING_W_WRITE_INDEX, wi & ~15u);",
     "        (void)wi;", "test_hps_lib.py",
     "a cold boot's misaligned write index left in place (WIDX_ALIGN at the core's first poll: nothing plays)"),
    ("hps/lib/h264ring.c", "            ((int32_t)(emitted - r->pic_ord[c]) >= 0 && !((held >> c) & 1u))) {",
     "            (!((held >> c) & 1u))) {", "test_hps_lib.py",
     "(0.15) the store rule without pic_emitted: a store queued, not yet emitted, refilled"),
    ("hps/lib/h264ring.c", "            ((int32_t)(emitted - r->pic_ord[c]) >= 0 && !((held >> c) & 1u))) {",
     "            ((int32_t)(emitted - r->pic_ord[c]) >= 0)) {", "test_hps_lib.py",
     "(0.15) the store rule without the holds: a store on screen refilled"),
    ("hps/lib/h264ring.c", "            r->pic_ord[k] = r->pic_base + ++r->pic_sent;",
     "            r->pic_ord[k] = r->pic_base + r->pic_sent++;", "test_hps_lib.py",
     "(0.15) pictures numbered one early: a store free a picture before its emission"),
    ("hps/lib/h264ring.c", "        if (H264RING_ST(&st, STATE) != H264RING_S_READY)", "        if (0)",
     "test_hps_lib.py", "(0.15) the numbering's base taken before the stream reset was seen"),
    ("hps/lib/h264ring.c", "            r->pic_ok = 0;                /* (0.15) a coded stream: the stores are the decoder's */",
     "", "test_hps_lib.py", "(0.15) pictures written into a coded stream's stores (the decoder's)"),
    ("hps/lib/h264ring.c", "    if ((type == H264RING_T_VIDEO_AU || type == H264RING_T_PICTURE) && r->need_disc)",
     "    if (type == H264RING_T_VIDEO_AU && r->need_disc)", "test_hps_lib.py",
     "(0.15) a picture after END_OF_STREAM without DISCONTINUITY (the core refuses it)"),
    ("hps/lib/h264ring.c", "    hf = pair ? 2u * ((p->height + 31u) / 32u) : (p->height + 15u) / 16u;",
     "    hf = (p->height + 15u) / 16u;", "test_hps_lib.py",
     "(0.15) a pair's height in frame macroblocks, not whole field ones (odd: the core refuses it)"),
    ("hps/lib/h264ring.c", "    l->crop_r = (16u * w - p->width) / 2u;", "    l->crop_r = 0;",
     "test_hps_lib.py", "(0.15) the right crop dropped: the padding shown"),
    ("hps/lib/h264ring.c", "        ratio_fit(2ull * p->rate_num, p->rate_den, 32, &two_num, &nuit);",
     "        ratio_fit(p->rate_num, p->rate_den, 32, &two_num, &nuit);", "test_hps_lib.py",
     "(0.15) time_scale not twice the rate (H.264's convention): the pictures shown at half speed"),
    ("hps/lib/h264ring.c", "    my = full && !pfull ? 219u : 0u;", "    my = 0u;",
     "test_hps_lib.py", "(0.15) full-range luma not converted to limited"),
    ("hps/lib/h264ring.c", "    my = full && !pfull ? 219u : 0u;                  /* full range -> limited (16-235 / 16-240) */\n    mc = full && !pfull ? 224u : 0u;",
     "    my = full ? 219u : 0u;\n    mc = full ? 224u : 0u;",
     "test_hps_lib.py", "(0.16) a full-range picture under a full-range code converted anyway (D-C8's pass-through gone)"),
    ("hps/lib/h264ring.c", "    r->colour = code;\n", "",
     "test_hps_lib.py", "(0.16) h264ring_set_colour() ignored: every access unit auto"),
    ("hps/lib/h264ring.c", "    return try_write_c(r, H264RING_T_PICTURE, flags, pts, b, sizeof b, p->colour);",
     "    return try_write_c(r, H264RING_T_PICTURE, flags, pts, b, sizeof b, 0u);",
     "test_hps_lib.py", "(0.16) a PICTURE's colour code not in its header"),
    ("hps/lib/h264ring.c", "                unsigned r0 = pair ? 4u * (y >> 1) + (y & 1u) : 2u * y;",
     "                unsigned r0 = 2u * y;", "test_hps_lib.py",
     "(0.15) 4:2:2 chroma averaged across a pair's fields"),
    ("hps/lib/h264ring.c", "    return (((n - 1u) ^ y) & 1u) ? n - 2u : n - 1u;", "    return n - 1u;",
     "test_hps_lib.py", "(0.15) a pair's padding rows from the other field"),
    # (docs/uvc.md U2) put_row's interior loops, one per case, beside the general one at the edges
    ("hps/lib/h264ring.c", "                t[i] = m ? to_limited(c, m) : (uint8_t)c;",
     "                t[i] = m && i != 3u ? to_limited(c, m) : (uint8_t)c;", "test_hps_lib.py",
     "(uvc) the interior's full-range path leaves one sample in eight unconverted"),
    ("hps/lib/h264ring.c", "                unsigned c = b ? (a[x + i] + b[x + i] + 1u) >> 1 : a[x + i];",
     "                unsigned c = a[x + i];", "test_hps_lib.py",
     "(uvc) the interior's 4:2:2 path takes one row, not the two rows' average"),
    ("hps/lib/h264ring.c", "    return (uint8_t)(16u + ((x + 1u + (x >> 8)) >> 8));", "    return (uint8_t)(16u + (x >> 8));",
     "test_hps_lib.py", "(uvc) the range conversion's division by 255 approximated by 256"),
    ("hps/lib/h264ring.c", "    unsigned x = 0, in = sw & ~7u;", "    unsigned x = 0, in = (sw + 7u) & ~7u;",
     "test_hps_lib.py", "(uvc) the interior loops run past the source's last sample (the edge not replicated)"),
]


def copy_tools(d, root):
    """tools/ copied (the mutation target), the RTL and the benches beside it as symlinks:
    the tests that compare the model with the RTL's tables (test_h264_fe_ref:
    h264/dec/*.mem) find them at ../h264 from the copy, as in the tree. UMD linked only
    its RTL at first and a control copy could not pass (its "Fixes exchanged": red_umd.py
    links every directory a test reads -- here h264/, bench/ and hps/: test_ring_model's
    --check reads the generated headers in h264/ and hps/include/)."""
    shutil.copytree(TOOLS, root, ignore=shutil.ignore_patterns("__pycache__"))
    for sub in ("h264", "bench"):
        os.symlink(os.path.join(os.path.dirname(TOOLS), sub), os.path.join(d, sub))
    # hps/ is COPIED (without its build): its mutations edit it, and its test builds inside it
    shutil.copytree(os.path.join(os.path.dirname(TOOLS), "hps"), os.path.join(d, "hps"),
                    ignore=shutil.ignore_patterns("build"))


def run(test, root):
    r = subprocess.run([sys.executable, os.path.join(root, "tests", test)],
                       capture_output=True, text=True)
    return r.returncode == 0 and "ALL GREEN" in r.stdout


def skipped(test, root):
    """the arm that would catch a mutation is missing its tool or reference set"""
    r = subprocess.run([sys.executable, os.path.join(root, "tests", test)],
                       capture_output=True, text=True)
    return "SKIP:" in r.stdout


def main():
    fails = 0
    for tool, anchor, repl, test, what in MUTATIONS:
        with tempfile.TemporaryDirectory() as d:
            root = os.path.join(d, "tools")
            copy_tools(d, root)
            path = os.path.join(d, tool) if tool.startswith("hps/") else os.path.join(root, tool)
            src = open(path).read()
            n = src.count(anchor)
            if n != 1:
                print("HARNESS FAIL %s: anchor found %d times: %r" % (tool, n, anchor))
                fails += 1
                continue
            open(path, "w").write(src.replace(anchor, repl))
            if not run(test, root):
                print("RED ok   %-22s caught by %-26s (%s)" % (tool, test, what))
            elif skipped(test, root):
                print("RED skip %-22s %s SKIPs an arm (tool or refs missing) (%s)" % (tool, test, what))
            else:
                print("RED FAIL %-22s NOT caught by %s (%s)" % (tool, test, what))
                fails += 1
    # the unmutated copy must still be green, or every "caught" above is meaningless
    with tempfile.TemporaryDirectory() as d:
        root = os.path.join(d, "tools")
        copy_tools(d, root)
        ctl = [t for _, _, _, t, _ in MUTATIONS if not run(t, root)]
        if ctl:
            print("CONTROL FAIL: unmutated copy fails %s" % ctl)
            fails += 1
        else:
            print("control  unmutated copy: every test green")
    print("red_h264: %s" % ("ALL GREEN" if not fails else "%d FAILURE(S)" % fails))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
