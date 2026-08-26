#!/usr/bin/env python3
"""The renderer-transition oracle never merges a truncated DEC 2026 frame."""

import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check


START = b'\x1b[?2026h'
FINISH = b'\x1b[?2026l'


class Sink:
    def feed(self, _data):
        pass


def capture_probe():
    probe = object.__new__(stlib.Client)
    probe._transition_pending = b''
    probe._transition_in_frame = True
    probe._transition_stream = Sink()
    probe._transition_raw = START
    probe._transition_direct_raw = b''
    return probe


# A legitimate reset may be split at any byte boundary between PTY reads.
split_probe = capture_probe()
saved = []
split_probe._save_transition = lambda kind, raw: saved.append((kind, raw))
split_probe._feed_transition_capture(b'payload' + FINISH[:4])
split_probe._feed_transition_capture(FINISH[4:])
check('split DEC reset completes one frame',
      not split_probe._transition_in_frame and len(saved) == 1 and
      saved[0][0] == 'sync' and saved[0][1].endswith(FINISH))

# A second transaction cannot donate its reset to a first, truncated one.
nested_probe = capture_probe()
nested_rejected = False
try:
    nested_probe._feed_transition_capture(b'broken' + START[:4])
    nested_probe._feed_transition_capture(START[4:] + b'new' + FINISH)
except AssertionError as exc:
    nested_rejected = 'nested DEC synchronized update' in str(exc)
check('nested DEC start exposes truncated frame', nested_rejected)

stlib.report()
