#!/usr/bin/env python3
"""Palette changes and local viewport resizes preserve one coherent surface.

The final menu mark is not evidence: the reported resize bug kept
"Monochrome" checked while FreeVision had silently reset AppPalette to colour.
This test observes the attributes actually presented by the renderer.

SUPERTERM_SYNC makes every buffered renderer update a DEC-2026 transaction.
The live palette path can use stlib's normal transition capture because the
terminal dimensions stay fixed.  A host resize needs a small offline replay:
the terminal emulator changes geometry *before* it receives SuperTerm's next
bytes, so the replay model is resized at exactly that boundary and every
synchronized or direct presentation is then inspected separately.
"""
import os
import re
import sys
import time
from collections import Counter

sys.path.insert(0, os.path.dirname(__file__))
import pyte  # noqa: E402
import stlib  # noqa: E402
from stlib import check  # noqa: E402


OLD_W, OLD_H = 100, 30
NEW_W, NEW_H = 112, 34
SYNC_START = b'\x1b[?2026h'
SYNC_END = b'\x1b[?2026l'
CHROMATIC = {
    'blue', 'brightblue', 'green', 'brightgreen', 'cyan', 'brightcyan',
    'red', 'brightred', 'magenta', 'brightmagenta', 'brown', 'yellow',
}

HOME = stlib.fresh_home('palette-resize-transition')
INI = HOME + '/.superterm/superterm.ini'
with open(INI, 'w') as fh:
    fh.write('[ui]\n'
             'language=en\n'
             'palette=color\n'
             'background=none\n'
             'solid_background=1\n'
             '[session]\n'
             'server=always\n'
             'autosave=0\n'
             'autorestore=0\n'
             '[class.palette-test]\n'
             'name=palette-test\n'
             'enabled=1\n'
             'type=local\n'
             'title=PALETTE FIXED\n'
             'cmd=\n')

ENV = {'SUPERTERM_SYNC': '1'}
c = stlib.Client(HOME, w=OLD_W, h=OLD_H, lang='en', env=ENV)


def display_of(value):
    if isinstance(value, dict):
        return value['display']
    return value.screen.display


def cells_of(value):
    if isinstance(value, dict):
        return value['cells']
    return tuple(tuple(value.screen.buffer[y][x] for x in range(value.w))
                 for y in range(value.h))


def char_attr(char):
    return (char.fg, char.bg, char.bold, char.italics, char.underscore,
            char.strikethrough, char.reverse, char.blink)


def active_frame_attr(value):
    """Attribute of the visible active-frame corner, never a menu flag."""
    rows = display_of(value)
    cells = cells_of(value)
    for y, row in enumerate(rows):
        x = row.find('╔')
        if x >= 0:
            return char_attr(cells[y][x])
    return None


def active_frame_rect(value):
    """Bounds of the active double-line frame in a complete surface."""
    rows = display_of(value)
    for top, row in enumerate(rows):
        title_x = row.find('PALETTE FIXED')
        if title_x < 0:
            continue
        lefts = [x for x, char in enumerate(row[:title_x])
                 if char in ('╔', '┌')]
        rights = [x for x, char in enumerate(
            row[title_x + len('PALETTE FIXED'):],
            title_x + len('PALETTE FIXED')) if char in ('╗', '┐')]
        if not lefts or not rights:
            continue
        left, right = max(lefts), min(rights)
        for bottom in range(top + 1, len(rows)):
            if (left < len(rows[bottom]) and right < len(rows[bottom]) and
                    rows[bottom][left] in ('╚', '└') and
                    rows[bottom][right] in ('╝', '┘')):
                return left, top, right, bottom
    return None


def has_complete_surface(value):
    rows = display_of(value)
    return (bool(rows) and 'Panes' in rows[0] and
            active_frame_attr(value) is not None and
            any('F2 Split' in row for row in rows))


def compact(values):
    result = []
    for value in values:
        if value is not None and (not result or result[-1] != value):
            result.append(value)
    return result


def is_chromatic(attr):
    return attr is not None and (attr[0] in CHROMATIC or
                                 attr[1] in CHROMATIC)


def changed_records(records):
    return [record for record in records
            if record['changed_cells'] > 0 and
            not stlib.cursor_only_transition(record)]


def material_records(records):
    """Structural changes plus a resent, visually identical large frame."""
    return [record for record in records
            if ((record['changed_cells'] > 0 and
                 not stlib.cursor_only_transition(record)) or
                len(record['raw']) > 512)]


def has_direct_clear(record):
    """Catch destructive terminal operations even if a redraw hides them."""
    raw = record['raw']
    return (re.search(br'\x1b\[[0-?]*[ -/]*[JKXPLM@]', raw) is not None or
            b'\x1bc' in raw or b'\x1b#8' in raw)


