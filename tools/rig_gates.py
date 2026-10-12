#!/usr/bin/env python3
"""rig_gates.py -- P6b's rig gates (docs/transport.md S6) on the maintainer's MiSTer.

Each gate launches a disc, runs a timed sequence ON the target (mister.py seq: the presses
and the 4 Hz telemetry in one timebase) and scores the log against tools/umd_nav_ref.py
(the navigation model, written from the format and the PSP, never from the RTL). The
telemetry words it reads are P6b7's (tools/telem_layout.py): land_lo / land_hi (the first
picture a landing shows), seek_lat, landing (the watchdogs, the recovery-point start),
xport, chapter, seeks, trick, av_err, the error words.

    rig_gates.py chapters DISC [--seed N]     Next / Prev bursts from random points
    rig_gates.py trick DISC                   FF / REW 1-3 each way, Display on, the exits
    rig_gates.py pause DISC                   3 x 10 s
    rig_gates.py track DISC                   every declared audio track in turn
    rig_gates.py inout DISC                   IN / OUT: the title plays only [IN, OUT)
    rig_gates.py film DISC --start | --score  a whole title, detached (the Phase 6 gate)
    rig_gates.py score GATE DISC LOG          re-score a saved log (.sim/rig/*.jsonl)

DISC is the image's file name: on the rig under $MISTER_UMD_DIR (default
/media/fat/cifs/games/DVD/umd), locally under ${UMD_ISO_DIR:-~/umd-isos} (the model reads
it). Logs go to .sim/rig/. The rig is the maintainer's: mister.py state first, restore
after (the hil-testing skill). Needs the HIL Main armed (mister.py deploy --main) and the
key daemon (deploy --agent).

What a gate CANNOT see, said once: the telemetry is sampled at 4 Hz, so the key a press was
judged from is known to within ~0.35 s (the sample before the press, plus the key daemon's
latency). A press whose model answer changes inside that window is AMBIGUOUS: reported,
not scored.
"""
import argparse
import json
import os
import random
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import mister                    # noqa: E402
import umd_nav_ref as NAV        # noqa: E402

RIG_DIR = os.environ.get('MISTER_UMD_DIR', '/media/fat/cifs/games/DVD/umd')
ISO_DIR = os.path.expanduser(os.environ.get('UMD_ISO_DIR', '~/umd-isos'))
LOGDIR = os.path.join(ROOT, '.sim', 'rig')
FRAME = 3003                     # a 29.97 frame, 90 kHz ticks: "av_err within one frame"
PIC_MAX = 4505                   # the longest picture on screen (3 fields of 3:2), ticks
KEY_WIN = 0.35 * 90000           # a press's key is known to within this (see above)


# ---- the log -------------------------------------------------------------------------------

def pts(r, lo, hi):
    return r[hi] * 65536 + r[lo]


class Log(object):
    def __init__(self, rows):
        self.rows = rows
        self.t = [x for x in rows if x['k'] == 'telem']
        self.ev = [x for x in rows if x['k'] != 'telem']
        # unwrap the 16-bit counters used here
        acc = {}
        for x in self.t:
            r = x['r']
            for f in ('seeks', 'pickups', 'aud_played', 'refreshes'):
                if f in r:
                    p = acc.get(f)
                    base = 0 if p is None else p[0] + ((r[f] - p[1]) & 0xFFFF)
                    acc[f] = (base, r[f])
                    r['_' + f] = base
            r['_land'] = pts(r, 'land_lo', 'land_hi')
            r['_sh'] = pts(r, 'sh_pts_lo', 'sh_pts_hi')
            r['_tag'] = r['xport'] >> 10 & 3
            r['_state'] = r['xport'] >> 13
            r['_seeking'] = r['xport'] >> 12 & 1
            r['_wd'] = r['landing'] >> 8
            r['_rerr'] = r['recon_err'] >> 4
            r['_ferr'] = r['fe_err'] >> 4
            r['_speed'] = r['trick'] >> 14
            r['_rev'] = r['trick'] >> 13 & 1
            r['_disp'] = r['trick'] >> 11 & 1
            r['_ended'] = r['sched'] >> 7 & 1
            r['_avok'] = r['aud_state'] >> 13 & 1

    def before(self, mt):
        """the last sample at or before mt"""
        out = None
        for x in self.t:
            if x['mt'] > mt:
                break
            out = x
        return out

    def after(self, mt):
        return [x for x in self.t if x['mt'] > mt]

    def keys(self):
        return [e for e in self.ev if e['k'] == 'key']


