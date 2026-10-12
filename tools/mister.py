#!/usr/bin/env python3
"""
mister.py -- drive a MiSTer running the UMD core, over ssh.

The hardware-in-the-loop harness: deploy a build, launch an image, press buttons,
and pull back a screenshot -- so a session can SEE the core instead of asking
someone to test and report. Inherited from MiSTer_DVD (tools/mister.py there), cut
down to the parts that need NOTHING but a stock MiSTer Main. Design notes and the
facts it relies on are in docs/hil_harness.md.

Four stock mechanisms:

  load_core   /dev/MiSTer_cmd accepts an .mgl, which loads a core AND mounts
              media in one command.
  screenshot  the same FIFO writes a PNG of the CORE's raw raster (read from
              ascal's INPUT buffer), so it carries no MiSTer OSD, no popups and
              no scaling. You cannot see the OSD in a shot -- which is why options
              are set by writing the settings file, not by navigating menus.
  UMD_vN.CFG  the core's saved settings are a raw dump of Main's 128-bit status
              word, read at core init before reset is released -- so writing 16
              bytes sets any OSD option for the next launch.
  uinput      a virtual keyboard on the target (tools/mister_keyd.py) reaches the
              core's PS/2 path once umd/kbd_map.sv exists (roadmap P6). Until
              then `key` knows only the OSD toggle.

Configuration, in precedence order -- NEVER hardcode a host; this repository will
be public:
    $MISTER_HOST                 e.g. root@<mister-ip>
    tools/.mister_host           one line, gitignored
    $MISTER_CORE_DIR             default /media/fat/_Other
    $MISTER_CFG_DIR              default /media/fat/config

⚠ The rig is the maintainer's. Run `state` first, and `restore` when done.

Usage:
    mister.py state
    mister.py deploy [--rbf PATH] [--agent] [--main main/.build/MiSTer_UMD_hil]
    mister.py telem [--watch N] [--csv FILE]
    mister.py osd "Name=Value"
    mister.py launch <image-on-the-mister> [--opt "Name=Value"] ... [--delay N]
    mister.py wait
    mister.py key <name> [<name> ...]
    mister.py shot [-o FILE]
    mister.py options
    mister.py restore
    mister.py shell -- <command>
    mister.py seq "wait 20; key next-chapter; wait 8; shot a" [--out LOG] [--detach | --fetch]
"""

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import docs_check                                    # noqa: E402  (CONF_STR parser)

CORE_NAME = 'UMD'                                    # CONF_STR[0]; /tmp/CORENAME reads this
CORE_DIR = os.environ.get('MISTER_CORE_DIR', '/media/fat/_Other')
CFG_DIR = os.environ.get('MISTER_CFG_DIR', '/media/fat/config')
SHOT_DIR = '/media/fat/screenshots'
# A FIXED name, deliberately. MGL <rbf> resolution takes the lexicographically
# GREATEST match (mra_loader.cpp), not the newest file, so a bare "UMD" would pick
# whichever UMD_* build sorts last. The core name comes from CONF_STR, not the
# filename, so renaming costs nothing.
HIL_RBF = 'UMD_hil.rbf'
HIL_MGL = 'UMD_hil.mgl'
EMU = os.path.join(ROOT, 'umd', 'emu.sv')
KBD_MAP = os.path.join(ROOT, 'umd', 'kbd_map.sv')


def _cfg_name():
    """The saved-settings filename, READ FROM emu.sv's CONF_STR "v,N" line.

    A hardcoded name goes stale the day the config version is bumped, and a stale
    one fails SILENTLY: every --opt writes a file the core never reads and the
    harness measures defaults while reporting the options it thought it set.
    """
    try:
        m = re.search(r'"v,(\d+);"', open(EMU).read())
        if m:
            return '%s_v%s.CFG' % (CORE_NAME, m.group(1))
    except Exception:
        pass
    return CORE_NAME + '.CFG'


CFG_NAME = _cfg_name()
AGENT_SRC = os.path.join(HERE, 'mister_keyd.py')
AGENT_DST = '/tmp/mister_keyd.py'
AGENT_FIFO = '/tmp/mister_hil'

SSH_OPTS = [
    '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8',
    '-o', 'StrictHostKeyChecking=accept-new',
    '-o', 'ControlMaster=auto', '-o', 'ControlPath=~/.ssh/cm-mister-%C',
    '-o', 'ControlPersist=120',
]


def kill_exact(cmdline):
    """Shell snippet: kill every process whose argv is EXACTLY `cmdline`.

    The MiSTer has NO pkill and no killall: `pkill -f ...` fails silently, and
    MiSTer_DVD found 18 leaked key daemons that way. Walk /proc instead; an EXACT
    argv match so it cannot hit the shell running this very script.
    """
    return ("for pid in $(ls /proc | grep -E '^[0-9]+$'); do\n"
            "  c=$( { tr '\\000' ' ' < /proc/$pid/cmdline; } 2>/dev/null )\n"
            f"  [ \"$c\" = \"{cmdline} \" ] && kill $pid 2>/dev/null\n"
            "done\n")


