#!/usr/bin/env python3
"""run_cosim.sh --sample's two tools: tools/cosim_features.py (a window's stream features,
from the front end's records) and tools/cosim_sample.py (the discs chosen from the census).

The expected features are written from the spec's tables (7-11, 7-13, 7-14, 7-17, 7-18)
and from hand-built record streams, not from the extractor; the expected choices from the
selection rules in cosim_sample.py's docstring, on censuses built so each rule decides.
"""
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, 'tools'))
import cosim_features as CF  # noqa: E402
import cosim_sample as CS  # noqa: E402

fails = 0


def check(name, ok, detail=''):
    global fails
    print(f"  {'PASS' if ok else 'FAIL'} {name}" + ('' if ok else f': {detail}'))
    if not ok:
        fails += 1


# ---- [features] ----------------------------------------------------------------------------
SPS = ['N 7 1', 'S pic_order_cnt_type 0', 'S pic_width_in_mbs_minus1 29', 'S frame_mbs_only_flag 0',
       'S direct_8x8_inference_flag 1', 'S frame_cropping_flag 0']
PPS = ['N 8 1', 'S pic_parameter_set_id 0', 'S pic_init_qp_minus26 -8', 'S weighted_pred_flag 0',
       'S weighted_bipred_idc 2', 'S num_ref_idx_l0_default_active_minus1 0',
       'S num_ref_idx_l1_default_active_minus1 0', 'S constrained_intra_pred_flag 0',
       'S chroma_qp_index_offset 0']


def slice_(nal, ref, st, extra=(), mbs=()):
    """a slice NAL's records: the header, then macroblocks (each a list of E records)"""
    r = ['N %d %d' % (nal, ref), 'S first_mb_in_slice 0', 'S slice_type %d' % st, 'S pic_parameter_set_id 0']
    r += ['S %s' % e for e in extra]
    for m in mbs:
        r += ['M 0'] + ['E %s' % e for e in m]
    return r


rec = (SPS + PPS
       # an IDR after the parameter sets: 0 = I_NxN, 25 = I_PCM, 3 = I_16x16 pred mode 2
       + slice_(5, 1, 7, ['field_pic_flag 0', 'slice_qp_delta 1'],
                [['mb_type 0', 'mb_qp_delta 5'], ['mb_type 25'], ['mb_type 3']])
       # a P field: 5 = I_NxN in a P slice, 3 = P_8x8 with a 4x4 sub-partition, a skip;
       # the picture timing SEI's pic_struct rides the slice's records; an MMCO 1
       + slice_(1, 1, 5, ['field_pic_flag 1', 'bottom_field_flag 1', 'num_ref_idx_active_override_flag 1',
                          'num_ref_idx_l0_active_minus1 2', 'modification_of_pic_nums_idc_l0 0',
                          'modification_of_pic_nums_idc_l0 3', 'adaptive_ref_pic_marking_mode_flag 1',
                          'memory_management_control_operation 1', 'memory_management_control_operation 0',
                          'pic_struct 3'],
                [['mb_type 5'], ['mb_type 3', 'sub_mb_type 3'], ['mb_skip_flag 1']])
       # a reference B frame, temporal direct: 22 = B_8x8 with a direct sub-partition, 23 =
       # I_NxN in a B slice, 24 = I_16x16 (pred mode 0)
       + slice_(1, 2, 6, ['field_pic_flag 0', 'direct_spatial_mv_pred_flag 0'],
                [['mb_type 22', 'sub_mb_type 0'], ['mb_type 23'], ['mb_type 24']])
       # a later IDR with no parameter sets before it (Astro Boy's structure)
       + slice_(5, 1, 7, ['field_pic_flag 0'], [['mb_type 0']]))
