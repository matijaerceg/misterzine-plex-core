# h264/h264.sdc -- the core's timing exceptions (the framework's live in sys/sys_top.sdc,
# which keeps the core PLL's clocks in one group: their transfers are timed).
#
# Harvested from MiSTer_UMD_Video's umd/umd.sdc at cc595c6 (docs/harvest.md): the
# decoder's and the display's bounds; UMD's vbuf handshake lines dropped (no vbuf here).
# Phase 3 added the HPS interface's reader (ring_rd) and the status block's indexed
# snapshots (cdc_snap_ix), bounded below the same way.
#
# Every transfer between two of the core's clocks goes through a crossing primitive: a
# two-flop synchroniser, a gray-coded fifo_dc pointer, or a quasi-static value captured
# by protocol (docs/architecture.md, the crossings table). Timed as same-group transfers
# they get the tightest edge pair of the two clocks. Since P5b the three share a 1,350 MHz
# VCO (27 = / 50, 90 = / 15, clk_dec 96.43 = / 14; / 13 = 103.85 on main 2026-09-30 until the
# macroblock pipeline): the pairs are gcd(divisors) VCO cycles apart at worst -- 1.48 ns for
# clk_dec / clk_sys (gcd(14, 50) = 2; 0.74 ns at / 13; 12.3 ns at 81 = 3 x 27 MHz, which is how the two
# synchronisers below went unbounded until the first 96.43 MHz fit reported them at -2.5 /
# -1.6 ns), 3.7 ns for clk_sys / clk_mem (27 / 90 MHz: the display's line requests) and
# 0.74 ns for clk_dec / clk_mem (gcd(14, 15) = 1: the reconstruction's DPB client,
# dpb_mem's three fifo_dc).
# These bound the capture stages to 8 ns instead -- under every period involved, so a
# gray pointer's bits still arrive within one destination cycle of each other.

# (hd_raster, 2026-10-03) The crossings with clk_vid -- disp_reader's and ovl_plane's command,
# done and descriptor handshakes with clk_mem, the raster bundle and its return (cdc_snap), the
# frame pulses (cdc_pulse) and frame0's tag -- are bounded at 12 ns, not 8: clk_vid comes from a
# second PLL, and set_max_delay counts the clock skew between the two PLLs' compensated outputs
# (~3 ns on the first fit: 5 ns of data failed 8). Every capture these protect is two or more
# destination cycles after its qualifier crossed (>= 22 ns at 90 MHz), and none is a gray pointer
# (fifo_dc's stay 8 ns, inside sys_pll), so 12 ns keeps the same margin the 8 ns had.

# Each bound names its SOURCE too: a bare "-to" also applied to the capture flops' reset
# recovery (a 37 ns clk_sys reset path became an 8 ns one, 2026-09-24).

# fifo_dc: the other side's gray pointer, first synchroniser stage (patterns end in *:
# the fitter duplicates registers, "...[5]~_Duplicate_1")
set_max_delay -from [get_keepers {*fifo_dc:*|wgray*}] -to [get_keepers {*fifo_dc:*|rq1_wgray*}] 8.000
set_max_delay -from [get_keepers {*fifo_dc:*|rgray*}] -to [get_keepers {*fifo_dc:*|wq1_rgray*}] 8.000
# dpb_mem's wr_drained (feature/mb-pipeline): the write bursts completed (clk_mem), a gray code,
# into clk_dec through two flops -- the same bound as the FIFOs' pointers
set_max_delay -from [get_keepers {*dpb_mem:*|wl_g*}] -to [get_keepers {*dpb_mem:*|wl_s1*}] 8.000

