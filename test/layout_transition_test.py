#!/usr/bin/env python3
"""Temporal shared-layout regression test with two real UI clients.

Unlike tests which inspect only the settled daemon state, this one enables
DEC synchronized output and replays every physical terminal transaction.  It
therefore detects a visible A->B->A->B rollback even when the final screen is
correct.  Zoom outlines are part of the synchronized framebuffer compositor:
the test reconstructs every complete ring from its before/after cell grids, so
both the actor and observers must see the same eight-step animation.
"""
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, run_cli


HOME = stlib.fresh_home('layout-transition')
INI = os.path.join(HOME, '.superterm', 'superterm.ini')
LOG = os.path.join(HOME, 'layout-transition.log')
with open(INI, 'w') as fh:
    fh.write('[ui]\n'
             'language=en\n'
             'palette=mono\n'
             'background=none\n'
             '[session]\n'
             'server=always\n'
             'autosave=0\n'
             'autorestore=0\n'
             'dragcontent=1\n'
             'zoomanim=1\n')
# This suite audits layout presentations, not concurrent pane output. Keep the
# login shells alive but quiescent so bash/readline cannot redraw a prompt in
# response to the deliberate TIOCSWINSZ between two animation frames and be
# misclassified as a second layout transaction. Output/layout ordering has
# its own deterministic coverage in f5_output_layout_order_test.py.
with open(os.path.join(HOME, '.bash_profile'), 'w', encoding='ascii') as fh:
    fh.write('exec /bin/sleep 3600\n')

ENV = {
    'SUPERTERM_DEBUG': LOG,
    'SUPERTERM_DEBUG_FULL': '1',
    # This is not merely cosmetic in this test: stlib records every complete
    # transaction separately, even if one PTY read contains several frames.
    'SUPERTERM_SYNC': '1',
}

a = stlib.Client(HOME, w=110, h=34, lang='en', env=ENV)
a.drain(2.0)
a.send(b'\x1bOQ', 1.0)       # F2: second pane
a.send(b'\x11', 0.08)
a.send(b't', 0.8)             # deterministic two-column baseline

sockets = stlib.session_sockets(HOME)
check('transition session exists', len(sockets) == 1)
SESSION = os.path.basename(sockets[0])[:-5] if sockets else ''


def control(args, attempts=20):
    """Retry only while startup still owns a transient layout lock."""
    last = None
    for _attempt in range(attempts):
        last = run_cli(args, HOME, env=ENV)
        if last.returncode == 0:
            return last
        if 'busy' not in (last.stdout + last.stderr).lower():
            break
        time.sleep(0.05)
    if last is not None:
        print('  control failed:', ' '.join(args),
              repr((last.stdout + last.stderr).strip()))
    return last


check('rename transition pane',
      control(['rename', SESSION + ':1', 'TXPANE']).returncode == 0)
check('rename other pane',
      control(['rename', SESSION + ':2', 'OTHERPANE']).returncode == 0)

# One extra physical column deliberately keeps this temporal renderer test on
# the mixed-geometry fallback path. Equal-size raw fullscreen is covered byte-for-byte
# by passthrough_multiclient_test; here we need the rendered final frame in
# order to audit every animation/lock presentation around it.
b = stlib.Client(HOME, args=['--attach'], w=111, h=34, lang='en', env=ENV)
b.drain(2.2)
focus_result = control(['focus', SESSION + ':1'])
check('focus transition pane', focus_result.returncode == 0)

clients = (a, b)


def drain_all(seconds=0.8):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        for client in clients:
            client.drain(0.025)


drain_all(1.0)


def display_of(value):
    if isinstance(value, dict):
        return value['display']
    return value.screen.display


def display_from_cells(cells):
    return tuple(''.join(char.data for char in row) for row in cells)


def cells_value(cells):
    return {'display': display_from_cells(cells)}


def frame_rect(value, title='TXPANE'):
    rows = display_of(value)
    for top, row in enumerate(rows):
        title_x = row.find(title)
        if title_x < 0:
            continue
        # A remotely leased pane keeps its ordinary top row except for the two
        # corners, which are CP437 #177 (medium shade).  Include those corners
        # so geometry remains observable throughout live move/resize previews;
        # ignoring them made every held-lock rectangle disappear from paths.
        lefts = [x for x, ch in enumerate(row[:title_x])
                 if ch in ('╔', '┌', '▒')]
        rights = [x for x, ch in enumerate(row[title_x + len(title):],
                  title_x + len(title)) if ch in ('╗', '┐', '▒')]
        if not lefts or not rights:
            continue
        left, right = max(lefts), min(rights)
        for bottom in range(top + 2, len(rows)):
            # The lock painter fills the complete bottom edge with #176; unlike
            # the top/sides it deliberately has no #177 corner override.
            if (rows[bottom][left] in ('╚', '└', '▒', '░') and
                    rows[bottom][right] in ('╝', '┘', '▒', '░')):
                return left, top, right, bottom
    return None


def frame_is_active(value, title='TXPANE'):
    """Only SuperTerm's active frame draws its custom [-] control."""
    rect = frame_rect(value, title)
    if rect is None:
        return False
    left, top, right, _bottom = rect
    rows = display_of(value)
    return '[-]' in rows[top][left:right + 1]


def icon_rect(value, title='TXPANE'):
    rows = display_of(value)
    for top in range(len(rows) - 1):
        tx = rows[top].find(title)
        if tx < 0:
            continue
        lefts = [x for x, ch in enumerate(rows[top][:tx]) if ch == '┌']
        rights = [x for x, ch in enumerate(rows[top][tx + len(title):],
                  tx + len(title)) if ch == '┐']
        if not lefts or not rights:
            continue
        left, right = max(lefts), min(rights)
        if rows[top + 1][left] == '└' and rows[top + 1][right] == '┘':
            return left, top, right, top + 1
    return None


def pane_state(value):
    if icon_rect(value) is not None:
        return 'icon'
    if frame_rect(value) is not None:
        return 'window'
    return None


def char_attr(char):
    return (char.fg, char.bg, char.bold, char.italics, char.underscore,
            char.strikethrough, char.reverse, char.blink)


