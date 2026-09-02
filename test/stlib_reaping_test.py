#!/usr/bin/env python3
"""superterm test: process cleanup reports every terminal outcome honestly."""
import os
import sys

import pyte

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import stlib  # noqa: E402
from stlib import check, report  # noqa: E402


_open_fds = []


def wrap(pid):
    """Build the smallest Client fixture needed to exercise its reaper."""
    read_fd, write_fd = os.pipe()
    _open_fds.append(write_fd)
    client = object.__new__(stlib.Client)
    client.pid = pid
    client.fd = read_fd
    client._reaped = False
    client._wait_status = None
    client._reap_disposition = None
    client._raw = b''
    client.screen = pyte.Screen(8, 2)
    client.stream = pyte.ByteStream(client.screen)
    client.dsr = (1, 1)
    client._transition_capture = False
    return client


def exited_child():
    pid = os.fork()
    if pid == 0:                       # pragma: no cover - child never returns
        os._exit(0)
    return wrap(pid)


def sleeping_child():
    block_read, block_write = os.pipe()
    pid = os.fork()
    if pid == 0:                       # pragma: no cover - child never returns
        os.close(block_write)
        try:
            os.read(block_read, 1)
        except OSError:
            pass
        os._exit(0)
    os.close(block_read)
    _open_fds.append(block_write)
    return wrap(pid)


# A wait status collected here must not become "still running" in Client.
client = exited_child()
os.waitpid(client.pid, 0)
status = client.wait_exit(1.0)
check('reaped-elsewhere child reports an exit', status is not None)
check('reaped-elsewhere outcome stays explicit',
      client.reap_disposition == stlib.REAP_REAPED_ELSEWHERE)

# alive() is another reaper and must retain the same evidence for wait_exit().
client = exited_child()
os.waitpid(client.pid, 0)
check('alive rejects an already collected child', not client.alive())
check('alive records reaped-elsewhere outcome',
      client.reap_disposition == stlib.REAP_REAPED_ELSEWHERE)
check('later wait_exit retains the exit', client.wait_exit(0.0) is not None)

# Preserve compatibility with a half-reaped object created by an older caller.
client = exited_child()
os.waitpid(client.pid, 0)
client._reaped = True
check('half-reaped state is repaired', client.wait_exit(0.0) is not None)
check('half-reaped repair is accounted',
      client.reap_disposition == stlib.REAP_REAPED_ELSEWHERE)

# Normal wait ownership records the real wait status and its distinct outcome.
client = exited_child()
status = client.wait_exit(5.0)
check('owned child is reaped', status is not None)
check('owned reap keeps exact status',
      status is not None and os.WIFEXITED(status) and
      os.WEXITSTATUS(status) == 0)
check('owned reap outcome stays explicit',
      client.reap_disposition == stlib.REAP_REAPED)

# A live child at the requested deadline is a leak verdict, not an unknown.
client = sleeping_child()
check('live deadline returns no exit status', client.wait_exit(0.1) is None)
check('live deadline is accounted as leaked',
      client.reap_disposition == stlib.REAP_LEAKED)
os.kill(client.pid, 15)
status = client.wait_exit(5.0)
check('later exit replaces the live verdict', status is not None)
check('later owned reap replaces leaked outcome',
      client.reap_disposition == stlib.REAP_REAPED)

# The final existence probe has its own outcome when waitpid observed no exit.
client = wrap(2_147_483_647)
original_waitpid = stlib.os.waitpid
try:
    stlib.os.waitpid = lambda _pid, _flags: (0, 0)
    status = client.wait_exit(0.0)
finally:
    stlib.os.waitpid = original_waitpid
check('vanished process reports an exit', status is not None)
check('vanished outcome stays distinct',
      client.reap_disposition == stlib.REAP_VANISHED)

# Stale identities are neither live nor signalling authority. The dedicated
# daemon_identity_safety_test exercises malformed sidecars and the runner too.
pid = os.getpid()
check('stale identity is rejected', not stlib._alive(pid, 'proc:0'))
kill_calls = []
original_kill = stlib.os.kill
try:
    stlib.os.kill = lambda candidate, signum: kill_calls.append(
        (candidate, signum))
    signalled = stlib._signal_if_identity(pid, 'proc:0', 15)
finally:
    stlib.os.kill = original_kill
check('stale identity cannot authorize a signal', not signalled)
check('stale identity emits no signal', kill_calls == [])

for fd in _open_fds:
    try:
        os.close(fd)
    except OSError:
        pass

report()
