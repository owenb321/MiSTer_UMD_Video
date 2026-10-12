#!/usr/bin/env python3
"""telem_layout.py -- the HIL telemetry wire format, written down once (docs/hil_harness.md
"Telemetry"): umd/umd_telem.sv answers command CMD on hps_io's EXT_BUS with these words;
the custom Main (main/support/umd/umd_ctl.cpp) reads them at 4 Hz into
/tmp/umd_telem.json; tools/mister.py telem unwraps and fits them.

Generated from this table (committed, like the HUD's layout ROM):
  umd/umd_telem_words.svh              the RTL word mux (a case on the word index)
  main/support/umd/umd_telem_fields.h  the field table Main's JSON writer walks

    telem_layout.py                 write both (and the bench's instantiation,
                                    bench/umd/telem_tb_ports.svh)
    telem_layout.py --check         exit 1 if any generated file differs from the table
    telem_layout.py --golden STEM [--seed N]
                                    random source values (STEM.src, one 64-bit hex word
                                    per port, the refresh count last) and a second set
                                    (STEM.src2), and the words the responder must answer:
                                    STEM.exp (all from the first set) and STEM.exp2 (the
                                    sources changed right after the command strobe: the
                                    atomic words still from the first set, the rest from
                                    the second)

Word 0 is MAGIC (not MiSTer_DVD's 0xD7D1: a reply from the wrong core is detectable);
word 1 is {FORMAT, NWORDS}, so a host reading an older core knows which words exist.
Kinds:
  c16   a free-running 16-bit counter. At a 4 Hz poll it is unambiguous below ~260 k/s,
        so a faster one is sent pre-divided (see FIELDS: scale); the host multiplies back.
  s16   a signed 16-bit value;   v16   an unsigned value;   bits  a packed word
ATOMIC fields are latched together on the command strobe (the rate pairs a host divides:
refreshes / pickups, decided / fetched changes, STC / refreshes); the rest are read
live -- every source is already a clk_sys register (disp_ctl's, or a cdc_snap copy), and
a transaction lasts ~100 us against a 250 ms poll.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CMD = 0x7A          # free in stock Main: it uses 0x00-0x44, 0x61-0x63, 0xF0-0xF9 (re-check on a Main bump)
MAGIC = 0xB0D5
# the responder's word index width (umd_telem.sv's wcnt / w_idx): the table may hold 2^WIDX - 1
# words at most (the counter saturates at the last). 6 until 2026-10-07: the table had grown to 67
# and every word from 63 on read word 63 -- words() refuses a table that does not fit now
WIDX = 7
FORMAT = 1

# (name, kind, RTL source expression (umd_telem's ports), atomic, scale, what it is).
# Every word is 16 bits (option B, 2026-09-26: the first cut -- 53 words, 32-bit lo / hi
# pairs -- cost 568 ALM against a P5 line with ~100 to spare). A fast counter is sent
# PRE-DIVIDED (its slice's low bit), so that it wraps no faster than every ~3 s against the
# 4 Hz poll; `scale` is what the host multiplies a count back by.
FIELDS = [
    ("refreshes", "c16", "t_refreshes[15:0]", True, 1, "raster refreshes (59.94 Hz)"),
    ("pickups", "c16", "t_pickups[15:0]", True, 1, "stores taken for display (disp_ctl)"),
    ("dc", "c16", "t_dc[15:0]", True, 1, "decided (store, parity) changes"),
    ("ft", "c16", "t_ft[15:0]", True, 1, "the reader's FETCHED (store, parity) changes"),
    ("stc", "c16", "t_stc[19:4]", True, 16, "the 90 kHz STC / 16"),
    ("late", "c16", "t_late", False, 1, "pickups that missed a due refresh"),
    ("starve", "c16", "t_starve", False, 1, "refreshes with no head while the timeline was due"),
    ("cadence", "c16", "t_cadence", False, 1, "stores held outside {floor, ceil} of their duration"),
    ("sched", "bits", "{t_reanchor, t_ended, t_sflags, t_lone}", False, 1,
     "[15:8] re-anchors [7] ended [6:4] flags {ps err, tick clamp, no timing} "
     "[3:0] lone PTS disbelieved (sat 15; display.md S10)"),
    ("lag_ms", "s16", "t_lag_ms", False, 1, "the last pickup's lag (want - STC), ms"),
    ("emitted", "c16", "t_emitted[15:0]", False, 1, "stores the output process emitted"),
    ("queue", "bits", "{t_dpb_fill, t_oq_flags, 8'd0}", False, 1,
     "[15:11] DPB fullness [10:8] {over, queue overflow, bad release}"),
    ("wait4k", "c16", "t_wait4k[15:0]", False, 4096, "decoder cycles waiting on the display / 4096"),
    ("pics", "c16", "t_pics[15:0]", False, 1, "pictures the reconstruction opened"),
    ("mbs", "c16", "t_mbs[23:8]", False, 256, "macroblocks reconstructed / 256"),
    ("recon_err", "bits", "{t_rerr[11:0], t_rcode}", False, 1, "[15:4] reconstruction errors [3:0] last code"),
    ("slices", "c16", "t_slices[15:0]", False, 1, "slices the front end parsed"),
    ("se", "c16", "t_se[27:12]", False, 4096, "syntax-element words delivered / 4096"),
    ("fe_err", "bits", "{t_ferr[11:0], t_fcode}", False, 1, "[15:4] front-end errors [3:0] last code"),
    ("packs", "c16", "t_packs[15:0]", False, 1, "2048-byte packs read from the image"),
    ("vstall", "c16", "t_vstall[31:16]", False, 65536, "demux cycles waiting on the video parser / 65536"),
    ("d1_wr", "c16", "t_d1_wr", False, 256, "ram1 (DPB): write beats accepted / 256"),
    ("d1_rdb", "c16", "t_d1_rdb", False, 256, "ram1: read beats returned / 256"),
    ("d1_busy", "v16", "t_d1_busy", False, 1, "ram1: the current BUSY run, mclk cycles (saturating)"),
    ("d1_busy_max", "v16", "t_d1_busy_max", False, 1, "ram1: the longest BUSY run (saturating: 0xFFFF = a hang)"),
    ("d1_owed", "v16", "t_d1_owed", False, 1, "ram1: read beats accepted but not yet returned"),
    ("d2_rdb", "c16", "t_d2_rdb", False, 256, "ram2 (display): read beats returned / 256"),
    ("d2_busy", "v16", "t_d2_busy", False, 1, "ram2: the current BUSY run"),
    ("d2_busy_max", "v16", "t_d2_busy_max", False, 1, "ram2: the longest BUSY run"),
    ("d2_owed", "v16", "t_d2_owed", False, 1, "ram2: read beats owed"),
    ("pt", "c16", "t_pt[15:0]", False, 1, "pictures with a picture timing SEI"),
    ("pts", "c16", "t_pts[15:0]", False, 1, "pictures tagged with a PTS"),
    # P6a: the audio path (docs/at3p_decoder.md S7). The lip-sync instrument is av_err:
    # every frame start's STC - PTS as it plays (0 on a healthy stream: one crystal, an
    # exact ratio); the re-arms and the discards say why it moved.
    ("aud_frames", "c16", "t_af", False, 1, "ATRAC3plus AUs decoded (at3p_top)"),
    ("aud_err", "bits", "{t_ar[7:0], t_ak}", False, 1, "[15:8] AUs refused [7:0] the last refusal's code"),
    ("aud_played", "c16", "t_aplayed", False, 1, "PCM frames started (aud_out)"),
    ("aud_rearm", "bits", "{t_under, t_resync}", False, 1, "[15:8] underrun re-arms [7:0] resync re-arms (|d| > 50 ms)"),
    ("av_err", "s16", "t_av_err", False, 1, "the last frame start's STC - PTS, 90 kHz ticks"),
    ("aud_drop", "c16", "t_adrop", False, 1, "pairs discarded (stale + before the STC ran)"),
    ("aud_state", "bits", "{t_arun, t_stc_run, t_aerr_seen, 1'd0, t_afb[3:0], t_amiss[3:0], t_apre_nz, 3'd0}",
     False, 1, "[15] RUN [14] the STC runs [13] av_err measured [11:8] fallback releases "
               "[7:4] missing tags (a bug) [3] pre-anchor drops seen"),
    ("ring_fill", "v16", "t_rfill", False, 1, "compressed-audio ring: bytes held"),
    ("ring_max", "v16", "t_rmax", False, 1, "compressed-audio ring: high-water mark, bytes"),
    ("ring_bp", "c16", "t_rbp[31:16]", False, 65536, "demux cycles blocked on the audio ring / 65536"),
    ("ring_tags", "bits", "{t_rslides[7:0], t_rjumps[7:0]}", False, 1,
     "[15:8] framer slides (the decoder's resyncs) [7:0] PES PTS disagreeing with the derivation"),
    # P6a: the compressed-video buffer (umd/vbuf.sv, the CPB on ram1). Not on the HUD: its
    # 64 field ids are spent.
    ("vbuf_fill", "v16", "t_vfill[25:10]", False, 1024, "compressed-video buffer: bytes held / 1024 (KB)"),
    ("vbuf_max", "v16", "t_vmax[25:10]", False, 1024, "compressed-video buffer: high-water mark / 1024 (KB)"),
    ("vbuf_bp", "c16", "t_vbp[31:16]", False, 65536, "demux cycles waiting on the video buffer / 65536"),
    ("vbuf_late", "v16", "t_vlate", False, 1, "bytes after the title's padding (never: a bug)"),
    # P6b2: the image reader. ep_flags describe the playing item's EP lookups (IN / OUT and
    # seeks, docs/transport.md S2.4): an item with no video map streams whole, an entry past
    # its clip skips the item, a target past 2^32 ticks lands on the map's last entry.
    # P8: the file's mode (0 an image, 1 a bare .MPS, 2 a .PMF) and pmf_warn (the PSMF's stream size
    # disagrees with the file's), in the bits that were spare (docs/bare_streams.md)
    ("reader", "bits", "{t_rdst, t_rdec, t_rbare, t_rpw, t_epf}", False, 1,
     "[15:10] reader state [9:6] err_code [5:4] bare (1 MPS, 2 PMF) [3] pmf_warn [2:0] ep_flags {wide, past, no map}"),
    # P6b3 / P6b3i: the transport (umd/player_ctl.sv, disp_ctl's items, aud_out's item rules).
    # Pulled forward from P6b7: the MCR hang needed them (docs/transport.md S9).
    ("xport", "bits", "{t_xstate, t_xseek, t_xshep, t_xleft, t_xstall, t_xhold, t_xnerr, 1'd0}", False, 1,
     "[15:13] state [12] seeking [11:10] shown item tag [9:6] items left [5] stalled [4] reader held [3:1] nav_err"),
    ("chapter", "v16", "t_chap", False, 1, "the shown (or projected) chapter, from 1"),
    ("seeks", "c16", "t_seeks", False, 1, "seeks issued"),
    ("holds", "c16", "{8'd0, t_holds}", False, 1, "times the reader was held at an item start (saturates at 255)"),
    ("sh_pts_lo", "v16", "t_shpts[15:0]", True, 1, "the shown picture's PTS, bits 15:0 (with sh_pts_hi: one latch)"),
    ("sh_pts_hi", "v16", "t_shpts[31:16]", True, 65536, "the shown picture's PTS, bits 31:16 (weight 2^16: PTS = hi * 65536 + lo)"),
    ("a_left", "c16", "t_aleft", False, 1, "audio pairs dropped as a left item's (aud_out)"),
    ("a_yield", "c16", "t_ayield", False, 1, "audio pairs yielded by the stall breaker (aud_out)"),
    ("trick", "bits", "{t_tkspd, t_tkrev, t_tkone, t_hud, t_il, t_aa, 5'd0}", False, 1,
     "P6b4 trick play: [15:14] speed (0 off, 1-3) [13] reverse [12] the landing is a hop (one_frame); "
     "P6b7 the transport HUD: [11] the Display overlay on [10] the title shows a placeholder "
     "[9] ... for malformed UTF-8 [8] the title ends in an ellipsis; [7] the 480i raster [6:5] its Analog "
     "Aspect in effect (0 Fit, 1 Letterbox, 2 Crop; docs/analog.md)"),
    # P6b7: a landing, read exactly (docs/transport.md S6's seek gate). land_* changes only at a
    # landing, so it is not in the atomic group (32 latch bits saved): a read torn by a landing
    # inside the ~100 us transaction is corrected by the next poll.
    ("land_lo", "v16", "t_land[15:0]", False, 1,
     "the first picture shown after the last landing (a seek's, a hop's, the watchdog's, the mount's): PTS bits 15:0"),
    ("land_hi", "v16", "t_land[31:16]", False, 65536, "... bits 31:16 (PTS = hi * 65536 + lo)"),
    ("seek_lat", "v16", "t_slat[19:4]", False, 16,
     "the last seek that landed with a picture (not a hop): 90 kHz ticks / 16 from its first action "
     "(a press's query, the merge window included) to that picture"),
    ("landing", "bits", "{t_wd, t_rlead, t_rpre, t_rnidr, t_rmmco}", False, 1,
     "[15:8] seeks the watchdog ended; since the last landing (the decoder's reset): [7:5] leading "
     "pictures skipped (sat 7) [4:2] pictures skipped before the first I (sat 7) [1] started at a "
     "non-IDR I [0] an MMCO named a picture from before the entry"),
    # the 480i raster (docs/analog.md V6): a field pair's pickup deferred a field so its first
    # field lands on the raster field of its parity (one at an anchor; one a pair after a parity
    # break in the stream)
    ("pdefer", "c16", "t_pdefer", False, 1, "480i: pickups deferred a field for field order"),
    # 2026-10-03 (area_plan.md A11): what only the diagnostic HUD showed, the readouts a bound hit or a
    # refusal is visible by (spec_hardening.md: "a counter or flag a bench or telemetry can see")
    ("refused", "bits", "{t_frn, t_frc, t_rzn}", False, 1,
     "[15:8] streams the front end refused (count mod 256) [7:4] the last refusal's code "
     "[3:0] pictures refused for their size (count mod 16)"),
    ("warn", "bits", "{t_rwarn, 1'd0, t_odir, t_odrp}", False, 1,
     "[15:13] the reader's warnings {duration saturated, title cut, PARAM.SFO odd} [11:8] output queue: "
     "direct releases (mod 16) [7:0] output queue: stores dropped (mod 256)"),
    ("subs", "bits", "{t_sdrop, t_slate}", False, 1,
     "[15:8] subtitle units dropped (ring full, refused, overrun, cut, bad header; sat 255) "
     "[7:0] subtitle flips late or missed and plane lines late (sat 255)"),
    # fj#80 field matching (docs/telecine.md S5): the cadence lock's state and how often it was lost
    ("film", "bits", "{t_flk, t_fslot, t_fconf, t_flost[7:0]}", False, 1,
     "fj#80 field matching: [15] locked [14:12] slot (7: no phase) [11:8] confidence "
     "[7:0] locks lost (a break or a pair break; mod 256)"),
]


# umd_telem's source ports, in order (name, width); the bench drives them from STEM.src
PORTS = [("t_pickups", 32), ("t_dc", 32), ("t_ft", 32), ("t_stc", 33), ("t_late", 16), ("t_starve", 16),
         ("t_cadence", 16), ("t_reanchor", 8), ("t_ended", 1), ("t_sflags", 3), ("t_lag_ms", 16),
         ("t_emitted", 32), ("t_dpb_fill", 5), ("t_oq_flags", 3), ("t_wait4k", 20), ("t_pics", 32),
         ("t_mbs", 32), ("t_rerr", 32), ("t_rcode", 4), ("t_slices", 32), ("t_se", 32), ("t_ferr", 32),
         ("t_fcode", 4), ("t_packs", 32), ("t_vstall", 32), ("t_d1_wr", 16), ("t_d1_rdb", 16),
         ("t_d1_busy", 16), ("t_d1_busy_max", 16), ("t_d1_owed", 16), ("t_d2_rdb", 16), ("t_d2_busy", 16),
         ("t_d2_busy_max", 16), ("t_d2_owed", 16), ("t_pt", 32), ("t_pts", 32),
         ("t_af", 16), ("t_ar", 16), ("t_ak", 8), ("t_aplayed", 16), ("t_under", 8), ("t_resync", 8),
         ("t_av_err", 16), ("t_adrop", 16), ("t_arun", 1), ("t_stc_run", 1), ("t_aerr_seen", 1),
         ("t_afb", 8), ("t_amiss", 8), ("t_apre_nz", 1), ("t_rfill", 16), ("t_rmax", 16),
         ("t_rbp", 32), ("t_rslides", 16), ("t_rjumps", 16),
         ("t_vfill", 32), ("t_vmax", 32), ("t_vbp", 32), ("t_vlate", 16),
         ("t_rdst", 6), ("t_rdec", 4), ("t_rbare", 2), ("t_rpw", 1), ("t_epf", 3),
         ("t_xstate", 3), ("t_xseek", 1), ("t_xshep", 2), ("t_xleft", 4), ("t_xstall", 1), ("t_xhold", 1),
         ("t_xnerr", 3), ("t_chap", 16), ("t_seeks", 16), ("t_holds", 8), ("t_shpts", 33), ("t_aleft", 16),
         ("t_ayield", 16), ("t_tkspd", 2), ("t_tkrev", 1), ("t_tkone", 1),
         ("t_hud", 4), ("t_land", 33), ("t_slat", 20), ("t_wd", 8), ("t_rlead", 3), ("t_rpre", 3),
         ("t_rnidr", 1), ("t_rmmco", 1), ("t_lone", 4), ("t_il", 1), ("t_pdefer", 16), ("t_aa", 2),
         ("t_frn", 8), ("t_frc", 4), ("t_rzn", 4), ("t_rwarn", 3), ("t_odir", 4), ("t_odrp", 8),
         ("t_sdrop", 8), ("t_slate", 8), ("t_flk", 1), ("t_fslot", 3), ("t_fconf", 4), ("t_flost", 16)]


def evaluate(expr, val):
    """the value of a table expression: an identifier, name[h:l], N'dV, or {a, b, ...}"""
    import re
    expr = expr.strip()
    widths = dict(PORTS)
    widths["t_refreshes"] = 32

    def one(t):
        t = t.strip()
        m = re.fullmatch(r"(\d+)'d(\d+)", t)
        if m:
            return int(m.group(2)), int(m.group(1))
        m = re.fullmatch(r"(\w+)\[(\d+):(\d+)\]", t)
        if m:
            h, l = int(m.group(2)), int(m.group(3))
            return (val[m.group(1)] >> l) & ((1 << (h - l + 1)) - 1), h - l + 1
        return val[t] & ((1 << widths[t]) - 1), widths[t]
    if expr.startswith("{"):
        v = 0
        for part in expr[1:-1].split(","):
            x, w = one(part)
            v = (v << w) | x
        return v
    return one(expr)[0]


