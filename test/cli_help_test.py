#!/usr/bin/env python3
"""Contextual CLI help: complete, navigable, truthful and side-effect free."""
import os
import pwd
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, run_cli


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_TEST_BIN = os.path.join(ROOT, 'bin', 'superterm-test')
TEST_BIN = os.environ.get('SUPERTERM_TEST_BIN', DEFAULT_TEST_BIN)
if not os.path.exists(TEST_BIN):
    # Keep a missing test runtime reportable by the distinct-binary assertion
    # instead of crashing before stlib can print the complete test result.
    TEST_BIN = stlib.BIN
stlib.BIN = TEST_BIN
HOME = stlib.fresh_home('cli-help')
RELEASE_BIN = os.environ.get(
    'SUPERTERM_RELEASE_BIN', os.path.join(ROOT, 'bin', 'superterm'))
with open(os.path.join(ROOT, 'VERSION'), encoding='ascii') as version_file:
    EXPECTED_VERSION = version_file.read().strip()


def run_binary(binary, args, lang='C', extra_env=None, home=None,
               preexec_fn=None):
    if home is None:
        home = HOME
    env = dict(os.environ, HOME=home, TERM='xterm', LANG=lang,
               SUPERTERM_INI=os.path.join(home, 'no-sys.ini'))
    if extra_env:
        env.update(extra_env)
    return subprocess.run([binary, *args], text=True, capture_output=True,
                          env=env, timeout=30, preexec_fn=preexec_fn)


def clean_help(result, marker):
    return (result.returncode == 0 and result.stderr == '' and
            marker in result.stdout and result.stdout.endswith('\n'))


def tree_snapshot(root):
    """Content snapshot: help may read HOME, but it must never mutate it."""
    result = []
    for parent, dirs, files in os.walk(root):
        dirs.sort()
        files.sort()
        for name in dirs + files:
            path = os.path.join(parent, name)
            info = os.lstat(path)
            data = b''
            if stat.S_ISREG(info.st_mode):
                with open(path, 'rb') as stream:
                    data = stream.read()
            result.append((os.path.relpath(path, root),
                           stat.S_IFMT(info.st_mode),
                           stat.S_IMODE(info.st_mode), data))
    return result


# The top level is deliberately an index, not an unstructured wall of text.
index = run_cli(['--help'], HOME, env={'LANG': 'C'})
canonical_topics = [
    'startup', 'targets', 'sessions', 'panes', 'windows', 'ssh',
    'ssh-server', 'reference', 'all',
]
check('help index exits cleanly', clean_help(index, 'CONTEXTUAL HELP'))
check('help index preserves release header',
      index.stdout.splitlines()[0].startswith(
          'superterm ' + EXPECTED_VERSION + ' '))
check('help index gives a copyable link for every main topic',
      all(f'superterm --help {topic}' in index.stdout
          for topic in canonical_topics))
check('help index advertises both navigation forms',
      'superterm help TOPIC' in index.stdout and
      'superterm COMMAND --help' in index.stdout)

# Crawl every canonical link printed by the index. A linked topic which does
# not resolve is a real documentation defect, not merely a missing substring.
linked_topics = sorted(set(re.findall(
    r'superterm --help ([a-z][a-z-]*)', index.stdout)))
crawl_failures = []
for topic in linked_topics:
    result = run_cli(['--help', topic], HOME, env={'LANG': 'C'})
    if result.returncode != 0 or not result.stdout or result.stderr:
        crawl_failures.append((topic, result.returncode, result.stderr))
if crawl_failures:
    print('  help crawl failures:', crawl_failures)
check('every indexed contextual page resolves', not crawl_failures)

# The compact index has several equivalent entrances. Compare the complete
# bytes, not one marker which a truncated or unrelated page could also contain.
index_alias_failures = []
for request in (['help'], ['ayuda'], ['-h'], ['-?'], ['--HELP'], ['--AYUDA']):
    result = run_cli(request, HOME, env={'LANG': 'C'})
    if (result.returncode != 0 or result.stderr or
            result.stdout != index.stdout):
        index_alias_failures.append((request, result.returncode,
                                     result.stderr, result.stdout[:80]))
if index_alias_failures:
    print('  index alias failures:', index_alias_failures)
check('every top-level help alias is the exact same index',
      not index_alias_failures)

# Keep the exact canonical pages for alias and --help all composition checks.
# HelpAll deliberately consists of these pages in this documented order.
all_component_topics = [
    'startup', 'targets', 'sessions', 'panes', 'windows', 'ssh',
    'ssh-server', 'reference',
]
english_pages = {
    topic: run_cli(['--help', topic], HOME, env={'LANG': 'C'})
    for topic in all_component_topics
}
check('every English all-component page exits cleanly',
      all(result.returncode == 0 and result.stderr == '' and result.stdout
          for result in english_pages.values()))

