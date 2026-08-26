#!/usr/bin/env python3
"""Dedicated OpenSSH administration is isolated, strict and idempotent.

Every command uses SUPERTERM_SSHD_ROOT below this suite's private HOME and
SUPERTERM_TESTING=1.  The real service-manager path is deliberately skipped;
rollback tests opt in only with a private stateful fake.  This test never
writes /etc, starts a listener or touches the host's ordinary sshd service.
"""

import fcntl
import glob
import hashlib
import os
import pwd
import shlex
import shutil
import stat
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check


HOME = stlib.fresh_home('ssh-server-config')
ROOT = os.path.join(HOME, 'isolated-sshd')
USER = pwd.getpwuid(os.getuid()).pw_name
DEFAULT_AUTH_INI = (
    'password_authentication=1\n'
    'managed_authorized_keys=1\n'
    'user_authorized_keys=1\n'
)


def admin(*args, root=ROOT, timeout=45, extra_env=None):
    env = dict(os.environ,
               HOME=HOME,
               TERM='xterm',
               LANG='C',
               SUPERTERM_INI=os.path.join(HOME, 'no-system.ini'),
               SUPERTERM_TESTING='1',
               SUPERTERM_SSHD_ROOT=root)
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        [stlib.BIN, 'ssh-server', *args],
        text=True, capture_output=True, env=env, timeout=timeout)


def admin_with_binary(binary, *args, root, timeout=45, extra_env=None):
    env = dict(os.environ,
               HOME=HOME,
               TERM='xterm',
               LANG='C',
               SUPERTERM_INI=os.path.join(HOME, 'no-system.ini'),
               SUPERTERM_TESTING='1',
               SUPERTERM_SSHD_ROOT=root)
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        [binary, 'ssh-server', *args], text=True, capture_output=True,
        env=env, timeout=timeout)


def read(path, binary=False):
    with open(path, 'rb' if binary else 'r',
              **({} if binary else {'encoding': 'utf-8'})) as stream:
        return stream.read()


def write_ini(listen='127.0.0.1:8022,[::1]:8022', allow_root=0,
              password_authentication=1, managed_authorized_keys=1,
              user_authorized_keys=1, extra=''):
    with open(os.path.join(ROOT, 'server.ini'), 'w',
              encoding='utf-8') as stream:
        stream.write('[server]\nconfig_version=1\n')
        stream.write(f'listen={listen}\nallow_root={allow_root}\n')
        stream.write(
            f'password_authentication={password_authentication}\n'
            f'managed_authorized_keys={managed_authorized_keys}\n'
            f'user_authorized_keys={user_authorized_keys}\n')
        stream.write(extra)
    os.chmod(os.path.join(ROOT, 'server.ini'), 0o644)


def write_raw_ini(content):
    with open(os.path.join(ROOT, 'server.ini'), 'w', encoding='utf-8') as stream:
        stream.write(content)
    os.chmod(os.path.join(ROOT, 'server.ini'), 0o644)


def mode(path):
    return stat.S_IMODE(os.lstat(path).st_mode)


# Every administrative spelling validates argv before privileges, files or an
# external helper are touched.  Cover both languages and the service wrapper;
# one shared marker makes an accidental helper execution observable.
arity_root = os.path.join(HOME, 'arity-root-must-not-exist')
arity_marker = os.path.join(HOME, 'arity-helper-ran')
arity_helper = os.path.join(HOME, 'arity-helper')
with open(arity_helper, 'w', encoding='utf-8') as stream:
    stream.write('#!/bin/sh\n')
    stream.write('printf ran > "$SUPERTERM_ARITY_MARKER"\n')
    stream.write('exit 0\n')
os.chmod(arity_helper, 0o755)
arity_env = {
    'SUPERTERM_TEST_SSHD': arity_helper,
    'SUPERTERM_TEST_SSH_KEYGEN': arity_helper,
    'SUPERTERM_TEST_SYSTEMCTL': arity_helper,
    'SUPERTERM_TEST_LAUNCHCTL': arity_helper,
    'SUPERTERM_TEST_SERVICE_MANAGER': '1',
    'SUPERTERM_ARITY_MARKER': arity_marker,
}
no_arg_spellings = (
    'help', 'ayuda', 'setup', 'init', 'configurar', 'preparar',
    'inicializar', 'check', 'comprobar', 'verificar', 'restart',
    'reiniciar', 'status', 'estado', 'enable', 'habilitar', 'activar',
    'disable', 'deshabilitar', 'desactivar', 'uninstall-service',
    'desinstalar-servicio', 'run', 'ejecutar',
)
arity_results = [
    admin(command, 'unexpected', root=arity_root, extra_env=arity_env)
    for command in no_arg_spellings
]
arity_results.extend((
    admin('authorize', 'only-user', root=arity_root, extra_env=arity_env),
    admin('autorizar', 'only-user', root=arity_root, extra_env=arity_env),
    admin('revoke', 'only-user', root=arity_root, extra_env=arity_env),
    admin('revocar', 'only-user', root=arity_root, extra_env=arity_env),
    admin('list-keys', USER, 'extra', root=arity_root,
          extra_env=arity_env),
    admin('listar-claves', USER, 'extra', root=arity_root,
          extra_env=arity_env),
))
check('all SSH admin aliases reject extra argv before effects',
      all(result.returncode == 2 for result in arity_results) and
      not os.path.lexists(arity_root) and
      not os.path.lexists(arity_marker))

setup = admin('setup')
check('isolated setup succeeds', setup.returncode == 0)
check('service action is test-only',
      'service manager action skipped' in setup.stdout.lower())

ini = os.path.join(ROOT, 'server.ini')
generated = os.path.join(ROOT, 'sshd_config.generated')
host_key = os.path.join(ROOT, 'ssh_host_ed25519_key')
host_pub = host_key + '.pub'
auth_dir = os.path.join(ROOT, 'authorized_keys')
service_dir = os.path.join(ROOT, 'service')
service_files = ([os.path.join(service_dir, name)
                  for name in os.listdir(service_dir)]
                 if os.path.isdir(service_dir) else [])

check('all persistent paths isolated',
      all(os.path.realpath(path).startswith(os.path.realpath(ROOT) + os.sep)
          for path in (ini, generated, host_key, host_pub, auth_dir)) and
      '/etc/ssh' not in read(generated))
check('directory permissions', mode(ROOT) == 0o755 and
      mode(auth_dir) == 0o755)
check('configuration permissions', mode(ini) == 0o644 and
      mode(generated) == 0o600)