def frame_attr(client, rect):
    if rect is None:
        return None
    left, top, _right, _bottom = rect
    return char_attr(client.screen.buffer[top][left])


def compact(values):
    result = []
    for value in values:
        if value is not None and (not result or result[-1] != value):
            result.append(value)
    return result


def state_path(records, initial):
    return compact([initial] + [pane_state(record) for record in records])


def rect_path(records, initial):
    return compact([initial] + [frame_rect(record) for record in records])


def structural(records):
    return [record for record in records
            if record['changed_cells'] > 0 and
            not stlib.cursor_only_transition(record)]


def has_lock(value):
    rows = display_of(value)
    # A minimized title keeps the spaces already stored around its caption,
    # so its deliberate ``' LOCK ' + title`` can render as
    # ``LOCK  TXPANE``.  Match that exact semantic label, without weakening
    # the oracle to an arbitrary occurrence of LOCK in pane contents.
    if any(re.search(r'\bLOCK\s+TXPANE\b', row) for row in rows):
        return True
    for x in range(len(rows[0]) if rows else 0):
        for y in range(max(0, len(rows) - 3)):
            if ''.join(rows[y + n][x] for n in range(4)) == 'LOCK':
                return True
    return False


def mouse_down(c, x, y):
    stlib.write_all(c.fd, f'\x1b[<0;{x + 1};{y + 1}M'.encode())


def mouse_drag(c, x, y):
    stlib.write_all(c.fd, f'\x1b[<32;{x + 1};{y + 1}M'.encode())


def mouse_up(c, x, y):
    stlib.write_all(c.fd, f'\x1b[<0;{x + 1};{y + 1}m'.encode())


def click(c, x, y):
    mouse_down(c, x, y)
    mouse_up(c, x, y)


def double_click(c, x, y):
    """Exactly two physical clicks inside FreeVision's double-click window.

    Queuing both press/release pairs back-to-back made FreeVision consume them
    as one synthetic burst and hid the real Konsole regression where the
    title's first click finishes its focus/move path before click two arrives.
    """
    click(c, x, y)
    # Upstream FreeVision uses eight clock ticks (about 440 ms on Darwin).
    # 120 ms lets the first click complete while remaining unambiguously one
    # double-click; the previous 250 ms drain + 250 ms sleep was three-click
    # timing in disguise on macOS.
    drain_all(0.12)
    click(c, x, y)


def begin_capture():
    for client in clients:
        client.begin_transition_capture()


def end_capture():
    return tuple(client.end_transition_capture() for client in clients)


