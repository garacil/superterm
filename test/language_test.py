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

from stlib import feed_pyte, wait_pid


BIN = os.environ.get('SUPERTERM_TEST_BIN', os.path.abspath(os.path.join(
    os.path.dirname(__file__), '..', 'bin', 'superterm')))
ROOT = '/tmp/opencode/stlanguage'
HOME = ROOT + '/home'
CONFIG = HOME + '/.superterm/superterm.ini'
W, H = 110, 35
os.makedirs(HOME + '/.superterm', exist_ok=True)
with open(CONFIG, 'w') as config:
    config.write('[ui]\nlanguage=es\n[session]\nserver=detach\n'
                 'autosave=0\nautorestore=0\n'
                 '[profile.alpha]\nname=alpha\nenabled=1\nwindows=\n')


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
                    data = os.read(self.fd, 65536)
                except OSError:
                    return
                feed_pyte(self.stream, data, 'language')

    def send(self, data, seconds=0.6):
        os.write(self.fd, data)
        self.drain(seconds)

    def text(self):
        return '\n'.join(''.join(row).rstrip() for row in self.screen.display)

    def close(self):
        try:
            os.write(self.fd, b'\x1bx')
            self.drain(0.4)
        except OSError:
            pass
        try:
            os.close(self.fd)
        except OSError:
            pass
        wait_pid(self.pid)


fails = []


def check(name, condition):
    print(f'{name:36}: ' + ('OK' if condition else 'FAIL'))
    if not condition:
        fails.append(name)


def click_text(session, label):
    """Click the middle of the first visible occurrence of label."""
    for y, row in enumerate(session.screen.display):
        x = row.find(label)
        if x >= 0:
            px = x + max(1, len(label) // 2) + 1
            py = y + 1
            session.send(f'\x1b[<0;{px};{py}M\x1b[<0;{px};{py}m'.encode())
            return True
    return False


s = Session()
try:
    s.drain(1.2)
    check('Spanish config selects Spanish UI',
          'Paneles' in s.text() and 'Opciones' in s.text())
    status = ''.join(s.screen.display[-1])
    check('Spanish status prefers Detach',
          'Separar' in status and 'Salir' not in status and
          'Ctrl-Q f Pantalla' in status and 'F5 Pantalla' not in status)

    s.send(b'\x1bv', 0.5)  # "Ventanas" menu
    check('Spanish window-wide actions fit',
          'Minimizar todas las ventanas' in s.text() and
          'Restaurar todas las ventanas' in s.text())
    s.send(b'\x1b', 0.3)

    s.send(b'\x1br', 0.5)  # "Perfiles" menu
    s.send(b's', 0.7)  # -> "Gestionar perfiles..."
    check('Spanish profile manager opens',
          'Guardar actual' in s.text() and 'alpha' in s.text())
    check('Profile overwrite action clicked', click_text(s, 'Guardar actual'))
    check('Spanish confirmation uses Si/No',
          'Sobrescribir el perfil' in s.text() and
          'Si' in s.text() and 'No' in s.text() and
          'Aviso' not in s.text())
    s.send(b'n', 0.4)  # decline without changing the profile
    s.send(b'\x1b', 0.3)  # close the profile manager

    s.send(b'\x1bs', 0.5)  # "Sesiones" menu
    s.send(b'a')  # -> "Asistente de sesion rapida" (quick session wizard)
    check('Spanish input dialog is localized',
          'Aceptar' in s.text() and 'Cancelar' in s.text())
    s.send(b'\t\t\r')

    s.send(b'\x1bo', 0.5)  # "Opciones" menu
    s.send(b'i', 0.5)  # "Idioma" (Language)
    check('Spanish language menu offers English', 'English' in s.text())
    s.send(b'e')
    check('English switch updates the UI',
          'Panes' in s.text() and 'Options' in s.text())
    status = ''.join(s.screen.display[-1])
    check('English status prefers Detach',
          'Detach' in status and 'Exit' not in status and
          'Ctrl-Q f Full screen' in status and
          'F5 Full screen' not in status)
    check('English switch persists', 'language=en' in open(CONFIG).read())

    s.send(b'\x1bo', 0.5)  # Options
    s.send(b'l', 0.5)  # Language
    s.send(b's')
    check('Spanish switch updates the UI',
          'Paneles' in s.text() and 'Opciones' in s.text())
    s.send(b'\x1ba\r')  # "Ayuda" -> "Ayuda y atajos" (Help -> Help and shortcuts)
    check('Spanish message dialog is localized', 'Aceptar' in s.text())
    check('Spanish help shows fullscreen chord',
          'Ctrl-Q f pantalla' in s.text() and 'Alt-F3 cierra' in s.text())
    s.send(b'\x1b', 0.5)  # close the help dialog
    s.send(b'\x1b', 0.5)  # and any menu still left open
    s.send(b'\x1bx', 1.5)  # Alt-X: the single Exit command
finally:
    s.close()


sys.exit(1 if fails else 0)
