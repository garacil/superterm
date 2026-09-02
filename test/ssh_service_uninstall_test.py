#!/usr/bin/env python3
"""SSH service removal is exact, transactional and packaging-safe.

All descriptors live below private SUPERTERM_SSHD_ROOT directories and every
systemd/launchd operation is handled by one stateful fake executable.  Even
the Makefile checks therefore cannot inspect or modify a host service.
"""

import os
import shutil
import stat
import subprocess
import sys

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check


PROJECT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
HOME = stlib.fresh_home('ssh-service-uninstall')
ROOT = os.path.join(HOME, 'installed-sshd')
MANAGER = os.path.join(HOME, 'fake-service-manager')
MANAGER_LOG = os.path.join(HOME, 'service-manager.log')
MANAGER_STATE = os.path.join(HOME, 'service-manager.state')
FAIL_MARKER = os.path.join(HOME, 'service-manager-failed-once')
IS_DARWIN = sys.platform == 'darwin'
MANAGER_OVERRIDE = ('SUPERTERM_TEST_LAUNCHCTL' if IS_DARWIN
                    else 'SUPERTERM_TEST_SYSTEMCTL')


def base_env(root):
    return dict(os.environ,
                HOME=HOME,
                TERM='xterm',
                LANG='C',
                SUPERTERM_INI=os.path.join(HOME, 'no-system.ini'),
                SUPERTERM_TESTING='1',
                SUPERTERM_SSHD_ROOT=root)


def admin(*args, root=ROOT, binary=stlib.BIN, manager=False,
          fail_action='', timeout=45):
    env = base_env(root)
    if manager:
        env.update(manager_env(fail_action))
    return subprocess.run([binary, 'ssh-server', *args], text=True,
                          capture_output=True, env=env, timeout=timeout)


def descriptor_path(root):
    leaf = ('org.superterm.sshd.plist' if IS_DARWIN
            else 'superterm-sshd.service')
    return os.path.join(root, 'service', leaf)


def write_state(enabled, active):
    with open(MANAGER_STATE, 'w', encoding='ascii') as stream:
        stream.write(f'enabled={int(enabled)}\nactive={int(active)}\n')


def read_state():
    values = {}
    with open(MANAGER_STATE, encoding='ascii') as stream:
        for line in stream:
            key, value = line.strip().split('=', 1)
            values[key] = int(value)
    return values['enabled'], values['active']


def reset_manager(enabled=True, active=True):
    write_state(enabled, active)
    for path in (MANAGER_LOG, FAIL_MARKER):
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass


def manager_env(fail_action=''):
    return {
        'SUPERTERM_TEST_SERVICE_MANAGER': '1',
        MANAGER_OVERRIDE: MANAGER,
        'SUPERTERM_TEST_SERVICE_KIND': 'launchd' if IS_DARWIN else 'systemd',
        'SUPERTERM_TEST_SERVICE_LOG': MANAGER_LOG,
        'SUPERTERM_TEST_SERVICE_STATE': MANAGER_STATE,
        'SUPERTERM_TEST_SERVICE_FAIL_ACTION': fail_action,
        'SUPERTERM_TEST_SERVICE_FAIL_MARKER': FAIL_MARKER,
    }


def calls():
    if not os.path.exists(MANAGER_LOG):
        return []
    with open(MANAGER_LOG, encoding='utf-8') as stream:
        return stream.read().splitlines()


def file_record(path):
    info = os.lstat(path)
    if stat.S_ISDIR(info.st_mode):
        data = None
    else:
        with open(path, 'rb') as stream:
            data = stream.read()
    return stat.S_IMODE(info.st_mode), data


def replace_descriptor_once(data, old, new):
    """Mutate one generated invariant without accidentally weakening a test."""
    if data.count(old) != 1:
        raise AssertionError(
            f'descriptor fixture expected exactly one {old!r}, '
            f'found {data.count(old)}')
    return data.replace(old, new, 1)


def write_descriptor(path, data):
    with open(path, 'wb') as stream:
        stream.write(data)
    os.chmod(path, 0o644)


