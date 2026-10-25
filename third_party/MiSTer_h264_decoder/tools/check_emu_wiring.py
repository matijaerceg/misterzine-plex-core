#!/usr/bin/env python3
"""check_emu_wiring.py -- gate the seams in h264/emu.sv by READING them out of the file.

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
milliseconds from bench/h264/run_scaffold.sh. Inherited from MiSTer_UMD_Video; the
helpers and the sys_top port / ram2 checks are verbatim, the seam checks are this core's.

    python3 tools/check_emu_wiring.py [emu.sv [sys_top.v]]   # exit 0 = wired as designed
    VID_OUT_SV=path  another h264/vid_out.sv (the output stage, read for its LAT; run_scaffold's
                     mutations of it)

THE RASTER ON clk_vid (hd_raster, docs/hd_raster.md S3): the raster side reads everything from
clk_sys through ONE bundle (xdn_src -> cdc_snap -> xdn_dst -> v_*). R() resolves a v_* net to
its clk_sys source, so a check written as "disp_reader.il must be interlaced_eff" still means
that; the bundle's packing (each pair the same width, the total the localparam) is its own check.

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
    qsf = open(os.path.join(ROOT, 'H264.qsf'), encoding='utf-8').read()
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


def terms(expr):
    return set(re.findall(r'[A-Za-z_]\w*', expr))


def split_top(text):
    """A concatenation's elements: split on the commas at nesting depth 0."""
    out, depth, cur = [], 0, ''
    for ch in text:
        if ch in '([{':
            depth += 1
        elif ch in ')]}':
            depth -= 1
        if ch == ',' and depth == 0:
            out.append(cur.strip()); cur = ''
        else:
            cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out


def decl_width(src, name):
    for m in re.finditer(r'\b(?:wire|reg|logic)\b\s*(?:signed\s*)?(\[\s*(\d+)\s*:\s*(\d+)\s*\])?\s*([^;=]*)', src):
        if name in [x.strip() for x in m.group(4).split(',')]:
            return int(m.group(2)) - int(m.group(3)) + 1 if m.group(1) else 1
    return None


