#!/usr/bin/env python3
"""superterm test: renaming a session, from the CLI and from the UI.

A session's name is not just a label: it is the name of the socket clients
connect through, of the sidecar that describes it, and of the lock that stops
two sessions sharing it. Renaming has to move all three together and leave an
attached client working, so that is what is asserted here rather than the
string in a listing.

Also pins the refusals -- an empty name, and a name another session already
holds -- and the fact that `rename` on a bare session no longer renames the
focused pane while reporting that it did.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, run_cli

HOME = stlib.fresh_home('rename-session')
with open(HOME + '/.superterm/superterm.ini', 'w') as config:
    config.write('[ui]\n'
                 'language=en\n'
                 'background=none\n'
                 '[session]\n'
                 'server=always\n'
                 'autosave=0\n'
                 'autorestore=0\n')

SESSDIR = HOME + '/.superterm/sessions'
EN = {'LANG': 'C'}


def files():
    return sorted(os.listdir(SESSDIR))


def names():
    return sorted(p.rsplit('/', 1)[-1][:-5] for p in stlib.session_sockets(HOME))


c = stlib.Client(HOME, w=100, h=30)
c.drain(2.5)
start = names()
check('one session to start with', len(start) == 1)
original = start[0]

# ---- rename on a bare session is a pane rename, and says so ---------------
# Omitting :PANE selects the focused pane; that is the documented rule for
# every pane command and rename is not an exception to it. What was wrong was
# the report: "pane 1 renamed" read as confirmation to anyone who believed
# they had renamed the session. It now names the session too.
r = run_cli(['rename', original, 'Something'], HOME, env=EN)
check('rename on a bare session still renames the pane', r.returncode == 0)
check('and the report names the session it belongs to',
      'pane 1 of session' in r.stdout and original in r.stdout)
check('the session itself was not renamed', original + '.sock' in files())

# ---- the rename itself -----------------------------------------------------
r = run_cli(['rename-session', original, 'production'], HOME, env=EN)
check('rename-session succeeds', r.returncode == 0)
check('it reports the settled name', 'production' in r.stdout)
c.drain(1.5)

check('the socket moved', 'production.sock' in files())
check('the sidecar moved', 'production.ini' in files())
check('the old socket is gone', original + '.sock' not in files())
check('the old sidecar is gone', original + '.ini' not in files())
check('the new name holds its creation lock',
      '.create-production.lock' in files())

# ---- the session is fully usable under the new name ------------------------
r = run_cli(['list'], HOME, env=EN)
check('list shows the new name', 'production' in r.stdout)
check('list does not show the old one', original not in r.stdout)
r = run_cli(['send', 'production:1', 'echo RENAMED_OK'], HOME, env=EN)
check('the session accepts commands by its new name', r.returncode == 0)
c.drain(1.5)
check('and the pane really ran it', 'RENAMED_OK' in c.text())

# ---- the attached client was not disturbed ---------------------------------
check('the attached client is still alive', not c.wait_exit(0.3) == 0)
check('its desktop is intact', 'Panes' in c.text() and 'Windows' in c.text())
c.send(b'\x11m', 0.8)
c.send(b's', 1.0)
check('its Sessions menu shows the new name', 'production' in c.text())
c.send(b'\x1b', 0.4)
c.send(b'\x1b', 0.4)

# ---- refusals --------------------------------------------------------------
r = run_cli(['rename-session', 'production', '   '], HOME, env=EN)
check('an empty name is refused', r.returncode != 0)
check('the session kept its name', 'production.sock' in files())

# A name already on disk is refused. Seeding the files is the deterministic
# way to assert it: what the daemon actually checks is whether the socket or
# the sidecar of the wanted name exists, whoever put them there.
with open(SESSDIR + '/taken.sock', 'w') as decoy:
    decoy.write('')
r = run_cli(['rename-session', 'production', 'taken'], HOME, env=EN)
check('a name already on disk is refused', r.returncode != 0)
check('it says why', 'in use' in (r.stderr + r.stdout))
check('the session kept its own name after the refusal',
      'production.sock' in files())
check('and the refusal left the other name untouched',
      'taken.sock' in files() and 'taken.ini' not in files())
os.remove(SESSDIR + '/taken.sock')

c.send(b'\x11x', 1.5)
check('the renamed session exits cleanly', c.wait_exit(8.0) == 0)

stlib.report()
