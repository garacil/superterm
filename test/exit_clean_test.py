#!/usr/bin/env python3
"""superterm test: the terminal is handed back with nothing still reporting.

The RTL's mouse driver enables and disables only ?1003 and ?1006. superterm
also enables ?1000 and ?1002 by hand when it reclaims the screen from a
maximised pane, and the RTL knows nothing about those -- so before this was
fixed they stayed on after superterm exited and the terminal kept reporting
every mouse movement to the shell, which printed the reports as line noise
at its prompt.

Checks both ways out: quitting, and detaching.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from stlib import Client, fresh_home, check, report, close_all_daemons

# every mode that makes a terminal send bytes on its own
MODES = (
    (1000, 'normal tracking'),
    (1002, 'button tracking'),
    (1003, 'any-event tracking'),
    (1006, 'SGR reporting'),
    (2004, 'bracketed paste'),
)


def last_word(raw, mode):
    """'h', 'l' or None: the last thing the session said about this mode."""
    hits = re.findall((r'\x1b\[\?%d([hl])' % mode).encode(), raw)
    return hits[-1].decode() if hits else None


def check_clean(raw, label):
    for mode, name in MODES:
        word = last_word(raw, mode)
        check('%s: ?%d %s off' % (label, mode, name), word in (None, 'l'))


# --- quitting, after a maximise/restore round trip -----------------------
# F5 in and out is what makes the client re-assert ?1000/?1002 by hand, so
# it is the case that used to leak. Do it before leaving.
home = fresh_home('exitclean-quit')
c = Client(home, w=100, h=30)
c.drain(3.0)
c.send(b'\x1b[15~', 1.2)          # F5: maximise (passthrough takes the screen)
c.send(b'\x1b[15~', 1.2)          # F5: restore (re-asserts the mouse modes)
c.send(b'\x1bx', 2.0)             # Alt-X: quit
c.wait_exit(timeout=8.0)
c.drain(0.6)
check_clean(c.raw(), 'quit')
close_all_daemons(home)

# --- detaching -----------------------------------------------------------
home = fresh_home('exitclean-detach')
d = Client(home, w=100, h=30)
d.drain(3.0)
d.send(b'\x1b[15~', 1.2)
d.send(b'\x1b[15~', 1.2)
d.send(b'\x11', 0.4)              # prefix (Ctrl-Q)
d.send(b'd', 2.0)                 # detach
d.wait_exit(timeout=8.0)
d.drain(0.6)
check_clean(d.raw(), 'detach')
close_all_daemons(home)

report()