def fetch_title(disc):
    path = os.path.join(ISO_DIR, disc)
    if not os.path.exists(path):              # (a multi-disc set may sit in a folder of its own)
        for d, _sub, files in os.walk(ISO_DIR):
            if disc in files:
                path = os.path.join(d, disc)
                break
    if not os.path.exists(path):
        sys.exit('rig_gates: no %s (set UMD_ISO_DIR): the model needs the image' % path)
    return NAV.from_iso(path)


def launch(disc, opts=()):
    cmd = [os.path.join(HERE, 'mister.py'), 'launch', os.path.join(RIG_DIR, disc)]
    for o in opts:
        cmd += ['--opt', o]
    subprocess.run(cmd, check=True)


def save(gate, disc, rows):
    os.makedirs(LOGDIR, exist_ok=True)
    stem = os.path.join(LOGDIR, '%s_%s_%s' % (gate, disc.split(' ')[0].split('.')[0].lower(),
                                               time.strftime('%H%M%S')))
    with open(stem + '.jsonl', 'w') as f:
        for r in rows:
            f.write(json.dumps(r) + '\n')
    return stem + '.jsonl'


def load(path):
    return [json.loads(line) for line in open(path) if line.startswith('{')]


class Score(object):
    def __init__(self, gate):
        self.gate, self.bad, self.notes = gate, [], []

    def fail(self, msg):
        self.bad.append(msg)
        print('  FAIL ' + msg)

    def ok(self, msg):
        print('  ok   ' + msg)

    def note(self, msg):
        self.notes.append(msg)
        print('  ..   ' + msg)

    def done(self):
        print('%s: %s' % (self.gate, 'PASS' if not self.bad else 'FAIL (%d)' % len(self.bad)))
        return 0 if not self.bad else 1


def health(sc, lg):
    """errors, watchdogs, hangs over the whole log"""
    a, b = lg.t[0]['r'], lg.t[-1]['r']
    for f, what in (('_rerr', 'reconstruction errors'), ('_ferr', 'front-end errors'), ('_wd', 'watchdogs')):
        if b[f] != a[f]:
            sc.fail('%s %d -> %d' % (what, a[f], b[f]))
        else:
            sc.ok('%s %d throughout' % (what, b[f]))
    if 'd1_busy' in b and (b['d1_busy'] == 0xFFFF or b['d2_busy'] == 0xFFFF):
        sc.fail('a DDR3 port BUSY for good (the hang signature)')
    gaps = [y['mt'] - x['mt'] for x, y in zip(lg.t, lg.t[1:])]
    if gaps and max(gaps) > 2.0:
        sc.note('telemetry gap of %.1f s (Main busy?)' % max(gaps))


def landing(lg, mt, seeks0):
    """the landing after mt: the first sample with more seeks than seeks0 and seeking done
    (land_pts is latched at the landing's pickup, before seeking falls)"""
    for x in lg.after(mt):
        r = x['r']
        if r['_seeks'] > seeks0 and not r['_seeking']:
            return x
    return None


def av_after(lg, mt, secs=3.0):
    """av_err (ticks) in the first sample secs after mt with the audio measured"""
    for x in lg.after(mt + secs):
        if x['r']['_avok']:
            return x['r']['av_err']
    return None


# ---- the item the display is in (the tag is the item mod 4) ------------------------------------

class ItemTrack(object):
    def __init__(self, title):
        self.title, self.item, self.tag, self.until = title, 0, 0, 0

    def sample(self, r, mt=None):
        # (a landing's samples before it -- the press not yet seen, the old tag -- are not a crossing)
        if r['_seeking'] or (mt is not None and mt < self.until):
            return
        if r['_tag'] != self.tag:
            self.item += (r['_tag'] - self.tag) % 4
            self.tag = r['_tag']

    def land(self, item, until=0):
        self.item, self.tag, self.until = item, item % 4, until


# ---- chapters ------------------------------------------------------------------------------

def seq_chapters(title, seed):
    rnd = random.Random(seed)
    steps = ['wait 20', 'mark settled']
    kinds = ['n'] * 5 + ['p'] * 3 + ['pp'] * 2
    rnd.shuffle(kinds)
    for k in kinds:
        if k == 'pp':          # a Prev burst inside the merge window: back one chapter
            steps += ['key prev-chapter', 'wait 0.25', 'key prev-chapter']
        else:
            steps.append('key %s' % ('next-chapter' if k == 'n' else 'prev-chapter'))
        steps.append('wait %.1f' % rnd.uniform(6, 14))
    return '; '.join(steps)


