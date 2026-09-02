#!/usr/bin/env python3
"""Verify the closed pyte compatibility catalogue and its audit boundary."""
import glob
import os
import sys

import pyte

sys.path.insert(0, os.path.dirname(__file__))
import stlib  # noqa: E402


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
failed = False


def check(label, condition):
    global failed
    print(f'{label:56s}: {"OK" if condition else "FAIL"}')
    if not condition:
        failed = True


def rendered_text(screen):
    return '\n'.join(row.rstrip() for row in screen.display).strip()


catalogued = (
    b"\x1b[0;0'z",
    b"\x1b[0'{",
    b'\x1b[=0u',
    b'\x1b[>4;0m',
    b'\x1b F',
)

# Validate the premise against the installed parser instead of assuming it.
raw_screen = pyte.Screen(20, 2)
raw_stream = pyte.ByteStream(raw_screen)
try:
    raw_stream.feed(b"\x1b[0;0'z")
    intermediate_gap = False
except TypeError:
    intermediate_gap = True
check('installed pyte exposes the audited intermediate-byte gap',
      intermediate_gap)

check('catalogue entries carry an explicit reason',
      bool(stlib._PYTE_SCRUB) and
      all(pattern is not None and reason
          for pattern, reason in stlib._PYTE_SCRUB))
check('ordinary bytes remain byte-identical',
      stlib.scrub_for_pyte(b'plain\x1b[31mred\x1b[0m') ==
      b'plain\x1b[31mred\x1b[0m')

all_splits_ok = True
for sequence in catalogued:
    for split in range(len(sequence) + 1):
        screen = pyte.Screen(40, 2)
        stream = pyte.ByteStream(screen)
        first = stlib.feed_pyte(
            stream, b'BEGIN' + sequence[:split], 'catalog split')
        second = stlib.feed_pyte(
            stream, sequence[split:] + b'END', 'catalog split')
        flushed = stlib.flush_pyte(stream, 'catalog split')
        if not (first and second and flushed and
                rendered_text(screen) == 'BEGINEND'):
            all_splits_ok = False
            print(f'  sequence={sequence!r} split={split} '
                  f'text={rendered_text(screen)!r}')
check('every catalogued sequence survives every read split', all_splits_ok)

bounded = pyte.ByteStream(pyte.Screen(40, 2))
stlib.feed_pyte(bounded, b'X\x1b[' + b'1' * 64, 'bounded prefix')
check('oversized incomplete prefix is not retained',
      getattr(bounded, '_st_pyte_pending', b'') == b'')


class BrokenStream:
    def feed(self, _data):
        raise RuntimeError('deliberate uncatalogued parser failure')


before = stlib.pyte_defects()
unknown_rejected = not stlib.feed_pyte(
    BrokenStream(), b'ordinary text', 'focused audit')
after = stlib.pyte_defects()
check('an uncatalogued parser failure is rejected and recorded',
      unknown_rejected and len(after) == len(before) + 1 and
      'RuntimeError' in after[-1] and 'focused audit' in after[-1])

offenders = []
for path in sorted(glob.glob(os.path.join(ROOT, 'test', '*.py'))):
    name = os.path.basename(path)
    if name in ('stlib.py', os.path.basename(__file__)):
        continue
    with open(path, encoding='utf-8') as stream:
        if '.feed(' in stream.read():
            offenders.append(name)
check('no suite bypasses the audited pyte feed', not offenders)
for name in offenders:
    print(f'  test/{name} calls .feed() directly')

print()
if failed:
    print('RESULT: FAIL')
    sys.exit(1)
print('RESULT: PASS')
sys.exit(0)
