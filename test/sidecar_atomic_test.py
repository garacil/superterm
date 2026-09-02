#!/usr/bin/env python3
"""The live-session sidecar is an atomic, optional discovery snapshot.

Raw clients repeatedly attach and detach (both operations rewrite the
sidecar), while independent CLI processes enumerate the session and this
process parses the published INI as fast as it can.  Every observation must
be one complete old or new snapshot: a transient empty/partial file, FPC's
EFOpenError/EAGAIN sharing failure, or a daemon crash is a regression.
"""
import configparser
import fcntl
import glob
import io
import os
import re
import socket
import struct
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, raw_frame, read_frame, run_cli
from stlib import (FRAME_ATTACH, FRAME_DETACH, FRAME_SESSION, FRAME_SCREEN,
    FRAME_READY)


STRESS_SECONDS = 2.2
CHURNERS = 2
CLI_READERS = 3


def attach_proto_ver():
    source = os.path.join(os.path.dirname(__file__), '..', 'src',
                          'st_server.pas')
    with open(source, encoding='utf-8') as stream:
        for line in stream:
            match = re.match(r'\s*ATTACH_PROTO_VER\s*=\s*(\d+)', line)
            if match:
                return int(match.group(1))
    raise RuntimeError('ATTACH_PROTO_VER not found')


PROTO_VER = attach_proto_ver()
HOME = stlib.fresh_home('sidecar-atomic')
SESSION = 'sidecar-atomic'
with open(HOME + '/.superterm/superterm.ini', 'w', encoding='utf-8') as fh:
    fh.write('[ui]\nlanguage=en\nbackground=none\n'
             '[session]\nserver=always\nautosave=0\nautorestore=0\n'
             'zoomanim=0\n')

owner = None
workers = []
active_raw = set()
active_lock = threading.Lock()
result_lock = threading.Lock()
start_event = threading.Event()
stop_event = threading.Event()
deadline = 0.0
errors = []
sidecar_races = []
counts = {'raw': 0, 'cli': 0, 'metadata': 0}


def remember(bucket, value):
    with result_lock:
        bucket.append(value)


def increment(kind):
    with result_lock:
        counts[kind] += 1


def strict_metadata(path, expected):
    """Return an error string, or None for one complete valid snapshot."""
    try:
        with open(path, 'rb') as stream:
            raw = stream.read()
        text = raw.decode('utf-8')
        parser = configparser.ConfigParser(
            interpolation=None, strict=True, empty_lines_in_values=False)
        parser.read_file(io.StringIO(text), source=path)
    except Exception as exc:
        return type(exc).__name__ + ': ' + str(exc)

    required = {
        'name', 'profile', 'panes', 'attached', 'pid', 'pid_identity', 'cpus',
        'thread_limit', 'threads', 'multithread', 'created', 'id',
        'client_chains',
    }
    if parser.sections() != ['session']:
        return 'sections=' + repr(parser.sections())
    fields = parser['session']
    missing = sorted(required - set(fields))
    if missing:
        return 'missing=' + repr(missing) + ' raw=' + repr(raw[:240])
    try:
        numeric = {key: fields.getint(key) for key in
                   ('panes', 'attached', 'pid', 'cpus', 'thread_limit',
                    'threads')}
    except ValueError as exc:
        return 'invalid integer: ' + str(exc)
    if fields.get('name') != SESSION:
        return 'name=' + repr(fields.get('name'))
    if numeric['pid'] != expected['pid']:
        return 'pid=%d expected=%d' % (numeric['pid'], expected['pid'])
    if fields.get('pid_identity') != expected['pid_identity']:
        return 'pid_identity changed=' + repr(fields.get('pid_identity'))
    if numeric['panes'] != expected['panes']:
        return 'panes=%d expected=%d' % (
            numeric['panes'], expected['panes'])
    if not 1 <= numeric['attached'] <= 1 + CHURNERS:
        return 'attached=' + str(numeric['attached'])
    if (numeric['cpus'] < 1 or numeric['thread_limit'] < 1 or
            not 1 <= numeric['threads'] <= numeric['thread_limit']):
        return 'invalid thread metadata=' + repr(numeric)
    if fields.get('profile') != expected['profile']:
        return 'profile changed=' + repr(fields.get('profile'))
    if fields.get('id') != expected['id'] or not fields.get('id'):
        return 'session id changed=' + repr(fields.get('id'))
    if not re.fullmatch(r'\d{4}-\d\d-\d\d \d\d:\d\d:\d\d',
                        fields.get('created', '')):
        return 'created=' + repr(fields.get('created'))
    return None


