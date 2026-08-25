#!/usr/bin/env python3
"""The sixteenth pane is visible, and the seventeenth is always explained.

There are two remote creation paths in the Classes menu: ``Local shell``
reuses the vertical-split command, while a configured class goes through
``DoOpenClassPane``.  At the daemon limit both must show the same message.

The client-side count is only a fast preflight.  Two attached clients can
both observe 15 panes and submit a creation before either sees the winner's
new-pane event.  The daemon serializes those requests, accepts one, and sends
``max panes`` to the loser; this test also requires that authoritative error
to become a visible dialog.

Finally, FreeVision historically painted only one-digit ``TWindow.Number``
values.  Focusing panes 10 through 16 checks the two cells deliberately kept
between SuperTerm's minimize and FreeVision's zoom controls.
"""
import os
import re
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, run_cli


HOME = stlib.fresh_home('maxpanes')
SESSION = 'max-panes'
ENV = {'SUPERTERM_REAP_MS': '300000'}
INI = HOME + '/.superterm/superterm.ini'

with open(INI, 'w', encoding='utf-8') as stream:
    stream.write(
        '[ui]\n'
        'language=en\n'
        'background=none\n'
        '[session]\n'
        'server=always\n'
        'autorestore=0\n'
        'autosave=0\n'
        '[class.vr1]\n'
        'name=vr1\n'
        'enabled=1\n'
        'cmd=\n')