def bursts(lg):
    """presses grouped as player_ctl merges them (a press within the merge window of the last)"""
    out = []
    for e in lg.keys():
        c = {'next-chapter': 'n', 'prev-chapter': 'p'}.get(e['keys'][0])
        if c is None:
            continue
        if out and e['mt'] - out[-1]['last'] < 0.45:
            out[-1]['seq'] += c
            out[-1]['last'] = e['mt']
        else:
            out.append({'mt': e['mt'], 'last': e['mt'], 'seq': c})
    return out


def score_chapters(title, lg, disc):
    sc = Score('chapters ' + disc)
    health(sc, lg)
    it = ItemTrack(title)
    lat = []
    bl = bursts(lg)
    k = 0
    for x in lg.t:
        # walk the samples to each burst, tracking the item
        while k < len(bl) and x['mt'] > bl[k]['mt']:
            b = bl[k]
            k += 1
            pre = lg.before(b['mt'])['r']
            key = (it.item, pre['_sh'])
            want, noch = title.presses(key, b['seq'])
            alt, _ = title.presses((key[0], key[1] + KEY_WIN), b['seq'])
            lx = landing(lg, b['last'], pre['_seeks'])
            tag = '%s from %s %s' % (b['seq'], key[0], NAV.hms(title.elapsed(key)))
            if want != alt:
                sc.note('%s: AMBIGUOUS (the model answers %s or %s inside the key window)' % (tag, want, alt))
                if lx:
                    it.land(title.seek(want)[0] if want else it.item, lx['mt'])
                continue
            if want is None:
                if lx is not None and lx['mt'] - b['last'] < 3:
                    sc.fail('%s: no chapter to go to, yet a seek landed' % tag)
                else:
                    sc.ok('%s: no chapter there (the message), no seek' % tag)
                continue
            if lx is None:
                sc.fail('%s: no landing' % tag)
                continue
            r = lx['r']
            item, _k, _e, _s, tgt = title.seek(want)
            d = tgt - r['_land']
            rank = title.chapter_at((item, tgt))[0]
            it.land(item, lx['mt'])
            # the recovery-point start of the landing (settled: the sample after it)
            rp = (lg.after(lx['mt'])[:1] or [lx])[0]['r']['landing']
            msg = '%s -> chapter %d at %s: land %d, target %d (%+d), tag %d, chapter word %d, %.0f ms; %s start, %d leading skipped' % (
                tag, rank, NAV.hms(title.elapsed((item, tgt))), r['_land'], tgt, -d, r['_tag'],
                r['chapter'], r['seek_lat'] * 16 / 90.0, 'non-IDR' if rp >> 1 & 1 else 'IDR', rp >> 5 & 7)
            if not (-1 <= d <= PIC_MAX) or r['_tag'] != item % 4 or r['chapter'] != rank:
                sc.fail(msg)
            else:
                sc.ok(msg)
                lat.append(r['seek_lat'] * 16 / 90.0)
            left = (title.total - title.elapsed((item, tgt))) / 90000.0
            if left < 4.0:
                sc.note('  %.2f s before the title\'s end: the title ends, no lip sync to measure' % left)
                continue
            av = av_after(lg, lx['mt'])
            if av is None or abs(av) > FRAME:
                sc.fail('  av_err 3 s after the landing: %s' % av)
        it.sample(x['r'], x['mt'])
    if lat:
        sc.note('press-to-picture (from the query): %.0f .. %.0f ms, mean %.0f' % (min(lat), max(lat), sum(lat) / len(lat)))
    return sc.done()


# ---- trick play ------------------------------------------------------------------------------

def seq_trick():
    steps = ['wait 15', 'key display', 'wait 2']
    for n in (1, 2, 3):
        steps += ['mark ff%d' % n] + ['key right', 'wait 0.3'] * n + ['wait 10', 'mark play', 'key left', 'wait 6']
    for n in (1, 2, 3):
        steps += ['mark rew%d' % n] + ['key left', 'wait 0.3'] * n + ['wait 10', 'mark play', 'key right', 'wait 6']
    # the title's start: REW 3 until play resumes by itself
    steps += ['mark start', 'key left', 'wait 0.3', 'key left', 'wait 0.3', 'key left', 'wait 60', 'shot trick_end',
              'key display']
    return '; '.join(steps)


