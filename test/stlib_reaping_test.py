#!/usr/bin/env python3
"""superterm test: the fixture must not report a dead process as running.

Client.wait_exit returning None is how every suite asks "did this client hang?"
-- the deadlines exist precisely to catch a client that will not die. So None
has to mean "still running" and nothing else.

It used to also mean two other things, both of which are dead processes:

  * the child exited and something else reaped it first, so waitpid raised
    ECHILD and wait_exit returned its unset _wait_status; and
  * an earlier alive() call learned the child was gone, set _reaped without
    recording a status, and every later wait_exit took the already-reaped
    fast path straight to None.

That cost a green run of ssh_entry_test: `lost SSH client exits` failed while
the very next check confirmed the daemon had seen that same client disconnect.
Measured separately, a client dies 0.4-1.0 ms after SIGHUP, so the 5 s budget
was never the issue -- the harness simply lost the answer.

_wait_pid_until had the right convention all along (ECHILD -> 0, "already
reaped by its owner"). These checks hold the three reapers to it together, with
no superterm process involved: the point is the state machine, not the product.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import stlib  # noqa: E402
from stlib import check, report  # noqa: E402


def wrap(pid):
    """A Client around an existing child, with what drain() needs and no more.

    Deliberately not a real superterm: the behaviour under test is the reaping
    state machine, and a product process would only add ways for the test to
    fail for unrelated reasons.
    """
    read_fd, write_fd = os.pipe()
    _open_fds.append(write_fd)
    client = object.__new__(stlib.Client)
    client.pid = pid
    client.fd = read_fd
    client._reaped = False
    client._wait_status = None
    client._raw = b''
    client.stream = None
    client.dsr = (1, 1)
    client._transition_capture = False
    return client


_open_fds = []


def detached_client():
    """A child that exits immediately, wrapped as a Client."""
    pid = os.fork()
    if pid == 0:                       # pragma: no cover - child never returns
        os._exit(0)
    return wrap(pid)


def sleeping_client():
    """A child that blocks until signalled, wrapped as a Client.

    It blocks on a read from a pipe nobody writes to rather than on pause():
    the read is portable across Python versions and cannot be mistaken for the
    child having crashed on its own.
    """
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


def gone(pid):
    """True once the PID cannot be signalled at all."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    except PermissionError:
        return False
    return False


# --- reaped by somebody else before wait_exit is ever called ---------------
client = detached_client()
os.waitpid(client.pid, 0)
status = client.wait_exit(1.0)
check('a child reaped elsewhere still reports an exit', status is not None)
check('and reports it as a clean exit',
      status is not None and os.WIFEXITED(status) and
      os.WEXITSTATUS(status) == 0)

# --- alive() learns it first, wait_exit must not lose the fact ------------
client = detached_client()
os.waitpid(client.pid, 0)
check('alive() reports a reaped child as not alive', not client.alive())
check('alive() records the exit it discovered',
      client._wait_status is not None)
check('a later wait_exit still reports the exit',
      client.wait_exit(1.0) is not None)
check('repeated wait_exit keeps reporting it',
      client.wait_exit(1.0) is not None)

# --- the exact corrupt state the old code left behind ---------------------
# _reaped set with no status recorded. wait_exit's already-reaped fast path
# returned that unset status directly, so once a Client reached this state it
# reported "did not exit" for the rest of the suite, however long it waited.
client = detached_client()
os.waitpid(client.pid, 0)
client._reaped = True
client._wait_status = None
check('a Client left half-reaped still reports the exit',
      client.wait_exit(1.0) is not None)

# --- the ordinary case must keep working ----------------------------------
client = detached_client()
status = client.wait_exit(5.0)
check('an ordinary exit is reported', status is not None)
check('an ordinary exit carries its real status',
      status is not None and os.WIFEXITED(status) and
      os.WEXITSTATUS(status) == 0)
check('the reaped child is really gone', gone(client.pid))

# --- a signalled exit keeps its true status, not the synthetic one --------
client = sleeping_client()
os.kill(client.pid, 15)
status = client.wait_exit(5.0)
check('a signalled exit is reported', status is not None)
check('a signalled exit is not flattened into a clean one',
      status is not None and os.WIFSIGNALED(status))

# --- and None must still mean "still running" -----------------------------
client = sleeping_client()
check('a running child is reported as running', client.wait_exit(0.3) is None)
check('the running child was not reaped by the probe', not gone(client.pid))
os.kill(client.pid, 9)
check('and it is reported once it does exit',
      client.wait_exit(5.0) is not None)

for _fd in _open_fds:
    try:
        os.close(_fd)
    except OSError:
        pass

report()