def wait_presented(predicate, timeout=2.0):
    """Wait for an exact physical state instead of sleeping past its event."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        drain_all(0.025)
    drain_all(0.05)
    return predicate()


def wait_capture_quiet(predicate, timeout=6.0, quiet=1.80):
    """Require convergence plus a real material-presentation quiet tail."""
    deadline = time.monotonic() + timeout
    counts = tuple(len(client.transitions()) for client in clients)
    changed_at = time.monotonic()
    while time.monotonic() < deadline:
        drain_all(0.05)
        records = tuple(client.transitions() for client in clients)
        material = any(
            not stlib.cursor_only_transition(record)
            for client_records, old_count in zip(records, counts)
            for record in client_records[old_count:])
        counts = tuple(len(client_records) for client_records in records)
        if material:
            changed_at = time.monotonic()
        if predicate() and time.monotonic() - changed_at >= quiet:
            return True
    return False


def print_path(label, path):
    print('  ' + label + ': ' + ' -> '.join(map(str, path)))


baseline_a = frame_rect(a)
baseline_b = frame_rect(b)
check('shared tiled baseline visible',
      baseline_a is not None and baseline_a == baseline_b)

# ---------------------------------------------------------------- minimize

# Click the original right-hand [-].  The old implementation first painted
# the local icon, then applied the lock snapshot containing the old window,
# then painted the final icon a second time.  The per-transaction state path
# exposes that rollback directly.
begin_capture()
if baseline_a is not None:
    left, top, right, _bottom = baseline_a
    click(a, right - 8, top)   # local Size.X-9: centre of [-]
min_settled = wait_capture_quiet(
    lambda: (icon_rect(a) is not None and
             icon_rect(a) == icon_rect(b) and
             not has_lock(a) and not has_lock(b)))
min_a, min_b = end_capture()
min_path_a = state_path(min_a, 'window')
min_path_b = state_path(min_b, 'window')
if min_path_a != ['window', 'icon']:
    print_path('minimize actor', min_path_a)
if min_path_b != ['window', 'icon']:
    print_path('minimize observer', min_path_b)
check('minimize actor has one transition',
      min_path_a == ['window', 'icon'])
check('minimize observer has one transition',
      min_path_b == ['window', 'icon'])
check('minimize never shades its actor',
      not any(has_lock(record) for record in min_a))
check('minimized icon shared',
      min_settled and icon_rect(a) is not None and
      icon_rect(a) == icon_rect(b))

# ---------------------------------------------------------------- restore

icon = icon_rect(a)
begin_capture()
if icon is not None:
    left, top, right, _bottom = icon
    click(a, (left + right) // 2, top)
restore_settled = wait_capture_quiet(
    lambda: (frame_rect(a) == baseline_a and
             frame_rect(b) == baseline_a and
             not has_lock(a) and not has_lock(b)))
restore_a, restore_b = end_capture()
restore_path_a = state_path(restore_a, 'icon')
restore_path_b = state_path(restore_b, 'icon')
if restore_path_a != ['icon', 'window']:
    print_path('restore actor', restore_path_a)
if restore_path_b != ['icon', 'window']:
    print_path('restore observer', restore_path_b)
check('restore actor has one transition',
      restore_path_a == ['icon', 'window'])
check('restore observer has one transition',
      restore_path_b == ['icon', 'window'])
check('restore never shades its actor',
      not any(has_lock(record) for record in restore_a))
check('restore returns exact shared rectangle',
      restore_settled and
      frame_rect(a) == baseline_a and frame_rect(b) == baseline_a)
restored_focus_ok = (
    frame_is_active(a) and frame_is_active(b) and
    not frame_is_active(a, 'OTHERPANE') and
    not frame_is_active(b, 'OTHERPANE'))
if not restored_focus_ok:
    for client_no, client in enumerate((a, b), 1):
        title_rows = [row for row in client.screen.display
                      if 'TXPANE' in row or 'OTHERPANE' in row]
        print(f'  restore focus client {client_no} title rows:',
              title_rows)
        for title in ('TXPANE', 'OTHERPANE'):
            rect = frame_rect(client, title)
            top_row = ('' if rect is None else
                       client.screen.display[rect[1]][rect[0]:rect[2] + 1])
            print(f'  restore focus client {client_no} {title}: '
                  f'rect={rect} active={frame_is_active(client, title)} '
                  f'top={top_row!r}')
    focus_list = run_cli(['list', SESSION], HOME,
                         env=dict(ENV, LANG='C'))
    print('  restore focus daemon list:',
          repr(focus_list.stdout), repr(focus_list.stderr))
check('restored pane owns shared focus', restored_focus_ok)

# ---------------------------------------------------------- maximize/zoom

# A native title control is not a drag gesture: the cmZoom command acquires
# its lock immediately before the first animation frame and holds it through
# the final commit. Check the observer's captured animation transactions,
# rather than incorrectly expecting a lock from mouse-down alone.
before_zoom = frame_rect(a)
zoom_frame_attr_a = frame_attr(a, before_zoom)
zoom_frame_attr_b = frame_attr(b, before_zoom)
begin_capture()
if before_zoom is not None:
    _left, top, right, _bottom = before_zoom
    zoom_x = right - 3          # centre of vendor Size.X-5..Size.X-3
    click(a, zoom_x, top)
zoom_settled = wait_capture_quiet(
    lambda: (frame_rect(a) is not None and frame_rect(a) != before_zoom and
             frame_rect(b) == frame_rect(a) and
             not has_lock(a) and not has_lock(b)))
zoom_a, zoom_b = end_capture()
observer_locked_zoom = any(has_lock(record) for record in zoom_b)
actor_locked_zoom = any(has_lock(record) for record in zoom_a)
after_zoom = frame_rect(a)
zoom_path_a = rect_path(zoom_a, before_zoom)
zoom_path_b = rect_path(zoom_b, before_zoom)
if zoom_path_a != compact([before_zoom, after_zoom]):
    print_path('maximize actor', zoom_path_a)
if zoom_path_b != compact([before_zoom, after_zoom]):
    print_path('maximize observer', zoom_path_b)
check('maximize observer sees held lock', observer_locked_zoom)
check('maximize actor never sees own lock', not actor_locked_zoom and
      not any(has_lock(record) for record in zoom_a))
check('maximize changes shared rectangle once',
      zoom_settled and before_zoom is not None and after_zoom is not None and
      before_zoom != after_zoom and
      zoom_path_a == [before_zoom, after_zoom] and
      zoom_path_b == [before_zoom, after_zoom] and
      frame_rect(b) == after_zoom)

# Restore from native maximize using the same instantaneous control path.
unzoom_frame_attr_a = frame_attr(a, after_zoom)
unzoom_frame_attr_b = frame_attr(b, after_zoom)
begin_capture()
if after_zoom is not None:
    _left, top, right, _bottom = after_zoom
    zoom_x = right - 3
    click(a, zoom_x, top)
unzoom_settled = wait_capture_quiet(
    lambda: (frame_rect(a) == before_zoom and
             frame_rect(b) == before_zoom and
             not has_lock(a) and not has_lock(b)))
unzoom_a, unzoom_b = end_capture()
after_unzoom = frame_rect(a)
unzoom_path_a = rect_path(unzoom_a, after_zoom)
unzoom_path_b = rect_path(unzoom_b, after_zoom)
check('maximize restore has no rollback',
      unzoom_settled and after_unzoom == before_zoom and
      frame_rect(b) == before_zoom and
      unzoom_path_a == [after_zoom, before_zoom] and
      unzoom_path_b == [after_zoom, before_zoom])

# Double-clicking the title text follows FreeVision's native cmZoom route.
# SuperTerm must keep that command on the same per-pane lock/canonical-layout
# path as the zoom button: both clients see exactly one geometry transition,
# the clicked pane remains focused, and the second double-click restores the
# byte-for-byte original rectangle instead of minimizing or moving it.
# TXPANE is already focused. Exactly two physical clicks must toggle it. An
# inactive title has the conventional three-click sequence instead: one click
# to focus, followed by a double-click; that case is checked after restore.
check('physical title double-click target starts active',
      frame_is_active(a) and frame_is_active(b) and
      not frame_is_active(a, 'OTHERPANE') and
      not frame_is_active(b, 'OTHERPANE'))
before_title_zoom = frame_rect(a)
title_x = -1
if before_title_zoom is not None:
    _left, title_y, _right, _bottom = before_title_zoom
    title_start = a.screen.display[title_y].find('TXPANE')
    if title_start >= 0:
        title_x = title_start + len('TXPANE') // 2
begin_capture()
if title_x >= 0:
    double_click(a, title_x, title_y)
title_zoom_settled = wait_capture_quiet(
    lambda: (frame_rect(a) == after_zoom and
             frame_rect(b) == after_zoom and
             not has_lock(a) and not has_lock(b)))
title_zoom_a, title_zoom_b = end_capture()
after_title_zoom = frame_rect(a)
title_zoom_path_a = rect_path(title_zoom_a, before_title_zoom)
title_zoom_path_b = rect_path(title_zoom_b, before_title_zoom)
check('title double-click maximizes exactly once in actor',
      title_zoom_settled and before_title_zoom is not None and
      after_title_zoom == after_zoom and
      title_zoom_path_a == [before_title_zoom, after_title_zoom])
check('title double-click maximizes exactly once in observer',
      frame_rect(b) == after_title_zoom and
      title_zoom_path_b == [before_title_zoom, after_title_zoom] and
      any(has_lock(record) for record in title_zoom_b))
check('title double-click keeps shared focus and never minimizes',
      frame_is_active(a) and frame_is_active(b) and
      not frame_is_active(a, 'OTHERPANE') and
      not frame_is_active(b, 'OTHERPANE') and
      icon_rect(a) is None and icon_rect(b) is None)

# Wait beyond the vendor double-click window so the next pair starts a new
# gesture rather than becoming a triple-click continuation of the first.
drain_all(0.55)
max_title = frame_rect(a)
max_title_x = -1
if max_title is not None:
    _left, max_title_y, _right, _bottom = max_title
    max_title_start = a.screen.display[max_title_y].find('TXPANE')
    if max_title_start >= 0:
        max_title_x = max_title_start + len('TXPANE') // 2
begin_capture()
if max_title_x >= 0:
    double_click(a, max_title_x, max_title_y)
title_restore_settled = wait_capture_quiet(
    lambda: (frame_rect(a) == before_title_zoom and
             frame_rect(b) == before_title_zoom and
             not has_lock(a) and not has_lock(b)))
title_restore_a, title_restore_b = end_capture()
after_title_restore = frame_rect(a)
title_restore_path_a = rect_path(title_restore_a, max_title)
title_restore_path_b = rect_path(title_restore_b, max_title)
check('maximized title double-click restores exact rectangle in actor',
      title_restore_settled and max_title == after_title_zoom and
      after_title_restore == before_title_zoom and
      title_restore_path_a == [max_title, before_title_zoom])
check('maximized title double-click restores exact rectangle in observer',
      frame_rect(b) == before_title_zoom and
      title_restore_path_b == [max_title, before_title_zoom])
check('title restore keeps shared focus and never minimizes',
      frame_is_active(a) and frame_is_active(b) and
      not frame_is_active(a, 'OTHERPANE') and
      not frame_is_active(b, 'OTHERPANE') and
      icon_rect(a) is None and icon_rect(b) is None)

# A single click on an inactive title must only focus it. It must not borrow
# the previous pane's click history and accidentally maximize; the following
# two-click gesture is deliberately left to the active-window checks above.
check('focus other pane before inactive title click',
      control(['focus', SESSION + ':2']).returncode == 0)
drain_all(0.45)
inactive_rect = frame_rect(a)
if inactive_rect is not None:
    _left, inactive_y, _right, _bottom = inactive_rect
    inactive_title = a.screen.display[inactive_y].find('TXPANE')
    if inactive_title >= 0:
        click(a, inactive_title + len('TXPANE') // 2, inactive_y)
drain_all(0.65)
check('inactive title first click only focuses without resizing',
      frame_rect(a) == inactive_rect and frame_rect(b) == inactive_rect and
      frame_is_active(a) and frame_is_active(b))

# -------------------------------------------------------------------- move

# Move the focused pane one physical column per event.  The actor owns the
# lease but never paints its own LOCK; the observer must present the old locked
# rectangle, every live preview under the same lock, then the final duplicate
# geometry once with the lock removed. The physical oracle below distinguishes
# layout/lock transitions from legitimate pane-content output at the same rect.
before_move = frame_rect(a)
expected_move_rects = []
move_title_x = -1
if before_move is not None:
    move_left, move_top, move_right, move_bottom = before_move
    title_start = a.screen.display[move_top].find('TXPANE')
    if title_start >= 0:
        move_title_x = title_start + len('TXPANE') // 2
    expected_move_rects = [
        (move_left + step, move_top, move_right + step, move_bottom)
        for step in range(7)
    ]
begin_capture()
move_steps_presented = True
if move_title_x >= 0:
    mouse_down(a, move_title_x, move_top)
    drain_all(0.35)
    observer_locked_move = has_lock(b)
    actor_locked_move = has_lock(a)
    for step in range(1, 7):
        mouse_drag(a, move_title_x + step, move_top)
        target = expected_move_rects[step]
        step_presented = wait_presented(
            lambda target=target:
                frame_rect(a) == target and frame_rect(b) == target and
                not has_lock(a) and has_lock(b), timeout=1.5)
        move_steps_presented = step_presented and move_steps_presented
    mouse_up(a, move_title_x + 6, move_top)
else:
    observer_locked_move = False
    actor_locked_move = False
    move_steps_presented = False
move_commit_settled = wait_capture_quiet(
    lambda: (bool(expected_move_rects) and
             frame_rect(a) == expected_move_rects[-1] and
             frame_rect(b) == expected_move_rects[-1] and
             not has_lock(a) and not has_lock(b)))
move_a, move_b = end_capture()
after_move = frame_rect(a)
move_path_a = rect_path(move_a, before_move)
move_path_b = rect_path(move_b, before_move)
if move_path_a != expected_move_rects:
    print_path('move actor', move_path_a)
if move_path_b != expected_move_rects:
    print_path('move observer', move_path_b)
check('move observer sees held lock', observer_locked_move)
check('move actor never sees own lock', not actor_locked_move and
      not any(has_lock(record) for record in move_a))
check('move renders every exact one-cell step in both clients',
      len(expected_move_rects) == 7 and move_steps_presented and
      move_commit_settled and
      move_path_a == expected_move_rects and
      move_path_b == expected_move_rects and
      after_move == expected_move_rects[-1] and
      frame_rect(b) == after_move)
move_focus_ok = frame_is_active(a) and frame_is_active(b)
if not move_focus_ok:
    print('  moved-pane focus state:',
          [frame_is_active(client) for client in clients])
# Do not parse the partly covered OTHERPANE as an independent active-frame
# oracle here. After the six-column overlap its hidden left corner can make a
# text-only parser combine TXPANE's left edge with OTHERPANE's right edge and
# falsely attribute TXPANE's [-] control to both. The moved pane's own complete
# top border stays visible and is the reliable shared-focus evidence.
check('move keeps shared focus', move_focus_ok)

# ------------------------------------------------------------------ resize

# Grow the bottom-right edge one character per event.  Live previews are part
# of the shared view, so both clients must traverse the same seven rectangles;
# only the observer shades them while the actor owns the pane lease.
before_resize = frame_rect(a)
resize_log_offset = os.path.getsize(LOG)
begin_capture()
resize_steps_presented = True
if before_resize is not None:
    left, top, right, bottom = before_resize
    mouse_down(a, right, bottom)
    drain_all(0.35)
    observer_locked_resize = has_lock(b)
    actor_locked_resize = has_lock(a)
    for step in range(1, 7):
        mouse_drag(a, right + step, bottom)
        target = (left, top, right + step, bottom)
        step_presented = wait_presented(
            lambda target=target:
                frame_rect(a) == target and frame_rect(b) == target and
                not has_lock(a) and has_lock(b), timeout=1.5)
        resize_steps_presented = step_presented and resize_steps_presented
    mouse_up(a, right + 6, bottom)
else:
    observer_locked_resize = False
    actor_locked_resize = False
    resize_steps_presented = False
resize_commit_settled = wait_capture_quiet(
    lambda: (before_resize is not None and
             frame_rect(a) == (before_resize[0], before_resize[1],
                               before_resize[2] + 6, before_resize[3]) and
             frame_rect(b) == frame_rect(a) and
             not has_lock(a) and not has_lock(b)))
resize_a, resize_b = end_capture()
with open(LOG, 'r', errors='replace') as log_fh:
    log_fh.seek(resize_log_offset)
    resize_log = log_fh.read()
after_resize = frame_rect(a)
actor_widths = compact([
    rect[2] - rect[0] + 1
    for rect in ([before_resize] + [frame_rect(record) for record in resize_a])
    if rect is not None
])
expected_actor_widths = (
    list(range(before_resize[2] - before_resize[0] + 1,
               before_resize[2] - before_resize[0] + 8))
    if before_resize is not None else []
)
observer_rects = rect_path(resize_b, before_resize)
if actor_widths != expected_actor_widths:
    print_path('resize actor widths', actor_widths)
expected_resize_rects = (
    [(before_resize[0], before_resize[1], before_resize[2] + step,
      before_resize[3]) for step in range(7)]
    if before_resize is not None else []
)
if observer_rects != expected_resize_rects:
    print_path('resize observer', observer_rects)
check('resize observer sees held lock', observer_locked_resize)
check('resize actor never sees own lock', not actor_locked_resize and
      not any(has_lock(record) for record in resize_a))
check('resize actor renders every exact one-cell step',
      resize_steps_presented and resize_commit_settled and
      actor_widths == expected_actor_widths and
      len(expected_actor_widths) == 7)
check('resize observer renders every exact one-cell step',
      after_resize is not None and before_resize is not None and
      after_resize[2] == before_resize[2] + 6 and
      frame_rect(b) == after_resize and
      observer_rects == expected_resize_rects)
check('layout commit sends no RESIZE_EV',
      'daemon says' not in resize_log)

# -------------------------------------------------- fullscreen animation

def pascal_div(value, divisor):
    """Integer division with Pascal's truncation toward zero."""
    quotient = abs(value) // abs(divisor)
    return -quotient if (value < 0) != (divisor < 0) else quotient


