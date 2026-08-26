#!/usr/bin/env python3
"""superterm test: pane copy, ten-item history, host paste and OSC 52."""

import base64
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(__file__))
from stlib import (Client, FULLSCREEN_CHORD, fresh_home, check, report,
                   close_all_daemons)  # noqa: E402


def bracketed(text):
    if isinstance(text, str):
        text = text.encode()
    return b'\x1b[200~' + text + b'\x1b[201~'


def bracketed_paste_shell():
    """Return a shell whose line editor turns on bracketed paste (ESC[?2004h),
    so a pasted CR stays on the input line instead of executing. bash gained
    this in 4.4; macOS still ships bash 3.2, so fall back to zsh (which enables
    it by default) there. On GNU /bin/bash is modern and is used unchanged."""
    for sh in ('/bin/bash', '/opt/homebrew/bin/bash', '/usr/local/bin/bash',
               '/bin/zsh', '/usr/bin/zsh'):
        if not os.path.exists(sh):
            continue
        if os.path.basename(sh) == 'bash':
            try:
                out = subprocess.check_output(
                    [sh, '-c', 'echo ${BASH_VERSINFO[0]} ${BASH_VERSINFO[1]}'],
                    text=True).split()
                if (int(out[0]), int(out[1])) >= (4, 4):
                    return sh
            except Exception:
                pass
        else:
            return sh
    return '/bin/bash'


def osc52_values(raw):
    values = []
    for payload in re.findall(rb'\x1b\]52;c;([^\x07]*)\x07', raw):
        try:
            values.append(base64.b64decode(payload, validate=True))
        except Exception:
            pass
    return values


def has_pane_line(client, expected):
    for line in client.screen.display:
        if line.startswith('║'):
            line = line[1:]
        if line.rstrip(' ▓▲▼║─') == expected:
            return True
    return False


home = fresh_home('clipboard')
c = Client(home, w=110, h=32, env={'SHELL': bracketed_paste_shell()})
c.drain(2.5)

# The top-level menu is a real UI entry and the outer terminal is asked to
# delimit host paste operations.
menu_row = c.screen.display[0]
check('Clipboard top-level menu', 'Clipboard' in menu_row)
check('Clipboard immediately before Help',
      menu_row.find('Clipboard') < menu_row.find('Help') and
      menu_row[menu_row.find('Clipboard') + len('Clipboard'):
               menu_row.find('Help')].strip() == '')
check('outer bracketed paste enabled', b'\x1b[?2004h' in c.raw())
c.send(b'\x1bb', 0.5)  # Alt-B
menu = c.text()
check('Clipboard menu copy action', 'Copy from pane' in menu)
check('Clipboard menu history action', 'Paste from history' in menu)
c.send(b'\x1b', 0.2)

# Bash/readline asks for bracketed paste. The CR inside a host paste must be
# inserted, not executed as a SuperTerm key event; one real Enter executes it.
c.send(bracketed(b'echo ATOMIC_HOST_PASTE\r'), 0.5)
check('host paste remains atomic', c.text().count('ATOMIC_HOST_PASTE') == 1)
c.send(b'\r', 0.8)
check('host paste reaches pane', c.text().count('ATOMIC_HOST_PASTE') >= 2)

# Fill eleven unique entries without executing them. The oldest one must fall
# off the fixed ten-item history.
for i in range(1, 12):
    c.send(bracketed(f'CLIP_{i:02d}'), 0.08)
    c.send(b'\x15', 0.04)  # readline Ctrl-U: clear the pending line
c.send(b'\x11', 0.08)
c.send(b'h', 0.6)
history = c.text()
check('history dialog opens', 'Clipboard history' in history)
check('history newest first', 'CLIP_11' in history and 'CLIP_10' in history)
check('history keeps ten items', 'CLIP_02' in history and 'CLIP_01' not in history)
c.send(b'\x1b', 0.2)

# Select the third row (CLIP_09) and paste it into a prepared shell command.
c.send(b'echo ', 0.1)
c.send(b'\x11', 0.08)
c.send(b'h', 0.4)
c.send(b'\x1b[B\x1b[B', 0.15)
c.send(b'\r', 0.25)
c.send(b'\r', 0.8)
check('chosen history item pasted', has_pane_line(c, 'CLIP_09'))

# Copy an exact range from the pane with the mouse while copy mode owns input.
marker = 'UNIQUE_COPY_42'
c.send(('echo ' + marker + '\r').encode(), 0.8)
matches = [(row, line.index(marker))
           for row, line in enumerate(c.screen.display) if marker in line]