default_ini = read(ini).lower()
check('setup enables all authentication sources by default',
      all(setting in default_ini for setting in (
          'password_authentication=1',
          'managed_authorized_keys=1',
          'user_authorized_keys=1',
      )))
check('host-key permissions', mode(host_key) == 0o600 and
      mode(host_pub) == 0o644)
check('private service descriptor', len(service_files) == 1 and
      mode(service_files[0]) == 0o644)

cfg = read(generated).lower()
required = (
    'listenaddress 127.0.0.1:8022',
    'listenaddress [::1]:8022',
    'authenticationmethods any',
    'passwordauthentication yes',
    'kbdinteractiveauthentication no',
    'pubkeyauthentication yes',
    # Password authentication uses the host PAM stack; keyboard-interactive
    # stays disabled so the same password policy is not exposed twice.
    'usepam yes',
    'permitrootlogin no',
    'disableforwarding yes',
    'allowagentforwarding no',
    'allowtcpforwarding no',
    'allowstreamlocalforwarding no',
    'x11forwarding no',
    'permittunnel no',
    'permituserenvironment no',
    'permituserrc no',
    'permittty yes',
    'maxsessions 1',
    ('authorizedkeysfile ' + auth_dir.lower() +
     '/%u .ssh/authorized_keys'),
    'forcecommand ' + os.path.realpath(stlib.BIN).lower() + ' --ssh-entry',
)
check('generated policy is fail-closed', all(item in cfg for item in required))
if os.name == 'posix' and sys.platform != 'darwin':
    check('systemd preserves session daemons',
          service_files and 'KillMode=process' in read(service_files[0]))
    check('service validates then execs accepted sshd',
          service_files and
          (os.path.realpath(stlib.BIN) + ' ssh-server run') in
          read(service_files[0]) and 'sshd -D' not in read(service_files[0]))
elif sys.platform == 'darwin':
    check('launchd descriptor abandons the listener process group',
          service_files and
          '<key>AbandonProcessGroup</key><true/>' in read(service_files[0]))
    # Apple files-974.120.2 creates the exact relative root alias
    # `/etc -> private/etc`.  The production validator accepts only that one
    # link and checks the physical directories; the test-only executable can
    # exercise the same code below HOME without modifying the real namespace.
    def protected_root_directory(path):
        info = os.lstat(path)
        return (stat.S_ISDIR(info.st_mode) and info.st_uid == 0 and
                stat.S_IMODE(info.st_mode) & 0o022 == 0)

    real_etc = os.lstat('/etc')
    real_etc_layout = (protected_root_directory('/') and
                       protected_root_directory('/etc'))
    if stat.S_ISLNK(real_etc.st_mode):
        real_etc_layout = (
            real_etc.st_uid == 0 and
            os.readlink('/etc') == 'private/etc' and
            os.path.realpath('/etc') == '/private/etc' and
            protected_root_directory('/') and
            protected_root_directory('/private') and
            protected_root_directory('/private/etc'))
    check('Darwin /etc has the supported physical layout', real_etc_layout)

    alias_tree = os.path.join(HOME, 'darwin-etc-alias-tree')
    alias_path = os.path.join(alias_tree, 'etc')
    os.makedirs(os.path.join(alias_tree, 'private', 'etc'), mode=0o755)
    os.symlink('private/etc', alias_path)
    alias_setup_root = os.path.join(HOME, 'darwin-alias-setup-root')
    alias_setup = admin('setup', root=alias_setup_root, extra_env={
        'SUPERTERM_TEST_DARWIN_ETC_ALIAS': alias_path,
    })
    check('isolated Darwin /etc alias passes the production validator',
          alias_setup.returncode == 0)

    bad_alias_tree = os.path.join(HOME, 'darwin-bad-etc-alias-tree')
    bad_alias_path = os.path.join(bad_alias_tree, 'etc')
    os.makedirs(os.path.join(bad_alias_tree, 'private', 'etc'), mode=0o755)
    os.makedirs(os.path.join(bad_alias_tree, 'other'), mode=0o755)
    os.symlink('other', bad_alias_path)
    bad_alias_root = os.path.join(HOME, 'darwin-bad-alias-setup-root')
    bad_alias_setup = admin('setup', root=bad_alias_root, extra_env={
        'SUPERTERM_TEST_DARWIN_ETC_ALIAS': bad_alias_path,
    })
    check('unexpected Darwin /etc alias target is rejected before writes',
          bad_alias_setup.returncode != 0 and
          'unexpected system directory alias target' in
          bad_alias_setup.stderr.lower() and
          not os.path.lexists(bad_alias_root))

    linked_target_tree = os.path.join(HOME, 'darwin-linked-etc-target-tree')
    linked_target_path = os.path.join(linked_target_tree, 'etc')
    os.makedirs(os.path.join(linked_target_tree, 'private'), mode=0o755)
    os.makedirs(os.path.join(linked_target_tree, 'elsewhere'), mode=0o755)
    os.symlink('../elsewhere', os.path.join(linked_target_tree,
                                            'private', 'etc'))
    os.symlink('private/etc', linked_target_path)
    linked_target_root = os.path.join(HOME,
                                      'darwin-linked-target-setup-root')
    linked_target_setup = admin('setup', root=linked_target_root, extra_env={
        'SUPERTERM_TEST_DARWIN_ETC_ALIAS': linked_target_path,
    })
    check('nested link below Darwin /etc alias remains rejected',
          linked_target_setup.returncode != 0 and
          'not a directory (or is a symlink)' in
          linked_target_setup.stderr.lower() and
          not os.path.lexists(linked_target_root))
    # launchctl(1) says its human-readable `print` output is not an API.  The
    # product therefore classifies only the bootstrap status that `launchctl
    # error` decodes as "Could not find specified service".  Verify that
    # Darwin itself still returns 113 for a unique, read-only absent probe.
    absent_target = ('system/org.superterm.sshd.classifier-test-' +
                     str(os.getpid()))
    absent_probe = subprocess.run(
        ['/bin/launchctl', 'print', absent_target], text=True,
        capture_output=True, timeout=10)
    check('real launchctl absent-service status is 113',
          absent_probe.returncode == 113)

sshd = next((path for path in ('/usr/sbin/sshd', '/usr/bin/sshd',
                               '/usr/local/sbin/sshd')
             if os.path.isfile(path) and os.access(path, os.X_OK)), '')