# Topic aliases are parser contracts too. Compare every accepted spelling to
# its canonical page byte for byte so a generic index cannot satisfy the test.
topic_aliases = {
    'index': ['help', 'ayuda', 'indice', 'topics', 'temas'],
    'startup': ['start', 'run', 'inicio', 'arranque'],
    'targets': ['target', 'destinos', 'destino'],
    'sessions': ['session', 'sesiones', 'sesion'],
    'panes': ['pane', 'paneles', 'panel', 'io'],
    'windows': ['window', 'ventanas', 'ventana'],
    'ssh': ['ssh-client', 'cliente-ssh'],
    'ssh-server': ['server-ssh', 'servidor-ssh'],
    'reference': ['automation', 'referencia', 'automatizacion'],
    'all': ['complete', 'todo', 'completo'],
    'exit-codes': ['exitcodes', 'codes', 'status', 'codigos', 'salida'],
    'language': ['languages', 'idioma', 'idiomas', 'aliases', 'alias'],
    'internals': ['internal', 'internos', 'interno'],
}
topic_alias_failures = []
for canonical, aliases in topic_aliases.items():
    expected = run_cli(['--help', canonical], HOME, env={'LANG': 'C'})
    for alias in aliases:
        result = run_cli(['--help', alias], HOME, env={'LANG': 'C'})
        if (result.returncode != 0 or result.stderr or
                result.stdout != expected.stdout):
            topic_alias_failures.append((canonical, alias, result.returncode,
                                         result.stderr, result.stdout[:80]))
if topic_alias_failures:
    print('  topic alias failures:', topic_alias_failures[:8])
check('every topic alias is the exact canonical page',
      not topic_alias_failures)

# Required-token manifests make a page fail when an accepted option, limit or
# example disappears while the page still happens to contain its command name.
required_pages = {
    'startup': [
        'STARTUP', '--session NAME', '--attach [SESSION]',
        '--list-sessions', '--version', '-h, -?',
        'resulting name is "sesion"', 'superterm --session incident-42',
    ],
    'targets': [
        'TARGETS', 'SESSION:PANE', '.:PANE', 'unique case-insensitive prefix',
        '1-based index', 'superterm capture prod:Logs --history',
    ],
    'sessions': [
        'COMMAND: list', 'COMMAND: attach', 'COMMAND: kill',
        'superterm list prod', 'superterm attach prod',
        'superterm kill incident-42',
    ],
    'panes': [
        'COMMAND: send', '--no-enter', '--sin-intro', '--noenter', '--sinintro',
        '--key NAME',
        'BackTab/TabAtras', 'Ins Del/Supr F1..F12',
        'COMMAND: capture', '--history', '--lines N', '--output FILE',
        'cat script.sh | superterm send prod:1 -',
    ],
    'windows': [
        'COMMAND: new', '--class NAME', '--cmd COMMAND', '--dir DIR',
        '--directorio DIR', '--right', 'at most 16 panes',
        'COMMAND: close', 'COMMAND: focus', 'COMMAND: rename',
        'COMMAND: resize', '4..1000', '2..500', 'COMMAND: minimize',
        'COMMAND: restore', 'COMMAND: zoom',
        'prefix f (Ctrl-Q f by default)',
        'COMMAND: organize', 'grid/rejilla', 'tile/mosaico',
        'cascade/cascada', 'superterm organize . cascade',
    ],
    'ssh': [
        'STANDARD SSH CLIENT ENTRY', 'ssh -p PORT USER@HOST', '-tt',
        '-i PRIVATE_KEY', 'PAM', 'Private keys stay on the client',
        'SESSION ROUTING', 'ssh_session=last', 'default_session=daily-ssh',
        'default_profile supplies initial panes', 'per-user/name lock',
        'Remote exec', 'network', 'ssh -p 8022 user@server',
    ],
    'ssh-server': [
        'DEDICATED SSH/TCP SERVER', 'TCP only, never UDP',
        '/etc/superterm/sshd', 'never edits or restarts',
        'setup/init/configurar/preparar/inicializar',
        'existing server.ini or keys',
        'check/comprobar/verificar', 'enable/habilitar/activar',
        'disable/deshabilitar/desactivar', 'uninstall-service',
        'authorize USER KEY.pub', 'list-keys [USER]', 'revoke USER',
        'run/ejecutar', 'INTERNAL', 'config_version=1',
        'listen=127.0.0.1:8022,[::1]:8022', 'allow_root=0',
        'password_authentication=1', 'managed_authorized_keys=1',
        'user_authorized_keys=1', '1..32', '1..65535',
        '0.0.0.0:8022', '[::]:8022', 'AUTHENTICATION POLICY',
        'not two-factor authentication', 'MANAGED KEY RULES',
        '4096 keys or 1 MiB', '/var/run/superterm-sshd.pid',
        '/etc/ssh/sshrc', 'ADMIN EXIT CODES',
        'ROOT PUBLIC-KEY EXAMPLE', 'allow_root=1',
        'sudo superterm ssh-server setup',
        'sudo superterm ssh-server check',
        'sudo superterm ssh-server restart',
        'sudo superterm ssh-server status',
        'sudo superterm ssh-server enable',
        'sudo superterm ssh-server disable',
        'sudo superterm ssh-server uninstall-service',
        'sudo superterm ssh-server authorize user ~/.ssh/superterm_ed25519.pub',
        'sudo superterm ssh-server list-keys user',
        'sudo superterm ssh-server revoke user ~/.ssh/old_superterm_ed25519.pub',
    ],
    'reference': [
        'EXIT CODES', '  0  success', '  1  ', '  2  ', '  3  ',
        'LANGUAGE AND ALIASES', '[ui] language',
        'VERSION', 'superterm ' + EXPECTED_VERSION,
        'RESERVED INTERNAL ENTRY POINTS', '--ssh-entry',
        'ssh-server run', 'not user commands',
    ],
}
manifest_failures = []
for topic, tokens in required_pages.items():
    result = english_pages[topic]
    missing = [token for token in tokens if token not in result.stdout]
    if result.returncode != 0 or result.stderr or missing:
        manifest_failures.append((topic, result.returncode, missing,
                                  result.stderr))
