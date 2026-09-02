#!/usr/bin/env python3
"""superterm test: every supported build mode is compiler-diagnostic clean."""
import os
import re
import shutil
import subprocess
import sys
import tempfile


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
MAKEFILE = os.path.join(ROOT, 'Makefile.in')
failed = False


def check(label, condition):
    global failed
    print(f'{label:56s}: {"OK" if condition else "FAIL"}')
    if not condition:
        failed = True


def compile_mode(root, label, mode, extra=''):
    target = os.path.join(root, 'bin', 'superterm-' + label)
    units = os.path.join(root, 'units', label)
    command = [
        'make', '--no-print-directory', '-j2', 'all',
        f'MODE={mode}', f'TARGET={target}', f'UNITDIR={units}',
        f'FPCFLAGS_EXTRA={extra}',
    ]
    completed = subprocess.run(
        command, cwd=ROOT, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, timeout=240)
    diagnostics = re.findall(
        r'(?im)^.*\b(?:warning|note|hint):\s+.*$', completed.stdout)
    check(f'{label} strict build exits successfully',
          completed.returncode == 0)
    check(f'{label} strict build emits no diagnostics', not diagnostics)
    check(f'{label} strict binary exists',
          completed.returncode == 0 and os.path.isfile(target) and
          os.access(target, os.X_OK))
    if completed.returncode != 0 or diagnostics:
        print(completed.stdout[-12000:])


def main():
    with open(MAKEFILE, encoding='utf-8') as handle:
        makefile = handle.read()
    base = re.search(r'^BASE_FLAGS\s*:=\s*(.*(?:\\\n.*)*)',
                     makefile, re.MULTILINE)
    flags = base.group(0) if base else ''
    check('Makefile exposes warnings, notes, and hints', '-vewnh' in flags)
    check('Makefile makes warnings, notes, and hints fatal', '-Sewnh' in flags)
    check('only audited FPC configuration notices are suppressed',
          '-vm11030,11031' in flags and flags.count('-vm') == 1)

    root = tempfile.mkdtemp(prefix='superterm-strict-build-')
    try:
        os.makedirs(os.path.join(root, 'bin'))
        compile_mode(root, 'release', 'release')
        compile_mode(root, 'debug', 'debug')
        compile_mode(root, 'test-runtime', 'release',
                     '-dSUPERTERM_TEST_BUILD')
    finally:
        shutil.rmtree(root, ignore_errors=True)

    print()
    if failed:
        print('RESULT: FAIL')
        return 1
    print('RESULT: PASS (release, debug, test-runtime)')
    return 0


sys.exit(main())
