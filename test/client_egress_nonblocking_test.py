#!/usr/bin/env python3
"""A stalled session daemon cannot block the interactive client writer.

The small Pascal probe uses the real TSessionClient API.  It attaches while
the suite-owned daemon is running, then this test stops that exact daemon only
after the snapshot handshake.  Repeated complete INPUT frames must fill the
client's bounded FIFO and be rejected promptly; the historical blocking
WriteFull path instead parked forever once the Unix socket buffer filled.
"""
import configparser
import os
import select
import shutil
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check


PROJECT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
HOME = stlib.fresh_home('client-egress')
SESSION = 'client-egress'
CONFIG = os.path.join(HOME, '.superterm', 'superterm.ini')
PROBE = os.path.join(HOME, 'client-egress-probe')
UNITS = os.path.join(HOME, 'probe-units')


with open(CONFIG, 'w', encoding='utf-8') as stream:
    stream.write('''[ui]
language=en
background=none
[autologin]
shell=/bin/bash
login=1
[session]
server=always
autosave=0
autorestore=0
''')


def read_sidecar(path):
    cp = configparser.ConfigParser()
    cp.read(path)
    return (cp.getint('session', 'pid', fallback=0),
            cp.get('session', 'pid_identity', fallback='').strip())


def read_line_bounded(stream, timeout):
    ready, _, _ = select.select([stream], [], [], timeout)
    return stream.readline().strip() if ready else ''


owner = None
probe = None
daemon_pid = 0
daemon_identity = ''
daemon_stopped = False
try:
    os.makedirs(UNITS, mode=0o700)
    fpc = shutil.which('fpc')
    built = False
    compile_diag = ''
    if fpc:
        result = subprocess.run([
            fpc, '-Mobjfpc', '-Sh', '-vewnh',
            '-Fu' + os.path.join(PROJECT, 'build', 'units', 'release'),
            '-FU' + UNITS, '-FE' + HOME, '-o' + PROBE,
            os.path.join(PROJECT, 'test', 'client_egress_probe.pas'),
        ], capture_output=True, text=True, timeout=30, check=False)
        built = result.returncode == 0 and os.path.isfile(PROBE)
        compile_diag = (result.stdout + result.stderr).strip()
    check('client egress probe compiles', built)
    if not built:
        if compile_diag:
            print(compile_diag)
    else:
        owner = stlib.Client(HOME, args=['--session', SESSION],
                             w=90, h=26, lang='en')
        ready = owner.wait_until(
            lambda _text: len(stlib.session_sockets(HOME)) == 1, 8.0)
        check('suite-owned session starts', ready)
        sockets = stlib.session_sockets(HOME)
        socket_path = sockets[0] if len(sockets) == 1 else ''
        sidecar_path = socket_path[:-5] + '.ini' if socket_path else ''
        if sidecar_path:
            daemon_pid, daemon_identity = read_sidecar(sidecar_path)
        exact_daemon = (daemon_pid > 1 and bool(daemon_identity) and
                        stlib.process_identity(daemon_pid) == daemon_identity)
        check('daemon has exact birth identity', exact_daemon)
        if socket_path and exact_daemon:
            env = dict(os.environ, HOME=HOME, TERM='xterm',
                       SUPERTERM_INI=HOME + '/no-sys.ini')
            probe = subprocess.Popen(
                [PROBE, socket_path], stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, env=env)
            stlib.register_process(probe.pid, 'client-egress-probe')
            first = read_line_bounded(probe.stdout, 8.0)
            check('probe completes real attach', first == 'READY')
            if first == 'READY':
                os.kill(daemon_pid, signal.SIGSTOP)
                daemon_stopped = True
                probe.stdin.write('\n')
                probe.stdin.flush()
                started = time.monotonic()
                try:
                    output, _ = probe.communicate(timeout=5.0)
                    elapsed = time.monotonic() - started
                    prompt = True
                except subprocess.TimeoutExpired:
                    output = ''
                    elapsed = time.monotonic() - started
                    prompt = False
                check('stalled daemon never blocks client send',
                      prompt and elapsed < 5.0)
                check('bounded FIFO rejects a complete frame',
                      prompt and 'REJECTED 1' in output and
                      probe.returncode == 0)
                if not prompt:
                    print('  probe remained blocked after %.3fs' % elapsed)
            if probe.poll() is not None:
                stlib.unregister_process(probe.pid)
finally:
    if daemon_stopped and daemon_pid > 1 and daemon_identity and \
            stlib.process_identity(daemon_pid) == daemon_identity:
        try:
            os.kill(daemon_pid, signal.SIGCONT)
        except ProcessLookupError:
            pass
        daemon_stopped = False
    if probe is not None and probe.poll() is None:
        try:
            probe.terminate()
            probe.wait(timeout=2.0)
        except subprocess.TimeoutExpired:
            if stlib.process_identity(probe.pid):
                probe.kill()
                probe.wait(timeout=2.0)
        finally:
            stlib.unregister_process(probe.pid)
    if owner is not None:
        owner.close()
    stlib.close_all_daemons(HOME)

stlib.report()