if manifest_failures:
    print('  help manifest failures:', manifest_failures)
check('every main page contains its complete public contract',
      not manifest_failures)

# The short SSH guide is an executable handoff contract for human and AI
# operators. Keep it discoverable, keep every local reference resolvable, and
# reject examples which drift away from the real administrative command set.
quickstart_path = os.path.join(ROOT, 'docs', 'SSH_QUICKSTART.md')
readme_path = os.path.join(ROOT, 'README.md')
ssh_reference_path = os.path.join(ROOT, 'docs', 'SSH_SERVER.md')
try:
    with open(quickstart_path, encoding='utf-8') as stream:
        ssh_quickstart = stream.read()
    with open(readme_path, encoding='utf-8') as stream:
        project_readme = stream.read()
    with open(ssh_reference_path, encoding='utf-8') as stream:
        ssh_reference = stream.read()
except OSError as exc:
    print('  SSH quick-start read failure:', exc)
    ssh_quickstart = ''
    project_readme = ''
    ssh_reference = ''

quickstart_contract = (
    'Required inputs',
    'Safety contract for an AI or automated operator',
    'Read-only preflight',
    'sha256sum -c superterm_5.2.2_amd64.deb.sha256',
    'sudo apt-get install -y openssh-server',
    'sudo dnf install -y openssh-server',
    'sudo pacman -S --needed openssh',
    'superterm --version',
    'sudo superterm ssh-server setup',
    'sudoedit /etc/superterm/sshd/server.ini',
    'listen=192.168.0.214:8022',
    'password_authentication=0',
    'managed_authorized_keys=1',
    'user_authorized_keys=0',
    'sudo superterm ssh-server authorize german',
    'sudo superterm ssh-server check',
    'sudo superterm ssh-server restart',
    'sudo superterm ssh-server status',
    'ssh -p 8022 german@192.168.0.214',
    'Never copy, display, log, or upload a private key',
    'sudo test ! -e /etc/ssh/sshrc',
    "sudo ss -H -ltn 'sport = :8022'",
    'StrictHostKeyChecking=yes',
    'Never use `StrictHostKeyChecking=no`',
    'is **not** an allow-list',
    '/etc/systemd/system/superterm-sshd.service',
    'ssh-keygen -l -E sha256 -f',
    'Test from a different client machine',
    'Required completion report',
    'not modified',
)
missing_quickstart = [token for token in quickstart_contract
                      if token not in ssh_quickstart]
if missing_quickstart:
    print('  SSH quick-start missing contract:', missing_quickstart)
check('AI SSH quick-start preserves its complete safe workflow',
      not missing_quickstart)
check('AI SSH quick-start is linked from both documentation entrances',
      'docs/SSH_QUICKSTART.md' in project_readme and
      'SSH_QUICKSTART.md' in ssh_reference)

quickstart_links = re.findall(r'\]\(([^)]+\.md)(?:#[^)]+)?\)',
                              ssh_quickstart)
broken_quickstart_links = [
    target for target in quickstart_links
    if not os.path.isfile(os.path.normpath(os.path.join(
        os.path.dirname(quickstart_path), target)))
]
if broken_quickstart_links:
    print('  SSH quick-start broken links:', broken_quickstart_links)
check('every AI SSH quick-start Markdown reference resolves',
      bool(quickstart_links) and not broken_quickstart_links)

quickstart_admin_commands = set(re.findall(
    r'(?:sudo )?superterm ssh-server ([a-z][a-z-]*)', ssh_quickstart))
public_admin_commands = {
    'setup', 'check', 'restart', 'status', 'enable', 'disable',
    'uninstall-service', 'authorize', 'list-keys', 'revoke',
}
check('AI SSH quick-start uses only public SSH administration commands',
      quickstart_admin_commands and
      quickstart_admin_commands <= public_admin_commands and
      all(command in english_pages['ssh-server'].stdout
          for command in quickstart_admin_commands))