# ---- the HIL Main (main/README.md): telemetry + the live OSD channel ----------------------
# Only the [UMD] section of MiSTer.ini is touched, and only through lines marked "; umd-hil"
# (MiSTer_DVD's harness owns MiSTer.ini.hilbak and [DVD] main= -- never collide with it).
HIL_MAIN_PREFIX = 'MiSTer_UMD_hil_'
HIL_ARM = '/media/fat/umd_hil'
TELEM_JSON = '/tmp/umd_telem.json'
CTL_FIFO = '/tmp/umd_ctl'
INI_SET_SCRIPT = """
chmod +x /media/fat/@NAME@
python3 - <<'PYEND'
import os, re
p = '/media/fat/MiSTer.ini'
s = open(p, encoding='utf-8', errors='replace').read()
# our line is recognised by its VALUE (the hash-named binary); no inline comment -- the
# ini parser's handling of one is not something to bet a Main path on
s = '\\n'.join(l for l in s.split('\\n') if not re.match(r'\\s*main\\s*=\\s*@PREFIX@', l))
m = re.search(r'(?m)^\\[UMD\\]\\s*$', s)
if m:
    # LAST in the section: Main takes the last main= of a section, and a user's own UMD Main
    # line (an installed release: [UMD] main=MiSTer_UMD) must not win over the harness's
    # (2026-10-09: inserted after the header, the maintainer's line below it ran instead)
    nxt = re.search(r'(?m)^\\[', s[m.end():])
    end = m.end() + (nxt.start() if nxt else len(s) - m.end())
    body = s[m.end():end].rstrip('\\n')
    s = s[:m.end()] + body + '\\nmain=@NAME@\\n' + ('\\n' + s[end:] if nxt else '')
else:
    s = s.rstrip('\\n') + '\\n\\n[UMD]\\nmain=@NAME@\\n'
    open('/media/fat/umd_hil_ini_section', 'w').write('the HIL harness created [UMD] in MiSTer.ini\\n')
open(p, 'w').write(s)
print('  [UMD] main=@NAME@')
PYEND
touch @ARM@
for f in /media/fat/@PREFIX@*; do
  [ -e "$f" ] || continue
  b=$(basename "$f")
  [ "$b" = "@NAME@" ] && continue
  running=0
  for pid in $(ls /proc | grep -E '^[0-9]+$'); do
    [ "$(readlink /proc/$pid/exe 2>/dev/null)" = "$f" ] && running=1
  done
  if [ $running = 0 ]; then rm -f "$f"; echo "  removed stale $b"; fi
done
true
"""


def deploy_main(path):
    """Install the HIL Main SAFELY (MiSTer_DVD's rule): NEVER over the running binary
    (Main re-execs /proc/self/exe; writing over it reboots the box) -- under a name
    derived from its hash, pointed at by [UMD] main=, taking effect at the next core load."""
    import hashlib
    sha = hashlib.sha256(open(path, 'rb').read()).hexdigest()[:8]
    name = HIL_MAIN_PREFIX + sha
    target = '/media/fat/' + name
    print('deploy: %s -> %s' % (os.path.basename(path), target))
    _, running = ssh("for p in $(ls /proc | grep -E '^[0-9]+$'); do "
                     "readlink /proc/$p/exe 2>/dev/null; done | grep MiSTer | sort -u\n", check=False)
    if target in running.split():
        print('  already running this exact binary -- nothing to copy')
    else:
        scp(path, target)
    _, out = ssh(INI_SET_SCRIPT.replace('@NAME@', name).replace('@ARM@', HIL_ARM)
                 .replace('@PREFIX@', HIL_MAIN_PREFIX))
    print(out.rstrip())
    print('  armed (%s); takes effect at the next core load' % HIL_ARM)


RESTORE_SCRIPT = """
@KILL_AGENT@
rm -f @ARM@
if grep -q '^main=@PREFIX@' /media/fat/MiSTer.ini 2>/dev/null; then
  python3 - <<'PYEND'
import os, re
p = '/media/fat/MiSTer.ini'
s = open(p, encoding='utf-8', errors='replace').read()
s = '\\n'.join(l for l in s.split('\\n') if not re.match(r'\\s*main\\s*=\\s*@PREFIX@', l))
flag = '/media/fat/umd_hil_ini_section'
if os.path.exists(flag):                     # we created [UMD]: drop it if nothing else is in it
    s = re.sub(r'\\n*\\[UMD\\]\\s*(?=\\n\\[|\\Z)', '\\n', s).rstrip('\\n') + '\\n'
    os.remove(flag)
open(p, 'w').write(s)
PYEND
  echo "  [UMD] main= removed (the harness's line only); the running Main stays until the next core load"
fi
rm -f @FIFO@ @AGENT@ @COREDIR@/@RBF@ @COREDIR@/@MGL@
echo "  harness files removed (core, mgl, agent)"
if [ -f @CFGDIR@/@CFG@.hilbak ]; then
  mv -f @CFGDIR@/@CFG@.hilbak @CFGDIR@/@CFG@
  echo "  restored the saved settings the harness had overwritten"
elif [ -f @CFGDIR@/@CFG@.hilnew ]; then
  rm -f @CFGDIR@/@CFG@ @CFGDIR@/@CFG@.hilnew
  echo "  removed the settings file the harness had created"
fi
# Removing the .rbf does not unload it: a harness-launched UMD core keeps running. Back
# to the menu -- but only if it is OUR core; any other core is the maintainer's.
if [ "$(cat /tmp/CORENAME 2>/dev/null)" = "UMD" ] && [ -f /media/fat/menu.rbf ]; then
  echo "load_core /media/fat/menu.rbf" > /dev/MiSTer_cmd
  echo "  UMD core unloaded: back to the menu"
  sleep 4                                    # the menu load re-execs stock Main: let it swap
fi
# the HIL Main binaries, AFTER the menu load swapped Main back (1 MB each; the card is nearly full) -- never the running one
for f in /media/fat/@PREFIX@*; do
  [ -e "$f" ] || continue
  running=0
  for pid in $(ls /proc | grep -E '^[0-9]+$'); do
    [ "$(readlink /proc/$pid/exe 2>/dev/null)" = "$f" ] && running=1
  done
  if [ $running = 0 ]; then rm -f "$f"; echo "  removed $(basename $f)"; fi
done
true
"""


