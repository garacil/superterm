#!/usr/bin/env python3
"""A dead daemon remains auditable without authorizing its recycled PID."""

import contextlib
import io
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check


home = stlib.fresh_home('stlib-crash-audit')
pid = os.getpid()
report_path = (
    f'/tmp/superterm-crash-daemon-{pid}-stlib-audit-'
    f'{os.getppid()}-{pid}.log')

# Register one exact old generation, then make identity resolution report a
# different generation for the same numeric PID. Any call to kill is a test
# failure: historical audit metadata must never become signalling authority.
stlib._known_daemons[home][pid] = 'recycled-test-daemon'
stlib._daemon_identities[home][pid] = 'old-generation'
stlib._auditable_daemons[home][pid] = 'recycled-test-daemon'
stlib._daemon_crash_baselines[home][pid] = set()
# A new suite-owned process is allowed to reuse the number; its independent
# registration must not overwrite the old daemon generation.
stlib._process_identities[pid] = 'recycled-generation'

original_identity = stlib._process_identity
original_kill = stlib.os.kill
original_check = stlib.check
kill_calls = []
audit_calls = []
detected = False
live = None
try:
    with open(report_path, 'w', encoding='utf-8') as stream:
        stream.write('synthetic daemon crash report\n')

    stlib._process_identity = lambda candidate: (
        'recycled-generation' if candidate == pid
        else original_identity(candidate))

    def forbidden_kill(candidate, signum):
        kill_calls.append((candidate, signum))
        raise AssertionError('historical PID was signalled')

    stlib.os.kill = forbidden_kill
    live = stlib._live_daemons(home)

    # Capture the audit verdict without printing an expected FAIL inside an
    # otherwise passing suite or contaminating its outer resource registry.
    stlib.check = lambda name, condition, width=36: audit_calls.append(
        (name, condition))
    audit_output = io.StringIO()
    with contextlib.redirect_stdout(audit_output):
        stlib._audit_daemon_crash_reports(home)
    detected = (audit_calls == [('daemon exits without fatal report', False)] and
                report_path in audit_output.getvalue())
finally:
    stlib._process_identity = original_identity
    stlib.os.kill = original_kill
    stlib.check = original_check
    try:
        os.unlink(report_path)
    except OSError:
        pass

check('dead generation leaves live index', live == [] and
      pid not in stlib._known_daemons[home])
check('dead generation remains auditable',
      stlib._auditable_daemons[home].get(pid) == 'recycled-test-daemon')
check('recycled PID is never signalled', not kill_calls)
check('historical crash report fails audit', detected)

stlib.report()