# Every executable command alias resolves through all three public help paths
# and publishes the exact canonical page, never a marker-only partial page.
command_aliases = {
    'list': ('COMMAND: list', ['list', 'listar', 'ls']),
    'attach': ('COMMAND: attach', ['attach', 'conectar']),
    'kill': ('COMMAND: kill', ['kill', 'matar']),
    'send': ('COMMAND: send', ['send', 'enviar']),
    'capture': ('COMMAND: capture', ['capture', 'capturar']),
    'new': ('COMMAND: new', ['new', 'nueva', 'nuevo']),
    'close': ('COMMAND: close', ['close', 'cerrar']),
    'focus': ('COMMAND: focus',
              ['focus', 'foco', 'select', 'seleccionar']),
    'minimize': ('COMMAND: minimize', ['minimize', 'minimizar']),
    'restore': ('COMMAND: restore', ['restore', 'restaurar']),
    'zoom': ('COMMAND: zoom', ['zoom', 'ampliar']),
    'organize': ('COMMAND: organize', ['organize', 'organizar']),
    'rename': ('COMMAND: rename', ['rename', 'renombrar']),
    'resize': ('COMMAND: resize', ['resize', 'tamano', 'redimensionar']),
    'version': ('VERSION', ['version']),
}
alias_failures = []
canonical_command_help = {}
for canonical, (marker, aliases) in command_aliases.items():
    expected = run_cli(['--help', canonical], HOME, env={'LANG': 'C'})
    canonical_command_help[canonical] = expected.stdout
    for alias in aliases:
        requests = (
            ['--help', alias],
            ['help', alias],
            ['ayuda', alias],
            [alias, '--help'],
        )
        for request in requests:
            result = run_cli(request, HOME, env={'LANG': 'C'})
            if (not clean_help(result, marker) or
                    result.stdout != expected.stdout):
                alias_failures.append((request, result.returncode,
                                       result.stderr, result.stdout[:80]))

# Accented and mixed-case operations/options exercise the exact UTF-8
# normalizer in top-level, topic and command-option positions.
casefold_requests = (
    (['--HELP', 'TAMAÑO'], 'resize'),
    (['HELP', 'TAMAÑO'], 'resize'),
    (['TAMAÑO', '--AYUDA'], 'resize'),
    (['SEND', '--HELP'], 'send'),
    (['enviar', '--AyÚdA'], 'send'),
)
for request, canonical in casefold_requests:
    result = run_cli(request, HOME, env={'LANG': 'C'})
    marker = command_aliases[canonical][0]
    if (not clean_help(result, marker) or
            result.stdout != canonical_command_help[canonical]):
        alias_failures.append((request, result.returncode,
                               result.stderr, result.stdout[:80]))
if alias_failures:
    print('  command-help alias failures:', alias_failures[:8])
check('all command aliases share exact contextual help pages',
      not alias_failures)

# Legacy startup spellings must also be help-safe and never enter the TUI.
legacy_help = {
    ('--attach', '--help'): ('COMMAND: attach',
                             canonical_command_help['attach']),
    ('--list-sessions', '--help'): ('COMMAND: list',
                                    canonical_command_help['list']),
    ('--session', '--help'): ('STARTUP', english_pages['startup'].stdout),
    ('--sesion', '--ayuda'): ('STARTUP', english_pages['startup'].stdout),
}
check('legacy startup options expose contextual help without opening the UI',
      all(clean_help(result := run_cli(list(args), HOME,
                                      env={'LANG': 'C'}), marker) and
          result.stdout == expected
          for args, (marker, expected) in legacy_help.items()))

# SSH help must return before root checks, configuration creation or external
# helpers. Point every test-only escape hatch at one loud marker executable and
# compare the whole private HOME before and after valid and invalid help forms.
SSH_HELP_HOME = stlib.fresh_home('cli-help-ssh')
ssh_config = os.path.join(SSH_HELP_HOME, '.superterm', 'superterm.ini')
with open(ssh_config, 'w', encoding='utf-8') as stream:
    stream.write('[ui]\nlanguage=en\n')
fake_root = os.path.join(SSH_HELP_HOME, 'must-not-create-ssh-root')
helper_marker = os.path.join(SSH_HELP_HOME, 'must-not-run-helper.marker')
fake_helper = os.path.join(SSH_HELP_HOME, 'must-not-run-helper')
with open(fake_helper, 'w', encoding='utf-8') as stream:
    stream.write('#!/bin/sh\n')
    stream.write('printf invoked >> "$SUPERTERM_HELP_SIDE_EFFECT_MARKER"\n')
    stream.write('exit 91\n')
os.chmod(fake_helper, 0o755)
help_env = {
    'LANG': 'C',
    'SUPERTERM_TESTING': '1',
    'SUPERTERM_SSHD_ROOT': fake_root,
    'SUPERTERM_TEST_SSHD': fake_helper,
    'SUPERTERM_TEST_EXPECT_SSHD': fake_helper,
    'SUPERTERM_TEST_SSH_KEYGEN': fake_helper,
    'SUPERTERM_TEST_SYSTEMCTL': fake_helper,
    'SUPERTERM_TEST_LAUNCHCTL': fake_helper,
    'SUPERTERM_TEST_SERVICE_MANAGER': '1',
    'SUPERTERM_HELP_SIDE_EFFECT_MARKER': helper_marker,
}
ssh_before = tree_snapshot(SSH_HELP_HOME)
ssh_help_requests = (
    ['--help', 'ssh-server'],
    ['ssh-server', 'help'],
    ['ssh-server', '--help'],
    ['ssh-server', '-h'],
    ['ssh-server', '-?'],
    ['ssh-server', 'setup', '--help'],
    ['ssh-server', 'setup', '-h'],
    ['ssh-server', 'authorize', '--help'],
    ['SSH-SERVER', 'SETUP', '--HELP'],
)
ssh_results = [
    run_binary(TEST_BIN, request, extra_env=help_env, home=SSH_HELP_HOME)
    for request in ssh_help_requests
]
expected_ssh_help = english_pages['ssh-server'].stdout
check('all SSH admin help paths are the exact detailed page',
      all(clean_help(result, 'DEDICATED SSH/TCP SERVER') and
          result.stdout == expected_ssh_help for result in ssh_results))