def expr_width(src, e):
    e = e.strip()
    m = re.fullmatch(r'\w+\s*\[\s*(\d+)\s*:\s*(\d+)\s*\]', e)
    if m:
        return int(m.group(1)) - int(m.group(2)) + 1
    if re.fullmatch(r'\(.*(?:==|!=).*\)', e):
        return 1
    if re.fullmatch(r'\w+', e):
        return decl_width(src, e)
    return None


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'h264', 'emu.sv')
    raw = open(path, encoding='utf-8').read()
    src = norm(strip_comments(raw))
    rel = os.path.relpath(path, ROOT) if path.startswith(ROOT) else path
    fails = []

    def bad(label, why):
        fails.append('%s: %s' % (label, why))

    # ---- (hd_raster) the raster side's bundles: clk_sys -> clk_vid (v_*), clk_vid -> clk_sys ----
    def bundle(sname, dname, lpname):
        ms = re.search(r'\b%s\s*=\s*\{([^{};]*)\}\s*;' % sname, src)
        md = re.search(r'\bassign\s*\{([^{};]*)\}\s*=\s*%s\s*;' % dname, src)
        ml = re.search(r'\blocalparam\s+int\s+%s\s*=\s*([\d\s+*]+);' % lpname, src)
        if not ms or not md or not ml:
            bad('bundle ' + lpname, 'the raster bundle (%s = {..}; assign {..} = %s; localparam %s) not found' % (sname, dname, lpname))
            return [], []
        sl, dl = split_top(ms.group(1)), split_top(md.group(1))
        total = sum(eval(x) for x in ml.group(1).split('+'))      # (digits and * only, by the regex)
        if len(sl) != len(dl):
            bad('bundle ' + lpname, '%d sources packed, %d unpacked' % (len(sl), len(dl)))
            return sl, dl
        tw = 0
        for a, b in zip(sl, dl):
            wa, wb = expr_width(src, a), expr_width(src, b)
            if wa is None or wb is None or wa != wb:
                bad('bundle ' + lpname, '%r (%s bits) packed opposite %r (%s bits): every field after it shifts' % (a, wa, b, wb))
            tw += wb or 0
        if tw != total:
            bad('bundle ' + lpname, 'the fields are %d bits, the localparam %d: the copy is truncated or padded' % (tw, total))
        return sl, dl
    xs, xd = bundle('xdn_src', 'xdn_dst', 'XW_DN')
    bmap = dict(zip(xd, xs))
    def R(expr):
        e = (expr or '').strip()
        return bmap.get(e, e)
    us, ud = bundle('xup_src', 'xup_dst', 'XW_UP')
    for a, b in zip(us, ud):
        if a != b + '_v':
            bad('bundle XW_UP', '%r unpacked from %r: each clk_sys word is its clk_vid twin (name + _v)' % (b, a))
    vpath = os.environ.get('VID_OUT_SV') or os.path.join(ROOT, 'h264', 'vid_out.sv')
    vsrc = norm(strip_comments(open(vpath, encoding='utf-8').read()))

    def inst(module):
        name, body = find_instance(src, module)
        if body is None:
            bad(module, 'no %s instantiation found in %s' % (module, rel))
            return name, {}
        return name, connections(body)

    def mux_on(port):
        """(Phase 6b) the ddr_mux2 whose ddr_address drives `port` (DDRAM_ADDR: ram1's, DDRAM2_ADDR: ram2's)."""
        for n, b in find_instances(src, 'ddr_mux2'):
            if b is not None and terms(connections(b).get('ddr_address', '')) == {port}:
                return n, connections(b)
        bad('ddr_mux2', 'no ddr_mux2 drives %s' % port)
        return None, {}

    # The OSD exposes the five app roles; adapt their compact JN slots to
    # the stable input-region bits consumed by existing HPS clients.
    for literal in ('"JN,OK,Back,Page Back,Page Forward,Pause/Play;"', '"jn,A,B,L,R,Start;"'):
        if literal not in src:
            bad('pad mapping', 'CONF_STR must contain %s' % literal)
    m = re.search(r'function\s+\[31:0\]\s+input_region_joy\s*\(input\s+\[31:0\]\s+joy\)\s*;?\s*begin\s*input_region_joy\s*=\s*([^;]+);\s*end\s*endfunction', src)
    want_map = "{20'b0,joy[8],1'b0,joy[7:6],2'b0,joy[4],joy[5],joy[3:0]}"
    if not m or m.group(1).replace(' ', '') != want_map:
        bad('input_region_joy', 'must preserve d-pad [3:0], map compact OK/Back to legacy B/A [5:4], shoulders to LB/RB [9:8], Pause/Play to Start [11], and clear unused bits')
    _, conn = inst('ring_in')
    want_joy = '{' + ','.join('input_region_joy(joystick_%d)' % p for p in range(5, -1, -1)) + '}'
    if conn.get('joy', '').replace(' ', '') != want_joy:
        bad('ring_in.joy', 'each of the six pads must pass through input_region_joy')

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
        # H264-FORK: the HDMI mode's own size. hdmi_width / hdmi_height are clipped to Main's
        # HSET / VSET, set from this core's raster under integer scaling: a feedback loop in Native.
        tconn = connections(tbody)
        for port, reg, rhs in (('HDMI_WIDTH', 'hdmi_mode_w', 'WIDTH<<HDMI_PR'),
                               ('HDMI_HEIGHT', 'hdmi_mode_h', 'HEIGHT')):
            m = re.search(r'\b%s\s*<=\s*([^;]+);' % reg, top)
            if reg not in terms(tconn.get(port, '')) or not m or m.group(1).replace(' ', '') != rhs:
                bad('sys_top.' + port, 'must be %s, the unclipped mode (%s), not VSET / HSET-clipped' % (reg, rhs))
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
    # ---- every module an SDC exception names must exist (a rename silently drops it) ----
    defined = set()
    for d in ('h264', 'h264/dec', 'sys'):
        for f in os.listdir(os.path.join(ROOT, d)):
            if f.endswith(('.sv', '.v')):
                defined |= set(re.findall(r'^\s*module\s+(\w+)', open(os.path.join(ROOT, d, f),
                               encoding='utf-8', errors='replace').read(), re.M))
    for f in sorted(os.listdir(os.path.join(ROOT, 'h264'))):
        if f.endswith('.sdc'):
            sdc = open(os.path.join(ROOT, 'h264', f), encoding='utf-8').read()
            for mod in sorted(set(re.findall(r'\*(\w+):\*', sdc))):
                if mod not in defined:
                    bad('sdc', 'h264/%s names module %s, which no h264/, h264/dec/ or sys/ file defines' % (f, mod))

    # ---- the framework's ALSA mixer stays compiled out (audio plays on the core's clock) ----
    if 'MISTER_DISABLE_ALSA' not in qsf_macros():
        bad('H264.qsf', 'MISTER_DISABLE_ALSA must be set: ram2 is the core\'s, and audio is '
                        'presented against the core\'s STC, not through Linux (docs/architecture.md)')

    # ---- exactly one CORE_VERSION define, in the allowed shape ----
    vers = re.findall(r'`define\s+CORE_VERSION\s+"([^"]*)"', raw)
    if len(vers) != 1:
        bad('CORE_VERSION', 'expected exactly one `define CORE_VERSION, found %d' % len(vers))
    elif len(vers[0]) > 18 or any(c in vers[0] for c in ',;"'):
        bad('CORE_VERSION', '%r breaks the CONF_STR rules (<= 18 chars, no , ; ")' % vers[0])

    # ---- clocks and reset ----
    for wire, want in (('CLK_VIDEO', {'clk_vid'}), ('CLK_SYS', {'clk_sys'}), ('CLK_MEM', {'clk_mem'}),
                       ('DDRAM_CLK', {'clk_mem'}), ('DDRAM2_CLK', {'clk_mem'}), ('LOCKED', {'locked', 'vid_locked'})):
        rhs = assign_of(src, wire)
        if rhs is None:
            bad(wire, 'not assigned')
        elif terms(rhs) != want:
            bad(wire, 'is `%s`, expected exactly %s' % (rhs, sorted(want)))
    # Analog Dither was removed 2026-10-19; its port must not come back.
    if 'VGA_DITHER' in src:
        bad('VGA_DITHER', 'removed 2026-10-19; must not come back')
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
    # (hd_raster) the raster's clock: its own PLL, named for fmax_check and sys_top.sdc's group
    name, conn = inst('vid_pll')
    if name != 'vid_pll' or terms(conn.get('outclk_0', '')) != {'clk_vid'} or terms(conn.get('locked', '')) != {'vid_locked'}:
        bad('vid_pll', 'the instance must be NAMED vid_pll (fmax_check, sys_top.sdc) with outclk_0 clk_vid, locked vid_locked')
    # the dot: one clk_vid cycle in three (27 MHz) -- the SD rasters' pins as on clk_sys
    if not re.search(r'always\s*@\s*\(\s*posedge\s+clk_vid\b[^)]*\)\s*if\s*\(\s*!\s*vid_lock_n\s*\)\s*ce_ph\s*<=\s*2\'d0\s*;\s*'
                     r'else\s+ce_ph\s*<=\s*\(\s*ce_ph\s*==\s*2\'d2\s*\)\s*\?\s*2\'d0\s*:\s*ce_ph\s*\+\s*2\'d1\s*;', src) \
            or (assign_of(src, 'tick27') or '').replace(' ', '') != "(ce_ph==2'd2)" \
            or terms(inst('sync_gen')[1].get('clk_en', '')) != {'tick27'} or terms(inst('sync_gen')[1].get('dot', '')) != {'ce_dot'}:
        bad('ce_dot', "tick27 must be one clk_vid cycle in three (ce_ph counting 0..2 on clk_vid, (ce_ph == 2'd2)), "
                      "sync_gen's clk_en, and ce_dot sync_gen's dot (the tick, or every clock native)")
    # every raster-side module on clk_vid and the dot
    for mod, cp, ep in (('sync_gen', 'clk', 'dot'), ('disp_reader', 'clk', 'ce'), ('ovl_plane', 'clk', 'ce'),
                        ('idle_bars', 'clk', 'ce'), ('vid_out', 'clk', 'ce')):
        c = inst(mod)[1]
        if c and (terms(c.get(cp, '')) != {'clk_vid'} or terms(c.get(ep, '')) != {'ce_dot'}):
            bad('raster clock', '%s must run on clk_vid with .%s(ce_dot), found %r / %r' % (mod, ep, c.get(cp), c.get(ep)))
    # the frame events into clk_sys: every refresh (frame_sys) and the frame start tagged with the mode
    pulses = {terms(connections(b).get('dst_pulse', '')).pop() if terms(connections(b).get('dst_pulse', '')) else '': connections(b)
              for _, b in find_instances(src, 'cdc_pulse') if b is not None}
    fx, f0 = pulses.get('frame_sys', {}), pulses.get('f0_sys', {})
    if not fx or not {'ce_dot', 'frame_tick'} <= terms(fx.get('src_pulse', '')) or terms(fx.get('src_clk', '')) != {'clk_vid'} \
            or terms(fx.get('dst_clk', '')) != {'clk_sys'}:
        bad('frame_sys', 'must be a cdc_pulse of (ce_dot & frame_tick) from clk_vid into clk_sys')
    f0a = assign_of(src, 'frame0_sys') or ''
    if not f0 or not {'ce_dot', 'frame_tick', 'v_pos'} <= terms(f0.get('src_pulse', '')) \
            or not {'f0_sys', 'f0_tag_s2', 'prog240_eff', 'raster_il_eff', 'raster_std'} <= terms(f0a) \
            or not re.search(r'\bf0_tag_s1\s*<=\s*\{\s*sg_mode_240p\s*,\s*sg_mode_il\s*,\s*sg_mode_std\s*\}\s*;', src) \
            or terms(inst('sync_gen')[1].get('mode_il', '')) != {'sg_mode_il'}:
        bad('frame0_sys', "the frame start (ce_dot & frame_tick & v_pos == 0, crossed) taken only when the mode it was "
                          "scanned in (sync_gen's mode_il / mode_std through f0_tag) is disp_ctl's: an old raster's "
                          "frame start must not align the grid after a mode change")

    # ---- hps_io ----
    if not re.search(r'\.CONF_STR\s*\(\s*CONF_STR\s*\)', params_of(src, 'hps_io')):
        bad('hps_io', 'must take .CONF_STR(CONF_STR)')
    name, conn = inst('hps_io')
    if conn and terms(conn.get('clk_sys', '')) != {'clk_sys'}:
        bad('hps_io.clk_sys', 'must be clk_sys')

    # ---- the raster and the idle screen ----
    name, conn = inst('sync_gen')
    if conn:
        # 1.3: the raster's mode is selected by the explicit Output Mode profile.
        if terms(R(conn.get('interlaced', ''))) != {'raster_il_eff'}:
            bad('sync_gen.interlaced', 'must use the effective raster interlace mode through the bundle')
        policy = inst('display_policy')[1]
        if not policy or terms(policy.get('interlaced', '')) != {'interlaced_eff'}:
            bad('interlaced_eff', 'must be driven by display_policy from the explicit output profile')
        if not policy or terms(policy.get('video_out', '')) != {'video_out_eff'}:
            bad('video_out_eff', 'must be driven by display_policy from the explicit output profile')
        if not re.search(r'vga31_want_l\s*<=\s*vga31_want_raw', src) or \
           not re.search(r'else\s+if\s*\(\s*cfg_seen\s*&&\s*!\s*stream_live\s*\)\s*begin\s*analog_want_l\s*<=\s*analog_want_raw\s*;\s*vga31_want_l\s*<=\s*vga31_want_raw', src):
            bad('vga31_want_l', 'must be latched with analog_want_l (once cfg is seen, never while a stream plays)')
    name, conn = inst('idle_bars')
    if conn:
        for port, want in (('v_pos', 'v_pos'), ('de_in', 'pixel_en'), ('frame_tick', 'frame_tick')):
            if terms(conn.get(port, '')) != {want}:
                bad('idle_bars.' + port, 'must be %s (from sync_gen)' % want)
        # the pixel column: h_pos counts DOTS, two a pixel at 480i (pixel repetition)
        hx = terms(conn.get('h_pos', ''))
        hx_src = assign_of(src, next(iter(hx))) if len(hx) == 1 else None
        if hx != {'h_pos'} and not (hx_src is not None and 'h_pos' in terms(hx_src)
                                    and {'v_il', 'v_prog240'} <= terms(hx_src)):
            bad('idle_bars.h_pos', 'must be h_pos, or a wire from h_pos halved for interlace / 240p')
        if hx == {'h_pos'}:
            bad('idle_bars.h_pos', 'the raw dot count: at 480i the bars would be squeezed into the left half')
        # This Jellyfin core intentionally has no hardware idle bars. Hold vis low
        # while retaining the module's DE/colour latency interface; idle_bars' RGB
        # then stays black, and Quartus can remove its unused marker/pattern logic.
        vis = re.sub(r'\s+', '', conn.get('vis', '')).strip('()')
        if vis not in ("1'b0", "1'd0", "1'h0", "0", "'0"):
            bad('idle_bars.vis', 'must be a constant zero (Jellyfin has no idle test pattern), found %r'
                % conn.get('vis'))
        if not re.search(r'else\s+if\s*\(\s*stream_live\s*\)\s*played\s*<=\s*1\s*\x27b1', src) \
           or not re.search(r'negedge\s+reset_n\s*\)\s*if\s*\(\s*!\s*reset_n\s*\)\s*played\s*<=\s*1\s*\x27b0', src):
            bad('played', 'must latch that a picture has played until core reset (Auto aspect and status)')
        # the output stage (h264/vid_out.sv since hd_raster): the picture path sets the pipeline --
        # disp_reader's LAT (its header "LAT N dots"); sync and DE are delayed that much, the idle
        # colour (idle_bars' "LAT = N dots") the difference more, so sync, DE and both colour sources
        # stay together. emu feeds vid_out the raster and the three sources by their own nets.
        _, vo = inst('vid_out')
        _, rdc = inst('disp_reader')
        _, ovp = inst('ovl_plane')
        for port, want in (('h_sync', {'h_sync'}), ('v_sync', {'v_sync'}), ('pixel_en', {'pixel_en'}),
                           ('ce_pix', {'ce_pix'}), ('field', {'field'}), ('v_pos', {'v_pos'}),
                           ('pic_r', terms(rdc.get('r', '-'))), ('pic_de', terms(rdc.get('de_out', '-'))),
                           ('idle_r', terms(conn.get('r', '-'))), ('ovl_pr', terms(ovp.get('pr', '-'))),
                           ('ovl_pa', terms(ovp.get('pa', '-')))):
            if not vo or terms(vo.get(port, '')) != want:
                bad('vid_out.' + port, 'must be %s' % sorted(want))
        for port, want in (('VGA_R', 'vga_r'), ('VGA_HS', 'vga_hs'), ('VGA_VS', 'vga_vs'), ('VGA_DE', 'vga_de'),
                           ('CE_PIXEL', 'vga_ce'), ('VGA_F1', 'vga_f1'), ('VGA_CS', 'cs'), ('VGA_CS_EN', 'cs_en')):
            a = assign_of(src, port)
            if a is None or not vo or terms(a) != terms(vo.get(want, '-')):
                bad(port, "must be vid_out's .%s (the delayed raster value)" % want)
        # every vid_out register on the dot, but CE_PIXEL's one-clock pulse
        for m in re.finditer(r'always\s*@\s*\(\s*posedge\s+clk\s*\)\s*(.{0,40})', vsrc):
            if not re.match(r'(begin\s*)?if\s*\(\s*ce\s*\)', m.group(1)):
                bad('vid_out.ce', 'every output-stage register advances on ce (LAT is in dots), found %r' % m.group(1)[:30])
        ib = open(os.path.join(ROOT, 'h264', 'idle_bars.sv'), encoding='utf-8').read()
        dr = open(os.path.join(ROOT, 'h264', 'disp_reader.sv'), encoding='utf-8').read()
        m = re.search(r'LAT\s*=\s*(\d+)\s*dots', ib)
        md = re.search(r'LAT\s+(\d+)\s+dots', dr)
        if not m or not md:
            bad('idle_bars/disp_reader', 'no "LAT = N dots" in idle_bars.sv or "LAT N dots" in disp_reader.sv')
        else:
            lat_i, lat = int(m.group(1)), int(md.group(1))
            # (Phase 6b) the selection register, then the overlay's composite into the output
            # registers: sync and DE take the picture's LAT + 1 (dly[lat])
            mo = re.search(r'LAT\s+(\d+)\s+dots', open(os.path.join(ROOT, 'h264', 'ovl_plane.sv'), encoding='utf-8').read())
            if not mo or int(mo.group(1)) != lat:
                bad('ovl_plane', 'its read-out must be LAT %d dots like disp_reader\'s (its header "LAT N dots")' % lat)
            # (hd_raster) plus the composite's own register(s): vid_out's LAT_BLEND
            mb = re.search(r'\blocalparam\s+int\s+LAT_BLEND\s*=\s*(\d+)\s*;', vsrc)
            if not mb or not re.search(r'\bovl_blend\s*#\s*\(\s*\.PIPE\s*\(\s*LAT_BLEND\s*\)\s*\)', vsrc):
                bad('ovl_blend', 'vid_out must declare LAT_BLEND and give it to ovl_blend as PIPE')
            out = lat + 1 + (int(mb.group(1)) if mb else 0)
            for q, d in (('vga_hs', 'hs_dly'), ('vga_vs', 'vs_dly')):
                mm = re.search(r'\b%s\s*<=\s*%s\s*\[\s*(\d+)\s*\]' % (q, d), vsrc)
                if not mm or int(mm.group(1)) != out - 1:
                    bad(q, 'must take %s[%d] (disp_reader LAT %d + the overlay\'s composite): sync and colour would '
                           'part company' % (d, out - 1, lat))
            # P6: the pixel-repetition phase and the field, delayed exactly like sync and DE (CE_PIXEL
            # also gated by ce: one clock a dot)
            for q, d, want, pre in (('vga_ce', 'ce_dly', 'ce_pix', r'ce\s*&\s*'), ('vga_f1', 'f1_dly', 'field', '')):
                mm = re.search(r'\b%s\s*<=\s*%s%s\s*\[\s*(\d+)\s*\]' % (q, pre, d), vsrc)
                if not mm or int(mm.group(1)) != out - 1:
                    bad(q, 'must take %s%s[%d]: CE_PIXEL / VGA_F1 would part company with the dots / lines'
                        % ('ce & ' if pre else '', d, out - 1))
                if not re.search(r'\b%s\s*<=\s*\{\s*%s\s*\[[^]]*\]\s*,\s*%s\s*\}' % (d, d, want), vsrc):
                    bad(d, 'must be fed by sync_gen\'s %s' % want)
            # the composite sync: csync_smpte from the hsync VGA_HS's register takes, on at 480i
            cname, cconn = find_instance(vsrc, 'csync_smpte')
            cconn = connections(cconn) if cconn else {}
            if not cconn:
                bad('csync_smpte', 'missing: the 480i raster needs its SMPTE composite sync (VGA_CS)')
            else:
                if terms(cconn.get('h_sync', '')) != {'hs_dly'} or not re.search(r'hs_dly\s*\[\s*%d\s*\]' % (out - 1), cconn.get('h_sync', '')):
                    bad('csync_smpte.h_sync', 'must be hs_dly[%d] (the hsync VGA_HS\'s register takes: CS_PIPE assumes VGA_HS\'s clock)' % (out - 1))
                if terms(cconn.get('en', '')) != {'il', 'prog240_i'} or not vo or \
                        terms(R(vo.get('il', ''))) != {'raster_il_eff'}:
                    bad('csync_smpte.en', 'must be enabled for interlace or progressive 240p')
                if terms(cconn.get('cs', '')) != {'cs'} or terms(cconn.get('cs_en', '')) != {'cs_en'}:
                    bad('VGA_CS', 'vid_out .cs / .cs_en must be csync_smpte\'s')
            mm = re.search(r'\bvga_de\s*<=\s*de_dly\s*\[\s*(\d+)\s*\]\s*;', vsrc)
            if not mm or int(mm.group(1)) != out - 1:
                bad('vga_de_q', 'must be de_dly[%d]: the raster\'s own active area at the output '
                                'stage\'s LAT, not a module\'s DE output' % (out - 1))
            # the idle colour: idle_bars' outputs through (lat - lat_i) more registers
            extra = lat - lat_i
            chain = 'idle_r'
            regs = []
            for _ in range(extra):
                mm = re.search(r'\b(\w+)\s*<=\s*\{?\s*%s\b' % chain, vsrc)
                if not mm:
                    break
                chain = mm.group(1)
                regs.append(chain)
            if len(regs) != extra:
                bad('idle colour', 'idle_bars\' colour must pass %d more registers (LAT %d -> %d); '
                                   'found %s' % (extra, lat_i, lat, regs))
            else:
                mm = re.search(r'\bsel_r_q\s*<=\s*([^;]+);', vsrc)
                if not mm or chain not in terms(mm.group(1)) or 'pic_r' not in terms(mm.group(1)):
                    bad('sel_r_q', 'must choose between pic_r and the delayed idle colour (%s)' % chain)
                # (Phase 6b) the composite: the selection and the overlay's pixel, both one register
                # after LAT, into ovl_blend, whose result is the output register
                _, ob = find_instance(vsrc, 'ovl_blend')
                ob = connections(ob) if ob else {}
                mo = re.search(r'\bovl_r_q\s*<=\s*(\w+)\s*;', vsrc)
                if not ob or terms(ob.get('v_r', '')) != {'sel_r_q'} or terms(ob.get('p_r', '')) != {'ovl_r_q'} \
                        or not mo or mo.group(1) != 'ovl_pr':
                    bad('ovl_blend', 'must take the selection (sel_r_q) and the overlay plane\'s pixel one register '
                                     'after it (ovl_r_q <= ovl_pr)')
                mm = re.search(r'\bvga_r\s*<=\s*(\w+)\s*;', vsrc)
                if not mm or not ob or terms(ob.get('r', '')) != {mm.group(1)}:
                    bad('vga_r_q', 'must be ovl_blend\'s r (the overlay composited over the video)')
        # the idle screen yields to a shown picture: stream_live is the display's own flag
        rhs = assign_of(src, 'stream_live')
        if rhs is None or terms(rhs) != {'sh_valid'}:
            bad('stream_live', 'must be disp_ctl\'s sh_valid (a picture is on screen), found %r' % rhs)

    # ---- P3: the HPS interface's reader (h264/ring_rd.sv) -> vidfeed_cdc -> h264_top ----
    # (docs/architecture.md "The HPS interface, v0.1"; D3 decided 2026-09-27: no ioctl input)
    hconn = inst('hps_io')[1]
    if hconn and hconn.get('ioctl_wait', '').replace(' ', '') != "1'b0":
        bad('hps_io.ioctl_wait', 'is an INPUT of hps_io with nothing to wait for (D3: no download '
                                 'path); it must be tied 1\'b0, found %r' % hconn.get('ioctl_wait'))
    # the lock-only resets, by domain: cdc_reset instances whose input is `locked` alone
    all_rsts = [connections(b) for _, b in find_instances(src, 'cdc_reset') if b is not None]
    lock_by = {}
    for c in all_rsts:
        if terms(c.get('rst_n_in', '')) == {'locked'}:
            lock_by[next(iter(terms(c.get('clk', ''))), '')] = terms(c.get('rst_n_out', ''))
    rr_name, rr = inst('ring_rd')
    rd_rst = ''
    if rr:
        if terms(rr.get('clk', '')) != {'clk_sys'} or terms(rr.get('mclk', '')) != {'clk_mem'}:
            bad('ring_rd', 'clk must be clk_sys (the parser) and mclk clk_mem (the engine)')
        if terms(rr.get('rst_n', '')) != {'reset_n'}:
            bad('ring_rd.rst_n', 'the parser runs on reset_n alone, never the per-stream reset: the records '
                                 'behind a DISCONTINUITY are the next stream\'s; found %r' % rr.get('rst_n'))
        if not lock_by.get('clk_mem') or terms(rr.get('mrst_n', '')) != lock_by['clk_mem']:
            bad('ring_rd.mrst_n', 'the engine drives ram1 (master B, no abort): the lock-only clk_mem '
                                  'reset, never RESET or the stream (a held command withdrawn: the reload hang)')
        if not lock_by.get('clk_sys') or terms(rr.get('lrst_n', '')) != lock_by['clk_sys']:
            bad('ring_rd.lrst_n', 'the status FIFO\'s write side resets with the lock alone (into clk_sys), '
                                  'both sides together with its clk_mem side')
        if terms(rr.get('disp_ended', '')) != {'disp_ended'}:
            bad('ring_rd.disp_ended', 'must be disp_ctl\'s `ended` (a DISCONTINUITY after END_OF_STREAM '
                                      'waits for the last picture)')
        # the region: the reader's defaults are the layout's (tools/ring_layout.py), nowhere overridden
        if params_of(src, 'ring_rd').strip():
            bad('ring_rd', 'parameters overridden in emu (%r): the region is the interface\'s, '
                           'tools/ring_layout.py' % params_of(src, 'ring_rd'))
        rsv = open(os.path.join(ROOT, 'h264', 'ring_rd.sv'), encoding='utf-8').read()
        sys.path.insert(0, os.path.join(ROOT, 'tools'))
        import ring_layout as RL
        for pname, want in (('CTRL_WORD', RL.CTRL_BYTE >> 3), ('RING_WORD', RL.RING_BYTE >> 3)):
            m = re.search(r"parameter\s+logic\s*\[28:0\]\s*%s\s*=\s*29'h([0-9A-Fa-f_]+)" % pname, rsv)
            if not m or int(m.group(1).replace('_', ''), 16) != want:
                bad('ring_rd.' + pname, 'default must be the layout\'s %#x' % want)
        m = re.search(r'parameter\s+int\s+RING_AW\s*=\s*(\d+)', rsv)
        if not m or (8 << int(m.group(1))) != RL.RING_SIZE:
            bad('ring_rd.RING_AW', 'default must give the layout\'s ring size %#x' % RL.RING_SIZE)
        # 0.11: the DPB (20 stores of 2 MiB) lies above the ring, at the layout's DPB_BYTE
        m = re.search(r"recon_top\s*#\s*\(\s*\.DPB_BASE\s*\(\s*29'h([0-9A-Fa-f_]+)\s*\)", src)
        if not m or int(m.group(1).replace('_', ''), 16) != RL.DPB_BYTE >> 3:
            bad('DPB_BASE', 'must be the layout\'s DPB_BYTE / 8 (%#x: above the ring)' % (RL.DPB_BYTE >> 3))
        if RL.DPB_BYTE < RL.RING_BYTE + RL.RING_SIZE:
            bad('ring_rd', 'the DPB overlaps the ring (DPB_BYTE %#x)' % RL.DPB_BYTE)
        # master B is the reader, both ways
        mconn = mux_on('DDRAM_ADDR')[1]
        for bp in ('b_address', 'b_burstcount', 'b_read', 'b_write', 'b_writedata', 'b_waitrequest',
                   'b_readdata', 'b_readdatavalid'):
            if not terms(mconn.get(bp, '')) or terms(mconn.get(bp, '')) != terms(rr.get(bp, '-')):
                bad('ddr_mux2.' + bp, 'master B must be the ring reader\'s %s, found %r' % (bp, mconn.get(bp)))
    rhs = assign_of(src, 'fe_rst_n')
    if rhs is None or terms(rhs) != {'reset_n', 'stream_clr'} or terms(rr.get('stream_clr', '')) != {'stream_clr'}:
        bad('fe_rst_n', 'must be reset_n with the reader\'s stream reset (reset_n & ~stream_clr), found %r' % rhs)
    name, conn = inst('vidfeed_cdc')
    if not conn:
        bad('vidfeed_cdc', 'not instantiated -- nothing carries the ES into clk_dec')
    else:
        if terms(conn.get('wr_clk', '')) != {'clk_sys'} or terms(conn.get('rd_clk', '')) != {'clk_dec'}:
            bad('vidfeed_cdc', 'wr_clk must be clk_sys and rd_clk clk_dec')
        wd = conn.get('wr_data', '').replace(' ', '')
        want_wd = '{%s,%s,%s}' % (rr.get('es_pts', '?'), rr.get('es_mark', '?'), rr.get('es_byte', '?'))
        if wd != want_wd.replace(' ', ''):
            bad('vidfeed_cdc.wr_data', 'must be the reader\'s {es_pts, es_mark, es_byte} in that order, found %r' % wd)
        if terms(conn.get('wr_valid', '')) != terms(rr.get('es_valid', '-')) or \
           terms(conn.get('wr_ready', '')) != terms(rr.get('es_ready', '-')):
            bad('vidfeed_cdc', 'wr_valid / wr_ready must be the reader\'s es_valid / es_ready')
        if not terms(conn.get('wr_flush', '')) or terms(conn.get('wr_flush', '')) != terms(rr.get('eos', '-')):
            bad('vidfeed_cdc.wr_flush', 'must be the reader\'s eos (END_OF_STREAM consumed): without it the '
                                        'last NAL unit of a stream is never released')
        if terms(conn.get('wr_rst_n', '')) != {'fe_rst_n'}:
            bad('vidfeed_cdc.wr_rst_n', 'must be the per-stream reset fe_rst_n')
        rd_rst = conn.get('rd_rst_n', '')
        if terms(rd_rst) & {'reset_n', 'fe_rst_n'}:
            bad('vidfeed_cdc.rd_rst_n', 'must come from cdc_reset (released on clk_dec), not a clk_sys reset')
    dec_rsts = all_rsts
    if not any(terms(c.get('clk', '')) == {'clk_dec'} and terms(c.get('rst_n_out', '')) == terms(rd_rst)
               for c in dec_rsts):
        bad('cdc_reset', 'vidfeed_cdc\'s read-side reset must be a cdc_reset on clk_dec')
    # the status block: ring_stat on the lock, its three muxes wired to it and to live sources
    name, st = inst('ring_stat')
    if st:
        if terms(st.get('clk', '')) != {'clk_sys'} or terms(st.get('frame', '')) != {'frame_sys'}:
            bad('ring_stat', 'must run on clk_sys, once a raster frame (frame_sys: frame_tick crossed)')
        for port, dom in (('rst_n', 'clk_sys'), ('mrst_n', 'clk_mem'), ('drst_n', 'clk_dec')):
            if not lock_by.get(dom) or terms(st.get(port, '')) != lock_by[dom]:
                bad('ring_stat.' + port, 'must be the lock-only %s reset (the heartbeat never restarts; a '
                                         'snapshot side reset per stream stalls a frame mid-build)' % dom)
        for port in ('st_word', 'st_ix', 'st_wr', 'st_grp', 'st_free'):
            if not terms(st.get(port, '')) or terms(st.get(port, '')) != terms(rr.get(port, '-')):
                bad('ring_stat.' + port, 'must be the reader\'s %s (its status FIFO)' % port)
        # (0.10) word 80's raster size and mode are constants until the native raster (stage 2 of
        # docs/hdmi_raster.md): the fitted raster is 720 wide, mode 0, by definition
        PENDING = set()                               # (word 80 live since stage 2)
        for dom in ('sys', 'mem', 'dec'):
            wn, wc = inst('ring_words_' + dom)
            if not wc:
                continue
            if terms(wc.get('ix', '')) != terms(st.get(dom + '_ix', '-')) or \
               terms(wc.get('w', '')) != terms(st.get(dom + '_word', '-')):
                bad('ring_words_' + dom, 'ix / w must be ring_stat\'s %s_ix / %s_word' % (dom, dom))
            for port, val in wc.items():
                if port.startswith('f_') and port not in PENDING:
                    t = terms(val)
                    if not t or all(re.match(r'^[bdh]\d*$', x) or x.isdigit() for x in t):
                        bad('ring_words_%s.%s' % (dom, port), 'a status field tied to a constant (%r): the '
                            'status block would report it forever' % val)
    # 0.6: the input region -- ring_in on clk_sys and the lock alone (a program's event count must
    # survive an OSD Reset), ring_stat's second job, and Main's input straight from hps_io (a port
    # left open or tied off here mirrors nothing, and no bench instantiates emu)
    name, ri = inst('ring_in')
    if ri:
        if terms(ri.get('clk', '')) != {'clk_sys'} or terms(ri.get('frame', '')) != {'frame_sys'}:
            bad('ring_in', 'must run on clk_sys, its heartbeat once a raster frame (frame_sys: frame_tick crossed)')
        if not lock_by.get('clk_sys') or terms(ri.get('rst_n', '')) != lock_by['clk_sys']:
            bad('ring_in.rst_n', 'must be the lock-only clk_sys reset (an OSD Reset must not move the event count)')
        for port in ('in_req', 'in_go', 'in_busy', 'in_ix', 'in_word'):
            if not terms(ri.get(port, '')) or terms(ri.get(port, '')) != terms(st.get(port, '-')):
                bad('ring_in.' + port, 'must be ring_stat\'s %s (the region is its second job)' % port)
        _, hp = inst('hps_io')
        srcs = (('joy', ['joystick_%d' % n for n in range(6)]),
                ('ana_l', ['joystick_l_analog_%d' % n for n in range(6)]),
                ('ana_r', ['joystick_r_analog_%d' % n for n in range(6)]),
                ('ps2_key', ['ps2_key']), ('ps2_mouse', ['ps2_mouse']), ('ps2_mouse_ext', ['ps2_mouse_ext']))
        for port, want in srcs:
            found = terms(ri.get(port, ''))
            expected = set(want) | ({'input_region_joy'} if port == 'joy' else set())
            if found != expected:
                bad('ring_in.' + port, 'must be hps_io\'s %s, found %r' % (', '.join(want), ri.get(port)))
            for w in want:
                if terms(hp.get(w, '')) != {w}:
                    bad('hps_io.' + w, 'must drive the wire %s (ring_in mirrors it), found %r' % (w, hp.get(w)))
        if terms(ri.get('osd', '')) != {'osd_q'}:
            bad('ring_in.osd', 'must be OSD_STATUS synchronised into clk_sys (osd_q[1]), found %r' % ri.get('osd'))
    # 0.13: the rumble -- ring_rd's (program words 36-38, 0 outside a session) into hps_io, pad n
    # to joystick_n_rumble exactly (a tie-off or a swapped slice rumbles nothing, or the wrong pad,
    # and no bench instantiates emu)
    _, hp = inst('hps_io')
    if rr and hp:
        if terms(rr.get('rumble', '')) != {'rumble'}:
            bad('ring_rd.rumble', 'must drive the wire rumble (into hps_io), found %r' % rr.get('rumble'))
        for n in range(6):
            want = 'rumble[%d:%d]' % (16 * n + 15, 16 * n)
            got = hp.get('joystick_%d_rumble' % n, '').replace(' ', '')
            if got != want:
                bad('hps_io.joystick_%d_rumble' % n, 'must be %s (pad %d\'s rumble), found %r' % (want, n, got))
    # low latency (P3f): the display takes the reader's LOW_LATENCY level and the queue's rec_more
    dconn = inst('disp_ctl')[1]
    if dconn and rr:
        if not terms(dconn.get('low_lat', '')) or terms(dconn.get('low_lat', '')) != terms(rr.get('ll_mode', '-')):
            bad('disp_ctl.low_lat', 'must be the reader\'s ll_mode (the stream\'s LOW_LATENCY), found %r' % dconn.get('low_lat'))
        oconn = inst('recon_out')[1]
        if not terms(dconn.get('rec_more', '')) or terms(dconn.get('rec_more', '')) != terms(oconn.get('rec_more', '-')):
            bad('disp_ctl.rec_more', 'must be recon_out\'s rec_more (a picture, never the END, behind the head)')
    pconn = inst('ddr_probe')[1]
    if pconn:
        for port, w in (('read', 'DDRAM_RD'), ('write', 'DDRAM_WE'), ('waitrequest', 'DDRAM_BUSY'),
                        ('readdatavalid', 'DDRAM_DOUT_READY'), ('burstcount', 'DDRAM_BURSTCNT')):
            if terms(pconn.get(port, '')) != {w}:
                bad('ddr_probe.' + port, 'must watch ram1\'s %s' % w)
    name, conn = inst('h264_top')
    if not conn:
        bad('h264_top', 'not instantiated -- the front end is not in the build')
    else:
        if terms(conn.get('clk', '')) != {'clk_dec'}:
            bad('h264_top.clk', 'must be clk_dec (the 96.43 MHz compute domain the Fmax gate watches)')
        if rd_rst and terms(conn.get('rst_n', '')) != terms(rd_rst):
            bad('h264_top.rst_n', 'must be the same clk_dec reset as vidfeed_cdc\'s read side')
        if 'es_data' not in terms(conn.get('es_byte', '')):
            bad('h264_top.es_byte', 'must be vidfeed_cdc\'s rd_data')
        if terms(conn.get('es_valid', '')) != {'es_valid'} or terms(conn.get('es_ready', '')) != {'es_ready'}:
            bad('h264_top', 'es_valid/es_ready must be vidfeed_cdc\'s rd_valid/rd_ready')
        if terms(conn.get('es_flush', '')) != {'es_flush'}:
            bad('h264_top.es_flush', 'must be vidfeed_cdc\'s rd_flush')
        for port in ('es_mark', 'es_pts'):
            if 'es_data' not in terms(conn.get(port, '')):
                bad('h264_top.' + port, 'must come from vidfeed_cdc\'s rd_data (the mark / PTS ride with '
                                        'the byte; Phase 3\'s ring fills them)')
        if terms(conn.get('se_ready', '')) != {'se_ready'}:
            bad('h264_top.se_ready', 'must be the reconstruction\'s se_ready, never a constant: a '
                                     'tied-off ready drops syntax elements the moment recon stalls')

    # ---- P2: the reconstruction, the output queue, the display (UMD's P4-P5 seams) ----
    name, rc = inst('recon_top')
    if not rc:
        bad('recon_top', 'not instantiated -- nothing reconstructs')
    else:
        if terms(rc.get('clk', '')) != {'clk_dec'} or terms(rc.get('mclk', '')) != {'clk_mem'}:
            bad('recon_top', 'clk must be clk_dec (with the front end) and mclk clk_mem')
        if terms(rc.get('rst_n', '')) != {'fe_rst_dec_n'}:
            bad('recon_top.rst_n', 'must be the per-stream reset of its clk_dec domain (fe_rst_dec_n)')
        if terms(rc.get('mrst_n', '')) & {'reset_n', 'fe_rst_n', 'fe_rst_dec_n'}:
            bad('recon_top.mrst_n', 'must be the per-stream reset released into clk_mem by a cdc_reset')
        if terms(rc.get('se_valid', '')) != {'se_valid'} or terms(rc.get('se_ready', '')) != {'se_ready'}:
            bad('recon_top.se_valid/se_ready', 'must be h264_top\'s se_valid / se_ready (the same clock)')
        if terms(rc.get('disp_hold', '')) != {'disp_hold'}:
            bad('recon_top.disp_hold', 'must be the display\'s held stores (else the decoder '
                                       'overwrites the picture on screen)')
        # Phase 4 (interface 0.5): the pause freezes the display; its holds are then no decode
        # error -- the freeze (ring_rd's ctl_pause) reaches recon_dpb through two clk_dec flops
        if terms(rc.get('disp_frz', '')) != {'frz_dec_s'} or not re.search(
                r'always\s*@\s*\(\s*posedge\s+clk_dec\s*\)\s*frz_dec_s\s*<=\s*\{\s*frz_dec_s\[0\]\s*,\s*ctl_pause\s*\}\s*;', src):
            bad('recon_top.disp_frz', 'must be the pause (ctl_pause) through two clk_dec flops (frz_dec_s): '
                                      'else a pause counts decode errors (UMD P6b3i)')
    name, conn = inst('recon_out')
    if not conn:
        bad('recon_out', 'not instantiated -- no store reaches the display in output order')
    else:
        if terms(conn.get('clk', '')) != {'clk_dec'} or terms(conn.get('sclk', '')) != {'clk_sys'}:
            bad('recon_out', 'clk must be clk_dec (the reconstruction) and sclk clk_sys (the display)')
        if terms(conn.get('rst_n', '')) != {'fe_rst_dec_n'} or terms(conn.get('srst_n', '')) != {'fe_rst_n'}:
            bad('recon_out', 'resets must be the per-stream ones of each domain (fe_rst_dec_n / fe_rst_n)')
        if terms(conn.get('oq_hold', '')) != {'disp_hold'} or assign_of(src, 'disp_hold') is not None:
            bad('recon_out.oq_hold', 'must drive disp_hold, and nothing else may (a store emitted to the '
                                     'display must stay out of the decoder\'s reach until released)')
        # 0.15: recon_out takes pic_in's mux (docs/architecture.md "Pictures from the program"), and
        # pic_in passes recon_top's output process through until a picture stream's first PICTURE
        pname, pc = inst('pic_in')
        if not pc:
            bad('pic_in', 'not instantiated -- a PICTURE record never reaches the display')
        else:
            if terms(pc.get('clk', '')) != {'clk_dec'}:
                bad('pic_in', 'clk must be clk_dec (recon_out\'s write side)')
            if terms(pc.get('rst_n', '')) != {'fe_rst_dec_n'} or terms(pc.get('cnt_rst_n', '')) != {'lock_dec_n'}:
                bad('pic_in.rst_n', 'must be the per-stream reset of clk_dec (fe_rst_dec_n), its count the lock '
                                    '(lock_dec_n: pic_emitted runs across streams for the store rule)')
            if terms(pc.get('oq_hold', '')) != {'disp_hold'}:
                bad('pic_in.oq_hold', 'must be recon_out\'s holds (disp_hold): else a store still shown is refilled')
            rr = inst('ring_rd')[1]
            for q in ('pd_req', 'pd_store', 'pd_crop', 'pd_eos'):
                if not terms(pc.get(q, '')) or terms(pc.get(q, '')) != terms(rr.get(q, '-')):
                    bad('pic_in.' + q, 'must be ring_rd\'s %s' % q)
            for q in ('pd_ack', 'pd_busy'):
                if not terms(rr.get(q, '')) or terms(rr.get(q, '')) != terms(pc.get(q, '-')):
                    bad('ring_rd.' + q, 'must be pic_in\'s %s' % q)
            for p in ('emit_valid', 'emit_store', 'pinfo_we', 'pinfo_store', 'eos_done'):
                if not terms(pc.get('r_' + p, '')) or terms(pc.get('r_' + p, '')) != terms(rc.get(p, '-')):
                    bad('pic_in.r_' + p, 'must be recon_top\'s %s' % p)
                if not terms(conn.get(p, '')) or terms(conn.get(p, '')) != terms(pc.get(p, '-')):
                    bad('recon_out.' + p, 'must be pic_in\'s %s (recon_top\'s through its mux)' % p)
            # word 84: the holds and pic_emitted as one snapshot (the store rule needs them together)
            m = re.search(r"cdc_snap\s*#\s*\(\s*\.W\s*\(\s*52\s*\)\s*\)\s*pic_xing\s*\((.*?)\);", src, re.S)
            if not m:
                bad('pic_xing', 'word 84 must cross as one cdc_snap of {disp_hold, pic_emitted} (pic_xing)')
            else:
                xc = connections(m.group(1))
                if norm(xc.get('src_data', '')) != norm('{disp_hold, pic_emitted}') or \
                        terms(pc.get('pic_emitted', '')) != {'pic_emitted'} or \
                        terms(xc.get('src_clk', '')) != {'clk_dec'} or terms(xc.get('dst_clk', '')) != {'clk_sys'}:
                    bad('pic_xing', 'must snapshot {disp_hold, pic_emitted} (pic_in\'s count) from clk_dec into clk_sys')
            ws = inst('ring_words_sys')[1]
            if terms(ws.get('f_pic_held', '')) != {'pic_held'} or terms(ws.get('f_pic_emitted', '')) != {'pic_emitted_s'}:
                bad('ring_words_sys.f_pic_held', 'word 84 must be pic_xing\'s copy (pic_held, pic_emitted_s)')
        for p in ('rel_valid', 'rel_store', 'rec_take'):
            t = terms(conn.get(p, ''))
            if not t or all(re.match(r'^[bdh]\d*$', x) or x.isdigit() for x in t):
                bad('recon_out.' + p, 'must come from the display (a constant release leaves every store '
                                      'held -- the decoder stalls -- or frees stores still on screen)')
    name, conn = inst('disp_ctl')
    rd = inst('disp_reader')[1]
    if not conn:
        bad('disp_ctl', 'not instantiated -- nothing paces the display')
    else:
        if terms(conn.get('clk', '')) != {'clk_sys'} or terms(conn.get('rst_n', '')) != {'fe_rst_n'}:
            bad('disp_ctl', 'must run on clk_sys (the raster, the 90 kHz tick phased to it) with the per-stream reset')
        if terms(conn.get('frame0', '')) != {'frame0_sys'}:
            bad('disp_ctl.frame0', 'must be frame0_sys (the raster\'s frame start crossed in, in disp_ctl\'s mode)')
        for p, r in (('sh_store', 'pic_store'), ('sh_field', 'pic_field'), ('sh_parity', 'pic_parity'),
                     ('sh_valid', 'pic_valid'), ('sh_single', 'pic_single')):
            if not terms(conn.get(p, '')) or terms(conn.get(p, '')) != terms(R(rd.get(r, '-'))):
                bad('disp_reader.' + r, 'must be disp_ctl\'s %s (the store and field it decided)' % p)
        # P6: both run in the raster's mode -- a refresh is a field, a pixel two dots at 480i
        for mod, c in (('disp_ctl', conn), ('disp_reader', rd)):
            if terms(R(c.get('il', ''))) != {'raster_il_eff'}:
                bad(mod + '.il', 'must be raster_il_eff (the raster\'s mode): tied off, the 480i '
                                 'raster shows the left half of each line and paces frames, not fields')
        # 0.15: word 85 -- the field holds (docs/analog.md §5) -- disp_ctl's own count
        if not terms(conn.get('n_fhold', '')) or \
                terms(inst('ring_words_sys')[1].get('f_disp_fhold', '')) != terms(conn.get('n_fhold', '-')):
            bad('ring_words_sys.f_disp_fhold', 'word 85 must be disp_ctl\'s n_fhold (the field holds at 480i / 576i)')
        # interface 0.4: the settings request reaches Main only through osd_req (checked,
        # merged into the menu's own status) -- never a raw word into hps_io
        qconn = inst('osd_req')[1]
        hconn = inst('hps_io')[1]
        rrc = inst('ring_rd')[1]
        if not qconn or terms(hconn.get('status_in', '')) != terms(qconn.get('status_in', '-')) \
                or terms(hconn.get('status_set', '')) != terms(qconn.get('status_set', '-')) \
                or terms(qconn.get('status', '')) != {'status'} \
                or terms(qconn.get('set_word', '')) != terms(rrc.get('set_word', '-')) \
                or terms(qconn.get('set_tog', '')) != terms(rrc.get('set_tog', '-')):
            bad('osd_req', 'hps_io.status_in / status_set must be osd_req\'s, fed by the menu\'s status and '
                           'ring_rd\'s set_word / set_tog')
        # P6 steps 5 / 6: ONE raster standard -- the raster, the scheduler's refresh grid, the
        # reader's and the fit's line counts and csync's block all read the same one (a split
        # paces 60.00 Hz pictures on a 59.94 grid, or fetches 480 lines of a 576-line raster)
        sconn = inst('sync_gen')[1]
        if terms(R(sconn.get('std', ''))) != {'raster_std'} or terms(conn.get('std', '')) != {'raster_std'}:
            bad('raster_std', 'sync_gen.std and disp_ctl.std must both be raster_std, got %r / %r'
                % (sconn.get('std'), conn.get('std')))
        pal_src = (assign_of(src, 'raster_pal') or '').replace(' ', '')
        fc = inst('disp_fit')[1]
        cc = inst('vid_out')[1]                       # (hd_raster) csync_smpte's .pal is vid_out's
        if pal_src != "raster_std[1]" or any(terms(R(c.get('pal', ''))) != {'raster_pal'} for c in (rd, fc, cc)):
            bad('raster_pal', 'must include the 50 Hz family via raster_std[1], and disp_reader / disp_fit / vid_out (csync_smpte) .pal '
                              'must be raster_pal')
        # Content rate is retained while idle; Match Video Refresh applies it during playback.
        policy = inst('display_policy')[1]
        if not policy or terms(policy.get('source_std', '')) != {'std_auto_l'} or \
                not re.search(r'\bstd_auto_l\s*<=\s*rate_cls\s*;', src) or \
                not re.search(r'if\s*\(\s*rate_v\s*&&\s*!\s*stream_live\s*\)\s*std_auto_l\s*<=', src) or \
                terms(conn.get('rate_cls', '')) != {'rate_cls'} or terms(conn.get('rate_v', '')) != {'rate_v'}:
            bad('std_auto_l', 'must latch disp_ctl rate_cls while no picture is shown and feed display_policy')
        # P6 step 3: the fit's mode follows shared Display Shape and output family, latched per refresh.
        fname, fconn = inst('disp_fit')
        if not fconn:
            bad('disp_fit', 'not instantiated -- nothing fits the picture to the raster')
        elif terms(fconn.get('mode', '')) != {'fit_mode_l'} or not re.search(r'\bfit_mode_l\s*<=\s*fit_mode_want\s*;', src):
            bad('disp_fit.mode', 'must be fit_mode_l, latched from fit_mode_want once a refresh')
        else:
            # Display Shape alone, on every output family: 16:9 the anamorphic fit, 4:3
            # Letterbox. HDMI is told that same shape, so Fill (3) would mis-shape it.
            want = assign_of(src, 'fit_mode_want') or ''
            if want.replace(' ', '') != "status[2]?2'd2:2'd0":
                bad('fit_mode_want', "must be status[2] ? 2'd2 : 2'd0 (Display Shape on every output)")
        # Global De-flicker is enabled by status[29] low, latched at pickup, and only used
        # on interlaced frame stores; progressive output must leave the vertical filter inactive.
        if not re.search(r'"O\[29\],De-flicker,On,Off;"', src):
            bad("De-flicker menu", "must use the new bit with On first so the core OSD defaults to On")
        if fconn:
            for port, rport in (("hpf", "fit_hpf"), ("vpf", "fit_vpf")):
                if not terms(fconn.get(port, "")) or terms(fconn.get(port, "")) != terms(R(rd.get(rport, "-"))):
                    bad("disp_reader." + rport, "must be disp_fit's %s (published with the fit's set)" % port)
            if fconn.get("area", "").replace(" ", "") != "1'b1":
                bad("disp_fit.area", "must be 1'b1 (the Area pre-filter always)")
            at_src = assign_of(src, "fit_at") or ""
            sel = (assign_of(src, "at_sel") or "").replace(" ", "")
            if terms(fconn.get("at", "")) != {"fit_at"} or not re.search(r"\bat_opt_l\s*<=\s*at_sel\s*;", src) or \
                    sel != "~status[29]":
                bad("disp_fit.at", "must use global De-flicker, latched once a refresh from status[29]")
            elif not {"at_opt_l", "raster_il_eff", "sh_field"} <= terms(at_src) or "~sh_field" not in at_src.replace(" ", ""):
                bad("fit_at", "must gate De-flicker to interlaced frame stores")
        # (P6: the line carries a hide prefix -- H0: hidden while the 480i raster is on)
        m = re.search(r'"(?:[HhDd]\d)*O\[(\d+):(\d+)\],Deinterlace,Weave,Bob,Blend;"', src)
        want = 'status[%s:%s]' % m.groups() if m else None
        if want is None or R(rd.get('deint_mode', '')).replace(' ', '') != want:
            bad('disp_reader.deint_mode', 'must be the Deinterlace option\'s status bits (%s), got %r'
                % (want, rd.get('deint_mode')))
        rwconn = inst('ring_words_sys')[1]
        if R(rwconn.get('f_osd_anti_twitter', '')).replace(' ', '') != "status[29]?2'd1:2'd2":
            bad('ring_words_sys.f_osd_anti_twitter', 'must mirror the actual De-flicker choice as legacy Off=1 / On=2')
        if rwconn.get('f_display_deflicker', '').replace(' ', '') != '!status[29]&&raster_il_eff':
            bad('ring_words_sys.f_display_deflicker', 'must report De-flicker On only while the effective raster is interlaced')
    # the masters that drive a DDR3 port directly reset with the PLL lock ALONE (UMD's reload
    # hang, docs/hil_harness.md): a cdc_reset of `locked` into clk_mem
    lock_rst = None
    for c in dec_rsts:
        if terms(c.get('rst_n_in', '')) == {'locked'} and terms(c.get('clk', '')) == {'clk_mem'}:
            lock_rst = terms(c.get('rst_n_out', ''))
    if not lock_rst:
        bad('cdc_reset', 'no lock-only clk_mem reset (a cdc_reset of `locked` alone): the DDR3 '
                         'masters would reset with RESET and withdraw a held request')
    name, conn = mux_on('DDRAM_ADDR')
    if not conn:
        bad('ddr_mux2', 'not instantiated -- nothing drives the DDRAM port')
    else:
        if terms(conn.get('clk', '')) != {'clk_mem'}:
            bad('ddr_mux2.clk', 'must be clk_mem (the DDRAM port clock)')
        if lock_rst and terms(conn.get('rst_n', '')) != lock_rst:
            bad('ddr_mux2.rst_n', 'must be the lock-only clk_mem reset (%s): a reset with the '
                                  'stream or RESET withdraws a request held under waitrequest '
                                  '(a_abort handles a new stream)' % sorted(lock_rst))
        ab = conn.get('a_abort', '')
        if not ab.strip() or not any(t for t in terms(ab) if not re.match(r'^[bdh]\d*$', t)):
            bad('ddr_mux2.a_abort', 'must follow the per-stream reset (never a constant)')
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
        for a in ('a_address', 'a_read', 'a_write', 'a_waitrequest', 'a_readdata', 'a_readdatavalid'):
            t = terms(conn.get(a, ''))
            if not t or not next(iter(t)).startswith('dpb_'):
                bad('ddr_mux2.' + a, 'master A must be the DPB client (dpb_*), found %r' % conn.get(a))
    if not rd:
        bad('disp_reader', 'not instantiated -- nothing shows a picture')
    else:
        if terms(rd.get('clk', '')) != {'clk_vid'} or terms(rd.get('mclk', '')) != {'clk_mem'}:
            bad('disp_reader', 'clk must be clk_vid (the raster, hd_raster) and mclk clk_mem')
        vrs = [connections(b) for _, b in find_instances(src, 'cdc_reset') if b is not None]
        if not any(terms(c.get('clk', '')) == {'clk_vid'} and 'fe_rst_n' in terms(c.get('rst_n_in', ''))
                   and terms(c.get('rst_n_out', '')) == terms(rd.get('rst_n', '-')) for c in vrs):
            bad('disp_reader.rst_n', 'must be the per-stream reset released on clk_vid (a cdc_reset of fe_rst_n)')
        # (Phase 6b) ram2 carries two readers: the display (ram2's mux, master A) and the overlay
        # plane (B); the mux's port side is DDRAM2, read-only
        _, m2 = mux_on('DDRAM2_ADDR')
        _, ov = inst('ovl_plane')
        for a, w in (('ddr_address', 'DDRAM2_ADDR'), ('ddr_read', 'DDRAM2_RD'),
                     ('ddr_burstcount', 'DDRAM2_BURSTCNT'), ('ddr_waitrequest', 'DDRAM2_BUSY'),
                     ('ddr_readdata', 'DDRAM2_DOUT'), ('ddr_readdatavalid', 'DDRAM2_DOUT_READY')):
            if m2 and terms(m2.get(a, '')) != {w}:
                bad('ram2 ddr_mux2.' + a, 'must be %s (the display port)' % w)
        for a in ('address', 'burstcount', 'read', 'waitrequest', 'readdata', 'readdatavalid'):
            if m2 and (not terms(rd.get('ddr_' + a, '')) or terms(m2.get('a_' + a, '')) != terms(rd.get('ddr_' + a, '-'))):
                bad('disp_reader.ddr_' + a, 'must be ram2\'s mux master A (the display is ram2\'s master, not ram1\'s)')
            if m2 and ov and (not terms(ov.get('ddr_' + a, '')) or terms(m2.get('b_' + a, '')) != terms(ov.get('ddr_' + a, '-'))):
                bad('ovl_plane.ddr_' + a, 'must be ram2\'s mux master B')
        if m2:
            for a in ('a_write', 'b_write', 'a_abort'):
                if m2.get(a, '').replace(' ', '') != "1'b0":
                    bad('ram2 ddr_mux2.' + a, 'must be 1\'b0 (ram2 is read-only; its masters never withdraw)')
            if terms(m2.get('clk', '')) != {'clk_mem'} or (lock_rst and terms(m2.get('rst_n', '')) != lock_rst):
                bad('ram2 ddr_mux2', 'clk_mem, and the lock-only clk_mem reset (a held request survives RESET)')
        if ov:
            if terms(ov.get('clk', '')) != {'clk_vid'} or terms(ov.get('mclk', '')) != {'clk_mem'}:
                bad('ovl_plane', 'clk must be clk_vid (the raster, hd_raster) and mclk clk_mem')
            if lock_rst and terms(ov.get('mrst_n', '')) != lock_rst:
                bad('ovl_plane.mrst_n', 'must be the lock-only clk_mem reset: its master drives ram2')
            ls = [terms(c.get('rst_n_out', '')) for _, b in find_instances(src, 'cdc_reset') if b is not None
                  for c in [connections(b)] if terms(c.get('rst_n_in', '')) == {'locked', 'vid_locked'} and terms(c.get('clk', '')) == {'clk_vid'}]
            if not ls or terms(ov.get('rst_n', '')) != ls[0]:
                bad('ovl_plane.rst_n', 'must be the lock-only clk_vid reset (its handshakes with the engine, and a program\'s counts, survive RESET)')
            if terms(R(ov.get('rast_h', ''))) != {'geom_rh'} or terms(R(ov.get('rast_w', ''))) != {'geom_rw'}:
                bad('ovl_plane.rast_h', 'the canvas is centred on raster_geom\'s raster (geom_rw x geom_rh, the next frame\'s), not '
                                        'sync_gen\'s current lines: the first frame after a size change misplaced it')
            for p_, want in (('h_pos', {'h_pos'}), ('v_pos', {'v_pos'}), ('de_in', {'pixel_en'}),
                             ('il', {'raster_il_eff'}), ('pal', {'raster_pal'}), ('sess', {'rr_sess'})):
                if terms(R(ov.get(p_, ''))) != want:
                    bad('ovl_plane.' + p_, 'must be %s (the raster / the session: a stale descriptor never shows after a reload)' % sorted(want))
            if 'v_at_en' not in terms(ov.get('at_en', '')):
                bad('ovl_plane.at_en', 'must use the global De-flicker setting through the synchronized bundle')
        if lock_rst and terms(rd.get('mrst_n', '')) != lock_rst:
            bad('disp_reader.mrst_n', 'must be the lock-only clk_mem reset (%s): its fetch side '
                                      'drives ram2 and must never withdraw a held read' % sorted(lock_rst))
        for p in ('h_pos', 'v_pos'):
            if terms(rd.get(p, '')) != {p}:
                bad('disp_reader.' + p, 'must be sync_gen\'s %s' % p)
        if terms(rd.get('de_in', '')) != {'pixel_en'}:
            bad('disp_reader.de_in', 'must be sync_gen\'s pixel_en')
        # the DPB's base is one number in three places: the decoder writes it, the reader reads it
        bases = {params_of(src, m).replace(' ', '') for m in ('recon_top', 'disp_reader')}
        if len(bases) != 1 or 'DPB_BASE' not in next(iter(bases)):
            bad('DPB_BASE', 'recon_top and disp_reader must name the same DPB_BASE, found %s' % sorted(bases))
    for w, want in (('DDRAM2_CLK', {'clk_mem'}), ('DDRAM2_WE', None)):
        rhs = assign_of(src, w)
        if rhs is None:
            bad(w, 'not assigned')
        elif want is not None and terms(rhs) != want:
            bad(w, 'is `%s`, expected exactly %s' % (rhs, sorted(want)))
        elif want is None and rhs.replace(' ', '') != "1'b0":
            bad(w, 'must be 1\'b0 (the display port is read-only)')

    # ---- Auto's aspect from the SHOWN picture's VUI (disp_ctl's sh_*) ----
    name, conn = inst('aspect_vui')
    if not conn:
        bad('aspect_vui', 'not instantiated -- Auto ignores the stream\'s aspect')
    else:
        for port, want in (('aspect_idc', 'sh_ar_idc'), ('ext_sar_w', 'sh_sar_w'), ('ext_sar_h', 'sh_sar_h'),
                           ('w_mbs', 'sh_w'), ('hf_mbs', 'sh_hf'), ('valid', 'sh_valid'), ('clk', 'clk_sys')):
            if terms(conn.get(port, '')) != {want}:
                bad('aspect_vui.' + port, 'must be %s (the shown picture, on clk_sys)' % want)
        rhs = assign_of(src, 'auto_wide')
        if rhs is not None and 'live_wide' in terms(rhs):     # one level of indirection
            rhs = rhs + ' ' + (assign_of(src, 'live_wide') or '')
        if rhs is None or not {'vui_sar_known', 'vui_wide', 'sq_wide_q', 'stream_live'}.issubset(terms(rhs)):
            bad('auto_wide', 'Auto must take the VUI aspect (vui_sar_known / vui_wide), square pixels '
                             '(sq_wide_q) for an unspecified SAR, while a picture is shown; found %r' % rhs)

    # Display Shape is shared: VIDEO_AR follows the explicit wide bit for the complete canvas.
    if not re.search(r'wire\s+ar_wide\s*=\s*status\[2\]\s*;', src):
        bad('ar_wide', 'must follow the shared Display Shape bit 2')
    # Native (HDMI): the raster's own shape (ar_x / ar_y: the display's when display-shaped, the
    # picture's when picture-sized), never Display Shape's -- a 16:9-shaped raster told 4:3 is squeezed.
    if not re.search(r'wire\s+native_raster\s*=\s*geom_nat\s*;', src):
        bad('native_raster', 'must be geom_nat: every Native HDMI raster, display-shaped or picture-sized')
    for port, ratio, exact in (('VIDEO_ARX', "ar_wide?13'd16:13'd4", 'ar_x'),
                               ('VIDEO_ARY', "ar_wide?13'd9:13'd3", 'ar_y')):
        expr = (assign_of(src, port) or '').replace(' ', '')
        if 'native_raster?' not in expr or ("{1'b0,%s}" % exact) not in expr or ratio not in expr:
            bad(port, "must give a Native HDMI raster its own shape (ar_x / ar_y), Display Shape otherwise")

    # A' (docs/hdmi_raster.md §3a): the fit takes the HDMI display's shape latched at the
    # pickup with the mode (never live: a mode change would split a picture), and under `lb`
    # HDMI is given that shape, not the picture's
    name, conn = inst('disp_fit')
    for port, want in (('disp_w', 'fit_dw_l'), ('disp_h', 'fit_dh_l'), ('lb', 'fit_lb')):
        if terms(conn.get(port, '')) != {want}:
            bad('disp_fit.' + port, "must be %s (A': the display's shape latched with the mode)" % want)
    for reg, port in (('fit_dw_l', 'HDMI_WIDTH'), ('fit_dh_l', 'HDMI_HEIGHT')):
        if not re.search(r'\b%s\s*<=\s*%s\s*;' % (reg, port), src):
            bad(reg, 'must latch %s (with fit_mode_l, at the pickup)' % port)
    # F8: between streams the fit is a 0x0 picture's -- ar_x / ar_y must hold the last shown one's
    if not re.search(r'if\s*\(\s*!\s*stream_live\s*\)\s*begin\s*ar_x\s*<=\s*ar_x\s*;\s*ar_y\s*<=\s*ar_y\s*;', src):
        bad('ar_hold', 'F8: ar_x / ar_y must hold while no picture is shown (!stream_live): the fit of a 0x0 picture is 0 : 0')
    if not re.search(r'if\s*\(\s*fit_lb\s*\|\|\s*\(\s*geom_nat\s*&&\s*geom_disp\s*\)\s*\)\s*begin\s*ar_x\s*<=\s*fit_dw_l\s*;\s*ar_y\s*<=\s*fit_dh_l\s*;', src):
        bad('ar_x', "under A' (fit_lb) or a display-shaped native raster the aspect HDMI is given must be the display's, fit_dw_l : fit_dh_l")
    # stage 2 (docs/hdmi_raster.md): the native raster -- raster_geom's geometry into sync_gen and the
    # fit, the frame sync_gen scans into the reader, the latches at the pickup's phase
    name, conn = inst('sync_gen')
    for port, want in (('nat', 'geom_nat'), ('g_w', 'geom_rw'), ('g_h', 'geom_rh'), ('g_l', 'geom_l'),
                       ('g_nt', 'geom_nt'), ('g_last', 'geom_last'), ('lines', 'rast_lines'), ('last_line', 'rast_last')):
        if terms(R(conn.get(port, ''))) != {want}:
            bad('sync_gen.' + port, 'must be %s (the native raster)' % want)
    name, conn = inst('disp_fit')
    for port, want in (('nat', 'geom_nat'), ('nat_w', 'geom_rw'), ('nat_h', 'geom_rh')):
        if terms(conn.get(port, '')) != {want}:
            bad('disp_fit.' + port, 'must be %s (the picture 1:1 on the native raster)' % want)
    name, conn = inst('disp_reader')
    for port, want in (('lines', 'rast_lines'), ('last_line', 'rast_last')):
        if terms(conn.get(port, '')) != {want}:
            bad('disp_reader.' + port, "must be %s (the frame sync_gen scans: its wrap)" % want)
    name, conn = inst('raster_geom')
    if terms(conn.get('en', '')) != {'sh_valid', 'nat_req_l'} or terms(conn.get('req', '')) != {'nat_req_l'}:
        bad('raster_geom.en', 'must compute while a picture is shown or Native is off (hold between streams), '
                              'req the latched Native')
    for port, want in (('dw', 'fit_dw_l'), ('dh', 'fit_dh_l'), ('wc', 'fit_wc'), ('hc', 'fit_hc'), ('w_mbs', 'sh_w')):
        if terms(conn.get(port, '')) != {want}:
            bad('raster_geom.' + port, 'must be %s' % want)
    if not re.search(r'if\s*\(\s*disp_pick_ph\s*\)\s*begin', src) or \
       not re.search(r'nat_req_l\s*<=\s*\(\s*video_out_eff\s*==\s*2\'d3\s*\)\s*&\s*sh_valid', src):
        bad('nat_req_l', "the fit's latches (Native among them) must be taken at disp_ctl's pickup phase, Native as resolved (video_out_eff)")
    # F8 (docs/hdmi_raster.md §7): word 47 reports exactly what HDMI's scaler is given, and
    # (0.10) word 80 the fit's rectangle and A'
    name, conn = inst('ring_words_sys')
    for port, want in (('f_ar_x', "VIDEO_ARX[11:0]"), ('f_ar_y', "VIDEO_ARY[11:0]"),
                       ('f_raster_lb', 'fit_lb|(geom_nat&geom_disp)'), ('f_pic_x0', 'st_pic_x0'), ('f_pic_y0', 'st_pic_y0'),
                       # (0.17, F5) the fit's status gated by a shown picture (the st_* wires, checked below)
                       ('f_fit_crop_bad', 'st_fit_crop_bad'), ('f_fit_clamp', 'st_fit_clamp'), ('f_fit_snap', 'st_fit_snap'),
                       ('f_fit_ow', 'st_fit_ow'), ('f_fit_oh', 'st_fit_oh'), ('f_fit_valid', 'st_fit_valid'),
                       ('f_raster_w', 'geom_rw'), ('f_raster_h', 'geom_rh'), ('f_raster_mode', 'geom_mode'),
                       ('f_video_out', 'video_out_eff')):        # (0.14) Video Output as resolved
        if conn.get(port, '').replace(' ', '') != want:
            bad('ring_words_sys.' + port, 'must be %s; found %r' % (want, conn.get(port)))

    # (0.17, F5) each st_ wire is its fit value qualified by sh_valid (a picture shown), and fit_valid IS sh_valid
    for wname, src_ in (('st_fit_crop_bad', 'fit_crop_bad'), ('st_fit_clamp', 'fit_clamp'), ('st_fit_snap', 'fit_snap')):
        m = re.search(r'wire\s+%s\s*=\s*([^;]+);' % wname, src)
        if not m or m.group(1).replace(' ', '') != 'sh_valid&' + src_:
            bad(wname, 'must be sh_valid & %s (0 while no picture is shown)' % src_)
    for wname, src_ in (('st_fit_ow', 'fit_ow'), ('st_fit_oh', 'fit_oh'), ('st_pic_x0', 'fit_ox0[12:0]'), ('st_pic_y0', 'fit_oy0[12:0]')):
        m = re.search(r'wire\s*\[12:0\]\s*%s\s*=\s*([^;]+);' % wname, src)
        if not m or m.group(1).replace(' ', '') != "sh_valid?%s:13'd0" % src_:
            bad(wname, "must be sh_valid ? %s : 13'd0" % src_)
    m = re.search(r'wire\s+st_fit_valid\s*=\s*([^;]+);', src)
    if not m or m.group(1).strip() != 'sh_valid':
        bad('st_fit_valid', 'must be sh_valid (a picture is shown)')

    name, conn = inst('dec_stub')
    if conn and terms(conn.get('clk_dec', '')) != {'clk_dec'}:
        bad('dec_stub.clk_dec', 'must be clk_dec -- it exists to keep a register in that domain')
    rhs = assign_of(src, 'LED_USER')
    if rhs is None or terms(rhs) != {'dec_alive'}:
        bad('LED_USER', 'must be dec_alive (the clk_dec heartbeat)')

    if fails:
        sys.stderr.write('check_emu_wiring: FAIL (%s)\n' % rel)
        for f in fails:
            sys.stderr.write('  - %s\n' % f)
        return 1
    print('check_emu_wiring: PASS (%s) -- ports match sys_top, clocks/reset/hps_io/raster/'
          'idle-screen/HPS-interface/status/decoder/display seams wired as designed' % rel)
    return 0


if __name__ == '__main__':
    sys.exit(main())
