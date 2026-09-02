#!/usr/bin/env python3
"""superterm test: one frozen Python wire table matches the Pascal server."""
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
    check('the daemon unit is readable', os.path.isfile(stlib.SERVER_SOURCE))
    if not os.path.isfile(stlib.SERVER_SOURCE):
        return 1

    declared = stlib.pascal_constants(stlib.WIRE_CONSTANT_NAMES)
    missing = [name for name in stlib.WIRE_CONSTANT_NAMES
               if name not in declared]
    check('every frozen entry exists in the Pascal unit', not missing)
    for name in missing:
        print(f'  missing from src/st_server.pas: {name}')

    mismatched = [
        (name, getattr(stlib, name), declared[name])
        for name in stlib.WIRE_CONSTANT_NAMES if name in declared
        and getattr(stlib, name) != declared[name]
    ]
    check('every frozen entry keeps its reviewed value', not mismatched)
    for name, fixture_value, server_value in mismatched:
        print(f'  {name}: fixture={fixture_value}, server={server_value}')

    try:
        version = stlib.attach_proto_ver()
        version_ok = isinstance(version, int) and version > 0
    except RuntimeError:
        version = None
        version_ok = False
    check('the intentionally versioned attach field is readable', version_ok)
    if version_ok:
        print(f'  current attach protocol version: {version}')

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
            for match in pattern.finditer(handle.read()):
                if name == 'run_tests.py':
                    runner_values[match.group(1)] = int(match.group(2))
                else:
                    offenders.append((name, match.group(1)))
    check('no suite privately redeclares a wire constant', not offenders)
    for name, constant in offenders:
        print(f'  test/{name}: {constant}')

    runner_wrong = [(name, value) for name, value in runner_values.items()
                    if getattr(stlib, name, None) != value]
    check('the independent runner close frame still matches', not runner_wrong)
    for name, value in runner_wrong:
        print(f'  run_tests.py {name}={value}; fixture={getattr(stlib, name)}')

    print()
    if failed:
        print('RESULT: FAIL')
        return 1
    print(f'RESULT: PASS ({len(stlib.WIRE_CONSTANT_NAMES)} constants)')
    return 0


sys.exit(main())
