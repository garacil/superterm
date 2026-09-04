"""Summarises the escape-sequence structure of frames cut from a SUPERTERM_TEE
capture: which sequences appear, how many absolute positions, how many rows,
whether autowrap or cursor visibility is touched, and the per-row sizes.

    python test/windows/analyze_frames.py big.bin small.bin
"""
import re
import sys
from collections import Counter

for fn in sys.argv[1:]:
    d = open(fn, 'rb').read()
    seqs = re.findall(rb'\x1b\[[0-9;?]*[A-Za-z]', d)
    kinds = Counter(re.sub(rb'[0-9;]+', b'#', s) for s in seqs)
    print('==', fn, len(d), 'bytes')
    print(' kinds:', kinds.most_common(12))
    rows = re.findall(rb'\x1b\[(\d+);(\d+)H', d)
    print(' positions:', len(rows), 'first', rows[:4], 'last', rows[-3:])
    print(' bytes>=0x80:', sum(1 for b in d if b >= 0x80))
    print(' ?7l', b'\x1b[?7l' in d, '?25l', b'\x1b[?25l' in d,
          '?25h', b'\x1b[?25h' in d, '2J', b'\x1b[2J' in d,
          '[K', b'\x1b[K' in d, 'OSC', b'\x1b]' in d,
          'CR/LF', d.count(b'\r'), d.count(b'\n'))
    parts = re.split(rb'\x1b\[\d+;\d+H', d)
    print(' part sizes:', [len(p) for p in parts[:5]], '...',
          [len(p) for p in parts[-3:]])
