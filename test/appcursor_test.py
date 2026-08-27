#!/usr/bin/env python3
"""superterm test: the arrow keys reach a curses program.

Every curses program puts the terminal in DECCKM (ESC [ ? 1 h) and from then
on expects the cursor keys as SS3 -- ESC O A -- and ignores the CSI form
ESC [ A. superterm always sent the CSI form, so in top and htop the arrows
did nothing. The pane's emulator now tracks the mode and the translation
follows it; this watches what the pane actually receives with 'cat -v'.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from stlib import Client, fresh_home, check, report, close_all_daemons

home = fresh_home('appcursor')
with open(home + '/.superterm/superterm.ini', 'w') as config:
    config.write('[ui]\n'
                 'language=en\n'
                 'palette=color\n'
                 'background=none\n'
                 '[session]\n'
                 'server=always\n'
                 'autosave=0\n'
                 'autorestore=0\n')
c = Client(home, w=100, h=30)
c.drain(3.0)

# the host terminal sends ESC [ A for Up; st_kbd decodes it to kbUp, and the
# pane translation decides what the application sees

# application cursor keys ON: the program must see ESC O A
c.send(b"printf '\\033[?1h'; cat -v\r", 1.5)
c.send(b'\x1b[A', 1.0)
check('DECCKM on: Up arrives as ESC O A', any('^[OA' in r for r in c.screen.display))
check('DECCKM on: not as ESC [ A', not any('^[[A' in r for r in c.screen.display))
c.send(b'\x1b[D', 1.0)
check('DECCKM on: Left arrives as ESC O D', any('^[OD' in r for r in c.screen.display))
c.send(b'\x03', 1.0)                      # Ctrl-C: out of cat

# back to normal: the CSI form again (a shell's line editor expects it)
c.send(b"printf '\\033[?1l'; clear; cat -v\r", 1.5)
c.send(b'\x1b[A', 1.0)
check('DECCKM off: Up arrives as ESC [ A', any('^[[A' in r for r in c.screen.display))
check('DECCKM off: not as ESC O A', not any('^[OA' in r for r in c.screen.display))
c.send(b'\x03', 1.0)

# keypad application mode must not leak as text
c.send(b"clear; printf '\\033='; echo KP_OK; printf '\\033>'\r", 1.5)
check('DECKPAM/DECKPNM are consumed silently',
      any('KP_OK' in r for r in c.screen.display) and
      not any('=KP_OK' in r or '>' in r.split('#')[-1] for r in c.screen.display
              if 'KP_OK' in r))

c.send(b'\x1bx', 1.0)
c.wait_exit(timeout=8.0)
close_all_daemons(home)
report()