# Do not merely search the help page for aliases: route every documented
# administrative spelling through the real parser. Context help returns before
# root checks and therefore proves recognition without touching service state.
ssh_admin_aliases = (
    'setup', 'init', 'configurar', 'preparar', 'inicializar',
    'check', 'comprobar', 'verificar', 'restart', 'reiniciar',
    'status', 'estado', 'enable', 'habilitar', 'activar',
    'disable', 'deshabilitar', 'desactivar',
    'uninstall-service', 'desinstalar-servicio',
    'authorize', 'autorizar', 'revoke', 'revocar',
    'list-keys', 'listar-claves', 'run', 'ejecutar',
)
ssh_alias_results = [
    run_binary(TEST_BIN, ['ssh-server', alias, '--help'],
               extra_env=help_env, home=SSH_HELP_HOME)
    for alias in ssh_admin_aliases
]
check('every documented SSH admin alias reaches the real help parser',
      all(clean_help(result, 'DEDICATED SSH/TCP SERVER') and
          result.stdout == expected_ssh_help for result in ssh_alias_results))

# Running the suite as root must not make the no-root promise vacuous. Drop
# credentials in the child and prove contextual admin help still returns
# before RequireRoot. On an ordinary non-root run, that process already is the
# required witness.
unprivileged_preexec = None
unprivileged_identity = None
unprivileged_binary = TEST_BIN
unprivileged_copy_dir = ''
if os.geteuid() == 0:
    for account in ('nobody', '_nobody', 'daemon'):
        try:
            candidate = pwd.getpwnam(account)
        except KeyError:
            continue
        if candidate.pw_uid != 0:
            unprivileged_identity = candidate
            break
    if unprivileged_identity is not None:
        witness_uid = unprivileged_identity.pw_uid
        witness_gid = unprivileged_identity.pw_gid

        # A developer checkout may correctly live below a mode-0700 HOME.
        # Copy only the already-built test executable to an isolated,
        # world-traversable temporary directory so directory permissions do
        # not prevent the child from reaching the code under test.
        unprivileged_copy_dir = tempfile.mkdtemp(
            prefix='superterm-cli-help-unpriv-')
        os.chmod(unprivileged_copy_dir, 0o755)
        unprivileged_binary = os.path.join(
            unprivileged_copy_dir, 'superterm-test')
        shutil.copyfile(TEST_BIN, unprivileged_binary)
        os.chmod(unprivileged_binary, 0o755)

        def unprivileged_preexec():
            os.setgroups([])
            os.setgid(witness_gid)
            os.setuid(witness_uid)

try:
    unprivileged_help = (run_binary(
        unprivileged_binary, ['ssh-server', 'setup', '--help'],
        extra_env=help_env,
        home=SSH_HELP_HOME, preexec_fn=unprivileged_preexec)
        if os.geteuid() != 0 or unprivileged_preexec is not None else None)
except (OSError, subprocess.SubprocessError):
    unprivileged_help = None
finally:
    if unprivileged_copy_dir:
        shutil.rmtree(unprivileged_copy_dir)
check('SSH contextual help genuinely requires no root privilege',
      unprivileged_help is not None and
      clean_help(unprivileged_help, 'DEDICATED SSH/TCP SERVER') and
      unprivileged_help.stdout == expected_ssh_help)

invalid_ssh_help_requests = (
    ['ssh-server', 'help', 'extra'],
    ['ssh-server', '-h', 'extra'],
    ['ssh-server', 'setup', '--help', 'extra'],
    ['ssh-server', 'authorize', 'user'],
)
invalid_ssh_results = [
    run_binary(TEST_BIN, request, extra_env=help_env, home=SSH_HELP_HOME)
    for request in invalid_ssh_help_requests
]
check('SSH admin help enforces strict arity without doing work',
      all(result.returncode == 2 and result.stderr == '' and
          result.stdout == expected_ssh_help
          for result in invalid_ssh_results))
check('SSH help and help errors have no filesystem/helper side effects',
      tree_snapshot(SSH_HELP_HOME) == ssh_before and
      not os.path.lexists(fake_root) and
      not os.path.lexists(helper_marker))

# Release and test runtimes must publish byte-identical help. Test-only service
# hooks are a compile-time boundary, never a second user interface.
binary_pair_ready = (os.path.isfile(TEST_BIN) and
                     os.path.isfile(RELEASE_BIN))
try:
    binaries_distinct = (binary_pair_ready and
                         os.path.abspath(TEST_BIN) !=
                         os.path.abspath(RELEASE_BIN) and
                         not os.path.samefile(TEST_BIN, RELEASE_BIN))
except OSError:
    binaries_distinct = False
check('release and test help use distinct executables', binaries_distinct)
test_all = run_binary(TEST_BIN, ['--help', 'all'])
release_all = (run_binary(RELEASE_BIN, ['--help', 'all'])
               if binary_pair_ready else None)
