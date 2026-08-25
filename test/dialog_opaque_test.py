#!/usr/bin/env python3
"""superterm test: a dialog drawn over a desktop picture is opaque.

The picture is painted as coloured cells rather than block glyphs, which is
what stops a terminal font's imperfect U+2588 from leaving hairlines through
it. The word left in the grid is still the block, on purpose: that word is
the overlay's oracle, and 'a space in some attribute' is a word every dialog
and menu writes too -- registering the picture under it made a dialog match
by coincidence and bring the picture back through its own body, in colour.

Checked by colour: the picture's cells are truecolor, the chrome's are not,
so nothing truecolor may appear inside a dialog that has no colours of its
own.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check

INI = ('[ui]\nlanguage=en\nbackground=london\nbackground_mode=center\n'
       'palette=%s\n[session]\nautorestore=0\nautosave=0\n'
       '[class.demo]\nname=demo\nenabled=0\ntitle=demo\n'
       'host=10.0.0.2\nuser=deploy\n'
       '[profile.daily]\nname=daily\nenabled=1\n')


def truecolor_inside(c, title, height=16):
    """count picture-coloured cells inside the dialog whose title is given"""
    # from row 2 down, and only a row that carries a frame: the menu bar has
    # words like 'Profiles' in it too, and measuring that row measures the
    # desktop
    rows = [y for y in range(2, c.h)
            if title in c.screen.display[y] and
            (('═' in c.screen.display[y]) or ('─' in c.screen.display[y]))]
    if not rows:
        return None
    top = rows[0]
    line = c.screen.display[top]
    # The dialog's extent is its FRAME, walked out from the title. Taking
    # "everything that is not a space" was right only while a picture was
    # made of spaces on coloured backgrounds; drawn with a shade character it
    # covers the row, and the box became the whole screen.
    FRAME = set('═─╔╗┌┐║│[]■ ')
    mid = line.index(title)
    x0 = mid
    while x0 > 0 and (line[x0 - 1] in FRAME or line[x0 - 1] == title[0]):
        x0 -= 1
    x1 = mid + len(title) - 1
    while x1 < len(line) - 1 and line[x1 + 1] in FRAME:
        x1 += 1
    # a run of blanks means we walked off the dialog and into the desktop
    while x0 < mid and line[x0] == ' ' and line[x0 + 1] == ' ':
        x0 += 1
    while x1 > mid and line[x1] == ' ' and line[x1 - 1] == ' ':
        x1 -= 1
    n = 0
    for y in range(top, min(c.h, top + height)):
        for x in range(x0, x1 + 1):
            cell = c.screen.buffer[y][x]
            for v in (cell.fg, cell.bg):
                if len(v) == 6 and v != '000000':
                    try:
                        int(v, 16)
                    except ValueError:
                        continue
                    n += 1
    return n


for palette in ('color', 'mono'):
    HOME = stlib.fresh_home('dlgopaque' + palette)
    os.makedirs(HOME + '/.superterm', exist_ok=True)
    with open(HOME + '/.superterm/superterm.ini', 'w') as f:
        f.write(INI % palette)

    c = stlib.Client(HOME, w=128, h=48, lang='en')
    c.drain(3.0)
    c.send(b'\x1b[20;3~', 1.2)          # Alt-F9: minimise, the picture shows
    check('%s: the picture is on the desktop' % palette,
          any(len(cell.bg) == 6 and cell.bg != '000000'
              for y in range(4, 40) for cell in [c.screen.buffer[y][40]]) or
          any(len(c.screen.buffer[y][x].bg) == 6
              for y in range(4, 40) for x in range(0, 128, 7)))

    # the class manager
    c.send(b'\x1b[<0;20;1M', 0.2)
    c.send(b'\x1b[<0;20;1m', 0.8)
    c.send(b'm', 2.0)
    n = truecolor_inside(c, 'Window classes')
    check('%s: the class manager is opaque' % palette, n == 0)
    c.send(b'\x1b', 0.6)

    # the profile manager
    c.send(b'\x1b[<0;29;1M', 0.2)
    c.send(b'\x1b[<0;29;1m', 0.8)
    c.send(b'm', 2.0)
    n = truecolor_inside(c, 'Profiles')
    check('%s: the profile manager is opaque' % palette, n == 0)
    c.send(b'\x1b', 0.6)

    # the session wizard
    c.send(b'\x1b[<0;38;1M', 0.2)
    c.send(b'\x1b[<0;38;1m', 0.8)
    c.send(b'w', 2.0)
    n = truecolor_inside(c, 'Session wizard', 8)
    check('%s: the wizard is opaque' % palette, n == 0)
    c.send(b'\x1b', 0.6)

    c.send(b'\x1bx', 0.8)
    try:
        c.wait_exit(timeout=6)
    except Exception:
        pass
    stlib.close_all_daemons(HOME)

stlib.report()
