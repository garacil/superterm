#!/usr/bin/env python3
"""A live profile switch closes one complete workspace and builds one new one.

The temporal capture rejects partial one-window desktops and a second
destroy/recreate cycle during server=always promotion.  The debug log also
proves that the newborn daemon is adopted in place instead of entering the
generic attach reconstruction path.
"""
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check


HOME = stlib.fresh_home('profile-switch-transition')
INI = HOME + '/.superterm/superterm.ini'
LOG = '/tmp/superterm-profile-switch-transition.log'
try:
    os.unlink(LOG)
except FileNotFoundError:
    pass

with open(INI, 'w') as fh:
    fh.write('''[ui]
language=en
background=none
[session]
server=always
default_profile=alpha
default_window=main
autosave=0
autorestore=0

[profile.alpha]
name=alpha
enabled=1
focused_window=0
windows=main
[profile.alpha.window.main]
enabled=1
layout=V:500;L;L
focused_pane=0
panes=left,right
[profile.alpha.window.main.pane.left]
enabled=1
title=ALPHALEFT
cmd=printf ALPHA_LEFT_READY\\n; exec /bin/bash -i
[profile.alpha.window.main.pane.right]
enabled=1
title=ALPHARIGHT
cmd=printf ALPHA_RIGHT_READY\\n; exec /bin/bash -i

[profile.beta]
name=beta
enabled=1
focused_window=0
windows=main
[profile.beta.window.main]
enabled=1
layout=V:500;L;L
focused_pane=1
panes=left,right
[profile.beta.window.main.pane.left]
enabled=1
title=BETALEFT
cmd=printf BETA_LEFT_READY\\n; exec /bin/bash -i
[profile.beta.window.main.pane.right]
enabled=1
title=BETARIGHT
cmd=printf BETA_RIGHT_READY\\n; exec /bin/bash -i
''')

ENV = {
    'SUPERTERM_DEBUG': LOG,
    'SUPERTERM_DEBUG_FULL': '1',
    'SUPERTERM_SYNC': '1',
}

c = stlib.Client(HOME, w=110, h=34, lang='en', env=ENV)
c.drain(2.5)


def display(value):
    return value['display'] if isinstance(value, dict) else value.screen.display


def cells(value):
    if isinstance(value, dict):
        return value['cells']
    return tuple(tuple(value.screen.buffer[y][x] for x in range(value.w))
                 for y in range(value.h))


def frame_rects(value):
    """Return every complete FreeVision window rectangle on the desktop."""
    rows = display(value)
    result = set()
    for top, row in enumerate(rows):
        for left, char in enumerate(row):
            if char not in ('╔', '┌'):
                continue
            for right in range(left + 2, len(row)):
                if row[right] not in ('╗', '┐'):
                    continue
                for bottom in range(top + 2, len(rows)):
                    if (rows[bottom][left] in ('╚', '└') and
                            rows[bottom][right] in ('╝', '┘')):
                        result.add((left, top, right, bottom))
                        break
                if any(rect[0] == left and rect[1] == top and
                       rect[2] == right for rect in result):
                    break
    return result


def profile_state(value):
    """Classify only exact workspaces; extra/provisional frames are invalid."""
    text = '\n'.join(display(value))
    old_count = sum(name in text for name in ('ALPHALEFT', 'ALPHARIGHT'))
    new_count = sum(name in text for name in ('BETALEFT', 'BETARIGHT'))
    frames = len(frame_rects(value))
    if old_count == 2 and new_count == 0 and frames == 2:
        return 'old'
    if old_count == 0 and new_count == 2 and frames == 2:
        return 'new'
    if old_count == 0 and new_count == 0 and frames == 0:
        return 'blank'
    return f'invalid(old={old_count},new={new_count},frames={frames})'


def compact(values):
    result = []
    for value in values:
        if not result or result[-1] != value:
            result.append(value)
    return result


def allowed_menu_prefix(record, baseline, menu):
    """Accept only the cellwise envelope of the old desktop and its menu."""
    baseline_cells, baseline_frames = baseline
    menu_cells, menu_frames = menu
    observed_frames = frame_rects(record)
    if observed_frames not in (baseline_frames, menu_frames):
        return False
    menu_only = menu_frames - baseline_frames
    last_row = len(baseline_cells) - 1

    def menu_owned(x, y):
        return (y in (0, last_row) or any(
            left <= x <= right + 2 and top <= y <= bottom + 1
            for left, top, right, bottom in menu_only))

    for y, (baseline_row, menu_row, observed_row) in enumerate(zip(
            baseline_cells, menu_cells, record['cells'])):
        for x, (baseline_cell, menu_cell, observed_cell) in enumerate(zip(
                baseline_row, menu_row, observed_row)):
            if (not menu_owned(x, y) and
                    observed_cell.data != baseline_cell.data and
                    observed_cell.data != menu_cell.data):
                return False
    return True


