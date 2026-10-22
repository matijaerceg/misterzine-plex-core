#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""mutations.py -- run_test.sh --red's mutations of the file player, each with the check that must
catch it (check_player.py's label, a fixed string).

  mutations.py list                 the names, one a line
  mutations.py label NAME           the check that must go RED
  mutations.py apply NAME ROOT      edit ROOT (a COPY holding src/ = clients/player/src and
                                    common/ = clients/common); exit 1 unless every replacement
                                    applied exactly once
"""
import os
import sys

# name: (file under ROOT, [(old, new), ...], the check's label)
MUTATIONS = {
    # a 25 frames/s file never asks for 50 Hz
    "M1_no_50hz": ("src/main.c", [
        ("    return (fps > 24.5 && fps < 25.5) || (fps > 49.5 && fps < 50.5) ? 3u : 0u;",
         "    (void)fps;\n    return 0u;"),
    ], "(r1) Refresh Rate 50 Hz asked for before each 25 frames/s file starts (b_pal, inner)"),
    # Auto never given back for a file of another rate
    "M2_no_auto_back": ("src/main.c", [
        ("    if (want != cur && settings(a, want) == 0) a->refresh_ours = want == 3;",
         "    if (want == 3 && want != cur && settings(a, want) == 0) a->refresh_ours = 1;"),
    ], "(r2) Refresh Rate Auto given back: before c_ok, and at the end (the mirror Auto)"),
    # ... nor when the player ends
    "M3_no_restore": ("src/main.c", [
        ("        close_player(a);\n        restore_refresh(a);\n", "        close_player(a);\n"),
    ], "(r2) Refresh Rate Auto given back: before c_ok, and at the end (the mirror Auto)"),
    # a file's end goes back to the list (the folder does not play on)
    "M4_no_advance": ("src/main.c", [
        ("        else step_file(a, 1);                         /* the folder plays on */",
         "        else stop_playing(a);"),
    ], "(c) the folder plays on: c_ok follows b_pal by itself"),
    # h264check never says SIZE: the 1344x720 file reaches the core
    "M5_size": ("common/h264check.c", [
        ("    if (mbs > (s->max_mbs ? s->max_mbs : MAX_MBS)) return H264C_SIZE;\n", ""),
    ], "(e) refused: a CAVLC 1344x720 (its size, CAVLC checked last), 720p60 (too fast), FFV1 (not decoded), MPEG-4 1280x720 (over SD) -- none reached the core, each reason named"),
    # the file's text subtitle tracks discarded (no cues)
    "M6_no_text_subs": ("src/main.c", [
        (".hold = 1, .text_subs = 1,", ".hold = 1, .text_subs = 0,"),
    ], "(s1) the file's default SRT track on screen in its time (The first cue, 0.5 - 2.5 s)"),
    # an ASS event taken as plain text (the event's fields shown, \N kept)
    "M7_ass_raw": ("common/player.c", [
        ("if (r->type == SUBTITLE_ASS && r->ass) subs_add(p->subs[k], a, b, r->ass, 1);",
         "if (r->type == SUBTITLE_ASS && r->ass) subs_add(p->subs[k], a, b, r->ass, 0);"),
    ], "(s2) X: the ASS track's cue as plain text in its time (3.0 - 5.5 s), no event fields or drawing"),
    # hidden files listed (".hidden.mkv" sorts first among the files)
    "M8_hidden": ("src/browse.c", [
        ("        if (de->d_name[0] == '.') continue;",
         "        if (!strcmp(de->d_name, \".\") || !strcmp(de->d_name, \"..\")) continue;"),
    ], "(b) the list: the first file played is the folder's first video (b_pal)"),
    # the forward step a third of what it says
    "M9_seek_step": ("src/main.c", [
        ("    case ACT_FWD: seek_step(a, 30); break;", "    case ACT_FWD: seek_step(a, 10); break;"),
    ], "(g) the seek: RIGHT -> one new session, an IDR at the position + 30 s (within a GOP)"),
    # a folder's entry opens nothing (OK on a folder ignored)
    "M10_no_enter": ("src/main.c", [
        ("            open_folder(a, next, NULL);\n            state_save(a);\n            return;",
         "            (void)next;\n            return;"),
    ], "(f) a folder entered: the ninth file played is a_dir/inner.mkv"),
    # the screensaver's first stage never comes (straight to black, or nothing)
    "M11_saver_no_dim": ("common/ui.c", [
        ("    if (u->dim_ms && idle >= u->dim_ms) return 1;\n", ""),
    ], "(z1) the screensaver: the list left alone dims at 3.6 s and goes black at 7.2 s, never before"),
    # (0.12) the canvas's rows a fixed 2,048 pixels apart (stage B's first try): a 1280x720 HDMI mode's
    # framebuffer then holds two pages of 450 lines -- the rasters' 480 / 576 drawn short
    "M20_fixed_stride": ("common/ui.c", [
        ("    unsigned stride = (w + 3u) & ~3u;", "    unsigned stride = H264RING_OVL_MAX_W;"),
    ], "T8 every canvas the raster's lines, or all two pages of it fit (Main's HDMI mode's framebuffer)"),
    # the pages spaced for the tallest canvas the interface allows, not the one drawn: page 1 past the
    # end of a 1280x720 mode's framebuffer
    "M21_page_spacing": ("common/ui.c", [
        ("        u->page_bytes = (size_t)stride * 2u * lines;", "        u->page_bytes = (size_t)stride * 2u * H264RING_OVL_MAX_H;"),
    ], "T9 every canvas inside the framebuffer Main gives (/dev/fb0's smem_len)"),
    # the press that wakes the screensaver also acts
    "M12_wake_acts": ("src/main.c", [
        ("            if (ui_wake(a->ui)) {                     /* the press only wakes the screensaver (P5) */",
         "            if (ui_wake(a->ui) && 0) {                /* the press only wakes the screensaver (P5) */"),
    ], "(z2) a press only wakes the screensaver: the veil goes, the selection stays (no file played)"),
    # playing never counts as busy: the saver dims a playing film
    "M13_never_busy": ("src/main.c", [
        ("        ui_busy(a->ui, a->playing && !a->paused);", "        ui_busy(a->ui, 0);"),
    ], "(z1) the screensaver: the list left alone dims at 3.6 s and goes black at 7.2 s, never before"),
    # the canvas 720 wide whatever the raster (the width ignored, as before 0.10)
    "M16_canvas_720": ("src/main.c", [
        ("    return rs.w ? rs.w : 720u;\n", "    (void)rs;\n    return 720u;\n"),
    ], "T7 the overlay drawn for the raster's width (852 native, 720 fitted: word 80)"),
    # a step writes until its packet count again, whatever the time (the loop held by slow writes)
    "M17_no_budget": ("common/player.c", [
        ("        if (k && mono_ms() - t_step >= STEP_BUDGET_MS) return p->state;   /* the loop's turn */\n",
         "        (void)t_step;\n"),
    ], "(w) slow writes (the A9's CAVLC rewrite): the player's loop never stalls over 0.25 s (the pad read)"),
    # CAVLC refused again (the player not letting the library rewrite it)
    "M14_no_cavlc": ("src/main.c", [
        (".text_subs = 1, .cavlc_ok = 1,", ".text_subs = 1, .cavlc_ok = 0,"),
    ], "(v) the CAVLC file plays: the core read CABAC (every PPS), decoding to the file's own pictures"),
    # h264check says CAVLC before the size again: a CAVLC 1344x720 file let through to the core
    "M15_cavlc_first": ("common/h264check.c", [
        ("    if (s->bit_depth_luma != 8 || s->bit_depth_chroma != 8) return H264C_BITDEPTH;\n",
         "    if (s->bit_depth_luma != 8 || s->bit_depth_chroma != 8) return H264C_BITDEPTH;\n"
         "    if (!s->entropy) return H264C_CAVLC;\n"),
    ], "(e) refused: a CAVLC 1344x720 (its size, CAVLC checked last), 720p60 (too fast), FFV1 (not decoded), MPEG-4 1280x720 (over SD) -- none reached the core, each reason named"),
    # (0.11) no rate check: a 720p60 file reaches the core (decoded at half speed)
    "M18_no_rate": ("common/h264check.c", [
        ("    if (s->fps > 0 && (double)mbs * s->fps > 1.01 * (s->mb_rate ? s->mb_rate : MB_RATE)) return H264C_RATE;\n", ""),
    ], "(e) refused: a CAVLC 1344x720 (its size, CAVLC checked last), 720p60 (too fast), FFV1 (not decoded), MPEG-4 1280x720 (over SD) -- none reached the core, each reason named"),
    # (0.11) the player's limits not from the core (0.10's 1,620 fixed): g_fast refused by its size,
    # not named "too fast" (and every 720p file refused)
    "M19_caps_ignored": ("common/player.c", [
        ("    p->chk.max_mbs = cfg->max_mbs;\n", "    p->chk.max_mbs = 1620;\n"),
    ], "(e) refused: a CAVLC 1344x720 (its size, CAVLC checked last), 720p60 (too fast), FFV1 (not decoded), MPEG-4 1280x720 (over SD) -- none reached the core, each reason named"),
    # (0.15) other codecs decoded on the ARM, sent as pictures (docs/player.md "Other codecs")
    # the player not asking for it: f_mpeg4 refused again
    "M22_no_arm_video": ("src/main.c", [
        ("        .arm_video = 1,", "        .arm_video = 0,"),
    ], "(p1) f_mpeg4 decoded on the ARM: every picture as ffmpeg decodes it, with its PTS, frames, the last with END_OF_STREAM"),
    # an interlaced picture sent as a frame (no deinterlace, no field order)
    "M23_pair_as_frame": ("common/player.c", [
        ("    if (f->flags & AV_FRAME_FLAG_INTERLACED)", "    if (0)"),
    ], "(p2) h_mpeg2i (interlaced MPEG-2): every picture a woven field pair, top first, as ffmpeg decodes it"),
    # (0.16) MJPEG's full range not tagged full: converted on the ARM and sent as limited (the copy's old path)
    # -- 0.15's M24 (yuvj422p taken as yuv422p) is now equivalent: the frame's own color_range promotes it back
    "M24_full_untagged": ("common/vdec.c", [
        ("    unsigned full = fmt == H264RING_PIX_YUVJ420P || fmt == H264RING_PIX_YUVJ422P;", "    unsigned full = 0;"),
    ], "(p3) i_mjpeg (4:2:2 full range): every picture 4:2:0, its full range kept and tagged BT.601 full (0.16)"),
    # the SD budget gone: an HD MPEG-4 decoded on the ARM (behind, every picture late)
    "M25_no_sd_budget": ("common/vdec.c", [
        ("    if (par->width > SD_W || par->height > SD_H) {", "    if (0) {"),
    ], "(e) refused: a CAVLC 1344x720 (its size, CAVLC checked last), 720p60 (too fast), FFV1 (not decoded), MPEG-4 1280x720 (over SD) -- none reached the core, each reason named"),
    # the last picture without END_OF_STREAM (the stream never ends on the core)
    "M26_last_no_eos": ("common/player.c", [
        ("last ? H264RING_F_END_OF_STREAM : 0u);", "0u);"),
    ], "(p1) f_mpeg4 decoded on the ARM: every picture as ffmpeg decodes it, with its PTS, frames, the last with END_OF_STREAM"),
    # stores taken in turn without the store rule (the library's acquire skipped)
    "M27_no_acquire": ("common/player.c", [
        ("        int rc = h264ring_picture_acquire(r, &k);",
         "        k = (unsigned)(p->n.pictures % H264RING_DPB_STORES); int rc = 0;"),
    ], "T10 (0.15) the store rule: pictures sent, none into a store the display held (queued or shown)"),
    # every picture's PTS dropped (the core paces them from the rate alone: the audio drifts)
    "M28_no_pic_pts": ("common/player.c", [
        ("t >= 0 ? (t & (int64_t)PTS_MASK) : -1,\n                                        last ?",
         "-1,\n                                        last ?"),
    ], "(p1) f_mpeg4 decoded on the ARM: every picture as ffmpeg decodes it, with its PTS, frames, the last with END_OF_STREAM"),
    # swr built once, for the layout the decoder reports at open (dca's stereo under `downmix`, its frames
    # 5.1): the center and the surrounds dropped (2026-10-06, a Blu-ray rip's DTS without dialogue)
    "M29_swr_at_open": ("common/player.c", [
        ("        if (swr_for(p, &fr->ch_layout, fr->format, fr->sample_rate) < 0) { av_frame_unref(fr); continue; }\n",
         ""),
        ("    return avcodec_open2(p->adec, dec, NULL);\n",
         "    if ((rc = avcodec_open2(p->adec, dec, NULL)) < 0) return rc;\n"
         "    return swr_for(p, &p->adec->ch_layout, p->adec->sample_fmt, p->adec->sample_rate);\n"),
    ], "(p4) f_mpeg4's DTS 5.1 downmixed with its center (a center-only tone in both sides, at ffmpeg's level)"),
    # (docs/jellyfin.md S12) the audio written in the demuxer's order again: never held for the video
    "M30_interleave": ("common/player.c", [
        ("        int ok = p->started && (t < 0 || p->vmax < 0 || t <= p->vmax + AUD_LEAD);\n",
         "        int ok = 1;\n"),
    ], "(x) l_ahead (audio 6.5 s ahead in the file): no AUDIO record over 1.3 s ahead of the video before it, "
       "every AU, the audio whole"),
    # (S12) an audio stream the probe missed passed over again (av_find_best_stream's choice alone)
    "M31_probe_pick": ("common/player.c", [
        ("    for (unsigned i = 0; p->as < 0 && i < p->fmt->nb_streams; i++) {",
         "    for (unsigned i = 0; 0 && i < p->fmt->nb_streams; i++) {"),
    ], "(y) m_late (its audio past the probe): AUDIO records with PTS, the PCM equal to a reference decode"),
    # (S12) swr built at the open again, from the probe's parameters (none: the audio refused)
    "M32_swr_open": ("common/player.c", [
        ("    return avcodec_open2(p->adec, dec, NULL);\n",
         "    if ((rc = avcodec_open2(p->adec, dec, NULL)) < 0) return rc;\n"
         "    return swr_for(p, &p->adec->ch_layout, p->adec->sample_fmt, p->adec->sample_rate);\n"),
    ], "(y) m_late (its audio past the probe): AUDIO records with PTS, the PCM equal to a reference decode"),
    # (S12) a frame without a time sent untimed (no carry from the frame before)
    "M33_apts_carry": ("common/player.c", [
        ("        int64_t fpts = ft == AV_NOPTS_VALUE ? p->apts_next\n", "        int64_t fpts = ft == AV_NOPTS_VALUE ? -1\n"),
    ], "(y) m_late (its audio past the probe): AUDIO records with PTS, the PCM equal to a reference decode"),
}


def main(argv):
    if len(argv) == 2 and argv[1] == "list":
        print("\n".join(MUTATIONS))
        return 0
    if len(argv) == 3 and argv[1] == "label":
        print(MUTATIONS[argv[2]][2])
        return 0
    if len(argv) == 4 and argv[1] == "apply":
        fn, edits, _ = MUTATIONS[argv[2]]
        path = os.path.join(argv[3], fn)
        s = open(path).read()
        for old, new in edits:
            if s.count(old) != 1:
                print("mutations: %s: %r found %d times (not exactly once)" % (argv[2], old[:60], s.count(old)))
                return 1
            s = s.replace(old, new)
        open(path, "w").write(s)
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