def descriptor_without_marker(data):
    marker = (b'<!-- X-SuperTerm-Managed-Service: '
              b'org.superterm.sshd/v1 -->\n' if IS_DARWIN else
              b'# X-SuperTerm-Managed-Service: org.superterm.sshd/v1\n')
    return replace_descriptor_once(data, marker, b'')


def descriptor_with_changed_identity(data):
    return replace_descriptor_once(
        data, b'org.superterm.sshd/v1', b'org.foreign.sshd/v1')


def descriptor_with_changed_command(data):
    if IS_DARWIN:
        return replace_descriptor_once(
            data, b'    <string>run</string>\n',
            b'    <string>status</string>\n')
    return replace_descriptor_once(
        data, b' ssh-server run\n', b' ssh-server status\n')


def descriptor_from_older_release(data):
    """Keep ownership/entry invariants but vary one harmless policy field."""
    if IS_DARWIN:
        return replace_descriptor_once(
            data,
            b'<key>ThrottleInterval</key><integer>2</integer>',
            b'<key>ThrottleInterval</key><integer>3</integer>')
    return replace_descriptor_once(data, b'RestartSec=2s', b'RestartSec=3s')


def persistent_snapshot(root):
    """Only state the removal contract promises never to modify."""
    names = (
        'server.ini',
        'sshd_config.generated',
        'ssh_host_ed25519_key',
        'ssh_host_ed25519_key.pub',
        'authorized_keys',
        'authorized_keys/preservation-sentinel',
    )
    return {name: file_record(os.path.join(root, name)) for name in names}


def prepare_root(root, binary=stlib.BIN):
    result = admin('setup', root=root, binary=binary)
    check('isolated SSH fixture is prepared', result.returncode == 0)
    if result.returncode != 0:
        print(result.stderr.strip())
        return False
    sentinel = os.path.join(root, 'authorized_keys', 'preservation-sentinel')
    with open(sentinel, 'wb') as stream:
        stream.write(b'configuration and keys stay byte-for-byte\n')
    os.chmod(sentinel, 0o644)
    return True


def make_uninstall(root, bindir, *, destdir='', fail_action=''):
    env = base_env(root)
    env.update(manager_env(fail_action))
    args = [
        'make', '-f', os.path.join(PROJECT, 'Makefile'), 'uninstall',
        f'BINDIR={bindir}',
        f'DOCDIR={os.path.join(HOME, "package-doc")}',
        f'SYSCONFDIR={os.path.join(HOME, "package-etc")}',
        f'DATADIR={os.path.join(HOME, "package-data")}',
    ]
    if destdir:
        args.append(f'DESTDIR={destdir}')
    return subprocess.run(args, cwd=PROJECT, env=env, text=True,
                          capture_output=True, timeout=60)


with open(MANAGER, 'w', encoding='utf-8') as stream:
    stream.write(r'''#!/usr/bin/env python3
import os
import sys

args = sys.argv[1:]
log = os.environ['SUPERTERM_TEST_SERVICE_LOG']
state_path = os.environ['SUPERTERM_TEST_SERVICE_STATE']
with open(log, 'a', encoding='utf-8') as output:
    output.write(' '.join(args) + '\n')

state = {}
with open(state_path, encoding='ascii') as source:
    for line in source:
        key, value = line.strip().split('=', 1)
        state[key] = int(value)

def save():
    temporary = state_path + '.tmp.' + str(os.getpid())
    with open(temporary, 'w', encoding='ascii') as output:
        output.write('enabled=%d\nactive=%d\n' %
                     (state['enabled'], state['active']))
    os.replace(temporary, state_path)

action = args[0] if args else ''
fail_action = os.environ.get('SUPERTERM_TEST_SERVICE_FAIL_ACTION', '')
fail_marker = os.environ['SUPERTERM_TEST_SERVICE_FAIL_MARKER']
if action == fail_action and not os.path.exists(fail_marker):
    with open(fail_marker, 'w', encoding='ascii') as marker:
        marker.write(action + '\n')
    print('injected manager failure: ' + action, file=sys.stderr)
    sys.exit(91)

kind = os.environ['SUPERTERM_TEST_SERVICE_KIND']
if kind == 'systemd':
    if action == 'daemon-reload':
        sys.exit(0)
    if action == 'is-enabled':
        print('enabled' if state['enabled'] else 'disabled')
        sys.exit(0 if state['enabled'] else 1)
    if action == 'is-active':
        print('active' if state['active'] else 'inactive')
        sys.exit(0 if state['active'] else 3)
    if action == 'enable':
        state['enabled'] = 1
    elif action == 'disable':
        state['enabled'] = 0
        if '--now' in args:
            state['active'] = 0
    elif action == 'restart':
        state['active'] = 1
    elif action == 'stop':
        state['active'] = 0
    else:
        sys.exit(64)
    save()
    sys.exit(0)

if action == 'print-disabled':
    print('disabled services = {')
    if not state['enabled']:
        print('    "org.superterm.sshd" => true')
    print('}')
    sys.exit(0)
if action == 'print':
    if state['active']:
        print('system/org.superterm.sshd = { }')
        sys.exit(0)
    print('service is not loaded', file=sys.stderr)
    sys.exit(113)
if action == 'enable':
    state['enabled'] = 1
elif action == 'disable':
    state['enabled'] = 0
elif action == 'bootout':
    state['active'] = 0
elif action == 'bootstrap':
    if not state['enabled']:
        print('service is disabled', file=sys.stderr)
        sys.exit(78)
    state['active'] = 1
else:
    sys.exit(64)
save()
sys.exit(0)
''')
os.chmod(MANAGER, 0o755)


