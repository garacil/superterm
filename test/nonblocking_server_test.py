#!/usr/bin/env python3
"""Detached daemon: partial frames, stalled peers and descriptors > 1023."""
import os
import re
import resource
import socket
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import (FRAME_CTL_CAPTURE, FRAME_CTL_DATA, FRAME_CTL_END,
                   FRAME_CTL_INFO, FRAME_CTL_WINOP, FRAME_DETACH, FRAME_INPUT,
                   FRAME_READY, FRAME_SCREEN, FRAME_SESSION, WINOP_RENAME,
                   check, pas_string, raw_frame, read_frame)

PROTO_VER = stlib.attach_proto_ver()


def start_detached(home):
    client = stlib.Client(home, w=100, h=28)
    client.drain(2.0)
    client.send(b'\x11', 0.3)
    client.send(b'd', 0.8)
    client.send(b'\r', 1.3)
    time.sleep(0.4)
    client.close()
    sockets = stlib.session_sockets(home)
    return sockets[0] if len(sockets) == 1 else None


def ctl_frames(path, kind, pane=-1, payload=b'', timeout=3.0):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    started = time.monotonic()
    frames = []
    try:
        sock.connect(path)
        sock.sendall(raw_frame(kind, pane, payload))
        while True:
            frame = read_frame(sock, timeout=timeout)
            if frame is None:
                break
            frames.append(frame)
            if frame[0] in (40, 41, FRAME_CTL_END):
                break
    except (OSError, socket.timeout):
        pass
    finally:
        sock.close()
    return frames, time.monotonic() - started


def info_works(path, timeout=3.0):
    frames, elapsed = ctl_frames(path, FRAME_CTL_INFO, timeout=timeout)
    return (len(frames) == 2 and frames[0][0] == FRAME_CTL_DATA and
            frames[1][0] == FRAME_CTL_END), elapsed


def attach_in_fragments(path):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(5.0)
    sock.connect(path)
    payload = struct.pack('<iiiii', PROTO_VER, 100, 28, 1, 0)
    frame = raw_frame(1, -1, payload)
    cuts = (1, 3, 7, 9, 13, len(frame))
    start = 0
    for end in cuts:
        sock.sendall(frame[start:end])
        start = end
        time.sleep(0.015)
    kinds = []
    try:
        while True:
            item = read_frame(sock, timeout=5.0)
            if item is None:
                break
            kinds.append(item[0])
            if item[0] == FRAME_READY:
                break
    except (OSError, socket.timeout):
        pass
    ok = bool(kinds) and kinds[0] == FRAME_SESSION and \
        FRAME_SCREEN in kinds and kinds[-1] == FRAME_READY
    return sock, ok


HOME = stlib.fresh_home('nonblocking-server')
SOCK = start_detached(HOME)
check('detached session exists', SOCK is not None)

