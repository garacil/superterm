#!/usr/bin/env python3
"""Real OpenSSH transport integration without touching the host service.

The administrative configuration is generated below a suite-owned directory
inside the target account's real home. That placement deliberately keeps the
production ``StrictModes yes`` policy testable. The runtime file differs from
the generated file only by one harness ``SetEnv`` directive which redirects
the forced SuperTerm process to this test's isolated application HOME.

The real listener is exercised only with euid 0: sshd must perform its normal
account/session setup, and pretending that an unprivileged partial run proves
that path would be a false positive.  CI sets ``SUPERTERM_TEST_SSH_USER`` to
its original ordinary runner account; that makes every listener prerequisite
and the observed real UID descent mandatory.  No system service, /etc/ssh
file, user SSH configuration, tmux session, or unrelated process is changed
or signalled.  On Debian/Ubuntu the fixture may create the distribution's
standard root-owned ``/run/sshd`` runtime directory when direct ``sshd -t``
reports it missing; it is intentionally retained because another OpenSSH
process may begin using that shared chroot immediately.
"""

import configparser
import fcntl
import os
import pty
import pwd
import re
import select
import shutil
import signal
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import termios
import time

import pyte

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, run_cli


CURRENT_ACCOUNT = pwd.getpwuid(os.geteuid())
REQUESTED_USER = os.environ.get('SUPERTERM_TEST_SSH_USER', '')
ACCOUNT_ERROR = ''
ACCOUNT = CURRENT_ACCOUNT
if REQUESTED_USER:
    if (not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}',
                         REQUESTED_USER, re.ASCII)):
        ACCOUNT_ERROR = 'SUPERTERM_TEST_SSH_USER is not a safe account name'
    else:
        try:
            ACCOUNT = pwd.getpwnam(REQUESTED_USER)
        except KeyError:
            ACCOUNT_ERROR = ('SUPERTERM_TEST_SSH_USER does not name a local '
                             'account')
        else:
            if ACCOUNT.pw_name != REQUESTED_USER:
                ACCOUNT_ERROR = ('SUPERTERM_TEST_SSH_USER did not resolve '
                                 'canonically')
            elif ACCOUNT.pw_uid == 0:
                ACCOUNT_ERROR = ('SUPERTERM_TEST_SSH_USER must be an '
                                 'ordinary non-root account')

# A root-started forced command must be able to traverse the isolated HOME
# after sshd drops privileges.  /tmp is sticky and searchable on GNU/Linux
# and macOS; the mkdtemp itself remains private and is chowned below.
HOME = stlib.fresh_home('ssh-transport', base='/tmp')
USER = ACCOUNT.pw_name
REAL_HOME = ACCOUNT.pw_dir
SSHD_ROOT = ''
PORT = 0
KNOWN_HOSTS = os.path.join(HOME, 'known_hosts')
CLIENT_KEY = os.path.join(HOME, 'id_client')
OTHER_KEY = os.path.join(HOME, 'id_other')
SSHD_LOG = os.path.join(HOME, 'sshd.log')
DEBUG_LOG = os.path.join(HOME, 'superterm-ssh-transport.log')
SESSION = 'ssh-e2e'
LINUX_PRIVSEP_PATH = '/run/sshd'
LINUX_PRIVSEP_ERROR = (
    'superterm ssh-server: sshd rejected generated configuration (-t): '
    'Missing privilege separation directory: /run/sshd')


def executable(candidates):
    return next((path for path in candidates
                 if os.path.isfile(path) and os.access(path, os.X_OK)), '')


SSHD = executable(('/usr/sbin/sshd', '/usr/bin/sshd',
                   '/usr/local/sbin/sshd', '/opt/homebrew/sbin/sshd'))
SSH = executable(('/usr/bin/ssh', '/usr/local/bin/ssh',
                  '/opt/homebrew/bin/ssh'))
SFTP = executable(('/usr/bin/sftp', '/usr/local/bin/sftp',
                   '/opt/homebrew/bin/sftp'))
KEYGEN = executable(('/usr/bin/ssh-keygen', '/usr/local/bin/ssh-keygen',
                     '/opt/homebrew/bin/ssh-keygen'))


def skip(name, reason):
    print(f'{name:36}: SKIP ({reason})')


def free_port():
    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        probe.bind(('127.0.0.1', 0))
        return probe.getsockname()[1]
    finally:
        probe.close()


def admin(*args):
    env = dict(os.environ,
               HOME=HOME,
               TERM='xterm',
               LANG='C',
               SUPERTERM_INI=os.path.join(HOME, 'no-system.ini'),
               SUPERTERM_TESTING='1',
               SUPERTERM_SSHD_ROOT=SSHD_ROOT)
    return subprocess.run([stlib.BIN, 'ssh-server', *args], env=env,
                          text=True, capture_output=True, timeout=45)


