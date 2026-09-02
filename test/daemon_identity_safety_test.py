#!/usr/bin/env python3
"""A stale daemon sidecar can never authorize a recycled numeric PID.

These cases are deterministic: no PID churn or timing assumption is used.
Old and mismatched sidecars still receive the protocol-level close attempt,
while both cleanup layers refuse to put their PID in an escalation set.
"""

import ctypes
import os
import socket
import struct
import subprocess
import sys
import tempfile
import threading

sys.path.insert(0, os.path.dirname(__file__))
import run_tests as runner
import stlib
from stlib import check


# Linux field 2 is allowed to contain spaces and ')'. Both independent
# readers must find the final delimiter and then field 22, not split the
# complete line naively.
tail = ['S'] + [str(field * 11) for field in range(4, 22)] + ['987654321']
stat_fixture = '4242 (worker ) with spaces) ' + ' '.join(tail)
check('stlib parses adversarial stat comm',
      stlib._linux_identity_from_stat(stat_fixture) == 'proc:987654321')
check('runner parses adversarial stat comm',
      runner.linux_identity_from_stat(stat_fixture) == 'proc:987654321')
check('malformed identities fail validation',
      not any(stlib._valid_process_identity(value) for value in (
          '', 'proc:', 'proc:-1', 'proc:abc', 'darwin:1',
          'darwin:1:-1', 'darwin:1:1000000', 'other:1')))


# Apple xnu exposes SZOMB=5 through proc_bsdinfo.pbi_status. Exercise that
# branch deterministically even on a GNU/Linux development host: a zombie is
# finished for cleanup purposes, while an otherwise identical live status is
# not. The strong birth identity is still checked first.
class FakeDarwinInfo:
    def __init__(self, status, start_sec=7, start_usec=11):
        self.pbi_status = status
        self.pbi_start_tvsec = start_sec
        self.pbi_start_tvusec = start_usec


our_identity = stlib.process_identity(os.getpid())
original_darwin_info = stlib._darwin_proc_bsd_info
original_process_identity = stlib._process_identity
original_runner_darwin_info = runner.darwin_proc_bsd_info
original_runner_process_identity = runner.process_identity
try:
    stlib._process_identity = lambda _pid: our_identity
    stlib._darwin_proc_bsd_info = lambda _pid: FakeDarwinInfo(5)
    darwin_zombie_finished = stlib.process_finished(
        os.getpid(), our_identity)
    stlib._darwin_proc_bsd_info = lambda _pid: FakeDarwinInfo(2)
    darwin_live_finished = stlib.process_finished(
        os.getpid(), our_identity)
    runner.process_identity = lambda _pid: our_identity
    runner.darwin_proc_bsd_info = lambda _pid: FakeDarwinInfo(5)
    runner_darwin_zombie_finished = runner.process_finished(
        os.getpid(), our_identity)
    runner.darwin_proc_bsd_info = lambda _pid: FakeDarwinInfo(2)
    runner_darwin_live_finished = runner.process_finished(
        os.getpid(), our_identity)
finally:
    stlib._darwin_proc_bsd_info = original_darwin_info
    stlib._process_identity = original_process_identity
    runner.darwin_proc_bsd_info = original_runner_darwin_info
    runner.process_identity = original_runner_process_identity
check('Darwin zombie status is an exit oracle',
      bool(our_identity) and darwin_zombie_finished and
      not darwin_live_finished and runner_darwin_zombie_finished and
      not runner_darwin_live_finished)

original_darwin_info = stlib._darwin_proc_bsd_info
try:
    stlib._darwin_proc_bsd_info = lambda _pid: FakeDarwinInfo(5)
    strong_darwin_zombie = stlib.process_is_zombie(
        87654320, 'darwin:7:11')
    recycled_darwin_zombie = stlib.process_is_zombie(
        87654320, 'darwin:7:12')
finally:
    stlib._darwin_proc_bsd_info = original_darwin_info
check('zombie observation is birth-qualified',
      strong_darwin_zombie and not recycled_darwin_zombie)


# timeout=0 is a non-blocking query, not permission to skip waitpid entirely.
# Stub only this one kernel call so the regression is deterministic and owns
# no real process.
wait_probe = object.__new__(stlib.Client)
wait_probe.pid = 87654321
wait_probe._reaped = False
wait_probe._wait_status = None
wait_calls = []
original_waitpid = stlib.os.waitpid
try:
    def completed_waitpid(candidate, options):
        wait_calls.append((candidate, options))
        return candidate, 0

    stlib.os.waitpid = completed_waitpid
    zero_status = wait_probe.wait_exit(0.0)
finally:
    stlib.os.waitpid = original_waitpid
check('zero-time wait still probes child once',
      zero_status == 0 and
      wait_calls == [(wait_probe.pid, os.WNOHANG)])