def animation_rects(before, after):
    if before is None or after is None:
        return []
    return [tuple(
        before[index] + pascal_div((after[index] - before[index]) * step, 8)
        for index in range(4)
    ) for step in range(1, 9)]


def perimeter(rect):
    if rect is None:
        return {}
    x1, y1, x2, y2 = rect
    if x1 >= x2 or y1 >= y2:
        return {}
    cells = {
        (x1, y1): '┌', (x2, y1): '┐',
        (x1, y2): '└', (x2, y2): '┘',
    }
    for x in range(x1 + 1, x2):
        cells[x, y1] = '─'
        cells[x, y2] = '─'
    for y in range(y1 + 1, y2):
        cells[x1, y] = '│'
        cells[x2, y] = '│'
    return cells


def complete_ring_attrs(cells, rect):
    """Return all attributes only when ``cells`` contains the complete ring."""
    expected = perimeter(rect)
    if not expected or not cells:
        return None
    height = len(cells)
    width = len(cells[0]) if height else 0
    if any(x < 0 or y < 0 or y >= height or x >= width
           for x, y in expected):
        return None
    attrs = set()
    for (x, y), glyph in expected.items():
        char = cells[y][x]
        if char.data != glyph:
            return None
        attrs.add(char_attr(char))
    return frozenset(attrs)