check('real sshd is available', bool(sshd))
if sshd:
    direct = subprocess.run([sshd, '-t', '-f', generated],
                            text=True, capture_output=True)
    effective = subprocess.run([sshd, '-T', '-f', generated],
                               text=True, capture_output=True)
    check('real sshd accepts generated file', direct.returncode == 0 and
          effective.returncode == 0)
    effective_policy = effective.stdout.lower()
    check('real sshd confirms configurable authentication defaults',
          'authenticationmethods any' in effective_policy and
          'passwordauthentication yes' in effective_policy and
          'pubkeyauthentication yes' in effective_policy and
          ('authorizedkeysfile ' + auth_dir.lower() +
           '/%u .ssh/authorized_keys') in effective_policy)
    check('real sshd confirms forced command',
          ('forcecommand ' + os.path.realpath(stlib.BIN).lower() +
           ' --ssh-entry') in effective_policy)

# Debian-style usrmerge keeps /usr/sbin as a root-owned link to /usr/bin.
# Production rejects a symlink in the executable ancestry, so selection must
# use the canonical inode path instead of stopping at the legacy alias.  The
# expectation observes the fixed candidate chosen by the test build; it is
# never used as an executable path.
usrmerge_sshd = (
    sys.platform.startswith('linux') and os.path.islink('/usr/sbin') and
    os.path.realpath('/usr/sbin') == os.path.realpath('/usr/bin') and
    os.path.isfile('/usr/bin/sshd') and os.access('/usr/bin/sshd', os.X_OK) and
    os.path.exists('/usr/sbin/sshd') and
    os.path.samefile('/usr/bin/sshd', '/usr/sbin/sshd'))
if usrmerge_sshd:
    canonical_setup = admin(
        'setup', root=os.path.join(HOME, 'usrmerge-canonical-sshd'),
        extra_env={'SUPERTERM_TEST_EXPECT_SSHD': '/usr/bin/sshd'})
    check('usrmerge selects canonical /usr/bin/sshd',
          canonical_setup.returncode == 0)
else:
    print('usrmerge canonical sshd selection    : SKIP (not an usrmerge host)')

private_before = hashlib.sha256(read(host_key, binary=True)).hexdigest()
again = admin('setup')
private_after = hashlib.sha256(read(host_key, binary=True)).hexdigest()
check('setup is idempotent', again.returncode == 0)
check('host identity is never replaced', private_before == private_after)
check('check validates current install', admin('check').returncode == 0)

# OpenSSH 10.5p1 session.c runs its compiled global sshrc even for an
# administrative ForceCommand and PermitUserRC=no.  No sshd_config directive
# disables it, so the dedicated service must fail closed before publishing a
# configuration.  The test-only path keeps this proof entirely below HOME.
global_rc_root = os.path.join(HOME, 'global-rc-root')
global_rc = os.path.join(HOME, 'global-sshrc')
with open(global_rc, 'w', encoding='utf-8') as stream:
    stream.write('# deliberately present; it must never be executed\n')
global_rc_setup = admin('setup', root=global_rc_root, extra_env={
    'SUPERTERM_TEST_SYSTEM_SSHRC': global_rc,
})
check('global OpenSSH sshrc is rejected before publication',
      global_rc_setup.returncode != 0 and
      'before ForceCommand' in global_rc_setup.stderr and
      not os.path.exists(os.path.join(global_rc_root,
                                      'sshd_config.generated')))

# Administrative operations must have a hard deadline if another administrator
# is stopped while owning the stable lock. The production bound is 30 seconds;
# this explicit test hook shortens only the number of identical nonblocking
# probes.
admin_lock = os.path.join(ROOT, '.admin.lock')
lock_fd = os.open(admin_lock, os.O_RDWR)
try:
    fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    lock_started = time.monotonic()
    lock_wait = admin('check', timeout=5, extra_env={
        'SUPERTERM_TEST_ADMIN_LOCK_POLLS': '3',
    })
    lock_elapsed = time.monotonic() - lock_started
finally:
    fcntl.flock(lock_fd, fcntl.LOCK_UN)
    os.close(lock_fd)
check('held administration lock has bounded failure',
      lock_wait.returncode != 0 and lock_elapsed < 2.0 and
      'timed out' in lock_wait.stderr.lower())

# A helper may exit after forking a descendant which still owns stdout.  The
# leader must remain unreaped until that capture pipe closes: its zombie PID
# reserves both the PID and private process-group number, so timeout cleanup
# can never target a reused numeric ID. The orphan may remain as a harmless
# zombie until the OS reaper collects it; disappearance of that non-child PID
# is therefore not a valid deadline oracle.
helper_tree_marker = os.path.join(HOME, 'captured-helper-tree')
helper_natural_marker = os.path.join(HOME, 'captured-helper-natural-exit')
helper_tree = os.path.join(HOME, 'fake-sshd-helper-tree')
with open(helper_tree, 'w', encoding='utf-8') as stream:
    stream.write(f'''#!{sys.executable}
import os
import time

child = os.fork()
if child == 0:
    time.sleep(8.0)
    with open({helper_natural_marker!r}, 'w', encoding='ascii') as marker:
        marker.write('natural exit\\n')
    os._exit(0)
marker_temp = {helper_tree_marker!r} + '.tmp'
with open(marker_temp, 'w', encoding='ascii') as marker:
    marker.write(f'{{os.getpid()}} {{child}}\\n')
os.replace(marker_temp, {helper_tree_marker!r})
time.sleep(0.2)
os._exit(0)
''')
os.chmod(helper_tree, 0o755)
helper_env = dict(os.environ,
                  HOME=HOME,
                  TERM='xterm',
                  LANG='C',
                  SUPERTERM_INI=os.path.join(HOME, 'no-system.ini'),
                  SUPERTERM_TESTING='1',
                  SUPERTERM_SSHD_ROOT=ROOT,
                  SUPERTERM_TEST_SSHD=helper_tree,
                  SUPERTERM_TEST_COMMAND_POLLS='30')
helper_started = time.monotonic()
helper_admin = subprocess.Popen(
    [stlib.BIN, 'ssh-server', 'check'], text=True,
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=helper_env)
marker_deadline = time.monotonic() + 2.0
while (not os.path.exists(helper_tree_marker) and
       time.monotonic() < marker_deadline and helper_admin.poll() is None):
    time.sleep(0.01)
