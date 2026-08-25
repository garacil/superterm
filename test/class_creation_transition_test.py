#!/usr/bin/env python3
"""A class window is first presented with its complete, final properties.

The settled screen is not enough to catch this regression: the old remote
path briefly inserted a centred window using one geometry and moved it to the
class geometry when the adjacent canonical layout arrived.  With
``SUPERTERM_SYNC=1`` every physical renderer update is a DEC-2026 transaction,
so this test replays every presentation seen by both the client which chooses
Classes -> precise and a second attached client.

The class size deliberately differs greatly from ``newwincols/newwinrows``.
The observer has no menu to dismiss and must receive exactly one material
presentation: the final titled window, with its exact interior size plus the
two-cell frame, centred on the shared desktop.  The actor may first repaint
the old desktop while FreeVision dismisses its Classes menu, but from the
first class window onward it too gets one final presentation and no rollback.
The separate local branch covers StartPaneEx, which does not traverse the
daemon protocol.
"""
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib  # noqa: E402
from stlib import check, run_cli  # noqa: E402


W, H = 124, 42
CLASS_COLS, CLASS_ROWS = 37, 9
CACHED_COLS, CACHED_ROWS = 58, 16
DEFAULT_COLS, DEFAULT_ROWS = 72, 20
SESSION = 'class-create-transition'
BASE_TITLE = 'CLASS_BASELINE'
CLASS_TITLE = 'CLASS_EXACT_FINAL'
CACHED_TITLE = 'CLASS_STALE_CACHED'
ENV = {
    'SUPERTERM_REAP_MS': '300000',
    'SUPERTERM_SYNC': '1',
}


def write_config(home, server_mode, class_title=CLASS_TITLE,
                 class_cols=CLASS_COLS, class_rows=CLASS_ROWS,
                 autorestore=0):
    with open(home + '/.superterm/superterm.ini', 'w', encoding='utf-8') as fh:
        fh.write(
            '[ui]\n'
            'language=en\n'
            'background=none\n'
            f'newwincols={DEFAULT_COLS}\n'
            f'newwinrows={DEFAULT_ROWS}\n'
            '[session]\n'
            f'server={server_mode}\n'
            'autosave=0\n'
            f'autorestore={autorestore}\n'
            '[class.precise]\n'
            'name=precise\n'
            'enabled=1\n'
            f'title={class_title}\n'
            'cmd=exec /bin/sleep 300\n'
            f'cols={class_cols}\n'
            f'rows={class_rows}\n')


def write_one_shell_session(home):
    """Prevent enabled classes from being auto-opened during local startup."""
    with open(home + '/.superterm/session.ini', 'w', encoding='utf-8') as fh:
        fh.write(
            '[layout]\n'
            'nodes=L\n'
            'count=1\n'
            'focused=0\n'
            '[pane0]\n'
            'cmd=exec /bin/sleep 300\n'
            f'cwd={home}\n'
            'term=\n'
            'title=LOCAL_BASELINE\n'
            'argc=0\n')