# Missing birth identity must visibly fail registration and must not emit a
# bare cleanup record.  Capture the expected failure locally so this safety
# proof does not make the enclosing suite fail.
identity_probe_pid = 87654322
registration_failures = []
original_identity_reader = stlib._process_identity
original_check = stlib.check
try:
    stlib._process_identity = lambda candidate: ''
    stlib.check = lambda name, condition, width=36: (
        registration_failures.append((name, condition)))
    registration = stlib.register_process(
        identity_probe_pid, 'missing-identity-probe')
finally:
    stlib._process_identity = original_identity_reader
    stlib.check = original_check
check('empty process identity fails registration',
      registration == '' and identity_probe_pid not in
      stlib._process_identities and
      registration_failures == [
          ('registered process identity is available', False)])


# Exercise the Pascal implementation itself. On Linux, deliberately put both
# a space and ')' in this Python process's kernel comm before the helper asks
# ProcBirthIdentity for our PID. On Darwin the same helper validates the exact
# 136-byte proc_bsdinfo ABI against the independent ctypes reader in stlib.
project = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
helper_program = r'''program birth_identity_helper;
{$mode objfpc}{$H+}
uses
  SysUtils, st_pty;
var
  Pid: LongInt;
begin
  if (ParamCount <> 1) or (not TryStrToInt(ParamStr(1), Pid)) then
    Halt(2);
  WriteLn(ProcBirthIdentity(Pid));
end.
'''
with tempfile.TemporaryDirectory(prefix='st-birth-helper-') as build:
    source = os.path.join(build, 'birth_identity_helper.pas')
    helper = os.path.join(build, 'birth_identity_helper')
    with open(source, 'w', encoding='utf-8') as stream:
        stream.write(helper_program)
    compiled = subprocess.run([
        'fpc', '-Mobjfpc', '-Sh', '-vewnh', '-vm11030,11031',
        '-Fu' + os.path.join(project, 'src'),
        '-FU' + build, '-FE' + build, '-o' + helper, source,
    ], text=True, capture_output=True, timeout=60)
    diagnostics = [
        line for line in (compiled.stdout + compiled.stderr).splitlines()
        if any(marker in line for marker in
               (' Warning:', ' Note:', ' Hint:', ' Error:', ' Fatal:'))
    ]
    check('birth identity helper compiles cleanly',
          compiled.returncode == 0 and not diagnostics)
    if diagnostics:
        print('\n'.join(diagnostics))

    old_comm = None
    libc = None
    if compiled.returncode == 0 and sys.platform.startswith('linux'):
        libc = ctypes.CDLL(None, use_errno=True)
        old_comm = ctypes.create_string_buffer(16)
        if libc.prctl(16, ctypes.byref(old_comm), 0, 0, 0) != 0:
            old_comm = None
        elif libc.prctl(15, ctypes.c_char_p(b'worker ) space'),
                        0, 0, 0) != 0:
            old_comm = None
    try:
        if compiled.returncode == 0:
            pascal_identity = subprocess.run(
                [helper, str(os.getpid())], text=True, capture_output=True,
                timeout=10).stdout.strip()
            check('Pascal birth identity matches kernel',
                  pascal_identity == stlib.process_identity(os.getpid()) and
                  stlib._valid_process_identity(pascal_identity))
    finally:
        if old_comm is not None:
            libc.prctl(15, ctypes.cast(old_comm, ctypes.c_char_p), 0, 0, 0)


home = stlib.fresh_home('daemon-identity-safety')
sessions = stlib.sessions_dir(home)
os.makedirs(sessions, mode=0o700, exist_ok=True)
pid = os.getpid()
with open(os.path.join(sessions, 'old.ini'), 'w', encoding='utf-8') as stream:
    stream.write('[session]\nname=old\npid=%d\n' % pid)
with open(os.path.join(sessions, 'mismatch.ini'), 'w',
          encoding='utf-8') as stream:
    stream.write('[session]\nname=mismatch\npid=%d\n'
                 'pid_identity=proc:0\n' % pid)
with open(os.path.join(sessions, 'malformed.ini'), 'w',
          encoding='utf-8') as stream:
    stream.write('[session\nthis is not an ini file\n')
with open(os.path.join(sessions, 'incomplete.ini'), 'w',
          encoding='utf-8') as stream:
    stream.write('[session]\nname=incomplete\n')

# One real Unix listener proves that lack of signalling authority does not
# suppress the safe FRAME_CLOSE route.
socket_path = os.path.join(sessions, 'old.sock')
listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
listener.bind(socket_path)
listener.listen(1)
listener.settimeout(3.0)
received = []

# A socket symlink under the private session directory must never redirect a
# protocol close to another endpoint.  The target is also suite-owned, which
# lets the test observe the absence of a connection without risking a real
# session.
foreign_socket_path = os.path.join(home, 'not-a-session.sock')
foreign_listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
foreign_listener.bind(foreign_socket_path)
foreign_listener.listen(1)
foreign_listener.setblocking(False)
linked_socket_path = os.path.join(sessions, 'linked.sock')
os.symlink(foreign_socket_path, linked_socket_path)