leader_pid = 0
descendant_pid = 0
leader_identity = ''
descendant_identity = ''
if os.path.exists(helper_tree_marker):
    try:
        leader_pid, descendant_pid = map(int, read(helper_tree_marker).split())
        leader_identity = stlib.process_identity(leader_pid)
        descendant_identity = stlib.process_identity(descendant_pid)
        stlib.register_process(leader_pid, 'captured-helper-leader')
        stlib.register_process(descendant_pid, 'captured-helper-descendant')
    except (OSError, ValueError):
        leader_pid = 0
        descendant_pid = 0
leader_zombie = False
zombie_deadline = time.monotonic() + 2.5
while leader_pid > 1 and time.monotonic() < zombie_deadline:
    if stlib.process_is_zombie(leader_pid, leader_identity):
        leader_zombie = True
        break
    time.sleep(0.02)
try:
    helper_stdout, helper_stderr = helper_admin.communicate(timeout=12.0)
except subprocess.TimeoutExpired:
    helper_admin.kill()
    helper_stdout, helper_stderr = helper_admin.communicate()
helper_elapsed = time.monotonic() - helper_started
finished_deadline = time.monotonic() + 2.0
leader_reaped = False
descendant_finished = False
while time.monotonic() < finished_deadline:
    leader_reaped = (bool(leader_identity) and
                     stlib.process_identity(leader_pid) != leader_identity)
    descendant_finished = (bool(descendant_identity) and
                           stlib.process_finished(
                               descendant_pid, descendant_identity))
    if leader_reaped and descendant_finished:
        break
    time.sleep(0.02)
if leader_pid > 1 and leader_reaped:
    stlib.unregister_process(leader_pid)
if descendant_pid > 1 and descendant_finished:
    stlib.unregister_process(descendant_pid)
helper_oracles = {
    'pids': leader_pid > 1 and descendant_pid > 1,
    'identities': bool(leader_identity) and bool(descendant_identity),
    'leader_zombie_seen': leader_zombie,
    'admin_failed': helper_admin.returncode != 0,
    'bounded': helper_elapsed < 6.0,
    'no_natural_exit': not os.path.exists(helper_natural_marker),
    'leader_reaped': leader_reaped,
    'descendant_finished': descendant_finished,
}
if not all(helper_oracles.values()):
    print('  captured-helper diagnostics: ' + repr({
        **helper_oracles,
        'elapsed': round(helper_elapsed, 3),
        'returncode': helper_admin.returncode,
        'stdout': helper_stdout[-300:],
        'stderr': helper_stderr[-300:],
    }))
check('captured helper leader is reserved until pipe cleanup',
      all(helper_oracles.values()))

# A failed helper may have already created both key halves. Setup owns those
# temporary names before exec and must remove private material on every error.
failed_key_root = os.path.join(HOME, 'failed-keygen-root')
fake_keygen = os.path.join(HOME, 'fake-keygen-failure')
with open(fake_keygen, 'w', encoding='utf-8') as stream:
    stream.write('''#!/bin/sh
target=
while [ "$#" -gt 0 ]; do
  if [ "$1" = -f ] && [ "$#" -ge 2 ]; then
    target=$2
    shift 2
  else
    shift
  fi
done
printf PRIVATE_TEST_MATERIAL > "$target"
printf PUBLIC_TEST_MATERIAL > "$target.pub"
exit 7
''')
os.chmod(fake_keygen, 0o755)
failed_keygen = admin('setup', root=failed_key_root, extra_env={
    'SUPERTERM_TEST_SSH_KEYGEN': fake_keygen,
})
keygen_temps = glob.glob(os.path.join(
    failed_key_root, 'ssh_host_ed25519_key.keygen.tmp.*'))
check('failed keygen removes both temporary halves',
      failed_keygen.returncode != 0 and not keygen_temps and
      not os.path.exists(os.path.join(failed_key_root,
                                      'ssh_host_ed25519_key')) and
      not os.path.exists(os.path.join(failed_key_root,
                                      'ssh_host_ed25519_key.pub')))

# Packaging mistakes must never turn the forced TUI into a privilege boundary.
# The check is unconditional, so it is testable without touching production
# paths or granting this isolated copy any different owner.
privileged_root = os.path.join(HOME, 'privileged-binary-root')
privileged_bin = os.path.join(HOME, 'superterm-setid-test')
shutil.copy2(stlib.BIN, privileged_bin)
os.chmod(privileged_bin, 0o4755)
setid_setup = admin_with_binary(privileged_bin, 'setup', root=privileged_root)
check('set-ID forced-command binary is rejected',
      setid_setup.returncode != 0 and
      'set-user-id or set-group-id' in setid_setup.stderr.lower())

# server.ini is pending state. `check` validates a temporary candidate and
# must not silently accept it; only a successful restart publishes it.
accepted_before = read(generated, binary=True)
write_ini(listen='127.0.0.1:38111')
pending_check = admin('check')
check('check never mutates accepted configuration',
      pending_check.returncode == 0 and
      read(generated, binary=True) == accepted_before)
check('restart atomically accepts pending configuration',
      admin('restart').returncode == 0 and
      'listenaddress 127.0.0.1:38111' in read(generated).lower())

# Every endpoint carries its own port, including bracketed IPv6.
listen = '127.0.0.1:38022,[::1]:38023,0.0.0.0:38024'
write_ini(listen=listen, allow_root=1)
restart = admin('restart')
cfg = read(generated).lower()
check('multiple interfaces and ports', restart.returncode == 0 and
      all(('listenaddress ' + value.lower()) in cfg
          for value in listen.split(',')))
check('root remains public-key-only opt-in',
      'permitrootlogin prohibit-password' in cfg)

# Authentication methods and public-key lookup sources are independent public
# choices.  Exercise each boundary, including the two-source key-only case and
# the default in which either a password or a public key may authenticate.
auth_matrix = (
    ('keys only', 0, 1, 1, 'publickey', 'no', 'yes',
     auth_dir + '/%u .ssh/authorized_keys'),
    ('password only', 1, 0, 0, 'password', 'yes', 'no', 'none'),
    ('central keys only', 0, 1, 0, 'publickey', 'no', 'yes',
     auth_dir + '/%u'),
    ('user keys only', 0, 0, 1, 'publickey', 'no', 'yes',
     '.ssh/authorized_keys'),
    ('password or public key', 1, 1, 1, 'any', 'yes', 'yes',
     auth_dir + '/%u .ssh/authorized_keys'),
)
for (label, password_authentication, managed_authorized_keys,
     user_authorized_keys, authentication_methods, password_value,
     pubkey_value, authorized_keys_value) in auth_matrix:
    write_ini(password_authentication=password_authentication,
              managed_authorized_keys=managed_authorized_keys,
              user_authorized_keys=user_authorized_keys)
    auth_restart = admin('restart')
    auth_enable = admin('enable') if auth_restart.returncode == 0 else None
    auth_lines = {
        line.strip().lower() for line in read(generated).splitlines()
        if line.strip()
    }
    expected_auth_lines = {
        'authenticationmethods ' + authentication_methods,
        'passwordauthentication ' + password_value,
        'pubkeyauthentication ' + pubkey_value,
        'authorizedkeysfile ' + authorized_keys_value.lower(),
        'kbdinteractiveauthentication no',
        'usepam yes',
    }
    check(f'authentication matrix accepts {label}',
          auth_restart.returncode == 0 and
          auth_enable is not None and auth_enable.returncode == 0 and
          expected_auth_lines.issubset(auth_lines))