def drain_all(clients, seconds):
    """Drain peers fairly so the actor cannot leave its observer behind."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        for client in clients:
            if client is not None:
                client.drain(0.025)


def display_of(value):
    return value['display'] if isinstance(value, dict) else value.screen.display


def frame_rect(value, title):
    """Return an inclusive outer frame rectangle for a titled window."""
    rows = display_of(value)
    for top, row in enumerate(rows):
        title_x = row.find(title)
        if title_x < 0:
            continue
        lefts = [x for x, char in enumerate(row[:title_x])
                 if char in ('╔', '┌')]
        rights = [x for x, char in enumerate(row[title_x + len(title):],
                  title_x + len(title)) if char in ('╗', '┐')]
        if not lefts or not rights:
            continue
        left, right = max(lefts), min(rights)
        for bottom in range(top + 2, len(rows)):
            if (rows[bottom][left] in ('╚', '└') and
                    rows[bottom][right] in ('╝', '┘')):
                return left, top, right, bottom
    return None


def frame_rects(value):
    """Return every complete FreeVision frame, including an untitled one."""
    rows = display_of(value)
    result = set()
    for top, row in enumerate(rows):
        for left, char in enumerate(row):
            if char not in ('╔', '┌'):
                continue
            for right in range(left + 2, len(row)):
                if row[right] not in ('╗', '┐'):
                    continue
                found = False
                for bottom in range(top + 2, len(rows)):
                    if (rows[bottom][left] in ('╚', '└') and
                            rows[bottom][right] in ('╝', '┘')):
                        result.add((left, top, right, bottom))
                        found = True
                        break
                if found:
                    break
    return result


def expected_class_rect():
    """Mirror WantedWindowSize + CentredRect in the visible desktop."""
    desktop_w = W
    desktop_h = H - 2             # menu row and status row are not Desktop
    outer_w = min(desktop_w, max(16, CLASS_COLS + 2))
    outer_h = min(desktop_h, max(6, CLASS_ROWS + 2))
    left = (desktop_w - outer_w) // 2
    top = 1 + (desktop_h - outer_h) // 2
    return left, top, left + outer_w - 1, top + outer_h - 1


def material_records(records):
    """Cell changes plus a resent, visually identical complete repaint."""
    return [record for record in records
            if ((record['changed_cells'] > 0 and
                 not stlib.cursor_only_transition(record)) or
                len(record['raw']) > 512)]


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
    """Only nonvisual cursor/mode controls may escape DEC synchronization."""
    return all(not has_destructive_clear(record) and
               record['changed_cells'] == 0 and
               not direct_printed_text(record)
               for record in records if record['kind'] == 'direct')


def print_records(label, records):
    print('  ' + label + ' presentations:')
    for index, record in enumerate(records):
        print('   ', index, record['kind'],
              'changed=' + str(record['changed_cells']),
              'bytes=' + str(len(record['raw'])),
              'class=' + repr(frame_rect(record, CLASS_TITLE)),
              'base=' + repr(frame_rect(record, BASE_TITLE)),
              'clear=' + str(has_destructive_clear(record)),
              'direct-text=' + repr(direct_printed_text(record)
                                    if record['kind'] == 'direct' else ''))


def check_observer(records, expected):
    material = material_records(records)
    rects = [frame_rect(record, CLASS_TITLE) for record in material]
    ok = (len(material) == 1 and material[0]['kind'] == 'sync' and
          rects == [expected])
    if not ok:
        print('  observer material class path:', rects)
        print_records('observer', records)
    check('observer sees only final class paint', ok)
    check('observer has no direct clear/output', direct_output_ok(records))
    check('observer never shows provisional geometry',
          all(rect in (None, expected)
              for rect in (frame_rect(record, CLASS_TITLE)
                           for record in records)))


def check_actor(records, expected, label, allowed_pre_states):
    material = material_records(records)
    titled = [(index, frame_rect(record, CLASS_TITLE))
              for index, record in enumerate(material)
              if frame_rect(record, CLASS_TITLE) is not None]
    first_final = next((index for index, rect in titled if rect == expected),
                       None)
    # FreeVision may expose the unchanged old desktop while closing Classes.
    # Once the new title is physically present there is no such exception:
    # that presentation is exact, unique, and the last material transaction.
    tail = material[first_final:] if first_final is not None else []
    pre = material[:first_final] if first_final is not None else material
    # Menu dismissal may expose either the menu-open screen or the unchanged
    # baseline desktop.  A provisional class window with no title (or with an
    # unexpected title) still contributes a new complete frame and is not
    # excused merely because CLASS_TITLE is absent.
    pre_frames_ok = all(any(frame_rects(record) == allowed
                            for allowed in allowed_pre_states)
                        for record in pre)
    ok = (titled == [(first_final, expected)] and len(tail) == 1 and
          tail[0]['kind'] == 'sync' and pre_frames_ok)
    if not ok:
        print(f'  {label} material class path:', titled)
        print(f'  {label} allowed pre-frame states:',
              [sorted(value) for value in allowed_pre_states])
        print(f'  {label} observed pre-frames:',
              [sorted(frame_rects(record)) for record in pre])
        print_records(label, records)
    check(f'{label} inserts final class once', ok)
    check(f'{label} has no direct clear/output', direct_output_ok(records))
    check(f'{label} never shows provisional geometry',
          all(rect in (None, expected)
              for rect in (frame_rect(record, CLASS_TITLE)
                           for record in records)))


def detach(client):
    if client is None:
        return
    client.send(b'\x11', 0.08)
    client.send(b'd', 0.25)
    client.wait_exit(timeout=6.0)
    client.close()


EXPECTED = expected_class_rect()


# ------------------------------------------------------ shared daemon path

remote_home = stlib.fresh_home('class-creation-transition')
# Both the original client and the daemon first cache a deliberately stale
# definition.  The INI is replaced while they remain alive.  The menu command
# carries only the class name, so the authoritative daemon must reload it and
# NEWPANE_EV must carry the newly resolved title and size to *both* clients.
write_config(remote_home, 'always', CACHED_TITLE, CACHED_COLS, CACHED_ROWS)
a = None
b = None
try:
    a = stlib.Client(remote_home, args=['--session', SESSION], w=W, h=H,
                     lang='en', env=ENV)
    a.drain(2.5)
    primed = run_cli(['list', SESSION], remote_home, env={'LANG': 'C'})
    write_config(remote_home, 'always')
    renamed = run_cli(['rename', f'{SESSION}:1', BASE_TITLE], remote_home,
                      env={'LANG': 'C'})
    a.drain(0.8)
    b = stlib.Client(remote_home, args=['--attach', SESSION], w=W, h=H,
                     lang='en', env=ENV)
    drain_all((a, b), 2.5)
    check('two-client daemon baseline is ready',
          primed.returncode == 0 and renamed.returncode == 0 and
          a.alive() and b.alive() and
          frame_rect(a, BASE_TITLE) is not None and
          frame_rect(a, BASE_TITLE) == frame_rect(b, BASE_TITLE))

    baseline_frames = frame_rects(a)
    a.send(b'\x1bc', 0.45)          # Alt-C: Classes
    check('actor opens configured Classes menu', 'precise' in a.text())
    allowed_pre_states = (baseline_frames, frame_rects(a))
    a.begin_transition_capture()
    b.begin_transition_capture()
    os.write(a.fd, b'2')            # first configured class after Local shell
    drain_all((a, b), 2.2)
    actor_records = a.end_transition_capture()
    observer_records = b.end_transition_capture()

    check_actor(actor_records, EXPECTED, 'actor', allowed_pre_states)
    check_observer(observer_records, EXPECTED)
    check('class has exact centred outer rectangle',
          frame_rect(a, CLASS_TITLE) == EXPECTED and
          frame_rect(b, CLASS_TITLE) == EXPECTED)
    check('stale cached class is never presented',
          CACHED_TITLE not in a.text() and CACHED_TITLE not in b.text() and
          all(CACHED_TITLE not in '\n'.join(display_of(record))
              for record in actor_records + observer_records))
    check('both clients render the same shared desktop',
          tuple(a.screen.display) == tuple(b.screen.display))

    listed = run_cli(['list', SESSION], remote_home, env={'LANG': 'C'})
    check('daemon PTY starts at exact class size',
          listed.returncode == 0 and
          f'{CLASS_COLS}x{CLASS_ROWS}' in listed.stdout)
finally:
    detach(b)
    detach(a)
    stlib.close_all_daemons(remote_home)


# ---------------------------------------------------------- local UI path

local_home = stlib.fresh_home('class-creation-transition-local')
write_config(local_home, 'detach', autorestore=1)
write_one_shell_session(local_home)
local = None
try:
    local = stlib.Client(local_home, w=W, h=H, lang='en', env=ENV)
    local.drain(2.2)
    check('local branch has no daemon', not stlib.session_sockets(local_home))
    baseline_frames = frame_rects(local)
    local.send(b'\x1bc', 0.45)
    check('local opens configured Classes menu', 'precise' in local.text())
    allowed_pre_states = (baseline_frames, frame_rects(local))
    local.begin_transition_capture()
    os.write(local.fd, b'2')
    local.drain(1.8)
    local_records = local.end_transition_capture()

    check_actor(local_records, EXPECTED, 'local actor', allowed_pre_states)
    check('local class has exact centred rectangle',
          frame_rect(local, CLASS_TITLE) == EXPECTED)
finally:
    if local is not None:
        local.send(b'\x1bx', 0.30)  # Alt-X: the single Exit path
        local.wait_exit(timeout=6.0)
        local.close()
    stlib.close_all_daemons(local_home)


stlib.report()
