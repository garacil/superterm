#!/usr/bin/env python3
"""superterm test: maximized-pane passthrough writes raw PTY bytes verbatim.

A rich line (truecolor fg+bg, prompt arrow U+276F, wide CJK) is collapsed to
the CP437/16-color grid while windowed, but passes through byte-for-byte once
the pane is maximized -- and the window manager comes back on restore.
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check

HOME = stlib.fresh_home('passthrough')
os.makedirs(HOME, exist_ok=True)
with open(HOME + '/.bashrc', 'w') as f:
    f.write("PS1='$ '\n")

# truecolor orange fg, ❯ (E2 9D AF), checkmark, wide 漢 (E6 BC A2), truecolor bg.
# The end marker is assembled by the shell -- E=EN'D' -- so the word END never
# appears in the command line itself. The shell echoes what is typed, so a
# marker written literally is on the screen BEFORE the printf has run: waiting
# for it then measured the echo instead of the output, and the checks below
# looked at a slice that had none of the rich bytes in it yet. That is the
# whole of this suite's long-standing flakiness.
#
# It ends in a NEWLINE, not a carriage return. With a bare \r the shell's next
# prompt lands on top of the line that was just printed, so whether the rich
# bytes ever reached the terminal depended on the renderer emitting a frame in
# between -- and it coalesces frames on purpose. The line has to stay on the
# screen for its cells to be worth asserting about.
SETUP = b"E=EN'D'\r"
RICH = (b"printf '\\033[38;2;255;100;0m\\342\\235\\257\\033[0m RICH "
        b"\\342\\234\\224 \\346\\274\\242 \\033[48;2;0;80;200mBG\\033[0m %s\\n' \"$E\"\r")

c = stlib.Client(HOME, w=118, h=34, lang='en')
c.drain(2.5)
c.send(SETUP, 0.5)

# ---- windowed: the rich renderer keeps the pane faithful without passthrough.
# Before 3.2 a windowed pane went through the CP437 / 16-color grid and these
# were asserted the other way round: truecolor was collapsed and the arrow was
# lost. That limitation is what the rich renderer removes. ----
base = len(c.raw())
c.send(RICH, 0.5)
# the bytes arrive when the pane's output has crossed the daemon and been
# rendered; on a loaded machine that is later than a fixed pause allows, so
# wait for the LAST thing the line prints rather than for a clock
c.wait_until(lambda t: b'END' in c.raw()[base:], 10.0)
win = c.raw()[base:]
check('windowed keeps truecolor fg', b'38;2;255;100;0' in win)
check('windowed keeps truecolor bg', b'48;2;0;80;200' in win)
check('windowed keeps the U+276F arrow', b'\xe2\x9d\xaf' in win)
check('windowed keeps the wide glyph', b'\xe6\xbc\xa2' in win)

# ---- fullscreen: the pane owns the terminal -> passthrough ----
c.send(stlib.FULLSCREEN_CHORD, 1.4)
check('maximize hides the menu', 'Detach' not in c.text())
base = len(c.raw())
c.send(RICH, 0.5)
c.wait_until(lambda t: b'END' in c.raw()[base:], 10.0)
mx = c.raw()[base:]
check('passthrough keeps truecolor fg', b'38;2;255;100;0' in mx)
check('passthrough keeps truecolor bg', b'48;2;0;80;200' in mx)
check('passthrough keeps the U+276F arrow', b'\xe2\x9d\xaf' in mx)
check('passthrough keeps the wide glyph', b'\xe6\xbc\xa2' in mx)

# ---- restore: the window manager reclaims the screen ----
c.send(stlib.FULLSCREEN_CHORD, 1.4)
check('restore brings the menu back', 'Detach' in c.text())
check('restore redraws a window frame',
      ('┌' in '\n'.join(c.screen.display)) or
      ('╔' in '\n'.join(c.screen.display)))

c.send(b'\x1bx', 1.5)   # Alt-X: last viewer closes the live session
c.wait_exit(timeout=6.0)
c.close()
deadline = time.time() + 6.0
while time.time() < deadline and stlib.session_sockets(HOME) != []:
    time.sleep(0.2)

stlib.report()