if SOCK:
    # Sending one header byte used to make ReadFirstFrame enter a blocking
    # ReadFull. A second peer could not even obtain CTL_INFO afterwards.
    stalled_header = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    stalled_header.connect(SOCK)
    stalled_header.sendall(raw_frame(FRAME_CTL_INFO, -1)[:1])
    time.sleep(0.2)
    ok, elapsed = info_works(SOCK, timeout=2.0)
    check('partial header does not block daemon', ok and elapsed < 1.5)
    time.sleep(1.2)
    stalled_header.settimeout(1.0)
    try:
        expired = stalled_header.recv(1) == b''
    except (OSError, socket.timeout):
        expired = False
    check('partial header expires after 1s', expired)
    stalled_header.close()

    # The same invariant applies after a complete header and a partial body.
    stalled_body = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    stalled_body.connect(SOCK)
    header = struct.pack('<BBhI', FRAME_CTL_INFO, 0, -1, 4096)
    stalled_body.sendall(header + b'x')
    time.sleep(0.15)
    ok, elapsed = info_works(SOCK, timeout=2.0)
    check('partial payload does not block daemon', ok and elapsed < 1.5)
    stalled_body.close()

    # Fragmentation is valid, not an error: both attach and later input must
    # survive arbitrary header/payload boundaries.
    raw_client, attached = attach_in_fragments(SOCK)
    check('fragmented attach gets snapshot', attached)
    if attached:
        command = raw_frame(FRAME_INPUT, 0,
                            b'echo FRAGMENTED_INPUT_OK\r')
        for byte in command:
            raw_client.sendall(bytes((byte,)))
            time.sleep(0.001)
        time.sleep(0.7)
        capture, _ = ctl_frames(
            SOCK, FRAME_CTL_CAPTURE, 0, struct.pack('<ii', 0, 0), 4.0)
        text = b''.join(data for kind, _pane, data in capture
                        if kind == FRAME_CTL_DATA).decode('utf-8', 'replace')
        check('fragmented client input reaches PTY',
              'FRAGMENTED_INPUT_OK' in text)
        raw_client.sendall(raw_frame(FRAME_DETACH, -1))
    raw_client.close()

    # A program which never reads its slave PTY fills the master quickly. Its
    # queued input must be POLLOUT-driven without delaying the shell pane or
    # control socket.
    new_sleep = bytes((1, 0)) + pas_string('') + pas_string('sleep 30') + \
        pas_string('') + pas_string('Blocked reader')
    created, _ = ctl_frames(SOCK, FRAME_CTL_WINOP, 0, new_sleep, 4.0)
    check('non-reading pane created', bool(created) and created[-1][0] == 40)
    blocked_send, _ = ctl_frames(SOCK, 12, 1, b'x' * (1024 * 1024), 4.0)
    check('blocked PTY input is queued', bool(blocked_send) and
          blocked_send[-1][0] == 40)
    ok, elapsed = info_works(SOCK, timeout=2.0)
    check('blocked PTY does not stall controls', ok and elapsed < 1.5)
    shell_send, _ = ctl_frames(SOCK, 12, 0,
                               b'echo OTHER_PANE_STILL_OK\r', 3.0)
    check('other pane accepts input', bool(shell_send) and
          shell_send[-1][0] == 40)
    ctl_frames(SOCK, FRAME_CTL_WINOP, 1, bytes((2,)), 3.0)

    # A snapshot receiver which stops consuming must not stall controls. Fill
    # enough scrollback that the snapshot exceeds a normal Unix socket buffer.
    frames, _ = ctl_frames(
        SOCK, 12, 0, b'seq 1 18000\r', timeout=3.0)
    check('large scrollback command accepted', bool(frames) and
          frames[-1][0] == 40)
    time.sleep(1.0)
    history, _ = ctl_frames(
        SOCK, FRAME_CTL_CAPTURE, 0, struct.pack('<ii', 1, 0), 5.0)
    history_text = b''.join(data for kind, _pane, data in history
                            if kind == FRAME_CTL_DATA)
    check('chunked capture keeps every batch',
          b'9000\n' in history_text and b'17000\n' in history_text)
    snapshot_peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    snapshot_peer.connect(SOCK)
    snapshot_peer.sendall(raw_frame(
        1, -1, struct.pack('<iiiii', PROTO_VER, 100, 28, 1, 0)))
    time.sleep(0.5)
    ok, elapsed = info_works(SOCK, timeout=3.0)
    check('stalled snapshot does not block controls', ok and elapsed < 2.0)
    snapshot_peer.close()

    # All 16 pending slots (MAX_PENDING_CONNECTIONS) held by silent peers:
    # the next connection is closed at once instead of queueing behind them,
    # and the slots return as soon as the first-frame deadline expires.
    idlers = []
    for _ in range(16):
        peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        peer.connect(SOCK)
        idlers.append(peer)
    time.sleep(0.3)
    overflow = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    overflow.settimeout(2.0)
    overflow.connect(SOCK)
    try:
        refused = overflow.recv(1) == b''
    except (OSError, socket.timeout):
        refused = False
    overflow.close()
    check('connection beyond the pending slots is closed', refused)
    time.sleep(1.2)     # FIRST_FRAME_TIMEOUT_MS expires every idler
    ok, elapsed = info_works(SOCK, timeout=2.0)
    check('slots recover once silent peers expire', ok and elapsed < 1.5)
    for peer in idlers:
        peer.close()

    # A header promising more than MAX_FRAME_SIZE is invalid on sight: the
    # peer is dropped without the daemon ever reserving that buffer.
    huge = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    huge.settimeout(2.0)
    huge.connect(SOCK)
    huge.sendall(struct.pack('<BBhI', FRAME_CTL_INFO, 0, -1,
                             200 * 1024 * 1024))
    try:
        dropped = huge.recv(1) == b''
    except (OSError, socket.timeout):
        dropped = False
    huge.close()
    check('oversize frame header drops the peer', dropped)
    ok, elapsed = info_works(SOCK, timeout=2.0)
    check('daemon alive after oversize header', ok and elapsed < 1.5)

    # A valid outer frame can still contain a malicious Pascal-string length.
    # The nested decoder must reject it by subtraction (without integer
    # overflow/allocation), release the pane lease in its finally block, and
    # accept the immediately following well-formed rename.
    malformed_rename = bytes((WINOP_RENAME,)) + struct.pack('<i', 0x7fffffff)
    bad_nested, _ = ctl_frames(
        SOCK, FRAME_CTL_WINOP, 0, malformed_rename, 3.0)
    check('oversize nested string is rejected',
          bool(bad_nested) and bad_nested[-1][0] == 41)
    good_rename = bytes((WINOP_RENAME,)) + pas_string('LEASE_RELEASED')
    renamed, _ = ctl_frames(SOCK, FRAME_CTL_WINOP, 0, good_rename, 3.0)
    check('malformed request releases pane lease',
          bool(renamed) and renamed[-1][0] == 40)
    ok, elapsed = info_works(SOCK, timeout=2.0)
    check('daemon alive after nested length attack', ok and elapsed < 1.5)