check('release and test runtimes publish identical complete help',
      release_all is not None and
      test_all.returncode == release_all.returncode == 0 and
      test_all.stdout == release_all.stdout and
      test_all.stderr == release_all.stderr == '')

expected_english_all = index.stdout + '\n' + ''.join(
    english_pages[topic].stdout for topic in all_component_topics)
check('--help all is the exact ordered English page composition',
      test_all.returncode == 0 and test_all.stderr == '' and
      test_all.stdout == expected_english_all)

# Output is intentionally plain, bounded and deterministic for terminals,
# parsers and AI agents. No TTY width or live-session state may affect it.
all_again = run_binary(TEST_BIN, ['--help', 'all'])
narrow_all = run_binary(
    TEST_BIN, ['--help', 'all'],
    extra_env={'TERM': 'dumb', 'COLUMNS': '40', 'LINES': '10'})
wide_all = run_binary(
    TEST_BIN, ['--help', 'all'],
    extra_env={'TERM': 'xterm-256color', 'COLUMNS': '300', 'LINES': '100'})
all_lines = test_all.stdout.splitlines()
check('complete help output is deterministic', test_all.stdout == all_again.stdout)
check('complete help is independent of terminal geometry and TERM',
      narrow_all.returncode == wide_all.returncode == 0 and
      narrow_all.stderr == wide_all.stderr == '' and
      narrow_all.stdout == wide_all.stdout == test_all.stdout)
check('complete help is plain text without terminal control bytes',
      all(char == '\n' or
          (ord(char) >= 32 and ord(char) != 127)
          for char in test_all.stdout))
check('complete help has bounded clean lines and final newline',
      bool(all_lines) and max(map(len, all_lines)) <= 100 and
      all(line == line.rstrip() for line in all_lines) and
      test_all.stdout.endswith('\n') and '\n\n\n' not in test_all.stdout)

# Unknown or structurally ambiguous help is a usage error, never a successful
# unrelated page. The diagnostic follows the configured language.
unknown = run_cli(['--help', 'definitely-not-a-topic'], HOME,
                  env={'LANG': 'C'})
extra = run_cli(['--help', 'send', 'extra'], HOME, env={'LANG': 'C'})
command_extra = run_cli(['send', '--help', 'extra'], HOME, env={'LANG': 'C'})
unknown_option = run_cli(['--definitely-not-an-option'], HOME,
                         env={'LANG': 'C'})
unknown_command = run_cli(['definitely-not-a-command'], HOME,
                          env={'LANG': 'C'})
check('unknown help topic exits 2 with a useful diagnostic',
      unknown.returncode == 2 and unknown.stdout == '' and
      'unknown help topic' in unknown.stderr and
      'superterm --help' in unknown.stderr)
check('help rejects an extra topic instead of guessing',
      extra.returncode == 2 and 'at most one topic' in extra.stderr)
check('command help rejects extra arguments instead of hiding them',
      command_extra.returncode == 2 and
      'help accepts no additional arguments' in command_extra.stderr)
check('unknown top-level options and commands are usage errors',
      unknown_option.returncode == unknown_command.returncode == 2 and
      unknown_option.stdout == unknown_command.stdout == '' and
      'unknown option' in unknown_option.stderr and
      'unknown command' in unknown_command.stderr)

# Arity failures must be decided by the command grammar before any session is
# resolved or TUI is opened. A nonempty diagnostic which is not "no sessions"
# keeps this honest without coupling the test to cosmetic diagnostic wording.
strict_arity_requests = (
    ['version', 'extra'],
    ['--list-sessions', 'extra'],
    ['list', 'one', 'two'],
    ['capture', '.', 'extra'],
    ['kill', 'one', 'two'],
    ['new', '.', 'extra'],
    ['close', '.', 'extra'],
    ['focus', '.', 'extra'],
    ['minimize', '.', 'extra'],
    ['restore', '.', 'extra'],
    ['zoom', '.', 'extra'],
    ['resize', '.', '80x20', 'extra'],
    ['organize', '.', 'grid', 'extra'],
    ['organize', '.', 'bogus'],
    ['rename', '.'],
    ['attach', 'one', 'two'],
    ['--attach', 'one', 'two'],
    ['--session', 'one', 'two'],
)
arity_before = tree_snapshot(HOME)
strict_arity_failures = []
for request in strict_arity_requests:
    result = run_cli(request, HOME, env={'LANG': 'C'})
    if (result.returncode != 2 or result.stdout != '' or
            not result.stderr or 'no sessions are running' in result.stderr):
        strict_arity_failures.append((request, result.returncode,
                                      result.stdout[:80], result.stderr))
if strict_arity_failures:
    print('  strict arity failures:', strict_arity_failures[:8])
check('command grammars reject extra/missing operands with exit 2',
      not strict_arity_failures)
close_extra = run_cli(['close', '.', 'extra'], HOME, env={'LANG': 'C'})
check('extra simple-window operands report the exact arity error',
      close_extra.returncode == 2 and
      'accepts exactly one TARGET' in close_extra.stderr)
check('strict arity errors do not create a session or mutate HOME',
      not stlib.session_sockets(HOME) and
      tree_snapshot(HOME) == arity_before)