# An idempotent removal must not manufacture the persistent root merely to
# acquire its lock, and with no descriptor there is nothing to ask the manager.
missing_root = os.path.join(HOME, 'never-installed')
reset_manager()
missing = admin('uninstall-service', root=missing_root, manager=True)
check('missing descriptor removal is idempotent', missing.returncode == 0)
check('missing removal creates no persistent root',
      not os.path.lexists(missing_root))
check('missing removal never calls service manager', calls() == [])


if not prepare_root(ROOT):
    stlib.report()

descriptor = descriptor_path(ROOT)
with open(descriptor, 'rb') as stream:
    canonical_descriptor = stream.read()
persistent_before = persistent_snapshot(ROOT)

# The stable SuperTerm marker is necessary: the generic Generated-by comment,
# expected command and expected service fields are deliberately insufficient
# on their own.  Likewise, neither a foreign marker identity nor a modified
# entry command may cross the ownership boundary.  Every refusal happens
# before querying or changing the service manager.
refused_descriptors = (
    ('generic Generated-by descriptor without managed marker',
     descriptor_without_marker(canonical_descriptor)),
    ('descriptor with a foreign managed-service identity',
     descriptor_with_changed_identity(canonical_descriptor)),
    ('descriptor with a changed entry command',
     descriptor_with_changed_command(canonical_descriptor)),
)
for description, refused_bytes in refused_descriptors:
    write_descriptor(descriptor, refused_bytes)
    refused_record = file_record(descriptor)
    reset_manager()
    refused = admin('uninstall-service', manager=True)
    check(description + ' is refused', refused.returncode != 0)
    check(description + ' remains byte-for-byte',
          file_record(descriptor) == refused_record)
    check(description + ' causes no manager action', calls() == [])
    check(description + ' preserves persistent SSH state',
          persistent_snapshot(ROOT) == persistent_before)

write_descriptor(descriptor, canonical_descriptor)

# lstat must reject links before either following/removing their target or
# invoking a privileged manager.
link_target = os.path.join(HOME, 'foreign-service-target')
with open(link_target, 'wb') as stream:
    stream.write(canonical_descriptor)
os.unlink(descriptor)
os.symlink(link_target, descriptor)
reset_manager()
linked = admin('uninstall-service', manager=True)
check('symlink descriptor is refused', linked.returncode != 0)
check('symlink target and link remain untouched',
      os.path.islink(descriptor) and
      file_record(link_target)[1] == canonical_descriptor)
check('symlink descriptor causes no manager action', calls() == [])
os.unlink(descriptor)
with open(descriptor, 'wb') as stream:
    stream.write(canonical_descriptor)
os.chmod(descriptor, 0o644)

# A manager can fail after partly changing runtime state (launchd bootout is
# the concrete case).  The descriptor and the exact pre-call service state
# must be restored and make/uninstall must not be allowed to continue.
reset_manager(True, True)
disable_failed = admin('uninstall-service', manager=True,
                       fail_action='disable')
