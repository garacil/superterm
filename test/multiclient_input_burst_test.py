#!/usr/bin/env python3
"""Every attached client can write concurrently to the shared focused pane."""
import os
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, run_cli


HOME = stlib.fresh_home('multiclient-input-burst')
with open(HOME + '/.superterm/superterm.ini', 'w') as fh:
    fh.write('[ui]\nlanguage=en\nbackground=none\n'
             '[session]\nserver=always\nautosave=0\nautorestore=0\n')
DEBUG_ENV = {
    'SUPERTERM_DEBUG': '/tmp/superterm-multiclient-input-burst.log',
    'SUPERTERM_DEBUG_FULL': '1',
    'SUPERTERM_HEAP_LOG': '/tmp/superterm-multiclient-input-burst-heap',
    'HEAPTRC': 'nohalt',
}

clients = [stlib.Client(HOME, w=100, h=30, lang='en', env=DEBUG_ENV)]
clients[0].drain(2.0)
sockets = stlib.session_sockets(HOME)
check('session exists', len(sockets) == 1)
session = os.path.basename(sockets[0])[:-5] if sockets else ''
clients.extend(stlib.Client(HOME, args=['--attach', session],
                            w=100, h=30, lang='en', env=DEBUG_ENV)
               for _ in range(2))
for client in clients:
    client.drain(2.0)
check('three clients attached', all(client.alive() for client in clients))

check('shared pane focused',
      run_cli(['focus', session + ':1'], HOME,
              env=DEBUG_ENV).returncode == 0)
for client in clients:
    client.drain(0.6)

# Raw cat makes every byte immediately visible.  A canonical cat is invalid
# for this test: the newline sent by one client may legitimately overtake
# bytes still queued on another client socket, leaving those bytes in the
# tty line discipline until the next newline.
os.write(clients[0].fd,
         b"stty raw -echo; printf '\\033[2J\\033[HOK'; exec cat\r")
ready_deadline = time.time() + 5.0
while time.time() < ready_deadline:
    for client in clients:
        client.drain(0.08)
    if 'OK' in run_cli(['capture', session + ':1'], HOME,
                       env=DEBUG_ENV).stdout:
        break
check('raw reader ready', 'OK' in run_cli(
    ['capture', session + ':1'], HOME, env=DEBUG_ENV).stdout)

# Every writer blocks on the same barrier and then performs one PTY write.
# There is deliberately no asserted order *between* clients: the scheduler
# and the server accept loop decide that.  What FIFO must preserve is every
# complete byte and each socket's own order, so each client has a disjoint,
# alternating alphabet whose projection can be checked after arbitrary
# interleaving.  These punctuation bytes do not occur in the cleared pane or
# the outer FreeVision chrome (unlike X in the "Alt-X Exit" status hint).
alphabets = ('@%', '#&', '$*')
count = 16
payloads = [(alphabet * count).encode('ascii') for alphabet in alphabets]
barrier = threading.Barrier(len(clients) + 1)
write_results = [None] * len(clients)


def concurrent_write(index):
    try:
        barrier.wait(timeout=3.0)
        write_results[index] = os.write(clients[index].fd, payloads[index])
    except Exception as exc:  # reported by the main test thread below
        write_results[index] = exc


writers = [threading.Thread(target=concurrent_write, args=(index,))
           for index in range(len(clients))]
for writer in writers:
    writer.start()
barrier.wait(timeout=3.0)
for writer in writers:
    writer.join(timeout=3.0)
check('all concurrent writers finish', all(not writer.is_alive()
                                            for writer in writers))
for client_no, (result, payload) in enumerate(zip(write_results, payloads), 1):
    check(f'client {client_no} writes complete burst', result == len(payload))

captured = ''
deadline = time.time() + 5.0
while time.time() < deadline:
    for client in clients:
        client.drain(0.08)
    captured = run_cli(['capture', session + ':1'], HOME,
                       env=DEBUG_ENV).stdout
    if all(captured.count(symbol) == count for alphabet in alphabets
           for symbol in alphabet):
        break
wire_alphabet = ''.join(alphabets)
wire = ''.join(ch for ch in captured if ch in wire_alphabet)
check('FIFO delivers the complete global stream',
      len(wire) == sum(len(payload) for payload in payloads))
for client_no, alphabet in enumerate(alphabets, 1):
    projection = ''.join(ch for ch in wire if ch in alphabet)
    check(f'client {client_no} FIFO order preserved',
          projection == alphabet * count)
rendered = False
render_deadline = time.time() + 5.0
while time.time() < render_deadline:
    for client in clients:
        client.drain(0.08)
    rendered = all(
        all(client.text().count(symbol) == count
            for alphabet in alphabets for symbol in alphabet)
        for client in clients)
    if rendered:
        break
if not rendered:
    for client_no, client in enumerate(clients, 1):
        counts = ', '.join(
            f'{symbol}={client.text().count(symbol)}'
            for alphabet in alphabets for symbol in alphabet)
        print(f'  client {client_no} rendered counts: {counts}')
        for row_no, row in enumerate(client.text().splitlines()):
            if any(symbol in row for alphabet in alphabets
                   for symbol in alphabet):
                print(f'    row {row_no:02d}: {row!r}')
check('all three bursts rendered to every client', rendered)

# The pane is intentionally still in raw cat.  Detach the clients and let the
# fixture close the daemon/pane; sending Ctrl-C would only be another data byte
# in raw mode.
for client in reversed(clients):
    client.send(b'\x11', 0.10)
    client.send(b'd', 0.35)
    client.wait_exit(timeout=5.0)
    client.close()
stlib.close_all_daemons(HOME)
stlib.report()
