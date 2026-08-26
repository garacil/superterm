#!/usr/bin/env python3
"""superterm test: superterm inside a superterm pane.

Every nested start used to be refused, because a pane attaching to its own
session mirrors forever. The guard is now by identity: each pane carries
SUPERTERM_SESSION_CHAIN, each daemon writes its id in the sidecar, and only
the sessions on the chain are refused -- the one this pane belongs to and
the ones above it. Another session, or a new one, is as safe from a pane as
from any terminal, and the picker never offers a forbidden one.
"""
import configparser
import glob
import os
import shlex
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import stlib
from stlib import (Client, fresh_home, check, report, close_all_daemons,
                   session_sockets, sessions_dir, run_cli, BIN)

W, H = 110, 35
home = fresh_home('nesting')
with open(os.path.join(home, '.superterm', 'superterm.ini'), 'w') as f:
    f.write('[ui]\nlanguage=en\nbackground=none\n')


def sidecar(name):
    cp = configparser.ConfigParser()
    cp.read(os.path.join(sessions_dir(home), name + '.ini'))
    return cp


def screen(c):
    return '\n'.join(r.rstrip() for r in c.screen.display)


def pane_state(session):
    """Read canonical PTY size and flags independently of rendered text."""
    result = run_cli(['list', session], home, env={'LANG': 'C'})
    for line in result.stdout.splitlines():
        fields = line.split()
        if fields and fields[0].isdigit():
            flags = fields[-1] if set(fields[-1]) <= set('*MZ!') else ''
            size = None
            for field in fields:
                if 'x' not in field or not field[0].isdigit():
                    continue
                try:
                    size = tuple(int(value) for value in field.split('x', 1))
                    break
                except ValueError:
                    pass
            return size, flags
    return None, ''


def pane_zoomed(session):
    return 'Z' in pane_state(session)[1]


# --- session A, the outer one
a = Client(home, w=W, h=H, args=['--session', 'outer'])
a.drain(3.0)
check('outer session up', any('outer' in os.path.basename(s) for s in session_sockets(home)))
check('the sidecar carries an id', sidecar('outer').get('session', 'id', fallback='') != '')

# the pane's environment carries the chain
a.send(b'echo CHAIN=$SUPERTERM_SESSION_CHAIN\r', 1.5)
# read it from the pane rather than from the screen: a window is only as wide
# as its class asks for, so the line can be wrapped or clipped on screen while
# the pane itself has it whole
chain = ''
for line in run_cli(['capture', 'outer:1'], home).stdout.splitlines():
    if line.startswith('CHAIN='):
        chain = line[len('CHAIN='):].strip()
check('the pane knows its session chain', chain != '' and
      chain.endswith(sidecar('outer').get('session', 'id')))

# --- from inside: the own session is refused, by name
a.send((BIN + ' --attach outer; echo EXIT=$?\r').encode(), 2.5)
check('attaching to the own session is refused', 'EXIT=2' in screen(a))
check('...and says why', 'belongs to' in screen(a))

# --- from inside: the control CLI still works
a.send((BIN + ' list >/dev/null; echo LIST=$?\r').encode(), 2.0)
check('the control CLI works from a pane', 'LIST=0' in screen(a))

# --- from inside, with no name and only the own session: refused too
a.send((BIN + ' --attach; echo AUTO=$?\r').encode(), 2.5)
check('auto-pick finds nothing safe', 'AUTO=1' in screen(a))

# --- another session, B, started from outside
b = Client(home, w=90, h=26, args=['--session', 'other'])
b.drain(3.0)
b.send(b'\x1b', 1.5)        # the picker offers 'outer'; Esc = start the new one
b.drain(2.0)
check('second session up', any('other' in os.path.basename(s) for s in session_sockets(home)))

# --- from inside A: attaching to B is allowed, and a client really starts
nested_pid_file = os.path.join(home, 'nested-client.pid')
nested_wrapper = os.path.join(home, 'nested-client-wrapper')
with open(nested_wrapper, 'w', encoding='utf-8') as wrapper:
    wrapper.write('#!/bin/sh\n')
    wrapper.write('marker=' + shlex.quote(nested_pid_file) + '\n')
    wrapper.write('tmp="${marker}.tmp.$$"\n')
    wrapper.write('(umask 077; printf \'%s\\n\' "$$" > "$tmp") || exit 125\n')
    wrapper.write('mv -f "$tmp" "$marker" || exit 125\n')
    wrapper.write('exec ' + shlex.quote(BIN) + ' --attach other\n')
os.chmod(nested_wrapper, 0o700)
a.send(b'clear\r', 0.6)
a.send((nested_wrapper + '\r').encode(), 4.0)
nested_pid = 0
nested_deadline = time.monotonic() + 3.0
while time.monotonic() < nested_deadline:
    try:
        with open(nested_pid_file, encoding='ascii') as marker:
            candidate = marker.read().strip()
        if candidate.isdigit() and int(candidate) > 1:
            nested_pid = int(candidate)
            break
    except OSError:
        pass
    time.sleep(0.03)
