#!/usr/bin/env python3
"""Per-client UTF-8 probing and 7-bit Windows compatibility rendering.

The ordinary stlib terminal deliberately returns one fixed CPR, which is the
right oracle for cursor restoration but cannot describe where a just-rendered
glyph moved its cursor.  This client supplies the three real replies involved
in startup: the caller's original cursor, the probe baseline, and the cursor
after the concealed marker.  Replies are fragmented and may have typeahead in
front of them, so a parser that merely reads through the next ``R`` cannot
make this suite pass.
"""
import os
import select
import sys
import time

import pyte

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, run_cli


WIDTH, HEIGHT = 100, 30
DSR = b'\x1b[6n'
PROBE_MARKER = b'\xc2\xa3'       # U+00A3: one UTF-8 cell, two legacy bytes
UTF8_BOX_PREFIXES = (b'\xe2\x94', b'\xe2\x95', b'\xe2\x96')


def configure(home):
    with open(home + '/.superterm/superterm.ini', 'w', encoding='utf-8') as fh:
        fh.write('[ui]\nlanguage=en\nbackground=none\n'
                 '[session]\nserver=always\nautosave=0\nautorestore=0\n'
                 'zoomanim=0\n')


class ProbeClient(stlib.Client):
    """stlib client whose CPR oracle models a real terminal cursor."""

    def __init__(self, *args, cell_width=1, timeout_query=0,
                 inject_typeahead=False, **kwargs):
        self.cell_width = cell_width
        self.timeout_query = timeout_query
        self.inject_typeahead = inject_typeahead
        self.query_count = 0
        self.query_tail = b''
        self.query_offsets = []
        self.probe_end_raw = None
        self.held_reply = None
        super().__init__(*args, **kwargs)

    @staticmethod
    def fragmented_write(fd, payload, suffix=b''):
        cuts = (payload[:1], payload[1:3], payload[3:-1],
                payload[-1:] + suffix)
        for part in cuts:
            if not part:
                continue
            stlib.write_all(fd, part)
            time.sleep(0.008)

    def answer_query(self):
        self.query_count += 1
        if self.inject_typeahead:
            prefixes = {1: b'p', 2: b'r', 3: b'i'}
            stlib.write_all(self.fd, prefixes.get(self.query_count, b''))
        if self.query_count == 1:
            reply = b'\x1b[5;7R'
        elif self.query_count == 2:
            reply = b'\x1b[1;1R'
        else:
            reply = f'\x1b[1;{1 + self.cell_width}R'.encode('ascii')
            self.probe_end_raw = len(self._raw)
        if self.query_count == self.timeout_query:
            self.held_reply = reply
            return
        suffix = b'n' if self.inject_typeahead and self.query_count == 3 else b''
        self.fragmented_write(self.fd, reply, suffix)

    def send_held_reply(self):
        if self.held_reply is not None:
            reply = self.held_reply
            self.held_reply = None
            self.fragmented_write(self.fd, reply)

    def drain(self, seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            ready, _, _ = select.select([self.fd], [], [], 0.05)
            if not ready:
                continue
            try:
                data = os.read(self.fd, 65536)
            except OSError:
                return
            if not data:
                return
            old_tail = self.query_tail
            combined = old_tail + data
            base = len(self._raw) - len(old_tail)
            self._raw += data
            start = 0
            while True:
                pos = combined.find(DSR, start)
                if pos < 0:
                    break
                self.query_offsets.append(base + pos)
                self.answer_query()
                start = pos + len(DSR)
            self.query_tail = combined[-(len(DSR) - 1):]
            stlib.feed_pyte(self.stream, data, 'terminal_encoding')
            if self._transition_capture:
                self._feed_transition_capture(data)

    def post_probe_raw(self):
        if self.probe_end_raw is None:
            return b''
        return self._raw[self.probe_end_raw:]

    def windows_text(self):
        """Render Microsoft's documented ESC(0/ESC(B DEC-ACS behavior.

        pyte implements DEC graphics through G1/SO/SI but not the equivalent
        Windows sequences.  Rewriting only those two designators lets pyte
        model what Windows Console documents, without changing the captured
        product bytes used by the stronger wire assertions below.
        """
        wire = self._raw.replace(
            b'\x1b(0', b'\x1b%@\x1b)0\x0e').replace(
            b'\x1b(B', b'\x0f\x1b%G')
        screen = pyte.Screen(self.w, self.h)
        stream = pyte.ByteStream(screen)
        stlib.feed_pyte(stream, wire, 'terminal_encoding wire')
        stlib.flush_pyte(stream, 'terminal_encoding wire')
        return '\n'.join(row.rstrip() for row in screen.display)


def one_session(home):
    sockets = stlib.session_sockets(home)
    check('one canonical encoding-test session exists', len(sockets) == 1)
    return os.path.basename(sockets[0])[:-5] if sockets else ''


def drain_all(clients, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        for client in clients:
            client.drain(0.025)


def no_utf8_box(data):
    return all(prefix not in data for prefix in UTF8_BOX_PREFIXES)


# One canonical session, two physical renderers with opposite capabilities.
home = stlib.fresh_home('terminal-encoding-shared')
configure(home)
utf8 = ProbeClient(home, w=WIDTH, h=HEIGHT, cell_width=1,
                   inject_typeahead=True)
legacy = None
try:
    utf8.drain(2.0)
    check('UTF-8 startup performs exactly three CPR queries',
          utf8.query_count == 3)
    check('UTF-8 probe marker is between baseline and result queries',
          len(utf8.query_offsets) == 3 and
          PROBE_MARKER in utf8.raw()[utf8.query_offsets[1]:
                                    utf8.query_offsets[2]])
    check('one-cell client keeps UTF-8 box drawing',
          any(prefix in utf8.post_probe_raw()
              for prefix in UTF8_BOX_PREFIXES))

    # "prin" arrived around all three CPRs: before each report and, for the
    # last one, immediately after its final R in the same write. It must
    # survive Capture, KInit and both probe reads byte-for-byte.
    utf8.send(b"tf 'ENCODING_TYPEAHEAD_%s\\n' 'SAFE'\r", 1.0)
    check('typeahead interleaved with CPR is preserved byte-for-byte',
          b'ENCODING_TYPEAHEAD_SAFE' in utf8.raw())

    session = one_session(home)
    legacy = ProbeClient(home, args=['--attach', session],
                         w=WIDTH, h=HEIGHT, cell_width=2,
                         # Exercise FPC's non-UTF-8 LANG initialization too;
                         # the measured renderer must remain coherent after
                         # its ESC%@ ISO-8859 terminal selection.
                         env={'LANG': 'C'})
    legacy.drain(2.0)
    check('legacy startup performs exactly three CPR queries',
          legacy.query_count == 3)
    legacy_frame = legacy.post_probe_raw()
    check('two-cell decoding selects 7-bit DEC ACS',
          b'\x1b(0' in legacy_frame and b'\x1b(B' in legacy_frame)
    check('legacy renderer emits no UTF-8 box/block bytes',
          no_utf8_box(legacy_frame))
    check('every ACS selection is returned to ASCII',
          legacy_frame.count(b'\x1b(0') == legacy_frame.count(b'\x1b(B'))
    legacy_text = legacy.windows_text()
    legacy_view_ok = ('Detach' in legacy_text and 'Panes' in legacy_text and
                      ('┌' in legacy_text or '╔' in legacy_text) and
                      ('│' in legacy_text or '║' in legacy_text))
    if not legacy_view_ok:
        print('--- simulated Windows ACS view ---')
        print(legacy_text)
    check('documented Windows ACS renderer shows the complete IDE',
          legacy_view_ok)

    clients = (utf8, legacy)
    offsets = {client: len(client.raw()) for client in clients}
    legacy.send(b"printf 'ENCODING_SHARED_%s\\n' 'SAFE'\r", 0.2)
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        drain_all(clients, 0.08)
        if all(b'ENCODING_SHARED_SAFE' in
               client.raw()[offsets[client]:] for client in clients):
            break
    check('both encodings observe one shared pane output',
          all(b'ENCODING_SHARED_SAFE' in client.raw()[offsets[client]:]
              for client in clients))

    # Equal geometries allow raw fullscreen only for the UTF-8 renderer. The
    # legacy peer must keep parsing the same shared output through TScreen.
    os.write(utf8.fd, stlib.FULLSCREEN_CHORD)
    drain_all(clients, 1.2)
    offsets = {client: len(client.raw()) for client in clients}
    osc = b'\x1b]777;ENCODING_RAW_ONLY\x07'
    os.write(utf8.fd,
             b"printf '\\033]777;ENCODING_RAW_ONLY\\007'; "
             b"printf 'ENCODING_FULLSCREEN_%s\\n' 'SAFE'\r")
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        drain_all(clients, 0.08)
        if all(b'ENCODING_FULLSCREEN_SAFE' in
               client.raw()[offsets[client]:] for client in clients):
            break
    utf8_chunk = utf8.raw()[offsets[utf8]:]
    legacy_chunk = legacy.raw()[offsets[legacy]:]
    check('UTF-8 client retains raw fullscreen fidelity',
          osc in utf8_chunk and b'ENCODING_FULLSCREEN_SAFE' in utf8_chunk)
    check('legacy client stays on safe rendered fullscreen path',
          osc not in legacy_chunk and
          b'ENCODING_FULLSCREEN_SAFE' in legacy_chunk and
          no_utf8_box(legacy_chunk))
finally:
    if legacy is not None:
        legacy.close()
    utf8.close()
    stlib.close_all_daemons(home)


# A missing probe result defaults to UTF-8; its eventual CPR is swallowed as
# protocol, not typed into the pane or decoded as F3.
late_home = stlib.fresh_home('terminal-encoding-late')
configure(late_home)
late = ProbeClient(late_home, w=WIDTH, h=HEIGHT, cell_width=1,
                   timeout_query=3)
try:
    late.drain(1.2)
    check('result timeout still issued the complete three-query probe',
          late.query_count == 3 and late.held_reply is not None)
    check('result timeout conservatively keeps UTF-8',
          any(prefix in late.post_probe_raw() for prefix in UTF8_BOX_PREFIXES))
    before = len(late.raw())
    late.send_held_reply()
    late.drain(0.4)
    late.send(b"printf 'ENCODING_LATE_%s\\n' 'SAFE'\r", 0.8)
    late_chunk = late.raw()[before:]
    check('late CPR never leaks into pane text',
          b'[1;2R' not in late_chunk and b'ENCODING_LATE_SAFE' in late.raw())
    session = one_session(late_home)
    listed = run_cli(['list', session], late_home)
    check('late CPR cannot trigger F3 or create a pane',
          listed.returncode == 0 and
          len([line for line in listed.stdout.splitlines()
               if line[:1].isdigit()]) == 1)
finally:
    late.close()
    stlib.close_all_daemons(late_home)


# If the baseline itself is unavailable, no glyph is emitted and no second
# query can be confused with the original delayed CPR.
base_home = stlib.fresh_home('terminal-encoding-no-baseline')
configure(base_home)
base_timeout = ProbeClient(base_home, w=WIDTH, h=HEIGHT,
                           timeout_query=2)
try:
    base_timeout.drain(1.0)
    check('baseline timeout stops before marker/result query',
          base_timeout.query_count == 2 and
          PROBE_MARKER not in base_timeout.raw())
    check('baseline timeout keeps existing UTF-8 renderer',
          any(prefix in base_timeout.raw() for prefix in UTF8_BOX_PREFIXES))
finally:
    base_timeout.close()
    stlib.close_all_daemons(base_home)


# A CPR remains terminal protocol even when it arrives well after the bounded
# startup read.  Treating an expired ESC[1;1R as CSI-F3 used to open a phantom
# split, which is far worse than the optional encoding probe timing out.
late_base_home = stlib.fresh_home('terminal-encoding-late-baseline')
configure(late_base_home)
late_base = ProbeClient(late_base_home, w=WIDTH, h=HEIGHT,
                        timeout_query=2)
try:
    late_base.drain(2.3)
    check('very late baseline was held past the old expiry',
          late_base.query_count == 2 and late_base.held_reply == b'\x1b[1;1R')
    late_base.send_held_reply()
    late_base.drain(0.4)
    late_base.send(b"printf 'ENCODING_LATE_BASE_%s\\n' 'SAFE'\r", 0.8)
    check('input remains live after a very late baseline CPR',
          b'ENCODING_LATE_BASE_SAFE' in late_base.raw())
    session = one_session(late_base_home)
    listed = run_cli(['list', session], late_base_home)
    check('very late baseline cannot become F3 and split the pane',
          listed.returncode == 0 and
          len([line for line in listed.stdout.splitlines()
               if line[:1].isdigit()]) == 1)
finally:
    late_base.close()
    stlib.close_all_daemons(late_base_home)


stlib.report()