def read_baseline(path):
    parser = configparser.ConfigParser(interpolation=None)
    parser.read(path, encoding='utf-8')
    section = parser['session']
    return {
        'pid': section.getint('pid'),
        'pid_identity': section.get('pid_identity', ''),
        'panes': section.getint('panes'),
        'profile': section.get('profile', ''),
        'id': section.get('id', ''),
    }


def raw_attach(path):
    peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    peer.settimeout(3.0)
    with active_lock:
        active_raw.add(peer)
    try:
        peer.connect(path)
        peer.sendall(raw_frame(
            FRAME_ATTACH, -1,
            struct.pack('<iiiii', PROTO_VER, 100, 30, 1, 0)))
        first = read_frame(peer, timeout=3.0)
        if first is None or first[0] != FRAME_SESSION:
            raise RuntimeError('missing FRAME_SESSION')
        screens = 0
        while True:
            frame = read_frame(peer, timeout=3.0)
            if frame is None:
                raise RuntimeError('EOF before FRAME_READY')
            if frame[0] == FRAME_READY:
                break
            if frame[0] != FRAME_SCREEN:
                raise RuntimeError('unexpected snapshot frame %d' % frame[0])
            screens += 1
        if screens != baseline['panes']:
            raise RuntimeError('snapshot screens=%d expected=%d' %
                               (screens, baseline['panes']))
        peer.sendall(raw_frame(FRAME_DETACH, -1))
    finally:
        with active_lock:
            active_raw.discard(peer)
        peer.close()


def churn_worker(worker_no):
    start_event.wait()
    while not stop_event.is_set() and time.monotonic() < deadline:
        try:
            raw_attach(socket_path)
            increment('raw')
        except Exception as exc:
            remember(errors, 'raw-%d: %s: %s' %
                     (worker_no, type(exc).__name__, exc))
            stop_event.set()
            return


def valid_cli_output(args, output):
    lines = [line for line in output.splitlines() if line.strip()]
    if args == ['list']:
        return (len(lines) >= 2 and 'NAME' in lines[0] and
                any(line.split() and line.split()[0] == SESSION
                    for line in lines[1:]))
    pane_rows = [line for line in lines[1:]
                 if line.split() and line.split()[0].isdigit()]
    return (bool(lines) and 'PANE' in lines[0] and
            len(pane_rows) == baseline['panes'])


def cli_worker(worker_no):
    iteration = worker_no
    start_event.wait()
    while not stop_event.is_set() and time.monotonic() < deadline:
        args = ['list'] if iteration % 2 == 0 else ['list', SESSION]
        iteration += 1
        try:
            result = run_cli(args, HOME, env={'LANG': 'C'}, timeout=4.0)
        except Exception as exc:
            remember(errors, 'cli-%d %r: %s: %s' %
                     (worker_no, args, type(exc).__name__, exc))
            stop_event.set()
            return
        increment('cli')
        combined = result.stdout + result.stderr
        race = ('EFOpenError' in combined or
                ('session.ini' in combined and 'Try again' in combined) or
                result.returncode == 217)
        if race:
            remember(sidecar_races,
                     'cli-%d %r rc=%d output=%r' %
                     (worker_no, args, result.returncode, combined[-500:]))
        if result.returncode != 0 or not valid_cli_output(args, result.stdout):
            remember(errors, 'cli-%d %r rc=%d output=%r' %
                     (worker_no, args, result.returncode, combined[-500:]))
            stop_event.set()
            return


def metadata_worker():
    start_event.wait()
    while not stop_event.is_set() and time.monotonic() < deadline:
        failure = strict_metadata(sidecar_path, baseline)
        increment('metadata')
        if failure is not None:
            remember(sidecar_races, failure)
            stop_event.set()
            return
        time.sleep(0.0005)


