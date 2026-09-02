#!/usr/bin/env python3
"""New sessions share one profile/empty picker and preserve the old daemon.

The test deliberately drives the real FreeVision menus.  It creates an empty
profile without changing the live workspace, creates an empty no-profile
session, gives it its first pane, then creates a second session from the
persisted empty profile.  Every previous daemon must remain attachable.
"""
import configparser
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, run_cli


HOME = stlib.fresh_home('new-session-profile')
INI = HOME + '/.superterm/superterm.ini'
with open(INI, 'w', encoding='utf-8') as stream:
    stream.write('''[ui]
language=en
background=none
desktop_notifications=0
[session]
server=always
default_profile=alpha
default_window=main
autosave=0
autorestore=0

[profile.alpha]
name=alpha
enabled=1
focused_window=0
windows=main
[profile.alpha.window.main]
enabled=1
layout=L
focused_pane=0
panes=p
[profile.alpha.window.main.pane.p]
enabled=1
title=ALPHA
cmd=printf ALPHA_SESSION_READY\\n; exec /bin/bash -i
''')


def sidecar(name):
    parser = configparser.ConfigParser(strict=True)
    try:
        with open(HOME + '/.superterm/sessions/' + name + '.ini',
                  encoding='utf-8') as stream:
            parser.read_file(stream)
    except (OSError, configparser.Error):
        return {'panes': -1, 'profile': '!unreadable!'}
    return {
        'panes': parser.getint('session', 'panes', fallback=-1),
        'profile': parser.get('session', 'profile', fallback=''),
    }


def session_names():
    return sorted(os.path.basename(path)[:-5]
                  for path in stlib.session_sockets(HOME))


def frame_count(client):
    return sum(row.count('╔') + row.count('┌')
               for row in client.screen.display)