def changed_positions(record):
    return {
        (x, y)
        for y, (before_row, after_row) in enumerate(
            zip(record['before_cells'], record['cells']))
        for x, (before, after) in enumerate(zip(before_row, after_row))
        if before != after
    }


def cells_difference(before_cells, after_cells):
    return {
        (x, y)
        for y, (before_row, after_row) in enumerate(
            zip(before_cells, after_cells))
        for x, (before, after) in enumerate(zip(before_row, after_row))
        if before != after
    }


def ring_transition(record, rect):
    """Recognize one composited show/hide from its presented cell grids."""
    if record['kind'] != 'sync' or record['changed_cells'] <= 0:
        return None
    before_attrs = complete_ring_attrs(record['before_cells'], rect)
    after_attrs = complete_ring_attrs(record['cells'], rect)
    if before_attrs is None and after_attrs is not None:
        return 'show', after_attrs
    if before_attrs is not None and after_attrs is None:
        return 'hide', before_attrs
    return None


def zoom_control_token(record, rect):
    """Classify only FreeVision's native zoom-button press feedback.

    TFrame.HandleEvent deliberately redraws one cell twice around cmZoom:
    normal arrow -> ClickC (#15) on mouse-down, then ClickC -> arrow on
    release.  It is useful visual feedback, not a layout presentation.  Keep
    it explicit in the expected physical sequence instead of hiding every
    one-cell update (which could mask a real artifact elsewhere).
    """
    if (rect is None or record['kind'] != 'sync' or
            record['changed_cells'] != 1 or frame_rect(record) != rect):
        return None
    left, top, right, bottom = rect
    changed = []
    for y, (before_row, after_row) in enumerate(
            zip(record['before_cells'], record['cells'])):
        for x, (before, after) in enumerate(zip(before_row, after_row)):
            if before != after:
                changed.append((x, y, before, after))
    if len(changed) != 1:
        return None
    x, y, before, after = changed[0]
    if (x != right - 3 or y != top or
            char_attr(before) != char_attr(after)):
        return None
    if before.data in ('↑', '↕') and after.data == '☼':
        return 'sync-zoom-down'
    if before.data == '☼' and after.data in ('↑', '↕'):
        return 'sync-zoom-up'
    return None