def drain_all(clients, seconds=0.8):
    """Drain attached UIs fairly; neither may hide the race winner."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        for client in clients:
            if client is not None:
                client.drain(0.025)


def wait_for(predicate, clients=(), timeout=8.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        drain_all(clients, 0.08)
        if predicate():
            return True
        time.sleep(0.02)
    drain_all(clients, 0.1)
    return predicate()


def pane_count():
    result = run_cli(['list', SESSION], HOME, env={'LANG': 'C'})
    if result.returncode != 0:
        return -1
    return sum(bool(re.match(r'^\d+\s', line))
               for line in result.stdout.splitlines())


def maximum_dialog(client):
    return 'Maximum 16 panes' in client.text()


def frame_number_slot(client):
    """Return the cells between the active minimize and zoom buttons.

    Only the active normal window has SuperTerm's ``[-]`` control.  The next
    ``[`` starts FreeVision's zoom control, so this slice cannot accidentally
    match a number in the pane title or terminal contents.
    """
    for row in client.screen.display:
        left = row.rfind('[-]')
        if left < 0:
            continue
        zoom = row.find('[', left + 3)
        if zoom >= 0:
            return row[left + 3:zoom]
    return ''


def open_class_menu(client):
    client.send(b'\x1bc', 0.35)       # Alt-C: Classes
    return 'Local shell' in client.text() and 'vr1' in client.text()


def dismiss_dialog(client):
    if maximum_dialog(client):
        client.send(b'\r', 0.25)


def detach(client):
    if client is None:
        return
    dismiss_dialog(client)
    client.send(b'\x11', 0.08)       # configured prefix: Ctrl-Q
    client.send(b'd', 0.20)
    client.wait_exit(timeout=6.0)
    client.close()


a = None
b = None
try:
    a = stlib.Client(HOME, args=['--session', SESSION], w=130, h=40,
                     lang='en', env=ENV)
    a.drain(2.5)

    # The session starts with one pane.  Control creation is the quickest way
    # to reach the limit; the interactions under test still go through the
    # real Classes menu below.
    creates = [run_cli(['new', SESSION], HOME, env={'LANG': 'C'})
               for _ in range(15)]
    check('fifteen additional panes created',
          all(result.returncode == 0 for result in creates))
    check('daemon reaches sixteen panes', wait_for(
        lambda: pane_count() == 16, (a,)))
    # A control request returns when the daemon has committed it, while this
    # viewer can still have NEWPANE/lock/layout frames queued locally.  Append
    # an explicit focus after those frames and wait for its active border;
    # socket ordering then proves the UI mirror reached the same revision.
    ready_focus = run_cli(['focus', f'{SESSION}:16'], HOME,
                          env={'LANG': 'C'})
    check('client mirrors all sixteen panes',
          ready_focus.returncode == 0 and wait_for(
              # A checked debug build may still be constructing fifteen
              # FreeVision windows while the daemon has already committed
              # them. The exact border is the oracle; give that real work a
              # load-tolerant deadline instead of turning scheduler pressure
              # into a false regression.
              lambda: frame_number_slot(a) == '16', (a,), timeout=20.0))
    drain_all((a,), 0.35)

    # A focused window is raised and is the only one whose top border contains
    # ``[-]``.  Panes 10..16 must occupy the exact two-cell slot before zoom.
    missing_numbers = []
    for number in range(10, 17):
        result = run_cli(['focus', f'{SESSION}:{number}'], HOME,
                         env={'LANG': 'C'})
        visible = result.returncode == 0 and wait_for(
            lambda number=number: frame_number_slot(a) == str(number),
            (a,), timeout=4.0)
        if not visible:
            missing_numbers.append((number, result.returncode,
                                    frame_number_slot(a)))
    if missing_numbers:
        print('  frame-number diagnostics:', missing_numbers)
    check('top borders show pane numbers 10-16', not missing_numbers)

    # Stable limit, local-shell route (cmSplitV -> DoSplit).
    check('local-shell menu is available', open_class_menu(a))
    a.send(b'1', 0.10)
    check('local shell reports maximum', wait_for(
        lambda: maximum_dialog(a), (a,)))
    check('local rejection stays at sixteen', pane_count() == 16)
    dismiss_dialog(a)

    # Stable limit, configured-class route (cmOpenClass -> DoOpenClassPane).
    check('configured-class menu is available', open_class_menu(a))
    a.send(b'2', 0.10)
    check('configured class reports maximum', wait_for(
        lambda: maximum_dialog(a), (a,)))
    check('class rejection stays at sixteen', pane_count() == 16)
    dismiss_dialog(a)

    # Return both mirrors to the same 15-pane revision, then release their
    # configured-class selections together.  Both local preflights pass; only
    # the daemon can decide which request is pane 16 and which is rejected.
    result = run_cli(['close', f'{SESSION}:16'], HOME, env={'LANG': 'C'})
    check('one pane closed for race setup', result.returncode == 0)
    check('first client observes fifteen', wait_for(
        lambda: pane_count() == 15 and not maximum_dialog(a), (a,)))
    b = stlib.Client(HOME, args=['--attach', SESSION], w=122, h=38,
                     lang='en', env=ENV)
    drain_all((a, b), 2.5)
    check('second client attaches at fifteen', b.alive() and
          pane_count() == 15)

    menu_a = open_class_menu(a)
    menu_b = open_class_menu(b)
    check('both race menus are open', menu_a and menu_b)
    barrier = threading.Barrier(3)
    send_errors = []

    def choose_vr1(client):
        try:
            barrier.wait(timeout=3.0)
            os.write(client.fd, b'2')
        except Exception as exc:
            send_errors.append(repr(exc))

    threads = [threading.Thread(target=choose_vr1, args=(client,))
               for client in (a, b)]
    for thread in threads:
        thread.start()
    barrier.wait(timeout=3.0)
    for thread in threads:
        thread.join(timeout=3.0)
    check('concurrent class requests delivered',
          not send_errors and all(not thread.is_alive()
                                  for thread in threads))
    dialog_seen = wait_for(
        lambda: maximum_dialog(a) or maximum_dialog(b), (a, b))
    check('race accepts exactly pane sixteen', pane_count() == 16)
    dialog_count = sum(maximum_dialog(client) for client in (a, b))
    check('only race loser sees maximum dialog',
          dialog_seen and dialog_count == 1)
finally:
    detach(a)
    detach(b)
    stlib.close_all_daemons(HOME)

stlib.report()