history_short = run_cli(['capture', '.', '-H'], HOME, env={'LANG': 'C'})
check('short -H remains capture history and never becomes help',
      history_short.returncode == 1 and history_short.stdout == '' and
      'no sessions are running' in history_short.stderr and
      'COMMAND: capture' not in history_short.stdout)

os.makedirs(os.path.join(HOME, '.superterm'), exist_ok=True)
with open(os.path.join(HOME, '.superterm', 'superterm.ini'), 'w',
          encoding='utf-8') as stream:
    stream.write('[ui]\nlanguage=es\n')
spanish = run_cli(['--ayuda'], HOME, env={'LANG': 'C'})
spanish_unknown = run_cli(['--ayuda', 'tema-inexistente'], HOME,
                          env={'LANG': 'C'})
spanish_component_topics = [
    'inicio', 'destinos', 'sesiones', 'paneles', 'ventanas', 'ssh',
    'servidor-ssh', 'referencia',
]
spanish_pages = {
    topic: run_cli(['--ayuda', topic], HOME, env={'LANG': 'C'})
    for topic in spanish_component_topics
}
spanish_all = run_cli(['--ayuda', 'todo'], HOME, env={'LANG': 'C'})
expected_spanish_all = spanish.stdout + '\n' + ''.join(
    spanish_pages[topic].stdout for topic in spanish_component_topics)
spanish_markers = (
    'INICIO', 'DESTINOS', 'SESIONES', 'E/S DE PANELES',
    'GESTION DE VENTANAS', 'ENTRADA CON CLIENTE SSH ESTANDAR',
    'SERVIDOR SSH/TCP DEDICADO', 'REFERENCIA DE AUTOMATIZACION',
)
accented_spanish_resize = run_cli(
    ['--AYÚDA', 'TAMAÑO'], HOME, env={'LANG': 'C'})
canonical_spanish_resize = run_cli(
    ['--ayuda', 'tamano'], HOME, env={'LANG': 'C'})
ssh_spanish_before = tree_snapshot(SSH_HELP_HOME)
direct_spanish_ssh_results = [
    run_binary(TEST_BIN, request, lang='C', extra_env=help_env,
               home=SSH_HELP_HOME)
    for request in (
        ['servidor-ssh', 'ayuda'],
        ['servidor-ssh', '--ayuda'],
    )
]
check('configured Spanish renders the index and contextual navigation',
      clean_help(spanish, 'AYUDA CONTEXTUAL') and
      'superterm --ayuda sesiones' in spanish.stdout)
check('--ayuda todo is the exact ordered Spanish page composition',
      spanish_all.returncode == 0 and spanish_all.stderr == '' and
      spanish_all.stdout == expected_spanish_all and
      all(marker in spanish_all.stdout for marker in spanish_markers))
check('Spanish complete help preserves translated operands and layout',
      '--salida FICHERO, --output FILE' in spanish_pages['paneles'].stdout and
      spanish_all.stdout.endswith('\n') and
      '\n\n\n' not in spanish_all.stdout and
      max(map(len, spanish_all.stdout.splitlines())) <= 100)
check('accented uppercase Spanish help selects the exact command page',
      accented_spanish_resize.returncode == 0 and
      accented_spanish_resize.stderr == '' and
      accented_spanish_resize.stdout == canonical_spanish_resize.stdout)
check('Spanish unknown-topic diagnostic is localized',
      spanish_unknown.returncode == 2 and
      'tema de ayuda desconocido' in spanish_unknown.stderr)
check('early servidor-ssh ayuda is Spanish without reading privileged HOME',
      all(clean_help(result, 'SERVIDOR SSH/TCP DEDICADO') and
          result.stdout == spanish_pages['servidor-ssh'].stdout
          for result in direct_spanish_ssh_results) and
      tree_snapshot(SSH_HELP_HOME) == ssh_spanish_before and
      not os.path.lexists(fake_root) and
      not os.path.lexists(helper_marker))

# Functional truth test for the spelling the old help advertised but the old
# parser rejected. No Enter means the shell must not create the marker until a
# separately named Enter key is sent. Exercise English and Spanish spellings.
SESSION_NAME = 'help.audit'
client = stlib.Client(HOME, args=['--session', SESSION_NAME], w=100, h=28)
client.drain(1.5)
client.send(b'\x11d', 0.8)
client.close()
sockets = stlib.session_sockets(HOME)
check('help truth fixture leaves one detached session',
      len(sockets) == 1 and
      os.path.basename(sockets[0]) == SESSION_NAME + '.sock')

# One dotted session exercises canonical colon targets, whole dotted session
# names and every documented legacy shorthand without depending on title
# matching. All operations address the same first pane.
target_requests = (
    ['focus', SESSION_NAME],
    ['focus', SESSION_NAME + ':1'],
    ['focus', '.:1'],
    ['focus', ':1'],
    ['focus', SESSION_NAME + '.1'],
    ['focus', '.1'],
)
target_results = [run_cli(request, HOME) for request in target_requests]
dotted_list = run_cli(['list', SESSION_NAME], HOME)
check('canonical and legacy targets preserve a dotted session name',
      all(result.returncode == 0 and result.stderr == ''
          for result in target_results) and
      dotted_list.returncode == 0 and dotted_list.stderr == '' and
      SESSION_NAME not in dotted_list.stderr)

