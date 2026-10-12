# umd/umd.sdc -- the core's timing exceptions (the framework's live in sys/sys_top.sdc,
# which keeps the core PLL's clocks in one group: their transfers are timed).
#
# Every transfer between two of the core's clocks goes through a crossing primitive: a
# two-flop synchroniser, a gray-coded fifo_dc pointer, or a quasi-static value captured
# by protocol (docs/architecture.md, the crossings table). Timed as same-group transfers
# they get the tightest edge pair of the two clocks: 12.3 ns for clk_dec / clk_sys
# (81 = 3 x 27 MHz), 3.7 ns for clk_sys / clk_mem (27 / 90 MHz: the display's line
# requests) and 1.23 ns for clk_dec / clk_mem (81 / 90 MHz: the reconstruction's DPB
# client, dpb_mem's three fifo_dc, since the reconstruction moved back to clk_dec).
# These bound the capture stages to 8 ns instead -- under every period involved, so a
# gray pointer's bits still arrive within one destination cycle of each other.

# Each bound names its SOURCE too: a bare "-to" also applied to the capture flops' reset
# recovery (a 37 ns clk_sys reset path became an 8 ns one, 2026-09-24).

# fifo_dc: the other side's gray pointer, first synchroniser stage (patterns end in *:
# the fitter duplicates registers, "...[5]~_Duplicate_1")
set_max_delay -from [get_keepers {*fifo_dc:*|wgray*}] -to [get_keepers {*fifo_dc:*|rq1_wgray*}] 8.000
set_max_delay -from [get_keepers {*fifo_dc:*|rgray*}] -to [get_keepers {*fifo_dc:*|wq1_rgray*}] 8.000

