#!/usr/bin/env python3
"""superterm test: the primary-reference catalogue is complete and verified."""
import hashlib
import os
import re
import sys


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
REFS = os.path.join(ROOT, 'docs', 'references')
INDEX = os.path.join(REFS, 'index.md')
SUMS = os.path.join(REFS, 'SHA256SUMS')
failed = False


def check(label, condition):
    global failed
    print(f'{label:58s}: {"OK" if condition else "FAIL"}')
    if not condition:
        failed = True


def main():
    with open(INDEX, encoding='utf-8') as handle:
        index = handle.read()
    with open(SUMS, encoding='ascii') as handle:
        manifest = handle.read()

    entries = re.findall(r'^([0-9a-f]{64})\s+(docs/references/\S+)$',
                         manifest, re.MULTILINE)
    files = sorted(name for name in os.listdir(REFS)
                   if name != 'SHA256SUMS')
    listed = sorted(os.path.basename(path) for _digest, path in entries)
    check('every committed catalogue file has one checksum', files == listed)
    check('checksum manifest has no duplicate paths',
          len(listed) == len(set(listed)))
    for digest, relative in entries:
        path = os.path.join(ROOT, relative)
        try:
            with open(path, 'rb') as handle:
                actual = hashlib.sha256(handle.read()).hexdigest()
        except OSError:
            actual = ''
        check(f'checksum matches {os.path.basename(path)}', actual == digest)

    rows = re.findall(r'^\| ([^|]+) \| \[[^]]+\]\((https://[^)]+)\) '
                      r'\| ([^|]+) \| ([^|]+) \| ([^|]+) \|$',
                      index, re.MULTILINE)
    check('reference table contains the required primary areas',
          len(rows) >= 10)
    check('every reference uses an HTTPS primary link',
          all(url.startswith('https://') for _s, url, _l, _r, _h in rows))
    check('every reference records local-copy policy',
          all(local.strip() for _s, _u, local, _r, _h in rows))
    check('every reference records redistribution evidence',
          all(rights.strip() for _s, _u, _l, rights, _h in rows))
    check('unlicensed standards remain link-only',
          all(local.strip() == 'link-only' for subject, _url, local,
              rights, _hash in rows
              if subject.startswith('ECMA-') and
              'no redistribution grant' in rights))
    ecma_hashes = re.findall(
        r'^\| ECMA-[^|]+\|.*?`([0-9a-f]{64})`\s*\|$',
        index, re.MULTILINE)
    check('link-only ECMA artifacts have complete SHA-256 digests',
          len(ecma_hashes) == 2)

    print()
    if failed:
        print('RESULT: FAIL')
        return 1
    print(f'RESULT: PASS ({len(rows)} primary references)')
    return 0


sys.exit(main())