def score_trick(title, lg, disc):
    sc = Score('trick ' + disc)
    health(sc, lg)
    marks = [e for e in lg.ev if e['k'] == 'mark']
    rates = {1: 20, 2: 33, 3: 55}
    entries = set(p for itm in title.items for p in itm.pts)
    for i, m in enumerate(marks):
        if not (m['text'].startswith('ff') or m['text'].startswith('rew')):
            continue
        n = int(m['text'][-1])
        fwd = m['text'].startswith('ff')
        end = marks[i + 1]['mt'] if i + 1 < len(marks) else lg.t[-1]['mt']
        run = [x for x in lg.t if m['mt'] + 1.5 < x['mt'] < end - 0.2 and x['r']['_speed'] == n]
        if len(run) < 8:
            sc.fail('%s: only %d samples at speed %d' % (m['text'], len(run), n))
            continue
        if any(x['r']['_rev'] != (not fwd) for x in run):
            sc.fail('%s: the direction bit wrong' % m['text'])
        ts = [x['mt'] for x in run]
        ys = [x['r']['_sh'] / 90000.0 for x in run]
        rate = mister._rate(ts, ys)
        want = rates[n] * (1 if fwd else -1)
        msg = '%s: %.1fx of content (the PSP %dx), display %s' % (
            m['text'], rate, want, 'on' if all(x['r']['_disp'] for x in run) else 'OFF')
        (sc.ok if abs(rate - want) <= 0.2 * abs(want) else sc.fail)(msg)
        # the exit: play lands on the last hop's I, exactly
        pm = marks[i + 1] if i + 1 < len(marks) else None
        if pm and pm['text'] == 'play':
            pre = lg.before(pm['mt'])['r']
            lx = landing(lg, pm['mt'], pre['_seeks'])
            held = [x['r']['_sh'] for x in lg.t if pm['mt'] < x['mt'] and lx and x['mt'] < lx['mt']]
            if lx is None:
                sc.fail('  the exit: no landing')
            else:
                r = lx['r']
                last = held[-1] if held else pre['_sh']
                # the exit waits for the hop in flight, whose picture may come and go between two
                # 4 Hz samples: the landing is the last sampled hop's I or ONE hop further on (a
                # hop is at most rate x ~0.6 s of content); the bench proves it exact
                # (run_player_ctl.sh [model], every exit's seek to the shown key)
                step = (r['_land'] - last) * (1 if fwd else -1)
                span = rates[n] * 90000 * 0.6
                msg = '  the exit: land %d, the last sampled hop %d (%+.2f s of content), an entry: %s; then speed %d, state %d, %.0f ms' % (
                    r['_land'], last, (r['_land'] - last) / 90000.0, r['_land'] in entries, r['_speed'], r['_state'],
                    r['seek_lat'] * 16 / 90.0)
                (sc.ok if 0 <= step <= span and r['_land'] in entries and r['_speed'] == 0 else sc.fail)(msg)
                av = av_after(lg, lx['mt'])
                if av is None or abs(av) > FRAME:
                    sc.fail('  av_err 3 s after the exit: %s' % av)
    st = [e for e in marks if e['text'] == 'start']
    if st:
        tail = lg.t[-12:]
        ok = all(x['r']['_speed'] == 0 and x['r']['_state'] == 1 for x in tail) and \
            mister._rate([x['mt'] for x in tail], [x['r']['_sh'] / 90000.0 for x in tail]) > 0.8
        (sc.ok if ok else sc.fail)('REW 3 into the title\'s start: play resumed by itself (sh %d, IN %d)' % (
            tail[-1]['r']['_sh'], title.items[0].in_pts))
    return sc.done()


# ---- pause -----------------------------------------------------------------------------------

def seq_pause():
    steps = ['wait 20']
    for i in range(3):
        steps += ['mark run%d' % i, 'wait 6', 'mark pause%d' % i, 'key select', 'wait 10', 'mark resume%d' % i,
                  'key play/pause', 'wait 8']
    return '; '.join(steps)