# disp_reader: the command toggle's first stage, and the command / picture / fit fields
# captured when the toggle has crossed (set with it, a line's worth of mclk cycles before
# the next command can change them; the picture and the fit change at a pickup). Sources:
# disp_reader's command registers, and (hd_raster) the shown picture and the fit as the raster
# bundle's clk_vid copies (raster_dn_xing's dst_data: disp_ctl's sh_*, disp_fit's factors).
# (6d) m_hpf / m_vpf, the Area pre-filter's factors, are captured with m_dh / m_dv (named here 2026-10-05:
# omitted with PR fj#32, they were timed as a 90 / 81 MHz cross-PLL transfer, -7.2 ns -- never a real path).
# And back: the done toggle's first stage (P6 step 3: fetch_late).
set_max_delay -from [get_keepers {*disp_reader:*|cmd_tog*}] -to [get_keepers {*disp_reader:*|m_tog[0]*}] 12.000
# (docs/chroma.md §3) the command's chroma rows (ccmd_* -> m_cn / m_crow / m_cslot) cross with it, the same way
set_max_delay -from [get_keepers {*disp_reader:*|cmd_* *disp_reader:*|ccmd_* *raster_dn_xing|dst_data*}] \
              -to [get_keepers {*disp_reader:*|m_store* *disp_reader:*|m_w[* *disp_reader:*|m_hf* *disp_reader:*|m_field* *disp_reader:*|m_valid* *disp_reader:*|m_first* *disp_reader:*|m_par* *disp_reader:*|m_dh* *disp_reader:*|m_dv* *disp_reader:*|m_hpf* *disp_reader:*|m_vpf* *disp_reader:*|m_slide* *disp_reader:*|m_n* *disp_reader:*|m_row* *disp_reader:*|m_slot* *disp_reader:*|m_cn* *disp_reader:*|m_crow* *disp_reader:*|m_cslot* *disp_reader:*|fc_* *disp_reader:*|fetch_changes*}] 12.000
set_max_delay -from [get_keepers {*disp_reader:*|done_tog*}] -to [get_keepers {*disp_reader:*|cmd_done_s1*}] 12.000

# cdc_snap (h264/cdc.sv): the handshake's two synchroniser first stages, and the copy of the
# latched bus -- hold is two or more destination cycles old when dst_data takes it (ack
# changed in the same source edge and crossed two flops). The instances copy into clk_sys
# (37 ns) or, since hd_raster, clk_vid (12.3 ns: raster_dn_xing, the raster bundle) -- 8 ns is
# under both; the clk_mem ones were timed on the 3.7 ns 90 / 27 MHz edge window
# the handshake never uses (-0.28 ns on the P5f fit, 2026-09-27: d1 / d2 / ft_snap).
set_max_delay -from [get_keepers {*cdc_snap:*|hold*}] -to [get_keepers {*cdc_snap:*|dst_data*}] 12.000
set_max_delay -from [get_keepers {*cdc_snap:*|ack*}]  -to [get_keepers {*cdc_snap:*|d_q1*}]     12.000
set_max_delay -from [get_keepers {*cdc_snap:*|req*}]  -to [get_keepers {*cdc_snap:*|s_q1*}]     12.000

# cdc_snap_ix (h264/cdc.sv, the status block's clk_mem / clk_dec words into clk_sys): as
# cdc_snap, plus the index -- the destination's register, read by the source's mux into
# hold once req has crossed two flops (stable since before the flip)
set_max_delay -from [get_keepers {*cdc_snap_ix:*|hold*}] -to [get_keepers {*cdc_snap_ix:*|dst_data*}] 8.000
set_max_delay -from [get_keepers {*cdc_snap_ix:*|ack*}]  -to [get_keepers {*cdc_snap_ix:*|d_q1*}]     8.000
set_max_delay -from [get_keepers {*cdc_snap_ix:*|req*}]  -to [get_keepers {*cdc_snap_ix:*|s_q1*}]     8.000
set_max_delay -from [get_keepers {*cdc_snap_ix:*|ix_q*}] -to [get_keepers {*cdc_snap_ix:*|hold*}]     8.000

# ring_rd (h264/ring_rd.sv): the clear handshake's two requests' first stages, the engine's
# error flag's, the status-group toggle's; and the quasi-static values captured once their
# flag has crossed (the session's start / new_sess with clr_req, the engine's error and the
# failing write index with its flag). Its two data FIFOs are fifo_dc (above).
set_max_delay -from [get_keepers {*ring_rd:*|clr_req*}]  -to [get_keepers {*ring_rd:*|req_s1*}] 8.000
set_max_delay -from [get_keepers {*ring_rd:*|clr_ack*}]  -to [get_keepers {*ring_rd:*|ack_m1*}] 8.000
set_max_delay -from [get_keepers {*ring_rd:*|grp_tog*}]  -to [get_keepers {*ring_rd:*|gt_m1*}]  8.000
set_max_delay -from [get_keepers {*ring_rd:*|eng_err*}]  -to [get_keepers {*ring_rd:*|ef_s1* *ring_rd:*|q_eng_err*}] 8.000
set_max_delay -from [get_keepers {*ring_rd:*|eng_bad_wi*}] -to [get_keepers {*ring_rd:*|q_eng_wi*}] 8.000
set_max_delay -from [get_keepers {*ring_rd:*|new_sess* *ring_rd:*|start*}] \
              -to [get_keepers {*ring_rd:*|sess *ring_rd:*|sess~* *ring_rd:*|rpos* *ring_rd:*|ps*}] 8.000
# recon_out's "END queued" flag into clk_sys (P3f: crosses ahead of the END's FIFO word)
set_max_delay -from [get_keepers {*recon_out:*|end_q*}] -to [get_keepers {*recon_out:*|end_s1*}] 8.000
# vidfeed_cdc: the END_OF_STREAM flush level (ring_rd's eos, clk_sys) into clk_dec, first stage
set_max_delay -from [get_keepers {*ring_rd:*|eos*}] -to [get_keepers {*vidfeed_cdc:*|fl_q1*}] 8.000
# dec_stub: the clk_dec liveness counter's MSB into clk_sys (LED_USER), first stage
set_max_delay -from [get_keepers {*dec_stub:*|cnt[23]*}] -to [get_keepers {*dec_stub:*|sync_q[0]*}] 8.000
# ring_rd's view of the OSD reset in clk_mem: asserted asynchronously, released through two
# flops (cdc_reset's shape)
set_false_path -to [get_pins -compatibility_mode {*ring_rd:*|rst_m1|clrn *ring_rd:*|rst_m2|clrn}]

# cdc_reset: the reset asserts asynchronously on the two synchroniser flops and is
# released through them -- their clear pins are the crossing (recovery checked from the
# source domain was 3.7 ns wide for clk_sys -> clk_mem)
set_false_path -to [get_pins -compatibility_mode {*cdc_reset:*|q1|clrn *cdc_reset:*|q2|clrn}]

# interface 0.4: the program's settings request, ring_rd's engine (clk_mem) -> osd_req (clk_sys):
# the toggle's first stage, and the word captured when the toggle has crossed (set with it, a
# poll period before the next can change it)
set_max_delay -from [get_keepers {*ring_rd:*|set_tog*}] -to [get_keepers {*osd_req:*|tog_s[0]*}] 8.000
set_max_delay -from [get_keepers {*ring_rd:*|set_word*}] -to [get_keepers {*osd_req:*}] 8.000

# interface 0.5: the audio's fetch, aud_play (clk_sys) -> ring_rd's engine (clk_mem): the
# request toggle's first stage; the ring index and length captured when it has crossed (set
# with it, held until the answer comes back); the answer toggle's first stage. The released
# index (u_rel) and word 34 (u_ctl) cross by cdc_snap, bounded above.
set_max_delay -from [get_keepers {*ring_rd:*|af_req*}] -to [get_keepers {*ring_rd:*|afr_m1*}] 8.000
set_max_delay -from [get_keepers {*ring_rd:*|af_addr_q* *ring_rd:*|af_n_q*}] \
              -to [get_keepers {*ring_rd:*|b_address* *ring_rd:*|b_burstcount* *ring_rd:*|n[*}] 8.000
set_max_delay -from [get_keepers {*ring_rd:*|af_ack*}] -to [get_keepers {*ring_rd:*|afa_s1*}] 8.000
# interface 0.5: the pause into clk_dec for recon_dpb's alarm (emu's frz_dec_s, two flops; the
# level is ring_rd's u_ctl copy, clk_sys)
set_max_delay -from [get_keepers {*ring_rd:*|cdc_snap:u_ctl|dst_data*}] -to [get_keepers {*frz_dec_s[0]*}] 8.000
# interface 0.16 (docs/colour.md): the stream's colour override into clk_dec (emu's col_dec_s0 / s1, two flops;
# quasi-static: latched at the stream's first VIDEO_AU, after the per-stream reset emptied the decoder)
set_max_delay -from [get_keepers {*ring_rd:*|colour_mode*}] -to [get_keepers {*col_dec_s0*}] 8.000

# interface 0.9 (Phase 6b): the overlay plane (h264/ovl_plane.sv), disp_reader's shape both ways.
# clk_sys -> clk_mem: the line command's toggle (first stage) and its fields, captured when the
# toggle has crossed (held from one issue to the done that answers it); the descriptor request's
# toggle. clk_mem -> clk_sys: the done toggle; the descriptor's answer toggle, and its eight words
# copied when it has crossed (stable from the flip until the next request, a refresh later).
set_max_delay -from [get_keepers {*ovl_plane:*|cmd_tog*}] -to [get_keepers {*ovl_plane:*|m_tog[0]*}] 12.000
set_max_delay -from [get_keepers {*ovl_plane:*|cmd_*}] \
              -to [get_keepers {*ovl_plane:*|m_slot* *ovl_plane:*|m_fmt* *ovl_plane:*|m_w[* *ovl_plane:*|m_words* *ovl_plane:*|n_ops* *ovl_plane:*|o_v* *ovl_plane:*|o_a* *ovl_plane:*|o_k* *ovl_plane:*|i_left* *ovl_plane:*|i_addr*}] 12.000
set_max_delay -from [get_keepers {*ovl_plane:*|d_req*}] -to [get_keepers {*ovl_plane:*|dr_m[0]*}] 12.000
set_max_delay -from [get_keepers {*ovl_plane:*|done_tog*}] -to [get_keepers {*ovl_plane:*|done_s1*}] 12.000
set_max_delay -from [get_keepers {*ovl_plane:*|d_ack*}] -to [get_keepers {*ovl_plane:*|da_s1*}] 12.000
set_max_delay -from [get_keepers {*ovl_plane:*|d_w[*}] -to [get_keepers {*ovl_plane:*|dq[*}] 12.000

# hd_raster (docs/hd_raster.md S3): the raster side on clk_vid. The bundle both ways is cdc_snap
# (bounded above, by its module's name); the frame events are cdc_pulse -- the toggle's first
# stage -- and disp_ctl's frame start carries the mode sync_gen scanned it in, two flops into
# clk_sys (quasi-static: it changes only at a restart, a frame before the next frame start).
set_max_delay -from [get_keepers {*cdc_pulse:*|tog*}] -to [get_keepers {*cdc_pulse:*|t1*}] 12.000
set_max_delay -from [get_keepers {*sync_gen:*|mode_*}] -to [get_keepers {*f0_tag_s1*}] 12.000

# interface 0.15 (docs/architecture.md "Pictures from the program"): a PICTURE's hand-over, ring_rd's
# parser (clk_sys) <-> pic_in (clk_dec), four-phase levels. clk_sys -> clk_dec: pd_req's first stage,
# and the descriptor captured when it has crossed (ring_rd's pdw0-3, the header word and PTS, held
# from before pd_req rises until pd_ack has come back). clk_dec -> clk_sys: pd_ack's and pd_busy's
# first stages (pd_busy settles a cycle before pd_ack). Word 84's {holds, pic_emitted} is emu's
# pic_xing (a cdc_snap: bounded above by its module's name).
set_max_delay -from [get_keepers {*ring_rd:*|pd_req*}] -to [get_keepers {*pic_in:*|rq1*}] 8.000
# (0.16) and the record's colour code (ring_rd's h_col, from header word 1: held as the descriptor is -- the next
# header is read only after the hand-over; its first fit timed it as a same-group transfer at -2.1 ns)
set_max_delay -from [get_keepers {*ring_rd:*|pdw* *ring_rd:*|h0* *ring_rd:*|pts* *ring_rd:*|h_col*}] -to [get_keepers {*pic_in:*|d_*}] 8.000
set_max_delay -from [get_keepers {*pic_in:*|pd_ack*}]  -to [get_keepers {*ring_rd:*|pa_s1*}] 8.000
set_max_delay -from [get_keepers {*pic_in:*|pd_busy*}] -to [get_keepers {*ring_rd:*|pb_s1*}] 8.000


# OSD level enters the video domain through a two-flop synchronizer.
set_false_path -to [get_registers {*|disp_reader_inst|gd_sync1}]