# disp_reader: the request toggle's first stage, and the line / picture fields captured
# when the toggle has crossed (stable for 2+ mclk cycles / 24 raster lines by then).
# Sources: disp_reader's own request registers and emu's latched picture (sh_*).
set_max_delay -from [get_keepers {*disp_reader:*|req_tog*}] -to [get_keepers {*disp_reader:*|m_tog[0]*}] 8.000
# (480i, docs/analog.md: the request's second line, its count, its ring slot and its "first of
# a field" flag cross the same way -- the first fit timed them on the 3.7 ns edge window, -0.09 ns)
set_max_delay -from [get_keepers {*disp_reader:*|req_line* *disp_reader:*|req_n* *disp_reader:*|req_slot* *disp_reader:*|req_first* *disp_reader:*|req_alt* *|sh_valid* *|sh_field* *|sh_store* *|sh_pstore* *|sh_w[* *|sh_hf* *|sh_parity*}] \
              -to [get_keepers {*disp_reader:*|m_line_q* *disp_reader:*|m_line1_q* *disp_reader:*|m_n_q* *disp_reader:*|m_slot_q* *disp_reader:*|m_first* *disp_reader:*|m_store* *disp_reader:*|m_w[* *disp_reader:*|m_hf* *disp_reader:*|m_valid* *disp_reader:*|m_field* *disp_reader:*|fc_* *disp_reader:*|fetch_changes*}] 8.000

# cdc_snap (umd/cdc.sv): the handshake's two synchroniser first stages, and the copy of the
# latched bus -- hold is two or more destination cycles old when dst_data takes it (ack
# changed in the same source edge and crossed two flops). Every instance copies into
# clk_sys (37 ns); the clk_mem ones were timed on the 3.7 ns 90 / 27 MHz edge window
# the handshake never uses (-0.28 ns on the P5f fit, 2026-09-27: d1 / d2 / ft_snap).
set_max_delay -from [get_keepers {*cdc_snap:*|hold*}] -to [get_keepers {*cdc_snap:*|dst_data*}] 8.000
set_max_delay -from [get_keepers {*cdc_snap:*|ack*}]  -to [get_keepers {*cdc_snap:*|d_q1*}]     8.000
set_max_delay -from [get_keepers {*cdc_snap:*|req*}]  -to [get_keepers {*cdc_snap:*|s_q1*}]     8.000

# cdc_reset: the reset asserts asynchronously on the two synchroniser flops and is
# released through them -- their clear pins are the crossing (recovery checked from the
# source domain was 3.7 ns wide for clk_sys -> clk_mem)
set_false_path -to [get_pins -compatibility_mode {*cdc_reset:*|q1|clrn *cdc_reset:*|q2|clrn}]
# vbuf (P6a): the clear handshake's two synchroniser first stages (clr_req clk_sys ->
# clk_mem, clr_ack clk_mem -> clk_sys). Levels held until the other side answers; timed as
# same-group transfers they got the 3.7 ns 90 / 27 MHz edge window (-0.133 ns clk_sys setup
# on the first vbuf fit, 2026-09-27). Its data crosses in fifo_dc (bounded above).
set_max_delay -from [get_keepers {*vbuf:*|clr_ack*}] -to [get_keepers {*vbuf:*|ack_s1*}] 8.000
set_max_delay -from [get_keepers {*vbuf:*|clr_req*}] -to [get_keepers {*vbuf:*|req_m1*}] 8.000
# P7, the subtitle overlay (umd/sub/sub_overlay.sv; docs/compositor.md §8). Its FIFOs are
# fifo_dc and its STC a cdc_snap (bounded above); these are its two protocol crossings.
# sub_flip: the request toggle (mclk -> clk_sys) and the ack toggle (clk_sys -> mclk), first
# stages; the held request (hb / hv / hx / hy / hw / hh, mclk registers stable from before the
# toggle until the ack) captured into the plane's geometry at vbl on clk_sys -- and, since P6d, into
# the kept copy (k_vis / k_buf / k_x / k_y / k_w / k_h, the same capture under the same m_new: what
# the panel's close restores). P6d's fits left the kept copy out of this bound, so it was timed on the
# 27 / 90 MHz edge window the handshake never uses (-2.6 ns at -40 C, found on A9's fit, 2026-10-05).
set_max_delay -from [get_keepers {*sub_flip:*|req_tog*}] -to [get_keepers {*sub_flip:*|req_s[0]*}] 8.000
set_max_delay -from [get_keepers {*sub_flip:*|ack_tog*}] -to [get_keepers {*sub_flip:*|ack_s[0]*}] 8.000
set_max_delay -from [get_keepers {*sub_flip:*|hb* *sub_flip:*|hv* *sub_flip:*|hx[* *sub_flip:*|hy[* *sub_flip:*|hw[* *sub_flip:*|hh[*}] \
              -to [get_keepers {*sub_flip:*|vis* *sub_flip:*|base[* *sub_flip:*|x[* *sub_flip:*|y[* *sub_flip:*|w[* *sub_flip:*|h[* \
                                *sub_flip:*|k_vis* *sub_flip:*|k_buf* *sub_flip:*|k_x[* *sub_flip:*|k_y[* *sub_flip:*|k_w[* *sub_flip:*|k_h[*}] 8.000
# plane_reader: its line request toggle's first stage, and the request's fields and the
# geometry (sub_flip's, changed only at vbl) captured on mclk when the toggle has crossed
# (as disp_reader's, above).
set_max_delay -from [get_keepers {*plane_reader:*|req_tog*}] -to [get_keepers {*plane_reader:*|m_tog[0]*}] 8.000
set_max_delay -from [get_keepers {*plane_reader:*|req_row* *plane_reader:*|req_need_b* *plane_reader:*|req_in* *plane_reader:*|req_half* *sub_flip:*|base[* *sub_flip:*|x[* *sub_flip:*|w[*}] \
              -to [get_keepers {*plane_reader:*|m_row* *plane_reader:*|m_need_b* *plane_reader:*|m_in* *plane_reader:*|m_half* *plane_reader:*|m_base* *plane_reader:*|m_sx* *plane_reader:*|m_sw*}] 8.000
# emu: a subtitle change's flush (player_ctl's sub_flush, a clk_sys level held 16 cycles) into its
# clk_mem synchroniser's first stage (sb_sfl_q[0]); timed as a same-group transfer it got the
# 3.7 ns 27 / 90 MHz edge window (-0.042 ns clk_mem setup on the first P7 fit, 2026-09-30).
set_max_delay -from [get_keepers {*player_ctl:*|sub_flush*}] -to [get_keepers {*|sb_sfl_q[0]*}] 8.000

# P9: pcm_shot's trigger (clk_sys -> clk_mem): the toggle's first stage, and the held fields
# captured on mclk when the synchronised toggle has changed (set with the toggle, two or more
# mclk cycles earlier -- the disp_reader pattern above). Its FIFO is fifo_dc's (above).
set_max_delay -from [get_keepers {*pcm_shot:*|t_tog*}] -to [get_keepers {*pcm_shot:*|m_s[0]*}] 8.000
set_max_delay -from [get_keepers {*pcm_shot:*|t_gen* *pcm_shot:*|t_start* *pcm_shot:*|t_words*}] \
              -to [get_keepers {*pcm_shot:*|m_gen* *pcm_shot:*|m_addr* *pcm_shot:*|m_left*}] 8.000
# P9: the host's ui level (umd_host, clk_sys) into emu's clk_mem edge detector (the subtitle flush)
set_max_delay -from [get_keepers {*umd_host:*|ui_r*}] -to [get_keepers {*|sb_ui_q[0]*}] 8.000