def expected(val_strobe, val_live):
    """the 16-bit words: atomic fields from val_strobe (the command strobe's), the rest
    from val_live (the value when each word is served)"""
    out = []
    for i, nm, kind, e, atomic, _sc in words():
        if kind == "const":
            out.append(int(e.split("'h")[1], 16))
        else:
            out.append(evaluate(e, val_strobe if atomic else val_live) & 0xFFFF)
    return out


def tb_ports():
    lines = ["// bench/umd/telem_tb_ports.svh -- GENERATED by tools/telem_layout.py (edit the table there).",
             "localparam int NPORTS = %d;" % len(PORTS),
             "localparam int NWORDS = %d;" % len(words()),
             "umd_telem dut (",
             "    .clk(clk), .io_enable(io_enable), .io_strobe(io_strobe), .io_din(io_din), .drive(drive),",
             "    .dout(dout), .refresh(refresh),"]
    for k, (nm, w) in enumerate(PORTS):
        lines.append("    .%s(src_v[%d][%d:0])%s" % (nm, k, w - 1, "," if k < len(PORTS) - 1 else ""))
    lines.append(");")
    return "\n".join(lines) + "\n"


def golden(stem, seed):
    import random
    rnd = random.Random(seed)
    sets = []
    for _ in range(2):
        v = {nm: rnd.getrandbits(w) for nm, w in PORTS}
        v["t_refreshes"] = rnd.randrange(1, 60)
        sets.append(v)
    # the refresh count is counted by the responder: both sets share it
    sets[1]["t_refreshes"] = sets[0]["t_refreshes"]
    for k, v in enumerate(sets):
        with open(stem + (".src" if k == 0 else ".src2"), "w") as f:
            for nm, w in PORTS:
                f.write("%016x\n" % v[nm])
            f.write("%016x\n" % v["t_refreshes"])
    for name, e in ((".exp", expected(sets[0], sets[0])), (".exp2", expected(sets[0], sets[1]))):
        with open(stem + name, "w") as f:
            for x in e:
                f.write("%04x\n" % x)