f = CF.features(rec)
print('[features]')
for want in ('idr', 'idr_without_ps', 'slice:I', 'slice:P', 'slice:B', 'mb:I:I4x4', 'mb:I:PCM',
             'mb:I:I16x16', 'i16_mode:2', 'i16_mode:0', 'mb:P:intra_I4x4', 'mb:P:8x8', 'sub:P:4x4', 'skip:P',
             'mb:B:8x8', 'sub:B:direct8x8', 'mb:B:intra_I4x4', 'mb:B:intra_I16x16', 'direct:temporal',
             'B_ref', 'wp:implicit_B', 'pic:frame', 'pic:bottom', 'paff', 'pic_struct:3', 'mmco:1',
             'listmod:l0:0', 'refs_l0:3-4', 'refs_l1:1', 'poc_type:0', 'width_mbs:30', 'deblock_idc:0'):
    check('has ' + want, f[want] > 0, 'missing (got %s)' % sorted(f))
for absent in ('mmco:0', 'listmod:l0:3', 'direct:spatial', 'mb:P:16x16', 'wp:explicit_P', 'multi_slice', 'crop'):
    check('lacks ' + absent, f[absent] == 0, 'present (%d)' % f[absent])
check('one IDR without parameter sets (the first had them)', f['idr_without_ps'] == 1, f['idr_without_ps'])
check('two IDRs', f['idr'] == 2, f['idr'])
# QP: 26 - 8 (PPS) + 1 (slice) + 5 (the first mb_qp_delta) = 24 -> qp / 6 = 4; without the
# PPS and the slice it would be 31 (bucket 5): the values are chosen so the two differ
check('the QP runs from the PPS and the slice (qp6:4)', f['qp6:4'] == 1 and f['qp6:5'] == 0,
      sorted(k for k in f if k.startswith('qp6')))

# ---- [sample] ------------------------------------------------------------------------------
print('[sample]')


def census(rows):
    fd, path = tempfile.mkstemp(suffix='.tsv')
    with os.fdopen(fd, 'w') as fh:
        fh.write('# census test\n')
        for label, verdict, xrt, feats in rows:
            fh.write('%s\t%s\t%s\t\t%s\n' % (label, verdict, '' if xrt is None else xrt, ' '.join(feats)))
    return path


# A covers the most; then d is left, held by C (3.0x) and D (2.5x): the tie goes to the
# slower window, D. B (a) adds nothing. E is SKIP and F REFUSED: never chosen, even slow.
rows = [('A', 'PASS', 2.0, 'a b c'.split()), ('B', 'PASS', 1.9, ['a']), ('C', 'PASS', 3.0, ['d']),
        ('D', 'PASS', 2.5, ['c', 'd']), ('E', 'SKIP', None, ['z']), ('F', 'REFUSED', 0.5, ['y'])]
got, universe, covered = CS.choose(CS.load(census(rows)), tail=0)
check('the cover: most new features first, the tie to the slower window', [l for l, _ in got] == ['A', 'D'], got)
check('every PASS feature covered, SKIP / REFUSED features not in the universe',
      universe == set('abcd') and covered >= universe, (universe, covered))

got, _, _ = CS.choose(CS.load(census(rows)), tail=2)
check('the tail: the two slowest PASS windows first', [l for l, _ in got][:2] == ['B', 'A'], got)
check('the tail then the cover: D for d, nothing for C', [l for l, _ in got] == ['B', 'A', 'D'], got)

rows2 = rows + [('G', 'FAIL', 1.0, ['a'])]
got, _, _ = CS.choose(CS.load(census(rows2)), tail=1)
check('a FAIL disc is always kept, first', got[0][0] == 'G' and got[0][1] == 'FAIL', got)
check('the FAIL disc does not take a tail place', [l for l, w in got if w.startswith('tail')] == ['B'], got)

p = census(rows)
pres = tempfile.mkstemp(suffix='.txt')[1]
open(pres, 'w').write('B\nC\nD\n')
import io  # noqa: E402
import contextlib  # noqa: E402
out = io.StringIO()
with contextlib.redirect_stdout(out):
    rc = CS.main([p, '--tail', '0', '--present', pres])
lines = [l for l in out.getvalue().splitlines() if not l.startswith('#')]
check('--present drops a disc no longer in the library (A gone: D, then B)',
      [l.split('\t')[0] for l in lines] == ['D', 'B'] and rc == 0, out.getvalue())

print('ALL GREEN' if fails == 0 else 'FAILURES: %d' % fails)
sys.exit(1 if fails else 0)
