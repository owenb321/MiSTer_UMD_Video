#!/usr/bin/env python3
"""docs_check.parse_bits() -- the CONF_STR -> status-bit decoder.

tools/mister.py builds the core's saved-settings blob from this, so a wrong bit span
silently sets the WRONG OPTION on the hardware -- a failure that looks like a core bug
and would be chased there. The expected spans below are written from umd/emu.sv's own
status-bit comment, i.e. from a source independent of the parser.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, 'tools'))
import docs_check  # noqa: E402

# label -> (start, end), documented independently of the parser (umd/emu.sv comment)
EXPECTED = {
    'Aspect Ratio': (1, 2),
    'Deinterlace': (3, 4),
    'Analog Aspect': (9, 10),     # (Diagnostics, bit 8, left with the diagnostic HUD: area_plan.md A11)
    'Disc Menus': (15, 15),
}

fails = 0


def check(name, got, want):
    global fails
    ok = got == want
    print(f"  {'PASS' if ok else 'FAIL'} {name}: {got}" + ('' if ok else f' want {want}'))
    if not ok:
        fails += 1


print('[live CONF_STR from umd/emu.sv]')
lits = docs_check.extract_conf_str(open(os.path.join(ROOT, 'umd', 'emu.sv')).read())
table = {lab: (s, e) for lab, s, e, _ in docs_check.parse_bits(lits)}
for label, want in EXPECTED.items():
    check(label, table.get(label), want)

missing = set(EXPECTED) - set(table)
extra = set(table) - set(EXPECTED)
if missing:
    print(f'  FAIL options vanished from CONF_STR: {sorted(missing)}')
    fails += 1
if extra:
    # Not a failure: a new option is expected to appear here one day. Say so
    # loudly, because it also means the manual and this table need updating.
    print(f'  NOTE new option(s) not in this table yet: {sorted(extra)}')

print('[synthetic forms not present in the live CONF_STR]')
cases = [
    ('"O12,Two char,A,B;"', 'Two char', (1, 2)),      # two base-32 chars
    ('"oB,Lower o,A,B;"', 'Lower o', (43, 43)),       # lowercase o adds 32
    ('"P3OX7,Paged X,A,B;"', 'Paged X', (7, 7)),      # page prefix + X skipped
    ('"O[12:4],Range,A,B;"', 'Range', (4, 12)),       # sscanf reads END first
    ('"O[9],Single,A,B;"', 'Single', (9, 9)),
    ('"H3O5,Hidden,A,B;"', 'Hidden', (5, 5)),         # hide prefix
    ('"h3d4O[7:6],Lower hd,A,B;"', 'Lower hd', (6, 7)),  # stacked inverse prefixes
    ('"P1HAO2,Page+hide,A,B;"', 'Page+hide', (2, 2)),  # page then hide, base-32 index
]
for lit, label, want in cases:
    got = {a: (b, c) for a, b, c, _ in docs_check.parse_bits([lit.strip('"')])}
    check(label, got.get(label), want)

print('[parse() sees an option behind a hide prefix -- else it goes undocumented]')
opts, _, _ = docs_check.parse(['h5O[4:3],Behind prefix,A,B;'])
check('parse() prefix', [o[0] for o in opts], ['Behind prefix'])

print('[rejections -- Main refuses these too]')
for lit in ('"O[3:9],Backwards,A,B;"', '"O[1:0],TooWide,A;"'):
    got = docs_check.parse_bits([lit.strip('"')])
    ok = not got or (got[0][2] - got[0][1] <= 8 and got[0][2] >= got[0][1])
    print(f"  {'PASS' if ok else 'FAIL'} rejects/normalises {lit}")
    if not ok:
        fails += 1

print('test_status_bits:', 'ALL GREEN' if not fails else f'{fails} FAILURE(S)')
sys.exit(1 if fails else 0)