# ---------------------------------------------------------------------------
# transport
# ---------------------------------------------------------------------------
def host():
    h = os.environ.get('MISTER_HOST')
    if h:
        return h.strip()
    path = os.path.join(HERE, '.mister_host')
    if os.path.exists(path):
        h = open(path).read().strip()
        if h:
            return h
    sys.exit('mister: no host. Set $MISTER_HOST or write tools/.mister_host '
             '(one line, e.g. root@<mister-ip>). It is gitignored.')


def ssh(script, check=True, timeout=120):
    """Run a shell script on the target. Returns (rc, stdout)."""
    p = subprocess.run(['ssh', *SSH_OPTS, host(), 'bash -s'],
                       input=script, capture_output=True, text=True,
                       timeout=timeout)
    if check and p.returncode != 0:
        sys.stderr.write(p.stderr)
        sys.exit(f'mister: remote command failed (rc={p.returncode})')
    return p.returncode, p.stdout


def scp(src, dst, to_target=True, timeout=180):
    a, b = (src, f'{host()}:{dst}') if to_target else (f'{host()}:{src}', dst)
    p = subprocess.run(['scp', *SSH_OPTS, '-q', a, b],
                       capture_output=True, text=True, timeout=timeout)
    if p.returncode != 0:
        sys.stderr.write(p.stderr)
        sys.exit(f'mister: scp failed ({a} -> {b})')


def fifo(cmd):
    """Write ONE command to /dev/MiSTer_cmd. One per write, always: Main does a single
    read() then one if/else chain, so a second command in the same write is dropped."""
    ssh(f'echo {shlex.quote(cmd)} > /dev/MiSTer_cmd\n')


# ---------------------------------------------------------------------------
# key names, derived from the RTL rather than hand-listed
# ---------------------------------------------------------------------------
# PS/2 set-2 -> Linux keycode, inverted from Main's own ev2ps2[] (input.cpp).
PS2_TO_LINUX = {
    (0x04, False): 61, (0x05, False): 59, (0x06, False): 60, (0x0C, False): 62,
    (0x0D, False): 15, (0x1B, False): 31, (0x1C, False): 30, (0x22, False): 45,
    (0x23, False): 32, (0x29, False): 57, (0x2B, False): 33, (0x2C, False): 20,
    (0x2D, False): 19, (0x31, False): 49, (0x32, False): 48, (0x34, False): 34,
    (0x3A, False): 50, (0x4D, False): 25, (0x5A, False): 28, (0x66, False): 14,
    (0x76, False): 1,
    (0x15, False): 16, (0x1A, False): 44, (0x03, False): 63,
    (0x4B, False): 38, (0x49, False): 52,
    (0x24, False): 18, (0x79, False): 78, (0x7B, False): 74,
    (0x5A, True): 96, (0x6B, True): 105, (0x72, True): 108, (0x74, True): 106,
    (0x75, True): 103, (0x7A, True): 109, (0x7D, True): 104,
}
DPAD = {0: 'right', 1: 'left', 2: 'down', 3: 'up'}
# kbd_map bits no CONF_STR button names (A-B Repeat: keyboard-only, docs/ab_repeat.md AB7; was Frame Step)
KBD_ONLY = {15: 'a-b-repeat'}
KEY_F12 = 88


def kbd_map_table():
    """Parse umd/kbd_map.sv -> {joy bit: [(ps2 code, extended), ...]}.

    Derived, not transcribed, so a new binding in the RTL is usable the same day.
    Returns {} while the module does not exist yet (roadmap P6).
    """
    if not os.path.exists(KBD_MAP):
        return {}
    src = open(KBD_MAP).read()
    m = re.search(r'if \(ps2_key\[8\]\) begin(.*?)\n\s*end else begin(.*?)\n\s*end\b',
                  src, re.S)
    if not m:
        sys.exit('mister: could not find the kbd_map.sv decode table')
    out = {}
    for extended, body in ((True, m.group(1)), (False, m.group(2))):
        body = re.sub(r'//[^\n]*', '', body)
        for code, bit in re.findall(r"8'h([0-9A-Fa-f]{2}):\s*hit\[(\d+)\]", body):
            out.setdefault(int(bit), []).append((int(code, 16), extended))
    return out


def key_names():
    """{name: linux keycode} for every transport action the core exposes."""
    lits = docs_check.extract_conf_str(open(EMU).read())
    _, buttons, _ = docs_check.parse(lits)
    names = {}
    for bit, codes in sorted(kbd_map_table().items()):
        linux = None
        for code, ext in codes:
            linux = PS2_TO_LINUX.get((code, ext))
            if linux is not None:
                break
        if linux is None:
            continue
        if bit in DPAD:
            label = DPAD[bit]
        elif bit - 4 < len(buttons):
            label = buttons[bit - 4]
        elif bit in KBD_ONLY:
            label = KBD_ONLY[bit]
        else:
            continue
        names[label.lower().replace(' ', '-')] = linux
    names['osd'] = KEY_F12          # Main's OSD toggle, not a core action
    return names


# ---------------------------------------------------------------------------
# OSD options -> the 16-byte saved-settings blob
# ---------------------------------------------------------------------------
def options():
    return docs_check.parse_bits(docs_check.extract_conf_str(open(EMU).read()))


