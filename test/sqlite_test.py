#!/usr/bin/env python3
"""superterm test: load one independent template from SQLite."""
import os
import pty
import select
import sqlite3
import struct
import sys
import termios
import time
import fcntl

import pyte

ROOT = '/tmp/opencode/stsqlite'
HOME = ROOT + '/home'
DBDIR = ROOT + '/templates'
SYSINI = ROOT + '/superterm.ini'
BIN = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'bin', 'superterm'))
W, H = 110, 35

sys.path.insert(0, os.path.dirname(__file__))
from stlib import close_all_daemons

close_all_daemons(HOME)
os.makedirs(HOME + '/.superterm', exist_ok=True)
os.makedirs(DBDIR, exist_ok=True)
for path in (HOME + '/.superterm/session.ini', HOME + '/.superterm/superterm.ini'):
    try:
        os.remove(path)
    except FileNotFoundError:
        pass

db = DBDIR + '/database-template.db'
try:
    os.remove(db)
except FileNotFoundError:
    pass
conn = sqlite3.connect(db)
conn.executescript('''
create table metadata(key text primary key, value text not null);
create table sessions(name text primary key, enabled integer,
    focused_window integer, ord integer);
create table windows(session_name text not null, name text not null,
    enabled integer, layout text, focused_pane integer, ord integer,
    primary key(session_name, name));
create table panes(session_name text not null, window_name text not null,
    name text not null, enabled integer, terminal text, cmd text, cwd text,
    postconnect text, scrollback integer, ord integer,
    primary key(session_name, window_name, name));
insert into metadata values ('name', 'database-template');
insert into metadata values ('enabled', '1');
insert into metadata values ('default_session', 'main');
insert into sessions values ('main', 1, 0, 0);
insert into windows values ('main', 'shell', 1, 'L', 0, 0);
insert into panes values ('main', 'shell', 'one', 1, 'db-shell', '', '', '', 0, 0);
''')
conn.commit()
conn.close()

with open(SYSINI, 'w') as f:
    f.write('[storage]\nbackend=sqlite\ndirectory=templates\n\n')
    f.write('[t1]\nname=db-shell\nenabled=1\ntype=local\ncmd=/bin/bash -i\n')


class Session:
    def __init__(self):
        self.screen = pyte.Screen(W, H)
        self.stream = pyte.ByteStream(self.screen)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.environ.update(TERM='xterm', SHELL='/bin/bash', HOME=HOME,
                              SUPERTERM_INI=SYSINI)
            os.execv(BIN, [BIN])
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ,
                    struct.pack('HHHH', H, W, 0, 0))

    def drain(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            readable, _, _ = select.select([self.fd], [], [], 0.05)
            if readable:
                try:
                    data = os.read(self.fd, 65536)
                except OSError:
                    return
                try:
                    self.stream.feed(data)
                except Exception:
                    pass

    def text(self):
        return '\n'.join(row.rstrip() for row in self.screen.display)

    def close(self):
        try:
            os.write(self.fd, b'\x1bq')
            self.drain(0.5)
        except OSError:
            pass
        try:
            os.close(self.fd)
        except OSError:
            pass
        try:
            os.waitpid(self.pid, 0)
        except ChildProcessError:
            pass


fails = []
session = Session()
try:
    session.drain(1.5)
    text = session.text()
    if 'db-shell' not in text:
        fails.append('SQLite template starts terminal')
    os.write(session.fd, b'\x1br')
    session.drain(0.4)
    if 'database-template' not in session.text():
        fails.append('SQLite template appears in menu')
finally:
    session.close()
    close_all_daemons(HOME)

for name in ('SQLite template starts terminal', 'SQLite template appears in menu'):
    print(f'{name:35}: ' + ('FAIL' if name in fails else 'OK'))
sys.exit(1 if fails else 0)