def words():
    ws = _words()
    if len(ws) > (1 << WIDX) - 1:
        raise SystemExit("telem_layout: %d words do not fit the responder's %d-bit word index "
                         "(at most %d): widen WIDX and umd_telem.sv's wcnt" % (len(ws), WIDX, (1 << WIDX) - 1))
    return ws


def _words():
    """[(index, field name, kind, expr, atomic, scale)]"""
    out = [(0, "magic", "const", "16'h%04X" % MAGIC, False, 1), (1, "format", "const", "", False, 1)]
    for k, (name, kind, expr, atomic, scale, _what) in enumerate(FIELDS):
        out.append((k + 2, name, kind, expr, atomic, scale))
    out[1] = (1, "format", "const", "16'h%02X%02X" % (FORMAT, len(out)), False, 1)
    return out


def svh():
    ws = words()
    lines = ["// umd/umd_telem_words.svh -- GENERATED by tools/telem_layout.py (edit the table there).",
             "// Included by umd/umd_telem.sv: NWORDS, the atomic latch, and the word mux.",
             "localparam int NWORDS = %d;" % len(ws),
             "localparam [15:0] T_MAGIC = 16'h%04X;" % MAGIC,
             "localparam [15:0] T_CMD = 16'h%04X;" % CMD]
    at = [(nm, e) for nm, k, e, a, _s, _w in FIELDS if a]
    lines.append("// the atomic group, latched on the command strobe")
    for nm, e in at:
        lines.append("logic [15:0] a_%s;" % nm)
    lines.append("`define UMD_TELEM_LATCH \\")
    lines.append("    " + " ".join("a_%s <= %s;" % (nm, e) for nm, e in at))
    lines.append("// word k's value")
    lines.append("always_comb begin")
    lines.append("    case (w_idx)")
    for i, nm, kind, e, atomic, _sc in ws:
        src = ("a_%s" % nm) if atomic else e
        lines.append("        %d'd%d: w_val = %s;%s" % (WIDX, i, src, "" if kind == "const" else "   // " + nm))
    lines.append("        default: w_val = 16'd0;")
    lines.append("    endcase")
    lines.append("end")
    return "\n".join(lines) + "\n"


