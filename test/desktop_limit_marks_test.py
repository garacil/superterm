#!/usr/bin/env python3
"""The dead area outside the canonical desktop is marked, and marked locally.

A viewer whose terminal is larger than the shared logical desktop has an
L-shaped band that is not workspace. This suite checks the three properties
that make that band readable rather than merely dark:

* the CP437 shades 178/177/176 screen it, solid against the desktop edge and
  thinning outward through a scattered mix of each neighbouring pair, never
  inside the canonical rectangle;
* the word in it is reverse video: its strokes are cells left unpainted and
  the screen running through and around them is what forms the letters;
* it is client-side chrome. Two viewers of different physical sizes mark
  different extents while the daemon's canonical desktop and pane geometry
  stay byte-identical, and the preference is one INI key with a menu toggle.
"""
import configparser
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, run_cli


HOME = stlib.fresh_home('desktop-limit-marks-' + str(os.getpid()))
INI = HOME + '/.superterm/superterm.ini'
SESSION_INI = HOME + '/.superterm/session.ini'
SESSION = 'limitmarks'
DESK = (60, 28)              # canonical desktop, smaller than both viewers
BIG = (120, 40)              # first viewer
SMALL = (100, 34)            # second viewer, still larger than the desktop
DENSE, MID, FAINT = '▓', '▒', '░'    # 178, 177, 176
SHADES = (DENSE, MID, FAINT)
GLYPH_H = 5                  # st_deskedge.GLYPH_H

with open(INI, 'w', encoding='utf-8') as stream:
    stream.write('[ui]\nlanguage=en\nbackground=none\n'
                 '[session]\nserver=always\nautosave=0\nautorestore=1\n'
                 'zoomanim=0\n')

with open(SESSION_INI, 'w', encoding='utf-8') as stream:
    stream.write(f'''[layout]
nodes=L
count=1
focused=0
deskw={DESK[0]}
deskh={DESK[1]}

[pane0]
cmd=
cwd={HOME}
term=
argc=0
bx=2
by=1
bw=40
bh=10
''')


def toggle_limit_marks(client):
    client.send(b'\x1bd', 0.0)
    if not client.wait_until(
            lambda text: 'Mark the desktop limit' in text, 4.0):
        return False
    client.send(b'l', 0.0)
    return client.wait_until(
        lambda text: 'Mark the desktop limit' not in text, 5.0)


def shown_desktop(client, expected):
    client.send(b'\x1bd', 0.0)
    opened = client.wait_until(
        lambda text: 'Show current dimensions' in text, 5.0)
    if opened:
        client.send(b's', 0.0)
    shown = client.wait_until(
        lambda text: f'Logical desktop: {expected[0]}x{expected[1]}' in text,
        5.0)
    if shown:
        client.send(b'\r', 0.0)
        client.wait_until(lambda text: 'Logical desktop:' not in text, 5.0)
    return opened and shown


def ini_limit_marks():
    parser = configparser.ConfigParser(interpolation=None)
    try:
        parser.read(INI)
        return parser.get('ui', 'desktop_limit_marks', fallback=None)
    except (configparser.Error, OSError):
        return None


def band(client):
    """The backdrop rows: the menu row is above and the status row below."""
    rows = client.screen.display
    return rows[1:len(rows) - 1]


def margin_cells(client):
    """Every (x, y, char) the viewer paints outside the canonical rectangle."""
    return [(x, y, char)
            for y, row in enumerate(band(client))
            for x, char in enumerate(row)
            if x >= DESK[0] or y >= DESK[1]]


def inside_marks(client):
    """Shade cells inside the canonical rectangle.

    Not zero: a window's own scrollbar trough is CP437 178. The oracle is that
    this set is the same whether the dead area is marked or not, which is what
    proves the marking never reaches inside.
    """
    return {(x, y)
            for y, row in enumerate(band(client))
            for x, char in enumerate(row)
            if x < DESK[0] and y < DESK[1] and char in SHADES}


def marked_cells(client):
    return {(x, y) for x, y, char in margin_cells(client) if char in SHADES}


