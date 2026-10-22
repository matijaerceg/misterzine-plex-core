#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""mutations.py -- run_test.sh --red's mutations of the Jellyfin client, each with the check that
must catch it (check_client.py's label, a fixed string).

  mutations.py list                 the names, one a line
  mutations.py label NAME           the check that must go RED
  mutations.py apply NAME ROOT      edit ROOT (a COPY holding src/ = clients/jellyfin/src and
                                    common/ = clients/common); exit 1 unless every replacement
                                    applied exactly once
"""
import os
import sys

# name: (file under ROOT, [(old, new), ...], the check's label)
MUTATIONS = {
    # the position from the demuxer (the last access unit written), not the STC
    "M1_position": ("common/player.c", [
        ("    int64_t first_pts;", "    int64_t first_pts, last_written;"),
        ("    av_packet_free(&p->out);\n    if (!rc) p->n.video_aus++;",
         "    p->last_written = t;\n    av_packet_free(&p->out);\n    if (!rc) p->n.video_aus++;"),
        ("return (double)(stc & PTS_MASK) / 90000.0 - origin;",
         "return (double)((uint64_t)p->last_written & PTS_MASK) / 90000.0 - origin;"),
    ], "(h) every report's position is the fake core's STC (within 0.6 s), at least 4 while it ran"),
    # h264check never says CAVLC
    "M2_cavlc": ("common/h264check.c", [
        ("    if (!s->entropy) return H264C_CAVLC;\n", ""),
    ], "(j) the CAVLC file: PlaybackInfo again with direct play and stream copy off; none of its AUs consumed"),
    # a seek without core_new_stream: no flush, no new session (since the held seek, the seek's flush
    # is the one at the held stream's release, PL_READY)
    "M3_seek_flush": ("src/main.c", [
        ("    if (s == PL_READY) {                        /* the new stream's IDR is ready: now the flush */\n"
         "        core_new_stream(&a->core);\n",
         "    if (s == PL_READY) {                        /* the new stream's IDR is ready: now the flush */\n"),
    ], "(g) the seek: a new session, its first record an IDR with SPS / PPS at or before 6 s (within a GOP)"),
    # the pause never written to word 34
    "M4_pause": ("src/main.c", [
        ("    if (!a->held) h264ring_set_pause(a->core.r, p);", "    (void)p;"),
    ], "(f) the pause: word 34's PAUSE set after Pause, cleared after Unpause"),
    # no KeepAlive on ForceKeepAlive (the 30 s timer only)
    "M5_keepalive": ("src/main.c", [
        ("{ a->jf.ws_tx_ms = 0; jf_ws_keepalive(&a->jf); return; }", "{ return; }"),
    ], "(c) ForceKeepAlive answered by a KeepAlive within 2 s (masked frames)"),
    # the direct-play band keyed on the height again (R1's finding undone)
    "M6_band_height": ("src/profile.c", [
        ('\\"Property\\":\\"Wi" \\\n    "dth\\",\\"Value\\":\\"721\\"',
         '\\"Property\\":\\"He" \\\n    "ight\\",\\"Value\\":\\"481\\"'),
    ], "(b) capabilities: Video, SupportsMediaControl, every band keyed on Width (never Height)"),
    # (0.11) the 720p transcode box asked for on every output (the fitted rasters show 720 wide)
    "M6b_hd_always": ("src/main.c", [
        ("    return h264ring_video_out(&a->core.st) == H264RING_VOUT_NATIVE && caps.native_h >= 720;   /* (0.14) as resolved: Auto can be Native */",
         "    return 1;"),
    ], "(b') the profile: direct play to 1280x720, a band above 30 frames/s inside 864x480, the box 854x480"),
    # (0.12) the 720p box on any output once the core's native raster reaches 720 (the fitted rasters
    # show 720 wide): Video Output's Native no longer asked
    "M6d_hd_any_output": ("src/main.c", [
        ("    return h264ring_video_out(&a->core.st) == H264RING_VOUT_NATIVE && caps.native_h >= 720;   /* (0.14) as resolved: Auto can be Native */",
         "    return caps.native_h >= 720;"),
    ], "(b') the profile: direct play to 1280x720, a band above 30 frames/s inside 864x480, the box 854x480"),
    # (0.12) the HD profile never handed out (the SD one in its place)
    "M6e_hd_profile": ("src/profile.c", [
        ("    return hd ? profile_hd : profile_sd;", "    return profile_sd;"),
    ], "(b'') the HD profile (Native, cap_native_h >= 720): the box 1280x720, direct play to 1280x720"),
    # (0.11) the fast band keyed on the width alone: a 720p60 source direct-plays at twice the rate
    "M6c_fast_band": ("src/profile.c", [
        (',{\\"Condit" \\\n    "ion\\":\\"GreaterThanEqual\\",\\"Property\\":\\"VideoFramerate\\",\\"Value\\":\\"30.5\\"}', ''),
    ], "(b') the profile: direct play to 1280x720, a band above 30 frames/s inside 864x480, the box 854x480"),
    # audio records without their PTS
    "M7_audio_pts": ("common/player.c", [
        ("p->aout_pts >= 0 ? (p->aout_pts & (int64_t)PTS_MASK) : -1);", "-1);"),
    ], "(e) item A's audio: AUDIO records with PTS, the PCM equal to a reference decode"),
    # the overlay's flip waits for an EQUAL generation (the old bug: a session start's newer one never matches)
    "M8_ovl_equal": ("common/ui.c", [
        ("if ((int32_t)((uint32_t)H264RING_ST(&st, OVL_GEN) - (uint32_t)u->pending_gen) < 0) return;",
         "if ((uint32_t)H264RING_ST(&st, OVL_GEN) != (uint32_t)u->pending_gen) return;"),
    ], "(l) the overlay: page flips after the seek's session started (the generation rule \"at least\")"),
    # Quick Connect's Initiate by GET (gone in 12.0)
    "M9_qc_get": ("src/jf.c", [
        ('jf_request(j, "POST", "/QuickConnect/Initiate"', 'jf_request(j, "GET", "/QuickConnect/Initiate"'),
    ], "(a) Quick Connect: Initiate by POST, polled, then the token in every request's MediaBrowser header"),
    # the last access unit without END_OF_STREAM
    "M10_no_eos": ("common/player.c", [
        ("p->out_flags = H264RING_F_END_OF_STREAM;", "p->out_flags = 0;"),
    ], "(k) the transcode: every AU as the playlist's, the last with END_OF_STREAM, Stopped near the runtime"),
    # a text subtitle track restarts the stream again (start_item for every switch)
    "M11_subs_restart": ("src/main.c", [
        ("    if (!a->st.sub_burned) {\n        if (idx < 0) {", "    if (0) {\n        if (idx < 0) {"),
    ], "(n) subtitles off and on again: no new session, the .srt fetched again, no Stopped"),
    # each pad / keyboard seek step seeks at once (no adding up, no settle)
    "M12_seek_now": ("src/main.c", [
        ("    a->seek_due = now_ms() + SEEK_SETTLE_MS;\n    show_now(a);\n    ui_panel(a->ui, PANEL_MS);\n}",
         "    seek_to(a, a->seek_target);\n}"),
    ], "(o) the pad: three RIGHT taps -> ONE seek of +90 s; RIGHT held 1.2 s -> ONE seek of >= 3 steps"),
    # a held seek button does not repeat (the repeat never armed)
    "M13_no_repeat": ("common/input.c", [
        ("else if (down & SEEK_BUTTONS) *repeat_ms = t + REPEAT_FIRST_MS;",
         "else if (down & SEEK_BUTTONS) *repeat_ms = 0;"),
    ], "(o) the pad: three RIGHT taps -> ONE seek of +90 s; RIGHT held 1.2 s -> ONE seek of >= 3 steps"),
    # the held seek undone: open_stream flushes at once (the screen black for the whole open)
    "M14_no_hold": ("src/main.c", [
        ("static int open_stream(struct app *a, double start, int keep)\n{\n    close_player(a);",
         "static int open_stream(struct app *a, double start, int keep)\n{\n    keep = 0;\n    close_player(a);"),
    ], "(p) the held seek: PAUSE at once and held through the slow open, then the flush and the IDR within 300 ms"),
    # the transcode's playlist opened whole (no trim): segment 0 probed, then a seek
    "M15_no_trim": ("src/main.c", [
        (".hls_trim = a->st.transcode,", ".hls_trim = 0,"),
    ], "(q) the transcode's seek: the trimmed playlist -- the target's segment first, its IDR first"),
    # (0.10, A') the canvas's lines from raster_std again, not word 80
    "M16_raster_lines": ("src/main.c", [
        ("    if (rs.h) return rs.h;\n", ""),
    ], "T8 the overlay drawn for the raster the core reports (word 80's lines, word 47's shape)"),
    # (0.10, A') the raster's shape guessed (4:3), not word 47 -- F9's squish back under A'
    "M17_raster_aspect": ("src/main.c", [
        ("    return rs.aspect;\n", "    return 4.0 / 3.0;\n"),
    ], "T8 the overlay drawn for the raster the core reports (word 80's lines, word 47's shape)"),
    # the subtitle URL's start kept: a track asked for at 6 s comes back rebased to 0
    "M18_sub_start": ("src/jf.c", [
        ("                whole_track(s->sub_url);\n", ""),
    ], "(u) every .srt asked for from 0 (the whole track, its own times), also after a switch at 6 s+"),
    # the subtitles fetched on the loop's thread again (the fetcher never started)
    "M19_sub_sync": ("src/main.c", [
        ("    if (fetcher_start(&a.fx, &a.jf)) fprintf(", "    if ((0)) fprintf("),
    ], "(r) a slow subtitle answer: the client's loop never stalls over 0.25 s while it waits"),
    # (0.16, docs/colour.md R4) a transcode trusted to its BT.709 label (no override): the source's ColorSpace ignored
    "M20_colour_source": ("src/jf.c", [
        ("                    s->colour = jf_source_colour(str(st2, \"ColorSpace\"), w, h);\n",
         "                    s->colour = 0;\n"),
    ], "(k2) the colour: the transcode's access units carry its source's BT.709 (3), direct play auto (0)"),
    # (0.16) the source's tag ignored, the size rule alone
    "M21_colour_size_only": ("src/jf.c", [
        ("    if (cs && (!strcmp(cs, \"bt709\") || !strcmp(cs, \"smpte240m\"))) return H264RING_COLOUR_709;\n", ""),
    ], "(k2) the colour: the transcode's access units carry its source's BT.709 (3), direct play auto (0)"),
    # (docs/jellyfin.md S12) the audio written in the demuxer's order again: never held for the video
    "M22_interleave": ("common/player.c", [
        ("        int ok = p->started && (t < 0 || p->vmax < 0 || t <= p->vmax + AUD_LEAD);\n",
         "        int ok = 1;\n"),
    ], "(v) item D (audio 6 s ahead in the stream): no AUDIO record over 1.3 s ahead of the video before it, "
       "played to its end"),
    # (S12) an audio stream the probe missed passed over again (av_find_best_stream's choice alone)
    "M23_probe_pick": ("common/player.c", [
        ("    for (unsigned i = 0; p->as < 0 && i < p->fmt->nb_streams; i++) {",
         "    for (unsigned i = 0; 0 && i < p->fmt->nb_streams; i++) {"),
    ], "(w) item D (its audio past the probe): AUDIO records with PTS, the PCM equal to a reference decode"),
    # (S12) swr built at the open again, from the probe's parameters (none: the audio refused)
    "M24_swr_open": ("common/player.c", [
        ("    return avcodec_open2(p->adec, dec, NULL);\n",
         "    if ((rc = avcodec_open2(p->adec, dec, NULL)) < 0) return rc;\n"
         "    return swr_for(p, &p->adec->ch_layout, p->adec->sample_fmt, p->adec->sample_rate);\n"),
    ], "(w) item D (its audio past the probe): AUDIO records with PTS, the PCM equal to a reference decode"),
    # (S12) a frame without a time sent untimed (no carry from the frame before)
    "M25_apts_carry": ("common/player.c", [
        ("        int64_t fpts = ft == AV_NOPTS_VALUE ? p->apts_next\n", "        int64_t fpts = ft == AV_NOPTS_VALUE ? -1\n"),
    ], "(w) item D (its audio past the probe): AUDIO records with PTS, the PCM equal to a reference decode"),
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