def receive_close():
    try:
        peer, _address = listener.accept()
        with peer:
            data = b''
            while len(data) < 8:
                chunk = peer.recv(8 - len(data))
                if not chunk:
                    break
                data += chunk
            if len(data) == 8:
                received.append(struct.unpack('<BBhI', data))
    except OSError:
        pass
    finally:
        listener.close()


receiver = threading.Thread(target=receive_close, name='sidecar-close-receiver')
receiver.start()
original_kill = stlib.os.kill
kill_calls = []


def forbidden_kill(candidate, signum):
    kill_calls.append((candidate, signum))
    raise AssertionError('untrusted sidecar authorized a signal')


try:
    stlib.os.kill = forbidden_kill
    original_check = stlib.check
    identity_failures = []

    def capture_identity_failure(name, condition, width=36):
        identity_failures.append((name, condition))

    stlib.check = capture_identity_failure
    try:
        trusted = stlib._sidecar_pids(home)
        # Repeat both paths to prove rescan noise is suppressed while socket
        # close remains available for claims which cannot authorize signals.
        stlib._sidecar_pids(home)
        stlib.close_all_daemons(home)
    finally:
        stlib.check = original_check
finally:
    stlib.os.kill = original_kill
    receiver.join(timeout=4.0)
    listener.close()

check('old and mismatched sidecars untrusted', trusted == [])
check('every invalid sidecar fails harness once',
      len(identity_failures) == 4 and
      all(not condition for _name, condition in identity_failures))
check('untrusted sidecars never signal', kill_calls == [])
check('old sidecar still receives FRAME_CLOSE',
      len(received) == 1 and received[0][0] == stlib.FRAME_CLOSE and
      received[0][2] == -1 and received[0][3] == 0)

# Exercise the outer cleanup implementation against the same link too.
runner.request_home_daemons_close(home)
foreign_contacted = False
try:
    peer, _address = foreign_listener.accept()
    foreign_contacted = True
    peer.close()
except BlockingIOError:
    pass
finally:
    foreign_listener.close()
check('socket symlink is never followed for close',
      not foreign_contacted and
      linked_socket_path not in stlib.session_sockets(home))


# The outer deadline runner must make the same fail-closed decision when a
# suite died before it could write a resource-registry daemon record.
with tempfile.TemporaryDirectory(prefix='st-daemon-identity-runner-') as root:
    fallback_home = os.path.join(root, 'home')
    fallback_sessions = os.path.join(
        fallback_home, '.superterm', 'sessions')
    os.makedirs(fallback_sessions)
    for name, identity in (('old', ''), ('mismatch', 'proc:0')):
        with open(os.path.join(fallback_sessions, name + '.ini'), 'w',
                  encoding='utf-8') as stream:
            stream.write('[session]\npid=%d\n' % pid)
            if identity:
                stream.write('pid_identity=%s\n' % identity)
    with open(os.path.join(fallback_sessions, 'malformed.ini'), 'w',
              encoding='utf-8') as stream:
        stream.write('[session\nnot valid\n')
    with open(os.path.join(fallback_sessions, 'incomplete.ini'), 'w',
              encoding='utf-8') as stream:
        stream.write('[session]\nname=incomplete\n')
    registry = os.path.join(root, 'resources')
    with open(registry, 'w', encoding='utf-8') as stream:
        stream.write('home\t%s\n' % fallback_home)
    original_identity = runner.process_identity
    try:
        runner.process_identity = lambda candidate: 'proc:123456'
        _homes, fallback_pids, fallback_failures = runner.registered_resources(
            registry)
    finally:
        runner.process_identity = original_identity
    check('runner rejects old and mismatched sidecars', fallback_pids == {})
    check('runner reports every invalid sidecar once',
          len([failure for failure in fallback_failures
               if failure.startswith(
                   'unverifiable daemon sidecar: ')]) == 4)
    close_attempts = []
    original_request_close = runner.request_home_daemons_close
    try:
        runner.request_home_daemons_close = close_attempts.append
        runner.cleanup_registered_resources(registry, settle=0.0)
    finally:
        runner.request_home_daemons_close = original_request_close
    check('runner still attempts FRAME_CLOSE',
          close_attempts == [fallback_home])

    # Generation-qualified completion cannot erase a newer owner of the same
    # numeric PID. A historical bare completion is readable but has no
    # authority to erase a generation-qualified owner.
    with open(registry, 'w', encoding='utf-8') as stream:
        stream.write(
            'daemon\t%s\t777\told\tproc:100\n'
            'daemon\t%s\t777\tnew\tproc:200\n'
            'daemon_done\t777\tproc:100\n' %
            (fallback_home, fallback_home))
    _homes, qualified_pids, _failures = runner.registered_resources(registry)
    check('daemon_done is generation-qualified',
          qualified_pids.get(777) == 'proc:200')

    with open(registry, 'a', encoding='utf-8') as stream:
        stream.write('daemon_done\t777\n')
    _homes, legacy_done_pids, _failures = runner.registered_resources(registry)
    check('bare daemon_done cannot erase qualified owner',
          legacy_done_pids.get(777) == 'proc:200')


stlib.report()