before_f5 = frame_rect(a)
f5_in_frame_attr_a = frame_attr(a, before_f5)
f5_in_frame_attr_b = frame_attr(b, before_f5)
begin_capture()
stlib.write_all(a.fd, stlib.FULLSCREEN_CHORD)
fullscreen_in_settled = wait_capture_quiet(
    lambda: (frame_rect(a) is not None and
             frame_rect(a) != before_f5 and
             frame_rect(b) == frame_rect(a) and
             not has_lock(a) and not has_lock(b)))
f5_in_a, f5_in_b = end_capture()
after_f5 = frame_rect(a)
f5_path_a = rect_path(f5_in_a, before_f5)
f5_path_b = rect_path(f5_in_b, before_f5)
check('fullscreen geometry has no stale rollback',
      fullscreen_in_settled and
      after_f5 is not None and after_f5 != before_f5 and
      f5_path_a == [before_f5, after_f5] and
      f5_path_b == [before_f5, after_f5] and
      frame_rect(b) == after_f5)

# Fullscreen out deliberately restores the window first, then contracts its ring.
# That order is valid animation, but the actual pane rectangle still changes
# exactly once and every one of the eight visible rings must shrink.
f5_out_frame_attr_a = frame_attr(a, after_f5)
f5_out_frame_attr_b = frame_attr(b, after_f5)
begin_capture()
stlib.write_all(a.fd, stlib.FULLSCREEN_CHORD)
fullscreen_out_settled = wait_capture_quiet(
    lambda: (frame_rect(a) == before_f5 and
             frame_rect(b) == before_f5 and
             not has_lock(a) and not has_lock(b)))
f5_out_a, f5_out_b = end_capture()
after_f5_out = frame_rect(a)
f5_out_path_a = rect_path(f5_out_a, after_f5)
f5_out_path_b = rect_path(f5_out_b, after_f5)
check('fullscreen return has no stale rollback',
      fullscreen_out_settled and
      after_f5_out == before_f5 and frame_rect(b) == before_f5 and
      f5_out_path_a == [after_f5, before_f5] and
      f5_out_path_b == [after_f5, before_f5])

# ------------------------------------------------ physical-frame contract

# A compact state path can lie by omission: the earlier version discarded
# every snapshot where neither the normal frame nor the icon parser matched.
# A ClearScreen therefore became ``None`` and vanished from the path, yielding
# green even though a human saw a flash.  Audit every actual terminal
# presentation below. Hardware-cursor-only updates change no cells; every
# other update must occupy one exact slot in the expected sequence.


def has_direct_clear(record):
    raw = record['raw']
    # Reject every ANSI operation capable of destroying cells, not only the
    # historical ESC[2J reproducer.  A clear followed by a redraw can leave
    # changed_cells == 0 while still producing a real visible flash.
    return (re.search(br'\x1b\[[0-?]*[ -/]*[JKXPLM@]', raw) is not None or
            b'\x1bc' in raw or b'\x1b#8' in raw)


def direct_printed_text(record):
    """Return visible text after removing complete terminal controls."""
    raw = record['raw']
    # OSC/DCS strings first, then CSI and ordinary two-byte ESC controls.
    raw = re.sub(br'\x1b\][^\x07]*(?:\x07|\x1b\\)', b'', raw,
                 flags=re.DOTALL)
    raw = re.sub(br'\x1bP.*?\x1b\\', b'', raw, flags=re.DOTALL)
    raw = re.sub(br'\x1b\[[0-?]*[ -/]*[@-~]', b'', raw)
    raw = re.sub(br'\x1b[ -/]*[@-Z\\-_]', b'', raw)
    raw = bytes(value for value in raw if value >= 32 and value != 127)
    return raw.decode('utf-8', 'replace')


def animation_tokens(records, old_rect, new_rect, rects, ring_base,
                     allow_zoom_control=False):
    tokens = []
    events = []
    ring_records = []
    for record in structural(records):
        control_token = (zoom_control_token(record, old_rect)
                         if allow_zoom_control else None)
        if control_token is not None:
            # Native press/release feedback is verified independently below;
            # it is not one of the animation's geometry presentations.
            continue
        matches = []
        for rect in rects:
            transition = ring_transition(record, rect)
            if transition is not None:
                phase, attrs = transition
                matches.append((phase, rect, attrs))
        if len(matches) == 1:
            phase, rect, attrs = matches[0]
            tokens.append(f'ring-{phase}-{ring_base}')
            events.append((phase, rect, attrs, record))
            ring_records.append(record)
        elif len(matches) > 1:
            tokens.append('sync-ambiguous-ring')
        elif record['kind'] != 'sync':
            tokens.append(record['kind'] + '-visual')
        elif has_lock(record):
            tokens.append('sync-lock')
        elif frame_rect(record) == old_rect:
            tokens.append('sync-old')
        elif frame_rect(record) == new_rect:
            tokens.append('sync-new')
        else:
            tokens.append('sync-unknown')
    return tokens, events, ring_records


def sequence_check(name, actual, expected):
    if actual != expected:
        print('  ' + name + ' actual  :', ' -> '.join(actual))
        print('  ' + name + ' expected:', ' -> '.join(expected))
    check(name, actual == expected)


def observer_layout_check(name, records, final_predicate,
                          allow_coalesced_lock=False):
    """Require at most one held-lock paint and one instant final paint.

    An instantaneous operation may place LOCK and the commit in the same
    socket-drain batch.  In that case the renderer correctly coalesces the
    obsolete lock and presents only the final state. Animated operations and
    held gestures have their own exact live-presentation oracles below.
    """
    updates = structural(records)
    final_only = (allow_coalesced_lock and len(updates) == 1 and
                  updates[0]['kind'] == 'sync' and
                  not has_lock(updates[0]) and final_predicate(updates[0]))
    lock_then_final = (len(updates) == 2 and
                       updates[0]['kind'] == 'sync' and
                       has_lock(updates[0]) and
                       updates[1]['kind'] == 'sync' and
                       not has_lock(updates[1]) and
                       final_predicate(updates[1]))
    ok = final_only or lock_then_final
    if not ok:
        print('  ' + name + ' structural updates:',
              [(record['kind'], record['changed_cells'], has_lock(record),
                pane_state(record), frame_rect(record)) for record in updates])
    check(name, ok)


