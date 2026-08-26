#!/usr/bin/env python3
"""superterm test: detach keeps live PTYs and reattach restores their screen."""
import os
import signal
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib


HOME = stlib.fresh_home('detach')
PIDFILE = os.path.join(HOME, 'pane.pid')
W, H = 110, 35

# Make every behaviour used by this test explicit.  In particular, it must
# not inherit the developer's real autosave/autorestore or server policy.
with open(HOME + '/.superterm/superterm.ini', 'w') as config:
    config.write('[ui]\n'
                 'language=en\n'
                 'background=none\n'
                 '[session]\n'
                 'server=always\n'
                 'autosave=0\n'
                 'autorestore=0\n')


def finish_client(client, timeout=3.0):
    """Reap a test client with bounded waits; never block in waitpid()."""
    if client is None:
        return None
    status = client.wait_exit(timeout)
    if status is None:
        try:
            os.kill(client.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        status = client.wait_exit(1.0)
    if status is None:
        try:
            os.kill(client.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        status = client.wait_exit(1.0)
    client.close()
    return status


def pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def wait_gone(path, timeout=4.0):
    # The daemon kills its panes before removing the socket: give it some
    # slack instead of checking at that very instant.
    end = time.time() + timeout
    while time.time() < end:
        if not os.path.exists(path):
            return True
        time.sleep(0.1)
    return not os.path.exists(path)


first = None
second = None
exit_client = None
try:
    first = stlib.Client(HOME, w=W, h=H, dsr_row=10, dsr_col=20)
    first.stream.feed(b'\033[10;20H')
    first.drain(1.5)
    stlib.check('detach menu is visible', 'Detach' in first.text())
    first.send(f'echo $$ > {PIDFILE}; sleep 1; echo DETACHED_OUTPUT\r'.encode(),
               0.3)
    first.send(b'\x11', 0.4)
    first.send(b'd', 0.8)     # always-server: detach, with no name dialog
    first_status = first.wait_exit(6.0)
    stlib.check('client exits after Ctrl-Q d', first_status is not None and
                os.WIFEXITED(first_status) and
                os.WEXITSTATUS(first_status) == 0)
    first.drain(0.6)          # consume the cursor restore already queued
    stlib.check('cursor restored after detach',
                first.screen.cursor.x == 19 and first.screen.cursor.y == 9)

    sockets = stlib.session_sockets(HOME)
    stlib.check('one server socket remains', len(sockets) == 1)
    socket_path = sockets[0] if len(sockets) == 1 else ''
    session = os.path.basename(socket_path)[:-5] if socket_path else ''
    sidecar = socket_path[:-5] + '.ini' if socket_path else ''
    stlib.check('session sidecar written', bool(sidecar) and
                os.path.exists(sidecar))

    pane_pid = None
    for _ in range(30):
        try:
            with open(PIDFILE) as pid_file:
                pane_pid = int(pid_file.read().strip())
            break
        except (FileNotFoundError, ValueError):
            time.sleep(0.1)
    stlib.check('pane process survives detach',
                pane_pid is not None and pid_alive(pane_pid))
    time.sleep(1.0)

    second = stlib.Client(HOME, args=['--attach', session], w=W, h=H)
    second.drain(2.0)
    stlib.check('reattach shows detached output',
                'DETACHED_OUTPUT' in second.text())
    second.send(b'echo ATTACHED_OK\r', 1.0)
    stlib.check('reattached pane accepts input',
                'ATTACHED_OK' in second.text())
    second.send(b'\x1bx', 1.0)
    second_status = second.wait_exit(6.0)
    stlib.check('permanent close exits client', second_status is not None and
                os.WIFEXITED(second_status) and
                os.WEXITSTATUS(second_status) == 0)

    stlib.check('server socket is removed', wait_gone(socket_path))
    stlib.check('session sidecar removed', wait_gone(sidecar))

    if pane_pid is not None:
        pane_alive = True
        end = time.time() + 4.0
        while time.time() < end:
            if not pid_alive(pane_pid):
                pane_alive = False
                break
            time.sleep(0.1)
        stlib.check('permanent close terminates pane', not pane_alive)

    exit_client = stlib.Client(HOME, w=W, h=H, dsr_row=10, dsr_col=20)
    exit_client.stream.feed(b'\033[10;20H')
    exit_client.drain(1.5)
    exit_client.send(b'\x1bx', 1.0)
    exit_status = exit_client.wait_exit(6.0)
    stlib.check('cursor restored after exit',
                exit_status is not None and
                exit_client.screen.cursor.x == 19 and
                exit_client.screen.cursor.y == 9)
finally:
    # Close session daemons first so any still-attached UI gets EOF, then
    # terminate/reap every PTY child through bounded WNOHANG polling.
    stlib.close_all_daemons(HOME)
    finish_client(first)
    finish_client(second)
    finish_client(exit_client)

stlib.report()