def trusted_root_directory(path, exact_mode=None):
    """Return lstat data only for a real, root-owned protected directory."""
    try:
        info = os.lstat(path)
    except OSError:
        return None
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or
            (stat.S_IMODE(info.st_mode) & 0o022) != 0):
        return None
    if exact_mode is not None and stat.S_IMODE(info.st_mode) != exact_mode:
        return None
    return info


def retry_setup_with_linux_privsep(setup):
    """Supply Ubuntu's sshd runtime prerequisite to this isolated fixture.

    Debian/Ubuntu compile sshd with ``--with-privsep-path=/run/sshd``. Their
    systemd unit normally creates that path, but this test intentionally
    starts neither the host unit nor the host listener. Mirror the distro's
    own test fixture only after the exact diagnostic. The standard runtime
    directory is not removed: an external sshd may begin using the empty
    chroot at any point, which cannot be proven from directory contents.
    """
    if (setup.returncode == 0 or not sys.platform.startswith('linux') or
            os.geteuid() != 0 or
            setup.stderr.strip() != LINUX_PRIVSEP_ERROR):
        return setup
    if trusted_root_directory('/run') is None:
        return setup

    try:
        old_umask = os.umask(0o022)
        try:
            os.mkdir(LINUX_PRIVSEP_PATH, 0o755)
        finally:
            os.umask(old_umask)
    except FileExistsError:
        # A service may have created the normal path after sshd -t failed.
        pass
    except OSError as exc:
        print('cannot create isolated sshd privilege-separation path: ' +
              str(exc))
        return setup

    info = trusted_root_directory(LINUX_PRIVSEP_PATH, exact_mode=0o755)
    if info is None:
        print('refusing unsafe sshd privilege-separation path: ' +
              LINUX_PRIVSEP_PATH)
        return setup
    return admin('setup')


def session_path(suffix):
    return os.path.join(HOME, '.superterm', 'sessions', SESSION + suffix)


def session_meta():
    cp = configparser.ConfigParser()
    try:
        cp.read(session_path('.ini'))
        return {
            'panes': cp.getint('session', 'panes', fallback=-1),
            'attached': cp.getint('session', 'attached', fallback=-1),
        }
    except (OSError, configparser.Error, ValueError):
        return {'panes': -1, 'attached': -1}


def session_daemon_claim():
    cp = configparser.ConfigParser()
    try:
        cp.read(session_path('.ini'))
        return (cp.getint('session', 'pid', fallback=0),
                cp.get('session', 'pid_identity', fallback='').strip())
    except (OSError, configparser.Error, ValueError):
        return 0, ''


def prepare_application_home():
    """Give the selected login UID the complete private isolated HOME."""
    target_uid = ACCOUNT.pw_uid
    target_gid = ACCOUNT.pw_gid
    paths = []
    for root, dirs, files in os.walk(HOME, topdown=True, followlinks=False):
        paths.append(root)
        paths.extend(os.path.join(root, name) for name in dirs + files)
    for path in paths:
        info = os.lstat(path)
        if stat.S_ISLNK(info.st_mode):
            raise RuntimeError('refusing symlink in isolated HOME: ' + path)
    if os.geteuid() == 0:
        # Children first leaves the directory reachable until the last step.
        for path in reversed(paths):
            os.chown(path, target_uid, target_gid)
    os.chmod(HOME, 0o700)
    os.chmod(os.path.join(HOME, '.superterm'), 0o700)
    ownership = [(path, os.lstat(path)) for path in paths]
    wrong_uid = [(path, info.st_uid) for path, info in ownership
                 if info.st_uid != target_uid]
    wrong_gid = [(path, info.st_gid) for path, info in ownership
                 if info.st_gid != target_gid]
    if wrong_uid:
        print('isolated HOME UID mismatches: ' + repr(wrong_uid))
    if wrong_gid:
        # A hosted Darwin runner may start the ordinary account with an
        # effective group different from pwd.pw_gid.  OpenSSH 10.5p1
        # misc.c:safe_path validates owner UID plus mode 022, not the group
        # number; HOME/.superterm are 0700, so a different group gains no
        # access and is not an authentication failure.
        print('isolated HOME non-primary groups (safe under mode 0700): ' +
              repr(wrong_gid))
    return not wrong_uid


def process_table():
    """Return portable ancestry/arguments; credentials come from the OS."""
    try:
        result = subprocess.run(
            ['/bin/ps', '-axo', 'pid=,ppid=,command='],
            text=True, capture_output=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return {}
    if result.returncode != 0:
        return {}
    rows = {}
    for line in result.stdout.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) != 3:
            continue
        try:
            pid, ppid = map(int, fields[:2])
        except ValueError:
            continue
        rows[pid] = (ppid, -1, -1, fields[2])
    return rows


def exact_listener_descendants(listener_pid, rows):
    descendants = {listener_pid}
    changed = True
    while changed:
        changed = False
        for pid, (ppid, _ruid, _euid, _command) in rows.items():
            if pid not in descendants and ppid in descendants:
                descendants.add(pid)
                changed = True
    descendants.discard(listener_pid)
    return descendants