def has_destructive_clear(record):
    raw = record['raw']
    return (re.search(br'\x1b\[[0-?]*[ -/]*[JKXPLM@]', raw) is not None or
            b'\x1bc' in raw or b'\x1b#8' in raw)


def direct_printed_text(record):
    raw = record['raw']
    raw = re.sub(br'\x1b\][^\x07]*(?:\x07|\x1b\\)', b'', raw,
                 flags=re.DOTALL)
    raw = re.sub(br'\x1bP.*?\x1b\\', b'', raw, flags=re.DOTALL)
    raw = re.sub(br'\x1b\[[0-?]*[ -/]*[@-~]', b'', raw)
    raw = re.sub(br'\x1b[ -/]*[@-Z\\-_]', b'', raw)
    raw = bytes(byte for byte in raw if byte >= 32 and byte != 127)
    return raw.decode('utf-8', 'replace')


def direct_output_ok(records):
    """A visual profile transition must stay inside DEC synchronization."""
    return all(not has_destructive_clear(record) and
               record['changed_cells'] == 0 and
               not direct_printed_text(record)
               for record in records if record['kind'] == 'direct')


check('alpha workspace starts complete', profile_state(c) == 'old')
check('initial profile daemon exists', len(stlib.session_sockets(HOME)) == 1)
old_frames = frame_rects(c)
old_presentation = (cells(c), old_frames)

# Open Profiles, move from active alpha to beta, then capture only Enter and
# the resulting replacement.  Menu navigation itself is deliberately outside
# the temporal contract being tested.
c.send(b'\x1br', 0.45)
c.send(b'\x1b[B', 0.25)
menu_frames = frame_rects(c)
menu_presentation = (cells(c), menu_frames)
log_offset = os.path.getsize(LOG)
c.begin_transition_capture()
os.write(c.fd, b'\r')
c.drain(2.8)
records = c.end_transition_capture()

material = [record for record in records
            if ((record['changed_cells'] > 0 and
                 not stlib.cursor_only_transition(record)) or
                len(record['raw']) > 512)]
states = [profile_state(record) for record in material]
# Capture starts with the Profiles menu still covering the old workspace.
# Before the first real workspace state, only that exact menu frame set or the
# exact old frame set is allowed.  A blank, partial or extra provisional pane
# is therefore not hidden under the generic label "menu teardown".
workspace_start = next((index for index, state in enumerate(states)
                        if state in ('old', 'blank', 'new')), len(states))
prefix = material[:workspace_start]
# Geometry alone is not a sufficient oracle: a provisional ALPHA/BETA mix
# can occupy exactly the same two rectangles. FreeVision may tear a menu down
# incrementally, so accept a cellwise mixture of the independently captured
# old/menu glyphs, but only inside their exact frame envelope. Any new pane
# glyph outside the menu/shadow is therefore a real partial desktop.
prefix_ok = all(allowed_menu_prefix(
    record, old_presentation, menu_presentation) for record in prefix)
workspace_states = states[workspace_start:]
path = compact(workspace_states)
if (not prefix_ok or
        any(state.startswith('invalid') for state in workspace_states) or
        path not in (['old', 'blank', 'new'], ['blank', 'new'],
                     ['old', 'new'], ['new'])):
    print('  profile teardown frame states:',
          [sorted(frame_rects(record)) for record in prefix])
    print('  profile presentation path:', ' -> '.join(path))
check('profile switch has no partial desktop',
      prefix_ok and workspace_states and
      not any(state.startswith('invalid') for state in workspace_states))
check('profile switch never reconstructs twice',
      path in (['old', 'blank', 'new'], ['blank', 'new'],
               ['old', 'new'], ['new']))
check('profile switch uses synchronized paints',
      all(record['kind'] == 'sync' for record in material) and
      direct_output_ok(records))
check('beta workspace finishes complete', profile_state(c) == 'new')
check('old profile is absent after switch',
      'ALPHALEFT' not in c.text() and 'ALPHARIGHT' not in c.text())

with open(LOG, 'r', errors='replace') as fh:
    fh.seek(log_offset)
    switch_log = fh.read()
check('profile constructed exactly once',
      switch_log.count('profile activate ') == 1 and
      switch_log.count('startpane i=') == 2)
check('new profile daemon adopted in place',
      switch_log.count('promote-adopt: panes=') == 1 and
      'attach: AttachRemoteSession begin' not in switch_log)

c.send(b'\x11', 0.10)
c.send(b'd', 0.4)
c.wait_exit(timeout=5.0)
c.close()
stlib.close_all_daemons(HOME)
stlib.report()