check('stop-disable failure is reported', disable_failed.returncode != 0)
check('stop-disable failure keeps descriptor',
      file_record(descriptor)[1] == canonical_descriptor)
check('stop-disable failure restores service state', read_state() == (1, 1))
check('stop-disable failure preserves persistent SSH state',
      persistent_snapshot(ROOT) == persistent_before)

if not IS_DARWIN:
    # systemd needs one daemon-reload after unlink.  Failure at that final
    # boundary restores both the exact descriptor and the old active policy.
    reset_manager(True, True)
    reload_failed = admin('uninstall-service', manager=True,
                          fail_action='daemon-reload')
    check('post-remove systemd reload failure is reported',
          reload_failed.returncode != 0)
    check('reload failure restores exact descriptor',
          file_record(descriptor)[1] == canonical_descriptor)
    check('reload failure restores exact service state',
          read_state() == (1, 1))
    check('reload rollback exercised both reload paths',
          sum(call == 'daemon-reload' for call in calls()) == 2)
    check('reload failure preserves persistent SSH state',
          persistent_snapshot(ROOT) == persistent_before)

reset_manager(True, True)
removed = admin('uninstall-service', manager=True)
check('verified descriptor is uninstalled', removed.returncode == 0)
check('successful uninstall removes only descriptor',
      not os.path.lexists(descriptor) and
      persistent_snapshot(ROOT) == persistent_before)
check('successful uninstall stops and disables service',
      read_state() == (0, 0))
successful_calls = calls()
if IS_DARWIN:
    check('launchd removal uses bootout then disable',
          any(call.startswith('bootout ') for call in successful_calls) and
          any(call.startswith('disable ') for call in successful_calls))
else:
    check('systemd removal disables now then reloads',
          any(call.startswith('disable --now ') for call in successful_calls) and
          successful_calls[-1] == 'daemon-reload')

# A second call stays a no-op, including at the manager boundary.
calls_before_repeat = list(successful_calls)
repeated = admin('uninstall-service', manager=True)
check('repeated service uninstall succeeds', repeated.returncode == 0)
check('repeated service uninstall is manager-free',
      calls() == calls_before_repeat)


# Descriptor policy fields can evolve between releases.  A descriptor with
# the stable marker and the exact SuperTerm identity/entry command remains
# owned even when one harmless generated field differs from today's form.
# Exercise this on a separate installation so the exact-descriptor rollback
# tests above remain independent of forward-compatibility recognition.
old_root = os.path.join(HOME, 'older-release-sshd')
if prepare_root(old_root):
    old_descriptor_path = descriptor_path(old_root)
    old_persistent = persistent_snapshot(old_root)
    with open(old_descriptor_path, 'rb') as stream:
        old_current = stream.read()
    old_descriptor = descriptor_from_older_release(old_current)
    check('older-release descriptor really differs from current descriptor',
          old_descriptor != old_current)
    write_descriptor(old_descriptor_path, old_descriptor)
    reset_manager(True, True)
    old_removed = admin('uninstall-service', root=old_root, manager=True)
    check('recognised older-release descriptor is uninstalled',
          old_removed.returncode == 0)
    check('older-release uninstall removes only its descriptor',
          not os.path.lexists(old_descriptor_path) and
          persistent_snapshot(old_root) == old_persistent)
    check('older-release uninstall stops and disables service',
          read_state() == (0, 0))
    check('older-release uninstall reaches the service manager',
          calls() != [])


# The real Makefile target must execute the installed binary first.  Injecting
# a manager failure proves that a failed administrative action prevents its
# subsequent rm recipe from deleting that binary.
failed_pkg_root = os.path.join(HOME, 'failed-package-sshd')
failed_pkg_bin_dir = os.path.join(HOME, 'failed-package-bin')
os.makedirs(failed_pkg_bin_dir)
failed_pkg_bin = os.path.join(failed_pkg_bin_dir, 'superterm')
shutil.copy2(stlib.BIN, failed_pkg_bin)
if prepare_root(failed_pkg_root, failed_pkg_bin):
    failed_pkg_descriptor = descriptor_path(failed_pkg_root)
    failed_pkg_persistent = persistent_snapshot(failed_pkg_root)
    reset_manager(True, True)
    failed_make = make_uninstall(failed_pkg_root, failed_pkg_bin_dir,
                                 fail_action='disable')
    check('make uninstall propagates service-removal failure',
          failed_make.returncode != 0)
    check('failed make uninstall keeps installed binary and descriptor',
          os.path.isfile(failed_pkg_bin) and
          os.path.isfile(failed_pkg_descriptor))
    check('failed make uninstall preserves package SSH state',
          persistent_snapshot(failed_pkg_root) == failed_pkg_persistent)


