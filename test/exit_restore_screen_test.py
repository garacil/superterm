#!/usr/bin/env python3
"""superterm test: leaving gives the shell its screen back.

superterm works on the terminal's alternate screen, so quitting or detaching
puts back what the shell had on the screen, with the cursor on the line after
the command that started it. FPC's video driver only enters the alternate
screen for the TERM names in its own table (xterm, screen, rxvt, konsole,
gnome, eterm); for every other -- tmux-256color inside tmux, alacritty, foot,
st -- superterm painted over the shell's screen and left its desktop there
on exit. A fullscreen round trip made it worse: reclaiming the screen enters
the alternate screen by hand, and nothing ever left it.

pyte has no alternate screen, so the terminal here adds one with xterm's
?1049 semantics: save the cursor and switch to a cleared buffer; switch back
and restore the cursor.
"""
import copy
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pyte
import stlib
from stlib import FULLSCREEN_CHORD, check

W, H = 100, 30
SHELL = [b'BEFORE one', b'BEFORE two', b'$ superterm']
ALT_MODES = (47, 1047, 1049)


class AltScreen(pyte.Screen):
    """A pyte screen with xterm's alternate screen buffer."""

    def __init__(self, columns, lines):
        super().__init__(columns, lines)
        self.in_alt = False
        self._normal = None

    def set_mode(self, *modes, **kwargs):
        if kwargs.get('private') and any(m in ALT_MODES for m in modes):
            if not self.in_alt:
                self._normal = (copy.deepcopy(self.buffer),
                                copy.copy(self.cursor))
                self.in_alt = True
                self.erase_in_display(2)
            modes = tuple(m for m in modes if m not in ALT_MODES)
            if not modes:
                return
        super().set_mode(*modes, **kwargs)

    def reset_mode(self, *modes, **kwargs):
        if kwargs.get('private') and any(m in ALT_MODES for m in modes):
            if self.in_alt:
                self.buffer, self.cursor = self._normal
                self._normal = None
                self.in_alt = False
                self.dirty.update(range(self.lines))
            modes = tuple(m for m in modes if m not in ALT_MODES)
            if not modes:
                return
        super().reset_mode(*modes, **kwargs)


def run(term, leave, fullscreen):
    label = '%s %s%s' % (term, leave, ' after fullscreen' if fullscreen else '')
    home = stlib.fresh_home('exit-restore')
    with open(os.path.join(home, '.superterm', 'superterm.ini'), 'w') as f:
        f.write('[ui]\nlanguage=en\nbackground=none\n'
                '[session]\nserver=always\nautosave=0\nautorestore=0\n')
    gate_read, gate_write = os.pipe()
    # The shell's cursor is on the line after its command when it starts us:
    # row 4, column 1 is what the terminal answers to the position query.
    c = stlib.Client(home, w=W, h=H, env={'TERM': term},
                     start_gate_fd=gate_read, dsr_row=len(SHELL) + 1,
                     dsr_col=1)
    os.close(gate_read)
    c.screen = AltScreen(W, H)
    c.stream = pyte.ByteStream(c.screen)
    c.stream.feed(b'\r\n'.join(SHELL) + b'\r\n')
    os.write(gate_write, b'1')
    os.close(gate_write)
    try:
        check(label + ': superterm starts',
              c.wait_until(lambda t: 'Detach' in t, 10.0))
        check(label + ': the desktop is on the alternate screen',
              c.screen.in_alt)
        if fullscreen:
            c.send(FULLSCREEN_CHORD, 1.4)
            c.send(FULLSCREEN_CHORD, 1.4)
        if leave == 'quit':
            c.send(b'\x11x', 1.5)
        else:
            c.send(b'\x11', 0.4)
            c.send(b'd', 1.5)
        c.wait_exit(timeout=8.0)
        c.drain(0.6)
        lines = [line.rstrip() for line in c.screen.display]
        check(label + ': the normal screen is back', not c.screen.in_alt)
        check(label + ': the shell text is back',
              lines[:len(SHELL)] == [s.decode() for s in SHELL])
        check(label + ': nothing of the desktop is left',
              not any(lines[len(SHELL):]))
        check(label + ': the cursor is below the command',
              (c.screen.cursor.y, c.screen.cursor.x) == (len(SHELL), 0))
    finally:
        stlib.close_all_daemons(home)
        c.wait_exit(3.0)
        c.close()


for term in ('xterm-256color', 'tmux-256color', 'alacritty'):
    run(term, 'quit', False)
run('tmux-256color', 'detach', False)
run('tmux-256color', 'quit', True)
run('xterm-256color', 'quit', True)

stlib.report()