def score_pause(title, lg, disc):
    sc = Score('pause ' + disc)
    health(sc, lg)
    marks = {e['text']: e['mt'] for e in lg.ev if e['k'] == 'mark'}
    for i in range(3):
        p, q = marks['pause%d' % i], marks['resume%d' % i]
        held = [x['r'] for x in lg.t if p + 1.0 < x['mt'] < q]
        a0 = lg.before(p)['r']
        a1 = [x['r'] for x in lg.after(q + 4)][:1]
        if len(held) < 20 or not a1:
            sc.fail('pause %d: too few samples' % i)
            continue
        a1 = a1[0]
        frozen = len(set(r['stc'] for r in held)) == 1 and len(set(r['_pickups'] for r in held)) == 1 and \
            len(set(r['_sh'] for r in held)) == 1 and all(r['_state'] == 2 for r in held)
        rearm = (a0['aud_rearm'], a0['sched'] >> 8) == (a1['aud_rearm'], a1['sched'] >> 8)
        msg = 'pause %d: STC / picture / pickups held %s, av_err %d -> %d ticks, re-arms and re-anchors unchanged %s' % (
            i, frozen, a0['av_err'], a1['av_err'], rearm)
        (sc.ok if frozen and rearm and abs(a1['av_err'] - a0['av_err']) <= 90 else sc.fail)(msg)
    return sc.done()


# ---- the audio track ------------------------------------------------------------------------------

def seq_track(n):
    steps = ['wait 20']
    for i in range(n):
        steps += ['mark t%d' % i, 'key audio', 'wait 2', 'shot track_%d' % i, 'wait 12']
    return '; '.join(steps)


def score_track(title, lg, disc):
    sc = Score('track ' + disc)
    health(sc, lg)
    ms = [e for e in lg.ev if e['k'] == 'mark' and e['text'].startswith('t')]
    for i, m in enumerate(ms):
        end = ms[i + 1]['mt'] if i + 1 < len(ms) else lg.t[-1]['mt']
        after = [x for x in lg.t if m['mt'] < x['mt'] < end]
        base = lg.before(m['mt'])['r']['_aud_played']
        # the silence: from the press to the first sample whose played count resumed at rate
        resumed = None
        for a, b in zip(after, after[1:]):
            if b['r']['_aud_played'] > a['r']['_aud_played'] and a['mt'] - m['mt'] > 0.2 and \
                    a['r']['_aud_played'] > base:
                resumed = a['mt'] - m['mt']
                break
        late = [x for x in after if x['mt'] > (m['mt'] + (resumed or 0) + 3)]
        rate = mister._rate([x['mt'] for x in late], [x['r']['_aud_played'] for x in late]) if len(late) > 8 else 0
        av = [x['r']['av_err'] for x in late if x['r']['_avok']]
        msg = 'track press %d: silence %.2f s, then %.2f frames/s played (23.44), av_err %s .. %s ticks' % (
            i + 1, resumed or -1, rate, min(av) if av else '-', max(av) if av else '-')
        ok = resumed is not None and abs(rate - 23.4375) < 0.5 and av and max(abs(v) for v in av) <= FRAME
        (sc.ok if ok else sc.fail)(msg)
    sc.note('audible: the screenshots show the track tag; listening is the maintainer\'s')
    return sc.done()


# ---- IN / OUT ------------------------------------------------------------------------------------

def seq_inout(title, lead):
    """play item 0 from its start; then, for a title whose last OUT lies before its clip's
    end, FF 3 to `lead` s before the title's end and play through the end"""
    tot = title.total / 90000.0
    steps = ['wait 25', 'mark start']
    if tot > 300:
        hop = max(0.0, (tot - lead - 30) / 55.0)
        steps += ['key right', 'wait 0.3', 'key right', 'wait 0.3', 'key right', 'wait %.1f' % hop,
                  'key left', 'mark played', 'wait %d' % (lead + 40), 'shot inout_end']
    return '; '.join(steps)


def score_inout(title, lg, disc):
    sc = Score('inout ' + disc)
    health(sc, lg)
    it = ItemTrack(title)
    shown = {}
    for x in lg.t:
        r = x['r']
        it.sample(r, x['mt'])
        if r['_seeking'] or r['_speed'] or not r['_sh']:
            continue
        shown.setdefault(it.item, []).append(r['_sh'])
    for k, ps in sorted(shown.items()):
        itm = title.items[k]
        lo, hi = min(ps), max(ps)
        ok = lo >= itm.in_pts - 1 and hi < itm.out_pts
        (sc.ok if ok else sc.fail)('item %d: shown %d .. %d inside [IN %d, OUT %d)' % (k, lo, hi, itm.in_pts, itm.out_pts))
    last = lg.t[-1]['r']
    if any(e['k'] == 'mark' and e['text'] == 'played' for e in lg.ev):
        lastitm = title.items[-1]
        out_gap = (lastitm.out_pts - last['_sh']) / 90000.0
        msg = 'the title\'s end: ended %d, the last picture %.2f s before OUT (clip past OUT: %s)' % (
            last['_ended'], out_gap, 'yes' if lastitm.pts[-1] > lastitm.out_pts else 'no')
        (sc.ok if last['_ended'] and 0 <= out_gap < 1.0 else sc.fail)(msg)
    return sc.done()