# Invalid pending authentication policies must not replace the final valid
# matrix entry.  Password-only is valid for ordinary users, but cannot satisfy
# an explicit request to permit root because root passwords remain prohibited.
accepted_auth_matrix = read(generated, binary=True)
write_ini(password_authentication=0, managed_authorized_keys=0,
          user_authorized_keys=0)
no_auth = admin('restart')
check('configuration with no authentication method is rejected atomically',
      no_auth.returncode != 0 and
      read(generated, binary=True) == accepted_auth_matrix)

write_ini(allow_root=1, password_authentication=1,
          managed_authorized_keys=0, user_authorized_keys=0)
root_without_keys = admin('restart')
check('root opt-in without a public-key source is rejected atomically',
      root_without_keys.returncode != 0 and
      read(generated, binary=True) == accepted_auth_matrix)

write_ini()
check('default authentication policy recovers after rejected updates',
      admin('restart').returncode == 0)

# Version-1 installations created before these optional switches existed
# must not silently widen network authentication after a package upgrade.
# Their omitted values retain the old central-key-only policy; a newly
# created server.ini above contains the explicit convenient 1/1/1 defaults.
write_raw_ini('[server]\nconfig_version=1\n'
              'listen=127.0.0.1:8022\nallow_root=0\n')
legacy_restart = admin('restart')
legacy_lines = {
    line.strip().lower() for line in read(generated).splitlines()
    if line.strip()
}
check('legacy version-1 auth omission remains central-key-only',
      legacy_restart.returncode == 0 and {
          'authenticationmethods publickey',
          'passwordauthentication no',
          'pubkeyauthentication yes',
          'authorizedkeysfile ' + auth_dir.lower() + '/%u',
      }.issubset(legacy_lines))
write_ini()
check('explicit default auth restores after legacy compatibility check',
      admin('restart').returncode == 0)

# A malformed public file must never replace the last accepted generated one.
good_generated = read(generated, binary=True)
write_ini(listen='127.0.0.1:39022', allow_root=0,
          extra='ForceCommand=/bin/sh\n')
bad = admin('restart')
check('unknown/injected key rejected', bad.returncode != 0)
check('invalid update is atomic', read(generated, binary=True) == good_generated)
enabled_with_bad_pending = admin('enable')
check('enable uses last accepted config, not invalid pending',
      enabled_with_bad_pending.returncode == 0 and
      read(generated, binary=True) == good_generated)

invalid_public_files = (
    ('duplicate key',
     '[server]\nconfig_version=1\nlisten=127.0.0.1:8022\n'
     'listen=127.0.0.1:8023\nallow_root=0\n' + DEFAULT_AUTH_INI),
    ('duplicate section',
     '[server]\nconfig_version=1\nlisten=127.0.0.1:8022\n'
     'allow_root=0\n' + DEFAULT_AUTH_INI + '[server]\n'),
    ('foreign section',
     '[server]\nconfig_version=1\nlisten=127.0.0.1:8022\n'
     'allow_root=0\n' + DEFAULT_AUTH_INI + '[match]\nuser=root\n'),
    ('missing version',
     '[server]\nlisten=127.0.0.1:8022\nallow_root=0\n' +
     DEFAULT_AUTH_INI),
    ('invalid boolean',
     '[server]\nconfig_version=1\nlisten=127.0.0.1:8022\n'
     'allow_root=perhaps\n' + DEFAULT_AUTH_INI),
    ('invalid password boolean',
     '[server]\nconfig_version=1\nlisten=127.0.0.1:8022\n'
     'allow_root=0\npassword_authentication=perhaps\n'
     'managed_authorized_keys=1\nuser_authorized_keys=1\n'),
    ('invalid managed-key boolean',
     '[server]\nconfig_version=1\nlisten=127.0.0.1:8022\n'
     'allow_root=0\npassword_authentication=1\n'
     'managed_authorized_keys=perhaps\nuser_authorized_keys=1\n'),
    ('invalid user-key boolean',
     '[server]\nconfig_version=1\nlisten=127.0.0.1:8022\n'
     'allow_root=0\npassword_authentication=1\n'
     'managed_authorized_keys=1\nuser_authorized_keys=perhaps\n'),
    ('duplicate authentication key',
     '[server]\nconfig_version=1\nlisten=127.0.0.1:8022\n'
     'allow_root=0\n' + DEFAULT_AUTH_INI +
     'password_authentication=0\n'),
    ('wildcard listener',
     '[server]\nconfig_version=1\nlisten=*:8022\nallow_root=0\n' +
     DEFAULT_AUTH_INI),
)
for label, content in invalid_public_files:
    write_raw_ini(content)
    rejected = admin('check')
    check(f'strict parser rejects {label}', rejected.returncode != 0 and
          read(generated, binary=True) == good_generated)

write_ini()
os.chmod(ini, 0o666)
check('unsafe public config mode rejected', admin('check').returncode != 0)
os.chmod(ini, 0o644)
check('valid config recovers', admin('restart').returncode == 0)

# A service-manager failure after files were published must restore both
# accepted files byte-for-byte and the two orthogonal manager states:
# enabled/disabled policy and active/inactive runtime state. The fakes model
# the documented managers but cannot touch a real service.
service_log = os.path.join(HOME, 'service-manager.log')
service_state = os.path.join(HOME, 'service-manager.state')
fail_marker = os.path.join(HOME, 'service-manager-failed-once')


def write_service_state(enabled, active):
    with open(service_state, 'w', encoding='ascii') as stream:
        stream.write(f'enabled={int(enabled)}\nactive={int(active)}\n')


