#!/usr/bin/env python3
"""Attach accepts fragmented progress but still has one hard total deadline.

Darwin can expose hundreds of immediately readable Unix-socket fragments for
one large screen snapshot. Readiness must not be mistaken for an expired poll.
Conversely, a peer dripping bytes just under the poll interval must not park an
interactive client forever. A fake listener drives both boundaries through the
real ``superterm --ssh-entry`` client and its real FRAME_ATTACH handshake.
"""
import os
import re
import socket
import struct
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import FRAME_ATTACH, FRAME_READY, FRAME_SESSION, check


PROJECT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
DEADLINE_RE = re.compile(
    r'test-attach-deadline: ready=(\d+) reached=([01]) success=([01])')


PROTO = stlib.attach_proto_ver()


def frame(kind, pane=-1, payload=b''):
    return struct.pack('<BBhI', kind, 0, pane, len(payload)) + payload


def pascal_string(value):
    data = value.encode('utf-8')
    return struct.pack('<i', len(data)) + data


def empty_snapshot(name):
    payload = bytearray()
    payload += pascal_string('')             # canonical layout
    payload += struct.pack('<ii', -1, 0)     # focus, pane count
    payload += pascal_string(name)
    payload += pascal_string('')             # source profile
    payload += struct.pack('<iii', 0, 80, 24)  # geom count, desktop
    payload += struct.pack('<ii', PROTO, 0)  # protocol, reserved v4 slot
    payload += struct.pack('<QiIiii', 1, 1, 0, 80, 24, 1)
    return frame(FRAME_SESSION, -1, payload) + frame(FRAME_READY)


def receive_exact(peer, size):
    data = bytearray()
    while len(data) < size:
        chunk = peer.recv(size - len(data))
        if not chunk:
            return None
        data += chunk
    return bytes(data)


def prepare_home(label, session):
    home = stlib.fresh_home(label)
    with open(os.path.join(home, '.superterm', 'superterm.ini'), 'w',
              encoding='utf-8') as stream:
        stream.write('[ui]\n'
                     'language=en\n'
                     'background=none\n'
                     '[session]\n'
                     f'default_session={session}\n'
                     'default_profile=\n')
    sessions = os.path.join(home, '.superterm', 'sessions')
    os.makedirs(sessions, mode=0o700, exist_ok=True)
    return home, os.path.join(sessions, session + '.sock')


def ssh_env(serial, polls, poll_ms=100):
    return {
        'SSH_CONNECTION': f'127.0.0.1 {46000 + serial} 127.0.0.1 8022',
        'SSH_TTY': f'/dev/pts/superterm-progress-{serial}',
        'LANG': 'C.UTF-8',
        'SUPERTERM_TESTING': '1',
        'SUPERTERM_TEST_ATTACH_POLLS': str(polls),
        'SUPERTERM_TEST_ATTACH_POLL_MS': str(poll_ms),
    }


