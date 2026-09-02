#!/usr/bin/env python3
"""superterm test: every suite owns exactly one documented behavior contract."""
import glob
import os
import re
import sys


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
MANIFEST = os.path.join(ROOT, 'test', 'README.md')
REQUIRED_AREAS = {
    'UI', 'sessions', 'protocol', 'rendering', 'colour', 'input',
    'lifecycle', 'SSH', 'cleanup',
}
failed = False


def check(label, condition):
    global failed
    print(f'{label:56s}: {"OK" if condition else "FAIL"}')
    if not condition:
        failed = True


def main():
    try:
        with open(MANIFEST, encoding='utf-8') as handle:
            text = handle.read()
    except OSError as exc:
        print(f'cannot read {MANIFEST}: {exc}')
        return 1

    rows = re.findall(
        r'^\|\s*([a-z0-9_]+_test\.py)\s*\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|$',
        text, re.MULTILINE)
    names = [name for name, _areas, _contract in rows]
    present = sorted(os.path.basename(path) for path in
                     glob.glob(os.path.join(ROOT, 'test', '*_test.py')))
    check('every suite has one manifest row', sorted(names) == present)
    missing = sorted(set(present) - set(names))
    extra = sorted(set(names) - set(present))
    duplicate = sorted({name for name in names if names.count(name) > 1})
    for name in missing:
        print(f'  missing contract: {name}')
    for name in extra:
        print(f'  stale contract: {name}')
    for name in duplicate:
        print(f'  duplicate contract: {name}')
    check('no suite contract is duplicated', not duplicate)
    check('every contract has meaningful text',
          all(len(contract.strip()) >= 24 for _name, _areas, contract in rows))

    covered = set()
    for _name, areas, _contract in rows:
        covered.update(part.strip() for part in areas.split(','))
    absent_areas = sorted(REQUIRED_AREAS - covered)
    check('all mandatory behavior areas are represented', not absent_areas)
    for area in absent_areas:
        print(f'  missing area: {area}')

    check('manifest states the frozen-expectation rule',
          'must not edit an expectation' in text)
    print()
    if failed:
        print('RESULT: FAIL')
        return 1
    print(f'RESULT: PASS ({len(rows)} behavior contracts)')
    return 0


sys.exit(main())