def has_marks(client):
    return any(char in SHADES for _x, _y, char in margin_cells(client))


def pane_geometry():
    result = run_cli(['list', SESSION], HOME, env={'LANG': 'C'})
    if result.returncode != 0:
        return None
    return [line for line in result.stdout.splitlines()
            if line and line[0].isdigit()]


# ---------------------------------------------------------------- first viewer
a = stlib.Client(HOME, args=['--session', SESSION], w=BIG[0], h=BIG[1],
                 lang='en')
a.drain(3.0)
check('the saved canonical desktop is smaller than the viewer',
      shown_desktop(a, DESK))
check('the dead area outside it is marked',
      a.wait_until(lambda _text: has_marks(a), 5.0))
inside_while_marked = inside_marks(a)

rows = band(a)
right_row = rows[0]
bottom_col = [row[0] for row in rows]
check('all three shades screen the right band',
      set(SHADES) <= set(right_row[DESK[0]:]))
check('the right band is solid against the desktop and faintest outside',
      right_row[DESK[0]] == DENSE and right_row[-1] == FAINT)
check('all three shades screen the bottom band',
      set(SHADES) <= set(bottom_col[DESK[1]:]))
check('the bottom band is solid against the desktop and faintest outside',
      bottom_col[DESK[1]] == DENSE and bottom_col[-1] == FAINT)

# Between the two solid runs the codes must interleave cell by cell. Three
# flat stripes, or any ramp that steps straight from a run of one code to a
# run of the next, leave far too few transitions to pass this.
mixes = [x for x in range(DESK[0], len(right_row) - 1)
         if right_row[x] != right_row[x + 1] and
         right_row[x] in SHADES and right_row[x + 1] in SHADES]
check('the codes scatter into each other instead of changing in blocks',
      len(mixes) >= 8)

# ------------------------------------------------------------ reverse video
# A letter stroke is a cell left unpainted; it reads as a letter only because
# the screen runs around it. Assert that, without duplicating the font here.
holes = [(x, y) for x, y, char in margin_cells(a) if char == ' ']
enclosed = [(x, y) for x, y in holes
            if any(c in SHADES for c in rows[y][:x]) and
            any(c in SHADES for c in rows[y][x + 1:])]
check('the word is knocked out of the screen, not drawn on it',
      len(holes) >= 30 and enclosed == holes)
check('every stroke is enclosed by the screen on its own row',
      len(enclosed) >= 30)
check('the word is tall enough to be block letters',
      len({y for _x, y in holes}) >= GLYPH_H)

# --------------------------------------------------------------- second viewer
before = pane_geometry()
b = stlib.Client(HOME, args=['--attach', SESSION], w=SMALL[0], h=SMALL[1],
                 lang='en')
b.drain(3.0)
check('a second viewer attaches and marks its own dead area',
      b.alive() and b.wait_until(lambda _text: has_marks(b), 5.0))
check('the second viewer keeps the same canonical desktop',
      shown_desktop(b, DESK))
check('the two viewers mark different extents',
      marked_cells(a) != marked_cells(b))
check('marking a dead area changes no shared geometry',
      before is not None and pane_geometry() == before)

# ---------------------------------------------------------------- the toggle
check('the Desktop menu turns the marks off', toggle_limit_marks(a))
check('the dead area goes back to the flat fill',
      a.wait_until(lambda _text: not has_marks(a), 5.0))
check('the canonical rectangle is untouched by the marking',
      inside_marks(a) == inside_while_marked)
check('turning them off changes no shared geometry',
      pane_geometry() == before)
check('the preference is saved as one [ui] key',
      ini_limit_marks() in ('0', 'false', 'False'))
check('the Desktop menu turns the marks back on', toggle_limit_marks(a))
check('the marks return', a.wait_until(lambda _text: has_marks(a), 5.0))
check('the preference is saved back on',
      ini_limit_marks() in ('1', 'true', 'True'))

a.close()
b.close()
stlib.close_all_daemons(HOME)
stlib.report()
