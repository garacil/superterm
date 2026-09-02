#!/usr/bin/env python3
"""superterm test: the Python wire table and the Pascal unit must agree.

Suites that speak the daemon socket need its frame numbers. They used to
declare their own -- FRAME_SCREEN = 21 appeared in ten separate files -- so a
renumbering had ten places to miss, and a suite left behind would keep
building frames the daemon no longer understands while still reporting PASS
for whatever it happened to observe.

stlib now owns one frozen table. Frozen, not derived: a table parsed out of
the unit would follow a renumbering silently, which is precisely what must not
happen. This suite is the tripwire that turns such a change into a visible
failure on both sides at once.

It also refuses a private redeclaration creeping back into any suite.
"""
import glob
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import stlib  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEST_DIR = os.path.join(ROOT, 'test')
failed = False


def check(label, condition):
    global failed
    print(f'{label:52s}: {"OK" if condition else "FAIL"}')
    if not condition:
        failed = True


def main():
    check('the daemon unit is readable',
          os.path.isfile(stlib.SERVER_SOURCE))
    if not os.path.isfile(stlib.SERVER_SOURCE):
        print('\nRESULT: FAIL')
        sys.exit(1)

    declared = stlib.pascal_constants(stlib.WIRE_CONSTANT_NAMES)

    missing = [n for n in stlib.WIRE_CONSTANT_NAMES if n not in declared]
    check('every table entry still exists in the unit', not missing)
    for name in missing:
        print(f'  {name} is in stlib but no longer declared in st_server.pas')

    mismatched = [(n, getattr(stlib, n), declared[n])
                  for n in stlib.WIRE_CONSTANT_NAMES
                  if n in declared and getattr(stlib, n) != declared[n]]
    check('every table entry has the unit\'s value', not mismatched)
    for name, python_value, pascal_value in mismatched:
        print(f'  {name}: stlib says {python_value}, '
              f'st_server.pas says {pascal_value}')

    absent = [n for n in stlib.WIRE_CONSTANT_NAMES if not hasattr(stlib, n)]
    check('every listed name is defined in stlib', not absent)
    for name in absent:
        print(f'  {name} is listed in WIRE_CONSTANT_NAMES but not defined')

    # A version bump is meant to be followed, not frozen; it must still be
    # findable, because three suites used to parse it out of the unit
    # themselves and would otherwise fail obscurely.
    try:
        version = stlib.attach_proto_ver()
        ok = isinstance(version, int) and version > 0
    except RuntimeError:
        version, ok = None, False
    check('the attach protocol version is readable', ok)
    if ok:
        print(f'  attach protocol version {version}')

    # No suite may keep a private copy of a wire constant. FRAME_LEFT and
    # friends are window-frame glyphs and have nothing to do with the wire.
    #
    # run_tests.py is the one exemption: it is the outer harness, and importing
    # the fixture would leave it unable to reap a suite whose fixture is the
    # thing that broke. Its copy is checked for the right VALUE instead.
    pattern = re.compile(
        r'^(' + '|'.join(stlib.WIRE_CONSTANT_NAMES) +
        r'|ATTACH_PROTO_VER)\s*=\s*(-?\d+)', re.MULTILINE)
    offenders = []
    runner_values = {}
    for path in sorted(glob.glob(os.path.join(TEST_DIR, '*.py'))):
        name = os.path.basename(path)
        if name == 'stlib.py':
            continue
        with open(path, encoding='utf-8') as handle:
            for hit in pattern.finditer(handle.read()):
                if name == 'run_tests.py':
                    runner_values[hit.group(1)] = int(hit.group(2))
                else:
                    offenders.append((name, hit.group(1)))
    check('no suite redeclares a wire constant', not offenders)
    for name, constant in offenders:
        print(f'  test/{name} declares its own {constant}')

    runner_wrong = [(n, v) for n, v in runner_values.items()
                    if getattr(stlib, n, None) != v]
    check('the runner\'s own copies still match the wire', not runner_wrong)
    for name, value in runner_wrong:
        print(f'  run_tests.py has {name} = {value}, wire says '
              f'{getattr(stlib, name, None)}')

    print()
    if failed:
        print('RESULT: FAIL')
        sys.exit(1)
    print(f'RESULT: PASS ({len(stlib.WIRE_CONSTANT_NAMES)} constants)')
    sys.exit(0)


main()