def read_service_state():
    values = {}
    for line in read(service_state).splitlines():
        key, value = line.split('=', 1)
        values[key] = int(value)
    return values['enabled'], values['active']


if sys.platform == 'darwin':
    fake_manager = os.path.join(HOME, 'fake-launchctl')
    manager_override = 'SUPERTERM_TEST_LAUNCHCTL'
    with open(fake_manager, 'w', encoding='utf-8') as stream:
        stream.write(r'''#!/bin/sh
. "$SUPERTERM_TEST_SERVICE_STATE"
save_state() {
  tmp="$SUPERTERM_TEST_SERVICE_STATE.tmp.$$"
  printf 'enabled=%s\nactive=%s\n' "$enabled" "$active" > "$tmp" || exit 70
  mv "$tmp" "$SUPERTERM_TEST_SERVICE_STATE" || exit 71
}
printf '%s\n' "$*" >> "$SUPERTERM_TEST_SERVICE_LOG"
if [ "$1" = print ] && [ -n "$SUPERTERM_TEST_LAUNCHCTL_PRINT_EXIT" ]; then
  printf 'injected launchctl print failure\n' >&2
  exit "$SUPERTERM_TEST_LAUNCHCTL_PRINT_EXIT"
fi
case "$1" in
  print-disabled)
    printf 'disabled services = {\n'
    if [ "$enabled" = 0 ]; then
      printf '    "org.superterm.sshd" => true\n'
    fi
    printf '}\n'
    exit 0
    ;;
  print)
    if [ "$active" = 1 ]; then
      printf 'system/org.superterm.sshd = { }\n'
      exit 0
    fi
    printf 'service is not loaded\n' >&2
    exit 113
    ;;
  enable)
    enabled=1
    save_state
    exit 0
    ;;
  disable)
    enabled=0
    save_state
    exit 0
    ;;
  bootout)
    active=0
    save_state
    exit 0
    ;;
  bootstrap)
    if [ "$enabled" != 1 ]; then
      printf 'service is disabled\n' >&2
      exit 78
    fi
    if [ ! -e "$SUPERTERM_TEST_RESTART_MARKER" ]; then
      active=0
      save_state
      : > "$SUPERTERM_TEST_RESTART_MARKER"
      exit 1
    fi
    active=1
    save_state
    exit 0
    ;;
esac
exit 64
''')
else:
    fake_manager = os.path.join(HOME, 'fake-systemctl')
    manager_override = 'SUPERTERM_TEST_SYSTEMCTL'
    with open(fake_manager, 'w', encoding='utf-8') as stream:
        stream.write(r'''#!/bin/sh
. "$SUPERTERM_TEST_SERVICE_STATE"
save_state() {
  tmp="$SUPERTERM_TEST_SERVICE_STATE.tmp.$$"
  printf 'enabled=%s\nactive=%s\n' "$enabled" "$active" > "$tmp" || exit 70
  mv "$tmp" "$SUPERTERM_TEST_SERVICE_STATE" || exit 71
}
printf '%s\n' "$*" >> "$SUPERTERM_TEST_SERVICE_LOG"
case "$1" in
  daemon-reload)
    exit 0
    ;;
  is-enabled)
    if [ "$enabled" = 1 ]; then
      printf 'enabled\n'
      exit 0
    fi
    printf 'disabled\n'
    exit 1
    ;;
  is-active)
    if [ "$active" = 1 ]; then
      printf 'active\n'
      exit 0
    fi
    printf 'inactive\n'
    exit 3
    ;;
  enable)
    enabled=1
    save_state
    exit 0
    ;;
  disable)
    enabled=0
    if [ "$2" = --now ]; then
      active=0
    fi
    save_state
    exit 0
    ;;
  stop)
    active=0
    save_state
    exit 0
    ;;
  restart)
    if [ ! -e "$SUPERTERM_TEST_RESTART_MARKER" ]; then
      active=0
      save_state
      : > "$SUPERTERM_TEST_RESTART_MARKER"
      exit 1
    fi
    active=1
    save_state
    exit 0
    ;;
esac
exit 64
''')
os.chmod(fake_manager, 0o755)


def manager_env():
    return {
        'SUPERTERM_TEST_SERVICE_MANAGER': '1',
        manager_override: fake_manager,
        'SUPERTERM_TEST_SERVICE_LOG': service_log,
        'SUPERTERM_TEST_SERVICE_STATE': service_state,
        'SUPERTERM_TEST_RESTART_MARKER': fail_marker,
    }


def reset_manager(enabled, active):
    write_service_state(enabled, active)
    for path in (service_log, fail_marker):
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass


# A failed launchctl query is not proof that a service is absent.  State
# capture precedes every update of an existing installation, so an arbitrary
# non-zero status must stop the transaction before either managed bytes or the
# manager state changes.  Exit 113 is exercised separately by the normal
# inactive fake paths and by the real Darwin probe near descriptor validation.
if sys.platform == 'darwin':
    transient_generated = read(generated, binary=True)
    transient_descriptor = read(service_files[0], binary=True)
    reset_manager(True, True)
    transient = admin('restart', extra_env={
        **manager_env(),
        'SUPERTERM_TEST_LAUNCHCTL_PRINT_EXIT': '75',
    })
    transient_calls = (read(service_log).splitlines()
                       if os.path.exists(service_log) else [])
    check('transient launchctl query fails closed',
          transient.returncode != 0 and
          'cannot determine' in transient.stderr.lower())
    check('failed launchctl query mutates no state',
          read(generated, binary=True) == transient_generated and
          read(service_files[0], binary=True) == transient_descriptor and
          read_service_state() == (1, 1) and
          transient_calls == [
              'print-disabled system',
              'print system/org.superterm.sshd',
          ])


# Keep the old descriptor valid but observably different from the freshly
# generated one. Otherwise a missing descriptor rollback would compare equal
# by accident and this test could lie while only the config rollback worked.
descriptor_before_fault = read(service_files[0])
if sys.platform == 'darwin':
    descriptor_before_fault = descriptor_before_fault.replace(
        '</plist>', '  <!-- rollback sentinel -->\n</plist>')
else:
    descriptor_before_fault += '# rollback sentinel\n'
with open(service_files[0], 'w', encoding='utf-8') as stream:
    stream.write(descriptor_before_fault)