def _forget_dead_listener_claims(claims):
    """Drop only generations which the kernel says no longer exist."""
    for pid, identity in list(claims.items()):
        if stlib.process_identity(pid) == identity:
            continue
        # Do not call unregister_process(pid) after a mismatch: another
        # suite-owned child could already have reused and registered that
        # number.  stlib's identity-qualified audit retires the stale record.
        del claims[pid]


def remember_listener_descendants(listener_pid, listener_identity, claims):
    """Register stable birth identities for the listener's current tree.

    OpenSSH's production accept loop forks a per-connection child and its PTY
    path forks the forced command again.  A process must be in two consecutive
    ancestry snapshots and retain one strong birth identity before this test
    records cleanup authority over it.  A transient or recycled numeric PID
    is therefore never enough to authorise a later signal.
    """
    _forget_dead_listener_claims(claims)
    if (listener_pid <= 1 or not listener_identity or
            stlib.process_identity(listener_pid) != listener_identity):
        return
    before = process_table()
    candidates = exact_listener_descendants(listener_pid, before)
    identities = {}
    for pid in candidates:
        identity = stlib.process_identity(pid)
        if identity:
            identities[pid] = identity
    after = process_table()
    if stlib.process_identity(listener_pid) != listener_identity:
        return
    descendants = exact_listener_descendants(listener_pid, after)
    for pid, identity in identities.items():
        if pid not in descendants:
            continue
        if stlib.process_identity(pid) != identity:
            continue
        previous = claims.get(pid)
        if previous == identity:
            continue
        registered = stlib.register_process(
            pid, 'ssh-transport-listener-descendant')
        if registered == identity:
            claims[pid] = identity
        elif registered:
            # register_process observed a different generation after our
            # snapshot. Do not retain authority over that racing PID.
            stlib.unregister_process(pid)


def release_managed_daemon_claims(claims):
    """Leave the detached SuperTerm daemon to close_all_daemons().

    The server may briefly have been below the SSH process tree while it was
    daemonising. Its authenticated sidecar and all of its current children
    belong to stlib's separate FRAME_CLOSE cleanup path, not to the transport
    connection cleanup below.
    """
    daemon_pid, daemon_identity = session_daemon_claim()
    if (daemon_pid <= 1 or not daemon_identity or
            stlib.process_identity(daemon_pid) != daemon_identity):
        return
    rows = process_table()
    managed = exact_listener_descendants(daemon_pid, rows)
    managed.add(daemon_pid)
    for pid in managed:
        identity = claims.get(pid)
        if not identity or stlib.process_identity(pid) != identity:
            continue
        stlib.unregister_process(pid)
        del claims[pid]


def live_listener_tree_is_claimed(listener_pid, listener_identity, claims):
    """Prove every currently live OpenSSH connection process is identified."""
    remember_listener_descendants(listener_pid, listener_identity, claims)
    release_managed_daemon_claims(claims)
    if stlib.process_identity(listener_pid) != listener_identity:
        return False
    rows = process_table()
    current = exact_listener_descendants(listener_pid, rows)
    daemon_pid, daemon_identity = session_daemon_claim()
    if (daemon_pid > 1 and daemon_identity and
            stlib.process_identity(daemon_pid) == daemon_identity):
        managed = exact_listener_descendants(daemon_pid, rows)
        managed.add(daemon_pid)
        current.difference_update(managed)
    if not current:
        return False
    for pid in current:
        identity = stlib.process_identity(pid)
        if not identity or claims.get(pid) != identity:
            return False
    return True


def listener_descendant_state(listener_pid, listener_identity, claims):
    """Return exact live claims and the listener's observable current tree."""
    remember_listener_descendants(listener_pid, listener_identity, claims)
    release_managed_daemon_claims(claims)
    _forget_dead_listener_claims(claims)
    if stlib.process_identity(listener_pid) == listener_identity:
        rows = process_table()
        current = exact_listener_descendants(listener_pid, rows)
    else:
        current = set()
    live = {pid: identity for pid, identity in claims.items()
            if stlib.process_identity(pid) == identity}
    unclaimed = {pid for pid in current if pid not in live}
    return live, current, unclaimed


def wait_listener_descendants(listener_pid, listener_identity, claims,
                              timeout):
    """Wait until both historical exact claims and current ancestry vanish."""
    deadline = time.monotonic() + timeout
    state = ({}, set(), set())
    while True:
        state = listener_descendant_state(listener_pid, listener_identity,
                                          claims)
        if not state[0] and not state[1]:
            return True, state
        if time.monotonic() >= deadline:
            return False, state
        time.sleep(0.05)


def signal_exact_listener_claims(claims, signum):
    """Signal matching birth generations, never groups or bare PIDs."""
    for pid, identity in list(claims.items()):
        if stlib.process_identity(pid) != identity:
            # As above, a reused PID may already have another registration;
            # deleting our stale local claim is safe, unregistering by number
            # here would not be.
            del claims[pid]
            continue
        try:
            os.kill(pid, signum)
        except ProcessLookupError:
            pass
        except OSError as exc:
            print(f'cannot signal exact sshd descendant pid={pid}: {exc}')