def direct_printed_text(record):
    """Return visible bytes left after removing complete terminal controls."""
    raw = record['raw']
    raw = re.sub(br'\x1b\][^\x07]*(?:\x07|\x1b\\)', b'', raw,
                 flags=re.DOTALL)
    raw = re.sub(br'\x1bP.*?\x1b\\', b'', raw, flags=re.DOTALL)
    raw = re.sub(br'\x1b\[[0-?]*[ -/]*[@-~]', b'', raw)
    raw = re.sub(br'\x1b[ -/]*[@-Z\\-_]', b'', raw)
    raw = bytes(value for value in raw if value >= 32 and value != 127)
    return raw.decode('utf-8', 'replace')


def direct_output_ok(records):
    """Only cursor/mode controls may escape DEC synchronized output."""
    return all(not has_direct_clear(record) and
               record['changed_cells'] == 0 and
               not direct_printed_text(record)
               for record in records if record['kind'] == 'direct')


def diff_details(record):
    """Describe where and how a presentation changed for race diagnostics."""
    changed = []
    for y, (before_row, after_row) in enumerate(
            zip(record['before_cells'], record['cells'])):
        for x, (before, after) in enumerate(zip(before_row, after_row)):
            if before != after:
                changed.append((x, y, before, after))

    row_spans = []
    for y in sorted({item[1] for item in changed}):
        xs = [item[0] for item in changed if item[1] == y]
        row_spans.append((y, min(xs), max(xs), len(xs)))

    char_changes = Counter(
        (before.data, after.data)
        for _, _, before, after in changed
        if before.data != after.data)
    attr_changes = Counter(
        (char_attr(before), char_attr(after))
        for _, _, before, after in changed
        if char_attr(before) != char_attr(after))
    return (row_spans, char_changes.most_common(12), len(char_changes),
            attr_changes.most_common())


def print_records(label, records):
    print('  ' + label + ' presentations:')
    for index, record in enumerate(records):
        changed_xy = [
            (x, y)
            for y, (before_row, after_row) in enumerate(
                zip(record['before_cells'], record['cells']))
            for x, (before, after) in enumerate(zip(before_row, after_row))
            if before != after
        ]
        if changed_xy:
            xs = [point[0] for point in changed_xy]
            ys = [point[1] for point in changed_xy]
            bounds = (min(xs), min(ys), max(xs), max(ys))
        else:
            bounds = None
        rows, chars, char_kinds, attrs = diff_details(record)
        print('   ', index, record['kind'],
              'changed=' + str(record['changed_cells']),
              'bytes=' + str(len(record['raw'])),
              'bounds=' + repr(bounds),
              'attr=' + repr(active_frame_attr(record)),
              'surface=' + str(has_complete_surface(record)),
              'clear=' + str(has_direct_clear(record)),
              'printed=' + repr(direct_printed_text(record)
                                if record['kind'] == 'direct' else ''))
        if changed_xy:
            print('      rows(y,min-x,max-x,count)=', rows)
            print('      chars(top/distinct)=', chars, '/', char_kinds)
            print('      attrs=', attrs)


def screen_cells(screen, width, height):
    return tuple(tuple(screen.buffer[y][x] for x in range(width))
                 for y in range(height))


def replay_resized_output(raw_before, raw_after):
    """Return every physical presentation after OLD -> NEW host geometry."""
    screen = pyte.Screen(OLD_W, OLD_H)
    stream = pyte.ByteStream(screen)
    parse_ok = stlib.feed_pyte(stream, raw_before, 'palette replay')
    parse_ok = stlib.flush_pyte(stream, 'palette replay') and parse_ok
    screen.resize(lines=NEW_H, columns=NEW_W)

    before = screen_cells(screen, NEW_W, NEW_H)
    records = []

    def feed(kind, raw):
        nonlocal before, parse_ok
        if not raw:
            return
        if not stlib.feed_pyte(stream, raw, 'palette replay'):
            parse_ok = False
        if not stlib.flush_pyte(stream, 'palette replay'):
            parse_ok = False
        after = screen_cells(screen, NEW_W, NEW_H)
        changed = sum(before[y][x] != after[y][x]
                      for y in range(NEW_H) for x in range(NEW_W))
        records.append({
            'kind': kind,
            'display': tuple(screen.display),
            'cells': after,
            'before_cells': before,
            'changed_cells': changed,
            'cursor': (screen.cursor.x, screen.cursor.y),
            'raw': raw,
        })
        before = after

    pos = 0
    while pos < len(raw_after):
        start = raw_after.find(SYNC_START, pos)
        if start < 0:
            feed('direct', raw_after[pos:])
            pos = len(raw_after)
            break
        if start > pos:
            feed('direct', raw_after[pos:start])
        finish = raw_after.find(SYNC_END, start + len(SYNC_START))
        if finish < 0:
            parse_ok = False
            feed('incomplete', raw_after[start:])
            pos = len(raw_after)
            break
        finish += len(SYNC_END)
        feed('sync', raw_after[start:finish])
        pos = finish
    return records, parse_ok


