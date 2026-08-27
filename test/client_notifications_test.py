#!/usr/bin/env python3
"""Membership notices are local UI chrome driven by ordered host summaries.

The daemon already serializes client attach/detach and emits its host-summary
event to every remaining viewer.  This test exercises the real UI path rather
than fabricating a frame: status text carries the resulting total, the desktop
toast is one FIFO item per event, each survivor receives one BEL, and toggling
the local desktop preference never suppresses the status line or a bell.
"""
import configparser
import os
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check


HOME = stlib.fresh_home('client-notifications')
INI = HOME + '/.superterm/superterm.ini'
with open(INI, 'w', encoding='utf-8') as stream:
    stream.write('[ui]\n'
                 'language=en\n'
                 'palette=mono\n'
                 'background=none\n'
                 'desktop_notifications=1\n'
                 '[session]\n'
                 'server=always\n'
                 'autosave=0\n'
                 'autorestore=0\n')


def status_message(kind, count):
    return f'Client {kind}: {count} clients'


def toast_rows(client):
    # Desktop logical (0,0) starts below the one-row menubar. The three-row
    # toast lives exactly there; the status line is intentionally excluded.
    return '\n'.join(client.screen.display[1:4])


def bell_count(client, offset):
    return client.raw()[offset:].count(b'\x07')


def attached_viewers(home):
    """Read the daemon's published viewer count, never its process count."""
    sockets = stlib.session_sockets(home)
    if len(sockets) != 1:
        return None
    sidecar = sockets[0][:-5] + '.ini'
    parser = configparser.ConfigParser()
    try:
        with open(sidecar, encoding='utf-8') as stream:
            parser.read_file(stream)
        return parser.getint('session', 'attached')
    except (OSError, ValueError, configparser.Error):
        return None


def detach(client):
    client.send(b'\x11d', 0.20)  # Ctrl-Q, d
    status = client.wait_exit(timeout=7.0)
    client.close()
    return status == 0


a = b = c = None
try:
    a = stlib.Client(HOME, w=118, h=32, lang='en')
    a.drain(1.8)
    check('one daemon session exists', len(stlib.session_sockets(HOME)) == 1)
    check('daemon is not counted as an attached viewer',
          attached_viewers(HOME) == 1)

    # B's attach is seen by A, but B's snapshot establishes its own baseline.
    a_bells = len(a.raw())
    b = stlib.Client(HOME, args=['--attach'], w=118, h=32, lang='en')
    check('A observes first connection in status',
          a.wait_until(lambda text: status_message('connected', 2) in text,
                       timeout=7.0))
    check('two UI clients publish exactly two viewers',
          attached_viewers(HOME) == 2)
    check('A desktop toast is one plain connection event',
          'User connected' in toast_rows(a) and
          'clients' not in toast_rows(a).lower())
    check('A receives one bell for B attach', bell_count(a, a_bells) == 1)
    check('B does not announce its own snapshot attach',
          b'\x07' not in b.raw() and 'User connected' not in toast_rows(b))

    # C attaches before B's visual two-second slot expires. Both bells must
    # arrive now, but the visible statuses must advance in FIFO order rather
    # than being collapsed into the last count.
    a_bells = len(a.raw())
    c = stlib.Client(HOME, args=['--attach'], w=118, h=32, lang='en')
    c.drain(0.5)
    a.drain(0.5)
    check('A receives one bell for C attach', bell_count(a, a_bells) == 1)
    check('second attach waits behind first desktop notice',
          status_message('connected', 2) in a.text())
    check('each new client suppresses its own attach notice',
          b'\x07' not in c.raw() and 'User connected' not in toast_rows(c))
    check('queued connection advances to its own total',
          a.wait_until(lambda text: status_message('connected', 3) in text,
                       timeout=5.0))
    check('three UI clients publish exactly three viewers',
          attached_viewers(HOME) == 3)
    check('queued connection retains its desktop event',
          'User connected' in toast_rows(a))

    # Let the second event finish so the Desktop preference transition below
    # is not testing a deliberately still-active toast.
    time.sleep(2.20)
    a.drain(0.35)
    check('connection toast expires after its own interval',
          'User connected' not in toast_rows(a))

    # Desktop -> Show desktop notifications (Alt-D, then mnemonic N) changes
    # only the local overlay. It persists atomically in this client's config.
    a.send(b'\x1bd', 0.30)
    check('Desktop menu exposes notification preference',
          'Show desktop notification' in a.text())
    a.send(b'n', 0.60)
    with open(INI, encoding='utf-8') as stream:
        config_after_disable = stream.read().lower()
    check('desktop notification preference disables and persists',
          'desktop_notifications=0' in config_after_disable)

    # C leaves. A must still hear/see the status event, but its optional
    # desktop box remains absent while the preference is disabled.
    a_bells = len(a.raw())
    check('C detaches cleanly', detach(c))
    c = None
    check('A observes disconnect in status while desktop toast is disabled',
          a.wait_until(lambda text: status_message('disconnected', 2) in text,
                       timeout=7.0) and
          'User disconnected' not in toast_rows(a))
    check('disconnect removes exactly one viewer', attached_viewers(HOME) == 2)
    check('A still receives one bell while desktop toast is disabled',
          bell_count(a, a_bells) == 1)

    # Re-enable while the disconnect event is still active: the pending
    # current item becomes visible immediately, proving the preference only
    # controls the local desktop representation.
    a.send(b'\x1bd', 0.25)
    a.send(b'n', 0.60)
    with open(INI, encoding='utf-8') as stream:
        config_after_enable = stream.read().lower()
    check('desktop notification preference enables and persists',
          'desktop_notifications=1' in config_after_enable)
    check('re-enable presents the active disconnect toast',
          a.wait_until(lambda _text: 'User disconnected' in toast_rows(a),
                       timeout=3.0))

    # The status and the toast are UI chrome only. They must never be injected
    # into the shared terminal buffer or shell input stream.
    from stlib import run_cli
    session = os.path.basename(stlib.session_sockets(HOME)[0])[:-5]
    captured = run_cli(['capture', session + ':1'], HOME)
    check('notice bytes never enter pane output',
          captured.returncode == 0 and
          'User connected' not in captured.stdout and
          'User disconnected' not in captured.stdout)
finally:
    if c is not None:
        detach(c)
    if b is not None:
        detach(b)
    if a is not None:
        detach(a)
    stlib.close_all_daemons(HOME)
    stlib.report()