def close_listener_descendants(listener_pid, listener_identity, claims):
    """Prove natural connection exit, then safely clean exact survivors."""
    if listener_pid <= 1:
        return
    natural, state = wait_listener_descendants(
        listener_pid, listener_identity, claims, 8.0)
    check('SSH connection descendants exit', natural)
    if not natural:
        live, current, unclaimed = state
        print('  live exact descendant claims: ' + repr(sorted(live)))
        print('  current listener descendants: ' + repr(sorted(current)))
        if unclaimed:
            print('  descendants without strong claim: ' +
                  repr(sorted(unclaimed)))
        signal_exact_listener_claims(claims, signal.SIGTERM)
        gone, _ = wait_listener_descendants(
            listener_pid, listener_identity, claims, 2.0)
        if not gone:
            signal_exact_listener_claims(claims, signal.SIGKILL)
            gone, state = wait_listener_descendants(
                listener_pid, listener_identity, claims, 2.0)
        check('exact SSH descendant cleanup succeeds', gone)
        if not gone:
            live, current, unclaimed = state
            print('  survivors after exact cleanup: ' +
                  repr(sorted(set(live) | current | unclaimed)))
    else:
        check('exact SSH descendant cleanup succeeds', True)


def stable_process_uids(pid):
    """Read credentials only if the PID generation stayed unchanged."""
    identity = stlib.process_identity(pid)
    if not identity:
        return None
    uids = stlib.process_uids(pid)
    if stlib.process_identity(pid) != identity:
        return None
    return uids


def transport_identities(listener_pid):
    """Observe the exact forced command tree and detached session daemon."""
    rows = process_table()
    daemon_pid, daemon_claim = session_daemon_claim()
    daemon = rows.get(daemon_pid)
    if daemon is not None:
        daemon_uids = stable_process_uids(daemon_pid) or (-1, -1)
        if stlib.process_identity(daemon_pid) != daemon_claim:
            daemon_uids = (-1, -1)
        daemon = (daemon[0], *daemon_uids, daemon[3])
    descendants = exact_listener_descendants(listener_pid, rows)
    forced = []
    for pid in descendants:
        row = rows[pid]
        if '--ssh-entry' not in row[3]:
            continue
        forced_uids = stable_process_uids(pid) or (-1, -1)
        forced.append((row[0], *forced_uids, row[3]))
    return daemon_pid, daemon, forced


def pane_size():
    result = run_cli(['list', SESSION], HOME, env={'LANG': 'C'})
    if result.returncode != 0:
        return None
    for line in result.stdout.splitlines():
        if not line.startswith('1 '):
            continue
        for token in line.split():
            if 'x' not in token or not token[:1].isdigit():
                continue
            try:
                cols, rows = token.split('x', 1)
                return int(cols), int(rows)
            except ValueError:
                continue
    return None


def base_ssh_args(identity=CLIENT_KEY):
    return [
        SSH, '-F', '/dev/null', '-p', str(PORT), '-l', USER,
        '-i', identity,
        '-o', 'IdentitiesOnly=yes',
        '-o', 'BatchMode=yes',
        '-o', 'PasswordAuthentication=no',
        '-o', 'KbdInteractiveAuthentication=no',
        '-o', 'StrictHostKeyChecking=accept-new',
        '-o', 'UserKnownHostsFile=' + KNOWN_HOSTS,
        '-o', 'GlobalKnownHostsFile=/dev/null',
        '-o', 'ConnectTimeout=5',
        '-o', 'ConnectionAttempts=1',
        '-o', 'LogLevel=ERROR',
    ]