def wait_for(predicate, client, timeout=12.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        client.drain(0.15)
        if predicate():
            return True
    return predicate()


def poll_until(predicate, timeout=12.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if predicate():
            return True
        time.sleep(0.02)
    return predicate()


def read_ini(path=INI):
    parser = configparser.ConfigParser(interpolation=None, strict=True)
    try:
        with open(path, encoding='utf-8') as stream:
            parser.read_file(stream)
    except (OSError, configparser.Error):
        return None
    return parser


def complete_empty_profile(name, path=INI):
    parser = read_ini(path)
    section = 'profile.' + name
    return (parser is not None and parser.has_section(section) and
            parser.get(section, 'name', fallback='') == name and
            parser.getboolean(section, 'enabled', fallback=False) and
            parser.has_option(section, 'focused_window') and
            parser.get(section, 'windows', fallback='!') == '')


def session_name_field(client):
    """Read the actual input value, not a matching profile/list label."""
    for row in client.screen.display:
        match = re.search(r'Session name:\s*([A-Za-z0-9_-]+)', row)
        if match:
            return match.group(1)
    return ''


c = stlib.Client(HOME, w=100, h=30, lang='en')
check('default alpha starts',
      c.wait_until(lambda text: 'ALPHA_SESSION_READY' in text))
check('alpha daemon starts',
      poll_until(lambda: session_names() == ['alpha']))
peer = stlib.Client(HOME, args=['--attach', 'alpha'], w=92, h=27, lang='en')
check('second client starts with old profile snapshot',
      peer.wait_until(lambda text: 'ALPHA_SESSION_READY' in text))

# Profiles -> New empty profile. The command persists data but never activates
# it, so the alpha terminal and its daemon must remain untouched.
c.send(b'\x1br', 0.4)                 # Alt-R: Profiles
check('new-empty profile menu item',
      c.wait_until(lambda text: 'New empty profile' in text))
c.send(b'n', 0.4)
check('empty-profile name prompt',
      c.wait_until(lambda text: 'Profile name:' in text))
c.send(b'scratch\r', 0.0)
check('empty profile persisted as a complete section',
      wait_for(lambda: complete_empty_profile('scratch'), c))
check('profile creation keeps workspace', 'ALPHA_SESSION_READY' in c.text())
check('profile creation keeps daemon', session_names() == ['alpha'])

# The already-open peer loaded Profiles before scratch existed. Opening New
# session must refresh the shared catalogue rather than showing that snapshot.
peer.send(b'\x1bs', 0.3)
peer.send(b'n', 0.5)
check('other client sees newly created profile immediately',
      peer.wait_until(lambda text:
          'scratch' in text and 'Session name:' in text))
peer.send(b'\x1b', 0.4)
peer.send(b'\x11', 0.2)
peer.send(b'd', 0.8)
check('catalogue peer detaches without closing alpha',
      peer.wait_exit(5.0) is not None)
peer.close()

# Sessions -> New session. Default alpha is row 1; Up selects the explicit
# Empty/no-profile row and automatically changes the untouched name proposal
# from alpha-2 to session.
c.send(b'\x1bs', 0.4)                 # Alt-S: Sessions
check('new-session menu item',
      c.wait_until(lambda text: 'New session' in text))
c.send(b'n', 0.5)
check('single creation dialog',
      c.wait_until(lambda text:
          'Session name:' in text and '<Empty (no profile)>' in text))
c.send(b'\x1b[A', 0.25)
check('empty choice suggests session',
      c.wait_until(lambda _text: session_name_field(c) == 'session'))
c.send(b'\r', 0.0)
check('old alpha and new empty live',
      wait_for(lambda: session_names() == ['alpha', 'session'], c))
check('empty session has zero panes', sidecar('session')['panes'] == 0)
check('empty session has no profile', sidecar('session')['profile'] == '')
check('empty UI has no windows', frame_count(c) == 0)

old_capture = run_cli(['capture', 'alpha:1'], HOME)
check('old alpha remains exact', old_capture.returncode == 0 and
      'ALPHA_SESSION_READY' in old_capture.stdout)

# The first pane can be created normally in the zero-pane session.
c.send(b'\x1bc', 0.3)
c.send(b'1', 0.0)
check('first pane created from zero',
      wait_for(lambda: sidecar('session')['panes'] == 1, c))
c.send(b"printf 'EMPTY_%s_DONE\\n' 7391\r", 0.0)
check('first pane accepts and executes input',
      c.wait_until(lambda text: 'EMPTY_7391_DONE' in text))

# Create a genuinely populated session through the same dialog.  Alpha is the
# default selected profile and the live alpha daemon makes its deterministic
# suggestion alpha-2.  Metadata alone is not enough: capture the new pane to
# prove that the configured command was actually materialized there.
c.send(b'\x1bs', 0.4)
c.send(b'n', 0.5)
check('non-empty profile is selected by default',
      c.wait_until(lambda _text: session_name_field(c) == 'alpha-2'))
c.send(b'\r', 0.0)
check('profile-backed session joins previous live sessions', wait_for(
      lambda: session_names() == ['alpha', 'alpha-2', 'session'], c))
check('profile-backed sidecar records profile and pane', wait_for(
      lambda: sidecar('alpha-2') == {'panes': 1, 'profile': 'alpha'}, c))
check('profile-backed command reaches its pane',
      c.wait_until(lambda text: 'ALPHA_SESSION_READY' in text))
profile_capture = run_cli(['capture', 'alpha-2:1'], HOME)
check('profile-backed capture contains configured command output',
      profile_capture.returncode == 0 and
      'ALPHA_SESSION_READY' in profile_capture.stdout)
previous_capture = run_cli(['capture', 'session:1'], HOME)
check('previous populated session remains live after profile creation',
      previous_capture.returncode == 0 and
      'EMPTY_7391_DONE' in previous_capture.stdout)

# Create another session from the newly persisted empty profile. The dialog
# starts on alpha; Down selects scratch. The current session must only detach.
c.send(b'\x1bs', 0.4)
c.send(b'n', 0.5)
c.send(b'\x1b[B', 0.25)
check('profile choice suggests scratch',
      c.wait_until(lambda _text: session_name_field(c) == 'scratch'))
c.send(b'\r', 0.0)
check('all four sessions remain live', wait_for(
      lambda: session_names() == ['alpha', 'alpha-2', 'scratch', 'session'],
      c))
check('scratch profile recorded', sidecar('scratch')['profile'] == 'scratch')
check('scratch starts with zero panes', sidecar('scratch')['panes'] == 0)
check('previous session kept its pane', sidecar('session')['panes'] == 1)

# Detach the final empty session; unlike the dead-pane reap case it must remain
# indefinitely available.  Reattach both earlier sessions to prove rollback-
# style switching did not close either daemon.
c.send(b'\x11', 0.2)
c.send(b'd', 1.0)
check('empty client detaches cleanly', c.wait_exit(5.0) is not None)
c.close()
check('zero-pane session survives detach',
      poll_until(lambda: session_names() ==
                 ['alpha', 'alpha-2', 'scratch', 'session']))

a = stlib.Client(HOME, args=['--attach', 'alpha'], w=100, h=30, lang='en')
check('alpha reattaches',
      a.wait_until(lambda text: 'ALPHA_SESSION_READY' in text))
a.send(b'\x11', 0.2)
a.send(b'd', 0.8)
check('reattached alpha detaches cleanly', a.wait_exit(5.0) is not None)
a.close()

s = stlib.Client(HOME, args=['--attach', 'session'], w=100, h=30, lang='en')
check('previous session reattaches',
      s.wait_until(lambda text: 'EMPTY_7391_DONE' in text))
s.send(b'\x11', 0.2)
s.send(b'd', 0.8)
check('reattached previous session detaches cleanly',
      s.wait_exit(5.0) is not None)
s.close()

stlib.close_all_daemons(HOME)

# Dynamic menu commands used to overlap direct actions at profile slots
# 50..52 and class slots 20..21.  Load a real 53-object catalogue (including
# disabled entries), then drive those direct actions through FreeVision.  Each
# oracle checks the dialog or committed profile produced by that command, so
# a colliding activation/open action cannot pass on matching menu text alone.
CATALOG_HOME = stlib.fresh_home('catalog-command-ranges')
CATALOG_INI = CATALOG_HOME + '/.superterm/superterm.ini'
disabled_profiles = {3, 12, 21, 30, 41}
disabled_classes = {2, 11, 20, 31, 42}
catalog = [
    '[ui]', 'language=en', 'background=none',
    '[session]', 'server=always', 'default_profile=profile-00',
    'autosave=0', 'autorestore=0',
]
for index in range(53):
    name = f'profile-{index:02d}'
    catalog.extend([
        f'[profile.{name}]', f'name={name}',
        f'enabled={0 if index in disabled_profiles else 1}',
        'focused_window=-1', 'windows=',
    ])
for index in range(53):
    name = f'class-{index:02d}'
    catalog.extend([
        f'[class.{name}]', f'name={name}',
        f'enabled={0 if index in disabled_classes else 1}',
        f'cmd=printf CLASS_{index:02d}_READY\\n; exec /bin/bash -i',
    ])
with open(CATALOG_INI, 'w', encoding='utf-8') as stream:
    stream.write('\n'.join(catalog) + '\n')
catalog_parser = read_ini(CATALOG_INI)
check('fixture has 53 profiles and 53 classes',
      catalog_parser is not None and
      len([section for section in catalog_parser.sections()
           if section.startswith('profile.')]) == 53 and
      len([section for section in catalog_parser.sections()
           if section.startswith('class.')]) == 53)

catalog_client = stlib.Client(CATALOG_HOME, w=120, h=70, lang='en')
check('53-object catalogue session starts', poll_until(
      lambda: sorted(os.path.basename(path)[:-5]
                     for path in stlib.session_sockets(CATALOG_HOME)) ==
              ['profile-00']))

# cmProfileManage used to equal cmProfileBase+51.  End proves that the manager
# received all 53 rows, including disabled ones, rather than activating row 51.
catalog_client.send(b'\x1br', 0.0)
check('large profile menu advertises bounded direct list',
      catalog_client.wait_until(
          lambda text: '(more profiles in Manage...)' in text))
catalog_client.send(b'm', 0.0)
check('profile Manage command does not collide at slot 51',
      catalog_client.wait_until(lambda text: 'Profiles' in text and
                                'Save current' in text))
catalog_client.send(b'\x1b[6;5~', 0.0)  # Ctrl-PgDn: final list item
check('profile manager contains all 53 catalogue rows',
      catalog_client.wait_until(lambda text: 'profile-52' in text))
catalog_client.send(b'\x1b', 0.2)

# cmProfileNewEmpty used to equal cmProfileBase+52.  A complete persisted
# section proves the direct command ran instead of activating profile 52.
catalog_client.send(b'\x1br', 0.0)
check('large profile direct menu remains reachable',
      catalog_client.wait_until(lambda text: 'New empty profile' in text))
catalog_client.send(b'n', 0.0)
check('profile New empty command does not collide at slot 52',
      catalog_client.wait_until(lambda text: 'Profile name:' in text))
catalog_client.send(b'catalog-created\r', 0.0)
check('large-catalogue New empty commits complete profile',
      wait_for(lambda: complete_empty_profile(
          'catalog-created', CATALOG_INI), catalog_client))

# The class direct commands occupy the former dynamic slots 20 and 21.
# Manage must open the 53-row manager; Open must open the enabled-only picker.
catalog_client.send(b'\x1bc', 0.0)
check('large class direct menu remains reachable',
      catalog_client.wait_until(lambda text: 'Manage classes' in text and
                                'Open class in new pane' in text))
catalog_client.send(b'm', 0.0)
check('class Manage command does not collide at slot 21',
      catalog_client.wait_until(lambda text: 'Window classes' in text and
                                'Duplicate' in text))
catalog_client.send(b'\x1b[6;5~', 0.0)  # Ctrl-PgDn: final list item
check('class manager contains all 53 catalogue rows',
      catalog_client.wait_until(lambda text: 'class-52' in text))
catalog_client.send(b'\x1b', 0.2)

catalog_client.send(b'\x1bc', 0.0)
check('large class Open action remains reachable',
      catalog_client.wait_until(lambda text: 'Manage classes' in text and
                                'Open class in new pane' in text))
catalog_client.send(b'o', 0.0)
check('class Open picker does not collide at slot 20',
      catalog_client.wait_until(
          lambda text: 'Open class in new pane' in text and
                       'Local shell' in text))
catalog_client.send(b'\x1b[6;5~', 0.0)  # Ctrl-PgDn: final enabled item
check('class picker keeps disabled-row mapping through catalogue end',
      catalog_client.wait_until(lambda text: 'class-52' in text))
catalog_client.send(b'\x1b', 0.2)

catalog_client.send(b'\x11', 0.1)
catalog_client.send(b'd', 0.0)
check('large-catalogue client detaches cleanly',
      catalog_client.wait_exit(5.0) is not None)
catalog_client.close()
stlib.close_all_daemons(CATALOG_HOME)
stlib.report()