def wait_for_log(client, path, token, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        client.drain(0.04)
        try:
            with open(path, encoding='utf-8', errors='replace') as stream:
                if token in stream.read():
                    return True
        except FileNotFoundError:
            pass
        time.sleep(0.01)
    return False


def wait_for_deadline_record(client, path, timeout):
    """Return the final test-build deadline telemetry tuple, if complete."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        client.drain(0.04)
        try:
            with open(path, encoding='utf-8', errors='replace') as stream:
                matches = DEADLINE_RE.findall(stream.read())
        except FileNotFoundError:
            matches = []
        if matches:
            return tuple(map(int, matches[-1]))
        time.sleep(0.01)
    return None


class FakeSnapshotServer:
    def __init__(self, path, payload, fragments, delay):
        self.path = path
        self.payload = payload
        self.fragments = fragments
        self.delay = delay
        self.attach = threading.Event()
        self.sent = threading.Event()
        self.stop = threading.Event()
        self.sent_count = 0
        self.sent_ticks = []
        self.attach_tick = None
        self.error = None
        self.peer = None
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(path)
        self.listener.listen(4)
        self.listener.settimeout(0.2)
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _next_attach(self):
        while not self.stop.is_set():
            try:
                peer, _ = self.listener.accept()
            except socket.timeout:
                continue
            peer.settimeout(2.0)
            try:
                header = receive_exact(peer, 8)
                if header is None:
                    peer.close()
                    continue
                kind, _reserved, _pane, size = struct.unpack('<BBhI', header)
                body = receive_exact(peer, size)
                if kind == FRAME_ATTACH and body is not None:
                    return peer
            except OSError:
                pass
            peer.close()
        return None

    def _run(self):
        peer = None
        try:
            peer = self._next_attach()
            if peer is None:
                return
            self.peer = peer
            self.attach_tick = time.monotonic()
            self.attach.set()
            start = 0
            total = len(self.payload)
            for index in range(self.fragments):
                end = (total * (index + 1)) // self.fragments
                if end <= start:
                    continue
                peer.sendall(self.payload[start:end])
                self.sent_count += 1
                self.sent_ticks.append(time.monotonic())
                start = end
                if self.stop.wait(self.delay):
                    return
            self.sent.set()
            self.stop.wait(5.0)
        except (BrokenPipeError, ConnectionResetError, OSError) as error:
            if not self.stop.is_set():
                self.error = error
        finally:
            if peer is not None:
                peer.close()
            self.peer = None

    def close(self):
        self.stop.set()
        peer = self.peer
        if peer is not None:
            try:
                peer.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            peer.close()
        self.listener.close()
        self.thread.join(timeout=2.0)
        try:
            os.unlink(self.path)
        except FileNotFoundError:
            pass
        return not self.thread.is_alive()

    def max_send_gap(self):
        ticks = ([self.attach_tick] if self.attach_tick is not None else [])
        ticks += self.sent_ticks
        if len(ticks) < 2:
            return None
        return max(after - before for before, after in zip(ticks, ticks[1:]))

    def progress_span(self):
        if self.attach_tick is None or not self.sent_ticks:
            return 0.0
        return self.sent_ticks[-1] - self.attach_tick


# More readiness cycles than the configured historical poll count must still
# complete inside one total deadline. The test-only one-second poll quantum
# keeps every intended 15 ms progress interval distinguishable from inactivity
# even when a virtualized Darwin runner schedules Python in coarse slices.
progress_home, progress_path = prepare_home(
    'attach-progress-budget', 'progress')
progress_payload = empty_snapshot('progress-' + 'x' * 512)
progress_server = FakeSnapshotServer(
    progress_path, progress_payload, fragments=48, delay=0.015)
progress_client = None
progress_stopped = False
try:
    progress_debug = os.path.join(progress_home, 'attach-progress.log')
    progress_env = ssh_env(1, 10, poll_ms=1000)
    progress_env['SUPERTERM_DEBUG'] = progress_debug
    progress_client = stlib.Client(
        progress_home, args=['--ssh-entry'], w=80, h=24,
        env=progress_env, lang='en')
    check('fragmented snapshot receives real ATTACH',
          progress_server.attach.wait(2.0))
    progress_sent = (progress_server.sent.wait(8.0) and
                     progress_server.sent_count >= 40 and
                     progress_server.error is None)
    check('fragmented snapshot sends every progress step', progress_sent)
    if not progress_sent:
        print('  progress diagnostic: sent_count={} max_gap={!r} error={!r}'
              .format(progress_server.sent_count,
                      progress_server.max_send_gap(),
                      progress_server.error))
    attached_remote = wait_for_log(
        progress_client, progress_debug, 'attach: panes=0 geom=0', 1.5)
    progress_deadline = wait_for_deadline_record(
        progress_client, progress_debug, 1.5)
    check('fragmented snapshot completes remote attach', attached_remote)
    check('fixture crosses historical readiness count',
          progress_deadline is not None and
          progress_deadline[0] > int(progress_env[
              'SUPERTERM_TEST_ATTACH_POLLS']) and
          progress_deadline[1:] == (0, 1))
    check('progress cycles do not exhaust attach budget',
          attached_remote and progress_deadline is not None and
          progress_deadline[2] == 1 and
          progress_client.wait_exit(0.1) is None)
    if progress_deadline is None:
        print('  progress diagnostic: deadline telemetry missing')
finally:
    if progress_client is not None:
        progress_client.close()
    progress_stopped = progress_server.close()
check('fragmented fixture stops cleanly', progress_stopped)


# Every fragment must arrive before the test-only one-second inactivity
# quantum, but the complete frame cannot fit inside the three-second total
# deadline. This is the slow-drip boundary that an inactivity-only timeout
# would leave open indefinitely. The observed maximum gap is part of the
# oracle, so a starved test host cannot manufacture a false product PASS.
drip_home, drip_path = prepare_home('attach-total-budget', 'slow-drip')
drip_server = FakeSnapshotServer(
    drip_path, empty_snapshot('slow-' + 'x' * 512),
    fragments=256, delay=0.05)
drip_client = None
drip_stopped = False
try:
    drip_debug = os.path.join(drip_home, 'attach-drip.log')
    drip_env = ssh_env(2, 3, poll_ms=1000)
    drip_env['SUPERTERM_DEBUG'] = drip_debug
    drip_client = stlib.Client(
        drip_home, args=['--ssh-entry'], w=80, h=24,
        env=drip_env, lang='en')
    attached = drip_server.attach.wait(2.0)
    status = drip_client.wait_exit(7.0)
    drip_deadline = wait_for_deadline_record(
        drip_client, drip_debug, 1.5)
    elapsed = (time.monotonic() - drip_server.attach_tick
               if drip_server.attach_tick is not None else 0.0)
    max_gap = drip_server.max_send_gap()
    progress_span = drip_server.progress_span()
    check('slow-drip listener receives real ATTACH', attached)
    exact_deadline = (drip_deadline is not None and
                      drip_deadline[1:] == (1, 0))
    check('slow-drip exits through total deadline', exact_deadline)
    total_deadline_ok = (
        status is not None and os.WIFEXITED(status) and
        os.WEXITSTATUS(status) == 0 and 2.20 <= elapsed < 7.0 and
        drip_server.sent_count >= 4 and max_gap is not None and
        max_gap < 0.80 and progress_span >= 2.20 and exact_deadline)
    check('progress cannot extend total attach deadline', total_deadline_ok)
    if not total_deadline_ok:
        print('  drip diagnostic: sent_count={} max_gap={!r} '
              'progress_span={:.3f} deadline={!r} error={!r} status={!r} '
              'exited={} exitcode={!r} elapsed={:.3f}'
              .format(
                  drip_server.sent_count, max_gap, progress_span,
                  drip_deadline, drip_server.error, status,
                  status is not None and os.WIFEXITED(status),
                  (os.WEXITSTATUS(status) if status is not None and
                   os.WIFEXITED(status) else None), elapsed))
finally:
    if drip_client is not None:
        drip_client.close()
    drip_stopped = drip_server.close()
check('slow-drip fixture stops cleanly', drip_stopped)


stlib.report()