class SshPty:
    """A standard interactive ssh client with deterministic initial size."""

    def __init__(self, width, height):
        self.width = width
        self.height = height
        self.screen = pyte.Screen(width, height)
        self.stream = pyte.ByteStream(self.screen)
        self.raw = b''
        self.reaped = False
        self.status = None

        # Without this barrier ssh could send 80x24 before the parent applies
        # TIOCSWINSZ. The first size seen by sshd is therefore deterministic.
        start_read, start_write = os.pipe()
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.close(start_write)
            try:
                os.read(start_read, 1)
            finally:
                os.close(start_read)
            env = dict(os.environ, HOME=HOME, TERM='xterm', LANG='C.UTF-8')
            os.execve(SSH, base_ssh_args() + ['-tt', '127.0.0.1'], env)

        os.close(start_read)
        stlib.register_process(self.pid, 'ssh-transport-client')
        try:
            fcntl.ioctl(self.fd, termios.TIOCSWINSZ,
                        struct.pack('HHHH', height, width, 0, 0))
            os.write(start_write, b'1')
        finally:
            os.close(start_write)

    def drain(self, seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            try:
                ready, _, _ = select.select([self.fd], [], [], 0.05)
            except (OSError, ValueError):
                return
            if not ready:
                continue
            try:
                data = os.read(self.fd, 65536)
            except OSError:
                return
            if not data:
                return
            prefix = self.raw[-3:]
            self.raw += data
            for _ in range((prefix + data).count(b'\x1b[6n')):
                try:
                    os.write(self.fd, b'\x1b[5;1R')
                except OSError:
                    break
            try:
                self.stream.feed(data)
            except Exception:
                pass

    def text(self):
        return '\n'.join(row.rstrip() for row in self.screen.display)

    def send(self, data, seconds=0.5):
        try:
            os.write(self.fd, data)
        except OSError:
            pass
        self.drain(seconds)

    def resize(self, width, height, seconds=1.0):
        """Change the real client PTY; ioctl sends SIGWINCH to ssh."""
        self.width = width
        self.height = height
        self.screen.resize(lines=height, columns=width)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ,
                    struct.pack('HHHH', height, width, 0, 0))
        self.drain(seconds)

    def wait_exit(self, timeout=6.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.reaped:
                return self.status
            try:
                pid, status = os.waitpid(self.pid, os.WNOHANG)
            except ChildProcessError:
                self.reaped = True
                stlib.unregister_process(self.pid)
                return self.status
            if pid:
                self.reaped = True
                self.status = status
                stlib.unregister_process(self.pid)
                return status
            self.drain(0.05)
        return None

    def close(self):
        if not self.reaped:
            try:
                os.kill(self.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            if self.wait_exit(1.5) is None:
                try:
                    os.kill(self.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                self.wait_exit(1.0)
        try:
            os.close(self.fd)
        except OSError:
            pass


def wait_for(predicate, clients=(), timeout=10.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        for client in clients:
            client.drain(0.04)
        if predicate():
            return True
        time.sleep(0.025)
    return predicate()


def wait_listener(proc, timeout=8.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            return False
        probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            probe.settimeout(0.2)
            if probe.connect_ex(('127.0.0.1', PORT)) == 0:
                return True
        finally:
            probe.close()
        time.sleep(0.05)
    return False


def stop_exact(proc):
    """Bounded cleanup of only the suite-owned foreground sshd PID."""
    if proc is None:
        return
    if proc.poll() is not None:
        stlib.unregister_process(proc.pid)
        return
    proc.terminate()
    try:
        proc.wait(timeout=3.0)
    except subprocess.TimeoutExpired:
        proc.kill()
        try:
            proc.wait(timeout=1.0)
        except subprocess.TimeoutExpired:
            check('suite sshd terminates after SIGKILL', False)
    if proc.poll() is not None:
        stlib.unregister_process(proc.pid)


def run_rejected(args, listener_pid, listener_identity, descendant_claims,
                 timeout=12):
    before = session_meta()['attached']
    timed_out = False
    try:
        proc = subprocess.Popen(args, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE)
        deadline = time.monotonic() + timeout
        while True:
            try:
                remaining = max(0.001, deadline - time.monotonic())
                stdout, stderr = proc.communicate(
                    timeout=min(0.10, remaining))
                break
            except subprocess.TimeoutExpired:
                remember_listener_descendants(
                    listener_pid, listener_identity, descendant_claims)
                if time.monotonic() < deadline:
                    continue
                timed_out = True
                proc.terminate()
                try:
                    stdout, stderr = proc.communicate(timeout=1.0)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    try:
                        stdout, stderr = proc.communicate(timeout=1.0)
                    except subprocess.TimeoutExpired as exc:
                        stdout = exc.stdout or ''
                        stderr = exc.stderr or ''
                        check('timed-out SSH probe terminates', False)
                break
        remember_listener_descendants(
            listener_pid, listener_identity, descendant_claims)
        result = subprocess.CompletedProcess(args, proc.returncode,
                                             stdout, stderr)
    except OSError as exc:
        # Preserve launch diagnostics and let the policy check fail without
        # bypassing the bounded listener/client cleanup in main's finally.
        result = subprocess.CompletedProcess(args, -1, '', str(exc))
    unchanged = wait_for(lambda: session_meta()['attached'] == before,
                         timeout=2.0)
    return result, unchanged, timed_out


def show_sshd_tail():
    if not os.path.exists(SSHD_LOG):
        return
    try:
        with open(SSHD_LOG, 'rb') as stream:
            tail = stream.read()[-5000:].decode('utf-8', 'replace').strip()
    except OSError:
        return
    if tail:
        print('\n--- isolated sshd diagnostic tail ---')
        print(tail)


def main():
    global SSHD_ROOT, PORT

    if ACCOUNT_ERROR:
        check('SSH transport account is safe', False)
        print(ACCOUNT_ERROR)
        return
    if (REQUESTED_USER and os.geteuid() != 0 and
            ACCOUNT.pw_uid != os.geteuid()):
        check('SSH transport account is assumable', False)
        print('euid 0 is required to assume SUPERTERM_TEST_SSH_USER')
        return
    if not (os.path.isabs(REAL_HOME) and os.path.isdir(REAL_HOME)):
        check('SSH transport account home exists', False)
        print('invalid account home: ' + REAL_HOME)
        return

    if not (SSHD and KEYGEN):
        missing = ', '.join(name for name, path in
                            (('sshd', SSHD), ('ssh-keygen', KEYGEN))
                            if not path)
        if REQUESTED_USER:
            check('mandatory OpenSSH prerequisites', False)
            print('missing ' + missing)
        else:
            skip('OpenSSH configuration integration', 'missing ' + missing)
        return

    # StrictModes walks this path using the authenticated account. A private
    # mkdtemp below its real home avoids weakening the generated policy.
    SSHD_ROOT = tempfile.mkdtemp(prefix='.superterm-sshd-test-',
                                 dir=REAL_HOME)
    os.chmod(SSHD_ROOT, 0o700)
    PORT = free_port()
    sshd_proc = None
    first = None
    second = None
    third = None
    log_stream = None
    listener_identity = ''
    descendant_claims = {}
    try:
        server_ini = os.path.join(SSHD_ROOT, 'server.ini')
        with open(server_ini, 'w', encoding='utf-8') as stream:
            stream.write('[server]\nconfig_version=1\n')
            stream.write(f'listen=127.0.0.1:{PORT}\n')
            stream.write(f'allow_root={1 if USER == "root" else 0}\n')
        os.chmod(server_ini, 0o644)

        keys_ok = True
        for key in (CLIENT_KEY, OTHER_KEY):
            generated = subprocess.run(
                [KEYGEN, '-q', '-t', 'ed25519', '-N', '', '-f', key],
                text=True, capture_output=True, timeout=30)
            key_ok = generated.returncode == 0
            check('transport client key generated', key_ok)
            keys_ok = keys_ok and key_ok
        if not keys_ok:
            return

        setup = retry_setup_with_linux_privsep(admin('setup'))
        setup_ok = setup.returncode == 0
        check('isolated production config generated', setup_ok)
        if not setup_ok:
            print(setup.stderr.strip())
            return

        authorized = admin('authorize', USER, CLIENT_KEY + '.pub')
        auth_ok = authorized.returncode == 0
        check('transport key centrally authorized', auth_ok)
        if not auth_ok:
            print(authorized.stderr.strip())
            return

        generated_config = os.path.join(SSHD_ROOT,
                                        'sshd_config.generated')
        runtime_config = os.path.join(SSHD_ROOT,
                                      'sshd_config.transport-test')
        with open(generated_config, encoding='utf-8') as source:
            policy = source.read()
        check('production transport keeps StrictModes',
              'StrictModes yes' in policy and 'StrictModes no' not in policy)

        # OpenSSH session.c applies administrator SetEnv after HOME/PAM setup.
        # Every generated security directive stays byte-for-byte unchanged.
        test_env = (
            'SetEnv HOME=' + HOME +
            ' SUPERTERM_INI=' + os.path.join(HOME, 'no-system.ini') +
            ' LANG=C.UTF-8 SUPERTERM_REAP_MS=300000' +
            ' SUPERTERM_DEBUG=' + DEBUG_LOG +
            ' SUPERTERM_DEBUG_FULL=1\n')
        with open(runtime_config, 'w', encoding='utf-8') as stream:
            stream.write(policy)
            stream.write(test_env)
        os.chmod(runtime_config, 0o600)

        with open(os.path.join(HOME, '.superterm', 'superterm.ini'), 'w',
                  encoding='utf-8') as stream:
            stream.write('''[ui]
language=en
background=none
[session]
server=detach
default_session=ssh-e2e
default_profile=e2e
autosave=0
autorestore=0
[profile.e2e]
name=e2e
enabled=1
focused_window=0
windows=main
[profile.e2e.window.main]
enabled=1
layout=L
focused_pane=0
panes=p
[profile.e2e.window.main.pane.p]
enabled=1
title=SSHE2E
cmd=echo SSH_TRANSPORT_READY; exec /bin/bash -i
''')

        try:
            home_owned = prepare_application_home()
        except (OSError, RuntimeError) as exc:
            home_owned = False
            print('cannot prepare isolated application HOME: ' + str(exc))
        check('isolated HOME belongs to SSH user', home_owned)
        if not home_owned:
            return

        syntax = subprocess.run([SSHD, '-t', '-f', runtime_config],
                                text=True, capture_output=True, timeout=30)
        syntax_ok = syntax.returncode == 0
        check('transport harness config accepted', syntax_ok)
        if not syntax_ok:
            print(syntax.stderr.strip())
            return

        if os.geteuid() != 0:
            if REQUESTED_USER:
                check('mandatory privileged SSH listener', False)
                print('real OpenSSH integration requires euid 0')
            else:
                skip('real OpenSSH listener integration', 'requires euid 0')
            return
        if not REQUESTED_USER:
            skip('non-root SSH privilege descent',
                 'SUPERTERM_TEST_SSH_USER not set; root compatibility run')
        if not (SSH and SFTP):
            missing = ', '.join(name for name, path in
                                (('ssh', SSH), ('sftp', SFTP)) if not path)
            if REQUESTED_USER:
                check('mandatory OpenSSH client tools', False)
                print('missing ' + missing)
            else:
                skip('real OpenSSH listener integration',
                     'missing ' + missing)
            return

        log_stream = open(SSHD_LOG, 'wb')
        try:
            # Keep sshd in the suite group. Normal cleanup targets only the
            # exact registered foreground listener PID.
            sshd_proc = subprocess.Popen(
                [SSHD, '-D', '-e', '-f', runtime_config],
                stdin=subprocess.DEVNULL, stdout=log_stream,
                stderr=log_stream)
            listener_identity = stlib.register_process(
                sshd_proc.pid, 'ssh-transport-sshd')
        except OSError as exc:
            check('isolated sshd starts', False)
            print(str(exc))
            return
        listening = wait_listener(sshd_proc)
        check('isolated sshd listens on TCP', listening)
        if not listening:
            return

        first = SshPty(100, 31)
        first.drain(4.0)
        first_visible = 'SSH_TRANSPORT_READY' in first.text()
        check('first standard ssh opens SuperTerm', first_visible)
        first_attached = wait_for(
            lambda: session_meta() == {'panes': 1, 'attached': 1},
            (first,))
        check('forced command creates one session', first_attached)
        if not (first_visible and first_attached):
            return

        observed_identity = {}

        def identities_visible():
            daemon_pid, daemon, forced = transport_identities(sshd_proc.pid)
            observed_identity['daemon_pid'] = daemon_pid
            observed_identity['daemon'] = daemon
            observed_identity['forced'] = forced
            return daemon is not None and bool(forced)

        identity_visible = wait_for(identities_visible, (first,), timeout=8.0)
        remember_listener_descendants(
            sshd_proc.pid, listener_identity, descendant_claims)
        expected_ids = (ACCOUNT.pw_uid, ACCOUNT.pw_uid)
        daemon_info = observed_identity.get('daemon')
        forced_info = observed_identity.get('forced', [])
        daemon_identity_ok = (
            identity_visible and daemon_info is not None and
            daemon_info[1:3] == expected_ids)
        forced_identity_ok = (
            identity_visible and bool(forced_info) and
            all(info[1:3] == expected_ids for info in forced_info))
        check('session daemon uses selected real UID', daemon_identity_ok)
        check('forced command uses selected real UID', forced_identity_ok)
        if REQUESTED_USER:
            check('mandatory non-root privilege descent',
                  ACCOUNT.pw_uid != 0 and daemon_identity_ok and
                  forced_identity_ok)
        if not (daemon_identity_ok and forced_identity_ok):
            daemon_pid = observed_identity.get('daemon_pid', 0)
            print('observed daemon identity: '
                  f'pid={daemon_pid} row={daemon_info!r}')
            print('observed forced-command identities: '
                  f'{forced_info!r}')
            return

        initial_size = pane_size()
        check('creator geometry is explicit', initial_size is not None)

        second = SshPty(145, 44)
        second.drain(4.0)
        second_attached = wait_for(
            lambda: session_meta() == {'panes': 1, 'attached': 2},
            (first, second))
        check('second standard ssh attaches same session', second_attached)
        if not second_attached:
            return
        remember_listener_descendants(
            sshd_proc.pid, listener_identity, descendant_claims)
        connection_tree_claimed = wait_for(
            lambda: live_listener_tree_is_claimed(
                sshd_proc.pid, listener_identity, descendant_claims),
            (first, second), timeout=3.0)
        check('live SSH descendants strongly claimed',
              connection_tree_claimed)
        if not connection_tree_claimed:
            return
        attached_size = pane_size()
        check('attach preserves canonical geometry',
              initial_size is not None and attached_size is not None and
              attached_size == initial_size)

        first.send(b'echo SSH_SHARED_OUTPUT\r', 0.4)
        check('pane output reaches both SSH clients', wait_for(
            lambda: ('SSH_SHARED_OUTPUT' in first.text() and
                     'SSH_SHARED_OUTPUT' in second.text()),
            (first, second)))

        # Kill exactly the local ssh client. TCP loss must close only its
        # viewer while the daemon and other viewer remain usable.
        remember_listener_descendants(
            sshd_proc.pid, listener_identity, descendant_claims)
        os.kill(first.pid, signal.SIGKILL)
        check('abrupt SSH client is reaped', first.wait_exit(4.0) is not None)
        check('network loss only detaches first viewer', wait_for(
            lambda: (session_meta()['attached'] == 1 and
                     os.path.exists(session_path('.sock'))),
            (second,)))
        first.close()
        first = None

        second.send(b'echo AFTER_FIRST_NETWORK_LOSS\r', 0.6)
        check('remaining SSH viewer stays writable',
              'AFTER_FIRST_NETWORK_LOSS' in second.text())

        before_resize = pane_size()
        second.resize(124, 37, 0.4)
        resize_applied = wait_for(
            lambda: (pane_size() is not None and
                     pane_size() != before_resize),
            (second,), timeout=12.0)
        resized_size = pane_size()
        check('SIGWINCH updates canonical geometry',
              before_resize is not None and resize_applied and
              resized_size is not None and resized_size != before_resize)

        # No PTY means no SSH_TTY, independently of the original-command
        # guard used by the next request.
        denied_shell, shell_unchanged, shell_timeout = run_rejected(
            base_ssh_args() + ['-T', '127.0.0.1'], sshd_proc.pid,
            listener_identity, descendant_claims)
        check('non-PTY remote shell rejected',
              not shell_timeout and denied_shell.returncode != 0 and
              shell_unchanged)

        denied_exec, exec_unchanged, exec_timeout = run_rejected(
            base_ssh_args() + ['-tt', '127.0.0.1', 'uname'], sshd_proc.pid,
            listener_identity, descendant_claims)
        check('PTY remote exec rejected without attach',
              not exec_timeout and denied_exec.returncode != 0 and
              exec_unchanged)

        denied_key, key_unchanged, key_timeout = run_rejected(
            base_ssh_args(OTHER_KEY) + ['-T', '127.0.0.1'], sshd_proc.pid,
            listener_identity, descendant_claims)
        check('unauthorized key rejected without attach',
              not key_timeout and denied_key.returncode != 0 and
              key_unchanged and
              'permission denied' in denied_key.stderr.lower())

        sftp_cmd = [
            SFTP, '-F', '/dev/null', '-P', str(PORT), '-b', '/dev/null',
            '-i', CLIENT_KEY,
            '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes',
            '-o', 'StrictHostKeyChecking=yes',
            '-o', 'UserKnownHostsFile=' + KNOWN_HOSTS,
            '-o', 'GlobalKnownHostsFile=/dev/null',
            USER + '@127.0.0.1',
        ]
        denied_sftp, sftp_unchanged, sftp_timeout = run_rejected(
            sftp_cmd, sshd_proc.pid, listener_identity, descendant_claims)
        check('SFTP subsystem rejected without attach',
              not sftp_timeout and denied_sftp.returncode != 0 and
              sftp_unchanged)

        forward_started = time.monotonic()
        denied_forward, forward_unchanged, forward_timeout = run_rejected(
            base_ssh_args() + [
                '-N', '-o', 'ExitOnForwardFailure=yes',
                '-R', '0:127.0.0.1:1', '127.0.0.1'], sshd_proc.pid,
            listener_identity, descendant_claims, timeout=10)
        forward_elapsed = time.monotonic() - forward_started
        check('remote TCP forwarding rejected immediately',
              not forward_timeout and denied_forward.returncode != 0 and
              forward_unchanged and
              forward_elapsed < 8.0)

        remember_listener_descendants(
            sshd_proc.pid, listener_identity, descendant_claims)
        second.send(b'\x11', 0.2)
        second.send(b'd', 0.8)
        check('clean SSH detach exits second client',
              second.wait_exit(8.0) is not None)
        check('clean detach leaves zero viewers and live socket', wait_for(
            lambda: (session_meta()['attached'] == 0 and
                     os.path.exists(session_path('.sock')))))
        second.close()
        second = None

        third = SshPty(82, 26)
        third.drain(4.0)
        check('third standard ssh reattaches live daemon', wait_for(
            lambda: session_meta()['attached'] == 1, (third,)))
        remember_listener_descendants(
            sshd_proc.pid, listener_identity, descendant_claims)
        check('third viewer restores shared output',
              'AFTER_FIRST_NETWORK_LOSS' in third.text())
        third_size = pane_size()
        check('reattach preserves resized canonical geometry',
              resized_size is not None and third_size is not None and
              third_size == resized_size)
        remember_listener_descendants(
            sshd_proc.pid, listener_identity, descendant_claims)
        third.send(b'\x11', 0.2)
        third.send(b'd', 0.8)
        check('third viewer detaches cleanly',
              third.wait_exit(8.0) is not None and wait_for(
                  lambda: session_meta()['attached'] == 0))
    finally:
        for client in (first, second, third):
            if client is not None:
                client.close()
        if sshd_proc is not None and listener_identity:
            remember_listener_descendants(
                sshd_proc.pid, listener_identity, descendant_claims)
            release_managed_daemon_claims(descendant_claims)
            close_listener_descendants(
                sshd_proc.pid, listener_identity, descendant_claims)
        stlib.close_all_daemons(HOME)
        stop_exact(sshd_proc)
        if log_stream is not None:
            log_stream.close()
        if stlib.fails():
            show_sshd_tail()
        shutil.rmtree(SSHD_ROOT, ignore_errors=True)


main()
stlib.report()
