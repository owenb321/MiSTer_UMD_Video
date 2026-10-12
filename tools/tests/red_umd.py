#!/usr/bin/env python3
"""RED arm for the Phase 1 python tests (bench/umd/README.md "--red proves the bench can
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
MUTATIONS = [
    # the telecine model, Forgejo fj#80 (test_telecine_ref.py)
    ("telecine_ref.py", "Wp = weave(f1, q2) if p1 == 0 else weave(q2, f1)",
     "Wp = weave(f1, q1) if p1 == 0 else weave(q1, f1)",
     "test_telecine_ref.py", "refresh 0's partner the previous store's FIRST field"),
    ("telecine_ref.py", "return (b, t, 1) if first_bot else (t, b, 0)",
     "return (t, b, 0) if first_bot else (b, t, 1)",
     "test_telecine_ref.py", "the first field's parity inverted"),
    ("telecine_ref.py", 'R * P["brk8"]:\n                self.locked, self.conf, self.slot = False, 0, None',
     'R * P["brk8"]:\n                pass',
     "test_telecine_ref.py", "a contradiction under the lock does not break it"),
    ("telecine_ref.py", "if self.hit and not self.bad:", "if not self.bad:",
     "test_telecine_ref.py", "a cycle with no combed pair counted as film evidence"),
    ("telecine_ref.py", "self.slot, self.conf, self.hit, self.bad = 1, 0, True, False",
     "self.slot, self.conf, self.hit, self.bad = 0, 0, True, False",
     "test_telecine_ref.py", "the cadence phase one store late"),
    ("telecine_ref.py", 'if C * 8 >= R * P["comb8"] and', 'if C * 8 >= P["comb8"] and',
     "test_telecine_ref.py", "the comb ratio's normaliser dropped"),
    ("telecine_ref.py", "if m in (0, 2, 4):", "if True:",
     "test_telecine_ref.py", "the truth guesses across a gap no 3:2 explains"),
    ("telecine_ref.py", "ia[0] = 1", "ia[0] = 0",
     "test_telecine_ref.py", "the window's top line not mirrored as the reader's ring does"),
    # run_cosim.sh --sample: the census features and the choice (test_cosim_sample.py)
    ("cosim_features.py", 'B_MB[v] if v < 23 else "intra_" + intra_name(v - 23)',
     'B_MB[v] if v < 23 else "intra_" + intra_name(v - 22)',
     "test_cosim_sample.py", "a B slice's intra mb_type offset one short (Table 7-14)"),
    ("cosim_features.py", "            if not ps_since_vcl and sh.get", "            if sh.get",
     "test_cosim_sample.py", "every IDR counted as sent without parameter sets"),
    ("cosim_features.py", '                elif name == "pic_struct":', '                elif name == "pic_struct_x":',
     "test_cosim_sample.py", "pic_struct looked for outside the slice that carries it"),
    ("cosim_features.py", "                qp = (qp + v + 52) % 52", "                qp = (26 + v + 52) % 52",
     "test_cosim_sample.py", "the QP not carried from the PPS and the slice"),
    ("cosim_sample.py", '        if r["verdict"] == "FAIL":', "        if False:",
     "test_cosim_sample.py", "a known FAIL dropped from the sample"),
    ("cosim_sample.py", 'key=lambda r: (r["xrt"], r["label"]))', 'key=lambda r: (-r["xrt"], r["label"]))',
     "test_cosim_sample.py", "the tail takes the FASTEST windows"),
    ("cosim_sample.py", '-(r["xrt"] if r["xrt"] is not None else 99.0)))', '(r["xrt"] if r["xrt"] is not None else 99.0)))',
     "test_cosim_sample.py", "a cover tie goes to the faster window"),
    # the HIL telemetry host side (test_telem.py)
    ("mister.py", "        acc += (r[key] - prev) & ((1 << bits) - 1)", "        acc += (r[key] - prev)",
     "test_telem.py", "a counter not unwrapped across its wrap"),
    ("telem_layout.py", "            v = (v << w) | x", "            v = (v << 8) | x",
     "test_telem.py", "a concatenation's widths ignored"),
    # the HIL settings backup (test_mister_cfg.py; the .hilnew marker, ported from the H264 fork)
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
    # P6b5, the transport HUD's model (test_transport_layout.py)
    ("transport_layout.py", "            if need:\n                need -= 1", "            if True:\n                need -= 1",
     "test_transport_layout.py", "a stray continuation byte adds nothing (a silent drop)"),
    ("transport_layout.py", "    cut = trunc or len(cells) > room", "    cut = trunc or len(cells) >= room",
     "test_transport_layout.py", "a title that fits exactly cut with an ellipsis"),
    ("transport_layout.py", '        return "%0*d:59:59+" % (hdig, 10 ** hdig - 1)', '        return "%0*d:59:59" % (hdig, 10 ** hdig - 1)',
     "test_transport_layout.py", "a saturated time shows no '+'"),
    ("transport_layout.py", "    return 3 if sat39(tot_ticks) >= 100 * 3600 * TICKS else 2", "    return 3 if sat39(tot_ticks) > 100 * 3600 * TICKS else 2",
     "test_transport_layout.py", "exactly 100 h keeps two hour digits"),
    ("transport_layout.py", "    return (q * BAR_W) >> 9", "    return (q * BAR_W + 256) >> 9",
     "test_transport_layout.py", "the bar's fill rounded, not floored"),
    ("transport_layout.py", "        boxes.append((slot, X0 + col * CW - BOX_PAD,", "        boxes.append((slot, X0 + col * CW - BOX_PAD + 1,",
     "test_transport_layout.py", "a box's left padding one pixel short"),
    ("transport_layout.py", '    elif st["display"] or state in ("pause", "stop", "ff", "rew") or popup is not None:',
     '    elif st["display"] or state in ("stop", "ff", "rew") or popup is not None:',
     "test_transport_layout.py", "no icon while paused with Display off"),
    ("transport_layout.py", "HDR_SHIFT, HDR_K = 1, (40, 52, 84)", "HDR_SHIFT, HDR_K = 2, (40, 52, 84)",
     "test_transport_layout.py", "the header wash at a quarter"),
    # P6b0, the navigation model (test_umd_nav_ref.py [nav])
    ("umd_nav_ref.py", "PREV_BACK_TICKS = 90000 ", "PREV_BACK_TICKS = 180000 ",
     "test_umd_nav_ref.py", "Prev goes back within 2 s, not 1 (the PSP restarts at 1 s)"),
    ("umd_nav_ref.py", "        self.chapters = sorted((it, pts)", "        self.chapters = list((it, pts)",
     "test_umd_nav_ref.py", "chapters in table order, not by (item, PTS)"),
    ("umd_nav_ref.py", "if typ == MARK_CHAPTER and it < len(self.items))",
     "if typ in (MARK_CHAPTER, 16) and it < len(self.items))",
     "test_umd_nav_ref.py", "an Endmark taken as a chapter"),
    ("umd_nav_ref.py", "        return max(0, bisect.bisect_right(p, pts) - 1)",
     "        return max(0, bisect.bisect_left(p, pts) - 1)",
     "test_umd_nav_ref.py", "an exact EP hit lands on the entry before"),
    ("umd_nav_ref.py", "        k = bisect.bisect_left(it.pts, it.out_pts)",
     "        k = bisect.bisect_right(it.pts, it.out_pts)",
     "test_umd_nav_ref.py", "OUT taken as inclusive (the reader reads a GOP past it)"),
    ("umd_nav_ref.py", "        return sum(x.duration for x in self.items[:item]) +",
     "        return 0 +",
     "test_umd_nav_ref.py", "elapsed ignores the earlier items"),
    # P6b4: the seek's clamp below OUT and the trick-play hop rule
    ("umd_nav_ref.py", "        return max(min(pts, lim), it.in_pts)",
     "        return max(min(pts, it.out_pts), it.in_pts)",
     "test_umd_nav_ref.py", "a seek clamped to OUT itself (an entry at OUT: nothing shown)"),
    # fix/skip-last-picture: the clamp's guard below OUT
    ("umd_nav_ref.py", "END_GUARD = 4 ", "END_GUARD = 1 ",
     "test_umd_nav_ref.py", "P6b4's OUT - 1 clamp (the display skips the title's last picture)"),
    ("umd_nav_ref.py", "        return r, (r[0], skip), edge", "        return r, req, edge",
     "test_umd_nav_ref.py", "a hop carries its request, not the clamped target"),
    ("umd_nav_ref.py", "        edge = (skip < req[1]) if forward else (sat or skip > req[1])",
     "        edge = (skip < req[1]) if forward else (skip > req[1])",
     "test_umd_nav_ref.py", "a reverse hop saturated at PTS 0 never finds the start"),
    ("umd_nav_ref.py", "                return ((item + 1, 0), False) if item + 1 < len(self.items) else None",
     "                return None",
     "test_umd_nav_ref.py", "a forward hop at an item's edge ends the trick (no crossing)"),
    # P6c, Go To: the time lookup and the marker
    ("umd_nav_ref.py", "            if ticks < it.duration or k == len(self.items) - 1:",
     "            if ticks <= it.duration or k == len(self.items) - 1:",
     "test_umd_nav_ref.py", "a time ON an item boundary taken as the earlier item's OUT"),
    ("umd_nav_ref.py", "                return (k, it.in_pts + min(ticks, it.duration))",
     "                return (k, it.in_pts + ticks)",
     "test_umd_nav_ref.py", "a time past the end not clamped (the seek's clamp alone)"),
    ("umd_nav_ref.py", "        return self.elapsed(key) if key[0] == streaming else None",
     "        return self.elapsed(key)",
     "test_umd_nav_ref.py", "the marker shown for a chapter in another item"),
    # P6b2, the reader's goldens: the chapter query and the stream it plays
    ("umd_nav_ref.py", "c[n - 2] if n >= 2 else None,", "c[n - 1] if n >= 2 else None,",
     "test_umd_nav_ref.py", "the chapter query's prev is the current chapter again"),
    ("umd_nav_ref.py", "        end = nsec if stop is None else min(stop, nsec)",
     "        end = nsec",
     "test_umd_nav_ref.py", "an item streams to its clip's end past OUT's entry"),
    # P6b0, the recovery-point start and the discontinuity (test_umd_nav_ref.py [x264])
    ("h264_recon_ref.py", "        if probe.poc >= self.rp_poc:", "        if True:",
     "test_umd_nav_ref.py", "the leading pictures decoded (their references are from before the entry)"),
    ("h264_recon_ref.py", "            self.recovering = True\n            self.prev_ref_frame_num = h.frame_num",
     "            self.recovering = True",
     "test_umd_nav_ref.py", "a non-IDR start keeps the old PrevRefFrameNum (the frame_num gap)"),
    ("h264_recon_ref.py", "            if op in (1, 2, 3) and self.recovering:", "            if False:",
     "test_umd_nav_ref.py", "an MMCO naming a picture from before the entry refused"),
    ("h264_recon_ref.py", "        for fr in list(self.waitq):\n            fr.waiting = False\n            fr.discarded = True",
     "        for fr in []:\n            fr.waiting = False\n            fr.discarded = True",
     "test_umd_nav_ref.py", "a discontinuity outputs the stores waiting at the seek"),
    ("h264_recon_ref.py", '        self.rp_cnt["discont"] += 1',
     '        self.rp_cnt["discont"] += 1\n        self.sps_map, self.pps_map = {}, {}',
     "test_umd_nav_ref.py", "a discontinuity wipes the parameter sets"),
    ("umd_iso.py", "FLAG_MULTI = 0x80", "FLAG_MULTI = 0x40",
     "test_umd_iso.py", "multi-extent flag bit"),
    ("umd_sfo.py", "FMT_INT32 = 0x0404", "FMT_INT32 = 0x0405",
     "test_umd_sfo.py", "int32 format code"),
    ("psmf_ref.py", "shl = 4 if sub < 0x10 else 2 if", "shl = 4 if sub < 0x10 else 4 if",
     "test_psmf_ref.py", "subtitle sub-header length"),
    # P8, the PSMF header of a .PMF (test_psmf_ref.py [psmf header])
    ("psmf_ref.py", "    if off == 0 or off % SEC or off >= file_size:", "    if off == 0 or off >= file_size:",
     "test_psmf_ref.py", "an unaligned PSMF stream offset accepted"),
    ("psmf_ref.py", "    end = min(off + size, file_size)", "    end = off + size",
     "test_psmf_ref.py", "a PSMF stream size past the file not cut"),
    ("psmf_ref.py", '         "last_pts": int.from_bytes(head[0x5A:0x60], "big"), "streams": []}',
     '         "last_pts": int.from_bytes(head[0x5C:0x60], "big"), "streams": []}',
     "test_psmf_ref.py", "the PSMF last PTS read as a u32 at 0x5C (JPCSP's u48 at 0x5A)"),
    ("psmf_ref.py", "            if self.mm[:4] == PSMF_MAGIC:", "            if False:",
     "test_psmf_ref.py", "a .PMF's header parsed as stream bytes"),
    # P8, a bare stream's goldens (test_umd_fixture.py [bare])
    ("umd_fixture.py", "    n = (h[\"stream_end\"] - off + SEC - 1) // SEC", "    n = (h[\"stream_size\"] + SEC - 1) // SEC",
     "test_umd_fixture.py", "a PSMF stream not cut at the file's end"),
    ("umd_fixture.py", "    return 0, 1, 0, 0, total, BARE_IN_MPS, 0", "    return 0, 1, 0, 0, len(raw) // SEC, BARE_IN_MPS, 0",
     "test_umd_fixture.py", "a bare .MPS's partial last sector dropped"),
    ("umd_clpi.py", "base = ep_off + 6", "base = ep_off + 8",
     "test_umd_clpi.py", "EP entry offset base"),
    ("umd_playlist.py", '"pts": _u48(b, 4)', '"pts": _u48(b, 6)',
     "test_umd_playlist.py", "mark PTS offset"),
    ("at3p_extract.py", '"frame_bytes": (p & 0x3FF) * 8 + 8}', '"frame_bytes": (p & 0x3FF) * 8}',
     "test_at3p_extract.py", "AT3+ frame size formula"),
    ("umd_sub_extract.py", '"len": ln + 4,', '"len": ln,',
     "test_umd_sub_extract.py", "subtitle unit length excludes its own field"),
    ("umd_index_packs.py", "struct.unpack(\">H\", pl[20 + 4 * i:22 + 4 * i])[0])",
     "struct.unpack(\">H\", pl[19 + 4 * i:21 + 4 * i])[0])",
     "test_umd_index_packs.py", "index entry size field offset"),
    ("umd_fixture.py", "mp = umd_playlist.main_playlist(pl)\n    add(", "mp = 0\n    add(",
     "test_umd_fixture.py", "nav walk follows the main (longest) playlist"),
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
    # P7: the DEFLATE coverage model against zlib
    ("inflate_ref.py", "8193, 12289, 16385, 24577)", "8193, 12289, 16386, 24577)",
     "test_inflate_ref.py", "distance code 28's base (RFC 1951 3.2.5)"),
    ("inflate_ref.py", "a = (a + x) % 65521", "a = (a + x) % 65536",
     "test_inflate_ref.py", "the Adler-32 modulus"),
    ("h264_fe_ref.py", "return 1 + cab.decode(27 + 5)                       # 1 0 x",
     "return 1 + cab.decode(27 + 4)                       # 1 0 x",
     "test_h264_fe_ref.py", "B mb_type bin 2 context after b1 == 0 (Table 9-41)"),
    # the ATRAC3plus models (P6): the [ffmpeg]/[mute] arms need UMD_ISO_DIR, else SKIP
    ("at3p_ref.py", "        if ln == 0:\n            self.holes += 1\n            return -1",
     "        if ln == 0:\n            self.holes += 1\n            return 0",
     "test_at3p_ref.py", "a Huffman hole returns -1 (ffmpeg's table)"),
    ("at3p_ref.py", "                        cf = sign_extend(cf, bits)",
     "                        cf = cf", "test_at3p_ref.py", "signed spectrum values"),
    ("at3p_ref.py", "        sb_rng[sb] = rng & 0x3FC", "        sb_rng[sb] = rng & 0x3FF",
     "test_at3p_ref.py", "the noise table's start index per subband"),
    ("at3p_ref.py", "    if u.mute_flag:\n        return out\n", "",
     "test_at3p_ref.py", "the mute flag (no disc sets it; the [mute] arm flips it)"),
    ("at3p_fixed.py", "            E[pos] = 4 * (6 - cur) - (nxt - cur) * k",
     "            E[pos] = 4 * (6 - cur) + (nxt - cur) * k",
     "test_at3p_ref.py", "the gain ramp's direction"),
    ("at3p_fixed.py", "        for i in range(96, 128):\n            w[i] = 1 << CB",
     "        for i in range(96, 128):\n            w[i] = 0",
     "test_at3p_ref.py", "a steep window's unmultiplied quarter"),
    # P6d, the control panel's behaviour and art (test_panel_ref.py; docs/panel.md §1.1, §8)
    ("panel_layout.py", 'START = "display"', 'START = "menu"',
     "test_panel_ref.py", "the cursor not starting on Display (K8)"),
    ("panel_ref.py", "cand = row[(c + step * k) % len(row)]",
     "cand = row[min(len(row) - 1, max(0, c + step * k))]",
     "test_panel_ref.py", "<- / -> not wrapping within a row"),
    ("panel_ref.py", "            if self.available(cand):\n                self.sel = cand",
     "            if True:\n                self.sel = cand",
     "test_panel_ref.py", "<- / -> landing on a dark item"),
    ("panel_ref.py", "if best is None or d < best[0]:", "if best is None or d <= best[0]:",
     "test_panel_ref.py", "a ^ / v tie going right"),
    ("panel_ref.py", 'CLOSES = {"menu", "stop"}', 'CLOSES = {"menu"}',
     "test_panel_ref.py", "Stop not closing the panel (K5)"),
    ("panel_ref.py", "RETURN_READS = 2", "RETURN_READS = 1",
     "test_panel_ref.py", "the panel back after Go To before the jump's seek can be seen"),
    ("panel_ref.py", 'elif not self.g_seen and now - self.g_since >= GOTO_OPEN_MS:',
     'elif not self.g_seen and now - self.g_since > GOTO_OPEN_MS:',
     "test_panel_ref.py", "the refused-editor timeout one tick late"),
    ("panel_ref.py", '"play": ("cmd", PC_PLAY)', '"play": ("press", 1 << B_PLAYPAUSE)',
     "test_panel_ref.py", "Play sent as Play/Pause (it would pause a playing title)"),
    ("panel_ref.py", "GRAB_OPEN = DPAD | (1 << B_PAUSE) | (1 << B_STOP) | (1 << B_PANEL)",
     "GRAB_OPEN = DPAD | (1 << B_PAUSE) | (1 << B_PANEL)",
     "test_panel_ref.py", "o not grabbed while open: it would stop the title (K6)"),
    ("panel_layout.py", 'IN_MENU = {"menu", "display", "stop"}', 'IN_MENU = {"menu", "goto", "display", "stop"}',
     "test_panel_ref.py", "Go To available over a disc menu (K9)"),
    ("panel_ref.py", "if rd.state == 0 and not rd.menu_up or rd.menu_up != prev.menu_up:",
     "if rd.state == 0 and not rd.menu_up:",
     "test_panel_ref.py", "a disc menu coming up under an open panel"),
    ("panel_ref.py", "            return dict(grab=1 << B_PANEL, show=None)",
     "            return dict(grab=GRAB_OPEN, show=None)",
     "test_panel_ref.py", "the D-pad grabbed while Go To's editor has it"),
    ("panel_ref.py", '"ff": ("press", 1 << B_RIGHT)', '"ff": ("press", 1 << B_LEFT)',
     "test_panel_ref.py", "Fast Forward sending REW's press"),
    ("panel_layout.py", "(flat[i] << 6) | (flat[i + 1] << 4)", "(flat[i + 1] << 6) | (flat[i] << 4)",
     "test_panel_ref.py", "the art packed out of pixel order (a stale umd_panel_art.c)"),
    # P8, the bug bundle (test_umd_report.py; docs/bug_reports.md)
    ("umd_report.py", "NAL_KEEP = (6, 7, 8, 9, 10, 11, 13, 15)", "NAL_KEEP = (6, 8, 9, 10, 11, 13, 15)",
     "test_umd_report.py", "the SPS zeroed (a header lost)"),
    ("umd_report.py", "                n = hb\n", "                n = len(nal)\n",
     "test_umd_report.py", "every slice kept whole (a picture leaked)"),
    ("umd_report.py", "            pos += 8 + (be16(d, pos + 2) & 0x3FF) * 8 + 8", "            pos += 8 + (be16(d, pos + 2) & 0x3FF) * 8",
     "test_umd_report.py", "an AU's frame length 8 bytes short: the chain loses its headers"),
    ("umd_report.py", "            if field:\n                br.bit()", "            if False:\n                br.bit()",
     "test_umd_report.py", "bottom_field_flag not read: a field slice's header mis-measured"),
    ("umd_report.py", "                    if run > MAX_NONZERO_RUN:", "                    if False:",
     "test_umd_report.py", "the audit's parser-free run ceiling off"),
    ("umd_report.py", 'a, b = px + lead * dx, px + (len(v.rstrip(b"\\0")) - 1) * dx',
     'a, b = px + lead * dx, px + (len(v.rstrip(b"\\0")) - 2) * dx',
     "test_umd_report.py", "an image's alpha box one pixel narrow"),
    ("umd_report.py", "        if not any(img):\n            continue", "        if True:\n            continue",
     "test_umd_report.py", "the audit skips the RCO images"),
    ("umd_report.py", "            out[at:at + 48] = data[at:at + 48]", "            out[at:at + 64] = data[at:at + 64]",
     "test_umd_report.py", "a VAG's first samples kept with its header"),
    ("umd_report.py", "            rep = png_flat(w, h, (0, 0, w - 1, h - 1), depth=4, alpha=160)",
     "            rep = png_flat(w, h + 1, (0, 0, w - 1, h), depth=4, alpha=160)",
     "test_umd_report.py", "a subtitle stand-in of the wrong size"),
    ("umd_report.py", 'struct.pack(">HH", h, w)', 'struct.pack(">HH", w, h)',
     "test_umd_report.py", "the JPEG stand-in's width and height swapped"),
    ("umd_report.py", "    if stray:", "    if False:",
     "test_umd_report.py", "a sector outside every captured file let through"),
    ("umd_report.py", "        audit_subtitles(path, sub, es)", "        pass",
     "test_umd_report.py", "the audit's subtitle unit check off"),
    ("umd_report.py", 'if read_span(img, rec["lba"], rec["size"]) != read_span(src, rec["lba"], rec["size"]):',
     "if False:", "test_umd_report.py", "verify does not compare the table files"),
]


def copy_tools(d, root):
    """tools/ copied (the mutation target), the RTL beside it as a symlink: the tests that
    compare the model with the RTL's tables (test_h264_fe_ref: umd/h264/*.mem) find them
    at ../umd from the copy, as in the tree -- without it the CONTROL copy failed that
    arm whenever $UMD_REFS_DIR was set (since P3, unseen until 2026-09-26). main/ and
    bench/ likewise: test_telem checks the generated files telem_layout.PATHS names there
    (umd/, main/support/umd/, bench/umd/); with only umd/ linked the control copy failed
    test_telem, so its two RED arms were "caught" by a test that could not pass (since
    PR fj#10, found 2026-09-27)"""
    shutil.copytree(TOOLS, root, ignore=shutil.ignore_patterns("__pycache__"))
    for sub in ("umd", "main", "bench"):
        os.symlink(os.path.join(os.path.dirname(TOOLS), sub), os.path.join(d, sub))


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
            path = os.path.join(root, tool)
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
    print("red_umd: %s" % ("ALL GREEN" if not fails else "%d FAILURE(S)" % fails))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
