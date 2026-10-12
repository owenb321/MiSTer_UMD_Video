#!/usr/bin/env python3
"""check_emu_wiring.py -- gate the seams in umd/emu.sv by READING them out of the file.

WHY THIS EXISTS
---------------
emu.sv has no testbench. Every module it instantiates is benched on its own, but the
facts that live only in emu -- which clock feeds which instance, which wire reaches which
port, whether the port list still matches sys/sys_top.v's instance -- are invisible to all
of them. MiSTer_DVD shipped several defects of exactly this shape (a CDC declared and
never instantiated; a port carrying the wrong fact), each surviving hardware rounds
because every module bench was handed the right value directly.

This is the MiSTer_DVD `tools/check_*_wiring.py` pattern: parse the RTL, assert on token
sets, and treat every lookup that comes back empty as a FAIL -- never a skip. It runs in
milliseconds from bench/umd/run_scaffold.sh.

    python3 tools/check_emu_wiring.py [emu.sv [sys_top.v [umd.sdc]]]   # exit 0 = wired as designed

THREE PARSING TRAPS (inherited, still true)
-------------------------------------------
* strip_comments() is mandatory: a comment quoting the pre-fix expression makes a grep
  pass on a reverted file.
* Tests are over TOKEN SETS, never substring `in`: `hs_dly` contains `hs`.
* terms() does not strip Verilog literals (`8'd0` -> `d0`); use membership on any
  expression that contains one, equality only on literal-free wires.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def strip_comments(src):
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == '/' and i + 1 < n and src[i + 1] == '/':
            j = src.find('\n', i)
            j = n if j < 0 else j
            out.append(' ' * (j - i))
            i = j
        elif c == '/' and i + 1 < n and src[i + 1] == '*':
            j = src.find('*/', i + 2)
            j = n if j < 0 else j + 2
            out.append(''.join(ch if ch == '\n' else ' ' for ch in src[i:j]))
            i = j
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def preprocess(src, defines):
    """Keep only the text the `ifdef/`ifndef/`elsif/`else/`endif conditionals select for
    these macros (sys_top.v's FB_* ports exist only under MISTER_FB)."""
    out, stack = [], []          # stack of [this branch live, some branch taken, parent live]
    live = True
    for line in src.split('\n'):
        m = re.match(r'\s*`(ifdef|ifndef|elsif|else|endif)\b\s*(\w*)', line)
        if not m:
            out.append(line if live else '')
            continue
        kw, name = m.groups()
        if kw in ('ifdef', 'ifndef'):
            cond = (name in defines) == (kw == 'ifdef')
            stack.append([cond, cond, live])
            live = live and cond
        elif kw == 'elsif':
            top = stack[-1]
            cond = not top[1] and name in defines
            top[0] = cond; top[1] = top[1] or cond
            live = top[2] and cond
        elif kw == 'else':
            top = stack[-1]
            cond = not top[1]
            top[0] = cond; top[1] = True
            live = top[2] and cond
        else:
            live = stack.pop()[2]
        out.append('')
    return '\n'.join(out)


def qsf_macros():
    qsf = open(os.path.join(ROOT, 'UMD.qsf'), encoding='utf-8').read()
    return set(m.split('=')[0] for m in re.findall(r'^\s*set_global_assignment\s+-name\s+VERILOG_MACRO\s+"?([\w=]+)', qsf, re.M))


def norm(text):
    return re.sub(r'\s+', ' ', text)


def find_instances(src, module):
    """Every instantiation of module: [(name, body)]."""
    out, pos = [], 0
    while True:
        m = re.search(r'\b%s\b\s*(?:#\s*\(.*?\)\s*)?(\w+)\s*\(' % re.escape(module), src[pos:])
        if not m:
            return out
        name, body = find_instance(src[pos + m.start():], module)
        out.append((name, body))
        pos += m.end()


def find_instance(src, module):
    """Text between a module instantiation's '(' and its matching ')'. Handles an
    optional #(...) parameter list."""
    m = re.search(r'\b%s\b\s*(?:#\s*\(.*?\)\s*)?(\w+)\s*\(' % re.escape(module), src)
    if not m:
        return None, None
    depth, i, n = 0, m.end() - 1, len(src)
    while i < n:
        if src[i] == '(':
            depth += 1
        elif src[i] == ')':
            depth -= 1
            if depth == 0:
                return m.group(1), src[m.end():i]
        i += 1
    return m.group(1), None


def params_of(src, module):
    m = re.search(r'\b%s\b\s*#\s*\(' % re.escape(module), src)
    if not m:
        return ''
    depth, i, n = 0, m.end() - 1, len(src)
    while i < n:
        if src[i] == '(':
            depth += 1
        elif src[i] == ')':
            depth -= 1
            if depth == 0:
                return src[m.end():i]
        i += 1
    return ''


def connections(body):
    out = {}
    i, n = 0, len(body)
    while i < n:
        if body[i] == '.':
            m = re.match(r'\.\s*(\w+)\s*\(', body[i:])
            if m:
                depth, j = 0, i + m.end() - 1
                while j < n:
                    if body[j] == '(':
                        depth += 1
                    elif body[j] == ')':
                        depth -= 1
                        if depth == 0:
                            break
                    j += 1
                out[m.group(1)] = ' '.join(body[i + m.end():j].split())
                i = j
        i += 1
    return out


def assign_of(src, name):
    m = re.search(r'\bassign\s+%s\s*=\s*([^;]+);' % re.escape(name), src)
    if m:
        return m.group(1).strip()
    m = re.search(r'\b(?:wire|reg|logic)\b[^;=]*?\b%s\s*=\s*([^;]+);' % re.escape(name), src)
    return m.group(1).strip() if m else None


def wire_init(src, name):
    """the expression of `wire ... name = <expr>;`, or None"""
    m = re.search(r'\bwire\b[^;=]*\b%s\s*=\s*([^;]+);' % re.escape(name), src)
    return m.group(1) if m else None