nested_identity = (stlib.register_process(
    nested_pid, 'nested-superterm-client') if nested_pid > 1 else '')
check('nested client publishes exact process identity',
      nested_pid > 1 and bool(nested_identity))
att = int(sidecar('other').get('session', 'attached', fallback='0'))
check('a nested client attached to the other session', att >= 2)
check('the nested client is on screen', 'Panes' in screen(a) and
      screen(a).count('Panes') >= 2)
nested_normal_state = pane_state('other')

# The outer prefix is escaped once so the inner SuperTerm receives its own
# complete prefix+f chord. This replaces the old prefix+F5 special case and
# proves that fullscreen remains controllable at arbitrary nesting depth.
# These two hosts deliberately differ (90x26 outside versus the outer pane's
# PTY), so source and the mixed-geometry tests require the synchronized IDE
# renderer, not raw passthrough: the inner menu remains visible while its
# canonical PTY grows to the exact 90x26 common fullscreen viewport.
a.send(b'\x11\x11f', 1.8)
zoom_deadline = time.monotonic() + 3.0
while time.monotonic() < zoom_deadline and not pane_zoomed('other'):
    a.drain(0.08)
nested_fullscreen_screen = screen(a)
nested_fullscreen_count = nested_fullscreen_screen.count('Panes')
nested_fullscreen_state = pane_state('other')
nested_fullscreen_ok = (nested_fullscreen_state[0] == (90, 26) and
                        'Z' in nested_fullscreen_state[1])
if not nested_fullscreen_ok:
    print('  nested states:', nested_normal_state, nested_fullscreen_state)
    print('  nested list:', repr(run_cli(
        ['list', 'other'], home, env={'LANG': 'C'}).stdout))
check('escaped prefix commits nested fullscreen', nested_fullscreen_ok)
check('mixed nested fullscreen stays in renderer',
      nested_fullscreen_count >= 2)
a.send(b'\x11\x11f', 1.8)
restore_deadline = time.monotonic() + 3.0
while time.monotonic() < restore_deadline and pane_zoomed('other'):
    a.drain(0.08)
check('escaped prefix restores nested IDE',
      pane_state('other') == nested_normal_state and
      screen(a).count('Panes') >= 2)

# --- two hops: from inside the nested client (whose pane belongs to B,
# below A), attaching back to A must be refused as well
a.send((BIN + ' --attach outer; echo DEEP=$?\r').encode(), 3.0)
check('the ancestor two hops up is refused', 'DEEP=2' in screen(a))

# --- leaving: close B from outside; the nested client goes with it
r = run_cli(['kill', 'other'], home)
check('other session killed', r.returncode == 0)
a.drain(1.5)
b.drain(1.5)
check('nested client receives shutdown notice',
      'session was closed' in screen(a).lower())
check('outside client receives shutdown notice',
      'session was closed' in screen(b).lower())
# Administrative kill deliberately asks every viewer to acknowledge the
# shutdown.  Confirm both dialogs; waiting without sending Enter tests only
# that a modal dialog is modal and strands the nested client in the pane.
b.send(b'\r', 0.4)
a.send(b'\r', 0.4)
b_pid = b.pid
b_status = b.wait_exit(timeout=8.0)
nested_finished = False
nested_finish_deadline = time.monotonic() + 8.0
while nested_identity and time.monotonic() < nested_finish_deadline:
    if stlib.process_finished(nested_pid, nested_identity):
        nested_finished = True
        break
    time.sleep(0.05)
if nested_finished:
    stlib.unregister_process(nested_pid)
check('acknowledged nested client returns to its shell', nested_finished)
return_marker = '__NESTED_RETURNED_OUTPUT__'
a.send(("printf '%s\\n' " + shlex.quote(return_marker) + '\r').encode(),
       0.4)
shell_returned = False
shell_deadline = time.monotonic() + 3.0
while time.monotonic() < shell_deadline:
    captured = run_cli(['capture', 'outer:1'], home)
    if (captured.returncode == 0 and
            return_marker in (line.strip()
                              for line in captured.stdout.splitlines())):
        shell_returned = True
        break
    time.sleep(0.05)
check('outer pane is usable after nested shutdown', shell_returned)

a.send(b'\x1bx', 1.0)
a_pid = a.pid
a_status = a.wait_exit(timeout=8.0)
if b_status is None or a_status is None or not nested_finished:
    print('  client-exit diagnostics:', {
        'outer': (a_pid, a_status),
        'other': (b_pid, b_status),
        'nested': (nested_pid, nested_identity, nested_finished),
    })
check('outside clients exit after nested shutdown',
      b_status == 0 and a_status == 0)
close_all_daemons(home)
report()