def header():
    ws = words()
    lines = ["// main/support/umd/umd_telem_fields.h -- GENERATED by tools/telem_layout.py (edit the table there).",
             "#pragma once",
             "#define UIO_UMD_TELEM 0x%02X" % CMD,
             "#define UMD_TELEM_MAGIC 0x%04X" % MAGIC,
             "#define UMD_TELEM_FORMAT %d" % FORMAT,
             "#define UMD_TELEM_NWORDS %d" % len(ws),
             "// kind: 1 c16, 2 s16, 3 v16, 4 bits; scale: what a count is worth (a pre-divided counter)",
             "struct umd_telem_field { const char *name; int word; int kind; unsigned scale; };",
             "static const struct umd_telem_field umd_telem_fields[] = {"]
    kinds = {"c16": 1, "s16": 2, "v16": 3, "bits": 4}
    for i, nm, kind, e, atomic, sc in ws:
        if kind == "const":
            continue
        lines.append('\t{"%s", %d, %d, %du},' % (nm, i, kinds[kind], sc))
    lines.append("};")
    return "\n".join(lines) + "\n"


PATHS = {"svh": os.path.join(ROOT, "umd", "umd_telem_words.svh"),
         "h": os.path.join(ROOT, "main", "support", "umd", "umd_telem_fields.h"),
         "tb": os.path.join(ROOT, "bench", "umd", "telem_tb_ports.svh")}


def main(argv):
    if "--golden" in argv:
        i = argv.index("--golden")
        seed = int(argv[argv.index("--seed") + 1]) if "--seed" in argv else 1
        golden(argv[i + 1], seed)
        return 0
    gen = {"svh": svh(), "h": header(), "tb": tb_ports()}
    if "--check" in argv:
        bad = [k for k, v in gen.items() if not os.path.exists(PATHS[k]) or open(PATHS[k]).read() != v]
        print("telem_layout: %s" % ("OK" if not bad else "STALE: %s" % bad))
        return 1 if bad else 0
    for k, v in gen.items():
        os.makedirs(os.path.dirname(PATHS[k]), exist_ok=True)
        with open(PATHS[k], "w") as f:
            f.write(v)
        print("wrote %s" % os.path.relpath(PATHS[k], ROOT))
    print("%d words" % len(words()))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