# On success that same ordering removes the descriptor and then the binary,
# while every key/configuration byte remains available for a later install.
pkg_root = os.path.join(HOME, 'package-sshd')
pkg_bin_dir = os.path.join(HOME, 'package-bin')
os.makedirs(pkg_bin_dir)
pkg_bin = os.path.join(pkg_bin_dir, 'superterm')
shutil.copy2(stlib.BIN, pkg_bin)
if prepare_root(pkg_root, pkg_bin):
    pkg_persistent = persistent_snapshot(pkg_root)
    reset_manager(True, True)
    made = make_uninstall(pkg_root, pkg_bin_dir)
    check('make uninstall performs verified service removal',
          made.returncode == 0)
    check('make uninstall removes descriptor before binary handoff',
          not os.path.lexists(descriptor_path(pkg_root)) and
          not os.path.lexists(pkg_bin))
    check('make uninstall preserves all persistent SSH material',
          persistent_snapshot(pkg_root) == pkg_persistent)
    check('make uninstall leaves fake service disabled and stopped',
          read_state() == (0, 0))


# DESTDIR is packaging staging, never authority over the host.  Both a host
# executable and a host descriptor are represented inside this private HOME;
# neither may be invoked or changed while only the staged file is removed.
stage = os.path.join(HOME, 'stage')
host_bin_dir = os.path.join(HOME, 'simulated-host-bin')
host_bin = os.path.join(host_bin_dir, 'superterm')
stage_bin = stage + host_bin
stage_exec_log = os.path.join(HOME, 'stage-host-executed')
os.makedirs(host_bin_dir)
os.makedirs(os.path.dirname(stage_bin), exist_ok=True)
for path in (host_bin, stage_bin):
    with open(path, 'w', encoding='utf-8') as stream:
        stream.write('#!/bin/sh\n')
        stream.write('printf invoked > "$SUPERTERM_STAGE_EXEC_LOG"\n')
        stream.write('exit 99\n')
    os.chmod(path, 0o755)
staged_host_root = os.path.join(HOME, 'simulated-host-sshd')
staged_descriptor = descriptor_path(staged_host_root)
os.makedirs(os.path.dirname(staged_descriptor), exist_ok=True)
with open(staged_descriptor, 'wb') as stream:
    stream.write(b'simulated host descriptor must remain\n')
staged_descriptor_before = file_record(staged_descriptor)
reset_manager(True, True)
stage_env = base_env(staged_host_root)
stage_env.update(manager_env())
stage_env['SUPERTERM_STAGE_EXEC_LOG'] = stage_exec_log
staged = subprocess.run([
    'make', '-f', os.path.join(PROJECT, 'Makefile'), 'uninstall',
    f'DESTDIR={stage}',
    f'BINDIR={host_bin_dir}',
    f'DOCDIR={os.path.join(HOME, "stage-doc")}',
    f'SYSCONFDIR={os.path.join(HOME, "stage-etc")}',
    f'DATADIR={os.path.join(HOME, "stage-data")}',
], cwd=PROJECT, env=stage_env, text=True, capture_output=True, timeout=60)
check('DESTDIR staging uninstall succeeds', staged.returncode == 0)
check('DESTDIR never executes host or staged binaries',
      not os.path.exists(stage_exec_log))
check('DESTDIR removes only staged binary',
      not os.path.lexists(stage_bin) and os.path.isfile(host_bin))
check('DESTDIR leaves simulated host descriptor unchanged',
      file_record(staged_descriptor) == staged_descriptor_before)
check('DESTDIR never calls a host service manager', calls() == [])


stlib.report()