def build_status(opts):
    """[('Aspect Ratio', '16:9'), ...] -> 16 bytes of cur_status. ALL 16 bytes are
    written from the full option set: the blob has no version or checksum."""
    table = options()
    by_label = {label.lower(): (label, s, e, vals) for label, s, e, vals in table}
    word = 0
    for name, value in opts:
        entry = by_label.get(name.strip().lower())
        if entry is None:
            sys.exit(f'mister: unknown option {name!r}. Try: mister.py options')
        label, start, end, vals = entry
        value = value.strip()
        idx = None
        for i, v in enumerate(vals):
            if v.strip().lower() == value.lower():
                idx = i
                break
        if idx is None:
            if re.fullmatch(r'\d+', value):
                idx = int(value)
            else:
                sys.exit(f'mister: {label!r} has no value {value!r}. '
                         f'Choices: {", ".join(vals)}')
        width = end - start + 1
        if idx >= (1 << width):
            sys.exit(f'mister: value {idx} does not fit {label!r} ({width} bits)')
        word |= idx << start
    return word.to_bytes(16, 'little')


# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------
def newest_rbf():
    rel = os.path.join(ROOT, 'releases')
    cands = [os.path.join(rel, f) for f in os.listdir(rel)] if os.path.isdir(rel) else []
    cands = [c for c in cands if c.endswith('.rbf')]
    if not cands:
        sys.exit('mister: no .rbf in releases/ -- build one, or pass --rbf')
    return max(cands, key=os.path.getmtime)


def cmd_restore(args):
    """Put the rig back: harness files removed, the user's saved settings restored."""
    script = RESTORE_SCRIPT.replace('@KILL_AGENT@', kill_exact(f'python3 {AGENT_DST}')) \
                           .replace('@ARM@', HIL_ARM).replace('@PREFIX@', HIL_MAIN_PREFIX) \
                           .replace('@AGENT@', AGENT_DST).replace('@FIFO@', AGENT_FIFO) \
                           .replace('@COREDIR@', CORE_DIR).replace('@CFGDIR@', CFG_DIR) \
                           .replace('@RBF@', HIL_RBF).replace('@MGL@', HIL_MGL) \
                           .replace('@CFG@', CFG_NAME)
    _, out = ssh(script)
    print('restore:')
    print(out.rstrip())
    st = os.path.join(HERE, '.mister_state.json')
    if os.path.exists(st):
        os.remove(st)
    return 0


def cmd_deploy(args):
    if args.main:
        deploy_main(args.main)
        if not args.rbf and not args.agent:
            return 0
    ssh(f'mkdir -p {SHOT_DIR}\n')
    if args.agent:
        scp(AGENT_SRC, AGENT_DST)
        _, out = ssh(kill_exact(f'python3 {AGENT_DST}') + f'''
rm -f {AGENT_FIFO}
setsid python3 {AGENT_DST} </dev/null >>/tmp/mister_keyd.log 2>&1 &
sleep 2
[ -p {AGENT_FIFO} ] && echo "agent: listening" || echo "agent: FIFO MISSING"
''')
        print(out.strip())
    # `--agent` alone means "agent only"; an explicit --rbf is an instruction and wins.
    if args.rbf or not args.agent:
        rbf = args.rbf or newest_rbf()
        print(f'deploy: {os.path.basename(rbf)} -> {CORE_DIR}/{HIL_RBF}')
        scp(rbf, f'{CORE_DIR}/{HIL_RBF}')
        meta = rbf + '.json'
        state = {'rbf': os.path.basename(rbf), 'deployed': time.strftime('%F %T')}
        if os.path.exists(meta):
            try:
                j = json.load(open(meta))
                state['core_version'] = j.get('core_version')
                state['git_sha'] = (j.get('git') or {}).get('sha')
                state['seed'] = (j.get('fit') or {}).get('seed')
                state['marginal'] = (j.get('rbf') or {}).get('marginal')
            except Exception:
                pass
        with open(os.path.join(HERE, '.mister_state.json'), 'w') as f:
            json.dump(state, f, indent=2)
        for k, v in state.items():
            print(f'  {k}: {v}')


def _telem_rows(watch):
    n = max(1, int(watch / 0.25))
    _, out = ssh(f'for i in $(seq 1 {n}); do cat {TELEM_JSON} 2>/dev/null; sleep 0.25; done\n',
                 timeout=watch + 60)
    rows, seen = [], set()
    for line in out.splitlines():
        line = line.strip()
        if line.startswith('{'):
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if r['t'] not in seen:                   # dedupe: umd_ctl writes at 4 Hz
                seen.add(r['t'])
                rows.append(r)
    return rows


def _unwrapped(rows, key, bits):
    """a free-running counter, unwrapped (it wraps at 2^bits between samples at most once)"""
    out, acc, prev = [], 0, rows[0][key]
    for r in rows:
        acc += (r[key] - prev) & ((1 << bits) - 1)
        prev = r[key]
        out.append(acc)
    return out


def _rate(ts, ys):
    """least-squares slope: endpoint differencing carries +/-1 count on each end
    (MiSTer_DVD measured +/-270 ppm over 3,709 pickups; the fit over 240 samples, single ppm)"""
    n = len(ts)
    mt, my = sum(ts) / n, sum(ys) / n
    den = sum((t - mt) ** 2 for t in ts)
    return sum((t - mt) * (y - my) for t, y in zip(ts, ys)) / den if den else 0.0


