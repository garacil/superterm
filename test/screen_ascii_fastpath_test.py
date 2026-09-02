#!/usr/bin/env python3
"""The ordinary ASCII parser path is allocation-free and semantics-preserving."""
import os
import re
import shutil
import subprocess
import sys
import tempfile


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
SOURCE = os.path.join(ROOT, 'src', 'st_screen.pas')
PROBE_SOURCE = os.path.join(ROOT, 'test', 'screen_ascii_fastpath_probe.pas')
failed = False


def check(label, condition):
    global failed
    print(f'{label:58s}: {"OK" if condition else "FAIL"}')
    if not condition:
        failed = True


with open(SOURCE, encoding='utf-8') as stream:
    source = stream.read()

ascii_body = re.search(
    r'procedure\s+TScreen\.PutAsciiChar\b(.*?)\nend;', source,
    re.IGNORECASE | re.DOTALL)
check('dedicated ASCII parser path exists', ascii_body is not None)
check('ASCII parser path performs no managed allocation',
      ascii_body is not None and
      not re.search(r'\b(?:SetLength|Copy)\s*\(', ascii_body.group(1),
                    re.IGNORECASE))
check('single-byte UTF-8 path dispatches directly to ASCII path',
      re.search(r'if\s+b\s*<\s*\$80\s+then.*?PutAsciiChar\s*\(b,\s*Attr\s*\)',
                source, re.IGNORECASE | re.DOTALL) is not None)

build = tempfile.mkdtemp(prefix='superterm-screen-ascii-')
try:
    fpc = shutil.which('fpc')
    result = None
    if fpc:
        result = subprocess.run([
            fpc, '-Mobjfpc', '-Sh', '-Sewnh', '-vewnh',
            '-vm11030,11031', '-O4', '-Fu' + os.path.join(ROOT, 'src'),
            '-FU' + build, '-FE' + build,
            '-o' + os.path.join(build, 'screen-ascii-probe'), PROBE_SOURCE,
        ], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            timeout=60, check=False)
    built = result is not None and result.returncode == 0
    check('focused parser probe compiles diagnostic-clean', built)
    if not built and result is not None:
        print(result.stdout[-8000:])
    if built:
        run = subprocess.run(
            [os.path.join(build, 'screen-ascii-probe')], text=True,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            timeout=60, check=False)
        checks = [line for line in run.stdout.splitlines()
                  if line.endswith(': OK')]
        timing = re.search(r'^benchmark_ms=(\d+)$', run.stdout, re.MULTILINE)
        check('ASCII/wrap/rendition/UTF-8 semantics pass',
              run.returncode == 0 and len(checks) == 4)
        check('parser benchmark completes', timing is not None)
        if timing:
            print('  16 MiB focused ASCII parse: %s ms' % timing.group(1))
        if run.returncode != 0:
            print(run.stdout[-8000:])
finally:
    shutil.rmtree(build, ignore_errors=True)

print()
if failed:
    print('RESULT: FAIL')
sys.exit(1 if failed else 0)
