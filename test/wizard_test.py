#!/usr/bin/env python3
"""Wizard routing and deferred-pane materialization regressions.

The first phase uses the daemon's per-pane capture instead of accepting both
tokens anywhere on the merged IDE surface.  The second starts from an attached
``server=detach`` workspace: profile and wizard replacements are prepared
daemon-first, but must be materialized locally when policy declines promotion.
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, run_cli


W, H = 110, 35
CONNECT = '/bin/bash --noprofile --norc -i'


def post_command(token):
    # The optional command initially arrives through a finite pipe. Reattach
    # the connection shell to its controlling PTY after printing the marker,
    # otherwise an interactive bash correctly exits on that pipe's EOF and a
    # test could mistake historical output for a live pane.
    return ('echo ' + token +
            '; exec /bin/bash --noprofile --norc -i '
            '</dev/tty >/dev/tty 2>&1')


def wait_for(predicate, client=None, timeout=12.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if client is not None:
            client.drain(0.12)
        if predicate():
            return True
        time.sleep(0.03)
    return predicate()


def session_names(home):
    return sorted(os.path.basename(path)[:-5]
                  for path in stlib.session_sockets(home))


def drive_wizard(client, token_one, token_two, label):
    """Answer only after each exact modal prompt is visibly ready.

    ``--noprofile --norc`` is understood by Apple's bash 3.2 and removes the
    host-specific MOTD/rc output which previously let timed keystrokes drift
    into the next pane's dialog.
    """
    client.send(b'\x1bs', 0.25)
    check(label + ': menu exposes wizard',
          client.wait_until(lambda text: 'Quick session wizard' in text, 5.0))
    client.send(b'w', 0.15)
    check(label + ': pane-count prompt ready', client.wait_until(
        lambda text: 'Number of panes (1-4):' in text, 5.0))
    client.send(b'2\r', 0.15)

    check(label + ': pane 1 connection prompt ready', client.wait_until(
        lambda text: ('Wizard: pane 1/2' in text and
                      'Connection command:' in text), 5.0))
    client.send(CONNECT.encode() + b'\r', 0.15)
    check(label + ': pane 1 post prompt ready', client.wait_until(
        lambda text: ('Wizard: pane 1/2' in text and
                      'After connecting (optional):' in text), 5.0))
    client.send(post_command(token_one).encode() + b'\r', 0.15)

    check(label + ': pane 2 connection prompt ready', client.wait_until(
        lambda text: ('Wizard: pane 2/2' in text and
                      'Connection command:' in text), 5.0))
    client.send(CONNECT.encode() + b'\r', 0.15)
    check(label + ': pane 2 post prompt ready', client.wait_until(
        lambda text: ('Wizard: pane 2/2' in text and
                      'After connecting (optional):' in text), 5.0))
    client.send(post_command(token_two).encode() + b'\r', 0.3)


def capture(home, session, pane):
    result = run_cli(['capture', f'{session}:{pane}'], home)
    return result.stdout if result.returncode == 0 else ''


# ---------------------------------------------------------------- daemon case

HOME = stlib.fresh_home('wizard')
INI = HOME + '/.superterm/superterm.ini'
with open(INI, 'w', encoding='utf-8') as stream:
    stream.write('''[ui]
language=en
background=none
[session]
server=always
autosave=0
autorestore=0
''')

one = 'WIZARD_PANE_ONE_41071'
two = 'WIZARD_PANE_TWO_41072'
c = stlib.Client(HOME, w=W, h=H, lang='en')
try:
    c.drain(1.5)
    drive_wizard(c, one, two, 'daemon wizard')
    check('daemon wizard publishes one session', wait_for(
        lambda: len(session_names(HOME)) == 1, c))
    names = session_names(HOME)
    session = names[0] if len(names) == 1 else 'session'

    captures = ['', '']

    def routed():
        captures[0] = capture(HOME, session, 1)
        captures[1] = capture(HOME, session, 2)
        return one in captures[0] and two in captures[1]

    check('both wizard commands reach their pane', wait_for(routed, c))
    check('pane 1 contains only its wizard token',
          one in captures[0] and two not in captures[0])
    check('pane 2 contains only its wizard token',
          two in captures[1] and one not in captures[1])

    listed = run_cli(['list', session], HOME, env={'LANG': 'C'})
    pane_rows = [line for line in listed.stdout.splitlines()
                 if line and line[0].isdigit()]
    panes_live = (listed.returncode == 0 and len(pane_rows) == 2 and
                  all(not row.rstrip().endswith('!') for row in pane_rows))
    check('wizard owns two live pane processes', panes_live)
    if not panes_live:
        print('  list output:', repr(listed.stdout))
        print('  list stderr:', repr(listed.stderr))
    check('wizard creates a divider', '│' in c.text())

    c.send(b'\x1bh', 0.3)
    check('help menu is accessible', 'Help and shortcuts' in c.text())
    c.send(b'\r', 0.3)
    check('help dialog opens', 'F2/F3 split' in c.text())
finally:
    try:
        c.send(b'\x1bx', 0.4)
        c.wait_exit(5.0)
    except OSError:
        pass
    c.close()
    stlib.close_all_daemons(HOME)


# ------------------------------------------------------ detach materialization

LOCAL_HOME = stlib.fresh_home('wizard-local-materialize')
LOCAL_INI = LOCAL_HOME + '/.superterm/superterm.ini'
with open(LOCAL_INI, 'w', encoding='utf-8') as stream:
    stream.write('''[ui]
language=en
background=none
[session]
server=detach
default_profile=alpha
default_window=main
autosave=0
autorestore=0

[profile.alpha]
name=alpha
enabled=1
focused_window=0
windows=main
[profile.alpha.window.main]
enabled=1
layout=L
focused_pane=0
panes=p
[profile.alpha.window.main.pane.p]
enabled=1
cmd=echo LOCAL_ALPHA_READY; exec /bin/bash --noprofile --norc -i

[profile.beta]
name=beta
enabled=1
focused_window=0
windows=main
[profile.beta.window.main]
enabled=1
layout=L
focused_pane=0
panes=p
[profile.beta.window.main.pane.p]
enabled=1
cmd=echo LOCAL_BETA_MATERIALIZED; exec /bin/bash --noprofile --norc -i
''')

local = stlib.Client(LOCAL_HOME, w=W, h=H, lang='en')
try:
    check('detach policy starts alpha locally', local.wait_until(
        lambda text: 'LOCAL_ALPHA_READY' in text, 8.0))
    check('detach policy starts without daemon',
          session_names(LOCAL_HOME) == [])

    # Give the workspace a daemon, then attach to reproduce the exact branch
    # where profile replacement configures launches while still remote.
    local.send(b'\x11', 0.15)
    local.send(b'd', 0.4)
    check('local detach asks for a session name', local.wait_until(
        lambda text: 'Session name:' in text, 5.0))
    local.send(b'\r', 0.8)
    check('local detach exits its client', local.wait_exit(8.0) == 0)
    local.close()
    check('local detach creates one daemon', wait_for(
        lambda: len(session_names(LOCAL_HOME)) == 1))
    base_name = session_names(LOCAL_HOME)[0]

    local = stlib.Client(LOCAL_HOME, args=['--attach', base_name],
                         w=W, h=H, lang='en')
    check('detached alpha reattaches', local.wait_until(
        lambda text: 'LOCAL_ALPHA_READY' in text, 8.0))
    local.send(b'\x1br', 0.3)
    check('both materialization profiles are offered', local.wait_until(
        lambda text: 'alpha' in text and 'beta' in text, 5.0))
    local.send(b'\x1b[B', 0.12)
    local.send(b'\r', 0.4)
    check('declined profile promotion spawns pane locally', local.wait_until(
        lambda text: 'LOCAL_BETA_MATERIALIZED' in text, 8.0))
    check('profile replacement leaves no hidden daemon', wait_for(
        lambda: session_names(LOCAL_HOME) == [], local))

    # Repeat from an attached beta workspace for the wizard path.
    local.send(b'\x11', 0.15)
    local.send(b'd', 0.4)
    check('materialized beta can detach normally', local.wait_until(
        lambda text: 'Session name:' in text, 5.0))
    local.send(b'\r', 0.8)
    check('beta detach exits its client', local.wait_exit(8.0) == 0)
    local.close()
    check('beta detach creates one daemon', wait_for(
        lambda: len(session_names(LOCAL_HOME)) == 1))
    beta_name = session_names(LOCAL_HOME)[0]

    local = stlib.Client(LOCAL_HOME, args=['--attach', beta_name],
                         w=W, h=H, lang='en')
    check('beta daemon reattaches', local.wait_until(
        lambda text: 'LOCAL_BETA_MATERIALIZED' in text, 8.0))
    local_one = 'LOCAL_WIZARD_ONE_42071'
    local_two = 'LOCAL_WIZARD_TWO_42072'
    drive_wizard(local, local_one, local_two, 'detach wizard')
    check('declined wizard promotion materializes both panes',
          local.wait_until(lambda text: (local_one in text and
                                         local_two in text), 10.0))
    check('local wizard keeps both pane windows', '│' in local.text())
    check('wizard replacement leaves no hidden daemon', wait_for(
        lambda: session_names(LOCAL_HOME) == [], local))
finally:
    try:
        local.send(b'\x1bx', 0.4)
        local.wait_exit(5.0)
    except OSError:
        pass
    local.close()
    stlib.close_all_daemons(LOCAL_HOME)

stlib.report()