def cmd_telem(args):
    """The core's counters (umd/umd_telem.sv -> the HIL Main's umd_ctl -> JSON)."""
    if not args.watch:
        _, out = ssh(f'cat {TELEM_JSON} 2>/dev/null\n', check=False)
        if not out.strip():
            sys.exit('mister: no telemetry -- needs the HIL Main (deploy --main) armed and the UMD core running')
        print(out.strip())
        return 0
    import telem_layout as TL
    rows = _telem_rows(args.watch)
    if len(rows) < 8:
        sys.exit(f'mister: only {len(rows)} telemetry samples -- is the HIL Main armed and the core playing?')
    ts = [r['t'] - rows[0]['t'] for r in rows]
    span = ts[-1]
    scale = {nm: sc for nm, _k, _e, _a, sc, _w in TL.FIELDS}
    def inc(key):
        return [x * scale[key] for x in _unwrapped(rows, key, 16)]   # 16-bit words, pre-divided
    def rate(key):
        return _rate(ts, inc(key))
    print(f'telemetry over {span:.1f} s ({len(rows)} samples, format {rows[-1].get("format")})')
    rr, pk = rate('refreshes'), rate('pickups')
    print(f'  raster  {rr:9.4f} Hz  ({(rr / (60000 / 1001.0) - 1) * 1e6:+.0f} ppm vs 59.94)')
    print(f'  pickups {pk:9.4f}/s', end='')
    for name, ideal in (('23.976', 24000 / 1001.0), ('29.97', 30000 / 1001.0), ('59.94', 60000 / 1001.0)):
        if abs(pk - ideal) / ideal < 0.02:
            print(f'  ({(pk / ideal - 1) * 1e6:+.0f} ppm vs {name})', end='')
    print()
    if pk:
        print(f'  refreshes per pickup {rr / pk:.5f}   (3:2 film and 23.976: 2.50000, field pairs: 2.00000)')
    stc = rate('stc')
    print(f'  STC     {stc:9.1f} ticks/s  ({(stc / 90000 - 1) * 1e6:+.0f} ppm vs 90 kHz; the raster clock)')
    dc, ft = inc('dc'), inc('ft')
    print(f'  judder gate: decided +{dc[-1]}  fetched +{ft[-1]}  -> {"EQUAL" if dc[-1] == ft[-1] else "DIFFER"}')
    for k in ('late', 'starve', 'cadence'):
        print(f'  {k:8s} +{inc(k)[-1]}')
    ra = [r['sched'] >> 8 for r in rows]
    lag = [r['lag_ms'] for r in rows]
    print(f'  re-anchors {ra[0]} -> {ra[-1]}   lag {min(lag)} .. {max(lag)} ms   flags {rows[-1]["sched"] >> 4 & 7}')
    print(f'  decode   {rate("pics"):8.2f} pictures/s  {rate("mbs"):9.0f} MB/s  {rate("se") / 1e6:6.2f} M SE/s  '
          f'{rate("packs"):6.1f} packs/s')
    print(f'  ram1     {rate("d1_wr") / 1e6:6.2f} M wr beats/s  {rate("d1_rdb") / 1e6:6.2f} M rd beats/s  '
          f'busy now {rows[-1]["d1_busy"]}  longest {max(r["d1_busy_max"] for r in rows)}  owed {rows[-1]["d1_owed"]}')
    print(f'  ram2     {rate("d2_rdb") / 1e6:6.2f} M rd beats/s  '
          f'busy now {rows[-1]["d2_busy"]}  longest {max(r["d2_busy_max"] for r in rows)}  owed {rows[-1]["d2_owed"]}')
    if 'aud_frames' in rows[-1]:
        # P6a: the audio path. 48 kHz / 2,048 samples = 23.4375 frames/s, decoded and played;
        # av_err is every frame start's STC - PTS as it plays (0 in step; 90 ticks = 1 ms)
        fr = 48000 / 2048.0
        dec, ply = rate('aud_frames'), rate('aud_played')
        print(f'  audio    decoded {dec:7.3f}/s  played {ply:7.3f}/s  '
              f'({(ply / fr - 1) * 1e6:+.0f} ppm vs {fr})' if ply else
              f'  audio    decoded {dec:7.3f}/s  played 0 (the gate never released)')
        av = [r['av_err'] for r in rows if r['aud_state'] >> 13 & 1]
        rearm0, rearm1 = rows[0]['aud_rearm'], rows[-1]['aud_rearm']
        st = rows[-1]['aud_state']
        print(f'  av_err   {min(av) if av else "-"} .. {max(av) if av else "-"} ticks '
              f'({(min(av) / 90.0) if av else 0:+.2f} .. {(max(av) / 90.0) if av else 0:+.2f} ms)   '
              f'RUN {st >> 15 & 1}  STC {st >> 14 & 1}')
        print(f'  re-arms  underrun {rearm0 >> 8} -> {rearm1 >> 8}  resync {rearm0 & 255} -> {rearm1 & 255}   '
              f'dropped +{inc("aud_drop")[-1]} pairs   refused {rows[-1]["aud_err"] >> 8} '
              f'(last {rows[-1]["aud_err"] & 255})   fallback {st >> 8 & 15}  missing tags {st >> 4 & 15}')
        print(f'  ring     now {rows[-1]["ring_fill"]}  max {max(r["ring_max"] for r in rows)} bytes   '
              f'demux blocked on audio {rate("ring_bp") / 27e6 * 100:5.1f} %   '
              f'slides {rows[-1]["ring_tags"] >> 8}  PTS jumps {rows[-1]["ring_tags"] & 255}')
    if 'vbuf_fill' in rows[-1]:
        print(f'  vbuf     now {rows[-1]["vbuf_fill"]} KB  max {max(r["vbuf_max"] for r in rows)} KB   '
              f'demux blocked on video {rate("vbuf_bp") / 27e6 * 100:5.1f} %   late bytes {rows[-1]["vbuf_late"]}')
    if 'reader' in rows[-1]:
        rd = rows[-1]['reader']
        fl = [nm for b, nm in ((0, 'no video map'), (1, 'entry past the clip'), (2, 'target >= 2^32'))
              if rd >> b & 1]
        print(f'  reader   state {rd >> 10}  err_code {rd >> 6 & 15}   '
              f'EP lookups: {", ".join(fl) if fl else "clean"}')
    if args.csv:
        cols = list(rows[0].keys())
        with open(args.csv, 'w') as f:
            f.write(','.join(cols) + '\n')
            for r in rows:
                f.write(','.join(str(r.get(c, '')) for c in cols) + '\n')
        print(f'  wrote {args.csv}')
    return 0


