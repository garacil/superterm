#!/usr/bin/env python3
"""superterm test: the rejected pipeline must stay out of this tree.

This branch keeps main's architecture: the daemon is authoritative and
multiplexes pane bytes, every attached client owns one persistent Free Vision
tree, and the last mile is st_video's changed-cell diff. The `speedupx` branch
replaced that with a daemon-side dense-frame pipeline -- session authority,
desktop actor, normalized frames, per-endpoint projection, delivery threads and
a thin client -- and it was measured 1.4x to 4.6x slower per update, growing
with desktop AREA rather than with changed cells.

That decision is easy to state and easy to erode one file at a time, because
those units are genuinely well written and each looks reasonable on its own.
This suite makes the boundary mechanical instead of cultural. It is deliberately
static: no daemon, no PTY, no build.

It also guards the macOS CI matrix. speedupx deleted it, which is a coverage
regression rather than an improvement: this tree still builds and passes there.
"""
import glob
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
SRC = os.path.join(ROOT, 'src')
failed = False


def check(label, condition):
    global failed
    print(f'{label:60s}: {"OK" if condition else "FAIL"}')
    if not condition:
        failed = True


# Units that exist only to serve the dense-frame pipeline. Importing any of
# them means the architecture decision has been reversed by accident.
REJECTED_UNITS = (
    'st_session_authority', 'st_session_types', 'st_session_effects',
    'st_session_desktop_actor', 'st_session_desktop_bridge',
    'st_session_endpoint_package', 'st_session_endpoint_delivery',
    'st_endpoint_sink', 'st_normalized_frame', 'st_presentation',
    'st_native_transaction', 'st_pane_raw',
    'st_worker', 'st_worker_bridge', 'st_worker_input', 'st_worker_lifecycle',
    'st_worker_fv_runtime', 'st_worker_fv_model', 'st_worker_fv_backend',
    'st_worker_fv_dialogs', 'st_fv_semantic_bridge', 'st_fv_chrome',
    'st_v1_thin_client', 'st_attach', 'st_conn_codec', 'st_product_input',
    'st_term_wire', 'st_screen_codec',
)

# Directory layout the pipeline introduced. Main+ keeps src/ flat.
REJECTED_DIRS = ('terminal', 'platform')


def main():
    sources = sorted(glob.glob(os.path.join(SRC, '*.pas')) +
                     glob.glob(os.path.join(SRC, '*.lpr')))
    check('src/ has sources to inspect', len(sources) > 10)

    present = [u for u in REJECTED_UNITS
               if os.path.exists(os.path.join(SRC, u + '.pas'))]
    check('no rejected pipeline unit exists in src/', not present)
    for name in present:
        print(f'  src/{name}.pas belongs to the rejected dense-frame pipeline')

    dirs = [d for d in REJECTED_DIRS if os.path.isdir(os.path.join(SRC, d))]
    check('src/ keeps its flat layout', not dirs)
    for name in dirs:
        print(f'  src/{name}/ is the pipeline layout, not this architecture')

    # An import is the real coupling: a stray copy of a file is inert, a uses
    # clause is not. Scan uses clauses rather than the whole text so a mention
    # inside a comment (like this suite's own rationale) is not a failure.
    rejected = set(REJECTED_UNITS)
    importers = []
    uses_re = re.compile(r'^\s*uses\b(.*?);', re.S | re.M | re.I)
    for path in sources:
        with open(path, encoding='utf-8', errors='replace') as handle:
            text = handle.read()
        # strip { } and (* *) comments and // lines before looking at uses
        text = re.sub(r'\(\*.*?\*\)', ' ', text, flags=re.S)
        text = re.sub(r'\{.*?\}', ' ', text, flags=re.S)
        text = re.sub(r'//[^\n]*', ' ', text)
        for match in uses_re.finditer(text):
            names = {n.strip().lower()
                     for n in match.group(1).replace('\n', ' ').split(',')}
            hit = sorted(rejected & names)
            for name in hit:
                importers.append((os.path.basename(path), name))
    check('no source imports a rejected pipeline unit', not importers)
    for path, name in importers:
        print(f'  src/{path} uses {name}')

    # Coverage guard: speedupx removed these jobs; removing them here would
    # silently stop proving the macOS target that this project still supports.
    ci = os.path.join(ROOT, '.github', 'workflows', 'ci.yml')
    try:
        with open(ci, encoding='utf-8') as handle:
            workflow = handle.read()
    except OSError:
        workflow = ''
    check('CI workflow is readable', bool(workflow))
    check('CI still builds on macOS', 'macos-' in workflow)
    check('CI still builds on GNU/Linux', 'ubuntu-' in workflow)

    print()
    if failed:
        print('RESULT: FAIL')
        sys.exit(1)
    print(f'RESULT: PASS ({len(sources)} sources, '
          f'{len(REJECTED_UNITS)} rejected units checked)')
    sys.exit(0)


main()