def normalized_ring_events(events):
    return [(phase, rect, attrs) for phase, rect, attrs, _record in events]


def ring_pair_problems(events, old_rect, allow_first_lock_merge=False):
    """Reject hidden redraws inside a nominal show/hide pair.

    Each SHOW must be exactly the state consumed as the following HIDE, and a
    HIDE may change only cells on that ring.  The first observer SHOW of an
    expansion may atomically add the pane's shaded lock underneath the ring;
    even then, those extra cells are restricted to the old pane perimeter.
    """
    problems = []
    if len(events) != 16:
        return [f'event-count={len(events)} expected=16']
    old_edge = set(perimeter(old_rect))
    for index in range(8):
        show = events[index * 2]
        hide = events[index * 2 + 1]
        if show[0] != 'show' or hide[0] != 'hide' or show[1] != hide[1]:
            problems.append(f'step {index + 1}: show/hide order or rect differs')
            continue
        show_record = show[3]
        hide_record = hide[3]
        ring_edge = set(perimeter(show[1]))
        # Cursor/pane output remains live during the 45 ms hold. It may update
        # interior cells between two renderer transactions, but it must never
        # damage or replace the still-present composited ring.
        held_changes = cells_difference(show_record['cells'],
                                        hide_record['before_cells'])
        if held_changes & ring_edge:
            problems.append(f'step {index + 1}: live output changed held ring '
                            f'{sorted(held_changes & ring_edge)[:8]}')
        if not changed_positions(hide_record) <= ring_edge:
            extra = sorted(changed_positions(hide_record) - ring_edge)
            problems.append(f'step {index + 1}: hide changed outside ring '
                            f'{extra[:8]}')
        show_extra = changed_positions(show_record) - ring_edge
        if show_extra:
            if not (allow_first_lock_merge and index == 0 and
                    show_extra <= old_edge and has_lock(hide_record)):
                problems.append(f'step {index + 1}: show changed outside ring '
                                f'{sorted(show_extra)[:8]}')
    return problems


animation_specs = [
    ('maximize', zoom_a, zoom_b, before_zoom, after_zoom,
     zoom_frame_attr_a, zoom_frame_attr_b, 'old', True),
    ('unzoom', unzoom_a, unzoom_b, after_zoom, after_unzoom,
     unzoom_frame_attr_a, unzoom_frame_attr_b, 'new', False),
    ('fullscreen in', f5_in_a, f5_in_b, before_f5, after_f5,
     f5_in_frame_attr_a, f5_in_frame_attr_b, 'old', True),
    ('fullscreen out', f5_out_a, f5_out_b, after_f5, after_f5_out,
     f5_out_frame_attr_a, f5_out_frame_attr_b, 'new', False),
]

ring_surface_record_ids = set()
animation_results = {}
for (name, actor_records, observer_records, old_rect, new_rect,
     actor_attr, observer_attr, ring_base, expanding) in animation_specs:
    rects = animation_rects(old_rect, new_rect)
    actor_result = animation_tokens(actor_records, old_rect, new_rect,
                                    rects, ring_base, True)
    observer_result = animation_tokens(observer_records, old_rect, new_rect,
                                       rects, ring_base)
    animation_results[name] = actor_result, observer_result
    for record in actor_records + observer_records:
        if any(complete_ring_attrs(record['before_cells'], rect) is not None or
               complete_ring_attrs(record['cells'], rect) is not None
               for rect in rects):
            ring_surface_record_ids.add(id(record))

    expected_attr = (frozenset((actor_attr,))
                     if actor_attr is not None else None)
    expected_events = [
        (phase, rect, expected_attr)
        for rect in rects for phase in ('show', 'hide')
    ]
    actor_events = normalized_ring_events(actor_result[1])
    observer_events = normalized_ring_events(observer_result[1])
    if actor_events != expected_events:
        print(f'  {name} actor rings:', actor_events)
        print(f'  {name} expected rings:', expected_events)
    if observer_events != expected_events:
        print(f'  {name} observer rings:', observer_events)
        print(f'  {name} expected rings:', expected_events)
    check(name + ' clients use the same frame palette',
          actor_attr is not None and actor_attr == observer_attr)
    check(name + ' actor has exact 8 show + 8 hide rings',
          actor_events == expected_events)
    check(name + ' observer has exact 8 show + 8 hide rings',
          observer_events == expected_events)
    actor_pair_problems = ring_pair_problems(actor_result[1], old_rect)
    observer_pair_problems = ring_pair_problems(
        observer_result[1], old_rect, allow_first_lock_merge=expanding)
    if actor_pair_problems:
        print(f'  {name} actor ring-pair defects:', actor_pair_problems)
    if observer_pair_problems:
        print(f'  {name} observer ring-pair defects:', observer_pair_problems)
    check(name + ' actor ring pairs contain no hidden redraw',
          not actor_pair_problems)
    check(name + ' observer ring pairs contain no hidden redraw',
          not observer_pair_problems)
    check(name + ' actor and observer ring streams are identical',
          actor_events == observer_events)


all_captures = {
    'minimize actor': min_a,
    'minimize observer': min_b,
    'restore actor': restore_a,
    'restore observer': restore_b,
    'maximize actor': zoom_a,
    'maximize observer': zoom_b,
    'unzoom actor': unzoom_a,
    'unzoom observer': unzoom_b,
    'move actor': move_a,
    'move observer': move_b,
    'resize actor': resize_a,
    'resize observer': resize_b,
    'fullscreen in actor': f5_in_a,
    'fullscreen in observer': f5_in_b,
    'fullscreen out actor': f5_out_a,
    'fullscreen out observer': f5_out_b,
}

