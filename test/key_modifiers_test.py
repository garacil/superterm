#!/usr/bin/env python3
"""superterm test: every key reaches the pane with all its modifiers.

Issue #6. A FreeVision key event has one scancode per physical key and keeps a
modifier only where the PC keyboard had a code for it, so Shift+Up went to the
pane as a plain Up, Shift+F5 and Shift+Ins as nothing at all, Ctrl+Alt+Left
as Ctrl+Left, Alt+> as Alt+. and Alt+Enter not at all. The keyboard driver
now keeps each key exactly as the terminal reported it, and the pane gets it
built the way tmux builds it (input-keys.c): xterm's CSI 1;m forms for named
keys, C0 codes and an ESC for characters, and, for a program that asked for
xterm's modifyOtherKeys, the CSI 27;m;code ~ reports -- which superterm then
asks its own terminal for, reads, and still recognises the prefix in.

The pane runs a raw-mode logger, so the bytes compared are the bytes the
program read, with nothing in between to interpret them.
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import stlib
from stlib import check

HOME = stlib.fresh_home('key-modifiers')
with open(HOME + '/.superterm/superterm.ini', 'w') as config:
    config.write('[ui]\nlanguage=en\nbackground=none\n'
                 '[session]\nserver=always\nautosave=0\nautorestore=0\n')
with open(HOME + '/.bash_profile', 'w') as f:
    f.write("PS1='$ '\n")
LOGGER = HOME + '/keylog.py'
with open(LOGGER, 'w') as f:
    f.write(r'''
import os, sys, termios, tty
log, mode = sys.argv[1], sys.argv[2]
saved = termios.tcgetattr(0)
tty.setraw(0)
try:
    if mode == 'ckm':
        os.write(1, b'\x1b[?1h')
    elif mode != '0':
        os.write(1, b'\x1b[>4;' + mode.encode() + b'm')
    os.write(1, b'KEYLOG ' + mode.encode() + b' READY\r\n')
    seen = b''
    with open(log, 'ab', buffering=0) as out:
        while b'ENDLOG' not in seen:
            data = os.read(0, 4096)
            if not data:
                break
            out.write(data)
            seen = (seen + data)[-16:]
    if mode not in ('0', 'ckm'):
        os.write(1, b'\x1b[>4m')
    elif mode == 'ckm':
        os.write(1, b'\x1b[?1l')
finally:
    termios.tcsetattr(0, termios.TCSADRAIN, saved)
''')

# (name, what the terminal sends, what the program must read)
LEGACY = [
    ('Shift+Up', b'\x1b[1;2A', b'\x1b[1;2A'),
    ('Shift+Down', b'\x1b[1;2B', b'\x1b[1;2B'),
    ('Shift+Right', b'\x1b[1;2C', b'\x1b[1;2C'),
    ('Shift+Left', b'\x1b[1;2D', b'\x1b[1;2D'),
    ('Ctrl+Shift+Left', b'\x1b[1;6D', b'\x1b[1;6D'),
    ('Ctrl+Alt+Up', b'\x1b[1;7A', b'\x1b[1;7A'),
    ('Alt+Shift+Right', b'\x1b[1;4C', b'\x1b[1;4C'),
    ('Ctrl+Left', b'\x1b[1;5D', b'\x1b[1;5D'),
    ('Alt+Up (Meta convention)', b'\x1b[1;3A', b'\x1b\x1b[A'),
    ('Shift+Home', b'\x1b[1;2H', b'\x1b[1;2H'),
    ('Shift+End', b'\x1b[1;2F', b'\x1b[1;2F'),
    ('Shift+PgUp', b'\x1b[5;2~', b'\x1b[5;2~'),
    ('Shift+PgDn', b'\x1b[6;2~', b'\x1b[6;2~'),
    ('Shift+Ins', b'\x1b[2;2~', b'\x1b[2;2~'),
    ('Ctrl+Ins', b'\x1b[2;5~', b'\x1b[2;5~'),
    ('Shift+Del', b'\x1b[3;2~', b'\x1b[3;2~'),
    ('Ctrl+Shift+Del', b'\x1b[3;6~', b'\x1b[3;6~'),
    ('F1', b'\x1bOP', b'\x1bOP'),
    ('Shift+F1', b'\x1b[1;2P', b'\x1b[1;2P'),
    ('Ctrl+F2', b'\x1b[1;5Q', b'\x1b[1;5Q'),
    ('Alt+F4 (Meta convention)', b'\x1b[1;3S', b'\x1b\x1bOS'),
    ('F5', b'\x1b[15~', b'\x1b[15~'),
    ('Shift+F5', b'\x1b[15;2~', b'\x1b[15;2~'),
    ('Ctrl+Shift+F9', b'\x1b[20;6~', b'\x1b[20;6~'),
    ('Ctrl+F12', b'\x1b[24;5~', b'\x1b[24;5~'),
    ('Shift+Tab', b'\x1b[Z', b'\x1b[Z'),
    ('Alt+>', b'\x1b>', b'\x1b>'),
    ('Alt+Shift+B', b'\x1bB', b'\x1bB'),
    ('Alt+b', b'\x1bb', b'\x1bb'),
    ('Alt+Enter', b'\x1b\r', b'\x1b\r'),
    ('Alt+Backspace', b'\x1b\x7f', b'\x1b\x7f'),
    ('Alt+n with tilde', b'\x1b\xc3\xb1', b'\x1b\xc3\xb1'),
    ('Ctrl+Alt+a', b'\x1b\x01', b'\x1b\x01'),
    ('a letter', b'x', b'x'),
    ('a UTF-8 letter', b'\xc3\xb1', b'\xc3\xb1'),
    ('Ctrl+a', b'\x01', b'\x01'),
    ('Backspace', b'\x7f', b'\x7f'),
    ('Enter', b'\r', b'\r'),
    ('Esc', b'\x1b', b'\x1b'),
]

APP_CURSOR = [
    ('Up in application cursor mode', b'\x1b[A', b'\x1bOA'),
    ('Shift+Up in application cursor mode', b'\x1b[1;2A', b'\x1b[1;2A'),
]

# what the terminal sends once asked for modifyOtherKeys, and the plain
# forms a terminal that ignored the request keeps sending
MODE2 = [
    ('Ctrl+Shift+A', b'\x1b[27;6;65~', b'\x1b[27;6;65~'),
    ('Ctrl+a reported', b'\x1b[27;5;97~', b'\x1b[27;5;97~'),
    ('Ctrl+Enter', b'\x1b[27;5;13~', b'\x1b[27;5;13~'),
    ('Shift+Enter', b'\x1b[27;2;13~', b'\x1b[27;2;13~'),
    ('Ctrl+. in CSI u form', b'\x1b[46;5u', b'\x1b[27;5;46~'),
    ('plain Ctrl+a', b'\x01', b'\x1b[27;5;97~'),
    ('plain Alt+x', b'\x1bx', b'\x1b[27;3;120~'),
    ('Shift+Up', b'\x1b[1;2A', b'\x1b[1;2A'),
    ('a letter', b'x', b'x'),
]

# mode 1 keeps every key a VT100 could already send as it was; Ctrl with or
# without Shift over a letter is still its control code (tmux, input_key_mode1)
MODE1 = [
    ('Ctrl+a reported', b'\x1b[27;5;97~', b'\x01'),
    ('Ctrl+Enter', b'\x1b[27;5;13~', b'\x1b[27;5;13~'),
    ('Ctrl+Shift+A', b'\x1b[27;6;65~', b'\x01'),
    ('Ctrl+Alt+a', b'\x1b[27;7;97~', b'\x1b[27;7;97~'),
    ('Alt+x reported', b'\x1b[27;3;120~', b'\x1bx'),
    ('plain Ctrl+a', b'\x01', b'\x01'),
]


def wait_log(path, size, timeout=6.0):
    """New bytes after size, once they have stopped arriving."""
    deadline = time.time() + timeout
    last = None
    stable = 0
    while time.time() < deadline:
        c.drain(0.1)
        try:
            with open(path, 'rb') as f:
                data = f.read()[size:]
        except OSError:
            data = b''
        if data and data == last:
            stable += 1
            if stable >= 3:
                return data
        else:
            stable = 0
        last = data
    return last or b''


def run_logger(mode, keys, label):
    log = HOME + '/keys-%s.log' % mode
    open(log, 'wb').close()
    c.send(('python3 %s %s %s\r' % (LOGGER, log, mode)).encode(), 0.3)
    check(label + ': the logger runs',
          c.wait_until(lambda t: 'KEYLOG %s READY' % mode in t, 10.0))
    c.drain(0.5)
    for name, sent, want in keys:
        size = os.path.getsize(log)
        c.send(sent, 0.05)
        got = wait_log(log, size)
        check('%s: %s' % (label, name), got == want)
        if got != want:
            print('    sent %r, the program read %r, wanted %r' % (sent, got, want))
    c.send(b'ENDLOG', 0.3)
    c.wait_until(lambda t: t.rstrip().endswith('$'), 6.0)


c = stlib.Client(HOME, w=110, h=32)
try:
    check('superterm starts',
          c.wait_until(lambda t: 'Detach' in t and '$' in t, 10.0))

    run_logger('0', LEGACY, 'plain')
    check('no key opened a menu or a dialog',
          'Split vertical' not in c.text() and 'Help and shortcuts' not in c.text())
    run_logger('ckm', APP_CURSOR, 'DECCKM')

    mark = len(c.raw())
    run_logger('2', MODE2, 'modifyOtherKeys=2')
    raw = c.raw()[mark:]
    check('the terminal is asked for modifyOtherKeys', b'\x1b[>4;2m' in raw)
    check('and given it up when the program does',
          raw.rfind(b'\x1b[>4m') > raw.find(b'\x1b[>4;2m'))

    run_logger('1', MODE1, 'modifyOtherKeys=1')

    # The prefix still works when the terminal reports Ctrl+Q as a key report.
    c.send(b'\x1b[27;5;113~', 0.3)
    c.send(b'm', 0.8)
    c.send(b'p', 1.0)
    check('a reported Ctrl+Q is still the prefix',
          c.wait_until(lambda t: 'Ctrl-Q v' in t, 4.0))
    c.send(b'\x1b', 0.4)
    c.send(b'\x1b', 0.4)
finally:
    try:
        c.send(b'\x11', 0.3)
        c.send(b'x', 1.0)
    except OSError:
        pass
    c.wait_exit(6.0)
    c.drain(0.5)
    tail = c.raw()
    stlib.close_all_daemons(HOME)
    c.close()

check('leaving superterm resets modifyOtherKeys',
      tail.rfind(b'\x1b[>4m') > tail.rfind(b'\x1b[>4;2m') >= 0)
stlib.report()