# A new name beginning with '--' is literal rename data, not an option or a
# late help request. This catches command-wide scans for flags/help tokens.
paused_rename = run_cli(
    ['rename', SESSION_NAME + ':1', '--paused'], HOME)
paused_list = run_cli(['list', SESSION_NAME], HOME)
check('rename accepts the literal title --paused',
      paused_rename.returncode == 0 and paused_rename.stderr == '' and
      'COMMAND: rename' not in paused_rename.stdout and
      paused_list.returncode == 0 and '--paused' in paused_list.stdout)

english_marker = os.path.join(HOME, 'no-enter-english')
spanish_marker = os.path.join(HOME, 'no-enter-spanish')
english_compat_marker = os.path.join(HOME, 'noenter-compat')
spanish_compat_marker = os.path.join(HOME, 'sinintro-compat')
english_cmd = 'printf ENGLISH > ' + english_marker
spanish_cmd = 'printf SPANISH > ' + spanish_marker
english_compat_cmd = 'printf COMPAT > ' + english_compat_marker
spanish_compat_cmd = 'printf COMPAT > ' + spanish_compat_marker

no_enter = run_cli(['send', '--no-enter', '.', english_cmd], HOME)
time.sleep(0.3)
check('--no-enter is accepted and really withholds Enter',
      no_enter.returncode == 0 and not os.path.exists(english_marker))
enter = run_cli(['send', '.', '--key', 'Enter'], HOME)
deadline = time.monotonic() + 3.0
while not os.path.exists(english_marker) and time.monotonic() < deadline:
    time.sleep(0.05)
check('named Enter releases the English no-enter command',
      enter.returncode == 0 and os.path.exists(english_marker))

sin_intro = run_cli(['enviar', '--sin-intro', '.', spanish_cmd], HOME)
time.sleep(0.3)
check('--sin-intro is accepted and really withholds Intro',
      sin_intro.returncode == 0 and not os.path.exists(spanish_marker))
intro = run_cli(['enviar', '.', '--tecla', 'Intro'], HOME)
deadline = time.monotonic() + 3.0
while not os.path.exists(spanish_marker) and time.monotonic() < deadline:
    time.sleep(0.05)
check('named Intro releases the Spanish no-enter command',
      intro.returncode == 0 and os.path.exists(spanish_marker))

noenter_compat = run_cli(
    ['send', '--noenter', '.', english_compat_cmd], HOME)
time.sleep(0.3)
check('--noenter compatibility spelling really withholds Enter',
      noenter_compat.returncode == 0 and
      not os.path.exists(english_compat_marker))
compat_enter = run_cli(['send', '.', '--key', 'Enter'], HOME)
deadline = time.monotonic() + 3.0
while (not os.path.exists(english_compat_marker) and
       time.monotonic() < deadline):
    time.sleep(0.05)
check('named Enter releases the --noenter command',
      compat_enter.returncode == 0 and
      os.path.exists(english_compat_marker))

sinintro_compat = run_cli(
    ['enviar', '--sinintro', '.', spanish_compat_cmd], HOME)
time.sleep(0.3)
check('--sinintro compatibility spelling really withholds Intro',
      sinintro_compat.returncode == 0 and
      not os.path.exists(spanish_compat_marker))
compat_intro = run_cli(['enviar', '.', '--tecla', 'Intro'], HOME)
deadline = time.monotonic() + 3.0
while (not os.path.exists(spanish_compat_marker) and
       time.monotonic() < deadline):
    time.sleep(0.05)
check('named Intro releases the --sinintro command',
      compat_intro.returncode == 0 and
      os.path.exists(spanish_compat_marker))

# Literal payload containing help must stay payload. `--` is the explicit
# boundary; a title named "help" is likewise data, not a help request.
literal = run_cli(
    ['send', '.', '--', 'echo', 'LITERAL_HELP_PAYLOAD', '--help'], HOME)
time.sleep(0.5)
captured = run_cli(['capture', '.'], HOME)
renamed = run_cli(['rename', '.', 'help'], HOME)
listed = run_cli(['list', '.'], HOME)
check('help-looking text after -- is delivered literally',
      literal.returncode == 0 and captured.returncode == 0 and
      'LITERAL_HELP_PAYLOAD --help' in captured.stdout)
check('a literal help pane title executes rename instead of opening help',
      renamed.returncode == 0 and listed.returncode == 0 and
      'help' in listed.stdout and 'COMMAND: rename' not in renamed.stdout)

# Live daemon state, pane title, shell output and geometry must not leak into a
# contextual reference assembled after those mutations.
spanish_all_after_state = run_binary(
    TEST_BIN, ['--ayuda', 'todo'], home=HOME,
    extra_env={'TERM': 'dumb', 'COLUMNS': '47', 'LINES': '13'})
check('complete help is stable after live session and pane mutations',
      spanish_all_after_state.returncode == 0 and
      spanish_all_after_state.stderr == '' and
      spanish_all_after_state.stdout == spanish_all.stdout)

killed = run_cli(['kill', SESSION_NAME], HOME)
check('help truth fixture closes cleanly', killed.returncode == 0)

stlib.report()