def cmd_osd(args):
    """Set an OSD option LIVE through the HIL Main's FIFO (no relaunch)."""
    name, _, value = args.setting.partition('=')
    table = {label.lower(): (label, s, e, vals) for label, s, e, vals in options()}
    ent = table.get(name.strip().lower())
    if ent is None:
        sys.exit(f'mister: unknown option {name!r}. Try: mister.py options')
    label, start, end, vals = ent
    idx = next((i for i, v in enumerate(vals) if v.strip().lower() == value.strip().lower()), None)
    if idx is None:
        if not re.fullmatch(r'\d+', value.strip()):
            sys.exit(f'mister: {label!r} has no value {value!r}. Choices: {", ".join(vals)}')
        idx = int(value)
    opt = f'[{end}:{start}]' if end != start else f'[{start}]'
    _, out = ssh(f'[ -p {CTL_FIFO} ] && echo "osd {opt} {idx}" > {CTL_FIFO} && echo sent || echo "no {CTL_FIFO}"\n',
                 check=False)
    if 'sent' not in out:
        sys.exit(f'mister: {CTL_FIFO} missing -- needs the HIL Main armed and the UMD core running')
    print(f'osd: {label} = {vals[idx] if idx < len(vals) else idx}  ({opt} <= {idx})')
    return 0


def cmd_launch(args):
    img = args.image
    opts = [tuple(o.split('=', 1)) for o in (args.opt or [])]
    for o in opts:
        if len(o) != 2:
            sys.exit('mister: --opt takes "Name=Value"')
    blob = build_status(opts)
    print(f'launch: {img}')
    if opts:
        print('  options: ' + ', '.join(f'{k}={v}' for k, v in opts))
    print(f'  status word: {blob.hex()}')
    mgl = (f'<mistergamedescription>\n'
           f'  <rbf>{os.path.basename(CORE_DIR)}/{HIL_RBF[:-4]}</rbf>\n'
           f'  <file delay="{args.delay}" type="s" index="0" path="{img}"/>\n'
           f'</mistergamedescription>\n')
    # This OVERWRITES the user's saved OSD settings for the core. Back them up once.
    ssh(f'''
# Back up the user's file ONCE; if there was none, mark that the harness created it, so a
# second launch does not back up the harness's own file as the user's (found by the H264
# fork's P0 HW gate: restore put the first launch's file back as "the user's settings").
if [ ! -f {CFG_DIR}/{CFG_NAME}.hilbak ] && [ ! -f {CFG_DIR}/{CFG_NAME}.hilnew ]; then
  if [ -f {CFG_DIR}/{CFG_NAME} ]; then cp {CFG_DIR}/{CFG_NAME} {CFG_DIR}/{CFG_NAME}.hilbak
  else touch {CFG_DIR}/{CFG_NAME}.hilnew; fi
fi
python3 -c "import sys;open('{CFG_DIR}/{CFG_NAME}','wb').write(bytes.fromhex('{blob.hex()}'))"
cat > {CORE_DIR}/{HIL_MGL} <<'MGLEOF'
{mgl}MGLEOF
''')
    fifo(f'load_core {CORE_DIR}/{HIL_MGL}')
    if not args.no_wait:
        cmd_wait(args)


def cmd_wait(args):
    """Wait for the core to be loaded, then for the MGL delay to have elapsed."""
    deadline = time.time() + args.timeout
    while time.time() < deadline:
        _, out = ssh('cat /tmp/CORENAME 2>/dev/null\n', check=False, timeout=30)
        if out.strip() == CORE_NAME:
            break
        time.sleep(0.5)
    else:
        sys.exit(f'mister: timed out waiting for the {CORE_NAME} core')
    # No custom Main here, so there is no "MGL finished" log line to wait on; the
    # mount lands `delay` seconds after the load. Wait that out plus a margin.
    time.sleep(getattr(args, 'delay', 2) + 1.5)
    print(f'  {CORE_NAME} core loaded')


def cmd_key(args):
    names = key_names()
    codes = []
    for n in args.names:
        n = n.lower()
        if n.isdigit():             # a raw Linux keycode (an alternate key: Tab, F3, ...)
            codes.append(int(n))
            continue
        if n not in names:
            sys.exit(f'mister: unknown key {n!r}. Known: {", ".join(sorted(names))}')
        codes.append(names[n])
    _, out = ssh(f'''
[ -p {AGENT_FIFO} ] || {{ echo "NOAGENT"; exit 0; }}
echo "keys {' '.join(str(c) for c in codes)}" > {AGENT_FIFO}
echo sent
''')
    if 'NOAGENT' in out:
        sys.exit('mister: key daemon is not running -- `mister.py deploy --agent`')
    print(f'key: {" ".join(args.names)}  ({", ".join(str(c) for c in codes)})')


def cmd_shot(args):
    name = 'hil.png'
    # --scaled: Main's `screenshot scaled` captures the SCALER's output (the HDMI frame,
    # cropped to the active picture), so the image's width shows the aspect the core
    # reports (VIDEO_ARX/ARY): 1440x1080 for 4:3, 1920x1080 for 16:9 on a 1080p output.
    # The plain shot is the core's raw raster, where aspect is invisible.
    what = 'screenshot scaled' if args.scaled else 'screenshot'
    # The PNG is written asynchronously with no temp-and-rename: poll for existence
    # AND a stable size.
    ssh(f'''
rm -f {SHOT_DIR}/{name}
echo '{what} {name}' > /dev/MiSTer_cmd
for i in $(seq 1 20); do
  sleep 0.25
  if [ -f {SHOT_DIR}/{name} ]; then
    a=$(stat -c %s {SHOT_DIR}/{name}); sleep 0.25
    b=$(stat -c %s {SHOT_DIR}/{name})
    [ "$a" = "$b" ] && [ "$a" != 0 ] && exit 0
  fi
done
echo "NOSHOT"; exit 1
''', check=False)
    out = args.out or os.path.join(
        os.environ.get('TMPDIR', '/tmp'), f'mister_{time.strftime("%H%M%S")}.png')
    scp(f'{SHOT_DIR}/{name}', out, to_target=False)
    print(f'shot: {out}')