os.chmod(service_files[0], 0o644)
accepted_snapshot = read(generated, binary=True)
descriptor_snapshot = read(service_files[0], binary=True)
write_ini(listen='127.0.0.1:38222')
reset_manager(True, True)
failed_restart = admin('restart', extra_env=manager_env())
calls = read(service_log).splitlines() if os.path.exists(service_log) else []
restart_command = 'bootstrap ' if sys.platform == 'darwin' else 'restart '
check('failed service activation is reported', failed_restart.returncode != 0)
check('failed activation restores accepted files exactly',
      read(generated, binary=True) == accepted_snapshot and
      read(service_files[0], binary=True) == descriptor_snapshot)
check('rollback restarts previously active service',
      read_service_state() == (1, 1) and
      sum(line.startswith(restart_command) for line in calls) == 2)
check('rollback preserves pending public edit', '38222' in read(ini))
write_ini()
check('accepted state recovers after rollback', admin('restart').returncode == 0)

# `enable` mutates persistent policy before it restarts. Inject failure at that
# restart for every possible pair and demand byte-for-byte/state-for-state
# rollback. In particular, inactive must stay inactive and disabled must stay
# disabled; a mere restart cannot satisfy either invariant.
for was_enabled in (False, True):
    for was_active in (False, True):
        reset_manager(was_enabled, was_active)
        accepted_snapshot = read(generated, binary=True)
        descriptor_snapshot = read(service_files[0], binary=True)
        failed_enable = admin('enable', extra_env=manager_env())
        calls = (read(service_log).splitlines()
                 if os.path.exists(service_log) else [])
        state_label = (f'enabled={int(was_enabled)},'
                       f'active={int(was_active)}')
        check(f'failed enable is reported ({state_label})',
              failed_enable.returncode != 0)
        check(f'failed enable restores files ({state_label})',
              read(generated, binary=True) == accepted_snapshot and
              read(service_files[0], binary=True) == descriptor_snapshot)
        check(f'failed enable restores exact manager state ({state_label})',
              read_service_state() ==
              (int(was_enabled), int(was_active)))
        check(f'fault and rollback paths were exercised ({state_label})',
              os.path.exists(fail_marker) and
              sum(line.startswith(restart_command) for line in calls) ==
              (2 if was_active else 1))

# A mismatched .pub is detected by check and repaired by idempotent setup;
# the private host identity must remain byte-for-byte unchanged.
with open(host_pub, 'w', encoding='ascii') as stream:
    stream.write('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBadKeyForTestOnly\n')
os.chmod(host_pub, 0o644)
check('mismatched host public key rejected', admin('check').returncode != 0)
check('setup repairs only public half', admin('setup').returncode == 0 and
      hashlib.sha256(read(host_key, binary=True)).hexdigest() == private_before)

# Central key management validates with the real ssh-keygen and is atomic.
ssh_keygen = next((path for path in ('/usr/bin/ssh-keygen',
                                     '/usr/local/bin/ssh-keygen',
                                     '/opt/homebrew/bin/ssh-keygen')
                   if os.path.isfile(path) and os.access(path, os.X_OK)), '')
check('real ssh-keygen is available', bool(ssh_keygen))
client_key = os.path.join(HOME, 'id_test_ed25519')
rsa_comment_root = ''
if ssh_keygen:
    # `ssh-keygen -l` prints the comment as well as a parenthesized key type.
    # A type check based on a substring can therefore be spoofed by an RSA
    # key whose comment says "(ED25519)".
    rsa_comment_root = os.path.join(HOME, 'rsa-comment-root')
    os.makedirs(rsa_comment_root, mode=0o755)
    rsa_host_key = os.path.join(rsa_comment_root, 'ssh_host_ed25519_key')
    rsa_keygen = subprocess.run(
        [ssh_keygen, '-q', '-t', 'rsa', '-b', '2048', '-N', '',
         '-C', '(ED25519)', '-f', rsa_host_key],
        text=True, capture_output=True)
    rsa_setup = admin('setup', root=rsa_comment_root)
    check('host key type uses actual public-key prefix',
          rsa_keygen.returncode == 0 and rsa_setup.returncode != 0 and
          'not Ed25519' in rsa_setup.stderr and
          not os.path.exists(os.path.join(
              rsa_comment_root, 'sshd_config.generated')))

    keygen = subprocess.run(
        [ssh_keygen, '-q', '-t', 'ed25519', '-N', '', '-f', client_key],
        text=True, capture_output=True)
    check('client test key generated', keygen.returncode == 0)
    added = admin('authorize', USER, client_key + '.pub')
    key_file = os.path.join(auth_dir, USER)
    lines = [line for line in read(key_file).splitlines() if line.strip()]
    check('central authorization succeeds', added.returncode == 0 and
          len(lines) == 1 and len(lines[0].split()) == 2 and
          mode(key_file) == 0o644)
    # Comments are outside the signed key blob. C1 and bidi controls survive
    # byte-oriented ASCII checks but can spoof the root terminal used by
    # list-keys. Newly imported keys are stored as exactly `type blob`; an
    # existing line is normalized in memory before it can reach admin output.
    with open(key_file, 'w', encoding='utf-8') as stream:
        stream.write(lines[0] + ' untrusted\u009b[2J\u202Eroot\u2066\n')
    os.chmod(key_file, 0o644)
    spoof_list = admin('list-keys', USER)
    check('authorized-key comments cannot spoof admin output',
          spoof_list.returncode == 0 and
          '\u009b' not in spoof_list.stdout and
          '\u202e' not in spoof_list.stdout and
          '\u2066' not in spoof_list.stdout and
          'untrusted' not in spoof_list.stdout)
    duplicate = admin('authorize', USER, client_key + '.pub')
    check('duplicate authorization is idempotent',
          duplicate.returncode == 0 and
          len([line for line in read(key_file).splitlines()
               if line.strip()]) == 1)
    fingerprint_out = subprocess.run(
        [ssh_keygen, '-l', '-E', 'sha256', '-f', client_key + '.pub'],
        text=True, capture_output=True, check=True).stdout.split()
    fingerprint = next((part for part in fingerprint_out
                        if part.startswith('SHA256:')), '')
    listed = admin('list-keys', USER)
    check('list reports SHA256 fingerprint', listed.returncode == 0 and
          fingerprint and fingerprint in listed.stdout)

    before = read(key_file, binary=True)
    wrong_case = 'SHA256:' + fingerprint[len('SHA256:'):].swapcase()
    case_revoke = admin('revoke', USER, wrong_case)
    check('fingerprints are matched case-sensitively',
          case_revoke.returncode != 0 and
          read(key_file, binary=True) == before)

    symlink_key = os.path.join(HOME, 'symlink-client-key.pub')
    os.symlink(client_key + '.pub', symlink_key)
    symlink_add = admin('authorize', USER, symlink_key)
    check('symlinked public-key source rejected',
          symlink_add.returncode != 0 and
          read(key_file, binary=True) == before)

    multiple_keys = os.path.join(HOME, 'multiple-keys.pub')
    with open(multiple_keys, 'w', encoding='utf-8') as stream:
        stream.write(read(client_key + '.pub'))
        stream.write(read(client_key + '.pub'))
    multiple_add = admin('authorize', USER, multiple_keys)
    check('public-key source must contain exactly one key',
          multiple_add.returncode != 0 and
          read(key_file, binary=True) == before)

    option_key = os.path.join(HOME, 'key-with-options.pub')
    with open(option_key, 'w', encoding='utf-8') as stream:
        stream.write('restrict ' + read(client_key + '.pub'))
    rejected = admin('authorize', USER, option_key)
    check('authorized-key options rejected', rejected.returncode != 0 and
          read(key_file, binary=True) == before)

    revoked = admin('revoke', USER, fingerprint)
    check('revoke by fingerprint succeeds', revoked.returncode == 0 and
          read(key_file).strip() == '')

