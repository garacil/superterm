#!/usr/bin/env python3
"""A stalled host terminal cannot park the interactive client.

The client writes through a separately opened nonblocking /dev/tty descriptor
owned by its output reactor.  This test deliberately stops draining the outer
PTY while a pane floods output, then sends Ctrl-C and the detach chord through
that same PTY.  The UI must still consume input and terminate without anyone
making room in the output buffer.
"""
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check


HOME = stlib.fresh_home('client-output-reactor')
LOG = os.path.join(HOME, 'client-output-reactor.log')
CONFIG = os.path.join(HOME, '.superterm', 'superterm.ini')
PROC_AUDIT = (sys.platform.startswith('linux') and
              os.path.isdir('/proc/self/fd'))

with open(CONFIG, 'w', encoding='utf-8') as stream:
    stream.write('''[ui]
language=en
background=none
desktop_notifications=0
[session]
server=always
autosave=0
autorestore=0
dragcontent=1
zoomanim=0
''')


def output_fd_from_log():
    try:
        with open(LOG, encoding='utf-8', errors='replace') as stream:
            match = re.search(r'client output reactor started fd=(\d+)',
                              stream.read())
    except OSError:
        return -1
    return int(match.group(1)) if match else -1


def fd_flags(pid, fd):
    try:
        with open(f'/proc/{pid}/fdinfo/{fd}', encoding='ascii') as stream:
            for line in stream:
                if line.startswith('flags:'):
                    return int(line.split()[1], 8)
    except (OSError, ValueError):
        pass
    return -1


def thread_names(pid):
    names = []
    try:
        tids = os.listdir(f'/proc/{pid}/task')
    except OSError:
        return names
    for tid in tids:
        try:
            with open(f'/proc/{pid}/task/{tid}/comm', encoding='ascii') as f:
                names.append(f.read().strip())
        except OSError:
            pass
    return names


client = None
status = None
try:
    client = stlib.Client(
        HOME, w=200, h=60,
        env={'SUPERTERM_DEBUG': LOG, 'TERM': 'xterm-256color',
             'COLORTERM': 'truecolor'})
    ready = client.wait_until(
        lambda _text: len(stlib.session_sockets(HOME)) == 1, 8.0)
    check('suite-owned session starts', ready)
    output_fd = output_fd_from_log()
    check('dedicated client output reactor starts',
          output_fd >= 0 and
          (not PROC_AUDIT or
           any(name.startswith('st-client-out')
               for name in thread_names(client.pid))))

    # /proc fd flags and thread names are kernel-specific evidence. The
    # functional stalled-PTY check below remains portable to other POSIX hosts.
    if output_fd >= 0 and PROC_AUDIT:
        output_flags = fd_flags(client.pid, output_fd)
        stdout_flags = fd_flags(client.pid, 1)
        check('reactor descriptor is nonblocking',
              output_flags >= 0 and bool(output_flags & os.O_NONBLOCK))
        check('inherited stdout remains blocking',
              stdout_flags >= 0 and not bool(stdout_flags & os.O_NONBLOCK))

    # From this write onward the harness intentionally performs no PTY read.
    # A few megabytes are enough to fill the PTY output queue on every target
    # while remaining well below the pane/server safety limits.
    if ready:
        stlib.write_all(client.fd,
                        b'yes STALLED-HOST-TERMINAL-OUTPUT\r')
        time.sleep(0.8)
        check('client survives a physically stalled terminal', client.alive())

        # Ctrl-C must still reach the focused pane, and the UI prefix must
        # still be decoded immediately even though presentation cannot move.
        stlib.write_all(client.fd, b'\x03')
        time.sleep(0.15)
        started = time.monotonic()
        stlib.write_all(client.fd, b'\x11d')
        status = stlib.wait_pid(client.pid, timeout=3.0, terminate=False)
        elapsed = time.monotonic() - started
        if status is None:
            stack_path = os.path.join(HOME, 'stalled-client.gdb.txt')
            result = subprocess.run(
                ['gdb', '--batch', '--nx', '--quiet',
                 '-ex', 'set pagination off', '-ex', 'thread apply all bt',
                 '-p', str(client.pid)], capture_output=True, text=True,
                timeout=15, check=False)
            with open(stack_path, 'w', encoding='utf-8') as stream:
                stream.write(result.stdout)
                stream.write(result.stderr)
        check('detach remains responsive without draining terminal output',
              status is not None and elapsed < 3.0)
        if status is not None:
            client.wait_exit(0)
finally:
    if client is not None:
        client.close()
    stlib.close_all_daemons(HOME)

stlib.report()
