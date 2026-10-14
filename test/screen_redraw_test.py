#!/usr/bin/env python3
"""A pane's redraw puts a cleared terminal exactly where the program was.

When a fullscreen pane takes the terminal back, superterm draws the pane from
its screen model and the program's raw output carries on from there (issue
#5). The probe parses streams into one screen, plays that screen's redraw
into a cleared second one, and requires the two to agree -- cells, cursor,
pen, scrolling region, cursor visibility -- before and after both receive the
same further bytes, so a lost pending wrap or autowrap mode shows up too.
"""
import os
import shutil
import subprocess
import sys
import tempfile


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
PROBE_SOURCE = os.path.join(ROOT, 'test', 'screen_redraw_probe.pas')
CASES = 9
failed = False


def check(label, condition):
    global failed
    print(f'{label:58s}: {"OK" if condition else "FAIL"}')
    if not condition:
        failed = True


build = tempfile.mkdtemp(prefix='superterm-screen-redraw-')
try:
    fpc = shutil.which('fpc')
    result = None
    if fpc:
        result = subprocess.run([
            fpc, '-Mobjfpc', '-Sh', '-Sewnh', '-vewnh',
            '-vm11030,11031', '-O2', '-Fu' + os.path.join(ROOT, 'src'),
            '-FU' + build, '-FE' + build,
            '-o' + os.path.join(build, 'screen-redraw-probe'), PROBE_SOURCE,
        ], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            timeout=60, check=False)
    built = result is not None and result.returncode == 0
    check('redraw probe compiles diagnostic-clean', built)
    if not built and result is not None:
        print(result.stdout[-8000:])
    if built:
        run = subprocess.run(
            [os.path.join(build, 'screen-redraw-probe')], text=True,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            timeout=60, check=False)
        print(run.stdout.rstrip())
        passed = [line for line in run.stdout.splitlines()
                  if line.endswith(': OK')]
        check('every case redraws and continues identically',
              run.returncode == 0 and len(passed) == 2 * CASES)
finally:
    shutil.rmtree(build, ignore_errors=True)

print()
if failed:
    print('RESULT: FAIL')
sys.exit(1 if failed else 0)