# ---- a whole title (the Phase 6 gate) ------------------------------------------------------------

def seq_film(title):
    tot = title.total / 90000.0
    # a pause and a chapter jump in the first minutes ("with the above in it"), then the rest
    return '; '.join(['wait 60', 'key select', 'wait 10', 'key play/pause', 'wait 30', 'key next-chapter',
                      'wait %d' % int(tot + 120)])


def score_film(title, lg, disc):
    sc = Score('film ' + disc)
    health(sc, lg)
    av = [(x['mt'], x['r']['av_err']) for x in lg.t if x['r']['_avok'] and x['r']['_state'] == 1]
    worst = max(av, key=lambda a: abs(a[1])) if av else None
    t0 = lg.t[0]['mt']
    if worst is None:
        sc.fail('no av_err measured')
    else:
        msg = 'av_err over %d samples: %d .. %d ticks (%+.2f .. %+.2f ms); worst at %.0f s' % (
            len(av), min(a[1] for a in av), max(a[1] for a in av), min(a[1] for a in av) / 90.0,
            max(a[1] for a in av) / 90.0, worst[0] - t0)
        (sc.ok if abs(worst[1]) <= FRAME else sc.fail)(msg)
    a, b = lg.t[0]['r'], lg.t[-1]['r']
    sc.ok('re-arms underrun %d -> %d, resync %d -> %d; re-anchors %d -> %d; lone PTS disbelieved %d -> %d '
          '(display.md S10: Akira has 3)' % (
              a['aud_rearm'] >> 8, b['aud_rearm'] >> 8, a['aud_rearm'] & 255, b['aud_rearm'] & 255,
              a['sched'] >> 8, b['sched'] >> 8, a['sched'] & 15, b['sched'] & 15))
    (sc.ok if b['_ended'] else sc.fail)('the title ended (END taken): %d, the last picture %s' % (
        b['_ended'], NAV.hms(b['_sh'])))
    return sc.done()


# ---- main ----------------------------------------------------------------------------------------

SCORERS = {'chapters': score_chapters, 'trick': score_trick, 'pause': score_pause, 'track': score_track,
           'inout': score_inout, 'film': score_film}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('gate', choices=sorted(SCORERS) + ['score'])
    ap.add_argument('disc')
    ap.add_argument('log', nargs='*', help='score: DISC LOG')
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--tracks', type=int, default=2, help='track: presses (the declared tracks)')
    ap.add_argument('--lead', type=int, default=60, help='inout: play the last N s of the title')
    ap.add_argument('--start', action='store_true', help='film: launch and start, detached')
    ap.add_argument('--score', action='store_true', help='film: fetch the detached log and score it')
    ap.add_argument('--no-launch', action='store_true', help='the disc is already playing')
    a = ap.parse_args(argv)
    if a.gate == 'score':
        gate, (disc, path) = a.disc, a.log
        return SCORERS[gate](fetch_title(disc), Log(load(path)), disc)
    title = fetch_title(a.disc)
    if a.gate == 'film' and a.score:
        rows = mister.seq_fetch()
        print('log: ' + save('film', a.disc, rows))
        return score_film(title, Log(rows), a.disc)
    seq = {'chapters': lambda: seq_chapters(title, a.seed), 'trick': seq_trick, 'pause': seq_pause,
           'track': lambda: seq_track(a.tracks), 'inout': lambda: seq_inout(title, a.lead),
           'film': lambda: seq_film(title)}[a.gate]()
    if not a.no_launch:
        launch(a.disc)
    if a.gate == 'film':
        mister.seq_run(seq, detach=True)
        print('film: started, detached (%s); score with --score after ~%d min' % (
            mister.SEQ_LOG, int(title.total / 90000 / 60) + 5))
        return 0
    rows = mister.seq_run(seq)
    print('log: ' + save(a.gate, a.disc, rows))
    return SCORERS[a.gate](title, Log(rows), a.disc)


if __name__ == '__main__':
    sys.exit(main())