try:
    owner = stlib.Client(HOME, args=['--session', SESSION], w=100, h=30,
                         lang='en')
    owner.drain(1.5)
    sockets = stlib.session_sockets(HOME)
    check('named daemon socket exists',
          len(sockets) == 1 and
          os.path.basename(sockets[0]) == SESSION + '.sock')
    socket_path = sockets[0] if sockets else ''
    sidecar_path = HOME + '/.superterm/sessions/' + SESSION + '.ini'
    sidecar_ready = os.path.isfile(sidecar_path)
    check('initial sidecar exists', sidecar_ready)
    baseline = read_baseline(sidecar_path) if sidecar_ready else {
        'pid': -1, 'pid_identity': '', 'panes': -1,
        'profile': '', 'id': ''}
    check('baseline metadata is independently meaningful',
          baseline['pid'] > 0 and baseline['panes'] == 1 and
          bool(baseline['id']) and
          baseline['pid_identity'] ==
          stlib.process_identity(baseline['pid']))
    check('baseline sidecar is complete',
          sidecar_ready and strict_metadata(sidecar_path, baseline) is None)

    # FPC opens TIniFile with fmShareDenyWrite and uses a non-blocking flock
    # on Unix. Hold the published inode exclusively to deterministically force
    # that optional read to fail. Discovery must retain the live socket and
    # its basename, then the per-session query must still reach the daemon.
    with open(sidecar_path, 'rb') as locked_sidecar:
        fcntl.flock(locked_sidecar.fileno(), fcntl.LOCK_EX)
        locked_lists = [
            run_cli(['list'], HOME, env={'LANG': 'C'}, timeout=4.0),
            run_cli(['list', SESSION], HOME, env={'LANG': 'C'}, timeout=4.0),
        ]
    check('exclusive sidecar lock cannot break live discovery',
          all(result.returncode == 0 for result in locked_lists) and
          valid_cli_output(['list'], locked_lists[0].stdout) and
          valid_cli_output(['list', SESSION], locked_lists[1].stdout) and
          all('EFOpenError' not in result.stdout + result.stderr
              for result in locked_lists))

    for index in range(CHURNERS):
        workers.append(threading.Thread(
            target=churn_worker, args=(index,), name='sidecar-churn-%d' % index))
    for index in range(CLI_READERS):
        workers.append(threading.Thread(
            target=cli_worker, args=(index,), name='sidecar-cli-%d' % index))
    workers.append(threading.Thread(
        target=metadata_worker, name='sidecar-reader'))
    for worker in workers:
        worker.start()
    deadline = time.monotonic() + STRESS_SECONDS
    start_event.set()
    while time.monotonic() < deadline and not stop_event.is_set():
        owner.drain(0.025)
    stop_event.set()
    for worker in workers:
        worker.join(timeout=5.0)
    stuck = [worker.name for worker in workers if worker.is_alive()]
    if stuck:
        with active_lock:
            for peer in tuple(active_raw):
                try:
                    peer.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                peer.close()
        for worker in workers:
            worker.join(timeout=1.0)

    check('stress workers terminate by deadline', not stuck)
    if errors:
        print('  first stress errors:', errors[:5])
    if sidecar_races:
        print('  first sidecar races:', sidecar_races[:5])
    check('raw attach/detach churn is substantial', counts['raw'] >= 20)
    check('concurrent CLI query load is substantial', counts['cli'] >= 30)
    check('published INI sampled substantially', counts['metadata'] >= 100)
    check('all raw and CLI operations succeed', not errors)
    check('no EFOpenError, EAGAIN or partial metadata', not sidecar_races)

    # A fresh protocol round-trip and CLI query after the storm independently
    # prove that success was not obtained by killing or wedging the daemon.
    post_raw_ok = False
    try:
        raw_attach(socket_path)
        post_raw_ok = True
    except Exception as exc:
        print('  post-stress raw attach:', repr(exc))
    final_cli = run_cli(['list', SESSION], HOME, env={'LANG': 'C'}, timeout=4.0)
    daemon_alive = False
    try:
        os.kill(baseline['pid'], 0)
        daemon_alive = True
    except OSError:
        pass
    check('daemon survives and answers after stress',
          owner.alive() and daemon_alive and post_raw_ok and
          final_cli.returncode == 0 and
          valid_cli_output(['list', SESSION], final_cli.stdout))
    time.sleep(0.10)
    check('final sidecar remains complete',
          strict_metadata(sidecar_path, baseline) is None)
    check('no orphan sidecar temporary files',
          glob.glob(sidecar_path + '.tmp*') == [])
finally:
    stop_event.set()
    start_event.set()
    with active_lock:
        for peer in tuple(active_raw):
            try:
                peer.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            peer.close()
    for worker in workers:
        worker.join(timeout=1.0)
    if owner is not None:
        if owner.alive():
            owner.send(b'\x11', 0.05)
            owner.send(b'd', 0.20)
            owner.wait_exit(timeout=3.0)
        owner.close()
    stlib.close_all_daemons(HOME)

stlib.report()
