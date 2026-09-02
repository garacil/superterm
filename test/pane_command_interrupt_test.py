#!/usr/bin/env python3
"""superterm test: interrupting a pane's configured command leaves a shell.

A pane configured with `cmd=` used to BE that command: superterm exec'd it as
the pane's own process. Ctrl-C reaches the whole foreground process group, so
interrupting the command killed the pane outright and the user was left with
nothing -- the reported symptom was "it stops, it does not go back to bash".

This is easy to get wrong in a way that looks fixed. Appending `exec $SHELL`
to the command is the obvious repair and it does NOT work: the wrapping shell
receives the same SIGINT and dies before reaching the exec. What works is
installing a handler first, and it must be a handler running a command rather
than an ignored disposition -- ignoring IS inherited across exec and would
make the pane's command itself immune to Ctrl-C, which is not what anyone
wants. Both halves are asserted here, because losing either one restores a
broken behaviour that still looks plausible in the source.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import stlib  # noqa: E402
from stlib import check, report  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PTY_UNIT = os.path.join(ROOT, 'src', 'st_pty.pas')

# A command that never ends on its own, so anything that returns a prompt can
# only have come from surviving the interrupt.
PANE_CMD = 'cat /dev/random'
MARKER_TYPED = "echo MAR''CADOR"      # the pty echoes this verbatim
MARKER_OUTPUT = 'MARCADOR'            # only a shell that RUNS it prints this


def test_wrapper_shape():
    """The mechanism, pinned in the source: both halves or neither."""
    with open(PTY_UNIT, 'r', encoding='utf-8', errors='replace') as f:
        src = f.read()
    check('a configured command is followed by exec of the shell',
          "'; exec ' + QuoteForShell(AShell)" in src)
    check('a SIGINT handler is installed before the command',
          "'trap : INT; '" in src)
    # `trap '' INT` would be inherited as "ignore" across exec and would make
    # the pane's own command unkillable by Ctrl-C.
    check('the trap is a handler, never an ignored disposition',
          "trap '' INT" not in src and 'trap "" INT' not in src)


def test_interrupt_returns_to_a_shell():
    """Run the product: interrupt the pane command and demand a live shell."""
    home = stlib.fresh_home('pane-interrupt')
    ini = os.path.join(home, '.superterm', 'superterm.ini')
    with open(ini, 'w') as f:
        f.write(
            '[autologin]\nshell=/usr/bin/bash\nlogin=1\n'
            '[ui]\nlanguage=en\nbackground=none\n'
            '[session]\nautosave=0\nautorestore=0\ndefault_profile=irq\n'
            '[profile.irq]\nname=irq\nenabled=1\nwindows=main\n'
            '[profile.irq.window.main]\nenabled=1\nlayout=L\n'
            'focused_pane=0\npanes=pane1\n'
            '[profile.irq.window.main.pane.pane1]\n'
            'enabled=1\ntitle=irq\ncmd=%s\ncwd=%s\n' % (PANE_CMD, home))
    client = None
    try:
        client = stlib.Client(home, w=100, h=30, lang='en')
        client.drain(3.0)
        check('the client is up with its pane', client.alive())
        client.send(b'\x03', 1.5)            # Ctrl-C into the pane
        check('the client survives interrupting the pane command',
              client.alive())
        client.send(MARKER_TYPED.encode() + b'\r', 2.0)
        text = client.text()
        typed_removed = text.replace(MARKER_TYPED, '')
        check('the pane returns to a shell that executes',
              MARKER_OUTPUT in typed_removed)
    finally:
        if client is not None:
            try:
                client.send(b'\x1bx', 1.0)
                client.close()
            except Exception:                            # noqa: BLE001
                pass
        stlib.close_all_daemons(home)


test_wrapper_shape()
test_interrupt_returns_to_a_shell()
report()