check('copy source is visible', bool(matches))
if matches:
    row, col = matches[-1]
    c.send(b'\x11', 0.08)
    c.send(b'[', 0.3)
    end_col = col + len(marker) - 1
    before = len(c.raw())
    c.send(f'\x1b[<0;{col + 1};{row + 1}M'.encode(), 0.05)
    c.send(f'\x1b[<32;{end_col + 1};{row + 1}M'.encode(), 0.05)
    c.send(f'\x1b[<0;{end_col + 1};{row + 1}m'.encode(), 0.5)
    copied = osc52_values(c.raw()[before:])
    check('pane copy exports OSC 52', copied and copied[-1] == marker.encode())

    c.send(b'echo ', 0.08)
    c.send(b'\x11', 0.08)
    c.send(b']', 0.2)
    c.send(b'\r', 0.7)
    check('latest copied item pastes', has_pane_line(c, marker))

# UTF-8 cells are copied from the screen model, not from its CP437 fallback.
# The final CJK glyph occupies two visual columns and its continuation must
# not be duplicated or lost.
utf8_marker = 'UTF8_café_漢'
c.send(('echo ' + utf8_marker + '\r').encode('utf-8'), 0.8)
matches = [(row, line.index(utf8_marker))
           for row, line in enumerate(c.screen.display) if utf8_marker in line]
check('UTF-8 copy source is visible', bool(matches))
if matches:
    row, col = matches[-1]
    visual_width = len('UTF8_café_') + 2
    end_col = col + visual_width - 1
    c.send(b'\x11', 0.08)
    c.send(b'[', 0.25)
    before = len(c.raw())
    c.send(f'\x1b[<0;{col + 1};{row + 1}M'.encode(), 0.05)
    c.send(f'\x1b[<32;{end_col + 1};{row + 1}M'.encode(), 0.05)
    c.send(f'\x1b[<0;{end_col + 1};{row + 1}m'.encode(), 0.5)
    copied = osc52_values(c.raw()[before:])
    check('UTF-8 pane copy is exact',
          copied and copied[-1] == utf8_marker.encode('utf-8'))

# An SSH/remote application commonly uses OSC 52 for copy. Normal pane
# rendering swallows the control sequence, records it, and emits a sanitized
# host OSC 52 write. Query payloads are not answered or put in history.
remote = b'REMOTE_OSC52_CLIP'
encoded = base64.b64encode(remote)
before = len(c.raw())
command = b"printf '\\033]52;c;" + encoded + b"\\007'\r"
c.send(command, 0.8)
exported = osc52_values(c.raw()[before:])
check('pane OSC 52 exported to host', exported and exported[-1] == remote)
c.send(b'echo ', 0.08)
c.send(b'\x11', 0.08)
c.send(b']', 0.2)
c.send(b'\r', 0.7)
check('pane OSC 52 enters history', has_pane_line(c, remote.decode()))

# Fullscreen passthrough remains raw for writes, but a pane cannot use that path to
# query and read the outer host clipboard.
c.send(FULLSCREEN_CHORD, 0.8)
before = len(c.raw())
c.send(b"printf '\\033]52;c;?\\007'\r", 0.6)
check('passthrough blocks OSC 52 query',
      b'\x1b]52;c;?\x07' not in c.raw()[before:])
c.send(FULLSCREEN_CHORD, 0.8)

c.send(b'\x1bx', 0.8)
c.close()
close_all_daemons(home)

# The longer Spanish top-level label must still fit the supported 80-column
# layout, and must use the translated menu/dialog names.
home_es = fresh_home('clipboard-es')
es = Client(home_es, w=80, h=25, lang='es')
es.drain(2.0)
menu_row = es.screen.display[0]
check('Spanish Clipboard menu fits', 'Portapapeles' in menu_row)
check('Spanish Clipboard immediately before Help',
      menu_row.find('Portapapeles') < menu_row.find('Ayuda') and
      menu_row[menu_row.find('Portapapeles') + len('Portapapeles'):
               menu_row.find('Ayuda')].strip() == '')
es.send(b'\x1bt', 0.4)  # Alt-T: Por-t-apapeles
check('Spanish Clipboard actions',
      'Copiar del panel' in es.text() and 'Pegar del historial' in es.text())
es.send(b'\x1bx', 0.7)
es.close()
close_all_daemons(home_es)

report()