def cmd_state(args):
    _, out = ssh('''
echo "corename=$(cat /tmp/CORENAME 2>/dev/null)"
for p in $(ls /proc | grep -E '^[0-9]+$'); do
  e=$(readlink /proc/$p/exe 2>/dev/null)
  case "$e" in *MiSTer*) echo "main=$e";; esac
done
[ -p ''' + AGENT_FIFO + ''' ] && echo "agent=listening" || echo "agent=down"
true
''')
    print(out.rstrip())
    st = os.path.join(HERE, '.mister_state.json')
    if os.path.exists(st):
        print('--- deployed ---')
        for k, v in json.load(open(st)).items():
            print(f'{k}={v}')


# ---------------------------------------------------------------------------
# seq: a timed sequence run ON the target (P6b7, the rig gates of docs/transport.md S6)
# ---------------------------------------------------------------------------
# ssh-paced presses land 1-2 s apart and a 4 Hz poll from the host carries ssh's jitter
# too; one python process on the target presses, marks and samples the telemetry JSON
# in ONE timebase: time.monotonic() is CLOCK_MONOTONIC, the clock umd_ctl stamps "t"
# with. Its log is JSON lines: {"k": "telem", "mt", "r": {...}}, {"k": "key", "mt",
# "keys", "codes"}, {"k": "mark", "mt", "text"}, {"k": "shot", "mt", "name"}, {"k": "end"}.
SEQ_LOG = '/tmp/umd_seq.jsonl'
SEQ_PY = r"""
import json, os, sys, threading, time
steps = json.loads(sys.argv[1])
TELEM, AGENT, CMD, LOG = '@TELEM@', '@AGENT@', '/dev/MiSTer_cmd', '@LOG@'
out = open(LOG, 'w'); lock = threading.Lock(); last = {'r': None}; run = [True]
def emit(d):
    d['mt'] = round(time.monotonic(), 4)
    with lock:
        out.write(json.dumps(d) + '\n'); out.flush()
def sampler():
    seen = None
    while run[0]:
        try:
            r = json.loads(open(TELEM).read())
            if r.get('t') != seen:
                seen = r.get('t'); last['r'] = r; emit({'k': 'telem', 'r': r})
        except Exception:
            pass                                 # a torn read of a file being rewritten
        time.sleep(0.05)
threading.Thread(target=sampler, daemon=True).start()
def val(f):
    r = last['r'] or {}
    return r.get(f)
for st in steps:
    op, a = st[0], st[1:]
    if op == 'wait':
        time.sleep(float(a[0]))
    elif op == 'key':
        codes = a[1]
        with open(AGENT, 'w') as f:
            f.write('keys ' + ' '.join(str(c) for c in codes) + '\n')
        emit({'k': 'key', 'keys': a[0], 'codes': codes})
    elif op == 'mark':
        emit({'k': 'mark', 'text': ' '.join(a)})
    elif op == 'shot':
        with open(CMD, 'w') as f:
            f.write('screenshot ' + a[0] + '.png\n')
        emit({'k': 'shot', 'name': a[0]})
    elif op == 'until':                          # until FIELD CHANGES|>=|== VALUE TIMEOUT
        f, rel, v, tmo = a[0], a[1], a[2], float(a[3])
        t0, v0 = time.monotonic(), val(f)
        while time.monotonic() - t0 < tmo:
            x = val(f)
            if x is not None and ((rel == 'changes' and x != v0) or (rel == '>=' and x >= int(v)) or
                                  (rel == '==' and x == int(v))):
                break
            time.sleep(0.05)
        else:
            emit({'k': 'timeout', 'text': ' '.join(a)})
run[0] = False
time.sleep(0.1)
emit({'k': 'end'})
"""


def _seq_steps(text):
    """'wait 20; key next-chapter pause; mark x; shot n; until seeks changes 0 10' -> steps"""
    names = key_names()
    steps = []
    for part in [p.strip() for p in re.split(r'[;\n]', text) if p.strip()]:
        w = part.split()
        if w[0] == 'key':
            codes = []
            for n in w[1:]:
                n = n.lower()
                if n.isdigit():
                    codes.append(int(n))
                elif n in names:
                    codes.append(names[n])
                else:
                    sys.exit(f'mister: unknown key {n!r}. Known: {", ".join(sorted(names))}')
            steps.append(['key', w[1:], codes])
        elif w[0] in ('wait', 'mark', 'shot', 'until'):
            steps.append(w)
        else:
            sys.exit(f'mister: seq step {part!r}: wait S | key NAME.. | mark TEXT | shot NAME | until FIELD REL V TMO')
    return steps