# Neither a symlinked public config nor '/' can become an administration root.
bad_root = os.path.join(HOME, 'symlink-root')
os.makedirs(bad_root, mode=0o755)
os.symlink(ini, os.path.join(bad_root, 'server.ini'))
check('server.ini symlink rejected', admin('setup', root=bad_root).returncode != 0)
root_override = admin('setup', root='/')
check('filesystem root override rejected',
      root_override.returncode != 0 and
      'may not be the filesystem root' in root_override.stderr)

# The service descriptor enters through this wrapper. It validates the last
# accepted generated file against the currently installed sshd and then
# execs that same binary in-place; a broken pending server.ini is irrelevant.
if sshd:
    write_ini()
    check('accepted config prepared for wrapper', admin('restart').returncode == 0)
    accepted_for_run = read(generated, binary=True)
    fake_sshd = os.path.join(HOME, 'fake-sshd-wrapper')
    wrapper_log = os.path.join(HOME, 'wrapper-exec.log')
    with open(fake_sshd, 'w', encoding='utf-8') as stream:
        stream.write('#!/bin/sh\n')
        stream.write('case "$1" in -t|-T) exec ' + shlex.quote(sshd) +
                     ' "$@" ;; esac\n')
        stream.write('printf "%s\\n" "$*" > "$SUPERTERM_TEST_WRAPPER_LOG"\n')
        stream.write('exit 0\n')
    os.chmod(fake_sshd, 0o755)
    wrapper_env = {
        'SUPERTERM_TEST_SSHD': fake_sshd,
        'SUPERTERM_TEST_WRAPPER_LOG': wrapper_log,
    }

    accepted_text = accepted_for_run.decode('utf-8')
    unsafe_variants = (
        ('extra effective AuthorizedKeysFile', accepted_text.replace(
            'AuthorizedKeysFile ' + auth_dir + '/%u',
            'AuthorizedKeysFile ' + auth_dir +
            '/%u /tmp/extra-authorized-keys', 1)),
        ('disabled StrictModes',
         accepted_text.replace('StrictModes yes', 'StrictModes no', 1)),
        ('incoherent authentication methods', accepted_text.replace(
            'AuthenticationMethods any',
            'AuthenticationMethods publickey', 1)),
        ('accepted client environment', accepted_text + 'AcceptEnv ST_ATTACK\n'),
        ('forced environment', accepted_text + 'SetEnv ST_ATTACK=1\n'),
        ('SFTP subsystem', accepted_text + 'Subsystem sftp internal-sftp\n'),
        ('trusted user CA', accepted_text +
         'TrustedUserCAKeys ' + host_pub + '\n'),
        ('conditional Match override', accepted_text +
         'Match User *\n    ForceCommand /bin/sh\n'),
        ('external Include', accepted_text + 'Include /dev/null\n'),
    )
    match_global_stays_safe = False
    for label, unsafe_accepted in unsafe_variants:
        with open(generated, 'w', encoding='utf-8') as stream:
            stream.write(unsafe_accepted)
        os.chmod(generated, 0o600)
        if label == 'conditional Match override':
            global_dump = subprocess.run(
                [sshd, '-T', '-f', generated], text=True,
                capture_output=True)
            match_global_stays_safe = (
                global_dump.returncode == 0 and
                ('forcecommand ' + os.path.realpath(stlib.BIN) +
                 ' --ssh-entry').lower() in global_dump.stdout.lower())
        try:
            os.unlink(wrapper_log)
        except FileNotFoundError:
            pass
        rejected_effective = admin('run', extra_env=wrapper_env)
        check('wrapper rejects ' + label,
              rejected_effective.returncode != 0 and
              not os.path.exists(wrapper_log))
    check('plain sshd -T misses conditional Match override',
          match_global_stays_safe)

    with open(generated, 'wb') as stream:
        stream.write(accepted_for_run)
    os.chmod(generated, 0o600)
    write_ini(extra='UnexpectedDirective=/bin/sh\n')
    foreground = admin('run', extra_env={
        **wrapper_env,
    })
    wrapper_args = read(wrapper_log).strip() if os.path.exists(wrapper_log) else ''
    check('service wrapper execs accepted sshd in place',
          foreground.returncode == 0 and wrapper_args.startswith('-D -e -f ') and
          wrapper_args.endswith(generated))
    check('service wrapper ignores invalid pending file',
          read(generated, binary=True) == accepted_for_run)

shutil.rmtree(ROOT, ignore_errors=True)
shutil.rmtree(bad_root, ignore_errors=True)
shutil.rmtree(failed_key_root, ignore_errors=True)
shutil.rmtree(privileged_root, ignore_errors=True)
shutil.rmtree(global_rc_root, ignore_errors=True)
if sys.platform == 'darwin':
    shutil.rmtree(alias_tree, ignore_errors=True)
    shutil.rmtree(alias_setup_root, ignore_errors=True)
    shutil.rmtree(bad_alias_tree, ignore_errors=True)
    shutil.rmtree(bad_alias_root, ignore_errors=True)
    shutil.rmtree(linked_target_tree, ignore_errors=True)
    shutil.rmtree(linked_target_root, ignore_errors=True)
if rsa_comment_root:
    shutil.rmtree(rsa_comment_root, ignore_errors=True)
stlib.report()