try:
    ready = c.wait_until(lambda text: 'Options' in text and '╔' in text,
                         timeout=12.0)
    check('colour workspace is ready', ready and has_complete_surface(c))
    color_attr = active_frame_attr(c)
    check('baseline frame is rendered in colour', is_chromatic(color_attr))

    # Open Options -> Color palette using only keyboard accelerators.  Menu
    # navigation is outside the capture; the contract starts with the one 'm'
    # key which chooses Monochrome.  No click or subsequent input is allowed to
    # make the palette finally take effect.
    c.send(b'\x1bo', 0.45)
    c.send(b'p', 0.45)
    check('keyboard opens palette submenu', 'Monochrome' in c.text())
    c.begin_transition_capture()
    os.write(c.fd, b'm')
    deadline = time.monotonic() + 4.0
    while time.monotonic() < deadline and active_frame_attr(c) == color_attr:
        c.drain(0.10)
    # Keep observing after the first mono frame: a delayed duplicate or colour
    # rollback is part of the same user-visible action.
    c.drain(0.75)
    palette_records = c.end_transition_capture()
    mono_attr = active_frame_attr(c)

    palette_path = compact([color_attr] +
                           [active_frame_attr(record)
                            for record in palette_records] + [mono_attr])
    palette_changed = changed_records(palette_records)
    palette_direct_ok = direct_output_ok(palette_records)
    mono_indexes = [index for index, record in enumerate(palette_records)
                    if active_frame_attr(record) == mono_attr]
    first_mono = mono_indexes[0] if mono_indexes else len(palette_records)
    final_material = material_records(palette_records[first_mono:])
    palette_ok = (
        mono_attr is not None and not is_chromatic(mono_attr) and
        mono_attr != color_attr and palette_path == [color_attr, mono_attr] and
        all(has_complete_surface(record) for record in palette_changed) and
        palette_direct_ok and
        len(final_material) == 1 and final_material[0]['kind'] == 'sync' and
        active_frame_attr(final_material[0]) == mono_attr)
    if not palette_ok:
        print('  palette attribute path:', palette_path)
        print_records('palette', palette_records)
    check('keyboard palette applies immediately',
          mono_attr is not None and mono_attr != color_attr and
          not is_chromatic(mono_attr))
    check('palette transition has no flash/blank',
          palette_path == [color_attr, mono_attr] and
          all(has_complete_surface(record) for record in palette_changed))
    check('palette has no direct visual output', palette_direct_ok)
    check('palette has one final repaint',
          len(final_material) == 1 and
          final_material[0]['kind'] == 'sync' and
          active_frame_attr(final_material[0]) == mono_attr)
    check('monochrome choice persists', 'palette=mono' in open(INI).read())

    # Drain before taking the byte boundary so no pre-resize cursor blink is
    # accidentally replayed on the new geometry.  Client.resize performs the
    # real TIOCSWINSZ and resizes the live pyte model at the same instant.
    c.drain(0.30)
    mono_rect = active_frame_rect(c)
    raw_before = c.raw()
    raw_offset = len(raw_before)
    c.resize(NEW_W, NEW_H, seconds=0.0)
    c.drain(2.0)
    raw_after = c.raw()[raw_offset:]
    resize_records, resize_parse_ok = replay_resized_output(raw_before,
                                                            raw_after)
    resize_changed = changed_records(resize_records)
    resize_material = material_records(resize_records)
    resize_direct_ok = direct_output_ok(resize_records)
    resize_path = compact([mono_attr] +
                          [active_frame_attr(record)
                           for record in resize_records] +
                          [active_frame_attr(c)])
    resize_rects = [active_frame_rect(record)
                    for record in resize_material]
    settled_rect = active_frame_rect(c)
    resize_geometry_ok = (
        len(resize_material) == 1 and
        resize_material[0]['kind'] == 'sync' and
        resize_rects == [mono_rect] and
        mono_rect is not None and settled_rect == mono_rect)
    resize_ok = (
        resize_parse_ok and resize_records and
        active_frame_attr(c) == mono_attr and resize_path == [mono_attr] and
        all(has_complete_surface(record) for record in resize_changed) and
        resize_direct_ok and
        resize_geometry_ok)
    if not resize_ok:
        print('  resize attribute path:', resize_path)
        print('  resize frame path:', mono_rect, resize_rects,
              settled_rect)
        print_records('resize', resize_records)
    check('resize stream is completely parsed',
          resize_parse_ok and bool(resize_records))
    check('host resize preserves mono attributes',
          active_frame_attr(c) == mono_attr and resize_path == [mono_attr])
    check('host resize never presents empty frame',
          all(has_complete_surface(record) for record in resize_changed))
    check('host resize has no direct visual output', resize_direct_ok)
    # SIGWINCH is now presentation-only. FreeVision adopts the new physical
    # viewport in one synchronized repaint while retaining the exact canonical
    # frame; no later server layout publication may scale it a second time.
    check('host resize publishes one fixed-canonical viewport',
          resize_geometry_ok)
finally:
    # Detach the UI, then close the isolated daemon through stlib's protocol.
    c.send(b'\x11', 0.08)
    c.send(b'd', 0.25)
    c.wait_exit(timeout=5.0)
    c.close()
    stlib.close_all_daemons(HOME)

stlib.report()
