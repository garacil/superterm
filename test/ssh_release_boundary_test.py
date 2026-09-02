#!/usr/bin/env python3
"""The installed administration binary cannot enable test hooks.

This test is deliberately unprivileged.  A production build must reject the
administrative request before an environment variable can redirect writes or
helpers; a mistakenly test-enabled release would instead create the private
fixture and execute the marker.  Running ``setup`` as root would be the wrong
oracle because a correct release ignores the override and would start working
on the real /etc/superterm/sshd tree.
"""

import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check


HOME = stlib.fresh_home('ssh-release-boundary')
RELEASE_BIN = os.environ.get('SUPERTERM_RELEASE_BIN', os.path.abspath(
    os.path.join(os.path.dirname(__file__), '..', 'bin', 'superterm')))

if os.geteuid() == 0:
    print('unprivileged release boundary         : SKIP (run as non-root)')
    stlib.report()

root = os.path.join(HOME, 'forbidden-release-override')
marker = os.path.join(HOME, 'forbidden-helper-ran')
fake = os.path.join(HOME, 'fake-root-helper')
with open(fake, 'w', encoding='utf-8') as stream:
    stream.write('#!/bin/sh\n')
    stream.write('printf ran > "$SUPERTERM_BOUNDARY_MARKER"\n')
    stream.write('exit 0\n')
os.chmod(fake, 0o755)

env = dict(os.environ,
           HOME=HOME,
           TERM='xterm',
           LANG='C',
           SUPERTERM_TESTING='1',
           SUPERTERM_SSHD_ROOT=root,
           SUPERTERM_TEST_SSHD=fake,
           SUPERTERM_TEST_EXPECT_SSHD=fake,
           SUPERTERM_TEST_SSH_KEYGEN=fake,
           SUPERTERM_TEST_SYSTEMCTL=fake,
           SUPERTERM_TEST_LAUNCHCTL=fake,
           SUPERTERM_TEST_SERVICE_MANAGER='1',
           SUPERTERM_BOUNDARY_MARKER=marker)
result = subprocess.run(
    [RELEASE_BIN, 'ssh-server', 'setup'], env=env, text=True,
    capture_output=True, timeout=10)
check('unprivileged release rejects test hooks',
      result.returncode != 0 and
      not os.path.lexists(root) and not os.path.lexists(marker))

stlib.report()