surfaces_ok = True
directs_ok = True
for capture_name, records in all_captures.items():
    for index, record in enumerate(records):
        ring_frame = id(record) in ring_surface_record_ids
        surface = (pane_state(record) is not None or has_lock(record) or
                   ring_frame)
        if record['changed_cells'] > 0 and not surface:
            surfaces_ok = False
            print(f'  missing surface: {capture_name}[{index}] '
                  f'{record["kind"]} changed={record["changed_cells"]}')
        if record['kind'] == 'direct':
            # The outline compositor is synchronized now. Outside DEC 2026,
            # only terminal mode/cursor controls are legal: no visible glyph,
            # no changed cell and no destructive clear even if a later redraw
            # happens to reconstruct the same final screen.
            printed = direct_printed_text(record)
            if (has_direct_clear(record) or
                    record['changed_cells'] != 0 or printed):
                directs_ok = False
                print(f'  bad direct: {capture_name}[{index}] '
                      f'changed={record["changed_cells"]} '
                      f'clear={has_direct_clear(record)} '
                      f'printed={printed!r}')

check('every presented update keeps surface', surfaces_ok)
check('direct writes are nonvisual and never clear', directs_ok)

# Instant actor operations have exactly one structural presentation. This is
# stronger than old->new: it rejects new->focus-old->focus-new repaints even
# though the geometry parser reports ``window`` for all three.
min_struct = structural(min_a)
restore_struct = structural(restore_a)
check('minimize actor has one physical paint',
      len(min_struct) == 1 and min_struct[0]['kind'] == 'sync' and
      pane_state(min_struct[0]) == 'icon')
if len(restore_struct) != 1:
    print('  restore structural updates:',
          [(record['kind'], record['changed_cells'], pane_state(record))
           for record in restore_struct])
check('restore actor has one physical paint',
      len(restore_struct) == 1 and restore_struct[0]['kind'] == 'sync' and
      frame_rect(restore_struct[0]) == baseline_a)

# Every non-owner sees precisely the held lock and the single canonical
# layout commit.  Repeated final paints, a content resize before the layout,
# or a missing lock are all observable protocol regressions even if the
# settled screen is correct.
observer_layout_check('minimize observer lock then final', min_b,
                      lambda record: pane_state(record) == 'icon', True)
observer_layout_check('restore observer lock then final', restore_b,
                      lambda record: frame_rect(record) == baseline_a, True)

# The only actor-side updates outside the geometry sequence are FreeVision's
# exact one-cell zoom-button press and release. Assert them explicitly, then
# audit the animation independently.
check('maximize native zoom feedback is exact',
      [zoom_control_token(record, before_zoom) for record in zoom_a
       if zoom_control_token(record, before_zoom) is not None] ==
      ['sync-zoom-down', 'sync-zoom-up'])
check('unzoom native zoom feedback is exact',
      [zoom_control_token(record, after_zoom) for record in unzoom_a
       if zoom_control_token(record, after_zoom) is not None] ==
      ['sync-zoom-down', 'sync-zoom-up'])

# Expansion paints each ring over the old surface, removes it back to old, then
# publishes the canonical final geometry. Contraction publishes final first,
# then paints/removes every ring over that new surface. Actor and observer have
# exactly the same synchronized presentations.
expanding = ['ring-show-old', 'ring-hide-old'] * 8 + ['sync-new']
contracting = ['sync-new'] + ['ring-show-new', 'ring-hide-new'] * 8
for name in ('maximize', 'fullscreen in'):
    actor_result, observer_result = animation_results[name]
    sequence_check(name + ' actor exact physical sequence',
                   actor_result[0], expanding)
    sequence_check(name + ' observer exact physical sequence',
                   observer_result[0], expanding)
for name in ('unzoom', 'fullscreen out'):
    actor_result, observer_result = animation_results[name]
    sequence_check(name + ' actor exact physical sequence',
                   actor_result[0], contracting)
    # The observer's lease paint may be its own completed transaction or may
    # be coalesced into the immediately following canonical contraction. Both
    # are exact, valid presentations; permit precisely one optional leading
    # lock and no other insertion, rollback or duplicate frame.
    observer_contracting = observer_result[0]
    observer_expected = (contracting if observer_contracting == contracting
                         else ['sync-lock'] + contracting)
    sequence_check(name + ' observer exact physical sequence',
                   observer_contracting, observer_expected)


def gesture_layout_events(records):
    """Return only actual geometry/lease presentations, not pane output."""
    events = []
    for record in structural(records):
        before_value = cells_value(record['before_cells'])
        before_rect = frame_rect(before_value)
        after_rect = frame_rect(record)
        before_lock = has_lock(before_value)
        after_lock = has_lock(record)
        if before_rect != after_rect or before_lock != after_lock:
            events.append((record['kind'], before_rect, after_rect,
                           before_lock, after_lock))
    return events


def gesture_physical_check(name, actor_records, observer_records, rects):
    actor_actual = gesture_layout_events(actor_records)
    observer_actual = gesture_layout_events(observer_records)
    actor_expected = [
        ('sync', rects[index - 1], rects[index], False, False)
        for index in range(1, len(rects))
    ]
    observer_expected = (
        [('sync', rects[0], rects[0], False, True)] +
        [('sync', rects[index - 1], rects[index], True, True)
         for index in range(1, len(rects))] +
        [('sync', rects[-1], rects[-1], True, False)] if rects else [])
    if actor_actual != actor_expected:
        print(f'  {name} actor structural updates:', actor_actual)
        print(f'  {name} actor expected:', actor_expected)
    if observer_actual != observer_expected:
        print(f'  {name} observer structural updates:', observer_actual)
        print(f'  {name} observer expected:', observer_expected)
    check(name + ' actor has no rollback or duplicate paint',
          actor_actual == actor_expected)
    check(name + ' observer previews all steps locked then unlocks final',
          observer_actual == observer_expected)


gesture_physical_check('move', move_a, move_b, expected_move_rects)
gesture_physical_check('resize', resize_a, resize_b, expected_resize_rects)

for client in (b, a):
    client.send(b'\x11', 0.08)
    client.send(b'd', 0.30)
    client.wait_exit(timeout=4.0)
    client.close()
stlib.close_all_daemons(HOME)
stlib.report()