def seq_run(text, detach=False, timeout=None):
    """Run a sequence on the target; returns its log's rows (none when detached)."""
    steps = _seq_steps(text)
    total = sum(float(s[1]) for s in steps if s[0] == 'wait') + \
        sum(float(s[4]) for s in steps if s[0] == 'until')
    prog = SEQ_PY.replace('@TELEM@', TELEM_JSON).replace('@AGENT@', AGENT_FIFO).replace('@LOG@', SEQ_LOG)
    arg = shlex.quote(json.dumps(steps))
    body = f"""
[ -p {AGENT_FIFO} ] || {{ echo NOAGENT; exit 0; }}
cat > /tmp/umd_seq.py <<'PYEOF'
{prog}
PYEOF
"""
    if detach:
        body += f'nohup python3 /tmp/umd_seq.py {arg} > /dev/null 2>&1 &\necho started\n'
    else:
        body += f'python3 /tmp/umd_seq.py {arg}\ncat {SEQ_LOG}\n'
    _, out = ssh(body, timeout=timeout or total + 120)
    if 'NOAGENT' in out:
        sys.exit('mister: key daemon is not running -- `mister.py deploy --agent`')
    return [] if detach else _seq_rows(out)


def _seq_rows(text):
    rows = []
    for line in text.splitlines():
        if line.startswith('{'):
            try:
                rows.append(json.loads(line))
            except ValueError:
                pass
    return rows


def seq_fetch():
    """the log of a detached sequence (so far)"""
    _, out = ssh(f'cat {SEQ_LOG} 2>/dev/null\n', check=False, timeout=300)
    return _seq_rows(out)


def cmd_seq(args):
    if args.fetch:
        rows = seq_fetch()
    else:
        rows = seq_run(args.steps or '', detach=args.detach)
        if args.detach:
            print(f'seq: started on the target; its log is {SEQ_LOG} (mister.py seq --fetch)')
            return 0
    if args.out:
        with open(args.out, 'w') as f:
            for r in rows:
                f.write(json.dumps(r) + '\n')
    ev = [r for r in rows if r['k'] != 'telem']
    print(f'seq: {len(rows) - len(ev)} telemetry samples, {len(ev)} events'
          + (f' -> {args.out}' if args.out else ''))
    for r in ev:
        print(f'  {r["mt"]:12.3f} {r["k"]:7s} {" ".join(r.get("keys", [])) or r.get("text", "") or r.get("name", "")}')
    return 0


def cmd_options(args):
    print('OSD options (from umd/emu.sv CONF_STR):')
    for label, s, e, vals in options():
        print(f'  {label:<20} bits[{e}:{s}]  {", ".join(vals)}')
    print('\nKeys (from umd/kbd_map.sv, plus osd):')
    print('  ' + ', '.join(sorted(key_names())))


def cmd_shell(args):
    # argparse.REMAINDER keeps the `--` separator; strip it or bash reports "command
    # not found" on stderr and silently eats the first command.
    rest = args.rest
    if rest and rest[0] == '--':
        rest = rest[1:]
    rc, out = ssh(' '.join(rest) + '\n', check=False)
    print(out.rstrip())
    return rc


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)

    p = sub.add_parser('deploy', help='copy a build (and/or the key daemon) to the rig')
    p.add_argument('--rbf', help='default: newest releases/*.rbf')
    p.add_argument('--agent', action='store_true',
                   help='(re)start the key daemon; alone = that and nothing else, '
                        'but an explicit --rbf is still flashed')
    p.add_argument('--main', metavar='PATH', help='install the HIL Main (main/build_main.sh) and arm it')
    p.set_defaults(fn=cmd_deploy)

    p = sub.add_parser('telem', help='the core counters via the HIL Main; --watch N: rates over N s')
    p.add_argument('--watch', type=float, default=0)
    p.add_argument('--csv')
    p.set_defaults(fn=cmd_telem)

    p = sub.add_parser('osd', help='set an OSD option live (the HIL Main)')
    p.add_argument('setting', help='"Name=Value"')
    p.set_defaults(fn=cmd_osd)

    sub.add_parser('restore', help='remove harness files and restore saved settings') \
       .set_defaults(fn=cmd_restore)

    p = sub.add_parser('launch', help='set options, mount an image, load the core')
    p.add_argument('image', help='absolute path ON THE MISTER')
    p.add_argument('--opt', action='append', metavar='"Name=Value"')
    p.add_argument('--delay', type=int, default=2)
    p.add_argument('--timeout', type=int, default=60)
    p.add_argument('--no-wait', action='store_true')
    p.set_defaults(fn=cmd_launch)

    p = sub.add_parser('wait')
    p.add_argument('--timeout', type=int, default=60)
    p.add_argument('--delay', type=int, default=2)
    p.set_defaults(fn=cmd_wait)

    p = sub.add_parser('key', help='press one or more keys')
    p.add_argument('names', nargs='+')
    p.set_defaults(fn=cmd_key)

    p = sub.add_parser('shot', help='screenshot and pull it back')
    p.add_argument('-o', '--out')
    p.add_argument('--scaled', action='store_true',
                   help="the scaler's output (shows the aspect), not the raw raster")
    p.set_defaults(fn=cmd_shot)

    for name, fn in (('state', cmd_state), ('options', cmd_options)):
        sub.add_parser(name).set_defaults(fn=fn)

    p = sub.add_parser('seq', help='a timed sequence of presses / marks / shots run ON the target, '
                                   'with the telemetry sampled in the same timebase')
    p.add_argument('steps', nargs='?', help='"wait S; key NAME..; mark TEXT; shot NAME; until FIELD REL V TMO"')
    p.add_argument('--out', help='write the log (JSON lines) here')
    p.add_argument('--detach', action='store_true', help='start it and return (long runs)')
    p.add_argument('--fetch', action='store_true', help='pull a detached run\'s log')
    p.set_defaults(fn=cmd_seq)

    p = sub.add_parser('shell')
    p.add_argument('rest', nargs=argparse.REMAINDER)
    p.set_defaults(fn=cmd_shell)

    args = ap.parse_args()
    return args.fn(args) or 0


if __name__ == '__main__':
    sys.exit(main())