def terms(expr):
    return set(re.findall(r'[A-Za-z_]\w*', expr))


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'umd', 'emu.sv')
    raw = open(path, encoding='utf-8').read()
    src = norm(strip_comments(raw))
    rel = os.path.relpath(path, ROOT) if path.startswith(ROOT) else path
    fails = []

    def bad(label, why):
        fails.append('%s: %s' % (label, why))

    def inst(module):
        name, body = find_instance(src, module)
        if body is None:
            bad(module, 'no %s instantiation found in %s' % (module, rel))
            return name, {}
        return name, connections(body)

    # ---- the port list must be exactly what sys/sys_top.v's emu instance drives ----
    head = src[:src.index(');')] if ');' in src else src
    ports = set(re.findall(r'\b(?:input|output|inout)\b[^,;]*?\b(\w+)\s*(?:,|$)', head))
    for p in ('VGA_CS', 'VGA_CS_EN', 'BUTTONS', 'AUDIO_MIX', 'CLK_SYS', 'DDRAM_CLK', 'HPS_BUS'):
        if p not in ports:
            bad('ports', '%s missing from the emu port list (sys_top.v drives it)' % p)
    for p in ('SPDIF_PASS', 'SPDIF_PASS_EN', 'HDMI_BS_SCK', 'HDMI_BS_WS', 'HDMI_BS_SD', 'HDMI_BS_EN'):
        if p in ports:
            bad('ports', '%s is a MiSTer_DVD bitstream-passthrough port; sys_top.v here no longer '
                         'drives it, so the instance would fail to elaborate' % p)
    top_path = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, 'sys', 'sys_top.v')
    top = norm(preprocess(strip_comments(open(top_path, encoding='utf-8').read()), qsf_macros()))
    _, tbody = find_instance(top, 'emu')
    if tbody is None:
        bad('sys_top', 'no emu instance found in sys/sys_top.v')
    else:
        driven = set(connections(tbody))
        if driven - ports:
            bad('ports', 'sys_top.v connects ports emu lacks: %s' % sorted(driven - ports))
        # CLK_MEM: an emu output stock sys_top.v leaves commented out (unconnected, harmless)
        if ports - driven - {'CLK_MEM'}:
            bad('ports', 'emu ports sys_top.v leaves unconnected: %s' % sorted(ports - driven - {'CLK_MEM'}))
    # ram2's nets must be declared before sysmem_lite connects them (Verilog declaration
    # order: an earlier use makes an implicit 1-bit net), and ram2 must be the core's
    m_sys = re.search(r'\bsysmem_lite\s+sysmem\b', top)
    m_decl = re.search(r'\bwire\s*\[\s*28\s*:\s*0\s*\]\s*ram2_address\s*;', top)
    if not m_sys or not m_decl or m_decl.start() > m_sys.start():
        bad('sys_top', 'ram2_address must be declared ABOVE the sysmem_lite instance')
    _, sbody = find_instance(top, 'sysmem_lite')
    if sbody is not None and terms(connections(sbody).get('ram2_clk', '')) != {'ram2_clk'}:
        bad('sys_top', 'sysmem_lite.ram2_clk must be ram2_clk (emu\'s DDRAM2_CLK), not clk_audio')
    if tbody is not None and terms(connections(tbody).get('DDRAM2_ADDR', '')) != {'ram2_address'}:
        bad('sys_top', 'emu.DDRAM2_ADDR must drive ram2_address')
    _, dbody = find_instance(top, 'ddr_svc')
    if dbody is None:
        bad('sys_top', 'ddr_svc must stay (its ram_bcnt feeds the palette address)')
    elif terms(connections(dbody).get('ram_addr', '')) & {'ram2_address'}:
        bad('sys_top', 'ddr_svc still drives ram2 (two drivers with emu\'s DDRAM2)')
    # ---- Analog Dither (2026-10-06, docs/analog.md S9; MiSTer_DVD's check_dac_dither_wiring.py
    # folded in): dac_dither's bench is handed the word and cannot see WHICH word, nor whether the
    # OSD reaches it. Bit 16 alone: 8 was Diagnostics and a saved config may still hold it set.
    rhs = assign_of(src, 'VGA_DITHER')
    if (rhs or '').replace(' ', '') != 'status[16]':
        bad('VGA_DITHER', 'must be status[16] (the OSD\'s Analog Dither), got %r' % rhs)
    rows = []
    for s in re.findall(r'"([^"\n]*)"', src):
        m = re.match(r'^(?:[HhDd]\d)*O\[(\d+)(?::(\d+))?\],', s)
        if m:
            hi = int(m.group(1)); lo = int(m.group(2)) if m.group(2) else hi
            if lo <= 16 <= hi:
                rows.append(s)
    if rows != ['O[16],Analog Dither,Off,On;']:
        bad('CONF_STR', 'status[16] must belong to exactly one row, "O[16],Analog Dither,Off,On;" '
                        '(another option\'s saved value would switch the dither), got %r' % rows)
    if tbody is not None and connections(tbody).get('VGA_DITHER', '').replace(' ', '') != 'vga_dither_en':
        bad('sys_top', 'emu .VGA_DITHER must drive vga_dither_en (dac_dither\'s enable)')
    dd = find_instances(top, 'dac_dither')
    if len(dd) != 1 or dd[0][1] is None:
        bad('sys_top', 'expected one dac_dither instance, found %d' % len(dd))
    else:
        dc = connections(dd[0][1])
        for p, net in (('clk', 'clk_vid'), ('en', 'vga_dither_en'), ('hs', 'vga_hs'), ('vs', 'vga_vs'),
                       ('de', 'vga_de'), ('din', 'vga_o'), ('dout', 'vga_od')):
            if dc.get(p, '').replace(' ', '') != net:
                bad('sys_top', 'dac_dither .%s(%s), want .%s(%s) (the VGA word after the yc_out mux, '
                               'its own syncs)' % (p, dc.get(p), p, net))
    for name, pat in (('VGA_R', r'\bassign\s+VGA_R\s*=\s*([^;]*);'),
                      ('VGA_G', r'\bassign\s+VGA_G\s*=\s*([^;]*);'),
                      ('VGA_B', r'\bassign\s+VGA_B\s*=\s*([^;]*);'),
                      ('vga_r', r'\bwire\s*\[1:0\]\s*vga_r\s*=\s*([^;]*);'),
                      ('vga_g', r'\bwire\s*\[1:0\]\s*vga_g\s*=\s*([^;]*);'),
                      ('vga_b', r'\bwire\s*\[1:0\]\s*vga_b\s*=\s*([^;]*);')):
        found = re.findall(pat, top)
        if len(found) != 1:
            bad('sys_top', 'expected one driver of %s, found %d' % (name, len(found)))
        elif 'vga_o' in terms(found[0]) or 'vga_od' not in terms(found[0]):
            bad('sys_top', '%s reads the undithered word (%s) -- that channel never dithers'
                % (name, found[0].strip()))
    # every module a umd/umd.sdc exception names must exist (a rename silently drops it)
    sdc_path = sys.argv[3] if len(sys.argv) > 3 else os.path.join(ROOT, 'umd', 'umd.sdc')
    sdc = open(sdc_path, encoding='utf-8').read()
    defined = set()
    for d in ('umd', 'umd/h264', 'umd/at3p', 'umd/png', 'umd/sub', 'sys'):
        for f in os.listdir(os.path.join(ROOT, d)):
            if f.endswith(('.sv', '.v')):
                defined |= set(re.findall(r'^\s*module\s+(\w+)', open(os.path.join(ROOT, d, f),
                               encoding='utf-8', errors='replace').read(), re.M))
    for mod in sorted(set(re.findall(r'\*(\w+):\*', sdc))):
        if mod not in defined:
            bad('umd.sdc', 'names module %s, which no longer exists: its exception binds nothing' % mod)
    if not re.search(r'output\s*\[\s*1\s*:\s*0\s*\]\s*BUTTONS', src):
        bad('ports', 'BUTTONS must be `output [1:0]` (the core->HPS virtual OSD button)')

    # ---- exactly one CORE_VERSION define, in the allowed shape ----
    vers = re.findall(r'`define\s+CORE_VERSION\s+"([^"]*)"', raw)
    if len(vers) != 1:
        bad('CORE_VERSION', 'expected exactly one `define CORE_VERSION, found %d' % len(vers))
    elif len(vers[0]) > 18 or any(c in vers[0] for c in ',;"'):
        bad('CORE_VERSION', '%r breaks the CONF_STR rules (<= 18 chars, no , ; ")' % vers[0])

    # ---- clocks and reset ----
    for wire, want in (('CLK_VIDEO', {'clk_sys'}), ('CLK_SYS', {'clk_sys'}),
                       ('CLK_MEM', {'clk_mem'}), ('DDRAM_CLK', {'clk_mem'}), ('LOCKED', {'locked'})):
        rhs = assign_of(src, wire)
        if rhs is None:
            bad(wire, 'not assigned')
        elif terms(rhs) != want:
            bad(wire, 'is `%s`, expected exactly %s' % (rhs, sorted(want)))
    rhs = assign_of(src, 'reset_n')
    if rhs is None:
        bad('reset_n', 'not assigned')
    elif not {'locked', 'RESET', 'user_rst_qn'}.issubset(terms(rhs)):
        bad('reset_n', 'must combine locked, RESET and user_rst_qn; found `%s`' % rhs)

    name, conn = inst('sys_pll')
    if name is not None and name != 'sys_pll':
        bad('sys_pll', 'instance must be NAMED sys_pll (tools/fmax_check.sh finds clk_dec by '
                       'the hierarchical name emu|sys_pll|...); found %r' % name)
    if conn and terms(conn.get('outclk_3', '')) != {'clk_dec'}:
        bad('sys_pll', 'outclk_3 must be clk_dec (general[3] is what fmax_check gates)')

    # ---- hps_io ----
    par = params_of(src, 'hps_io')
    if not re.search(r'\.BLKSZ\s*\(\s*4\s*\)', par):
        bad('hps_io', 'must be instantiated with .BLKSZ(4): sd_lba in 2048-byte units = one '
                      'ISO sector per request, which every reader in this core assumes')
    if not re.search(r'\.CONF_STR\s*\(\s*CONF_STR\s*\)', par):
        bad('hps_io', 'must take .CONF_STR(CONF_STR)')
    name, conn = inst('hps_io')
    if conn:
        if terms(conn.get('TIMESTAMP', '')) != {'hps_timestamp'}:
            bad('hps_io.TIMESTAMP', 'must be hps_timestamp (the idle-screen month source)')
        if terms(conn.get('clk_sys', '')) != {'clk_sys'}:
            bad('hps_io.clk_sys', 'must be clk_sys')

    # ---- the raster and the idle screen ----
    name, conn = inst('sync_gen')
    if conn:
        if terms(conn.get('clk', '')) != {'clk_sys'}:
            bad('sync_gen.clk', 'must be clk_sys (27 MHz = the 480p dot clock)')
        # (its `interlaced` is the Video Output raster: the 480i section below)
    name, conn = inst('xmb_wave')
    if conn:
        if terms(conn.get('timestamp', '')) != {'hps_timestamp'}:
            bad('xmb_wave.timestamp', 'must be hps_timestamp -- otherwise the month tint is a constant')
        # .vis may be a named wire (wave_vis); follow ONE level of indirection
        vis = conn.get('vis', '')
        vis_terms = terms(vis)
        if len(vis_terms) == 1 and assign_of(src, next(iter(vis_terms))) is not None:
            vis_terms = terms(assign_of(src, next(iter(vis_terms))))
        if 'media_seen' not in vis_terms:
            bad('xmb_wave.vis', 'must depend on media_seen (the wave is the idle screen)')
        if terms(conn.get('clk', '')) != {'clk_sys'}:
            bad('xmb_wave.clk', 'must be clk_sys')
    name, conn = inst('dec_stub')
    if conn and terms(conn.get('clk_dec', '')) != {'clk_dec'}:
        bad('dec_stub.clk_dec', 'must be clk_dec -- it exists to keep a register in that domain')
    # ---- the P2 chain: reader -> fifo -> demux -> probe, and the HUD ----
    name, conn = inst('umd_reader')
    if not conn:
        bad('umd_reader', 'not instantiated -- nothing reads the mounted image')
    else:
        if 'start_streaming' not in terms(conn.get('start', '')):
            bad('umd_reader.start', 'must be start_streaming (a mount WITH media)')
        if 'img_ejected' not in terms(conn.get('stop', '')):
            bad('umd_reader.stop', 'must be img_ejected (an eject must stop the walk)')
        if terms(conn.get('file_size', '')) != {'img_size'}:
            bad('umd_reader.file_size', 'must be img_size')
        if terms(conn.get('sd_lba', '')) != {'sd_lba'} or terms(conn.get('sd_rd', '')) != {'sd_rd'}:
            bad('umd_reader', 'sd_lba/sd_rd must reach hps_io by those names')
        if terms(conn.get('busy', '')) != {'stream_busy', 'pc_rd_hold'}:
            bad('umd_reader.busy', 'must be the fifo\'s almost_full (stream_busy) OR player_ctl\'s hold '
                                   '(pc_rd_hold): a tied-off busy drops bytes the moment the demux '
                                   'stalls, and a seek\'s first bytes would enter a FIFO in reset')
        # P6b3: the navigation port is player_ctl's
        for port, want in (('nav_req', 'pc_nav_req'), ('nav_op', 'pc_nav_op'), ('nav_item', 'pc_nav_item'),
                           ('nav_pts', 'pc_nav_pts'), ('nav_ready', 'pc_nav_ready'), ('nav_done', 'pc_nav_done'),
                           ('nav_skip', 'rd_nav_skip'), ('ch_next', 'rd_ch_next')):
            if terms(conn.get(port, '')) != {want}:
                bad('umd_reader.' + port, 'must be %s (player_ctl drives the navigation port)' % want)
    name, conn = inst('ps_demux')
    if not conn:
        bad('ps_demux', 'not instantiated')
    else:
        # a floating aud_realign reads x and sends every audio PES down the realign branch
        if terms(conn.get('aud_realign', '')) != {'pc_realign'}:
            bad('ps_demux.aud_realign', 'must be player_ctl\'s realign (pc_realign): a track switch '
                                        'realigns on the new track\'s first access unit')
        if terms(conn.get('aud_track', '')) != {'aud_track'} or terms(assign_of(src, 'aud_track') or '') != {'pc_aud_track'}:
            bad('ps_demux.aud_track', 'must be player_ctl\'s track (aud_track = pc_aud_track)')
        rhs = assign_of(src, 'dmx_rst_n')
        if rhs is None or terms(rhs) != {'pipe_rst_n'}:
            bad('dmx_rst_n', 'must be pipe_rst_n: the demux restarts with a mount AND a seek')
        if terms(conn.get('in_byte', '')) != {'dmx_in_byte'}:
            bad('ps_demux.in_byte', 'must come from ps_stream_fifo (dmx_in_byte)')

    # ---- the P3 front end: demux -> vidfeed_cdc (clk_sys -> clk_dec) -> h264_top -> snapshot ----
    name, conn = inst('ps_demux')
    if conn and terms(conn.get('vid_ready', '')) != {'vid_ready'}:
        bad('ps_demux.vid_ready', 'must be the CDC FIFO\'s wr_ready (vid_ready), never a constant: '
                                  'a tied-off ready drops video bytes the moment the front end stalls')
    name, conn = inst('vidfeed_cdc')
    rd_rst = ''
    if not conn:
        bad('vidfeed_cdc', 'not instantiated -- nothing carries the video ES into clk_dec')
    else:
        if terms(conn.get('wr_clk', '')) != {'clk_sys'} or terms(conn.get('rd_clk', '')) != {'clk_dec'}:
            bad('vidfeed_cdc', 'wr_clk must be clk_sys and rd_clk clk_dec (the demux writes, the front end reads)')
        # P6a: the demux feeds the compressed-video buffer (vbuf), the vbuf feeds the CDC
        if not {'vb_byte', 'vb_mark', 'vb_pts'}.issubset(terms(conn.get('wr_data', ''))):
            bad('vidfeed_cdc.wr_data', 'must carry {vb_pts, vb_mark, vb_byte} from the vbuf (P5c: '
                                       'the PES PTS rides with its marked byte)')
        if terms(conn.get('wr_valid', '')) != {'vb_valid'} or terms(conn.get('wr_ready', '')) != {'vb_ready'}:
            bad('vidfeed_cdc', 'wr_valid/wr_ready must be the vbuf\'s out_valid/out_ready (vb_valid/vb_ready)')
        if terms(conn.get('wr_flush', '')) != {'vb_flush'}:
            bad('vidfeed_cdc.wr_flush', 'must be the vbuf\'s flush_out (vb_flush): the title\'s end, once '
                                        'every byte the vbuf holds is delivered')
    name, vconn = inst('vbuf')
    if not vconn:
        bad('vbuf', 'not instantiated -- the video path has no compressed buffer (S7.8: late audio)')
    else:
        for port, want in (('in_byte', 'vid_byte'), ('in_mark', 'vid_mark'), ('in_pts', 'vid_pts'),
                           ('in_valid', 'vid_valid'), ('in_ready', 'vid_ready'), ('flush_in', 'rd_done'),
                           ('out_byte', 'vb_byte'), ('out_mark', 'vb_mark'), ('out_pts', 'vb_pts'),
                           ('out_valid', 'vb_valid'), ('out_ready', 'vb_ready'), ('flush_out', 'vb_flush'),
                           ('clk', 'clk_sys'), ('rst_n', 'pipe_rst_n'), ('mclk', 'clk_mem'), ('mrst_n', 'mem_lock_n')):
            if terms(vconn.get(port, '')) != {want}:
                bad('vbuf.' + port, 'must be %s (the demux -> vbuf -> vidfeed_cdc chain; its clear per mount '
                                    'and per seek; the engine a DDR3 master reset with the PLL lock alone)' % want)
        rd_rst = conn.get('rd_rst_n', '')
        if terms(rd_rst) & {'reset_n', 'fe_rst_n', 'pipe_rst_n'}:
            bad('vidfeed_cdc.rd_rst_n', 'must come from cdc_reset (released on clk_dec), not a clk_sys reset')
        if terms(conn.get('wr_rst_n', '')) != {'pipe_rst_n'} or terms(rd_rst) != {'pipe_rst_dec_n'}:
            bad('vidfeed_cdc', 'both sides must reset with the pipeline (pipe_rst_n / pipe_rst_dec_n): a '
                               'seek empties the CDC')
    name, conn = inst('cdc_reset')
    if not conn:
        bad('cdc_reset', 'not instantiated -- the clk_dec side has no synchronised reset release')
    elif terms(conn.get('clk', '')) != {'clk_dec'}:
        bad('cdc_reset.clk', 'must be clk_dec')
    elif rd_rst and terms(conn.get('rst_n_out', '')) != terms(rd_rst):
        bad('cdc_reset.rst_n_out', 'must be the reset vidfeed_cdc\'s read side uses')
    name, conn = inst('h264_top')
    if not conn:
        bad('h264_top', 'not instantiated -- the front end is not in the build')
    else:
        if terms(conn.get('clk', '')) != {'clk_dec'}:
            bad('h264_top.clk', 'must be clk_dec (the 81 MHz compute domain the Fmax gate watches)')
        if rd_rst and terms(conn.get('rst_n', '')) != terms(rd_rst):
            bad('h264_top.rst_n', 'must be the same clk_dec reset as vidfeed_cdc\'s read side')
        if terms(conn.get('ps_rst_n', '')) != {'fe_rst_dec_n'}:
            bad('h264_top.ps_rst_n', 'must be the MOUNT\'s reset (fe_rst_dec_n): a seek keeps the parameter sets')
        if 'es_data' not in terms(conn.get('es_byte', '')):
            bad('h264_top.es_byte', 'must be vidfeed_cdc\'s rd_data')
        if terms(conn.get('es_valid', '')) != {'es_valid'} or terms(conn.get('es_ready', '')) != {'es_ready'}:
            bad('h264_top', 'es_valid/es_ready must be vidfeed_cdc\'s rd_valid/rd_ready')
        if terms(conn.get('es_flush', '')) != {'es_flush'}:
            bad('h264_top.es_flush', 'must be vidfeed_cdc\'s rd_flush')
        for port in ('es_mark', 'es_pts'):
            if 'es_data' not in terms(conn.get(port, '')):
                bad('h264_top.' + port, 'must come from vidfeed_cdc\'s rd_data (the mark / PTS ride with the byte); '
                                        'a constant tags no picture')
        if terms(conn.get('se_ready', '')) != {'se_ready'}:
            bad('h264_top.se_ready', 'must be the reconstruction\'s se_ready, never a constant: a '
                                     'tied-off ready drops syntax elements the moment recon stalls')
    name, conn = inst('cdc_snap')
    if not conn:
        bad('cdc_snap', 'not instantiated -- the front end\'s counters reach the HUD unsynchronised')
    else:
        if terms(conn.get('src_clk', '')) != {'clk_dec'} or terms(conn.get('dst_clk', '')) != {'clk_sys'}:
            bad('cdc_snap', 'src_clk must be clk_dec and dst_clk clk_sys')
        if not {'fe_slice', 'fe_err', 'fe_refused', 'se_words'}.issubset(terms(conn.get('src_data', ''))):
            bad('cdc_snap.src_data', 'must carry the slice, error, refusal and SE-word counters')

    # ---- P4: the reconstruction, the DDRAM port mux and the smoke display ----
    name, conn = inst('recon_top')
    if conn:
        # the reconstruction on clk_dec with the front end (the P4 smoke clocking on
        # clk_sys through umd/se_cdc.sv ended 2026-09-24, docs/h264_recon.md S4)
        if terms(conn.get('clk', '')) != {'clk_dec'} or terms(conn.get('mclk', '')) != {'clk_mem'}:
            bad('recon_top', 'clk must be clk_dec (with the front end) and mclk clk_mem')
        if terms(conn.get('rst_n', '')) != {'pipe_rst_dec_n'}:
            bad('recon_top.rst_n', 'must be the pipeline\'s reset of its clk_dec domain (pipe_rst_dec_n: '
                                   'a mount or a seek)')
        if terms(conn.get('ps_rst_n', '')) != {'fe_rst_dec_n'}:
            bad('recon_top.ps_rst_n', 'must be the MOUNT\'s reset (fe_rst_dec_n): a seek keeps the parameter sets')
        if terms(conn.get('mrst_n', '')) != {'pipe_rst_mem_n'}:
            bad('recon_top.mrst_n', 'must be the pipeline\'s reset released into clk_mem by a cdc_reset '
                                    '(pipe_rst_mem_n)')
        if terms(conn.get('se_valid', '')) != {'se_valid'} or terms(conn.get('se_ready', '')) != {'se_ready'}:
            bad('recon_top.se_valid/se_ready', 'must be h264_top\'s se_valid / se_ready (the same clock)')
        if terms(conn.get('disp_hold', '')) != {'disp_hold'}:
            bad('recon_top.disp_hold', 'must be the display\'s held stores (else the decoder '
                                       'overwrites the picture on screen)')
        # P6b3i: the display's freeze, synchronised into clk_dec by two flops, so a pause's
        # holds are not counted as err_no_store (transport.md S9)
        if terms(conn.get('disp_frz', '')) != {'frz_dec_s'} or not re.search(
                r'always\s*@\s*\(\s*posedge\s+clk_dec\s*\)\s*frz_dec_s\s*<=\s*\{\s*frz_dec_s\[0\]\s*,\s*ds_frz\s*\}\s*;', src):
            bad('recon_top.disp_frz', 'must be the display\'s freeze (ds_frz) through two clk_dec flops '
                                      '(frz_dec_s): else a pause counts decode errors (P6b3i)')
    # P5d: the output queue (umd/recon_out.sv) -- the only way a store reaches the display
    # and the only source of the decoder's holds; its two sides on their own clocks
    name, conn = inst('recon_out')
    if conn:
        if terms(conn.get('clk', '')) != {'clk_dec'} or terms(conn.get('sclk', '')) != {'clk_sys'}:
            bad('recon_out', 'clk must be clk_dec (the reconstruction) and sclk clk_sys (the display)')
        if terms(conn.get('rst_n', '')) != {'fe_rst_dec_n'} or terms(conn.get('srst_n', '')) != {'fe_rst_n'}:
            bad('recon_out', 'resets must be the per-mount ones of each domain (fe_rst_dec_n / fe_rst_n)')
        if terms(conn.get('oq_hold', '')) != {'disp_hold'} or assign_of(src, 'disp_hold') is not None:
            bad('recon_out.oq_hold', 'must drive disp_hold, and nothing else may (a store emitted to the '
                                     'display must stay out of the decoder\'s reach until released)')
        rc = inst('recon_top')[1]
        for p in ('emit_valid', 'emit_store', 'pinfo_we', 'pinfo_store', 'eos_done'):
            if not terms(conn.get(p, '')) or terms(conn.get(p, '')) != terms(rc.get(p, '-')):
                bad('recon_out.' + p, 'must be recon_top\'s %s' % p)
        for p in ('rel_valid', 'rel_store', 'rec_take'):
            t = terms(conn.get(p, ''))
            if not t or all(re.match(r'^[bdh]\d*$', x) or x.isdigit() for x in t):
                bad('recon_out.' + p, 'must come from the display (a constant release leaves every store '
                                      'held -- the decoder stalls -- or frees stores still on screen)')
    else:
        bad('recon_out', 'not instantiated -- no store reaches the display in output order')
    # P5e: the display's control on the raster's clock, its decisions to the reader
    name, conn = inst('disp_ctl')
    if conn:
        if terms(conn.get('clk', '')) != {'clk_sys'} or terms(conn.get('rst_n', '')) != {'fe_rst_n'}:
            bad('disp_ctl', 'must run on clk_sys (the raster, the 90 kHz tick phased to it) with the mount reset')
        rd = inst('disp_reader')[1]
        for p, r in (('sh_store', 'pic_store'), ('sh_field', 'pic_field'), ('sh_parity', 'pic_parity'),
                     ('sh_valid', 'pic_valid'), ('sh_single', 'pic_single'),
                     # fj#80 field matching (docs/telecine.md S5): the lock's choice, to the reader
                     ('sh_match', 'pic_match'), ('sh_pstore', 'pic_pstore'), ('sh_film', 'pic_film')):
            if not terms(conn.get(p, '')) or terms(conn.get(p, '')) != terms(rd.get(r, '-')):
                bad('disp_reader.' + r, 'must be disp_ctl\'s %s (the store and field it decided)' % p)
        # fj#80: the lock's evidence is the reader's comb sums of the refresh it fetched
        for p, r in (('cm_c', 'cm_c'), ('cm_r', 'cm_r'), ('cm_v', 'cm_v')):
            if not terms(conn.get(p, '')) or terms(conn.get(p, '')) != terms(rd.get(r, '-')):
                bad('disp_ctl.' + p, 'must be disp_reader\'s %s (the comb sums: fj#80)' % r)
        # P5f: the deinterlace mode is the menu's own bits (the CONF_STR line's O[hi:lo])
        m = re.search(r'"(?:[HhDd]\d)*O\[(\d+):(\d+)\],Deinterlace,Weave,Bob,Blend;"', src)
        want = 'status[%s:%s]' % m.groups() if m else None
        if want is None or rd.get('deint_mode', '').replace(' ', '') != want:
            bad('disp_reader.deint_mode', 'must be the Deinterlace option\'s status bits (%s), got %r'
                % (want, rd.get('deint_mode')))
    else:
        bad('disp_ctl', 'not instantiated -- nothing paces the display')
    # HIL telemetry: the responder on hps_io's clock and EXT_BUS; the DDR3 probes on the
    # ports' own wires (what the HPS sees), their counters crossing in a cdc_snap
    name, conn = inst('umd_telem')
    if conn:
        if terms(conn.get('clk', '')) != {'clk_sys'}:
            bad('umd_telem.clk', 'must be clk_sys (hps_io\'s clock)')
        for p, bit in (('io_enable', '34'), ('io_strobe', '33')):
            if conn.get(p, '').replace(' ', '') != 'ext_bus[%s]' % bit:
                bad('umd_telem.' + p, 'must be EXT_BUS[%s] (hps_io)' % bit)
        hconn = inst('hps_io')[1]
        if terms(hconn.get('EXT_BUS', '')) != {'ext_bus'}:
            bad('hps_io.EXT_BUS', 'must be ext_bus, the responder\'s bus')
        # P6b7: the landing and the seek gate's words carry player_ctl's own values, the HUD's
        # flags transport_hud's, in the table's bit order (tools/telem_layout.py)
        pconn = inst('player_ctl')[1]
        for tp, pp in (('t_land', 'land_pts'), ('t_slat', 'seek_lat'), ('t_wd', 'n_wd')):
            if not terms(conn.get(tp, '')) or terms(conn.get(tp, '')) != terms(pconn.get(pp, '-')):
                bad('umd_telem.' + tp, 'must be player_ctl\'s %s' % pp)
        hconn2 = inst('transport_hud')[1]
        want = [hconn2.get(p, '-').strip() for p in ('display', 't_ph', 't_bad', 't_cut')]
        got = [x.strip() for x in conn.get('t_hud', '').strip().strip('{}').split(',')]
        if got != want:
            bad('umd_telem.t_hud', 'must be {display, t_ph, t_bad, t_cut} of transport_hud, got %r' % got)
        # the decoder's recovery-point counts are clk_dec values: read on clk_sys only as a
        # cdc_snap's copy
        snap_dst = set()
        for _, b in find_instances(src, 'cdc_snap'):
            if b is not None:
                snap_dst |= terms(connections(b).get('dst_data', ''))
        # (and the names a concatenation assign splits a snapshot's bus into: fe_snap -> sn_slice ...)
        for lhs, rhs in re.findall(r'\bassign\s*\{([^}]*)\}\s*=\s*(\w+)\s*;', src):
            if rhs in snap_dst:
                snap_dst |= terms(lhs)
        # (A11: the slice, picture-timing, emitted and fetched counts too -- the diagnostic HUD's
        #  rows that read them left the core; telemetry keeps them, the same rule)
        for tp in ('t_rlead', 't_rpre', 't_rnidr', 't_rmmco', 't_slices', 't_pt', 't_emitted', 't_ft'):
            t = terms(conn.get(tp, ''))
            if not t or not t <= snap_dst:
                bad('umd_telem.' + tp, 'must be a cdc_snap copy (a clk_dec count), got %r' % conn.get(tp))
    else:
        bad('umd_telem', 'not instantiated -- the HIL telemetry has no responder')
    probes = [connections(b) for _, b in find_instances(src, 'ddr_probe') if b is not None]
    seen = set()
    for c in probes:
        if terms(c.get('clk', '')) != {'clk_mem'}:
            bad('ddr_probe', 'must run on clk_mem (the ports\' clock)')
        for p, w in (('read', 'RD'), ('waitrequest', 'BUSY'), ('readdatavalid', 'DOUT_READY'),
                     ('burstcount', 'BURSTCNT'), ('write', 'WE')):
            t = terms(c.get(p, ''))
            port = [x for x in t if x in ('DDRAM_' + w, 'DDRAM2_' + w)]
            if not port:
                bad('ddr_probe.' + p, 'must watch the port wire DDRAM*_%s itself (what the HPS sees)' % w)
            else:
                seen.add(port[0].split('_')[0])
    if seen != {'DDRAM', 'DDRAM2'}:
        bad('ddr_probe', 'one probe per DDR3 port (DDRAM and DDRAM2), found %s' % sorted(seen))
    snaps_t = [connections(b) for _, b in find_instances(src, 'cdc_snap') if b is not None]
    for sig in ('d1_wr', 'd2_rdb'):
        found = [c for c in snaps_t if sig in terms(c.get('src_data', ''))]
        if not found or any(terms(c.get('src_clk', '')) != {'clk_mem'} or terms(c.get('dst_clk', '')) != {'clk_sys'}
                            for c in found):
            bad('cdc_snap', 'the DDR3 probe counters (%s) cross clk_mem -> clk_sys in a cdc_snap' % sig)
    # its clk_dec values reach clk_sys (the HUD) only through cdc_snap copies
    snaps = [connections(b) for _, b in find_instances(src, 'cdc_snap') if b is not None]
    def snap_of(sig):
        return [c for c in snaps if sig in terms(c.get('src_data', ''))]
    for sig, what in (('rc_pics', 'the reconstruction\'s counters'), ('rc_stall', 'the output process\'s counters'),
                      ('rc_lead_s', 'the landing\'s recovery-point counts (P6b7)')):
        found = snap_of(sig)
        if not found:
            bad('cdc_snap', '%s (%s) must cross in a cdc_snap' % (what, sig))
        for c in found:
            if terms(c.get('src_clk', '')) != {'clk_dec'} or terms(c.get('dst_clk', '')) != {'clk_sys'}:
                bad('cdc_snap', 'the reconstruction\'s values cross clk_dec -> clk_sys')
    # The masters that drive a DDR3 port directly reset with the PLL lock ALONE: a master
    # reset while the port holds its request under waitrequest withdraws the request, and
    # the HPS f2sdram port then stops returning read beats (the reload hang,
    # docs/hil_harness.md). The lock-only reset is a cdc_reset of `locked` into clk_mem.
    lock_rst = None
    for _, b in find_instances(src, 'cdc_reset'):
        c = connections(b) if b is not None else {}
        if terms(c.get('rst_n_in', '')) == {'locked'} and terms(c.get('clk', '')) == {'clk_mem'}:
            lock_rst = terms(c.get('rst_n_out', ''))
    if not lock_rst:
        bad('cdc_reset', 'no lock-only clk_mem reset (a cdc_reset of `locked` alone): the DDR3 '
                         'masters would reset with RESET and withdraw a held request')
    name, conn = inst('ddr_mux2')
    if conn:
        if terms(conn.get('clk', '')) != {'clk_mem'}:
            bad('ddr_mux2.clk', 'must be clk_mem (the DDRAM port clock)')
        if lock_rst and terms(conn.get('rst_n', '')) != lock_rst:
            bad('ddr_mux2.rst_n', 'must be the lock-only clk_mem reset (%s): a reset with the '
                                  'mount or RESET withdraws a request held under waitrequest '
                                  '(a_abort handles the mount)' % sorted(lock_rst))
        ab = conn.get('a_abort', '')
        if not ab.strip() or not any(t for t in terms(ab) if not re.match(r'^[bdh]\d*$', t)):
            bad('ddr_mux2.a_abort', 'must follow the mount reset (never a constant)')
        # the abort register itself: reset with the lock only, or RESET would clear the
        # abort exactly when the decoder's master is being reset
        ab_reg = re.match(r'\s*(\w+)', ab)
        if lock_rst and ab_reg:
            m = re.search(r'always\s*@\s*\(\s*posedge\s+clk_mem\s+or\s+negedge\s+(\w+)\s*\)'
                          r'\s*begin\s*if\s*\(\s*!\s*\w+\s*\)\s*%s\s*<=' % re.escape(ab_reg.group(1)), src)
            if not m or {m.group(1)} != lock_rst:
                bad('ddr_mux2.a_abort', 'its register (%s) must reset with the lock-only clk_mem reset'
                    % ab_reg.group(1))
        for a, w in (('ddr_address', 'DDRAM_ADDR'), ('ddr_read', 'DDRAM_RD'), ('ddr_write', 'DDRAM_WE'),
                     ('ddr_waitrequest', 'DDRAM_BUSY'), ('ddr_readdatavalid', 'DDRAM_DOUT_READY'),
                     ('ddr_byteenable', 'DDRAM_BE'), ('ddr_burstcount', 'DDRAM_BURSTCNT')):
            if terms(conn.get(a, '')) != {w}:
                bad('ddr_mux2.' + a, 'must be %s' % w)
    else:
        bad('ddr_mux2', 'not instantiated -- nothing drives the DDRAM port')
    name, conn = inst('disp_reader')
    if conn:
        if terms(conn.get('clk', '')) != {'clk_sys'} or terms(conn.get('mclk', '')) != {'clk_mem'}:
            bad('disp_reader', 'clk must be clk_sys (the raster) and mclk clk_mem')
        # the display reads through its OWN port, ram2 (docs/hw_budget_and_lessons.md S2); since
        # P7 through the subtitle overlay's read merge, video first (docs/compositor.md §8):
        # disp_reader's master IS sub_overlay's v_* (the same nets), sub_overlay drives DDRAM2
        _, oconn = inst('sub_overlay')
        if oconn:
            for a, v in (('ddr_address', 'v_address'), ('ddr_read', 'v_read'),
                         ('ddr_burstcount', 'v_burstcount'), ('ddr_waitrequest', 'v_waitrequest'),
                         ('ddr_readdata', 'v_readdata'), ('ddr_readdatavalid', 'v_readdatavalid')):
                if not terms(conn.get(a, '')) or terms(conn.get(a, '')) != terms(oconn.get(v, '')):
                    bad('disp_reader.' + a, 'must be sub_overlay\'s %s (the video is the read merge\'s '
                                            'first input on ram2)' % v)
        else:
            bad('sub_overlay', 'not instantiated -- ram2 has no master and no subtitles show')
        if lock_rst and terms(conn.get('mrst_n', '')) != lock_rst:
            bad('disp_reader.mrst_n', 'must be the lock-only clk_mem reset (%s): its fetch side '
                                      'drives ram2 and must never withdraw a held read' % sorted(lock_rst))
        if terms(conn.get('pic_field', '')) != {'sh_field'}:
            bad('disp_reader.pic_field', 'must be the latched picture\'s field flag (sh_field): a '
                                         'constant sites a field pair\'s chroma on the frame grid')
    else:
        bad('disp_reader', 'not instantiated -- nothing shows a picture')
    name, conn = inst('ddr_mux2')
    # P6a: master B is the vbuf's engine (the display is on ram2)
    for port in ('b_address', 'b_burstcount', 'b_read', 'b_write', 'b_writedata', 'b_waitrequest',
                 'b_readdata', 'b_readdatavalid'):
        if conn and vconn and (not terms(conn.get(port, '')) or terms(conn.get(port, '')) != terms(vconn.get(port, ''))):
            bad('ddr_mux2.' + port, 'master B must be the vbuf\'s engine (%s)' % port)
    rhs = assign_of(src, 'DDRAM2_CLK')
    if rhs is None:
        bad('DDRAM2_CLK', 'not assigned')
    elif terms(rhs) != {'clk_mem'}:
        bad('DDRAM2_CLK', 'is `%s`, expected exactly clk_mem' % rhs)
    # P7: ram2 is the subtitle overlay's port (its read merge + ddr_mux2 B_FIRST), read AND write
    _, oconn = inst('sub_overlay')
    if oconn:
        for a, w in (('ddr_address', 'DDRAM2_ADDR'), ('ddr_read', 'DDRAM2_RD'), ('ddr_write', 'DDRAM2_WE'),
                     ('ddr_writedata', 'DDRAM2_DIN'), ('ddr_byteenable', 'DDRAM2_BE'),
                     ('ddr_burstcount', 'DDRAM2_BURSTCNT'), ('ddr_waitrequest', 'DDRAM2_BUSY'),
                     ('ddr_readdata', 'DDRAM2_DOUT'), ('ddr_readdatavalid', 'DDRAM2_DOUT_READY')):
            if terms(oconn.get(a, '')) != {w}:
                bad('sub_overlay.' + a, 'must be %s (ram2 is the overlay\'s port)' % w)
        for a in ('DDRAM2_WE', 'DDRAM2_DIN', 'DDRAM2_BE'):
            if assign_of(src, a) is not None:
                bad(a, 'also assigned: two drivers with the overlay\'s writer')
        if lock_rst and terms(oconn.get('mrst_n', '')) != lock_rst:
            bad('sub_overlay.mrst_n', 'must be the lock-only clk_mem reset (%s): it drives ram2' % sorted(lock_rst))
        # its clk_sys sides pair with mclk sides across fifo_dc / toggle handshakes: the SAME lock
        lock_sys = None
        for _, b in find_instances(src, 'cdc_reset'):
            c = connections(b) if b is not None else {}
            if terms(c.get('rst_n_in', '')) == {'locked'} and terms(c.get('clk', '')) == {'clk_sys'}:
                lock_sys = terms(c.get('rst_n_out', ''))
        for a in ('srst_n', 'rst_n'):
            if not lock_sys or terms(oconn.get(a, '')) != lock_sys:
                bad('sub_overlay.' + a, 'must be the lock-only clk_sys reset (a cdc_reset of `locked` on '
                                        'clk_sys): its FIFOs / handshakes pair with mem_lock_n sides')
        # a mount or a seek is a flush, on clk_mem and registered (pipe_rst_mem_n asserts async)
        fl = terms(oconn.get('flush', ''))
        if not fl or not any(t.startswith('sb_flush') for t in fl):
            bad('sub_overlay.flush', 'must be the registered clk_mem copy of the mount / seek reset (sb_flush_q)')
        for a, want in (('sclk', 'clk_sys'), ('clk', 'clk_sys'), ('mclk', 'clk_mem')):
            if terms(oconn.get(a, '')) != {want}:
                bad('sub_overlay.' + a, 'must be %s' % want)
        # A7 (docs/hps_host.md §2, §3.2): the host port on hps_io's clock and EXT_BUS, its
        # subtitle side on the overlay's own handshake nets, both sides on the lock-only resets
        # (the completion's toggle and its clk_mem copy must start together)
        _, hc = inst('umd_host')
        if hc:
            for a, want in (('clk', 'clk_sys'), ('mclk', 'clk_mem')):
                if terms(hc.get(a, '')) != {want}:
                    bad('umd_host.' + a, 'must be %s' % want)
            for p_, bit in (('io_enable', '34'), ('io_strobe', '33'), ('io_din', '31:16')):
                if hc.get(p_, '').replace(' ', '') != 'ext_bus[%s]' % bit:
                    bad('umd_host.' + p_, 'must be EXT_BUS[%s] (hps_io)' % bit)
            if not lock_sys or terms(hc.get('rst_n', '')) != lock_sys:
                bad('umd_host.rst_n', 'must be the lock-only clk_sys reset (the overlay\'s)')
            if lock_rst and terms(hc.get('mrst_n', '')) != lock_rst:
                bad('umd_host.mrst_n', 'must be the lock-only clk_mem reset (%s)' % sorted(lock_rst))
            # A12 SD1 (docs/nav_engine.md §10): the fabric decodes (sub_dec); the UMD Main is never asked,
            # so it never writes a plane the fabric writes
            if hc.get('h_req', '').replace(' ', '') != "1'b0":
                bad('umd_host.h_req', "must be 1'b0 (A12 SD1: the fabric decodes; the UMD Main is never asked)")
            if terms(oconn.get('pclk', '')) != {'clk_sys'}:
                bad('sub_overlay.pclk', "must be clk_sys (png_top's clock, as before A7)")
            for hp, op in (('h_seq', 'h_seq'), ('h_buf', 'h_buf'), ('h_x', 'h_x'),
                           ('h_y', 'h_y'), ('h_start', 'h_start'), ('h_len', 'h_len'), ('h_gen', 'h_gen'),
                           ('h_vis', 'h_vis'), ('h_shown_seq', 'h_shown_seq'), ('n_stale', 'n_stale'),
                           ('h_sbuf', 'h_sbuf'), ('h_sx', 'h_sx'), ('h_sy', 'h_sy'), ('h_sw', 'h_sw'), ('h_sh', 'h_sh'),
                           ('h_done', 'h_done'), ('h_done_seq', 'h_done_seq'), ('h_done_err', 'h_done_err'),
                           ('h_done_w', 'h_done_w'), ('h_done_h', 'h_done_h')):
                if not terms(hc.get(hp, '')) or terms(hc.get(hp, '')) != terms(oconn.get(op, '-')):
                    bad('umd_host.' + hp, 'must be sub_overlay\'s %s (the same net)' % op)
            pc = inst('player_ctl')[1]
            # A12 SD3: SUB no longer needs the UMD Main (the fabric decodes)
            if pc.get('host_ok', '').replace(' ', '') != "1'b1":
                bad('player_ctl.host_ok', "must be 1'b1 (A12 SD3: subtitles need no UMD Main)")
            if not terms(pc.get('host_bad', '')) or terms(pc.get('host_bad', '')) != terms(hc.get('host_bad', '-')):
                bad('player_ctl.host_bad', 'must be umd_host\'s host_bad')
            # both responders reach the bus: [32] the OR of their drives
            rhs = assign_of(src, 'ext_bus[32]')
            if rhs is None or not {hc.get('drive', '-').strip(), inst('umd_telem')[1].get('drive', '-').strip()} <= terms(rhs):
                bad('ext_bus[32]', 'must OR umd_telem\'s and umd_host\'s drive, got %r' % rhs)
        else:
            bad('umd_host', 'not instantiated -- the UMD Main has no door (no subtitles)')
    # P7: the raster at LAT 7. The pixel-only consumers take the copy delayed 3 (h_pos_l7 ...);
    # whatever talks to the display scheduler or a reader stays on the undelayed raster
    # (docs/subtitles.md §7): a mix-up shifts a layer by 3 dots, or the picture itself.
    for mod, want in (('xmb_wave', 'h_col_l7'), ('transport_hud', 'h_col_l7'),
                      ('disp_ctl', 'h_pos'), ('disp_reader', 'h_pos'), ('sub_overlay', 'h_pos')):
        _, c = inst(mod)
        if c and terms(c.get('h_pos', '')) != {want}:
            bad(mod + '.h_pos', 'must be %s (%s)' % (want, 'the LAT 7 copy: a pixel layer over the composite'
                                                      if want.endswith('_l7') else 'the undelayed raster'))
    # ---- the 480i raster (docs/analog.md, S1) ----
    rhs = assign_of(src, 'interlaced_eff')
    if rhs is None or 'analog_want_l' not in terms(rhs) or 'analog_want_raw' in terms(rhs):
        bad('interlaced_eff', 'Auto must take the LATCHED ini wish (analog_want_l): Main re-sends its cfg '
                              'on every resolution report, a live wire switches the raster under a title')
    if not re.search(r'cfg_seen\s*&&\s*!\s*sh_valid\s*\)\s*analog_want_l\s*<=\s*analog_want_raw', src):
        bad('analog_want_l', 'must latch analog_want_raw only while no picture is shown (cfg_seen && !sh_valid)')
    for mod in ('sync_gen',):
        _, c = inst(mod)
        if c and terms(c.get('interlaced', '')) != {'interlaced_eff'}:
            bad(mod + '.interlaced', 'must be interlaced_eff (the Video Output raster)')
    for mod in ('disp_ctl', 'disp_reader', 'sub_overlay', 'transport_hud'):
        _, c = inst(mod)
        if c and terms(c.get('il', '')) != {'interlaced_eff'}:
            bad(mod + '.il', 'must be interlaced_eff: the module reads the raster\'s dots and lines')
    _, c = inst('disp_reader')
    if c and terms(c.get('pic_still', '')) != {'ds_frz'}:
        bad('disp_reader.pic_still', 'must be the display\'s freeze (ds_frz): a paused pair shows one field')
    _, c = inst('hps_io')
    if c and 'interlaced_eff' not in terms(c.get('status_menumask', '')):
        bad('hps_io.status_menumask', 'bit 0 must be the raster (the H0 / h0 deinterlace lines)')
    if c and not re.search(r"\{\s*14'd0\s*,\s*host_ok\s*,\s*interlaced_eff\s*\}", c.get('status_menumask', '')):
        bad('hps_io.status_menumask', "must be {14'd0, host_ok, interlaced_eff}: bit 1 the UMD Main (Disc Menus' h1, P9 M3b)")
    rhs = assign_of(src, 'h_col_l7')
    if rhs is None or 'interlaced_eff' not in terms(rhs):
        bad('h_col_l7', 'the pixel layers\' column must halve h_pos at 480i (interlaced_eff)')
    rhs = assign_of(src, 'HDMI_BOB_DEINT')
    if rhs is None or not {'interlaced_eff', 'status'} <= terms(rhs):
        bad('HDMI_BOB_DEINT', 'must be the 480i raster AND its menu bit')
    # the output stage: CE_PIXEL, VGA_F1, VGA_HS, VGA_DE sampled from the same delay tap, and
    # csync_smpte fed the hsync VGA_HS's register takes
    taps = {}
    for port, reg_ in (('CE_PIXEL', 'ce'), ('VGA_F1', 'f1'), ('VGA_HS', 'hs'), ('VGA_DE', 'de')):
        rhs = assign_of(src, port)
        m = re.search(r'\b%s\s*<=\s*%s_dly\[(\d+)\]\s*;' % (re.escape((rhs or '').strip()), reg_), src)
        taps[port] = m.group(1) if m else None
    if None in taps.values() or len(set(taps.values())) != 1:
        bad('output stage', 'CE_PIXEL / VGA_F1 / VGA_HS / VGA_DE must come from one delay tap: %s' % taps)
    _, c = inst('csync_smpte')
    if not c:
        bad('csync_smpte', 'not instantiated: the 480i raster has the stock csync (fields ~50 / ~18 us)')
    else:
        if taps.get('VGA_HS') is None or c.get('h_sync', '').replace(' ', '') != 'hs_dly[%s]' % taps['VGA_HS']:
            bad('csync_smpte.h_sync', 'must be the hsync VGA_HS\'s register takes (hs_dly[%s]), got %r'
                % (taps.get('VGA_HS'), c.get('h_sync')))
        if terms(c.get('en', '')) != {'interlaced_eff'}:
            bad('csync_smpte.en', 'must be interlaced_eff alone (480p keeps the framework\'s csync)')
        for port, want in (('VGA_CS', 'cs_smpte'), ('VGA_CS_EN', 'cs_smpte_en')):
            if terms(assign_of(src, port) or '') != {want}:
                bad(port, 'must be csync_smpte\'s %s' % want)
    # VGA_DE: follow the output register to what it samples (one level)
    rhs = assign_of(src, 'VGA_DE')
    de_terms = terms(rhs or '')
    if len(de_terms) == 1:
        m = re.search(r'\b%s\s*<=\s*([^;]+);' % re.escape(next(iter(de_terms))), src)
        if m:
            de_terms = terms(m.group(1))
    if rhs is None:
        bad('VGA_DE', 'not assigned')
    elif 'wave_de' in de_terms or not de_terms & {'de_dly'}:
        bad('VGA_DE', 'must be the raster\'s delayed active area (de_dly), not the idle wave\'s '
                      'output; found %s' % sorted(de_terms))

    # P5b: Auto's aspect from the SHOWN picture's VUI (the display latch sh_*)
    name, conn = inst('aspect_vui')
    if conn:
        for port, want in (('aspect_idc', 'sh_ar_idc'), ('ext_sar_w', 'sh_sar_w'), ('ext_sar_h', 'sh_sar_h'),
                           ('w_mbs', 'sh_w'), ('hf_mbs', 'sh_hf'), ('valid', 'sh_valid'), ('clk', 'clk_sys')):
            if terms(conn.get(port, '')) != {want}:
                bad('aspect_vui.' + port, 'must be %s (the shown picture, on clk_sys)' % want)
        rhs = assign_of(src, 'auto_wide')
        if rhs is None or not {'vui_sar_known', 'vui_wide'}.issubset(terms(rhs)):
            bad('auto_wide', 'Auto must take the VUI aspect (vui_sar_known / vui_wide) when media is loaded')
        # P9: under a disc menu 16:9 (a menu is drawn in 16:9), Analog Aspect Fit (the plane does not move)
        if rhs is None or 'host_menu' not in terms(rhs):
            bad('auto_wide', 'Auto must be 16:9 under a disc menu (host_menu, P9)')
        rhs = assign_of(src, 'aa_mode')
        if rhs is None or 'host_menu' not in terms(rhs):
            bad('aa_mode', 'Analog Aspect must be Fit under a disc menu (host_menu, P9)')
        # ... the host fitting the menu itself at 480i unless Analog Aspect is Fit (menu_aa), the
        # raster then 4:3 to HDMI as for the reader's Letterbox (analog.md S7)
        rhs = assign_of(src, 'menu_aa')
        if rhs is None or not re.fullmatch(r"!interlaced_eff\s*\?\s*2'd0\s*:\s*\(status\[10:9\]\s*==\s*2'd1\)\s*\?\s*2'd0\s*:\s*"
                                           r"\(status\[10:9\]\s*==\s*2'd3\)\s*\?\s*2'd2\s*:\s*2'd1", rhs.strip()):
            bad('menu_aa', 'must be 0 at 480p or under Fit, 2 under Crop, else 1 (Auto, Letterbox) (P9)')
        rhs = assign_of(src, 'menu_aa_on')
        if rhs is None or not re.fullmatch(r"host_menu\s*&&\s*\(menu_aa\s*!=\s*2'd0\)", rhs.strip()):
            bad('menu_aa_on', "must be host_menu && (menu_aa != 2'd0) (P9)")
        for w in ('VIDEO_ARX', 'VIDEO_ARY'):
            rhs = assign_of(src, w)
            if rhs is None or not {'aa_live', 'menu_aa_on'}.issubset(terms(rhs)):
                bad(w, '4:3 while the reader fits the picture (aa_live) or the host a menu (menu_aa_on, P9)')
    else:
        bad('aspect_vui', 'not instantiated -- Auto ignores the stream\'s aspect')

    # ---- fj#71 Zoom (docs/zoom.md): Aspect Ratio's fourth value, a 4:3 picture's lines 60 .. 419 at 16:9 ----
    if '"O[2:1],Aspect Ratio,Auto,4:3,16:9,Zoom;"' not in src:
        bad('CONF_STR', 'Aspect Ratio must offer Zoom as its fourth value (O[2:1] = 3, fj#71)')
    _, zc = inst('zoom_ctl')
    if zc:
        if not re.fullmatch(r"status\[2:1\]\s*==\s*2'd3", zc.get('sel', '').strip()):
            bad('zoom_ctl.sel', "must be status[2:1] == 2'd3 (Aspect Ratio's Zoom)")
        for port, want in (('il', 'interlaced_eff'), ('media_seen', 'media_seen'), ('stopped', 'pc_idle'),
                           ('host_menu', 'host_menu'), ('sh_valid', 'sh_valid'), ('pic_wide', 'pic_wide'),
                           ('sh_w', 'sh_w'), ('sh_hf', 'sh_hf'), ('v_pos', 'v_pos'), ('clk', 'clk_sys'),
                           ('zoom', 'zoom'), ('cut', 'zoom_cut')):
            if terms(zc.get(port, '')) != {want}:
                bad('zoom_ctl.' + port, 'must be %s (fj#71: %s)' % (want, {
                    'il': 'off at 480i', 'stopped': 'never over the disc screen / the wave (NOT host_ui: the panel)',
                    'host_menu': 'off under a disc menu', 'v_pos': 'the undelayed raster, delayed with DE'}.get(port, 'the gating table')))
        if not {'h_pos', 'v_pos'} <= terms(zc.get('vbl', '')):
            bad('zoom_ctl.vbl', 'must be a vblank strobe on the raster (the one sub_overlay\'s flips use)')
        m = re.search(r'\bde_dly\s*<=\s*\{[^;]*\};', src)
        if not m or 'zoom_cut' not in terms(m.group(0).split('<=', 1)[1]):
            bad('de_dly', 'must drop the lines Zoom cuts (pixel_en & ~zoom_cut): the scaler captures by DE (fj#71)')
        m = re.search(r'\bcut_dly\s*<=\s*\{[^;]*\};', src)
        if not m or 'zoom_cut' not in terms(m.group(0).split('<=', 1)[1]):
            bad('cut_dly', 'must delay zoom_cut with DE (LAT 7): the cut lines blanked in RGB (fj#71 Z5)')
        for ch in ('r', 'g', 'b'):
            if not re.search(r'vga_%s_q\s*<=\s*cut_dly\[6\]\s*\?\s*8\'d0' % ch, src):
                bad('vga_%s_q' % ch, 'the cut lines must be black (cut_dly[6]): the analog pins are not DE-gated (fj#71 Z5)')
        for w in ('VIDEO_ARX', 'VIDEO_ARY'):
            if 'zoom' not in terms(assign_of(src, w) or ''):
                bad(w, '16:9 under Zoom (zoom: 4 * 480 : 3 * 360, fj#71)')
        _, hc71 = inst('transport_hud')
        if hc71:
            if terms(hc71.get('safe', '')) != {'interlaced_eff', 'zoom'}:
                bad('transport_hud.safe', 'must be interlaced_eff | zoom: the title-safe layout at 480i and inside Zoom\'s band (fj#71)')
            if terms(hc71.get('v_pos', '')) != {'hud_v_pos'} or \
                    not {'zoom', 'v_pos_l7'} <= terms(assign_of(src, 'hud_v_pos') or ''):
                bad('transport_hud.v_pos', 'must be hud_v_pos, v_pos_l7 moved under Zoom (the layout inside 60 .. 419, fj#71)')
        for mod in ('sub_overlay', 'umd_host'):
            if terms(inst(mod)[1].get('zoom', '')) != {'zoom'}:
                bad(mod + '.zoom', 'must be zoom: the subtitle moved inside the band (%s, fj#71 Z3)'
                    % ('the fabric\'s' if mod == 'sub_overlay' else 'the UMD Main\'s, under the panel'))
    else:
        bad('zoom_ctl', 'not instantiated -- Aspect Ratio\'s Zoom does nothing (fj#71)')

    # ---- P6a: the audio path (docs/at3p_decoder.md S7) ----
    name, conn = inst('ps_demux')
    if conn and terms(conn.get('aud_ready', '')) != {'aud_ready'}:
        bad('ps_demux.aud_ready', 'must be the audio ring\'s in_ready (aud_ready), never a constant: '
                                  'a tied 1 loses bytes the moment the ring fills')
    name, rconn = inst('aud_ring')
    name, dconn = inst('at3p_top')
    name, oconn = inst('aud_out')
    if rconn and dconn and oconn:
        if terms(rconn.get('in_ready', '')) != {'aud_ready'}:
            bad('aud_ring.in_ready', 'must drive aud_ready (the demux\'s audio back-pressure)')
        for mod, c in (('aud_ring', rconn), ('at3p_top', dconn), ('aud_out', oconn)):
            if terms(c.get('clk', '')) != {'clk_sys'}:
                bad(mod + '.clk', 'must be clk_sys (the demux\'s and the STC\'s clock)')
            if terms(c.get('rst_n', '')) != {'aud_rst_n'}:
                bad(mod + '.rst_n', 'must be aud_rst_n: the ring\'s framer, the decoder and the gate '
                                    'restart with the demux\'s realign, per mount, per seek and per track switch')
        rhs = assign_of(src, 'aud_rst_n')
        if rhs is None or terms(rhs) != {'pipe_rst_n', 'pc_aud_rst'}:
            bad('aud_rst_n', 'must be pipe_rst_n & ~pc_aud_rst')
        if terms(oconn.get('freeze', '')) != {'ds_frz'}:
            bad('aud_out.freeze', 'must be the display\'s refresh-aligned freeze (ds_frz): the STC and the '
                                  'sample clock stop and restart on the same cycles')
        if terms(rconn.get('in_frame_start', '')) != {'aud_frame_start'} or \
                terms(rconn.get('in_pts', '')) != {'aud_frame_pts'} or \
                terms(rconn.get('in_pts_valid', '')) != {'aud_frame_pts_valid'}:
            bad('aud_ring', 'the PES start and its PTS must be the demux\'s aud_frame_start / '
                            'aud_frame_pts / aud_frame_pts_valid (the tags)')
        for port in ('tag_valid', 'tag_has', 'tag_pts', 'tag_pop'):
            if not terms(rconn.get(port, '')) or terms(rconn.get(port, '')) != terms(oconn.get(port, '')):
                bad('aud_out.' + port, 'must be aud_ring\'s %s (every PCM frame takes its AU\'s tag)' % port)
        if terms(oconn.get('stc', '')) != {'ds_stc'} or terms(oconn.get('stc_run', '')) != {'ds_stc_run'}:
            bad('aud_out.stc', 'must be the display\'s STC (ds_stc / ds_stc_run): lip-sync is audio '
                               'played against the clock the pictures are shown by')
        if not {'aud_valid', 'aud_ready'}.issubset(terms(oconn.get('ring_blocked', ''))):
            bad('aud_out.ring_blocked', 'must be aud_valid & ~aud_ready: the deadlock rule yields audio '
                                        'only while the ring is blocking the demux')
        # (P9: the film's output plus the sound one-shot's, saturating: AUDIO_x is the mix mx_x of
        #  aud_out's audio_x -- silenced by host_mute, a menu play() with its audio off -- and pcm_shot's
        #  pcm_x)
        name, psconn = inst('pcm_shot')
        for w, port, mx, am, pp in (('AUDIO_L', 'audio_l', 'mx_l', 'am_l', 'pcm_l'), ('AUDIO_R', 'audio_r', 'mx_r', 'am_r', 'pcm_r')):
            rhs, mrhs, arhs = assign_of(src, w), wire_init(src, mx), wire_init(src, am)
            film = terms(oconn.get(port, ''))
            want = {am} | terms(psconn.get(pp, '') if psconn else '')
            if rhs is None or terms(rhs) != {mx} or mrhs is None or len(film) != 1 or \
                    not (terms(mrhs) >= want) or len(want) != 2:
                bad(w, 'must be the saturated mix of %s (aud_out\'s %s) and pcm_shot\'s %s (P9)' % (am, port, pp))
            if arhs is None or not re.fullmatch(r'host_mute\s*\?\s*16\'sd0\s*:\s*%s' % re.escape(next(iter(film), '-')), arhs.strip()):
                bad(am, 'must be host_mute ? 16\'sd0 : aud_out\'s %s (P9: a play() with its audio off)' % port)
    else:
        bad('audio', 'aud_ring, at3p_top and aud_out must all be instantiated')

    # ---- P6b3: the pipeline's reset, and the display's side of the transport ----
    rhs = assign_of(src, 'pipe_rst_n')
    if rhs is None or terms(rhs) != {'fe_rst_n', 'pc_flush'}:
        bad('pipe_rst_n', 'must be fe_rst_n & ~pc_flush (a mount or a seek)')
    name, conn = inst('disp_ctl')
    if conn:
        for port, want in (('freeze', 'pc_freeze'), ('resync', 'pc_flush'), ('ep_we', 'pc_ep_we'),
                           ('ep_wi', 'pc_ep_wi'), ('ep_in', 'pc_ep_in'), ('ep_out', 'pc_ep_out'),
                           ('frz', 'ds_frz'), ('rec_ep', 'rq_ep'), ('rec_ep_v', 'rq_ep_v'), ('sh_ep', 'ds_sh_ep')):
            if terms(conn.get(port, '')) != {want}:
                bad('disp_ctl.' + port, 'must be %s (the transport; P6b3i the item table and tags)' % want)
    name, conn = inst('player_ctl')
    if not conn:
        bad('player_ctl', 'not instantiated -- nothing drives the transport')
    else:
        if terms(conn.get('rst_n', '')) != {'reset_n'}:
            bad('player_ctl.rst_n', 'must be the CORE reset (reset_n): a gesture survives the flush it causes')
        for port, want in (('rec_idle', 'rq_idle'), ('seek_flush', 'pc_flush'), ('sh_pts', 'ds_sh_pts'),
                           ('mount', 'start_streaming'), ('sh_ep', 'ds_sh_ep'), ('item_hold', 'pc_item_hold'),
                           ('ep_we', 'pc_ep_we')):
            if terms(conn.get(port, '')) != {want}:
                bad('player_ctl.' + port, 'must be %s' % want)
    # P6b3i: the item tag, byte by byte from the reader to the display
    name, rconn = inst('umd_reader')
    if rconn and (terms(rconn.get('stream_ep', '')) != {'stream_ep'} or terms(rconn.get('item_hold', '')) != {'pc_item_hold'}):
        bad('umd_reader', 'stream_ep must feed the FIFO and item_hold come from player_ctl (P6b3i)')
    name, fconn = inst('ps_stream_fifo')
    if fconn and not ({'stream_ep', 'stream_data'} <= terms(fconn.get('wr_data', '')) and
                      {'dmx_in_ep', 'dmx_in_byte'} <= terms(fconn.get('out_byte', ''))):
        bad('ps_stream_fifo', 'must carry {stream_ep, stream_data} to {dmx_in_ep, dmx_in_byte} (P6b3i)')
    name, dconn = inst('ps_demux')
    if dconn and (terms(dconn.get('in_ep', '')) != {'dmx_in_ep'} or terms(dconn.get('vid_ep', '')) != {'vid_ep'}):
        bad('ps_demux', 'in_ep must be dmx_in_ep and vid_ep reach the vbuf (P6b3i)')
    name, vconn = inst('vbuf')
    if vconn and (terms(vconn.get('in_ep', '')) != {'vid_ep'} or terms(vconn.get('out_ep', '')) != {'vb_ep'}):
        bad('vbuf', 'the stamps must carry the item tag (in_ep = vid_ep, out_ep = vb_ep; P6b3i)')
    name, cconn = inst('vidfeed_cdc')
    if cconn and 'vb_ep' not in terms(cconn.get('wr_data', '')):
        bad('vidfeed_cdc.wr_data', 'must carry vb_ep (P6b3i)')
    name, hconn = inst('h264_top')
    if hconn and 'es_data' not in terms(hconn.get('es_ep', '')):
        bad('h264_top.es_ep', 'must come from vidfeed_cdc\'s rd_data (P6b3i)')
    # P6b4, trick play: a hop's landing makes the front end end its stream after the entry's
    # first frame -- player_ctl's one_frame through two clk_dec flops; the D-pad's Right / Left
    # are FF / REW (codes 10 / 11), gated while the OSD is open
    if hconn and (terms(hconn.get('one_frame', '')) != {'one_dec_s'} or not re.search(
            r'always\s*@\s*\(\s*posedge\s+clk_dec\s*\)\s*one_dec_s\s*<=\s*\{\s*one_dec_s\[0\]\s*,\s*pc_one\s*\}\s*;', src)):
        bad('h264_top.one_frame', 'must be player_ctl\'s one_frame (pc_one) through two clk_dec flops (one_dec_s): '
                                  'else a hop decodes on past its I picture (P6b4)')
    name, pconn = inst('player_ctl')
    if pconn and terms(pconn.get('one_frame', '')) != {'pc_one'}:
        bad('player_ctl.one_frame', 'must drive pc_one (P6b4)')
    if not re.search(r"dpad_cmd\[0\]\s*\?\s*4'd10\s*:\s*\|dpad_cmd\s*\?\s*4'd11", src) or \
            not re.search(r'dpad_all\s*=\s*\(joystick_0\[3:0\]\s*&\s*~dpad_q\s*&\s*\{4\{~OSD_STATUS\}\}\)\s*\|\s*kbd_joy\[3:0\]', src) or \
            not re.search(r'dpad_press\s*=\s*dpad_all\[1:0\]\s*&\s*~host_grab\[1:0\]', src):
        bad('dpad_press', 'the D-pad\'s Right / Left must be FF (10) / REW (11), their press edges gated '
                          'while the OSD is open, the keyboard\'s arrows ORed in (P6b4)')
    # ---- P6b6 (transport.md D10): the J1 list's order IS the joystick bits (B1 = bit 4); the
    #      command wiring and umd/kbd_map.sv's table must agree with it ----
    J1 = ['Play/Pause', 'Select', 'Stop', 'Prev Chapter', 'Next Chapter', 'Audio', 'Display',
          'UMD Menu', 'Subtitle', 'Go To', 'Control Panel']    # (P6d: Repeat became Control Panel, K3)
    m = re.search(r'"J1,([^;"]*);"', raw)
    if not m or [x.strip() for x in m.group(1).split(',')] != J1:
        bad('CONF_STR J1', 'must list %s in this order (the bits kbd_map and the commands use)' % ', '.join(J1))
    m = re.search(r'"jn,([^;"]*);"', raw)
    if not m or [x.strip() for x in m.group(1).split(',')] != ['Start', 'A', 'B', 'L', 'R', 'Select', '', 'Y', '', '', 'X']:
        bad('CONF_STR jn', 'the default pad map must be Start,A,B,L,R,Select,,Y,,,X (D4; P6d K3: Control Panel on '
                           'X, the PSP\'s triangle, Display without a default)')
    # P6d (docs/panel.md F4): the Control Panel button reaching the transport (no UMD Main took it) is the HUD's message
    rhs = wire_init(src, 'th_pmsg')
    if rhs is None or re.sub(r'\s', '', rhs) != "btn_press[14]?((host_ok|host_bad)?2'd2:2'd1):2'd0":
        bad('th_pmsg', "the panel button refused: 1 with no UMD Main, 2 with one that did not take it (P6d)")
    _, hudc = inst('transport_hud')
    if hudc and terms(hudc.get('pmsg', '')) != {'th_pmsg'}:
        bad('transport_hud.pmsg', "must be th_pmsg: the panel button's message (P6d)")
    for bit, code, what in ((6, 4, 'Stop'), (4, 1, 'Play/Pause'), (5, 1, 'Select'), (7, 6, 'Prev'), (8, 5, 'Next')):
        if not re.search(r"btn_cmd\[%d\]\s*\?\s*4'd%d\b" % (bit, code), src):
            bad('pc_cmd', '%s (J1 bit %d) must issue command %d' % (what, bit, code))
    # (P7: Subtitle, bit 12, is SUB (12) -- after Audio in the same-cycle order)
    if not re.search(r"pc_cmd_v\s*=\s*\|btn_cmd\[9:4\]\s*\|\s*btn_cmd\[12\]\s*\|\s*\|dpad_cmd", src) or \
            not re.search(r"\|dpad_cmd\s*\?\s*4'd11\s*:\s*btn_cmd\[9\]\s*\?\s*4'd8\s*:\s*4'd12", src):
        bad('pc_cmd', 'Audio (bit 9) must issue AUDIO (8), Subtitle (bit 12) SUB (12), and bits 4-9, 12 and '
                      'the D-pad are the commands')
    if not re.search(r"wire\s+bp_disp\s*=\s*btn_press\[10\]", src):
        bad('bp_disp', 'Display is J1 bit 10')
    # P6d follow-up (the maintainer, 2026-10-05): Audio / Subtitle show the current track first; the press is
    # the cycle only while its tag is up; Subtitle without the UMD Main goes straight to SUB (its message)
    for nm, want in (('th_show_aud', "btn_press[9]&~th_tag_aud"), ('th_show_sub', "btn_press[12]&~th_tag_sub"),
                     ('btn_cmd', "{btn_press[15:13],btn_press[12]&~th_show_sub,btn_press[11:10],btn_press[9]&~th_show_aud,btn_press[8:7]&~{2{ab_loop}},btn_press[6:4]}")):
        rhs = wire_init(src, nm)
        if rhs is None or re.sub(r'\s', '', rhs) != want:
            bad(nm, 'must be %s: Audio / Subtitle show the current track before they cycle (P6d follow-up)' % want)
    _, hudc2 = inst('transport_hud')
    if hudc2:
        for port, want in (('show_aud', {'th_show_aud'}), ('show_sub', {'th_show_sub'}), ('aud_cur', {'pc_aud_track'}),
                           ('sub_on_cur', {'pc_sub_on'}), ('sub_cur', {'pc_sub_track'}), ('tag_aud', {'th_tag_aud'}),
                           ('tag_sub', {'th_tag_sub'})):
            if terms(hudc2.get(port, '')) != want:
                bad('transport_hud.' + port, 'must be %s (P6d follow-up: show, then cycle)' % ', '.join(sorted(want)))
    kbd = open(os.path.join(ROOT, 'umd', 'kbd_map.sv'), encoding='utf-8').read()
    for bit, bn, name in re.findall(r"8'h[0-9A-Fa-f]{2}:\s*hit\[(\d+)\]\s*=\s*1'b1;\s*//[^\n]*->\s*B(\d+)\s+([A-Za-z/ ]+?)(?:\s{2,}|\s*\(|\s*,|$)", kbd, re.M):
        bit, bn = int(bit), int(bn)
        if bit != bn + 3 or bn > len(J1) or J1[bn - 1] != name.strip():
            bad('kbd_map', 'a key to hit[%d] says B%d %s, but J1 bit %d is %s' %
                (bit, bn, name.strip(), bit, J1[bit - 4] if 4 <= bit < 4 + len(J1) else 'none'))

    # ---- P6b5: the transport HUD over the picture, under the diagnostic HUD ----
    name, hconn = inst('transport_hud')
    name, rdconn = inst('umd_reader')
    if hconn:
        if terms(hconn.get('bg', '')) != {'bg_r', 'bg_g', 'bg_b'}:
            bad('transport_hud.bg', 'must be the picture at the output stage ({bg_r, bg_g, bg_b}, P6b5)')
        if not re.search(r'vga_r_q\s*<=\s*cut_dly\[6\]\s*\?\s*8\'d0\s*:\s*th_rgb\[23:16\]', src) or \
                terms(hconn.get('rgb', '')) != {'th_rgb'}:
            bad('transport_hud.rgb', 'th_rgb must be what the output register shows (P6b5: the HUD over the '
                                     'picture; the diagnostic HUD over it left the core, A11)')
        for port, want in (('show', {'media_seen', 'host_menu'}), ('sh_ep', {'ds_sh_ep'}), ('sh_pts', {'ds_sh_pts'}),
                           ('ev_valid', {'pc_ev_v'}), ('item_base', {'rd_item_base'}),
                           ('item_start', {'rd_item_start'}), ('pl_dur', {'rd_pl_dur'}),
                           ('title_addr', {'th_title_addr'}), ('lang_sel', {'th_lang_sel'})):
            if terms(hconn.get(port, '')) != want:
                bad('transport_hud.' + port, 'must be %s (P6b5)' % ', '.join(sorted(want)))
        if rdconn and (terms(rdconn.get('title_addr2', '')) != {'th_title_addr'} or
                       terms(rdconn.get('lang_sel', '')) != {'th_lang_sel'}):
            bad('umd_reader.title_addr2', 'the reader\'s second title port and its language port must be the '
                                          'transport HUD\'s (P6b5)')
    # ---- P9 (docs/p9.md S3.2): the host's rows, the menu gate -------------------------------
    name, uhconn = inst('umd_host')
    name, pcconn = inst('player_ctl')
    if not re.search(r'assign\s+hk_press\s*=\s*\{btn_all,\s*dpad_all\}', src) or \
            not re.search(r'btn_press\s*=\s*btn_all\s*&\s*~host_grab\[15:4\]', src):
        bad('hk_press', 'every press goes to umd_host (hk_press = {btn_all, dpad_all}); the transport sees the '
                        'ungrabbed ones (btn_press = btn_all & ~host_grab[15:4]) (P9)')
    if not re.search(r'assign\s+hc_take\s*=\s*hc_v\s*&\s*~pc_cmd_v', src):
        bad('hc_take', 'a host command takes a cycle with no button command (hc_take = hc_v & ~pc_cmd_v, P9)')
    if uhconn:
        for port, want in (('key_press', {'hk_press'}), ('grab', {'host_grab'}), ('menu', {'host_menu'}),
                           ('ev_in_v', {'pc_ev_v'}), ('ev_in_code', {'pc_ev_code'}), ('hc_take', {'hc_take'}),
                           ('p_state', {'pc_state'}), ('p_key_item', {'pc_key_item'}), ('p_playlist', {'rd_main_pl'}),
                           ('p_pts', {'ds_sh_pts'}), ('pic_wide', {'vui_wide'}), ('pic_known', {'vui_sar_known'}),
                           ('mute', {'host_mute'}), ('menu_aa', {'menu_aa'})):
            if terms(uhconn.get(port, '')) != want:
                bad('umd_host.' + port, 'must be %s (P9)' % ', '.join(sorted(want)))
    if pcconn:
        for port, want in (('cmd_valid', {'gt_cmd_v', 'pc_cmd_v', 'ab_take', 'hc_pc'}), ('cmd_pl', {'hc_pl'}), ('nav_pl', {'pc_nav_pl'}),
                           ('rd_n_playlists', {'rd_n_pl'}), ('key_item', {'pc_key_item'})):
            if terms(pcconn.get(port, '')) != want:
                bad('player_ctl.' + port, 'must be %s (P9)' % ', '.join(sorted(want)))
        if not re.search(r"\.cmd_code\s*\(\s*gt_cmd_v\s*\?\s*gt_cmd_code\s*:\s*pc_cmd_v\s*\?\s*pc_cmd\s*:\s*ab_take\s*\?\s*4'd7\s*:\s*hc_code\s*\)", src):
            bad('player_ctl.cmd_code', 'Go To\'s jump, then the buttons, A-B\'s SEEK (7), the host\'s in a cycle without '
                                       'them (P9, P6c, A-B Repeat)')
    if rdconn and terms(rdconn.get('nav_pl', '')) != {'pc_nav_pl'}:
        bad('umd_reader.nav_pl', 'must be player_ctl\'s nav_pl (pc_nav_pl, P9)')
    name, soconn = inst('sub_overlay')
    if soconn:
        for port, want in (('ui', {'host_ui'}), ('hf_req', {'hf_req'}), ('hf_ack', {'hf_ack'})):
            if terms(soconn.get(port, '')) != want:
                bad('sub_overlay.' + port, 'must be %s: the plane hand-over (P9)' % ', '.join(sorted(want)))
    if uhconn and (terms(uhconn.get('hf_req', '')) != {'hf_req'} or terms(uhconn.get('hf_ack', '')) != {'hf_ack'} or
                   terms(uhconn.get('ui', '')) != {'host_ui'}):
        bad('umd_host.hf_req', 'the host\'s flip and ui must reach sub_overlay (P9)')
    name, drconn = inst('disp_reader')
    if drconn and uhconn:
        for port in ('win', 'win_hold', 'win_x', 'win_y', 'win_w', 'win_h', 'win_hs', 'win_vs', 'win_x0', 'win_y0'):
            if terms(drconn.get(port, '')) != {'host_' + port} or terms(uhconn.get(port, '')) != {'host_' + port}:
                bad('disp_reader.' + port, 'the video window must be umd_host\'s (host_%s, P9 item 6)' % port)
        if terms(drconn.get('win_bad', '')) != {'host_win_bad'} or terms(uhconn.get('win_bad', '')) != {'host_win_bad'}:
            bad('disp_reader.win_bad', 'the window\'s refusal must reach HOST_RD (host_win_bad, P9)')
    if not re.search(r'sp_on\s*=\s*pc_sub_on\s*&\s*~pc_sub_flush\s*&\s*\(pc_tkspd\s*==\s*2\'d0\)\s*&\s*~host_ui', src):
        bad('sp_on', 'the demux\'s subtitle output is off while the host owns the plane (& ~host_ui, P9)')
    if not re.search(r'sb_ui_q\[2\]\s*\^\s*sb_ui_q\[1\]', src):
        bad('sb_flush_q', 'either edge of host_ui flushes the subtitle side (P9)')
    if not re.search(r'wave_vis\s*=\s*~media_seen\s*\|\s*\(pc_idle\s*&\s*~host_menu\)', src):
        bad('wave_vis', 'stop under a disc menu is black, not the idle wave (P9)')
    # A11 (the diagnostic HUD removed): a disc the core stops on says so, and telemetry keeps what only
    # the HUD showed
    name, thc = inst('transport_hud')
    if thc and terms(thc.get('unplay', '')) != {'th_unplay'}:
        bad('transport_hud.unplay', 'must be th_unplay: "This disc cannot be played." (A11)')
    rhs = assign_of(src, 'th_unplay')
    if rhs is None or not {'sn_refused', 'unp_ref_q', 'rd_err', 'unp_err_q'}.issubset(terms(rhs)):
        bad('th_unplay', 'a new front-end refusal or the reader\'s error, edge-detected (A11)')
    name, tlc = inst('umd_telem')
    if tlc:
        for port, want in (('t_frc', {'sn_refused_code'}), ('t_frn', {'sn_refused'}), ('t_rzn', {'sn_rz'}),
                           ('t_rwarn', {'rd_dur_sat', 'rd_title_trunc', 'rd_sfo_warn'}), ('t_odrp', {'sn_ox'}),
                           ('t_sdrop', {'sb_drop'}), ('t_slate', {'sn_sub'})):
            if not want.issubset(terms(tlc.get(port, ''))):
                bad('umd_telem.' + port, 'must carry %s: the readout only the diagnostic HUD showed (A11)'
                    % ', '.join(sorted(want)))
    # ---- P6c (docs/p6c.md §9): Go To -- its keys ahead of the host's grab and the D-pad's FF / REW,
    #      its queries on player_ctl's port, its jump on the command port, its editor drawn by the HUD ----
    name, gtc = inst('goto_ctl')
    if not gtc:
        bad('goto_ctl', 'not instantiated -- the Go To button does nothing (P6c)')
    else:
        for port, want in (('k_goto', '(btn_all[13]|hx_press[13])&~ab_loop'), ('k_up', 'dpad_all[3]'), ('k_down', 'dpad_all[2]'),
                           ('k_left', 'dpad_all[1]'), ('k_right', 'dpad_all[0]'), ('k_ok', 'btn_all[5]'),
                           ('k_back', 'btn_all[6]'), ('k_menu', 'btn_all[11]')):
            if re.sub(r'\s', '', gtc.get(port, '')) != want:
                bad('goto_ctl.' + port, 'must be %s (the J1 bits: Go To B10, Pause, Stop, UMD Menu; the D-pad; '
                                        'P6d: Go To also opens on the panel\'s press)' % want)
        for port, want in (('gq_req', 'gt_gq_req'), ('gq_key', 'gt_gq_key'), ('gq_done', 'gt_gq_done'),
                           ('cmd_v', 'gt_cmd_v'), ('cmd_code', 'gt_cmd_code'), ('cmd_item', 'gt_cmd_item'),
                           ('cmd_pts', 'gt_cmd_pts'), ('open', 'gt_open'), ('el_ticks', 'th_el'),
                           ('ch_cur', 'rd_ch_cur'), ('ch_next', 'rd_ch_next'), ('ch_rank', 'rd_ch_rank'),
                           ('ch_valid', 'rd_ch_valid'), ('rd_item_idx', 'rd_item_idx'), ('rd_item_base', 'rd_item_base'),
                           ('host_ui', 'host_ui'), ('state', 'pc_state'), ('key_item', 'pc_key_item'),
                           ('rst_n', 'reset_n'), ('mount', 'start_streaming')):
            if terms(gtc.get(port, '')) != {want}:
                bad('goto_ctl.' + port, 'must be %s (P6c)' % want)
    rhs = wire_init(src, 'gt_take')
    if rhs is None or re.sub(r'\s', '', rhs) != "{2'b00,1'b1,6'd0,gt_open,gt_open,1'b0,{4{gt_open}}}":
        bad('gt_take', 'Go To takes its button (bit 13) always, and while open the D-pad, Pause (5) and Stop (6) (P6c)')
    if not re.search(r'assign\s+hk_press\s*=\s*\{btn_all,\s*dpad_all\}\s*&\s*~gt_take\s*;', src) or \
            not re.search(r'btn_press\s*=\s*btn_all\s*&\s*~host_grab\[15:4\]\s*&\s*~gt_take\[15:4\]\s*\|\s*hx_press\[15:4\]\s*;', src) or \
            not re.search(r'dpad_press\s*=\s*dpad_all\[1:0\]\s*&\s*~host_grab\[1:0\]\s*&\s*~gt_take\[1:0\]\s*\|\s*hx_press\[1:0\]\s*;', src):
        bad('gt_take', 'Go To\'s keys must be masked from the UMD Main (hk_press) and the transport (btn_press, '
                       'dpad_press) -- before the host\'s grab (P6c)')
    if not re.search(r'assign\s+hc_take\s*=\s*hc_v\s*&\s*~pc_cmd_v\s*&\s*~gt_cmd_v\s*&\s*~ab_req\s*;', src):
        bad('hc_take', 'a host command waits for a cycle with no button, no Go To jump and no A-B SEEK (P6c, A-B Repeat)')
    # ---- A-B Repeat (docs/ab_repeat.md): its press, CLEAR, its SEEK's slot, the loop's masks ----------
    name, abc = inst('ab_ctl')
    if not abc:
        bad('ab_ctl', 'not instantiated -- A-B Repeat does nothing')
    else:
        for port, want in (('k_ab', 'btn_press[15]'), ('k_next', 'btn_press[8]'), ('k_prev', 'btn_press[7]'),
                           ('k_clear', 'ab_clear'), ('host_nav', 'ab_hnav'), ('cmd_req', 'ab_req'),
                           ('cmd_take', 'ab_take'), ('cmd_item', 'ab_item'), ('cmd_pts', 'ab_pts'),
                           ('loop', 'ab_loop'), ('state', 'pc_state'), ('tk_speed', 'pc_tkspd'),
                           ('seeking', 'pc_seeking'), ('key_item', 'pc_key_item'), ('sh_pts', 'ds_sh_pts'),
                           ('sh_pts_v', 'ds_sh_pts_v'), ('pick', 'ds_pick_evt'), ('ended', 'ds_ended'),
                           ('bare', 'is_bare'), ('host_ui', 'host_ui'), ('mount', 'start_streaming'),
                           ('eject', 'img_ejected'), ('rst_n', 'reset_n')):
            if re.sub(r'\s', '', abc.get(port, '')) != want:
                bad('ab_ctl.' + port, 'must be %s (A-B Repeat)' % want)
    for nm, want in (('ab_take', "ab_req&~pc_cmd_v&~gt_cmd_v"), ('hc_pc', "hc_v&(hc_code!=4'd0)"),
                     ('ab_clear', "hc_take&(hc_code==4'd0)"),
                     ('ab_hnav', "hc_take&(hc_code==4'd7||hc_code==4'd13||hc_code==4'd15)"),
                     ('dpad_cmd', "dpad_press&~{2{ab_loop}}")):
        rhs = assign_of(src, nm) or wire_init(src, nm)
        if rhs is None or re.sub(r'\s', '', rhs) != want:
            bad(nm, 'must be %s (A-B Repeat: the SEEK after Go To and the buttons; code 0 is CLEAR, never '
                    'player_ctl\'s; a host seek clears it; FF / REW masked while it loops)' % want)
    if not re.search(r"\.cmd_item\s*\(\s*gt_cmd_v\s*\?\s*gt_cmd_item\s*:\s*pc_cmd_v\s*\?\s*32'd0\s*:\s*ab_take\s*\?\s*ab_item\s*:\s*hc_item\s*\)", src) or \
            not re.search(r"\.cmd_pts\s*\(\s*gt_cmd_v\s*\?\s*gt_cmd_pts\s*:\s*pc_cmd_v\s*\?\s*48'd0\s*:\s*ab_take\s*\?\s*ab_pts\s*:\s*hc_pts\s*\)", src):
        bad('player_ctl.cmd_item', 'A-B\'s SEEK carries A (ab_item / ab_pts) in its slot (A-B Repeat)')
    _, hudc2 = inst('transport_hud')
    if hudc2:
        for port, want in (('ab_up', 'ab_tag_up'), ('ab_b', 'ab_tag_b'), ('ab_loop', 'ab_loop'), ('ab_na', 'ab_na')):
            if terms(hudc2.get(port, '')) != {want}:
                bad('transport_hud.' + port, 'must be %s: A-B Repeat\'s tag and its bare-file message' % want)
    if abc:
        for port, want in (('tag_up', 'ab_tag_up'), ('tag_b', 'ab_tag_b'), ('unavail', 'ab_na')):
            if terms(abc.get(port, '')) != {want}:
                bad('ab_ctl.' + port, 'must be %s (the HUD\'s)' % want)
    kbdsrc = open(os.path.join(ROOT, 'umd', 'kbd_map.sv'), encoding='utf-8').read()
    if not re.search(r"8'h32:\s*hit\[15\]\s*=\s*1'b1;", kbdsrc):
        bad('kbd_map', 'B (32) must be bit 15, A-B Repeat (docs/ab_repeat.md AB7)')
    if pcconn:
        for port, want in (('gq_req', 'gt_gq_req'), ('gq_key', 'gt_gq_key'), ('gq_done', 'gt_gq_done'),
                           ('nav_op', 'pc_nav_op')):
            if terms(pcconn.get(port, '')) != {want}:
                bad('player_ctl.' + port, 'must be %s (P6c)' % want)
    if rdconn and terms(rdconn.get('nav_op', '')) != {'pc_nav_op'}:
        bad('umd_reader.nav_op', 'must be player_ctl\'s nav_op (pc_nav_op; 3 bits since P6c, NAV_TIME)')
    if not re.search(r'wire\s*\[2:0\]\s*pc_nav_op\s*;', src):
        bad('pc_nav_op', 'must be 3 bits (P6c: NAV_TIME is op 4) -- 2 bits turn a TIME into a reserved op')
    if thc:
        for port, want in (('goto_open', 'gt_open'), ('goto_sel', 'gt_sel'), ('goto_edit', 'gt_edit'),
                           ('goto_chap', 'gt_chap'), ('goto_t', 'gt_t'), ('goto_mv', 'gt_mv'),
                           ('goto_mark', 'gt_mark'), ('el_ticks', 'th_el')):
            if terms(thc.get(port, '')) != {want}:
                bad('transport_hud.' + port, 'must be %s: Go To\'s editor (P6c)' % want)
    if not re.search(r'show_pic\s*=\s*media_seen\s*&\s*\(~pc_idle\s*\|\s*host_ui\s*\|\s*host_uis\)', src):
        bad('show_pic', 'a menu page or the control panel over a stopped player is the composite '
                        '(media_seen & (~pc_idle | host_ui | host_uis), P9 M4, P6d)')
    # ---- P6d (docs/panel.md F1 / F2 / F5): the control panel's press record and mode ----------------
    rhs = wire_init(src, 'hx_press')
    if rhs is None or re.sub(r'\s', '', rhs) != "hx_v?hx_mask:16'd0":
        bad('hx_press', "the press record is umd_host's one-cycle pulse (hx_v ? hx_mask : 16'd0, P6d)")
    if uhconn:
        for port, want in (('p_goto_open', {'gt_open'}), ('p_sub_any', {'trk_sub'}), ('ui_sub', {'host_uis'}),
                           ('hx_v', {'hx_v'}), ('hx_mask', {'hx_mask'}), ('hf_buf', {'hf_buf'})):
            if terms(re.sub(r"\d+'[bdh][0-9a-fA-F_]+", '', uhconn.get(port, ''))) != want:
                bad('umd_host.' + port, 'must be %s (P6d)' % ', '.join(sorted(want)))
    if soconn and (terms(soconn.get('ui_sub', '')) != {'host_uis'} or terms(soconn.get('hf_buf', '')) != {'hf_buf'}):
        bad('sub_overlay.ui_sub', "the panel's mode and its planes reach sub_flip (ui_sub = host_uis, hf_buf, P6d)")
    if not re.search(r'wire\s*\[1:0\]\s*hf_buf\s*;', src):
        bad('hf_buf', 'the host flip\'s plane is 2 bits (P6d: planes 2 / 3 are the panel\'s)')
    if 'hx_press' in terms(assign_of(src, 'hk_press') or '') or 'hx_press' in terms(assign_of(src, 'btn_all') or '') or \
            'hx_press' in terms(assign_of(src, 'dpad_all') or ''):
        bad('hk_press', 'the press record must never reach hk_press / btn_all: it would come back to the panel as a KEY (P6d)')
    name, tconn = inst('recon_top')
    name, oconn = inst('recon_out')
    if tconn and oconn and (terms(tconn.get('pinfo_ep', '')) != {'pi_ep'} or terms(oconn.get('pinfo_ep', '')) != {'pi_ep'}):
        bad('recon_out.pinfo_ep', 'must be recon_top\'s pinfo_ep (pi_ep; P6b3i)')
    name, aconn = inst('aud_out')
    name, rgconn = inst('aud_ring')
    if aconn and rgconn:
        if terms(aconn.get('left_mask', '')) != {'ds_left'} or terms(aconn.get('vid_stalled', '')) != {'ds_stalled'}:
            bad('aud_out', 'left_mask / vid_stalled must be the display\'s (ds_left / ds_stalled): a left item\'s '
                           'audio waits forever otherwise (the rig\'s MCR hang, P6b3i)')
        if terms(rgconn.get('in_ep', '')) != {'aud_frame_ep'} or terms(aconn.get('tag_ep', '')) != {'at_ep'} or \
                terms(rgconn.get('tag_ep', '')) != {'at_ep'}:
            bad('aud_ring', 'the audio\'s item tag must ride the tags (in_ep = aud_frame_ep, tag_ep = at_ep; P6b3i)')
    rhs = assign_of(src, 'wave_vis')
    if rhs is None or 'pc_idle' not in terms(rhs):
        bad('wave_vis', 'must include pc_idle (Stop shows the idle screen, D5)')

    # ---- P8, bare stream files (docs/bare_streams.md): the tracks of a bare file are the stream's
    #      (the demux's taps, from the mount), an image's its CLP's; player_ctl knows which ----
    pc = inst('player_ctl')[1]
    def nterms(x):                       # (a sized literal is not a net)
        return terms(re.sub(r"\d+'[bdh][0-9a-fA-F_]+", '', x or ''))
    if terms(pc.get('bare', '')) != {'is_bare'} or nterms(assign_of(src, 'is_bare')) != {'rd_bare'}:
        bad('player_ctl.bare', 'must be is_bare = (rd_bare != 0): a bare file must not seek (P8)')
    for w, want in (('trk_aud', {'is_bare', 'bare_aud', 'rd_aud_present'}),
                    ('trk_sub', {'is_bare', 'bare_sub', 'rd_sub_present'}),
                    ('trk_lang', {'is_bare', 'rd_lang_q'})):
        if nterms(assign_of(src, w)) != want:
            bad(w, 'must choose the stream-learned value on a bare file, the reader\'s otherwise (P8)')
    if terms(pc.get('rd_aud_present', '')) != {'trk_aud'} or terms(pc.get('rd_sub_present', '')) != {'trk_sub'}:
        bad('player_ctl.rd_*_present', 'must be trk_aud / trk_sub (P8: a bare file\'s tracks from the stream)')
    th = inst('transport_hud')[1]
    if terms(th.get('aud_present', '')) != {'trk_aud'} or terms(th.get('sub_present', '')) != {'trk_sub'} or \
            terms(th.get('lang_q', '')) != {'trk_lang'}:
        bad('transport_hud', 'the track tag must use trk_aud / trk_sub / trk_lang (P8)')
    m = re.search(r'if\s*\(aud_ss_seen\)\s*bare_aud\[aud_ss_id\]', src)
    m2 = re.search(r'if\s*\(sub_ss_seen\)\s*bare_sub\[sub_ss_id\]', src)
    if not m or not m2:
        bad('bare_aud / bare_sub', 'must be set from the demux\'s taps (aud_ss_seen / sub_ss_seen, P8)')
    dx = inst('ps_demux')[1]
    if terms(dx.get('sub_ss_seen', '')) != {'sub_ss_seen'} or terms(dx.get('aud_ss_seen', '')) != {'aud_ss_seen'}:
        bad('ps_demux', 'its substream taps must reach bare_aud / bare_sub (P8)')

    # ---- mount gating: a size-0 mount is an eject, not a mount ----
    rhs = assign_of(src, 'start_streaming')
    if rhs is None or not {'img_evt', 'img_size'}.issubset(terms(rhs)):
        bad('start_streaming', 'must be img_evt gated on img_size != 0 (a failed mount / eject '
                               'arrives as img_mounted with size 0)')
    rhs = assign_of(src, 'BUTTONS')
    if rhs is None or 'osd_btn' not in terms(rhs):
        bad('BUTTONS', 'must carry osd_btn (the startup OSD pop)')

    if fails:
        sys.stderr.write('check_emu_wiring: FAIL (%s)\n' % rel)
        for f in fails:
            sys.stderr.write('  - %s\n' % f)
        return 1
    print('check_emu_wiring: PASS (%s) -- ports match sys_top, clocks/reset/hps_io/raster/'
          'idle-screen/P2-chain/P3-front-end/P4/ram2/audio seams wired as designed' % rel)
    return 0


if __name__ == '__main__':
    sys.exit(main())