# Integration coverage for the old select FD_SETSIZE failure. The UI, pane,
# listener and accepted sockets all start above 1023 in the forked daemon.
HIGH_HOME = stlib.fresh_home('poll-high-fd')
fillers = []
old_limit = resource.getrlimit(resource.RLIMIT_NOFILE)
target_limit = 1152
high_fd_ready = False
try:
    soft, hard = old_limit
    if soft < target_limit:
        new_soft = target_limit if hard == resource.RLIM_INFINITY else \
            min(target_limit, hard)
        resource.setrlimit(resource.RLIMIT_NOFILE,
                           (new_soft, hard))
    while True:
        fd = os.open('/dev/null', os.O_RDONLY)
        os.set_inheritable(fd, True)
        fillers.append(fd)
        if fd >= 1050:
            high_fd_ready = True
            break
except (OSError, ValueError):
    high_fd_ready = False

check('high descriptor setup available', high_fd_ready)
high_sock = None
if high_fd_ready:
    high_client = stlib.Client(HIGH_HOME, w=90, h=26)
    for fd in fillers:
        os.close(fd)
    fillers = []
    # The forked UI keeps the inherited high descriptors, while this test
    # moves only its PTY master back below FD_SETSIZE because Python's select
    # wrapper intentionally refuses high descriptors.
    low_master = os.dup(high_client.fd)
    os.close(high_client.fd)
    high_client.fd = low_master
    high_client.drain(2.0)
    high_client.send(b'\x11', 0.3)
    high_client.send(b'd', 0.8)
    high_client.send(b'\r', 1.4)
    time.sleep(0.5)
    high_client.close()
    high_sockets = stlib.session_sockets(HIGH_HOME)
    high_sock = high_sockets[0] if len(high_sockets) == 1 else None
    ok, _elapsed = info_works(high_sock, timeout=3.0) if high_sock else \
        (False, 0)
    check('daemon serves descriptors above 1023', ok)

for fd in fillers:
    os.close(fd)
try:
    resource.setrlimit(resource.RLIMIT_NOFILE, old_limit)
except (OSError, ValueError):
    pass

stlib.close_all_daemons(HOME)
stlib.close_all_daemons(HIGH_HOME)
stlib.report()
