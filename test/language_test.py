#!/usr/bin/env python3
"""superterm test: English default and runtime English/Spanish switching."""
import fcntl
import os
import pty
import select
import struct
import sys
import termios
import time

import pyte


BIN = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'bin', 'superterm'))
ROOT = '/tmp/opencode/stlanguage'
HOME = ROOT + '/home'
CONFIG = HOME + '/.superterm/superterm.ini'
W, H = 110, 35
os.makedirs(HOME + '/.superterm', exist_ok=True)
with open(CONFIG, 'w') as config:
    config.write('[ui]\nlanguage=es\n[session]\nautosave=0\nautorestore=0\n')


class Session:
    def __init__(self):
        self.screen = pyte.Screen(W, H)
        self.stream = pyte.ByteStream(self.screen)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.environ.update({
                'TERM': 'xterm',
                'SHELL': '/bin/bash',
                'HOME': HOME,
                'SUPERTERM_INI': ROOT + '/none.ini',
            })
            os.execv(BIN, [BIN])
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ,
                    struct.pack('HHHH', H, W, 0, 0))

    def drain(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            readable, _, _ = select.select([self.fd], [], [], 0.05)
            if readable:
                try:
                    self.stream.feed(os.read(self.fd, 65536))
                except Exception:
                    return

    def send(self, data, seconds=0.6):
        os.write(self.fd, data)
        self.drain(seconds)

    def text(self):
        return '\n'.join(''.join(row).rstrip() for row in self.screen.display)

    def close(self):
        try:
            os.write(self.fd, b'\x1bq')
            self.drain(0.4)
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


def check(name, condition):
    print(f'{name:36}: ' + ('OK' if condition else 'FAIL'))
    if not condition:
        fails.append(name)


s = Session()
try:
    s.drain(1.2)
    check('Spanish config selects Spanish UI',
          'Paneles' in s.text() and 'Idioma' in s.text())

    s.send(b'\x1be\r')  # Sesion -> Asistente nueva sesion
    check('Spanish input dialog is localized',
          'Aceptar' in s.text() and 'Cancelar' in s.text())
    s.send(b'\t\t\r')

    s.send(b'\x1bi')  # Idioma
    check('Spanish language menu offers English', 'English' in s.text())
    s.send(b'e')
    check('English switch updates the UI',
          'Panels' in s.text() and 'Language' in s.text())
    check('English switch persists', 'language=en' in open(CONFIG).read())

    s.send(b'\x1bl')  # Language
    s.send(b's')
    check('Spanish switch updates the UI',
          'Paneles' in s.text() and 'Idioma' in s.text())
    s.send(b'\x1ba\r')  # Ayuda -> Ayuda y atajos
    check('Spanish message dialog is localized', 'Aceptar' in s.text())
finally:
    s.close()


sys.exit(1 if fails else 0)
