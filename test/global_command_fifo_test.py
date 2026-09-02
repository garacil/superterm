#!/usr/bin/env python3
"""Global daemon FIFO: concurrent clients execute in observed order."""
import os
import re
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import (FRAME_ATTACH, FRAME_CTL_CAPTURE, FRAME_CTL_DATA,
                   FRAME_CTL_END, FRAME_CTL_ERR, FRAME_CTL_INFO,
                   FRAME_CTL_OK, FRAME_CTL_SEND, FRAME_DETACH, FRAME_INPUT,
                   FRAME_READY, check, raw_frame, read_frame)
CLIENTS = 3
TOKENS_PER_CLIENT = 40
DEBUG_LOG = '/tmp/superterm-global-command-fifo.log'
READY_MARKER = 'FIFO_READY_47A9'

FIFO_RE = re.compile(
    r'command-fifo: (enqueue|dequeue) seq=(\d+) origin=(\w+) '
    r'slot=(\d+) gen=(\d+) kind=(\d+) pane=(-?\d+) bytes=(\d+)'
    r'(?: valid=(\d+))?')


def check_multiprocess_flow_log():
    """Make many independent st_debug users append long records at once."""
    workers = 16
    records = 120
    payload_size = 2048
    source_dir = os.path.abspath(os.path.join(
        os.path.dirname(__file__), '..', 'src'))
    helper_source = r'''
program st_debug_log_writer;

{$mode objfpc}{$H+}

uses
  cthreads, SysUtils, st_debug;

const
  PayloadSize = 2048;

var
  Worker: string;
  SyncDir: string;
  WorkerNo, RecordNo, RecordCount: integer;
  Payload: string;
  ReadyFile: Text;
begin
  if ParamCount <> 3 then
    Halt(2);
  Worker := ParamStr(1);
  WorkerNo := StrToInt(Worker);
  RecordCount := StrToInt(ParamStr(2));
  SyncDir := IncludeTrailingPathDelimiter(ParamStr(3));
  Payload := StringOfChar(Chr(Ord('A') + (WorkerNo mod 16)), PayloadSize);
  DebugSetRole('mp-' + Worker);
  AssignFile(ReadyFile, SyncDir + 'ready-' + Worker);
  Rewrite(ReadyFile);
  CloseFile(ReadyFile);
  while not FileExists(SyncDir + 'start') do
    Sleep(1);
  for RecordNo := 0 to RecordCount - 1 do
    DebugLog('MPLOG worker=' + Worker + ' seq=' + IntToStr(RecordNo) +
      ' payload=' + Payload);
end.
'''
    with tempfile.TemporaryDirectory(
            prefix='superterm-multiprocess-log-') as temp_dir:
        source_path = os.path.join(temp_dir, 'st_debug_log_writer.pas')
        helper_path = os.path.join(temp_dir, 'st_debug_log_writer')
        unit_dir = os.path.join(temp_dir, 'units')
        log_path = os.path.join(temp_dir, 'flow.log')
        os.mkdir(unit_dir)
        with open(source_path, 'w', encoding='ascii') as stream:
            stream.write(helper_source)
        compile_result = subprocess.run(
            ['fpc', '-Mobjfpc', '-Sh', '-Fu' + source_dir,
             '-FU' + unit_dir, '-FE' + temp_dir, '-o' + helper_path,
             source_path],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, timeout=30.0, check=False)
        compile_clean = (compile_result.returncode == 0 and
                         not re.search(r'\b(?:Warning|Note):',
                                       compile_result.stdout))
        if not compile_clean:
            print('  st_debug helper compiler output:')
            print(compile_result.stdout.rstrip())
        check('multiprocess log helper compiles cleanly', compile_clean)
        if compile_result.returncode != 0:
            check('all multiprocess log writers exit cleanly', False)
            check('multiprocess log has every record once', False)
            check('multiprocess log lines stay atomic', False)
            return

        env = os.environ.copy()
        env['SUPERTERM_DEBUG'] = log_path
        env['SUPERTERM_DEBUG_FULL'] = '1'
        processes = [subprocess.Popen(
            [helper_path, str(worker), str(records), temp_dir], env=env,
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            for worker in range(workers)]
        ready_paths = [os.path.join(temp_dir, 'ready-' + str(worker))
                       for worker in range(workers)]
        ready_deadline = time.monotonic() + 10.0
        while (time.monotonic() < ready_deadline and
               not all(os.path.exists(path) for path in ready_paths)):
            time.sleep(0.005)
        all_ready = all(os.path.exists(path) for path in ready_paths)
        check('multiprocess log writers reach barrier', all_ready)
        # Release every surviving helper even after a failed readiness check,
        # so the test's own teardown never strands a child process.
        with open(os.path.join(temp_dir, 'start'), 'wb'):
            pass
        errors = []
        for worker, process in enumerate(processes):
            try:
                _stdout, stderr = process.communicate(timeout=30.0)
            except subprocess.TimeoutExpired:
                process.kill()
                _stdout, stderr = process.communicate()
                errors.append((worker, 'timeout'))
            if process.returncode != 0:
                errors.append((worker, 'exit=%d stderr=%r' %
                               (process.returncode, stderr[-300:])))
        if errors:
            print('  multiprocess writer errors:', errors)
        check('all multiprocess log writers exit cleanly', not errors)

        try:
            with open(log_path, 'rb') as stream:
                raw_lines = stream.read().splitlines()
        except FileNotFoundError:
            raw_lines = []
        # Keep GNU strict: its pthread_t is emitted as a decimal ordinal.
        # Darwin models pthread_t as a pointer, which st_debug renders in hex.
        thread_id_pattern = (rb'[0-9A-Fa-f]+' if sys.platform == 'darwin'
                             else rb'\d+')
        line_re = re.compile(
            rb'^\d\d:\d\d:\d\d\.\d\d\d \[(\d+) mp-(\d+) tid=' +
            thread_id_pattern + rb'\] ' +
            rb'MPLOG worker=(\d+) seq=(\d+) payload=([A-P]+)$')
        seen = set()
        corrupt = []
        for index, line in enumerate(raw_lines):
            match = line_re.fullmatch(line)
            if match is None:
                corrupt.append((index, line[:160]))
                continue
            pid, role_worker, body_worker, sequence = (
                int(match.group(group)) for group in range(1, 5))
            payload = match.group(5)
            valid_worker = (role_worker == body_worker and
                            0 <= body_worker < workers)
            valid_pid = (valid_worker and
                         pid == processes[body_worker].pid)
            expected_payload = bytes(
                (ord('A') + body_worker,)) * payload_size
            if (not valid_worker or not valid_pid or
                    payload != expected_payload or
                    not 0 <= sequence < records):
                corrupt.append((index, line[:160]))
                continue
            key = (body_worker, sequence)
            if key in seen:
                corrupt.append((index, b'duplicate ' + repr(key).encode()))
                continue
            seen.add(key)
        expected = {(worker, sequence)
                    for worker in range(workers)
                    for sequence in range(records)}
        if corrupt:
            print('  first corrupt multiprocess log lines:', corrupt[:3])
        missing = sorted(expected - seen)
        if missing:
            print('  first missing multiprocess records:', missing[:12])
        check('multiprocess log has every record once',
              len(raw_lines) == workers * records and seen == expected)
        check('multiprocess log lines stay atomic', not corrupt)


def attach_proto_ver():
    source = os.path.join(os.path.dirname(__file__), '..', 'src',
                          'st_server.pas')
    with open(source, encoding='utf-8') as stream:
        for line in stream:
            match = re.match(r'\s*ATTACH_PROTO_VER\s*=\s*(\d+)', line)
            if match:
                return int(match.group(1))
    raise RuntimeError('ATTACH_PROTO_VER not found')


PROTO_VER = attach_proto_ver()


def fifo_events():
    events = []
    try:
        with open(DEBUG_LOG, encoding='utf-8', errors='replace') as stream:
            for line in stream:
                match = FIFO_RE.search(line)
                if match:
                    events.append({
                        'op': match.group(1),
                        'seq': int(match.group(2)),
                        'origin': match.group(3),
                        'slot': int(match.group(4)),
                        'gen': int(match.group(5)),
                        'kind': int(match.group(6)),
                        'pane': int(match.group(7)),
                        'bytes': int(match.group(8)),
                        'valid': (None if match.group(9) is None
                                  else int(match.group(9))),
                    })
    except FileNotFoundError:
        pass
    return events


def control(path, kind, pane=-1, payload=b'', timeout=5.0):
    """One request per pending peer, deliberately half-closing its writer."""
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    frames = []
    try:
        sock.connect(path)
        sock.sendall(raw_frame(kind, pane, payload))
        sock.shutdown(socket.SHUT_WR)
        while True:
            frame = read_frame(sock, timeout=timeout)
            if frame is None:
                break
            frames.append(frame)
            if frame[0] in (FRAME_CTL_OK, FRAME_CTL_ERR, FRAME_CTL_END):
                break
    finally:
        sock.close()
    return frames


def capture(path):
    frames = control(path, FRAME_CTL_CAPTURE, 0, struct.pack('<ii', 0, 0))
    return b''.join(data for kind, _pane, data in frames
                    if kind == FRAME_CTL_DATA).decode('utf-8', 'replace')


def attach(path):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(8.0)
    sock.connect(path)
    sock.sendall(raw_frame(
        FRAME_ATTACH, -1,
        struct.pack('<iiiii', PROTO_VER, 100, 30, 1, 0)))
    while True:
        frame = read_frame(sock, timeout=8.0)
        if frame is None:
            raise RuntimeError('EOF during attach snapshot')
        if frame[0] == FRAME_READY:
            return sock


check_multiprocess_flow_log()

try:
    os.unlink(DEBUG_LOG)
except FileNotFoundError:
    pass

HOME = stlib.fresh_home('global-command-fifo')
os.makedirs(HOME + '/.superterm', exist_ok=True)
with open(HOME + '/.superterm/superterm.ini', 'w') as stream:
    stream.write('[ui]\nlanguage=en\nbackground=none\n'
                 '[session]\nserver=always\nautosave=0\nautorestore=0\n')
ENV = {
    'SUPERTERM_DEBUG': DEBUG_LOG,
    'SUPERTERM_DEBUG_FULL': '1',
}

owner = stlib.Client(HOME, w=100, h=30, lang='en', env=ENV)
owner.drain(2.0)
sockets = stlib.session_sockets(HOME)
check('session exists', len(sockets) == 1)
path = sockets[0] if sockets else ''
time.sleep(0.2)
baseline = max((event['seq'] for event in fifo_events()), default=0)

peers = []
if path:
    try:
        for _ in range(CLIENTS):
            peers.append(attach(path))
    except (OSError, socket.timeout, RuntimeError) as exc:
        print('  attach error:', exc)
check('three raw clients attached', len(peers) == CLIENTS)

ready = False
readiness_screen = ''
if len(peers) == CLIENTS:
    # The literal command deliberately does not contain READY_MARKER: seeing
    # an echoed shell command must never be mistaken for cat being ready.
    command = (b"stty raw -echo; printf '\\033[2J\\033[HFIFO_READY_%s' "
               b"47A9; exec cat\r")
    try:
        command_written = os.write(owner.fd, command)
    except OSError as exc:
        print('  raw echo command write error:', exc)
        command_written = -1
    check('raw echo command accepted', command_written == len(command))
    deadline = time.time() + 6.0
    while time.time() < deadline:
        owner.drain(0.04)
        readiness_screen = capture(path)
        if READY_MARKER in readiness_screen:
            ready = True
            break
if not ready:
    print('  readiness capture:', repr(readiness_screen))
check('raw echo is ready', ready)

tokens = [[f'{chr(65 + client)}{index:03d};'.encode('ascii')
           for index in range(TOKENS_PER_CLIENT)]
          for client in range(CLIENTS)]
barrier = threading.Barrier(CLIENTS)
errors = []


def sender(client_no):
    try:
        barrier.wait(timeout=3.0)
        for index, token in enumerate(tokens[client_no]):
            peers[client_no].sendall(raw_frame(FRAME_INPUT, 0, token))
            # Deterministic sub-millisecond skew produces interleaving without
            # making the test depend on random scheduling or run slowly.
            time.sleep(((index * 3 + client_no) % 5) * 0.00015)
    except Exception as exc:  # surfaced as a normal test failure below
        errors.append((client_no, repr(exc)))


if ready:
    threads = [threading.Thread(target=sender, args=(client,))
               for client in range(CLIENTS)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=10.0)
    check('concurrent senders completed',
          not errors and all(not thread.is_alive() for thread in threads))
else:
    check('concurrent senders completed', False)

rendered = ''
deadline = time.time() + 8.0
while ready and time.time() < deadline:
    owner.drain(0.03)
    rendered = ''.join(capture(path).split())
    if all(rendered.count(token.decode('ascii')) == 1
           for group in tokens for token in group):
        break
all_tokens = ready and all(rendered.count(token.decode('ascii')) == 1
                           for group in tokens for token in group)
check('every distinguishable token arrived once', all_tokens)

# A final, half-closed INFO request is a FIFO barrier: its response can only be
# generated after every command observed before it has been dequeued.
if path:
    control(path, FRAME_CTL_INFO)
time.sleep(0.15)
events = [event for event in fifo_events() if event['seq'] > baseline]
enqueued = [event for event in events if event['op'] == 'enqueue']
dequeued = [event for event in events if event['op'] == 'dequeue']
enqueue_seq = [event['seq'] for event in enqueued]
dequeue_seq = [event['seq'] for event in dequeued]
check('FIFO logged commands', len(enqueue_seq) >= CLIENTS * TOKENS_PER_CLIENT)
check('enqueue sequence strictly consecutive',
      enqueue_seq == list(range(enqueue_seq[0], enqueue_seq[-1] + 1))
      if enqueue_seq else False)
check('dequeue order equals enqueue order', dequeue_seq == enqueue_seq)
check('no queued command became stale',
      bool(dequeued) and all(event['valid'] == 1 for event in dequeued))

# Reconstruct the PTY byte order solely from the global FIFO observation log.
# Raw clients occupy the three slots following the still-attached owner.
input_events = [event for event in enqueued
                if event['origin'] == 'client' and
                event['kind'] == FRAME_INPUT and event['bytes'] == 5]
input_slots = sorted({event['slot'] for event in input_events})
expected = ''
per_slot = {slot: 0 for slot in input_slots}
if len(input_slots) == CLIENTS:
    slot_to_client = {slot: client for client, slot in enumerate(input_slots)}
    for event in input_events:
        slot = event['slot']
        client = slot_to_client[slot]
        index = per_slot[slot]
        if index < TOKENS_PER_CLIENT:
            expected += tokens[client][index].decode('ascii')
            per_slot[slot] += 1
marker = rendered.rfind(READY_MARKER)
actual = rendered[marker + len(READY_MARKER):] if marker >= 0 else ''
order_ok = (len(expected) == CLIENTS * TOKENS_PER_CLIENT * 5 and
            actual.startswith(expected))
if not order_ok:
    mismatch = next((index for index, (left, right) in
                     enumerate(zip(expected, actual)) if left != right),
                    min(len(expected), len(actual)))
    print(f'  fifo text mismatch at {mismatch}; slots={input_slots}; '
          f'events={len(input_events)} expected={len(expected)} '
          f'actual={len(actual)}')
    print('  expected:', repr(expected[max(0, mismatch - 30):mismatch + 70]))
    print('  actual:  ', repr(actual[max(0, mismatch - 30):mismatch + 70]))
check('PTY text follows global enqueue order', order_ok)

for peer in peers:
    try:
        peer.sendall(raw_frame(FRAME_DETACH, -1))
    except OSError:
        pass
for peer in peers:
    peer.close()
owner.send(b'\x11', 0.10)
owner.send(b'd', 0.40)
owner.close()
stlib.close_all_daemons(HOME)
stlib.report()
