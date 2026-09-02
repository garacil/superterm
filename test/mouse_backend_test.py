#!/usr/bin/env python3
"""Mouse backend initialization and descriptor-wake contract.

The FPC GNU/Linux mouse backend attempts a blocking GPM connection for an
unrecognised TERM.  SuperTerm must install its own driver before FreeVision's
Drivers unit probes it, use the kernel console identity rather than TERM, and
wake the UI from the real GPM descriptor on a virtual console.
"""
import os
import pty
import subprocess
import sys

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
BIN = os.environ.get('SUPERTERM_TEST_BIN',
                     os.path.join(ROOT, 'bin', 'superterm'))


def source(name):
    with open(os.path.join(ROOT, 'src', name), encoding='utf-8') as stream:
        return stream.read()


mouse = source('st_mouse.pas')
ui = source('st_fvui.pas')
program = source('superterm.lpr')
implementation = mouse.split('implementation', 1)[1].split(
    'initialization', 1)[0]

uses_line = program.split('uses', 1)[1].split(';', 1)[0]
check('mouse unit precedes FreeVision Drivers',
      uses_line.find('st_mouse') < uses_line.find('Drivers'))
check('mouse unit has no video/Drivers dependency cycle',
      'st_video' not in implementation and 'Drivers' not in implementation)
check('nonblocking output writer installed before application',
      program.find('InstallMouseOutputWriter(@st_video.WriteRaw)') <
      program.find('STApp := New(PSuperApp, Init)'))
check('real console is identified by kernel ioctl',
      'FpIOCtl(StdInputHandle, KDGETMODE' in mouse and
      "GetEnvironmentVariable('TERM')" not in
      mouse[mouse.find('function OnLinuxConsole: boolean;\n{$IFDEF LINUX}'):
            mouse.find('function FindGpmWaitHandle')])
check('GPM probe is nonblocking before connect',
      mouse.find('F_SETFL') < mouse.find("fpconnect(Fd"))
check('RTL GPM driver runs only after accepted probe',
      'if GpmAccepting and Assigned(SysDriver.DetectMouse)' in mouse)
check('GPM descriptor is discovered after initialization',
      'GpmWaitFd := FindGpmWaitHandle' in mouse)
check('event loop watches GPM descriptor',
      'AddFd(MouseInputWaitHandle, POLLIN)' in ui)


def command_help(term):
    master, slave = pty.openpty()
    env = dict(os.environ, TERM=term, LANG='C.UTF-8')
    try:
        return subprocess.run(
            [BIN, '--help'], stdin=slave,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env,
            text=True, timeout=3.0)
    finally:
        os.close(slave)
        os.close(master)


for terminal in ('tmux-256color', 'linux'):
    try:
        probe = command_help(terminal)
    except subprocess.TimeoutExpired:
        check(terminal + ' PTY startup never waits for GPM', False)
        continue
    check(terminal + ' PTY startup never waits for GPM',
          probe.returncode == 0 and 'superterm' in probe.stdout.lower())

stlib.report()
